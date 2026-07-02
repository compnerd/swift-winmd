// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - In-memory adapter

/// An in-memory relation: a fixed schema plus rows of typed values.
///
/// The `sorted` flag marks a single integral column whose rows are stored in
/// ascending order; `bound` reports a boundary for that column and `nil` for
/// any other, so a `FETCH` after a seekable `WHERE` still exercises the cap.
/// This harness knows nothing of WinMD — it is a self-contained fixture for the
/// row-limiting (`OFFSET`/`FETCH`) tests, deliberately independent of
/// `EngineTests.swift` so the two files reconcile cleanly.
private struct LimitRelation: Sendable {
  let names: Array<String>
  let records: Array<Array<Value>>
  /// The ordinal of the sorted column, or `nil` if the relation is unsorted.
  let sorted: Int?

  init(_ names: Array<String>, _ records: Array<Array<Value>>,
       sorted: Int? = nil) {
    self.names = names
    self.records = records
    self.sorted = sorted
  }
}

/// A `Catalog` over a dictionary of named relations.
private struct LimitMemory: Catalog {
  let relations: Dictionary<String, LimitRelation>

  init(_ relations: Dictionary<String, LimitRelation>) {
    self.relations = relations
  }

  func table(named name: String) -> LimitTable? {
    guard let relation = relations[name] else { return nil }
    return LimitTable(relation)
  }
}

/// A `Table` over one in-memory relation.
private struct LimitTable: Table {
  let relation: LimitRelation

  init(_ relation: LimitRelation) {
    self.relation = relation
  }

  var width: Int { relation.names.count }

  var names: Array<String> { relation.names }

  func ordinal(of name: String) -> Int? {
    relation.names.firstIndex(of: name)
  }

  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? {
    guard column == relation.sorted else { return nil }
    var lower = 0
    var upper = relation.records.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      guard case let .integer(cell) = relation.records[middle][column] else {
        return nil
      }
      let before = strict ? cell <= value : cell < value
      if before {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  func cursor() -> LimitCursor {
    LimitCursor(relation)
  }
}

/// An index-addressed cursor over a relation's rows.
private struct LimitCursor: Cursor {
  let relation: LimitRelation

  init(_ relation: LimitRelation) {
    self.relation = relation
  }

  var count: Int { relation.records.count }

  func row(_ index: Int) -> LimitRow? {
    guard index < relation.records.count else { return nil }
    return LimitRow(relation, index)
  }
}

/// A positional view over one row's cells.
private struct LimitRow: Row {
  let relation: LimitRelation
  let index: Int

  init(_ relation: LimitRelation, _ index: Int) {
    self.relation = relation
    self.index = index
  }

  subscript(_ column: Int) -> Value {
    borrowing get { relation.records[index][column] }
  }
}

// MARK: - Fixtures

/// A `People` relation of five rows, sorted ascending on its `Id` column.
private func people() -> LimitMemory {
  let records = [
    [.integer(1), .text("Alice"), .integer(30)],
    [.integer(2), .text("Bob"), .integer(25)],
    [.integer(3), .text("Carol"), .integer(30)],
    [.integer(4), .text("Dave"), .integer(40)],
    [.integer(5), .text("Eve"), .integer(25)],
  ] as Array<Array<Value>>
  return LimitMemory(["People": LimitRelation(["Id", "Name", "Age"], records,
                                              sorted: 0)])
}

/// A `Block` relation whose columns include `Offset` — a real WinMD column name
/// (`ManifestResource` and `FieldLayout` both declare one) — to prove the
/// reserved word `OFFSET` is still reachable as a column via a delimited
/// identifier (`"Offset"`).
private func blocks() -> LimitMemory {
  let records = [
    [.integer(1), .integer(100)],
    [.integer(2), .integer(200)],
    [.integer(3), .integer(300)],
  ] as Array<Array<Value>>
  return LimitMemory(["Block": LimitRelation(["Id", "Offset"], records)])
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

/// Runs `text` against the `People` catalog, yielding the projected rows.
private func run(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), people())
}

// MARK: - Tests

struct LimitTests {
  @Test("FETCH FIRST n ROWS ONLY caps the row count")
  func caps() throws {
    let rows = try run("SELECT Id FROM People FETCH FIRST 3 ROWS ONLY")
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test("FETCH FIRST 0 ROWS ONLY yields no rows")
  func zero() throws {
    #expect(try run("SELECT Id FROM People FETCH FIRST 0 ROWS ONLY") == [])
  }

  @Test("FETCH with an omitted count takes one row")
  func defaultsToOne() throws {
    // The ISO `FETCH FIRST ROW ONLY` — no count — takes a single row.
    #expect(try run("SELECT Id FROM People FETCH FIRST ROW ONLY")
            == [[.integer(1)]])
  }

  @Test("ROW and ROWS, FIRST and NEXT, are interchangeable")
  func synonyms() throws {
    // `ROW`/`ROWS` and `FIRST`/`NEXT` are ISO synonyms — the singular and the
    // `NEXT` spelling parse to the same clause as the plural `FIRST` form.
    let canonical = try run("SELECT Id FROM People FETCH FIRST 1 ROWS ONLY")
    #expect(try run("SELECT Id FROM People FETCH NEXT 1 ROW ONLY") == canonical)
    #expect(canonical == [[.integer(1)]])
  }

