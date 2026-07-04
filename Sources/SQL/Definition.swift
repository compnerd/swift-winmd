// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The reserved namespace a DEFINITION_SCHEMA store relation is named under —
/// the ISO 9075-11 `DEFINITION_SCHEMA`, the base metadata relations the
/// portable `INFORMATION_SCHEMA` views read, case-folded for the dotted match.
private let kDefinitionNamespace = "definition_schema"

/// A base DEFINITION_SCHEMA relation the store serves — the raw metadata the
/// engine builds by ENUMERATING a catalog. Each carries its column schema as
/// (name, type) pairs — the ONE source the row build (`store(_:)`) and the
/// schema-only build (`schematise(_:)`) share, so name and type cannot drift.
///
/// These are the actual store of metadata: the `INFORMATION_SCHEMA` relations
/// are ordinary VIEWS over them (see `View.standard`), resolved by the
/// engine's existing view machinery. The store holds each relation's portable
/// shape, so a view is a plain column projection — the reshaping the grammar
/// cannot yet express in SQL (NULL literals, a `CASE` mapping) lives in the
/// builder here, and the view names and orders the store's columns.
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
/// than reading a stored relation: `store(_:)` walks the catalog's
/// `relations()`/`views()` and each relation's schema and builds the named
/// relation's rows as an escapable `Materialised`. It builds no cached state,
/// so the engine resolves a `definition_schema.` name lazily, building only the
/// one a query references. The portable `INFORMATION_SCHEMA` relations are
/// ordinary VIEWS over these (see `View.standard`).
///
/// The store is dialect-neutral: it reads only the adapter surface every
/// `Catalog` shares, so any source gets it for free. It is built in engine core
/// rather than by an adapter because `Schema` — a relation's `names`/`types` —
/// is internal to the engine.
extension Catalog where Self: ~Escapable {
  /// The `Materialised` for the reserved `definition_schema.` `relation`, built
  /// over this catalog by ENUMERATING it — `store` walks its
  /// `relations()`/`views()` and each relation's schema and builds the
  /// relation's rows. It builds no cached state, so the engine resolves a
  /// reserved name lazily, building only the one a query references.
  borrowing func store(_ relation: Definition,
                       _ returns: Dictionary<String, ValueType> = [:])
      -> Materialised {
    switch relation {
    case .tables:
      tables()
    case .columns:
      columns(returns)
    }
  }

  /// `ctes` extended with every `definition_schema.` store relation `query`
  /// names, each built over this catalog as a `Materialised` — the resolution
  /// surface the engine consults for a reserved store relation.
  ///
  /// The store sits AFTER the common table expressions and BEFORE the base
  /// catalog: a `definition_schema.` name is added only when `ctes` does not
  /// already bind it (a user relation may shadow the store), and the extended
  /// map is consulted first by every resolution phase (compile, optimise,
  /// execute) — so it shadows a base table or view but yields to a CTE.
  /// Building runs lazily per named relation: only the reserved relations the
  /// query actually references are enumerated. A name in the reserved namespace
  /// but not one the store serves is left unbound, so it faults later as an
  /// ordinary unknown relation (`SQLError.relation`).
  borrowing func augment(_ ctes: CTEs, for query: Query,
                         returns: Dictionary<String, ValueType> = [:]) -> CTEs {
    var names = Set<String>()
    query.collect(into: &names)
    var augmented = ctes
    for name in names where augmented[name.lowercased()] == nil {
      if let relation = Definition(name) {
        augmented[name.lowercased()] = store(relation, returns)
      }
    }
    return augmented
  }

