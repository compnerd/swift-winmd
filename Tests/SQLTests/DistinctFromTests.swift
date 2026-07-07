// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising `IS [NOT] DISTINCT FROM`: two integer columns `K` and
/// `L`, each `NULL` in some rows, so the null-safe corners (both NULL, exactly
/// one NULL) are reachable by comparing columns — SQL has no bare `NULL`
/// literal in expression position, so a NULL operand is spelled as a NULL cell.
/// Row 5 is both-NULL, rows 3 and 4 are one-NULL, rows 1 and 2 are non-NULL.
private func things() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer, "L": .integer]) {
      Row(1, 5, 5)
      Row(2, 1, 2)
      Row(3, 5, nil)
      Row(4, nil, 7)
      Row(5, nil, nil)
    }
  }
}

/// Parses `text` and returns its `Select`, failing on any other shape.
private func parse(select text: String) throws -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

// MARK: - Parsing

struct DistinctFromParsingTests {
  @Test func `IS DISTINCT FROM parses to a first-class node`() throws {
    // `a IS DISTINCT FROM b` is a first-class `Predicate.distinct` holding both
    // operands as plain expressions — no `:parameter` form is defined for it.
    let select =
        try parse(select: "SELECT * FROM T WHERE K IS DISTINCT FROM 5")
    #expect(select.predicate
                == .distinct(.column("K"), .literal(.integer(5)),
                             negated: false))
  }

  @Test func `IS NOT DISTINCT FROM parses to a negated first-class node`()
      throws {
    // `a IS NOT DISTINCT FROM b` is the same node, `negated` — null-safe
    // equality.
    let select =
        try parse(select: "SELECT * FROM T WHERE K IS NOT DISTINCT FROM 5")
    #expect(select.predicate
                == .distinct(.column("K"), .literal(.integer(5)),
                             negated: true))
  }

  @Test func `both operands are ordinary expressions`() throws {
    // Neither side is special — a column against a column parses too.
    let select =
        try parse(select: "SELECT * FROM T WHERE K IS DISTINCT FROM Id")
    #expect(select.predicate
                == .distinct(.column("K"), .column("Id"), negated: false))
  }
}

// MARK: - Evaluation

struct DistinctFromEvaluationTests {
  @Test func `equal non-null values are NOT DISTINCT`() throws {
    // Row 1's K is 5 — equal to 5, so `K IS DISTINCT FROM 5` is FALSE and the
    // row is dropped; the unequal and NULL Ks stay DISTINCT.
    try things().expect("SELECT Id FROM T WHERE K IS DISTINCT FROM 5",
                        yields: [[2], [4], [5]])
  }

  @Test func `equal non-null values match NOT DISTINCT`() throws {
    // The complement: `K IS NOT DISTINCT FROM 5` keeps only the rows whose K
    // equals 5 — rows 1 and 3.
    try things().expect("SELECT Id FROM T WHERE K IS NOT DISTINCT FROM 5",
                        yields: [[1], [3]])
  }

  @Test func `exactly one NULL operand is DISTINCT`() throws {
    // Row 3 (K = 5, L = NULL) and row 4 (K = NULL, L = 7) each pair a NULL with
    // a non-NULL, so `K IS DISTINCT FROM L` is TRUE for them — a NULL differs
    // from a non-NULL — where `K = L` would be UNKNOWN and drop them. Row 2
    // (1 vs 2) also differs; rows 1 (equal) and 5 (both NULL) do not.
    try things().expect("SELECT Id FROM T WHERE K IS DISTINCT FROM L",
                        yields: [[2], [3], [4]])
  }

  @Test func `both NULL operands are NOT DISTINCT`() throws {
    // Row 5 has both K and L NULL; two NULLs are the SAME, so `K IS NOT DISTINCT
    // FROM L` keeps it — alongside the equal-valued row 1 — where the null-safe
    // equality `K = L` (UNKNOWN on any NULL) could never keep the both-NULL row.
    try things().expect("SELECT Id FROM T WHERE K IS NOT DISTINCT FROM L",
                        yields: [[1], [5]])
  }

  @Test func `a non-null against a NULL cell is DISTINCT`() throws {
    // Row 3's L is NULL against a non-NULL K, so `L IS DISTINCT FROM K` keeps
    // it; the both-NULL row 5 is NOT DISTINCT and the equal row 1 is not.
    try things().expect("SELECT Id FROM T WHERE L IS DISTINCT FROM K",
                        yields: [[2], [3], [4]])
  }

  @Test func `column against itself is null-safe`() throws {
    // `K IS NOT DISTINCT FROM K` is TRUE on EVERY row, NULL rows included — a
    // NULL equals itself under null-safe equality, where `K = K` would be
    // UNKNOWN (and drop) on the NULL-K rows 4 and 5.
    try things().expect("SELECT Id FROM T WHERE K IS NOT DISTINCT FROM K",
                        yields: [[1], [2], [3], [4], [5]])
  }
}

// MARK: - Cross-kind

