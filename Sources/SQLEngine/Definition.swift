// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The reserved namespace a DEFINITION_SCHEMA store relation is named under —
/// the ISO 9075-11 `DEFINITION_SCHEMA`, the base metadata relations the
/// portable `INFORMATION_SCHEMA` views read, case-folded for the dotted match.
private let kDefinitionNamespace = "definition_schema"

/// A base DEFINITION_SCHEMA relation the store serves — the raw metadata the
/// engine builds by ENUMERATING a catalog. Each carries its column schema as
/// (name, type) pairs — the ONE source the row build and the schema-only build
/// (`store(_:rows:)`) share, so name and type cannot drift.
///
/// These are the actual store of metadata: the `INFORMATION_SCHEMA` relations
/// are ordinary VIEWS over them, resolved by the engine's existing view
/// machinery. The store holds each relation's portable shape, so a view is a
/// plain column projection — the reshaping the grammar cannot yet express in
/// SQL (NULL literals, a `CASE` mapping) lives in the builder here, and the
/// view names and orders the store's columns.
internal enum Definition {
  case tables
  case columns

  /// The store relation `name` denotes, or `nil` if it is not one — the name
  /// matched case-insensitively against the reserved namespace.
  internal init?(_ name: String) {
    switch name.lowercased() {
    case "\(kDefinitionNamespace).tables":
      self = .tables
    case "\(kDefinitionNamespace).columns":
      self = .columns
    default:
      return nil
    }
  }

  /// The relation's column names, in order.
  internal var names: Array<String> { schema.map(\.name) }

  /// The relation's column types, in order.
  internal var types: Array<ValueType> { schema.map(\.type) }

  /// The relation's column schema — its (name, type) pairs, the ONE source
  /// `names` and `types` (and the row and schema builders) read, so the two
  /// cannot drift.
  private var schema: Array<(name: String, type: ValueType)> {
    switch self {
    case .tables:
      [("table_catalog", .text), ("table_schema", .text),
       ("table_name", .text), ("table_type", .text)]
    case .columns:
      [("table_name", .text), ("column_name", .text),
       ("ordinal_position", .integer), ("data_type", .text),
       ("is_nullable", .text)]
    }
  }
}

extension View {
  /// The engine-provided views — the portable relations the engine ships,
  /// resolvable over ANY catalog without a source registering them, keyed by
  /// their case-folded dotted name.
  ///
  /// Where `Routines.standard` seeds the built-in scalar functions, this seeds
  /// the built-in VIEWS: the ISO `INFORMATION_SCHEMA` relations, each a stored
  /// `SELECT` over the `DEFINITION_SCHEMA` store. `resolve(view:)` consults
  /// these AFTER a catalog's own views and base tables, so a source that itself
  /// defines `information_schema.tables` shadows the built-in — the same low
  /// precedence the store's overlay held. A built-in view's body names a
  /// `definition_schema.` relation, resolved through the same overlay a user
  /// view over the store resolves through, so it plans, types, and executes
  /// exactly as a registered view does.
  internal static let standard: Dictionary<String, View> =
      ["information_schema.tables": tables,
       "information_schema.columns": columns]

  /// A view over the query `text`, parsing `text` to its `SELECT` and inferring
  /// the column names from its first arm's projection — the same rule
  /// `CREATE VIEW` applies without an explicit list, so the query alone names
  /// the columns. It TRAPS if `text` is not a single `SELECT`, or names no
  /// inferable columns — for a caller with a known-good literal (the engine's
  /// built-in views, a test fixture); a consumer parsing untrusted SQL uses
  /// `Statement(parsing:)` and the memberwise initializer.
  internal init(_ text: String) {
    guard case let .select(query) = try! Statement(parsing: text) else {
      fatalError("a view body must be a SELECT")
    }
    self.init(query: query, columns: try! query.first.projection.names())
  }

  /// The engine-provided (built-in `INFORMATION_SCHEMA`) view named `name`
  /// (case-folded), or `nil` if the engine ships none by that name.
  internal init?(named name: String) {
    guard let view = View.standard[name.lowercased()] else { return nil }
    self = view
  }

  /// `information_schema.tables` — a projection over the store relation
  /// `definition_schema.tables`, which already holds the portable shape
  /// (`table_catalog`/`table_schema` NULL, `table_name`, `table_type`), so the
  /// view names and orders its columns; the ISO reshaping the grammar cannot
  /// express lives in the store's builder.
  private static let tables =
      View("""
          SELECT table_catalog, table_schema, table_name, table_type
            FROM definition_schema.tables
          """)

  /// `information_schema.columns` — a projection over
  /// `definition_schema.columns`, the standard column-metadata relation.
  private static let columns =
      View("""
          SELECT table_name, column_name, ordinal_position, data_type,
                 is_nullable
            FROM definition_schema.columns
          """)
}

