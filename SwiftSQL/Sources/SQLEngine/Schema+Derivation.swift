// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Catalog where Self: ~Escapable {
  /// The result columns `query` would yield, named and typed, resolved without
  /// executing it.
  ///
  /// A union's result columns take their names from the FIRST arm's projection
  /// (the ISO rule a `UNION` follows), so a union names its result off its
  /// leading `SELECT`, while their types are unified across ALL arms (a mixed
  /// integer/double column widening to `double`, an irreconcilable pair
  /// faulting). The column count matches the compiled plan's `width`; the names
  /// and types come from re-walking the projection exactly as compilation
  /// resolves it:
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
  /// The result columns' names come from the first arm and their types unify
  /// across arms, but ONLY after the whole query validates: `compile` resolves
  /// every arm (each `WHERE`,
  /// join, and projection) and cross-checks a `UNION`'s arm arity, without
  /// opening a cursor. So a query whose first arm names its columns cleanly but
  /// whose `WHERE` references a missing column, or whose second `UNION` arm
  /// mismatches the arity, faults here exactly as a run would rather than
  /// returning headers for a query that cannot run.
  ///
  /// `routines` are the scalar functions a run would resolve against — pass the
  /// same set here so a projected call `TAG(Name)` reports its declared return
  /// type rather than the `.integer` default. It defaults to none, matching a
  /// run with no custom routines.
  ///
  /// `validate` (default `true`) whole-query type-checks before deriving, so a
  /// static shape check faults an ill-typed query a run would only reach with
  /// rows — `SELECT Name + 1 …` reports `SQLError.operand`. Pass `false` when a
  /// run has already proved the query runnable (an empty result whose headers
  /// this fills in): the data-dependent filter never reached the projection, so
  /// re-validating the reachable `Name + 1` would fault a query that succeeded.
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
    // Expand any `GROUP BY GROUPING SETS` select to its `UNION ALL` FIRST, so
    // the compile validation and the `columns(unifying:)` derive below see the
    // same expanded AST a run does (`run ≡ columns(of:)`).
    let query = try query.expanded
    // Pure engine: it types calls against exactly the `routines` given, seeding
    // no prelude. `import SQLStandard` adds a prelude-defaulting overload
    // (`columns(of:validate:)`). A typing path has no bindings.
    let context = Context(routines: routines).validating(validate)
    // Extend the scope with any `definition_schema.` store relation the query
    // names, so its result schema resolves the reserved relation the same as a
    // run would — schema-ONLY, so typing never triggers the row build. A
    // derived body is validated only when `validate`: a `validate: false`
    // derive after a run trusts the body rather than re-checking a reachable
    // operand a data-dependent filter never reached (matching the non-derived
    // path, whose empty run never evaluates it).
    let scope = try augment(context, for: query, rows: false)
    // Validate the whole query without executing — the same compile the run
    // path drives, resolving every arm and cross-checking a UNION's arity — so
    // a schema is returned only for a query that could actually run. `validate`
    // threads through: a `validate: false` derive after a run must NOT eager-
    // type-check a derived body in a subquery a data-dependent filter dropped,
    // matching the run's lenient compile.
    _ = try compile(query, scope)
    // Type-check every reachable operand and call across all arms — the
    // projection, `WHERE`, and `HAVING` of each. `compile` resolves a call's
    // arguments but cannot check the routine EXISTS or that it is called with
    // its declared arity and argument kinds, and the first-arm walk below
    // sees only the first projection; `typecheck` faults an unknown or
    // ill-typed call or a bad operand anywhere a run would evaluate it, and —
    // like the executor — skips an arm a `false AND`/`true OR` short-circuits,
    // so a query that runs is not rejected for an unreachable call. A caller
    // that already ran the query (`validate: false`) skips it: a reachable
    // operand a data-dependent filter never reached would otherwise fault a
    // query that produced its (empty) result.
    if validate { try typecheck(query, scope) }
    // The result columns' names come from the first arm's projection (the ISO
    // rule a UNION follows), but their types are unified across ALL arms — a
    // column mixing `integer` and `double` arms widens to `double`, an
    // irreconcilable pair (text beside a number) faults `SQLError.operand` —
    // resolved against the validated scope; a scalar call types from its
    // routine's declared return type. `validate` rides through so a `SELECT *`
    // over a view derives the body's types without re-type-checking it — the
    // view body's own reachable-operand check is gated the same as the outer
    // query's, so a `validate: false` derive faults nowhere.
    return try columns(unifying: query, scope).map(\.column)
  }

  /// The result columns `statement` would yield, named and typed, resolved
  /// without executing it — the statement-level entry that keeps a `WITH`'s CTE
  /// scope in place.
  ///
  /// A `select` derives exactly as `columns(of query:)` does. A `with` derives
  /// its trailing query against the statement's common table expressions, so a
  /// reference the CTEs bind — a `SELECT *` over a CTE, or a name a CTE shadows
  /// off a same-named base relation — resolves against the CTE the run did, not
  /// the base catalog: `WITH t(x) AS (SELECT 1) SELECT * FROM t` reports one
  /// column `x`, even where a base `t` of a different width exists. The scope
  /// is schema-ONLY — each CTE contributes its declared column list (typed
  /// `.integer`, the default a materialised relation reports) without running
  /// its body — so the derive never opens a cursor, exactly as `columns(of
  /// query:)` never does. A `create` and a `function` name no result, so each
  /// faults `SQLError.statement` the way running one does.
  ///
  /// `routines` and `validate` carry the meaning `columns(of query:)` gives
  /// them; pass `validate: false` after a run has proved the statement
  /// runnable.
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
    case let .explain(query):
      // `EXPLAIN` yields the plan tree as one text column per line — a fixed
      // single-column shape, whatever the inspected query projects. Under
      // `validate`, prove it plannable by building its plan — exactly what
      // running the EXPLAIN does (`plan(of:)`) — rather than deriving the
      // inspected query's schema. Planning faults on a query that cannot be
      // planned (an unknown column, a statically incomparable comparison), so a
      // client cannot describe an unplannable EXPLAIN; but it does not eager
      // type-check a projected row operand the way the schema derive would, so
      // `EXPLAIN SELECT Name + 1 FROM People` — which runs fine, no row
      // expression evaluated — is not wrongly rejected. The plan is discarded,
      // only its faults matter. Then name the fixed diagnostic column.
      if validate { _ = try plan(of: query, Context(routines: routines)) }
      return [OutputColumn(name: "plan", type: .text)]
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
  /// against a schema-ONLY overlay of the `ctes` in scope.
  ///
  /// Each CTE binds a `RelationInstance` of its declared columns with no rows —
  /// the schema the run's materialised CTE resolves to (columns from the
  /// declared list, each typed from its body fold and carrying its
  /// `unconstrained` mask, `kinds(of:)`) — laid into the overlay in source
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
  /// When `validate`, each CTE body is validated before its schema is trusted
  /// by the same code a run drives — `Engine.validate`, the compile-time
  /// structural check `Engine.with` runs before materialising: the recursive
  /// shape (a recursive reference must be the final `UNION` arm; a
  /// self-reference in the anchor with no same-named base faults
  /// `SQLError.unsupported`, the recursive shape a run rejects before
  /// materialising) and the declared arity (the compiled body width against the
  /// column list, `SQLError.columns` on a mismatch — the anchor and recursive
  /// arm checked separately, self bound only in the recursive arm). The schema
  /// path also asks that helper to run its reachable-operand type-check
  /// (`typecheck: true` — the run defers this to execution, so it stays off the
  /// run path): folding it in rather than layering it here keeps one per-arm
  /// scoping for both, so a recursive CTE's anchor is operand-checked against
  /// the base scope the run evaluates it in, NOT the CTE-self overlay. So a
  /// dry-run schema is advertised only for a `WITH` that could actually run,
  /// never for one whose body's shape or width contradicts its declared list —
  /// nor for one whose reachable operand a run would fault. When `validate` is
  /// `false` — a derive after a successful run — the bodies are trusted, not
  /// compiled: the run already proved them consistent, and re-checking a
  /// data-dependent-empty body would fault a statement that succeeded.
  private borrowing func columns(of query: Query, with ctes: Array<CTE>,
                                 routines: Routines,
                                 validate: Bool)
      throws(SQLError) -> Array<OutputColumn> {
    // Expand any `GROUP BY GROUPING SETS` in the trailing query to its `UNION
    // ALL` FIRST, so this schema derive sees the same AST the run does: the run
    // WITH path (`with` then `run(query:)`) normalizes there. The CTE bodies
    // expand within `typed`/`validate`/`contributions`.
    let query = try query.expanded
    let context = Context(routines: routines).validating(validate)
    // Type the CTEs into a schema-ONLY overlay (`rows: false`) through the one
    // producer the run path also drives — `Engine.typed(ctes:in:rows:)` — so
    // the redefinition guard, the shared `validate` (its `typecheck: true`
    // riding this context's `validate` gate — a `validate: false` post-run
    // derive trusts the bodies and skips it), and the per-CTE `kinds` carrier
    // derivation all run through the same walk a run does. Each CTE binds its
    // declared columns with no rows, laid in source order, so a later CTE and
    // the trailing query resolve a name the precedence a run applies.
    let overlay = try typed(ctes: ctes, in: context, rows: false)
    // Compile/type-check/derive from the base `context.scoping(overlay)`
    // (idempotently augmented within each, which pushes the trailing query's
    // derived layer and reveals the base for a nested subquery), so a nested
    // subquery's FROM sees the CTE overlay and base tables but NOT this query's
    // derived aliases, and a CTE a same-named derived alias shadows stays
    // visible beneath the revealed base. Thread `validate` into `compile` as
    // the non-`WITH` path does: a `validate: false` derive after a successful
    // run must NOT eager-type-check a derived body in the trailing query — a
    // data-dependent body expression a filter drops (`FROM (SELECT Label + 1 AS
    // x FROM K WHERE k = 0) AS d`) is trusted, not rejected, matching the run.
    // `validate: true` keeps the strict schema check.
    let base = context.body(overlay)
    _ = try compile(query, base)
    if validate { try typecheck(query, base) }
    return try columns(unifying: query, base).map(\.column)
  }

  /// The result columns of a single `select`, resolved against this catalog
  /// with the in-scope `ctes` — the per-arm worker `columns(of:)` drives.
  ///
  /// This names AND types the projection; it does not re-validate the WHERE,
  /// joins, GROUP BY, HAVING, or ORDER BY. Whole-query validation belongs to
  /// `compile` — the public `columns(of query:)` runs it — so this worker never
  /// duplicates (and never drifts from) that resolution. It runs only after
  /// compilation has proved the arm resolves. `routines` are the scalar
  /// routines a call types from — its declared return type — rather than the
  /// `.integer` default. The context's `validate` rides through to any view
  /// this arm's relations resolve, gating the view body's reachable-operand
  /// check the same as the outer query's — a `validate: false` context never
  /// re-type-checks a view body a run already proved runnable.
  borrowing func columns(of select: Select, _ context: Context)
      throws(SQLError) -> Array<OutputColumn> {
    try arms(of: select, context).map(\.column)
  }

  /// The output columns of a single set-operation `select` arm — each carried
  /// as a `ResolvedColumn` recording whether its projected expression is a
  /// constant NULL — the per-arm worker the set-operation fold
  /// (`columns(unifying:_:)`) drives.
  ///
  /// This names AND types the projection and marks its constant-NULL columns;
  /// it does not re-validate the WHERE, joins, GROUP BY, HAVING, or ORDER BY.
  /// Whole-query validation belongs to `compile` — the public `columns(of
  /// query:)` runs it — so this worker never duplicates (and never drifts from)
  /// that resolution. It runs only after compilation has proved the arm
  /// resolves. `routines` are the scalar routines a call types from — its
  /// declared return type — rather than the `.integer` default. The context's
  /// `validate` rides through to any view this arm's relations resolve, gating
  /// the view body's reachable-operand check the same as the outer query's — a
  /// `validate: false` context never re-type-checks a view body a run already
  /// proved runnable.
  private borrowing func arms(of select: Select, _ context: Context)
      throws(SQLError) -> Array<ResolvedColumn> {
    // Bind this select's own FROM/JOIN derived tables (and store relations)
    // before deriving either the subquery map or the scope — a set-op ARM
    // reaches here directly (`columns(unifying: query, …)`), and the top-level
    // augment collected no arm-local aliases (arms are SELECT-scoped), so a
    // subquery naming the arm's own derived alias (`WHERE Id IN (SELECT Id FROM
    // d)`) would else compile against a scope missing `d`. Schema-only, no
    // cursor; `validate` gates a derived body's own operand check.
    let augmented = try augment(context, for: .select(select), rows: false)
    // A scalar subquery in the projection derives its type from its inner
    // query's single column, so build the same cursor-free `Resolution` map the
    // compile path's lowering reads — every nested subquery compiled once for
    // its width and single-column type, each discovering its correlation
    // against this select's own scope (`enclosing`) — and pass it to the
    // projection walk so an output type for a `(SELECT …)` matches the type the
    // run advertises. The projection walk admits a correlated column of this
    // query, resolving it against the enclosing scope as the run's projection
    // lowering does. Resolve over the augmented context so a subquery
    // naming this select's own arm-local derived alias binds it, while
    // `subquery(of:)` reveals the base so the subquery's own FROM sees no
    // derived alias (a CTE a same-named derived alias shadows resolved beneath
    // the dropped layer).
    let scope = try scope(of: select, augmented)
    // Pass each join's prefix scope so an `ON`'s subquery correlates against
    // its prefix and the WHERE's against the full scope — the same
    // per-occurrence resolution the run path uses, so a name a WHERE subquery
    // finds ambiguous in the full scope faults here too (typecheck↔run parity),
    // not silently reusing an `ON` occurrence's narrower prefix.
    let prefixes = try prefixes(of: select, augmented)
    // These derivations lower under `.caller` — a schema-only type derive keys
    // its subqueries in the caller id space regardless of an enclosing view
    // scope the incoming context may carry.
    let plans = try subquery(of: select, augmented.scoped(as: .caller),
                             enclosing: scope, prefixes: prefixes)
    // one walk yields each column's name, type, AND `unconstrained` mask
    // together — a constant-NULL projection or a reference to an unconstrained
    // (local or correlated) source column carries the mask through the same
    // resolution as the type, so the two cannot diverge. The projection walk
    // admits a correlated column of this query, resolving it against the
    // enclosing scope as the run's projection lowering does.
    return try scope.columns(of: select.projection, augmented.routines,
                             subquery: plans.rest)
  }

  /// The output columns of `query`, type-unified across every set-operation arm
  /// — the ISO rule a `UNION`/`INTERSECT`/`EXCEPT` result columns follow.
  ///
  /// A bare `SELECT` types off its own projection. A `setop` node folds its two
  /// arms column-wise: each result column takes the LEFT (first) arm's name
  /// (the ISO rule — a union names its columns off its leading `SELECT`) and
  /// the merge of the two arms' types (`merge` — like types pass through, a
  /// mixed integer/double pair widens to `double`, an irreconcilable pair
  /// faults `SQLError.operand`). A left-associative chain composes
  /// automatically. A column an arm projects as a constant NULL places no type
  /// constraint (a NULL unifies with any typed arm), so the fold carries the
  /// other arm's type and unconstrained-ness up unchanged, mirroring
  /// `COALESCE`'s constant-NULL skip. The arm arity is proved equal by
  /// `compile` before this runs, so the column-wise zip is safe.
  ///
  /// Each returned `ResolvedColumn` carries the unified column AND whether it
  /// is constant NULL in every arm folded so far — the value coercion paths
  /// read the `type`, and a further enclosing fold reads `unconstrained`.
  borrowing func columns(unifying query: Query, _ context: Context)
      throws(SQLError) -> Array<ResolvedColumn> {
    // The body's carrier-free result columns.
    var cols: Array<ResolvedColumn>
    switch query.body {
    case let .select(select):
      // A `GROUP BY GROUPING SETS (…)` derives its schema through the same
      // lowering the compile path uses, so the run and the derived columns
      // cannot diverge (`run ≡ columns(of:)`). A windowed one derives the outer
      // window layer over the arm union's schema — the schema twin of the
      // direct compile lowering (`compile(windowed sets:)`) — while a
      // non-windowed one derives its `UNION ALL` expansion, whose arms'
      // NULL-padded columns type through the set-operation `merge` as the run's
      // do.
      if case let .sets(sets) = select.grouping {
        cols = select.windows
            ? try columns(windowed: select, sets: sets, context)
            : try columns(unifying: expand(select, sets: sets), context)
      } else {
        cols = try arms(of: select, context)
      }
    case let .setop(_, left, right, _):
      let l = try columns(unifying: left, context)
      let r = try columns(unifying: right, context)
      // A nested set operation's arm mismatch is faulted here, before the
      // column-wise merge indexes both arms — `compile` cross-checks the
      // outer widths but the fold descends into child nodes it has not yet
      // validated, so an unguarded `r[index]` would trap rather than fault.
      guard l.count == r.count else { throw .arity(l.count, r.count) }
      // The operand-compatibility fold defers under the shape pre-pass
      // (`context.shape`): a nested subquery's set-operation type is recorded
      // ahead of the reachability walk, so an unreached incompatible pair
      // yields a discardable placeholder rather than faulting; a reached
      // scalar/`IN` occurrence is re-folded strictly on the reached path.
      cols = try l.indices.map { index throws(SQLError) in
        try merge(l[index], r[index], shape: context.shape)
      }
    case let .values(rows):
      // The ISO table value constructor's result columns: each row's
      // expressions typed against the empty FROM-less scope (a subquery a row
      // nests reads its single-column type from the same cursor-free
      // `Resolution` the compile path builds), then folded column-wise across
      // the rows through the SAME set-operation `merge` a `UNION ALL` uses — so
      // a mixed integer/double column widens to `double` and an irreconcilable
      // pair (`VALUES ('a'), (1)`) faults `SQLError.operand` exactly as the
      // former `UNION ALL` desugar did. Each row has equal arity (the ISO
      // degree rule) — a mismatch is `SQLError.arity(first, offending)` — and
      // the result columns are named the ISO default `column1, column2, …` off
      // the first row's aliases (the ISO first-arm rule the `merge` carries).
      //
      // The parser enforces the ISO `≥ 1 row, each ≥ 1 element` shape
      // syntactically, but `Query`/`Query.Body` are public: a caller can hand-
      // build `.values([])` (no rows) or `.values([[]])` (a zero-column row),
      // which the type fold below would otherwise treat as a valid empty
      // relation. Reject them here — the single deriver both the run
      // (`compile(values:)`) and `columns(of: validate:)` reach — before the
      // fold, so a malformed AST faults cleanly rather than producing a zero-
      // column relation. A later empty row is caught by the equal-arity check.
      guard let first = rows.first else {
        throw .state("42601", "VALUES requires at least one row")
      }
      guard !first.isEmpty else {
        throw .state("42601", "VALUES requires at least one column per row")
      }
      let arity = first.count
      for row in rows.dropFirst() where row.count != arity {
        throw .arity(arity, row.count)
      }
      var subqueries = Array<Query>()
      for row in rows {
        for expression in row { expression.collect(subqueries: &subqueries) }
      }
      let resolution =
          try subquery(subqueries, roles: { query.roles(of: $0, order: nil) },
                       context, within: nil)
      var folded: Array<ResolvedColumn>? = nil
      for row in rows {
        let items = row.enumerated().map {
          Projected(expression: $0.element, alias: "column\($0.offset + 1)")
        }
        let typed = try Scope([]).columns(of: .expressions(items),
                                          context.routines,
                                          subquery: resolution)
        if let current = folded {
          folded = try current.indices.map { index throws(SQLError) in
            try merge(current[index], typed[index], shape: context.shape)
          }
        } else {
          folded = typed
        }
      }
      cols = folded ?? []
    }
    // A carrier is transparent to the result schema: `ORDER BY`, `DISTINCT`,
    // and `OFFSET`/`FETCH` are row operators — they do NOT project — so the
    // result columns are the body's arm-0-named, unified ones whether reached
    // via `run`/`compile` or `columns(of:)` (`run ≡ columns`). The one
    // exception is a hidden materialised sort column (`expand` appends
    // `generated` of them to every arm so an unprojected `ORDER BY MAX(x)`
    // survives the union at equal arity): the carrier's compile trims them
    // through the identity projection, so drop the matching trailing columns
    // here too so the schema matches the run. The count is the structural
    // `generated` each carrier carries, never a scan of the arm-0 names for a
    // synthetic prefix — a user's delimited `AS "*gs0"` is a real output, not a
    // generated column. Range-check `generated` against the width through the
    // shared guard the compile carrier uses (`real(trimming:of:)` on Engine)
    // before trimming: a public-AST count past the width makes `cols.count −
    // generated` negative and `Array.prefix` precondition-traps the process,
    // while a negative count returns ALL columns untrimmed — silently wrong and
    // diverging from `run`, which faults the same XX000. One guard, one message
    // ⇒ `columns(of:) ≡ run` on a malformed carrier.
    for carrier in query.carriers {
      let real = try real(trimming: carrier.generated, of: cols.count)
      cols = Array(cols.prefix(real))
    }
    return cols
  }

  /// The unified column types of `query`, folded across every set-operation arm
  /// — the types each producer path coerces its arms' values to so a set
  /// operation's result carries the common column type (`SELECT 1 UNION SELECT
  /// 2.5` a `double` column). It is the type projection of
  /// `columns(unifying:_:)`, resolved against `context`.
  borrowing func types(unifying query: Query, _ context: Context)
      throws(SQLError) -> Array<ValueType> {
    try columns(unifying: query, context).map(\.type)
  }

  /// The single deriver of a relation body's resolved output columns: the
  /// columns unified across every set-operation arm (the ISO rule a
  /// `UNION`/`INTERSECT`/`EXCEPT` follows), named off the first arm and typed
  /// across all of them, each carrying its `unconstrained` mask — the
  /// `ResolvedColumn` carrier every body-derived binding is constructed from.
  ///
  /// Every binding site that folds a body into a `RelationInstance`/`Schema` —
  /// a derived table's `materialise`, a view's schema resolution — obtains its
  /// columns here, never by re-deriving the projection inline, so the
  /// per-column `unconstrained` mask threads through all of them from one place
  /// via the single `init(from:)` constructor and no site can drop it.
  borrowing func resolved(query body: Query, in context: Context)
      throws(SQLError) -> Array<ResolvedColumn> {
    try columns(unifying: body, context)
  }

  /// The column carrier a CTE binds under — its declared column names (a CTE is
  /// addressed by its declared list, `WITH t(x) AS …` exposes `x`, never the
  /// body's own projected name) carrying each column's body-folded type (never
  /// the `.integer` placeholder) and whether every arm feeding it projects a
  /// constant NULL, so it places no type constraint. A recursive `UNION` CTE
  /// unifies the anchor's columns (self not in scope) with the recursive arm's
  /// (self bound to the anchor's types), mirroring `fixpoint`; any other body
  /// folds its own. A trusted derive (a `validate: false` body a filter drops)
  /// that faults falls back to the placeholder.
  ///
  /// The result is always the CTE's declared width (`cte.columns.count`): a
  /// body whose fold yields a different count is reconciled to it (padding a
  /// short fold with the `.integer` default, truncating a long one), so a
  /// caller building the CTE binding from it indexes a same-length carrier
  /// whatever the (possibly malformed) body derives.
  borrowing func kinds(of cte: CTE, _ scope: Context)
      throws(SQLError) -> Array<ResolvedColumn> {
    let derived = try contributions(of: cte, scope)
    let sized = reconcile(derived, to: cte.columns.count, named: cte.columns)
    // Bind under the CTE's declared names, keeping each column's body-folded
    // type and `unconstrained` mask, so `WITH t(x) AS (SELECT 1 AS n)` is
    // addressed as `x` while `x` carries the body's derived type.
    return sized.indices.map {
      ResolvedColumn(name: cte.columns[$0], type: sized[$0].type,
                     unconstrained: sized[$0].unconstrained)
    }
  }

  /// The raw column carrier a CTE's body folds to, before reconciling to the
  /// declared width — the recursive-aware merge `kinds` wraps.
  private borrowing func contributions(of cte: CTE, _ scope: Context)
      throws(SQLError) -> Array<ResolvedColumn> {
    // Recognise the recursive `UNION` shape through the canonical peel
    // (`recursiveArms` — unwound), the same recogniser the run/validate/
    // fixpoint recursive-CTE seams take (`CTE.recurses`, `fixpoint`'s
    // `canonical`), so the schema derive inspects the identical AST the run
    // does — a trailing `ORDER BY`/`OFFSET`·`FETCH`/`DISTINCT` carrier peeled
    // off. Otherwise a carried recursive union would fall through to the non-
    // recursive fold with the self unbound and fault `.relation`, diverging
    // from the run that iterates the fixpoint. The carrier is transparent to
    // the derived schema (its row operators do not project), so peeling it
    // yields the same columns.
    guard let (anchor, recursive, _) = try cte.recursiveArms else {
      // A non-recursive body's carrier is its unified fold, propagating a
      // genuine incompatibility (`SELECT 'b' UNION SELECT 1`) as `.operand`
      // rather than swallowing it into the declared `.integer`: with every
      // placeholder now marked unconstrained, a trusted body that ran carries
      // no genuine incompat to fault, so no `try?` fallback is needed. Derive
      // types off the same expanded AST a run does: a `GROUP BY GROUPING SETS`
      // body expands to its `UNION ALL` arms FIRST, so the schema fold matches
      // `run`/`compile` (run and `columns(of:)` cannot diverge). The carrier is
      // transparent to a non-recursive body's fold too — the `.ordered` case of
      // `columns(unifying:)` peels it identically.
      return try columns(unifying: cte.query.expanded, scope)
    }
    let seeds = try columns(unifying: anchor, scope)
    // The recursive arm addresses the self by the CTE's declared names (`SELECT
    // n + 1 FROM t` reads `n`), so bind the schema-only self under those names
    // carrying the anchor's derived types/mask, not the anchor's own projected
    // names. The anchor's width is proved against the declared list before this
    // runs, so the index is in range.
    let named = seeds.indices.map { index -> ResolvedColumn in
      guard index < cte.columns.count else { return seeds[index] }
      return ResolvedColumn(name: cte.columns[index], type: seeds[index].type,
                            unconstrained: seeds[index].unconstrained)
    }
    let empty = RelationInstance(from: named, rows: [])
    let steps = try columns(unifying: recursive,
                            scope.binding(cte.name, to: empty))
    // A malformed recursive CTE whose anchor and recursive arms project
    // differing widths would trap indexing `steps[index]`; fault cleanly on the
    // mismatch instead, the same column-count fault a declared-arity mismatch
    // raises.
    guard seeds.count == steps.count else {
      throw .columns(expected: seeds.count, got: steps.count)
    }
    return try seeds.indices.map { index throws(SQLError) in
      try merge(seeds[index], steps[index])
    }
  }

  /// `contributions` reconciled to exactly `count` columns — the declared width
  /// a caller binds the CTE under. A fold that yields fewer columns is padded
  /// with a fabricated `.integer` placeholder (named from `names` where one
  /// exists) marked unconstrained, since it is not a genuine derivation, a
  /// longer one truncated, so the built binding's type and unconstrained arrays
  /// always match the declared column list's length whatever a malformed body
  /// derives.
  private borrowing func reconcile(_ carrier: Array<ResolvedColumn>,
                                   to count: Int, named names: Array<String>)
      -> Array<ResolvedColumn> {
    guard carrier.count != count else { return carrier }
    return (0 ..< count).map { index in
      if index < carrier.count { return carrier[index] }
      let name = index < names.count ? names[index] : "column \(index + 1)"
      return ResolvedColumn(name: name, type: .integer, unconstrained: true)
    }
  }

  /// The name-resolution scope of `select` — its FROM relation and each joined
  /// relation resolved to schema and laid end to end in one combined ordinal
  /// space, the same layout compilation resolves a projection against. A
  /// FROM-less `SELECT <expr-list>` projects over no relation, so its scope is
  /// empty. It reads only schemas, never a cursor. The context's `validate`
  /// rides through to each relation's `schema(of:)`, gating a view body's
  /// reachable-operand check the same as the outer query's.
  borrowing func scope(of select: Select, _ context: Context)
      throws(SQLError) -> Scope {
    // Bind this select's own FROM/JOIN derived tables (and store relations)
    // before resolving its relations — SELECT-scoped, so a subquery select
    // whose schema is derived directly here (a scalar subquery's output type)
    // resolves its own aliases. Schema-only: `scope` reads no cursor. `visited`
    // carries the cyclic-view guard into a derived body's materialise, and
    // `validate` gates that body's own reachable-operand check the same as the
    // outer query's — a `validate: false` derive trusts a run-proven body.
    let context = try augment(context, for: .select(select), rows: false)
    let relation = select.from
    // Build the running scope incrementally so a LATERAL join's schema derives
    // against the preceding FROM — per ISO its projection may name a preceding
    // column, so its output shape types from that scope. A non-lateral join's
    // schema is correlation-independent, so the preceding scope is harmless.
    var relations = [(relation, try schema(of: relation, context))]
    for index in select.joins.indices {
      // The preceding scope carries the merged columns the joins before this
      // one expose (`prefix(through:)`) — the same one-merge path the run's
      // resolve loop threads — so a LATERAL body's schema derives its bare
      // merged references against the one coalesced column rather than the two
      // physical join columns.
      let preceding =
          try prefix(through: index, over: relations, select.joins)
      let joined = try schema(of: select.joins[index].relation, context,
                              preceding: preceding)
      relations.append((select.joins[index].relation, joined))
    }
    // Model the `NATURAL`/`USING` merged columns (ISO 9075 7.10) in the scope
    // so the schema path names and types the same output columns the run's
    // `compile` projects — a bare merged column resolves to the coalesce type,
    // and a `SELECT *` exposes it once. Empty for a chain with no named-column
    // join, so an ordinary scope is unchanged.
    let merged = try merges(over: relations, select.joins).merged
    return Scope(relations, merged: merged)
  }

  /// The prefix scope of each join of `select` — join `index`'s prefix is the
  /// FROM relation and joins `0…index`, the relations available at that join
  /// point, never one joined later. A join `ON`'s subquery correlates against
  /// its prefix (so a reference to a later-joined relation faults), matching
  /// the compile path's `subquery(of:)`. Empty for a join-less select.
  private borrowing func prefixes(of select: Select, _ context: Context)
      throws(SQLError) -> Array<Scope> {
    guard !select.joins.isEmpty else { return [] }
    let relation = select.from
    // Build the running scope incrementally so a LATERAL join's schema derives
    // against the preceding FROM (the same reason `scope(of:)` does), the
    // preceding scope carrying the joins-before's merged columns through the
    // one merge path (`prefix(through:)`).
    var relations = [(relation, try schema(of: relation, context))]
    for index in select.joins.indices {
      let preceding =
          try prefix(through: index, over: relations, select.joins)
      let joined = try schema(of: select.joins[index].relation, context,
                              preceding: preceding)
      relations.append((select.joins[index].relation, joined))
    }
    // Each join's prefix carries the merged columns accumulated before it (the
    // same `merges` the run's `compile` threads), so an `ON` subquery's bare
    // merged outer operand resolves the same way the run does.
    let merges = try merges(over: relations, select.joins).prefixes
    return select.joins.indices.map { index in
      Scope(Array(relations[0 ... index + 1]), merged: merges[index])
    }
  }

  /// Type-checks every operand in `query` — the projection, `WHERE`, and
  /// `HAVING` of every arm — throwing the run-time fault a bad operand would.
  ///
  /// The result schema derives each arm's projection type (unifying them across
  /// arms), but that non-faulting derive does not exercise a later arm's or a
  /// `HAVING`'s reachable-operand check — `SELECT Age FROM t UNION SELECT Name
  /// + 1 FROM t` or `… HAVING SUM(Name) > 0` resolves its names but
  /// `Arithmetic.apply`/`Aggregate.fold` faults `SQLError.operand` at run.
  /// `compile` cannot catch this (no evaluating term is built), so a schema
  /// path type-checks each arm before returning metadata. It reads no cursor.
  borrowing func typecheck(_ query: Query, _ context: Context)
      throws(SQLError) {
    // Bind the derived tables (and store relations) this query names in its own
    // FROM/JOIN before type-checking its arms — SELECT-scoped, so a subquery
    // type-checked through here (e.g. from `precheck`) resolves its own
    // aliases. Schema-only (`rows: false`): the type-check reads no cursor.
    // `visited` carries the cyclic-view guard into a derived body's derive.
    // A nested subquery's FROM sees base tables and enclosing CTEs, NOT this
    // query's derived aliases — its type-check lowers against the base
    // `precheck` reveals from the augmented `context` (enclosing derived
    // aliases dropped, CTEs and store kept, a shadowed CTE preserved).
    // The type-check subtree resolves its scopes strictly (`validate: true`),
    // as its internal `scope`/`prefixes`/`schema` calls always did — force it
    // on regardless of the incoming context's gate (a caller reaches here only
    // when validating). The comparability walk is the exception: it runs on the
    // run path, where a derived body resolves lenient (`validate: false`) so
    // a data-dependent operand a filter drops is not rejected, yet its own
    // reachable comparisons are still comparability-checked — so keep the gate
    // off there while `augment` carries `comparability` into each derived
    // body's resolve (`materialise`), which runs this same walk over it.
    let context = try augment(
        context.validating(context.comparability ? false : true),
        for: query, rows: false)
    // A carrier's row operators add no expression the arms carry — the body
    // type-checks every reachable operand of its own arms.
    switch query.body {
    case let .select(select):
      try typecheck(select, context)
    case let .setop(_, left, right, _):
      // Both arms of a set-operation subquery correlate against the same
      // enclosing scope, so each type-checks under the shared `context.outer`.
      try typecheck(left, context)
      try typecheck(right, context)
    case let .values(rows):
      // A `VALUES` body type-checks each row's expressions — its reachable
      // operands and calls (validate), or its cross-kind comparisons (the run's
      // comparability walk) — exactly as the former `UNION ALL` of FROM-less
      // selects type-checked each arm's projection.
      try typecheck(values: rows, query, context)
    }
    // Each carrier's own `ORDER BY` keys are a new expression surface, handled
    // only by the carrier compile (`ordered(…)`). A reached scalar/`IN`
    // subquery whose body is an ordered set operation is first compiled in the
    // shape pre-pass with `validating(false)`, which bypasses that surface, and
    // is re-checked through this seam — so unless the carrier's keys are
    // checked here too, an outer `columns(of:)` accepts a reached `(… UNION …
    // ORDER BY missing(a))` a run faults (a run-vs-validate divergence). Re-run
    // each carrier compile over the query up to (not including) that carrier —
    // the same inner it stacks over — carrying this context's mode: a validate
    // `columns(of:)` type-checks the sort keys' operands, while the run's
    // comparability walk (this `context.comparability`) hands them to the
    // finder alone, so a carrier `ORDER BY <cross-kind key>` faults 42804 while
    // `ORDER BY <arithmetic>` does not. The plan is discarded, only the keys'
    // fault matters; it is idempotent with the top-level `compile`, and
    // reached-only. The augment above depends only on the body (carriers
    // collect no derived table), so it is the scope each carrier resolves over.
    for (index, carrier) in query.carriers.enumerated() {
      let inner = Query(body: query.body,
                        carriers: Array(query.carriers.prefix(index)))
      _ = try ordered(inner, distinct: carrier.distinct, order: carrier.order,
                      limit: carrier.limit, generated: carrier.generated,
                      context)
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
  ///     emits one empty group, so its `HAVING` and projection are evaluated
  ///     over that group (`empty`) — a divide, overflow, or bad routine call
  ///     faults as a run would; an aggregate operand (zero rows) does not.
  ///   - Otherwise the aggregate folds in the projection and `HAVING` run over
  ///     the filtered rows in the group node, before `HAVING` and any limit, so
  ///     every aggregate operand is validated unconditionally (a short-circuit
  ///     or zero-row limit does not spare it).
  ///   - `HAVING` filters grouped rows before the limit: it validates
  ///     short-circuit aware, and a statically false `HAVING` (like a false
  ///     `WHERE`) leaves the projection's non-aggregate work unreachable.
  ///   - The projection runs last: a limit that drops every row it would yield
  ///     leaves its non-aggregate work unreachable — a `FETCH FIRST 0 ROWS
  ///     ONLY`, or a positive `OFFSET` over a whole-result aggregate's sole row
  ///     (its output type is still derived for the schema, non-faulting);
  ///     otherwise it validates fully.
  /// A `SubqueryCheck` for a `select` — every uncorrelated subquery it nests
  /// recursively type-checked against the same shape the run evaluates and
  /// compiled for its arity once, ahead of the `check` walk, into a map `check`
  /// reads. Validating and compiling each subquery here — where the borrowing
  /// catalog is in scope — mirrors the run path's lowering (which resolves and
  /// materialises the inner query), so schema validation matches execution: a
  /// bad column or routine inside a subquery faults, and a `IN (Q)`'s
  /// single-column arity is enforced from the compiled width.
  ///
  /// An `IN (Q)` occurrence (its `Query` in `select.valued`) has its select
  /// list read at run, so its original shape is type-checked — an `IN (SELECT
  /// 1 / 0 FROM S)` faults `.divide` as the run does. An occurrence ONLY an
  /// `EXISTS` operand runs through the cardinality probe (`Select.probe`:
  /// constant projection, `DISTINCT` quantifier and original `OFFSET`/`FETCH`
  /// kept, `ORDER BY` dropped), which never evaluates the original select list
  /// or sort keys — so its probed shape is type-checked, matching the run:
  /// `EXISTS (SELECT 1 / 0 FROM S)` does NOT fault `.divide` at validate,
  /// exactly as it does not at run, while a bad inner relation or `WHERE`
  /// (retained by the probe) still faults. A `Query` used by both is in
  /// `valued`, so its original is checked (the `IN` needs its values). The
  /// probe applies only to a `probable` `SELECT` — the shape `probe` rewrites
  /// (a non-set-operation select without a `HAVING` that is non-`DISTINCT` or
  /// `DISTINCT` without an `OFFSET`, its target the constant `1` or, for an
  /// aggregate/grouped one, a cardinality-preserving `COUNT(*)`); any other
  /// EXISTS-only query (a `HAVING` or set operation) runs in FULL, so its
  /// original is checked. The arity width is always the original query's
  /// (cursor-free), as `subquery(of:)` records it on the compile path.
  private borrowing func precheck(of select: Select, _ context: Context,
                                  enclosing: Scope? = nil,
                                  prefixes: Array<Scope> = [])
      throws(SQLError) -> SubqueryCheck {
    // Every occurrence's inner-query operand validation defers to the
    // reachability walk, mirroring the lazy executor: a subquery in an
    // unreachable `CASE`/`COALESCE` arm or a short-circuited `AND`/`OR` leg is
    // never materialised, so a throwing operand (`1 / 0`) the type-check finds
    // must not fault an arm the run skips. A scalar occurrence's operands defer
    // through the `.subquery` case of the walk (`SubqueryCheck.type` records it
    // reached), an `IN`/`EXISTS`/quantified one through the `.within`/`.exists`
    // case (`SubqueryCheck.validate` records it) — each validated in its run
    // shape after the walk: an `IN`'s original (its select list is read), an
    // EXISTS-only occurrence's cardinality probe. A reached bad body still
    // faults (parity both directions). (A bad inner column/relation is a
    // structural fault the outer `compile` already raised for every subquery
    // before this runs, so it never reaches here — validation and run agree on
    // it regardless of the arm.)
    // A nested subquery's FROM resolves against base tables and enclosing CTEs,
    // NOT the enclosing SELECT's derived-table aliases — strip them (CTEs/store
    // kept) before type-checking/compiling each subquery, mirroring the compile
    // path's strip in `subquery(of:)`, so the schema path faults an outer
    // derived alias in a subquery's FROM exactly as the run does.
    let context = context.revealed()
    let scalar = select.scalar
    // every scalar occurrence's operand check defers to the walk, keyed here
    // independently of a co-existing `IN`/`EXISTS` twin over identical SQL. A
    // valued/existential twin's eager arity/type derivation is total (no
    // `.divide` on `1 / 0`) and does not reproduce the scalar's operand fault,
    // and — now that an `IN`/`EXISTS` materialises lazily — a twin may itself
    // sit in an unreachable leg, so it cannot stand in for a reachable scalar's
    // operand check. Deferring on `scalar` alone (not `scalar - valued`)
    // records the scalar's own `.scalar` reach in `type` even when a `.valued`
    // reach for the same query is also present — the two per-occurrence reaches
    // must not dedup the scalar away.
    let deferred = scalar
    var widths = Dictionary<Query, Int>()
    var types = Dictionary<Query, ValueType>()
    // Derive each site'S subqueries' cursor-free width and single-column type
    // against that site's own scope, keyed per occurrence — a join `i`'s `ON`
    // against its prefix scope `prefixes[i]` (the relations at that point, not
    // one joined later), the rest against the full `enclosing` — matching the
    // run's `subquery(of:)`. The same inner SQL in an `ON` and the WHERE
    // derives twice — each against its own site's scope — so a name a WHERE
    // subquery finds ambiguous in the full scope faults here, not the `ON`'s
    // narrower prefix. The operand validation now defers to the reachability
    // walk for every site — an `ON` runs the same short-circuit walk the
    // WHERE/HAVING do (`walk` calls `check` per join), so a subquery a
    // short-circuited `AND`/`OR` leg of the `ON` never reaches is unvalidated,
    // exactly as the run's join evaluator never materialises it.
    for index in select.joins.indices {
      var queries = Array<Query>()
      select.joins[index].on.collect(subqueries: &queries)
      let within = index < prefixes.count ? prefixes[index] : enclosing
      for query in queries {
        let nested = within.map { (context.outer ?? Outer()).nested(under: $0) }
            ?? context.outer
        try width(query, scalar, context, nested, &widths, &types)
      }
    }
    // The WHERE, `HAVING`, projection, `GROUP BY`, and `ORDER BY` are walked by
    // the reachability phase, so their operand check defers; their width and
    // single- column type still derive here against the full `enclosing` scope.
    var rest = Array<Query>()
    select.predicate?.collect(subqueries: &rest)
    select.having?.collect(subqueries: &rest)
    if case let .expressions(items) = select.projection {
      for item in items { item.expression.collect(subqueries: &rest) }
    }
    for key in select.grouping.collected { key.collect(subqueries: &rest) }
    for key in select.order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &rest)
      }
    }
    for query in rest {
      let base = context.outer ?? Outer()
      let nested = enclosing.map { base.nested(under: $0) } ?? context.outer
      try width(query, scalar, context, nested, &widths, &types)
    }
    // Carry this select's own enclosing scope `context.outer` so its WHERE
    // type-check (`walk`) resolves a correlated column of this query against
    // the outer, matching the run's lowering; validation admits a correlated
    // column in every clause (projection/`GROUP BY`/`HAVING`/`ORDER BY` as well
    // as `WHERE`/`ON`) exactly as the run's lowering binds it per outer row.
    return SubqueryCheck(widths, types, deferred: deferred,
                         outer: context.outer)
  }

  /// Records the cursor-free width and single-column type of `query` into
  /// `widths`/`types` against the `nested` outer scope, and enforces a scalar
  /// occurrence's single-column arity eagerly (reachability-independent, as the
  /// run's lowering does). Computed once per distinct query at a given site.
  internal borrowing func width(_ query: Query, _ scalar: Set<Query>,
                                _ context: Context, _ nested: Outer?,
                                _ widths: inout Dictionary<Query, Int>,
                                _ types: inout Dictionary<Query, ValueType>)
      throws(SQLError) {
    // The width and single-column type derive for every subquery — cursor-free
    // and total for a clean-resolving inner query (deriving the type of `1 / 0`
    // yields the integer type without dividing). A distinct query at one site
    // is derived once; the same query at another site re-derives against its
    // scope, so a WHERE occurrence's ambiguity still faults there. The compile
    // is shape ONLY, so lenient (`validate: false`): this pre-pass runs for
    // every nested subquery ahead of the reachability walk, so validating a
    // derived body it nests — `1 IN (SELECT x FROM (SELECT 1 / 0 …) AS d)` —
    // would fault a subquery a short-circuited `AND`/`OR` leg drops before the
    // walk reaches it. Validation of a reached subquery's body (and the derived
    // tables nested within it, at any depth) is the walk's job — `typecheck(_
    // select:)` re-derives each reached occurrence's body strictly. Structural
    // faults (a bad inner relation/column, a UNION arity) still surface here —
    // those resolve regardless of `validate`. Lower under `.caller`, this
    // frame's `nested` outer, and shape-only lenience (`validate: false`) — the
    // schema pre-pass's cursor-free derive.
    // `shaping()` defers the set-operation operand-compatibility fold: this
    // pre-pass records every nested subquery's width and single-column type
    // ahead of the reachability walk, so faulting `SQLError.operand` here would
    // reject an unreachable incompatible set-operation subquery a short-
    // circuited leg never reaches. The reached scalar/`IN` re-fold below
    // restores the strict check for an occurrence that does run. Arity and
    // resolution stay eager regardless.
    let inner = context.scoped(as: .caller).with(outer: nested)
        .validating(false).shaping()
    let width = try compile(query, inner).width
    // The single-column output type — unified across the subquery's set-
    // operation arms (`(SELECT 1 UNION SELECT 2.5)` typing `double`), not the
    // first arm alone — for validation's type-check. The run/derive fold reads
    // the `unconstrained` mask via `Resolution`; validation uses the type.
    let derived = try columns(unifying: query, inner).first?.type
    if widths[query] == nil {
      widths[query] = width
      types[query] = derived
    }
    // A scalar occurrence's single-column arity is enforced eagerly,
    // reachability-independent — a cursor-free width check the run's lowering
    // also makes — so a two-column scalar subquery in an unreachable arm still
    // faults `SQLError.arity`, kept separate from the deferred operand check.
    if scalar.contains(query), width != 1 {
      throw .arity(1, width)
    }
  }

  /// The subquery shape a run of the reached occurrence `reach` type-checks
  /// against — chosen from the occurrence's own reached role, not the union of
  /// every role the query occupies in the select. A `scalar` reach (collapses
  /// the cell) or a `valued` one (`IN (Q)`, its value set read) evaluates the
  /// select list, so its original is type-checked; an `existential` reach
  /// (`EXISTS`) runs the cardinality probe (`Select.probe`: constant
  /// projection, `ORDER BY` dropped, original `OFFSET`/`FETCH` kept), never its
  /// select list — so its probed shape is checked, matching the run. So the
  /// same inner SQL reached ONLY as an `EXISTS` validates the probe even where
  /// an unreached arm has it as a scalar. A query the probe does not rewrite (a
  /// `HAVING` or set operation) runs in FULL, so its original is checked even
  /// for an `existential` reach.
  internal borrowing func shape(of reach: Reach) -> Query {
    // The validate side of the EXISTS cardinality probe: an `existential` reach
    // checks the same probed shape the run compiles, so delegate to the single
    // `probed(_:)` source of truth (which peels an `ordered` carrier over a
    // probable primary and rewrites its select list to a constant). A scalar or
    // valued reach evaluates its select list, so its original is checked.
    guard reach.role == .existential else { return reach.query }
    return probed(reach.query)
  }

  private borrowing func typecheck(_ select: Select, _ context: Context)
      throws(SQLError) {
    // A windowed `GROUP BY GROUPING SETS` select lowers to a window over the
    // arm union (`compile(windowed sets:)`): every window-free operand — a
    // group key, an aggregate, a `GROUPING(…)`, a scalar over them — lives in
    // the arm union, while the outer window layer keeps the windows and the
    // scalars wrapping them (`NULLIF(ROW_NUMBER() OVER (), 'x')`, a
    // comparison, a `CASE`), reading the arm columns as `*gwN` union
    // references. Type-check (and, on the run's comparability walk, compare)
    // the arm union so a reachable-operand or cross-kind-comparison fault
    // inside a lifted operand surfaces exactly as a run does, then the lifted
    // outer projection and `ORDER BY` over the union-output scope so a
    // wrapper's operand incomparability faults `42804` here rather than only
    // at execution (`matches`) — both in the mode this `context` carries,
    // keeping run ≡ validate. The window structure itself (its function,
    // frame, and slot positions) is validated by `compile`, the parity gate
    // both paths run before this.
    if select.windows, case let .sets(sets) = select.grouping {
      let parts = try decompose(windowed: select, sets: sets,
                                context.routines, schemas(context.relations))
      try typecheck(parts.union, context)
      try typecheck(outer: parts, select, context)
      return
    }
    // The run's comparability walk visits every reachable comparison surface of
    // this select for the ISO comparability rule — its WHERE, join `ON`s,
    // HAVING, projection, `GROUP BY` and `ORDER BY` keys, aggregate `FILTER`s,
    // and the body of every reached predicate or scalar subquery — and leaves
    // every other validate-only concern to the strict schema path. Its FROM's
    // derived-table bodies are walked by the `augment` that resolved them
    // (`materialise` recurses this same walk under the carried `comparability`
    // gate), and its set-operation arms by the `typecheck(_ query:)` above, so
    // a cross-kind comparison anywhere in the query faults at compile without
    // the full walk's operand type-check.
    if context.comparability {
      try comparability(of: select, context)
      return
    }
    // This select's own resolution scope — the one its nested subqueries
    // correlate against. Built from the unrevealed `context` — correlation
    // resolves against the enclosing scope's relations (its derived aliases
    // among them), unlike an inner subquery's own FROM, which resolves against
    // the revealed base below.
    let enclosing = try scope(of: select, context)
    // The prefix scope of each join, the surface its `ON`'s subquery correlates
    // against — matching the run's `subquery(of:)`.
    let prefixes = try prefixes(of: select, context)
    // Type-check and compile every subquery once, ahead of the reachability
    // walk: the pre-pass validates each `IN`/`EXISTS` inner query (never
    // short-circuited past) and derives every scalar subquery's cursor-free
    // arity and type (total — no `.divide` on `1 / 0`), but defers a scalar
    // occurrence's inner-query operand validation to the walk. Each nested
    // query's correlation resolves against `enclosing` (a join `ON`'s against
    // its prefix) here, matching the run.
    let subquery = try precheck(of: select, context, enclosing: enclosing,
                                prefixes: prefixes)
    // Walk the query's operands reachability-aware, so an unreachable
    // `CASE`/`COALESCE` arm's subquery is left unrecorded and unchecked.
    try walk(select, context, subquery: subquery, prefixes: prefixes)
    // Validate the inner query of each occurrence the walk reached — a scalar
    // or an `IN`/`EXISTS`/quantified one — in the run shape of its own reached
    // role: an `existential` reach the cardinality probe (never its select
    // list), a `scalar`/`valued` reach the original. The shape is chosen from
    // the occurrence's role, NOT the union of every role the query occupies in
    // the select — so the same inner SQL reached only as an `EXISTS` validates
    // the probe even where an unreached arm has it as a scalar. Its correlated
    // columns resolve against this select's scope (nearest), stacked past
    // `outer` — mirroring the lazy executor. A reached `(SELECT 1 / 0 …)`
    // faults `.divide` here exactly as the run does, while an unreached one in
    // a skipped arm does not.
    //
    // A subquery's own FROM sees base tables and enclosing CTEs, NOT the
    // enclosing SELECT's derived-table aliases, so recurse against the revealed
    // base — the derived layers dropped, the CTEs/store (a shadowed CTE among
    // them) kept — while the correlation `outer` above still carries the
    // enclosing scope's ordinals.
    let revealed = context.revealed()
    let base = context.outer ?? Outer()
    let nested = base.nested(under: enclosing)
    let inner = revealed.with(outer: nested)
    for reach in subquery.visited {
      try typecheck(shape(of: reach), inner)
      // The nested-subquery shape pre-pass deferred a set-operation's operand-
      // compatibility fold (`shaping()`), so a genuine incompatibility in a
      // subquery that actually runs would otherwise slip through. Re-fold it
      // strictly here (`inner` carries no `shape`), so a reached scalar or
      // `IN`/quantified (`.valued`) occurrence with irreconcilable arm types
      // faults `SQLError.operand` exactly as before the deferral. An
      // `existential` (`EXISTS`) or `lateral` reach does NOT constrain column
      // type — its cardinality does not read the arms' unified type — so it is
      // skipped and never faults on it, reachable or not.
      switch reach.role {
      case .scalar, .valued:
        _ = try columns(unifying: reach.query, inner)
      case .existential, .lateral:
        break
      }
    }
    // Each join `ON` runs through the same reachability/short-circuit walk the
    // WHERE does, but prefix-scoped: an `ON` predicate short-circuits its
    // `AND`/`OR` at run (`Scope.on` lowers the conjunction the join evaluator
    // steps), so a subquery a short-circuited leg never reaches is NOT
    // validated — `ON 1 = 0 AND 1 IN (SELECT 1 / 0 …)` does not fault, exactly
    // as the join never materialises it — while a reached `ON` subquery IS
    // validated (parity). The `ON`'s local scope is the join's prefix
    // (`prefixes[index]`, the relations at that point, never one joined later),
    // so a correlated reference to a later-joined relation faults per that
    // prefix; its enclosing `outer` stays the select's, so a correlated `ON`
    // subquery column resolves against that prefix stacked past the outer,
    // matching the run's `subquery(of:)`.
    for index in select.joins.indices {
      guard index < prefixes.count else { continue }
      let prefix = prefixes[index]
      let scope = (context.outer ?? Outer()).nested(under: prefix)
      let on = subquery.scoped(context.outer)
      try prefix.check(select.joins[index].on, context.routines, subquery: on)
      for reach in on.visited {
        try typecheck(shape(of: reach), revealed.with(outer: scope))
      }
    }
  }

  /// Type-checks the outer window layer of a windowed `GROUP BY GROUPING SETS`
  /// select — its lifted projection and query `ORDER BY` — against the arm
  /// union's output scope, so a scalar wrapping a window
  /// (`NULLIF(ROW_NUMBER() OVER (), 'x')`, a comparison, a `CASE`) whose
  /// operands are incomparable faults exactly as the ordinary grouped-window
  /// path faults it, on both the run's comparability walk and the strict
  /// validate path.
  ///
  /// The direct lowering (`decompose`) keeps the window functions in the outer
  /// layer, their window-free operands lifted to `*gwN` references of the union
  /// output. The arm union (type-checked by the caller) validates those
  /// operands in their grouped scope, but the outer wrappers that combine the
  /// windows resolve only over the union output — a hole through which a
  /// wrapper's operand-comparability mismatch reaches `matches` at execution
  /// (`42804`) while `columns(of:validate:)` accepts it. Resolving each lifted
  /// outer expression over the same union-output scope the compile seam builds
  /// (`windowed(sets:)`) closes it, in the mode this `context` carries — the
  /// run's comparability finder (`comparisons`, only a `42804` escaping) or the
  /// strict validate type-check (`validate`) — the same two surfaces `walk` and
  /// `comparability(of:)` drive over an ordinary select's projection and sort.
  private borrowing func typecheck(outer parts: WindowedSets,
                                   _ select: Select, _ context: Context)
      throws(SQLError) {
    // The union-output scope keyed by the empty alias — the `*gwN`-named,
    // type-unified arm columns the outer layer reads — built exactly as the
    // compile seam and the schema derive build it, so a lifted outer
    // expression resolves its window operands (`*gwN`) as the run lowers them.
    let inner = try columns(unifying: parts.union, context)
    let schema = Schema(from: inner, names: inner.map(\.name),
                        extent: inner.count, virtuals: [])
    let scope = Scope([(Relation(derived: parts.union.arm, as: ""), schema)])
    // The outer layer hosts every subquery the `Lift` kept out of the arms,
    // resolved against the union scope. Build the `SubqueryCheck` twin of the
    // run's `Resolution` — each hosted subquery's cursor-free width and single-
    // column type derived once (ahead of the walk), a scalar occurrence's
    // operand check deferred to the walk — so validate types a hosted subquery
    // exactly as the run lowers it, keeping run ≡ validate. A subquery
    // correlates against the union scope stacked past this query's own outer,
    // as the run's `subquery(_:_:_:within:)` correlates it.
    let revealed = context.revealed()
    let nested = (context.outer ?? Outer()).nested(under: scope)
    var widths = Dictionary<Query, Int>()
    var types = Dictionary<Query, ValueType>()
    // The scalar-position subqueries classified over the rewritten outer
    // projection and `order` — not the original select — so a correlated
    // subquery the lifter rewrote to reference `*gwN` is recognised as the very
    // `Query` the union-scope check hosts, its arity enforced and its reached
    // body deferred exactly as the run lowers it (run ≡ validate).
    let scalar = parts.scalar
    var hosted = Array<Query>()
    for item in parts.projection {
      item.expression.collect(subqueries: &hosted)
    }
    for key in parts.order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &hosted)
      }
    }
    for query in hosted {
      try width(query, scalar, revealed, nested, &widths, &types)
    }
    let check = SubqueryCheck(widths, types, deferred: scalar,
                              outer: context.outer)
    // The projection sits above the query-level cap (`Project(Limit(Sort))`),
    // so a zero `FETCH` that drops every output row leaves it unreachable;
    // validate it only when reachable, as the ordinary walk does, while a
    // DISTINCT evaluates it before the cap. The layer is a window over the arm
    // union — cardinality-preserving — so its row count is the union's, and the
    // union is statically single-row iff it reduces to one arm with no group
    // keys: the grand-total single set `GROUPING SETS (())` (`.sets([[]])`),
    // which yields exactly one whole-result row. A multi-arm union
    // (`sets.count > 1`, e.g. `((), ())`) is ≥2 rows; a non-empty single set
    // groups by its keys. So a positive `OFFSET` elides the projection only for
    // that grand total, exactly as an ordinary whole-result aggregate
    // (`aggregates && no keys`) is skipped by a positive `OFFSET`. Derive that
    // single-row flag from the decomposition rather than hard-coding `false`.
    // (`||` with a `borrowing self` autoclosure needs the two-statement form.)
    let single: Bool
    if case let .sets(sets) = select.grouping {
      single = sets.count == 1 && sets[0].isEmpty
    } else {
      single = false
    }
    var reachable = select.distinct
    if !reachable { reachable = !drops(select.limit, single: single) }
    if reachable {
      for item in parts.projection {
        try validate(outer: item.expression, scope, context, subquery: check)
      }
    }
    // The sort sits below the cap (`Sort` under `Limit`), so every ORDER BY key
    // runs over the union before the cap pages the rows. Resolve each key
    // to the value the sort evaluates through the one `orderKeys` resolver the
    // ordinary path uses (`Select.orderKeys`): an ordinal or an output name —
    // bound over the output surface the run's `windowed.order` records, an
    // alias else a bare column's name (`\.name`) — names a projected expression
    // the sort recomputes below the cap, so an output-referencing sort pulls
    // that projection into reach and validates it even where the projection
    // block above is skipped under a row-dropping cap (`FETCH FIRST 0` with
    // `ORDER BY 1`), the hole the bespoke ordinal/column skip left. A directly
    // written wrapper (a `NULLIF` over a window) keeps its expression and is
    // validated too; a bare `*gwN` reference resolves cleanly against the union
    // scope. Inheriting the resolver, not re-implementing it, keeps the sort-
    // output model from drifting from the run's.
    for expression in orderKeys(parts.projection, parts.order, named: \.name) {
      try validate(outer: expression, scope, context, subquery: check)
    }
    // Validate the body of each hosted subquery the walk reached — a scalar or
    // an `IN`/`EXISTS`/quantified one — in its own reached role's run shape (an
    // `existential` reach the cardinality probe, a `scalar`/`valued` reach the
    // original), so a reached throwing body faults exactly as the run
    // evaluates it while an unreached one (a dropped page, a lazy `LEAD`
    // default the walk never records) does not. A subquery's own FROM sees the
    // revealed base, its correlation the union scope stacked past this query's
    // outer — the same context the run re-executes it under.
    let recursion =
        revealed.with(outer: (context.outer ?? Outer()).nested(under: scope))
    for reach in check.visited {
      try typecheck(shape(of: reach), recursion)
      // Re-fold a reached set-operation subquery's operand compatibility (the
      // width pre-pass deferred it through `shaping()`), so a reached scalar or
      // `IN` with irreconcilable arm types faults `SQLError.operand`; an
      // `EXISTS`/`lateral` reach doesn't read the unified arm type, so skip it.
      switch reach.role {
      case .scalar, .valued:
        _ = try columns(unifying: reach.query, recursion)
      case .existential, .lateral:
        break
      }
    }
  }

  /// Validates one lifted outer window-layer `expression` over the union
  /// `scope` in the mode `context` carries — the run's comparability finder
  /// (only a `42804` escaping) or the strict validate type-check — resolving a
  /// hosted subquery through the union-scope `subquery` check.
  private borrowing func validate(outer expression: Expression, _ scope: Scope,
                                  _ context: Context,
                                  subquery: SubqueryCheck) throws(SQLError) {
    if context.comparability {
      try scope.comparisons(in: expression, context.routines,
                            subquery: subquery)
    } else {
      _ = try scope.validate(expression, context.routines, subquery: subquery)
    }
  }

  /// Type-checks a `VALUES` body's row expressions — the first-class node's
  /// counterpart of the former `UNION ALL` of FROM-less selects, so a run and a
  /// `columns(of:)` derive fault a `VALUES` alike.
  ///
  /// The rows resolve over an empty local scope (`Scope([])`) carrying the
  /// enclosing `outer`, so a row's expression resolves its literals, calls, and
  /// subqueries, and a bare column — naming nothing local — is a correlated
  /// reference resolved against `outer` (a name neither binds faults). Each row
  /// subquery's cursor-free width and single-column type derive against that
  /// `outer` (a `VALUES` in subquery position), then in validate mode each row
  /// expression's reachable operands and calls are checked (`aggregates`/
  /// `validate`) and each reached subquery body recursed, and in the run's
  /// comparability mode each row expression's cross-kind comparisons are found
  /// (`comparisons`) and each reached body recursed — the same discipline the
  /// carrier `ORDER BY` and the plain arm use.
  ///
  /// A correlated column is admitted throughout the constructor whether or not
  /// the `VALUES` sits in a LATERAL position: ISO puts a LATERAL body's
  /// preceding FROM references in scope, and an ordinary subquery's `VALUES`
  /// likewise names its enclosing query's columns — both bind per outer row.
  private borrowing func typecheck(values rows: Array<Array<Expression>>,
                                   _ query: Query, _ context: Context)
      throws(SQLError) {
    // Value-check (and, on the run's comparability walk, compare) only the rows
    // the run evaluates. A carried positional limit over a bare `VALUES` — no
    // ORDER BY, no DISTINCT — pages the constructor at compile time: the run
    // slices the `.values` leaf's rows before their cells lower (`paged`, see
    // `ordered`), so a discarded row never evaluates and its cell faults never
    // surface — exactly as a `FETCH FIRST 0 ROWS` SELECT's projection is
    // unreachable. Page these AST rows through that same `paged` so a discarded
    // row's `1 / 0` faults neither the run nor `columns(of: validate:)`. An
    // ORDER BY or a DISTINCT carrier keeps the eager leaf — every row evaluates
    // to sort or dedup it — so `surviving` stops the peel at the first such
    // carrier and every row that reaches it is checked (a `VALUES (1 / 0) ORDER
    // BY 1 FETCH FIRST 0 ROWS` still faults, matching the run).
    //
    // The arity/degree and column-type derivation is not sliced: it stays over
    // all the rows in `columns(unifying:)` (the result schema is limit-
    // independent, and the run arity-checks every row before its own carrier
    // slice), so a discarded row's arity mismatch still faults on both paths.
    let rows = surviving(rows, under: query.carriers)
    let scope = Scope([])
    let expressions = rows.flatMap { $0 }
    let nested = context.outer
    var subqueries = Array<Query>()
    var scalars = Set<Query>()
    for expression in expressions {
      expression.collect(subqueries: &subqueries)
      expression.collect(scalar: &scalars)
    }
    if context.comparability {
      // The run's comparability walk: derive each row subquery's width best-
      // effort (a structural fault defers, matching the finder's discipline),
      // find each row expression's cross-kind comparisons, and recurse the
      // finder into each reached predicate/scalar-subquery body — rethrowing
      // only 42804.
      var widths = Dictionary<Query, Int>()
      var types = Dictionary<Query, ValueType>()
      for query in subqueries {
        do {
          try width(query, [], context, nested, &widths, &types)
        } catch let error {
          guard case let .state(code, _) = error, code == "42804" else {
            continue
          }
          throw error
        }
      }
      let check = SubqueryCheck(widths, types, deferred: scalars,
                                outer: nested)
      for expression in expressions {
        try scope.comparisons(in: expression, context.routines, subquery: check)
      }
      let inner = context.revealed().with(outer: nested).comparing()
      for reach in check.visited {
        do {
          try typecheck(shape(of: reach), inner)
        } catch let error {
          guard case let .state(code, _) = error, code == "42804" else {
            continue
          }
          throw error
        }
      }
    } else {
      // Validate mode: derive each row subquery's width/type, type-check each
      // row expression's reachable operands and calls, then re-derive each
      // reached scalar/`IN` subquery body strictly (an `EXISTS`/`LATERAL` reach
      // does not constrain column type).
      var widths = Dictionary<Query, Int>()
      var types = Dictionary<Query, ValueType>()
      for query in subqueries {
        try width(query, [], context, nested, &widths, &types)
      }
      let check = SubqueryCheck(widths, types, deferred: scalars,
                                outer: nested)
      for expression in expressions {
        try scope.aggregates(in: expression, context.routines, subquery: check)
        _ = try scope.validate(expression, context.routines, subquery: check)
      }
      let inner = context.revealed().with(outer: nested)
      for reach in check.visited {
        try typecheck(shape(of: reach), inner)
        switch reach.role {
        case .scalar, .valued:
          _ = try columns(unifying: reach.query, inner)
        case .existential, .lateral:
          break
        }
      }
    }
  }

  /// The `VALUES` rows the run evaluates under its query-level carriers — the
  /// rows a value-check faults over, matching the run's compile-time page.
  ///
  /// It mirrors the compile's carrier peel (`ordered`, innermost first): a
  /// carrier that neither orders nor deduplicates and carries a positional
  /// limit pages the still-`.values` leaf (`paged`), so the rows it discards
  /// never evaluate. The peel stops at the first carrier that orders or
  /// deduplicates — its eager leaf evaluates every row that reaches it — or that
  /// carries no limit, leaving the surviving rows those the run evaluates.
  private func surviving(_ rows: Array<Array<Expression>>,
                         under carriers: Array<Query.Carrier>)
      -> Array<Array<Expression>> {
    var rows = rows
    for carrier in carriers {
      guard !carrier.distinct, carrier.order == nil,
            let limit = carrier.limit else { return rows }
      rows = paged(rows, by: limit)
    }
    return rows
  }

  /// The comparison-finder over a single arm — the comparability-only
  /// counterpart of `typecheck(_ select:)`, faulting a statically-typed
  /// incomparable comparison (`42804`) anywhere the arm reaches one: its WHERE,
  /// join `ON`s, HAVING, projection, `GROUP BY` keys, `ORDER BY` sort keys,
  /// aggregate `FILTER`s, and the body of every reached predicate or scalar
  /// subquery. So the run agrees with the validate walk regardless of table
  /// cardinality, and the optimiser never receives a comparison that would
  /// throw at run to hash into disjoint buckets, push below an empty product,
  /// or drop with a constant-false fold.
  ///
  /// It builds the same scopes the validate `typecheck(_ select:)` builds — the
  /// same `scope`/`prefixes`/`precheck` pre-pass, so the reachable
  /// comparison surfaces and the reached-subquery set match — then hands
  /// each surface to the dedicated finder (`Scope.comparisons(in:)`), which
  /// looks only for comparison-bearing constructs and defers each one's own
  /// resolution fault locally. Unlike the retired walk-reuse, the finder never
  /// runs full type validation, so it cannot abort on a non-comparability fault
  /// and skip a later reachable incomparable comparison — the leak class
  /// (a `COALESCE` argument's arithmetic error hiding a sibling `NULLIF`'s
  /// cross-kind equality) is closed by construction. Only a `42804` escapes; a
  /// subquery-operand-typed placeholder, a NULL comparison, an `IS DISTINCT
  /// FROM`, a `:parameter` operand, and an unreachable short-circuited leg each
  /// defer, since the leaf check (`comparable`/`character`) deciding them is
  /// the validate path's own.
  ///
  /// A reached subquery body recurses through this same finder (`comparing()`),
  /// so an `EXISTS`/`IN (Q)`/quantified or scalar subquery whose uncorrelated
  /// body a run never materialises over an empty outer — its per-row `matches`
  /// never firing — is still comparability-checked. A correlated body's outer
  /// column types against the enclosing scope carried here as the subquery's
  /// `outer`, so a correlated cross-kind key faults here too; the `decorrelate`
  /// gate stays the backstop for the residual a physical rewrite would bucket
  /// apart.
  private borrowing func comparability(of select: Select, _ context: Context)
      throws(SQLError) {
    // Resolve the same scopes the validate `typecheck(_ select:)` builds. A
    // resolution fault here is one the preceding `compile` already surfaced, so
    // it does not re-raise on this post-compile walk (only a 42804 escapes); it
    // does abandon this select's walk, there being nothing left to resolve
    // against.
    let scope: Scope
    let enclosing: Scope?
    let prefixes: Array<Scope>
    let subquery: SubqueryCheck
    do {
      scope = try self.scope(of: select, context)
      enclosing = scope
      prefixes = try self.prefixes(of: select, context)
      subquery = try precheck(of: select, context, enclosing: enclosing,
                              prefixes: prefixes)
    } catch let error {
      guard case let .state(code, _) = error, code == "42804" else { return }
      throw error
    }
    // A stored VIEW this select names in its FROM or a JOIN is executed on the
    // run path as an already-compiled plan (`validate: false`), so its body's
    // comparisons were never comparability-checked and this outer walk treats
    // the view as an opaque relation. Descend the finder into each reached
    // view's body — the same recursion a derived-table body gets through
    // `augment`/`materialise`.
    try comparability(ofViewsIn: select, context)
    // Find every reachable comparison in this arm's own surfaces (WHERE,
    // HAVING, projection, GROUP BY, ORDER BY, aggregate FILTERs),
    // reachability-aware, recording each reached predicate/scalar subquery into
    // `subquery` for the recursion below.
    try find(comparisonsOf: select, scope, context, subquery: subquery)
    // Recurse the finder into each reached predicate or scalar subquery body
    // (`comparing()`). An unreached body (a short-circuited leg's subquery) was
    // never recorded, so it is not recursed, matching the run. Each reach is
    // handled on its own, so a deferred fault in one body never hides a later
    // body's incomparable comparison.
    let revealed = context.revealed()
    let base = context.outer ?? Outer()
    let nested = enclosing.map { base.nested(under: $0) } ?? context.outer
    let inner = revealed.with(outer: nested).comparing()
    for reach in subquery.visited {
      do {
        try typecheck(shape(of: reach), inner)
      } catch let error {
        guard case let .state(code, _) = error, code == "42804" else {
          continue
        }
        throw error
      }
    }
    // Each join `ON` is a comparison surface, scoped to the join's prefix — a
    // cross-kind `ON L.n = R.s` key faults here rather than hashing the two
    // sides into disjoint buckets — and its reached subqueries recurse the same
    // way, correlated against that prefix.
    for index in select.joins.indices where index < prefixes.count {
      let prefix = prefixes[index]
      let outer = (context.outer ?? Outer()).nested(under: prefix)
      let on = subquery.scoped(context.outer)
      try prefix.comparisons(in: select.joins[index].on, context.routines,
                             subquery: on)
      for reach in on.visited {
        do {
          try typecheck(shape(of: reach),
                        revealed.with(outer: outer).comparing())
        } catch let error {
          guard case let .state(code, _) = error, code == "42804" else {
            continue
          }
          throw error
        }
      }
    }
  }

  /// Hands each of `select`'s own reachable comparison surfaces to the finder,
  /// reachability-aware — the comparability counterpart of `walk`, mirroring
  /// exactly the surfaces `walk` reaches, so the finder faults the reachable
  /// static 42804 the validate path faults, and no others.
  ///
  /// The clauses run `WHERE` → group/fold → `HAVING` → limit → projection, so a
  /// constant-false `WHERE` (or `HAVING`) prunes everything after it, a
  /// whole-result aggregate emits one empty group whose HAVING/projection/sort
  /// are value-folded (`fold`/`empty`, NULL-aware — an aggregate over the empty
  /// group is NULL, so a comparison against it is UNKNOWN, not a fault), and a
  /// row-dropping limit leaves the projection unreachable while the aggregate
  /// folds (checked unconditionally, `aggregatesIn`) and the below-limit sort
  /// still run.
  private borrowing func find(comparisonsOf select: Select, _ scope: Scope,
                              _ context: Context, subquery: SubqueryCheck)
      throws(SQLError) {
    let routines = context.routines
    // Every clause admits a correlated column of this query — the WHERE, the
    // projection, `HAVING`, GROUP BY, and `ORDER BY` alike — each resolving it
    // through the enclosing `outer` that `subquery` carries.
    if let predicate = select.predicate {
      try scope.comparisons(in: predicate, routines, subquery: subquery)
      // A false WHERE filters every row, so a GROUP BY forms no group and a
      // non-aggregate query yields no row — nothing after is reachable. A
      // whole-result aggregate still emits one empty group: the HAVING and
      // projection run over it, value-folded.
      if scope.constant(predicate, routines) == false {
        if select.aggregates, select.grouping.expressions.isEmpty {
          if let having = select.having, !having.subquery {
            // A subquery-free HAVING over the empty group both surfaces its own
            // cross-kind fault (`empty`, 42804) and decides the group's fate: a
            // group passes only when it is TRUE, so FALSE/UNKNOWN drops it and
            // the projection is unreachable. A non-comparability fault defers,
            // keeping the projection reachable (the run's `or: true` posture).
            var passes: Bool? = true
            do {
              passes = try scope.empty(having, routines)
            } catch let error {
              if case let .state(code, _) = error, code == "42804" {
                throw error
              }
              passes = true
            }
            if passes != true { return }
          }
          // The lone empty group's projection is unreachable when a limit drops
          // its one row (a zero FETCH or any positive OFFSET), unless DISTINCT.
          var reachable = select.distinct
          if !reachable { reachable = !drops(select.limit, single: true) }
          if reachable, case let .expressions(items) = select.projection {
            for item in items {
              try fold(comparisonsIn: item.expression, scope, routines,
                                subquery: subquery)
            }
          }
          // The sort sits below the limit, so its keys fold over the empty
          // group unconditionally.
          for expression in select.orderKeys {
            try fold(comparisonsIn: expression, scope, routines,
                        subquery: subquery)
          }
        }
        return
      }
    }
    // Aggregate folds run before HAVING and any limit, so their operand and
    // FILTER comparisons are reachable unconditionally — even under a
    // row-dropping limit that leaves the surrounding projection unreachable.
    if case let .expressions(items) = select.projection {
      for item in items {
        try scope.comparisons(aggregatesIn: item.expression, routines,
                              subquery: subquery)
      }
    }
    for expression in select.orderKeys {
      try scope.comparisons(aggregatesIn: expression, routines,
                            subquery: subquery)
    }
    // Each GROUP BY key is evaluated over the input rows to form the groups,
    // before HAVING, projection, and any limit — so find its comparisons
    // unconditionally in this reachable path.
    for expression in select.grouping.expressions {
      try scope.comparisons(in: expression, routines, subquery: subquery)
    }
    if let having = select.having {
      // A HAVING aggregate is collected and folded by the group node before the
      // filter runs, so its operand and FILTER comparisons are reachable
      // whatever the enclosing predicate's short-circuit — a `1 = 0 AND
      // SUM(…)`/`1 = 1 OR SUM(…)` leg the reachability walk prunes still folds.
      // Check them unconditionally, ahead of the reachability-aware scalar
      // walk, exactly as the projection and sort aggregates above and as the
      // validate walk's `aggregates(in:)` does.
      try scope.comparisons(aggregatesIn: having, routines, subquery: subquery)
      try scope.comparisons(in: having, routines, subquery: subquery)
      // A false HAVING filters every group before the projection, so the
      // projection's non-aggregate work is unreachable.
      if scope.constant(having, routines) == false { return }
    }
    // The projection runs after any limit: a limit that drops every row it
    // would yield leaves only its aggregate folds (checked above) reachable. A
    // single-row result (a whole-result aggregate) is dropped by a positive
    // OFFSET too. DISTINCT is the exception (its plan evaluates the projection
    // before the cap pages the deduplicated result).
    let sole = select.aggregates && select.grouping.expressions.isEmpty
    var reachable = select.distinct
    if !reachable { reachable = !drops(select.limit, single: sole) }
    if reachable, case let .expressions(items) = select.projection {
      for item in items {
        try scope.comparisons(in: item.expression, routines, subquery: subquery)
      }
    }
    // The sort sits below the limit, so every ORDER BY key runs over the input
    // rows before the cap pages them — its comparisons are checked
    // unconditionally.
    for expression in select.orderKeys {
      try scope.comparisons(in: expression, routines, subquery: subquery)
    }
  }

  /// Finds the reachable comparisons in a whole-result aggregate's projection
  /// or sort `expression` over the single empty group a constant-false `WHERE`
  /// leaves, through the empty-group fold (`fold`/`empty`) — value-based, so an
  /// aggregate that folds to NULL/0 reads a comparison against it as UNKNOWN
  /// rather than a static type fault, matching the run exactly. It faults 42804
  /// on a cross-kind non-NULL pair the fold reaches; every other fault the fold
  /// would raise is the run's to raise at execution, so it is deferred.
  private borrowing func fold(comparisonsIn expression: Expression,
                              _ scope: Scope, _ routines: Routines,
                              subquery: SubqueryCheck)
      throws(SQLError) {
    do {
      try scope.fold(expression, routines, subquery: subquery)
    } catch let error {
      guard case let .state(code, _) = error, code == "42804" else { return }
      throw error
    }
  }

  /// Descends the comparability walk into each stored VIEW `select` names in
  /// its FROM or a JOIN. A named relation resolving through `resolve(view:)` to
  /// a registered view is executed on the run path as an already-compiled plan
  /// (compiled `validate: false`), so its body's comparisons were never
  /// comparability-checked and the enclosing walk treats it as an opaque
  /// relation — the same silent hole an empty derived-table body left before it
  /// was walked. Recursing the walk into the view's body `Query` (`typecheck`
  /// in `comparing()` mode) faults a cross-kind comparison in the body exactly
  /// as the derived-table recursion does, and — the body resolving through this
  /// same walk — transitively into a view whose body names another view, a
  /// derived table, or a subquery.
  ///
  /// The body resolves over its own `definition_schema.` overlay with the
  /// caller's correlation and CTEs cleared (`body([:])`), so a view means what
  /// it was registered to mean, independent of its call site — the same scope
  /// `schema(of:)` derives a view's types under. A CTE, a derived alias, or a
  /// reserved store relation of the same name resolves ahead of a view (the
  /// `schema(of:)` precedence), so it is not treated as one here; a cyclic view
  /// already under resolution down this chain (`visited`) is not re-entered —
  /// the recursion would not terminate, and the cycle itself faults
  /// `.recursion` on the compile path ahead of this walk. Only a `42804`
  /// escapes: every other body fault stays deferred to the view's own run,
  /// matching the derived-table and subquery-body recursions.
  private borrowing func comparability(ofViewsIn select: Select,
                                       _ context: Context)
      throws(SQLError) {
    var relations = [select.from]
    relations.append(contentsOf: select.joins.map(\.relation))
    for relation in relations {
      guard case let .named(name) = relation.source else { continue }
      let key = name.lowercased()
      // A CTE or derived alias in scope, or a reserved store relation, resolves
      // ahead of a view, so it is not a stored-view reference to descend into.
      if context.relations[key] != nil { continue }
      if Definition(name) != nil { continue }
      guard let view = resolve(view: name) else { continue }
      if context.visited.contains(key) { continue }
      // Expand a `GROUP BY GROUPING SETS` body to its `UNION ALL` arms first —
      // the same expansion the run and `schema(of:)` walk — then recurse the
      // comparability walk over the view body under its own uncorrelated scope,
      // the view marked visited so a nested self-reference terminates.
      let body = try view.query.expanded
      try typecheck(body, context.body([:]).visiting(name))
    }
  }

  /// Walks the operands of `select` reachability-aware — the same order and
  /// short-circuit rules the executor applies — validating each operand a run
  /// would evaluate and recording (via `subquery`) each scalar subquery it
  /// reaches, so the caller validates only the reached scalars' inner queries.
  private borrowing func walk(_ select: Select, _ context: Context,
                              subquery: SubqueryCheck,
                              prefixes: Array<Scope> = [])
      throws(SQLError) {
    let routines = context.routines
    let scope = try scope(of: select, context)
    // Every clause admits a correlated column of this query (`subquery`) — the
    // WHERE, projection, `HAVING`, and `ORDER BY` alike — resolving it against
    // the enclosing `outer` exactly as the run's lowering does.
    // An `ORDER BY` ordinal names a 1-based SELECT-list position; one outside
    // `1 ... width` names no output column and faults `SQLError.column`
    // (spelled as the ordinal), exactly as the compile path's ordinal
    // resolution does — structural and reachability-independent, so a
    // row-dropping limit never spares it. `orderKeys` resolves an IN-range
    // ordinal to its projection expression but silently drops an out-of-range
    // one, so this raises it here.
    if let clause = select.order {
      let width = scope.width(of: select.projection)
      for key in clause.keys {
        if case let .ordinal(position) = key.sort,
            position < 1 || position > width {
          throw .column("\(position)")
        }
      }
    }
    // A grouped `ORDER BY` sorts in the grouped slot space, so each sort key
    // must name a `GROUP BY` key, an aggregate, or an output — resolve it
    // through the same grouped lowering the run does, faulting
    // `SQLError.grouping` on a resolvable-but-non-grouped column exactly as the
    // compile path does. Structural, so it runs regardless of the WHERE/limit
    // reachability the operand type-check below tracks.
    if select.aggregates {
      try order(grouped: select, scope, context, prefixes: prefixes)
    }
    if let predicate = select.predicate {
      try scope.check(predicate, routines, subquery: subquery)
      // A false WHERE filters every row, so a GROUP BY forms no group and a
      // non-aggregate query yields no row — nothing after is reachable. A
      // whole-result aggregate (an aggregate projection or HAVING, no GROUP BY)
      // still emits one empty group: the fold sees zero rows, so an aggregate
      // operand never evaluates (it propagates NULL), but the HAVING and
      // projection run over the group's results, so evaluate them (`empty`) — a
      // divide, overflow, or bad routine call faults as the run would.
      if scope.constant(predicate, routines) == false {
        if select.aggregates, select.grouping.expressions.isEmpty {
          if let having = select.having {
            // HAVING filters the group before any OFFSET/FETCH limit, so
            // evaluate it unconditionally — a zero `FETCH` or positive `OFFSET`
            // spares only the projection, never HAVING. It validates its
            // operands (a divide, overflow, or bad routine call faults) AND
            // yields the group's fate — a group passes only when HAVING is
            // TRUE, so FALSE or UNKNOWN drops it and the projection is
            // unreachable.
            //
            // A HAVING nesting an `EXISTS`/`IN (Q)` subquery is the exception:
            // `empty` cannot materialise the subquery (it carries no catalog),
            // so it folds UNKNOWN — but the subquery is row-independent and may
            // be TRUE at run, keeping the group and running the projection. So
            // a subquery-bearing HAVING is NOT-definitely-empty: fall through
            // and validate the projection, so `columns(of:)` surfaces the fault
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
          // empty group's row (dedup needs it) before the cap pages the
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
          // The lone empty group is sorted below the limit — the shape is
          // `Project(Limit(Sort(…)))` — so its ORDER BY keys evaluate over
          // that group's row unconditionally, ahead of a limit that would drop
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
    // Each GROUP BY key is evaluated over the input rows to form the groups,
    // before the HAVING, the projection, and any limit — so validate every key
    // here, unconditionally in this reachable path (the constant-false WHERE
    // above already returned, forming no group and evaluating no key). Route
    // each key through the same per-operand type-check the projection and
    // ORDER BY keys use (`validate`), so a bare `.column` key (the only shape
    // the parser yields today, a `NATURAL`/`USING` merged column among them)
    // resolves exactly as it does elsewhere — the merged binding shadowing its
    // two sides — while an evaluatable key surfaces its fault (a divide,
    // overflow, bad-type op, or unknown/misapplied call) under `validate`
    // exactly as the run evaluates it, closing the gap where `group` lowers the
    // key structurally (no evaluation) so `compile` alone never surfaces it.
    for expression in select.grouping.expressions {
      _ = try scope.validate(expression, routines, subquery: subquery)
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
    // A single-row result — a whole-result aggregate, or any FROM-less select
    // (one row over the `single` leaf) — emits exactly one row, so a positive
    // OFFSET drops it too, not just a zero FETCH, and its projection is then
    // unreachable; this matches the compile path, which caps the `single` plan
    // below the projection. A DISTINCT select is the exception: its plan is
    // `Limit(Distinct(Project(…)))`, so the projection evaluates over every
    // candidate row (dedup needs them) before the cap pages the deduplicated
    // result — a zero FETCH or skipping OFFSET does not spare it. A false WHERE
    // still yields no rows to dedup (handled above), so only the limit-based
    // elision is bypassed for DISTINCT.
    let sole = select.aggregates && select.grouping.expressions.isEmpty
    var reachable = select.distinct
    if !reachable { reachable = !drops(select.limit, single: sole) }
    if reachable, case let .expressions(items) = select.projection {
      for item in items {
        _ = try scope.validate(item.expression, routines, subquery: subquery)
      }
    }
    // The sort sits below the limit — the shape is `Project(Limit(Sort(…)))`
    // — so it evaluates every ORDER BY key over the input rows before the cap
    // pages them, independent of whether the projection is reachable: a limit
    // that drops every output row still runs the sort. So validate each key
    // unconditionally — its calls, arithmetic, and column references exactly
    // as a projected expression's. `orderKeys` resolves an `ordinal(n)` or an
    // output-name key to the projection expression the sort recomputes below
    // the limit, so a projection term reached only through the sort is checked
    // even where the projection block above is skipped under the limit; a
    // projection term no sort key reaches stays correctly unchecked (the
    // projection never runs under a row-dropping limit).
    for expression in select.orderKeys {
      _ = try scope.validate(expression, routines, subquery: subquery)
    }
  }


  /// Resolves a grouped `select`'s `ORDER BY` through the same grouped lowering
  /// the compile path applies, so the type-check enforces the GROUP BY rules on
  /// each sort key exactly as a run does — a bare column must be a `GROUP BY`
  /// key or occur inside an aggregate, else `SQLError.grouping`; an
  /// out-of-range ordinal `SQLError.column`; a duplicated output name
  /// `SQLError.ambiguous`.
  ///
  /// It rebuilds the `Grouped` `group` builds — the `GROUP BY` keys and the
  /// aggregations collected from the projection, `HAVING`, and the `ORDER BY`
  /// sort keys, deduped by resolved `Aggregation` — then lowers the projection
  /// and the `ORDER BY` through it, reusing `Grouped.terms`/`Grouped.order`
  /// so the two paths cannot drift. It resolves only, reading no cursor; a
  /// run's operand type-check over the (structurally valid) keys stays the
  /// caller's.
  private borrowing func order(grouped select: Select, _ scope: Scope,
                               _ context: Context,
                               prefixes: Array<Scope> = [])
      throws(SQLError) {
    guard let clause = select.order else { return }
    let routines = context.routines
    // A grouped aggregate's argument or FILTER may nest a subquery (`ORDER BY
    // SUM(CASE WHEN EXISTS (Q) …)`), which lowering resolves against the
    // materialised map, so build the select's subquery seam once here — the
    // same one the run's `group` builds — for this structural resolve to lower
    // those aggregates exactly as the run does. It threads the same
    // `enclosing`/`outer`/`prefixes` the run path passes, so a correlated inner
    // query (`WHERE S.k = T.k`) resolves its outer column here exactly as at
    // run, rather than compiling with no enclosing scope and faulting
    // `SQLError.column`.
    let subquery = try subquery(of: select, context.scoped(as: .caller),
                                enclosing: scope, prefixes: prefixes).rest
    // Collect the distinct aggregates the grouped plan folds — the projection,
    // the `HAVING`, and the `ORDER BY` sort-key expressions — then dedup by the
    // resolved `Aggregation`, exactly as `group` does, so a grouped `ORDER BY`
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
    // This select's grouping keys and — for one expanded `GROUPING SETS` arm —
    // its superset, matching the run's `group`. An `.arm` never carries an
    // `ORDER BY` (it rides the wrapper), so the superset is used here only for
    // completeness; a `.sets` never reaches this path (it is expanded before
    // any resolve).
    let (grouping, superset): (Array<Expression>, Array<Expression>) =
        switch select.grouping {
        case let .keys(keys): (keys, [])
        case let .arm(keys, superset): (keys, superset)
        case .sets: ([], [])
        }
    // The GROUP BY keys' lowered base-ordinal terms, so a bare `NATURAL`/
    // `USING` merged key (which binds no single ordinal) is matched by term —
    // the same lowering the run's `group` computes.
    let keys = try grouping.map { key throws(SQLError) -> Term in
      try scope.term(key, routines, subquery: subquery)
    }
    let supers = try superset.map { key throws(SQLError) -> Term in
      try scope.term(key, routines, subquery: subquery)
    }
    // Build the grouping and lower the projection through it to record each
    // output name (an alias, else a group column's own name) — the surface an
    // `ORDER BY` output name resolves against — then lower the `ORDER BY`,
    // which faults a non-group column, an out-of-range ordinal, or an ambiguous
    // name. A window in the ORDER BY (`ORDER BY RANK() OVER (…)`) makes this a
    // window query, so build the windowed surface `group` builds — threading
    // the same `select.windows` — or `Grouped.order` faults lowering the window
    // through a surface with no window registry.
    var grouped = try Grouped(scope, grouping, keys, aggregations,
                              superset: supers, subquery: subquery,
                              windowed: select.windows)
    let projection = try grouped.terms(select.projection, routines,
                                       subquery: subquery)
    _ = try grouped.order(clause, projection, routines, subquery: subquery)
  }

  /// The resolved grouped-space `Term` of each of a grouped arm's projected
  /// items, paired with a resolver lowering an arbitrary expression to the same
  /// grouped space — the identity surface the `ordered` set-op carrier matches
  /// a query-level `ORDER BY` key against, so it agrees with the plain grouped
  /// `ORDER BY` path (both route through this one `Grouped`).
  ///
  /// The carrier over a `GROUPING SETS` expansion resolves its `ORDER BY` keys
  /// against the union's output scope, which cannot recompute an aggregate. To
  /// decide whether a key is an already-projected value — so it orders on that
  /// output rather than a synthetic hidden column — it lowers the key here and
  /// matches its `Term` against these projected terms by resolved identity,
  /// general over every expression shape (a qualifier-equivalent aggregate
  /// `SUM(s.Qty)` ≡ the projected `SUM(Qty)`), not raw AST + a `.column`-only
  /// qualifier strip. It rebuilds the same `Grouped` the run's `group` and the
  /// schema `order(grouped:)` build — the keys and the aggregations collected
  /// from the projection, `HAVING`, and (the arm carries the materialised keys
  /// as projected items) the sort keys, deduped by resolved `Aggregation` — so
  /// the identity cannot drift from either. It resolves only, reads no cursor.
  ///
  /// `resolve` faults `SQLError.grouping` on a genuinely non-grouped reference,
  /// which for an unprojected key the carrier catches to mean "not a projected
  /// value, materialise it"; a projected key lowers cleanly to its output slot.
  borrowing func projected(arm select: Select, _ context: Context)
      throws(SQLError)
      -> (terms: Array<Term>,
          resolve: (Expression) throws(SQLError) -> Term) {
    let context = try augment(context, for: .select(select), rows: false)
    let routines = context.routines
    let scope = try scope(of: select, context)
    let prefixes = try prefixes(of: select, context)
    let subquery = try subquery(of: select, context.scoped(as: .caller),
                                enclosing: scope, prefixes: prefixes).rest
    // The distinct aggregates the arm folds — its projection (which for a
    // carried GROUPING SETS arm includes the materialised sort keys as extra
    // projected items) and its `HAVING` — deduped by resolved `Aggregation`,
    // exactly as `group` does, so a projected aggregate and a
    // qualifier-equivalent sort key fold into one slot.
    var expressions = Array<Expression>()
    for expression in select.projection.projected {
      expression.collect(into: &expressions)
    }
    if let having = select.having { having.collect(into: &expressions) }
    var aggregations = Array<Aggregation>()
    for expression in expressions {
      let aggregation = try expression.aggregation(scope, routines,
                                                   subquery: subquery)
      if !aggregations.contains(aggregation) {
        aggregations.append(aggregation)
      }
    }
    let (grouping, superset): (Array<Expression>, Array<Expression>) =
        switch select.grouping {
        case let .keys(keys): (keys, [])
        case let .arm(keys, superset): (keys, superset)
        case .sets: ([], [])
        }
    let keys = try grouping.map { key throws(SQLError) -> Term in
      try scope.term(key, routines, subquery: subquery)
    }
    let supers = try superset.map { key throws(SQLError) -> Term in
      try scope.term(key, routines, subquery: subquery)
    }
    var grouped = try Grouped(scope, grouping, keys, aggregations,
                              superset: supers, subquery: subquery)
    let terms = try grouped.terms(select.projection, routines,
                                  subquery: subquery)
    return (terms, { expression throws(SQLError) in
      try grouped.resolve(expression, routines, subquery: subquery)
    })
  }

  /// The result columns of a windowed `GROUP BY GROUPING SETS` `select` — the
  /// schema twin of the direct compile lowering (`compile(windowed sets:)`), so
  /// validate types exactly the shape run computes (run ≡ columns(of:)).
  ///
  /// It reuses the same `decompose` the compile seam does — the window-free arm
  /// union and the outer window layer's `projection` over it — derives the arm
  /// union's output schema (its `*gwN`-named, type-unified columns), builds the
  /// union-output `Scope` over that schema, and resolves each lifted outer item
  /// against it through the ordinary projection-output logic (`output(_:at:)`),
  /// so each output carries the complete `ResolvedColumn` — type AND
  /// `unconstrained` mask — that an ordinary grouped-window select yields as a
  /// set-op arm: a `*gwN` reference by the union column's type and mask (a
  /// passed-through constant-NULL source column stays unconstrained), a
  /// constant NULL kept outer unconstrained, a window by its constrained result
  /// (a ranking function `.integer`, an aggregate window from its `*gwN`
  /// argument), the shape the compiled `Windowed` surface lowers it to. Keeping
  /// only the type (hand-stamped constrained) would mis-type a constant-NULL
  /// output as a constrained integer, so an outer set-op merge would reject the
  /// integer/text pair (`42804`) the ordinary companion accepts.
  ///
  /// Each output then re-takes its name and synthesized-header provenance from
  /// the original projected item — an alias, else a bare column's name, else a
  /// positional `column N` an unnamed expression takes (marked synthesized), so
  /// an unnamed windowed output feeding an outer set-op carrier stays
  /// ordinal-only (not name-bindable), never the internal `*gwN` name it reads.
  borrowing func columns(windowed select: Select,
                         sets: Array<Array<Expression>>, _ context: Context)
      throws(SQLError) -> Array<ResolvedColumn> {
    let routines = context.routines
    let parts = try decompose(windowed: select, sets: sets, routines,
                              schemas(context.relations))
    // The arm union's output schema — the same columns the compile seam builds
    // its window-source scope from — derived through the shared `columns
    // (unifying:)` fold, so the arms' NULL-padded columns type through the
    // set-operation `merge` exactly as at compile.
    let inner = try columns(unifying: parts.union, context)
    let arity = inner.count
    let schema = Schema(from: inner, names: inner.map(\.name), extent: arity,
                        virtuals: [])
    let scope = Scope([(Relation(derived: parts.union.arm, as: ""), schema)])
    // The outer layer hosts every subquery the `Lift` kept out of the arms,
    // resolved against the union scope — the same `Resolution` the compile seam
    // builds, so a hosted subquery derives its output column exactly as the run
    // lowers it.
    var hosted = Array<Query>()
    for item in parts.projection {
      item.expression.collect(subqueries: &hosted)
    }
    for key in parts.order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &hosted)
      }
    }
    // Classify each hosted subquery's role over the rewritten outer items,
    // not the original select: the lifter may rewrite a correlated subquery's
    // free group-key references to `*gwN` before hosting it, so the `Query` the
    // `Resolution` compiles differs from the select's original spelling.
    let outer = try subquery(hosted, roles: { parts.roles(of: $0) }, context,
                             within: scope)
    // Resolve each outer window-layer item over the union scope through the
    // ordinary projection-output logic, so its `unconstrained` mask comes from
    // the same resolution as its type (a constant NULL unconstrained, a window
    // constrained, a passed-through `*gwN` column by its source mask), then
    // re-stamp the name and synthesized-header provenance from the original
    // item — an inferable name, else a synthesized `column N`.
    return try parts.items.indices.map { index throws(SQLError) in
      let name = parts.items[index].name ?? "column \(index + 1)"
      let resolved = try scope.output(parts.projection[index], at: index,
                                      routines, subquery: outer)
      return ResolvedColumn(OutputColumn(name: name, type: resolved.type),
                            unconstrained: resolved.unconstrained,
                            synthesized: parts.items[index].name == nil)
    }
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
  /// types without re-checking its reachable operands, so a view whose body is
  /// data-dependent-empty — a text-arithmetic projection under a filter that
  /// matched no row — does not fault a `SELECT *` over it that already ran.
  borrowing func schema(of relation: Relation, _ context: Context,
                        preceding: Scope? = nil)
      throws(SQLError) -> Schema {
    let name = relation.name
    // A LATERAL derived table is not bound in the overlay (it is never
    // materialised once as a constant), so derive its schema through the same
    // derived-body machinery a non-lateral body uses (`materialise`, `rows:
    // false`) — over the revealed base (base + CTEs + store, its own alias out
    // of scope), so a body naming a CTE resolves it, exactly as a non-lateral
    // body does.
    //
    // Per ISO a LATERAL body's preceding-FROM references are in scope
    // throughout its query expression, including the SELECT list, so its output
    // shape is not correlation-independent — a projected preceding column
    // (`SELECT T.Id AS id`) types from that outer column. So the schema derive
    // threads the `preceding` scope as the correlation stack (`with(outer:)`),
    // the same revealed-base-with-outer context `compile(select)` compiles the
    // body under — schema, validation, and compile share it, so a projected
    // preceding column derives its type here exactly as the run lowers it to a
    // bound parameter. Correlation is admitted in every clause, so the
    // projected preceding column needs no special lateral admission. `validate:
    // false` keeps the derive lenient; the strict operand/function type-check
    // rides through `compile(select)` where the `validate` gate is honoured, so
    // it is not duplicated here.
    if relation.lateral, case let .derived(query) = relation.source {
      let stack = context.outer ?? Outer()
      let nested = stack.nested(under: preceding ?? Scope([]))
      let scope = context.revealed().with(outer: nested)
          .validating(false)
      return try materialise(query, scope, rows: false,
                             columns: relation.columns).schema()
    }
    // The explicit `AS t(c, …)` list positionally renames a named relation's
    // output columns; a derived table's list was already applied where it
    // materialised (its overlay binding below carries the renamed names), so
    // only a `.named` source renames here — never double-renaming a derived
    // table read back through the overlay. This is the schema-only mirror of
    // `resolve`'s named-relation rename, kept in parity so the two paths
    // advertise the same column names.
    let renaming: Array<String> = if case .named = relation.source {
      relation.columns
    } else {
      []
    }
    if let cte = context.relations[name.lowercased()] {
      return try cte.schema().renamed(renaming)
    }
    // A reserved store relation types through its schema-ONLY build (header +
    // types, no rows), so resolving a view over `definition_schema.tables`/
    // `.columns` reads only the schema and never triggers the row builder.
    if let relation = Definition(name) {
      return try store(relation, rows: false).schema().renamed(renaming)
    }
    if let view = resolve(view: name) {
      // A view's declared schema types every column `.integer`, since a view
      // stores no types; resolve the view body's own types so a `SELECT *` over
      // the view reports each column's true type. Resolving runs the
      // resolve-only worker over the view's own `definition_schema.` overlay,
      // built schema-ONLY so a view over a reserved relation resolves its types
      // without a row build. The names stay the view's declared ones; only the
      // types come from the resolved body.
      let base = view.schema()
      // A cyclic view cannot resolve its body's types: resolving it would
      // re-enter this view forever, so break the cycle and fall back to the
      // declared schema (every type the `.integer` default). `try?` cannot
      // catch this — the recursion overflows the stack rather than throwing.
      if context.visited.contains(name.lowercased()) {
        return try base.renamed(renaming)
      }
      // Type-check the body's reachable operands and calls across every arm and
      // clause — `compile` cannot check a routine EXISTS, the first-arm resolve
      // below sees only the first projection, and the outer query's walk does
      // not reach into a body. `typecheck` faults an unknown call or a bad
      // operand a `SELECT * FROM v` run would evaluate — a `WHERE`/`HAVING`, a
      // later `UNION` arm — while skipping an arm a short-circuit proves
      // unreachable.
      // The view name enters `visited` before its body's derived tables
      // materialise, so a derived table naming this view (`FROM (SELECT * FROM
      // <self>) AS d`) re-enters with the view already visited and faults
      // `.recursion` rather than recursing to a stack overflow — the guard
      // rides through `augment`/`materialise` into the derived body.
      // `body([:])` enters the view-body scope with the caller's correlation
      // stack cleared: a view is defined independently of its call site, so an
      // unbound column in the definition must fault — NOT bind to an enclosing
      // row — when the view's schema is derived from inside a correlated
      // subquery, keeping this derivation consistent with `resolve`/`compile`.
      // Derive and type-check the same expanded AST a run does: a `GROUP BY
      // GROUPING SETS` body expands to its `UNION ALL` arms FIRST, so the
      // reachability typecheck sees the per-set arms. An unexpanded body would
      // read `GROUPING SETS ((Region), ())` as non-empty `grouping.expressions`
      // and, under a constant-false `WHERE`, short-circuit without validating
      // the projection — yet the expanded `()` grand-total arm still produces a
      // group and evaluates it at run, so `columns(of:)` would accept a body
      // (`SELECT 1 / 0 … GROUP BY GROUPING SETS ((Region), ())`) the run
      // faults. Expanding here keeps the view schema path in step with the run.
      let body = try view.query.expanded
      let overlay =
          try augment(context.body([:]).visiting(name), for: body,
                      rows: false)
      // Gate the body's reachable-operand check on `context.validate`: a
      // `validate: false` derive skips it, so a data-dependent-empty body (a
      // text arithmetic under an unmatched filter) does not fault a `SELECT *`
      // over the view that already ran to its (empty) result. It also rides
      // into the recursive derive so a view over a view stays derive-only.
      if context.validate {
        try typecheck(body, overlay)
      }
      // Type the body's columns: their names off the first arm (the ISO rule
      // for a UNION), their types unified across every arm, each carrying its
      // `unconstrained` mask so an all-NULL view column unifies with any later
      // typed arm through `Schema(from:)`. Arity — the body's width against the
      // declared columns — is `compile`'s job (the public entry runs it), so on
      // a shortfall fall back to the declared schema rather than re-checking it
      // here.
      let resolved = try resolved(query: body, in: overlay)
      guard resolved.count == base.width else {
        return try base.renamed(renaming)
      }
      return try Schema(from: resolved, names: base.names,
                        extent: base.extent,
                        virtuals: base.virtuals).renamed(renaming)
    }
    guard let table = table(named: name) else {
      throw .relation(name)
    }
    return try table.schema().renamed(renaming)
  }
}
