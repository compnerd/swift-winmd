// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// Execution over a small in-memory fixture catalog — the built query, handed to
// `run(against:routines:)`, yields the rows the equivalent SQL would. It proves
// the AST-direct lowering runs end to end, not just that it equals the parser's
// tree.

/// An `Employees` relation and a `Departments` relation, a two-table fixture
/// for the where/select, join, order, and group/aggregate chains.
private func company() throws -> FixtureCatalog {
  try Catalog {
    Relation("Employees",
             ["Name": .text, "Dept": .integer, "Salary": .integer]) {
      Row("Alice", 1, 100)
      Row("Bob", 1, 90)
      Row("Carol", 2, 120)
      Row("Dave", 2, 80)
    }
    Relation("Departments", ["Id": .integer, "Name": .text]) {
      Row(1, "Engineering")
      Row(2, "Sales")
    }
  }
}

struct ExecutionTests {
  @Test func `where and select project the filtered rows`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select("Name")
        .where(column("Salary") >= 100)
        .order(by: "Name")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.text("Alice")], [.text("Carol")]])
  }

  @Test func `an equi-join pairs the two relations`() throws {
    let catalog = try company()
    let rows = try from("Employees", as: "e")
        .select(column("e.Name").as("Emp"), column("d.Name").as("Dept"))
        .join("Departments", as: "d", on: column("e.Dept") == column("d.Id"))
        .where(column("e.Name") == "Alice")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.text("Alice"), .text("Engineering")]])
  }

  @Test func `order(by:) descending sorts the result`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select("Name")
        .order(by: desc("Salary"))
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.text("Carol")], [.text("Alice")], [.text("Bob")],
                     [.text("Dave")]])
  }

  @Test func `group(by:) with an aggregate folds each group`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select(column("Dept").as("Dept"), sum(column("Salary")).as("Total"))
        .group(by: "Dept")
        .order(by: "Dept")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1), .integer(190)],
                     [.integer(2), .integer(200)]])
  }

  @Test func `having filters the grouped rows`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select(column("Dept").as("Dept"), count().as("N"))
        .group(by: "Dept")
        .having(sum(column("Salary")) > 195)
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(2), .integer(2)]])
  }

  @Test func `distinct deduplicates the projected rows`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select("Dept")
        .distinct()
        .order(by: "Dept")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }

  @Test func `limit and offset page the ordered result`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select("Name")
        .order(by: "Name")
        .offset(1)
        .limit(2)
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.text("Bob")], [.text("Carol")]])
  }

  @Test func `union combines two queries`() throws {
    let catalog = try company()
    let rows = try from("Employees").select("Dept")
        .union(from("Departments").select("Id"))
        .run(against: catalog, routines: .standard)
    #expect(Set(rows) == [[.integer(1)], [.integer(2)]])
  }

  @Test func `columns(against:) reports the projected schema`() throws {
    let catalog = try company()
    let columns = try from("Employees")
        .select("Name", "Salary")
        .columns(against: catalog, routines: .standard)
    #expect(columns.map(\.name) == ["Name", "Salary"])
    #expect(columns.map(\.type) == [.text, .integer])
  }

  @Test func `first returns the first result row`() throws {
    let catalog = try company()
    let row = try from("Employees")
        .select("Name")
        .order(by: "Name")
        .first(against: catalog, routines: .standard)
    #expect(row == [.text("Alice")])
  }

  @Test func `first returns nil over an empty result`() throws {
    let catalog = try company()
    let row = try from("Employees")
        .select("Name")
        .where(column("Salary") > 1000)
        .first(against: catalog, routines: .standard)
    #expect(row == nil)
  }

  @Test func `single returns the sole row of a one-row query`() throws {
    let catalog = try company()
    let row = try from("Employees")
        .select("Name")
        .where(column("Name") == "Carol")
        .single(against: catalog, routines: .standard)
    #expect(row == [.text("Carol")])
  }

  @Test func `single returns nil over an empty result`() throws {
    let catalog = try company()
    let row = try from("Employees")
        .select("Name")
        .where(column("Salary") > 1000)
        .single(against: catalog, routines: .standard)
    #expect(row == nil)
  }

  @Test func `single throws cardinality for a multi-row query`() throws {
    let catalog = try company()
    #expect(throws: SQLError.cardinality) {
      try from("Employees")
          .select("Name")
          .where(column("Dept") == 1)
          .single(against: catalog, routines: .standard)
    }
  }

  @Test func `any is true for a non-empty query`() throws {
    let catalog = try company()
    let present = try from("Employees")
        .select("Name")
        .where(column("Name") == "Alice")
        .any(against: catalog, routines: .standard)
    #expect(present == true)
  }

  @Test func `any is false for an empty query`() throws {
    let catalog = try company()
    let present = try from("Employees")
        .select("Name")
        .where(column("Salary") > 1000)
        .any(against: catalog, routines: .standard)
    #expect(present == false)
  }

  @Test func `where then any tests a predicate`() throws {
    let catalog = try company()
    let hasHighEarner = try from("Employees")
        .where(column("Salary") >= 120)
        .any(against: catalog, routines: .standard)
    let hasMillionaire = try from("Employees")
        .where(column("Salary") >= 1000000)
        .any(against: catalog, routines: .standard)
    #expect(hasHighEarner == true)
    #expect(hasMillionaire == false)
  }
}
