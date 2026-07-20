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

// MARK: - WITH

extension CTE {
  /// Whether the CTE actually references itself — the test the fixpoint routing
  /// turns on, distinct from the syntactic `recursive` flag a `WITH RECURSIVE`
  /// stamps on every member.
  ///
  /// The parser marks each member of a `WITH RECURSIVE` list recursive whether
  /// or not it names itself, but only a self-referential CTE has a recursive
  /// arm to iterate; running a non-self-referential one through the fixpoint
  /// would re-evaluate an arm that never reads the CTE, repeating its rows
  /// without end (a `UNION ALL`) or needlessly (a `UNION`). A CTE is recursive
  /// in truth when its recursive arm — the right member of the top-level
  /// `UNION`, the one the fixpoint compiles with the CTE bound — names `name`
  /// in a `FROM`/`JOIN`. The anchor is the base case, compiled with the name
  /// NOT in scope, so a `FROM <name>` there reads a base relation of that name,
  /// not the CTE. Scanning the anchor too would misroute `WITH RECURSIVE
  /// Parent(Id) AS (SELECT Id FROM Parent UNION ALL SELECT Id FROM Extra)` —
  /// whose anchor merely reads the same-named base — into the fixpoint.
  internal var recurses: Bool {
    guard case let .setop(.union, _, arm, _) = query else { return false }
    return arm.references(name.lowercased())
  }
}

extension Query {
  /// Whether the query names the relation `name` (case-folded) in ANY member's
  /// `FROM`/`JOIN` — walking the set-operation tree and each arm. Used to spot
  /// a self-reference lurking in a recursive body's anchor; `CTE.recurses`
  /// itself inspects only the recursive arm.
  internal func references(_ name: String) -> Bool {
    switch self {
    case let .select(select):
      select.references(name)
    case let .setop(_, left, right, _):
      left.references(name) || right.references(name)
    }
  }
}

extension Select {
  /// Whether the select names the relation `name` (case-folded) in its `FROM`
  /// or any `JOIN`.
  ///
  /// A relation contributes a reference by its SOURCE, not its binding name: a
  /// `.named` relation names `name` when its identifier matches; a `.derived`
  /// one names NOTHING through its alias — a `FROM (SELECT …) AS a` does not
  /// reference a relation `a` — but its inner query is recursed into for the
  /// REAL `.named` references its body holds. So a recursive-CTE fixpoint
  /// detector sees a self-reference nested inside a derived body (`FROM (SELECT
  /// n FROM a) AS d` names `a`) yet is NOT fooled by a shadowing derived alias
  /// (`FROM (SELECT … ) AS a` does not name the CTE `a`).
  internal func references(_ name: String) -> Bool {
    from?.references(name) ?? false
        || joins.contains { $0.relation.references(name) }
  }
}

extension Relation {
  /// Whether this relation references the relation `name` (case-folded): a
  /// `.named` relation by its identifier, a `.derived` one by RECURSING into
  /// its inner query — the derived alias itself is not a reference.
  internal func references(_ name: String) -> Bool {
    switch source {
    case let .named(identifier):
      identifier.lowercased() == name
    case let .derived(query):
      query.references(name)
    }
  }
}

// MARK: - Execution

extension Catalog where Self: ~Escapable {
  /// Runs `query` against this catalog, returning the projected, filtered, and
  /// ordered rows as typed values.
  ///
  /// A bare `SELECT` runs as before; a `UNION` runs each arm through the same
  /// compile/optimise/execute with the SAME `bindings` and `routines`, then
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
    // The engine is PURE: it resolves calls against exactly the `routines`
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
    // A set operation runs each ARM against its OWN scope and combines the
    // results, rather than materialising both arms' derived tables into one
    // shared overlay the executor scans by name. Both arms bind their aliases
    // in ONE map, so a right arm's `derived T` would shadow a left arm's base
    // (or CTE) `T` at the leaf scan — the executor keys a `.scan` by name and
    // cannot tell the two `T`s apart. Running per arm scopes each arm's derived
    // tables to that arm: the left arm's `FROM T` scans the base relation and
    // the right arm's its own derived one, then `combine` merges them under the
    // operator's duplicate rule. The arity across arms is checked as `compile`
    // resolves the whole query below.
    if case let .setop(kind, left, right, all) = query {
      // Validate the whole query (per-arm resolution and the cross-arm arity
      // check) exactly as a single select does, then run each arm on its own —
      // each arm's `run` threads its OWN lazy subquery box. `validate: false` —
      // the preflight must not eager-type-check a derived body a data-dependent
      // filter never reaches (execution faults only on a REACHED operand),
      // matching the non-derived path.
      _ = try compile(query, context.validating(false))
      let combined = try combine(kind, run(left, context).map(Record.init),
                                 run(right, context).map(Record.init), all)
      return combined.map(\.values)
    }
    // Thread a fresh LAZY subquery cache — a shared box — through BOTH compile
    // and execute. The executor's row evaluator runs each nested subquery into
    // it on first reach (where the borrowing catalog IS in scope; a schema-only
    // path never reaches it, so opens no cursor): an UNCORRELATED occurrence
    // runs once and memoises, while a CORRELATED one re-executes per outer row
    // against the correlated bindings, bypassing the memo. Compile stashes each
    // CORRELATED occurrence's inner PLAN here (compiled once with its enclosing
    // scope, so its correlated columns are bound `Term.parameter`s), so the
    // evaluator re-executes THAT plan rather than recompiling the inner query
    // with no outer scope.
    let context = context.resolving(Subqueries())
    // Compile from the un-augmented `context` (idempotently augmented inside
    // `compile`, which reveals the base for a nested subquery) — this query's
    // derived aliases are invisible to a subquery's FROM, and a CTE a
    // same-named derived alias shadows stays visible beneath the revealed base.
    // Compile VALIDATES the whole query (schema-only, `rows: false`) BEFORE any
    // row materialises below, so an invalid query — an unknown column resolving
    // over a `FROM (SELECT tick() …) AS d` — faults WITHOUT ever executing the
    // derived body's stateful routine. A materialise ahead of this compile
    // would run the body for a query that cannot run.
    //
    // `validate: false` gates the derived-body type-check OFF: the preflight
    // proves the OUTER query runnable and resolves its relations, but a data-
    // dependent body expression a filter drops (`FROM (SELECT Label + 1 AS x
    // FROM K WHERE k = 0) AS d`) must NOT be rejected here — execution faults
    // ONLY on an expression a surviving row reaches, exactly as the non-derived
    // `SELECT Label + 1 FROM K WHERE k = 0` runs to zero rows. The eager body
    // type-check stays for the EXPLICIT schema path (`columns` `validate:
    // true`).
    let logical = try compile(query, context.validating(false)).pushdown()
    // Now that `compile` proved the query runnable, extend the overlay with any
    // `definition_schema.` store relation the query names (resolved lazily —
    // the overlay after the CTEs, before the base catalog) AND MATERIALISE this
    // query's derived tables (`rows: true`, executing each body ONCE). Every
    // phase reads the extended map, so a reserved store relation resolves,
    // plans, and materialises exactly as a common table expression does; a
    // portable `information_schema.` view over the store resolves through the
    // ordinary view machinery. The routines ride in so a store `data_type` row
    // types a view's scalar-call column (`GUID(...)`) by its declared return
    // type.
    //
    // `validate: false` — this run materialise executes each body's rows, but a
    // NESTED derived body's schema is still derived schema-only inside
    // `materialise` (to name the inner alias's columns); `validate: true` there
    // would eager-type-check a doubly-nested filtered-out body on the RUN path.
    // The run stays lenient at every depth (the outer query already compiled,
    // and a REACHED operand still faults at execution).
    let augmented = try augment(context.validating(false), for: query,
                                rows: true)
    // Record the caller's overlay under `.caller` so a subquery lowered under
    // it (even one a pushdown moved INTO a view) re-runs against the caller's
    // relations, not the view's base. REVEAL the base first — this query's
    // derived-table aliases are SELECT-scoped, invisible to a subquery's FROM,
    // while the CTEs and `definition_schema.` store relations a `.caller`
    // subquery's FROM resolves against are kept, so a subquery `FROM d` reads a
    // CTE `d` a same-named derived alias shadows rather than the derived rows.
    // The shared box survives from the un-augmented compile into execution.
    augmented.subqueries.record(overlay: augmented.revealed().relations,
                                for: .caller)
    // Rewrite each decorrelatable correlated CROSS APPLY into a set-based join
    // BEFORE the physical `optimise`/`nest`, so the emitted `select`-over-
    // `product` folds to a hash equi-join. The pass reads the compiled body
    // plans recorded above into the shared subquery box; a non-decorrelatable
    // apply is left verbatim, so a plan with none is unchanged.
    let decorrelated = try decorrelate(logical, augmented)
    let plan = try optimise(decorrelated, augmented)
    return try execute(plan, augmented).map(\.values)
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
  /// Each CTE materialises against the base catalog plus every EARLIER CTE,
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
  /// against the declared count BEFORE the CTE materialises — regardless of how
  /// many rows the body yields. A body filtered to zero rows still faults with
  /// `SQLError.columns`, where a per-row check would pass it through vacuously.
  internal borrowing func with(_ ctes: Array<CTE>, _ query: Query,
                               _ context: Context)
      throws(SQLError) -> Array<Array<Value>> {
    var relations = ScopedRelations()
    for cte in ctes {
      // A query name repeated in the list (case-insensitively) would silently
      // shadow the earlier binding in `relations`, so reject it rather than
      // overwrite — a typo in a multi-CTE query must not change the result.
      guard relations[cte.name.lowercased()] == nil else {
        throw .redefinition(cte.name)
      }
      // The scope for this CTE's body: the base catalog plus every earlier CTE,
      // over the run's routines and bindings. `body(_:)` enters this fresh
      // statement-scoped body with the correlation stack CLEARED — a CTE is
      // resolved independently of any call site (a `WITH` is statement-level,
      // so the stack is already empty here; routing through `body(_:)` keeps
      // the clear intrinsic to entering a body scope rather than incidental).
      let scope = context.body(relations)
      // Validate the CTE's SHAPE and ARITY against the CTEs done so far — the
      // compile-time structural check, shared with the dry-run schema path so a
      // derive rejects exactly the CTEs a run rejects. It faults the recursive
      // shape and the width mismatch here, BEFORE any rows materialise.
      try validate(cte, against: scope)
      // A CTE that names itself iterates a fixpoint; every other one — a
      // non-recursive CTE, or one a `WITH RECURSIVE` marks recursive but which
      // does not reference itself — runs its query once. Each resolves against
      // the base catalog plus the CTEs done so far. The arity of both routings
      // is already checked by `validate` above.
      let rows: Array<Array<Value>>
      if cte.recursive && cte.recurses {
        rows = try fixpoint(cte, scope)
      } else {
        rows = try run(cte.query, scope)
      }
      relations[cte.name.lowercased()] =
          RelationInstance(from: cte.declared, rows: rows)
    }
    return try run(query, context.body(relations))
  }

  /// Validates the SHAPE and declared ARITY of a single common table expression
  /// `cte` against the base catalog plus the CTEs done so far (`ctes`), WITHOUT
  /// materialising a row — the compile-time structural check `with` runs before
  /// each CTE materialises, factored out so the dry-run result-schema path
  /// (`columns(of:with:)`) validates a `WITH` by the SAME code a run does,
  /// ending the divergence between the two.
  ///
  /// It reproduces, without executing, the two structural faults `with` and
  /// `fixpoint` raise:
  ///
  /// - The RECURSIVE SHAPE. A `WITH RECURSIVE` member's recursive reference
  /// must be its FINAL `UNION` arm — the engine's model is anchor members then
  /// ONE recursive arm. A reference to the CTE's own name in an EARLIER arm
  /// resolves against the base scope (the CTE is not in scope outside the
  /// recursive arm), so a same-named base or view is a valid seed; but with no
  /// such base/view the reference can only be a misplaced recursive arm —
  /// recursion before the final arm, or a second recursive arm — a shape the
  /// engine does not support, faulted `SQLError.unsupported`.
  ///
  /// - The DECLARED ARITY. Each CTE body must project exactly the arity its
  /// column list declares, or a later reader indexes out of bounds. The body's
  /// width is known once it COMPILES — never opening a cursor — so the compiled
  /// `Plan.width` is checked against the declared count, faulting
  /// `SQLError.columns` on a mismatch. A recursive (self-naming) CTE checks its
  /// ANCHOR (self NOT in scope) and its RECURSIVE arm (self bound to the
  /// declared columns) separately, exactly as `fixpoint` does; every other CTE
  /// checks its whole body with self NOT in scope. This is why the schema path
  /// must NOT bind the CTE's self for the whole body: a `WITH RECURSIVE t(n) AS
  /// (SELECT n FROM t UNION SELECT n FROM t)` faults the recursive shape here —
  /// self is not in scope in the anchor — rather than resolving a
  /// self-reference the run would reject.
  ///
  /// The reachable-operand type-check the schema path also wants is NOT part of
  /// the shape/arity check the run relies on — the run DEFERS it to execution.
  /// It rides in through `typecheck`: the run path passes `false` (it defers),
  /// the schema path passes `true` (it must fault an ill-typed body
  /// statically). Folding it here rather than layering it in the schema path
  /// keeps ONE per-arm scoping for BOTH the structural check and the operand
  /// check — a recursive CTE's ANCHOR is operand-checked against base + prior
  /// CTEs (self NOT in scope, the scope the run evaluates the anchor in), NOT
  /// the CTE-self overlay, so `SELECT Name + 1 FROM People` in the anchor
  /// faults `SQLError.operand` against the BASE `People` a run reads it
  /// against, never wrongly types clean against the CTE's declared columns.
  ///
  /// `typecheck` ALSO gates the eager type-check of a DERIVED body the CTE
  /// body nests: the arity `augment`/`compile` below thread `validate:
  /// typecheck` so a run (`typecheck: false`) derives a `FROM (SELECT …) AS d`
  /// LENIENTLY — a data-dependent body expression a filter drops (`FROM (SELECT
  /// Label + 1 AS x FROM K WHERE k = 0) AS d`) is TRUSTED, not rejected, as
  /// the non-`WITH` and `WITH`-trailing paths already do — while the schema
  /// path (`typecheck: true`) keeps the strict body type-check.
  internal borrowing func validate(_ cte: CTE, against context: Context,
                                   typecheck: Bool = false)
      throws(SQLError) {
    // Reject a misplaced recursive reference in an EARLIER arm when no
    // same-named base/view can seed it — the shape `with` rejects before
    // routing to the fixpoint.
    if cte.recursive, case let .setop(.union, anchor, _, _) = cte.query,
        anchor.references(cte.name.lowercased()),
        case nil = table(named: cte.name),
        case nil = view(named: cte.name) {
      throw .state("0A000",
                   "recursive WITH references the CTE outside its final " +
                   "UNION arm")
    }
    // Check the declared arity by compiling the body — never a cursor. A
    // recursive (self-naming) CTE checks its anchor and recursive arm the way
    // `fixpoint` does: the anchor with self NOT in scope, the recursive arm
    // with self bound to the declared columns. Every other CTE checks its whole
    // body with self NOT in scope. When `typecheck`, the reachable-operand
    // check runs in the SAME per-arm scope each arity check uses, so the
    // operand check shares the run's arm scoping and never types an anchor
    // against the CTE-self overlay.
    if cte.recursive && cte.recurses,
        case let .setop(.union, anchor, recursive, _) = cte.query {
      let scope = try augment(context.validating(typecheck), for: anchor,
                              rows: false)
      let width = try compile(anchor, scope).width
      guard width == cte.columns.count else {
        throw .columns(expected: cte.columns.count, got: width)
      }
      // The anchor is operand-checked with self NOT in scope — the scope the
      // run evaluates it in — so a text-arithmetic anchor faults against the
      // base relation, not the CTE's declared (integer) columns.
      if typecheck { try self.typecheck(anchor, scope) }
      let empty = RelationInstance(from: cte.declared, rows: [])
      // Bind the CTE self BEFORE augmenting the recursive arm, so a derived
      // body in the arm that names the CTE (`FROM (SELECT n FROM a) AS d`)
      // resolves it — `augment` materialises derived bodies eagerly, so the
      // self must be in scope by then, not bound only afterwards.
      let bound = context.binding(cte.name, to: empty).validating(typecheck)
      let probe = try augment(bound, for: recursive, rows: false)
      let arm = try compile(recursive, probe).width
      guard arm == cte.columns.count else {
        throw .columns(expected: cte.columns.count, got: arm)
      }
      // The recursive arm is operand-checked with self bound to the declared
      // columns — the schema every iteration reads the CTE under.
      if typecheck {
        try self.typecheck(recursive, probe)
      }
    } else {
      let scope = try augment(context.validating(typecheck), for: cte.query,
                              rows: false)
      let width = try compile(cte.query, scope).width
      guard width == cte.columns.count else {
        throw .columns(expected: cte.columns.count, got: width)
      }
      // A non-self-naming body is operand-checked whole with self NOT in scope.
      if typecheck { try self.typecheck(cte.query, scope) }
    }
  }

  /// Evaluates a recursive `cte` to a fixpoint over this catalog with the
  /// `ctes` in scope, returning every produced row.
  ///
  /// A recursive CTE's query is a `UNION` of an ANCHOR (its left arm) and a
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
  /// `cte.columns.count` by their compiled `Plan.width` BEFORE any rows bind
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
      throws(SQLError) -> Array<Array<Value>> {
    // Extend the scope with any `definition_schema.` store relation the CTE's
    // body names, so the fixpoint's width-check compiles resolve a reserved
    // relation as the body's own run does. The routines ride in: this store
    // entry is cached in the overlay and reused by every anchor/recursive
    // execution (a later `augment` will not replace a bound name), so a view
    // column using even a standard routine (`BITAND(...)`) types the same
    // inside the CTE as the identical SELECT does outside it.
    // `validate: false` on every arity `compile` below — `fixpoint` is a pure
    // RUN path (only `with` routes a self-naming CTE here), so a derived body
    // the CTE's arm nests must be TRUSTED, not eager-type-checked: a data-
    // dependent body expression a filter drops must not fault a CTE that runs
    // empty, matching the non-recursive and non-`WITH` paths.
    let context = try augment(context.validating(false), for: cte.query,
                              rows: true)
    guard case let .setop(.union, anchor, recursive, all) = cte.query else {
      // A non-`UNION` recursive query runs once, but still binds under
      // `cte.columns`, so validate its compiled width here too — the check the
      // anchor and arm get. A body naming a base relation of the CTE's own name
      // (`WITH RECURSIVE Parent(x,y,z) AS (SELECT * FROM Parent)`) would else
      // bind narrow base rows under the wider list and trap on a later read.
      let width = try compile(cte.query, context).width
      guard width == cte.columns.count else {
        throw .columns(expected: cte.columns.count, got: width)
      }
      return try run(cte.query, context)
    }

    // A misplaced recursive reference in the anchor (a same-named base/view is
    // absent) was already rejected in `with`, before routing here, so the
    // anchor is a genuine base case by this point.

    // Validate the anchor's compiled width against the declared columns BEFORE
    // it seeds the working set: the loop binds `working` under `cte.columns` as
    // a `RelationInstance`, so an anchor narrower than the column list — a
    // two-column `Parent` under `t(a, b, c)` — would trap when the recursive
    // arm reads the absent ordinal, rather than surfacing `SQLError.columns`.
    // The anchor is the base case and does not reference the CTE, so its width
    // resolves with the name not yet in scope.
    let width = try compile(anchor, context).width
    guard width == cte.columns.count else {
      throw .columns(expected: cte.columns.count, got: width)
    }

    // The recursive arm compiles with the CTE name bound to `cte.columns` — the
    // schema every iteration reads it under — so its width resolves too (a
    // `SELECT *` arm spans that schema). Checking it here catches a mismatch
    // even when the arm is filtered to zero rows in every iteration.
    let empty = RelationInstance(from: cte.declared, rows: [])
    let probe = context.binding(cte.name, to: empty)
    let arm = try compile(recursive, probe).width
    guard arm == cte.columns.count else {
      throw .columns(expected: cte.columns.count, got: arm)
    }

    // The anchor seeds the result and the working set, the CTE name not yet in
    // scope (the anchor is the base case, which does not reference itself). A
    // bare `UNION` dedups the seed exactly as it dedups an iteration's rows —
    // duplicate anchor rows collapse to their first occurrence — while `UNION
    // ALL` keeps every anchor row.
    let anchored = try run(anchor, context)
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
      // recursive arm against the base catalog plus the earlier CTEs.
      let step = RelationInstance(from: cte.declared, rows: working)
      let produced = try run(recursive, context.binding(cte.name, to: step))

      var next = Array<Array<Value>>()
      for row in produced where all || seen.insert(row) {
        next.append(row)
      }
      result += next
      working = next
    }
    return result
  }
}

// MARK: - Compilation

