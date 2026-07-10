// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The result schema of a query — the columns it would yield, named and typed,
/// WITHOUT running it.
///
/// A `SELECT`'s result has a name and a type per column: `SELECT *` takes them
/// from the relations in scope, a bare-column list from the column names, and
/// an expression list from each item's alias (else a derived name, else a
/// positional `column N`). `Catalog.columns(of:)` computes this by RESOLVING
/// the query — the same name → schema resolution compilation runs — but never
/// opening a cursor, so it is safe over an empty or costly source. It is the
/// one capability behind the `INFORMATION_SCHEMA` overlay's own headers, a
/// future `SELECT *` empty-result header, and a `.schema` metacommand.

/// One column of a query's result: its output name and its value type.
public struct OutputColumn: Hashable, Sendable {
  /// The column's output name — an alias, a source column's name, or a
  /// positional `column N` for an unnamed expression.
  public let name: String

  /// The column's value type.
  public let type: ValueType

  public init(name: String, type: ValueType) {
    self.name = name
    self.type = type
  }
}

extension Catalog where Self: ~Escapable {
  /// The result columns `query` would yield, named and typed, resolved WITHOUT
  /// executing it.
  ///
  /// The result columns are the FIRST arm's projection (the ISO rule a `UNION`
  /// follows), so a union names its result off its leading `SELECT`. The column
  /// count matches the compiled plan's `width`; the names and types come from
  /// re-walking the projection exactly as compilation resolves it:
  ///
  ///   - `SELECT *` — every real column of every relation in scope, in chain
  ///     order (never a virtual column), named and typed from each relation's
  ///     schema, matching what `Scope.terms(.all)` projects.
  ///   - `SELECT a, b` — each column's name, typed from the relation that
  ///     resolves it.
  ///   - `SELECT f(a) AS x, b` — each item's alias, else a bare column's name,
  ///     else a positional `column N` (1-based). A bare column carries its
  ///     source type and a literal its own; every other expression is reported
  ///     `.integer`, the engine's exact-numeric default.
  ///
  /// The result columns come from the first arm's projection, but ONLY after
  /// the WHOLE query validates: `compile` resolves every arm (each `WHERE`,
  /// join, and projection) and cross-checks a `UNION`'s arm arity, without
  /// opening a cursor. So a query whose first arm names its columns cleanly but
  /// whose `WHERE` references a missing column, or whose second `UNION` arm
  /// mismatches the arity, faults here EXACTLY as a run would rather than
  /// returning headers for a query that cannot run.
  ///
  /// `routines` are the scalar functions a run would resolve against — pass the
  /// SAME set here so a projected call `TAG(Name)` reports its declared return
  /// type rather than the `.integer` default. It defaults to none, matching a
  /// run with no custom routines.
  ///
  /// `validate` (default `true`) whole-query type-checks before deriving, so a
  /// static shape check faults an ill-typed query a run would only reach with
  /// rows — `SELECT Name + 1 …` reports `SQLError.operand`. Pass `false` when a
  /// run has ALREADY proved the query runnable (an empty result whose headers
  /// this fills in): the data-dependent filter never reached the projection, so
  /// re-validating the reachable `Name + 1` would fault a query that SUCCEEDED.
  /// `compile` still runs either way — it resolves the relations and CTEs the
  /// derive needs and is non-faulting for a runnable query — only the operand
  /// type-check is skipped.
  ///
  /// - Throws: the same resolution faults `run(query)` raises —
  ///   `SQLError.relation` for an unknown relation,
  ///   `SQLError.column`/`SQLError.ambiguous` for a column reference that does
  ///   not resolve to exactly one relation, `SQLError.function` for a call to
  ///   an unregistered scalar function anywhere in the query, `SQLError.arity`
  ///   for a `UNION` whose arms project differing column counts; and, when
  ///   `validate`, `SQLError.operand` for an ill-typed reachable expression.
  public borrowing func columns(of query: Query, routines: Routines,
                                validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> {
    // Pure engine: it types calls against exactly the `routines` given, seeding
    // no prelude. `import SQLStandard` adds a prelude-defaulting overload
    // (`columns(of:validate:)`). A typing path has no bindings.
    let context = Context(routines: routines)
    // Extend the scope with any `definition_schema.` store relation the query
    // names, so its result schema resolves the reserved relation the same as a
    // run would — SCHEMA-ONLY, so typing never triggers the row build.
    let scope = augment(context, for: query, rows: false)
    // Validate the whole query without executing — the same compile the run
    // path drives, resolving every arm and cross-checking a UNION's arity — so
    // a schema is returned only for a query that could actually run.
    _ = try compile(query, scope)
    // Type-check every REACHABLE operand and call across all arms — the
    // projection, `WHERE`, and `HAVING` of each. `compile` resolves a call's
    // arguments but cannot check the routine EXISTS or that it is called with
    // its declared arity and argument kinds, and the first-arm walk below
    // sees only the first projection; `typecheck` faults an unknown or
    // ill-typed call or a bad operand anywhere a run would evaluate it, and —
    // like the executor — skips an arm a `false AND`/`true OR` short-circuits,
    // so a query that runs is not rejected for an unreachable call. A caller
    // that already RAN the query (`validate: false`) skips it: a reachable
    // operand a data-dependent filter never reached would otherwise fault a
    // query that produced its (empty) result.
    if validate { try typecheck(query, scope) }
    // The result columns are the first arm's projection (the ISO rule a UNION
    // follows), resolved against the validated scope; a scalar call types from
    // its routine's declared return type. `validate` rides through so a
    // `SELECT *` over a view derives the body's types WITHOUT re-type-checking
    // it — the view body's own reachable-operand check is gated the same as the
    // outer query's, so a `validate: false` derive faults nowhere.
    return try columns(of: query.first, scope, validate: validate)
  }

  /// The result columns `statement` would yield, named and typed, resolved
  /// WITHOUT executing it — the statement-level entry that keeps a `WITH`'s CTE
  /// scope in place.
  ///
  /// A `select` derives exactly as `columns(of query:)` does. A `with` derives
  /// its TRAILING query against the statement's common table expressions, so a
  /// reference the CTEs bind — a `SELECT *` over a CTE, or a name a CTE shadows
  /// off a same-named base relation — resolves against the CTE the run did, not
  /// the base catalog: `WITH t(x) AS (SELECT 1) SELECT * FROM t` reports one
  /// column `x`, even where a base `t` of a different width exists. The scope is
  /// SCHEMA-ONLY — each CTE contributes its declared column list (typed
  /// `.integer`, the default a materialised relation reports) without running
  /// its body — so the derive never opens a cursor, exactly as `columns(of
  /// query:)` never does. A `create` and a `function` name no result, so each
  /// faults `SQLError.statement` the way running one does.
  ///
  /// `routines` and `validate` carry the meaning `columns(of query:)` gives
  /// them; pass `validate: false` after a run has proved the statement runnable.
  ///
  /// - Throws: the resolution faults `columns(of query:)` raises, plus
  ///   `SQLError.statement` for a `create` or a `function`.
  public borrowing func columns(of statement: Statement,
                                routines: Routines,
                                validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> {
    switch statement {
    case let .select(query):
      return try columns(of: query, routines: routines, validate: validate)
    case let .with(ctes, query):
      return try columns(of: query, with: ctes, routines: routines,
                         validate: validate)
    case .create:
      throw .statement("CREATE VIEW names no result columns")
    case .function:
      throw .statement("CREATE FUNCTION names no result columns")
    }
  }

  /// The result columns the trailing `query` of a `WITH` would yield, resolved
  /// against a SCHEMA-ONLY overlay of the `ctes` in scope.
  ///
  /// Each CTE binds a `Materialised` of its DECLARED columns with no rows —
  /// the schema the run's materialised CTE resolves to (columns from the
  /// declared list, every type `.integer`) — laid into the overlay in source
  /// order so a later CTE, and the trailing query, resolve a name the same
  /// precedence a run applies (a CTE shadows a base relation of the same name).
  /// The `definition_schema.` store augment then extends this overlay for the
  /// trailing query exactly as `columns(of query:)` does, so a `WITH` whose
  /// trailing query also names a reserved store relation still resolves it —
  /// the store yields to a CTE of the same name, the run's order.
  ///
  /// A name repeated in the list (case-insensitively) faults
  /// `SQLError.redefinition`, the same fault `Engine.with` raises before
  /// materialising, rather than silently shadowing the earlier binding.
  ///
  /// When `validate`, each CTE BODY is validated before its schema is trusted by
  /// the SAME code a run drives — `Engine.validate`, the compile-time structural
  /// check `Engine.with` runs before materialising: the recursive shape (a
  /// recursive reference must be the final `UNION` arm; a self-reference in the
  /// anchor with no same-named base faults `SQLError.unsupported`, the recursive
  /// shape a run rejects BEFORE materialising) and the declared arity (the
  /// compiled body width against the column list, `SQLError.columns` on a
  /// mismatch — the anchor and recursive arm checked separately, self bound only
  /// in the recursive arm). The schema path also asks that helper to run its
  /// reachable-operand type-check (`typecheck: true` — the run defers this to
  /// execution, so it stays OFF the run path): folding it in rather than layering
  /// it here keeps ONE per-arm scoping for both, so a recursive CTE's ANCHOR is
  /// operand-checked against the base scope the run evaluates it in, NOT the
  /// CTE-self overlay. So a dry-run schema is advertised only for a `WITH` that
  /// could actually run, never for one whose body's shape or width contradicts
  /// its declared list — nor for one whose reachable operand a run would fault.
  /// When `validate` is `false` — a
  /// derive after a successful run — the bodies are TRUSTED, not compiled: the
  /// run already proved them consistent, and re-checking a data-dependent-empty
  /// body would fault a statement that succeeded.
  private borrowing func columns(of query: Query, with ctes: Array<CTE>,
                                 routines: Routines,
                                 validate: Bool)
      throws(SQLError) -> Array<OutputColumn> {
    let context = Context(routines: routines)
    var overlay = ScopedRelations()
    for cte in ctes {
      // A name repeated in the list (case-insensitively) would silently shadow
      // the earlier binding in the overlay, so reject it rather than overwrite —
      // the same fault `Engine.with` raises before materialising, so a schema is
      // advertised only for a `WITH` that could actually run.
      guard overlay[cte.name.lowercased()] == nil else {
        throw .redefinition(cte.name)
      }
      // The CTE's schema-only self — its declared columns, no rows, every type
      // `.integer` (the default a materialised relation reports) — bound into
      // the recursive arm's operand check and, after validation, into the
      // overlay a later CTE and the trailing query resolve against.
      let declared =
          Materialised(columns: cte.columns, rows: [],
                       types: Array(repeating: .integer,
                                    count: cte.columns.count))
      // Validate the body's SHAPE and ARITY against the scope of the PRIOR CTEs
      // by the SAME code a run uses — `Engine.validate` — so a schema is not
      // advertised for a `WITH` a run would reject, and this path never again
      // drifts from the engine's recursive-shape and arity rules. It binds the
      // CTE's self only inside the recursive arm (never the whole body), so a
      // recursive reference in the final arm resolves while a self-reference in
      // the anchor faults the recursive shape exactly as the run does. The
      // schema path adds ONE thing the run defers to execution: a
      // reachable-operand type-check over the body — passed IN as `typecheck` so
      // it runs in the SAME per-arm scope the shared helper computes, checking a
      // recursive CTE's anchor against the base scope the run evaluates it in
      // (NOT the CTE-self overlay). A `validate: false` derive skips both — the
      // run already proved the bodies consistent — so `typecheck: false` there.
      if validate {
        // `self.` escapes the shadow the `validate` Bool parameter casts over
        // the shared `validate(_:against:)` engine helper.
        try self.validate(cte, against: context.scoping(overlay),
                          typecheck: true)
      }
      // Bind the CTE's schema-only self into the overlay AFTER its body is
      // validated — the scope a later CTE and the trailing query resolve against
      // — exactly as `Engine.with` binds the materialised relation after running
      // its body.
      overlay[cte.name.lowercased()] = declared
    }
    let scope = augment(context.scoping(overlay), for: query, rows: false)
    _ = try compile(query, scope)
    if validate { try typecheck(query, scope) }
    return try columns(of: query.first, scope, validate: validate)
  }

  /// The result columns of a single `select`, resolved against this catalog
  /// with the in-scope `ctes` — the per-arm worker `columns(of:)` drives.
  ///
  /// This NAMES AND TYPES the projection; it does not re-validate the WHERE,
  /// joins, GROUP BY, HAVING, or ORDER BY. Whole-query validation belongs to
  /// `compile` — the public `columns(of query:)` runs it — so this worker never
  /// duplicates (and never drifts from) that resolution. It runs only after
  /// compilation has proved the arm resolves. `routines` are the scalar
  /// routines a call types from — its declared return type — rather than the
  /// `.integer` default. `validate` (default `true`) rides through to any view
  /// this arm's relations resolve, gating the view body's reachable-operand
  /// check the same as the outer query's — a `validate: false` derive never
  /// re-type-checks a view body a run already proved runnable.
  borrowing func columns(of select: Select, _ context: Context,
                         visited: Set<String> = [],
                         validate: Bool = true)
      throws(SQLError) -> Array<OutputColumn> {
    try scope(of: select, context, visited: visited, validate: validate)
        .columns(of: select.projection, context.routines)
  }

  /// The name-resolution scope of `select` — its FROM relation and each joined
  /// relation resolved to schema and laid end to end in one combined ordinal
  /// space, the same layout compilation resolves a projection against. A
  /// FROM-less `SELECT <expr-list>` projects over no relation, so its scope is
  /// empty. It reads only schemas, never a cursor. `validate` (default `true`)
  /// rides through to each relation's `schema(of:)`, gating a view body's
  /// reachable-operand check the same as the outer query's.
  borrowing func scope(of select: Select, _ context: Context,
                       visited: Set<String> = [],
                       validate: Bool = true)
      throws(SQLError) -> Scope {
    guard let relation = select.from else { return Scope([]) }
    var relations =
        [(relation, try schema(of: relation, context, visited: visited,
                               validate: validate))]
    for join in select.joins {
      let joined = try schema(of: join.relation, context, visited: visited,
                              validate: validate)
      relations.append((join.relation, joined))
    }
    return Scope(relations)
  }

  /// Type-checks every operand in `query` — the projection, `WHERE`, and
  /// `HAVING` of EVERY arm — throwing the run-time fault a bad operand would.
  ///
  /// The result schema types only the FIRST arm's projection (the ISO rule), so
  /// a later set-operation arm's or a `HAVING`'s operand-type error would
  /// otherwise go unadvertised — `SELECT Age FROM t UNION SELECT Name + 1 FROM
  /// t` or `…
  /// HAVING SUM(Name) > 0` resolves its names but `Arithmetic.apply`/
  /// `Aggregate.fold` faults `SQLError.operand` at run. `compile` cannot catch
  /// this (no evaluating term is built), so a schema path type-checks each arm
  /// before returning metadata. It reads no cursor.
  borrowing func typecheck(_ query: Query, _ context: Context,
                           visited: Set<String> = [])
      throws(SQLError) {
    switch query {
    case let .select(select):
      try typecheck(select, context, visited: visited)
    case let .setop(_, left, right, _):
      try typecheck(left, context, visited: visited)
      try typecheck(right, context, visited: visited)
    }
  }

  /// Type-checks a single arm against its own scope, validating exactly the
  /// expressions a run reaches — throwing the operand or function fault a run
  /// would — and skipping those the executor's evaluation order makes
  /// unreachable. The clauses run `WHERE` → group/fold → `HAVING` → limit →
  /// projection, so:
  ///
  ///   - `WHERE` runs first and always validates (`check`, short-circuit
  ///     aware).
  ///   - A statically-false `WHERE` filters every row, so a `GROUP BY` forms no
  ///     group and a non-aggregate query yields no row — nothing after it is
  ///     checked. A whole-result aggregate (no `GROUP BY`) is the exception: it
  ///     emits one empty group, so its `HAVING` and projection are EVALUATED
  ///     over that group (`empty`) — a divide, overflow, or bad routine call
  ///     faults as a run would; an aggregate operand (zero rows) does not.
  ///   - Otherwise the aggregate FOLDS in the projection and `HAVING` run over
  ///     the filtered rows in the group node, before `HAVING` and any limit, so
  ///     every aggregate operand is validated unconditionally (a short-circuit
  ///     or zero-row limit does not spare it).
  ///   - `HAVING` filters grouped rows before the limit: it validates
  ///     short-circuit aware, and a statically false `HAVING` (like a false
  ///     `WHERE`) leaves the projection's non-aggregate work unreachable.
  ///   - The projection runs LAST: a limit that drops every row it would yield
  ///     leaves its non-aggregate work unreachable — a `FETCH FIRST 0 ROWS
  ///     ONLY`, or a positive `OFFSET` over a whole-result aggregate's sole row
  ///     (its output type is still DERIVED for the schema, non-faulting);
  ///     otherwise it validates fully.
  /// A `SubqueryCheck` for a `select` — every UNCORRELATED subquery it nests
  /// recursively TYPE-CHECKED against the SAME shape the run evaluates and
  /// compiled for its arity ONCE, ahead of the `check` walk, into a map `check`
  /// reads. Validating and compiling each subquery here — where the borrowing
  /// catalog is in scope — mirrors the run path's lowering (which resolves and
  /// materialises the inner query), so schema validation matches execution: a
  /// bad column or routine inside a subquery faults, and a `IN (Q)`'s
  /// single-column arity is enforced from the compiled width.
  ///
  /// An `IN (Q)` occurrence (its `Query` in `select.valued`) has its select
  /// list READ at run, so its ORIGINAL shape is type-checked — an `IN (SELECT
  /// 1 / 0 FROM S)` faults `.divide` as the run does. An occurrence ONLY an
  /// `EXISTS` operand runs through the cardinality PROBE (`Select.probe`:
  /// constant projection, `DISTINCT` quantifier and original `OFFSET`/`FETCH`
  /// kept, `ORDER BY` dropped), which never evaluates the original select list
  /// or sort keys — so its PROBED shape is type-checked, matching the run:
  /// `EXISTS (SELECT 1 / 0 FROM S)` does NOT fault `.divide` at validate,
  /// exactly as it does not at run, while a bad inner RELATION or `WHERE`
  /// (retained by the probe) still faults. A `Query` used by BOTH is in
  /// `valued`, so its original is checked (the `IN` needs its values). The
  /// probe applies only to a `probable` `SELECT` — the shape `probe` rewrites
  /// (a non-set-operation select WITHOUT a `HAVING` that is non-`DISTINCT` or
  /// `DISTINCT` WITHOUT an `OFFSET`, its target the constant `1` or, for an
  /// aggregate/grouped one, a cardinality-preserving `COUNT(*)`); any other
  /// EXISTS-only query (a `HAVING` or set operation) runs in FULL, so its
  /// original is checked. The arity width is always the ORIGINAL query's
  /// (cursor-free), as `subquery(of:)` records it on the compile path.
  private borrowing func subqueryCheck(of select: Select, _ context: Context,
                                       visited: Set<String>)
      throws(SQLError) -> SubqueryCheck {
    let valued = select.valued
    var widths = Dictionary<Query, Int>()
    for query in select.subqueries where widths[query] == nil {
      try typecheck(shape(of: query, valued: valued), context, visited: visited)
      widths[query] = try compile(query, context, visited).width
    }
    return SubqueryCheck(widths)
  }

  /// The subquery shape a run of `query` type-checks against — the ORIGINAL for
  /// an `IN (Q)` occurrence (in `valued`, its select list evaluated) or a query
  /// the probe does not rewrite, else the `Select.probe` the `EXISTS`
  /// cardinality probe runs (constant projection, `ORDER BY` dropped, original
  /// `OFFSET`/`FETCH` kept) so validation does not evaluate a select list or
  /// sort key the run never does.
  private borrowing func shape(of query: Query, valued: Set<Query>) -> Query {
    guard !valued.contains(query), case let .select(select) = query,
        select.probable else {
      return query
    }
    return .select(select.probe)
  }

  private borrowing func typecheck(_ select: Select, _ context: Context,
                                   visited: Set<String>)
      throws(SQLError) {
    let routines = context.routines
    let scope = try scope(of: select, context, visited: visited)
    // Type-check and compile every UNCORRELATED subquery ONCE, ahead of the
    // `check` walk, into a map the checks read for validation and arity.
    let subquery = try subqueryCheck(of: select, context, visited: visited)
    // An `ORDER BY` ordinal names a 1-based SELECT-list position; one outside
    // `1 ... width` names no output column and faults `SQLError.column` (spelled
    // as the ordinal), exactly as the compile path's ordinal resolution does —
    // structural and reachability-independent, so a row-dropping limit never
    // spares it. `orderKeys` resolves an IN-RANGE ordinal to its projection
    // expression but silently drops an out-of-range one, so this raises it here.
    if let clause = select.order {
      let width = scope.width(of: select.projection)
      for key in clause.keys {
        if case let .ordinal(position) = key.sort,
            position < 1 || position > width {
          throw .column("\(position)")
        }
      }
    }
    // A GROUPED `ORDER BY` sorts in the grouped slot space, so each sort key
    // must name a `GROUP BY` key, an aggregate, or an output — resolve it
    // through the SAME grouped lowering the run does, faulting `SQLError.grouping`
    // on a resolvable-but-non-grouped column exactly as the compile path does.
    // Structural, so it runs regardless of the WHERE/limit reachability the
    // operand type-check below tracks.
    if select.aggregates {
      try order(grouped: select, scope, context, visited)
    }
    if let predicate = select.predicate {
      try scope.check(predicate, routines, subquery: subquery)
      // A false WHERE filters every row, so a GROUP BY forms no group and a
      // non-aggregate query yields no row — nothing after is reachable. A
      // whole-result aggregate (an aggregate projection or HAVING, no GROUP BY)
      // still emits ONE empty group: the fold sees zero rows, so an aggregate
      // operand never evaluates (it propagates NULL), but the HAVING and
      // projection run over the group's results, so EVALUATE them (`empty`) — a
      // divide, overflow, or bad routine call faults as the run would.
      if scope.constant(predicate, routines) == false {
        if select.aggregates, select.grouping.isEmpty {
          if let having = select.having {
            // HAVING filters the group BEFORE any OFFSET/FETCH limit, so
            // evaluate it UNCONDITIONALLY — a zero `FETCH` or positive `OFFSET`
            // spares only the projection, never HAVING. It validates its
            // operands (a divide, overflow, or bad routine call faults) AND
            // yields the group's fate — a group passes only when HAVING is TRUE,
            // so FALSE or UNKNOWN drops it and the projection is unreachable.
            //
            // A HAVING nesting an `EXISTS`/`IN (Q)` subquery is the exception:
            // `empty` cannot materialise the subquery (it carries no catalog),
            // so it folds UNKNOWN — but the subquery is row-independent and may
            // be TRUE at RUN, keeping the group and RUNNING the projection. So
            // a subquery-bearing HAVING is NOT-definitely-empty: fall through
            // and VALIDATE the projection, so `columns(of:)` surfaces the fault
            // the run would (`SELECT 1 / 0 … HAVING EXISTS (Q)` raises
            // `.divide`). A subquery-free HAVING keeps the precise pruning.
            if !having.subquery, try scope.empty(having, routines) != true {
              return
            }
          }
          // The lone empty group is itself unreachable when a limit drops the
          // one row it would emit — a zero `FETCH` or any positive `OFFSET`. A
          // DISTINCT select is the exception: its plan is
          // `Limit(Distinct(Project(…)))`, so the projection evaluates over the
          // empty group's row (dedup needs it) BEFORE the cap pages the
          // deduplicated result — a zero FETCH or skipping OFFSET does not
          // spare it, mirroring the main projection path below. (`||` with a
          // `borrowing self` autoclosure needs the two-statement form.)
          var reachable = select.distinct
          if !reachable { reachable = !drops(select.limit, single: true) }
          if reachable, case let .expressions(items) = select.projection {
            for item in items {
              try scope.fold(item.expression, routines, subquery: subquery)
            }
          }
          // The lone empty group is sorted BELOW the limit — the shape is
          // `Project(Limit(Sort(…)))` — so its ORDER BY keys evaluate over
          // that group's row UNCONDITIONALLY, ahead of a limit that would drop
          // the projection: an unknown routine or a divide faults here as a run
          // would. `orderKeys` resolves an ordinal or an output-name key to the
          // projection expression the sort recomputes below the limit, so a
          // projection term reached only via the sort is checked even where the
          // projection block above is skipped.
          for expression in select.orderKeys {
            try scope.fold(expression, routines, subquery: subquery)
          }
        }
        return
      }
    }
    // Aggregate folds run before HAVING and any limit, so validate every
    // aggregate operand in the projection, HAVING, and ORDER BY
    // unconditionally. A grouped `ORDER BY` may sort on an aggregate that is
    // neither projected nor in the `HAVING` (`GROUP BY Dept ORDER BY
    // COUNT(*)`), which `group` collects into the group plan and folds before
    // `HAVING` — so its operand and arity are checked here, the same as a
    // projection or `HAVING` aggregate's.
    if case let .expressions(items) = select.projection {
      for item in items {
        try scope.aggregates(in: item.expression, routines, subquery: subquery)
      }
    }
    for expression in select.orderKeys {
      try scope.aggregates(in: expression, routines, subquery: subquery)
    }
    if let having = select.having {
      try scope.aggregates(in: having, routines, subquery: subquery)
      try scope.check(having, routines, subquery: subquery)
      // A false HAVING filters every group before the projection, so the
      // projection's non-aggregate work is unreachable.
      if scope.constant(having, routines) == false { return }
    }
    // The projection runs after any limit: a limit that drops every row it
    // would yield leaves only its aggregate folds (validated above) reachable.
    // A whole-result aggregate emits exactly ONE row, so a positive OFFSET
    // drops it too — not just a zero FETCH. A DISTINCT select is the exception:
    // its plan is `Limit(Distinct(Project(…)))`, so the projection evaluates
    // over EVERY candidate row (dedup needs them) BEFORE the cap pages the
    // deduplicated result — a zero FETCH or skipping OFFSET does not spare it.
    // A false WHERE still yields no rows to dedup (handled above), so only the
    // limit-based elision is bypassed for DISTINCT.
    let sole = select.aggregates && select.grouping.isEmpty
    var reachable = select.distinct
    if !reachable { reachable = !drops(select.limit, single: sole) }
    if reachable, case let .expressions(items) = select.projection {
      for item in items {
        _ = try scope.validate(item.expression, routines, subquery: subquery)
      }
    }
    // The sort sits BELOW the limit — the shape is `Project(Limit(Sort(…)))`
    // — so it evaluates every ORDER BY key over the input rows BEFORE the cap
    // pages them, INDEPENDENT of whether the projection is reachable: a limit
    // that drops every output row still runs the sort. So validate each key
    // UNCONDITIONALLY — its calls, arithmetic, and column references exactly
    // as a projected expression's. `orderKeys` resolves an `ordinal(n)` or an
    // output-name key to the projection expression the sort recomputes below
    // the limit, so a projection term reached only through the sort is checked
    // even where the projection block above is skipped under the limit; a
    // projection term NO sort key reaches stays correctly unchecked (the
    // projection never runs under a row-dropping limit).
    for expression in select.orderKeys {
      _ = try scope.validate(expression, routines, subquery: subquery)
    }
  }

  /// Resolves a GROUPED `select`'s `ORDER BY` through the SAME grouped lowering
  /// the compile path applies, so the type-check enforces the GROUP BY rules on
  /// each sort key exactly as a run does — a bare column must be a `GROUP BY`
  /// key or occur inside an aggregate, else `SQLError.grouping`; an out-of-range
  /// ordinal `SQLError.column`; a duplicated output name `SQLError.ambiguous`.
  ///
  /// It rebuilds the `Grouping` `group` builds — the `GROUP BY` keys and the
  /// aggregations collected from the projection, `HAVING`, and the `ORDER BY`
  /// sort keys, deduped by resolved `Aggregation` — then lowers the projection
  /// and the `ORDER BY` through it, reusing `Grouping.terms`/`Grouping.order` so
  /// the two paths cannot drift. It resolves only, reading no cursor; a run's
  /// operand type-check over the (structurally valid) keys stays the caller's.
  private borrowing func order(grouped select: Select, _ scope: Scope,
                               _ context: Context, _ visited: Set<String>)
      throws(SQLError) {
    guard let clause = select.order else { return }
    let routines = context.routines
    // A grouped aggregate's argument or FILTER may nest an UNCORRELATED
    // subquery (`ORDER BY SUM(CASE WHEN EXISTS (Q) …)`), which lowering
    // resolves against the materialised map, so materialise the select's
    // subqueries ONCE here — the same map the run's `group` builds — for this
    // structural resolve to lower those aggregates exactly as the run does.
    let subquery = try subquery(of: select, context, visited)
    // Collect the distinct aggregates the grouped plan folds — the projection,
    // the `HAVING`, and the `ORDER BY` sort-key expressions — then dedup by the
    // RESOLVED `Aggregation`, exactly as `group` does, so a grouped `ORDER BY`
    // over an aggregate resolves against the same slot the run folds it into.
    var expressions = Array<Expression>()
    for expression in select.projection.projected {
      expression.collect(into: &expressions)
    }
    if let having = select.having { having.collect(into: &expressions) }
    for key in clause.keys {
      if case let .expression(expression) = key.sort {
        expression.collect(into: &expressions)
      }
    }
    var aggregations = Array<Aggregation>()
    for expression in expressions {
      let aggregation = try expression.aggregation(scope, routines,
                                                   subquery: subquery)
      if !aggregations.contains(aggregation) {
        aggregations.append(aggregation)
      }
    }
    // Build the grouping and lower the projection through it to record each
    // output name (an alias, else a group column's own name) — the surface an
    // `ORDER BY` output name resolves against — then lower the `ORDER BY`, which
    // faults a non-group column, an out-of-range ordinal, or an ambiguous name.
    var grouping = try Grouping(scope, select.grouping, aggregations)
    let projection = try grouping.terms(select.projection, routines,
                                        subquery: subquery)
    _ = try grouping.order(clause, projection, routines, subquery: subquery)
  }

  /// Whether `limit` drops the one row a `single`-row result would yield,
  /// making a projection over that row unreachable. A zero `FETCH`
  /// (`count == 0`) drops every row; a positive `OFFSET` skips the sole row of
  /// a single-row result (a whole-result aggregate). A `nil` `count` caps
  /// nothing, and an `offset` of `0` skips nothing.
  private func drops(_ limit: Limit?, single: Bool) -> Bool {
    guard let limit else { return false }
    return limit.count == 0 || (single && limit.offset >= 1)
  }

  /// The name-resolution schema of `relation`, resolved against this catalog
  /// and the in-scope `ctes` — a CTE first, then a reserved
  /// `definition_schema.` store relation, then a view, then a base table, the
  /// same precedence `compile` resolves a relation by. It reads only schemas,
  /// never a cursor, so it never executes. `visited` names the views already
  /// being resolved down this chain, breaking a cyclic view (`A` over `B` over
  /// `A`) that would otherwise re-enter here. `routines` ride through so a view
  /// body projecting a scalar call types it from the routine's declared return
  /// type, not the `.integer` default. `validate` (default `true`) gates the
  /// view body's reachable-operand type-check: a `validate: false` derive (an
  /// empty result whose headers this fills) resolves the body's relations and
  /// types WITHOUT re-checking its reachable operands, so a view whose body is
  /// data-dependent-empty — a text-arithmetic projection under a filter that
  /// matched no row — does not fault a `SELECT *` over it that already ran.
  borrowing func schema(of relation: Relation, _ context: Context,
                        visited: Set<String> = [],
                        validate: Bool = true)
      throws(SQLError) -> Schema {
    let name = relation.name
    if let cte = context.relations[name.lowercased()] {
      return cte.schema()
    }
    // A reserved store relation types through its SCHEMA-ONLY build (header +
    // types, no rows), so resolving a view over `definition_schema.tables`/
    // `.columns` reads only the schema and never triggers the row builder.
    if let relation = Definition(name) {
      return store(relation, rows: false).schema()
    }
    if let view = resolve(view: name) {
      // A view's declared schema types every column `.integer`, since a view
      // stores no types; resolve the view body's own types so a `SELECT *` over
      // the view reports each column's true type. Resolving runs the
      // RESOLVE-only worker over the view's OWN `definition_schema.` overlay,
      // built SCHEMA-ONLY so a view over a reserved relation resolves its types
      // without a row build. The names stay the view's DECLARED ones; only the
      // types come from the resolved body.
      let base = view.schema()
      // A cyclic view cannot resolve its body's types: resolving it would
      // re-enter this view forever, so break the cycle and fall back to the
      // declared schema (every type the `.integer` default). `try?` cannot
      // catch this — the recursion overflows the stack rather than throwing.
      guard !visited.contains(name.lowercased()) else { return base }
      // Type-check the body's REACHABLE operands and calls across every arm and
      // clause — `compile` cannot check a routine EXISTS, the first-arm resolve
      // below sees only the first projection, and the outer query's walk does
      // not reach into a body. `typecheck` faults an unknown call or a bad
      // operand a `SELECT * FROM v` run would evaluate — a `WHERE`/`HAVING`, a
      // later `UNION` arm — while skipping an arm a short-circuit proves
      // unreachable.
      let overlay = augment(context.scoping([:]), for: view.query, rows: false)
      let inner = visited.union([name.lowercased()])
      // Gate the body's reachable-operand check on `validate`: a `validate:
      // false` derive skips it, so a data-dependent-empty body (a text
      // arithmetic under an unmatched filter) does not fault a `SELECT *` over
      // the view that already ran to its (empty) result. `validate` also rides
      // into the recursive derive so a view over a view stays derive-only.
      if validate {
        try typecheck(view.query, overlay, visited: inner)
      }
      // Type off the body's first arm (the ISO rule for a UNION). Arity — the
      // body's width against the declared columns — is `compile`'s job (the
      // public entry runs it), so on a shortfall fall back to the declared
      // schema rather than re-checking it here.
      let resolved =
          try columns(of: view.query.first, overlay, visited: inner,
                      validate: validate)
      guard resolved.count == base.width else { return base }
      return Schema(width: base.width, extent: base.extent, names: base.names,
                    types: resolved.map(\.type), virtuals: base.virtuals)
    }
    guard let table = table(named: name) else {
      throw .relation(name)
    }
    return table.schema()
  }
}

extension Scope {
  /// The output columns a `projection` yields over this scope, named and typed
  /// — `routines` type a scalar call from its declared return type.
  internal func columns(of projection: Projection,
                        _ routines: Routines = [:])
      throws(SQLError) -> Array<OutputColumn> {
    return switch projection {
    case .all:
      outputs()
    case let .columns(references):
      try references.map { column throws(SQLError) in try output(of: column) }
    case let .expressions(items):
      try items.indices.map { index throws(SQLError) in
        try output(items[index], at: index, routines)
      }
    }
  }

  /// The output columns of a `SELECT *` over this scope — every real column of
  /// every relation, in chain order, named and typed from each relation's
  /// schema (never a virtual column) — the terms `terms(.all)` projects.
  internal func outputs() -> Array<OutputColumn> {
    schemas.flatMap { schema in
      (0 ..< schema.width).map {
        OutputColumn(name: schema.names[$0], type: schema.types[$0])
      }
    }
  }

  /// The output column a bare `column` reference yields: its own name (its
  /// spelling as written), typed from the relation that resolves it.
  internal func output(of column: Column) throws(SQLError) -> OutputColumn {
    let type = try type(at: ordinal(of: column))
    return OutputColumn(name: column.name, type: type)
  }

  /// The output column a projected `item` at 0-based `index` yields: its
  /// inferable output name (`Projected.name` — an alias, else a bare column's
  /// name), else a positional `column N` (1-based). A bare column carries its
  /// source type and a literal its own; a scalar call its routine's declared
  /// return type; every other expression `.integer`.
  internal func output(_ item: Projected, at index: Int,
                       _ routines: Routines = [:])
      throws(SQLError) -> OutputColumn {
    let name = item.name ?? "column \(index + 1)"
    // DERIVE the nominal output type: the schema reports the type a run would
    // produce and never faults on an operand. Run-time operand and call
    // validation is `typecheck`'s job, reachability-aware, so a schema resolves
    // even for an expression a zero-row limit makes unreachable.
    return try OutputColumn(name: name,
                            type: derive(item.expression, routines))
  }
}
