// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising `IS [NOT] TRUE/FALSE/UNKNOWN`: a nullable BOOLEAN
/// column `Flag` covering all three truth values (TRUE, FALSE, and a NULL row
/// whose UNKNOWN corner the test collapses to a definite result), beside the
/// integer columns `A`/`B` a comparison predicate tests and a nullable integer
/// `N` (NULL in every row) an UNKNOWN comparison reads.
private func flags() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "Flag": .boolean,
                   "A": .integer, "B": .integer, "N": .integer]) {
      Row(1, true, 2, 1, nil)
      Row(2, false, 1, 2, nil)
      Row(3, nil, 1, 1, nil)
    }
  }
}

/// The boolean predicate a bare boolean operand `x` bridges to — the comparison
/// `x = TRUE`, whose three-valued truth IS `x`'s boolean value — the inner
/// `Predicate` a column truth test wraps.
private func boolean(_ column: Column) -> Predicate {
  .comparison(left: .column(column), op: .equal,
              right: .literal(.boolean(true)))
}

// MARK: - Parsing

struct TruthTestParsingTests {
  @Test func `IS TRUE parses to a truth node over the bridged operand`()
      throws {
    // `x IS TRUE` is a `Predicate.truth` whose inner is the bridge comparison
    // `x = TRUE` — the boolean operand as a predicate.
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS TRUE")
    #expect(select.predicate
                == .truth(boolean("Flag"), value: .true, negated: false))
  }

  @Test func `IS FALSE parses to a FALSE truth node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS FALSE")
    #expect(select.predicate
                == .truth(boolean("Flag"), value: .false, negated: false))
  }

  @Test func `IS UNKNOWN parses to an UNKNOWN truth node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS UNKNOWN")
    #expect(select.predicate
                == .truth(boolean("Flag"), value: .unknown, negated: false))
  }

  @Test func `IS NOT TRUE parses to a negated truth node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS NOT TRUE")
    #expect(select.predicate
                == .truth(boolean("Flag"), value: .true, negated: true))
  }

  @Test func `IS NOT FALSE parses to a negated FALSE truth node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS NOT FALSE")
    #expect(select.predicate
                == .truth(boolean("Flag"), value: .false, negated: true))
  }

  @Test func `IS NOT UNKNOWN parses to a negated UNKNOWN truth node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS NOT UNKNOWN")
    #expect(select.predicate
                == .truth(boolean("Flag"), value: .unknown, negated: true))
  }

  @Test func `IS NULL still parses to a null node, not a truth node`() throws {
    // The truth-value dispatch is ADDITIVE: an `IS NULL` tail is untouched, so
    // it lowers to the existing `null` predicate rather than a `truth`.
    let select = try parse(select: "SELECT * FROM T WHERE Flag IS NULL")
    #expect(select.predicate == .null(.column("Flag"), negated: false))
  }

  @Test func `a parenthesised comparison IS TRUE parses to a truth node`()
      throws {
    // `(a > b) IS TRUE` tests a parenthesised comparison predicate directly:
    // the inner `Predicate` is the comparison itself, not the `x = TRUE`
    // bridge.
    let select = try parse(select: "SELECT * FROM T WHERE (A > B) IS TRUE")
    #expect(select.predicate
                == .truth(.comparison(left: .column("A"), op: .gt,
                                      right: .column("B")),
                          value: .true, negated: false))
  }

  @Test func `a parenthesised comparison IS NOT FALSE parses negated`() throws {
    let select =
        try parse(select: "SELECT * FROM T WHERE (A > B) IS NOT FALSE")
    #expect(select.predicate
                == .truth(.comparison(left: .column("A"), op: .gt,
                                      right: .column("B")),
                          value: .false, negated: true))
  }
}

// MARK: - Evaluation over a nullable boolean column

struct TruthColumnEvaluationTests {
  // Fixture Flags: Id 1 → TRUE, Id 2 → FALSE, Id 3 → NULL (UNKNOWN).

  @Test func `IS TRUE keeps only the TRUE row`() throws {
    try flags().expect("SELECT Id FROM T WHERE Flag IS TRUE", yields: [[1]])
  }

  @Test func `IS FALSE keeps only the FALSE row`() throws {
    try flags().expect("SELECT Id FROM T WHERE Flag IS FALSE", yields: [[2]])
  }

  @Test func `IS UNKNOWN keeps only the NULL row`() throws {
    // The UNKNOWN Flag (Id 3) is TESTED for — a definite TRUE — while the
    // definite TRUE/FALSE rows are FALSE against `IS UNKNOWN`.
    try flags().expect("SELECT Id FROM T WHERE Flag IS UNKNOWN", yields: [[3]])
  }

  @Test func `IS NOT TRUE keeps the FALSE and UNKNOWN rows`() throws {
    // `IS NOT TRUE` is the negation: the FALSE row (Id 2) and the UNKNOWN row
    // (Id 3) both pass — an UNKNOWN operand is NOT TRUE, so the row is KEPT
    // (the key divergence from a bare `Flag`, which drops the UNKNOWN row).
    try flags().expect("SELECT Id FROM T WHERE Flag IS NOT TRUE",
                       yields: [[2], [3]])
  }

  @Test func `IS NOT FALSE keeps the TRUE and UNKNOWN rows`() throws {
    try flags().expect("SELECT Id FROM T WHERE Flag IS NOT FALSE",
                       yields: [[1], [3]])
  }

  @Test func `IS NOT UNKNOWN keeps the definite TRUE and FALSE rows`() throws {
    try flags().expect("SELECT Id FROM T WHERE Flag IS NOT UNKNOWN",
                       yields: [[1], [2]])
  }

  @Test func `IS TRUE agrees with the explicit boolean comparison`() throws {
    // `WHERE Flag IS TRUE` and `WHERE Flag = TRUE` agree — both admit only the
    // definite TRUE row — because `IS TRUE` is exactly the bridge comparison
    // the parser builds. `IS NOT TRUE`, though, is NOT `Flag = FALSE`: it also
    // keeps the UNKNOWN row (see the `IS NOT TRUE` test), the collapse of the
    // third value the plain comparison cannot express.
    try flags().expect("SELECT Id FROM T WHERE Flag IS TRUE",
                       equals: "SELECT Id FROM T WHERE Flag = TRUE")
  }
}

// MARK: - Evaluation over a comparison predicate

struct TruthComparisonEvaluationTests {
  // Fixture A/B: Id 1 → 2 > 1 (TRUE), Id 2 → 1 > 2 (FALSE), Id 3 → 1 > 1
  // (FALSE). No comparison here is UNKNOWN — both operands are non-null — so
  // the definite corners are exercised over a real predicate operand.

  @Test func `a comparison IS TRUE keeps the rows the comparison keeps`()
      throws {
    // `(A > B) IS TRUE` equals the bare comparison `A > B`: both keep Id 1.
    try flags().expect("SELECT Id FROM T WHERE (A > B) IS TRUE", yields: [[1]])
  }

  @Test func `a comparison IS FALSE keeps the rows the comparison rejects`()
      throws {
    try flags().expect("SELECT Id FROM T WHERE (A > B) IS FALSE",
                       yields: [[2], [3]])
  }

  @Test func `a comparison IS NOT TRUE is the complement of IS TRUE`() throws {
    try flags().expect("SELECT Id FROM T WHERE (A > B) IS NOT TRUE",
                       yields: [[2], [3]])
  }

  @Test func `a comparison IS TRUE equals the bare comparison`() throws {
    try flags().expect("SELECT Id FROM T WHERE (A > B) IS TRUE",
                       equals: "SELECT Id FROM T WHERE A > B")
  }

  @Test func `an UNKNOWN comparison IS UNKNOWN tests for that UNKNOWN`()
      throws {
    // `A > N` is UNKNOWN for EVERY row (the NULL `N` is unordered), so `(A > N)
    // IS UNKNOWN` is a definite TRUE for every row — keeping them all — and
    // `IS TRUE` drops them all. The truth test collapses the UNKNOWN comparison
    // to a definite two-valued answer, never itself UNKNOWN.
    try flags().expect("SELECT Id FROM T WHERE (A > N) IS UNKNOWN",
                       yields: [[1], [2], [3]])
  }

  @Test func `an UNKNOWN comparison IS TRUE drops every row`() throws {
    try flags().empty("SELECT Id FROM T WHERE (A > N) IS TRUE")
  }

  @Test func `an UNKNOWN comparison IS NOT TRUE keeps every row`() throws {
    // The negation of a per-row UNKNOWN `IS TRUE` (definite FALSE) is a
    // definite TRUE — so `IS NOT TRUE` keeps every row, unlike `NOT (A > N)`
    // which stays UNKNOWN and keeps none.
    try flags().expect("SELECT Id FROM T WHERE (A > N) IS NOT TRUE",
                       yields: [[1], [2], [3]])
  }
}

