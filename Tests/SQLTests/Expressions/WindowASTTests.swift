// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

/// The window AST — `WindowFunction`, `WindowSpec`, and the `Expression.window`
/// node — carries value semantics (`Hashable`/`Equatable`) so the resolver and
/// the carrier can dedup and compare windows structurally, exactly as they do
/// aggregates.
struct WindowASTTests {
  @Test func `equal window functions compare equal`() {
    #expect(WindowFunction.rowNumber == WindowFunction.rowNumber)
    #expect(WindowFunction.rank != WindowFunction.denseRank)
  }

  @Test func `a window spec compares by partition and order`() {
    let a = WindowSpec(partition: [.column(Column("d"))],
                       order: Order(keys: [Order.Key(column: Column("x"))]))
    let b = WindowSpec(partition: [.column(Column("d"))],
                       order: Order(keys: [Order.Key(column: Column("x"))]))
    let c = WindowSpec(partition: [.column(Column("e"))],
                       order: Order(keys: [Order.Key(column: Column("x"))]))
    #expect(a == b)
    #expect(a != c)
  }

  @Test func `an empty window spec has no partition and no order`() {
    let spec = WindowSpec()
    #expect(spec.partition.isEmpty)
    #expect(spec.order == nil)
  }

  @Test func `a window spec differs on its order`() {
    let ascending =
        WindowSpec(order: Order(keys: [Order.Key(column: Column("x"))]))
    let descending =
        WindowSpec(order: Order(keys: [Order.Key(column: Column("x"),
                                                 ascending: false)]))
    #expect(ascending != descending)
  }

  @Test func `window expressions compare by function and spec`() {
    let spec = WindowSpec(partition: [.column(Column("d"))])
    let a = Expression.window(function: .rowNumber, spec: spec)
    let b = Expression.window(function: .rowNumber, spec: spec)
    let c = Expression.window(function: .rank, spec: spec)
    #expect(a == b)
    #expect(a != c)
    #expect(a.hashValue == b.hashValue)
  }

  @Test func `a window spec flattens its constituent expressions`() {
    // The structural walks descend `expressions` — the partition keys followed
    // by the order keys' value expressions; an ordinal sort key names an output
    // column, not a value, so it contributes none.
    let spec = WindowSpec(partition: [.column(Column("d")), .literal(.integer(1))],
                          order: Order(keys: [
                            Order.Key(column: Column("x")),
                            Order.Key(sort: .ordinal(2)),
                          ]))
    #expect(spec.expressions == [.column(Column("d")), .literal(.integer(1)),
                                 .column(Column("x"))])
  }
}