  @Test("OFFSET n ROWS then FETCH skips then caps")
  func offset() throws {
    let rows =
        try run("SELECT Id FROM People OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY")
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test("OFFSET 0 ROWS is the same as no OFFSET")
  func zeroOffset() throws {
    let rows =
        try run("SELECT Id FROM People OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY")
    let bare = try run("SELECT Id FROM People FETCH FIRST 2 ROWS ONLY")
    #expect(rows == bare)
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }

  @Test("OFFSET without a FETCH skips with no cap")
  func offsetOnly() throws {
    // An `OFFSET` written without a `FETCH` returns every row after the skip.
    let rows = try run("SELECT Id FROM People OFFSET 3 ROWS")
    #expect(rows == [[.integer(4)], [.integer(5)]])
  }

  @Test("FETCH after ORDER BY takes the top-N in sorted order")
  func afterOrder() throws {
    // Ordered by Age ascending, ties by source order (a stable sort): Bob(25),
    // Eve(25), Alice(30), Carol(30), Dave(40). The FETCH caps the ORDERED
    // result, so it takes the two lowest ages rather than the first two rows.
    let rows =
        try run("SELECT Name FROM People ORDER BY Age FETCH FIRST 2 ROWS ONLY")
    #expect(rows == [[.text("Bob")], [.text("Eve")]])
  }

  @Test("OFFSET then FETCH after ORDER BY skips into the sorted result")
  func offsetAfterOrder() throws {
    // Descending by Id: Eve, Dave, Carol, Bob, Alice — skip 1, take 2.
    let rows = try run("""
        SELECT Name FROM People
          ORDER BY Id DESC OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY
        """)
    #expect(rows == [[.text("Dave")], [.text("Carol")]])
  }

  @Test("OFFSET past the end yields no rows")
  func offsetPastEnd() throws {
    #expect(try run("SELECT Id FROM People OFFSET 5 ROWS") == [])
    #expect(try run("SELECT Id FROM People OFFSET 10 ROWS") == [])
  }

  @Test("a FETCH larger than the result yields every row")
  func largerThanResult() throws {
    let all = try run("SELECT Id FROM People")
    #expect(try run("SELECT Id FROM People FETCH FIRST 100 ROWS ONLY") == all)
  }

  @Test("FETCH caps rows admitted by a seekable WHERE")
  func afterWhere() throws {
    // `Id >= 2` seeks to rows 2…5; the FETCH then caps that run to two rows.
    let rows =
        try run("SELECT Id FROM People WHERE Id >= 2 FETCH FIRST 2 ROWS ONLY")
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test("a reserved-word column is reachable via a delimited identifier")
  func offsetColumn() throws {
    // `OFFSET` is a reserved word, so a relation's `Offset` column is reached
    // by the standard delimited identifier `"Offset"`. It selects, orders, and
    // coexists with a genuine OFFSET/FETCH row-limiting clause.
    let catalog = blocks()
    #expect(try Engine.run(parse("SELECT \"Offset\" FROM Block"), catalog)
            == [[.integer(100)], [.integer(200)], [.integer(300)]])
    #expect(try Engine.run(parse("""
        SELECT "Offset" FROM Block
          ORDER BY "Offset" DESC OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY
        """), catalog) == [[.integer(200)]])
  }

  @Test("the row limit applies before a discarded row's projection")
  func beforeProjection() throws {
    // The cap sits below the projection, so a select list that would throw —
    // `1 / 0` — never runs for a row outside the page: FETCH 0 and an OFFSET
    // past the end return empty rather than dividing.
    #expect(try run("SELECT 1 / 0 FROM People FETCH FIRST 0 ROWS ONLY") == [])
    #expect(try run("SELECT 1 / 0 FROM People OFFSET 10 ROWS") == [])
    // A page that DOES admit a row still evaluates the projection (and throws),
    // confirming the guard is the empty page, not a skipped projection.
    #expect(throws: SQLError.self) {
      try run("SELECT 1 / 0 FROM People FETCH FIRST 1 ROW ONLY")
    }
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
    let negativeOffset = Select(projection: base.projection, from: base.from,
                                limit: Limit(count: 1, offset: -1))
    #expect(throws: fault) { try Engine.run(.select(negativeOffset), people()) }
    let negativeCount = Select(projection: base.projection, from: base.from,
                               limit: Limit(count: -1))
    #expect(throws: fault) { try Engine.run(.select(negativeCount), people()) }
  }

  @Test("a near-maximal FETCH after an OFFSET does not overflow")
  func saturates() throws {
    // A `count` near `Int.max` plus a positive `offset` would overflow an
    // `offset + count` bound; capping by a prefix of the skipped slice returns
    // the remaining rows rather than trapping.
    let rows = try run("""
        SELECT Id FROM People
          OFFSET 1 ROWS FETCH NEXT 9223372036854775807 ROWS ONLY
        """)
    #expect(rows == [[.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }
}
