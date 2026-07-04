// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - In-memory adapter

/// A typed in-memory relation — a column name/kind list and rows — for the
/// INFORMATION_SCHEMA overlay tests.
private struct MetaRelation: Sendable {
  let names: Array<String>
  let types: Array<ValueType>
  let records: Array<Array<Value>>

  init(_ columns: Array<(String, ValueType)>,
       _ records: Array<Array<Value>> = []) {
    self.names = columns.map(\.0)
    self.types = columns.map(\.1)
    self.records = records
  }
}

/// A `Catalog` over named typed relations plus registered views, exposing a
/// virtual `Id` past each relation's real columns (to prove the overlay reports
/// only the real ones).
private struct MetaCatalog: Catalog {
  let catalog: Dictionary<String, MetaRelation>
  let registered: Dictionary<String, View>

  init(_ catalog: Dictionary<String, MetaRelation>,
       views: Dictionary<String, View> = [:]) {
    self.catalog = catalog
    self.registered = views
  }

  func table(named name: String) -> MetaTable? {
    guard let relation = catalog[name] else { return nil }
    return MetaTable(relation)
  }

  func view(named name: String) -> View? {
    registered[name]
  }

  func relations() -> Array<String> {
    catalog.keys.sorted()
  }

  func views() -> Array<String> {
    registered.keys.sorted()
  }
}

/// A `Table` over one typed relation, with a lone virtual `Id` at `width`.
private struct MetaTable: Table {
  let relation: MetaRelation

  init(_ relation: MetaRelation) {
    self.relation = relation
  }

  var width: Int { relation.names.count }
  var names: Array<String> { relation.names }
  var types: Array<ValueType> { relation.types }
  var virtuals: Array<String> { ["Id"] }
  var extent: Int { width + 1 }

  func ordinal(of name: String) -> Int? {
    if name == "Id" { return width }
    return relation.names.firstIndex(of: name)
  }

  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? { nil }

  func cursor() -> MetaCursor {
    MetaCursor(relation)
  }
}

private struct MetaCursor: Cursor {
  let relation: MetaRelation

  init(_ relation: MetaRelation) {
    self.relation = relation
  }

  var count: Int { relation.records.count }

  func row(_ index: Int) -> MetaRow? {
    guard index < relation.records.count else { return nil }
    return MetaRow(relation, index)
  }
}

private struct MetaRow: Row {
  let relation: MetaRelation
  let index: Int

  init(_ relation: MetaRelation, _ index: Int) {
    self.relation = relation
    self.index = index
  }

  subscript(_ column: Int) -> Value {
    borrowing get {
      column == relation.names.count ? .integer(index + 1)
                                     : relation.records[index][column]
    }
  }
}

// MARK: - Fixtures

/// A catalog of two base relations — `People` (a text column, an integer
/// column) and `Widget` (one text column) — and one registered view `Adults`.
private func catalog() -> MetaCatalog {
  MetaCatalog([
    "People": MetaRelation([("Name", .text), ("Age", .integer)],
                           [[.text("Ann"), .integer(30)]]),
    "Widget": MetaRelation([("Label", .text)], [[.text("cog")]]),
  ], views: ["Adults": View("SELECT Name FROM People")])
}

// MARK: - Helpers

