// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - In-memory adapter

/// A typed in-memory relation — a column name/kind list and rows — for the
/// DEFINITION_SCHEMA store tests.
private struct StoreRelation: Sendable {
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

/// A `Catalog` over named typed relations plus registered views, the store
/// enumerates through `relations()`/`views()`.
private struct StoreCatalog: Catalog {
  let catalog: Dictionary<String, StoreRelation>
  let registered: Dictionary<String, View>

  init(_ catalog: Dictionary<String, StoreRelation>,
       views: Dictionary<String, View> = [:]) {
    self.catalog = catalog
    self.registered = views
  }

  func table(named name: String) -> StoreTable? {
    guard let relation = catalog[name] else { return nil }
    return StoreTable(relation)
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

/// A `Table` over one typed relation.
private struct StoreTable: Table {
  let relation: StoreRelation

  init(_ relation: StoreRelation) {
    self.relation = relation
  }

  var width: Int { relation.names.count }
  var names: Array<String> { relation.names }
  var types: Array<ValueType> { relation.types }

  func ordinal(of name: String) -> Int? {
    relation.names.firstIndex(of: name)
  }

  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? { nil }

  func cursor() -> StoreCursor {
    StoreCursor(relation)
  }
}

private struct StoreCursor: Cursor {
  let relation: StoreRelation

  init(_ relation: StoreRelation) {
    self.relation = relation
  }

  var count: Int { relation.records.count }

  func row(_ index: Int) -> StoreRow? {
    guard index < relation.records.count else { return nil }
    return StoreRow(relation, index)
  }
}

private struct StoreRow: Row {
  let relation: StoreRelation
  let index: Int

  init(_ relation: StoreRelation, _ index: Int) {
    self.relation = relation
    self.index = index
  }

  subscript(_ column: Int) -> Value {
    borrowing get { relation.records[index][column] }
  }
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

// MARK: - Tests

@Suite struct DefinitionSchemaTests {
  @Test("definition_schema.columns lists a base relation's columns")
  func columns() throws {
    let cat = StoreCatalog([
      "People": StoreRelation([("Name", .text), ("Age", .integer)]),
    ])
    let rows = try cat.run(parse("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'People'
        """))
    #expect(rows == [[.text("Name")], [.text("Age")]])
  }

  @Test("definition_schema.columns skips a cyclic view and stays usable")
  func cyclicViewColumns() throws {
    // `A` reads `B` and `B` reads `A` — a cycle. The store's `columns` builder
    // compiles each view to advertise it, which for a cyclic view would recurse
    // resolve→compile→resolve until the stack overflows (SIGBUS, not an
    // `SQLError`). The cycle guard threaded through `compile`/`resolve` faults
    // `.recursion` instead, which the builder's `try? compile` catches so it
    // skips the cyclic view. The store must not hang or crash, and an unrelated
    // base relation still reports.
    let a = try parse("SELECT * FROM B")
    let b = try parse("SELECT * FROM A")
    let cat = StoreCatalog(
        ["People": StoreRelation([("Name", .text)])],
        views: ["A": View(query: a, columns: ["x"]),
                "B": View(query: b, columns: ["y"])])
    let people = try cat.run(parse("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'People'
        """))
    #expect(people == [[.text("Name")]])
    let cyclic = try cat.run(parse("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'A' OR table_name = 'B'
        """))
    #expect(cyclic == [])
  }

  @Test("definition_schema.tables lists a cyclic view without crashing")
  func cyclicViewTables() throws {
    // `definition_schema.tables` enumerates relations and views by NAME without
    // compiling their bodies, so it lists the cyclic view too — the point is it
    // does not hang or crash reaching it. Assert the catalog's own names all
    // appear (a superset check, so a later slice adding engine-provided rows
    // does not break this).
    let a = try parse("SELECT * FROM B")
    let b = try parse("SELECT * FROM A")
    let cat = StoreCatalog(
        ["People": StoreRelation([("Name", .text)])],
        views: ["A": View(query: a, columns: ["x"]),
                "B": View(query: b, columns: ["y"])])
    let names = try cat.run(parse("""
        SELECT table_name FROM definition_schema.tables
        """))
    #expect(names.contains([.text("People")]))
    #expect(names.contains([.text("A")]))
    #expect(names.contains([.text("B")]))
  }
}
