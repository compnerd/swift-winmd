// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// The query engine — the compiler, optimiser, and executor for a `SELECT`.
//
// The engine runs a `SELECT` entirely against the adapter protocols, with no
// knowledge of any data source. It resolves the relation(s) through a borrowed
// `Catalog`, *compiles* a logical operator tree, *optimises* it into a physical
// one, and *executes* that. Each phase borrows the catalog: `compile`
// re-resolves each relation by name to a transient `~Escapable` table to read
// its schema (width, ordinals, the set of ordinals the query references) and
// emits a name-holding `Plan`; `optimise` re-resolves to read sort-key
// seekability and rewrites scans into seeks and the product into an
// index-nested-loop join; `execute` re-resolves to open cursors and
// materialise. A single relation compiles to `Project(Sort(Select(Scan)))`; a
// chain of joins compiles to a left-deep tree of `Product`s, each level's `ON`
// equality a `Select` over its product, with the `WHERE` wrapping the whole
// chain. Absent layers are omitted. Executing the plan yields the result
// records' typed values; formatting them is a client's job. The compile,
// optimise, and execute entry points are `Catalog` members.

/// The greatest number of fixpoint iterations a recursive CTE may take before
/// the engine concludes it does not terminate and throws `SQLError.recursion`.
private let kRecursionCap = 10_000

// MARK: - Execution

extension Catalog where Self: ~Escapable {
  /// Runs `query` against this catalog, returning the projected, filtered, and
  /// ordered rows as typed values.
  ///
  /// A bare `SELECT` runs as before; a `UNION` runs each arm through the same
  /// compile/optimise/execute with the same `bindings` and `routines`, then
  /// concatenates the rows in source order — `UNION ALL` keeps every row, a
  /// bare `UNION` removes whole-row duplicates (first occurrence kept). The
  /// plan is binary and mirrors the left-associative chain, so each
  /// `UNION`/`UNION ALL` honours its own flag — `(A UNION B) UNION ALL C`
  /// dedups `A ∪ B` before appending `C`. The result columns are the first
  /// arm's projection (the ISO rule); each arm keeps its own `ORDER BY`,
  /// applied before the union.
  ///
  /// - Throws: `SQLError.relation` if the catalog resolves no such relation,
  ///   `SQLError.column` if a referenced column is absent, `SQLError.ambiguous`
  ///   if an unqualified name is resolved by more than one relation of a chain,
  ///   `SQLError.arity` if a `UNION`'s arms project differing column counts.
  public borrowing func run(_ query: Query, _ routines: Routines,
                            bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    // The engine is pure: it resolves calls against exactly the `routines`
    // given, seeding no prelude of its own. `import SQLStandard` adds a
    // prelude-defaulting overload (`run(_:bindings:)` — see `SQLStandard`),
    // so a call under that module reaches the built-ins without naming them.
    try run(query, Context(routines: routines, bindings: bindings))
  }

  /// Runs `query` against this catalog under `context` — the in-scope common
  /// table expressions (empty for a query with no `WITH`), the routines, and
  /// the bindings — the resolution phases consulting the overlay before the
  /// base catalog.
  internal borrowing func run(_ query: Query, _ context: Context)
      throws(SQLError) -> Array<Array<Value>> {
    // Expand any `GROUP BY GROUPING SETS` select to its `UNION ALL` FIRST, so
    // every downstream phase — the arm-wise run below, the compile preflight,
    // and the derived-table materialise/augment — sees the expanded AST, and a
    // run and a `columns(of:)` derive cannot diverge. Idempotent for a
    // `.keys`/`.arm` select; a nested body re-enters and expands in turn.
    let query = try query.expanded
    // A set operation runs each ARM against its own scope and combines the
    // results, rather than materialising both arms' derived tables into one
    // shared overlay the executor scans by name. Both arms bind their aliases
    // in one map, so a right arm's `derived T` would shadow a left arm's base
    // (or CTE) `T` at the leaf scan — the executor keys a `.scan` by name and
    // cannot tell the two `T`s apart. Running per arm scopes each arm's derived
    // tables to that arm: the left arm's `FROM T` scans the base relation and
    // the right arm's its own derived one, then `combine` merges them under the
    // operator's duplicate rule. The arity across arms is checked as `compile`
    // resolves the whole query below.
    if query.carriers.isEmpty, case let .setop(kind, left, right, all) = query
        .body {
      // Validate the whole query (per-arm resolution and the cross-arm arity
      // check) exactly as a single select does, then run each arm on its own —
      // each arm's `run` threads its own lazy subquery box. `validate: false` —
      // the preflight must not eager-type-check a derived body a data-dependent
      // filter never reaches (execution faults only on a reached operand),
      // matching the non-derived path.
      _ = try compile(query, context.validating(false))
      // Fault a statically-typed incomparable comparison at compile — in either
      // arm — so the run agrees with the validate walk regardless of arm
      // cardinality, and the optimiser never hashes, reorders, or drops a
      // comparison that would throw at run. It runs only the comparability
      // portion of the type-check (`Scope.comparability`), leaving every other
      // operand fault to the arms' execution.
      try typecheck(query, context.validating(false).comparing())
      // The result column types are unified across the arms (ISO), so coerce
      // each arm's values to them — `SELECT 1 UNION SELECT 2.5` emits a
      // `double` column. The fold reads the arm queries in hand here; the
      // Plan-node path carries the same types precomputed at compile.
      let types = try types(unifying: query, context.validating(false))
      let combined = try combine(kind, run(left, context).map(Record.init),
                                 run(right, context).map(Record.init), all,
                                 types: types)
      return combined.map(\.values)
    }
    // Build the optimised physical plan, then run it. `optimised` is the single
    // source of the compile → pushdown → decorrelate → optimise walk, so
    // `EXPLAIN` (`plan(of:)`) inspects exactly the plan this execute runs — the
    // two cannot drift. It returns the augmented context alongside the plan so
    // the execute below reads the same materialised derived tables and shared
    // subquery box the plan was built against.
    let (plan, augmented) = try optimised(query, context, rows: true)
    // A query-level `ORDER BY`/`DISTINCT`/`OFFSET`·`FETCH` over a set operation
    // — the `ordered` carrier — must run its inner union per ARM, as the direct
    // `run(.setop)` above does: each arm augments its own arm-local derived
    // aliases (arms are SELECT-scoped, so the query-level augment misses them)
    // before its `.scan` reads them, then the arms `combine`. Executing the
    // compiled carrier plan under the single carrier context instead would
    // never materialise an arm's derived table, faulting `.relation`. Route the
    // execute through the carrier descent, which threads the inner union's arm
    // queries to the setop leaf and runs `arms` there — the same per-arm
    // machinery — leaving the sort/dedup/limit/project stack above unchanged.
    if !query.carriers.isEmpty, case .setop = query.body {
      return try execute(plan, carrying: query.core, augmented).map(\.values)
    }
    // A carrier over a bare `SELECT` (a parenthesised simple query with an
    // outer tail — `(SELECT …) ORDER BY …`) has no set-operation arms to
    // augment, so its `.shaped` plan runs through the plain executor; only a
    // carrier over a `.setop` needs the per-arm carrier descent above.
    return try execute(plan, augmented).map(\.values)
  }