/// Parses `text` to a query, failing on any other statement.
private func parse(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

/// Runs `text` against the introspection `catalog`, yielding the result rows.
private func run(_ text: String) throws -> Array<Array<Value>> {
  try catalog().run(parse(text))
}

// MARK: - Tests

struct IntrospectionTests {
  @Test("information_schema.tables lists base tables and views")
  func tables() throws {
    let rows = try run("""
        SELECT table_name, table_type FROM information_schema.tables
          ORDER BY table_type, table_name
        """)
    // Two base tables (People, Widget) and one view (Adults), ordered by type
    // then name — the base tables first (`BASE TABLE` < `VIEW`).
    #expect(rows == [
      [.text("People"), .text("BASE TABLE")],
      [.text("Widget"), .text("BASE TABLE")],
      [.text("Adults"), .text("VIEW")],
    ])
  }

  @Test("information_schema.tables carries the standard catalog/schema columns")
  func tableColumns() throws {
    let rows = try run("""
        SELECT * FROM information_schema.tables WHERE table_name = 'People'
        """)
    // table_catalog, table_schema (both NULL), table_name, table_type.
    #expect(rows == [[.null, .null, .text("People"), .text("BASE TABLE")]])
  }

  @Test("information_schema.columns names, positions, and types every column")
  func columns() throws {
    let rows = try run("""
        SELECT column_name, ordinal_position, data_type
          FROM information_schema.columns
         WHERE table_name = 'People'
         ORDER BY ordinal_position
        """)
    #expect(rows == [
      [.text("Name"), .integer(1), .text("character varying")],
      [.text("Age"), .integer(2), .text("integer")],
    ])
  }

  @Test("information_schema.columns lists a view's columns and kinds")
  func viewColumns() throws {
    // `Adults` is `SELECT Name FROM People` over the `.text` `Name` column, so
    // the overlay lists its one column with the resolved text domain — a
    // metadata consumer can discover the columns of a view `.tables` reports.
    let rows = try run("""
        SELECT column_name, data_type FROM information_schema.columns
         WHERE table_name = 'Adults'
         ORDER BY ordinal_position
        """)
    #expect(rows == [[.text("Name"), .text("character varying")]])
  }

  @Test("information_schema.columns types a view defined over the overlay")
  func viewOverIntrospection() throws {
    // `Meta` reads `information_schema.tables`, whose `table_name` is text, so
    // the builder must seed the view body's OWN introspection overlay for
    // `Meta`'s column to advertise the text domain, not the integer default.
    let body = try parse("SELECT table_name FROM information_schema.tables")
    let meta = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["Meta": View(query: body, columns: ["Label"])])
    let rows = try meta.run(parse("""
        SELECT data_type FROM information_schema.columns
         WHERE table_name = 'Meta'
        """))
    #expect(rows == [[.text("character varying")]])
  }

  @Test("information_schema.columns excludes the virtual Id column")
  func excludesVirtual() throws {
    // `People` exposes a virtual `Id` past its two real columns; the overlay
    // reports only the real ones, so the count is two, not three.
    let rows = try run("""
        SELECT COUNT(*) FROM information_schema.columns
         WHERE table_name = 'People'
        """)
    #expect(rows == [[.integer(2)]])
  }

  @Test("information_schema.columns reports YES nullability")
  func nullability() throws {
    let rows = try run("""
        SELECT is_nullable FROM information_schema.columns
         WHERE table_name = 'Widget'
        """)
    #expect(rows == [[.text("YES")]])
  }

  @Test("a view shadowing a base relation hides the base in the overlay")
  func shadowed() throws {
    // `People` is both a base relation and a view; `resolve` picks the
    // view, so the overlay lists the name once as a VIEW and reports the view's
    // columns — never a base row `SELECT *` can no longer reach.
    let body = try parse("SELECT Name FROM Widget")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Age", .integer)], []),
         "Widget": MetaRelation([("Name", .text)], [])],
        views: ["People": View(query: body, columns: ["Name"])])
    let tables = try cat.run(parse("""
        SELECT table_type FROM information_schema.tables
         WHERE table_name = 'People'
        """))
    #expect(tables == [[.text("VIEW")]])
    let cols = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'People'
        """))
    #expect(cols == [[.text("Name")]])
  }

  @Test("a view over information_schema.columns keeps its columns' kinds")
  func viewOverColumnsKinds() throws {
    // A view reading `information_schema.columns` ITSELF must resolve against a
    // schema-only seed of that relation, so its `column_name` column advertises
    // the text domain rather than falling back to the integer default.
    let body = try parse("SELECT column_name FROM information_schema.columns")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["c": View(query: body, columns: ["name"])])
    let rows = try cat.run(parse("""
        SELECT data_type FROM information_schema.columns
         WHERE table_name = 'c'
        """))
    #expect(rows == [[.text("character varying")]])
  }

  @Test("information_schema.columns terminates through transitive views")
  func transitiveViews() throws {
    // `A` reads `information_schema.columns` and `B` reads `A`; building the
    // columns overlay must not re-enter itself through `B`'s resolution of `A`
    // — it terminates (rather than overflowing), and the schema-only seed rides
    // through so `B`'s column keeps `column_name`'s text kind.
    let a = try parse("SELECT column_name FROM information_schema.columns")
    let b = try parse("SELECT a FROM A")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["A": View(query: a, columns: ["a"]),
                "B": View(query: b, columns: ["b"])])
    let rows = try cat.run(parse("""
        SELECT column_name, data_type FROM information_schema.columns
         WHERE table_name = 'B'
        """))
    #expect(rows == [[.text("b"), .text("character varying")]])
  }

  @Test("information_schema.columns hides a view whose WHERE is invalid")
  func invalidView() throws {
    // `v`'s projection resolves, but its WHERE names a missing column, so
    // `SELECT * FROM v` throws. The overlay validates the WHOLE body — as the
    // public schema API does — and does not advertise `v` as queryable
    // metadata.
    let body = try parse("SELECT Name FROM People WHERE Missing = 1")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose UNION arm is invalid")
  func invalidUnionArm() throws {
    // The leading arm resolves, but the second names a missing column, so the
    // whole view cannot run — the overlay must validate EVERY arm, not just the
    // first, and not list `u`.
    let body = try parse("""
        SELECT Name FROM People UNION SELECT Missing FROM People
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["u": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'u'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose join ON is invalid")
  func invalidJoin() throws {
    // The join's ON names a column `People` does not have, so `SELECT * FROM v`
    // fails to compile — the overlay validates each join's ON, not just the
    // projection, and does not list `v`.
    let body = try parse("""
        SELECT People.Name FROM People
          JOIN Pet ON People.Missing = Pet.Id
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], []),
         "Pet": MetaRelation([("Id", .integer)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose GROUP BY is invalid")
  func invalidGrouping() throws {
    // GROUP BY names a missing column, so `SELECT * FROM v` fails to compile —
    // the overlay validates the grouping, not just the projection.
    let body = try parse("SELECT Name FROM People GROUP BY Missing")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose scalar-call arg is bad")
  func invalidCallArgument() throws {
    // `v`'s projection is a scalar call `BITAND(Missing, 1)` whose ARGUMENT
    // names a column `People` does not have, so `SELECT * FROM v` fails to
    // compile (`Scope.term` resolves `Missing` and throws `SQLError.column`). A
    // resolve-only validator that typed a `.call` by its fallback kind WITHOUT
    // visiting its arguments advertised `v` anyway; validating each view via
    // the real `compile` — which lowers a call's arguments — closes that
    // gap, so `v` is not listed. This passes through the compile-based
    // validation, not a hand-added argument check.
    let body = try parse("SELECT BITAND(Missing, 1) AS x FROM People")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["x"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose HAVING is invalid")
  func invalidHaving() throws {
    // HAVING names a column that is neither a GROUP BY key nor aggregated, so
    // `SELECT * FROM v` fails to compile — the overlay validates the HAVING
    // too.
    let body = try parse("""
        SELECT Name FROM People GROUP BY Name HAVING Missing > 0
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view over an invalid view")
  func invalidNestedView() throws {
    // `w`'s WHERE is invalid and `v` reads `w`; `SELECT * FROM v` fails because
    // `w` cannot run, so the overlay validates the nested body and lists
    // neither.
    let w = try parse("SELECT Name FROM People WHERE Missing = 1")
    let v = try parse("SELECT Name FROM w")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["w": View(query: w, columns: ["Name"]),
                "v": View(query: v, columns: ["Name"])])
    let listed = try cat.run(parse("""
        SELECT table_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(listed == [])
  }

  @Test("information_schema.columns rejects a mismatched nested view")
  func mismatchedNestedView() throws {
    // `w` declares one column but its body projects two, so `resolve(w)`
    // faults and `SELECT * FROM v` cannot run; the nested resolution must
    // propagate that mismatch, not mask it with `w`'s declared schema, so `v`
    // is not listed.
    let w = try parse("SELECT Name, Age FROM People")
    let v = try parse("SELECT x FROM w")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text), ("Age", .integer)], [])],
        views: ["w": View(query: w, columns: ["x"]),
                "v": View(query: v, columns: ["x"])])
    let rows = try cat.run(parse("""
        SELECT table_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns rejects a wrong declared arity over *")
  func mismatchedStarArity() throws {
    // `v(x)` declares one column but `SELECT *` over two-column `People`
    // projects two, so `resolve` faults `SELECT * FROM v`. The builder
    // compares the compiled body width to the declared count, so `v` is not
    // listed.
    let body = try parse("SELECT * FROM People")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text), ("Age", .integer)], [])],
        views: ["v": View(query: body, columns: ["x"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a cyclic view and stays usable")
  func cyclicViews() throws {
    // `A` reads `B` and `B` reads `A` — a cycle. `SELECT * FROM A` cannot run:
    // resolution now faults it `.recursion` (see cyclicViewRuns) rather than
    // hanging, so the overlay validates each view via the real `compile`
    // and does not advertise a view that could never be queried. The cycle must
    // not hang or corrupt an UNRELATED metadata query either — `People` still
    // reports normally, and the cyclic views are absent.
    let a = try parse("SELECT * FROM B")
    let b = try parse("SELECT * FROM A")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["A": View(query: a, columns: ["x"]),
                "B": View(query: b, columns: ["y"])])
    let people = try cat.run(parse("""
        SELECT column_name, data_type FROM information_schema.columns
         WHERE table_name = 'People'
        """))
    #expect(people == [[.text("Name"), .text("character varying")]])
    let cyclic = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'A' OR table_name = 'B'
        """))
    #expect(cyclic == [])
  }

  @Test("a cyclic view faults rather than hanging when run")
  func cyclicViewRuns() throws {
    // `A` over `B` over `A` is a cyclic definition; running it once recursed
    // resolve→compile→resolve until the stack overflowed (an unrecoverable
    // crash, not an `SQLError`). The cycle guard threaded through
    // `compile`/`resolve` now reports `.recursion` instead — the same
    // definition-does-not-terminate condition a runaway recursive CTE raises.
    let a = try parse("SELECT * FROM B")
    let b = try parse("SELECT * FROM A")
    let cat = MetaCatalog([:],
        views: ["A": View(query: a, columns: ["x"]),
                "B": View(query: b, columns: ["y"])])
    #expect(throws: SQLError.recursion("A")) {
      let _ = try cat.run(parse("SELECT * FROM A"))
    }
  }

  @Test("a query joins a base relation against information_schema.columns")
  func joinIntrospection() throws {
    // The overlay is an ordinary relation, so it joins and filters like any
    // other — here counting a named table's columns via a WHERE.
    let rows = try run("""
        SELECT data_type FROM information_schema.columns
         WHERE table_name = 'Widget'
        """)
    #expect(rows == [[.text("character varying")]])
  }

  @Test("an unknown information_schema relation faults as unknown")
  func unknownReserved() throws {
    // A name in the reserved namespace the overlay does not serve is a plain
    // unknown relation.
    #expect(throws: SQLError.self) {
      let _ = try run("SELECT * FROM information_schema.routines")
    }
  }

  @Test("a user CTE shadows the information_schema overlay")
  func cteShadows() throws {
    // The overlay sits after the CTEs: a `WITH` binding the reserved name wins,
    // so the query reads the CTE's rows, not the enumerated metadata.
    let rows = try catalog().run(Statement(parsing: """
        WITH "information_schema.tables" (x) AS (SELECT 1)
          SELECT x FROM "information_schema.tables"
        """))
    #expect(rows == [[.integer(1)]])
  }

  @Test("a base relation shadows the built-in information_schema view")
  func baseShadowsBuiltin() throws {
    // A catalog vending its OWN `information_schema.tables` base relation must
    // reach it: a base relation shadows the engine's built-in view (precedence
    // user view > base table > built-in view), so `SELECT *` reads the base
    // rows, not the enumerated metadata.
    let cat = MetaCatalog([
      "information_schema.tables":
          MetaRelation([("x", .integer)], [[.integer(7)]]),
    ])
    let rows = try cat.run(parse("SELECT * FROM information_schema.tables"))
    #expect(rows == [[.integer(7)]])
  }

  @Test("a CTE may select from the information_schema overlay")
  func cteReads() throws {
    let rows = try catalog().run(Statement(parsing: """
        WITH t (n) AS (SELECT table_name FROM information_schema.tables
                        WHERE table_type = 'BASE TABLE')
          SELECT COUNT(*) FROM t
        """))
    #expect(rows == [[.integer(2)]])
  }

  @Test("columns(of:) resolves an information_schema relation's headers")
  func schemaHeaders() throws {
    let query = try parse("SELECT * FROM information_schema.tables")
    let columns = try catalog().columns(of: query)
    #expect(columns.map(\.name) == ["table_catalog", "table_schema",
                                    "table_name", "table_type"])
  }

  @Test("a fully qualified introspection column resolves like the bare form")
  func qualifiedColumn() throws {
    // The relation name itself carries a dot, so a qualified reference has two
    // (`information_schema.tables.table_name`); the last-dot split makes the
    // qualifier the two-part relation name, resolving to the same rows the bare
    // reference yields.
    let bare = try run("""
        SELECT table_name FROM information_schema.tables
          ORDER BY table_name
        """)
    let qualified = try run("""
        SELECT information_schema.tables.table_name
          FROM information_schema.tables
          ORDER BY table_name
        """)
    #expect(qualified == bare)
    #expect(!qualified.isEmpty)
  }

  @Test("a single-dot qualified column still resolves a base relation")
  func singleDotQualifier() throws {
    // A table-qualified reference over a base relation keeps its single-dot
    // meaning (qualifier `People`, column `Name`) under last-dot splitting.
    let rows = try run("SELECT People.Name FROM People")
    #expect(rows == [[.text("Ann")]])
  }

  @Test("a view over information_schema.tables yields the inline rows")
  func viewOverTables() throws {
    // A view whose body selects from a reserved introspection relation must
    // resolve its overlay from ITS OWN query, so selecting from the view yields
    // exactly what the inline query does.
    let body = try parse("""
        SELECT table_name FROM information_schema.tables
          WHERE table_type = 'BASE TABLE'
        """)
    let source = MetaCatalog([
      "People": MetaRelation([("Name", .text), ("Age", .integer)]),
      "Widget": MetaRelation([("Label", .text)]),
    ], views: ["meta": View(query: body, columns: ["table_name"])])
    let inline = try source.run(body)
    let viewed =
        try source.run(parse("SELECT table_name FROM meta"))
    #expect(viewed == inline)
    #expect(viewed == [[.text("People")], [.text("Widget")]])
  }

  @Test("a view over information_schema.columns yields the inline rows")
  func viewOverColumns() throws {
    let body = try parse("""
        SELECT column_name, data_type FROM information_schema.columns
          WHERE table_name = 'People'
          ORDER BY column_name
        """)
    let source = MetaCatalog([
      "People": MetaRelation([("Name", .text), ("Age", .integer)]),
    ], views: ["cols": View(query: body,
                            columns: ["column_name", "data_type"])])
    let inline = try source.run(body)
    let viewed = try source.run(parse("""
        SELECT column_name, data_type FROM cols ORDER BY column_name
        """))
    #expect(viewed == inline)
    #expect(viewed == [
      [.text("Age"), .text("integer")],
      [.text("Name"), .text("character varying")],
    ])
  }

  @Test("information_schema.columns preserves each column's value kind")
  func materialisedKinds() throws {
    // The overlay reports its own columns' kinds — `ordinal_position` is an
    // integer, `table_name`/`data_type` text — not a synthesized all-integer
    // schema.
    let columns =
        try catalog().columns(of: parse("""
            SELECT * FROM information_schema.columns
            """))
    let typed = Dictionary(uniqueKeysWithValues:
        columns.map { ($0.name, $0.type) })
    #expect(typed["table_name"] == .text)
    #expect(typed["ordinal_position"] == .integer)
    #expect(typed["data_type"] == .text)
  }

  @Test("columns(of:) types a view's columns from its resolved body")
  func viewKinds() throws {
    // `Adults` is `SELECT Name FROM People`, over the `.text` `Name` column. A
    // view stores no kinds — its declared schema types every column `.integer`
    // — so resolving the body's kinds is what reports the `.text` here rather
    // than the integer default.
    let columns =
        try catalog().columns(of: parse("SELECT * FROM Adults"))
    #expect(columns == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("a text-returning scalar-call column types character varying")
  func scalarReturnType() throws {
    // `v` projects a scalar call `TAG(Name)` whose routine declares a `.text`
    // return type. `information_schema.columns` types the view's column from
    // its body: a `.call` reads the run's routine return-type map, so `iid`
    // advertises `character varying`, not the `.integer` default a call fell to
    // before routines declared a return type. The run carries `TAG`, so its
    // return type reaches the store builder's view typing.
    let body = try parse("SELECT TAG(Name) AS iid FROM People")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["iid"])])
    let routines =
        Routines().registering("tag", returns: .text) { _ in .text("x") }
    let rows = try cat.run(parse("""
        SELECT column_name, data_type FROM information_schema.columns
         WHERE table_name = 'v'
        """), routines)
    #expect(rows == [[.text("iid"), .text("character varying")]])
  }

  @Test("columns(of:) types a scalar call by its routine's return type")
  func scalarCallColumn() throws {
    // The public schema API takes the SAME routines a run would, so a projected
    // `TAG(Name)` reports its declared `.text` return type, not `.integer`.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    let query = try parse("SELECT TAG(Name) AS t FROM People")
    let routines =
        Routines().registering("tag", returns: .text) { _ in .text("x") }
    #expect(try cat.columns(of: query, routines: routines)
                == [OutputColumn(name: "t", type: .text)])
    // Without the routines, `TAG` is an unknown function that a run could not
    // execute, so the schema faults rather than inventing an `.integer` header.
    #expect(throws: SQLError.self) { let _ = try cat.columns(of: query) }
  }

  @Test("columns(of:) faults on an unknown call in a predicate")
  func unknownCallPredicateColumns() throws {
    // The unknown `NOPE` is in the WHERE, invisible to the first-arm projection
    // walk; the whole-query inventory faults it, exactly as a run would.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    let query = try parse("SELECT Name FROM People WHERE NOPE(Name) = 1")
    #expect(throws: SQLError.self) { let _ = try cat.columns(of: query) }
  }

  @Test("columns(of:) faults on an unknown call in a later UNION arm")
  func unknownCallLaterArmColumns() throws {
    // The first arm types cleanly; the unknown `NOPE` is in the second arm the
    // first-arm walk never visits.
    let cat = MetaCatalog([
      "People": MetaRelation([("Name", .text)], []),
      "Pet": MetaRelation([("Species", .text)], []),
    ])
    let query = try parse("""
        SELECT Name FROM People UNION SELECT NOPE(Species) FROM Pet
        """)
    #expect(throws: SQLError.self) { let _ = try cat.columns(of: query) }
  }

  @Test("a routine return type crosses a view boundary in schema resolution")
  func scalarCallThroughView() throws {
    // `w` projects `TAG(Name)`; `SELECT * FROM w` must report `t` as the
    // routine's declared `.text`, so schema resolution threads the return map
    // across the view boundary rather than dropping it to `.integer`.
    let body = try parse("SELECT TAG(Name) AS t FROM People")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["w": View(query: body, columns: ["t"])])
    let routines =
        Routines().registering("tag", returns: .text) { _ in .text("x") }
    let typed =
        try cat.columns(of: parse("SELECT * FROM w"), routines: routines)
    #expect(typed == [OutputColumn(name: "t", type: .text)])
  }

  @Test("columns(of:) faults on an unknown call in a view body predicate")
  func unknownCallViewBodyColumns() throws {
    // `SELECT * FROM v` names no call, but v's body calls the unregistered
    // `NOPE` in its WHERE — a clause the view-boundary first-arm walk misses.
    // The body's call inventory must fault, as `SELECT * FROM v` would at run.
    let body = try parse("SELECT Name FROM People WHERE NOPE(Name) = 1")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("SELECT * FROM v"))
    }
  }

  @Test("information_schema.columns hides a view with an unknown scalar call")
  func unknownCallView() throws {
    // `v` projects `NOPE(Name)`; `NOPE` is not registered, so `SELECT * FROM v`
    // faults at run. `compile` lowers the call without checking the routine, so
    // the unknown function surfaces at typing — the view is not listed.
    let body = try parse("SELECT NOPE(Name) AS x FROM People")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["x"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose predicate calls unknown")
  func unknownCallPredicate() throws {
    // The unknown `NOPE` is in the WHERE, not the projection, so the first-arm
    // type walk never sees it — only the whole-body call inventory does, and a
    // run of `SELECT * FROM v` would fault `SQLError.function`.
    let body = try parse("SELECT Name FROM People WHERE NOPE(Name) = 1")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns hides a view whose later arm calls unknown")
  func unknownCallLaterArm() throws {
    // The first arm types cleanly; the unknown `NOPE` is in the second UNION
    // arm, which the first-arm walk never types — the inventory spans arms.
    let body = try parse("""
        SELECT Name FROM People UNION SELECT NOPE(Name) FROM People
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [])
  }

  @Test("information_schema.columns lists a view whose predicate calls known")
  func knownCallPredicate() throws {
    // The gate rejects only an UNKNOWN routine — a registered one in the WHERE
    // (`BITAND`, the standard prelude) leaves the view advertised.
    let body = try parse("SELECT Name FROM People WHERE BITAND(1, 1) = 1")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [[.text("Name")]])
  }

  // MARK: - DEFINITION_SCHEMA store

  @Test("definition_schema.tables is itself queryable as the store")
  func definitionTables() throws {
    // The store the portable `information_schema.tables` view reads is
    // queryable in its own right — it holds the shape the view merely renames.
    let rows = try run("""
        SELECT table_name, table_type FROM definition_schema.tables
          ORDER BY table_type, table_name
        """)
    #expect(rows == [
      [.text("People"), .text("BASE TABLE")],
      [.text("Widget"), .text("BASE TABLE")],
      [.text("Adults"), .text("VIEW")],
    ])
  }

  @Test("definition_schema.columns is itself queryable as the store")
  func definitionColumns() throws {
    let rows = try run("""
        SELECT column_name, ordinal_position, data_type
          FROM definition_schema.columns
         WHERE table_name = 'People'
         ORDER BY ordinal_position
        """)
    #expect(rows == [
      [.text("Name"), .integer(1), .text("character varying")],
      [.text("Age"), .integer(2), .text("integer")],
    ])
  }

  @Test("information_schema.tables yields exactly its definition_schema store")
  func informationOverDefinition() throws {
    // The portable view is a projection over the store, so the two return the
    // same rows — the layering is visible, not conflated.
    let over =
        try run("SELECT * FROM information_schema.tables ORDER BY table_name")
    let store =
        try run("SELECT * FROM definition_schema.tables ORDER BY table_name")
    #expect(over == store)
    #expect(!over.isEmpty)
  }

  @Test("an unknown definition_schema relation faults as unknown")
  func unknownStore() throws {
    // A name in the reserved store namespace the store does not serve is a
    // plain unknown relation, as an unserved information_schema name is.
    #expect(throws: SQLError.self) {
      let _ = try run("SELECT * FROM definition_schema.routines")
    }
  }

  @Test("a user CTE shadows the definition_schema store")
  func storeCTEShadows() throws {
    let rows = try catalog().run(Statement(parsing: """
        WITH "definition_schema.tables" (x) AS (SELECT 1)
          SELECT x FROM "definition_schema.tables"
        """))
    #expect(rows == [[.integer(1)]])
  }
}
