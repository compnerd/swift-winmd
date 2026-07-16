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
    let context = Context(routines: routines).validating(validate)
    // Extend the scope with any `definition_schema.` store relation the query
    // names, so its result schema resolves the reserved relation the same as a
    // run would — SCHEMA-ONLY, so typing never triggers the row build. A
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
    return try columns(of: query.first, scope)
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
  /// Each CTE binds a `RelationInstance` of its DECLARED columns with no rows —
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
    let context = Context(routines: routines).validating(validate)
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
          RelationInstance(columns: cte.columns, rows: [],
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
        try self.validate(cte, against: context.body(overlay),
                          typecheck: true)
      }
      // Bind the CTE's schema-only self into the overlay AFTER its body is
      // validated — the scope a later CTE and the trailing query resolve against
      // — exactly as `Engine.with` binds the materialised relation after running
      // its body.
      overlay[cte.name.lowercased()] = declared
    }
    // Compile/type-check/derive from the base `context.scoping(overlay)`
    // (idempotently augmented within each, which pushes the trailing query's
    // derived layer and reveals the base for a nested subquery), so a nested
    // subquery's FROM sees the CTE overlay and base tables but NOT this query's
    // derived aliases, and a CTE a same-named derived alias shadows stays
    // visible beneath the revealed base. Thread `validate` into `compile` as
    // the non-`WITH` path does: a `validate: false` derive after a successful
    // run must NOT eager-type-check a derived body in the trailing query — a
    // data-dependent body expression a filter drops (`FROM (SELECT Label + 1 AS
    // x FROM K WHERE k = 0) AS d`) is TRUSTED, not rejected, matching the run.
    // `validate: true` keeps the strict schema check.
    let base = context.body(overlay)
    _ = try compile(query, base)
    if validate { try typecheck(query, base) }
    return try columns(of: query.first, base)
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
  /// `.integer` default. The context's `validate` rides through to any view
  /// this arm's relations resolve, gating the view body's reachable-operand
  /// check the same as the outer query's — a `validate: false` context never
  /// re-type-checks a view body a run already proved runnable.
  borrowing func columns(of select: Select, _ context: Context)
      throws(SQLError) -> Array<OutputColumn> {
    // Bind THIS select's own FROM/JOIN derived tables (and store relations)
    // before deriving either the subquery map or the scope — a set-op ARM
    // reaches here directly (`columns(of query.first, …)`), and the top-level
    // augment collected NO arm-local aliases (arms are SELECT-scoped), so a
    // subquery naming the arm's own derived alias (`WHERE Id IN (SELECT Id FROM
    // d)`) would else compile against a scope missing `d`. Schema-only, no
    // cursor; `validate` gates a derived body's own operand check.
    let augmented = try augment(context, for: .select(select), rows: false)
    // A scalar subquery in the projection derives its type from its inner
    // query's single column, so build the SAME cursor-free `Resolution` map the
    // compile path's lowering reads — every nested subquery compiled ONCE for
    // its width and single-column type, each discovering its correlation against
    // this select's own scope (`enclosing`) — and pass it to the projection walk
    // so an output type for a `(SELECT …)` matches the type the run advertises.
    // The projection walk is BARRED (a correlated column of THIS query in the
    // projection is diagnosed, as the run's projection lowering bars it).
    // Resolve over the AUGMENTED context so a subquery naming this select's own
    // arm-local derived alias binds it, while `subquery(of:)` REVEALS the base
    // so the subquery's OWN FROM sees no derived alias (a CTE a same-named
    // derived alias shadows resolved beneath the dropped layer).
    let scope = try scope(of: select, augmented)
    // Pass each join's PREFIX scope so an `ON`'s subquery correlates against its
    // prefix and the WHERE's against the full scope — the SAME per-occurrence
    // resolution the run path uses, so a name a WHERE subquery finds ambiguous in
    // the full scope faults HERE too (typecheck↔run parity), not silently reusing
    // an `ON` occurrence's narrower prefix.
    let prefixes = try prefixes(of: select, augmented)
    // These derivations lower under `.caller` — a schema-only type derive keys
    // its subqueries in the caller id space regardless of an enclosing view
    // scope the incoming context may carry.
    let plans = try subquery(of: select, augmented.scoped(as: .caller),
                             enclosing: scope, prefixes: prefixes)
    return try scope.columns(of: select.projection, augmented.routines,
                             subquery: plans.rest.barred)
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
    // Bind THIS select's own FROM/JOIN derived tables (and store relations)
    // before resolving its relations — SELECT-scoped, so a subquery select
    // whose schema is derived directly here (a scalar subquery's output type)
    // resolves its OWN aliases. Schema-only: `scope` reads no cursor. `visited`
    // carries the cyclic-view guard into a derived body's materialise, and
    // `validate` gates that body's own reachable-operand check the same as the
    // outer query's — a `validate: false` derive trusts a run-proven body.
    let context = try augment(context, for: .select(select), rows: false)
    guard let relation = select.from else { return Scope([]) }
    // Build the running scope INCREMENTALLY so a LATERAL join's schema derives
    // against the PRECEDING FROM — per ISO its projection may name a preceding
    // column, so its output shape types from that scope. A non-lateral join's
    // schema is correlation-independent, so the preceding scope is harmless.
    var relations = [(relation, try schema(of: relation, context))]
    for join in select.joins {
      let joined =
          try schema(of: join.relation, context, preceding: Scope(relations))
      relations.append((join.relation, joined))
    }
    return Scope(relations)
  }

  /// The PREFIX scope of each join of `select` — join `index`'s prefix is the
  /// FROM relation and joins `0…index`, the relations available AT that join
  /// point, never one joined LATER. A join `ON`'s subquery correlates against
  /// its prefix (so a reference to a later-joined relation faults), matching the
  /// compile path's `subquery(of:)`. Empty for a FROM-less or join-less select.
  private borrowing func prefixes(of select: Select, _ context: Context)
      throws(SQLError) -> Array<Scope> {
    guard let relation = select.from, !select.joins.isEmpty else { return [] }
    // Build the running scope INCREMENTALLY so a LATERAL join's schema derives
    // against the PRECEDING FROM (the same reason `scope(of:)` does).
    var relations = [(relation, try schema(of: relation, context))]
    for join in select.joins {
      let joined =
          try schema(of: join.relation, context, preceding: Scope(relations))
      relations.append((join.relation, joined))
    }
    return select.joins.indices.map { index in
      Scope(Array(relations[0 ... index + 1]))
    }
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
  borrowing func typecheck(_ query: Query, _ context: Context)
      throws(SQLError) {
    // Bind the derived tables (and store relations) THIS query names in its own
    // FROM/JOIN before type-checking its arms — SELECT-scoped, so a subquery
    // type-checked through here (e.g. from `subqueryCheck`) resolves its OWN
    // aliases. Schema-only (`rows: false`): the type-check reads no cursor.
    // `visited` carries the cyclic-view guard into a derived body's derive.
    // A nested subquery's FROM sees base tables and enclosing CTEs, NOT this
    // query's derived aliases — its type-check lowers against the base
    // `subqueryCheck` REVEALS from the augmented `context` (enclosing derived
    // aliases dropped, CTEs and store kept, a shadowed CTE preserved).
    // The type-check subtree resolves its scopes strictly (`validate: true`),
    // as its internal `scope`/`prefixes`/`schema` calls always did — force it
    // on regardless of the incoming context's gate (a caller reaches here only
    // when validating).
    let context = try augment(context.validating(true), for: query, rows: false)
    switch query {
    case let .select(select):
      try typecheck(select, context)
    case let .setop(_, left, right, _):
      // Both arms of a set-operation subquery correlate against the same
      // enclosing scope, so each type-checks under the shared `context.outer`.
      try typecheck(left, context)
      try typecheck(right, context)
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
                                       enclosing: Scope? = nil,
                                       prefixes: Array<Scope> = [])
      throws(SQLError) -> SubqueryCheck {
    // Every occurrence's inner-query OPERAND validation DEFERS to the
    // reachability walk, mirroring the lazy executor: a subquery in an
    // unreachable `CASE`/`COALESCE` arm or a short-circuited `AND`/`OR` leg is
    // never materialised, so a THROWING operand (`1 / 0`) the type-check finds
    // must not fault an arm the run skips. A SCALAR occurrence's operands defer
    // through the `.subquery` case of the walk (`SubqueryCheck.type` records it
    // reached), an `IN`/`EXISTS`/quantified one through the `.within`/`.exists`
    // case (`SubqueryCheck.validate` records it) — each validated in its RUN
    // shape after the walk: an `IN`'s ORIGINAL (its select list is read), an
    // EXISTS-only occurrence's cardinality PROBE. A REACHED bad body still
    // faults (parity both directions). (A bad inner column/relation is a
    // STRUCTURAL fault the outer `compile` already raised for EVERY subquery
    // before this runs, so it never reaches here — validation and run agree on
    // it regardless of the arm.)
    // A nested subquery's FROM resolves against base tables and enclosing CTEs,
    // NOT the enclosing SELECT's derived-table aliases — STRIP them (CTEs/store
    // kept) before type-checking/compiling each subquery, mirroring the compile
    // path's strip in `subquery(of:)`, so the schema path faults an outer
    // derived alias in a subquery's FROM exactly as the run does.
    let context = context.revealed()
    let scalar = select.scalar
    // EVERY scalar occurrence's operand check defers to the walk, keyed here
    // INDEPENDENTLY of a co-existing `IN`/`EXISTS` twin over identical SQL. A
    // valued/existential twin's eager arity/type derivation is TOTAL (no
    // `.divide` on `1 / 0`) and does not reproduce the scalar's operand fault,
    // and — now that an `IN`/`EXISTS` materialises LAZILY — a twin may itself
    // sit in an unreachable leg, so it cannot stand in for a REACHABLE scalar's
    // operand check. Deferring on `scalar` alone (not `scalar - valued`) records
    // the scalar's own `.scalar` reach in `type` even when a `.valued` reach for
    // the same query is also present — the two per-occurrence reaches must not
    // dedup the scalar away.
    let deferred = scalar
    var widths = Dictionary<Query, Int>()
    var types = Dictionary<Query, ValueType>()
    // Derive each SITE'S subqueries' cursor-free width and single-column type
    // against THAT site's own scope, keyed PER OCCURRENCE — a join `i`'s `ON`
    // against its PREFIX scope `prefixes[i]` (the relations AT that point, not
    // one joined LATER), the rest against the full `enclosing` — matching the
    // run's `subquery(of:)`. The SAME inner SQL in an `ON` and the WHERE
    // derives TWICE — each against its own site's scope — so a name a WHERE
    // subquery finds ambiguous in the full scope faults HERE, not the `ON`'s
    // narrower prefix. The OPERAND validation now DEFERS to the reachability
    // walk for EVERY site — an `ON` runs the SAME short-circuit walk the
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
    // The WHERE, `HAVING`, projection, and `ORDER BY` are walked by the
    // reachability phase, so their operand check DEFERS; their width and single-
    // column type still derive here against the full `enclosing` scope.
    var rest = Array<Query>()
    select.predicate?.collect(subqueries: &rest)
    select.having?.collect(subqueries: &rest)
    if case let .expressions(items) = select.projection {
      for item in items { item.expression.collect(subqueries: &rest) }
    }
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
    // Carry THIS select's own enclosing scope `context.outer` so its WHERE
    // type-check (`walk`) resolves a correlated column of THIS query against
    // the outer, matching the run's lowering; the projection/`HAVING` walk uses
    // `.barred` — a NO-OP for a LATERAL body (`everywhere`), whose projection
    // ISO puts the preceding references in scope for, so validation admits the
    // projected correlated column exactly as the run's lowering does.
    return SubqueryCheck(widths, types, deferred: deferred,
                         outer: context.outer, everywhere: context.lateral)
  }

  /// Records the cursor-free width and single-column type of `query` into
  /// `widths`/`types` against the `nested` outer scope, and enforces a scalar
  /// occurrence's single-column ARITY EAGERLY (reachability-independent, as the
  /// run's lowering does). Computed ONCE per distinct query at a given site.
  private borrowing func width(_ query: Query, _ scalar: Set<Query>,
                               _ context: Context, _ nested: Outer?,
                               _ widths: inout Dictionary<Query, Int>,
                               _ types: inout Dictionary<Query, ValueType>)
      throws(SQLError) {
    // The width and single-column type derive for EVERY subquery — cursor-free
    // and TOTAL for a clean-resolving inner query (deriving the type of `1 / 0`
    // yields the integer type WITHOUT dividing). A distinct query at ONE site is
    // derived once; the SAME query at ANOTHER site re-derives against ITS scope,
    // so a WHERE occurrence's ambiguity still faults there. The compile is
    // SHAPE ONLY, so LENIENT (`validate: false`): this pre-pass runs for EVERY
    // nested subquery ahead of the reachability walk, so validating a derived
    // body it nests — `1 IN (SELECT x FROM (SELECT 1 / 0 …) AS d)` — would
    // fault a subquery a short-circuited `AND`/`OR` leg drops BEFORE the walk
    // reaches it. Validation of a REACHED subquery's body (and the derived
    // tables nested within it, at any depth) is the walk's job — `typecheck(_
    // select:)` re-derives each reached occurrence's body strictly. Structural
    // faults (a bad inner relation/column, a UNION arity) still surface here —
    // those resolve regardless of `validate`.
    // Lower under `.caller`, this frame's `nested` outer, and shape-only
    // lenience (`validate: false`) — the schema pre-pass's cursor-free derive.
    let inner =
        context.scoped(as: .caller).with(outer: nested).validating(false)
    let width = try compile(query, inner).width
    let derived = try columns(of: query.first, inner).first?.type
    if widths[query] == nil {
      widths[query] = width
      types[query] = derived
    }
    // A scalar occurrence's single-column ARITY is enforced EAGERLY,
    // reachability-independent — a cursor-free width check the run's lowering
    // also makes — so a two-column scalar subquery in an unreachable arm STILL
    // faults `SQLError.arity`, kept SEPARATE from the deferred operand check.
    if scalar.contains(query), width != 1 {
      throw .arity(1, width)
    }
  }

  /// The subquery shape a run of the reached occurrence `reach` type-checks
  /// against — chosen from the occurrence's OWN reached ROLE, not the union of
  /// every role the query occupies in the select. A `scalar` reach (collapses
  /// the cell) or a `valued` one (`IN (Q)`, its value set read) EVALUATES the
  /// select list, so its ORIGINAL is type-checked; an `existential` reach
  /// (`EXISTS`) runs the cardinality PROBE (`Select.probe`: constant
  /// projection, `ORDER BY` dropped, original `OFFSET`/`FETCH` kept), never its
  /// select list — so its PROBED shape is checked, matching the run. So the
  /// SAME inner SQL reached ONLY as an `EXISTS` validates the probe even where
  /// an unreached arm has it as a scalar. A query the probe does not rewrite (a
  /// `HAVING` or set operation) runs in FULL, so its original is checked even
  /// for an `existential` reach.
  private borrowing func shape(of reach: Reach) -> Query {
    guard reach.role == .existential, case let .select(select) = reach.query,
        select.probable else {
      return reach.query
    }
    return .select(select.probe)
  }

  private borrowing func typecheck(_ select: Select, _ context: Context)
      throws(SQLError) {
    // This select's OWN resolution scope — the one its nested subqueries
    // CORRELATE against (`nil` for a FROM-less select, which adds no relations
    // and correlates through `outer` unchanged). Built from the UNREVEALED
    // `context` — correlation resolves against the enclosing scope's relations
    // (its derived aliases among them), unlike an inner subquery's own FROM,
    // which resolves against the REVEALED base below.
    let enclosing = select.from == nil
        ? nil : try scope(of: select, context)
    // The PREFIX scope of each join, the surface its `ON`'s subquery correlates
    // against — matching the run's `subquery(of:)`.
    let prefixes = try prefixes(of: select, context)
    // Type-check and compile every subquery ONCE, ahead of the reachability
    // walk: the pre-pass validates each `IN`/`EXISTS` inner query (never
    // short-circuited past) and derives every scalar subquery's cursor-free
    // arity and type (TOTAL — no `.divide` on `1 / 0`), but DEFERS a scalar
    // occurrence's inner-query OPERAND validation to the walk. Each nested
    // query's CORRELATION resolves against `enclosing` (a join `ON`'s against
    // its prefix) here, matching the run.
    let subquery = try subqueryCheck(of: select, context, enclosing: enclosing,
                                     prefixes: prefixes)
    // Walk the query's operands reachability-aware, so an unreachable
    // `CASE`/`COALESCE` arm's subquery is left unrecorded and unchecked.
    try walk(select, context, subquery: subquery, prefixes: prefixes)
    // Validate the inner query of each occurrence the walk REACHED — a scalar
    // or an `IN`/`EXISTS`/quantified one — in the RUN shape of ITS OWN reached
    // role: an `existential` reach the cardinality PROBE (never its select
    // list), a `scalar`/`valued` reach the ORIGINAL. The shape is chosen from
    // the occurrence's role, NOT the union of every role the query occupies in
    // the select — so the SAME inner SQL reached only as an `EXISTS` validates
    // the probe even where an UNREACHED arm has it as a scalar. Its correlated
    // columns resolve against THIS select's scope (nearest), stacked past
    // `outer` — mirroring the lazy executor. A reached `(SELECT 1 / 0 …)`
    // faults `.divide` here exactly as the run does, while an unreached one in
    // a skipped arm does not.
    //
    // A subquery's own FROM sees base tables and enclosing CTEs, NOT the
    // enclosing SELECT's derived-table aliases, so recurse against the REVEALED
    // base — the derived layers dropped, the CTEs/store (a shadowed CTE among
    // them) kept — while the correlation `outer` above still carries the
    // enclosing scope's ordinals.
    let revealed = context.revealed()
    let base = context.outer ?? Outer()
    let nested = enclosing.map { base.nested(under: $0) } ?? context.outer
    let inner = revealed.with(outer: nested)
    for reach in subquery.visited {
      try typecheck(shape(of: reach), inner)
    }
    // Each join `ON` runs through the SAME reachability/short-circuit walk the
    // WHERE does, but PREFIX-scoped: an `ON` predicate short-circuits its
    // `AND`/`OR` at run (`Scope.on` lowers the conjunction the join evaluator
    // steps), so a subquery a short-circuited leg never reaches is NOT
    // validated — `ON 1 = 0 AND 1 IN (SELECT 1 / 0 …)` does not fault, exactly
    // as the join never materialises it — while a REACHED `ON` subquery IS
    // validated (parity). The `ON`'s LOCAL scope is the join's PREFIX
    // (`prefixes[index]`, the relations AT that point, never one joined LATER),
    // so a correlated reference to a later-joined relation faults per that
    // prefix; its enclosing `outer` stays the select's, so a correlated `ON`
    // subquery column resolves against THAT prefix stacked past the outer,
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

  /// Walks the operands of `select` reachability-aware — the SAME order and
  /// short-circuit rules the executor applies — validating each operand a run
  /// would evaluate and RECORDING (via `subquery`) each scalar subquery it
  /// reaches, so the caller validates only the reached scalars' inner queries.
  private borrowing func walk(_ select: Select, _ context: Context,
                              subquery: SubqueryCheck,
                              prefixes: Array<Scope> = [])
      throws(SQLError) {
    let routines = context.routines
    let scope = try scope(of: select, context)
    // The WHERE admits a correlated column of THIS query (`subquery`); the
    // projection, `HAVING`, and `ORDER BY` bar it (`barred`), diagnosing the
    // unsupported correlated-projection/HAVING case exactly as the run's
    // lowering does.
    let barred = subquery.barred
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
      try order(grouped: select, scope, context, prefixes: prefixes)
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
              try scope.fold(item.expression, routines, subquery: barred)
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
            try scope.fold(expression, routines, subquery: barred)
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
        try scope.aggregates(in: item.expression, routines, subquery: barred)
      }
    }
    for expression in select.orderKeys {
      try scope.aggregates(in: expression, routines, subquery: barred)
    }
    if let having = select.having {
      try scope.aggregates(in: having, routines, subquery: barred)
      try scope.check(having, routines, subquery: barred)
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
        _ = try scope.validate(item.expression, routines, subquery: barred)
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
      _ = try scope.validate(expression, routines, subquery: barred)
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
                               _ context: Context,
                               prefixes: Array<Scope> = [])
      throws(SQLError) {
    guard let clause = select.order else { return }
    let routines = context.routines
    // A grouped aggregate's argument or FILTER may nest a subquery (`ORDER BY
    // SUM(CASE WHEN EXISTS (Q) …)`), which lowering resolves against the
    // materialised map, so build the select's subquery seam ONCE here — the
    // same one the run's `group` builds — for this structural resolve to lower
    // those aggregates exactly as the run does. It threads the SAME
    // `enclosing`/`outer`/`prefixes` the run path passes, so a CORRELATED inner
    // query (`WHERE S.k = T.k`) resolves its outer column here exactly as at
    // run, rather than compiling with no enclosing scope and faulting
    // `SQLError.column`.
    let subquery = try subquery(of: select, context.scoped(as: .caller),
                                enclosing: scope, prefixes: prefixes).rest
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
    var grouping = try Grouping(scope, select.grouping, aggregations,
                                subquery: subquery)
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
                        preceding: Scope? = nil)
      throws(SQLError) -> Schema {
    let name = relation.name
    // A LATERAL derived table is not bound in the overlay (it is never
    // materialised once as a constant), so derive its schema through the SAME
    // derived-body machinery a non-lateral body uses (`materialise`, `rows:
    // false`) — over the REVEALED base (base + CTEs + store, its own alias out
    // of scope), so a body naming a CTE resolves it, exactly as a non-lateral
    // body does.
    //
    // Per ISO a LATERAL body's preceding-FROM references are in scope
    // throughout its query expression, INCLUDING the SELECT list, so its output
    // SHAPE is NOT correlation-independent — a projected preceding column
    // (`SELECT T.Id AS id`) types from that outer column. So the schema derive
    // THREADS the `preceding` scope as the correlation stack (`with(outer:)`)
    // and marks the body a lateral one (`lateralizing`), the SAME
    // revealed-base-with-outer context `compile(select)`'s `lateral` compiles
    // it under — schema, validation, and compile share it, so a projected
    // preceding column derives its type here exactly as the run lowers it to a
    // bound parameter. `validate: false` keeps the derive lenient; the strict
    // operand/function type-check rides through `compile(select)`'s `lateral`
    // path where the `validate` gate is honoured, so it is not duplicated here.
    if relation.lateral, case let .derived(query) = relation.source {
      let stack = context.outer ?? Outer()
      let nested = stack.nested(under: preceding ?? Scope([]))
      let scope = context.revealed().with(outer: nested)
          .lateralizing().validating(false)
      return try materialise(query, scope, rows: false).schema()
    }
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
      if context.visited.contains(name.lowercased()) { return base }
      // Type-check the body's REACHABLE operands and calls across every arm and
      // clause — `compile` cannot check a routine EXISTS, the first-arm resolve
      // below sees only the first projection, and the outer query's walk does
      // not reach into a body. `typecheck` faults an unknown call or a bad
      // operand a `SELECT * FROM v` run would evaluate — a `WHERE`/`HAVING`, a
      // later `UNION` arm — while skipping an arm a short-circuit proves
      // unreachable.
      // The view name enters `visited` BEFORE its body's derived tables
      // materialise, so a derived table naming this view (`FROM (SELECT * FROM
      // <self>) AS d`) re-enters with the view already visited and faults
      // `.recursion` rather than recursing to a stack overflow — the guard
      // rides through `augment`/`materialise` into the derived body.
      // `body([:])` enters the view-body scope with the caller's correlation
      // stack CLEARED: a view is defined independently of its call site, so an
      // unbound column in the DEFINITION must fault — NOT bind to an enclosing
      // row — when the view's schema is derived from inside a correlated
      // subquery, keeping this derivation consistent with `resolve`/`compile`.
      let overlay =
          try augment(context.body([:]).visiting(name), for: view.query,
                      rows: false)
      // Gate the body's reachable-operand check on `context.validate`: a
      // `validate: false` derive skips it, so a data-dependent-empty body (a
      // text arithmetic under an unmatched filter) does not fault a `SELECT *`
      // over the view that already ran to its (empty) result. It also rides
      // into the recursive derive so a view over a view stays derive-only.
      if context.validate {
        try typecheck(view.query, overlay)
      }
      // Type off the body's first arm (the ISO rule for a UNION). Arity — the
      // body's width against the declared columns — is `compile`'s job (the
      // public entry runs it), so on a shortfall fall back to the declared
      // schema rather than re-checking it here.
      let resolved = try columns(of: view.query.first, overlay)
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
                        _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<OutputColumn> {
    return switch projection {
    case .all:
      outputs()
    case let .columns(references):
      try references.map { column throws(SQLError) in
        try output(of: column, subquery: subquery)
      }
    case let .expressions(items):
      try items.indices.map { index throws(SQLError) in
        try output(items[index], at: index, routines, subquery: subquery)
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
  /// spelling as written), typed from the relation that resolves it — or, for a
  /// name no local relation binds, from the correlation `subquery` surface,
  /// mirroring the expression path's `derive`. Under a LATERAL body's admitting
  /// (`everywhere`) surface a preceding-FROM column types as its outer column;
  /// under an ordinary barred surface it faults `.unsupported`. A genuinely
  /// unknown name re-throws the `.column` fault.
  internal func output(of column: Column,
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> OutputColumn {
    if let ordinal = try find(column) {
      return OutputColumn(name: column.name, type: type(at: ordinal))
    }
    if let type = try subquery.correlated(column) {
      return OutputColumn(name: column.name, type: type)
    }
    return try OutputColumn(name: column.name,
                            type: type(at: ordinal(of: column)))
  }

  /// The output column a projected `item` at 0-based `index` yields: its
  /// inferable output name (`Projected.name` — an alias, else a bare column's
  /// name), else a positional `column N` (1-based). A bare column carries its
  /// source type and a literal its own; a scalar call its routine's declared
  /// return type; every other expression `.integer`.
  internal func output(_ item: Projected, at index: Int,
                       _ routines: Routines = [:],
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> OutputColumn {
    let name = item.name ?? "column \(index + 1)"
    // DERIVE the nominal output type: the schema reports the type a run would
    // produce and never faults on an operand. Run-time operand and call
    // validation is `typecheck`'s job, reachability-aware, so a schema resolves
    // even for an expression a zero-row limit makes unreachable. A scalar
    // subquery derives its single-column type from the `subquery` map.
    return try OutputColumn(name: name,
                            type: derive(item.expression, routines,
                                         subquery: subquery))
  }
}