/// The `DEFINITION_SCHEMA` metadata store — the ISO 9075-11 base relations,
/// built on demand from any `Catalog` by ENUMERATING it.
///
/// A query may name a reserved `definition_schema.` relation
/// (`definition_schema.tables`, `definition_schema.columns`) wherever it names
/// a base table, and the engine answers it by ENUMERATING the catalog rather
/// than reading a stored relation: `store(_:rows:)` walks the catalog's
/// `relations()`/`views()` and each relation's schema and builds the named
/// relation's rows as an escapable `RelationInstance`. It builds no cached
/// state, so the engine resolves a `definition_schema.` name lazily, building
/// only the one a query references. The portable `INFORMATION_SCHEMA`
/// relations are ordinary VIEWS over these.
///
/// The store is dialect-neutral: it reads only the adapter surface every
/// `Catalog` shares, so any source gets it for free. It is built in engine core
/// rather than by an adapter because `Schema` — a relation's `names`/`types` —
/// is internal to the engine.
extension Catalog where Self: ~Escapable {
  /// The `RelationInstance` for the reserved `definition_schema.` `relation`,
  /// built over this catalog. When `rows` is `true` the relation is ENUMERATED
  /// into its rows — `store` walks the catalog's `relations()`/`views()` and
  /// each relation's schema; when `false` it vends a SCHEMA-ONLY relation
  /// (columns + types, no rows), exactly what a lazy system table's `schema()`
  /// would.
  ///
  /// The typing paths (the view-body type resolution and the schema path in
  /// `columns(of:)`) resolve a reserved name schema-only, so they read only the
  /// header and never re-enter the row builder (the row build lists views,
  /// whose bodies name the relation again). Building either form is lazy, so
  /// the engine resolves a reserved name building only the one a query
  /// references.
  borrowing func store(_ relation: Definition, rows: Bool,
                       _ routines: Routines = [:])
      -> RelationInstance {
    guard rows else {
      return RelationInstance(columns: relation.names, rows: [],
                              types: relation.types)
    }
    return switch relation {
    case .tables:
      tables()
    case .columns:
      columns(Context(routines: routines))
    }
  }

