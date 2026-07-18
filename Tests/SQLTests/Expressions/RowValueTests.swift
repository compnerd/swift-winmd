// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising ISO row-value constructors in comparisons and `IN`:
/// two integer keys `A` and `B` (each `NULL` in some rows, so the three-valued
/// corners — a NULL component on either side — are reachable) and a third `C`
/// for the n-ary (three-element) row cases. Every column mirrors another
/// column, so a row-of-columns comparison (`(A, B) = (C, …)`) is exercisable
/// alongside row-of-literal comparisons.
private func pairs() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "A": .integer, "B": .integer,
                   "C": .integer]) {
      Row(1, 1, 2, 3)
      Row(2, 1, 3, 3)
      Row(3, 2, 2, 2)
      Row(4, 1, nil, 3)
      Row(5, nil, 2, 3)
    }
  }
}

// MARK: - Parsing

struct RowValueParsingTests {
  @Test func `a row equality parses a first-class rows node`() throws {
    // `(A, B) = (C, Id)` parses to the FIRST-CLASS `Predicate.rows` node
    // holding both rows' component expressions once — NOT a desugared
    // conjunction of scalar comparisons (which duplicated a component). The
    // componentwise semantics live in the lowering, not the AST.
    let select = try parse(select: "SELECT * FROM T WHERE (A, B) = (C, Id)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B")], .equal,
                         [.column("C"), .column("Id")]))
  }

  @Test func `a row inequality parses a rows node carrying the operator`()
      throws {
    let select = try parse(select: "SELECT * FROM T WHERE (A, B) <> (C, Id)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B")], .unequal,
                         [.column("C"), .column("Id")]))
  }

  @Test func `a row less-than parses a rows node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE (A, B) < (C, Id)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B")], .lt,
                         [.column("C"), .column("Id")]))
  }

  @Test func `a row less-or-equal parses a rows node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE (A, B) <= (C, Id)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B")], .leq,
                         [.column("C"), .column("Id")]))
  }

  @Test func `a row greater-than parses a rows node`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE (A, B) > (C, Id)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B")], .gt,
                         [.column("C"), .column("Id")]))
  }

  @Test func `a three-element row parses a rows node of three components`()
      throws {
    // The n-ary shape parses to one `rows` node holding all three components
    // per side, not a nested cascade — the generalisation is in the lowering.
    let select =
        try parse(select: "SELECT * FROM T WHERE (A, B, C) < (1, 2, 3)")
    #expect(select.predicate
                == .rows([.column("A"), .column("B"), .column("C")], .lt,
                         [.literal(.integer(1)), .literal(.integer(2)),
                          .literal(.integer(3))]))
  }

  @Test func `a row IN parses a first-class among node`() throws {
    // `(A, B) IN ((1, 2), (2, 2))` parses to the FIRST-CLASS `Predicate.among`
    // node holding the left row and each element row once — NOT a desugared
    // disjunction of row equalities.
    let select =
        try parse(select: "SELECT * FROM T WHERE (A, B) IN ((1, 2), (2, 2))")
    #expect(select.predicate
                == .among([.column("A"), .column("B")],
                          [[.literal(.integer(1)), .literal(.integer(2))],
                           [.literal(.integer(2)), .literal(.integer(2))]],
                          negated: false))
  }

  @Test func `a row NOT IN parses an among node marked negated`() throws {
    let select =
        try parse(select: "SELECT * FROM T WHERE (A, B) NOT IN ((1, 2))")
    #expect(select.predicate
                == .among([.column("A"), .column("B")],
                          [[.literal(.integer(1)), .literal(.integer(2))]],
                          negated: true))
  }

  @Test func `a single parenthesised scalar stays a scalar comparison`()
      throws {
    // No comma inside the parentheses, so `(A) = B` is an ordinary scalar
    // comparison, NOT a one-element row — the disambiguation rule.
    let select = try parse(select: "SELECT * FROM T WHERE (A) = B")
    #expect(select.predicate
                == .comparison(left: .column("A"), op: .equal,
                               right: .column("B")))
  }

  @Test func `a parenthesised arithmetic operand stays a scalar comparison`()
      throws {
    let select = try parse(select: "SELECT * FROM T WHERE (A + 1) = B")
    #expect(select.predicate
                == .comparison(left: .binary(.add, .column("A"),
                                             .literal(.integer(1))),
                               op: .equal, right: .column("B")))
  }

  @Test func `a parenthesised predicate is unaffected by row detection`()
      throws {
    // A comma-free group holding a predicate (`(A = 1 AND B = 2)`) still parses
    // as a parenthesised predicate — `row()` rewinds, and the existing
    // comparison / predicate rewind resolves it.
    let select = try parse(select: "SELECT * FROM T WHERE (A = 1 AND B = 2)")
    #expect(select.predicate
                == .and(.comparison(left: .column("A"), op: .equal,
                                    right: .literal(.integer(1))),
                        .comparison(left: .column("B"), op: .equal,
                                    right: .literal(.integer(2)))))
  }

  @Test func `a parenthesised NOT predicate falls through to the predicate`()
      throws {
    // The `(` is followed by `NOT`, a token that cannot begin an expression, so
    // the speculative row probe's first-element parse fails: `row()` catches
    // it, rewinds, and returns `nil`, and the parenthesised-predicate path
    // resolves `(NOT A = 1)` — the regression the fix restores.
    let select = try parse(select: "SELECT * FROM T WHERE (NOT A = 1)")
    #expect(select.predicate
                == .not(.comparison(left: .column("A"), op: .equal,
                                    right: .literal(.integer(1)))))
  }

  @Test func `a parenthesised EXISTS falls through to the predicate`()
      throws {
    // `(EXISTS (…))` opens on `EXISTS`, which cannot begin an expression, so
    // the row probe rewinds and the parenthesised-predicate path parses the
    // nested EXISTS — again a form the pre-fix eager probe rejected.
    let select =
        try parse(select: "SELECT * FROM T WHERE (EXISTS (SELECT Id FROM T))")
    let inner = try parse(query: "SELECT Id FROM T")
    #expect(select.predicate == .exists(inner, negated: false))
  }

  @Test func `a parenthesised scalar comparison stays a predicate`()
      throws {
    // `(A = 1)` holds a scalar comparison, not a row (no comma): the probe
    // parses `A`, finds no comma, rewinds, and the predicate path resolves it.
    let select = try parse(select: "SELECT * FROM T WHERE (A = 1)")
    #expect(select.predicate
                == .comparison(left: .column("A"), op: .equal,
                               right: .literal(.integer(1))))
  }

  @Test func `a mismatched row arity faults`() {
    #expect(throws: SQLError.arity(3, 2)) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE (A, B, C) = (1, 2)")
    }
  }

  @Test func `a mismatched row IN arity faults`() {
    #expect(throws: SQLError.arity(2, 3)) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE (A, B) IN ((1, 2, 3))")
    }
  }
}

