// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising the `IN` value-list predicate: an integer key `K` that
/// is `NULL` in some rows, so the three-valued corners (a NULL operand, a NULL
/// element) are reachable, and a text `Name` to fault an incompatible element
/// type against.
private func members() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer, "Name": .text]) {
      Row(1, 10, "a")
      Row(2, 20, "b")
      Row(3, nil, "c")
      Row(4, 30, "d")
    }
  }
}

// MARK: - Parsing

/// Parses `text` and returns its `Select`, failing on any other shape.
private func parse(select text: String) throws -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

struct MembershipParsingTests {
  @Test func `parses an IN value list`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K IN (1, 2, 3)")
    #expect(select.predicate
                == .membership(.column("K"),
                               [.literal(.integer(1)), .literal(.integer(2)),
                                .literal(.integer(3))], negated: false))
  }

  @Test func `parses a NOT IN value list`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K NOT IN (1, 2)")
    #expect(select.predicate
                == .membership(.column("K"),
                               [.literal(.integer(1)), .literal(.integer(2))],
                               negated: true))
  }

  @Test func `parses a single-element IN list`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K IN (7)")
    #expect(select.predicate
                == .membership(.column("K"), [.literal(.integer(7))],
                               negated: false))
  }

  @Test func `parses IN over an expression operand`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K + 1 IN (11, 21)")
    let operand = Expression.binary(.add, .column("K"), .literal(.integer(1)))
    #expect(select.predicate
                == .membership(operand,
                               [.literal(.integer(11)), .literal(.integer(21))],
                               negated: false))
  }

  @Test func `rejects an empty IN list`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE K IN ()")
    }
  }
}

// MARK: - Evaluation

struct MembershipEvaluationTests {
  @Test func `IN admits a matching value`() throws {
    try members().expect("SELECT Id FROM T WHERE K IN (10, 30)",
                         yields: [[1], [4]])
  }

  @Test func `IN rejects a non-matching value`() throws {
    try members().expect("SELECT Id FROM T WHERE K IN (99)", yields: [])
  }

  @Test func `NOT IN admits the complement`() throws {
    // Rows with a non-NULL K not in the list; row 3 (K NULL) is UNKNOWN and
    // dropped.
    try members().expect("SELECT Id FROM T WHERE K NOT IN (10, 30)",
                         yields: [[2]])
  }

  @Test func `a NULL operand makes IN UNKNOWN`() throws {
    // Row 3's K is NULL, so `NULL IN (10, 20)` is UNKNOWN, not FALSE — the row
    // is dropped rather than admitted, and would not be admitted by NOT IN
    // either.
    try members().expect("SELECT Id FROM T WHERE K IN (10, 20)",
                         yields: [[1], [2]])
    try members().expect("SELECT Id FROM T WHERE K NOT IN (10, 20)",
                         yields: [[4]])
  }

  @Test func `a NULL element leaves an unmatched IN UNKNOWN`() throws {
    // Row 3 has K = NULL, so its `K` cell is the NULL element. Over that row,
    // `20 IN (99, K)` is `20 = 99 OR 20 = NULL` — FALSE OR UNKNOWN — which is
    // UNKNOWN, not FALSE: the row is not admitted. `NOT IN` negates that
    // UNKNOWN to UNKNOWN, so it is never TRUE either — the row is dropped both
    // ways.
    try members().empty("SELECT Id FROM T WHERE 20 IN (99, K) AND Id = 3")
    try members().empty("SELECT Id FROM T WHERE 20 NOT IN (99, K) AND Id = 3")
  }

  @Test func `IN folds like an OR of equalities`() throws {
    try members().expect("SELECT Id FROM T WHERE K IN (10, 20, 30)",
                         equals: "SELECT Id FROM T WHERE K = 10 OR K = 20 OR K = 30")
  }
}

// MARK: - Type checking

struct MembershipTypeTests {
  /// Parses `text` to a query, failing on any other statement.
  private func parse(_ text: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      Issue.record("expected a SELECT statement")
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }

  @Test func `an incompatible element type faults the schema check`() throws {
    // `K` is an integer column; a text element can never match, so the WHERE
    // type check (the output-schema path) rejects it up front rather than
    // silently never matching. It faults where a comparison to a text literal
    // would be classified as ill-typed.
    let query = try parse("SELECT Id FROM T WHERE K IN (10, 'x')")
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query)
    }
    #expect(throws:
        SQLError.operand("IN list element is not comparable to the operand")) {
      try resolve()
    }
  }

  @Test func `a numeric element of the other numeric kind is admitted`() throws {
    // An integer operand and a double element are comparable (both numeric), so
    // the schema check passes and the run matches by magnitude.
    let query = try parse("SELECT Id FROM T WHERE K IN (10.0, 20.0)")
    _ = try members().columns(of: query)
    try members().expect("SELECT Id FROM T WHERE K IN (10.0, 20.0)",
                         yields: [[1], [2]])
  }

  @Test func `a definite match short-circuits a later bad element`() throws {
    // `1 IN (1, Name + 1)` lowers to `1 = 1 OR 1 = Name + 1`; the first
    // disjunct is a definite constant match, so the OR-chain short-circuits and
    // `Name + 1` (text arithmetic) is unreachable — the type check does not
    // validate it, and the query runs (matching every row).
    let query = try parse("SELECT Id FROM T WHERE 1 IN (1, Name + 1)")
    _ = try members().columns(of: query, validate: true)
    try members().expect("SELECT Id FROM T WHERE 1 IN (1, Name + 1)",
                         yields: [[1], [2], [3], [4]])
  }

  @Test func `no definite match leaves a bad element reachable`() throws {
    // `2 IN (1, Name + 1)` never definitely matches `1`, so `Name + 1` is
    // reachable and its text arithmetic must still fault the type check.
    let query = try parse("SELECT Id FROM T WHERE 2 IN (1, Name + 1)")
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `an empty-group HAVING IN short-circuits a faulting element`()
      throws {
    // A whole-result aggregate over an empty source projects one empty group,
    // whose HAVING `1 IN (1, 1 / 0)` the schema path (`columns(of:)`) folds. The
    // OR-chain short-circuits on the literal `1 = 1`, so `1 / 0` is unreachable
    // and must not fault `.divide` — the schema resolves and the query runs.
    let query = try parse(
        "SELECT COUNT(*) FROM T WHERE 1 = 0 HAVING 1 IN (1, 1 / 0)")
    let columns = try members().columns(of: query)
    #expect(columns.count == 1)
    try members().expect(
        "SELECT COUNT(*) FROM T WHERE 1 = 0 HAVING 1 IN (1, 1 / 0)",
        yields: [[0]])
  }

  /// A `SELECT Id FROM T WHERE <predicate>` built directly, so a
  /// `Predicate.membership` with an EMPTY value list reaches the engine —
  /// bypassing the parser, which rejects `IN ()`.
  private func select(where predicate: Predicate) -> Query {
    .select(Select(projection: .columns([Column(name: "Id")]),
                   from: Relation(name: "T"), predicate: predicate))
  }

  @Test func `an empty IN list faults the schema check, not a crash`() throws {
    // `Predicate.membership` is public, so a caller can build an EMPTY list
    // directly, bypassing the parser's `IN ()` rejection. The lowering has no
    // OR-chain seed for an empty list, so it FAULTS the schema check (an
    // unsupported shape) rather than trapping on the force-unwrap.
    let query = select(where: .membership(.column("Id"), [], negated: false))
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws:
        SQLError.unsupported("IN requires a non-empty value list")) {
      try resolve()
    }
  }

  @Test func `an empty IN list faults the run, not a crash`() throws {
    // The same direct-AST empty list must FAULT the run's compile/lowering (the
    // OR-chain reduction) rather than crashing on the force-unwrap.
    let query = select(where: .membership(.column("Id"), [], negated: false))
    #expect(throws:
        SQLError.unsupported("IN requires a non-empty value list")) {
      _ = try members().run(query)
    }
  }
}