  /// `context` with its `relations` overlay extended by every
  /// `definition_schema.` store relation `query` names, each built over this
  /// catalog as a `RelationInstance` — the resolution surface the engine
  /// consults for a reserved store relation, threaded onward as the working
  /// scope.
  ///
  /// The store sits AFTER the common table expressions and BEFORE the base
  /// catalog: a `definition_schema.` name is added only when the overlay does
  /// not already bind it (a user relation may shadow the store), and the
  /// extended map is consulted first by every resolution phase (compile,
  /// optimise, execute) — so it shadows a base table or view but yields to a
  /// CTE. Building runs lazily per named relation: only the reserved relations
  /// the query actually references are enumerated. A name in the reserved
  /// namespace but not one the store serves is left unbound, so it faults later
  /// as an ordinary unknown relation (`SQLError.relation`).
  ///
  /// `rows` selects the build: a run passes `true` for the enumerated rows; a
  /// typing path passes `false` for the SCHEMA-ONLY sibling, so resolving a
  /// view body's types never triggers the row build (a view over
  /// `definition_schema.columns` types without the builder re-entering itself).
  /// A store relation's row build types a view's scalar-call column through the
  /// context's `routines`.
  ///
  /// The overlay also binds every DERIVED TABLE THIS query names in its own
  /// FROM/JOIN — a `FROM (SELECT …) AS t` — under its alias as a
  /// `RelationInstance` so the FROM/JOIN resolves it exactly as it resolves a
  /// common table expression (the `ScopedRelations` path). It binds ONLY this
  /// query's own aliases, not a nested subquery's: `augment` runs at every
  /// query level (`run`, `compile`, `typecheck`, and `materialise` each
  /// augment the query they receive), so a subquery binds its own aliases in
  /// its OWN scope. This SELECT-scopes derived tables — unlike a
  /// statement-scoped, uniquely-named CTE — so two sibling subqueries may reuse
  /// an alias `t` without colliding, and this query's `t` SHADOWS an outer CTE
  /// or derived table of the same name. A derived table is UNCORRELATED in this
  /// cut: its inner query
  /// materialises ONCE, against the overlay WITHOUT its own alias (base catalog
  /// plus the store relations and CTEs in scope, NOT its sibling FROM items),
  /// so a reference to an outer or sibling column resolves as an unknown column
  /// — LATERAL is a later feature. `rows` selects the build the same as for the
  /// store: a run materialises the inner query's rows, a typing path resolves
  /// its OUTPUT columns to a schema-only relation (no cursor) and validates the
  /// inner body, so a derived table's alias types exactly as a run's would.
  borrowing func augment(_ context: Context, for query: Query, rows: Bool)
      throws(SQLError) -> Context {
    var names = Set<String>()
    query.collect(into: &names)
    var augmented = context.relations
    for name in names where augmented[name.lowercased()] == nil {
      if let relation = Definition(name) {
        augmented[name.lowercased()] =
            store(relation, rows: rows, context.routines)
      }
    }
    var derivations = Array<(String, Query, Array<String>)>()
    query.collect(derived: &derivations)
    if derivations.isEmpty { return context.scoping(augmented) }
    // A derived table's alias sharing a RANGE NAME with another FROM/JOIN item
    // in THIS SELECT's own scope collides: the alias-keyed overlay holds one
    // binding under that name, so binding the derived rows would SHADOW the
    // sibling — `FROM T JOIN (…) AS T` resolves the base `T` scan to the
    // derived rows, and `FROM (…) AS d JOIN (…) AS d` resolves both to the
    // later's. A duplicate RELATION alias (`FROM T AS d JOIN S AS d`) instead
    // leaves BOTH in scope, so a shared column is `SQLError.ambiguous` — reject
    // the same way here rather than silently shadow, faulting the ALIAS
    // ambiguous at BOTH the schema-only path and a run, BEFORE binding the
    // derived rows below (so the sibling is never shadowed). The collision is a
    // range name TWO of THIS query's own FROM/JOIN items spell where one is a
    // derived alias; a named-vs-named duplicate (no derived alias) stays the
    // lazy per-reference ambiguity. This query's own ranges are its OWN scope:
    // `collect(ranges:)`, `collect(sources:)`, and `collect(derived:)` all
    // stop at a `SELECT`, so a nested subquery's, a sibling subquery's, or a
    // set-operation arm's same-named alias (a DIFFERENT SELECT's ranges) is
    // unaffected, and a derived alias equal to an ENCLOSING query's relation is
    // not a same-scope collision (it shadows per normal scoping).
    //
    // The collision is counted against BOTH the EXPOSED range name and each
    // named relation's SOURCE name. A qualified reference names an item by its
    // range name (`alias ?? name`), but `resolve` LOOKS THE NAMED RELATION UP
    // BY ITS SOURCE NAME in the overlay — so a derived alias `T` shadowing an
    // aliased base `T AS x` (exposed range `x`, source `T`) would bind the
    // derived rows under `T`, and the base scan for `T AS x` — keyed on `T` —
    // would resolve to the DERIVED rows rather than the base table/CTE.
    // Counting the source names too faults that alias BEFORE binding the
    // derived rows, so `FROM T AS x JOIN (…) AS T` is rejected exactly as
    // `FROM T JOIN (…) AS T` is.
    var ranges = Array<String>()
    query.collect(ranges: &ranges)
    var identifiers = Array<String>()
    query.collect(sources: &identifiers)
    var counts = Dictionary<String, Int>()
    for range in ranges { counts[range.lowercased(), default: 0] += 1 }
    let sources = Set(identifiers.map { $0.lowercased() })
    for (alias, _, _) in derivations {
      let name = alias.lowercased()
      // >1 range: the derived alias equals another FROM/JOIN item's exposed
      // range name (a sibling derived alias, or an unaliased named relation).
      // A source-name match: the derived alias equals a named relation's
      // SOURCE name (an aliased base `T AS x` whose exposed range is `x`) —
      // `resolve` keys that relation on `T`, so the derived `T` would capture
      // its scan.
      if counts[name, default: 0] > 1 || sources.contains(name) {
        throw .ambiguous(alias)
      }
    }
    // The scope every derived body resolves against: the enclosing scope with
    // ALL derived layers REVEALED away, leaving the base (every CTE and store
    // relation). Revealing rather than a name blanket lets a self-named
    // `(SELECT … FROM T) AS T` read the BASE `T` while a `WITH t … FROM (SELECT
    // … FROM t) AS t` still reads the CTE `t`: the alias being DEFINED is in
    // its derived layer this augment is BUILDING (not yet pushed), so it is out
    // of scope in its own body, but a same-named CTE in the base is not.
    // Revealing keeps a derived table UNCORRELATED/no-LATERAL — a sibling
    // `FROM` item lives in the layer being built, invisible to the revealed
    // base scope, so `FROM (…) AS a JOIN (SELECT v FROM a) AS b` faults `a`.
    // `uncorrelated()` likewise CLEARS the enclosing correlation stack: a
    // non-LATERAL derived body must NOT see an ENCLOSING query's row either, so
    // `… IN (SELECT x FROM (SELECT 1 AS x FROM S WHERE S.k = T.k) AS d)` faults
    // on `T.k` — and CONSISTENTLY at both the strict schema pass and the
    // run, rather than the strict pass binding it while the lenient run records
    // no correlation and then faults at execution (a schema/run MISMATCH).
    let scope = context.body(augmented.revealed())
    // The idempotent re-augment keys on the derivation IDENTITY, not the name.
    // The run→compile→typecheck chain each augments the query it receives, so
    // the innermost derived layer may ALREADY bind THIS select's aliases to
    // THIS select's derivations — the same query, materialised against the
    // same revealed base scope. Skip re-materialising then (leave the layer as
    // is), so `augment` stays idempotent without re-resolving — and, on a run,
    // a stateful body is not re-executed. A binding whose derivation DIFFERS
    // (an ENCLOSING query's same-named derived table) is not this select's, so
    // a fresh layer is materialised and pushed, SHADOWING the outer one — a
    // nested subquery's `FROM t` reads ITS `t`. A self-named alias resolves the
    // base: the layer being pushed is not yet in scope when a body resolves.
    if derivations.allSatisfy({ augmented.derivation(of: $0.0.lowercased())
                                == $0.1 }) {
      return context.scoping(augmented)
    }
    // A derived table's optional `AS d(a, b)` column list renames its output
    // columns; thread it into `materialise` so the bound `RelationInstance`
    // carries the RENAMED names — the same overlay both `resolve` and
    // `schema(of:)` read a derived table's schema back from, so the run and the
    // schema-only paths see the renamed columns from ONE seam.
    // Materialise each alias's body against the revealed base scope (a
    // same-named CTE visible, the derived aliases being defined not), then push
    // them as one derived layer that SHADOWS an outer CTE or derived alias of
    // the same name in the scope THIS SELECT resolves its OWN references
    // against (projection/WHERE/JOIN-ON/GROUP/HAVING).
    var layer = Dictionary<String, RelationInstance>()
    for (alias, inner, columns) in derivations {
      layer[alias.lowercased()] =
          try materialise(inner, scope, rows: rows, columns: columns)
    }
    return context.scoping(augmented.pushing(layer))
  }