// MARK: - Evaluation

struct RowValueEvaluationTests {
  @Test func `a row equality matches on every component`() throws {
    // Row 3 has A = 2, B = 2, so `(A, B) = (2, 2)` holds only there.
    try pairs().expect("SELECT Id FROM T WHERE (A, B) = (2, 2)",
                       yields: [[3]])
  }

  @Test func `a row equality against columns compares componentwise`() throws {
    // `(A, C) = (1, 3)` — A = 1 and C = 3 hold in rows 1, 2, and 4.
    try pairs().expect("SELECT Id FROM T WHERE (A, C) = (1, 3)",
                       yields: [[1], [2], [4]])
  }

  @Test func `a row inequality is the negation of equality`() throws {
    // `(A, B) <> (1, 2)` keeps every row whose (A, B) is definitely not (1, 2);
    // rows 4 (B NULL) and 5 (A NULL) are UNKNOWN and dropped.
    try pairs().expect("SELECT Id FROM T WHERE (A, B) <> (1, 2)",
                       yields: [[2], [3]])
  }

  @Test func `a row less-than orders lexicographically on the first component`()
      throws {
    // First component decides when it differs: `(A, B) < (2, 0)` — A < 2 admits
    // rows 1, 2, 4 (A = 1); row 3 (A = 2) needs B < 0, false; row 5 (A NULL) is
    // UNKNOWN.
    try pairs().expect("SELECT Id FROM T WHERE (A, B) < (2, 0)",
                       yields: [[1], [2], [4]])
  }

