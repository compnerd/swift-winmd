// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising `[NOT] BETWEEN`: an integer key `K` that is `NULL` in
/// one row, so a NULL operand's UNKNOWN corner is reachable.
private func things() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer]) {
      Row(1, 5)
      Row(2, 1)
      Row(3, 10)
      Row(4, nil)
      Row(5, 15)
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

struct BetweenParsingTests {
  @Test func `BETWEEN parses to a first-class node`() throws {
    // `x BETWEEN a AND b` is a first-class `Predicate.between` holding `x` ONCE
    // — not the re-referencing `AND` of two comparisons its ISO definition
    // names.
    let select = try parse(select: "SELECT * FROM T WHERE K BETWEEN 1 AND 10")
    #expect(select.predicate
                == .between(.column("K"), .literal(.integer(1)),
                            .literal(.integer(10)), negated: false))
  }

  @Test func `NOT BETWEEN parses to a negated first-class node`() throws {
    // `x NOT BETWEEN a AND b` is the same node, `negated`.
    let select =
        try parse(select: "SELECT * FROM T WHERE K NOT BETWEEN 1 AND 10")
    #expect(select.predicate
                == .between(.column("K"), .literal(.integer(1)),
                            .literal(.integer(10)), negated: true))
  }
}

// MARK: - Evaluation

struct BetweenEvaluationTests {
  /// The `Id`s of every fixture row — a constant-TRUE `WHERE` keeps them all.
  private let all = [[1], [2], [3], [4], [5]]

  @Test func `a constant BETWEEN is true within the range`() throws {
    // A constant-true predicate keeps every row.
    try things().expect("SELECT Id FROM T WHERE 5 BETWEEN 1 AND 10",
                        yields: all)
  }

  @Test func `a constant NOT BETWEEN is false within the range`() throws {
    // A constant-false predicate drops every row.
    try things().empty("SELECT Id FROM T WHERE 5 NOT BETWEEN 1 AND 10")
  }

  @Test func `the lower bound is inclusive`() throws {
    try things().expect("SELECT Id FROM T WHERE 1 BETWEEN 1 AND 10",
                        yields: all)
  }

  @Test func `the upper bound is inclusive`() throws {
    try things().expect("SELECT Id FROM T WHERE 10 BETWEEN 1 AND 10",
                        yields: all)
  }

  @Test func `a value outside the range is not between`() throws {
    try things().empty("SELECT Id FROM T WHERE 15 BETWEEN 1 AND 10")
  }

  @Test func `BETWEEN over a column keeps only in-range rows`() throws {
    // K in [1, 10]: rows 1 (5), 2 (1), 3 (10); row 4 (NULL) is UNKNOWN, row 5
    // (15) is out of range.
    try things().expect("SELECT Id FROM T WHERE K BETWEEN 1 AND 10",
                        yields: [[1], [2], [3]])
  }

  @Test func `NOT BETWEEN over a column keeps only out-of-range rows`() throws {
    // K outside [2, 8]: row 2 (1) and rows 3/5 (10/15); row 1 (5) is in range,
    // row 4 (NULL) is UNKNOWN.
    try things().expect("SELECT Id FROM T WHERE K NOT BETWEEN 2 AND 8",
                        yields: [[2], [3], [5]])
  }

  @Test func `a NULL operand is UNKNOWN and excludes the row`() throws {
    // Row 4's K is NULL, so both bounds are UNKNOWN — the row is excluded, as
    // the equivalent `K >= 1 AND K <= 10` comparisons would exclude it.
    try things().expect("SELECT Id FROM T WHERE K BETWEEN 1 AND 10",
                        equals: "SELECT Id FROM T WHERE K >= 1 AND K <= 10")
  }
}

// MARK: - Test expression evaluated once

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so the non-deterministic
/// `stepper()` routine registered against it both observes successive values
/// and records how many times the run invoked it. The engine evaluates a row's
/// filter synchronously on one thread, so the box needs no lock.
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

struct BetweenOperandTests {
  /// A single-row table, so a per-row test expression is evaluated once.
  private func one() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `the BETWEEN test expression is evaluated once`() throws {
    // `stepper()` yields 0, then 1, …; non-deterministic, so unfoldable.
    // `stepper() BETWEEN 0 AND 0` must evaluate `stepper()` EXACTLY ONCE —
    // yielding 0, which IS in [0, 0], so the row is KEPT. The old desugar
    // duplicated the test across `stepper() >= 0 AND stepper() <= 0`, calling
    // it twice: the lower bound saw 0 (0 >= 0) and the upper saw a DIFFERENT 1
    // (1 <= 0 is false), wrongly DROPPING the row and calling it twice. The
    // first-class node holds the test, so the row is kept and the counter reads
    // exactly 1.
    let counter = Counter()
    let routines = try Routines()
        .registering("stepper", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try one().expect("SELECT Id FROM T WHERE stepper() BETWEEN 0 AND 0",
                     yields: [[1]], routines: routines)
    #expect(counter.count == 1)
  }
}

// MARK: - Upper bound short-circuit

struct BetweenShortCircuitTests {
  /// A single-row table — enough to reach the per-row predicate once.
  private func one() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `a FALSE lower bound skips the upper bound`() throws {
    // `0 BETWEEN 1 AND (1 / 0)` ≡ `0 >= 1 AND 0 <= (1 / 0)` — the lower
    // `0 >= 1` is FALSE, so Kleene `AND` is FALSE without the upper `1 / 0`.
    // The eager form evaluated BOTH bounds and faulted `.divide` on the upper;
    // deferring it keeps the predicate FALSE, dropping the row with NO throw.
    try one().empty("SELECT Id FROM T WHERE 0 BETWEEN 1 AND (1 / 0)")
  }

