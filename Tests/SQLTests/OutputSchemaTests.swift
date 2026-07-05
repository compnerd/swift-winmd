// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - In-memory adapter

/// A typed in-memory relation — a column name/kind list and rows — for the
/// result-schema tests. `columns(of:)` never reads a row, so the rows are only
/// present to prove it does not (a fixture with rows must resolve exactly as
/// one with none).
private struct SchemaRelation: Sendable {
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

/// A `Catalog` over named typed relations, with optional views.
private struct SchemaCatalog: Catalog {
  let catalog: Dictionary<String, SchemaRelation>
  let registered: Dictionary<String, View>

  init(_ catalog: Dictionary<String, SchemaRelation>,
       views: Dictionary<String, View> = [:]) {
    self.catalog = catalog
    self.registered = views
  }

  func table(named name: String) -> SchemaTable? {
    guard let relation = catalog[name] else { return nil }
    return SchemaTable(relation)
  }

  func view(named name: String) -> View? {
    registered[name]
  }

  func relations() -> Array<String> {
    Array(catalog.keys)
  }

  func views() -> Array<String> {
    Array(registered.keys)
  }
}

/// A `Table` over one typed relation, with a lone virtual `Id`.
private struct SchemaTable: Table {
  let relation: SchemaRelation

  init(_ relation: SchemaRelation) {
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

  func cursor() -> SchemaCursor {
    SchemaCursor(relation)
  }
}

/// A cursor that TRAPS on any row read — `columns(of:)` must never open it.
private struct SchemaCursor: Cursor {
  let relation: SchemaRelation

  init(_ relation: SchemaRelation) {
    self.relation = relation
  }

  var count: Int { relation.records.count }

  func row(_ index: Int) -> SchemaRow? {
    fatalError("columns(of:) must not read a row")
  }
}

private struct SchemaRow: Row {
  subscript(_ column: Int) -> Value {
    borrowing get { .null }
  }
}

// MARK: - Fixtures

/// A `People` relation of two typed columns past its `Id`, plus a `Pet` for the
/// join cases.
private func catalog() -> SchemaCatalog {
  SchemaCatalog([
    "People": SchemaRelation([("Name", .text), ("Age", .integer)]),
    "Pet": SchemaRelation([("Species", .text), ("Legs", .integer)]),
  ])
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

/// The `(name, kind)` pairs of a query's resolved result schema.
private func schema(_ text: String) throws -> Array<(String, ValueType)> {
  let columns = try catalog().columns(of: parse(text))
  return columns.map { ($0.name, $0.type) }
}

/// Whether two `(name, kind)` lists are equal, element by element.
private func same(_ lhs: Array<(String, ValueType)>,
                  _ rhs: Array<(String, ValueType)>) -> Bool {
  lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 == $1 }
}

// MARK: - Tests

struct OutputSchemaTests {
  @Test("SELECT * names and types every real column, never a virtual")
  func star() throws {
    let columns = try schema("SELECT * FROM People")
    #expect(columns.count == 2)
    #expect(columns[0] == ("Name", .text))
    #expect(columns[1] == ("Age", .integer))
  }

  @Test("a bare-column list carries each column's name and source kind")
  func bareColumns() throws {
    let columns = try schema("SELECT Age, Name FROM People")
    #expect(columns[0] == ("Age", .integer))
    #expect(columns[1] == ("Name", .text))
  }

  @Test("an aliased expression takes its alias, typed by its expression")
  func alias() throws {
    let columns = try schema("SELECT Name AS Who, Age AS Years FROM People")
    #expect(columns[0] == ("Who", .text))
    #expect(columns[1] == ("Years", .integer))
  }

  @Test("an unnamed computed expression gets a positional name")
  func positional() throws {
    // `Age + 1` has no alias and is not a bare column, so it is `column N`
    // (1-based); an all-integer arithmetic expression is `.integer`.
    let columns = try schema("SELECT Name, Age + 1 FROM People")
    #expect(columns[0] == ("Name", .text))
    #expect(columns[1] == ("column 2", .integer))
  }

