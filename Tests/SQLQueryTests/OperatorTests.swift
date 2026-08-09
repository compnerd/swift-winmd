// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// The LINQ operators added over the rebased builder — `concat` (UNION ALL),
// `then(by:)` (ThenBy), and the `count`/`all` terminals. The combinators assert
// the built statement equals the parser's tree for the equivalent SQL (the
// `Hashable` oracle); every operator is also run over a fixture, so it is
// checked to both parse-equal and execute to the expected rows.

/// Parses `sql` to the `Statement` the builder should equal.
private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

/// The two-relation company fixture the other execution tests use.
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

struct ConcatTests {
  @Test func `concat lowers to UNION ALL`() throws {
    let built = from("a").select("x")
        .concat(from("b").select("x"))
        .statement
    #expect(built == (try parsed("""
        SELECT x FROM a UNION ALL SELECT x FROM b
        """)))
  }

  @Test func `a chained concat associates left`() throws {
    let built = from("a").select("x")
        .concat(from("b").select("x"))
        .concat(from("c").select("x"))
        .statement
    #expect(built == (try parsed("""
        SELECT x FROM a UNION ALL SELECT x FROM b UNION ALL SELECT x FROM c
        """)))
  }

  @Test func `concat keeps duplicates a union would drop`() throws {
    let catalog = try company()
    let rows = try from("Employees").select("Dept")
        .concat(from("Departments").select("Id"))
        .run(against: catalog, routines: .standard)
    // Employees.Dept is 1, 1, 2, 2 and Departments.Id is 1, 2 — the append
    // keeps every one of the six rows, where `union` would collapse to {1, 2}.
    #expect(rows.count == 6)
    #expect(rows.filter { $0 == [.integer(1)] }.count == 3)
    #expect(rows.filter { $0 == [.integer(2)] }.count == 3)
  }
}

struct ThenByTests {
  @Test func `then(by:) appends a minor sort key`() throws {
    let built = from("T").order(by: "a").then(by: desc("b")).then(by: asc("c"))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T ORDER BY a, b DESC, c ASC
        """)))
  }

  @Test func `a lone then(by:) starts the ordering`() throws {
    let built = from("T").then(by: "a").statement
    #expect(built == (try parsed("SELECT * FROM T ORDER BY a")))
  }

  @Test func `then(by:) breaks ties by the minor key`() throws {
    let catalog = try company()
    let rows = try from("Employees")
        .select("Name")
        .order(by: "Dept").then(by: desc("Salary"))
        .run(against: catalog, routines: .standard)
    // Dept ascending, ties broken by descending salary: dept 1 (Alice 100,
    // Bob 90), then dept 2 (Carol 120, Dave 80).
    #expect(rows == [[.text("Alice")], [.text("Bob")],
                     [.text("Carol")], [.text("Dave")]])
  }
}

struct CountTests {
  @Test func `count returns the row count`() throws {
    let catalog = try company()
    let n = try from("Employees")
        .count(against: catalog, routines: .standard)
    #expect(n == 4)
  }

  @Test func `count reflects a where filter`() throws {
    let catalog = try company()
    let n = try from("Employees")
        .where(column("Salary") >= 100)
        .count(against: catalog, routines: .standard)
    #expect(n == 2)
  }

  @Test func `count reflects distinct`() throws {
    let catalog = try company()
    let n = try from("Employees")
        .select("Dept")
        .distinct()
        .count(against: catalog, routines: .standard)
    #expect(n == 2)
  }
}

struct AllTests {
  @Test func `all is true when every row satisfies the predicate`() throws {
    let catalog = try company()
    let everyone = try from("Employees")
        .all(column("Salary") > 0, against: catalog, routines: .standard)
    #expect(everyone == true)
  }

  @Test func `all is false when a row falsifies the predicate`() throws {
    let catalog = try company()
    let everyone = try from("Employees")
        .all(column("Salary") >= 100, against: catalog, routines: .standard)
    #expect(everyone == false)
  }

  @Test func `all is vacuously true over an empty source`() throws {
    let catalog = try company()
    let everyone = try from("Employees")
        .where(column("Salary") > 1000)
        .all(column("Salary") < 0, against: catalog, routines: .standard)
    #expect(everyone == true)
  }
}