  @Test func `a TRUE lower bound skips the NOT BETWEEN upper`() throws {
    // `0 NOT BETWEEN 1 AND (1 / 0)` ≡ `0 < 1 OR 0 > (1 / 0)` — the lower
    // `0 < 1` is TRUE, so Kleene `OR` is TRUE without the upper `1 / 0`. The
    // row is kept with NO throw.
    try one().expect("SELECT Id FROM T WHERE 0 NOT BETWEEN 1 AND (1 / 0)",
                     yields: [[1]])
  }

  @Test func `the upper bound is evaluated when the lower does not settle it`()
      throws {
    // `5 BETWEEN 1 AND (1 / 0)` — the lower `5 >= 1` is TRUE, so the result
    // hinges on the upper: the deferred `1 / 0` MUST evaluate and STILL fault,
    // confirming the upper is not silently dropped when the lower needs it.
    try one().expect("SELECT Id FROM T WHERE 5 BETWEEN 1 AND (1 / 0)",
                     fails: .divide)
  }

  @Test func `a needed upper bound keeps an in-range row`() throws {
    // `5 BETWEEN 1 AND 10` — the lower `5 >= 1` is TRUE, so the upper `5 <= 10`
    // is evaluated and TRUE, keeping the row.
    try one().expect("SELECT Id FROM T WHERE 5 BETWEEN 1 AND 10",
                     yields: [[1]])
  }
}

// MARK: - Typecheck short-circuit

/// Parses `text` to a `Query`, failing on any other shape.
private func query(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

struct BetweenTypecheckTests {
  /// A relation with a text `Name`, so `Name + 1` is a reachable operand fault.
  private func named() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "Name": .text]) {
        Row(1, "a")
      }
    }
  }

  @Test func `a constant FALSE BETWEEN WHERE leaves the projection unreachable`()
      throws {
    // `0 BETWEEN 1 AND (1 / 0)` — the constant lower `0 >= 1` folds definitely
    // FALSE, settling the whole BETWEEN FALSE WITHOUT folding the upper
    // `1 / 0`. So `constant(_ predicate:)` reports the WHERE always-FALSE, the
    // projection `Name + 1` (a `.operand` fault over the text `Name`, if
    // reached) is unreachable, and `columns(of:validate:)` SUCCEEDS. The run
    // drops every row before the projection, yielding no rows and NO throw.
    let text = "SELECT Name + 1 FROM T WHERE 0 BETWEEN 1 AND (1 / 0)"
    _ = try named().columns(of: query(text))
    try named().empty(text)
  }
}

// MARK: - Seek planning

/// A relation sorted on its integer key `Id` (rows 1 … 10), so a BETWEEN over
/// `Id` can seek a contiguous run rather than scan the whole relation.
private func sorted() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer], sorted: "Id") {
      Row(1)
      Row(2)
      Row(3)
      Row(4)
      Row(5)
      Row(6)
      Row(7)
      Row(8)
      Row(9)
      Row(10)
    }
  }
}

/// The seek `Range<Int>` the first `.scan` reachable from `plan` carries, or
/// `nil` if that scan is unseeked — the run a BETWEEN seek plans over the
/// sorted key's row positions.
private func seek(_ plan: Plan) -> Range<Int>? {
  switch plan {
  case let .scan(_, _, seek):
    seek
  case let .select(_, source):
    seek(source)
  case let .project(_, source):
    seek(source)
  case let .sort(_, source):
    seek(source)
  default:
    nil
  }
}

struct BetweenSeekTests {
  @Test func `a BETWEEN over the sorted key seeks its two-sided run`() throws {
    // `Id BETWEEN 3 AND 7` over the `Id`-sorted relation must seek the run
    // `2 ..< 7` — the positions of Ids 3 … 7 (first `>= 3` at index 2, first
    // `> 7` at index 7) — exactly the range `Id >= 3 AND Id <= 7` would seek,
    // not scan all ten rows.
    let catalog = try sorted()
    let query = try query("SELECT Id FROM T WHERE Id BETWEEN 3 AND 7")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(seek(plan) == 2 ..< 7)
    try catalog.expect("SELECT Id FROM T WHERE Id BETWEEN 3 AND 7",
                       yields: [[3], [4], [5], [6], [7]])
  }

