// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// The window-function surface (`Window.swift`) — ranking, distribution, offset,
// value, and aggregate windows built with `.over(partitioning:ordering:)`. Each
// operator asserts the built statement equals the parser's tree for the
// equivalent SQL (the `Hashable` oracle) and, where it computes a value, runs
// over a fixture to the rows the SQL would yield.

/// Parses `sql` to the `Statement` the builder should equal.
private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

/// A one-relation fixture with ties within each department.
private func employees() throws -> FixtureCatalog {
  try Catalog {
    Relation("Employees",
             ["Name": .text, "Dept": .integer, "Salary": .integer]) {
      Row("Alice", 1, 100)
      Row("Bob", 1, 90)
      Row("Carol", 2, 120)
      Row("Dave", 2, 80)
    }
  }
}

struct WindowLoweringTests {
  @Test func `ROW_NUMBER lowers with an ORDER BY`() throws {
    let built = from("Employees")
        .select(number().over(ordering: [asc("Salary")]).as("rn"))
        .statement
    #expect(built == (try parsed("""
        SELECT ROW_NUMBER() OVER (ORDER BY Salary) AS rn FROM Employees
        """)))
  }

  @Test func `RANK lowers with a PARTITION BY and a descending ORDER BY`()
      throws {
    let built = from("Employees")
        .select(rank().over(partitioning: [column("Dept")],
                            ordering: [desc("Salary")]).as("r"))
        .statement
    #expect(built == (try parsed("""
        SELECT RANK() OVER (PARTITION BY Dept ORDER BY Salary DESC) AS r
        FROM Employees
        """)))
  }

  @Test func `an aggregate windows with over`() throws {
    let built = from("Employees")
        .select(sum(column("Salary")).over(partitioning: [column("Dept")])
                    .as("total"))
        .statement
    #expect(built == (try parsed("""
        SELECT SUM(Salary) OVER (PARTITION BY Dept) AS total FROM Employees
        """)))
  }

  @Test func `the distribution, offset, and value functions lower`() throws {
    let cases: [(Term, String)] = [
      (dense().over(ordering: [asc("Salary")]),
       "DENSE_RANK() OVER (ORDER BY Salary)"),
      (ntile(2).over(ordering: [asc("Salary")]),
       "NTILE(2) OVER (ORDER BY Salary)"),
      (percent().over(ordering: [asc("Salary")]),
       "PERCENT_RANK() OVER (ORDER BY Salary)"),
      (cumulative().over(ordering: [asc("Salary")]),
       "CUME_DIST() OVER (ORDER BY Salary)"),
      (lead(column("Salary")).over(ordering: [asc("Salary")]),
       "LEAD(Salary) OVER (ORDER BY Salary)"),
      (lag(column("Salary"), offset: 2, default: 0)
          .over(ordering: [asc("Salary")]),
       "LAG(Salary, 2, 0) OVER (ORDER BY Salary)"),
      (first(column("Name")).over(ordering: [asc("Salary")]),
       "FIRST_VALUE(Name) OVER (ORDER BY Salary)"),
      (last(column("Name")).over(ordering: [asc("Salary")]),
       "LAST_VALUE(Name) OVER (ORDER BY Salary)"),
      (nth(column("Name"), 2).over(ordering: [asc("Salary")]),
       "NTH_VALUE(Name, 2) OVER (ORDER BY Salary)"),
    ]
    for (term, sql) in cases {
      let built = from("Employees").select(term.as("w")).statement
      #expect(built == (try parsed("SELECT \(sql) AS w FROM Employees")),
              "\(sql)")
    }
  }

  @Test func `a grouped window orders by an aggregate`() throws {
    let built = from("Employees")
        .select(column("Dept").as("Dept"),
                dense().over(ordering: [asc(sum(column("Salary")))]).as("r"))
        .group(by: "Dept")
        .statement
    #expect(built == (try parsed("""
        SELECT Dept AS Dept, DENSE_RANK() OVER (ORDER BY SUM(Salary)) AS r
        FROM Employees GROUP BY Dept
        """)))
  }
}

struct WindowExecutionTests {
  @Test func `ROW_NUMBER numbers the rows in the window order`() throws {
    let rows = try from("Employees")
        .select(column("Name").as("Name"),
                number().over(ordering: [asc("Salary")]).as("rn"))
        .order(by: "Name")
        .run(against: employees(), routines: .standard)
    // By Salary ascending: Dave 80=1, Bob 90=2, Alice 100=3, Carol 120=4;
    // the output is ordered by Name.
    #expect(rows == [[.text("Alice"), .integer(3)],
                     [.text("Bob"), .integer(2)],
                     [.text("Carol"), .integer(4)],
                     [.text("Dave"), .integer(1)]])
  }

  @Test func `an aggregate window totals each partition`() throws {
    let rows = try from("Employees")
        .select(column("Name").as("Name"),
                sum(column("Salary")).over(partitioning: [column("Dept")])
                    .as("total"))
        .order(by: "Name")
        .run(against: employees(), routines: .standard)
    // Dept 1 = 100 + 90 = 190; Dept 2 = 120 + 80 = 200.
    #expect(rows == [[.text("Alice"), .integer(190)],
                     [.text("Bob"), .integer(190)],
                     [.text("Carol"), .integer(200)],
                     [.text("Dave"), .integer(200)]])
  }

  @Test func `RANK ranks within each partition`() throws {
    let rows = try from("Employees")
        .select(column("Name").as("Name"),
                rank().over(partitioning: [column("Dept")],
                            ordering: [desc("Salary")]).as("r"))
        .order(by: "Name")
        .run(against: employees(), routines: .standard)
    // Dept 1 by Salary desc: Alice 100=1, Bob 90=2; Dept 2: Carol 120=1,
    // Dave 80=2.
    #expect(rows == [[.text("Alice"), .integer(1)],
                     [.text("Bob"), .integer(2)],
                     [.text("Carol"), .integer(1)],
                     [.text("Dave"), .integer(2)]])
  }

  @Test func `a window over grouped output ranks the groups`() throws {
    let rows = try from("Employees")
        .select(column("Dept").as("Dept"),
                dense().over(ordering: [asc(sum(column("Salary")))]).as("r"))
        .group(by: "Dept")
        .order(by: "Dept")
        .run(against: employees(), routines: .standard)
    // Group totals: Dept 1 = 190, Dept 2 = 200; DENSE_RANK by total ascending.
    #expect(rows == [[.integer(1), .integer(1)],
                     [.integer(2), .integer(2)]])
  }
}
