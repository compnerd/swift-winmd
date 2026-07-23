// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport
import func SQLTestSupport.parse

// MARK: - TABLE t

/// The ISO `TABLE t` query primary is exactly `SELECT * FROM t`. These tests
/// confirm it lowers to the SAME star-projection single-relation `Select`,
/// resolves a base table AND a view identically, and composes with the
/// set-operation tiers as a bare `SELECT *` does.
struct TableTests {
  @Test func `TABLE t lowers to a star-projection SELECT over the named relation`() throws {
    // The primary builds the same AST `SELECT * FROM People` does: a `.all`
    // projection over one named `Relation`, with no WHERE/GROUP/HAVING/order.
    guard case let .select(select) = try parse(query: "TABLE People") else {
      Issue.record("expected a single-SELECT query")
      return
    }
    #expect(select.projection == .all)
    #expect(select.table == "People")
    #expect(select.predicate == nil)
    #expect(select.grouping.isEmpty)
    #expect(select.having == nil)
    #expect(select.order == nil)
    #expect(select.limit == nil)
    #expect(select.joins.isEmpty)
  }

  @Test func `TABLE t parses the same AST as SELECT star FROM t`() throws {
    let table = try parse(query: "TABLE People")
    let star = try parse(query: "SELECT * FROM People")
    #expect(table == star)
  }

  @Test func `TABLE t yields every row and column of SELECT star FROM t`() throws {
    try roster().expect("TABLE People", equals: "SELECT * FROM People")
  }

  @Test func `TABLE t yields the full row/column set`() throws {
    try roster().expect("TABLE People", yields: [
      [1, "Alice", 30],
      [2, "Bob", 25],
      [3, "Carol", 30],
      [4, "Dave", 40],
      [5, "Eve", 25],
    ])
  }

  @Test func `TABLE over a view resolves as the view relation`() throws {
    // `Adults` is a registered view; `TABLE Adults` resolves it by name exactly
    // as `SELECT * FROM Adults` does, exposing the view's Key/Label columns.
    try gallery().expect("TABLE Adults", equals: "SELECT * FROM Adults")
    try gallery().expect("TABLE Adults", yields: [[2, "Bee"], [3, "Cid"]])
  }

  @Test func `TABLE a UNION TABLE b composes with a set operation`() throws {
    // Each arm is a `TABLE` primary; the UNION merges and dedups the shared row
    // exactly as the two-SELECT spelling does.
    try tags().expect("TABLE Lhs UNION TABLE Rhs",
                            equals: "SELECT * FROM Lhs UNION SELECT * FROM Rhs")
    try tags().expect("TABLE Lhs UNION TABLE Rhs",
                            yields: [["a"], ["shared"], ["b"]])
  }

  @Test func `a TABLE primary mixes with a SELECT arm across a set operation`() throws {
    // The primary composes on either side of the operator, so one arm may be a
    // `TABLE` and the other a `SELECT`.
    try tags().expect("TABLE Lhs UNION ALL SELECT Tag FROM Rhs",
                            yields: [["a"], ["shared"], ["shared"], ["b"]])
  }

  @Test func `TABLE composes at the tighter INTERSECT tier`() throws {
    try tags().expect("TABLE Lhs INTERSECT TABLE Rhs",
                            yields: [["shared"]])
  }

  @Test func `TABLE t admits no trailing ORDER BY at the primary level`() throws {
    // Ordering is a SELECT-internal clause in this grammar, not a
    // query-expression clause, so a `TABLE t ORDER BY …` tail is not part of
    // the primary — the trailing tokens fault. `SELECT * FROM t ORDER BY …`
    // carries an order.
    #expect(throws: SQLError.self) {
      _ = try parse(query: "TABLE People ORDER BY Age")
    }
  }

  @Test func `TABLE requires a relation name, not a derived table`() throws {
    // `TABLE (…)` is not an ISO form; the operand is a bare table/view name, so
    // a parenthesised subquery in its place faults.
    #expect(throws: SQLError.self) {
      _ = try parse(query: "TABLE (SELECT * FROM People)")
    }
  }

  // MARK: - (TABLE …) in a query position

  // A parenthesised query — a derived table, a scalar subquery, or an
  // IN-subquery — may open with `TABLE` exactly as it opens with `SELECT`,
  // since `TABLE t` is itself a query. Each form parses and runs identically to
  // its `(SELECT * FROM t)` spelling.

  @Test func `a (TABLE t) derived table parses and runs as (SELECT star FROM t)`() throws {
    // `FROM (TABLE People) AS d` is a derived table whose body is the `TABLE`
    // primary; it selects the same rows the `(SELECT * FROM People)` body does.
    _ = try parse(query: "SELECT * FROM (TABLE People) AS d")
    try roster().expect(
        "SELECT * FROM (TABLE People) AS d",
        equals: "SELECT * FROM (SELECT * FROM People) AS d")
    try roster().expect("SELECT d.Name FROM (TABLE People) AS d",
                              yields: [["Alice"], ["Bob"], ["Carol"],
                                       ["Dave"], ["Eve"]])
  }

  @Test func `a (TABLE t) scalar subquery parses and runs as (SELECT star FROM t)`() throws {
    // `One` is one row of one column, so `(TABLE One)` is a valid scalar
    // subquery — it yields that single cell, exactly as `(SELECT * FROM One)`.
    _ = try parse(query: "SELECT (TABLE One) FROM One")
    try scalars().expect("SELECT (TABLE One) FROM One",
                               equals: "SELECT (SELECT * FROM One) FROM One")
    try scalars().expect("SELECT (TABLE One) FROM One", yields: [[42]])
  }

  @Test func `an x IN (TABLE t) subquery parses and runs as IN (SELECT star FROM t)`() throws {
    // `Ids` is a single column, so `Tag IN (TABLE Ids)` is a valid IN-subquery,
    // membership over that column exactly as `IN (SELECT * FROM Ids)`.
    _ = try parse(query: "SELECT V FROM Vals WHERE V IN (TABLE Ids)")
    try scalars().expect(
        "SELECT V FROM Vals WHERE V IN (TABLE Ids)",
        equals: "SELECT V FROM Vals WHERE V IN (SELECT * FROM Ids)")
    try scalars().expect("SELECT V FROM Vals WHERE V IN (TABLE Ids)",
                               yields: [[1], [3]])
  }
}

/// A catalog for the scalar-subquery and IN-subquery `(TABLE …)` forms: `One`
/// is one row of one column (a valid scalar subquery), `Ids` is a single column
/// (a valid IN-subquery), and `Vals` is the probe relation the IN filters.
func scalars() throws -> EngineMemory {
  try Catalog {
    Relation("One", ["N": .integer]) {
      Row(42)
    }
    Relation("Ids", ["Key": .integer]) {
      Row(1)
      Row(3)
    }
    Relation("Vals", ["V": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
  }
}