  /// A DERIVED TABLE's `query` materialised into a `RelationInstance` bound
  /// under its alias: its OUTPUT columns name the relation's columns (the ISO
  /// rule — a derived table's columns are its inner query's output names),
  /// typed from the same output-schema walk a scalar subquery's width and a
  /// CTE's schema use. `rows` selects the build — a run captures the inner
  /// query's rows, a typing path leaves them empty (schema-only, no cursor) —
  /// so the alias resolves and types identically on both paths.
  ///
  /// The inner query resolves against `context` (the base catalog plus the
  /// store relations and CTEs in scope), NOT its sibling FROM items. The OUTER
  /// treatment is the CALLER's: a NON-LATERAL derived body's caller
  /// (`augment`) enters through `context.body(…)`, CLEARING the correlation
  /// stack — so a reference to an outer or sibling column faults as an unknown
  /// column (the derived table is UNCORRELATED); a LATERAL body's caller
  /// (`lateral`) instead THREADS the preceding-FROM scope as `context.outer`,
  /// so a correlated reference to a preceding relation resolves outward. This
  /// derive is otherwise IDENTICAL for both — the same revealed-base overlay,
  /// output-schema walk, duplicate-column check, and `validate`-gated body
  /// type-check — so a lateral body inherits the CTE visibility and the
  /// operand/function validation a non-lateral body gets. Its OWN derived
  /// tables (a `FROM (SELECT … FROM (…) AS x) AS y`) are augmented into `scope`
  /// FIRST — the schema derivation resolves `x` exactly as a run would — so the
  /// schema and run paths bind the same nested aliases before either reads the
  /// inner query.
  borrowing func materialise(_ query: Query, _ context: Context,
                             rows: Bool, columns renaming: Array<String> = [])
      throws(SQLError) -> RelationInstance {
    // Bind the inner query's OWN derived tables (and store relations) before
    // deriving its schema — a run augments them recursively, so the schema
    // path must too, or a nested derived table's alias resolves as unknown
    // here while the run resolves it (schema/run parity). `visited` threads the
    // cyclic-view guard through: a derived body naming a view under resolution
    // re-enters `columns`/`compile` with that view already visited, so the
    // resolver faults `.recursion` rather than recursing to a stack overflow.
    //
    // This augment is SCHEMA-ONLY (`rows: false`), even on a run (`rows`
    // `true`): it exists only to derive the inner query's OUTPUT schema
    // (`columns(of:)` below), which reads name/schema bindings — NOT rows. The
    // single row materialisation is `run(query, context)`'s job below, and it
    // re-augments the body itself. Materialising here as well (`rows: true`)
    // would EXECUTE a nested derived body once for the schema and AGAIN in that
    // run, so a stateful routine in a `FROM (SELECT tick() …)` nested a level
    // down would fire twice for one query.
    let scope = try augment(context, for: query, rows: false)
    // The derived table's columns are its inner query's OUTPUT columns (the
    // ISO rule): the NAMES from the FIRST arm's projection, the TYPES UNIFIED
    // across every set-operation arm (a mixed integer/double column widening to
    // `double`, matching the coerced values a run produces), each carrying its
    // `unconstrained` mask — resolved against the augmented `scope` so a
    // derived table over a CTE, a store relation, or a nested derived table
    // resolves.
    // `resolved(query:in:)` REVEALS the base for the body's NESTED subqueries:
    // `scope`'s derived layer shadows a CTE this body's own FROM alias names,
    // and revealing drops that layer, so a nested
    // `EXISTS (… FROM t)` reads the enclosing CTE `t` beneath — the layered
    // overlay never overwrote it, keeping schema/run parity without a
    // pre-augment context. The caller's `validate` threads through, so a RUN's
    // output discovery (`validate: false`) stays LENIENT — a nested derived
    // body's scalar a filter drops (`(SELECT Label + 1 …) … WHERE k = 0`) is
    // NOT eager-type-checked before execution, exactly as the non-derived path
    // never evaluates an unreached operand — while the strict schema path
    // (`validate: true`) still faults it.
    let derived = try resolved(query: query, in: scope)
    // An explicit `AS d(a, b)` column list positionally RENAMES the derived
    // table's inner output names, keeping each column's inferred TYPE and its
    // `unconstrained` mask (the list names, the body types unified across the
    // arms), so `(SELECT x, y FROM T) AS d(a, b)` addresses them as `a`, `b`.
    // Its arity must match the inner output width (`SQLError.columns`, the
    // CTE/view arity fault) — checked HERE, where the width is resolved, so a
    // list over a `SELECT *` derived body is checked once its `*` expands.
    // Absent a list, the inner output names stand. Carrying the mask through
    // the same indexing means an all-NULL derived column (`SELECT
    // NULLIF('a', 'a') AS x`) stays UNCONSTRAINED and unifies with any later
    // typed set-operation arm order-independently: a wrapper must not change
    // set-op typing.
    let outputs: Array<ResolvedColumn>
    if renaming.isEmpty {
      outputs = derived
    } else {
      guard renaming.count == derived.count else {
        throw .columns(expected: derived.count, got: renaming.count)
      }
      outputs = renaming.indices.map {
        ResolvedColumn(name: renaming[$0], type: derived[$0].type,
                       unconstrained: derived[$0].unconstrained)
      }
    }
    // A derived table's columns are its inner query's OUTPUT names (or the
    // explicit list above), so two same-named ones (`SELECT Id AS x, V AS x`,
    // or a `d(a, a)` list) leave the shadowed one unreachable through the alias
    // — exactly the case the Parser rejects for a view's or a CTE's inferred
    // column list. Fault it the SAME way here (`SQLError.duplicate`, the
    // "duplicate view column" fault), so it faults at BOTH the schema-only path
    // and a run rather than silently exposing the first `x`. A plain top-level
    // `SELECT Id AS x, V AS x` stays legal — the duplicate matters only where
    // the relation is named and its columns are addressed by that name (a view,
    // a CTE, a derived table).
    var seen = Set<String>()
    for output in outputs
        where !seen.insert(output.name.lowercased()).inserted {
      throw .duplicate(output.name)
    }
    let captured: Array<Array<Value>>
    if rows {
      // Resolve the inner body's relations against `visited` BEFORE running it,
      // so a body naming a view under resolution through this derived table
      // (`FROM (SELECT * FROM <self>) AS d`) faults `.recursion` rather than
      // recursing to a stack overflow. `run` re-compiles the body WITHOUT the
      // cyclic-view guard, so on the EXECUTE path (`derive` seeds `visited`
      // with the view under resolution) this guarded resolve fires — the
      // strict output discovery above no longer carries it once `validate` is
      // `false`. `validate: false` keeps it structural: the recursion guard
      // fires in `resolve` regardless, while a data-dependent operand a filter
      // drops is NOT eager-type-checked.
      _ = try compile(query, context.validating(false))
      // A run captures the inner query's rows once (uncorrelated).
      captured = try run(query, context)
    } else {
      // The schema-only path reads no cursor. When `validate`, it still
      // VALIDATES the whole inner body exactly as a run does — `compile`
      // resolves every arm's WHERE, joins, and projection and cross-checks a
      // UNION's arity; `typecheck` faults an ill-typed or unknown reachable
      // operand/call — so an invalid inner body (a bad column in a WHERE, or a
      // later arm) faults at the schema-only path exactly as at run, keeping
      // schema/run parity. The first-arm projection alone (`outputs` above)
      // would miss a fault outside it, advertising a schema for a derived table
      // that cannot run. When `validate` is `false` — a derive after a
      // successful run — the body is TRUSTED, not compiled/type-checked: the
      // outer run already proved it runnable, and re-checking a reachable
      // operand a data-dependent filter never reached would fault a query that
      // SUCCEEDED (`SELECT Name + 1 … WHERE Id = -1`), unlike the non-derived
      // path whose empty run never evaluates it.
      //
      // Compile/type-check from the revealed base `context` (idempotently
      // re-augmented inside each, which pushes the body's own derived layer):
      // `compile` reveals that scope for the body's nested subqueries, so a
      // subquery reading a CTE a body's FROM alias shadows resolves it beneath
      // the dropped layer — the layered overlay never overwrote it. The schema
      // walk validates the body's nested subqueries exactly as the run path
      // does (`run` compiles from the same base context).
      if context.validate {
        _ = try compile(query, context.validating(true))
        try typecheck(query, context)
      }
      captured = []
    }
    return RelationInstance(from: outputs, rows: captured, derivation: query)
  }

