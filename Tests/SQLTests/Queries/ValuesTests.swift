// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport
import func SQLTestSupport.parse

// MARK: - VALUES

/// The ISO `VALUES (…), …` table value constructor desugars to a `UNION ALL` of
/// FROM-less constant `SELECT`s. These tests confirm it yields its rows in
/// order, names the default `column1, column2, …` outputs, works standalone and
/// as a derived table, preserves duplicate rows, composes with a set operation,
/// and faults on a cross-row arity mismatch.
struct ValuesTests {
  /// A minimal catalog for the FROM-less `VALUES` runs — the constructor names
  /// no relation, so its single one-element relation is never scanned; the run
  /// still needs a catalog to borrow.
  private func store() throws -> EngineMemory {
    try Catalog {
      Relation("Unused", ["a": .integer]) {
        Row(1)
      }
    }
  }

  // MARK: - Desugar shape

  @Test func `VALUES desugars to a UNION ALL of FROM-less SELECTs`() throws {
    // `VALUES (1, 2), (3, 4)` lowers to `SELECT 1 AS column1, 2 AS column2
    // UNION ALL SELECT 3, 4` — a `.setop(.union, …, all: true)` whose first arm
    // is FROM-less and aliases the default output names.
    let query = try parse(query: "VALUES (1, 2), (3, 4)")
    guard case let .setop(kind, left, right, all) = query else {
      Issue.record("expected a UNION ALL set operation")
      return
    }
    #expect(kind == .union)
    #expect(all)

    guard case let .select(head) = left,
          case let .expressions(items) = head.projection else {
      Issue.record("expected a FROM-less expression projection as the head arm")
      return
    }
    #expect(head.from == nil)
    #expect(items.map(\.alias) == ["column1", "column2"])
    #expect(items.map(\.expression) == [.literal(.integer(1)),
                                        .literal(.integer(2))])

    // The trailing arm projects the bare expressions — a set operation names
    // its result from the first arm alone, so a later arm carries no aliases.
    guard case let .select(tail) = right,
          case let .expressions(later) = tail.projection else {
      Issue.record("expected a FROM-less expression projection as the tail arm")
      return
    }
    #expect(tail.from == nil)
    #expect(later.map(\.alias) == [nil, nil])
  }

  @Test func `a single-row VALUES is one FROM-less SELECT`() throws {
    // With one row there is no set operation — the desugar is the single arm.
    let query = try parse(query: "VALUES (1, 2)")
    guard case let .select(select) = query,
          case let .expressions(items) = select.projection else {
      Issue.record("expected a single FROM-less SELECT")
      return
    }
    #expect(select.from == nil)
    #expect(items.map(\.alias) == ["column1", "column2"])
  }

  // MARK: - Standalone

  @Test func `a standalone VALUES yields its rows in order`() throws {
    try store().expect("VALUES (1, 2), (3, 4)", yields: [[1, 2], [3, 4]])
  }

  @Test func `a single-row VALUES yields that one row`() throws {
    try store().expect("VALUES (1, 2)", yields: [[1, 2]])
  }

  @Test func `VALUES yields a text column`() throws {
    try store().expect("VALUES (1, 'a'), (2, 'b')",
                       yields: [[1, "a"], [2, "b"]])
  }

  @Test func `VALUES preserves duplicate rows with no dedup`() throws {
    // The desugar is `UNION ALL`, so a repeated row is kept, not collapsed.
    try store().expect("VALUES (1, 2), (1, 2), (3, 4)",
                       yields: [[1, 2], [1, 2], [3, 4]])
  }

  @Test func `VALUES row order is source order`() throws {
    try store().expect("VALUES (3), (1), (2)", yields: [[3], [1], [2]])
  }

  // MARK: - Default column names

  @Test func `VALUES names its default columns column1, column2, …`() throws {
    // The default output names are the ISO `column1, column2, …`; a derived
    // table over the constructor exposes them for selection.
    try store().expect("SELECT column1 FROM (VALUES (5, 6), (7, 8)) AS t",
                       yields: [[5], [7]])
    try store().expect("SELECT column2 FROM (VALUES (5, 6), (7, 8)) AS t",
                       yields: [[6], [8]])
  }

  @Test func `VALUES default names appear in the result schema`() throws {
    let columns = try store().columns(of:
        parse(query: "VALUES (1, 'a'), (2, 'b')"), routines: .standard)
    #expect(columns.map(\.name) == ["column1", "column2"])
  }

  // MARK: - Derived table

  @Test func `VALUES is a derived-table source in FROM`() throws {
    try store().expect("SELECT * FROM (VALUES (1, 2), (3, 4)) AS t",
                       yields: [[1, 2], [3, 4]])
  }

  @Test func `a derived VALUES projects a qualified column`() throws {
    try store().expect("SELECT t.column1 FROM (VALUES (10), (20)) AS t",
                       yields: [[10], [20]])
  }

  @Test func `a derived VALUES filters through a WHERE`() throws {
    try store().expect(
        "SELECT column1 FROM (VALUES (1), (2), (3)) AS t WHERE column1 > 1",
        yields: [[2], [3]])
  }

  // MARK: - Type unification

  @Test func `a mixed numeric VALUES column unifies to double`() throws {
    // VALUES desugars to a `UNION ALL`, so a column's type UNIFIES across every
    // arm through the set-operation type fold (the ISO rule a `UNION` follows),
    // NOT the first arm alone. A column mixing integer and double widens to
    // double, and the integer arm's value is COERCED to that unified type.
    // `VALUES (1), (2.5)`'s column1 is thus a double throughout, `1.0` then
    // `2.5`, regardless of the arm order.
    let columns = try store().columns(of:
        parse(query: "VALUES (1), (2.5)"), routines: .standard)
    #expect(columns.map(\.type) == [.double])
    try store().expect("VALUES (1), (2.5)", yields: [[1.0], [2.5]])
  }

  @Test func `a VALUES with a leading double column types double`() throws {
    // Written double-first, the same column is a double throughout — the
    // cross-arm unification is order-independent, so integer-then-double and
    // double-then-integer both widen to double and coerce the integer arm.
    let columns = try store().columns(of:
        parse(query: "VALUES (2.5), (1)"), routines: .standard)
    #expect(columns.map(\.type) == [.double])
    try store().expect("VALUES (2.5), (1)", yields: [[2.5], [1.0]])
  }

  // MARK: - Set-operation composition

  @Test func `VALUES composes under a UNION`() throws {
    // A `VALUES` primary is a query, so it composes on either side of a set
    // operator; the outer `UNION` dedups the shared row.
    try store().expect(
        "VALUES (1), (2) UNION VALUES (2), (3)",
        yields: [[1], [2], [3]])
  }

  @Test func `VALUES mixes with a TABLE arm across a UNION ALL`() throws {
    try enginePeople().expect(
        "SELECT Age FROM People WHERE Id = 1 UNION ALL VALUES (99)",
        yields: [[30], [99]])
  }

  // MARK: - Parenthesised-query contexts

  @Test func `VALUES is a scalar subquery`() throws {
    // `(VALUES (1))` is a query, so it is a first-class scalar subquery: a
    // one-row one-column constructor yields that single scalar, exactly as
    // `(SELECT …)` does. The parse must route the parenthesised `VALUES` to the
    // query parser, not the value-expression parser.
    let query = try parse(query: "SELECT (VALUES (1)) AS x")
    guard case let .select(select) = query,
          case let .expressions(items) = select.projection else {
      Issue.record("expected an expression projection")
      return
    }
    guard case .subquery = items[0].expression else {
      Issue.record("expected a scalar subquery expression")
      return
    }
    try store().expect("SELECT (VALUES (1)) AS x", yields: [[1]])
  }

  @Test func `VALUES is an IN-subquery`() throws {
    // `IN (VALUES (…), (…))` tests membership over the constructor's rows — a
    // query subquery, not a bare value list. The parenthesised `VALUES` must
    // route to the query parser so it is one subquery, not two row literals.
    let query = try parse(query:
        "SELECT Id FROM People WHERE Id IN (VALUES (1), (2))")
    guard case let .select(select) = query,
          case .within? = select.predicate else {
      Issue.record("expected an IN-subquery predicate")
      return
    }
    try enginePeople().expect(
        "SELECT Id FROM People WHERE Id IN (VALUES (1), (2))",
        yields: [[1], [2]])
  }

  @Test func `VALUES is a quantified-comparison subquery`() throws {
    // `= ANY (VALUES (…), (…))` compares against the constructor's rows — the
    // quantified path always parses a parenthesised query, so a `VALUES`
    // primary composes there as `(SELECT …)` does.
    try enginePeople().expect(
        "SELECT Id FROM People WHERE Age = ANY (VALUES (30), (40))",
        yields: [[1], [3], [4]])
  }

  @Test func `an incompatible mixed VALUES column faults`() throws {
    // A column mixing text and integer has no common type, so the set-operation
    // type fold VALUES desugars through rejects it — the same operand fault a
    // `UNION` of irreconcilable arms raises.
    try store().expect("VALUES ('a'), (1)",
                       fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a NULL VALUES arm unifies with a typed arm`() throws {
    // A constant-NULL arm constrains nothing, so it unifies with the other
    // arm's type rather than faulting — `NULLIF('a', 'a')` is NULL, so the
    // column takes the integer arm's type and the constructor runs, the NULL
    // arm yielding NULL and the integer arm its value.
    let columns = try store().columns(of:
        parse(query: "VALUES (NULLIF('a', 'a')), (1)"), routines: .standard)
    #expect(columns.map(\.type) == [.integer])
    try store().expect("VALUES (NULLIF('a', 'a')), (1)",
                       yields: [[nil], [1]])
  }

  // MARK: - Faults

  @Test func `VALUES faults on a cross-row arity mismatch`() throws {
    // Every row must construct the same number of columns; a wider or narrower
    // later row is an ISO arity error.
    try store().expect("VALUES (1, 2), (3)", fails: .arity(2, 1))
    try store().expect("VALUES (1), (2, 3)", fails: .arity(1, 2))
  }

  @Test func `an empty VALUES row faults`() throws {
    // Each row must have at least one element; a `VALUES ()` is not a row.
    #expect(throws: SQLError.self) {
      _ = try parse(query: "VALUES ()")
    }
  }
}