  /// Builds the optimised physical `Plan` for `query` under `context`, running
  /// the full compile → pushdown → decorrelate → optimise pipeline the executor
  /// uses — the single source of that walk, shared by `run` and by the
  /// diagnostic `plan(of:)` (so `EXPLAIN` inspects exactly the plan a run
  /// executes).
  ///
  /// It threads a fresh subquery cache — a shared box — through compile and
  /// the returned context, so the executor's row evaluator (which runs a nested
  /// subquery on first reach, memoising an uncorrelated occurrence and
  /// re-executing a correlated one per outer row) reads the correlated inner
  /// plans compile stashed. Compile validates the whole query schema-only
  /// (`rows: false`, `validate: false`) before any row materialises; the
  /// comparability walk faults a statically cross-kind comparison the optimiser
  /// could otherwise hide; `augment` extends the overlay with any
  /// `definition_schema.` store relation and — when `rows` — materialises this
  /// query's derived tables; `decorrelate` rewrites a decorrelatable correlated
  /// CROSS APPLY into a set-based join; and `optimise` rewrites scans into
  /// seeks and products into index-nested-loop/hash joins.
  ///
  /// `rows` is `true` for `run` (the execute below reads the materialised
  /// derived tables) and `false` for the diagnostic `plan(of:)`, which must not
  /// execute: materialising a derived table calls `run` on its body, so a
  /// stateful routine or a throwing derived expression would fire under
  /// `EXPLAIN` — which stops before execution. The plan shape is identical
  /// either way (the physical pass reads base-table cursors and derived
  /// schemas, never materialised derived rows).
  ///
  /// A set operation — bare or under a carrier — optimises per arm
  /// (`optimise(_:_:_:)`), since each arm scans its own arm-local derived
  /// aliases the top-level scope does not bind; every other shape uses the
  /// generic optimiser. `run` reaches this with a set-operation query only
  /// under a carrier (it runs a bare set operation's arms directly, above); the
  /// plan-only `plan(of:)` reaches it with a bare set operation too, so both
  /// take the per-arm path here. The augmented context is returned beside the
  /// plan so a caller's execute reads the same materialised tables and subquery
  /// box.
  internal borrowing func optimised(_ query: Query, _ context: Context,
                                    rows: Bool)
      throws(SQLError) -> (plan: Plan, augmented: Context) {
    let context = context.resolving(Subqueries())
    let logical =
        try compile(query, context.validating(false)).demoted().pushdown()
    try typecheck(query, context.validating(false).comparing())
    let augmented = try augment(context.validating(false), for: query,
                                rows: rows)
    augmented.subqueries.record(overlay: augmented.revealed().relations,
                                for: .caller)
    // A carrier-free set operation runs each arm separately under its own
    // augmented scope — arms are SELECT-scoped, binding arm-local derived
    // aliases the shared context does not — so decorrelate and optimise it per
    // arm too: recurse through `optimised` (the same pipeline `run` drives per
    // arm) and recombine with the compiled unified types and widened mask.
    // Decorrelating on the shared context instead would bail on an arm's
    // correlated subquery, the arm alias unbound, where a per-arm run
    // decorrelates it — so the inspected plan would differ from the executed
    // one. `run` reaches a bare set operation through its own per-arm path and
    // never through this helper, so this affects only the plan-only path.
    if query.carriers.isEmpty,
        case let .setop(kind, left, right, all) = query.body,
        case let .setop(_, _, _, _, types, widened) = logical {
      let leftPlan = try optimised(left, context, rows: rows).plan
      let rightPlan = try optimised(right, context, rows: rows).plan
      return (.setop(kind, leftPlan, rightPlan, all: all, types: types,
                     widened: widened), augmented)
    }
    let decorrelated = try decorrelate(logical, augmented)
    let plan: Plan
    if case .setop = query.body {
      plan = try optimise(decorrelated, query.core, augmented)
    } else {
      plan = try optimise(decorrelated, augmented)
    }
    return (plan, augmented)
  }

  /// The optimised physical `Plan` for `query` under `context` — the plan the
  /// executor would run, built without executing it. This is the testable
  /// plan-inspection entry `EXPLAIN` renders: it runs the same compile →
  /// pushdown → decorrelate → optimise pipeline as `run`, sharing `optimised`,
  /// but stops short of the final `execute`.
  ///
  /// A `GROUP BY GROUPING SETS` query is expanded first (idempotent), as
  /// `run`/`compile` normalise it, so the inspected plan matches the run's.
  ///
  /// Augments schema-only (`rows: false`): unlike `run`, inspecting a plan must
  /// not materialise a derived table (which would `run` its body), so a
  /// stateful routine or a throwing derived expression never fires here.
  internal borrowing func plan(of query: Query, _ context: Context)
      throws(SQLError) -> Plan {
    try optimised(query.expanded, context, rows: false).plan
  }

