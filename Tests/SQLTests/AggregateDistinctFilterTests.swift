// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// MARK: - Fixtures

/// An `Orders` relation of `Region`/`Amount` rows with deliberate duplicate
/// amounts and a NULL. The two regions and the repeated `Amount` values let a
/// `DISTINCT` set quantifier differ from an `ALL` one, and a `FILTER (WHERE …)`
/// gate a subset of the rows per group.
///
/// East amounts: 10, 10, 20 (one NULL) — three non-NULL rows, two distinct
/// values (10, 20). West amounts: 20, 20, 30 — three rows, two distinct values
/// (20, 30). Across both: 10, 10, 20, 20, 20, 30 (and one NULL) — six non-NULL
/// rows, three distinct values (10, 20, 30).
private func orders() throws -> FixtureCatalog {
  try Catalog {
    Relation("Orders", ["Region": .text, "Amount": .integer]) {
      Row("East", 10)
      Row("East", 10)
      Row("East", 20)
      Row("East", nil)
      Row("West", 20)
      Row("West", 20)
      Row("West", 30)
    }
  }
}

// MARK: - DISTINCT set quantifier

struct AggregateDistinctTests {
  @Test func `COUNT(DISTINCT x) counts each value once where COUNT(x) counts every row`() throws {
    // Six non-NULL amounts (10, 10, 20, 20, 20, 30), three distinct (10, 20,
    // 30): COUNT(Amount) is 6, COUNT(DISTINCT Amount) is 3.
    try orders().expect(
        "SELECT COUNT(Amount), COUNT(DISTINCT Amount) FROM Orders",
        yields: [[6, 3]])
  }

  @Test func `SUM(DISTINCT x) totals each distinct value once`() throws {
    // SUM(Amount) totals every non-NULL row: 10+10+20+20+20+30 = 110.
    // SUM(DISTINCT Amount) totals the distinct values once: 10+20+30 = 60.
    try orders().expect(
        "SELECT SUM(Amount), SUM(DISTINCT Amount) FROM Orders",
        yields: [[110, 60]])
  }

  @Test func `AVG(DISTINCT x) averages the distinct values`() throws {
    // AVG(DISTINCT Amount) is the distinct total 60 over the 3 distinct values
    // = 20.0 — real division to an approximate-numeric double.
    try orders().expect("SELECT AVG(DISTINCT Amount) FROM Orders",
                        yields: [[20.0]])
  }

  @Test func `DISTINCT is a no-op for MIN and MAX`() throws {
    // The least/greatest value is unchanged by duplicates, so a MIN/MAX honours
    // DISTINCT as a no-op — MIN 10, MAX 30 either way. The DISTINCT form
    // normalises the quantifier OFF, so it never builds the `seen` dedup set
    // (an O(1) streaming fold, not O(distinct-values) memory), yet must still
    // agree cell for cell with the plain form.
    try orders().expect("""
        SELECT MIN(DISTINCT Amount), MAX(DISTINCT Amount),
               MIN(Amount), MAX(Amount)
          FROM Orders
        """, yields: [[10, 30, 10, 30]])
  }

  @Test func `MIN and MAX DISTINCT agree with the plain form over duplicates`() throws {
    // A group whose extreme values (10 and 30) are DUPLICATED many times: the
    // MIN/MAX(DISTINCT) fold does not dedup (it keeps no `seen` set), so its
    // memory does not grow with the group, and its result matches the plain
    // MIN/MAX — the extreme is the same with or without duplicates. Grouped so
    // the fold runs per group, exercising the streaming path each time.
    try orders().expect("""
        SELECT Region, MIN(DISTINCT Amount), MAX(DISTINCT Amount),
               MIN(Amount), MAX(Amount)
          FROM Orders
          GROUP BY Region ORDER BY Region
        """, yields: [["East", 10, 20, 10, 20], ["West", 20, 30, 20, 30]])
  }

