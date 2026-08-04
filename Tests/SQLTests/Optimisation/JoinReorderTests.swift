// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A small `Small` (2 rows) and a larger `Big` (6 rows) sharing a join key `k`,
/// so a strict count asymmetry drives the reorder — the existing 2-row fixtures
/// tie and never flip.
private func skewed() throws -> FixtureCatalog {
  try Catalog {
    Relation("Small", ["k": .integer, "v": .text], sorted: "k") {
      Row(1, "a")
      Row(2, "b")
    }
    Relation("Big", ["k": .integer, "w": .text], sorted: "k") {
      Row(1, "p")
      Row(1, "s")
      Row(2, "q")
      Row(2, "t")
      Row(3, "r")
      Row(3, "u")
    }
  }
}

/// Two relations of equal row count — the reorder never fires (a tie keeps the
/// written order).
private func even() throws -> FixtureCatalog {
  try Catalog {
    Relation("Uno", ["k": .integer, "v": .text], sorted: "k") {
      Row(1, "a")
      Row(2, "b")
    }
    Relation("Dos", ["k": .integer, "w": .text], sorted: "k") {
      Row(1, "p")
      Row(2, "q")
    }
  }
}

private func plan(_ catalog: borrowing FixtureCatalog, _ sql: String)
    throws -> Plan {
  try catalog.plan(of: parse(query: sql), Context(routines: .standard))
}

private func lines(_ catalog: borrowing FixtureCatalog, _ sql: String)
    throws -> Array<String> {
  let context = Context(routines: .standard)
  return try catalog.render(catalog.plan(of: parse(query: sql), context),
                            context)
}

/// Whether `plan` reaches an index-nested-loop `.join` whose inner relation is
/// `name` — the sign that relation was made the probed inner (so the OTHER side
/// drives).
private func inner(_ plan: Plan, is name: String) -> Bool {
  switch plan {
  case let .join(_, inner, _, _, _, _, _):
    return inner == name
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .topN(_, _, _, source), let .aggregate(_, _, source),
       let .window(_, source), let .derived(_, source, _, _),
       let .apply(source, _, _, _, _, _):
    return inner(source, is: name)
  case let .product(left, right), let .outer(left, right, _, _),
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return inner(left, is: name) || inner(right, is: name)
  case .single, .values, .empty, .scan:
    return false
  }
}

/// The base relation that drives the top join/product of `plan` — the outer,
/// first-materialised side, found by descending the leftmost child.
private func drives(_ plan: Plan) -> String? {
  switch plan {
  case let .scan(name, _, _):
    return name
  case let .join(outer, _, _, _, _, _, _), let .apply(outer, _, _, _, _, _):
    return drives(outer)
  case let .product(left, _), let .outer(left, _, _, _),
       let .semijoin(left, _, _, _), let .setop(_, left, _, _, _, _):
    return drives(left)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .topN(_, _, _, source), let .aggregate(_, _, source),
       let .window(_, source), let .derived(_, source, _, _):
    return drives(source)
  case .single, .values, .empty:
    return nil
  }
}

// MARK: - Tests