extension Projection {
  /// Compiles this scalar (FROM-less) `SELECT <expr-list>` projection into
  /// `Project(single)` — the projection evaluated against the one empty row the
  /// `single` leaf yields.
  ///
  /// The projection resolves against an empty schema (no columns), so only
  /// literals, scalar calls, and arithmetic over them lower; a `SELECT *` has
  /// no relation to expand and a bare-column reference no column to bind, each
  /// faulting (`SQLError.column` for a column, `SQLError.unsupported` for `*`).
  /// The terms hold no slots, so the `single` row's empty record carries every
  /// value the projection needs.
  ///
  /// `subquery` carries the compile-time width map of the UNCORRELATED
  /// subqueries the projection nests, so an `EXISTS`/`IN (Q)` inside a scalar
  /// term lowers exactly as it does on the FROM'd path — the FROM-less scalar
  /// select is otherwise the ONE path that would hit the default unsupported
  /// map and reject a subquery a run materialises. The `Resolution` is
  /// threaded, not run, here (see `subquery(of:)`).
  ///
  /// A projection is a BARRED clause position, so a correlated column of THIS
  /// query has no evaluator here. `Schema.terms` bars the seam intrinsically,
  /// so this FROM-less projection CANNOT admit correlation even when handed the
  /// admitting `plans.rest` — the same cut `columns(of:)` applies on the schema
  /// path, keeping run and derive in lockstep.
  internal func scalar(_ routines: Routines = [:],
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> Plan {
    guard case .all = self else {
      let schema = Schema(width: 0, extent: 0, names: [], types: [],
                          virtuals: [])
      let terms = try schema.terms(self, in: Relation(name: ""), routines,
                                   subquery: subquery)
      return .project(terms, .single)
    }
    // `SELECT *` names every column of the relations in scope; a FROM-less
    // query has none, so there is nothing to expand.
    throw .unsupported("SELECT * requires a FROM clause")
  }
}

/// A relation resolved for compilation: its name-resolution `schema` and a
/// `leaf` factory that, given the ordinals the query references on its side,
/// builds the leaf `Plan` — a `scan` for a base table, a `derived` over the
/// view's compiled sub-plan for a view.
internal struct Resolved {
  let schema: Schema
  let leaf: (Array<Int>) -> Plan
}

/// The sorted, deduplicated ordinals a query references: the union of the
/// ordinals its `projection` terms read, the columns its `filter` reads, and
/// EVERY column its `order` keys read. The projection terms hold ordinals at
/// this stage; a scalar call's arguments contribute their read ordinals too.
private func referenced(_ projection: Array<Term>, _ filter: Filter?,
                        _ order: Array<SortKey>)
    -> Array<Int> {
  var ordinals = Set<Int>()
  for term in projection {
    term.references(into: &ordinals)
  }
  filter?.references(into: &ordinals)
  for key in order { key.term.references(into: &ordinals) }
  return ordinals.sorted()
}

/// The inverse map `ordinal → slot` of a referenced-ordinal list: slot `i` is
/// `ordinals[i]`, so the map sends `ordinals[i]` back to `i`.
private func invert(_ ordinals: Array<Int>) -> Dictionary<Int, Int> {
  var slot = Dictionary<Int, Int>(minimumCapacity: ordinals.count)
  for index in ordinals.indices {
    slot[ordinals[index]] = index
  }
  return slot
}

/// Rejects an `ORDER BY` key ordering on a value outside the `DISTINCT` output.
///
/// `SELECT DISTINCT` sorts the pre-projection rows then dedups the projected
/// ones, so ordering on a value the projection drops is ill-defined — after
/// dedup one output row stands for many source rows, whose differing sort-key
/// values leave no single order. The standard therefore requires every
/// `ORDER BY` key under `DISTINCT` to be a value of the select list, as the
/// grouped path requires for `GROUP BY`. An ordinal or an output-alias key
/// references a select-list output by construction (`SortKey.output`), so it
/// satisfies the rule whatever its term computes — its value is constant across
/// a dedup group. An ordinary INPUT expression key satisfies it when either it
/// reads a projected column — its resolved `Term` is a bare `.slot` (a plain
/// column read) that a projected bare-slot term also reads — or it REPEATS a
/// projected select-list expression: its AST `Expression` is structurally equal
/// to a projected one (`SELECT DISTINCT A + B AS total … ORDER BY A + B`), so
/// the key orders on a projected distinct value and is well-defined, exactly as
/// the alias `ORDER BY total` and the ordinal `ORDER BY 1` naming that same
/// output are. A key ordering on any other value faults `SQLError.distinct`.
///
/// The satisfying comparison is over the RESOLVED `Term`s, not the AST: a key
/// whose lowered `term` equals a projected item's lowered `term` orders on a
/// projected value. Lowering normalizes column qualification to a slot, so a
/// key that differs from its projected twin ONLY in qualification — `SELECT
/// DISTINCT A + 1 AS v … ORDER BY People.A + 1` against a projected `A + 1`,
/// where the two `.column`s resolve to the same slot — matches, as its
/// unqualified spelling and its alias/ordinal already do. The one comparison
/// runs in whatever slot space the caller resolved into (base ordinals on the
/// non-aggregate paths, grouped slots on the grouped path); `order` and
/// `projection` share it, so it serves every compile path, and it subsumes the
/// bare-projected-column case (`ORDER BY <projectedColumn>` lowers to the same
/// `.slot` the projection reads). `keys` supplies the AST key's spelling for
/// the fault message; each resolved order key pairs index-for-index with it.
///
/// A matching INPUT key is REBOUND to the projected column it matched: this
/// returns the order keys with each satisfying input key's `column` set to the
/// index of the projection item whose term it equals, so the DISTINCT
/// materialisation sorts on that already-materialised projected slot rather
/// than appending and re-evaluating `term` — a re-evaluation that would
/// misorder a non-deterministic or stateful key (`ORDER BY tick()` against a
/// projected `tick()`). An ordinal/alias key already names its column and
/// passes through.
private func distinct(_ keys: Array<Order.Key>, _ order: Array<SortKey>,
                      _ projection: Array<Term>)
    throws(SQLError) -> Array<SortKey> {
  var bound = order
  for index in order.indices where !order[index].output {
    guard let column = projection.firstIndex(of: order[index].term) else {
      throw .distinct(keys[index].name)
    }
    bound[index] = SortKey(term: order[index].term,
                           ascending: order[index].ascending, column: column)
  }
  return bound
}

extension Plan {
  /// This source plan wrapped in the projection/limit/sort/select operators,
  /// omitting each layer when its clause is absent. The `projection`, `filter`,
  /// and `order` keys are in slot space; an empty `order` omits the sort.
  ///
  /// Without `distinct` and with no `ORDER BY` key naming a select-list OUTPUT
  /// (an ordinal or an output alias), the shape is `Project(Limit(Sort(_)))`:
  /// the row `limit` sits BELOW the projection — after `WHERE` and `ORDER BY`
  /// but before the select list runs. A row outside the requested page is
  /// dropped by the limit before its projection runs, so a projection that
  /// could throw (`SELECT 1 / 0 … FETCH FIRST 0 ROWS ONLY`) never evaluates for
  /// a discarded row and the query returns the documented empty page.
  ///
  /// When an `ORDER BY` key names a select-list output over a COMPUTED
  /// expression (`SELECT next() AS n … ORDER BY n`), reusing the projection
  /// term as the pre-projection sort key would evaluate that expression twice
  /// — once to order, once to project — so a non-deterministic or stateful
  /// routine sorts on one set of values and returns a second, misordering the
  /// result. `materialised` instead computes the sort-referenced outputs ONCE
  /// below the sort and orders an output key by that column, then a
  /// final projection reads those SAME values it sorted on (and computes the
  /// remaining, unreferenced outputs above the cap). `shaped` takes that shape
  /// exactly when a key names an output; a pure input-key `ORDER BY` keeps the
  /// simpler `Project(Sort(_))` (its keys need input columns the materialised
  /// row has projected away).
  ///
  /// With `distinct` (`SELECT DISTINCT`) the dedup runs on the projected rows —
  /// after `ORDER BY`, before `OFFSET`/`FETCH` (the ISO order) — so the shape
  /// is `Limit(Distinct(Project(Sort(_))))`: the projection loses its cap
  /// (every candidate row must be projected to dedup it), the `distinct` dedups
  /// the projected rows, and the `limit` pages the deduplicated result. Its
  /// `ORDER BY` keys are all output values (the `distinct` rule), so the sort
  /// runs over the materialised projection here too.
  internal func shaped(distinct: Bool = false, projection: Array<Term>,
                       filter: Filter?, order: Array<SortKey>,
                       limit: Limit?) -> Plan {
    var plan = self
    if let filter {
      plan = .select(filter, plan)
    }

    // An output key names a materialised projection column; sorting on the
    // recomputed projection term instead would double-evaluate it (WRONG for a
    // non-deterministic routine). Materialise the sort-referenced outputs once
    // below the sort, so the order reflects the returned values whenever a key
    // does — over the FILTERED `plan`, so a HAVING/WHERE above governs.
    if order.contains(where: { $0.output }) {
      return plan.materialised(distinct: distinct, projection: projection,
                               order: order, limit: limit)
    }

    if !order.isEmpty {
      let keys = order.map { (term: $0.term, ascending: $0.ascending) }
      plan = .sort(keys: keys, plan)
    }
    guard distinct else {
      return .project(projection, plan.capped(limit: limit))
    }
    return Plan.distinct(.project(projection, plan)).capped(limit: limit)
  }

  /// This plan (already filtered) shaped so an `ORDER BY` key naming an OUTPUT
  /// sorts on exactly the value that output returns, computing each such output
  /// EXACTLY ONCE — the single-evaluation shape `shaped` picks when a key
  /// references the select list.
  ///
  /// Only the sort-REFERENCED outputs are materialised below the sort. A `map`
  /// projection retains the input columns (slots `0 ..< self.slots`) and
  /// appends one materialised column per output an ORDER BY key names, then one
  /// per ordinary INPUT sort key (an `ORDER BY a + b` over non-projected
  /// columns still needs its input terms). The sort orders by slots into that
  /// row — an output key by its materialised column, an input key by its
  /// appended (or existing input) column — so a computed output key is
  /// evaluated once and its sort value equals the value the row returns.
  ///
  /// The final projection produces each output from that row: a sort-referenced
  /// output READS its materialised slot (never recomputed, preserving the
  /// single evaluation), and any OTHER output computes its expression from the
  /// retained input columns. Without `distinct` this final projection sits
  /// above the cap, so an unreferenced output (`SELECT x, 1 / 0 … ORDER BY x
  /// FETCH FIRST 0 ROWS`) evaluates only for rows the limit keeps — never for a
  /// dropped row, restoring the lazy `Project(Limit(_))` page the all-outputs
  /// shape regressed.
  ///
  /// With `distinct` the dedup runs on the WHOLE projected row, so every output
  /// (not only the sort-referenced ones) is materialised BELOW the distinct —
  /// the lazy split would dedup on a partial row. The `distinct` then dedups
  /// the projected rows and `limit` pages the deduplicated result.
  private func materialised(distinct: Bool, projection: Array<Term>,
                            order: Array<SortKey>, limit: Limit?) -> Plan {
    let width = projection.count

    // Under DISTINCT the dedup needs the full projected row, so materialise
    // every output below the sort (the sort keys are all outputs here) and let
    // the distinct dedup and the limit page the projected rows.
    if distinct {
      var lower = projection
      var keys = Array<(term: Term, ascending: Bool)>()
      keys.reserveCapacity(order.count)
      for key in order {
        if let column = key.column {
          keys.append((term: .slot(column), ascending: key.ascending))
        } else {
          keys.append((term: .slot(lower.count), ascending: key.ascending))
          lower.append(key.term)
        }
      }
      let sorted = Plan.sort(keys: keys, .project(lower, self))
      let outputs = (0 ..< width).map { Term.slot($0) }
      return Plan.distinct(.project(outputs, sorted)).capped(limit: limit)
    }

    // Retain the input columns, then append only the outputs an ORDER BY key
    // names (materialised once) and the input-only sort-key expressions. A
    // non-sort output stays out of this row — it is computed above the limit.
    let inputs = slots ?? 0
    var lower = (0 ..< inputs).map { Term.slot($0) }
    var materialised = Dictionary<Int, Int>()
    var keys = Array<(term: Term, ascending: Bool)>()
    keys.reserveCapacity(order.count)
    for key in order {
      if let column = key.column {
        // Materialise this output once, reusing its slot if an earlier key
        // named it too, and order by that slot.
        let slot: Int
        if let existing = materialised[column] {
          slot = existing
        } else {
          slot = lower.count
          materialised[column] = slot
          lower.append(projection[column])
        }
        keys.append((term: .slot(slot), ascending: key.ascending))
      } else {
        keys.append((term: .slot(lower.count), ascending: key.ascending))
        lower.append(key.term)
      }
    }

    let sorted = Plan.sort(keys: keys, .project(lower, self))
    // Each output reads its materialised slot when a key named it, else
    // computes its expression from the retained inputs (above the cap, lazily).
    let outputs = (0 ..< width).map { column -> Term in
      if let slot = materialised[column] {
        .slot(slot)
      } else {
        projection[column]
      }
    }
    return .project(outputs, sorted.capped(limit: limit))
  }
}

// MARK: - Aggregation

extension Select {
  /// Whether the select aggregates — it has a `GROUP BY`, a `HAVING`, or an
  /// aggregate function anywhere in its projection.
  ///
  /// A query with any of these compiles through the grouped path; one with none
  /// keeps the ordinary `Project(Limit(Sort(Select(_))))` shape unchanged. A
  /// `HAVING` alone (no `GROUP BY`, no aggregate) still aggregates — it filters
  /// the single whole-result group.
  internal var aggregates: Bool {
    if !grouping.isEmpty || having != nil { return true }
    switch projection {
    case .all, .columns:
      return false
    case let .expressions(items):
      return items.contains { $0.expression.aggregated }
    }
  }
}

extension Expression {
  /// Whether the expression contains an aggregate call anywhere within it.
  internal var aggregated: Bool {
    switch self {
    case .column, .literal, .subquery:
      // An aggregate INSIDE a scalar subquery belongs to that subquery, not the
      // enclosing query, so a `subquery` is not an aggregated expression here.
      false
    case .aggregate:
      true
    case let .call(_, arguments):
      arguments.contains { $0.aggregated }
    case let .binary(_, lhs, rhs):
      lhs.aggregated || rhs.aggregated
    case let .case(whens, otherwise):
      whens.contains { $0.when.aggregated || $0.then.aggregated }
          || (otherwise?.aggregated ?? false)
    case let .cast(operand, _):
      operand.aggregated
    case let .coalesce(arguments):
      arguments.contains { $0.aggregated }
    case let .nullif(lhs, rhs):
      lhs.aggregated || rhs.aggregated
    }
  }

  /// Whether the expression references a query binding — a `.bound` predicate —
  /// anywhere within it, reached only through a `CASE` guard (a scalar
  /// expression has no other predicate). A defined-function body is validated
  /// over its parameter schema and evaluated with only its argument record — no
  /// query bindings reach it — so a body naming a `:parameter` is rejected at
  /// registration rather than silently evaluating that reference as UNBOUND.
  internal var bound: Bool {
    switch self {
    case .column, .literal, .aggregate, .subquery:
      // An UNCORRELATED scalar subquery references no query binding of the
      // enclosing query (correlation is a later slice), so it is not bound.
      false
    case let .call(_, arguments):
      arguments.contains { $0.bound }
    case let .binary(_, lhs, rhs):
      lhs.bound || rhs.bound
    case let .case(whens, otherwise):
      whens.contains { $0.when.bound || $0.then.bound }
          || (otherwise?.bound ?? false)
    case let .cast(operand, _):
      operand.bound
    case let .coalesce(arguments):
      arguments.contains { $0.bound }
    case let .nullif(lhs, rhs):
      lhs.bound || rhs.bound
    }
  }
}

extension Predicate.Operand {
  /// Whether this `LIKE` operand contains an aggregate — an expression's own,
  /// never a `:parameter`.
  internal var aggregated: Bool {
    switch self {
    case let .expression(expression): expression.aggregated
    case .parameter: false
    }
  }

  /// Whether this `LIKE` operand references a query binding — an expression's
  /// own, or the operand's OWN `:parameter`, so a defined-function body that
  /// names a `:parameter` in a `LIKE` pattern or escape is rejected at
  /// registration (see `Expression.bound`).
  internal var bound: Bool {
    switch self {
    case let .expression(expression): expression.bound
    case .parameter: true
    }
  }

  /// Collects the distinct aggregates within this `LIKE` operand into
  /// `expressions` — an expression's own, none for a `:parameter`.
  internal func collect(into expressions: inout Array<Expression>) {
    switch self {
    case let .expression(expression): expression.collect(into: &expressions)
    case .parameter: break
    }
  }
}

extension Predicate {
  /// The flat list of top-level `AND`-conjuncts of this predicate in SOURCE
  /// ORDER (a non-`and` is a singleton). The parser leans `AND` left (`a AND b
  /// AND c` is `.and(.and(a, b), c)`), so a left-first flatten yields the
  /// conjuncts as written — the order `Scope.on` walks to bound its safe
  /// key-extraction prefix.
  internal var conjuncts: Array<Predicate> {
    guard case let .and(lhs, rhs) = self else { return [self] }
    return lhs.conjuncts + rhs.conjuncts
  }

  /// Whether the predicate contains an aggregate call anywhere within it — used
  /// to spot an aggregate hiding in a `CASE` guard (`CASE WHEN COUNT(*) > 1
  /// …`), which makes the enclosing query an aggregate one.
  internal var aggregated: Bool {
    switch self {
    case let .comparison(left, _, right):
      left.aggregated || right.aggregated
    case let .bound(left, _, _):
      left.aggregated
    case let .null(operand, _):
      operand.aggregated
    case let .membership(operand, values, _):
      operand.aggregated || values.contains { $0.aggregated }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.aggregated } || rhs.contains { $0.aggregated }
    case let .among(lhs, rows, _):
      lhs.contains { $0.aggregated }
          || rows.contains { $0.contains { $0.aggregated } }
    case .exists:
      // A subquery is its OWN scope, so an aggregate inside it folds over its
      // group, not the enclosing one — it never makes the OUTER query an
      // aggregate one.
      false
    case let .within(operand, _, _):
      // Only the OUTER operand can hold an enclosing-group aggregate; the
      // subquery is its own scope.
      operand.aggregated
    case let .quantified(operand, _, _, _):
      // As `within`: only the OUTER operand can hold an enclosing-group
      // aggregate; the subquery is its own scope.
      operand.aggregated
    case let .like(operand, pattern, escape, _):
      operand.aggregated || pattern.aggregated
          || (escape?.aggregated ?? false)
    case let .between(test, lower, upper, _):
      test.aggregated || lower.aggregated || upper.aggregated
    case let .distinct(lhs, rhs, _):
      lhs.aggregated || rhs.aggregated
    case let .truth(inner, _, _):
      inner.aggregated
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.aggregated || rhs.aggregated
    case let .not(operand):
      operand.aggregated
    }
  }

  /// Whether the predicate references a query binding — a `.bound` operand — in
  /// any position within it. A defined-function body's `CASE` guards are walked
  /// through this to reject a `:parameter` at registration (see
  /// `Expression.bound`).
  internal var bound: Bool {
    switch self {
    case .bound:
      true
    case let .comparison(left, _, right):
      left.bound || right.bound
    case let .null(operand, _):
      operand.bound
    case let .membership(operand, values, _):
      operand.bound || values.contains { $0.bound }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.bound } || rhs.contains { $0.bound }
    case let .among(lhs, rows, _):
      lhs.contains { $0.bound } || rows.contains { $0.contains { $0.bound } }
    case let .exists(query, _):
      // A `:parameter` inside a subquery binds against the SAME run bindings
      // (the subquery runs under the enclosing context), so a defined-function
      // body that nests one still carries a binding to reject at registration.
      query.bound
    case let .within(operand, query, _):
      operand.bound || query.bound
    case let .quantified(operand, _, _, query):
      operand.bound || query.bound
    case let .like(operand, pattern, escape, _):
      operand.bound || pattern.bound || (escape?.bound ?? false)
    case let .between(test, lower, upper, _):
      test.bound || lower.bound || upper.bound
    case let .distinct(lhs, rhs, _):
      lhs.bound || rhs.bound
    case let .truth(inner, _, _):
      inner.bound
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.bound || rhs.bound
    case let .not(operand):
      operand.bound
    }
  }
}

extension Query {
  /// Whether this query references a query binding — a `.bound` operand — in
  /// any predicate within it, descending a set operation's arms. A subquery
  /// nested in a defined-function body is walked through this to reject a
  /// `:parameter` at registration (see `Expression.bound`).
  internal var bound: Bool {
    switch self {
    case let .select(select): select.bound
    case let .setop(_, left, right, _): left.bound || right.bound
    }
  }

  /// The UNCORRELATED subqueries this query nests DIRECTLY — the union of every
  /// arm's `Select.subqueries`, descending a set operation's arms but NOT a
  /// nested subquery's OWN body (each subquery is run as a whole, resolving its
  /// inner subqueries through its own `run`). The run path materialises these
  /// once, keyed by occurrence, so a set operation's every arm reads its own
  /// `EXISTS`/`IN (Q)` result from the SAME cache.
  internal var subqueries: Array<Query> {
    switch self {
    case let .select(select): select.subqueries
    case let .setop(_, left, right, _): left.subqueries + right.subqueries
    }
  }

  /// The subqueries this query nests in an `IN (Q)` position — the ones whose
  /// single COLUMN of values a run reads, so the materialiser runs each in FULL
  /// rather than as a cardinality probe. A subquery only ever an `EXISTS`
  /// operand is absent, so its select list is never evaluated; one used by BOTH
  /// an `EXISTS` and an `IN` appears here (its values are needed), so its lone
  /// full materialisation serves both.
  internal var valued: Set<Query> {
    switch self {
    case let .select(select): select.valued
    case let .setop(_, left, right, _): left.valued.union(right.valued)
    }
  }

  /// The subqueries this query nests in a SCALAR-subquery position — the ones a
  /// run collapses to a single VALUE (empty → NULL, one row → the cell, more →
  /// `SQLError.cardinality`), distinct from a `valued` (`IN`) or `EXISTS`-probe
  /// occurrence. The materialiser reads this to decide a scalar occurrence's
  /// materialisation.
  internal var scalar: Set<Query> {
    switch self {
    case let .select(select): select.scalar
    case let .setop(_, left, right, _): left.scalar.union(right.scalar)
    }
  }

  /// The subqueries this query nests in an `EXISTS (Q)` position — the ones a
  /// run materialises as a cardinality PROBE. The SAME query may ALSO occur as
  /// a `valued` (`IN`) or `scalar` occurrence over identical SQL; each role is
  /// a DISTINCT cache entry (see `Role`), so the materialiser produces an
  /// existential probe entry whenever a query occurs here — never reusing a
  /// `valued`/`scalar` entry for an `EXISTS` read.
  internal var existential: Set<Query> {
    switch self {
    case let .select(select): select.existential
    case let .setop(_, left, right, _):
      left.existential.union(right.existential)
    }
  }
}

extension Select {
  /// Whether this `SELECT` references a query binding — a `.bound` operand — in
  /// its `WHERE`, any join `ON`, or its `HAVING` (the predicate positions a
  /// binding may occur in).
  internal var bound: Bool {
    if predicate?.bound ?? false { return true }
    if joins.contains(where: { $0.on.bound }) { return true }
    return having?.bound ?? false
  }

  /// The UNCORRELATED subqueries this `SELECT` nests DIRECTLY — those in its
  /// `WHERE`, each join `ON`, its `HAVING`, its projection, and its `ORDER BY`
  /// sort-key expressions — in appearance order, for the `compile`/`typecheck`
  /// pre-pass to materialise ONCE.
  ///
  /// It descends this select's own predicates and expressions but NOT into a
  /// nested subquery's OWN body: each subquery is compiled/run as a whole
  /// (`compile(query)`/`run(query)`), which recurses into its inner subqueries
  /// through its own pre-pass, so gathering only the directly-nested ones keeps
  /// the walk one level and lets each subquery own its inner materialisation.
  internal var subqueries: Array<Query> {
    var queries = Array<Query>()
    predicate?.collect(subqueries: &queries)
    for join in joins { join.on.collect(subqueries: &queries) }
    having?.collect(subqueries: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(subqueries: &queries) }
    }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &queries)
      }
    }
    return queries
  }

  /// The subqueries this `SELECT` nests in an `IN (Q)` position — the same
  /// clauses `subqueries` walks, keeping only the `within` operands' queries,
  /// so a run materialises each in FULL for its values while an `EXISTS`-only
  /// subquery stays a cardinality probe.
  internal var valued: Set<Query> {
    var queries = Set<Query>()
    predicate?.collect(valued: &queries)
    for join in joins { join.on.collect(valued: &queries) }
    having?.collect(valued: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(valued: &queries) }
    }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(valued: &queries)
      }
    }
    return queries
  }

  /// The subqueries this `SELECT` nests in a SCALAR-subquery position — the
  /// same clauses `subqueries` walks, keeping only the `Expression.subquery`
  /// queries, so a run materialises each as its collapsed single VALUE (empty →
  /// NULL, one row → the cell, more → `SQLError.cardinality`), distinct from a
  /// `valued` (`IN`, full column) or `EXISTS`-probe occurrence.
  internal var scalar: Set<Query> {
    var queries = Set<Query>()
    predicate?.collect(scalar: &queries)
    for join in joins { join.on.collect(scalar: &queries) }
    having?.collect(scalar: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(scalar: &queries) }
    }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(scalar: &queries)
      }
    }
    return queries
  }

  /// The subqueries this `SELECT` nests in an `EXISTS (Q)` position — the
  /// same clauses `subqueries` walks, keeping only the `exists` operands'
  /// queries, so a run materialises each as a cardinality PROBE under its own
  /// `existential` key, distinct from any `valued`/`scalar` occurrence over the
  /// same SQL.
  internal var existential: Set<Query> {
    var queries = Set<Query>()
    predicate?.collect(existential: &queries)
    for join in joins { join.on.collect(existential: &queries) }
    having?.collect(existential: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(existential: &queries) }
    }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(existential: &queries)
      }
    }
    return queries
  }

  /// The `Role`s `query` occupies within this `SELECT` — `scalar`, `valued`,
  /// and/or `existential` — the SHAPES the lowered nodes carry in their
  /// `Subkey`. The same inner SQL used in more than one position occupies more
  /// than one role, so a correlated occurrence's pre-compiled plan is recorded
  /// under each, matching every lowered node that looks it up.
  internal func roles(of query: Query) -> Array<Role> {
    var roles = Array<Role>()
    if scalar.contains(query) { roles.append(.scalar) }
    if valued.contains(query) { roles.append(.valued) }
    if existential.contains(query) { roles.append(.existential) }
    return roles
  }
}