  @Test func `a row less-than falls to a later component on a tie`() throws {
    // `(A, B) < (1, 3)` — the first component ties at A = 1 for rows 1, 2, 4,
    // so the second decides: row 1 (B = 2) admits, row 2 (B = 3) does not, row
    // 4 (B NULL) is UNKNOWN. Rows 3 (A = 2) and 5 (A NULL) never tie in.
    try pairs().expect("SELECT Id FROM T WHERE (A, B) < (1, 3)",
                       yields: [[1]])
  }

  @Test func `a row less-or-equal admits the all-equal row`() throws {
    // `(A, B) <= (1, 2)` — the strict `<` rows (none below (1, 2) here) plus
    // the equal row 1 (A = 1, B = 2).
    try pairs().expect("SELECT Id FROM T WHERE (A, B) <= (1, 2)",
                       yields: [[1]])
  }

  @Test func `a row greater-than mirrors the ordering`() throws {
    // `(A, B) > (1, 2)` — row 2 (A = 1 ties, B = 3 > 2) and row 3 (A = 2 > 1);
    // row 1 is equal (not greater), rows 4/5 UNKNOWN.
    try pairs().expect("SELECT Id FROM T WHERE (A, B) > (1, 2)",
                       yields: [[2], [3]])
  }

  @Test func `a row greater-or-equal admits the all-equal row`() throws {
    try pairs().expect("SELECT Id FROM T WHERE (A, B) >= (1, 2)",
                       yields: [[1], [2], [3]])
  }

  @Test func `a three-element row compares componentwise`() throws {
    // `(A, B, C) = (2, 2, 2)` holds only in row 3.
    try pairs().expect("SELECT Id FROM T WHERE (A, B, C) = (2, 2, 2)",
                       yields: [[3]])
  }

  @Test func `a three-element row orders lexicographically`() throws {
    // `(A, B, C) < (1, 3, 0)` — A < 1 (none), tie A = 1 then B < 3 (rows 1, 4
    // have B = 2 / NULL): row 1 admits, row 4 (B NULL) UNKNOWN; row 2 ties B =
    // 3 then needs C < 0 (false).
    try pairs().expect("SELECT Id FROM T WHERE (A, B, C) < (1, 3, 0)",
                       yields: [[1]])
  }

  @Test func `a row IN admits a matching row literal`() throws {
    // `(A, B) IN ((1, 2), (2, 2))` matches row 1 (1, 2) and row 3 (2, 2).
    try pairs().expect("SELECT Id FROM T WHERE (A, B) IN ((1, 2), (2, 2))",
                       yields: [[1], [3]])
  }

  @Test func `a row IN rejects a non-matching set`() throws {
    try pairs().expect("SELECT Id FROM T WHERE (A, B) IN ((9, 9), (8, 8))",
                       yields: [])
  }

  @Test func `a row NOT IN admits the complement`() throws {
    // `(A, B) NOT IN ((1, 2))` — rows definitely not (1, 2); rows 4/5 have a
    // NULL component making the membership UNKNOWN, so they are dropped.
    try pairs().expect("SELECT Id FROM T WHERE (A, B) NOT IN ((1, 2))",
                       yields: [[2], [3]])
  }

