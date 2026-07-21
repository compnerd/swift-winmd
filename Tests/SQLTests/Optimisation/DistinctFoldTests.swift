// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A single-relation catalog whose `a` REPEATS across rows differing only in
/// `b` — the adversarial fixture: a `SELECT DISTINCT a` projects the whole row
/// down to `a`, COLLAPSING two distinct rows to one value, so the `.distinct`
/// MUST be kept or the result would leak the duplicate `a`.
private func collapsing() throws -> FixtureCatalog {
  try Catalog {
    Relation("D", ["a": .integer, "b": .integer]) {
      Row(1, 10)
      Row(1, 20)
      Row(2, 30)
    }
  }
}

/// A single-relation catalog for the aggregate/GROUP BY oracles.
private func numbers() throws -> FixtureCatalog {
  try Catalog {
    Relation("N", ["Id": .integer, "V": .text]) {
      Row(1, "x")
      Row(2, "y")
      Row(3, "x")
    }
  }
}

/// Whether `plan` reaches ANY `.distinct` node — the dedup the optimiser drops
/// when its source is PROVABLY distinct. Mirrors `ConstantFoldTests`'s
/// `selects`/`empties`, recursing every operator so a `.distinct` nested under
/// a project/aggregate/set-op arm is still found.
private func distincts(_ plan: Plan) -> Bool {
  switch plan {
  case .distinct:
    true
  case let .project(_, source):
    distincts(source)
  case let .sort(_, source):
    distincts(source)
  case let .limit(_, _, source):
    distincts(source)
  case let .derived(_, sub, _, _):
    distincts(sub)
  case let .aggregate(_, _, source):
    distincts(source)
  case let .select(_, source):
    distincts(source)
  case let .product(left, right):
    distincts(left) || distincts(right)
  case let .outer(left, right, _, _):
    distincts(left) || distincts(right)
  case let .semijoin(left, right, _, _):
    distincts(left) || distincts(right)
  case let .join(source, _, _, _, _, _, _):
    distincts(source)
  case let .apply(left, _, _, _, _, _):
    distincts(left)
  case let .setop(_, left, right, _, _, _):
    distincts(left) || distincts(right)
  case .single, .empty, .scan:
    false
  }
}

// MARK: - Plan.unique unit tests

/// `Plan.unique` is the SOUND, CONSERVATIVE full-row-distinctness property the
/// optimiser drops a `.distinct` on: `true` only when the plan PROVABLY yields
/// no two equal full rows, `false` for anything whose distinctness is not
/// certain (a `scan` multiset, a fan-out join, an `all` set operation, or a
/// column-dropping project). An over-claim here would LEAK duplicates.
struct PlanUniqueTests {
  /// A width-1 scan of `D.a` — a base relation, so NOT provably unique.
  private let scan = Plan.scan(name: "D", ordinals: [0], seek: nil)

  @Test func `a base scan is not unique`() {
    // A SQL table is a MULTISET — a duplicate row is possible and no unique key
    // is tracked — so a scan is conservatively non-unique.
    #expect(!scan.unique)
  }

  @Test func `single and empty are trivially unique`() {
    #expect(Plan.single.unique)
    #expect(Plan.empty(slots: 2).unique)
  }

  @Test func `a distinct is unique`() {
    // The dedup guarantees no duplicate full row — DISTINCT-of-DISTINCT.
    #expect(Plan.distinct(scan).unique)
  }

  @Test func `a set operation is unique without all, not with`() {
    // UNION/INTERSECT/EXCEPT (no `all`) dedup their result; the `all` multiset
    // keeps duplicates.
    let deduped = Plan.setop(.union, scan, scan, all: false,
                             types: [.integer], widened: [])
    let multiset = Plan.setop(.union, scan, scan, all: true,
                              types: [.integer], widened: [])
    #expect(deduped.unique)
    #expect(!multiset.unique)
  }

