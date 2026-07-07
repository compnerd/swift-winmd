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
/// relation's rows as an escapable `Materialised`. It builds no cached state,
/// so the engine resolves a `definition_schema.` name lazily, building only the
/// one a query references. The portable `INFORMATION_SCHEMA` relations are
/// ordinary VIEWS over these.
///
/// The store is dialect-neutral: it reads only the adapter surface every
/// `Catalog` shares, so any source gets it for free. It is built in engine core
/// rather than by an adapter because `Schema` — a relation's `names`/`types` —
/// is internal to the engine.
extension Catalog where Self: ~Escapable {
  /// The `Materialised` for the reserved `definition_schema.` `relation`, built
  /// over this catalog. When `rows` is `true` the relation is ENUMERATED into
  /// its rows — `store` walks the catalog's `relations()`/`views()` and each
  /// relation's schema; when `false` it vends a SCHEMA-ONLY relation (columns +
  /// types, no rows), exactly what a lazy system table's `schema()` would.
  ///
  /// The typing paths (the view-body type resolution and the schema path in
  /// `columns(of:)`) resolve a reserved name schema-only, so they read only the
  /// header and never re-enter the row builder (the row build lists views,
  /// whose bodies name the relation again). Building either form is lazy, so
  /// the engine resolves a reserved name building only the one a query
  /// references.
  borrowing func store(_ relation: Definition, rows: Bool,
                       _ routines: Routines = [:])
      -> Materialised {
    guard rows else {
      return Materialised(columns: relation.names, rows: [],
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
  /// catalog as a `Materialised` — the resolution surface the engine consults
  /// for a reserved store relation, threaded onward as the working scope.
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
  borrowing func augment(_ context: Context, for query: Query, rows: Bool)
      -> Context {
    var names = Set<String>()
    query.collect(into: &names)
    var augmented = context.relations
    for name in names where augmented[name.lowercased()] == nil {
      if let relation = Definition(name) {
        augmented[name.lowercased()] =
            store(relation, rows: rows, context.routines)
      }
    }
    return context.scoping(augmented)
  }

  /// `context` rescoped to the `definition_schema.` overlay a view's body
  /// resolves against — the reserved store relations the view `name` names in
  /// its OWN query, each built over this catalog, the caller's CTEs DROPPED (an
  /// empty overlay when `name` is not a view or names none). It seeds the view
  /// sub-plan's execute so a view defined over a store relation resolves; it
  /// never carries a caller's statement CTEs, so a view means what it was
  /// registered to mean. The routines and bindings ride through unchanged.
  ///
  /// The name resolves to a user view first, then a built-in `View.standard`
  /// view — so a built-in `information_schema.` view over the store re-resolves
  /// its own `definition_schema.` scan exactly as a user view would.
  borrowing func overlay(_ name: String, _ context: Context) -> Context {
    let fresh = context.scoping([:])
    guard let view = resolve(view: name) else { return fresh }
    return augment(fresh, for: view.query, rows: true)
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
  private borrowing func tables() -> Materialised {
    var rows = Array<Array<Value>>()
    for name in bases() {
      rows.append([.null, .null, .text(name), .text("BASE TABLE")])
    }
    for name in listable() {
      rows.append([.null, .null, .text(name), .text("VIEW")])
    }
    return Materialised(columns: Definition.tables.names, rows: rows,
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
      -> Materialised {
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
      // run and is not advertised here.
      let overlay = augment(context.scoping([:]), for: view.query, rows: false)
      guard let plan = try? compile(view.query, overlay),
          plan.width == view.columns.count else { continue }
      // Type the columns from the body's first arm; type-check every arm's
      // REACHABLE operands and calls too — an unknown call or a bad operand in
      // a `WHERE`/`HAVING` or a later `UNION` arm faults a run, but the
      // first-arm resolve would miss it (`compile` cannot check a routine
      // exists), while an arm a short-circuit proves unreachable is skipped. A
      // view a `SELECT *` could not evaluate is not advertised.
      guard (try? typecheck(view.query, overlay,
                            visited: [name.lowercased()])) != nil,
          let resolved = try? columns(of: view.query.first, overlay,
                                      visited: [name.lowercased()]),
          resolved.count == view.columns.count else { continue }
      for ordinal in view.columns.indices {
        rows.append([.text(name), .text(view.columns[ordinal]),
                     .integer(ordinal + 1),
                     .text(resolved[ordinal].type.domain), .text("YES")])
      }
    }
    return Materialised(columns: Definition.columns.names, rows: rows,
                        types: Definition.columns.types)
  }
}

extension Query {
  /// Collects every relation name this query names in a `FROM`/`JOIN`, across
  /// the set-operation tree and each arm, into `names` — the reserved store
  /// names among them are what `Catalog.augment` builds.
  func collect(into names: inout Set<String>) {
    switch self {
    case let .select(select):
      select.collect(into: &names)
    case let .setop(_, left, right, _):
      left.collect(into: &names)
      right.collect(into: &names)
    }
  }
}

extension Select {
  /// Collects this select's `FROM` and `JOIN` relation names into `names`.
  func collect(into names: inout Set<String>) {
    if let from { names.insert(from.name) }
    for join in joins { names.insert(join.relation.name) }
  }
}