  /// Runs a `Statement` against this catalog, returning its result rows.
  ///
  /// A `select` runs its query directly; a `with` materialises its common table
  /// expressions, in source order, into the `ScopedRelations` the trailing
  /// query resolves against (see `with`). A `create` defines a view and a
  /// `function` a scalar function rather than producing rows, so neither is
  /// runnable — both fault with `SQLError.statement`.
  public borrowing func run(_ statement: Statement, _ routines: Routines,
                            bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    // Pure engine: it uses exactly `routines` (see the query overload);
    // `import SQLStandard` re-defaults the prelude via an overload.
    let context = Context(routines: routines, bindings: bindings)
    return switch statement {
    case let .select(query):
      try run(query, context)
    case let .explain(query):
      try explain(query, context)
    case let .with(ctes, query):
      try with(ctes, query, context)
    case .create:
      throw .statement("CREATE VIEW defines a view rather than producing rows")
    case .function:
      throw .statement("CREATE FUNCTION defines a function rather than rows")
    }
  }

  // MARK: - WITH

  /// Materialises the common table expressions `ctes`, in source order, into
  /// the `ScopedRelations` map and runs the trailing `query` against this
  /// catalog with that map in scope.
  ///
  /// Each CTE materialises against the base catalog plus every earlier CTE,
  /// so a CTE may name one defined before it (chained CTEs); a CTE name shadows
  /// a base relation of the same name (the resolver consults the map first). A
  /// recursive CTE — one that names itself in its own query — iterates a
  /// fixpoint (see `fixpoint`); every other CTE, including one a `WITH
  /// RECURSIVE` marks recursive but which does not reference itself, runs its
  /// query once and captures its rows. The fully materialised relations then
  /// resolve the trailing query, run through the same `routines` and
  /// `bindings`.
  ///
  /// Each CTE's body must project exactly the arity its column list declares —
  /// the resolver advertises `cte.columns.count` columns, so a body of a
  /// different width would index out of bounds when a later query reads it. The
  /// body's width is known once it compiles (a `SELECT *` resolves its extent
  /// against the relations in scope), so its compiled `Plan.width` is checked
  /// against the declared count before the CTE materialises — regardless of how
  /// many rows the body yields. A body filtered to zero rows still faults with
  /// `SQLError.columns`, where a per-row check would pass it through vacuously.
  internal borrowing func with(_ ctes: Array<CTE>, _ query: Query,
                               _ context: Context)
      throws(SQLError) -> Array<Array<Value>> {
    // Type AND materialise the CTEs into the overlay through the one producer
    // (`rows: true`) the schema path also drives, then run the trailing query
    // against it — the CTE walk lives in `typed(ctes:in:rows:)`, so a per-CTE
    // step cannot be added to a run loop and forgotten on the schema one.
    let relations = try typed(ctes: ctes, in: context, rows: true)
    return try run(query, context.body(relations))
  }

  /// Types the common table expressions `ctes` into a `ScopedRelations` overlay
  /// — the single statement-level CTE walk both the run (`with`) and the
  /// schema-only (`columns(of:with:)`) paths consume, so a per-CTE step lives
  /// in one place and cannot be added to one loop and forgotten on the other.
  ///
  /// It walks `ctes` in source order, binding each into the growing overlay the
  /// next resolves against (so a later CTE names one before it, and a CTE
  /// shadows a same-named base relation). Per CTE it:
  ///
  /// 1. rejects a case-insensitive redefinition — a name repeated in the list
  ///    would silently shadow the earlier binding, so it faults
  ///    `SQLError.redefinition` rather than overwrite (a typo in a multi-CTE
  ///    query must not change the result);
  /// 2. validates the CTE's shape and arity against the CTEs done so far — the
  ///    compile-time structural check `validate` runs. This gate is the one
  ///    legitimate run-vs-schema difference, and it now lives here: the run
  ///    (`rows: true`) ALWAYS validates and passes `typecheck: false` — it
  ///    defers the reachable-operand check to execution — while a schema derive
  ///    (`rows: false`) validates ONLY when its context's `validate` gate is
  ///    set (a post-run `validate: false` derive trusts the bodies) and then
  ///    strictly (`typecheck: true`), faulting an ill-typed body statically;
  /// 3. computes the column carrier once. On the run path a self-referential
  ///    CTE iterates a `fixpoint` (which returns both its rows and their
  ///    unified carrier); every other CTE runs its query once and re-derives
  ///    the carrier trusted (`validating(false)`, so an unreached data-
  ///    dependent operand is not eager-checked while a genuine set-operation
  ///    incompatibility still faults through `kinds`'s `merge` fold). On the
  ///    schema path `kinds`
  ///    derives the carrier for either kind without iterating — its recursive
  ///    branch (`contributions`) folds anchor ⊕ recursive the same way
  ///    `fixpoint` does;
  /// 4. binds the carrier as `RelationInstance(from:, rows:)`, with the rows
  ///    on the run path and none on the schema path. Both paths accumulate the
  ///    overlay identically — same names, types, and
  ///    `unconstrained` mask — differing ONLY in the captured rows, which is
  ///    safe because downstream typing reads names/types/mask, never rows. The
  ///    carrier feeds the same `init(from:)`, so the schema-only self and the
  ///    materialised binding cannot diverge.
  internal borrowing func typed(ctes: Array<CTE>, in context: Context,
                                rows: Bool)
      throws(SQLError) -> ScopedRelations {
    var relations = ScopedRelations()
    for cte in ctes {
      guard relations[cte.name.lowercased()] == nil else {
        throw .redefinition(cte.name)
      }
      // The scope for this CTE's body: the base catalog plus every earlier CTE,
      // over the run's routines and bindings. `body(_:)` enters this fresh
      // statement-scoped body with the correlation stack cleared — a CTE is
      // resolved independently of any call site (a `WITH` is statement-level,
      // so the stack is already empty here; routing through `body(_:)` keeps
      // the clear intrinsic to entering a body scope rather than incidental).
      let scope = context.body(relations)
      // The compile-time structural check, shared with the dry-run schema path
      // so a derive rejects exactly the CTEs a run rejects. It faults the
      // recursive shape and the width mismatch before any rows materialise. The
      // run ALWAYS validates (`typecheck: false` — it defers the operand check
      // to execution); the schema derive validates ONLY when its context's gate
      // is set — a `validate: false` derive after a run trusts the bodies (the
      // run already proved them consistent) — and then strictly (`typecheck:
      // true`). This gate is the one legitimate run-vs-schema difference.
      if rows || context.validate {
        try validate(cte, against: scope, typecheck: !rows)
      }
      let materialised: Array<Array<Value>>
      let carrier: Array<ResolvedColumn>
      if rows {
        // A CTE that names itself iterates a fixpoint; every other one runs its
        // query once. The arity of both routings is already checked above.
        if cte.recursive, try cte.recurses {
          (materialised, carrier) = try fixpoint(cte, scope)
        } else {
          materialised = try run(cte.query, scope)
          // The body already ran, so re-derive its carrier trusted — the same
          // `kinds` call the fixpoint's non-recursive tail routes through, so
          // no inline carrier construction diverges from it.
          carrier = try kinds(of: cte, scope.validating(false))
        }
      } else {
        // The schema derive materialises no row; `kinds` types either CTE kind
        // without iterating (its recursive branch folds anchor ⊕ recursive the
        // way `fixpoint` does), under the incoming validate gate.
        materialised = []
        carrier = try kinds(of: cte, scope)
      }
      // Both routings feed the same carrier into `init(from:)`, so the
      // schema-only self and the materialised binding cannot diverge.
      relations[cte.name.lowercased()] =
          RelationInstance(from: carrier, rows: materialised)
    }
    return relations
  }

