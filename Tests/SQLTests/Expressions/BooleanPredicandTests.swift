// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising a bare `<boolean value expression>` in predicate
/// position: a nullable BOOLEAN column `Flag` covering all three truth values
/// (TRUE, FALSE, and a NULL row whose UNKNOWN corner a bare predicand drops),
/// beside an integer `Age` a non-boolean bare predicand reads.
private func flags() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "Flag": .boolean, "Age": .integer]) {
      Row(1, true, 20)
      Row(2, false, 30)
      Row(3, nil, 40)
    }
  }
}

/// The boolean predicate a bare boolean operand `x` bridges to — the comparison
/// `x = TRUE`, whose three-valued truth IS `x`'s boolean value.
private func boolean(_ left: Expression) -> Predicate {
  .comparison(left: left, op: .equal, right: .literal(.boolean(true)))
}

// MARK: - Parsing

struct BareBooleanPredicandParsingTests {
  @Test func `a bare NULL predicate desugars to NULL = TRUE`() throws {
    // A bare value expression standing alone as a predicate is an ISO `<boolean
    // predicand>`: it bridges to the comparison `NULL = TRUE`, the same desugar
    // `x IS TRUE` uses, whose three-valued truth is `NULL`'s (UNKNOWN).
    let select = try parse(select: "SELECT * FROM T WHERE NULL")
    #expect(select.predicate == boolean(.literal(.null)))
  }

  @Test func `a bare boolean column predicate desugars to column = TRUE`()
      throws {
    let select = try parse(select: "SELECT * FROM T WHERE Flag")
    #expect(select.predicate == boolean(.column("Flag")))
  }

  @Test func `a bare NOT NULL wraps the bridged comparison in a NOT`() throws {
    // The prefix `NOT` is the ordinary boolean negation `negation` consumes, so
    // `NOT NULL` is `NOT (NULL = TRUE)` — `NOT UNKNOWN` is UNKNOWN.
    let select = try parse(select: "SELECT * FROM T WHERE NOT NULL")
    #expect(select.predicate == .not(boolean(.literal(.null))))
  }

  @Test func `a parenthesised bare predicand desugars through the group`()
      throws {
    // `(Flag)` parses as the grouped value expression `Flag`, still bridging to
    // `Flag = TRUE`.
    let select = try parse(select: "SELECT * FROM T WHERE (Flag)")
    #expect(select.predicate == boolean(.column("Flag")))
  }

  @Test func `a genuinely malformed tail is not swallowed`() throws {
    // The desugar admits only a bare value expression standing alone: a second
    // value expression with no operator between them (`Age Age`) leaves the
    // trailing `Age` for the statement parser to reject, rather than being
    // swallowed by the predicand path.
    #expect(throws: SQLError.self) {
      try parse(select: "SELECT * FROM T WHERE Age Age")
    }
  }
}

// MARK: - Evaluation

struct BareBooleanPredicandEvaluationTests {
  // Fixture: Id 1 → Flag TRUE, Id 2 → Flag FALSE, Id 3 → Flag NULL (UNKNOWN).

  @Test func `WHERE NULL selects no rows`() throws {
    // `NULL = TRUE` is UNKNOWN for every row, and WHERE admits only TRUE.
    try flags().empty("SELECT Id FROM T WHERE NULL")
  }

  @Test func `WHERE NOT NULL selects no rows`() throws {
    // `NOT UNKNOWN` is UNKNOWN, so the negation keeps nothing either.
    try flags().empty("SELECT Id FROM T WHERE NOT NULL")
  }

  @Test func `NULL AND a true term is UNKNOWN, selecting no rows`() throws {
    // Kleene AND: UNKNOWN AND TRUE = UNKNOWN.
    try flags().empty("SELECT Id FROM T WHERE NULL AND 1 = 1")
  }

  @Test func `NULL OR a true term is TRUE, selecting every row`() throws {
    // Kleene OR: UNKNOWN OR TRUE = TRUE — TRUE dominates.
    try flags().expect("SELECT Id FROM T WHERE NULL OR 1 = 1",
                       yields: [[1], [2], [3]])
  }

  @Test func `NULL AND a false term is FALSE, selecting no rows`() throws {
    // Kleene AND: UNKNOWN AND FALSE = FALSE — FALSE dominates.
    try flags().empty("SELECT Id FROM T WHERE NULL AND 1 = 2")
  }

  @Test func `NULL OR a false term is UNKNOWN, selecting no rows`() throws {
    // Kleene OR: UNKNOWN OR FALSE = UNKNOWN.
    try flags().empty("SELECT Id FROM T WHERE NULL OR 1 = 2")
  }

  @Test func `a bare boolean column keeps only its TRUE rows`() throws {
    // `Flag` bridges to `Flag = TRUE`: the FALSE row is FALSE and the NULL row
    // UNKNOWN, so only the definite TRUE row (Id 1) passes.
    try flags().expect("SELECT Id FROM T WHERE Flag", yields: [[1]])
  }

  @Test func `NOT of a bare boolean column keeps only its FALSE rows`() throws {
    // `NOT (Flag = TRUE)`: the TRUE row is dropped, the FALSE row kept, and the
    // NULL row (NOT UNKNOWN = UNKNOWN) dropped — only Id 2 passes.
    try flags().expect("SELECT Id FROM T WHERE NOT Flag", yields: [[2]])
  }

  @Test func `a parenthesised bare NULL selects no rows`() throws {
    try flags().empty("SELECT Id FROM T WHERE (NULL)")
  }

  @Test func `a parenthesised bare boolean column keeps its TRUE rows`()
      throws {
    try flags().expect("SELECT Id FROM T WHERE (Flag)", yields: [[1]])
  }

  @Test func `a bare boolean column agrees with the explicit = TRUE`() throws {
    // The desugar's promise: the bare form is exactly `Flag = TRUE`.
    try flags().expect("SELECT Id FROM T WHERE Flag",
                       equals: "SELECT Id FROM T WHERE Flag = TRUE")
  }

  @Test func `a bare boolean predicand in HAVING filters the groups`() throws {
    // A bare predicand is a predicate in every filtering position: HAVING keeps
    // only the TRUE group.
    try flags().expect("SELECT Flag FROM T GROUP BY Flag HAVING Flag",
                       yields: [[true]])
  }

  @Test func `a bare NULL predicand in HAVING drops every group`() throws {
    try flags().empty("SELECT Id FROM T GROUP BY Id HAVING NULL")
  }

  @Test func `a non-boolean bare predicand does not fault, matching = TRUE`()
      throws {
    // A non-boolean operand does not fault: the engine compares it cross-kind
    // against the boolean literal, a definite non-match, exactly as the
    // explicit `Age = TRUE` does — so both select no rows and agree.
    try flags().empty("SELECT Id FROM T WHERE Age")
    try flags().expect("SELECT Id FROM T WHERE Age",
                       equals: "SELECT Id FROM T WHERE Age = TRUE")
  }

  @Test func `the run and schema paths agree on a bare predicand`() throws {
    // `columns(of:)` (schema-only) accepts the new predicate form on the same
    // footing the run path does — neither faults — so a `WHERE`/`HAVING` bare
    // predicand keeps typecheck↔run parity.
    _ = try flags().columns(of: parse(query: "SELECT Id FROM T WHERE NULL"))
    _ = try flags().columns(of: parse(query: "SELECT Id FROM T WHERE Flag"))
    _ = try flags().columns(of:
        parse(query: "SELECT Flag FROM T GROUP BY Flag HAVING Flag"))
  }
}
