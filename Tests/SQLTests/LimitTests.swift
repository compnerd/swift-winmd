// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQL
import SQLTestSupport

// MARK: - Fixtures

/// A `People` relation of five rows, sorted ascending on its `Id` column.
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

/// A `Block` relation whose columns include `Offset` — a real WinMD column name
/// (`ManifestResource` and `FieldLayout` both declare one) — to prove the
/// reserved word `OFFSET` is still reachable as a column via a delimited
/// identifier (`"Offset"`).
private func blocks() throws -> FixtureCatalog {
  try Catalog {
    Relation("Block", ["Id": .integer, "Offset": .integer]) {
      Row(1, 100)
      Row(2, 200)
      Row(3, 300)
    }
  }
}

// MARK: - Helpers

/// Parses `text` to a query, failing on any other statement.
private func parse(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

// MARK: - Tests

struct LimitTests {
  @Test("FETCH FIRST n ROWS ONLY caps the row count")
  func caps() throws {
    try people().expect("SELECT Id FROM People FETCH FIRST 3 ROWS ONLY",
                        yields: [[1], [2], [3]])
  }

  @Test("FETCH FIRST 0 ROWS ONLY yields no rows")
  func zero() throws {
    try people().empty("SELECT Id FROM People FETCH FIRST 0 ROWS ONLY")
  }

  @Test("FETCH with an omitted count takes one row")
  func defaultsToOne() throws {
    // The ISO `FETCH FIRST ROW ONLY` — no count — takes a single row.
    try people().expect("SELECT Id FROM People FETCH FIRST ROW ONLY",
                        yields: [[1]])
  }

  @Test("ROW and ROWS, FIRST and NEXT, are interchangeable")
  func synonyms() throws {
    // `ROW`/`ROWS` and `FIRST`/`NEXT` are ISO synonyms — the singular and the
    // `NEXT` spelling parse to the same clause as the plural `FIRST` form.
    let catalog = try people()
    try catalog.expect("SELECT Id FROM People FETCH NEXT 1 ROW ONLY",
                       equals: "SELECT Id FROM People FETCH FIRST 1 ROWS ONLY")
    try catalog.expect("SELECT Id FROM People FETCH FIRST 1 ROWS ONLY",
                       yields: [[1]])
  }

  @Test("OFFSET n ROWS then FETCH skips then caps")
  func offset() throws {
    try people().expect(
        "SELECT Id FROM People OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY",
        yields: [[2], [3]])
  }

  @Test("OFFSET 0 ROWS is the same as no OFFSET")
  func zeroOffset() throws {
    let catalog = try people()
    try catalog.expect(
        "SELECT Id FROM People OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY",
        equals: "SELECT Id FROM People FETCH FIRST 2 ROWS ONLY")
    try catalog.expect(
        "SELECT Id FROM People OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY",
        yields: [[1], [2]])
  }

  @Test("OFFSET without a FETCH skips with no cap")
  func offsetOnly() throws {
    // An `OFFSET` written without a `FETCH` returns every row after the skip.
    try people().expect("SELECT Id FROM People OFFSET 3 ROWS",
                        yields: [[4], [5]])
  }

  @Test("FETCH after ORDER BY takes the top-N in sorted order")
  func afterOrder() throws {
    // Ordered by Age ascending, ties by source order (a stable sort): Bob(25),
    // Eve(25), Alice(30), Carol(30), Dave(40). The FETCH caps the ORDERED
    // result, so it takes the two lowest ages rather than the first two rows.
    try people().expect(
        "SELECT Name FROM People ORDER BY Age FETCH FIRST 2 ROWS ONLY",
        yields: [["Bob"], ["Eve"]])
  }

  @Test("OFFSET then FETCH after ORDER BY skips into the sorted result")
  func offsetAfterOrder() throws {
    // Descending by Id: Eve, Dave, Carol, Bob, Alice — skip 1, take 2.
    try people().expect("""
                 SELECT Name FROM People
                   ORDER BY Id DESC OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY
                 """, yields: [["Dave"], ["Carol"]])
  }

  @Test("OFFSET past the end yields no rows")
  func offsetPastEnd() throws {
    let catalog = try people()
    try catalog.empty("SELECT Id FROM People OFFSET 5 ROWS")
    try catalog.empty("SELECT Id FROM People OFFSET 10 ROWS")
  }

  @Test("a FETCH larger than the result yields every row")
  func largerThanResult() throws {
    let catalog = try people()
    try catalog.expect("SELECT Id FROM People FETCH FIRST 100 ROWS ONLY",
                       equals: "SELECT Id FROM People")
  }

  @Test("FETCH caps rows admitted by a seekable WHERE")
  func afterWhere() throws {
    // `Id >= 2` seeks to rows 2…5; the FETCH then caps that run to two rows.
    try people().expect(
        "SELECT Id FROM People WHERE Id >= 2 FETCH FIRST 2 ROWS ONLY",
        yields: [[2], [3]])
  }

  @Test("a reserved-word column is reachable via a delimited identifier")
  func offsetColumn() throws {
    // `OFFSET` is a reserved word, so a relation's `Offset` column is reached
    // by the standard delimited identifier `"Offset"`. It selects, orders, and
    // coexists with a genuine OFFSET/FETCH row-limiting clause.
    let catalog = try blocks()
    try catalog.expect("SELECT \"Offset\" FROM Block",
                       yields: [[100], [200], [300]])
    try catalog.expect("""
                SELECT "Offset" FROM Block
                  ORDER BY "Offset" DESC OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY
                """, yields: [[200]])
  }

  @Test("the row limit applies before a discarded row's projection")
  func beforeProjection() throws {
    // The cap sits below the projection, so a select list that would throw —
    // `1 / 0` — never runs for a row outside the page: FETCH 0 and an OFFSET
    // past the end return empty rather than dividing.
    let catalog = try people()
    try catalog.empty("SELECT 1 / 0 FROM People FETCH FIRST 0 ROWS ONLY")
    try catalog.empty("SELECT 1 / 0 FROM People OFFSET 10 ROWS")
    // A page that DOES admit a row still evaluates the projection (and throws),
    // confirming the guard is the empty page, not a skipped projection.
    catalog.expect("SELECT 1 / 0 FROM People FETCH FIRST 1 ROW ONLY",
                   fails: .divide)
  }

  @Test("a directly-built negative OFFSET or FETCH is rejected")
  func rejectsNegative() throws {
    // The parser cannot spell a negative count, but a direct `Limit` can — the
    // executor's skip and take would trap on it, so the engine rejects it as a
    // query error instead.
    guard case let .select(base) = try parse("SELECT Id FROM People") else {
      Issue.record("expected a single SELECT")
      return
    }
    let fault =
        SQLError.unsupported("OFFSET and FETCH row counts must be non-negative")
    let catalog = try people()
    let negativeOffset = Select(projection: base.projection, from: base.from,
                                limit: Limit(count: 1, offset: -1))
    #expect(throws: fault) {
      try catalog.run(.select(negativeOffset))
    }
    let negativeCount = Select(projection: base.projection, from: base.from,
                               limit: Limit(count: -1))
    #expect(throws: fault) {
      try catalog.run(.select(negativeCount))
    }
  }

  @Test("a near-maximal FETCH after an OFFSET does not overflow")
  func saturates() throws {
    // A `count` near `Int.max` plus a positive `offset` would overflow an
    // `offset + count` bound; capping by a prefix of the skipped slice returns
    // the remaining rows rather than trapping.
    try people().expect("""
                 SELECT Id FROM People
                   OFFSET 1 ROWS FETCH NEXT 9223372036854775807 ROWS ONLY
                 """, yields: [[2], [3], [4], [5]])
  }
}
