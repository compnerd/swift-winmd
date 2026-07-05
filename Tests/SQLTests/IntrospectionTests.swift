// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQL

import SQLTestSupport

// MARK: - In-memory adapter

// The INFORMATION_SCHEMA overlay tests run over the shared SQLTestSupport
// store, whose `FixtureCatalog`/`FixtureTable` already model named typed
// relations, registered views, and a virtual `Id` past each relation's real
// columns — exactly the shape these tests built by hand. `MetaCatalog` aliases
// the shared catalog so the inline fixtures read as before, and `MetaRelation`
// lifts the tests' `[(name, kind)]` schema tuples (with optional rows) into a
// `FixtureRelation`. The store folds `relations()`/`views()` case-insensitively
// and returns them unordered; every test that observes the enumeration sorts it
// with an explicit `ORDER BY`, so the order is unobservable here.
private typealias MetaCatalog = FixtureCatalog

/// A `FixtureRelation` from a `[(name, kind)]` schema and optional rows — the
/// shape the introspection fixtures declare their relations in.
private func MetaRelation(_ columns: Array<(String, ValueType)>,
                          _ records: Array<Array<Value>> = [])
    -> FixtureRelation {
  FixtureRelation(columns.map { FixtureField(name: $0.0, type: $0.1) }, records)
}

// MARK: - Fixtures