  @Test func `a parenthesised NOT predicate evaluates as the negated scalar`()
      throws {
    // `(NOT A = 1)` keeps the rows where A is definitely not 1 — row 3 (A = 2);
    // row 5 (A NULL) is UNKNOWN and dropped. Proves the fall-through parses AND
    // evaluates, not merely parses.
    try pairs().expect("SELECT Id FROM T WHERE (NOT A = 1)", yields: [[3]])
  }

  @Test func `a parenthesised EXISTS predicate evaluates over the subquery`()
      throws {
    // `(EXISTS (SELECT …))` is TRUE for every outer row since T is non-empty,
    // so all five rows survive — the parenthesised nested EXISTS runs.
    try pairs().expect("SELECT Id FROM T WHERE (EXISTS (SELECT Id FROM T))",
                       yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a parenthesised scalar comparison evaluates as the comparison`()
      throws {
    // `(A = 1)` and `A = 1` select the same rows — the parentheses are
    // grouping, not a one-element row.
    try pairs().expect("SELECT Id FROM T WHERE (A = 1)",
                       equals: "SELECT Id FROM T WHERE A = 1")
  }

  @Test func `a row IN folds like an OR of row equalities`() throws {
    try pairs().expect(
        "SELECT Id FROM T WHERE (A, B) IN ((1, 2), (2, 2))",
        equals: "SELECT Id FROM T WHERE (A = 1 AND B = 2) "
              + "OR (A = 2 AND B = 2)")
  }
}

// MARK: - Three-valued NULL

struct RowValueNullTests {
  @Test func `a NULL component makes an otherwise-equal row UNKNOWN`() throws {
    // `(1, NULL) = (1, 2)` → `1 = 1 AND NULL = 2` → TRUE AND UNKNOWN → UNKNOWN,
    // so the row is DROPPED, not admitted. Row 4 is (A = 1, B = NULL).
    try pairs().empty("SELECT Id FROM T WHERE (A, B) = (1, 2) AND Id = 4")
  }

  @Test func `a definite component mismatch dominates a NULL component`()
      throws {
    // `(1, NULL) = (2, 2)` → `1 = 2 AND NULL = 2` → FALSE AND UNKNOWN → FALSE,
    // a DEFINITE non-match: the row is dropped by `=` (and would be ADMITTED by
    // `<>`, since NOT FALSE is TRUE). Row 4 is (1, NULL).
    try pairs().empty("SELECT Id FROM T WHERE (A, B) = (2, 2) AND Id = 4")
    try pairs().expect("SELECT Id FROM T WHERE (A, B) <> (2, 2) AND Id = 4",
                       yields: [[4]])
  }

  @Test func `a NULL in a later lexicographic component is UNKNOWN`() throws {
    // Row 4 is (A = 1, B = NULL): `(1, 2) < (A, B)` → `1 < 1 OR (1 = 1 AND 2 <
    // NULL)` → FALSE OR (TRUE AND UNKNOWN) → UNKNOWN, so the row whose deciding
    // right-hand component is NULL is dropped — the lexicographic cascade keeps
    // the ISO 3VL rather than reading the NULL as a definite ordering.
    try pairs().empty("SELECT Id FROM T WHERE (1, 2) < (A, B) AND Id = 4")
  }

  @Test func `a NULL in the deciding component still resolves definitely`()
      throws {
    // `(1, NULL) < (2, 0)` → `1 < 2 OR …` → the FIRST component decides TRUE
    // before the NULL second is ever consulted (Kleene OR short-circuits on a
    // definite TRUE), so the row is admitted despite the NULL. Row 4 is (1,
    // NULL).
    try pairs().expect("SELECT Id FROM T WHERE (A, B) < (2, 0) AND Id = 4",
                       yields: [[4]])
  }

  @Test func `a row IN with a NULL component is UNKNOWN without a match`()
      throws {
    // Row 4 (1, NULL): `(1, NULL) IN ((1, 2))` → `1 = 1 AND NULL = 2` → UNKNOWN
    // — no definite match — so the row is dropped by IN and by NOT IN (the
    // negation of UNKNOWN is UNKNOWN).
    try pairs().empty("SELECT Id FROM T WHERE (A, B) IN ((1, 2)) AND Id = 4")
    try pairs().empty(
        "SELECT Id FROM T WHERE (A, B) NOT IN ((1, 2)) AND Id = 4")
  }

  @Test func `a row IN resolves definitely when another element matches`()
      throws {
    // Row 4 (1, NULL): `(1, NULL) IN ((1, 2), (9, 9))` is still UNKNOWN (no
    // element definitely matches), but row 1 (1, 2) matches the first element
    // definitely — proving a definite match resolves the disjunction to TRUE.
    try pairs().expect(
        "SELECT Id FROM T WHERE (A, B) IN ((1, 2), (9, 9))",
        yields: [[1]])
  }
}

// MARK: - Component evaluated once

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so the non-deterministic
/// `stepper()` routine registered against it both observes successive values
/// and records how many times the run invoked it. The engine evaluates a row's
/// predicate synchronously on one thread, so the box needs no lock.
private final class Counter: @unchecked Sendable {
  /// The number of times `next()` has been called.
  private(set) var count = 0

  /// Increments the count and returns the PREVIOUS value — the sequence `0, 1,
  /// 2, …` across successive calls.
  func next() -> Int {
    defer { count += 1 }
    return count
  }
}

/// The load-bearing regression for the first-class redesign: a row-value
/// component holding a STATEFUL call must be evaluated EXACTLY ONCE per row.
/// The old parse-time desugar named a component in several places — a `<`
/// cascade uses an earlier component in both a strict step and an equality
/// tie-guard, and a row `IN` copies the left row into each element's equality
/// — so `stepper()` ran twice and the two calls saw DIFFERENT values (0, 1),
/// admitting or dropping the wrong rows. The first-class nodes evaluate each
/// component once into a value the fold reuses, so the counter reads exactly 1
/// and the truth is computed over the single value (0).
struct RowValueOnceTests {
  /// A single-row table, so a per-row component runs once for the one row.
  private func one() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  /// A fresh non-deterministic `stepper()` over its own counter — non-
  /// deterministic so the optimiser cannot constant-fold it away, exposing the
  /// eval count.
  private func stepper(_ counter: Counter) throws -> Routines {
    try Routines()
        .registering("stepper", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
  }

  @Test func `a row IN evaluates a stateful component once`() throws {
    // Left row is `(stepper(), 0)` = `(0, 0)`. It matches NEITHER `(99, 0)` nor
    // `(1, 0)`, so no row is admitted — but ONLY if `stepper()` yields 0 in the
    // one evaluation the fold reads. The old desugar copied `stepper()` into
    // each element's equality: the first read 0 (no match against 99), the
    // SECOND read 1, wrongly matching `(1, 0)` and admitting the row. The
    // first-class node reads it once, so no row is admitted and the counter is
    // exactly 1.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 0) IN ((99, 0), "
                   + "(1, 0))", yields: [], routines: stepper(counter))
    #expect(counter.count == 1)
  }

  @Test func `a row less-than evaluates a stateful component once`() throws {
    // `(stepper(), 0) < (0, 1)` with `stepper()` = 0 is `0 < 0 OR (0 = 0 AND
    // 0 < 1)` = FALSE OR (TRUE AND TRUE) = TRUE, so the row is admitted. The
    // old cascade named the first component twice (the strict `stepper() < 0`
    // and the `stepper() = 0` tie-guard): the first read 0, the second read 1,
    // so the guard `1 = 0` was FALSE and the row was wrongly DROPPED. The
    // first-class node reads it once, admitting the row, counter exactly 1.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 0) < (0, 1)",
                     yields: [[1]], routines: stepper(counter))
    #expect(counter.count == 1)
  }

  @Test func `a row less-or-equal evaluates a stateful component once`()
      throws {
    // `(stepper(), 0) <= (0, 0)` with `stepper()` = 0 is the all-equal row,
    // TRUE via the innermost `<=`. The desugar's re-read (guard `1 = 0`) drops
    // it; the first-class node admits it, counter exactly 1.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 0) <= (0, 0)",
                     yields: [[1]], routines: stepper(counter))
    #expect(counter.count == 1)
  }