  /// `context` rescoped to the `definition_schema.` overlay a view's body
  /// resolves against — the reserved store relations the view `name` names in
  /// its OWN query, each built over this catalog, the caller's CTEs DROPPED (an
  /// empty overlay when `name` is not a view or names none). It seeds the view
  /// sub-plan's OPTIMISE so a view defined over a store relation resolves; it
  /// never carries a caller's statement CTEs, so a view means what it was
  /// registered to mean. The routines and bindings ride through unchanged.
  ///
  /// The name resolves to a user view first, then a built-in `View.standard`
  /// view — so a built-in `information_schema.` view over the store re-resolves
  /// its own `definition_schema.` scan exactly as a user view would.
  ///
  /// The augment is SCHEMA-ONLY (`rows: false`): the optimiser needs only
  /// name/schema bindings — it treats a store or derived alias as an unseekable
  /// materialised relation — NOT rows. Materialising here (`rows: true`) would
  /// EXECUTE the view's derived-table bodies during optimisation, so a stateful
  /// or non-deterministic routine in a `FROM (SELECT tick() …)` would run once
  /// at optimise and AGAIN at `derive`, double-consuming it. The single
  /// execution happens at `derive`/run.
  borrowing func overlay(_ name: String, _ context: Context)
      throws(SQLError) -> Context {
    // `uncorrelated()` CLEARS the caller's correlation stack: a view body is
    // resolved independently of its call site, so it must NOT correlate against
    // an enclosing row when the view is optimised from inside a correlated
    // subquery.
    let fresh = context.body([:])
    guard let view = resolve(view: name) else { return fresh }
    // `validate: false` — this overlay is the OPTIMISER's schema-only view-body
    // scope on the RUN path (`resolve`/`compile` already validated the body
    // under the caller's `validate`), so a data-dependent-empty derived body
    // the view nests must not be re-type-checked and fault a run.
    return try augment(fresh.validating(false), for: view.query, rows: false)
  }