/// A catalog of two base relations — `People` (a text column, an integer
/// column) and `Widget` (one text column) — and one registered view `Adults`.
private func catalog() throws -> MetaCatalog {
  MetaCatalog([
    "People": MetaRelation([("Name", .text), ("Age", .integer)],
                           [[.text("Ann"), .integer(30)]]),
    "Widget": MetaRelation([("Label", .text)], [[.text("cog")]]),
  ], views: ["Adults": View(query: try parse("SELECT Name FROM People"),
                            columns: ["Name"])])
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
    // Two base tables (People, Widget) and the views — the user's `Adults` and
    // the two engine-provided `information_schema.` views, which are themselves
    // queryable — ordered by type then name (`BASE TABLE` < `VIEW`).
    #expect(rows == [
      [.text("People"), .text("BASE TABLE")],
      [.text("Widget"), .text("BASE TABLE")],
      [.text("Adults"), .text("VIEW")],
      [.text("information_schema.columns"), .text("VIEW")],
      [.text("information_schema.tables"), .text("VIEW")],
    ])
  }

  @Test("information_schema.tables lists an engine-provided view by name")
  func builtinViewListed() throws {
    // The built-in views are queryable through `resolve(view:)`, so a consumer
    // discovers them by name — `... WHERE table_name = 'information_schema.
    // columns'` finds the VIEW even though it is engine-provided, not a
    // registered user view.
    let rows = try run("""
        SELECT table_type FROM information_schema.tables
         WHERE table_name = 'information_schema.columns'
        """)
    #expect(rows == [[.text("VIEW")]])
  }

  @Test("information_schema.columns lists an engine-provided view's columns")
  func builtinViewColumns() throws {
    // A built-in view's columns are typed from its body — over the store, all
    // text — exactly as a user view's are.
    let rows = try run("""
        SELECT column_name, data_type FROM information_schema.columns
         WHERE table_name = 'information_schema.tables'
         ORDER BY ordinal_position
        """)
    #expect(rows == [
      [.text("table_catalog"), .text("character varying")],
      [.text("table_schema"), .text("character varying")],
      [.text("table_name"), .text("character varying")],
      [.text("table_type"), .text("character varying")],
    ])
  }

  @Test("a base relation shadows a same-named built-in information_schema view")
  func baseShadowsBuiltinView() throws {
    // A base relation named for a built-in view shadows it (`resolve(view:)`
    // yields the base), so the built-in is not listed as a VIEW — the base is
    // listed as a BASE TABLE. (The name now resolves to the base, so the store
    // relation is read directly to observe the metadata.)
    let cat = MetaCatalog([
      "information_schema.tables": MetaRelation([("x", .integer)], []),
    ])
    let rows = try cat.run(parse("""
        SELECT table_type FROM definition_schema.tables
         WHERE table_name = 'information_schema.tables'
        """))
    #expect(rows == [[.text("BASE TABLE")]])
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
          WHERE table_type = 'BASE TABLE' ORDER BY table_name
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
        Routines().registering("tag", returns: .text, parameters: [.text]) {
          _ in .text("x")
        }
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
        Routines().registering("tag", returns: .text, parameters: [.text]) {
          _ in .text("x")
        }
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
        Routines().registering("tag", returns: .text, parameters: [.text]) {
          _ in .text("x")
        }
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

  @Test("columns(of:) faults on arithmetic over a non-numeric operand")
  func nonnumericArithmetic() throws {
    // `Name + 1` has no arithmetic — `Arithmetic.apply` faults on the first
    // non-NULL text row, so the schema faults rather than typing `.integer`.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("SELECT Name + 1 AS x FROM People"))
    }
  }

  @Test("columns(of:) faults on SUM or AVG over a non-numeric operand")
  func nonnumericAggregate() throws {
    // `SUM`/`AVG` fold numerically — `Aggregate.fold` faults on non-numeric —
    // so `SUM(Name)`/`AVG(Name)` fault rather than typing text/double.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("SELECT SUM(Name) FROM People"))
    }
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("SELECT AVG(Name) FROM People"))
    }
  }

  @Test("columns(of:) types numeric aggregates and arithmetic")
  func numericAggregateTyping() throws {
    let cat = MetaCatalog(["T": MetaRelation(
        [("Name", .text), ("Age", .integer), ("Score", .double)], [])])
    #expect(try cat.columns(of: parse("SELECT SUM(Age) AS x FROM T"))
                == [OutputColumn(name: "x", type: .integer)])
    #expect(try cat.columns(of: parse("SELECT SUM(Score) AS x FROM T"))
                == [OutputColumn(name: "x", type: .double)])
    #expect(try cat.columns(of: parse("SELECT AVG(Age) AS x FROM T"))
                == [OutputColumn(name: "x", type: .double)])
    #expect(try cat.columns(of: parse("SELECT Age + 1 AS x FROM T"))
                == [OutputColumn(name: "x", type: .integer)])
    #expect(try cat.columns(of: parse("SELECT Age + Score AS x FROM T"))
                == [OutputColumn(name: "x", type: .double)])
    // MIN/MAX compare rather than fold, so they keep the operand's own type —
    // even a non-numeric one.
    #expect(try cat.columns(of: parse("SELECT MIN(Name) AS x FROM T"))
                == [OutputColumn(name: "x", type: .text)])
  }

  @Test("columns(of:) faults on a bad operand in a later UNION arm")
  func nonnumericLaterArm() throws {
    // The first arm types fine; the later arm's `Name + 1` faults, as a run of
    // the union would — the first-arm schema walk never visits it.
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Age FROM People UNION SELECT Name + 1 FROM People
          """))
    }
  }

  @Test("columns(of:) faults on a bad aggregate operand in a HAVING")
  func nonnumericHaving() throws {
    // `SUM(Name)` in the HAVING is not projected, so the projection walk misses
    // it; the whole-query type-check faults it, as a run would.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Name FROM People GROUP BY Name HAVING SUM(Name) > 0
          """))
    }
  }

  @Test("columns(of:) faults on a bad operand in a WHERE")
  func nonnumericWhere() throws {
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Age FROM People WHERE Name + 1 = 2
          """))
    }
  }

  @Test("columns(of:) types a valid later arm and HAVING")
  func validLaterArmAndHaving() throws {
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Age FROM People UNION SELECT Age + 1 FROM People
        """)) == [OutputColumn(name: "Age", type: .integer)])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People GROUP BY Name HAVING SUM(Age) > 0
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("information_schema.columns hides a view with a bad HAVING operand")
  func nonnumericHavingView() throws {
    // The view's HAVING folds `SUM(Name)` over text — a run faults — so the
    // view is not advertised, though its projection types cleanly.
    let body = try parse("""
        SELECT Name FROM People GROUP BY Name HAVING SUM(Name) > 0
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

  @Test("columns(of:) skips an arm a constant-false AND short-circuits")
  func shortCircuitAnd() throws {
    // `1 = 0` is constantly false, so the executor never evaluates `Name + 1`;
    // the schema resolves rather than faulting on the unreachable arm.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE 1 = 0 AND Name + 1 = 2
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("columns(of:) skips an arm a constant-true OR short-circuits")
  func shortCircuitOr() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE 1 = 1 OR Name + 1 = 2
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("columns(of:) still faults on a reachable bad arm")
  func reachableBadArm() throws {
    // A constant-TRUE AND does not short-circuit its right arm, and a
    // non-constant guard leaves the arm reachable — both still fault.
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Name FROM People WHERE 1 = 1 AND Name + 1 = 2
          """))
    }
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Name FROM People WHERE Age = 0 AND Name + 1 = 2
          """))
    }
  }

  @Test("information_schema.columns lists a view with a short-circuited arm")
  func shortCircuitView() throws {
    let body = try parse("""
        SELECT Name FROM People WHERE 1 = 0 AND Name + 1 = 2
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [[.text("Name")]])
  }

  @Test("columns(of:) skips an unknown call a false AND short-circuits")
  func shortCircuitUnknownCall() throws {
    // `NOPE` is only in the unreachable arm of `1 = 0 AND …`, so the executor
    // never evaluates it and the query runs — the schema resolves, and call
    // validation rides the same short-circuit-aware walk as operand checking.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE 1 = 0 AND NOPE(Name) = 1
        """)) == [OutputColumn(name: "Name", type: .text)])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE 1 = 1 OR NOPE(Name) = 1
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("columns(of:) still faults on a reachable unknown call")
  func reachableUnknownCall() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Name FROM People WHERE 1 = 1 AND NOPE(Name) = 1
          """))
    }
  }

  @Test("information_schema.columns lists a view with an unreachable call")
  func shortCircuitUnknownCallView() throws {
    let body = try parse("""
        SELECT Name FROM People WHERE 1 = 0 AND NOPE(Name) = 1
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["Name"])])
    let rows = try cat.run(parse("""
        SELECT column_name FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [[.text("Name")]])
  }

  @Test("columns(of:) derives a schema for a zero-row-limit projection")
  func zeroRowLimitProjection() throws {
    // `FETCH FIRST 0 ROWS ONLY` yields no rows and the limit applies before the
    // projection, so `Name + 1` is never evaluated; the schema DERIVES its
    // nominal type without faulting on the non-numeric operand.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name + 1 AS x FROM People FETCH FIRST 0 ROWS ONLY
        """)) == [OutputColumn(name: "x", type: .integer)])
  }

  @Test("columns(of:) still faults on a projection under a non-zero limit")
  func nonzeroLimitProjection() throws {
    // A non-zero limit projects rows, so the operand is reachable and faults.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Name + 1 AS x FROM People FETCH FIRST 2 ROWS ONLY
          """))
    }
  }

  @Test("information_schema.columns lists a zero-row-limit view")
  func zeroRowLimitView() throws {
    let body = try parse("""
        SELECT Name + 1 AS x FROM People FETCH FIRST 0 ROWS ONLY
        """)
    let cat = MetaCatalog(
        ["People": MetaRelation([("Name", .text)], [])],
        views: ["v": View(query: body, columns: ["x"])])
    let rows = try cat.run(parse("""
        SELECT column_name, data_type FROM information_schema.columns
         WHERE table_name = 'v'
        """))
    #expect(rows == [[.text("x"), .text("integer")]])
  }

  @Test("columns(of:) validates an aggregate fold under a zero-row limit")
  func aggregateUnderZeroLimit() throws {
    // A `FETCH FIRST 0 ROWS ONLY` skips a non-aggregate projection, but an
    // aggregate folds every row before the limit, so `SUM(Name)` over text
    // still faults; a numeric fold types cleanly.
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT SUM(Name) FROM People FETCH FIRST 0 ROWS ONLY
          """))
    }
    #expect(try cat.columns(of: parse("""
        SELECT SUM(Age) AS x FROM People FETCH FIRST 0 ROWS ONLY
        """)) == [OutputColumn(name: "x", type: .integer)])
  }

  @Test("columns(of:) folds a literal IS NULL test in a short-circuit")
  func shortCircuitNullTest() throws {
    // `1 IS NULL` is constantly false and `1 IS NOT NULL` constantly true, so
    // the executor skips the guarded arm; the schema resolves rather than
    // faulting on the unreachable operand or call.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE 1 IS NULL AND Name + 1 = 2
        """)) == [OutputColumn(name: "Name", type: .text)])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE 1 IS NOT NULL OR NOPE(Name) = 1
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("columns(of:) skips the work after a constant-false WHERE")
  func constantFalseWhere() throws {
    // `WHERE 1 = 0` filters every row before projecting, so `Name + 1` is
    // unreachable and the schema resolves.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name + 1 AS x FROM People WHERE 1 = 0
        """)) == [OutputColumn(name: "x", type: .integer)])
    // An aggregate folds zero rows, so its text operand is never evaluated.
    let summed = try cat.columns(of: parse("""
        SELECT SUM(Name) AS s FROM People WHERE 1 = 0
        """))
    #expect(summed.count == 1)
    // But a whole-result aggregate still emits ONE empty group, so a scalar
    // call projecting it runs — an unregistered routine faults, as a run does.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT NOPE(COUNT(*)) AS x FROM People WHERE 1 = 0
          """))
    }
  }

  @Test("columns(of:) refines empty-group reachability")
  func emptyGroupReachability() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    // A false HAVING drops the empty group before the projection, so its call
    // is unreachable — the query returns an empty result and types cleanly.
    #expect(try cat.columns(of: parse("""
        SELECT NOPE(COUNT(*)) AS x FROM People WHERE 1 = 0 HAVING 1 = 0
        """)) == [OutputColumn(name: "x", type: .integer)])
    // A true HAVING keeps the empty group, so the projection's call runs.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT NOPE(COUNT(*)) AS x FROM People WHERE 1 = 0 HAVING 1 = 1
          """))
    }
    // COUNT is 0 over the empty group, so COUNT(*) / 0 is a real divide.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT COUNT(*) / 0 AS x FROM People WHERE 1 = 0
          """))
    }
    // Every other aggregate is NULL, so SUM(Age) / 0 propagates NULL, no fault.
    #expect(try cat.columns(of: parse("""
        SELECT SUM(Age) / 0 AS x FROM People WHERE 1 = 0
        """)) == [OutputColumn(name: "x", type: .integer)])
    // A literal fault in the projection beside an aggregate still runs.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT COUNT(*) AS c, 1 / 0 AS x FROM People WHERE 1 = 0
          """))
    }
    // A registered routine runs over the empty group, so a wrong-arity call
    // (BITAND takes two) faults as the run would.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT BITAND(COUNT(*)) AS x FROM People WHERE 1 = 0
          """))
    }
    // A HAVING false over the empty group (COUNT is 0) drops it, so a faulting
    // projection is never reached — the query returns no rows, types cleanly.
    #expect(try cat.columns(of: parse("""
        SELECT 1 / 0 AS x FROM People WHERE 1 = 0 HAVING COUNT(*) = 1
        """)).count == 1)
    // A HAVING true over the empty group keeps it, so the projection runs.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT 1 / 0 AS x FROM People WHERE 1 = 0 HAVING COUNT(*) = 0
          """))
    }
  }

  @Test("columns(of:) skips an unbound HAVING parameter over the empty group")
  func emptyGroupUnboundParameter() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    // With no binding, `... = :p` yields UNKNOWN without evaluating the left,
    // so the divide never runs — the query returns no rows and types cleanly.
    #expect(try cat.columns(of: parse("""
        SELECT COUNT(*) AS c FROM People WHERE 1 = 0 HAVING COUNT(*) / 0 = :p
        """)).count == 1)
  }

  @Test("columns(of:) rejects a non-finite routine result over the empty group")
  func emptyGroupNonfiniteRoutine() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    let routines: Routines =
        ["BAD": Routine(returns: .double, parameters: []) { _ in
          .double(.infinity)
        }]
    // The empty group projects BAD(), a non-finite double the run rejects
    // (SQLError.magnitude), so the schema must reject it too.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT BAD() AS x FROM People WHERE 1 = 0 HAVING 1 = 1
          """), routines: routines)
    }
  }

  @Test("columns(of:) validates a COUNT expression operand")
  func countOperand() throws {
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    // COUNT evaluates its operand per row to test non-NULL, so a bad operand
    // (or an unknown call) faults; a valid operand counts as integer.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("SELECT COUNT(Name + 1) FROM People"))
    }
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("SELECT COUNT(NOPE(Name)) FROM People"))
    }
    #expect(try cat.columns(of: parse("SELECT COUNT(Age) AS c FROM People"))
                == [OutputColumn(name: "c", type: .integer)])
  }

  @Test("columns(of:) skips the projection after a constant-false HAVING")
  func constantFalseHaving() throws {
    // `HAVING 1 = 0` filters every group before the projection, so `Name + 1`
    // is unreachable and the schema resolves — but an aggregate fold, which the
    // group node runs before HAVING, is still validated.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name + 1 AS x FROM People GROUP BY Name HAVING 1 = 0
        """)) == [OutputColumn(name: "x", type: .integer)])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT SUM(Name) FROM People GROUP BY Name HAVING 1 = 0
          """))
    }
  }

  @Test("columns(of:) validates a HAVING aggregate despite a short-circuit")
  func havingAggregateShortCircuit() throws {
    // `HAVING 1 = 0 AND SUM(Name) > 0` short-circuits the comparison, but the
    // group node folds `SUM(Name)` before the HAVING filter, so it faults;
    // a numeric fold in the skipped arm is fine.
    let cat = MetaCatalog(["People":
        MetaRelation([("Name", .text), ("Age", .integer)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT Name FROM People GROUP BY Name HAVING 1 = 0 AND SUM(Name) > 0
          """))
    }
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People GROUP BY Name HAVING 1 = 0 AND SUM(Age) > 0
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("columns(of:) rejects a statically-known division by zero")
  func divideByZeroLiteral() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    #expect(throws: SQLError.divide) {
      let _ = try cat.columns(of: parse("SELECT 1 / 0 AS x FROM People"))
    }
    // A non-literal divisor is data-dependent, so it is not rejected.
    #expect(try cat.columns(of: parse("SELECT 1 / Age AS x FROM People"))
                == [OutputColumn(name: "x", type: .integer)])
  }

  @Test("columns(of:) rejects statically-overflowing literal arithmetic")
  func overflowLiteral() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    // Both operands literal, so the result overflows on every row (a FROM-less
    // SELECT at once); the schema rejects it rather than advertise a column.
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of:
          parse("SELECT 9223372036854775807 + 1 AS x FROM People"))
    }
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of:
          parse("SELECT 1e308 * 1e308 AS x FROM People"))
    }
    // A non-literal operand is data-dependent, so it is not rejected.
    #expect(try cat.columns(of: parse("SELECT Age + 1 AS x FROM People"))
                == [OutputColumn(name: "x", type: .integer)])
  }

  @Test("columns(of:) accepts a parameterized predicate with no binding")
  func unboundParameter() throws {
    // With no binding (the schema default), `Name + 1 = :p` yields UNKNOWN
    // without evaluating the left term, so the query runs (no rows) and the
    // schema resolves rather than faulting on the text arithmetic.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT Name FROM People WHERE Name + 1 = :p
        """)) == [OutputColumn(name: "Name", type: .text)])
  }

  @Test("columns(of:) faults on a bad operand inside a call's arguments")
  func nonnumericCallArgument() throws {
    // `BITAND(Name + 1, 1)` returns integer, but its argument `Name + 1`
    // faults; typing recurses into the arguments, as a run would.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT BITAND(Name + 1, 1) FROM People
          """))
    }
  }

  @Test("columns(of:) types a call over valid arguments")
  func callArgumentTyping() throws {
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    #expect(try cat.columns(of: parse("""
        SELECT BITAND(Age, 1) AS b FROM People
        """)) == [OutputColumn(name: "b", type: .integer)])
  }

  @Test("columns(of:) faults on a call over a wrong-kind argument")
  func callArgumentKind() throws {
    // `BITAND` declares an `[.integer, .integer]` contract, so
    // `BITAND(Name, 1)` over the text `Name` faults as a run would (`BITAND`
    // throws `SQLError.argument` on a non-integer non-NULL value); the schema
    // must reject it rather than advertise an integer column no row produces.
    let cat = MetaCatalog(["People": MetaRelation([("Name", .text)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT BITAND(Name, 1) AS x FROM People
          """))
    }
  }

  @Test("columns(of:) faults on a call over the wrong arity")
  func callArgumentArity() throws {
    // `BITAND` takes two arguments, so `BITAND(Age)` faults `SQLError.argument`
    // at run; the static type-check enforces the declared arity, so the schema
    // rejects it rather than typing an integer column.
    let cat = MetaCatalog(["People": MetaRelation([("Age", .integer)], [])])
    #expect(throws: SQLError.self) {
      let _ = try cat.columns(of: parse("""
          SELECT BITAND(Age) AS x FROM People
          """))
    }
  }

  @Test("a recursive CTE over the store types a view's standard call")
  func recursiveStoreRoutineReturns() throws {
    // A view column that is a standard scalar call must appear in
    // definition_schema.columns even when a recursive CTE names the store
    // directly — the cached CTE store entry is seeded with the routine returns,
    // so `BITAND(...)` types inside the CTE as it does outside it.
    let body = try parse("SELECT BITAND(Age, 1) AS b FROM People")
    let cat = MetaCatalog(
        ["People": MetaRelation([("Age", .integer)], [])],
        views: ["v": View(query: body, columns: ["b"])])
    let rows = try cat.run(Statement(parsing: """
        WITH RECURSIVE r AS (
          SELECT column_name FROM definition_schema.columns
           WHERE table_name = 'v'
          UNION SELECT column_name FROM r WHERE 1 = 0
        )
        SELECT column_name FROM r
        """))
    #expect(rows == [[.text("b")]])
  }

  @Test("a base relation shadowed by the definition_schema store is hidden")
  func storeShadowsBase() throws {
    // The store overlay resolves `definition_schema.tables`, so a catalog base
    // relation of that name is unreachable; it must not be advertised as a BASE
    // TABLE, or metadata would disagree with resolution for the reserved name.
    let cat = MetaCatalog([
      "People": MetaRelation([("Name", .text)], []),
      "definition_schema.tables": MetaRelation([("x", .integer)], []),
    ])
    let rows = try cat.run(parse("""
        SELECT table_name FROM information_schema.tables ORDER BY table_name
        """))
    // `People` and the two built-in views — but NOT the shadowed reserved base.
    #expect(rows == [
      [.text("People")],
      [.text("information_schema.columns")],
      [.text("information_schema.tables")],
    ])
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
      [.text("information_schema.columns"), .text("VIEW")],
      [.text("information_schema.tables"), .text("VIEW")],
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

  @Test("a view over definition_schema.tables yields the inline rows")
  func viewOverStoreTables() throws {
    // A view whose body names the STORE relation directly — not an
    // `information_schema.` view over it — resolves and runs the same as the
    // inline query: the store overlay reaches the view body's compile and
    // execution (`resolve`/`derive`), not only the top-level query.
    let body = try parse("""
        SELECT table_name FROM definition_schema.tables
          WHERE table_type = 'BASE TABLE' ORDER BY table_name
        """)
    let source = MetaCatalog([
      "People": MetaRelation([("Name", .text), ("Age", .integer)]),
      "Widget": MetaRelation([("Label", .text)]),
    ], views: ["meta": View(query: body, columns: ["table_name"])])
    let inline = try source.run(body)
    let viewed = try source.run(parse("""
        SELECT table_name FROM meta ORDER BY table_name
        """))
    #expect(viewed == inline)
    #expect(viewed == [[.text("People")], [.text("Widget")]])
  }

  @Test("a view over definition_schema.columns yields the inline rows")
  func viewOverStoreColumns() throws {
    let body = try parse("""
        SELECT column_name, data_type FROM definition_schema.columns
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
}