  /// Validates the shape and declared arity of a single common table expression
  /// `cte` against the base catalog plus the CTEs done so far (`ctes`), without
  /// materialising a row — the compile-time structural check `with` runs before
  /// each CTE materialises, factored out so the dry-run result-schema path
  /// (`columns(of:with:)`) validates a `WITH` by the same code a run does,
  /// ending the divergence between the two.
  ///
  /// It reproduces, without executing, the two structural faults `with` and
  /// `fixpoint` raise:
  ///
  /// - The RECURSIVE shape. A `WITH RECURSIVE` member's recursive reference
  /// must be its final `UNION` arm — the engine's model is anchor members then
  /// one recursive arm. A reference to the CTE's own name in an earlier arm
  /// resolves against the base scope (the CTE is not in scope outside the
  /// recursive arm), so a same-named base or view is a valid seed; but with no
  /// such base/view the reference can only be a misplaced recursive arm —
  /// recursion before the final arm, or a second recursive arm — a shape the
  /// engine does not support, faulted `SQLError.unsupported`.
  ///
  /// - The declared arity. Each CTE body must project exactly the arity its
  /// column list declares, or a later reader indexes out of bounds. The body's
  /// width is known once it compiles — never opening a cursor — so the compiled
  /// `Plan.width` is checked against the declared count, faulting
  /// `SQLError.columns` on a mismatch. A recursive (self-naming) CTE checks its
  /// anchor (self NOT in scope) and its RECURSIVE arm (self bound to the
  /// declared columns) separately, exactly as `fixpoint` does; every other CTE
  /// checks its whole body with self NOT in scope. This is why the schema path
  /// must NOT bind the CTE's self for the whole body: a `WITH RECURSIVE t(n) AS
  /// (SELECT n FROM t UNION SELECT n FROM t)` faults the recursive shape here —
  /// self is not in scope in the anchor — rather than resolving a
  /// self-reference the run would reject.
  ///
  /// The reachable-operand type-check the schema path also wants is NOT part of
  /// the shape/arity check the run relies on — the run defers it to execution.
  /// It rides in through `typecheck`: the run path passes `false` (it defers),
  /// the schema path passes `true` (it must fault an ill-typed body
  /// statically). Folding it here rather than layering it in the schema path
  /// keeps one per-arm scoping for both the structural check and the operand
  /// check — a recursive CTE's anchor is operand-checked against base + prior
  /// CTEs (self NOT in scope, the scope the run evaluates the anchor in), NOT
  /// the CTE-self overlay, so `SELECT Name + 1 FROM People` in the anchor
  /// faults `SQLError.operand` against the base `People` a run reads it
  /// against, never wrongly types clean against the CTE's declared columns.
  ///
  /// `typecheck` also gates the eager type-check of a derived body the CTE
  /// body nests: the arity `augment`/`compile` below thread `validate:
  /// typecheck` so a run (`typecheck: false`) derives a `FROM (SELECT …) AS d`
  /// leniently — a data-dependent body expression a filter drops (`FROM (SELECT
  /// Label + 1 AS x FROM K WHERE k = 0) AS d`) is trusted, not rejected, as
  /// the non-`WITH` and `WITH`-trailing paths already do — while the schema
  /// path (`typecheck: true`) keeps the strict body type-check.
  internal borrowing func validate(_ cte: CTE, against context: Context,
                                   typecheck: Bool = false)
      throws(SQLError) {
    // Reject a misplaced recursive reference in an earlier arm when no
    // same-named base/view can seed it — the shape `with` rejects before
    // routing to the fixpoint.
    if cte.recursive,
        case let .setop(.union, anchor, _, _) = try cte.canonical.inner.body,
        anchor.references(cte.name.lowercased()),
        case nil = table(named: cte.name),
        case nil = view(named: cte.name) {
      throw .state("0A000",
                   "recursive WITH references the CTE outside its final " +
                   "UNION arm")
    }
    // A recursive body that is a non-UNION set operation (`EXCEPT`/`INTERSECT`)
    // referencing itself has no recursive arm to iterate: `recurses` matches
    // only a `.union` core, so this body would take the run-once path and
    // compile with the CTE self unbound, faulting a generic `SQLError.relation`
    // on the self reference. ISO 9075 permits recursion only through
    // `UNION [ALL]`, so fault the precise `0A000` feature diagnostic instead —
    // unless a same-named base/view seeds it (then the reference reads that
    // relation and the body runs once, as the misplaced-anchor guard allows).
    let core = try cte.canonical.inner
    if cte.recursive,
        case let .setop(kind, _, _, _) = core.body, kind != .union,
        core.references(cte.name.lowercased()),
        case nil = table(named: cte.name),
        case nil = view(named: cte.name) {
      throw .state("0A000", "recursion requires UNION [ALL]")
    }
    // Check the declared arity by compiling the body — never a cursor. A
    // recursive (self-naming) CTE checks its anchor and recursive arm the way
    // `fixpoint` does: the anchor with self NOT in scope, the recursive arm
    // with self bound to the declared columns. Every other CTE checks its whole
    // body with self NOT in scope. When `typecheck`, the reachable-operand
    // check runs in the same per-arm scope each arity check uses, so the
    // operand check shares the run's arm scoping and never types an anchor
    // against the CTE-self overlay. `recursiveArms`/`canonical` peel the same
    // canonical (unwound) shape the run's `fixpoint` and the schema
    // `contributions` do, so all three inspect the identical AST.
    if let (anchor, recursive, _) = try cte.recursiveArms {
      let carriers = try cte.canonical.carriers
      let scope = try augment(context.validating(typecheck), for: anchor,
                              rows: false)
      let width = try compile(anchor, scope).width
      guard width == cte.columns.count else {
        throw .columns(expected: width, got: cte.columns.count)
      }
      // The anchor is operand-checked with self NOT in scope — the scope the
      // run evaluates it in — so a text-arithmetic anchor faults against the
      // base relation, not the CTE's declared (integer) columns.
      if typecheck { try self.typecheck(anchor, scope) }
      // Check the recursive arm's width against the declared list before any
      // `kinds` derive — an arm degree differing from the list is the declared-
      // arity fault, and it must win in the ISO order (`expected: arm, got:
      // declared`) on both paths. A width check needs only the self's COLUMN
      // COUNT, not its types, so bind the self under the placeholder-typed
      // `declared` carrier here: `kinds` would otherwise fold the arms and
      // raise its own inter-arm count fault (`expected: anchor, got: arm`) in
      // the reverse order first, re-diverging the schema path from the run.
      // Measure the arm non-validating even on the schema path: `augment`
      // materialises a derived body in the arm eagerly, and validating it here
      // would type-check its operands against the placeholder-typed self (the
      // `.integer` carrier), spuriously faulting a runnable arm whose self is
      // really text. Arity is structural, so the width guard still fires; the
      // genuine recursive-arm operand type-check happens later, under the
      // `kinds`-rebound unified carrier where the self carries its real types.
      let sized = RelationInstance(from: cte.declared, rows: [])
      let measured = context.binding(cte.name, to: sized)
                            .validating(false)
      let widened = try augment(measured, for: recursive, rows: false)
      let arm = try compile(recursive, widened).width
      guard arm == cte.columns.count else {
        throw .columns(expected: arm, got: cte.columns.count)
      }
      // Both widths match, so — ONLY on the schema path — type-check the
      // recursive arm with the CTE self bound under the unified (anchor ⊕
      // recursive) column carrier `kinds` derives: the same carrier `fixpoint`
      // binds the iterated self under (the rows every step reads are coerced to
      // those types). Typing the self at the anchor-only types while the run
      // reads the widened unified types would let schema validation call a
      // query "valid" that the run mistypes (an integer-anchor self a widening
      // recursive arm reads as `double`); `kinds` folds it recursive-aware, so
      // a genuine irreconcilable arm pair faults here as the run's own fold
      // rejects it. The run path defers this operand check to execution, so it
      // needs neither the derive nor the self binding — the width guard above
      // is the whole of its arity check. Feeding the carrier through
      // `init(from:)` means this self binding and the run-iteration one cannot
      // diverge.
      if typecheck {
        let seeded = try kinds(of: cte, context.validating(typecheck))
        let empty = RelationInstance(from: seeded, rows: [])
        // Bind the CTE self before augmenting the recursive arm, so a derived
        // body in the arm naming the CTE (`FROM (SELECT n FROM a) AS d`)
        // resolves it — `augment` materialises derived bodies eagerly, so the
        // self must be in scope by then, not bound only afterwards.
        let bound = context.binding(cte.name, to: empty).validating(typecheck)
        let probe = try augment(bound, for: recursive, rows: false)
        // The recursive arm is operand-checked with self bound to the declared
        // columns — the schema every iteration reads the CTE under.
        try self.typecheck(recursive, probe)
        // Validate the peeled carrier's `ORDER BY` keys the same way the run
        // path resolves them (`fixpoint`/`apply`): against the body's FIRST-ARM
        // set-op output scope, through the ordinary `SELECT * FROM <temp> ORDER
        // BY …` machinery over an empty temp of those output columns. A key
        // naming a missing column or function faults here on the schema path as
        // it faults the run, closing the run-vs-validate gap where a carrier
        // `ORDER BY missing(n)` passed `columns(of:validate:true)` yet the run
        // faulted `.function('missing')` when `apply` resolved it after the
        // fixpoint. The declared rename rides the CTE binding after the
        // carrier, so — as the run does — the carrier resolves the body's
        // output names.
        if !carriers.isEmpty {
          // A set operation names its output off its FIRST arm (the ISO rule),
          // so each carrier's `ORDER BY` resolves against the anchor's output
          // names — resolved with the CTE self NOT in scope, so the anchor's
          // own names/types derive without faulting `.relation` on the
          // recursive arm's self reference. (Unifying the whole `body` would
          // need the self bound to fold the recursive arm.) Stacked carriers
          // all page and order the same set-op output, so each validates it.
          let outputs = try columns(unifying: anchor, scope)
          for carrier in carriers {
            try validate(carrier: carrier, over: outputs, arm: anchor.arm,
                         context.validating(true))
          }
        }
      }
    } else {
      // Validate the same expanded AST a run does: a `GROUP BY GROUPING SETS`
      // body expands to its `UNION ALL` FIRST, so this schema-path typecheck
      // sees the per-set arms (an empty-set grand-total arm evaluates its
      // projection even under a `WHERE` that spares the unexpanded key list),
      // matching the run/`compile` normalization.
      let query = try cte.query.expanded
      let scope = try augment(context.validating(typecheck), for: query,
                              rows: false)
      let width = try compile(query, scope).width
      guard width == cte.columns.count else {
        throw .columns(expected: width, got: cte.columns.count)
      }
      // A non-self-naming body is operand-checked whole with self NOT in scope.
      if typecheck { try self.typecheck(query, scope) }
    }
  }

