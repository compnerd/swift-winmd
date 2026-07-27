// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// Relations exercising the row-valued `IN (subquery)` and quantified-subquery
/// predicates: an outer `T2` whose two-column row `(A, B)` reaches the
/// three-valued corners (row 4 has a NULL component); a non-NULL inner `P`
/// filtered to empty or non-empty by `Flag`; a NULL-bearing inner `QN` (one row
/// has a NULL component, so the row NULL trap is reachable); and a `R2` whose
/// text `Name` column makes a UNION subquery irreconcilable.
private func rowfixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T2", ["Id": .integer, "A": .integer, "B": .integer]) {
      Row(1, 10, 100)
      Row(2, 20, 200)
      Row(3, 10, 999)
      Row(4, nil, 100)
      Row(5, 30, 300)
      Row(6, 5, 50)
    }
    Relation("P", ["X": .integer, "Y": .integer, "Flag": .integer]) {
      Row(10, 100, 1)
      Row(20, 200, 1)
      Row(50, 500, 0)
    }
    Relation("QN", ["X": .integer, "Y": .integer]) {
      Row(10, 100)
      Row(20, nil)
    }
    Relation("R2", ["Id2": .integer, "Name": .text]) {
      Row(1, "a")
    }
  }
}

// MARK: - Parsing

struct RowSubqueryParsingTests {
  @Test func `parses a row IN over a subquery`() throws {
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM P)")
    let inner = try parse(query: "SELECT X, Y FROM P")
    #expect(select.predicate
                == .within([.column("A"), .column("B")], inner,
                           negated: false))
  }

  @Test func `parses a row NOT IN over a subquery`() throws {
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) NOT IN (SELECT X, Y FROM P)")
    let inner = try parse(query: "SELECT X, Y FROM P")
    #expect(select.predicate
                == .within([.column("A"), .column("B")], inner,
                           negated: true))
  }

  @Test func `a row IN over a value list still parses as among`() throws {
    // The subquery lookahead only takes the subquery arm on a leading SELECT (or
    // a parenthesised query); an ordinary value list of rows stays a `.among`.
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) IN ((10, 100), (20, 200))")
    #expect(select.predicate
                == .among([.column("A"), .column("B")],
                          [[.literal(.integer(10)), .literal(.integer(100))],
                           [.literal(.integer(20)), .literal(.integer(200))]],
                          negated: false))
  }

  @Test func `parses a row IN over a parenthesised subquery`() throws {
    // A leading `(` after `IN (` is ambiguous: a nested query primary here, told
    // apart by the `)` that immediately follows the parsed query.
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) IN ((SELECT X, Y FROM P))")
    let inner = try parse(query: "(SELECT X, Y FROM P)")
    #expect(select.predicate
                == .within([.column("A"), .column("B")], inner,
                           negated: false))
  }

  @Test func `parses a row quantified subquery`() throws {
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) = ANY (SELECT X, Y FROM P)")
    let inner = try parse(query: "SELECT X, Y FROM P")
    #expect(select.predicate
                == .quantified([.column("A"), .column("B")], .equal, .any,
                               inner))
  }

  @Test func `SOME normalises to ANY in a row quantified subquery`() throws {
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) <> SOME (SELECT X, Y FROM P)")
    let inner = try parse(query: "SELECT X, Y FROM P")
    #expect(select.predicate
                == .quantified([.column("A"), .column("B")], .unequal, .any,
                               inner))
  }

  @Test func `parses a row comparison against a row still as rows`() throws {
    // The op-then-row path is unchanged when no quantifier follows the operator.
    let select = try parse(select:
        "SELECT Id FROM T2 WHERE (A, B) = (10, 100)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B")], .equal,
                         [.literal(.integer(10)), .literal(.integer(100))]))
  }
}

// MARK: - Row IN (subquery) execution