  @Test func `a row greater-than evaluates a stateful component once`() throws {
    // `(stepper(), 2) > (0, 1)` with `stepper()` = 0 is `0 > 0 OR (0 = 0 AND
    // 2 > 1)` = FALSE OR (TRUE AND TRUE) = TRUE. The desugar's guard re-read
    // (`1 = 0` FALSE) drops it; the first-class node admits it, counter one.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 2) > (0, 1)",
                     yields: [[1]], routines: stepper(counter))
    #expect(counter.count == 1)
  }

  @Test func `a row greater-or-equal evaluates a stateful component once`()
      throws {
    // `(stepper(), 0) >= (0, 0)` with `stepper()` = 0 is the all-equal row,
    // TRUE via the innermost `>=`. The desugar's re-read would drop it; the
    // first-class node admits it, counter exactly 1.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 0) >= (0, 0)",
                     yields: [[1]], routines: stepper(counter))
    #expect(counter.count == 1)
  }

  @Test func `a row equality evaluates a stateful component once`() throws {
    // `(stepper(), 0) = (0, 0)` with `stepper()` = 0 is TRUE. `=` reads each
    // component once even in the desugar, so this confirms the first-class node
    // preserves that — counter exactly 1.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 0) = (0, 0)",
                     yields: [[1]], routines: stepper(counter))
    #expect(counter.count == 1)
  }

  @Test func `a row inequality evaluates a stateful component once`() throws {
    // `(stepper(), 0) <> (9, 9)` with `stepper()` = 0 is NOT(FALSE) = TRUE.
    // `<>` is the negation of the componentwise equality, each read once —
    // counter exactly 1.
    let counter = Counter()
    try one().expect("SELECT Id FROM T WHERE (stepper(), 0) <> (9, 9)",
                     yields: [[1]], routines: stepper(counter))
    #expect(counter.count == 1)
  }
}

