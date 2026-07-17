// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A single-relation catalog for the constant-fold result oracles.
private func numbers() throws -> FixtureCatalog {
  try Catalog {
    Relation("N", ["Id": .integer, "V": .text]) {
      Row(1, "one")
      Row(2, "two")
      Row(3, "three")
    }
  }
}

/// A single-row catalog whose `X` is zero — `1 / X` throws `SQLError.divide`
/// when evaluated, so it is the probe for whether a fold SKIPS a throwing
/// operand it must not drop.
private func zero() throws -> FixtureCatalog {
  try Catalog {
    Relation("Z", ["X": .integer]) {
      Row(0)
    }
  }
}

/// A parent `T` and child `S` keyed on `T.Id` — the LATERAL fixture whose right
/// side VARIES per outer row, so the fold's result-equivalence is a real proof.
private func lateral() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    Relation("S", ["k": .integer, "x": .integer]) {
      Row(1, 100)
      Row(1, 101)
      Row(2, 200)
    }
  }
}

/// Whether `plan` reaches ANY `.select` node — a residual per-row filter. The
/// constant-true fold eliminates a `WHERE 1 = 1` select entirely, so the
/// optimised plan for such a query reaches none.
private func selects(_ plan: Plan) -> Bool {
  switch plan {
  case .select:
    true
  case let .project(_, source):
    selects(source)
  case let .sort(_, source):
    selects(source)
  case let .limit(_, _, source):
    selects(source)
  case let .distinct(source):
    selects(source)
  case let .derived(_, sub, _, _):
    selects(sub)
  case let .aggregate(_, _, source):
    selects(source)
  case let .product(left, right):
    selects(left) || selects(right)
  case let .outer(left, right, _, _):
    selects(left) || selects(right)
  case let .join(source, _, _, _, _, _, _):
    selects(source)
  case let .apply(left, _, _, _, _, _):
    selects(left)
  case let .setop(_, left, right, _):
    selects(left) || selects(right)
  case .single, .scan:
    false
  }
}

// MARK: - Filter.constant unit tests

/// `Filter.constant` is the SOUND, CONSERVATIVE constant-truth evaluator the
/// optimiser folds on: `true` only when PROVABLY always TRUE, `false` only when
/// PROVABLY always FALSE, and `nil` (do NOT fold) for anything that reads a
/// slot, a `:parameter`, a subquery, or a NULL constant.
struct FilterConstantTests {
  @Test func `a constant-true compare is provably true`() {
    #expect(Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(1))).constant == true)
  }

  @Test func `a constant-false compare is provably false`() {
    #expect(Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(0))).constant == false)
  }

  @Test func `a NULL-bearing constant compare is undecidable`() {
    // `matches` yields UNKNOWN for a NULL on either side, so `constant` is
    // `nil` — never folded to `true`, so a `WHERE NULL = 1` keeps filtering.
    #expect(Filter.compare(.constant(.null), .equal,
                           .constant(.integer(1))).constant == nil)
    #expect(Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.null)).constant == nil)
  }

  @Test func `a slot-bearing compare is undecidable`() {
    // A comparison against a row slot is not statically known — `nil`.
    #expect(Filter.compare(.slot(0), .equal,
                           .constant(.integer(1))).constant == nil)
  }

  @Test func `AND folds only when both operands are constant`() {
    let t = Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(1)))
    let f = Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(0)))
    let slot = Filter.compare(.slot(0), .equal, .constant(.integer(1)))
    #expect(Filter.and(t, t).constant == true)
    #expect(Filter.and(t, f).constant == false)
    // An undecidable operand can read row data and THROW, so it must be
    // evaluated at runtime — a `false`/`true` sibling cannot license folding
    // the compound away. Either side undecidable ⇒ the compound is undecidable.
    #expect(Filter.and(f, slot).constant == nil)
    #expect(Filter.and(t, slot).constant == nil)
    #expect(Filter.and(slot, f).constant == nil)
  }

  @Test func `OR folds only when both operands are constant`() {
    let t = Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(1)))
    let f = Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(0)))
    let slot = Filter.compare(.slot(0), .equal, .constant(.integer(1)))
    #expect(Filter.or(f, f).constant == false)
    #expect(Filter.or(t, f).constant == true)
    // A `true` disjunct cannot license dropping an undecidable sibling that
    // reads row data and may throw. Either side undecidable ⇒ undecidable.
    #expect(Filter.or(t, slot).constant == nil)
    #expect(Filter.or(f, slot).constant == nil)
    #expect(Filter.or(slot, t).constant == nil)
  }

  @Test func `NOT flips a definite value and preserves undecidable`() {
    let t = Filter.compare(.constant(.integer(1)), .equal,
                           .constant(.integer(1)))
    let slot = Filter.compare(.slot(0), .equal, .constant(.integer(1)))
    #expect(Filter.not(t).constant == false)
    #expect(Filter.not(slot).constant == nil)
  }
}

// MARK: - Optimiser fold: WHERE result equivalence + plan shape

