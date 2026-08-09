// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A `People` relation stored ascending on `Id` (so it declares that physical
/// order), its rows listed in `Id` order so the declared order is honest.
private func sorted() throws -> FixtureCatalog {
  try Catalog {
    Relation("People", ["Id": .integer, "Name": .text, "Age": .integer],
             sorted: "Id") {
      Row(1, "Alice", 30)
      Row(2, "Bob", 25)
      Row(3, "Carol", 30)
      Row(4, "Dave", 40)
      Row(5, "Eve", 25)
    }
  }
}

/// The same rows, but the relation declares no physical order — so a sort over
/// it is never eliminated. The differential reference: identical data whose
/// `ORDER BY` always runs a real sort.
private func unsorted() throws -> FixtureCatalog {
  try Catalog {
    Relation("People", ["Id": .integer, "Name": .text, "Age": .integer]) {
      Row(1, "Alice", 30)
      Row(2, "Bob", 25)
      Row(3, "Carol", 30)
      Row(4, "Dave", 40)
      Row(5, "Eve", 25)
    }
  }
}

// MARK: - Plan assertions

/// Whether `plan` reaches a `.sort` node — the sign a redundant sort was NOT
/// eliminated.
private func sorts(_ plan: Plan) -> Bool {
  switch plan {
  case .sort: return true
  case let .select(_, source), let .project(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .top(_, _, _, source), let .aggregate(_, _, source),
       let .window(_, source):
    return sorts(source)
  case let .derived(_, source, _, _):
    return sorts(source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return sorts(left) || sorts(right)
  case .single, .values, .empty, .scan, .join, .apply:
    return false
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

// MARK: - Tests

@Suite struct RedundantSortTests {
  @Test func `a sort matching the scan order is eliminated`() throws {
    let catalog = try sorted()
    // `People` is stored ascending on `Id`, so `ORDER BY Id` is redundant: the
    // sort node is gone and the scan advertises the order it recognised.
    let rendered = try lines(catalog, "SELECT Name FROM People ORDER BY Id")
    #expect(rendered == [
      "project [slot 1]",
      "└─ scan People  reads [0, 1]  ordered [slot 0 ASC]",
    ])
    #expect(rendered.allSatisfy { !$0.contains("sort") })
  }

  @Test func `a DESC sort over an ascending scan is kept`() throws {
    let catalog = try sorted()
    // The scan promises ascending order only, so a `DESC` key never matches and
    // the sort stays.
    let rendered =
        try lines(catalog, "SELECT Name FROM People ORDER BY Id DESC")
    #expect(rendered.contains { $0.contains("sort  slot 0 DESC") })
  }

  @Test func `a sort over a seeked scan is eliminated`() throws {
    let catalog = try sorted()
    // A seek is a contiguous slice of the sorted scan, so it stays ordered —
    // `WHERE Id > 1 ORDER BY Id` drops the sort over the seeked scan.
    let rendered =
        try lines(catalog, "SELECT Name FROM People WHERE Id > 1 ORDER BY Id")
    #expect(rendered.allSatisfy { !$0.contains("sort") })
    #expect(rendered.contains { $0.contains("seek") })
  }

  @Test func `a multi-key sort past the promised prefix is kept`() throws {
    let catalog = try sorted()
    // The scan promises order on `Id` alone, so `ORDER BY Id, Name` — whose key
    // list is longer than the promised prefix — is not satisfied and the sort
    // stays (the rows are not guaranteed ordered on `Name` within an `Id`).
    #expect(try sorts(plan(catalog,
        "SELECT Name FROM People ORDER BY Id, Name")))
  }

  @Test func `an expression sort key is kept`() throws {
    let catalog = try sorted()
    // `Id + 0` is not a bare slot, so the promised order can never match it and
    // the sort stays — a bare-slot key is the only shape the elimination reads.
    #expect(try sorts(plan(catalog, "SELECT Name FROM People ORDER BY Id + 0")))
  }

  @Test func `a sort over a materialised CTE is not wrongly eliminated`()
      throws {
    let catalog = try sorted()
    // A CTE is a materialised relation with no declared order — even one named
    // `People` shadowing the sorted base table must not borrow its order. The
    // CTE rows are supplied out of order, so a wrongly-eliminated sort would
    // leak them unsorted; the kept sort yields them ascending.
    let statement = try Statement(parsing:
        "WITH People(x) AS (VALUES (3), (1), (2)) "
      + "SELECT x FROM People ORDER BY x")
    let rows = try catalog.run(statement, .standard)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `eliminating a sort preserves the rows and order`() throws {
    // Differential: identical data, one catalog declaring the physical order
    // (sort eliminated) and one not (sort kept). Every `ORDER BY` clause must
    // yield byte-identical rows either way — the elimination changes the plan,
    // never the result.
    let ordered = try sorted()
    let plain = try unsorted()
    for clause in ["ORDER BY Id", "ORDER BY Id DESC", "ORDER BY Name",
                   "ORDER BY Id, Name", "ORDER BY Age, Id"] {
      let sql = "SELECT Id, Name, Age FROM People \(clause)"
      let left = try ordered.run(parse(query: sql), .standard)
      let right = try plain.run(parse(query: sql), .standard)
      #expect(left == right, "\(sql)")
    }
    // The declared-order catalog really does eliminate the `ORDER BY Id` sort
    // while the plain one keeps it — the differential is meaningful.
    #expect(try !sorts(plan(ordered, "SELECT Id FROM People ORDER BY Id")))
    #expect(try sorts(plan(plain, "SELECT Id FROM People ORDER BY Id")))
  }

  @Test func `an eliminated sort yields the ascending rows`() throws {
    let catalog = try sorted()
    // The observable result of the eliminated `ORDER BY Id`: the rows in
    // ascending `Id` order, exactly as the un-eliminated sort would produce.
    try catalog.expect("SELECT Name FROM People ORDER BY Id",
                       yields: [["Alice"], ["Bob"], ["Carol"], ["Dave"],
                                ["Eve"]])
  }

  @Test func `an eliminated sort over an empty seek yields no rows`() throws {
    let catalog = try sorted()
    // An empty seek range is trivially ordered; dropping the sort over it still
    // yields no rows.
    try catalog.empty("SELECT Name FROM People WHERE Id > 99 ORDER BY Id")
  }
}