  @Test func `an aggregate is unique`() {
    // One row per distinct group key (key cells prefix each output row), or
    // exactly one row with no GROUP BY.
    let grouped = Plan.aggregate(keys: [.slot(0)], aggregates: [], scan)
    #expect(grouped.unique)
  }

  @Test func `select, limit, and sort preserve a unique source`() {
    // Each drops or reorders rows, never duplicating one, so it is unique iff
    // its source is — and NOT unique over a non-unique source.
    let unique = Plan.distinct(scan)
    let filter = Filter.compare(.slot(0), .equal, .constant(.integer(1)))
    #expect(Plan.select(filter, unique).unique)
    #expect(!Plan.select(filter, scan).unique)
    #expect(Plan.limit(count: 1, offset: 0, unique).unique)
    #expect(!Plan.limit(count: 1, offset: 0, scan).unique)
    #expect(Plan.sort(keys: [(.slot(0), true)], unique).unique)
    #expect(!Plan.sort(keys: [(.slot(0), true)], scan).unique)
  }

  @Test func `a product and a join are not unique`() {
    // A pairing operator can MULTIPLY rows — one row paired with many — so
    // it is never provably distinct here.
    #expect(!Plan.product(Plan.distinct(scan), Plan.distinct(scan)).unique)
  }

  @Test func `an injective project over a unique source is unique`() {
    // A permutation/renaming reading EVERY source slot retains all columns, so
    // two distinct source rows stay distinct — injective. Over a `distinct`
    // source (width 1), a project reading slot 0 covers the whole row.
    let unique = Plan.distinct(scan)
    #expect(Plan.project([.slot(0)], unique).unique)
  }

  @Test func `a column-dropping project is not unique`() {
    // Dropping a source column can COLLAPSE distinct rows: an aggregate of two
    // key columns projected down to the first loses the second, so two rows
    // differing only in it become equal. Not covering every source slot ⇒ not
    // unique.
    let grouped =
        Plan.aggregate(keys: [.slot(0), .slot(1)], aggregates: [], scan)
    #expect(grouped.unique)
    #expect(!Plan.project([.slot(0)], grouped).unique)
    // Reading BOTH slots (a full permutation) stays unique.
    #expect(Plan.project([.slot(1), .slot(0)], grouped).unique)
  }

  @Test func `a computed project is not unique`() {
    // A non-slot term is not an injective column read — it can map distinct
    // rows to an equal output — so a project carrying one is not unique over a
    // unique source.
    let unique = Plan.distinct(scan)
    #expect(!Plan.project([.constant(.integer(1))], unique).unique)
  }
}

// MARK: - Optimiser fold: DISTINCT elimination

/// The optimiser DROPS a `.distinct` whose source is PROVABLY distinct
/// (identical result, one fewer dedup) and KEEPS it over any source that could
/// hold a duplicate full row.
struct DistinctFoldTests {
  /// The optimised plan for `sql` against `catalog`, through the full
  /// compile/pushdown/optimise pipeline the executor runs.
  private func optimised(_ catalog: borrowing FixtureCatalog, _ sql: String)
      throws -> Plan {
    try catalog.optimise(catalog.compile(parse(query: sql)).pushdown(), [:])
  }