struct RowInQueryEvaluationTests {
  @Test func `a row IN over a subquery admits the matching rows`() throws {
    // P filtered to Flag = 1 yields {(10, 100), (20, 200)}: T2 rows 1 and 2
    // match componentwise; 3 (B differs), 5, 6 do not; 4 (A NULL) is UNKNOWN.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM P WHERE Flag = 1)",
        yields: [[1], [2]])
  }

  @Test func `a row NOT IN over a subquery admits the complement`() throws {
    // The negation over the non-NULL, non-UNKNOWN rows: 3, 5, 6. Row 4's NULL
    // component leaves the membership UNKNOWN, so NOT IN drops it too.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) NOT IN "
        + "(SELECT X, Y FROM P WHERE Flag = 1)",
        yields: [[3], [5], [6]])
  }

  @Test func `a NULL left component makes the row IN UNKNOWN`() throws {
    // Row 4 is (NULL, 100): `(NULL, 100) = (10, 100)` is `UNKNOWN AND TRUE` =
    // UNKNOWN, `= (20, 200)` is `UNKNOWN AND FALSE` = FALSE, so the disjunction
    // is `UNKNOWN OR FALSE` = UNKNOWN — dropped by IN and by NOT IN alike.
    try rowfixture().empty(
        "SELECT Id FROM T2 WHERE (A, B) IN "
        + "(SELECT X, Y FROM P WHERE Flag = 1) AND Id = 4")
    try rowfixture().empty(
        "SELECT Id FROM T2 WHERE (A, B) NOT IN "
        + "(SELECT X, Y FROM P WHERE Flag = 1) AND Id = 4")
  }

  @Test func `a row IN folds like the value-list row IN`() throws {
    // The subquery yielding {(10, 100), (20, 200)} matches exactly the value
    // list of the same rows — the two share one three-valued membership core.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) IN "
        + "(SELECT X, Y FROM P WHERE Flag = 1)",
        equals:
        "SELECT Id FROM T2 WHERE (A, B) IN ((10, 100), (20, 200))")
  }

  @Test func `a row IN over an empty subquery is FALSE`() throws {
    // An empty subquery has no witness row, so `(A, B) IN (empty)` is FALSE for
    // every outer row.
    try rowfixture().empty(
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM P WHERE Flag = 9)")
  }

  @Test func `a row NOT IN over an empty subquery is TRUE`() throws {
    // `NOT IN (empty)` is the negation of FALSE — TRUE — so every row survives,
    // including row 4 whose A is NULL (the NULL trap needs a NULL candidate row,
    // and an empty subquery has none).
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) NOT IN "
        + "(SELECT X, Y FROM P WHERE Flag = 9)",
        yields: [[1], [2], [3], [4], [5], [6]])
  }
}

// MARK: - The NULL corners (subquery components)

struct RowInQueryNullCornerTests {
  @Test func `a row present in a NULL-bearing subquery is TRUE`() throws {
    // QN is {(10, 100), (20, NULL)}; `(10, 100) IN (…)` finds the definite
    // `(10, 100)` match, so it is TRUE regardless of the NULL-bearing row.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM QN) AND Id = 1",
        yields: [[1]])
  }

  @Test func `an unmatched row against a NULL-bearing subquery is UNKNOWN`()
      throws {
    // Row 2 is (20, 200): `= (10, 100)` FALSE, `= (20, NULL)` is
    // `TRUE AND UNKNOWN` = UNKNOWN, so the disjunction is UNKNOWN, not FALSE —
    // the row is not admitted by IN.
    try rowfixture().empty(
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM QN) AND Id = 2")
  }

  @Test func `a row NOT IN a NULL-bearing subquery is UNKNOWN (the trap)`()
      throws {
    // Row 2 (20, 200): the membership is UNKNOWN (the NULL component of the
    // `(20, NULL)` candidate), so `NOT IN` negates UNKNOWN to UNKNOWN — never
    // TRUE when a candidate comparison is UNKNOWN and none is TRUE — so the row
    // is dropped, the row-valued NULL trap.
    try rowfixture().empty(
        "SELECT Id FROM T2 WHERE (A, B) NOT IN (SELECT X, Y FROM QN) AND Id = 2")
  }
}

// MARK: - Row quantified subquery execution