// MARK: - Result is never itself UNKNOWN

struct TruthDefiniteTests {
  @Test func `the test is definite where NOT of the operand is UNKNOWN`()
      throws {
    // The whole point: a boolean test yields a DEFINITE two-valued result. Over
    // the UNKNOWN Flag row (Id 3), `NOT (Flag = TRUE)` is UNKNOWN (dropped),
    // but `Flag IS NOT TRUE` is a definite TRUE (kept). If the test could be
    // UNKNOWN the two would agree; they diverge exactly because it cannot.
    try flags().expect("SELECT Id FROM T WHERE Flag IS NOT TRUE",
                       yields: [[2], [3]])
    try flags().expect("SELECT Id FROM T WHERE NOT (Flag = TRUE)",
                       yields: [[2]])
  }

  @Test func `IS TRUE and IS NOT TRUE partition every row`() throws {
    // Because neither is ever UNKNOWN, every row lands in exactly one — their
    // union is all three rows and their intersection is empty.
    try flags().expect("SELECT Id FROM T WHERE Flag IS TRUE", yields: [[1]])
    try flags().expect("SELECT Id FROM T WHERE Flag IS NOT TRUE",
                       yields: [[2], [3]])
  }
}

// MARK: - Constant folding

struct TruthConstantTests {
  /// A relation with a text `Name`, so `Name + 1` is a reachable operand fault.
  private func named() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "Name": .text]) {
        Row(1, "a")
        Row(2, "b")
      }
    }
  }

  @Test func `a constant-UNKNOWN IS TRUE folds FALSE and short-circuits`()
      throws {
    // `CASE WHEN 1 = 0 THEN TRUE END` is a ROW-INDEPENDENT UNKNOWN (no
    // reachable branch → NULL). `… IS TRUE` folds DEFINITELY FALSE, settling
    // the `AND` false WITHOUT validating the unreachable `Name + 1 = 0` (a
    // `.operand` fault over the text `Name`, if reached) — so `columns(of:)`
    // SUCCEEDS and the run drops every row. Before the fold distinguished a
    // constant UNKNOWN from a per-row `nil`, the whole `AND` read
    // row-dependent, the RHS was validated, and it faulted.
    let text = "SELECT Id FROM T "
        + "WHERE CASE WHEN 1 = 0 THEN TRUE END IS TRUE AND Name + 1 = 0"
    _ = try named().columns(of: parse(query: text))
    try named().empty(text)
  }

  @Test func `a constant-UNKNOWN IS UNKNOWN folds TRUE`() throws {
    // The same constant-UNKNOWN operand: `… IS UNKNOWN` is DEFINITELY TRUE, so
    // the WHERE keeps every row — the fold decides it rather than deferring.
    try named().expect(
        "SELECT Id FROM T WHERE CASE WHEN 1 = 0 THEN TRUE END IS UNKNOWN",
        yields: [[1], [2]])
  }

  @Test func `a two-valued inner IS UNKNOWN folds FALSE though row-dependent`()
      throws {
    // `Name IS NULL` READS a row yet is DEFINITE — an `IS NULL` test is never
    // itself UNKNOWN — so `… IS UNKNOWN` folds DEFINITELY FALSE regardless of
    // the rows (not just when the inner is row-INDEPENDENT), settling the `AND`
    // false WITHOUT validating the unreachable `Name + 1 = 0`. `columns(of:)`
    // SUCCEEDS and the run drops every row.
    let text = "SELECT Id FROM T "
        + "WHERE (Name IS NULL) IS UNKNOWN AND Name + 1 = 0"
    _ = try named().columns(of: parse(query: text))
    try named().empty(text)
  }

  @Test func `a two-valued inner IS NOT UNKNOWN folds TRUE though row-dependent`()
      throws {
    // `(Name IS NULL) IS NOT UNKNOWN` is DEFINITELY TRUE — the two-valued inner
    // never takes the UNKNOWN value — so the WHERE keeps every row.
    try named().expect(
        "SELECT Id FROM T WHERE (Name IS NULL) IS NOT UNKNOWN",
        yields: [[1], [2]])
  }
}
