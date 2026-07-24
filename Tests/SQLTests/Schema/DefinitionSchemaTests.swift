// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// MARK: - Tests

@Suite struct DefinitionSchemaTests {
  @Test func `definition_schema.columns lists a base relation's columns`() throws {
    let catalog = try Catalog {
      Relation("People", ["Name": .text, "Age": .integer])
    }
    try catalog.expect("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'People'
        """, yields: [["Name"], ["Age"]])
  }

  @Test func `definition_schema.columns skips a cyclic view and stays usable`() throws {
    // `A` reads `B` and `B` reads `A` — a cycle. The store's `columns` builder
    // compiles each view to advertise it, which for a cyclic view would recurse
    // resolve→compile→resolve until the stack overflows (SIGBUS, not an
    // `SQLError`). The cycle guard threaded through `compile`/`resolve` faults
    // `.recursion` instead, which the builder's `try? compile` catches so it
    // skips the cyclic view. The store must not hang or crash, and an unrelated
    // base relation still reports.
    let a = try parse(query: "SELECT * FROM B")
    let b = try parse(query: "SELECT * FROM A")
    let catalog = FixtureCatalog(
        ["People": FixtureRelation([FixtureField(name: "Name", type: .text)],
                                   [])],
        views: ["A": View(query: a, columns: ["x"]),
                "B": View(query: b, columns: ["y"])])
    try catalog.expect("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'People'
        """, yields: [["Name"]])
    try catalog.empty("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'A' OR table_name = 'B'
        """)
  }

  @Test func `definition_schema.tables lists a cyclic view without crashing`() throws {
    // `definition_schema.tables` enumerates relations and views by NAME without
    // compiling their bodies, so it lists the cyclic view too — the point is it
    // does not hang or crash reaching it. Assert the catalog's own names all
    // appear (a superset check, so a later slice adding engine-provided rows
    // does not break this).
    let a = try parse(query: "SELECT * FROM B")
    let b = try parse(query: "SELECT * FROM A")
    let catalog = FixtureCatalog(
        ["People": FixtureRelation([FixtureField(name: "Name", type: .text)],
                                   [])],
        views: ["A": View(query: a, columns: ["x"]),
                "B": View(query: b, columns: ["y"])])
    let names = try catalog.run(parse(query: """
        SELECT table_name FROM definition_schema.tables
        """))
    #expect(names.contains([.text("People")]))
    #expect(names.contains([.text("A")]))
    #expect(names.contains([.text("B")]))
  }

  @Test func `definition_schema.columns skips a faulting grouping-sets view`()
      throws {
    // The metadata builder EXPANDS a `GROUPING SETS` view body before
    // type-checking, as the schema path does. Unexpanded, the constant-false
    // `WHERE` reads as skipping the `1 / 0` projection; expanded, the `()` arm
    // forms one group (a grand total) and evaluates it, faulting. The store
    // must NOT advertise a view that selecting from would fault.
    let bad = try parse(query: """
        SELECT 1 / 0 AS x FROM Sales
         WHERE 1 = 0 GROUP BY GROUPING SETS ((Region), ())
        """)
    let catalog = FixtureCatalog(
        ["Sales": FixtureRelation([FixtureField(name: "Region", type: .text)],
                                  [])],
        views: ["v": View(query: bad, columns: ["x"])])
    try catalog.empty("""
        SELECT column_name FROM definition_schema.columns
         WHERE table_name = 'v'
        """)
  }
}