/// The optimiser drops a PROVABLY-true `WHERE` (identical result, one fewer
/// per-row predicate) and NEVER folds a false or NULL-bearing one.
struct ConstantSelectFoldTests {
  @Test func `WHERE 1 = 1 yields the same rows as no WHERE`() throws {
    // A constant-true filter admits every row: the folded query yields exactly
    // the unfiltered result.
    try numbers().expect("SELECT Id, V FROM N WHERE 1 = 1 ORDER BY Id",
                         equals: "SELECT Id, V FROM N ORDER BY Id")
  }

  @Test func `WHERE 1 = 1 optimises away the select node`() throws {
    // Plan-shape proof: the always-true select is GONE after optimisation — the
    // fold left a plain scan, not a select over a true residual.
    let catalog = try numbers()
    let plan = try catalog.optimise(
        catalog.compile(parse(query: "SELECT Id FROM N WHERE 1 = 1")), [:])
    #expect(!selects(plan))
  }

  @Test func `a genuine WHERE keeps its select node`() throws {
    // Contrast: a slot-bearing predicate is NOT folded, so its select
    // survives — the fold is scoped to provable constants only.
    let catalog = try numbers()
    let plan = try catalog.optimise(
        catalog.compile(parse(query: "SELECT Id FROM N WHERE Id = 2")), [:])
    #expect(selects(plan))
  }

  @Test func `WHERE 1 = 0 still returns no rows`() throws {
    // A constant-FALSE filter is left filtering (there is no empty-relation
    // node) and correctly rejects every row — proving false is NOT mis-folded.
    try numbers().empty("SELECT Id FROM N WHERE 1 = 0")
  }

  @Test func `WHERE NULL = 1 returns no rows (UNKNOWN rejects)`() throws {
    // A NULL operand makes the compare UNKNOWN; `constant` returns `nil` for a
    // NULL-bearing constant compare (unit-tested directly on
    // `Filter.constant`), so it is NOT folded. `NULL` is unspellable as a bare
    // comparison
    // operand here — the parser accepts it only in `IS NULL` — so the SQL-level
    // guard spells the NULL with `NULLIF(1, 1)` (a constant expression that
    // evaluates to NULL): the compare is not a two-constant leaf, so it stays,
    // evaluates UNKNOWN per row, and correctly rejects every row.
    try numbers().empty("SELECT Id FROM N WHERE NULLIF(1, 1) = 1")
  }

  @Test func `WHERE 1 = NULL returns no rows (UNKNOWN rejects)`() throws {
    try numbers().empty("SELECT Id FROM N WHERE 1 = NULLIF(1, 1)")
  }

  @Test func `an always-true OR does not drop a throwing operand`() throws {
    // The reviewer case: `(1 / X) = 0` reads a row slot and, with `X = 0`,
    // THROWS `SQLError.divide` when evaluated. The `OR 1 = 1` disjunct is
    // constant-true, but the compound OR is NOT a compile-time constant (the
    // left disjunct is undecidable), so the predicate is NOT folded away — it
    // runs per row and the division-by-zero surfaces. Folding it would silently
    // return the row.
    try zero().expect("SELECT X FROM Z WHERE (1 / X) = 0 OR 1 = 1",
                      fails: .divide)
  }

  @Test func `a constant-false AND still evaluates a throwing conjunct`()
      throws {
    // Symmetric guard: `1 = 0` is constant-false and `(1 / X) = 0` is
    // undecidable, so the AND is undecidable (not the pre-fix definite
    // `false`). The predicate stays and evaluates per row, raising `.divide` —
    // no fold may classify this compound and license skipping the throwing
    // conjunct.
    try zero().expect("SELECT X FROM Z WHERE (1 / X) = 0 AND 1 = 0",
                      fails: .divide)
  }
}

// MARK: - Apply ON-skip: LATERAL result equivalence

/// A LATERAL apply always emits `ON 1 = 1`; the executor skips the redundant
/// per-row `ON` check for a constant-true predicate — the fold changes the
/// plan/execution, never the rows.
struct ConstantApplyFoldTests {
  @Test func `a LATERAL ON 1 = 1 yields the known-correct rows`() throws {
    // The SAME rows the un-folded lateral fixture produces: Id 1 → {100, 101},
    // Id 2 → {200}, Id 3 → {} (dropped, INNER apply). The constant-true `ON`
    // skip admits every merged row directly — identical result.
    try lateral().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200]])
  }

  @Test func `a LATERAL ON does not skip a throwing predicate`() throws {
    // The apply's `ON` is not always `1 = 1`: `(1 / (T.Id - 1)) = 0 OR 1 = 1`
    // has an undecidable, throwing left disjunct, so the compound is NOT a
    // compile-time constant and the `ON` is NOT skipped. The outer `T.Id = 1`
    // makes the divisor zero, so the per-row `ON` evaluation raises `.divide`
    // rather than admitting rows.
    try lateral().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d " +
        "ON (1 / (T.Id - 1)) = 0 OR 1 = 1 " +
        "ORDER BY T.Id, d.x",
        fails: .divide)
  }

  @Test func `a LATERAL with a real ON still filters per row`() throws {
    // Contrast: a non-trivial `ON d.x > 100` is NOT constant-true, so it still
    // runs per merged row and filters — the skip is scoped to provable truth.
    try lateral().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON d.x > 100 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 101], [2, 200]])
  }
}