  @Test func `an explicit ALL quantifier folds every value`() throws {
    // `ALL` is the explicit default — COUNT(ALL Amount) equals COUNT(Amount).
    try orders().expect(
        "SELECT COUNT(ALL Amount), SUM(ALL Amount) FROM Orders",
        yields: [[6, 110]])
  }

  @Test func `DISTINCT dedups per group under GROUP BY`() throws {
    // East distinct amounts are 10, 20 (two); West distinct are 20, 30 (two).
    // The dedup is per group, so each region counts its own distinct values.
    try orders().expect("""
        SELECT Region, COUNT(DISTINCT Amount) FROM Orders
          GROUP BY Region ORDER BY Region
        """, yields: [["East", 2], ["West", 2]])
  }

  @Test func `COUNT(DISTINCT *) is rejected`() throws {
    // A set quantifier applies to a value, so `*` — the whole row — admits none;
    // the parser diagnoses `COUNT(DISTINCT *)`.
    #expect(throws: SQLError.self) {
      try orders().run(Statement(parsing:
          "SELECT COUNT(DISTINCT *) FROM Orders"))
    }
  }
}

/// A pair of one-column relations whose values CANONICALISE across the two
/// kinds: `Ints` holds the exact integers `Int.max` and `1`, `Reals` the double
/// `1.0` (equal to the integer `1` under `canonical`). Two views `UNION ALL`
/// them into a single `V` column mixing integer and double cells — `IntFirst`
/// with the integers before the double, `RealFirst` the reverse — so a
/// `SUM(DISTINCT …)` over either dedups `1` and `1.0` to one value while the
/// distinct integer total (`Int.max + 1`) overflows `Int`. An int-first order
/// must still WIDEN to the finite double a double-first order gives, the
/// order-independence a skipped double duplicate must not defeat.
private func mixed() throws -> FixtureCatalog {
  try Catalog {
    Relation("Ints", ["N": .integer]) {
      Row(Int.max)
      Row(1)
    }
    Relation("Reals", ["R": .double]) {
      Row(1.0)
    }
    try View("IntFirst",
             "SELECT N AS V FROM Ints UNION ALL SELECT R AS V FROM Reals",
             as: ["V"])
    try View("RealFirst",
             "SELECT R AS V FROM Reals UNION ALL SELECT N AS V FROM Ints",
             as: ["V"])
  }
}

// MARK: - DISTINCT numeric widening is order-independent

struct AggregateDistinctWideningTests {
  // The finite double both orders must yield: the distinct set is `{Int.max,
  // 1}` (the double `1.0` dedups with the integer `1`), whose integer total
  // `Int.max + 1` overflows `Int` but widens to this double.
  private let widened = Double(Int.max) + 1.0

  @Test func `SUM(DISTINCT) widens regardless of row order`() throws {
    // Int-first: 1 folds (integer), Int.max folds, then 1.0 is a DISTINCT
    // duplicate skipped for the sum — but it must still set the widen flag,
    // else the all-integer total Int.max + 1 overflows. Double-first: 1.0 folds
    // and widens, Int.max folds, then 1 is the skipped duplicate. Both must
    // yield the SAME finite double.
    try mixed().expect("SELECT SUM(DISTINCT V) FROM IntFirst",
                       yields: [[widened]])
    try mixed().expect("SELECT SUM(DISTINCT V) FROM RealFirst",
                       yields: [[widened]])
  }

  @Test func `AVG(DISTINCT) widens regardless of row order`() throws {
    // AVG divides the widened total by the two distinct values, the same value
    // for either order — the int-first skipped double must widen it too.
    let average = widened / 2.0
    try mixed().expect("SELECT AVG(DISTINCT V) FROM IntFirst",
                       yields: [[average]])
    try mixed().expect("SELECT AVG(DISTINCT V) FROM RealFirst",
                       yields: [[average]])
  }
}

// MARK: - FILTER

