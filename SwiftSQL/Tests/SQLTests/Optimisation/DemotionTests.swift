// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - strict unit matrix

/// The three-valued null-rejection analysis, tested directly on constructed
/// `Filter`s — the demotion gate that decides an enclosing `WHERE` drops every
/// NULL-extended row on a side. `nulled` here is `{2}` (a single right slot).
@Suite struct RejectsNullTests {
  private let nulled: Set<Int> = [2]

  @Test func `a comparison over a nulled slot rejects`() {
    // `slot2 = 'Ada'` is UNKNOWN when slot 2 is NULL — rejecting.
    let filter = Filter.compare(.slot(2), .equal, .constant(.text("Ada")))
    #expect(filter.strict(on: nulled))
  }

  @Test func `a comparison off the nulled side does not reject`() {
    // `slot1 = 'Ada'` reads no nulled slot, so it can still be TRUE.
    let filter = Filter.compare(.slot(1), .equal, .constant(.text("Ada")))
    #expect(!filter.strict(on: nulled))
  }

  @Test func `IS NOT NULL over a nulled slot rejects`() {
    #expect(Filter.null(.slot(2), negated: true).strict(on: nulled))
  }

  @Test func `IS NULL over a nulled slot does not reject`() {
    // `slot2 IS NULL` is TRUE when slot 2 is NULL — it keeps the row.
    #expect(!Filter.null(.slot(2), negated: false).strict(on: nulled))
  }

  @Test func `AND rejects when either arm rejects`() {
    let rejecting = Filter.compare(.slot(2), .equal, .constant(.integer(1)))
    let keeping = Filter.compare(.slot(1), .equal, .constant(.integer(1)))
    #expect(Filter.and(rejecting, keeping).strict(on: nulled))
    #expect(Filter.and(keeping, rejecting).strict(on: nulled))
  }

  @Test func `OR rejects only when both arms reject`() {
    let rejecting = Filter.compare(.slot(2), .equal, .constant(.integer(1)))
    let keeping = Filter.compare(.slot(1), .equal, .constant(.integer(1)))
    // One arm can be TRUE via the left disjunct, so OR does not reject.
    #expect(!Filter.or(rejecting, keeping).strict(on: nulled))
    // Both arms reject ⇒ the OR is never TRUE on the NULL row.
    let other = Filter.compare(.slot(2), .gt, .constant(.integer(0)))
    #expect(Filter.or(rejecting, other).strict(on: nulled))
  }

  @Test func `NOT is conservatively not rejecting`() {
    let rejecting = Filter.compare(.slot(2), .equal, .constant(.integer(1)))
    #expect(!Filter.not(rejecting).strict(on: nulled))
  }

  @Test func `a COALESCE masking the NULL does not reject`() {
    // `COALESCE(slot2, 1) = 1` is TRUE when slot 2 is NULL — the COALESCE is
    // not strict (one element is a constant), so it must not reject.
    let masked = Term.coalesce([.slot(2), .constant(.integer(1))],
                               type: .integer)
    let filter = Filter.compare(masked, .equal, .constant(.integer(1)))
    #expect(!filter.strict(on: nulled))
  }

  @Test func `arithmetic over a nulled slot rejects`() {
    // `slot2 + 1 = 5` is UNKNOWN when slot 2 is NULL (arithmetic propagates).
    let sum = Term.binary(.add, .slot(2), .constant(.integer(1)))
    #expect(Filter.compare(sum, .equal, .constant(.integer(5)))
              .strict(on: nulled))
  }

  @Test func `a match over a nulled slot rejects`() {
    #expect(Filter.match(1, 2).strict(on: nulled))
    #expect(!Filter.match(0, 1).strict(on: nulled))
  }
}

// MARK: - Demotion fixtures