  @Test("binary arithmetic with a double operand is a double column")
  func arithmetic() throws {
    // `Age + 1` stays integer (both operands integral); `Age + 1.5` promotes to
    // a double, as the engine's arithmetic does, so the schema types it so.
    let integral = try schema("SELECT Age + 1 FROM People")
    #expect(integral[0].1 == .integer)
    let promoted = try schema("SELECT Age + 1.5 FROM People")
    #expect(promoted[0].1 == .double)
  }

  @Test("a literal projection carries the literal's kind")
  func literals() throws {
    let columns = try schema("SELECT 'x', 1, 2.5 FROM People")
    #expect(columns[0] == ("column 1", .text))
    #expect(columns[1] == ("column 2", .integer))
    #expect(columns[2] == ("column 3", .double))
  }

  @Test("a join's SELECT * concatenates both relations' columns in order")
  func joinStar() throws {
    let columns =
        try schema("SELECT * FROM People JOIN Pet ON People.Id = Pet.Id")
    #expect(columns.count == 4)
    #expect(same(columns, [("Name", .text), ("Age", .integer),
                           ("Species", .text), ("Legs", .integer)]))
  }

  @Test("a qualified column resolves its kind from the naming relation")
  func qualified() throws {
    let columns = try schema("""
        SELECT People.Name, Pet.Legs
          FROM People JOIN Pet ON People.Id = Pet.Id
        """)
    #expect(columns[0] == ("Name", .text))
    #expect(columns[1] == ("Legs", .integer))
  }

  @Test("a UNION names its result off the first arm")
  func union() throws {
    // The first arm's projection names the result (the ISO rule), so the
    // schema is the leading SELECT's regardless of the trailing arm.
    let columns =
        try schema("SELECT Name FROM People UNION SELECT Species FROM Pet")
    #expect(columns.count == 1)
    #expect(columns[0] == ("Name", .text))
  }

  @Test("a view resolves against its registered columns")
  func view() throws {
    let definition = try View(query: {
      guard case let .select(query) =
          try Statement(parsing: "SELECT Name FROM People") else {
        throw SQLError.incomplete(expected: "a SELECT")
      }
      return query
    }(), columns: ["Label"])
    let source = SchemaCatalog([
      "People": SchemaRelation([("Name", .text), ("Age", .integer)]),
    ], views: ["Named": definition])
    let query = try parse("SELECT * FROM Named")
    let columns = try source.columns(of: query)
    // A view's columns are its registered names; its kinds are resolved from
    // the view body, so `Label` (over the `.text` `Name`) reports `.text`
    // rather than the view schema's `.integer` default.
    #expect(columns.count == 1)
    #expect(columns[0] == OutputColumn(name: "Label", type: .text))
  }

  @Test("an unknown relation faults exactly as compilation would")
  func unknownRelation() throws {
    #expect(throws: SQLError.self) {
      let _ = try catalog().columns(of: parse("SELECT * FROM Absent"))
    }
  }

  @Test("an unknown column faults exactly as compilation would")
  func unknownColumn() throws {
    #expect(throws: SQLError.self) {
      let _ =
          try catalog().columns(of: parse("SELECT Absent FROM People"))
    }
  }

  @Test("columns(of:) never opens a cursor")
  func resolveOnly() throws {
    // The fixture's cursor traps on any row read, so a passing resolve proves
    // `columns(of:)` reads only schemas.
    let columns = try schema("SELECT Name, Age FROM People WHERE Age > 0")
    #expect(columns.count == 2)
  }

  @Test("a WHERE naming a missing column faults, though the first arm resolves")
  func invalidPredicate() throws {
    // The projection names a real column, so a first-arm-only walk would return
    // a schema; the whole-query validation resolves the WHERE too and faults as
    // a run would.
    let query = try parse("SELECT Name FROM People WHERE Missing = 1")
    let resolve = { () throws -> Array<OutputColumn> in
      try catalog().columns(of: query)
    }
    #expect(throws: SQLError.self) { try resolve() }
  }

  @Test("a UNION whose arms mismatch arity faults, though the first resolves")
  func invalidUnionArity() throws {
    // The first arm projects one column and the second two — a run would fault
    // with `SQLError.arity`, so the schema resolution must too rather than name
    // the result off the first arm.
    let query = try parse("""
        SELECT Name FROM People UNION SELECT Species, Legs FROM Pet
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try catalog().columns(of: query)
    }
    #expect(throws: SQLError.self) { try resolve() }
  }

  @Test("a valid multi-column UNION names its result off the first arm")
  func validUnion() throws {
    // Both arms project two columns, so the query validates; the result names
    // come from the leading SELECT (the ISO rule).
    let columns = try schema("""
        SELECT Name, Age FROM People UNION SELECT Species, Legs FROM Pet
        """)
    #expect(columns.count == 2)
    #expect(same(columns, [("Name", .text), ("Age", .integer)]))
  }

  @Test("AVG is typed double and COUNT integer")
  func aggregateNumeric() throws {
    // The engine always yields a non-NULL AVG as a double and a COUNT as an
    // integer, so the result schema types them so rather than as the scalar
    // default.
    let columns = try schema("SELECT AVG(Age), COUNT(*) FROM People")
    #expect(columns[0].1 == .double)
    #expect(columns[1].1 == .integer)
  }

  @Test("SUM and MIN take the aggregated argument's kind")
  func aggregateArgument() throws {
    // SUM/MIN/MAX carry the kind of what they aggregate — an integer column's
    // SUM is an integer, a text column's MIN text.
    let columns =
        try schema("SELECT SUM(Age), MIN(Age), MIN(Name) FROM People")
    #expect(columns[0].1 == .integer)
    #expect(columns[1].1 == .integer)
    #expect(columns[2].1 == .text)
  }

  @Test("a zero FETCH over a whole-result aggregate spares its projection")
  func aggregateZeroFetch() throws {
    // A whole-result aggregate (aggregates, no GROUP BY) emits one row, which a
    // FETCH FIRST 0 ROWS ONLY drops — so its projection is unreachable and its
    // literal divide-by-zero never faults. Without the limit the same
    // projection is reachable and faults, so the schema resolution must too.
    #expect(throws: SQLError.self) {
      try schema("SELECT 1 / 0, COUNT(*) FROM People")
    }
    let normal = try schema(
        "SELECT 1 / 0, COUNT(*) FROM People FETCH FIRST 0 ROWS ONLY")
    #expect(normal.count == 2)
    // A constant-false WHERE leaves the same lone empty group, which the zero
    // FETCH likewise drops — so the empty-group evaluation is spared too.
    let empty = try schema(
        "SELECT 1 / 0, COUNT(*) FROM People WHERE 1 = 0 "
            + "FETCH FIRST 0 ROWS ONLY")
    #expect(empty.count == 2)
  }

  @Test("a positive OFFSET over a whole-result aggregate spares its projection")
  func aggregatePositiveOffset() throws {
    // A whole-result aggregate emits exactly ONE row, so an OFFSET of 1 skips
    // it — the projection is unreachable and its divide-by-zero never faults,
    // just as a zero FETCH spares it.
    let normal = try schema(
        "SELECT 1 / 0, COUNT(*) FROM People OFFSET 1 ROWS")
    #expect(normal.count == 2)
    // The constant-false WHERE's lone empty group is the sole row the OFFSET
    // skips, so the empty-group evaluation is spared too.
    let empty = try schema(
        "SELECT 1 / 0, COUNT(*) FROM People WHERE 1 = 0 OFFSET 1 ROWS")
    #expect(empty.count == 2)
  }

  @Test("a zero FETCH does not spare a SELECT DISTINCT projection")
  func distinctZeroFetch() throws {
    // A DISTINCT plan is `Limit(Distinct(Project(…)))`: the projection
    // evaluates over every candidate row to dedup it BEFORE the cap pages the
    // result, so a zero FETCH does NOT make it unreachable. The schema must
    // fault its divide-by-zero exactly as a run would — unlike the non-distinct
    // form, whose `Project(Limit(…))` shape the zero FETCH still spares.
    #expect(throws: SQLError.self) {
      try schema("SELECT DISTINCT 1 / 0 FROM People FETCH FIRST 0 ROWS ONLY")
    }
    let normal = try schema(
        "SELECT 1 / 0 FROM People FETCH FIRST 0 ROWS ONLY")
    #expect(normal.count == 1)
  }

  @Test("a positive OFFSET does not spare a SELECT DISTINCT projection")
  func distinctPositiveOffset() throws {
    // The OFFSET pages the deduplicated result, so the projection still
    // evaluates over every candidate row and its divide-by-zero faults.
    #expect(throws: SQLError.self) {
      try schema("SELECT DISTINCT 1 / 0 FROM People OFFSET 1 ROWS")
    }
  }

  @Test("a zero FETCH does not spare a grouped DISTINCT projection")
  func groupedDistinctZeroFetch() throws {
    // A grouped DISTINCT dedups the projected group rows before the cap, so the
    // projection is reachable and its divide-by-zero faults under a zero FETCH.
    #expect(throws: SQLError.self) {
      try schema("SELECT DISTINCT 1 / 0 FROM People GROUP BY Name "
          + "FETCH FIRST 0 ROWS ONLY")
    }
  }

  @Test("a constant-false WHERE still spares a SELECT DISTINCT projection")
  func distinctFalseWhere() throws {
    // A statically-false WHERE yields no rows, so a DISTINCT query has nothing
    // to dedup and the projection is genuinely unreached — the WHERE-based
    // elision stays, unlike the limit-based one.
    let columns = try schema("SELECT DISTINCT 1 / 0 FROM People WHERE 1 = 0")
    #expect(columns.count == 1)
  }

  @Test("a zero FETCH does not spare a DISTINCT empty-group projection")
  func distinctEmptyGroupZeroFetch() throws {
    // A constant-false WHERE over a whole-result aggregate emits ONE empty
    // group. For a non-distinct query a zero FETCH drops that lone row, so its
    // projection is unreachable and the divide-by-zero is spared. A DISTINCT
    // query is the exception: its `Limit(Distinct(Project(…)))` plan evaluates
    // the projection over the empty group's row (to dedup) BEFORE the cap, so
    // the divide-by-zero faults exactly as a run does — the empty-group gate
    // must bypass the limit elision under DISTINCT just as the main path does.
    #expect(throws: SQLError.self) {
      try schema("SELECT DISTINCT COUNT(*) / 0 FROM People WHERE 1 = 0 "
          + "FETCH FIRST 0 ROWS ONLY")
    }
    // The non-distinct equivalent's zero FETCH drops the lone empty-group row,
    // so its projection is unreachable and the schema resolves cleanly.
    let columns = try schema(
        "SELECT COUNT(*) / 0 FROM People WHERE 1 = 0 FETCH FIRST 0 ROWS ONLY")
    #expect(columns.count == 1)
  }

  @Test("HAVING is evaluated before a zero-FETCH limit, so its faults surface")
  func havingFaultsUnderZeroLimit() throws {
    // The compiled plan applies HAVING BEFORE the OFFSET/FETCH limit, so a zero
    // FETCH spares only the PROJECTION — HAVING still evaluates over the empty
    // group. A faulting HAVING must therefore surface even under a zero FETCH.
    #expect(throws: SQLError.self) {
      try schema("SELECT COUNT(*) FROM People WHERE 1 = 0 "
          + "HAVING 1 / 0 = 0 FETCH FIRST 0 ROWS ONLY")
    }
    // A non-faulting FALSE HAVING drops the empty group cleanly (the limit would
    // drop it anyway), so the schema resolves.
    let columns = try schema("SELECT COUNT(*) FROM People WHERE 1 = 0 "
        + "HAVING COUNT(*) = 1 FETCH FIRST 0 ROWS ONLY")
    #expect(columns.count == 1)
  }
}