  /// The view named `name`, or `nil`, by the precedence a query name follows.
  /// A USER view the catalog registers wins; a BASE relation of that name then
  /// shadows a built-in `information_schema.` view (so a source that vends its
  /// own `information_schema.tables` stays reachable, and `SELECT *` reads its
  /// rows); the engine-provided `View.standard` view answers only when nothing
  /// else bears the name.
  borrowing func resolve(view name: String) -> View? {
    if let view = view(named: name) { return view }
    if table(named: name) != nil { return nil }
    return View(named: name)
  }

  /// The names of every view a query can resolve — each user `views()` entry
  /// the store does not shadow, then each built-in `View.standard` view a user
  /// view or base relation does not shadow (the precedence `resolve(view:)`
  /// applies). The metadata builders enumerate these so a consumer discovers
  /// EVERY queryable view — the engine-provided `information_schema.` views are
  /// resolvable through `resolve(view:)`, so they belong in the catalog
  /// metadata alongside a user's own. A name resolves to its `View` with
  /// `resolve(view:)`.
  private borrowing func listable() -> Array<String> {
    var names = Array<String>()
    for name in views() where Definition(name) == nil {
      names.append(name)
    }
    for name in View.standard.keys {
      // A user view or a base relation of the same name shadows the built-in
      // (`resolve(view:)`), so list the built-in only when neither does.
      if view(named: name) == nil, table(named: name) == nil {
        names.append(name)
      }
    }
    return names
  }

  /// The base relations whose metadata the store reports — every `relations()`
  /// name that is neither a reserved `definition_schema.` store name (it
  /// resolves to the store overlay, not a catalog relation) nor shadowed by a
  /// same-named view (a view resolves ahead of a base, so the base is
  /// unreachable). The `tables`/`columns` builders share this one walk.
  private borrowing func bases() -> Array<String> {
    let shadowed = Set(views().map { $0.lowercased() })
    return relations().filter { name in
      Definition(name) == nil && !shadowed.contains(name.lowercased())
    }
  }

  /// `definition_schema.tables` — one row per base relation and view, with the
  /// standard `table_catalog`, `table_schema`, `table_name`, `table_type`
  /// columns. `table_type` is `'BASE TABLE'` for a base relation, `'VIEW'` for
  /// a view (a user view or a built-in `information_schema.` one);
  /// `table_catalog`/`table_schema` are `NULL` (the store models a single
  /// unnamed catalog and schema).
  private borrowing func tables() -> RelationInstance {
    var rows = Array<Array<Value>>()
    for name in bases() {
      rows.append([.null, .null, .text(name), .text("BASE TABLE")])
    }
    for name in listable() {
      rows.append([.null, .null, .text(name), .text("VIEW")])
    }
    return RelationInstance(columns: Definition.tables.names, rows: rows,
                            types: Definition.tables.types)
  }