struct RowQuantifiedEvaluationTests {
  @Test func `= ANY over a subquery is the row IN`() throws {
    // ISO: `(l…) = ANY (Q)` is `(l…) IN (Q)`.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) = ANY "
        + "(SELECT X, Y FROM P WHERE Flag = 1)",
        equals:
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM P WHERE Flag = 1)")
  }

  @Test func `<> ALL over a subquery is the row NOT IN`() throws {
    // ISO: `(l…) <> ALL (Q)` is `(l…) NOT IN (Q)` — both fold the same NULL
    // trap over row 4.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) <> ALL "
        + "(SELECT X, Y FROM P WHERE Flag = 1)",
        equals:
        "SELECT Id FROM T2 WHERE (A, B) NOT IN "
        + "(SELECT X, Y FROM P WHERE Flag = 1)")
  }

  @Test func `< ALL compares rows lexicographically`() throws {
    // P = {(10, 100), (20, 200)}; `< ALL` is strictly below the lexicographic
    // minimum (10, 100). Only row 6 (5, 50) qualifies; row 1 (10, 100) is not
    // strictly below itself, and row 4's NULL leaves it UNKNOWN.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) < ALL "
        + "(SELECT X, Y FROM P WHERE Flag = 1)",
        yields: [[6]])
  }

  @Test func `> ANY compares rows lexicographically`() throws {
    // `> ANY` is strictly above at least one row — above the minimum (10, 100).
    // Rows 2, 3, 5 qualify; row 1 equals the minimum, row 6 is below it, and
    // row 4's NULL leaves both comparisons UNKNOWN.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) > ANY "
        + "(SELECT X, Y FROM P WHERE Flag = 1)",
        yields: [[2], [3], [5]])
  }

  @Test func `ANY over an empty subquery is FALSE`() throws {
    // The fold's identity: `ANY` over no rows has no witness — FALSE for every
    // outer row.
    try rowfixture().empty(
        "SELECT Id FROM T2 WHERE (A, B) = ANY "
        + "(SELECT X, Y FROM P WHERE Flag = 9)")
  }

  @Test func `ALL over an empty subquery is TRUE`() throws {
    // The fold's identity: `ALL` over no rows is vacuously TRUE for every outer
    // row, including row 4 whose A is NULL (no candidate row is evaluated).
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) <> ALL "
        + "(SELECT X, Y FROM P WHERE Flag = 9)",
        yields: [[1], [2], [3], [4], [5], [6]])
  }
}

// MARK: - Arity

struct RowSubqueryArityTests {
  @Test func `a row IN over a mis-arity subquery faults`() throws {
    // The row's degree (2) must equal the subquery's result degree; a one-column
    // subquery is `SQLError.arity`, checked from the compiled width, so it
    // faults even though P has rows.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X FROM P)",
        fails: .arity(2, 1))
  }

  @Test func `a row quantified mis-arity subquery faults`() throws {
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) = ANY (SELECT X FROM P)",
        fails: .arity(2, 1))
  }

  @Test func `a row IN mis-arity subquery faults the schema check too`()
      throws {
    // The schema path enforces the same row-arity-equals-width rule as the run,
    // so validation matches execution (run ≡ columns(of:)).
    let query = try parse(query:
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X FROM P)")
    let resolve = { () throws -> Array<OutputColumn> in
      try rowfixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.arity(2, 1)) {
      try resolve()
    }
  }
}

// MARK: - Type checking (run ≡ validate)

struct RowSubqueryTypeCheckingTests {
  @Test func `columns validates a row IN over a subquery`() throws {
    let query = try parse(query:
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Y FROM P)")
    let columns = try rowfixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `columns validates a row quantified subquery`() throws {
    let query = try parse(query:
        "SELECT Id FROM T2 WHERE (A, B) >= ALL (SELECT X, Y FROM P)")
    let columns = try rowfixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad inner column faults the schema check`() throws {
    // The inner query is type-checked too, so an unknown column inside it faults
    // validation exactly as a run would reject it.
    let query = try parse(query:
        "SELECT Id FROM T2 WHERE (A, B) IN (SELECT X, Missing FROM P)")
    let resolve = { () throws -> Array<OutputColumn> in
      try rowfixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }

  @Test func `an irreconcilable UNION subquery faults`() throws {
    // The subquery's own set-operation type fold reuses the existing machinery:
    // the second column pairs an integer (P.Y) with a text (R2.Name), which the
    // UNION arms cannot unify — `SQLError.operand` (SQLSTATE 42804) — faulting
    // the row IN at run.
    try rowfixture().expect(
        "SELECT Id FROM T2 WHERE (A, B) IN "
        + "(SELECT X, Y FROM P UNION SELECT Id2, Name FROM R2)",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `an irreconcilable UNION subquery faults the schema check too`()
      throws {
    // The same irreconcilable UNION faults validation, so run ≡ columns(of:).
    let query = try parse(query:
        "SELECT Id FROM T2 WHERE (A, B) IN "
        + "(SELECT X, Y FROM P UNION SELECT Id2, Name FROM R2)")
    let resolve = { () throws -> Array<OutputColumn> in
      try rowfixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("UNION arms have irreconcilable types")) {
      try resolve()
    }
  }
}