struct AggregateFilterTests {
  @Test func `FILTER gates the rows an aggregate folds`() throws {
    // COUNT(*) counts all seven rows; the filtered COUNT(*) counts only the
    // four East rows (its WHERE is TRUE for them).
    try orders().expect("""
        SELECT COUNT(*), COUNT(*) FILTER (WHERE Region = 'East') FROM Orders
        """, yields: [[7, 4]])
  }

  @Test func `FILTER gates a value aggregate before the fold`() throws {
    // SUM(Amount) over the West rows only: 20+20+30 = 70 (the East rows and the
    // NULL are gated out).
    try orders().expect("""
        SELECT SUM(Amount) FILTER (WHERE Region = 'West') FROM Orders
        """, yields: [[70]])
  }

  @Test func `FILTER composes with DISTINCT — filter first, then dedup`() throws {
    // Gate to the West rows (amounts 20, 20, 30), then dedup: two distinct
    // values (20, 30), summing to 50.
    try orders().expect("""
        SELECT COUNT(DISTINCT Amount) FILTER (WHERE Region = 'West'),
               SUM(DISTINCT Amount) FILTER (WHERE Region = 'West')
          FROM Orders
        """, yields: [[2, 50]])
  }

  @Test func `FILTER composes with GROUP BY per group`() throws {
    // Per region, count only the rows whose amount is at least 20. East has one
    // such row (20); West has all three (20, 20, 30).
    try orders().expect("""
        SELECT Region, COUNT(*) FILTER (WHERE Amount >= 20) FROM Orders
          GROUP BY Region ORDER BY Region
        """, yields: [["East", 1], ["West", 3]])
  }

  @Test func `a FILTER whose predicate no row satisfies folds an empty group`() throws {
    // No row matches, so the filtered COUNT is 0 and the filtered SUM is NULL —
    // the empty-group result, alongside the unfiltered counts.
    try orders().expect("""
        SELECT COUNT(*) FILTER (WHERE Region = 'North'),
               SUM(Amount) FILTER (WHERE Region = 'North')
          FROM Orders
        """, yields: [[0, nil]])
  }

  @Test func `an aggregate in a FILTER predicate is rejected`() throws {
    // A FILTER's search condition is a per-row gate, so it may not contain an
    // aggregate (which has no per-row meaning).
    #expect(throws: SQLError.self) {
      try orders().run(Statement(parsing: """
          SELECT COUNT(*) FILTER (WHERE COUNT(*) > 1) FROM Orders
          """))
    }
  }
}

// MARK: - a statically-empty FILTER leaves the operand unreachable

struct AggregateFilterUnreachableOperandTests {
  @Test func `a constant-false FILTER makes the operand unreachable`() throws {
    // The executor evaluates the FILTER before the argument, so a definitely-
    // false gate means `1 / 0` never divides: the query validates (no fault on
    // the dead operand) and RUNS to the empty aggregate result (NULL).
    let sql = "SELECT SUM(1 / 0) FILTER (WHERE 1 = 0) FROM Orders"
    _ = try orders().columns(of: Statement(parsing: sql))
    try orders().expect(sql, yields: [[nil]])
  }

  @Test func `a bare divide-by-zero operand still faults`() throws {
    // With no FILTER the operand IS reachable, so a static divide by zero is
    // rejected exactly as before — the skip is gated on a statically non-TRUE
    // filter, not a blanket amnesty for the operand.
    try orders().expect("SELECT SUM(1 / 0) FROM Orders", fails: .divide)
  }

  @Test func `a constant-true FILTER still validates the operand`() throws {
    // A definitely-TRUE gate admits every row, so the operand IS reachable and
    // its static fault stands — a constant-true filter must not skip it.
    try orders().expect("SELECT SUM(1 / 0) FILTER (WHERE 1 = 1) FROM Orders",
                        fails: .divide)
  }