  /// Evaluates a recursive `cte` to a fixpoint over this catalog with the
  /// `ctes` in scope, returning every produced row.
  ///
  /// A recursive CTE's query is a `UNION` of an anchor (its left arm) and a
  /// RECURSIVE arm (its right arm, which names the CTE). The
  /// anchor evaluates once — with the CTE name NOT yet bound — to seed `result`
  /// and the `working` set. Each iteration then binds the CTE name to ONLY the
  /// `working` rows (the SQL semantics — the recursive arm sees just the
  /// previous step's output) and runs the recursive arm; the rows it produces
  /// extend `result` and become the next `working` set. A `UNION ALL` keeps
  /// every produced row; a `UNION` keeps only rows not seen before (a whole-row
  /// `seen` set), and a step that adds nothing new is the fixpoint. The
  /// `kRecursionCap` guards a non-terminating CTE with `SQLError.recursion`.
  ///
  /// A non-`UNION` recursive query has no recursive arm to iterate, so it runs
  /// once like a non-recursive CTE — its compiled width validated the same way
  /// before it materialises, so a non-`UNION` body binding rows of a width
  /// other than the column list (e.g. a base relation of the CTE's own name)
  /// faults with `SQLError.columns` rather than trapping on a later read.
  ///
  /// The anchor and the recursive arm are each validated against
  /// `cte.columns.count` by their compiled `Plan.width` before any rows bind
  /// under the declared columns: the loop binds `working` as a
  /// `RelationInstance` of `cte.columns`, so an arm narrower or wider than the
  /// column list — a two-column anchor under a three-column list, or a
  /// recursive arm of a width differing from the anchor's — would trap in
  /// `RelationInstance.record` when the next iteration reads it. Checking the
  /// compiled width faults with `SQLError.columns` regardless of how many rows
  /// an arm yields, so even a `SELECT *` arm filtered to zero rows is caught.
  /// The anchor compiles with the CTE name NOT in scope (it does not reference
  /// itself); the recursive arm compiles with the name bound to `cte.columns`,
  /// the schema it reads.
  internal borrowing func fixpoint(_ cte: CTE, _ context: Context)
      throws(SQLError) -> (rows: Array<Array<Value>>,
                           carrier: Array<ResolvedColumn>) {
    // Extend the scope with any `definition_schema.` store relation the CTE's
    // body names, so the fixpoint's width-check compiles resolve a reserved
    // relation as the body's own run does. The routines ride in: this store
    // entry is cached in the overlay and reused by every anchor/recursive
    // execution (a later `augment` will not replace a bound name), so a view
    // column using even a standard routine (`BITAND(...)`) types the same
    // inside the CTE as the identical SELECT does outside it.
    // `validate: false` on every arity `compile` below — `fixpoint` is a pure
    // run path (only `with` routes a self-naming CTE here), so a derived body
    // the CTE's arm nests must be trusted, not eager-type-checked: a data-
    // dependent body expression a filter drops must not fault a CTE that runs
    // empty, matching the non-recursive and non-`WITH` paths.
    // Expand a `GROUP BY GROUPING SETS` body to its `UNION ALL` FIRST — the
    // same normalization `run`/`compile`/the schema `validate` apply — so the
    // `augment` and the non-`UNION` run-once branch below see the expanded AST.
    // Idempotent for a plain recursive `UNION` body.
    let query = try cte.query.expanded
    let context = try augment(context.validating(false), for: query,
                              rows: true)
    // Peel the canonical recursive shape — the same `canonical` (expanded,
    // unwound) form `recurses`/`recursiveArms`, the shape validator, and the
    // schema derive peel — off the body: the fixpoint iterates the INNER
    // `UNION` (anchor ∪ recursive) with the CTE self in scope, then the peeled
    // `carrier` applies its row operators to the materialised result. The
    // carrier is transparent to the recursive shape (`references` descends it),
    // so `recurses` already routed an ordered body here. `canonical` expands a
    // grouping-sets body FIRST, matching the `query` `augment` sees above.
    let (body, carriers) = try cte.canonical
    guard case let .setop(.union, anchor, recursive, all) = body.body else {
      // A non-`UNION` recursive query runs once, but still binds under
      // `cte.columns`, so validate its compiled width here too — the check the
      // anchor and arm get. A body naming a base relation of the CTE's own name
      // (`WITH RECURSIVE Parent(x,y,z) AS (SELECT * FROM Parent)`) would else
      // bind narrow base rows under the wider list and trap on a later read.
      let width = try compile(query, context).width
      guard width == cte.columns.count else {
        throw .columns(expected: width, got: cte.columns.count)
      }
      // The CTE exposes its body's derived column types/mask under its declared
      // names (resolved with the self shadowed by the same-named base it seeds
      // from), not the declared-name placeholder, so a caller reading the CTE
      // unifies against real types and the `unconstrained` mask while
      // addressing the CTE by its declared list.
      let rows = try run(query, context)
      // trusted re-derive (the body already ran): `validating(false)` so an
      // unreached data-dependent operand is not eager-checked, while a genuine
      // set-operation incompatibility still faults through `merge`.
      let carrier = try kinds(of: cte, context.validating(false))
      return (rows, carrier)
    }

    // A misplaced recursive reference in the anchor (a same-named base/view is
    // absent) was already rejected in `with`, before routing here, so the
    // anchor is a genuine base case by this point.

    // Validate the anchor's compiled width against the declared columns before
    // it seeds the working set: the loop binds `working` under `cte.columns` as
    // a `RelationInstance`, so an anchor narrower than the column list — a
    // two-column `Parent` under `t(a, b, c)` — would trap when the recursive
    // arm reads the absent ordinal, rather than surfacing `SQLError.columns`.
    // The anchor is the base case and does not reference the CTE, so its width
    // resolves with the name not yet in scope.
    let width = try compile(anchor, context).width
    guard width == cte.columns.count else {
      throw .columns(expected: width, got: cte.columns.count)
    }

    // The CTE column carrier a recursive reference reads under — the anchor's
    // own output columns (the base case, resolved with self NOT in scope).
    // Binding the schema-only self under these — rather than a flat `.integer`
    // placeholder — types the recursive arm's self-referencing columns
    // consistently with the anchor, so the anchor/recursive fold below does not
    // spuriously merge a genuine anchor type (a `text` `column_name`) against
    // an `.integer` placeholder self column and fault. A NULL-only anchor
    // column stays unconstrained, so the recursive arm's typed column supplies
    // the type. It defaults to `.integer`, the run's materialised-relation
    // default.
    let seeds = try columns(unifying: anchor, context)

    // The recursive arm compiles with the CTE name bound to the anchor's own
    // carrier under the CTE's declared names (a `SELECT x FROM t` self
    // reference addresses the declared `x`, not the anchor's projected name) —
    // the schema every iteration reads it under — so its width resolves too (a
    // `SELECT *` arm spans that schema). Checking it here catches a mismatch
    // even when the arm is filtered to zero rows in every iteration. It is
    // typed under the anchor's own `seeds`, so the arm's self columns carry the
    // base-case types, not a flat `.integer`.
    let declared = seeds.indices.map {
      ResolvedColumn(name: cte.columns[$0], type: seeds[$0].type,
                     unconstrained: seeds[$0].unconstrained)
    }
    let empty = RelationInstance(from: declared, rows: [])
    let probe = context.binding(cte.name, to: empty)
    let arm = try compile(recursive, probe).width
    guard arm == cte.columns.count else {
      throw .columns(expected: arm, got: cte.columns.count)
    }

    // The result column carrier unifies the anchor — typed under `context`,
    // where a same-named base/view the anchor seeds from resolves to that base
    // (the CTE self not yet in scope) — with the RECURSIVE arm, typed under
    // `probe` (self bound). Folding the whole `cte.query` under `probe` would
    // resolve the anchor's base reference against the empty self, rejecting or
    // mis-unifying a base-only column (`SELECT Age FROM People` seeding a
    // recursive `People`). So merge the two arms' own-scope columns
    // column-wise: an irreconcilable pair (text beside a number) faults
    // `SQLError.operand`.
    // `combine` never runs here (the fixpoint is hand-rolled for its `Seen`
    // dedup), so these types coerce the produced ROWS directly with
    // `Value.coerced` — the anchored seed and each iteration's output — before
    // the dedup and append, leaving the plan tree (and the recursive self-
    // reference) untouched.
    let steps = try columns(unifying: recursive, probe)
    // Merge column-wise, then bind under the CTE's declared names (a CTE is
    // addressed by its declared list, never the arm's own projected name),
    // keeping each column's unified type and `unconstrained` mask. The declared
    // width is proved equal to each arm's above, so the index is in range.
    let unified = try seeds.indices.map { index throws(SQLError) in
      try merge(seeds[index], steps[index])
    }
    let merged = unified.indices.map {
      ResolvedColumn(name: cte.columns[$0], type: unified[$0].type,
                     unconstrained: unified[$0].unconstrained)
    }
    let types = merged.map(\.type)

    // The anchor seeds the result and the working set, the CTE name not yet in
    // scope (the anchor is the base case, which does not reference itself). A
    // bare `UNION` dedups the seed exactly as it dedups an iteration's rows —
    // duplicate anchor rows collapse to their first occurrence — while `UNION
    // ALL` keeps every anchor row. Each seed row is coerced to the unified
    // column types before it is dedup'd or seeds the working set.
    let anchored = try run(anchor, context).map { coerce($0, to: types) }
    var seen = Seen()
    var result = all ? anchored
                     : anchored.filter { seen.insert($0) }
    var working = result

    var iterations = 0
    while !working.isEmpty {
      iterations += 1
      guard iterations <= kRecursionCap else {
        throw .recursion(cte.name)
      }

      // Bind the CTE name to ONLY the previous step's output and run the
      // recursive arm against the base catalog plus the earlier CTEs. The self
      // relation carries the unified `merged` carrier — the rows in `working`
      // are already coerced to those types (the anchored seed and each step
      // passes through `coerce($0, to: types)`), so the recursive arm must be
      // typed to the values it reads. Typing the self under the anchor-only
      // `seeds` would type an integer-anchor self while the coerced rows
      // already hold widened `double` values, mistyping the arm the run reads.
      let step = RelationInstance(from: merged, rows: working)
      let produced = try run(recursive, context.binding(cte.name, to: step))
          .map { coerce($0, to: types) }

      var next = Array<Array<Value>>()
      for row in produced where all || seen.insert(row) {
        next.append(row)
      }
      result += next
      working = next
    }
    // Apply the peeled query-level carrier — a trailing `ORDER BY` / `OFFSET`·
    // `FETCH` / `DISTINCT` on the body's set operation — to the materialised
    // fixpoint result, reusing the ordinary `SELECT`-over-a-relation path
    // rather than re-resolving the row operators here. A trailing carrier's
    // `generated` is always `0` (the parser materialises no hidden sort column
    // for it; only `expand` does, which never yields a recursive body), so the
    // result rows are exactly the CTE's declared columns and need no trim.
    //
    // The carrier's `ORDER BY` resolves against the body's FIRST-ARM set-op
    // output names — the same scope the non-recursive ordered-CTE body uses
    // (`WITH t(n) AS (SELECT 1 AS x UNION ALL … ORDER BY x)` orders by the
    // arm-0 output `x`, not the declared `n`) — so name the temp `apply` binds
    // under the anchor's output names (a set operation names its output off its
    // FIRST arm, the ISO rule; the anchor resolves with the CTE self NOT in
    // scope, so its names derive without the self binding), NOT the CTE's
    // declared names (`merged`). Each column carries the run-unified `merged`
    // type the materialised rows hold. The CTE-declared rename rides the
    // returned `merged` carrier, applied after the carrier at CTE consumption,
    // so the outer `SELECT n FROM t` still addresses `n`.
    if !carriers.isEmpty {
      let outputs = try columns(unifying: anchor, context)
      let named = merged.indices.map {
        ResolvedColumn(name: outputs[$0].name, type: merged[$0].type,
                       unconstrained: merged[$0].unconstrained)
      }
      // Stacked carriers (`(recursive-union ORDER BY 1) ORDER BY 1`) apply
      // innermost first — the peel order — each over the prior result, so the
      // outer tail pages/orders what the inner already produced.
      for carrier in carriers {
        result = try apply(carrier, result, named, arm: anchor.arm, context)
      }
    }
    return (result, merged)
  }