  @Test func `DISTINCT over a GROUP BY drops the redundant dedup`() throws {
    // The grouped aggregate already emits one row per distinct key, so the
    // outer DISTINCT is redundant — the fold leaves no `.distinct` over it.
    let catalog = try numbers()
    #expect(!distincts(try optimised(catalog,
        "SELECT DISTINCT V FROM N GROUP BY V")))
  }

  @Test func `DISTINCT over a GROUP BY yields the same rows`() throws {
    // Result equivalence: eliminating the dedup changes nothing — the folded
    // query returns exactly the un-DISTINCT grouped rows.
    try numbers().expect("SELECT DISTINCT V FROM N GROUP BY V ORDER BY V",
                         equals: "SELECT V FROM N GROUP BY V ORDER BY V")
  }

  @Test func `DISTINCT over an ungrouped aggregate drops the dedup`() throws {
    // A no-GROUP-BY aggregate emits exactly one row, trivially distinct, so the
    // DISTINCT is dropped — and the single COUNT row is unchanged.
    let catalog = try numbers()
    #expect(!distincts(try optimised(catalog,
        "SELECT DISTINCT COUNT(*) FROM N")))
    try catalog.expect("SELECT DISTINCT COUNT(*) FROM N", yields: [[3]])
  }

  @Test func `DISTINCT over a projecting scan KEEPS the dedup`() throws {
    // The adversarial must-KEEP case. `SELECT DISTINCT a FROM D` projects the
    // whole (a, b) row down to `a`, which REPEATS (rows (1,10) and (1,20)), so
    // the projection COLLAPSES two distinct rows to one value — the `.distinct`
    // is the only thing removing the duplicate. Its source is a base scan (not
    // unique), so the fold MUST keep it.
    let catalog = try collapsing()
    #expect(distincts(try optimised(catalog, "SELECT DISTINCT a FROM D")))
  }

  @Test func `DISTINCT over a projecting scan actually deduplicates`() throws {
    // The result proof behind the must-KEEP shape: `a` is `[1, 1, 2]` in the
    // rows, so a correct DISTINCT yields `[1, 2]`. Removing the dedup would
    // leak the duplicate `1`, changing the row multiset.
    try collapsing().expect("SELECT DISTINCT a FROM D ORDER BY a",
                            yields: [[1], [2]])
  }

  @Test func `DISTINCT over a full-row scan projection KEEPS the dedup`()
      throws {
    // Even a project reading BOTH scan columns is injective but its SOURCE (the
    // scan) is a multiset — a duplicate whole row is possible — so the fold
    // keeps the dedup. The scan, not the projection, is the non-unique link.
    let catalog = try collapsing()
    #expect(distincts(try optimised(catalog, "SELECT DISTINCT a, b FROM D")))
  }

  @Test func `DISTINCT of DISTINCT collapses to one`() throws {
    // A hand-built `distinct(distinct(scan))` — the source's own `.distinct`
    // already deduplicates, so the outer one is redundant and the fold drops
    // it, leaving a single `.distinct` (over the scan).
    let catalog = try collapsing()
    let scan = Plan.scan(name: "D", ordinals: [0, 1], seek: nil)
    let plan = try catalog.optimise(.distinct(.distinct(scan)), [:])
    guard case let .distinct(inner) = plan else {
      Issue.record("expected a single distinct, got \(plan)")
      return
    }
    // Exactly ONE distinct survives: the inner is the bare scan, not a nested
    // second distinct.
    #expect(!distincts(inner))
  }

  @Test func `DISTINCT over a deduped set operation drops the dedup`() throws {
    // A hand-built `distinct(setop(.union, all: false))` — the UNION already
    // yields distinct rows, so the outer DISTINCT is redundant and the fold
    // drops it, leaving the set operation alone.
    let catalog = try collapsing()
    let scan = Plan.scan(name: "D", ordinals: [0], seek: nil)
    let union = Plan.setop(.union, .project([.slot(0)], scan),
                           .project([.slot(0)], scan), all: false,
                           types: [.integer], widened: [])
    #expect(!distincts(try catalog.optimise(.distinct(union), [:])))
  }

  @Test func `DISTINCT over a UNION ALL KEEPS the dedup`() throws {
    // The set-operation must-KEEP case: `UNION ALL` is a MULTISET that keeps
    // duplicates, so a `.distinct` over it is NOT redundant — the fold must
    // keep it or the duplicates leak.
    let catalog = try collapsing()
    let scan = Plan.scan(name: "D", ordinals: [0], seek: nil)
    let union = Plan.setop(.union, .project([.slot(0)], scan),
                           .project([.slot(0)], scan), all: true,
                           types: [.integer], widened: [])
    #expect(distincts(try catalog.optimise(.distinct(union), [:])))
  }
}