  @Test func `a non-constant FILTER still validates the operand`() throws {
    // A row-dependent gate cannot prove the operand unreachable, so the operand
    // is validated as a bare aggregate is — a well-typed operand type-checks.
    try orders().expect("""
        SELECT SUM(Amount) FILTER (WHERE Region = 'West') FROM Orders
        """, yields: [[70]])
  }

  // A FILTER that folds definitely UNKNOWN — a constant NULL comparison, here
  // `NULLIF(1, 1) = 1` whose left side folds to NULL — is treated the SAME as a
  // constant-false one: the executor's gate admits a row only on a definite
  // TRUE, so an UNKNOWN gate also admits no row and leaves the operand
  // unreachable. Validation matches that, so `SUM(1 / 0)` behind it validates
  // and runs to NULL rather than faulting on the dead operand.
  @Test func `a constant-UNKNOWN FILTER makes the operand unreachable`() throws {
    let sql = """
        SELECT SUM(1 / 0) FILTER (WHERE NULLIF(1, 1) = 1) FROM Orders
        """
    _ = try orders().columns(of: Statement(parsing: sql))
    try orders().expect(sql, yields: [[nil]])
  }

  // A settled-non-TRUE CONJUNCT kills the whole conjunction: an AND is TRUE
  // only if EVERY conjunct is, so a row-independently non-TRUE conjunct means
  // no row can pass the gate even when a SIBLING conjunct is per row. Here
  // `NULLIF(1, 1) = 1` folds definitely UNKNOWN (NULLIF(1,1) is NULL, NULL = 1
  // is UNKNOWN) while `Amount > 0` is per row — the filter is still dead, so
  // `SUM(1 / 0)` behind it validates and runs to NULL rather than faulting.
  @Test func `a settled-UNKNOWN conjunct makes a row-dependent FILTER dead`() throws {
    let sql = """
        SELECT SUM(1 / 0)
                 FILTER (WHERE NULLIF(1, 1) = 1 AND Amount > 0)
          FROM Orders
        """
    _ = try orders().columns(of: Statement(parsing: sql))
    try orders().expect(sql, yields: [[nil]])
  }

  // A settled-FALSE conjunct is likewise dead alongside a row-dependent one.
  @Test func `a settled-FALSE conjunct makes a row-dependent FILTER dead`() throws {
    let sql = """
        SELECT SUM(1 / 0) FILTER (WHERE 1 = 0 AND Amount > 0) FROM Orders
        """
    _ = try orders().columns(of: Statement(parsing: sql))
    try orders().expect(sql, yields: [[nil]])
  }

  // The proof is order-independent — the AND spine is flattened, so a
  // settled-non-TRUE conjunct SECOND kills the filter as one first does.
  @Test func `a settled-FALSE conjunct kills the FILTER in either order`() throws {
    let sql = """
        SELECT SUM(1 / 0) FILTER (WHERE Amount > 0 AND 1 = 0) FROM Orders
        """
    _ = try orders().columns(of: Statement(parsing: sql))
    try orders().expect(sql, yields: [[nil]])
  }

  // Soundness: a purely row-dependent conjunction could be TRUE per row, so
  // the operand IS reachable and its static fault stands — the dead-filter
  // skip must not fire without a proof of non-TRUE.
  @Test func `a row-dependent conjunction still validates the operand`() throws {
    try orders().expect("""
        SELECT SUM(1 / 0) FILTER (WHERE Amount > 0 AND Region = 'West')
          FROM Orders
        """, fails: .divide)
  }

  // Soundness: a settled-TRUE conjunct does NOT kill the filter — the sibling
  // `Amount > 0` can still make the conjunction TRUE per row, so the operand is
  // reachable and its divide by zero is rejected as before.
  @Test func `a settled-TRUE conjunct does not make the FILTER dead`() throws {
    try orders().expect("""
        SELECT SUM(1 / 0) FILTER (WHERE 1 = 1 AND Amount > 0) FROM Orders
        """, fails: .divide)
  }
}