private func households() throws -> FixtureCatalog {
  try Catalog {
    Relation("People", ["Id": .integer, "Name": .text, "Age": .integer],
             sorted: "Id") {
      Row(1, "Alice", 30)
      Row(2, "Bob", 40)
      Row(3, "Cara", 50)
    }
    Relation("Parent", ["Id": .integer, "Name": .text], sorted: "Id") {
      Row(1, "Ada")
      Row(2, "Bee")
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

// MARK: - Demotion tests

@Suite struct DemotionTests {
  @Test func `a LEFT JOIN with a right-rejecting WHERE demotes to inner`()
      throws {
    let catalog = try households()
    let rendered = try lines(catalog,
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name = 'Ada'")
    // No `outer` node survives — the join demoted — and the inner-join
    // machinery took over, seeking Parent, with the WHERE preserved above it.
    #expect(rendered.allSatisfy { !$0.contains("outer") })
    #expect(rendered.contains {
      $0.contains("join (index nested loop)  inner Parent")
    })
    #expect(rendered.contains { $0.contains("= 'Ada'") })
  }

  @Test func `a demoted LEFT JOIN equals the inner join`() throws {
    let catalog = try households()
    // The demotion's correctness: a rejecting WHERE makes LEFT ≡ INNER, so the
    // demoted plan yields exactly the inner join's rows.
    try catalog.expect(
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name = 'Ada'",
        equals:
        "SELECT People.Name FROM People INNER JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name = 'Ada'")
    try catalog.expect(
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name = 'Ada'",
        yields: [["Alice"]])
  }

  @Test func `a WHERE on the preserved side does not demote`() throws {
    let catalog = try households()
    // `People.Name IS NOT NULL` rejects on the LEFT (preserved) side, not the
    // NULL-extended right — so the LEFT join stays, and its unmatched left rows
    // survive.
    let rendered = try lines(catalog,
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE People.Name IS NOT NULL")
    #expect(rendered.contains { $0.contains("outer LEFT") })
    // Cara (unmatched) survives — proof the join stayed outer.
    try catalog.expect(
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE People.Name IS NOT NULL",
        yields: [["Alice"], ["Bob"], ["Cara"]])
  }

  @Test func `a rejecting predicate in the ON does not demote`() throws {
    let catalog = try households()
    // A null-rejecting predicate in the `ON` governs matching, not
    // post-filtering — the pass reads only the WHERE, so the LEFT join stays
    // and every left row survives NULL-extended where `Parent.Name <> 'Ada'`.
    let rendered = try lines(catalog,
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id AND Parent.Name = 'Ada'")
    #expect(rendered.contains { $0.contains("outer LEFT") })
    try catalog.expect(
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id AND Parent.Name = 'Ada'",
        yields: [["Alice"], ["Bob"], ["Cara"]])
  }

  @Test func `an OR across both sides does not demote`() throws {
    let catalog = try households()
    // A right-NULL row can still be TRUE via the left disjunct, so the WHERE is
    // not rejecting and the join stays outer.
    let rendered = try lines(catalog,
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name = 'Ada' OR People.Age = 50")
    #expect(rendered.contains { $0.contains("outer LEFT") })
  }

  @Test func `an unsafe WHERE does not demote`() throws {
    let catalog = try households()
    // `1 / (Parent.Id - Parent.Id) = 0` rejects NULL on the right, but it can
    // throw — demoting would drop the NULL-extended rows without evaluating it,
    // suppressing a fault the un-demoted WHERE owes there. The `filter.safe`
    // gate keeps the join outer.
    let rendered = try lines(catalog,
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id "
      + "WHERE 1 / (Parent.Id - Parent.Id) = 0")
    #expect(rendered.contains { $0.contains("outer") })
  }

  @Test func `a FULL JOIN rejecting one side demotes to the other outer`()
      throws {
    let catalog = try households()
    // A FULL join whose WHERE rejects NULL on the right (`Parent`) demotes to
    // RIGHT: the unmatched-left rows (right columns NULL) drop, but the
    // unmatched-right rows must be PRESERVED — a RIGHT outer, not LEFT.
    let rendered = try lines(catalog,
        "SELECT People.Name FROM People FULL JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name IS NOT NULL")
    #expect(rendered.contains { $0.contains("outer RIGHT") })
    #expect(rendered.allSatisfy { !$0.contains("FULL") })
  }

  @Test func `a demoted FULL preserves the non-rejected side's rows`() throws {
    // `Parent` 5 matches no `People`. Rejecting NULL on the right drops the
    // unmatched-`People` rows but the unmatched-`Parent` row (its `People`
    // columns NULL) must survive — demoting to LEFT would wrongly drop it.
    let catalog = try Catalog {
      Relation("People", ["Id": .integer, "Name": .text], sorted: "Id") {
        Row(1, "Alice")
      }
      Relation("Parent", ["Id": .integer, "Name": .text], sorted: "Id") {
        Row(1, "Ada")
        Row(5, "Zed")
      }
    }
    try catalog.expect(
        "SELECT Parent.Name FROM People FULL JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name IS NOT NULL "
      + "ORDER BY Parent.Name",
        yields: [["Ada"], ["Zed"]])
  }

  @Test func `a row-value predicate does not demote an outer join`() throws {
    let catalog = try households()
    // `(People.Age, Parent.Id) < (100, 0)` is TRUE from the first component
    // even when the right's `Parent.Id` is NULL, so it does not reject NULL on
    // the right: the unmatched `People` 3 still satisfies it and must survive.
    // A demotion to inner would wrongly drop it.
    try catalog.expect(
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE (People.Age, Parent.Id) < (100, 0) "
      + "ORDER BY People.Name",
        yields: [["Alice"], ["Bob"], ["Cara"]])
  }

  @Test func `a demotion over an empty preserved side yields no rows`()
      throws {
    let catalog = try Catalog {
      Relation("People", ["Id": .integer, "Name": .text], sorted: "Id") {
      }
      Relation("Parent", ["Id": .integer, "Name": .text], sorted: "Id") {
        Row(1, "Ada")
      }
    }
    // No left rows: LEFT and the demoted INNER both yield nothing.
    try catalog.empty(
        "SELECT People.Name FROM People LEFT JOIN Parent "
      + "ON People.Id = Parent.Id WHERE Parent.Name = 'Ada'")
  }
}