  /// Applies a peeled query-level `carrier` — `DISTINCT`/`ORDER BY`/`OFFSET`·
  /// `FETCH` — to the materialised `rows` a recursive-CTE fixpoint produced,
  /// typed by the fixpoint's unified `carrier` `columns` (the body's arm-0
  /// output names), `arm` the body's leftmost arm as a carrier-free `Query`
  /// (the anchor).
  ///
  /// The rows are bound as a temporary relation under a non-spellable name; a
  /// bare scan over it seeds the shared `carried(over:)` carrier resolver — the
  /// same resolver the ordinary `ordered` set-operation path uses — so the
  /// carrier's `ORDER BY` resolves a projected-expression / aliased / qualified
  /// / ordinal key against the arm-0 projection surface identically to the
  /// ordinary path, never a bare `SELECT * FROM <temp>` that re-evaluates a
  /// projected key over the column-shy temp. A trailing carrier's `generated`
  /// is always `0` (only `expand` materialises hidden sort columns, and it
  /// never yields a recursive body), so the identity projection trims nothing.
  private borrowing func apply(_ carrier: Query.Carrier,
                               _ rows: Array<Array<Value>>,
                               _ columns: Array<ResolvedColumn>,
                               arm: Query, _ context: Context)
      throws(SQLError) -> Array<Array<Value>> {
    let name = "*fixpoint"
    let temp = RelationInstance(from: columns, rows: rows)
    // Thread one fresh subquery cache — a shared box — through both `carried`
    // (which resolves the carrier `ORDER BY` and, for a sort key correlated to
    // the set-op output, records that key's compiled runtime plan here) AND
    // `execute` (whose row evaluator reads that recorded plan back), mirroring
    // the top-level `run`. A fresh box (not the incoming context's) isolates
    // the carrier's subquery cache from the fixpoint iterations' recorded body
    // plans; what matters is that `carried` writes and `execute` read the same
    // box, so a correlated carrier sort key does not fault "a correlated
    // subquery plan was not compiled" on execution.
    let context = context.binding(name, to: temp).resolving(Subqueries())
    // The base scan over the temp — its output columns are `columns`, the
    // setop-output scope the carrier resolves against. The shared resolver
    // stacks the row operators over it in that identity slot space.
    let scan = try compile(.select(Select(projection: .all,
                                          from: Relation(name: name))),
                           context)
    // The fixpoint peels this carrier and runs it here under a normal (non-
    // comparing) context, so — unlike the non-recursive run carrier the top-
    // level `typecheck(_:comparing())` re-runs through `ordered` — its `ORDER
    // BY` keys never reached the compile-time comparability walk: a cross-kind
    // sort key (`ORDER BY NULLIF(n, 'x')`) over an empty fixpoint sorted no
    // rows and returned empty rather than faulting 42804, while the schema
    // path's `validate(carrier:)` faulted the same key — a run ≠ validate
    // break. Preflight the carrier through the same `carried` resolver in
    // `comparing()` mode before the materialised rows are ordered, so the
    // finder (the carrier's `context.comparability` branch) faults a cross-kind
    // key here as it does on the non-recursive run and the validate path. The
    // plan is discarded — only the keys' fault matters; a fresh subquery box
    // isolates the preflight's carrier-subquery cache from the real run below.
    // The walk is comparability-only (`validate` stays `false`), so an
    // arithmetic sort key (`ORDER BY n + 1`) still defers to the run — only a
    // statically incomparable comparison faults.
    _ = try carried(over: scan, output: columns, arm: arm,
                    distinct: carrier.distinct, order: carrier.order,
                    limit: carrier.limit, generated: carrier.generated,
                    context.resolving(Subqueries()).comparing())
    let plan = try carried(over: scan, output: columns, arm: arm,
                           distinct: carrier.distinct, order: carrier.order,
                           limit: carrier.limit, generated: carrier.generated,
                           context)
    return try execute(plan, context).map(\.values)
  }

