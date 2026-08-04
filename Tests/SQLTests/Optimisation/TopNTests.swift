// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A `People` relation carrying deliberate `Age` ties (30 twice, 25 twice) so
/// the bounded selection's stable original-index tie-break — a kept prefix
/// byte-identical to the full stable sort's head — is exercised across the
/// `offset + count` boundary.
private func people() throws -> FixtureCatalog {
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

/// A `Nulls` relation whose `Age` holds NULLs — NULL sorts first ascending,
/// last descending — so the fused selection reuses the engine's `less` order
/// rather than a separate comparator that could drift.
private func nulls() throws -> FixtureCatalog {
  try Catalog {
    Relation("Nulls", ["Id": .integer, "Name": .text, "Age": .integer]) {
      Row(1, "A", nil)
      Row(2, "B", 10)
      Row(3, "C", nil)
      Row(4, "D", 5)
    }
  }
}

// MARK: - Plan assertions

/// Whether `plan` carries a `.topN` node — the observable sign the `limit` over
/// `sort` fused into a bounded selection.
private func fused(_ plan: Plan) -> Bool {
  switch plan {
  case .topN: return true
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source), let .window(_, source):
    return fused(source)
  case let .derived(_, source, _, _):
    return fused(source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return fused(left) || fused(right)
  case .single, .values, .empty, .scan, .join, .apply:
    return false
  }
}

private func plan(_ catalog: borrowing FixtureCatalog, _ sql: String)
    throws -> Plan {
  try catalog.plan(of: parse(query: sql), Context(routines: .standard))
}

// MARK: - Tests

@Suite struct TopNTests {
  /// The fusion is a partial sort, so its result must be byte-identical to the
  /// full stable sort then the page slice. Compute the reference from the
  /// UN-fused full `ORDER BY` (no FETCH, so no `.topN` forms) and slice it in
  /// Swift, then check every `(offset, count)` page's fused query against it —
  /// a differential proof the optimisation preserves rows and order.
  @Test func `a fused top-N matches the full sort then page slice`() throws {
    let catalog = try people()
    for order in ["ORDER BY Age", "ORDER BY Age DESC",
                  "ORDER BY Age, Name", "ORDER BY Name"] {
      let reference = try catalog.run(
          parse(query: "SELECT Id, Name FROM People \(order)"), .standard)
      for offset in 0 ... 6 {
        for count in 0 ... 6 {
          let sql = "SELECT Id, Name FROM People \(order) "
                  + "OFFSET \(offset) ROWS FETCH FIRST \(count) ROWS ONLY"
          // A bounded FETCH over a sort must actually fuse (`count == 0` still
          // fuses — its bound is `offset`, keeping nothing after the slice).
          #expect(try fused(plan(catalog, sql)), "\(sql)")
          let paged = Array(reference.dropFirst(offset).prefix(count))
          #expect(try catalog.run(parse(query: sql), .standard) == paged,
                  "\(sql)")
        }
      }
    }
  }

  @Test func `a fused top-N keeps the stable tie-break at the boundary`()
      throws {
    let catalog = try people()
    // Ascending by Age the stable order is Bob(25,#2), Eve(25,#5),
    // Alice(30,#1), Carol(30,#3), Dave(40,#4). OFFSET 1 FETCH 2 selects head 3
    // (bound = 3) and pages: among the equal-Age-30 rows the lower input index
    // (Alice) wins over Carol, exactly the full stable sort's choice.
    try catalog.expect(
        "SELECT Name FROM People ORDER BY Age OFFSET 1 ROWS "
      + "FETCH FIRST 2 ROWS ONLY", yields: [["Eve"], ["Alice"]])
  }

  @Test func `a fused top-N orders NULLs first ascending`() throws {
    let catalog = try nulls()
    // NULL sorts before every value ascending, so the two NULL-Age rows lead —
    // in input order (A#1 before C#3) by the stable tie-break.
    try catalog.expect(
        "SELECT Name FROM Nulls ORDER BY Age FETCH FIRST 2 ROWS ONLY",
        yields: [["A"], ["C"]])
  }

  @Test func `a fused top-N orders NULLs last descending`() throws {
    let catalog = try nulls()
    // Descending, NULL sorts last, so the two non-NULL rows lead: B(10) then
    // D(5).
    try catalog.expect(
        "SELECT Name FROM Nulls ORDER BY Age DESC FETCH FIRST 2 ROWS ONLY",
        yields: [["B"], ["D"]])
  }

  @Test func `a fused top-N over an offset past the end yields no rows`()
      throws {
    let catalog = try people()
    // n = 5 rows, offset 10: the selection keeps every row it can, the slice
    // drops them all — matching the un-fused full sort then limit.
    try catalog.empty(
        "SELECT Name FROM People ORDER BY Age OFFSET 10 ROWS "
      + "FETCH FIRST 2 ROWS ONLY")
  }

  @Test func `a fused top-N over a short remainder takes what remains`()
      throws {
    let catalog = try people()
    // offset 4 leaves one row (Dave, the largest Age); FETCH 5 takes just it.
    try catalog.expect(
        "SELECT Name FROM People ORDER BY Age OFFSET 4 ROWS "
      + "FETCH FIRST 5 ROWS ONLY", yields: [["Dave"]])
  }

  @Test func `a fused top-N still evaluates a throwing sort key per row`()
      throws {
    let catalog = try people()
    // `1 / (Age - Age)` divides by zero for every row. The keys are evaluated
    // per row up front — exactly as the full sort does — before any selection,
    // so the fusion must still fault rather than skip the throwing key on the
    // rows it would drop.
    catalog.expect(
        "SELECT Name FROM People ORDER BY 1 / (Age - Age) "
      + "FETCH FIRST 1 ROWS ONLY", fails: .divide)
  }

  @Test func `an Int-max FETCH degrades to a full sort without trapping`()
      throws {
    let catalog = try people()
    // `offset + count` saturates rather than overflowing: a near-`Int.max`
    // FETCH keeps every row (the bound exceeds the row count), so the result is
    // the whole ordered relation.
    let sql = "SELECT Name FROM People ORDER BY Age "
            + "OFFSET 1 ROWS FETCH FIRST 9223372036854775807 ROWS ONLY"
    #expect(try fused(plan(catalog, sql)))
    try catalog.expect(sql,
                       yields: [["Eve"], ["Alice"], ["Carol"], ["Dave"]])
  }

  @Test func `a DISTINCT ORDER BY FETCH does not fuse and stays correct`()
      throws {
    let catalog = try people()
    // The cap sits over the `.distinct`, not the `.sort`, so no `.topN` forms;
    // the distinct ages ascending are 25, 30, 40 and the FETCH takes the first
    // two.
    let sql = "SELECT DISTINCT Age FROM People ORDER BY Age "
            + "FETCH FIRST 2 ROWS ONLY"
    #expect(try !fused(plan(catalog, sql)))
    try catalog.expect(sql, yields: [[25], [30]])
  }
}