// MARK: - Reachability

/// The type-check reachability of a row comparison and a row `IN` must match
/// the executor's SHORT-CIRCUIT exactly as the scalar `.comparison`/
/// `.membership` do — a constant-false row guard folds an `AND` (leaving its
/// right arm unreachable and unvalidated), and a definite constant match in a
/// row `IN`'s element list prunes every later element. Folding TOO MUCH would
/// accept an invalid query, so only a ROW-INDEPENDENT (all-constant) guard that
/// DEFINITELY settles a branch prunes it; a row-dependent guard stays reachable
/// and is still validated. A text column `Name` makes `Name + 1` a REAL type
/// fault (`operands must be numeric`) wherever it is reached.
struct RowValueReachabilityTests {
  /// A relation with a TEXT column `Name`, so `Name + 1` is a genuine type
  /// error wherever the reachability walk reaches it — the probe the pruning
  /// tests turn on.
  private func texts() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "Name": .text]) {
        Row(1, "a")
        Row(2, "b")
      }
    }
  }

  // MARK: Unreachable — must NOT reject

  @Test func `a constant match in a row IN prunes a later bad element`()
      throws {
    // `(1, 2) IN ((1, 2), (Name + 1, 3))`: the constant left `(1, 2)`
    // DEFINITELY matches the first element, so `Filter.memberships`
    // short-circuits and the second element's `Name + 1` (text arithmetic) is
    // unreachable — the type check must not validate it, and the run keeps
    // every row.
    let query = try parse(query:
        "SELECT Id FROM T WHERE (1, 2) IN ((1, 2), (Name + 1, 3))")
    _ = try texts().columns(of: query, validate: true)
    try texts().expect(
        "SELECT Id FROM T WHERE (1, 2) IN ((1, 2), (Name + 1, 3))",
        yields: [[1], [2]])
  }

  @Test func `a constant-false row guard makes the AND right arm unreachable`()
      throws {
    // `(1, 2) = (3, 4) AND Name + 1 = 0`: the left conjunct folds DEFINITELY
    // FALSE (a row `=` over constants), so the executor's `AND` short-circuits
    // and `Name + 1` is unreachable — the type check must not validate it, and
    // the run yields no rows.
    let query = try parse(query:
        "SELECT Id FROM T WHERE (1, 2) = (3, 4) AND Name + 1 = 0")
    _ = try texts().columns(of: query, validate: true)
    try texts().empty("SELECT Id FROM T WHERE (1, 2) = (3, 4) AND Name + 1 = 0")
  }

  @Test func `a constant-false row inequality guard prunes the AND right arm`()
      throws {
    // `(1, 2) <> (1, 2) AND Name + 1 = 0`: a row `<>` over equal constants
    // folds DEFINITELY FALSE (the negation of the all-TRUE `=`), so the `AND`
    // short-circuits and `Name + 1` is unreachable and unvalidated.
    let query = try parse(query:
        "SELECT Id FROM T WHERE (1, 2) <> (1, 2) AND Name + 1 = 0")
    _ = try texts().columns(of: query, validate: true)
    try texts().empty(
        "SELECT Id FROM T WHERE (1, 2) <> (1, 2) AND Name + 1 = 0")
  }

  @Test func `a constant-true row guard makes the OR right arm unreachable`()
      throws {
    // `(1, 2) = (1, 2) OR Name + 1 = 0`: the left disjunct folds DEFINITELY
    // TRUE, so the executor's `OR` short-circuits and `Name + 1` is
    // unreachable — the type check must not validate it (mirroring the scalar
    // `1 = 1 OR …`), and the run keeps every row.
    let query = try parse(query:
        "SELECT Id FROM T WHERE (1, 2) = (1, 2) OR Name + 1 = 0")
    _ = try texts().columns(of: query, validate: true)
    try texts().expect(
        "SELECT Id FROM T WHERE (1, 2) = (1, 2) OR Name + 1 = 0",
        yields: [[1], [2]])
  }

  // MARK: Reachable — must still fault

  @Test func `no constant match in a row IN leaves a bad element reachable`() {
    // `(1, 2) IN ((3, 4), (Name + 1, 5))`: no element DEFINITELY matches the
    // constant left, so the second element stays reachable — the pruning is
    // PRECISE — and its `Name + 1` must still fault the type check, exactly as
    // the run would when it evaluates the second row equality.
    let query = try! parse(query:
        "SELECT Id FROM T WHERE (1, 2) IN ((3, 4), (Name + 1, 5))")
    let resolve = { () throws -> Array<OutputColumn> in
      try texts().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a constant-true row guard leaves the AND right arm reachable`() {
    // `(1, 2) = (1, 2) AND Name + 1 = 0`: the left conjunct folds DEFINITELY
    // TRUE, so the `AND` does NOT short-circuit and `Name + 1` is reachable —
    // it must still fault the type check, matching the run.
    let query = try! parse(query:
        "SELECT Id FROM T WHERE (1, 2) = (1, 2) AND Name + 1 = 0")
    let resolve = { () throws -> Array<OutputColumn> in
      try texts().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a bad component in a reachable row comparison faults`() {
    // `(1, Name + 1) = (1, 2)`: a row `=` evaluates ALL its components at
    // runtime (`compare` reads both whole rows before folding), so `Name + 1`
    // is reachable and must fault the type check — the `check` `.rows` arm
    // validates every component, unchanged.
    let query = try! parse(query:
        "SELECT Id FROM T WHERE (1, Name + 1) = (1, 2)")
    let resolve = { () throws -> Array<OutputColumn> in
      try texts().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }
}