  /// The `definition_schema.` overlay a view's body resolves against — the
  /// reserved store relations the view `name` names in its OWN query, each
  /// built over this catalog — or empty when `name` is not a view (or names
  /// none). It seeds the view sub-plan's compile, optimise, and execute so a
  /// view defined over a store relation resolves; it never carries a caller's
  /// statement CTEs, so a view means what it was registered to mean.
  ///
  /// The name resolves to a user view first, then a built-in `View.standard`
  /// view — so a built-in `information_schema.` view over the store re-resolves
  /// its own `definition_schema.` scan exactly as a user view would.
  borrowing func overlay(_ name: String) -> CTEs {
    guard let view = resolve(view: name) else { return [:] }
    return augment([:], for: view.query)
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

  /// The SCHEMA-ONLY `Materialised` for the reserved store `relation` — its
  /// columns and per-column types, with NO rows.
  ///
  /// It vends exactly what a lazy system table's `schema()` would: the column
  /// list and types a name resolution needs, without the row build. Typing a
  /// query — the view-body type resolution and the schema path in
  /// `columns(of:)` — resolves a reserved name through this rather than
  /// `store(_:)`, so it reads only the schema and never re-enters the row
  /// builder (`columns()` lists views, whose bodies name the relation again).
  borrowing func schematise(_ relation: Definition) -> Materialised {
    Materialised(columns: relation.names, rows: [], types: relation.types)
  }

  /// `ctes` extended with a SCHEMA-ONLY `Materialised` for every
  /// `definition_schema.` store relation `query` names — the schema-only
  /// sibling of `augment` the typing path uses.
  ///
  /// It mirrors `augment`'s CTE-first precedence and lazy per-name building,
  /// but binds each reserved name to its `schematise(_:)` schema (header +
  /// types, no rows) rather than its `store(_:)` rows. Resolving a view body's
  /// types through this never triggers the row build, so a view over
  /// `definition_schema.columns` types without the builder re-entering itself.
  borrowing func schemas(_ ctes: CTEs, for query: Query) -> CTEs {
    var names = Set<String>()
    query.collect(into: &names)
    var augmented = ctes
    for name in names where augmented[name.lowercased()] == nil {
      if let relation = Definition(name) {
        augmented[name.lowercased()] = schematise(relation)
      }
    }
    return augmented
  }

  /// `definition_schema.tables` — one row per base relation and view, with the
  /// standard `table_catalog`, `table_schema`, `table_name`, `table_type`
  /// columns. `table_type` is `'BASE TABLE'` for a base relation, `'VIEW'` for
  /// a view; `table_catalog`/`table_schema` are `NULL` (the store models a
  /// single unnamed catalog and schema).
  private borrowing func tables() -> Materialised {
    var rows = Array<Array<Value>>()
    // A view shadows a same-named base relation (`resolve` picks the view), so
    // a shadowed base is unreachable and is not listed — the name appears once,
    // as the VIEW a query actually resolves.
    let shadowed = Set(views().map { $0.lowercased() })
    for name in relations() {
      // A reserved store name resolves to the store overlay, never a catalog
      // relation of that name, so such a base is unreachable and is not listed;
      // nor is a base a view shadows.
      guard Definition(name) == nil,
          !shadowed.contains(name.lowercased()) else { continue }
      rows.append([.null, .null, .text(name), .text("BASE TABLE")])
    }
    for name in views() where Definition(name) == nil {
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
  /// types from `returns`, the run's routine return-type map, so a view's
  /// `GUID(...)` column advertises `character varying`, not the integer
  /// default.
  private borrowing func columns(_ returns: Dictionary<String, ValueType>)
      -> Materialised {
    var rows = Array<Array<Value>>()
    // A view shadows a same-named base relation, so a shadowed base's columns
    // are unreachable and not listed — only the view's are (below).
    let shadowed = Set(views().map { $0.lowercased() })
    for name in relations() {
      // A reserved store name resolves to the store overlay, not a catalog
      // relation, so its columns are unreachable and not listed; nor is a base
      // a view shadows.
      guard Definition(name) == nil,
          !shadowed.contains(name.lowercased()) else { continue }
      guard let table = table(named: name) else { continue }
      let names = table.names
      let types = table.types
      for ordinal in 0 ..< table.width {
        rows.append([.text(name), .text(names[ordinal]),
                     .integer(ordinal + 1), .text(types[ordinal].domain),
                     .text("YES")])
      }
    }
    for name in views() where Definition(name) == nil {
      guard let view = view(named: name) else { continue }
      // List a view's columns only if its WHOLE body validates — exactly the
      // resolution a run performs, so a view a `SELECT *` could not run is not
      // advertised as queryable metadata. Validate via the REAL `compile`
      // rather than a resolve-only reimplementation of it: a hand-rolled
      // validator drifts from compile (it missed a scalar call's arguments,
      // advertising `SELECT BITAND(Missing, 1)` though the run faults on
      // `Missing`), whereas `compile` resolves every arm's WHERE, joins, GROUP
      // BY, HAVING, ORDER BY, projection — INCLUDING each scalar call's
      // arguments — and a UNION's arity. The view body compiles over its OWN
      // `definition_schema.` overlay, built SCHEMA-ONLY (`schemas`) so a view
      // over a store relation resolves without this row builder re-entering
      // itself.
      // The body must compile AND its width must equal the view's DECLARED
      // column count: `resolve` rejects a view whose declared arity differs
      // from its body's (`v(x) AS SELECT * FROM People`), so such a view cannot
      // run and is not advertised here.
      guard let plan = try? compile(view.query, schemas([:], for: view.query)),
          plan.width == view.columns.count else { continue }
      // `compile` resolved the body — its relations, arities, and each call's
      // ARGUMENTS — but cannot check a called routine EXISTS (it holds no
      // routine set and builds no call term; the name binds at execute), so
      // reject a body naming an unregistered function against the run's routine
      // return-type map. The first-arm type walk below faults an unknown call
      // it PROJECTS, but not one in a `WHERE`/`HAVING` or a later `UNION` arm,
      // so gate on `calls`, the whole-body inventory — a view a run could not
      // execute is not advertised as queryable metadata.
      let unknown = view.query.calls.first { returns[$0.lowercased()] == nil }
      guard unknown == nil else { continue }
      // Type the columns from the body's first arm.
      let overlay = schemas([:], for: view.query)
      guard let resolved = try? columns(of: view.query.first, overlay,
                                        visited: [name.lowercased()],
                                        returns: returns),
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
  /// the `UNION` chain and each arm, into `names` — the reserved store names
  /// among them are what `Catalog.augment` builds.
  func collect(into names: inout Set<String>) {
    switch self {
    case let .select(select):
      select.collect(into: &names)
    case let .union(left, select, _):
      left.collect(into: &names)
      select.collect(into: &names)
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

extension ValueType {
  /// The ISO `data_type` spelling of this value type.
  ///
  /// The engine's types map onto the ISO domains: exact numeric to `integer`,
  /// approximate numeric to `double precision`, character to `character
  /// varying`, truth-valued to `boolean`, and binary to `binary varying`.
  internal var domain: String {
    switch self {
    case .integer: "integer"
    case .double: "double precision"
    case .text: "character varying"
    case .boolean: "boolean"
    case .blob: "binary varying"
    }
  }
}