  @Test func `the seeked BETWEEN matches the equivalent range comparison`()
      throws {
    // The desugar `Id >= 3 AND Id <= 7` also seeks over the sorted key and
    // returns the SAME rows — but seeks only ONE conjunct (`Id >= 3`, the run
    // `2 ..< 10`) and residuals the other, so the first-class BETWEEN's
    // two-sided `2 ..< 7` is the TIGHTER run. Parity is the seeked shape and
    // the rows, and the BETWEEN run sits within the comparison's.
    let catalog = try sorted()
    let comparison =
        try query("SELECT Id FROM T WHERE Id >= 3 AND Id <= 7")
    let range = try #require(seek(catalog.optimise(catalog.compile(comparison),
                                                   [:])))
    #expect(range.lowerBound <= 2 && range.upperBound >= 7)
    try catalog.expect("SELECT Id FROM T WHERE Id BETWEEN 3 AND 7",
                       equals: "SELECT Id FROM T WHERE Id >= 3 AND Id <= 7")
  }

  @Test func `a NOT BETWEEN does not seek — the complement is two runs`()
      throws {
    // `Id NOT BETWEEN 3 AND 7` is the complement — two disjoint runs, not one
    // contiguous seek — so it scans under the residual and returns the
    // out-of-range rows.
    let catalog = try sorted()
    let query = try query("SELECT Id FROM T WHERE Id NOT BETWEEN 3 AND 7")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(seek(plan) == nil)
    try catalog.expect("SELECT Id FROM T WHERE Id NOT BETWEEN 3 AND 7",
                       yields: [[1], [2], [8], [9], [10]])
  }

  @Test func `an expression test does not seek — the operand is not a slot`()
      throws {
    // `Id + 1 BETWEEN 4 AND 8` tests an arithmetic term, not a bare key slot,
    // so it does not qualify for the seek; it scans and filters, admitting the
    // same rows the seeked `Id BETWEEN 3 AND 7` would.
    let catalog = try sorted()
    let query = try query("SELECT Id FROM T WHERE Id + 1 BETWEEN 4 AND 8")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(seek(plan) == nil)
    try catalog.expect("SELECT Id FROM T WHERE Id + 1 BETWEEN 4 AND 8",
                       yields: [[3], [4], [5], [6], [7]])
  }

  @Test func `a bound referencing a column does not seek — it is not constant`()
      throws {
    // `Id BETWEEN 3 AND Id` has an upper bound that reads a column, not an
    // integer literal, so it does not qualify for the seek; it scans and admits
    // every row whose `Id >= 3` (each row's own `Id` is its upper bound).
    let catalog = try sorted()
    let query = try query("SELECT Id FROM T WHERE Id BETWEEN 3 AND Id")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(seek(plan) == nil)
    try catalog.expect("SELECT Id FROM T WHERE Id BETWEEN 3 AND Id",
                       yields: [[3], [4], [5], [6], [7], [8], [9], [10]])
  }

  @Test func `an inverted BETWEEN seeks an empty run without trapping`()
      throws {
    // `Id BETWEEN 10 AND 1` is a valid EMPTY range (lower > upper): the
    // `Id >= 10` partition starts at index 9 and the `Id <= 1` partition ends
    // at index 1, so the raw `lower ..< upper` (9 ..< 1) would trap Swift's
    // `Range(lowerBound <= upperBound)` precondition and abort the process. The
    // guard detects the inversion and seeks the EMPTY run `9 ..< 9` instead, so
    // the query returns no rows and never traps.
    let catalog = try sorted()
    let query = try query("SELECT Id FROM T WHERE Id BETWEEN 10 AND 1")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    let range = try #require(seek(plan))
    #expect(range.isEmpty)
    try catalog.empty("SELECT Id FROM T WHERE Id BETWEEN 10 AND 1")
  }
}

// MARK: - Empty-group short-circuit

struct BetweenEmptyGroupTests {
  /// A relation to fold a whole-result aggregate over.
  private func numbers() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `a constant FALSE BETWEEN HAVING type-checks over an empty group`()
      throws {
    // A constant-FALSE `WHERE` leaves a whole-result aggregate its single empty
    // group, over which the `HAVING 0 BETWEEN 1 AND (1 / 0)` folds: the
    // constant lower `0 >= 1` is FALSE, settling BETWEEN FALSE WITHOUT folding
    // the upper `1 / 0`. So `empty(_ predicate:)` drops the group WITHOUT a
    // `.divide` fault, schema/type checking SUCCEEDS, and the run yields no row
    // with NO throw.
    let text = """
        SELECT COUNT(*) FROM T WHERE 1 = 0
        HAVING 0 BETWEEN 1 AND (1 / 0)
        """
    _ = try numbers().columns(of: query(text))
    try numbers().empty(text)
  }
}