  /// Validates the peeled `carrier`'s `ORDER BY` keys against the body's set-op
  /// output `columns` — an empty temp of those columns — through the same
  /// shared `carried(over:)` resolver `apply` runs, under a validating context,
  /// so a schema-path `columns(of:validate:true)` faults a carrier `ORDER BY`
  /// naming a missing column or function exactly as the run does, closing the
  /// run-vs-validate gap. `arm` is the body's leftmost arm as a carrier-free
  /// `Query` (the anchor), the projection surface an ordinal / projected-
  /// expression / aliased key binds against. Discards the resolved plan — only
  /// its resolution can fault.
  private borrowing func validate(carrier: Query.Carrier,
                                  over columns: Array<ResolvedColumn>,
                                  arm: Query, _ context: Context)
      throws(SQLError) {
    let name = "*fixpoint"
    let temp = RelationInstance(from: columns, rows: [])
    let context = context.binding(name, to: temp)
    let scan = try compile(.select(Select(projection: .all,
                                          from: Relation(name: name))),
                           context)
    _ = try carried(over: scan, output: columns, arm: arm,
                    distinct: carrier.distinct, order: carrier.order,
                    limit: carrier.limit, generated: carrier.generated,
                    context)
  }
}

/// A row's cells coerced to the unified column `types` — the recursive-CTE
/// fixpoint's row-level counterpart of `Record.coerced(to:)`, applied to each
/// materialised `Array<Value>` row (the fixpoint works on raw rows, not the
/// plan tree) so the anchor and every iteration carry the set-operation's
/// unified column types. `Value.coerced` widens an `integer` cell to `double`
/// where the unified column is `double` and passes every other cell through, so
/// a homogeneous recursive CTE's rows are unchanged. `types` matches the row
/// width (the arity `fixpoint` proved equal against the declared columns).
private func coerce(_ row: Array<Value>, to types: Array<ValueType>)
    -> Array<Value> {
  row.indices.map { row[$0].coerced(to: types[$0]) }
}
