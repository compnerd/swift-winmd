// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A left relation `A` and a right relation `B` with integer join keys, plus a
/// second integer on each so a comparison against a run-time `:parameter` sits
/// beside a comparable `A.Ak = B.Bk` equi key.
private func joinable() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["Ak": .integer, "Ax": .integer]) {
      Row(1, 10)
      Row(2, 20)
    }
    Relation("B", ["Bk": .integer, "Bm": .integer]) {
      Row(1, 1)
      Row(2, 2)
    }
  }
}

/// The incomparable-type fault an `integer` against a `character varying` pair
/// raises at run.
private let intVsText =
    SQLError.state("42804", "cannot compare integer with character varying")

// MARK: - A run-time :parameter operand is a throwable residual, not a key gate

/// A comparison against a `:parameter` (`.bound`) can fault `42804` at run — the
/// binding may be a non-NULL incomparable value — so it is NOT safe to hoist a
/// sibling equi key past it. The classifier stamps it unsafe at compile (the
/// binding is not yet known), so `Scope.on` declines the hoist and the whole
/// `ON` stays a nested-loop residual that faults, rather than hashing the
/// comparable key into disjoint buckets and silently returning no rows.
struct BoundOperandComparabilityTests {
  @Test func `a text-bound parameter beside an equi key bars the hoist`()
      throws {
    // `A.Ak = :p AND A.Ak = B.Bk`: the parameter comparison leads the equi key.
    // The buggy classifier read `.bound` unconditionally safe, hoisted
    // `A.Ak = B.Bk` into a hash key, and — with no matching bucket — dropped
    // every pair before the `.bound` residual ran, silently returning empty.
    // The `.bound` is now stamped unsafe, so no key is hoisted (no `.join`).
    let catalog = try joinable()
    let sql =
        "SELECT A.Ax FROM A JOIN B ON A.Ak = :p AND A.Ak = B.Bk"
    let plan = try catalog.optimise(catalog.compile(parse(sql)),
                                    ["p": .text("z")])
    #expect(!joined(plan))
  }

  @Test func `a text-bound parameter beside an equi key faults at run`()
      throws {
    // The nested-loop `ON` evaluates `A.Ak = :p` first per pair, so a text-bound
    // `:p` against the integer `A.Ak` faults `42804` — not a silent empty.
    let sql =
        "SELECT A.Ax FROM A JOIN B ON A.Ak = :p AND A.Ak = B.Bk"
    try joinable().expect(sql, fails: intVsText, bindings: ["p": .text("z")])
  }

  @Test func `an integer-bound parameter still matches correctly`() throws {
    // A comparable binding never faults: `:p` = 1 admits the `A.Ak = 1` row and
    // the equi key selects its `B` partner. The residual stays a nested loop,
    // but the result is correct — the soundness fix costs no correctness.
    let sql =
        "SELECT A.Ax FROM A JOIN B ON A.Ak = :p AND A.Ak = B.Bk"
    try joinable().expect(sql, yields: [[10]], bindings: ["p": .integer(1)])
  }
}

// MARK: - A parameterised BETWEEN bound is a throwable residual

/// A `BETWEEN` with a `:parameter` bound can fault `42804` at run, so a sibling
/// equi key must not hoist past it — the `.between` analogue of the `.bound`
/// bar.
struct BetweenParameterComparabilityTests {
  @Test func `a text-bound BETWEEN bound beside an equi key bars the hoist`()
      throws {
    // `A.Ax BETWEEN :lo AND 10 AND A.Ak = B.Bk`: the parameterised range leads
    // the equi key. The `.between` is stamped unsafe (its `:lo` bound is an
    // opaque run-time value), so `Scope.on` declines the hoist — no `.join`.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B "
            + "ON A.Ax BETWEEN :lo AND 10 AND A.Ak = B.Bk"
    let plan = try catalog.optimise(catalog.compile(parse(sql)),
                                    ["lo": .text("z")])
    #expect(!joined(plan))
  }

  @Test func `a text-bound BETWEEN bound beside an equi key faults at run`()
      throws {
    // The nested-loop `ON` evaluates the range's `A.Ax >= :lo` per pair, so a
    // text-bound `:lo` against the integer `A.Ax` faults `42804`.
    let sql = "SELECT A.Ax FROM A JOIN B "
            + "ON A.Ax BETWEEN :lo AND 10 AND A.Ak = B.Bk"
    try joinable().expect(sql, fails: intVsText, bindings: ["lo": .text("z")])
  }
}

// MARK: - An unreachable cross-kind IN element must not bar the hoist

/// The membership walk honours the run's Kleene-OR short-circuit: an element
/// after a definite match is never compared and cannot fault, so it must not
/// mark the whole `IN` unsafe. A reachable cross-kind element still does. This
/// is the over-strictness fix — a sibling equi key beside such an `IN` keeps
/// its hash join.
struct MembershipReachabilityPlanningTests {
  @Test func `a constant-matched IN beside an equi key keeps the hash join`()
      throws {
    // `1 IN (1, 'x')`: the run matches `1 = 1` and never reaches `'x'`, so the
    // `IN` cannot fault. The classifier stops at the constant match, leaves the
    // `IN` safe, and `Scope.on` hoists the comparable `A.Ak = B.Bk` — a `.join`.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B ON 1 IN (1, 'x') AND A.Ak = B.Bk"
    let plan = try catalog.optimise(catalog.compile(parse(sql)), [:])
    #expect(joined(plan))
    try catalog.expect(sql, yields: [[10], [20]])
  }

  @Test func `a reflexive IN beside an equi key keeps the hash join`() throws {
    // `A.Ak IN (A.Ak, 'x')`: `A.Ak = A.Ak` is TRUE for a non-NULL row and
    // UNKNOWN (never a fault) for a NULL one, so `'x'` is never a reachable
    // fault. The classifier stops at the reflexive element, so the `IN` is safe
    // and the equi key still hashes.
    let catalog = try joinable()
    let sql =
        "SELECT A.Ax FROM A JOIN B ON A.Ak IN (A.Ak, 'x') AND A.Ak = B.Bk"
    let plan = try catalog.optimise(catalog.compile(parse(sql)), [:])
    #expect(joined(plan))
    try catalog.expect(sql, yields: [[10], [20]])
  }

  @Test func `a reachable cross-kind IN element still bars the hoist`() throws {
    // `A.Ak IN ('x', A.Ak)`: the run compares `A.Ak = 'x'` FIRST and faults, so
    // the cross-kind element is reachable and the `IN` is unsafe — the equi key
    // is not hoisted and the run faults `42804`.
    let catalog = try joinable()
    let sql =
        "SELECT A.Ax FROM A JOIN B ON A.Ak IN ('x', A.Ak) AND A.Ak = B.Bk"
    let plan = try catalog.optimise(catalog.compile(parse(sql)), [:])
    #expect(!joined(plan))
    catalog.expect(sql, fails: intVsText)
  }
}
