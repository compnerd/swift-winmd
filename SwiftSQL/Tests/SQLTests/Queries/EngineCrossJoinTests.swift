// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Cross-join tests

struct EngineCrossJoinTests {
  @Test func `a CROSS JOIN yields every pair of the two relations`() throws {
    // `family` has three Parent rows and four Child rows, so the Cartesian
    // product is 3 × 4 = 12 rows — every parent paired with every child.
    let rows = try join("SELECT * FROM Parent CROSS JOIN Child")
    #expect(rows.count == 12)
  }

  @Test func `a CROSS JOIN yields the full product in outer-major order`() throws {
    // The exact Cartesian product: each Parent row (outer) paired in turn with
    // every Child row (inner), the combined columns laid Parent-then-Child.
    let rows = try join("SELECT * FROM Parent CROSS JOIN Child")
    let expected: Array<Array<Value>> = [
      [.integer(1), .text("Ada"), .integer(1), .text("Ann")],
      [.integer(1), .text("Ada"), .integer(1), .text("Amy")],
      [.integer(1), .text("Ada"), .integer(2), .text("Bob")],
      [.integer(1), .text("Ada"), .integer(9), .text("Orphan")],
      [.integer(2), .text("Bee"), .integer(1), .text("Ann")],
      [.integer(2), .text("Bee"), .integer(1), .text("Amy")],
      [.integer(2), .text("Bee"), .integer(2), .text("Bob")],
      [.integer(2), .text("Bee"), .integer(9), .text("Orphan")],
      [.integer(3), .text("Cid"), .integer(1), .text("Ann")],
      [.integer(3), .text("Cid"), .integer(1), .text("Amy")],
      [.integer(3), .text("Cid"), .integer(2), .text("Bob")],
      [.integer(3), .text("Cid"), .integer(9), .text("Orphan")],
    ]
    #expect(rows == expected)
  }

  @Test func `a CROSS JOIN equals an inner join on a true predicate`() throws {
    // A CROSS JOIN synthesizes an always-true `ON`, so it is identical to an
    // inner join written with an explicit `ON 1 = 1`.
    try family().expect(
        "SELECT * FROM Parent CROSS JOIN Child",
        equals: "SELECT * FROM Parent JOIN Child ON 1 = 1")
  }

  @Test func `a CROSS JOIN lays the columns left-then-right`() throws {
    // The combined row is the outer relation's columns (Parent: Id, Name)
    // followed by the inner's (Child: Pid, Name) — the same a-then-b layout the
    // comma product and inner join produce.
    let rows = try join("SELECT * FROM Parent CROSS JOIN Child")
    #expect(rows.first == [.integer(1), .text("Ada"),
                           .integer(1), .text("Ann")])
  }

  @Test func `a CROSS JOIN composes in a chain with an inner join`() throws {
    // `Parent CROSS JOIN Child JOIN Ordered ON …` crosses Parent with Child,
    // then inner-joins Ordered keyed off the child's `Pid` against the ordered
    // relation's virtual `Id`. Every (parent, child) pair whose child `Pid`
    // names an `Ordered` row survives, gaining that row's `Label`.
    let rows = try join("""
        SELECT Parent.Name, Child.Name, Ordered.Label
          FROM Parent CROSS JOIN Child
          JOIN Ordered ON Ordered.Id = Child.Pid
        """)
    // Children with Pid 1 (Ann, Amy) → "first", Pid 2 (Bob) → "second"; the
    // orphan (Pid 9) drops. Each surviving child pairs with all three parents.
    #expect(rows.count == 9)
    #expect(rows.allSatisfy { $0[2] == .text("first")
                              || $0[2] == .text("second") })
  }

  @Test func `an inner join composes in a chain with a trailing CROSS JOIN`() throws {
    // `Parent JOIN Child ON … CROSS JOIN Ordered` keeps the three matched
    // (parent, child) pairs, then crosses each with all three `Ordered` rows —
    // 3 × 3 = 9 rows.
    let rows = try join("""
        SELECT Parent.Name, Child.Name, Ordered.Label
          FROM Parent JOIN Child ON Child.Pid = Parent.Id
          CROSS JOIN Ordered
        """)
    #expect(rows.count == 9)
  }

  @Test func `a CROSS JOIN optimises to a bare product`() throws {
    // The synthesized constant-true `ON` lowers to a filter the optimiser
    // proves always-true and elides, so the plan collapses to a bare `.product`
    // with no wrapping `.select` — the same plan the comma product produces.
    let catalog = try family()
    let select = try parse("SELECT * FROM Parent CROSS JOIN Child")
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(product(plan))
  }
}

/// Whether `plan` is a bare `.product` (optionally under a `.project`), with no
/// intervening `.select` — the shape a CROSS JOIN collapses to once the
/// optimiser elides its constant-true residual.
private func product(_ plan: Plan) -> Bool {
  switch plan {
  case .product:
    true
  case let .project(_, source):
    product(source)
  default:
    false
  }
}
