// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

/// A single-relation resolution scope `T(d, x)` — `d` at combined ordinal `0`,
/// `x` at `1` — for lowering a window over a known slot layout.
private func scope() -> Scope {
  Scope([(Relation(name: "T"),
          Schema(width: 2, extent: 2, names: ["d", "x"],
                 types: [.integer, .integer], virtuals: []))])
}

// MARK: - Windowing resolution

/// A ranking window resolves to a `Windowing` whose `PARTITION BY` keys and
/// window `ORDER BY` lower to combined base-ordinal terms, and whose result
/// type is `.integer`. The `Windowed` surface then maps a collected window to
/// its appended output slot while an ordinary source column passes through to
/// its own slot — the run's resolution, before the executor lands.
struct WindowResolutionTests {
  @Test func `each ranking function types as an integer`() {
    #expect(WindowFunction.rowNumber.type == .integer)
    #expect(WindowFunction.rank.type == .integer)
    #expect(WindowFunction.denseRank.type == .integer)
  }

  @Test func `a window lowers its partition and order to source terms`() throws {
    let window = Expression.window(
        function: .rowNumber,
        spec: WindowSpec(partition: [.column(Column("d"))],
                         order: Order(keys: [Order.Key(column: Column("x"),
                                                       ascending: false)])))
    let windowing = try window.windowing(scope())
    #expect(windowing.function == .rowNumber)
    #expect(windowing.partition == [.slot(0)])
    #expect(windowing.order == [SortKey(term: .slot(1), ascending: false,
                                        column: nil)])
  }

  @Test func `an empty OVER lowers to no partition and no order`() throws {
    let window = Expression.window(function: .rank, spec: WindowSpec())
    let windowing = try window.windowing(scope())
    #expect(windowing.partition.isEmpty)
    #expect(windowing.order.isEmpty)
  }

  @Test func `a window ORDER BY output ordinal is unsupported`() {
    // A window ORDER BY fixes the input row order, so an integer sort key —
    // which parses as an output ordinal — is meaningless and faults 0A000, in
    // parity across the run and validate paths.
    let window = Expression.window(
        function: .rowNumber,
        spec: WindowSpec(order: Order(keys: [Order.Key(sort: .ordinal(1))])))
    #expect(throws:
        SQLError.state("0A000",
                       "a window ORDER BY output ordinal is not supported")) {
      _ = try window.windowing(scope())
    }
  }

  @Test func `the windowed surface maps a window to its appended slot`() throws {
    let window = Expression.window(
        function: .rowNumber,
        spec: WindowSpec(partition: [.column(Column("d"))]))
    // Source `T(d, x)` packed identically (slots 0, 1); the `Windowed` appends
    // the lone windowing as it first resolves it, landing at appended slot
    // `width + 0` = 2.
    let windowed = Windowed(scope(), [0: 0, 1: 1], width: 2)
    #expect(try windowed.resolve(window) == .slot(2))
    // A bare source column passes through to its own slot — a window preserves
    // cardinality, so no grouping rule bars it.
    #expect(try windowed.resolve(.column(Column("x"))) == .slot(1))
    // A compound over the window recurses, lowering the window leaf to its
    // appended slot and the literal to a constant.
    let compound = Expression.binary(.add, window, .literal(.integer(1)))
    #expect(try windowed.resolve(compound)
                == .binary(.add, .slot(2), .constant(.integer(1))))
  }

  @Test func `a window is discovered inside a compound expression`() {
    let window = Expression.window(function: .rowNumber, spec: WindowSpec())
    #expect(Expression.binary(.add, window, .literal(.integer(1))).windowed)
    #expect(!Expression.column(Column("x")).windowed)
    var collected = Array<Expression>()
    Expression.binary(.add, window, window).collect(windows: &collected)
    // The same window written twice is collected once.
    #expect(collected == [window])
  }
}