  /// `definition_schema.columns` — one row per real column of every base
  /// relation, with the standard `table_name`, `column_name`,
  /// `ordinal_position` (1-based), `data_type`, `is_nullable` columns.
  ///
  /// Only a relation's REAL columns (`0 ..< width`) are reported — the virtual
  /// `Id`, owner foreign keys, and coded-index join keys past `width` are not
  /// ISO columns. `data_type` maps the engine's `ValueType` to its ISO domain;
  /// `is_nullable` is a first cut of `'YES'` for every column (the engine does
  /// not yet track per-column nullability). A view's columns are listed too,
  /// their types resolved from the view's body — a scalar call in that body
  /// types from `routines`, the run's registered routines, so a view's
  /// `GUID(...)` column advertises `character varying`, not the integer
  /// default.
  private borrowing func columns(_ context: Context)
      -> RelationInstance {
    var rows = Array<Array<Value>>()
    for name in bases() {
      guard let table = table(named: name) else { continue }
      let names = table.names
      let types = table.types
      for ordinal in 0 ..< table.width {
        rows.append([.text(name), .text(names[ordinal]),
                     .integer(ordinal + 1), .text(types[ordinal].domain),
                     .text("YES")])
      }
    }
    for name in listable() {
      guard let view = resolve(view: name) else { continue }
      // List a view's columns only if its WHOLE body validates — exactly the
      // resolution a run performs, so a view a `SELECT *` could not run is not
      // advertised as queryable metadata. Validate via the REAL `compile`
      // rather than a resolve-only reimplementation of it: a hand-rolled
      // validator drifts from compile (it missed a scalar call's arguments,
      // advertising `SELECT BITAND(Missing, 1)` though the run faults on
      // `Missing`), whereas `compile` resolves every arm's WHERE, joins, GROUP
      // BY, HAVING, ORDER BY, projection — INCLUDING each scalar call's
      // arguments — and a UNION's arity. The view body compiles over its OWN
      // `definition_schema.` overlay, built SCHEMA-ONLY so a view over a store
      // relation resolves without this row builder re-entering itself.
      // The body must compile AND its width must equal the view's DECLARED
      // column count: `resolve` rejects a view whose declared arity differs
      // from its body's (`v(x) AS SELECT * FROM People`), so such a view cannot
      // run and is not advertised here. `uncorrelated()` CLEARS the correlation
      // stack: a view body is defined independently of any call site, so the
      // schema-only listing must resolve it exactly as the compile path does —
      // never binding an unbound view-definition column to an enclosing row.
      let fresh = context.body([:]).validating(true)
      guard let overlay = try? augment(fresh, for: view.query, rows: false),
          let plan = try? compile(view.query, overlay),
          plan.width == view.columns.count else { continue }
      // The type-check and derive resolve the body under the cyclic-view guard
      // seeded with THIS view's name.
      let inner = overlay.visiting(name)
      // Type the columns from the body — NAMES off the first arm, TYPES unified
      // across every arm (a mixed integer/double column reporting `double`);
      // type-check every arm's REACHABLE operands and calls too — an unknown
      // call or a bad operand in a `WHERE`/`HAVING` or a later `UNION` arm
      // faults a run, but a first-arm resolve would miss it (`compile` cannot
      // check a routine exists), while an arm a short-circuit proves
      // unreachable is skipped. A view a `SELECT *` could not evaluate is not
      // advertised.
      let resolved = try? columns(unifying: view.query, inner).map(\.column)
      guard (try? typecheck(view.query, inner)) != nil, let resolved,
          resolved.count == view.columns.count else { continue }
      for ordinal in view.columns.indices {
        rows.append([.text(name), .text(view.columns[ordinal]),
                     .integer(ordinal + 1),
                     .text(resolved[ordinal].type.domain), .text("YES")])
      }
    }
    return RelationInstance(columns: Definition.columns.names, rows: rows,
                            types: Definition.columns.types)
  }
}

extension Query {
  /// Collects every relation name THIS query names in a `FROM`/`JOIN`, across
  /// the set-operation tree and each arm, into `names` — the reserved store
  /// names among them are what `Catalog.augment` builds.
  ///
  /// It does NOT descend a nested `EXISTS`/`IN (Q)`/scalar subquery: each
  /// subquery is compiled, type-checked, and run as a whole (`compile`/
  /// `typecheck`/`run` each `augment` the query they receive), so a subquery
  /// binds its OWN store relations in its OWN scope. Descending here would
  /// instead lift a subquery's names into this query's statement-global
  /// overlay, where a sibling subquery could not rebind a same-named entry.
  func collect(into names: inout Set<String>) {
    switch self {
    case let .select(select):
      select.collect(into: &names)
    case let .setop(_, left, right, _):
      left.collect(into: &names)
      right.collect(into: &names)
    }
  }