@Suite struct JoinReorderTests {
  @Test func `a big-first join is reordered to drive from the small side`()
      throws {
    let catalog = try skewed()
    // `Big` is written first, so the naive plan would make `Small` the inner
    // and drive the six-row `Big`. The reorder flips it: `Big` is the probed
    // inner and the two-row `Small` drives.
    let rendered =
        try lines(catalog, "SELECT Small.v, Big.w FROM Big JOIN Small "
                         + "ON Big.k = Small.k")
    #expect(rendered.contains { $0.contains("join (index nested loop)  "
                                          + "inner Big") })
    #expect(rendered.contains { $0.contains("scan Small") })
    let reordered = try plan(catalog, "SELECT Small.v, Big.w FROM Big "
                                    + "JOIN Small ON Big.k = Small.k")
    #expect(inner(reordered, is: "Big"))
    #expect(drives(reordered) == "Small")
  }

  @Test func `a small-first join already drives from the small side`() throws {
    let catalog = try skewed()
    // Written small-first, the plan already drives from `Small` (inner `Big`) —
    // so no reorder is needed and the driver is unchanged.
    let natural = try plan(catalog, "SELECT Small.v, Big.w FROM Small "
                                  + "JOIN Big ON Small.k = Big.k")
    #expect(inner(natural, is: "Big"))
    #expect(drives(natural) == "Small")
  }

  @Test func `reordering preserves the join result multiset`() throws {
    let catalog = try skewed()
    // Differential: the reordered big-first join and the already-optimal
    // small-first join project the same columns and order by them, so — the
    // reorder preserving the multiset — they are byte-identical.
    try catalog.expect(
        "SELECT Small.v, Big.w FROM Big JOIN Small ON Big.k = Small.k "
      + "ORDER BY Small.v, Big.w",
        equals:
        "SELECT Small.v, Big.w FROM Small JOIN Big ON Small.k = Big.k "
      + "ORDER BY Small.v, Big.w")
  }

  @Test func `a reordered join yields the expected rows`() throws {
    let catalog = try skewed()
    // The output columns are the SELECT list (`Small.v, Big.w`) regardless of
    // join order — the restoring projection keeps the layout — and every
    // matching pair survives.
    try catalog.expect(
        "SELECT Small.v, Big.w FROM Big JOIN Small ON Big.k = Small.k "
      + "ORDER BY Small.v, Big.w",
        yields: [["a", "p"], ["a", "s"], ["b", "q"], ["b", "t"]])
  }

  @Test func `SELECT star keeps its column layout across a reorder`() throws {
    let catalog = try skewed()
    // `SELECT *` over `Big JOIN Small` lays out `Big`'s columns then `Small`'s;
    // the reorder swaps the physical sides but the restoring projection keeps
    // that exact output layout.
    try catalog.expect(
        "SELECT * FROM Big JOIN Small ON Big.k = Small.k "
      + "ORDER BY Small.v, Big.w",
        yields: [[1, "p", 1, "a"], [1, "s", 1, "a"],
                 [2, "q", 2, "b"], [2, "t", 2, "b"]])
  }

  @Test func `an equal-count join is not reordered`() throws {
    let catalog = try even()
    // A tie keeps the written order: `Uno` (written first) drives, unchanged.
    #expect(try drives(plan(catalog, "SELECT Uno.v, Dos.w FROM Uno "
                                    + "JOIN Dos ON Uno.k = Dos.k")) == "Uno")
  }

  @Test func `a non-equi join is not reordered`() throws {
    let catalog = try skewed()
    // No straddling equi `.match`, so the run is not equi-connected — a reorder
    // could force a cartesian step, so it bails and the written-first `Big`
    // still drives (the non-equi join stays a nested-loop product).
    #expect(try drives(plan(catalog, "SELECT Small.v, Big.w FROM Big "
                                    + "JOIN Small ON Big.k < Small.k"))
              == "Big")
  }

  @Test func `an unsafe ON predicate blocks the reorder`() throws {
    let catalog = try skewed()
    // The `ON` carries a throwing conjunct, so the join predicate is not `safe`
    // — reordering could move or suppress the fault, so it bails and the
    // written-first `Big` still drives (the division still faults at run).
    #expect(try drives(plan(catalog,
        "SELECT Small.v, Big.w FROM Big JOIN Small "
      + "ON Big.k = Small.k AND 1 / (Big.k - Big.k) = 0")) == "Big")
  }

  @Test func `a filtered join is not reordered`() throws {
    let catalog = try skewed()
    // A per-relation `WHERE` pushes a `select` onto a leaf, so the arm is not a
    // bare scan — its base count no longer measures the arm, so the reorder
    // bails and the written-first `Big` still drives.
    #expect(try drives(plan(catalog,
        "SELECT Small.v, Big.w FROM Big JOIN Small "
      + "ON Big.k = Small.k WHERE Big.w <> 'z'")) == "Big")
  }

  @Test func `a reordered join preserves cardinality with duplicates`()
      throws {
    let catalog = try skewed()
    // `Big` has two rows per key and `Small` one, so each key yields two result
    // rows — the reorder is a permutation, never dropping or duplicating a
    // pair, so the count is exactly the un-reordered join's.
    let rows = try catalog.run(parse(
        "SELECT Small.v, Big.w FROM Big JOIN Small ON Big.k = Small.k"),
        .standard)
    #expect(rows.count == 4)
  }
}