struct DistinctFromCrossKindTests {
  @Test func `a cross-kind pair is DISTINCT`() throws {
    // Integer `K` against the text `'5'` is a cross-kind pair — the engine's
    // `matches` yields FALSE for cross-kind equality, so the two DIFFER — and
    // `K IS DISTINCT FROM '5'` keeps every non-NULL K (rows 1, 2, 3) and the
    // NULL Ks too (a NULL differs from a non-NULL text).
    try things().expect("SELECT Id FROM T WHERE K IS DISTINCT FROM '5'",
                        yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a cross-kind pair is never NOT DISTINCT`() throws {
    // Its complement keeps nothing: no integer K is null-safe EQUAL to the text
    // `'5'` (cross-kind is DISTINCT), so `K IS NOT DISTINCT FROM '5'` is FALSE
    // on every row.
    try things().empty("SELECT Id FROM T WHERE K IS NOT DISTINCT FROM '5'")
  }
}

// MARK: - Two-valued semantics

struct DistinctFromTwoValuedTests {
  @Test func `IS DISTINCT FROM and IS NOT DISTINCT FROM partition the rows`()
      throws {
    // The predicate is TWO-VALUED — never UNKNOWN — so on EVERY row exactly one
    // of the two spellings holds and neither is UNKNOWN. `K IS NOT DISTINCT FROM
    // 5` keeps rows 1 and 3 (K = 5); `K IS DISTINCT FROM 5` keeps the OTHER
    // three — rows 2, 4, 5 — including the NULL-K rows a `=` would leave
    // UNKNOWN, so together they cover all five rows disjointly.
    try things().expect("SELECT Id FROM T WHERE K IS NOT DISTINCT FROM 5",
                        yields: [[1], [3]])
    try things().expect("SELECT Id FROM T WHERE K IS DISTINCT FROM 5",
                        yields: [[2], [4], [5]])
  }

  @Test func `a NULL operand never makes the row UNKNOWN`() throws {
    // Contrast with `=`: `K = 5` is UNKNOWN on the NULL-K rows and drops them,
    // so it keeps FEWER rows than `K IS NOT DISTINCT FROM 5`. The null-safe form
    // keeps rows 1 and 3 (K = 5) and, unlike `=`, is DEFINITELY FALSE (not
    // UNKNOWN) on the NULL-K rows rather than erroring or admitting them.
    try things().expect("SELECT Id FROM T WHERE K = 5", yields: [[1], [3]])
    try things().expect("SELECT Id FROM T WHERE K IS NOT DISTINCT FROM 5",
                        yields: [[1], [3]])
  }

  @Test func `NOT of a NULL-operand comparison keeps it while NOT DISTINCT does`()
      throws {
    // `NOT (K = 5)` is still UNKNOWN on the NULL-K rows (NOT of UNKNOWN is
    // UNKNOWN), so it keeps only the definite-unequal row 2 — whereas `K IS
    // DISTINCT FROM 5` is two-valued and additionally keeps the NULL-K rows 4
    // and 5.
    try things().expect("SELECT Id FROM T WHERE NOT (K = 5)", yields: [[2]])
    try things().expect("SELECT Id FROM T WHERE K IS DISTINCT FROM 5",
                        yields: [[2], [4], [5]])
  }
}

// MARK: - Constant folding

struct DistinctFromFoldingTests {
  /// The `Id`s of every fixture row — a constant-TRUE `WHERE` keeps them all.
  private let all = [[1], [2], [3], [4], [5]]

  @Test func `a constant DISTINCT folds true and keeps every row`() throws {
    // `1 IS DISTINCT FROM 2` folds to a constant TRUE, kept on every row.
    try things().expect("SELECT Id FROM T WHERE 1 IS DISTINCT FROM 2",
                        yields: all)
  }

  @Test func `a constant NOT DISTINCT of equal folds true`() throws {
    // `1 IS NOT DISTINCT FROM 1` folds TRUE.
    try things().expect("SELECT Id FROM T WHERE 1 IS NOT DISTINCT FROM 1",
                        yields: all)
  }

  @Test func `a constant both-NULL folds NOT DISTINCT`() throws {
    // `NULLIF(1, 1)` folds to a constant NULL, so both operands fold NULL — the
    // SAME — and `NULLIF(1, 1) IS DISTINCT FROM NULLIF(1, 1)` folds FALSE
    // (dropping every row) and its negation TRUE.
    try things().empty(
        "SELECT Id FROM T WHERE NULLIF(1, 1) IS DISTINCT FROM NULLIF(1, 1)")
    try things().expect(
        "SELECT Id FROM T WHERE NULLIF(1, 1) IS NOT DISTINCT FROM NULLIF(1, 1)",
        yields: all)
  }

  @Test func `a constant one-NULL folds DISTINCT`() throws {
    // Exactly one NULL is DISTINCT, so `1 IS DISTINCT FROM NULLIF(2, 2)` — the
    // second folding to NULL — folds TRUE.
    try things().expect(
        "SELECT Id FROM T WHERE 1 IS DISTINCT FROM NULLIF(2, 2)", yields: all)
  }
}