  /// Collects the DERIVED TABLES a single `SELECT` arm names in its own
  /// `FROM`/`JOIN` — each alias paired with its inner `Query` — into
  /// `derivations`. `Catalog.augment` materialises each once and binds it under
  /// its alias in the scope of the arm that owns it, so the resolution scope
  /// reads a derived table exactly as it reads a common table expression (see
  /// `ScopedRelations`).
  ///
  /// It stops at a `SELECT`: a `setop` collects NOTHING here, so its two arms'
  /// derived aliases never merge into one map. Each arm is augmented on its own
  /// as `compile`/`typecheck`/`scope` descend it (each `augment`s the arm it
  /// receives), so a derived alias binds only in the arm that names it — a
  /// left arm's `FROM T` resolves the base relation (or a same-named CTE),
  /// never a `derived T` a right arm named. Hoisting both arms into one
  /// query-level map instead bound a right arm's `T` query-wide, mis-resolving
  /// the left arm.
  ///
  /// It likewise does NOT descend a nested `EXISTS`/`IN (Q)`/scalar subquery,
  /// or a derived table's OWN inner query: derived aliases are scoped to the
  /// SELECT that owns their FROM/JOIN — not a statement-scoped, uniquely-named
  /// CTE — so each subquery and each inner query `augment`s its own derived
  /// tables in its own scope (see `Catalog.augment`/`materialise`). Descending
  /// would bind those aliases into one map, where two siblings sharing an alias
  /// `t` collide and an inner `t` cannot shadow an outer.
  func collect(derived derivations:
                   inout Array<(String, Query, Array<String>)>) {
    if case let .select(select) = self {
      select.collect(derived: &derivations)
    }
  }

  /// Collects the RANGE NAMES a single `SELECT` arm binds in its own `FROM`/
  /// `JOIN` — the alias a qualified reference names each item by (its explicit
  /// alias, else a named relation's spelling), duplicates KEPT — into `ranges`.
  /// `Catalog.augment` counts these to fault a derived alias that shadows a
  /// same-scope sibling. It stops at a `SELECT` as `collect(derived:)` does: a
  /// `setop` collects nothing, so each arm's ranges stay in its own scope, and
  /// a nested subquery is not descended.
  func collect(ranges: inout Array<String>) {
    if case let .select(select) = self {
      select.collect(ranges: &ranges)
    }
  }

  /// Collects the SOURCE NAMES a single `SELECT` arm's `FROM`/`JOIN` NAMED
  /// relations carry — the identifier `resolve` keys each named relation on in
  /// the overlay (`relation.name` for a `.named` source, IGNORING its alias),
  /// not the range name a qualified reference uses — into `sources`.
  /// `Catalog.augment` checks these too so a derived alias `T` shadowing an
  /// aliased base `T AS x` (exposed range `x`, source `T`) collides — `resolve`
  /// would otherwise bind the base scan, keyed on `T`, to the derived rows. It
  /// stops at a `SELECT` as `collect(ranges:)` does: a `setop` collects
  /// nothing, and a nested subquery is not descended.
  func collect(sources: inout Array<String>) {
    if case let .select(select) = self {
      select.collect(sources: &sources)
    }
  }
}

extension Select {
  /// Collects this select's `FROM` and `JOIN` relation names into `names`.
  func collect(into names: inout Set<String>) {
    if let from { names.insert(from.name) }
    for join in joins { names.insert(join.relation.name) }
  }

  /// Collects the range name of this select's `FROM` and each `JOIN` item — the
  /// alias a qualified reference names it by (`relation.alias`, else the named
  /// relation's spelling), matching `Scope.admits` — into `ranges`, duplicates
  /// KEPT so a collision counts.
  func collect(ranges: inout Array<String>) {
    if let from { ranges.append(from.alias ?? from.name) }
    for join in joins {
      ranges.append(join.relation.alias ?? join.relation.name)
    }
  }

  /// Collects the SOURCE NAME of this select's `FROM` and each `JOIN` NAMED
  /// relation — the `relation.name` (`.named`'s identifier, its alias ignored)
  /// that `resolve` keys the relation on — into `sources`, a derived table's
  /// source contributing NONE (its rows key on its alias, already a range).
  func collect(sources: inout Array<String>) {
    if let from, case .named = from.source { sources.append(from.name) }
    for join in joins {
      if case .named = join.relation.source {
        sources.append(join.relation.name)
      }
    }
  }

  /// Collects this select's `FROM` and `JOIN` NON-LATERAL derived tables — each
  /// alias with its inner query — into `derivations`. A LATERAL derived table
  /// is SKIPPED: it is not materialised once as a constant relation but
  /// resolved against the preceding FROM and re-evaluated per its rows (a
  /// correlated apply), so `compile(select)` binds and executes it directly
  /// rather than through the overlay `augment` builds.
  func collect(derived derivations:
                   inout Array<(String, Query, Array<String>)>) {
    if case let .derived(query) = from?.source, let alias = from?.alias,
        !(from?.lateral ?? false) {
      derivations.append((alias, query, from?.columns ?? []))
    }
    for join in joins {
      if case let .derived(query) = join.relation.source,
          let alias = join.relation.alias, !join.relation.lateral {
        derivations.append((alias, query, join.relation.columns))
      }
    }
  }
}