extension Predicate {
  /// Collects the subqueries this predicate nests DIRECTLY into `queries` — the
  /// whole `Query` of an `exists`/`within`, and any in an operand expression,
  /// a `CASE` guard, or an `AND`/`OR`/`NOT` — WITHOUT descending a collected
  /// subquery's own body (`compile`/`run` recurse into it).
  internal func collect(subqueries queries: inout Array<Query>) {
    switch self {
    case let .exists(query, _):
      queries.append(query)
    case let .within(operand, query, _):
      operand.collect(subqueries: &queries)
      queries.append(query)
    case let .quantified(operand, _, _, query):
      operand.collect(subqueries: &queries)
      queries.append(query)
    case let .comparison(left, _, right):
      left.collect(subqueries: &queries)
      right.collect(subqueries: &queries)
    case let .bound(left, _, _):
      left.collect(subqueries: &queries)
    case let .null(operand, _):
      operand.collect(subqueries: &queries)
    case let .membership(operand, values, _):
      operand.collect(subqueries: &queries)
      for value in values { value.collect(subqueries: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(subqueries: &queries) }
      for expression in rhs { expression.collect(subqueries: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(subqueries: &queries) }
      for element in rows {
        for expression in element { expression.collect(subqueries: &queries) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(subqueries: &queries)
      pattern.collect(subqueries: &queries)
      escape?.collect(subqueries: &queries)
    case let .between(test, lower, upper, _):
      test.collect(subqueries: &queries)
      lower.collect(subqueries: &queries)
      upper.collect(subqueries: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .truth(inner, _, _):
      inner.collect(subqueries: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .not(operand):
      operand.collect(subqueries: &queries)
    }
  }

  /// Whether this predicate nests any `EXISTS`/`IN (Q)` subquery — the schema
  /// path's reachability check reads this to keep a subquery-bearing `HAVING`
  /// from being pruned as unreachable, since its truth is decided at RUN by the
  /// subquery, not statically.
  internal var subquery: Bool {
    var queries = Array<Query>()
    collect(subqueries: &queries)
    return !queries.isEmpty
  }

  /// Collects the subqueries this predicate nests in an `IN (Q)` position into
  /// `queries` — ONLY a `within`'s `Query`, recursing the same structure
  /// `collect(subqueries:)` does. An `exists`'s `Query` is NOT collected — its
  /// values are never read — so it materialises as a probe.
  internal func collect(valued queries: inout Set<Query>) {
    switch self {
    case .exists:
      // An `EXISTS` operand's values are never read — it materialises as a
      // cardinality probe — so it is NOT a valued occurrence.
      break
    case let .within(operand, query, _):
      operand.collect(valued: &queries)
      queries.insert(query)
    case let .quantified(operand, _, _, query):
      // A quantified comparison reads the subquery's full COLUMN — folding `x
      // op v` over every value — so it materialises FULL under the `.valued`
      // role, exactly as `IN (Q)` does, never a cardinality probe.
      operand.collect(valued: &queries)
      queries.insert(query)
    case let .comparison(left, _, right):
      left.collect(valued: &queries)
      right.collect(valued: &queries)
    case let .bound(left, _, _):
      left.collect(valued: &queries)
    case let .null(operand, _):
      operand.collect(valued: &queries)
    case let .membership(operand, values, _):
      operand.collect(valued: &queries)
      for value in values { value.collect(valued: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(valued: &queries) }
      for expression in rhs { expression.collect(valued: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(valued: &queries) }
      for element in rows {
        for expression in element { expression.collect(valued: &queries) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(valued: &queries)
      pattern.collect(valued: &queries)
      escape?.collect(valued: &queries)
    case let .between(test, lower, upper, _):
      test.collect(valued: &queries)
      lower.collect(valued: &queries)
      upper.collect(valued: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .truth(inner, _, _):
      inner.collect(valued: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .not(operand):
      operand.collect(valued: &queries)
    }
  }

  /// Collects the SCALAR-subquery-position queries this predicate nests into
  /// `queries` — an operand expression's own `subquery`, a `CASE` guard's, and
  /// those under `AND`/`OR`/`NOT`, mirroring `collect(subqueries:)`. An
  /// `EXISTS`/`IN (Q)`'s own `Query` is NOT a scalar occurrence — it is
  /// probed/valued — so it is not collected here.
  internal func collect(scalar queries: inout Set<Query>) {
    switch self {
    case .exists:
      break
    case let .within(operand, _, _):
      operand.collect(scalar: &queries)
    case let .quantified(operand, _, _, _):
      // As `within`: the quantified subquery is `valued`, not scalar; only the
      // outer operand's own subqueries are descended.
      operand.collect(scalar: &queries)
    case let .comparison(left, _, right):
      left.collect(scalar: &queries)
      right.collect(scalar: &queries)
    case let .bound(left, _, _):
      left.collect(scalar: &queries)
    case let .null(operand, _):
      operand.collect(scalar: &queries)
    case let .membership(operand, values, _):
      operand.collect(scalar: &queries)
      for value in values { value.collect(scalar: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(scalar: &queries) }
      for expression in rhs { expression.collect(scalar: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(scalar: &queries) }
      for element in rows {
        for expression in element { expression.collect(scalar: &queries) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(scalar: &queries)
      pattern.collect(scalar: &queries)
      escape?.collect(scalar: &queries)
    case let .between(test, lower, upper, _):
      test.collect(scalar: &queries)
      lower.collect(scalar: &queries)
      upper.collect(scalar: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .truth(inner, _, _):
      inner.collect(scalar: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .not(operand):
      operand.collect(scalar: &queries)
    }
  }

  /// Collects the `EXISTS (Q)`-position subqueries this predicate nests into
  /// `queries` — ONLY an `exists`'s `Query`, recursing the same structure
  /// `collect(subqueries:)` does. An `IN (Q)`'s `Query` is NOT collected
  /// here — its values are read, so it is a `valued` occurrence, not an
  /// existential one — but its operand's own subqueries are still descended.
  internal func collect(existential queries: inout Set<Query>) {
    switch self {
    case let .exists(query, _):
      queries.insert(query)
    case let .within(operand, _, _):
      operand.collect(existential: &queries)
    case let .quantified(operand, _, _, _):
      // A quantified subquery is `valued` (its full column is read), not an
      // existential probe; only the outer operand is descended here.
      operand.collect(existential: &queries)
    case let .comparison(left, _, right):
      left.collect(existential: &queries)
      right.collect(existential: &queries)
    case let .bound(left, _, _):
      left.collect(existential: &queries)
    case let .null(operand, _):
      operand.collect(existential: &queries)
    case let .membership(operand, values, _):
      operand.collect(existential: &queries)
      for value in values { value.collect(existential: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(existential: &queries) }
      for expression in rhs { expression.collect(existential: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(existential: &queries) }
      for element in rows {
        for expression in element {
          expression.collect(existential: &queries)
        }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(existential: &queries)
      pattern.collect(existential: &queries)
      escape?.collect(existential: &queries)
    case let .between(test, lower, upper, _):
      test.collect(existential: &queries)
      lower.collect(existential: &queries)
      upper.collect(existential: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .truth(inner, _, _):
      inner.collect(existential: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .not(operand):
      operand.collect(existential: &queries)
    }
  }
}

extension Predicate.Operand {
  /// Collects the subqueries in this `LIKE` operand — an expression's own, none
  /// for a `:parameter`.
  internal func collect(subqueries queries: inout Array<Query>) {
    if case let .expression(expression) = self {
      expression.collect(subqueries: &queries)
    }
  }

  /// Collects the `IN (Q)`-position subqueries in this `LIKE` operand — an
  /// expression's own, none for a `:parameter`.
  internal func collect(valued queries: inout Set<Query>) {
    if case let .expression(expression) = self {
      expression.collect(valued: &queries)
    }
  }

  /// Collects the scalar-subquery-position queries in this `LIKE` operand — an
  /// expression's own, none for a `:parameter`.
  internal func collect(scalar queries: inout Set<Query>) {
    if case let .expression(expression) = self {
      expression.collect(scalar: &queries)
    }
  }

  /// Collects the `EXISTS (Q)`-position subqueries in this `LIKE` operand —
  /// an expression's own, none for a `:parameter`.
  internal func collect(existential queries: inout Set<Query>) {
    if case let .expression(expression) = self {
      expression.collect(existential: &queries)
    }
  }
}

extension Expression {
  /// Collects the subqueries this expression nests DIRECTLY into `queries` —
  /// its own scalar `subquery`, and those reached through a `CASE` guard or an
  /// aggregate's argument/FILTER — recursing its call arguments, arithmetic,
  /// aggregate operand and FILTER, `CASE`, `CAST`, `COALESCE`, and `NULLIF`
  /// sub-expressions WITHOUT descending a collected subquery's own body
  /// (`compile`/`run` recurse into it). A scalar `Expression.subquery` is
  /// collected so the pre-pass compiles it (for its width and type) and the run
  /// materialises its single value.
  internal func collect(subqueries queries: inout Array<Query>) {
    switch self {
    case .column, .literal:
      break
    case let .subquery(query):
      queries.append(query)
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(subqueries: &queries)
      }
      filter?.collect(subqueries: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(subqueries: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(subqueries: &queries)
        when.then.collect(subqueries: &queries)
      }
      otherwise?.collect(subqueries: &queries)
    case let .cast(operand, _):
      operand.collect(subqueries: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(subqueries: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    }
  }

  /// Collects the `IN (Q)`-position subqueries this expression nests — reached
  /// through a `CASE` guard or an aggregate's argument/FILTER, mirroring
  /// `collect(subqueries:)`. An `EXISTS` guard contributes none (it probes),
  /// and a SCALAR `subquery` contributes none here — its single value is read
  /// (`scalar`), not its column (`values`), so it is a `scalar` occurrence, not
  /// a `valued` one.
  internal func collect(valued queries: inout Set<Query>) {
    switch self {
    case .column, .literal, .subquery:
      break
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(valued: &queries)
      }
      filter?.collect(valued: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(valued: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(valued: &queries)
        when.then.collect(valued: &queries)
      }
      otherwise?.collect(valued: &queries)
    case let .cast(operand, _):
      operand.collect(valued: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(valued: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    }
  }

  /// Collects the SCALAR-subquery-position queries this expression nests — its
  /// own `subquery`, and those reached through a `CASE` guard or an aggregate's
  /// argument/FILTER, mirroring `collect(subqueries:)`. A scalar occurrence is
  /// materialised as its collapsed single VALUE (empty → NULL, one row → the
  /// cell, more → `SQLError.cardinality`), distinct from a `valued` (`IN`) or
  /// `EXISTS`-probe occurrence.
  internal func collect(scalar queries: inout Set<Query>) {
    switch self {
    case .column, .literal:
      break
    case let .subquery(query):
      queries.insert(query)
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(scalar: &queries)
      }
      filter?.collect(scalar: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(scalar: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(scalar: &queries)
        when.then.collect(scalar: &queries)
      }
      otherwise?.collect(scalar: &queries)
    case let .cast(operand, _):
      operand.collect(scalar: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(scalar: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    }
  }

  /// Collects the `EXISTS (Q)`-position subqueries this expression nests —
  /// reached through a `CASE` guard or an aggregate's FILTER, mirroring
  /// `collect(subqueries:)`. A scalar `subquery` contributes none here — its
  /// value is read, so it is a `scalar` occurrence, not an existential one.
  internal func collect(existential queries: inout Set<Query>) {
    switch self {
    case .column, .literal, .subquery:
      break
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(existential: &queries)
      }
      filter?.collect(existential: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(existential: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(existential: &queries)
        when.then.collect(existential: &queries)
      }
      otherwise?.collect(existential: &queries)
    case let .cast(operand, _):
      operand.collect(existential: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(existential: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    }
  }

  /// Whether this expression nests any `EXISTS`/`IN (Q)`/scalar subquery —
  /// reached through a `CASE` guard or an aggregate's argument/FILTER, or its
  /// own scalar `subquery`. The empty-fold reads this to VALIDATE a
  /// subquery-guarded projection or sort expression (whose selected branch a
  /// run decides at RUN by the subquery, not statically) rather than prune it,
  /// so `columns(of:)` surfaces the same fault the run would (`SELECT CASE WHEN
  /// EXISTS (Q) THEN 1 / 0 …` raises `.divide`). A subquery-free expression
  /// keeps the precise empty-fold.
  internal var subquery: Bool {
    var queries = Array<Query>()
    collect(subqueries: &queries)
    return !queries.isEmpty
  }
}

// MARK: - Aggregation

extension Catalog where Self: ~Escapable {
  /// Compiles an aggregate `select` into `Project(Limit(Sort(Having(Aggregate(
  /// source)))))`, the `source` the WHERE/join chain and the aggregate node
  /// grouping it.
  ///
  /// The source (a scan, or a left-deep join chain) materialises exactly the
  /// ordinals the WHERE, the `GROUP BY` keys, and the aggregate arguments read.
  /// The `aggregate` node groups it by the keys and folds each aggregate over a
  /// group, yielding grouped records whose slots are the key values then the
  /// aggregate results. The projection, `HAVING`, and `ORDER BY` lower against
  /// that grouped slot space through a `Grouping`, which also enforces the
  /// standard rule that every non-aggregated projection/`ORDER BY` column
  /// appear in the `GROUP BY`.
  internal borrowing func group(_ select: Select, _ relation: Relation,
                                _ from: Resolved, _ context: Context)
      throws(SQLError) -> Plan {
    // The augmented `context` threads to `subquery(of:)`, which REVEALS the
    // base — this select's and every enclosing select's derived aliases
    // dropped, the CTEs and store relations kept — before lowering a nested
    // subquery, so its FROM sees no derived alias while a CTE a same-named
    // derived alias shadows stays visible (a grouped `ORDER BY SUM((SELECT x
    // FROM d))` reads the CTE `d` beneath the derived `d`). Resolve every
    // joined relation and lay the FROM relation and each joined one end to end
    // in one combined ordinal space (as the non-aggregate join path does), so
    // the WHERE, keys, and aggregate arguments resolve uniformly. A LATERAL
    // join under a GROUP BY / aggregate query is a deliberate follow-up — the
    // grouped path forms a single-relation chain differently from the
    // correlated apply — so fault it rather than mis-plan.
    for join in select.joins where join.relation.lateral {
      throw .state("0A000",
                   "a LATERAL join under an aggregate is not supported")
    }
    let (joined, relations) = try resolve(from: relation, schema: from.schema,
                                          joins: select.joins, context)
    let scope = Scope(relations)

    // Each join's ON predicate lowers to a `Filter` at its own chain level,
    // resolved against only the prefix already in scope (as the non-aggregate
    // path does). A `column = column` conjunct becomes a `match` hash-join key;
    // the rest is a residual the join runs as a filter.
    // Each join's PREFIX scope — the relations available AT that join point,
    // never one joined LATER — the scope its `ON` lowers against and a subquery
    // in that `ON` correlates against.
    let prefixes = select.joins.indices.map { index in
      Scope(Array(relations[0 ... index + 1]))
    }
    // Compile every nested subquery ONCE for arity/type, ahead of lowering, and
    // discover each one's CORRELATION: a join `ON`'s against its PREFIX scope,
    // the WHERE against the join `scope`. Only the WHERE and join ONs admit a
    // correlated column of THIS query; the aggregations, projection, `HAVING`,
    // and `ORDER BY` lower under a BARRED seam. `validate` gates the eager
    // type-check of a filtered-out derived body a nested subquery names, off on
    // the RUN path, on for a schema check.
    let plans = try subquery(of: select, context, enclosing: scope,
                             prefixes: prefixes)
    let barred = plans.rest.barred
    var matches = Array<Filter>()
    matches.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      let join = select.joins[index]
      try matches.append(prefixes[index].on(join.on, context.routines,
                                            subquery: plans.on(index)))
    }
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause, context.routines,
                                  subquery: plans.rest)
    }

    // The `GROUP BY` keys and the aggregate arguments lower to combined
    // base-ordinal terms; the aggregates are collected from the projection, the
    // `HAVING`, and the `ORDER BY` sort keys (deduplicated so the same
    // aggregate computes once).
    let keys = try select.grouping.map { column throws(SQLError) -> Term in
      // A grouping key a local relation binds reads its combined slot; one NONE
      // binds is a candidate CORRELATED reference (a LATERAL body grouping on a
      // preceding column) — the same `barred` surface the projection/HAVING use
      // lowers it to a `Term.parameter` the apply binds per outer row (a
      // per-invocation constant → one group), admitting it only under the
      // LATERAL `everywhere` seam and faulting `.unsupported` on an ordinary
      // grouped subquery. The final `ordinal(of:)` re-throws a genuine
      // unknown-column `.column`.
      if let ordinal = try scope.find(column) { return .slot(ordinal) }
      if let name = try barred.correlate(column) { return .parameter(name) }
      return try .slot(scope.ordinal(of: column))
    }
    var expressions = Array<Expression>()
    for expression in select.projection.projected {
      expression.collect(into: &expressions)
    }
    if let having = select.having {
      having.collect(into: &expressions)
    }
    // A grouped `ORDER BY` may sort on an aggregate that is neither projected
    // nor in the `HAVING` (`GROUP BY Dept ORDER BY COUNT(*) DESC`), so collect
    // its sort-key expressions too.
    if let order = select.order {
      for key in order.keys {
        if case let .expression(expression) = key.sort {
          expression.collect(into: &expressions)
        }
      }
    }
    // Resolve each collected aggregate and dedup by its RESOLVED
    // `Aggregation` — function plus resolved argument term. `collect` deduped
    // only exact AST spellings, so a qualification-equivalent pair
    // (`SUM(Amount)` projected, `SUM(Sales.Amount)` in the `ORDER BY`) survived
    // as two expressions; both resolve to the same `Aggregation` in a
    // single-relation scope, so this folds them into ONE grouped slot — the
    // aggregate computes once and both clauses read/order that slot (which lets
    // the DISTINCT sort-key check accept it).
    var aggregations = Array<Aggregation>()
    for expression in expressions {
      let aggregation = try expression.aggregation(scope, context.routines,
                                                   subquery: barred)
      if !aggregations.contains(aggregation) {
        aggregations.append(aggregation)
      }
    }

    // The source materialises exactly the ordinals the WHERE, the keys, and the
    // aggregate arguments read — never the projection/HAVING/ORDER, which read
    // the GROUPED record. Pack them per relation in chain order, building the
    // combined-ordinal → slot map and each relation's leaf ordinals.
    var references = Set<Int>()
    for match in matches { match.references(into: &references) }
    predicate?.references(into: &references)
    for key in keys { key.references(into: &references) }
    for aggregation in aggregations {
      aggregation.references(into: &references)
    }
    let combined = references.sorted()

    var slot = Dictionary<Int, Int>(minimumCapacity: combined.count)
    var locals = Array<Array<Int>>()
    var packed = 0
    for (offset, extent) in scope.layout {
      let local = combined.compactMap {
        offset <= $0 && $0 < offset + extent ? $0 - offset : nil
      }
      for index in local.indices {
        slot[offset + local[index]] = packed + index
      }
      locals.append(local)
      packed += local.count
    }

    let seed = from.leaf(locals[0])
    var chain = select.joins.indices.reduce(seed) { chain, index in
      let leaf = joined[index].leaf(locals[index + 1])
      let on = matches[index].remapped(through: slot)
      switch select.joins[index].kind {
      case .inner:
        return .select(on, .product(chain, leaf))
      case .left, .right, .full:
        return .outer(chain, leaf, on: on, kind: select.joins[index].kind)
      }
    }
    if let predicate {
      chain = .select(predicate.remapped(through: slot), chain)
    }

    // The aggregate node groups the source by the remapped keys and folds each
    // aggregate; its output is the grouped slot space the rest lowers against.
    let node = Plan.aggregate(keys: keys.map { $0.remapped(through: slot) },
                              aggregates: aggregations.map {
                                $0.remapped(through: slot)
                              }, chain)

    // Lower the projection, HAVING, and ORDER BY against the grouped slot
    // space, enforcing the projection rule (every non-aggregated column must be
    // a GROUP BY key).
    var grouping = try Grouping(scope, select.grouping, aggregations,
                                subquery: barred)
    let projection = try grouping.terms(select.projection, context.routines,
                                        subquery: barred)
    let having: Filter? = if let clause = select.having {
      try grouping.lower(clause, context.routines, subquery: barred)
    } else {
      nil
    }
    var order = if let clause = select.order {
      try grouping.order(clause, projection, context.routines,
                         subquery: barred)
    } else {
      Array<SortKey>()
    }

    // Under DISTINCT every ORDER BY key must be a select-list value — the
    // dedup runs on the projected rows, so ordering on a dropped value is
    // ill-defined (see `distinct`). The order keys and projection are
    // in grouped-slot space here, aligned with the AST keys index-for-index.
    // A key matching a projected term is rebound to that projected column so
    // the sort reuses the materialised slot rather than re-evaluating it.
    if select.distinct, let clause = select.order {
      order = try distinct(clause.keys, order, projection)
    }

    // The HAVING filters groups below the sort, the slot the WHERE occupies on
    // the non-aggregate path, so the shared `shaped` applies it identically —
    // an ORDER BY key naming a COMPUTED aggregate output (`COUNT(*) * 2 AS n`)
    // then materialises once and sorts on the returned value.
    return node.shaped(distinct: select.distinct, projection: projection,
                       filter: having, order: order, limit: select.limit)
  }
}

extension Projection {
  /// The projected expressions — an `expressions` list yields each item's
  /// expression; a `*` or bare-column list yields none (no aggregate can hide
  /// in them). An aggregate query's projection is always the `expressions` case
  /// (an aggregate call makes it one).
  internal var projected: Array<Expression> {
    switch self {
    case .all, .columns:
      []
    case let .expressions(items):
      items.map(\.expression)
    }
  }
}

extension Expression {
  /// Collects the distinct aggregate expressions within this expression into
  /// `expressions`, in first-appearance order — the same aggregate written
  /// twice computes once.
  internal func collect(into expressions: inout Array<Expression>) {
    switch self {
    case .column, .literal, .subquery:
      // An aggregate inside a scalar `subquery` belongs to THAT subquery's own
      // grouping, not the enclosing query's, so it is not collected here — the
      // subquery is compiled and run as a whole plan.
      break
    case .aggregate:
      if !expressions.contains(self) {
        expressions.append(self)
      }
    case let .call(_, arguments):
      for argument in arguments { argument.collect(into: &expressions) }
    case let .binary(_, lhs, rhs):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .case(whens, otherwise):
      for branch in whens {
        branch.when.collect(into: &expressions)
        branch.then.collect(into: &expressions)
      }
      otherwise?.collect(into: &expressions)
    case let .cast(operand, _):
      operand.collect(into: &expressions)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(into: &expressions) }
    case let .nullif(lhs, rhs):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    }
  }

  /// Lowers this AST `.aggregate` expression to an `Aggregation`, its argument
  /// (if any) and its `FILTER` predicate resolved to combined base-ordinal
  /// forms through `scope`.
  ///
  /// `COUNT(*)` has no argument (it counts rows); every other aggregate lowers
  /// its single operand expression to a term. The `DISTINCT` set quantifier
  /// carries through as a flag; a `FILTER (WHERE …)` lowers to a source-space
  /// `Filter` — the same combined base-ordinal space the argument resolves in,
  /// so it reads the pre-aggregation row the fold gates on. `self` is always an
  /// `.aggregate` — `collect` gathers only those.
  internal func aggregation(_ scope: Scope, _ routines: Routines = [:],
                            subquery: Resolution = .unsupported)
      throws(SQLError) -> Aggregation {
    guard case let .aggregate(function, operand, distinct, filter) = self else {
      throw .state("XX000", "expected an aggregate")
    }
    let argument: Term? = switch operand {
    case .star:
      nil
    case let .expression(expression):
      try scope.term(expression, routines, subquery: subquery)
    }
    let gate: Filter? = if let filter {
      try scope.lower(filter, routines, subquery: subquery)
    } else {
      nil
    }
    return Aggregation(function: function, argument: argument,
                       distinct: distinct, filter: gate)
  }
}

extension Predicate {
  /// Collects the distinct aggregates within this predicate into `expressions`.
  internal func collect(into expressions: inout Array<Expression>) {
    switch self {
    case let .comparison(left, _, right):
      left.collect(into: &expressions)
      right.collect(into: &expressions)
    case let .bound(left, _, _):
      left.collect(into: &expressions)
    case let .null(expression, _):
      expression.collect(into: &expressions)
    case let .membership(operand, values, _):
      operand.collect(into: &expressions)
      for value in values { value.collect(into: &expressions) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(into: &expressions) }
      for expression in rhs { expression.collect(into: &expressions) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(into: &expressions) }
      for element in rows {
        for expression in element { expression.collect(into: &expressions) }
      }
    case .exists:
      // A subquery is its own scope — an aggregate inside it folds over its
      // group, not the enclosing one — so it contributes none here.
      break
    case let .within(operand, _, _):
      // Only the OUTER operand may hold an enclosing-group aggregate.
      operand.collect(into: &expressions)
    case let .quantified(operand, _, _, _):
      // As `within`: only the OUTER operand may hold an enclosing-group
      // aggregate.
      operand.collect(into: &expressions)
    case let .like(operand, pattern, escape, _):
      operand.collect(into: &expressions)
      pattern.collect(into: &expressions)
      escape?.collect(into: &expressions)
    case let .between(test, lower, upper, _):
      test.collect(into: &expressions)
      lower.collect(into: &expressions)
      upper.collect(into: &expressions)
    case let .distinct(lhs, rhs, _):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .truth(inner, _, _):
      inner.collect(into: &expressions)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .not(operand):
      operand.collect(into: &expressions)
    }
  }
}

// MARK: - Optimisation

extension Catalog where Self: ~Escapable {
  /// Rewrites the logical `plan` into a physical one, re-resolving relations by
  /// name through this catalog for their seekability and a bound key through
  /// `bindings` so it seeks like a literal.
  ///
  /// Two pattern rewrites fire, the rest of the tree recursing unchanged:
  ///
  /// (a) **Seek.** A `Select` over a full `Scan` whose predicate (or a
  ///     conjunct of it) is a sort-key equality or range on a seekable column
  ///     becomes a seeked `Scan`, the remaining predicate kept as a residual
  ///     `Select`.
  ///
  /// (b) **Index-nested-loop join.** A `Select` over a `Product` whose
  ///     predicate carries a `match` conjunct relating an outer-side ordinal to
  ///     an inner-side ordinal — the inner side a bare `Scan` — becomes a
  ///     `Join` that seeks the inner per outer record, the remaining conjuncts
  ///     kept as a residual `Select`. If the inner side is not a bare `Scan`,
  ///     the product stays (a plain nested loop).
  internal borrowing func optimise(_ plan: Plan, _ bindings: Bindings)
      throws(SQLError) -> Plan {
    try optimise(plan, Context(bindings: bindings))
  }

  /// Rewrites `plan` into a physical one under `context` — the in-scope overlay
  /// (consulted before the base catalog for seekability) and the bindings a
  /// bound key seeks like a literal.
  internal borrowing func optimise(_ plan: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    switch plan {
    case .single:
      plan
    case .scan:
      plan
    case let .derived(name, plan, ordinals, seek):
      // Optimise the view's sub-plan with the bindings so a bound predicate
      // inside the view seeks; the derived leaf itself carries no sort key, so
      // the outer query still scans its result as is. The sub-plan resolves
      // OUTSIDE the statement's CTE scope — never a caller's `WITH` — so a view
      // means what it was registered to mean; its scope is the
      // `definition_schema.` overlay its OWN query names (the same one it
      // compiled under), so a view body's store scan re-resolves.
      //
      // A SET-OPERATION view body's arm scans an arm-local derived alias the
      // whole-view overlay does not bind (arms are SELECT-scoped), so `seek`
      // would fault `.relation` resolving it. Optimise each arm under THAT
      // arm's own augmented overlay — the same per-arm scope `derive`/`setop`
      // execute it under — so the arm's `d` resolves for the seek rewrite.
      try .derived(name: name,
                   plan: optimise(view: name, plan, context),
                   ordinals: ordinals, seek: seek)
    case let .select(filter, source) where filter.constant == true:
      // A PROVABLY-always-true filter admits every row, so the select is a
      // no-op: drop it and optimise the source alone — identical result, one
      // fewer per-row predicate. This composes with the seek and nest cases
      // below: a constant-true filter over a `.scan` or `.product` never
      // reaches them, becoming just the optimised source (a plain scan or
      // product), not a seek over a true residual or a nest with a true gate. A
      // constant-FALSE filter is NOT folded — there is no empty-relation Plan
      // node, so a false filter is left filtering correctly (see the deferred
      // empty-plan follow-up).
      try optimise(source, context)
    case let .select(filter, .scan(name, ordinals, nil)):
      try seek(filter, name, ordinals, context)
    case let .select(filter, .product(left, right)):
      try nest(filter, left, right, context)
    case let .select(filter, source):
      try .select(filter, optimise(source, context))
    case let .project(ordinals, source):
      try .project(ordinals, optimise(source, context))
    case let .sort(keys, source):
      try .sort(keys: keys, optimise(source, context))
    case let .product(left, right):
      try .product(optimise(left, context), optimise(right, context))
    case .join:
      plan
    case let .outer(left, right, on, kind):
      // Optimise each side (a nested inner join or a seekable scan inside a
      // side still rewrites), but keep the outer node and its `on` intact — the
      // `on` governs matching and must not fold into a product or push onto a
      // leaf, or an unmatched preserved row would be dropped rather than
      // NULL-extended.
      try .outer(optimise(left, context), optimise(right, context), on: on,
                 kind: kind)
    case let .semijoin(left, right, on, anti):
      // Optimise each side (a nested join or seekable scan inside a side still
      // rewrites), but keep the semijoin node and its `on` intact — the `on`
      // governs the existence test and must not fold into a product or onto
      // a leaf, or a surviving/excluded left row would change. The executor's
      // hash fast-path keys on the straddling equi `.match` this `on` holds.
      try .semijoin(optimise(left, context), optimise(right, context), on: on,
                    anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // Optimise the left side (a seekable scan or a nested join inside it
      // still rewrites), but keep the apply node, its `on`, and its recorded
      // body plan intact — the body re-executes per outer row and was already
      // compiled and pushed down under its own scope, so the outer optimise
      // never reshapes it.
      try .apply(optimise(left, context), key: key, correlation: correlation,
                 ordinals: ordinals, on: on, kind: kind)
    case let .setop(kind, left, right, all):
      // Optimise each side with the same bindings so a bound predicate inside
      // an arm seeks; the set operation itself merely combines its sides,
      // preserving this node's own `kind` and `all`.
      try .setop(kind, optimise(left, context), optimise(right, context),
                 all: all)
    case let .distinct(source):
      // A `distinct` dedups its source without a seek or join of its own;
      // optimise the source below it and rewrap.
      try .distinct(optimise(source, context))
    case let .aggregate(keys, aggregates, source):
      // An aggregate reshapes its source and has no seek or join of its own;
      // optimise its source (the WHERE/join chain below it seeks and nests as
      // usual) and rewrap. The `HAVING`/projection sit above it as `select`s
      // the recursion reaches through here, but their grouped-space slots never
      // seek a base relation.
      try .aggregate(keys: keys, aggregates: aggregates,
                     optimise(source, context))
    case let .limit(count, offset, source):
      // A `limit` is a transparent wrapper — optimise its source and re-cap;
      // the cap itself has no seek or join to rewrite.
      try .limit(count: count, offset: offset, optimise(source, context))
    }
  }

  /// Optimises a VIEW body's sub-`plan` for the view named `name`, resolving
  /// its scans under the view's OWN overlay rather than a caller's scope.
  ///
  /// A SINGLE-arm body optimises under the whole-view overlay
  /// (`overlay(name:)`) — the same scope it compiled under. A SET-OPERATION
  /// body optimises each ARM under THAT arm's own augmented overlay: an arm
  /// scans its arm-local derived alias, which the whole-view overlay does not
  /// bind (arms are SELECT-scoped), so `seek` would fault `.relation` resolving
  /// it. The `plan` tree mirrors the `query` tree, so this descends the two in
  /// lockstep — a `.setop` node recurses into both arms, a LEAF arm augments
  /// the arm's aliases SCHEMA-ONLY (`rows: false`, so `seek` treats them as
  /// unseekable materialised relations by name/schema WITHOUT executing a
  /// derived body) and optimises the arm sub-plan under that arm-local scope —
  /// matching the per-arm scope `derive`/`setop` execute it under.
  private borrowing func optimise(view name: String, _ plan: Plan,
                                  _ context: Context)
      throws(SQLError) -> Plan {
    let overlay = try overlay(name, context)
    guard let view = resolve(view: name), case .setop = view.query,
        case .setop = plan else {
      return try optimise(plan, overlay)
    }
    return try optimise(plan, view.query, overlay)
  }

  /// Optimises a view body's SET-OPERATION `plan` arm by arm, each arm sub-plan
  /// under `overlay` AUGMENTED with THAT arm's own derived aliases, descending
  /// the `plan` and `query` trees in lockstep (they mirror each other).
  private borrowing func optimise(_ plan: Plan, _ query: Query,
                                  _ overlay: Context)
      throws(SQLError) -> Plan {
    if case let .setop(kind, left, right, all) = plan,
        case let .setop(_, leftQuery, rightQuery, _) = query {
      return try .setop(kind, optimise(left, leftQuery, overlay),
                        optimise(right, rightQuery, overlay), all: all)
    }
    // Schema-only (`rows: false`): the optimiser needs the arm's derived alias
    // bound by name/schema so `seek` treats it as an unseekable materialised
    // relation — NOT its rows. Materialising here would EXECUTE the arm's
    // derived body during optimisation (a stateful routine would run once here
    // and again at `derive`), so bind schema-only and let the single execution
    // happen at run.
    //
    // `validate: false` — this is the RUN path's optimiser, matching the
    // `overlay(name:)` above: `resolve`/`compile` already validated the view
    // body under the caller's `validate`, so an arm's data-dependent-empty
    // derived body must not be re-type-checked here and fault a run that its
    // filtered-out rows never reach.
    return try optimise(plan, augment(overlay.validating(false), for: query,
                                      rows: false))
  }

  // MARK: - Physical seek

  /// Rewrites `Select(filter, Scan(name, ordinals, nil))` into a seeked scan
  /// when a sort-key conjunct qualifies, else leaves the full scan under the
  /// filter. The relation re-resolves through this catalog for its boundaries.
  ///
  /// A standalone qualifying comparison seeks its run and admits all of it (no
  /// residual). An `AND` with one qualifying conjunct seeks that run and keeps
  /// the other as the residual `Select` — but ONLY when that residual is safe,
  /// since seeking narrows the scan and a throwing residual would then raise
  /// over just the sought run, suppressing a throw the un-seeked scan owes on a
  /// skipped row. Everything else scans under the whole filter. The `filter` is
  /// in slot space, so a comparison's slot maps back to its table ordinal
  /// through the scan's `ordinals` before reading a boundary.
  private borrowing func seek(_ filter: Filter, _ name: String,
                              _ ordinals: Array<Int>, _ context: Context)
      throws(SQLError) -> Plan {
    // A materialised CTE relation stores no sort key, so it is never seekable —
    // leave the scan under the whole filter.
    guard context.relations[name.lowercased()] == nil else {
      return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
    }
    guard let table = table(named: name) else { throw .relation(name) }
    let count = table.cursor().count

    let bindings = context.bindings
    if let range = table.boundaries(filter, ordinals, count, bindings) {
      return .scan(name: name, ordinals: ordinals, seek: range)
    }

    // Seek by one conjunct only when the OTHER — the residual, then run over
    // just the sought run — is safe. Seeking narrows the scan, so a residual
    // that can throw would raise only on the rows the seek kept, suppressing a
    // throw the un-seeked scan owes on a skipped row: `(1 / x) = 0 AND id < 0`
    // over an id-sorted table (an empty id < 0 run) must still raise the
    // division rather than seek past it, as must a grouped `… AND (… AND id <
    // 0)` the left fold rebuilds so a seekable `id < 0` is the top-level RHS.
    if case let .and(lhs, rhs) = filter {
      if rhs.safe,
          let range = table.boundaries(lhs, ordinals, count, bindings) {
        return .select(rhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
      if lhs.safe,
          let range = table.boundaries(rhs, ordinals, count, bindings) {
        return .select(lhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
    }

    return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
  }
}

/// The seekable `(slot, op, integer)` of `filter`: a `compare` against an
/// integer literal, or a `bound` whose parameter resolves to an integer in
/// `bindings`. A string operand, an unbound or non-integer parameter, or a
/// non-comparison does not qualify, and the relation scans.
private func comparison(_ filter: Filter, _ bindings: Bindings)
    -> (Int, Comparison, Int)? {
  switch filter {
  case let .compare(.slot(slot), op, .constant(.integer(value))):
    (slot, op, value)
  case let .bound(.slot(slot), op, parameter):
    if case let .integer(value)? = bindings[parameter] {
      (slot, op, value)
    } else {
      nil
    }
  default:
    nil
  }
}

/// The seekable `(slot, lower, upper)` of a non-negated `x BETWEEN lower AND
/// upper` whose test `x` is a `slot` and whose bounds EACH resolve to an
/// integer — a `.term` integer literal, or a `:parameter` bound to an integer
/// in `bindings`, the same resolution `comparison` applies to a `.bound` — a
/// two-sided run the seek reads directly off the sorted key, exactly the range
/// `x >= lower AND x <= upper` would seek, so a fully-bound parameterised range
/// seeks rather than regressing to a scan. A `NOT BETWEEN` (the complement is
/// two disjoint runs, not one contiguous seek), a non-slot test, or a bound
/// that does not resolve to an integer (a non-constant term, a string, or an
/// unbound or non-integer parameter) does not qualify, and the relation scans
/// under the residual `between`.
private func range(_ filter: Filter, _ bindings: Bindings) -> (Int, Int, Int)? {
  guard case let .between(.slot(slot), lower, upper, negated: false) = filter,
      let low = integer(lower, bindings),
      let high = integer(upper, bindings) else {
    return nil
  }
  return (slot, low, high)
}

/// The integer a BETWEEN bound seeks on: a `.term` integer literal, or a
/// `:parameter` bound to an integer in `bindings` — the same resolution
/// `comparison` gives a `.bound`'s parameter. Any other operand — a
/// non-constant term, a non-integer constant, or an unbound or non-integer
/// parameter — does not seek (`nil`), and the residual `between` runs instead.
private func integer(_ operand: Filter.Operand, _ bindings: Bindings) -> Int? {
  switch operand {
  case let .term(.constant(.integer(value))):
    value
  case let .parameter(name):
    if case let .integer(value)? = bindings[name] { value } else { nil }
  case .term:
    nil
  }
}

extension Table where Self: ~Escapable {
  /// The boundaries `[lower, upper)` to seek for a sort-key comparison, or
  /// `nil` if `filter` does not qualify for the seek path.
  ///
  /// It qualifies when `filter` is a sort-key equality or range whose operand
  /// is an integer — a literal, or a bound parameter resolved from `bindings`
  /// so a correlated child seeks on its parent key — and `bound` reports the
  /// column seekable (a non-`nil` boundary). A range additionally requires the
  /// column `ordered`: a `bound` boundary partitions a range correctly only
  /// when the seeked column is monotonic, so a range on a seekable, unordered
  /// column (a decoded coded-index key) does not qualify and scans, while its
  /// equality still seeks. The comparison's slot maps back to its table ordinal
  /// through `ordinals` (slot `i` is `ordinals[i]`) for the `bound` query. A
  /// `string` operand or an unseekable column never qualifies, and the executor
  /// scans.
  ///
  /// A first-class `x BETWEEN lower AND upper` (non-negated) whose test `x` is
  /// the sort-key slot and whose bounds each resolve to an integer — a literal,
  /// or a `:parameter` bound in `bindings` (so `x BETWEEN :lo AND :hi` seeks
  /// rather than scans) — seeks a two-sided run: the intersection of the
  /// `x >= lower` and `x <= upper` partitions, exactly the run the desugar
  /// would seek, as an ordered-only range. A `NOT BETWEEN` (a two-run
  /// complement, not one contiguous seek), a non-slot test, or a bound that
  /// does not resolve to an integer does not qualify; the residual `between`
  /// still runs over the sought rows either way.
  ///
  /// The hash-join executor reuses this over a pushed inner filter's conjuncts
  /// to seek the inner by a seekable conjunct before bucketing, so a
  /// seekable/contradictory inner filter reads few or no inner rows.
  internal borrowing func boundaries(_ filter: Filter, _ ordinals: Array<Int>,
                                     _ count: Int, _ bindings: Bindings)
      -> Range<Int>? {
    // A first-class `x BETWEEN lower AND upper` seeks a two-sided run directly:
    // the lower boundary is the `x >= lower` partition (inclusive, `strict`
    // false) and the upper is the `x <= upper` partition (inclusive, `strict`
    // true), so their intersection `lower ..< upper` is exactly the range the
    // desugar `x >= lower AND x <= upper` would seek. As a range it seeks ONLY
    // an ordered key — an unordered seekable column brackets an equality, not
    // a range — and the residual `between` still runs over the sought rows.
    if let (slot, low, high) = range(filter, bindings) {
      guard ordered(ordinals[slot]),
          let lower = bound(ordinals[slot], low, strict: false),
          let upper = bound(ordinals[slot], high, strict: true) else {
        return nil
      }
      // An inverted `BETWEEN lower AND upper` (lower > upper) is a valid EMPTY
      // range: the `x >= lower` partition starts after the `x <= upper` one
      // ends, so `lower > upper` here and `lower ..< upper` would trap Swift's
      // `Range(lowerBound <= upperBound)` precondition. Seek an empty run.
      guard lower <= upper else { return lower ..< lower }
      return lower ..< upper
    }

    guard let (slot, op, value) = comparison(filter, bindings),
        let lower = bound(ordinals[slot], value, strict: false),
        let upper = bound(ordinals[slot], value, strict: true) else {
      return nil
    }

    // A range takes the rows on one side of the boundary, which is correct only
    // when the column is ordered — every row on that side compares that way. An
    // equality takes only the boundary's own run, which `bound` brackets
    // exactly even for an unordered seek (a decoded coded-index key: the sorted
    // raw run brackets one tag's value, and the join re-tests the decoded key
    // per row), so equality always seeks; a range on an unordered column
    // returns `nil` and the engine scans and filters.
    let ordered = ordered(ordinals[slot])
    return switch op {
    case .equal: lower ..< upper
    case .lt: ordered ? 0 ..< lower : nil
    case .leq: ordered ? 0 ..< upper : nil
    case .gt: ordered ? upper ..< count : nil
    case .geq: ordered ? lower ..< count : nil
    case .unequal: nil   // a split run is two scans; let the scan handle it
    }
  }
}

// MARK: - Physical join

extension Catalog where Self: ~Escapable {
  /// Rewrites `Select(filter, Product(left, Scan(inner, _, nil)))` into an
  /// index-nested-loop `Join` when a `match` conjunct relates the two sides,
  /// else leaves the product (a plain nested loop) under the filter.
  ///
  /// The inner side is a bare `Scan(inner, _, nil)`, or that scan under a
  /// pushed single-relation filter — `Select(inner-filter, Scan(inner, _,
  /// nil))`, the shape selection pushdown leaves when a `WHERE` conjunct
  /// references only the joined-in relation. Either way the join folds in the
  /// scan; the pushed filter is preserved so the joined-in relation's non-key
  /// predicate still rides the `Join` path rather than degrading to a residual
  /// product.
  ///
  /// The left side's slot count is the boundary `base` in the combined slot
  /// space: a slot below it is an outer-side key, a slot at or above it an
  /// inner-side key (still in combined space). The inner key's slot maps to its
  /// table ordinal (`column`) through the inner scan's `ordinals` for the
  /// seek's `bound`. The matching conjunct is consumed; any remaining conjuncts
  /// stay as a residual `Select`. The pushed inner filter rides on the `Join`
  /// node itself — in the inner's OWN 0-based standalone slot space, the space
  /// it already lives in on the inner scan — so the executor applies it WHILE
  /// materialising inner rows (before bucketing / as part of the inner scan),
  /// rather than lifting it into the residual to run after the join. Applying
  /// it during materialisation means a pair forms only when the filter holds,
  /// so it still gates a later unsafe residual conjunct (the pushdown barrier
  /// having kept the safe inner filter ahead of any unsafe conjunct). When the
  /// inner side is neither shape, the product is preserved.
  private borrowing func nest(_ filter: Filter, _ left: Plan, _ right: Plan,
                              _ context: Context)
      throws(SQLError) -> Plan {
    let inner: (name: String, ordinals: Array<Int>, filter: Filter?)?
    switch right {
    case let .scan(name, ordinals, nil):
      inner = (name, ordinals, nil)
    case let .select(pushed, .scan(name, ordinals, nil)):
      inner = (name, ordinals, pushed)
    default:
      inner = nil
    }

    guard let inner, let base = left.slots else {
      return try filter.gated(over: .product(optimise(left, context),
                                             optimise(right, context)))
    }

    let conjuncts = filter.conjuncts
    for index in conjuncts.indices {
      guard case let .match(lhs, rhs) = conjuncts[index],
          let key = keys(lhs, rhs, base) else {
        continue
      }

      var residual = conjuncts
      residual.remove(at: index)
      // The pushed inner filter stays in the inner's 0-based standalone slot
      // space and rides on the `Join` node, applied while the executor
      // materialises the inner (before bucketing / as part of the inner scan) —
      // NOT lifted into the residual to run after the join. It is always safe
      // and the pushdown barrier kept it ahead of any unsafe conjunct, so
      // applying it during materialisation still gates a later unsafe residual
      // (a pair forms only when the filter holds), without letting that
      // conjunct throw first (`Parent.Name = 'nope' AND (1 / Child.x) = 0`, the
      // false name excluding the row before the division runs).
      let join = try Plan.join(optimise(left, context),
                               name: inner.name, ordinals: inner.ordinals,
                               base: base,
                               column: inner.ordinals[key.inner - base],
                               keys: (left: key.outer, right: key.inner),
                               filter: inner.filter)
      guard let predicate = residual.conjunction else { return join }
      return .select(predicate, join)
    }

    return try filter.gated(over: .product(optimise(left, context),
                                           optimise(right, context)))
  }

  // MARK: - Decorrelation

  /// Rewrites a decorrelatable correlated CROSS APPLY into a set-based inner
  /// join — a behaviour-preserving LOGICAL pass run AFTER `pushdown` (so each
  /// `.apply` body is already in `project`/`select`/`scan` canonical form) and
  /// BEFORE `optimise`/`nest` (so the emitted `.select`-over-`.product` folds
  /// to a `.join` for free). It recurses the tree structurally, leaving every
  /// node but a decorrelatable `.apply` untouched, so a plan with none is
  /// returned unchanged.
  ///
  /// At each `.apply(left, key, correlation, ordinals, on, kind: .inner)` it
  /// consults the pre-compiled body plan (`context.subqueries.plan(key,
  /// correlation)`, the SAME lookup `executed` uses) and, when the body is a
  /// simple filter+project over a single base-relation scan with a purely EQUI
  /// correlation, rewrites the apply to `project(over left ++ taken,
  /// select(on'', product(left, scan(R))))` — the exact output geometry the
  /// correlated `applied` produces (each left row multiplied by its match
  /// count, an unmatched left row DROPPED), which the subsequent `nest` folds
  /// to a hash equi-join. On ANY doubt (a non-`.inner` kind, a
  /// non-decorrelatable body, a non-equi/expression correlation, an unsafe body
  /// term, or a taken-ordinals geometry it cannot map soundly) it leaves the
  /// `.apply` verbatim, so execution is unchanged — a missed decorrelation is a
  /// perf loss, a wrong one is silent data corruption.
  internal borrowing func decorrelate(_ plan: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    switch plan {
    case .single, .scan, .join:
      return plan
    case let .derived(name, plan, ordinals, seek):
      // A view body is compiled and re-executed under its OWN scope; its
      // correlated applies (if any) decorrelate when it is derived/optimised,
      // not here. Recurse structurally only.
      return try .derived(name: name, plan: decorrelate(plan, context),
                          ordinals: ordinals, seek: seek)
    case let .select(filter, source):
      // Decorrelate the source first (a nested apply/exists/IN inside it still
      // rewrites), then attempt to lift a top-level correlated `EXISTS`/`NOT
      // EXISTS` or correlated `IN (Q)` conjunct of this select's filter into a
      // semijoin. On any doubt the whole `.select` is left correlated
      // (`decorrelated(semijoins:)` returns `nil`), so execution is unchanged.
      let source = try decorrelate(source, context)
      return decorrelated(semijoins: filter, source, context)
          ?? .select(filter, source)
    case let .project(terms, source):
      // Decorrelate the source first (a nested apply/exists/IN inside it still
      // rewrites), then attempt to lift each top-level correlated scalar
      // `.subquery` TERM of this projection into its own LEFT join. On any
      // doubt the whole `.project` is left correlated (`decorrelated(scalars:)`
      // returns `nil`), so execution is unchanged.
      let source = try decorrelate(source, context)
      return decorrelated(scalars: terms, source, context)
          ?? .project(terms, source)
    case let .sort(keys, source):
      return try .sort(keys: keys, decorrelate(source, context))
    case let .product(left, right):
      return try .product(decorrelate(left, context),
                          decorrelate(right, context))
    case let .outer(left, right, on, kind):
      return try .outer(decorrelate(left, context), decorrelate(right, context),
                        on: on, kind: kind)
    case let .semijoin(left, right, on, anti):
      // A semijoin this pass ITSELF produced (from a decorrelated `EXISTS`);
      // recurse structurally into both sides so a nested correlated apply
      // inside either still rewrites, preserving the node.
      return try .semijoin(decorrelate(left, context),
                           decorrelate(right, context), on: on, anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // Decorrelate the LEFT first (a nested apply inside it still rewrites),
      // then attempt this apply. `.inner` (CROSS APPLY) folds to an inner hash
      // join; `.left` (OUTER APPLY) folds to a LEFT `.outer` join. A `.right`/
      // `.full` apply does not exist (rejected at compile), so any other kind
      // is left verbatim.
      let left = try decorrelate(left, context)
      guard kind == .inner || kind == .left,
          let body = context.subqueries.plan(key, correlation),
          let rewritten = decorrelated(apply: left, body, key, correlation,
                                       ordinals, on, kind, context) else {
        return .apply(left, key: key, correlation: correlation,
                      ordinals: ordinals, on: on, kind: kind)
      }
      return rewritten
    case let .setop(kind, left, right, all):
      return try .setop(kind, decorrelate(left, context),
                        decorrelate(right, context), all: all)
    case let .distinct(source):
      return try .distinct(decorrelate(source, context))
    case let .aggregate(keys, aggregates, source):
      return try .aggregate(keys: keys, aggregates: aggregates,
                            decorrelate(source, context))
    case let .limit(count, offset, source):
      return try .limit(count: count, offset: offset,
                        decorrelate(source, context))
    }
  }

  /// The join rewrite of a CROSS APPLY (`.inner`) or OUTER APPLY (`.left`)
  /// whose `left` is already decorrelated, or `nil` when the apply's `body` is
  /// not decorrelatable — in which case the caller leaves the `.apply`
  /// unchanged (conservative default). An `.inner` apply becomes an inner hash
  /// join; a `.left` apply becomes a LEFT `.outer` join.
  ///
  /// The body must be `project(projection, select(where, scan(R, _, nil)))`
  /// with every projection term a bare slot (G3: a filter+project over a single
  /// base relation, no aggregate/limit/distinct/setop/nested apply — none of
  /// which wear this exact shape), the correlation must be all `.slot` sources
  /// (no `.bound` grandparent), and the `where` conjuncts must be EXACTLY one
  /// equi correlation `correlate.inner = :param` (or the reversed order) plus
  /// safe, non-parameterised, single-relation local predicates `p_R` (G4: an
  /// unsafe or parameterised residual — a non-equi/expression correlation —
  /// bails).
  /// The scan's `seek` must be absent (a seeked body is not the canonical
  /// shape).
  ///
  /// **`.inner` (CROSS APPLY).** The rewrite lays the body scan's referenced
  /// ordinals after the left (a `.product`), then stacks TWO selects: an INNER
  /// select carrying the WHOLE body WHERE (the correlation equality
  /// `.match(correlate.outer, base + correlate.inner)` AND the local residual
  /// `p_R`) and an OUTER select carrying the apply's `on` — the apply's `on`
  /// mapped from its `left ++ taken` space into this `left ++ scan` space. The
  /// `on` is kept
  /// SEPARATE (not folded into the body residual's conjunction) so it is
  /// evaluated ONLY on rows the body WHERE admitted: nested selects run
  /// bottom-up, restoring the correlated order (body WHERE → drop an UNKNOWN
  /// row → `on`), so an `on` that would throw on a row the body WHERE drops
  /// never fires — matching the correlated `applied` (which never reaches the
  /// `on` for a dropped row). It then PROJECTS the result back to the apply's
  /// `left ++ taken` geometry. The equi `.match` lets `nest`/`optimise` fold
  /// the product into a hash equi-join whose NULL-key drops and match-count
  /// multiplicity mirror the per-row re-execution.
  ///
  /// **`.left` (OUTER APPLY).** The rewrite is a LEFT `.outer` join
  /// `outer(left, scan(R), on: match(correlate.outer, base + correlate.inner)
  /// AND residual' AND on', kind: .left)`, projected back to the apply's
  /// `left ++ taken` geometry. The `.outer` node's `on` GOVERNS matching and
  /// NULL-extends an unmatched left row across the taken width — exactly OUTER
  /// APPLY. UNLIKE the inner case the `on` CANNOT be split into a select above
  /// the join: the LEFT join's match/NULL-extension condition IS the whole
  /// `on`, so the correlation equality, the body residual, and the apply `on`
  /// must fold into ONE predicate evaluated together per (L, R) pair. This
  /// engine evaluates an `AND`'s RHS even for an UNKNOWN LHS, so folding an
  /// UNSAFE apply `on` beside a nullable body residual would raise a throw for
  /// a pair the correlated body WHERE dropped. THEREFORE `.left` decorrelates
  /// ONLY when the mapped apply `on` is `safe` (non-throwing) or provably
  /// constant-true (the common `ON 1 = 1`): evaluating a `safe` `on` for an
  /// UNKNOWN-residual pair cannot throw, so the fold is result- AND throw-
  /// equivalent. An unsafe apply `on` leaves the `.apply` correlated. The equi
  /// `match` conjunct lets the `.outer` executor's hash fast-path probe by the
  /// key, mirroring the inner join's NULL-key drop and multiplicity.
  private borrowing func decorrelated(apply left: Plan, _ body: Plan,
                                      _ key: Subkey,
                                      _ correlation: Correlation,
                                      _ ordinals: Array<Int>, _ on: Filter,
                                      _ kind: Join.Kind,
                                      _ context: Context) -> Plan? {
    guard case let .project(projection, .select(filter, leaf)) = body,
        case let .scan(name, scanOrdinals, nil) = leaf,
        let base = left.slots else { return nil }
    // The scanned `name` must be a genuine BASE relation, not a BODY-LOCAL
    // derived alias. When the lateral body declares its OWN derived table(s) —
    // `SELECT x FROM (SELECT k, x FROM S) AS e WHERE …` — the compiled body
    // plan scans that alias (`e`), which the correlated `applied` executor
    // MATERIALISES per execution under the body's revealed overlay. The
    // caller-level checks below (a CTE/store overlay entry, a view) do not see
    // `e`, so it would pass as a base relation and the rewrite would relay a
    // caller-level `scan("e")` that faults `.relation("e")` or, worse, binds a
    // same-named OUTER base table and returns WRONG rows. Bail whenever the
    // body query declares any derived tables of its own — the SAME
    // `collect(derived:)` the augment path uses over the body select — and
    // leave the apply correlated.
    var derivations = Array<(String, Query, Array<String>)>()
    key.query.collect(derived: &derivations)
    guard derivations.isEmpty else { return nil }
    // The scan must also name a genuine BASE relation, not a CTE/store overlay
    // entry or a view. A CTE `.scan` binds under the body's OWN revealed
    // overlay (a caller derived alias of the same name shadowed) that the
    // `applied` executor restores per run; relaid into a caller-level join it
    // would re-resolve the name against the OUTER overlay and bind the wrong
    // relation. A view `.scan` (a `.derived` after resolution) is likewise out
    // of the single-base-relation cut. Leave either correlated.
    guard context.relations[name.lowercased()] == nil,
        resolve(view: name) == nil else { return nil }
    // Every projection term must be a bare slot: a projected expression (a
    // LATERAL-only shape over a preceding column, or any computed column) has a
    // slot geometry the scan-relaid rewrite cannot reproduce, so bail.
    var projected = Array<Int>()
    for term in projection {
      guard case let .slot(slot) = term else { return nil }
      projected.append(slot)
    }
    // A taken ordinal at or beyond the projection's width is the body's virtual
    // `Id` — a LATERAL-only per-left-row row number the `applied` executor
    // derives from THIS left row's output through a `RelationInstance`, which a
    // set-based join (numbering over the whole relation) cannot reproduce.
    // Leave it correlated.
    guard ordinals.allSatisfy({ projection.indices.contains($0) }) else {
      return nil
    }
    // The correlation must be a single `.slot` source (no `.bound` grandparent
    // this v1 decorrelates). The outer key is that source's ordinal, already in
    // the left's combined slot space.
    guard correlation.count == 1,
        case let (name: parameter, source: .slot(outer))? =
            correlation.first.map({ (name: $0.key, source: $0.value) })
        else { return nil }

    // Split the body WHERE into the ONE equi correlation conjunct
    // (`correlate.inner = :parameter`) and the local residual `p_R`. Any other
    // parameterised conjunct is a non-equi/expression correlation — bail. Every
    // residual must be safe (G4: a throwing body term could fire for an inner
    // row no left row reaches under set-based execution).
    var inner: Int? = nil
    var residual = Array<Filter>()
    for conjunct in filter.conjuncts {
      if inner == nil, let slot = equated(conjunct, to: parameter) {
        inner = slot
        continue
      }
      guard conjunct.safe, !conjunct.parameterised else { return nil }
      residual.append(conjunct)
    }
    guard let inner else { return nil }
    // The correlation key pair: `outer` the source's ordinal (in the left's
    // combined slot space), `inner` the equi conjunct's body slot.
    let correlate = (outer: outer, inner: inner)

    // The scan is relaid after the left, so the body's 0-based scan slots shift
    // by `base` into the combined space. The correlation equality becomes a
    // `.match` (folded to the join key), and the residual `p_R` shifts
    // alongside into this `left ++ scan` space.
    let scan = Plan.scan(name: name, ordinals: scanOrdinals, seek: nil)
    let matched = Filter(match: correlate.outer, base + correlate.inner)
    let shifted = residual.map { $0.shifted(by: -base) }
    // The apply's `on` addresses the `left ++ taken` space; map it into this
    // `left ++ scan` space (taken column `base + j` becomes the scan slot `base
    // + projected[ordinals[j]]` its projection read).
    let mapped =
        on.remapped(through: remap(taken: ordinals, over: base, projected))
    // Project back to the apply's exact `left ++ taken` geometry: the left's
    // slots unchanged, then each taken column at its combined scan slot.
    var terms = (0 ..< base).map { Term.slot($0) }
    terms.append(contentsOf: ordinals.map { Term.slot(base + projected[$0]) })

    switch kind {
    case .inner:
      // The inner gate carries the WHOLE body WHERE (match key + residual) and
      // NOTHING else — the apply's `on` is kept in a SEPARATE select ABOVE the
      // body-filtered join rather than folded into the residual conjunction.
      // The correlated `applied` evaluates the body WHERE FIRST (dropping an
      // UNKNOWN row — a NULL-flag child) and only THEN the `on`, so an `on`
      // that would throw on a dropped row never fires. This engine evaluates an
      // `AND`'s RHS even for an UNKNOWN LHS, so folding `on` into the residual
      // conjunction would evaluate it for a dropped row and raise a fault the
      // original APPLY never hits. Nested selects evaluate bottom-up, so an
      // OUTER `on` sees only the rows the body WHERE admitted — restoring the
      // correlated order (body WHERE → drop → on). The `.match` lets
      // `nest`/`optimise` fold the product into a hash equi-join.
      let product = Plan.product(left, scan)
      let gate = ([matched] + shifted).conjunction
      let filtered = gate.map { Plan.select($0, product) } ?? product
      let gated = mapped.constant == true ? filtered : .select(mapped, filtered)
      return .project(terms, gated)
    case .left:
      // OUTER APPLY: a LEFT `.outer` join whose `on` GOVERNS matching and
      // NULL-extends an unmatched left row. UNLIKE the inner case the `on`
      // cannot be split into a select above the join — the LEFT join's match/
      // NULL-extension condition IS the whole `on`, so correlation + residual +
      // apply `on` must be ONE predicate evaluated together per (L, R) pair.
      //
      // SAFE-`on` GATE (throw-equivalence): this engine evaluates an `AND`'s
      // RHS even for an UNKNOWN LHS, so if the body residual can be UNKNOWN and
      // the apply `on` is UNSAFE, folding them raises a throw for a pair the
      // correlated body WHERE dropped at its own filter — a spurious throw the
      // OUTER APPLY never hits. Only decorrelate `.left` when the mapped `on`
      // is `safe` (non-throwing) or provably constant-true (`ON 1 = 1`): a
      // `safe` `on` for an UNKNOWN-residual pair cannot throw, so the fold is
      // result- AND throw-equivalent. An unsafe apply `on` bails — the caller
      // leaves the `.apply` correlated.
      guard mapped.safe || mapped.constant == true else { return nil }
      let condition =
          mapped.constant == true ? [matched] + shifted
                                  : [matched] + shifted + [mapped]
      // `condition` always holds the `match` conjunct, so it is never empty.
      let clause = condition.conjunction ?? matched
      let outer = Plan.outer(left, scan, on: clause, kind: .left)
      return .project(terms, outer)
    default:
      // `.right`/`.full` do not exist as apply kinds (rejected at compile); the
      // caller already gates on `.inner`/`.left`, so this is unreachable.
      return nil
    }
  }

  /// The semijoin rewrite of a `.select` whose `filter` carries one or more
  /// top-level correlated `EXISTS`/`NOT EXISTS` or correlated `IN (Q)`
  /// conjuncts over an already-decorrelated `source`, or `nil` when no conjunct
  /// is decorrelatable — in which case the caller leaves the `.select`
  /// correlated (conservative default). EVERY decorrelatable `EXISTS` becomes
  /// its own SEMIJOIN (a `NOT EXISTS` an ANTI-join), and every decorrelatable
  /// correlated `IN (Q)` a SEMIJOIN whose `on` ALSO carries the membership
  /// equality; the semijoins are STACKED over the source, and the conjuncts NOT
  /// lifted are kept in a `.select` ABOVE the stack.
  ///
  /// An `EXISTS` is a two-valued existence test — TRUE iff the body yields a
  /// row, never UNKNOWN — so a semijoin is result-equivalent to the per-row
  /// re-execution the `exists` evaluator does, WITHOUT the NOT-IN NULL trap (a
  /// NULL correlation key is simply "no match", dropping a SEMI left row and
  /// keeping an ANTI one). A POSITIVE correlated `IN (Q)` is likewise a
  /// per-row test — `operand IN (Q)` is TRUE iff some inner row's projected
  /// column equals `operand` — so a semijoin whose `on` conjoins the
  /// correlation key with the membership equality `operand = projected` is
  /// result-equivalent (a NULL `operand` or projected element yields no
  /// definite equality, so the row simply does not match — correct for POSITIVE
  /// IN, where the UNKNOWN-vs-FALSE distinction only bites NOT IN). `NOT IN`
  /// (`negated`) is DEFERRED — it carries that NULL trap — and stays
  /// correlated. The body must be the SAME simple filter+project over a single
  /// base-relation scan the CROSS APPLY recogniser requires; for EXISTS the
  /// projection CONTENT is irrelevant (existence only), while for `IN (Q)` the
  /// projection must be EXACTLY ONE bare-slot term (the IN column). The
  /// correlation must be a single `.slot` source and the body WHERE must split
  /// into EXACTLY one equi correlation conjunct plus safe, non-parameterised
  /// residual conjuncts `p_R` (an unsafe or parameterised residual — a non-equi
  /// correlation — bails, G3/G4).
  ///
  /// **SIBLING THROW-VISIBILITY (load-bearing).** A semijoin DROPS left rows
  /// (SEMI drops non-matching rows, ANTI drops matching rows), so a sibling
  /// conjunct of the enclosing `AND` that is UNSAFE could be SKIPPED for a row
  /// the semijoin drops — suppressing a throw the correlated `.select` raises
  /// (it evaluates every conjunct of the `AND` for the row before the row is
  /// dropped). This is the throw-visibility class the OUTER APPLY safe gate
  /// guards. THEREFORE lifting proceeds ONLY when EVERY conjunct NOT lifted
  /// into a semijoin is `safe`; a decorrelatable exists/IN body is itself safe
  /// (a filter+project over one base scan with safe residuals, and an IN
  /// operand gated `safe` before lifting), so the lifted conjuncts add no
  /// throw, but a non-decorrelatable exists/IN left in the residual is unsafe
  /// and blocks all lifting. If any non-lifted conjunct is unsafe the whole
  /// `.select` stays correlated. Conservative is correct — a missed
  /// decorrelation is a perf loss, a wrong one is silent data corruption.
  ///
  /// The decorrelatable exists/IN conjuncts are ALL lifted, each into its own
  /// semijoin stacked over the source; the rest (a non-decorrelatable
  /// exists/IN, a `NOT IN`, or another predicate) are the SIBLINGS the
  /// throw-visibility guard tests, kept in the `.select` above the stack. Each
  /// semijoin's output width is the source's, so every stacked semijoin sees
  /// the same source slots — the correlation-key ordinals stay valid through
  /// the stack — and the residual select and everything above still address
  /// those slots.
  private borrowing func decorrelated(semijoins filter: Filter, _ source: Plan,
                                      _ context: Context) -> Plan? {
    // Lift EVERY decorrelatable exists/IN conjunct into its own semijoin
    // STACKED over `source`; a conjunct that is not one is kept in `remaining`
    // (both the SIBLINGS the throw-visibility guard tests and the residual
    // select above the stack).
    var node = source
    var remaining = Array<Filter>()
    var lifted = false
    for conjunct in filter.conjuncts {
      if case let .exists(key, correlation, negated) = conjunct,
          let body = context.subqueries.plan(key, correlation),
          let next = semijoin(node, body, key, correlation, negated,
                              membership: nil, context) {
        node = next
        lifted = true
        continue
      }
      // A POSITIVE correlated `IN (Q)`: the operand rides the semijoin `on` as
      // the membership equality. `NOT IN` (`negated`) is DEFERRED (its NULL
      // trap is not a plain anti-join) and an UNCORRELATED IN (an empty
      // correlation) stays as is — both fall through to `remaining`. The
      // operand must be `safe`: a per-outer-row `operand` throw fires even when
      // the inner is empty, but a semijoin never evaluates `on` for a left row
      // with no right rows, so an unsafe operand would be SUPPRESSED — leave it
      // correlated.
      if case let .within(operand, key, correlation, false) = conjunct,
          !correlation.isEmpty, operand.safe,
          let body = context.subqueries.plan(key, correlation),
          let next = semijoin(node, body, key, correlation, false,
                              membership: operand, context) {
        node = next
        lifted = true
        continue
      }
      remaining.append(conjunct)
    }
    guard lifted else { return nil }
    // SIBLING THROW-VISIBILITY: every conjunct NOT lifted into a semijoin must
    // be safe — a row a semijoin drops could otherwise suppress a throw the
    // correlated select raises for it. A non-decorrelatable exists/IN (or a
    // deferred `NOT IN`) is itself unsafe, so it (conservatively) blocks all
    // lifting here.
    guard remaining.allSatisfy(\.safe) else { return nil }
    // Keep the remaining conjuncts in a `.select` ABOVE the stack. Each
    // semijoin's width == the source's, so they and everything above still
    // address the same slots.
    return remaining.conjunction.map { .select($0, node) } ?? node
  }

  /// The `.semijoin` node for a correlated `EXISTS`/`NOT EXISTS` body — or a
  /// POSITIVE correlated `IN (Q)` body when `membership` is the IN operand —
  /// over `left`, or `nil` when the `body` is not decorrelatable — the SAME
  /// guards the CROSS APPLY recogniser applies. `negated` selects the ANTI
  /// sense (only ever `false` for the IN path, `NOT IN` being deferred).
  ///
  /// The body must be `project(projection, select(where, scan(R, _, nil)))`
  /// with no body-local derived table (the body-local hazard), `R` a genuine
  /// BASE relation (not a CTE/store overlay entry or a view), a single `.slot`
  /// correlation source, and a `where` splitting into EXACTLY one equi
  /// correlation conjunct plus safe, non-parameterised residual conjuncts. The
  /// correlation equality becomes a straddling `.match` (the executor's hash
  /// key), the residual shifts into combined `left ++ scan` space alongside.
  ///
  /// For EXISTS (`membership == nil`) the projection CONTENT is irrelevant (a
  /// semijoin tests existence, taking no body column), so `on` is the
  /// correlation match AND the residual. For `IN (Q)` (`membership` the
  /// operand) the projection must be EXACTLY ONE bare `.slot` term — the IN
  /// column — else the shape is not decorrelatable and this bails. The
  /// membership equality `operand = .slot(base + projected)` conjoins into `on`
  /// AFTER the correlation match (so `equikey` still picks the correlation as
  /// the hash key and the membership rides the whole-`on` confirm): a left row
  /// survives iff some inner row equi-matches the key AND its projected column
  /// equals the operand AND the residual holds. The `operand` addresses the
  /// SOURCE's slots `0 ..< base`, unchanged in combined space, so used AS-IS.
  private borrowing func semijoin(_ left: Plan, _ body: Plan, _ key: Subkey,
                                  _ correlation: Correlation, _ negated: Bool,
                                  membership operand: Term?,
                                  _ context: Context) -> Plan? {
    guard case let .project(projection, .select(filter, leaf)) = body,
        case let .scan(name, scanOrdinals, nil) = leaf,
        let base = left.slots else { return nil }
    // No body-local derived table: its per-execution alias cannot be relaid as
    // a caller-level scan — the SAME hazard the CROSS APPLY recogniser guards.
    var derivations = Array<(String, Query, Array<String>)>()
    key.query.collect(derived: &derivations)
    guard derivations.isEmpty else { return nil }
    // The scan must name a genuine BASE relation, not a CTE/store overlay entry
    // or a view — a CTE/view `.scan` re-resolves against the wrong overlay when
    // relaid at the caller level. Leave either correlated.
    guard context.relations[name.lowercased()] == nil,
        resolve(view: name) == nil else { return nil }
    // For the IN path the projection must be EXACTLY ONE bare `.slot` — the IN
    // column whose value the membership equality tests against the operand. A
    // multi-term or expression projection has no single membership slot, so it
    // is not decorrelatable; bail. The EXISTS path takes no body column, so its
    // projection content is irrelevant and this is skipped.
    var projected: Int? = nil
    if operand != nil {
      guard projection.count == 1,
          case let .slot(slot) = projection[0] else { return nil }
      projected = slot
    }
    // The correlation must be a single `.slot` source (no `.bound` parent):
    // the outer key is that source's ordinal, already in the left's slot space.
    guard correlation.count == 1,
        case let (name: parameter, source: .slot(outer))? =
            correlation.first.map({ (name: $0.key, source: $0.value) })
        else { return nil }

    // Split the body WHERE into the ONE equi correlation conjunct
    // (`correlate.inner = :parameter`) and the local residual `p_R`. Any other
    // parameterised conjunct is a non-equi/expression correlation — bail. Every
    // residual must be safe (a throwing body term could fire for an inner
    // left row reaches under set-based execution).
    var inner: Int? = nil
    var residual = Array<Filter>()
    for conjunct in filter.conjuncts {
      if inner == nil, let slot = equated(conjunct, to: parameter) {
        inner = slot
        continue
      }
      guard conjunct.safe, !conjunct.parameterised else { return nil }
      residual.append(conjunct)
    }
    guard let inner else { return nil }

    // The scan is relaid after the left, so the body's 0-based scan slots shift
    // by `base` into the combined space. The correlation equality becomes a
    // straddling `.match` (the executor's hash key), and the residual `p_R`
    // shifts alongside into this `left ++ scan` space.
    let scan = Plan.scan(name: name, ordinals: scanOrdinals, seek: nil)
    let matched = Filter(match: outer, base + inner)
    let shifted = residual.map { $0.shifted(by: -base) }
    // The IN membership equality `operand = projected` rides `on` AFTER the
    // correlation match (so `equikey` still hashes on the correlation) and
    // BEFORE the residual. The `operand` reads the source's slots `0 ..< base`,
    // unchanged in combined space, so it is used AS-IS; the projected body slot
    // shifts by `base`. For EXISTS there is no membership, so `on` is the match
    // plus the residual exactly as before (a `nil` operand ⇒ byte-identical).
    var conjuncts = [matched]
    if let operand, let projected {
      conjuncts.append(Filter(compare: operand, .equal,
                              .slot(base + projected)))
    }
    conjuncts.append(contentsOf: shifted)
    let on = conjuncts.conjunction ?? matched
    return .semijoin(left, scan, on: on, anti: negated)
  }

  /// Lift every decorrelatable correlated scalar `.subquery` TERM of a
  /// projection into its OWN LEFT `.outer` join STACKED under the projection,
  /// replacing the term with a coercion-preserving read of the joined column,
  /// or `nil` when NO term is liftable — in which case the caller leaves the
  /// `.project` correlated (conservative default). A correlated scalar subquery
  /// `(SELECT v FROM R WHERE R.Id = T.fk [AND p_R])` today re-executes per
  /// outer row; over the UNIQUE virtual `Id` key each left row matches AT MOST
  /// ONE `R` row (a residual `p_R` can only drop the single candidate), so it
  /// becomes a plain LEFT join reading `v` from the joined column.
  ///
  /// **UNIQUENESS (load-bearing).** `join(scalar:)` decorrelates ONLY when the
  /// equi correlation's inner key is the relation's virtual `Id`, at ordinal
  /// EXACTLY `== width` (a 1-based unique row index). A non-`Id` key (an owner
  /// foreign key or a coded-index key at an ordinal `> width`, or a real column
  /// `< width`) is NOT unique — many rows share it — so admitting it would
  /// silently COLLAPSE many matches to one. The at-most-one match makes the
  /// `>1` cardinality throw impossible, so the LEFT join reproduces it without
  /// a MIN aggregate (which would materialise-and-group all of `R` and could
  /// throw for a group no left row reaches).
  ///
  /// **NO SIBLING THROW HAZARD.** Unlike the semijoin/anti-join lifts (which
  /// DROP left rows), a LEFT join drops NOTHING — every left row is emitted
  /// exactly once — so a throwing SIBLING projection term is evaluated on
  /// exactly the same rows it was correlated; nothing is suppressed. The body
  /// residual is gated `safe` and the unique key makes the cardinality throw
  /// impossible, so the join reads `R` once introducing no new throw. Hence no
  /// safe-gate over the siblings is needed.
  ///
  /// Each `.outer` appends `R`'s ordinals AFTER the running node, never
  /// shifting slots `0 ..< base`, so an unreplaced projection term keeps its
  /// ORIGINAL source slot verbatim and the j-th lifted scalar reads its joined
  /// `v` at `base_j + vSlot_j` (the running slot count before that join plus
  /// `v`'s combined-space slot). The final `.project` sits atop the whole stack
  /// and re-selects, discarding the extra right columns, so the output geometry
  /// stays `terms.count`.
  private borrowing func decorrelated(scalars terms: Array<Term>,
                                      _ source: Plan, _ context: Context)
      -> Plan? {
    guard var base = source.slots else { return nil }
    var node = source
    var projected = terms
    var lifted = false
    for (position, term) in terms.enumerated() {
      guard case let .subquery(key, correlation, type) = term,
          !correlation.isEmpty,       // uncorrelated: leave (already memoised)
          let body = context.subqueries.plan(key, correlation),
          let (outer, slot) = join(scalar: body, node, key, correlation, base,
                                   context)
        else { continue }
      node = outer
      // COERCION-PRESERVING: `.coalesce([.slot(slot)], type)` applies exactly
      // `Value.coerced(to: type)` to a non-NULL cell and passes NULL through —
      // byte-identical to `scalar()`'s `(value ?? .null).coerced(to: type)`. A
      // raw `.slot` would DROP the coercion (a `.double`-typed scalar over an
      // `.integer` cell); a `.cast` is WRONG (it faults/truncates rather than
      // widens). Use `.coalesce`.
      projected[position] = .coalesce([.slot(slot)], type: type)
      base = node.slots ?? base       // width grew by R's ordinals
      lifted = true
    }
    guard lifted else { return nil }
    return .project(projected, node)
  }

  /// The LEFT `.outer` join and the combined-space slot of the joined value `v`
  /// for a correlated scalar `.subquery` body over `left`, or `nil` when the
  /// `body` is not decorrelatable — the SAME guards the semijoin recogniser
  /// applies PLUS the unique-`Id`-key guard.
  ///
  /// The body must be `project(projection, select(where, scan(R, _, nil)))`
  /// with the projection EXACTLY ONE bare `.slot(v)` (the scalar's column), no
  /// body-local derived table, `R` a genuine BASE relation, a single `.slot`
  /// correlation source, and a `where` splitting into EXACTLY one equi
  /// correlation conjunct plus safe, non-parameterised residual conjuncts
  /// `p_R`. The equi conjunct's inner scan slot must map (through the scan's
  /// referenced ordinals) to the relation ordinal `== width` AND that
  /// width-ordinal virtual (`virtuals.first`) must be the UNIQUE `Id`, and ONLY
  /// it — a non-`Id` first virtual, which the `Table.virtuals` contract
  /// permits, is not unique and must stay correlated. The correlation match
  /// becomes a straddling
  /// `.match` (the executor hash key), the residual shifts into combined `left
  /// ++ scan` space, and the two conjoin into the LEFT join's `on`.
  private borrowing func join(scalar body: Plan, _ left: Plan, _ key: Subkey,
                              _ correlation: Correlation, _ base: Int,
                              _ context: Context) -> (Plan, Int)? {
    guard case let .project(projection, .select(filter, leaf)) = body,
        case let .scan(name, scanOrdinals, nil) = leaf,
        left.slots == base else { return nil }
    // No body-local derived table: its per-execution alias cannot be relaid as
    // a caller-level scan — the SAME hazard the semijoin recogniser guards.
    var derivations = Array<(String, Query, Array<String>)>()
    key.query.collect(derived: &derivations)
    guard derivations.isEmpty else { return nil }
    // The scan must name a genuine BASE relation, not a CTE/store overlay entry
    // or a view — a CTE/view `.scan` re-resolves against the wrong overlay when
    // relaid at the caller level. Leave either correlated.
    guard context.relations[name.lowercased()] == nil,
        resolve(view: name) == nil else { return nil }
    // The projection must be EXACTLY ONE bare `.slot(v)` — the scalar's column,
    // whose joined value replaces the term. A multi-term or expression
    // projection has no single value slot, so it is not decorrelatable.
    guard projection.count == 1,
        case let .slot(vSlot) = projection[0] else { return nil }
    // The correlation must be a single `.slot` source (no `.bound` parent):
    // the outer key is that source's ordinal, already in the left's slot space.
    guard correlation.count == 1,
        case let (name: parameter, source: .slot(outer))? =
            correlation.first.map({ (name: $0.key, source: $0.value) })
        else { return nil }

    // Split the body WHERE into the ONE equi correlation conjunct
    // (`correlate.inner = :parameter`) and the local residual `p_R`. Any other
    // parameterised conjunct is a non-equi/expression correlation — bail. Every
    // residual must be safe (a throwing body term could fire for an inner row
    // no left row reaches under set-based execution).
    var inner: Int? = nil
    var residual = Array<Filter>()
    for conjunct in filter.conjuncts {
      if inner == nil, let slot = equated(conjunct, to: parameter) {
        inner = slot
        continue
      }
      guard conjunct.safe, !conjunct.parameterised else { return nil }
      residual.append(conjunct)
    }
    guard let inner else { return nil }
    // UNIQUENESS GUARD: the equi conjunct's inner scan slot must map to the
    // relation ordinal `== width` AND that width-ordinal virtual must be the
    // unique `Id` — a 1-based unique row index, and ONLY it. An ordinal `>
    // width` is another (non-unique) virtual; an ordinal `< width` is a real
    // column: neither is a unique key. The width-ordinal virtual is
    // `virtuals.first`, and the `Table.virtuals` contract permits a conformer
    // whose first virtual is NOT `Id` (a non-unique `Owner`, say) — such a key
    // matches many rows, so decorrelating over it would silently collapse them
    // and drop the correlated scalar's `.cardinality`; it must stay correlated.
    // `table(named:)` resolves the base relation (the caller-level checks above
    // already ensured `name` is not a CTE/view), and `scanOrdinals[inner]` maps
    // the equi conjunct's 0-based scan slot to its relation ordinal.
    guard let table = table(named: name),
        scanOrdinals[inner] == table.width,
        table.virtuals.first?.lowercased() == "id" else { return nil }

    // The scan is relaid after the left, so the body's 0-based scan slots shift
    // by `base` into the combined space. The correlation equality becomes a
    // straddling `.match` (the executor's hash key), and the residual `p_R`
    // shifts alongside into this `left ++ scan` space.
    let scan = Plan.scan(name: name, ordinals: scanOrdinals, seek: nil)
    let matched = Filter(match: outer, base + inner)
    let shifted = residual.map { $0.shifted(by: -base) }
    let on = ([matched] + shifted).conjunction ?? matched
    // A unique-`Id` key matches AT MOST ONE R row, so a plain LEFT join reads
    // `v` from the joined column: an unmatched left row NULL-extends (the empty
    // → NULL of the correlated scalar), a matched one reads its lone cell. `v`
    // lands at `base + vSlot` in the combined `left ++ scan` space.
    return (.outer(left, scan, on: on, kind: .left), base + vSlot)
  }
}

/// The inner-key slot of an EQUI correlation conjunct `slot = :parameter` (in
/// either operand order), or `nil` when `conjunct` is not that shape — a
/// comparison of a bare slot to the correlation `parameter` under `=`. A
/// non-`=` comparison (a NON-equi correlation), a compound operand, or a
/// different parameter is not an equi correlation key and leaves the conjunct
/// to the residual test (which bails on it as a parameterised non-equi term).
private func equated(_ conjunct: Filter, to parameter: String) -> Int? {
  guard case let .compare(lhs, .equal, rhs) = conjunct else { return nil }
  switch (lhs, rhs) {
  case let (.slot(slot), .parameter(name)) where name == parameter:
    return slot
  case let (.parameter(name), .slot(slot)) where name == parameter:
    return slot
  default:
    return nil
  }
}

/// The slot remap from a CROSS APPLY's `left ++ taken` output space into the
/// decorrelated `left ++ scan` space: a left slot (`< base`) is unchanged, and
/// the `j`-th taken column (slot `base + j`, reading body-output column
/// `ordinals[j]`) maps to the scan slot `base + projected[ordinals[j]]` its
/// projection read. `on` is remapped through this so it addresses the relaid
/// scan's slots rather than the apply's taken columns.
private func remap(taken ordinals: Array<Int>, over base: Int,
                   _ projected: Array<Int>) -> Dictionary<Int, Int> {
  var map = Dictionary<Int, Int>(minimumCapacity: base + ordinals.count)
  for slot in 0 ..< base { map[slot] = slot }
  for taken in ordinals.indices {
    map[base + taken] = base + projected[ordinals[taken]]
  }
  return map
}

/// The `(outer, inner)` key pair an equality between slots `lhs` and `rhs`
/// relates across the boundary `base`, or `nil` if both fall on one side.
///
/// Exactly one slot must be below `base` (the outer key) and the other at or
/// above it (the inner key, still in combined space); the order the equality
/// was written in does not matter.
private func keys(_ lhs: Int, _ rhs: Int, _ base: Int)
    -> (outer: Int, inner: Int)? {
  switch (lhs < base, rhs < base) {
  case (true, false): (lhs, rhs)
  case (false, true): (rhs, lhs)
  default: nil
  }
}

// MARK: - Selection pushdown

extension Plan {
  /// Pushes each `WHERE` conjunct that references a single relation's slots
  /// down to just above that relation's leaf, before the join/product chain
  /// folds it in — so a relation is filtered as it is read rather than after
  /// the whole product is formed.
  ///
  /// `compile` leaves the `WHERE` as one `select` atop the left-deep chain, so
  /// a join runs on unfiltered inputs. This pass descends the chain: a conjunct
  /// whose slots all fall in one relation's contiguous slot run rides down to
  /// that relation's leaf as a `select` over its `scan`/`derived`, where the
  /// seek and nest rewrites can then act on it; a conjunct spanning two
  /// relations (a residual, an `OR` across sides) stays at the level whose two
  /// children it straddles. A conjunct over a `derived` view's output columns
  /// is pushed INTO the view's sub-plan — its outer slot mapped back through
  /// the view's projection to the sub-plan slot the column reads — recursing
  /// below the view's own joins. A `union` pushes into every arm. The pass is a
  /// pure logical rewrite; `optimise` runs after it and still sees the
  /// `select`s the seek and nest rewrites match.
  internal func pushdown() throws(SQLError) -> Plan {
    switch self {
    case .single, .scan, .join:
      self
    case let .derived(name, sub, ordinals, seek):
      try .derived(name: name, plan: sub.pushdown(), ordinals: ordinals,
                   seek: seek)
    case let .select(filter, source):
      try source.pushdown().distribute(filter.conjuncts)
    case let .project(terms, source):
      try .project(terms, source.pushdown())
    case let .sort(keys, source):
      try .sort(keys: keys, source.pushdown())
    case let .product(left, right):
      try .product(left.pushdown(), right.pushdown())
    case let .outer(left, right, on, kind):
      // Push down WITHIN each side (its own joins/filters rewrite), but the
      // outer node is a pushdown barrier: a `WHERE` conjunct above it never
      // rides into a side. Filtering a preserved side's rows before the outer
      // join is equivalent, but filtering the NULL-extended side's rows before
      // it would change which rows match, so — preferring correctness — the
      // whole `WHERE` stays above (`distribute`'s default keeps it a `select`
      // over this node).
      try .outer(left.pushdown(), right.pushdown(), on: on, kind: kind)
    case let .semijoin(left, right, on, anti):
      // Push down WITHIN each side (its own joins/filters rewrite), but the
      // semijoin node is a pushdown barrier: a `WHERE` conjunct above it never
      // rides into a side. The semijoin DROPS left rows by the existence test,
      // so filtering a side's rows before it could change which left rows
      // survive — preferring correctness, the whole `WHERE` stays above
      // (`distribute`'s default keeps it a `select` over this node). Pushdown
      // runs BEFORE decorrelate, so this arm handles only a semijoin a nested
      // pass produced; a top-level plan never carries one at this point.
      try .semijoin(left.pushdown(), right.pushdown(), on: on, anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // Push down WITHIN the left side (its own joins/filters rewrite), but the
      // apply is a pushdown barrier: its right side is not a static sub-plan
      // but a per-outer-row re-execution, so a `WHERE` conjunct above it never
      // rides into it (mirroring the `.outer` gate — `distribute`'s default
      // keeps the conjunct a `select` over this node). The recorded body plan
      // was already pushed down at its compile.
      try .apply(left.pushdown(), key: key, correlation: correlation,
                 ordinals: ordinals, on: on, kind: kind)
    case let .setop(kind, left, right, all):
      try .setop(kind, left.pushdown(), right.pushdown(), all: all)
    case let .distinct(source):
      // A `distinct` sits above the projection, so no `WHERE` conjunct reaches
      // it to push down; it recurses transparently. A filter must never cross a
      // dedup — filtering before or after it yields different rows — and none
      // can, since it sits above the projection like the cap.
      try .distinct(source.pushdown())
    case let .aggregate(keys, aggregates, source):
      // An aggregate reshapes rows into a fresh grouped slot space, so it is a
      // pushdown barrier: a `HAVING`/projection filter above it is in grouped
      // space and stays there (`distribute`'s default keeps it as a `select`
      // over the aggregate), while the WHERE below it — already placed under
      // the aggregate at compile — pushes down within the source as usual.
      try .aggregate(keys: keys, aggregates: aggregates, source.pushdown())
    case let .limit(count, offset, source):
      // A `limit` is the outermost operator, so no `WHERE` conjunct ever
      // reaches it to push down; it recurses transparently, its source pushed
      // as usual. A filter must never cross it — capping before or after a
      // filter yields different rows — and none can, since the cap sits above
      // the projection.
      try .limit(count: count, offset: offset, source.pushdown())
    }
  }

  /// Places each of `conjuncts` as deep in the already-pushed `self` as the
  /// slots it reads allow, wrapping the level whose children a conjunct
  /// straddles in a residual `select`.
  ///
  /// At a `product`, `left.slots` is the boundary: a conjunct entirely below it
  /// belongs to the left child and rides down; one entirely at or above it
  /// belongs to the right child, rebased into that child's own slot space; one
  /// straddling the boundary — or reading no slots, or able to throw when
  /// evaluated (a division or scalar call) — stays here. A `select` is a join's
  /// `ON` gate, whose two sides straddle every boundary, and is a BARRIER for
  /// an UNSAFE `WHERE` conjunct: `nest` folds only ONE `match` into the hash
  /// `Join`'s key, leaving every other `ON` conjunct (a match beyond that key,
  /// or a non-equi residual) as the gate's residual under the join, and the
  /// gate drops a pair its leftover conjuncts evaluate UNKNOWN or `false`
  /// BEFORE the `WHERE` runs. So fusing a throwing `WHERE` conjunct into the
  /// gate — the `AND` not short-circuiting, still evaluating it for a pair the
  /// gate already dropped — would raise an error the separate gate suppresses,
  /// whether the leftover is a non-equi residual (`A JOIN B ON A.k < B.k WHERE
  /// (1 / A.x) = 0`, `A.k` NULL) or a second equi key (`… ON A.k1 = B.k1 AND
  /// A.k2 = B.k2 WHERE (1 / A.x) = 0`, `A.k2` NULL). Every UNSAFE `WHERE`
  /// conjunct stays a separate `select` above the gate, preserving the
  /// `ON`-drops-before-`WHERE` ordering; a SAFE `WHERE` conjunct (which never
  /// raises) still descends below the gate — as the product loop's ordering
  /// allows — so a safe single-relation conjunct reaches its base scan. The
  /// match keys fold down so `nest` can join under the gate. At a `derived`
  /// leaf the conjuncts push into the view; at a base `scan` they land right
  /// above it. A conjunct that cannot descend is re-conjoined here.
  private func distribute(_ conjuncts: Array<Filter>)
      throws(SQLError) -> Plan {
    switch self {
    case let .product(left, right):
      guard let base = left.slots else {
        return residual(conjuncts)
      }
      var here = Array<Filter>()
      var down = Array<Filter>()
      var over = Array<Filter>()
      var barrier = false
      for (index, conjunct) in conjuncts.enumerated() {
        let slots = conjunct.slots
        // A conjunct stays here — at the product level, run per pair, in the
        // order the `AND` chain wrote — when a preceding conjunct was unsafe
        // (`barrier`), when it reads no slots (e.g. `(1 / 0) = 0`, where
        // `allSatisfy` is vacuously true), when evaluating it can throw (a
        // division or scalar call, e.g. `(1 / A.x) = 0`), or when it is
        // nullable (reads a slot, so a NULL there makes it UNKNOWN) and a LATER
        // conjunct is unsafe. Riding a throwing conjunct down would raise while
        // scanning a child even when the join's other side is empty; riding a
        // safe conjunct PAST an earlier unsafe one would filter its rows before
        // the unsafe one runs, suppressing a throw the left-to-right `AND` owes
        // (`(1 / A.x) = 0 AND A.x <> 0`, `A.x = 0`, on a matching pair).
        // Because the evaluator's `AND` does not short-circuit, riding a
        // nullable conjunct BELOW a later unsafe one likewise suppresses a
        // throw: the un-pushed `AND` runs the later conjunct even for the
        // UNKNOWN row, but the pushed conjunct drops that row first (`A.x = 1
        // AND (1 / B.y) = 0`, `A.x` NULL and `B.y = 0`). Only a safe
        // single-relation conjunct with no unsafe predecessor — and, if
        // nullable, no unsafe successor — rides down.
        let hazard =
            conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
        if barrier || slots.isEmpty || !conjunct.safe || hazard {
          here.append(conjunct)
        } else if slots.allSatisfy({ $0 < base }) {
          down.append(conjunct)
        } else if slots.allSatisfy({ $0 >= base }) {
          over.append(conjunct)
        } else {
          here.append(conjunct)
        }
        // An unsafe conjunct bars every later conjunct from riding past it.
        if !conjunct.safe { barrier = true }
      }
      let product =
          Plan.product(try left.distribute(down),
                       try right.distribute(over.map { $0.shifted(by: base) }))
      return product.residual(here)
    case let .select(gate, source):
      // A join's `ON` gate straddles both sides, so it never captures a
      // single-relation conjunct. Its equi `column = column` conjuncts are the
      // `match` keys `nest` folds into a hash `Join`; any other conjunct is a
      // residual (non-equi) `ON` predicate the join runs over its product.
      var matches = Array<Filter>()
      var residual = Array<Filter>()
      for conjunct in gate.conjuncts {
        if case .match = conjunct {
          matches.append(conjunct)
        } else {
          residual.append(conjunct)
        }
      }
      // The `ON` gate is ALWAYS a DISTRIBUTION BARRIER for an UNSAFE outer
      // `WHERE` conjunct, whether the gate is mixed (a non-equi residual) or
      // PURE-equi (only matches). `nest` folds only ONE `match` into the hash
      // `Join`'s key and leaves every other `ON` conjunct — a match beyond that
      // key, plus any non-equi residual — as the gate's own residual `select`
      // under the join, which drops a pair it evaluates UNKNOWN or `false`
      // BEFORE the `WHERE` runs. Because the evaluator's `AND` does not
      // short-circuit, FUSING a throwing `WHERE` conjunct into that gate
      // residual would evaluate it for a pair the gate has already dropped.
      // This bites a pure-equi `ON` too: `A JOIN B ON A.k1 = B.k1 AND A.k2 =
      // B.k2 WHERE (1 / A.x) = 0`, `A.k1` matching, `A.k2` NULL, `A.x` = 0 —
      // `nest` keys on `A.k1 = B.k1`, so the surviving pair reaches the
      // leftover `A.k2 = B.k2` (UNKNOWN), which should drop it; a fused `A.k2 =
      // B.k2 AND (1 / A.x) = 0` would instead divide by zero. So every UNSAFE
      // `WHERE` conjunct stays a SEPARATE `select` ABOVE the gate — never fused
      // with a leftover `ON` conjunct — keeping the `ON`-drops-before-`WHERE`
      // order.
      //
      // A SAFE `WHERE` conjunct, by contrast, never raises, so pushing it below
      // the gate can only drop rows, not suppress a throw; it still descends
      // (`matches + residual + safe`) so a safe single-relation conjunct
      // reaches its base scan as before. `distribute`'s product loop keeps it
      // AFTER the `ON` residual, and its own barrier bars it from riding past
      // an unsafe `ON` conjunct — a safe `WHERE` pushed to a base scan below
      // the product does not co-locate with, nor reorder around, the gate's
      // leftover conjuncts. A safe conjunct stays above when the loop would
      // keep it at the product level anyway — mirroring that loop's ordering
      // rules so descending it never suppresses a throw the `WHERE`'s
      // non-short-circuiting `AND` owes: after ANY earlier unsafe conjunct
      // (a `barrier`), or when it is NULLABLE and a LATER conjunct is unsafe
      // (a `hazard`). The match keys still fold down beside the residual so
      // `nest` can form the join under the gate; a single-equality pure-equi
      // `ON` folds its one key and carries no leftover conjunct, so a safe
      // `WHERE` descends and an unsafe one sits directly above the join.
      var safe = Array<Filter>()
      var above = Array<Filter>()
      var barrier = false
      for (index, conjunct) in conjuncts.enumerated() {
        let hazard =
            conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
        if conjunct.safe && !barrier && !hazard {
          safe.append(conjunct)
        } else {
          above.append(conjunct)
        }
        if !conjunct.safe { barrier = true }
      }
      let gated = try source.distribute(matches + residual + safe)
      return gated.residual(above)
    case .derived:
      return try into(conjuncts)
    default:
      return residual(conjuncts)
    }
  }

  /// Pushes `conjuncts` INTO this `derived` view's sub-plan, below its own
  /// projection and joins, mapping each conjunct's outer slot (a slot into the
  /// leaf's `ordinals`, i.e. a view output column) back to the sub-plan slot
  /// the column reads.
  ///
  /// A view's sub-plan is `Project(terms, body)` (or a `union` of such), so an
  /// output column `ordinals[slot]` is `terms[ordinals[slot]]`. A conjunct
  /// pushes in only when every slot it reads maps to a bare `.slot` term — a
  /// plain column of the body; a conjunct over a computed column (a call or
  /// arithmetic) cannot rebase and stays as a `select` on the derived leaf. A
  /// `union` sub-plan admits a conjunct only when every arm's projection admits
  /// it — the arms are combined, so a conjunct that cannot push into one arm
  /// must stay outside them all. The admitted conjuncts, still in the view's
  /// OUTPUT slot space, push in through `inject`, which rebases each against
  /// the projection it lands under — PER ARM for a union, since the arms map
  /// the same output column to DIFFERENT body slots; the rest wrap the leaf.
  ///
  /// The partition carries the SAME ordering barrier `distribute`'s product
  /// loop has: a conjunct stays `outer` — on the derived leaf, run in the `AND`
  /// chain's order — when a preceding conjunct was unsafe (`barrier`), when it
  /// is itself unsafe (a division or scalar call), when it is nullable and a
  /// LATER conjunct is unsafe, or when the view's projection cannot admit it;
  /// only a safe conjunct with no unsafe predecessor — and, if nullable, no
  /// unsafe successor — pushes in. An unsafe conjunct bars every later one from
  /// riding into the view: pushing a later conjunct past it would let the view
  /// seek and drop the row before the unsafe outer conjunct runs, suppressing a
  /// throw the left-to-right `AND` owes (`(1 / x) = 0 AND x = 1` over a view
  /// whose `x` is sorted, the `x = 1` seek dropping the `x = 0` row before the
  /// outer division raises). Symmetrically a nullable conjunct pushed BELOW a
  /// later unsafe one suppresses a throw: the non-short-circuiting `AND` runs
  /// the later conjunct even for the UNKNOWN row, but the injected conjunct
  /// drops that row first (`x = 1 AND (1 / y) = 0`, `x` NULL and `y = 0`).
  private func into(_ conjuncts: Array<Filter>) throws(SQLError) -> Plan {
    guard case let .derived(name, plan, ordinals, seek) = self else {
      return residual(conjuncts)
    }
    var inner = Array<Filter>()
    var outer = Array<Filter>()
    var barrier = false
    for (index, conjunct) in conjuncts.enumerated() {
      // A nullable conjunct (reads a slot, so a NULL there makes it UNKNOWN)
      // must also stay outer when a LATER conjunct is unsafe: the evaluator's
      // `AND` does not short-circuit, so the un-pushed query runs the later
      // conjunct even for the UNKNOWN row, but injecting this one into the view
      // would seek or filter that row away first — suppressing a throw the
      // left-to-right `AND` owes (`x = 1 AND (1 / y) = 0` over a view exposing
      // `x`/`y`, `x` NULL and `y = 0`).
      let hazard =
          conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
      if barrier || !conjunct.safe || hazard
          || !plan.pushable(conjunct, ordinals) {
        outer.append(conjunct)
      } else {
        inner.append(conjunct)
      }
      // An unsafe conjunct bars every later conjunct from riding past it.
      if !conjunct.safe { barrier = true }
    }
    let sub = inner.isEmpty ? plan : try plan.inject(inner, ordinals)
    let leaf = Plan.derived(name: name, plan: sub, ordinals: ordinals,
                            seek: seek)
    return leaf.residual(outer)
  }

  /// Whether `conjunct` (in this view's OUTPUT slot space, its slots indices
  /// into `ordinals`) can push below this sub-plan's projection.
  ///
  /// A `project` admits it when every slot it reads maps to a bare `.slot` term
  /// of the body — the `rebase` helper produces a mapping; a computed column
  /// (call or arithmetic) has none. A `union` admits it only when EVERY arm
  /// does — the arms are combined, so a conjunct pushable into one but not
  /// another cannot descend into any and must stay outside. Anything else does
  /// not admit it.
  private func pushable(_ conjunct: Filter, _ ordinals: Array<Int>) -> Bool {
    switch self {
    case let .project(terms, _):
      // A conjunct pushes below the projection only when every projected term
      // is safe: pushing it filters rows before the projection runs, so a
      // throwing term — a division or scalar call, even one the conjunct does
      // not read — would be skipped for the filtered rows, suppressing a raise
      // `derive` owes by evaluating every column of every view row.
      terms.allSatisfy(\.safe) && rebase(conjunct, ordinals) != nil
    case let .setop(_, left, right, _):
      left.pushable(conjunct, ordinals) && right.pushable(conjunct, ordinals)
    default:
      false
    }
  }

  /// This view sub-plan with `conjuncts` (in the view's OUTPUT slot space)
  /// pushed below its projection, each rebased into the body slots the
  /// projection it lands under reads.
  ///
  /// For a `union` each arm rebases the conjuncts against ITS OWN projection —
  /// the same output column sits at different body slots across arms, so a
  /// single pre-rebased filter cannot serve them all; the rebase must happen
  /// per arm. `pushable` has already vetted every conjunct against every arm,
  /// so the per-arm `rebase` is guaranteed non-nil.
  private func inject(_ conjuncts: Array<Filter>, _ ordinals: Array<Int>)
      throws(SQLError) -> Plan {
    switch self {
    case let .project(terms, body):
      try .project(terms,
                   body.distribute(conjuncts.map { rebase($0, ordinals)! }))
    case let .setop(kind, left, right, all):
      try .setop(kind, left.inject(conjuncts, ordinals),
                 right.inject(conjuncts, ordinals), all: all)
    default:
      // A view sub-plan is always a `project` (or a `union` of them); anything
      // else keeps the conjuncts as an outer `select` rather than dropping
      // them.
      residual(conjuncts)
    }
  }

  /// `conjunct` rebased from a `derived` leaf's OUTPUT slot space into this
  /// projection sub-plan's body slot space, or `nil` if any slot it reads is a
  /// computed view column (not a bare `.slot` projection term) and so cannot be
  /// pushed in.
  ///
  /// Slot `s` of the leaf reads view column `ordinals[s]`, whose value is the
  /// projection term `terms[ordinals[s]]`; the conjunct pushes in only when
  /// that term is a bare `.slot(body)`, in which case `s` maps to `body`.
  /// Shared by `pushable` (the non-nil check) and `inject` (the rebased value).
  private func rebase(_ conjunct: Filter, _ ordinals: Array<Int>) -> Filter? {
    guard case let .project(terms, _) = self else { return nil }
    var map = Dictionary<Int, Int>(minimumCapacity: conjunct.slots.count)
    for slot in conjunct.slots {
      guard case let .slot(body) = terms[ordinals[slot]] else { return nil }
      map[slot] = body
    }
    return conjunct.remapped(through: map)
  }

  /// This plan wrapped in a `select` of `conjuncts`, or unchanged for an empty
  /// list — the residual placement of conjuncts that descend no further.
  private func residual(_ conjuncts: Array<Filter>) -> Plan {
    guard let filter = conjuncts.conjunction else { return self }
    return .select(filter, self)
  }
}

// MARK: - Compilation

extension Catalog where Self: ~Escapable {
  /// Compiles `query` over this catalog into a logical operator tree.
  ///
  /// A single `SELECT` compiles as itself; a set operation compiles recursively
  /// into a BINARY `setop` plan that mirrors the `Query`:
  /// `compile(.setop(kind, left, right, all))` is `.setop(kind, compile(left),
  /// compile(right), all)`. Each node carries its OWN `kind`/`all`, so the
  /// executor honours every operator distinctly — `(A UNION B) UNION ALL C`
  /// dedups `A ∪ B` before appending `C`, rather than treating the whole chain
  /// by the trailing arm's flag. The right arm must project the same column
  /// count as the query's first `SELECT` — the result columns — else
  /// `SQLError.arity`.
  ///
  internal borrowing func compile(_ query: Query,
                                  _ context: Context = Context())
      throws(SQLError) -> Plan {
    // Bind the derived tables (and store relations) THIS query names in its own
    // FROM/JOIN before resolving its relations — SELECT-scoped, so a subquery
    // compiled through here binds its OWN aliases (an outer statement-global
    // pre-collection would leave a sibling subquery's same-named `t` bound to
    // the wrong one). Schema-only (`rows: false`): compilation reads schemas,
    // never a cursor. Idempotent when the caller already augmented (`run`).
    // `visited` carries the cyclic-view guard through, so a derived table in a
    // view body under resolution that names the view faults `.recursion`.
    // A nested subquery's FROM sees base tables and enclosing CTEs, NOT this
    // query's derived aliases — so the augmented `context` threads onward and
    // `subquery(of:)` REVEALS the base before lowering a subquery (this query's
    // and every enclosing query's derived aliases dropped, the CTEs and store
    // relations kept, a CTE a same-named derived alias here shadows still
    // visible). The layered overlay never overwrote the CTE, so no pre-augment
    // context is threaded. `validate` gates a derived body's eager type-check:
    // a RUN preflight passes `false` so a data-dependent body expression an
    // execution never evaluates is not rejected here (the outer query still
    // faults, and a REACHED body operand still faults at run), matching the
    // non-derived path; a schema check passes `true`.
    let context = try augment(context, for: query, rows: false)
    guard case let .setop(kind, left, right, all) = query else {
      return try compile(query.first, context)
    }

    // A set operation collects NO derived aliases at the query level — arms are
    // SCOPED, so `collect(derived:)` stops at a `SELECT` — leaving the augment
    // above with no arm-local bindings. But the `SELECT *` arity check resolves
    // each arm's `*` BEFORE the recursive per-arm compile augments that arm, so
    // augment each arm's OWN derived aliases into a PER-ARM scope first, as the
    // per-arm `compile`/`run` scope them: `SELECT * FROM (SELECT V FROM S) AS
    // d` resolves `d`'s width. It is per arm so the left arm's `d` never
    // leaks to the right (the arm-scoping fix); the width each check computes
    // matches what the arm actually produces at run.
    let head = try augment(context, for: .select(query.first), rows: false)
    let tail = try augment(context, for: .select(right.first), rows: false)
    let width = try arity(query.first, head)
    let count = try arity(right.first, tail)
    guard count == width else { throw .arity(width, count) }
    // Both arms of a set-operation subquery correlate against the SAME
    // enclosing scope, so each lowers under the shared `context.outer`.
    return try .setop(kind, compile(left, context), compile(right, context),
                      all: all)
  }

  /// The distinct UNCORRELATED subqueries `select` nests, each COMPILED ONCE
  /// against this catalog and `context` for its column count — NEVER run — into
  /// a `Resolution` map the predicate/projection lowering reads for arity, the
  /// seam that carries each sub-`Query` into its lowered `Filter` as data.
  ///
  /// This is CURSOR-FREE: it drives `compile`, which resolves schemas and reads
  /// the subquery's `Plan.width` without a cursor, so a schema-only path
  /// (`columns(of:)`, view resolution) that shares this lowering opens none and
  /// surfaces no data-dependent error. Every subquery in the `WHERE`, join
  /// `ON`s, `HAVING`, projection, `ORDER BY` expressions, and aggregate
  /// arguments and FILTERs is found by a syntactic walk and keyed by its own
  /// `Query` (which is `Hashable`), so lowering resolves each `EXISTS`/`IN (Q)`
  /// against the map by identity. A subquery compiles ONCE even if it appears
  /// twice; it RUNS at execution (see `subqueries(of:)`), UNCORRELATED so once.
  ///
  /// `context.subscope` is the resolution context these subqueries lower under
  /// — `.caller` for a top-level compile, `.view(name)` for a view body's —
  /// carried into each lowered `Filter`'s cache key so a view-body occurrence
  /// and a top-level one over the same AST stay distinct entries (see
  /// `Subscope`).
  ///
  /// `enclosing` is the select's OWN resolution scope — the one its nested
  /// subqueries CORRELATE against: each nested query compiles under a fresh
  /// `Outer` extending `context.outer` (this select's own enclosing scope, when
  /// it is itself a subquery) with `enclosing` the nearest scope, so a nested
  /// query's inner `WHERE` column binding none of ITS relations resolves
  /// against the enclosing select (and outward), lowering to a synthetic
  /// `Term.parameter` and RECORDING the correlation the lowered node carries.
  /// The returned `Resolution` also carries `context.outer` so THIS select's
  /// own columns correlate outward when it is a subquery.
  ///
  /// `prefixes`, when supplied, gives the PREFIX scope each join `ON` lowers
  /// against — the FROM relation and joins `0…index`, never a relation joined
  /// LATER — so a subquery in join `i`'s `ON` correlates against `prefixes[i]`
  /// (the relations available AT that join point) rather than the full join
  /// `enclosing`. A correlated reference to a later-joined relation then binds
  /// against NONE of the prefix's relations and faults `SQLError.column`,
  /// matching the DIRECT `ON` resolver, which already uses the prefix scope. A
  /// non-join surface (WHERE/projection/HAVING/ORDER) correlates against
  /// `enclosing` as before.
  internal borrowing func subquery(of select: Select, _ context: Context,
                                   enclosing: Scope? = nil,
                                   prefixes: Array<Scope> = [])
      throws(SQLError) -> Plans {
    // Resolve each SITE'S subqueries against THAT site's own scope, keyed PER
    // OCCURRENCE: a join `i`'s `ON` against its PREFIX scope `prefixes[i]` (the
    // relations available AT that join point), the
    // WHERE/HAVING/projection/ORDER against the full join `enclosing`. The SAME
    // inner SQL in both an `ON` and the WHERE is resolved TWICE — each against
    // its own site's scope — so the WHERE occurrence sees the full scope and
    // reports a genuine ambiguity rather than reusing the first `ON`
    // occurrence's narrower prefix correlation.
    var lowerings = Array<Resolution>()
    lowerings.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      var queries = Array<Query>()
      select.joins[index].on.collect(subqueries: &queries)
      let within = index < prefixes.count ? prefixes[index] : enclosing
      try lowerings.append(subquery(queries, select, context, within: within))
    }
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
    let remainder = try subquery(rest, select, context, within: enclosing)
    return Plans(lowerings, remainder)
  }

  /// Builds ONE lowering `Resolution` over the directly-nested `queries` of a
  /// single SITE, resolving each against `within` — the scope THAT site's
  /// subqueries correlate against (a join `ON`'s prefix, or the full
  /// `enclosing` for the WHERE/HAVING/projection/ORDER). Each distinct `Query`
  /// is compiled ONCE here; the SAME inner SQL at a DIFFERENT site is resolved
  /// by that site's own call, against its own scope.
  private borrowing func subquery(_ queries: Array<Query>, _ select: Select,
                                  _ context: Context, within: Scope?)
      throws(SQLError) -> Resolution {
    // A nested subquery's FROM resolves against base tables and enclosing CTEs,
    // NOT the enclosing SELECT's derived-table aliases (SELECT-scoped, unseen
    // by a subquery's FROM as a base-table alias would be) — so STRIP them, the
    // CTEs/store relations kept, before compiling each subquery. Applied for
    // scalar, `IN`, and `EXISTS` alike (`select.subqueries` covers all three).
    let context = context.revealed()
    let scope = context.subscope
    var widths = Dictionary<Query, Int>()
    var types = Dictionary<Query, ValueType>()
    var correlations = Dictionary<Query, Correlation>()
    for query in queries where widths[query] == nil {
      // A fresh `Outer` per nested query — its enclosing scope is THIS select
      // (nearest, `within`), stacked past this select's own enclosing scope
      // `outer`. A FROM-less select adds no relations, but it is STILL a scope
      // FRAME: it pushes an EMPTY `Scope` so correlation DEPTH counts this
      // level. Its own plan runs over a `single` empty record, so a deeper
      // reference to the true outer must NOT bind as this frame's `.slot` (an
      // empty record has no such cell) — the empty frame makes that reference
      // a grandparent one, resolved `.bound` and threaded through `bindings`,
      // while a genuinely-immediate correlation to a REAL enclosing FROM (a
      // non-nil `within`) stays `.slot` as before.
      let nested = (context.outer ?? Outer()).nested(under: within ?? Scope([]))
      // The context each nested compile/derive threads: the revealed base with
      // this frame's `nested` as the enclosing correlation stack and the
      // shape-only lenience below. `unlateralized()` clears the LATERAL-body
      // flag so a nested ORDINARY subquery within a lateral body builds its OWN
      // Resolution with `everywhere: false` — the lateral everywhere-admission
      // covers ONLY the lateral body's own projection, NOT a subquery inside
      // it, so an ordinary correlated scalar-subquery projection is barred
      // exactly as it is outside a lateral body.
      let inner =
          context.with(outer: nested).validating(false).unlateralized()
      // A nested subquery's body derivation is SHAPE ONLY, so ALWAYS lenient
      // (`validate: false`) — this pass exists to record the subquery's width,
      // arity, and correlation, never to validate its body. Validation of a
      // subquery's body (and the derived tables nested within it, at any depth)
      // is the reachability walk's job: `typecheck(_ select:)` re-derives each
      // REACHED occurrence's body strictly over `subquery.visited`. Compiling a
      // derived body THIS subquery nests with `validate: true` here would
      // eager-type-check it BEFORE the walk decides the subquery is reached —
      // faulting `WHERE 1 = 0 AND 1 IN (SELECT x FROM (SELECT 1 / 0 …) AS d)`,
      // whose `IN` a run short-circuits away. Structural faults (a bad inner
      // relation/column, a UNION arity) still surface — they resolve regardless
      // of `validate`. The type derivation below is already lenient.
      let plan = try compile(query, inner)
      widths[query] = plan.width
      // A scalar subquery contributes its single-column output type; a wider or
      // an `EXISTS`/`IN (Q)` subquery still records the FIRST column's type
      // (harmless — only a width-1 scalar occurrence reads it, and the lowering
      // rejects a wider one). It derives cursor-free against the SAME context
      // the width compile uses, so it matches what the run advertises.
      types[query] =
          try columns(of: query.first, inner).first?.type
      // The correlation the nested compile discovered — the outer columns its
      // inner `WHERE`/`ON` named — carried into the lowered subquery node so
      // the per-outer-row re-execution binds them. Empty for an UNCORRELATED
      // one.
      correlations[query] = nested.correlation
      // A CORRELATED occurrence's inner PLAN was just compiled with THIS site's
      // enclosing scope, so its correlated columns are `Term.parameter`s bound
      // from the outer row. Stash it into the run path's `context.subqueries`
      // memo (which survives into execution) so the evaluator RE-EXECUTES this
      // plan per outer row rather than recompiling the inner query fresh —
      // which, with no outer scope in hand at eval, would fault on the outer
      // column. Record it under the occurrence's `PlanKey` — its `Subkey` for
      // each ROLE this query occupies (scalar / `IN` / `EXISTS`) composed with
      // the correlation's parameter names — the same identity the lowered node
      // looks up. The names distinguish two occurrences of IDENTICAL inner SQL
      // under DIFFERENT outer layouts (two set-operation arms whose correlated
      // column sits at different ordinals), so each arm's node finds ITS OWN
      // plan rather than the first arm's. The `existential` role records the
      // PROBED shape
      // (`probed`: the cardinality-only rewrite when `probable`, else the full
      // query) so the per-outer-row EXISTS re-execution tests non-emptiness
      // WITHOUT evaluating the select list — a `1 / 0` projection never runs —
      // exactly as the UNCORRELATED EXISTS probes. A schema-only path threads a
      // throwaway memo, harmless there.
      if !nested.correlation.isEmpty {
        for role in select.roles(of: query) {
          // Recompile the EXISTS probe LENIENTLY (`validate: false`), the SAME
          // way the `plan` above compiled: this builds the run-time plan a
          // correlated re-execution reuses, so it must not eager-type-check a
          // filtered-out projection the per-outer-row probe never evaluates.
          // The reachability walk validates a REACHED occurrence's probe shape
          // itself (`typecheck(shape(of: reach), …)`), so validation stays the
          // walk's, never this shape-deriving pass'.
          let recorded = try role == .existential
              ? compile(probed(query), inner)
              : plan
          // Push selection down into the inner plan as the top-level `run` does
          // (line ~134), so a correlated re-execution enjoys the same seeks and
          // join placement. The pushdown's nullability analysis treats a
          // conjunct carrying a correlated `Term.parameter` as nullable, so it
          // never rides ahead of a LATER unsafe conjunct the inner `AND` still
          // owes.
          context.subqueries.record(plan: try recorded.pushdown(),
                                    for: Subkey(scope, query, role),
                                    nested.correlation)
        }
      }
    }
    // A LATERAL body's `Resolution` admits a correlated preceding-FROM column
    // EVERYWHERE (`everywhere`), so its projection lowers such a column to a
    // `Term.parameter` rather than barring it — the ISO scoping a lateral body
    // gets and an ordinary subquery (`context.lateral == false`) does not.
    return Resolution(scope, widths, types, correlations,
                      outer: context.outer, everywhere: context.lateral)
  }

  /// The single VALUE a SCALAR subquery `query` collapses to against this
  /// catalog and `context`: NULL when it yields no row, its lone cell when it
  /// yields exactly one, and `SQLError.cardinality` when it yields more than
  /// one (the ISO `<scalar subquery>` cardinality rule).
  ///
  /// The compile pre-pass checked `query`'s width to exactly 1
  /// (`SQLError.arity`, cursor-free), so each result row has exactly one cell
  /// and the collapse reads the first. A wider subquery never reaches here — it
  /// faulted at compile.
  ///
  /// The evaluator calls this LAZILY, on the first reach of a scalar
  /// `Term.subquery`, so an occurrence in an unreachable `CASE`/`COALESCE` arm
  /// never runs it — preserving short-circuit semantics — and memoises the
  /// result for the reached occurrence's later reads.
  internal borrowing func cell(of query: Query, _ context: Context)
      throws(SQLError) -> Value {
    // A scalar subquery is a nested subquery: its FROM resolves against base
    // tables and enclosing CTEs, NOT the enclosing SELECT's derived-table
    // aliases (the evaluator threads the owning plan's overlay, which binds
    // them for the owning scan). STRIP them (CTEs/store kept), matching the
    // eager `IN`/`EXISTS` strip in `subqueries(of:)`, so a scalar subquery's
    // `FROM d` cannot scan an outer derived alias `d`.
    let context = context.revealed()
    let rows = try run(query, context)
    guard rows.count <= 1 else { throw .cardinality }
    return rows.first?.first ?? .null
  }

  /// Whether `query`'s row source yields ANY row — the `EXISTS` cardinality
  /// probe — WITHOUT evaluating its select list or sort keys.
  ///
  /// For a `probable` `SELECT` (see `Select.probable`), it runs a PROBE query
  /// that keeps the FROM/`WHERE`/joins, the `DISTINCT` quantifier, the `GROUP
  /// BY`, and the SAME original `OFFSET`/`FETCH` but replaces the projection
  /// with a cardinality-preserving target and drops the `ORDER BY`, so the
  /// original select-list expressions never evaluate (no `1 / 0` fault) while
  /// the original limiting is honoured: a `FETCH FIRST 0 ROWS` probes zero rows
  /// (EXISTS false) and an `OFFSET` past the end probes none (false). A
  /// FROM-less `SELECT <exprs>` carries no limit, so its probe is a limit-free
  /// `SELECT <constant>` that compiles and yields its one row (EXISTS true). A
  /// `DISTINCT` select without an `OFFSET` is probable too: `SELECT DISTINCT 1
  /// FROM S` yields exactly one distinct row iff `S` is non-empty, so the
  /// constant projection preserves existence. An aggregate/grouped select
  /// WITHOUT a `HAVING` is probable via a `COUNT(*)` target (see
  /// `Select.probe`): a whole-result aggregate yields exactly one row (EXISTS
  /// true modulo the limit, even over an empty source) and a grouped one yields
  /// one row per group, so the probe preserves its cardinality without running
  /// the original target. A `DISTINCT` select WITH an `OFFSET` (its emptiness
  /// depends on the real distinct count), a `HAVING` one (group survival
  /// depends on the aggregate values, not a source-only fact), or a set
  /// operation is materialised in FULL and tested for emptiness — the rewrite
  /// would not preserve its cardinality — which for those shapes evaluates the
  /// select list as a run would anyway.
  internal borrowing func probe(_ query: Query, _ context: Context)
      throws(SQLError) -> Bool {
    return try !run(probed(query), context).isEmpty
  }

  /// The cardinality-only shape of `query` an `EXISTS` tests for non-emptiness:
  /// a `probable` `SELECT`'s probe rewrite (`Select.probe` — its select list
  /// and `ORDER BY` replaced by a cardinality-preserving target, so a `1 / 0`
  /// projection never evaluates) and the full `query` otherwise (a `HAVING`
  /// select, a `DISTINCT`-with-`OFFSET` one, or a set operation, whose empty
  /// test is not a source-only fact the rewrite preserves). The `probe(_:)` run
  /// and the CORRELATED `existential` plan both compile/execute THIS shape, so
  /// a correlated EXISTS probes per outer row as an uncorrelated one does.
  internal borrowing func probed(_ query: Query) -> Query {
    guard case let .select(select) = query, select.probable else {
      return query
    }
    return .select(select.probe)
  }

  /// Resolves the FROM `relation` and its `joins` into one combined scope, the
  /// single source three call sites share: the aggregate compile path, the
  /// non-aggregate compile path, and the `SELECT *` arity check. The caller
  /// resolves FROM once (it needs the leaf for its own base lowering) and
  /// passes its `schema` here, so FROM is never re-resolved; each join then
  /// resolves into one running, end-to-end ordinal space.
  ///
  /// The returned `joined` holds each join's `Resolved` (its schema and leaf
  /// factory) in source order — the plan lowers each into the combined slot
  /// space from these. The returned `relations` lays the FROM relation first,
  /// then each joined one, each paired with its schema: `Scope(relations)` is
  /// the full-chain scope, `relations[0 ... index + 1]` a join's prefix scope,
  /// and `relations.reduce(0) { $0 + $1.1.width }` the `SELECT *` width — every
  /// downstream derivation reads out of this one resolution.
  ///
  /// `relations` is built INCREMENTALLY, each join resolving against the
  /// PRECEDING FROM (`Scope` of the relations before it): a LATERAL arm's
  /// projection may name a preceding column, so its output SHAPE depends on
  /// that scope. A non-lateral join's schema is correlation-independent, so the
  /// preceding scope is harmless — the incremental order is a no-op for it. The
  /// preceding scope threads through here rather than at each call site, so the
  /// arity check gets a LATERAL arm's shape without duplicating the loop.
  private borrowing func resolve(from relation: Relation, schema: Schema,
                                 joins: Array<Join>, _ context: Context)
      throws(SQLError) -> (joined: Array<Resolved>,
                           relations: Array<(Relation, Schema)>) {
    var joined = Array<Resolved>()
    joined.reserveCapacity(joins.count)
    var relations = [(relation, schema)]
    for join in joins {
      let resolved =
          try resolve(join.relation, context, preceding: Scope(relations))
      joined.append(resolved)
      relations.append((join.relation, resolved.schema))
    }
    return (joined, relations)
  }

  /// The number of result columns `select` projects — the extent of a `*` over
  /// its relations, else the count of its projected items — for the `UNION`
  /// arity check. The relations resolve through this catalog, the overlay
  /// consulted first.
  private borrowing func arity(_ select: Select, _ context: Context)
      throws(SQLError) -> Int {
    switch select.projection {
    case .all:
      // `SELECT *` spans the relations in scope; a FROM-less arm has none.
      guard let relation = select.from else {
        throw .named("SELECT * with no FROM")
      }
      // The FROM resolves once here; each join then resolves through the shared
      // helper, which threads each join's PRECEDING scope into its resolve — so
      // a LATERAL arm's body derives its projected preceding-FROM column
      // against the relations before it rather than against no scope, which
      // would fault the arity check even though the per-arm compile passes the
      // prefix.
      let schema = try resolve(relation, context).schema
      let (_, relations) = try resolve(from: relation, schema: schema,
                                       joins: select.joins, context)
      return relations.reduce(0) { $0 + $1.1.width }
    case let .columns(columns):
      return columns.count
    case let .expressions(items):
      return items.count
    }
  }

  /// Resolves a `Relation` against this catalog and the in-scope `ctes` to its
  /// schema and leaf factory.
  ///
  /// A common table expression shadows a base relation of the same name:
  /// `ctes` is consulted first, a CTE resolving to its materialised schema and
  /// a `scan` leaf (the executor materialises its records from the rows). Else
  /// a view shadows a base table — its `select` compiled to a sub-plan in a
  /// `derived` leaf — and finally a base table scans. A name none resolves is
  /// `SQLError.relation`.
  ///
  /// A view's body compiles OUTSIDE the statement's CTE scope — never the
  /// caller's `ctes` — so a stored view means exactly what it was registered to
  /// mean regardless of the `WITH` a caller wraps around it. A name that IS a
  /// statement CTE has already resolved above (a CTE shadows a view, as it
  /// shadows a base table), so a name reaching the view branch is genuinely a
  /// view; letting its body see the caller's CTEs would let an unrelated
  /// statement-local `WITH Parent AS …` reach into a view whose own `FROM
  /// Parent` must mean the base relation. The body's scope is instead the
  /// `definition_schema.` overlay built from the view's OWN query, so a view
  /// defined over a reserved store relation resolves; its `FROM`/`JOIN` names
  /// otherwise resolve against the base catalog (and other views) alone.
  ///
  /// A view's `columns` must name exactly one column per value its query
  /// projects, or the view's schema would let a query index past a sub-plan
  /// row. The parser checks this whenever the projection's arity is statically
  /// known; this is the backstop for a `SELECT *` view, whose width is known
  /// only here, after the sub-plan compiles — a mismatch is `SQLError.columns`.
  ///
  /// `visited` names the views already being resolved down this chain. A view
  /// whose body reaches back to itself — `A` over `B` over `A`, or a view over
  /// itself — would recurse resolve→compile→resolve without end (a stack
  /// overflow, not an `SQLError`); re-encountering a name is a cyclic
  /// definition, reported as `.recursion` rather than hung. The
  /// `definition_schema.` store's `columns` builder, which compiles every view
  /// to advertise it, relies on this: a cyclic view's `try? compile` catches
  /// the fault and skips it. Compiles a LATERAL derived table's `body` against
  /// the PRECEDING FROM `scope`, discovering its correlation and stashing the
  /// pre-compiled plan for the per-outer-row apply to re-execute — the
  /// FROM-clause analog of a correlated subquery's compile pre-pass
  /// (`subquery(_:_:_:within:)`).
  ///
  /// The body compiles under a fresh `Outer` frame nested under `scope` (the
  /// FROM relation and the joins BEFORE this one), so a body column naming a
  /// preceding relation binds none of its OWN relations and resolves outward to
  /// a synthetic `Term.parameter`, minting a `Correlation`. The plan compile is
  /// lenient (`validate: false`), as the correlated-subquery pre-pass is — this
  /// pass discovers the shape, and the run's per-row execution faults a REACHED
  /// operand. The plan is recorded under the occurrence's `Subkey` (this
  /// select's `subscope`, the body query, the `.lateral` role) composed with
  /// the correlation, the same identity `Plan.apply` looks up through
  /// `executed`. Returns the occurrence `Subkey` and the discovered
  /// correlation.
  ///
  /// A lateral body's SCHEMA + VALIDATION route through the SAME derived-body
  /// machinery a NON-LATERAL derived body uses (`materialise`, `rows: false`),
  /// differing ONLY in the OUTER treatment: a non-lateral body CLEARS the
  /// correlation stack (`body(_:)`, uncorrelated), while a lateral body THREADS
  /// the preceding-FROM `nested` outer so its correlated references resolve. So
  /// a lateral body inherits the revealed-base overlay (base + CTEs + store,
  /// its own alias out of scope) — a CTE stays visible in the body — AND the
  /// `validate`-gated operand/function type-check, exactly as a non-lateral
  /// body does. Under `validate: false` (a lenient run/shape pass) the body is
  /// NOT eagerly type-checked, matching the reachability-gated validation the
  /// rest of the engine applies; a REACHED bad operand still faults at run.
  private borrowing func lateral(_ body: Query, against scope: Scope,
                                 columns renaming: Array<String>,
                                 _ context: Context)
      throws(SQLError) -> (key: Subkey, correlation: Correlation) {
    let nested = (context.outer ?? Outer()).nested(under: scope)
    // Derive the body's schema and — under `validate` — type-check its operands
    // and functions through the SHARED derived-body path, over the revealed
    // base (CTEs visible) with the preceding-FROM outer THREADED so a
    // correlated reference resolves rather than faulting as unknown. The
    // returned schema is discarded here (`resolve`/`schema(of:)` advertises the
    // columns); this call exists to run the same validation a non-lateral body
    // gets.
    // Mark the body a LATERAL body (`lateralizing`) so its `Resolution`/
    // `SubqueryCheck` admit a correlated preceding-FROM column EVERYWHERE,
    // including its projection — per ISO a LATERAL body's preceding references
    // are in scope throughout, unlike an ordinary subquery whose projection
    // stays barred. The flag rides through the shared derived-body machinery to
    // the projection lowering, where a projected preceding column lowers to a
    // `Term.parameter` rather than faulting `.unsupported`.
    // Thread the derived table's explicit `AS d(a, b)` column list into the
    // body's schema derive so this validation checks the same EXPOSED (renamed)
    // names `schema(of:)` advertises — its arity (`SQLError.columns`) and
    // uniqueness (`SQLError.duplicate`) run against the renamed list, so a list
    // hiding a duplicate INNER name (`SELECT T.Id AS x, T.Id AS x) AS d(a, b)`)
    // passes at BOTH seams rather than faulting only here.
    let revealed = context.revealed().with(outer: nested).lateralizing()
    _ = try materialise(body, revealed, rows: false, columns: renaming)
    // Compile the body LENIENTLY for the per-outer-row apply plan (the shape
    // pass a correlated subquery's pre-pass runs), recording it under the
    // occurrence's key composed with the discovered correlation. It compiles
    // over the SAME revealed base the schema/validation pass above used (base +
    // CTEs + store, this select's derived aliases STRIPPED) with the
    // preceding-FROM outer threaded, so a body `FROM d` cannot bind a CALLER
    // derived alias `d` as a relation — the compile and the schema path resolve
    // the body's FROM identically, faulting an unknown relation consistently
    // rather than the run-only compile scanning a caller alias the schema pass
    // faults.
    let inner = revealed.validating(false)
    let plan = try compile(body, inner)
    let key = Subkey(context.subscope, body, .lateral)
    context.subqueries.record(plan: try plan.pushdown(), for: key,
                              nested.correlation)
    // The per-outer-row apply re-runs this plan under the occurrence scope's
    // RECORDED revealed overlay (`revealed(under:)`), which the run stores as
    // `revealed().relations` for `key.scope` — the SAME revealed base compiled
    // here — so execution resolves the body's `FROM` identically and a shadowed
    // CTE cannot diverge between compile and run.
    return (key, nested.correlation)
  }

  internal borrowing func resolve(_ relation: Relation, _ context: Context,
                                  preceding: Scope? = nil)
      throws(SQLError) -> Resolved {
    let name = relation.name
    // A LATERAL derived table is not bound in the overlay — its rows are not a
    // constant relation but a correlated apply's right side, materialised per
    // outer row. Resolve only its SCHEMA here; the join loop compiles its body
    // against the preceding FROM and emits a `Plan.apply` rather than calling
    // the `leaf`, so the leaf is never reached for a lateral relation. Its
    // output SHAPE is NOT correlation-independent (per ISO its projection may
    // name a preceding column), so thread the `preceding` scope — the FROM
    // relation and the joins BEFORE this one — so a projected preceding column
    // types from that outer column exactly as the run lowers it.
    if relation.lateral {
      let schema = try schema(of: relation, context, preceding: preceding)
      return Resolved(schema: schema) { ordinals in
        .scan(name: name, ordinals: ordinals, seek: nil)
      }
    }
    // The explicit `AS t(c, …)` list positionally renames a NAMED relation's
    // output columns; a DERIVED table's list was applied where it materialised
    // (its overlay binding carries the renamed names), so only a `.named`
    // source renames HERE — the compile-path mirror of `schema(of:)`'s named
    // rename, kept in parity so compile and the schema-only path resolve the
    // SAME column names.
    let columns: Array<String> = if case .named = relation.source {
      relation.columns
    } else {
      []
    }
    if let cte = context.relations[name.lowercased()] {
      let schema = try cte.schema().renamed(columns)
      return Resolved(schema: schema) { ordinals in
        .scan(name: name, ordinals: ordinals, seek: nil)
      }
    }

    if let view = resolve(view: name) {
      // A view whose body reaches back to itself — `A` over `B` over `A`, or a
      // view over itself — would recurse resolve→compile→resolve without end (a
      // stack overflow, not an `SQLError`). `visited` names the views already
      // being resolved down this chain; re-encountering one is a cyclic
      // definition, reported as `.recursion` rather than hung.
      if context.visited.contains(name.lowercased()) {
        throw .recursion(name)
      }
      // The view body compiles OUTSIDE the caller's statement CTEs, but it may
      // still name a reserved `definition_schema.` store relation, so seed its
      // scope with the overlay built from the view's OWN query — never the
      // caller's `ctes` — so a view defined over a store relation resolves.
      // This covers the built-in `information_schema.` views themselves, whose
      // bodies name `definition_schema.` relations.
      //
      // Compilation resolves only SCHEMAS (names → ordinals/types), never rows,
      // so the overlay is built SCHEMA-ONLY: a reserved relation types from its
      // header+types, and the row build is never triggered here. A view over
      // `definition_schema.columns` would otherwise re-enter that row builder
      // (which lists views, whose bodies name the relation again) — an
      // unbounded recursion, and the reason the introspection builder can
      // validate a view via `compile`. The rows a view over a reserved
      // relation actually returns are supplied at EXECUTE time, where `derive`
      // rebuilds the overlay with rows and runs the sub-plan.
      // This view name enters `visited` BEFORE its body's derived tables
      // materialise, so a body naming this view through a derived table
      // (`FROM (SELECT * FROM <self>) AS d`) re-enters `augment`/`materialise`
      // with the view already visited and faults `.recursion` here rather than
      // recursing to a stack overflow.
      // `context.validate` threads into the view body's schema-only augment +
      // compile so a RUN (`validate: false`) resolving `FROM <view>` does NOT
      // eager-type-check a data-dependent-empty derived body the view nests —
      // as the lenient inline run does; a schema check keeps it strict.
      // `uncorrelated()` CLEARS the caller's correlation stack: a view is
      // defined independently of its call site, so its body must NOT correlate
      // against an enclosing row when the view is queried from inside a
      // correlated subquery. Without it an unbound column in the view
      // DEFINITION would bind to the caller's row rather than fault.
      let overlay =
          try augment(context.body([:]).visiting(name),
                      for: view.query, rows: false)
      // The body's subqueries resolve under the VIEW's overlay — never the
      // caller's — so lower them under `.view(name)`, keeping a view-body
      // occurrence and a top-level one over the same AST distinct entries.
      let plan =
          try compile(view.query,
                      overlay.scoped(as: .view(name.lowercased())))
      let projected = plan.width
      guard view.columns.count == projected else {
        throw .columns(expected: projected, got: view.columns.count)
      }
      let schema = try view.schema().renamed(columns)
      return Resolved(schema: schema) { ordinals in
        .derived(name: name, plan: plan, ordinals: ordinals, seek: nil)
      }
    }

    guard let table = table(named: name) else {
      throw .relation(name)
    }
    let schema = try table.schema().renamed(columns)
    return Resolved(schema: schema) { ordinals in
      .scan(name: name, ordinals: ordinals, seek: nil)
    }
  }

  /// Compiles `select` over this catalog into a logical operator tree in slot
  /// space.
  ///
  /// The relation(s) resolve through this catalog (`SQLError.relation` on a
  /// miss). A single relation shapes `Project(Sort(Select(Scan)))`; a chain
  /// of joins shapes a left-deep tree, each join level a `Select(match,
  /// Product(chain, Scan))` on that join's `ON` equality, with the `WHERE`
  /// wrapped outside as `Project(Sort(Select(where, chain)))`. The `Select` and
  /// `Sort` layers are present only when a predicate or an `ORDER BY` is. Each
  /// scan carries the set of ordinals the query references on its side
  /// (projection ∪ every match ∪ filter ∪ order, reals and virtuals) so the
  /// executor materialises exactly those, in a fixed order that defines a dense
  /// SLOT for each — slot `i` is the scan's `i`th referenced ordinal.
  ///
  /// The operators run in slot space: `compile` remaps every ordinal it lowered
  /// (the projection, the `filter`, the order column, and each join's keys)
  /// through `ordinal → slot` so the records the operators address are dense
  /// arrays. The combined slot space lays the relations end to end in chain
  /// order — relation `i`'s referenced ordinals take a contiguous slot run
  /// after every earlier relation's — matching the merged record (each
  /// relation's cells concatenated in order). The tree is logical: every scan
  /// is a full `Scan(_, _, nil)`; the optimiser turns scans into seeks and each
  /// product into a join.
  ///
  internal borrowing func compile(_ select: Select,
                                  _ context: Context = Context())
      throws(SQLError) -> Plan {
    // Bind THIS select's own FROM/JOIN derived tables (and store relations)
    // before resolving its relations — SELECT-scoped, so a select reaching
    // this entry DIRECTLY (a bare `compile(select)`, not through the `Query`
    // wrapper) resolves its OWN derived aliases rather than faulting
    // `.relation`, the same as its schema siblings `columns(of select:)`/
    // `scope(of select:)`. Schema-only (`rows: false`): compilation reads
    // schemas, never a cursor. Idempotent when the caller already augmented
    // (the `Query` wrapper augments this select before its `compile(query.
    // first, …)`), so the wrapped path does not re-derive — a binding whose
    // derivation matches is kept, so a self-named `(SELECT … FROM T) AS T`
    // still reads the base and a shadowed CTE keeps its binding. `visited`
    // carries the cyclic-view guard, `validate` gates a derived body's eager
    // type-check the same as the wrapper's.
    //
    // The augmented `context` threads onward to `subquery(of:)`/`group`, which
    // REVEAL the base before lowering a nested subquery — this select's (and
    // every enclosing select's) derived aliases dropped, the CTEs and store
    // relations kept — so a subquery's FROM sees no derived alias while a CTE
    // a same-named derived alias here shadows stays visible. The layered
    // overlay never overwrote the CTE, so no separate pre-augment context runs.
    let context = try augment(context, for: .select(select), rows: false)
    guard let relation = select.from else {
      // A FROM-less select projects expressions over a single row; a `WHERE`,
      // `GROUP BY`, `HAVING`, `ORDER BY`, `OFFSET`/`FETCH`, or `JOIN` has no
      // relation to apply to. The parser never produces that shape, but a
      // direct `Select(from: nil, …)` can, so reject it rather than silently
      // ignore the clause — a scalar projection would drop a `GROUP
      // BY`/`HAVING` otherwise.
      guard select.joins.isEmpty, select.predicate == nil,
          select.grouping.isEmpty, select.having == nil,
          select.order == nil, select.limit == nil else {
        throw .unsupported(
            "a WHERE, GROUP BY, HAVING, ORDER BY, OFFSET/FETCH, or JOIN " +
            "requires a FROM clause")
      }
      // A scalar projection may still nest an UNCORRELATED subquery
      // (`SELECT CASE WHEN EXISTS (Q) …`); compile each ONCE for its width and
      // thread the map through so the term lowers as it does on the FROM'd path
      // rather than hit the default unsupported map. The run path builds the
      // matching run-time cache from `query.subqueries` (which descends the
      // projection), so the subquery is materialised there — `compile` runs it
      // never.
      // A FROM-less select adds no relations, so its nested subqueries
      // correlate against this select's own enclosing scope `outer` unchanged;
      // and its OWN columns (none but a projected outer reference) correlate
      // outward through `outer` too. The seam is `plans.rest`; `scalar` (via
      // `Schema.terms`) BARS it — a projection is a barred clause position — so
      // a correlated column of THIS query is diagnosed, not lowered to a
      // `Term.parameter`, matching `columns(of:)`'s schema-path rejection.
      let plans = try subquery(of: select, context)
      return try select.projection.scalar(context.routines,
                                          subquery: plans.rest)
    }
    // A LATERAL first FROM item has no PRECEDING relation to correlate against,
    // so it is meaningless (and ISO forbids it) — fault rather than resolve a
    // lateral body against nothing.
    if relation.lateral {
      throw .state("42601",
                   "a LATERAL derived table needs a preceding FROM item")
    }
    let from = try resolve(relation, context)

    if let limit = select.limit {
      // The parser yields only non-negative counts (a `-` is its own token),
      // but a direct `Limit(count:offset:)` may carry negatives the executor's
      // skip and take would trap on. Reject them as a query error rather than
      // crash.
      guard limit.offset >= 0 else {
        throw .state("2201X", "OFFSET row count must be non-negative")
      }
      guard (limit.count ?? 0) >= 0 else {
        throw .state("2201W", "FETCH row count must be non-negative")
      }
    }

    // An aggregate query — one with a `GROUP BY`, a `HAVING`, or an aggregate
    // in its projection — compiles through the grouped path, which places an
    // `aggregate` node above the WHERE/join chain and lowers the projection,
    // `HAVING`, and `ORDER BY` against the grouped slot space. A non-aggregate
    // query compiles exactly as before.
    if select.aggregates {
      return try group(select, relation, from, context)
    }

    guard !select.joins.isEmpty else {
      // Compile every nested subquery ONCE for its arity/type, ahead of
      // lowering, into a map the WHERE/projection/ORDER BY lowering reads — and
      // discover each one's CORRELATION against this select's single-relation
      // scope (`enclosing`). This select's OWN columns correlate outward
      // through `outer`.
      let enclosing = Scope([(relation, from.schema)])
      let plans = try subquery(of: select, context, enclosing: enclosing)
      var filter: Filter? = nil
      if let predicate = select.predicate {
        filter = try from.schema.lower(predicate, in: relation,
                                       context.routines, subquery: plans.rest)
      }
      // The projection and ORDER BY are BARRED clause positions (only the WHERE
      // admits a correlated column of THIS query); `terms`/`order` bar the seam
      // intrinsically, so passing `plans.rest` cannot admit one. A nested
      // subquery there still lowers with its OWN inner correlation.
      let projection =
          try from.schema.terms(select.projection, in: relation,
                                context.routines, subquery: plans.rest)

      // The ORDER BY lowers its keys against the projection: an ordinal or an
      // output-alias key resolves to a select-list item's own term, an ordinary
      // expression key lowers fresh over the source. Its terms and the
      // projection are still in base-ordinal space here.
      var order = Array<SortKey>()
      if let clause = select.order {
        let names = select.projection.outputs(count: projection.count)
        order = try from.schema.order(clause, in: relation, projection, names,
                                      context.routines, subquery: plans.rest)
      }

      // Under DISTINCT every ORDER BY key must be a select-list value — the
      // dedup runs on the projected rows, so ordering on a dropped value is
      // ill-defined (see `distinct`). The order keys and projection are
      // aligned with the AST keys by index. A key matching a projected term is
      // rebound to that projected column so the sort reuses the materialised
      // slot rather than re-evaluating it.
      if select.distinct, let clause = select.order {
        order = try distinct(clause.keys, order, projection)
      }

      // The referenced ordinals, in slot order: slot `i` is `ordinals[i]`.
      let ordinals = referenced(projection, filter, order)
      let slot = invert(ordinals)
      let scan = from.leaf(ordinals)
      return scan.shaped(
          distinct: select.distinct,
          projection: projection.map { $0.remapped(through: slot) },
          filter: filter.map { $0.remapped(through: slot) },
          order: order.map { $0.remapped(through: slot) },
          limit: select.limit)
    }

    // Resolve every joined relation and lay all relations — the FROM relation
    // first, then each joined one in source order — end to end in one combined
    // ordinal space. The helper builds the running `relations` INCREMENTALLY
    // and threads each join's PRECEDING FROM as its resolve scope, so a LATERAL
    // arm's schema derives against the relations before it.
    let (joined, relations) = try resolve(from: relation, schema: from.schema,
                                          joins: select.joins, context)
    let scope = Scope(relations)

    // Each join's ON predicate lowers to a `Filter` at its own chain level,
    // resolved against only the prefix already in scope plus the relation that
    // join introduces — the FROM relation and joins `0…index` — never a
    // relation joined later. Since `Scope` lays relations at cumulative offsets
    // from 0, a prefix scope yields the same global combined ordinals as the
    // full-chain scope, so the ON ordinals remap through `slot` as before;
    // resolving against the prefix rejects a reference to a not-yet-joined
    // relation (`SQLError.column`) and judges ambiguity only within the prefix.
    // A `column = column` conjunct lowers to a `match` hash-join key; any
    // inequality or expression equality lowers to a residual the join filters.
    // The WHERE and ORDER lower against the whole chain, which legitimately
    // sees every relation. Each join's PREFIX scope — the FROM relation and
    // joins `0…index`, the relations available AT that join point, never one
    // joined LATER — the scope its `ON` lowers against and a subquery in that
    // `ON` correlates against.
    let prefixes = select.joins.indices.map { index in
      Scope(Array(relations[0 ... index + 1]))
    }
    // Resolve each LATERAL join's body ONCE against the PRECEDING FROM — the
    // FROM relation and the joins BEFORE this one (`relations[0…index]`, ONE
    // less than the prefix, which includes the join's own relation) — so a body
    // column naming a preceding relation correlates outward and the body's plan
    // is pre-compiled for the per-outer-row apply. A non-lateral join records
    // nothing here (its `nil` slot). The apply is `.inner` (CROSS APPLY, which
    // drops an unmatched outer row) or `.left` (OUTER APPLY, which NULL-extends
    // one); `.right`/`.full` are nonsensical for a correlated body, so fault.
    let empty: (key: Subkey, correlation: Correlation)? = nil
    var laterals = Array(repeating: empty, count: select.joins.count)
    for index in select.joins.indices {
      let join = select.joins[index]
      guard join.relation.lateral,
          case let .derived(body) = join.relation.source else { continue }
      guard join.kind == .inner || join.kind == .left else {
        throw .state("0A000", "a RIGHT/FULL LATERAL join is not supported")
      }
      let preceding = Scope(Array(relations[0 ... index]))
      laterals[index] = try lateral(body, against: preceding,
                                    columns: join.relation.columns, context)
    }
    // Compile every nested subquery ONCE for arity/type, ahead of lowering,
    // into a map the join ONs, WHERE, projection, and ORDER BY lowering reads —
    // and discover each one's CORRELATION. A join `ON`'s subquery correlates
    // against its PREFIX scope; the WHERE/projection/ORDER against the whole
    // join `scope`. This select's OWN columns correlate outward through
    // `outer`. `validate` gates a nested filtered-out derived body's eager
    // type-check.
    let plans = try subquery(of: select, context, enclosing: scope,
                             prefixes: prefixes)
    var matches = Array<Filter>()
    matches.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      let join = select.joins[index]
      try matches.append(prefixes[index].on(join.on, context.routines,
                                            subquery: plans.on(index)))
    }
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause, context.routines,
                                  subquery: plans.rest)
    }
    // The projection and ORDER BY are BARRED clause positions: a correlated
    // column of THIS query is out of the minimal (b) cut there (only its
    // WHERE/ON admits one), so `terms`/`order` bar the seam intrinsically and
    // it is diagnosed rather than mis-resolved. A nested subquery in the
    // projection still lowers — its OWN inner WHERE correlation was discovered
    // in the pre-pass.
    let projection = try scope.terms(select.projection, context.routines,
                                     subquery: plans.rest)

    // The ORDER BY lowers its keys against the projection (as the
    // single-relation path does): an ordinal or an output-alias key resolves to
    // a select-list item's own term, an ordinary expression key lowers fresh
    // over the chain. Its terms and the projection are in combined base-ordinal
    // space here.
    var order = Array<SortKey>()
    if let clause = select.order {
      let names = select.projection.outputs(count: projection.count)
      order = try scope.order(clause, projection, names, context.routines,
                              subquery: plans.rest)
    }

    // Under DISTINCT every ORDER BY key must be a select-list value (see
    // `distinct`); order keys and projection are in combined base-ordinal
    // space here, aligned with the AST keys index-for-index. A key matching a
    // projected term is rebound to that projected column so the sort reuses the
    // materialised slot rather than re-evaluating it.
    if select.distinct, let clause = select.order {
      order = try distinct(clause.keys, order, projection)
    }

    // The combined referenced ordinals — projection ∪ every match ∪ WHERE ∪
    // order — packed per relation in chain order: relation i's referenced
    // ordinals take a contiguous slot run after every earlier relation's,
    // building the combined-ordinal → slot map and each relation's leaf
    // ordinals.
    var references = Set<Int>()
    for term in projection { term.references(into: &references) }
    for match in matches { match.references(into: &references) }
    predicate?.references(into: &references)
    for key in order { key.term.references(into: &references) }
    // A LATERAL apply reads its correlation's outer ordinals from the left
    // chain's record, so those preceding-relation ordinals must be MATERIALISED
    // (given a packed slot) even when no clause of THIS select references them
    // — else the correlation's remap through `slot` finds no slot for the outer
    // column its body names.
    for lateral in laterals {
      references.formUnion(lateral?.correlation.slots ?? [])
    }
    let combined = references.sorted()

    var slot = Dictionary<Int, Int>(minimumCapacity: combined.count)
    var locals = Array<Array<Int>>()
    var packed = 0
    for (offset, extent) in scope.layout {
      let local = combined.compactMap {
        offset <= $0 && $0 < offset + extent ? $0 - offset : nil
      }
      for index in local.indices {
        slot[offset + local[index]] = packed + index
      }
      locals.append(local)
      packed += local.count
    }

    // The left-deep chain: starting from the FROM relation's leaf, each join
    // folds in the next relation's scan. An INNER join is a `Select` on that
    // join's ON over the product — the optimiser turns each `Select`-over-
    // `Product` level into an index-nested-loop join. An OUTER join is an
    // `outer` node holding the ON directly, so the ON governs matching alone
    // and an unmatched preserved row is NULL-extended rather than dropped; its
    // ON is NOT distributed into the product (a `WHERE` still filters after
    // it).
    var chain = from.leaf(locals[0])
    for index in select.joins.indices {
      let on = matches[index].remapped(through: slot)
      // A LATERAL join re-evaluates its pre-compiled body per outer row (a
      // correlated apply): the apply node carries the body occurrence's `key`
      // and its correlation (its `slot` outer ordinals remapped to the left
      // chain's packed slots, so the per-row bind reads the correct cell) plus
      // the referenced body-output `ordinals` this select takes, laid after the
      // left's slots. Its `on` filters the concatenated pair; INNER APPLY drops
      // a left row with no surviving right row.
      if let lateral = laterals[index] {
        chain = .apply(chain, key: lateral.key,
                       correlation: lateral.correlation.remapped(through: slot),
                       ordinals: locals[index + 1], on: on,
                       kind: select.joins[index].kind)
        continue
      }
      let leaf = joined[index].leaf(locals[index + 1])
      switch select.joins[index].kind {
      case .inner:
        chain = .select(on, .product(chain, leaf))
      case .left, .right, .full:
        chain = .outer(chain, leaf, on: on, kind: select.joins[index].kind)
      }
    }

    return chain.shaped(
        distinct: select.distinct,
        projection: projection.map { $0.remapped(through: slot) },
        filter: predicate.map { $0.remapped(through: slot) },
        order: order.map { $0.remapped(through: slot) },
        limit: select.limit)
  }
}
