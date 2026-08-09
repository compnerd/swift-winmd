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
    let earner = try from("Employees")
        .where(column("Salary") >= 120)
        .any(against: catalog, routines: .standard)
    let millionaire = try from("Employees")
        .where(column("Salary") >= 1000000)
        .any(against: catalog, routines: .standard)
    #expect(earner == true)
    #expect(millionaire == false)
  }

  @Test func `first honors a stricter existing limit`() throws {
    let catalog = try company()
    // limit(0) caps the result to no rows, so first yields nil — the probe caps
    // at the existing 0 rather than expanding it back to one row.
    let row = try from("Employees").limit(0)
        .first(against: catalog, routines: .standard)
    #expect(row == nil)
  }

  @Test func `any honors a stricter existing limit`() throws {
    let catalog = try company()
    let present = try from("Employees").limit(0)
        .any(against: catalog, routines: .standard)
    #expect(present == false)
  }

  @Test func `single does not over-report cardinality under limit(1)`()
      throws {
    let catalog = try company()
    // Dept 1 has two rows, but limit(1) caps the sequence to one, so single
    // returns it rather than fetching two and throwing cardinality.
    let row = try from("Employees").select("Name")
        .where(column("Dept") == 1).order(by: "Name").limit(1)
        .single(against: catalog, routines: .standard)
    #expect(row == [.text("Alice")])
  }

  @Test func `all tests the paged sequence not the pre-filtered rows`() throws {
    let catalog = try company()
    // Salaries descending are 120, 100, 90, 80; limit(1) yields the one row
    // [120], which satisfies Salary > 90, so all is true. Injecting the
    // negation into the WHERE would drop 120/100 before the fetch and expose
    // 90, wrongly returning false.
    let satisfied = try from("Employees")
        .order(by: desc("Salary")).limit(1)
        .all(column("Salary") > 90, against: catalog, routines: .standard)
    #expect(satisfied == true)
    // Ascending, the one-row page is [80], which violates — so all is false,
    // confirming the paged row, not a pre-filtered one, is the row tested.
    let violated = try from("Employees")
        .order(by: asc("Salary")).limit(1)
        .all(column("Salary") > 90, against: catalog, routines: .standard)
    #expect(violated == false)
  }

  @Test func `all resolves a qualifier against the query's own alias`() throws {
    let catalog = try company()
    // The predicate names the source alias `e`. An unshaped all keeps the
    // query's own scope, so e.Salary resolves rather than faulting against a
    // hidden derived relation. Every salary is positive, so all is true; a
    // higher floor some row undercuts falsifies it.
    let positive = try from("Employees", as: "e")
        .all(column("e.Salary") > 0, against: catalog, routines: .standard)
    #expect(positive == true)
    let rich = try from("Employees", as: "e")
        .all(column("e.Salary") > 100, against: catalog, routines: .standard)
    #expect(rich == false)
  }

  @Test func `all over an aggregate-only select tests the grouped row`()
      throws {
    let catalog = try company()
    // count() collapses the four employees to one row n=4 with no GROUP BY, so
    // the query aggregates and all must test that grouped row through a derived
    // table — not inject NOT n > 0 into the pre-aggregation WHERE, where the
    // alias n does not exist (and count() > 0 there is an aggregate in WHERE).
    let positive = try from("Employees").select(count().as("n"))
        .all(column("n") > 0, against: catalog, routines: .standard)
    #expect(positive == true)
    // Over an empty filter count() is one row n=0, which the grouped row test
    // falsifies — proving all judges the aggregate output, not the input rows.
    let empty = try from("Employees").where(column("Salary") > 1000)
        .select(count().as("n"))
        .all(column("n") > 0, against: catalog, routines: .standard)
    #expect(empty == false)
  }

  @Test func `all over a window projection tests the projected value`()
      throws {
    let catalog = try company()
    // ROW_NUMBER projects rn = 1…4; the rn alias exists only after the window
    // projection, so all must test it through a derived table — not inject
    // NOT rn > 0 into the pre-projection WHERE, where rn does not yet exist.
    let numbered = try from("Employees")
        .select(number().over(ordering: [asc("Salary")]).as("rn"))
        .all(column("rn") > 0, against: catalog, routines: .standard)
    #expect(numbered == true)
    // rn > 1 is falsified by the first-ordered row (rn = 1), proving the
    // projected window value is what is tested.
    let beyond = try from("Employees")
        .select(number().over(ordering: [asc("Salary")]).as("rn"))
        .all(column("rn") > 1, against: catalog, routines: .standard)
    #expect(beyond == false)
  }

  @Test func `all over a join resolves each side's qualifier`() throws {
    let catalog = try company()
    // A joined all keeps both relations in scope — even though Employees and
    // Departments share a Name column — so a predicate naming a column of each
    // by its qualifier resolves unambiguously. Every joined row pairs a
    // positive salary with a positive department id.
    let paired = try from("Employees", as: "e")
        .join("Departments", as: "d", on: column("e.Dept") == column("d.Id"))
        .all(column("e.Salary") > 0 && column("d.Id") > 0,
             against: catalog, routines: .standard)
    #expect(paired == true)
  }
}
