// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Single-relation tests

struct EngineProjectionTests {
  @Test func `SELECT * yields every real column and excludes the virtual Id`() throws {
    let rows = try answer("SELECT * FROM People WHERE Id = 1")
    // Three real columns; `Id` is virtual and never in `*`.
    #expect(rows == [[.integer(1), .text("Alice"), .integer(30)]])
  }

  @Test func `SELECT names yields the named columns in order`() throws {
    try roster().expect("SELECT Name, Id FROM People WHERE Id = 2",
                        yields: [["Bob", 2]])
  }

  @Test func `a named projection may include the virtual Id column`() throws {
    let rows = try answer("SELECT Id, Name FROM People WHERE Name = 'Carol'")
    // Carol is the third row; her 1-based `Id` is 3.
    #expect(rows == [[.integer(3), .text("Carol")]])
  }

  @Test func `an unknown column is reported`() throws {
    #expect(throws: SQLError.column("Missing")) {
      try answer("SELECT Missing FROM People")
    }
  }

  @Test func `an unknown relation is reported`() throws {
    try roster().expect("SELECT * FROM Absent", fails: .relation("Absent"))
  }
}

struct EngineFilterTests {
  @Test func `equality on a text column`() throws {
    try roster().expect("SELECT Id FROM People WHERE Name = 'Carol'",
                        yields: [[3]])
  }

  @Test func `a range on the sorted column`() throws {
    try roster().expect("SELECT Id FROM People WHERE Id >= 4",
                        yields: [[4], [5]])
  }

  @Test func `an AND of a seekable conjunct and a residual`() throws {
    let rows = try answer("SELECT Name FROM People WHERE Id > 1 AND Age = 30")
    #expect(rows == [[.text("Carol")]])
  }

  @Test func `an OR scans and admits either side`() throws {
    let rows =
        try answer("SELECT Id FROM People WHERE Id = 1 OR Name = 'Eve'")
    #expect(rows == [[.integer(1)], [.integer(5)]])
  }

  @Test func `a NOT scans and negates`() throws {
    try roster().expect("SELECT Id FROM People WHERE NOT Age = 30",
                        yields: [[2], [4], [5]])
  }

  @Test func `a filter on the virtual Id column`() throws {
    try roster().expect("SELECT Name FROM People WHERE Id = 4",
                        yields: [["Dave"]])
  }
}

struct EngineOrderTests {
  @Test func `ORDER BY ascending on an integer column`() throws {
    let rows = try answer("SELECT Id FROM People ORDER BY Age ASC")
    // Ages: Bob 25, Eve 25, Alice 30, Carol 30, Dave 40 — a stable sort keeps
    // the scan order within an equal-key group.
    #expect(rows == [[.integer(2)], [.integer(5)], [.integer(1)],
                     [.integer(3)], [.integer(4)]])
  }

  @Test func `ORDER BY descending on a text column`() throws {
    let rows = try answer("SELECT Name FROM People ORDER BY Name DESC")
    #expect(rows == [[.text("Eve")], [.text("Dave")], [.text("Carol")],
                     [.text("Bob")], [.text("Alice")]])
  }
}

struct EngineCompoundOrderTests {
  @Test func `a single-key ORDER BY still orders as before`() throws {
    // The one-key case is unchanged: ages ascending, ties kept in scan order.
    let rows = try answer("SELECT Id FROM People ORDER BY Age ASC")
    #expect(rows == [[.integer(2)], [.integer(5)], [.integer(1)],
                     [.integer(3)], [.integer(4)]])
  }

  @Test func `two keys order by the first, then the second`() throws {
    // Age ascending, ties by Name ascending: {Bob,Eve} at 25 → Bob, Eve;
    // {Alice,Carol} at 30 → Alice, Carol; then Dave.
    let rows = try answer("SELECT Name FROM People ORDER BY Age, Name")
    #expect(rows == [[.text("Bob")], [.text("Eve")], [.text("Alice")],
                     [.text("Carol")], [.text("Dave")]])
  }

  @Test func `each key carries its own direction`() throws {
    // Age descending, ties by Name ascending: Dave(40); Alice, Carol (30);
    // Bob, Eve (25).
    let rows =
        try answer("SELECT Name FROM People ORDER BY Age DESC, Name ASC")
    #expect(rows == [[.text("Dave")], [.text("Alice")], [.text("Carol")],
                     [.text("Bob")], [.text("Eve")]])
  }

  @Test func `a later key breaks ties the first key leaves`() throws {
    // Age ascending leaves {Bob,Eve} and {Alice,Carol} tied; a DESC Name key
    // reorders each pair against the scan order (Eve before Bob, Carol before
    // Alice) — proof the second key, not the input order, settles the ties.
    let rows = try answer("SELECT Name FROM People ORDER BY Age ASC, Name DESC")
    #expect(rows == [[.text("Eve")], [.text("Bob")], [.text("Carol")],
                     [.text("Alice")], [.text("Dave")]])
  }

  @Test func `three keys settle rows the first two leave equal`() throws {
    // Class ascending, Score ascending, Name ascending. Class A: Bob(70), then
    // the 80s by Name — Ada, Mel, Yan. Class B: both 90, by Name — Amy, Zed.
    let rows =
        try grades("SELECT Id FROM Grade ORDER BY Class, Score, Name")
    #expect(rows == [[.integer(6)], [.integer(3)], [.integer(5)],
                     [.integer(2)], [.integer(4)], [.integer(1)]])
  }

  @Test func `a compound ORDER BY is stable across all keys`() throws {
    // Class and Score alone leave the three Class-A/Score-80 rows tied; with no
    // further key the sort keeps their scan order — Yan(2), Ada(3), Mel(5).
    let rows = try grades("SELECT Id FROM Grade ORDER BY Class, Score")
    #expect(rows == [[.integer(6)], [.integer(2)], [.integer(3)],
                     [.integer(5)], [.integer(1)], [.integer(4)]])
  }

  @Test func `FETCH takes the top-N of a compound order`() throws {
    // Age descending, ties by Name ascending, then the first two rows: Dave(40)
    // and the lower-named of the 30s, Alice.
    try roster().expect("""
        SELECT Name FROM People
          ORDER BY Age DESC, Name ASC FETCH FIRST 2 ROWS ONLY
        """,
        yields: [["Dave"], ["Alice"]])
  }

  @Test func `OFFSET then FETCH pages into a compound order`() throws {
    // The full compound order is Dave, Alice, Carol, Bob, Eve; skip 1, take 2.
    try roster().expect("""
        SELECT Name FROM People
          ORDER BY Age DESC, Name ASC OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY
        """,
        yields: [["Alice"], ["Carol"]])
  }
}

struct EngineProjectionPushdownTests {
  @Test func `a query referencing few columns of a wide relation works`() throws {
    // The relation has ten columns; the query reads only C0 (filter, project),
    // C5 (project), and C8 (order). The leaf materialises just those, but the
    // result is exactly as if every column were copied.
    try wide().expect("""
        SELECT C5, C0 FROM Wide WHERE C0 >= 10 ORDER BY C8 DESC
        """,
        yields: [[35, 30], [25, 20], [15, 10]])
  }
}

struct EngineSeekTests {
  @Test func `the seek path and the scan path return identical results`() throws {
    // `Id >= 2` seeks the sorted column; the same selection by `Name` (which
    // `bound` reports unseekable) scans. Both must yield the same rows.
    let seek = try answer("SELECT Id FROM People WHERE Id >= 2 AND Id <= 4")
    #expect(seek == [[.integer(2)], [.integer(3)], [.integer(4)]])

    let scan =
        try answer("SELECT Id FROM People WHERE Name >= 'Bob' AND Name <= 'Dave'")
    #expect(scan == seek)
  }
}

/// A seekable but unordered column (a decoded coded-index key) is
/// equality-seekable only: an equality seeks its exact run and the join
/// re-tests per row, but a range must not consume the raw boundary — the raw
/// run brackets one tag's value while the other tags interleaved by row decode
/// to `NULL` and lie inside the raw range. `bound` returns a boundary for both,
/// so before the fix `Engine.boundaries` consumed a range as a standalone seek
/// and leaked the other-tag rows (no residual recheck on the scan-seek path).
/// The fix gates the range cases on `Table.ordered`, so a range scans and
/// filters instead.
///
/// The scenario is driven through the in-memory `Attribute` table rather than a
/// sorted `WinMD.Storage` fixture: assembling a physically-sorted mixed-tag
/// `CustomAttribute` in the byte-buffer harness is impractical, and the leak is
/// purely a property of `boundaries`/`bound` over an unordered seekable column,
/// which the memory table models faithfully (stored raw
/// `(Id << EngineCoded.bits) | tag`, decoded to the `TypeDef` `Id` or `NULL`).
/// The engine-level plan-shape assertion complements the two result assertions.
struct EngineCodedKeyTests {
  @Test func `a range on an unordered coded key scans and admits only its own rows`() throws {
    // `Parent < 5` must return only the TypeDef-tagged rows whose decoded
    // `Id` is `< 5` (td1, td2, td4) — never the other-tag rows (other-a, -b,
    // -c), which decode to NULL. Before the fix the raw boundary
    // `0 ..< bound(5)` seeked the low raw run, sweeping in the interleaved NULLs.
    let rows = try attributes("SELECT Name FROM Attribute WHERE Parent < 5")
    #expect(rows == [[.text("td1")], [.text("td2")], [.text("td4")]])
  }

  @Test func `a range equals the correct scan-and-filter result`() throws {
    // The seek path (`Parent < 5`) must equal a filter that cannot seek at all
    // (`Name < 'z'` over the same rows, restricted to the tagged ones) — i.e.
    // the range yields exactly the rows a full scan-and-filter would.
    let seek = try attributes("SELECT Name FROM Attribute WHERE Parent < 5")
    let scan = try attributes("""
        SELECT Name FROM Attribute WHERE Parent < 5 AND Name < 'z'
        """)
    #expect(seek == scan)
  }

  @Test func `an equality on an unordered coded key still seeks its exact run`() throws {
    // Equality is always seekable — the exact coded run brackets exactly the
    // rows that decode to the value, and a join rechecks — so `Parent = 4`
    // returns just td4.
    let rows = try attributes("SELECT Name FROM Attribute WHERE Parent = 4")
    #expect(rows == [[.text("td4")]])
  }

  @Test func `an equality on zero rejects a null coded reference rather than seeking`() throws {
    // A decoded row is 1-based, so `Parent = 0` is `NULL = 0` for every row —
    // UNKNOWN, admitting none. Row 0's stored raw cell is `(0 << 2) | 0 == 0`,
    // which encodes exactly the target the equality would seek; before the fix
    // `bound(0, …)` bracketed that raw run and `Catalog.seek` consumed it with no
    // residual recheck, leaking the null-reference row. The fix returns `nil`
    // for a non-positive decoded Id, so the query scans and filters, and the
    // decoded `NULL` correctly fails `= 0`.
    let rows = try attributes("SELECT Name FROM Attribute WHERE Parent = 0")
    #expect(rows.isEmpty)
  }

  @Test func `an equality too large to encode rejects rather than seeking an alias`() throws {
    // A decoded Id must be encodable without truncation. `(1 << 62) + 6` is
    // positive but past `Int.max >> EngineCoded.bits`, so `(value << 2) | 0` shifts the
    // high `1` clear out of the word and aliases raw `24` — the same raw cell as
    // `td6` (`(6 << 2) | 0`). Before the upper-bound guard, `bound` bracketed
    // that aliased run and `Catalog.seek` consumed the standalone equality with no
    // residual recheck, returning td6 for a value no decoded key equals. The
    // guard returns `nil` for the unencodable value, so the query scans and
    // filters — every decoded key is a small Id or NULL, none equals the huge
    // value — and admits nothing.
    let alias = (1 << 62) + 6
    let rows =
        try attributes("SELECT Name FROM Attribute WHERE Parent = \(alias)")
    #expect(rows.isEmpty)
  }

  @Test func `an equality plans a seek, a range plans a scan-and-filter`() throws {
    // The plan shape proves the gate directly: equality reaches a seeked scan
    // with no residual filter; a range reaches a raw scan under a filter.
    let catalog = attributes()

    let equal = try parse("SELECT Name FROM Attribute WHERE Parent = 4")
    let equalPlan =
        try catalog.optimise(catalog.compile(equal), [:])
    #expect(sought(equalPlan))
    #expect(!filters(equalPlan))

    let less = try parse("SELECT Name FROM Attribute WHERE Parent < 5")
    let lessPlan =
        try catalog.optimise(catalog.compile(less), [:])
    #expect(!sought(lessPlan))
    #expect(filters(lessPlan))
  }

  @Test func `a sorted key with a leading NULL does not seek it into an equality`() throws {
    // NULLs sort first, so a direct seek would bracket the NULL row into the
    // `K = 1` range; an equality seek drops the residual, so the sorted-key
    // seek must fall back to a scan and filter the NULL out, not return it.
    let catalog = try Catalog {
      Relation("T", ["K": .integer, "V": .text], sorted: "K") {
        Row(nil, "null")
        Row(1, "one")
      }
    }
    try catalog.expect("SELECT V FROM T WHERE K = 1", yields: [["one"]])
  }

  @Test func `a case-varied sorted-column name is still seekable`() throws {
    // The fixture folds `sorted: "id"` to the declared `Id`, so an equality on
    // it plans a seek — a case mismatch must not silently build an unsorted
    // relation that drops to a scan the plan-shape tests mean to cover.
    let catalog = try Catalog {
      Relation("T", ["Id": .integer], sorted: "id") {
        Row(1)
        Row(2)
      }
    }
    let query = try parse("SELECT * FROM T WHERE Id = 1")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(sought(plan))
  }

  @Test func `an empty sorted fixture still plans a seek`() throws {
    // A sorted relation with no rows has no leading cell to disqualify the
    // seek; it plans a seek over the empty range, not a scan.
    let catalog = try Catalog {
      Relation("T", ["Id": .integer], sorted: "Id")
    }
    let query = try parse("SELECT * FROM T WHERE Id = 1")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(sought(plan))
  }
}

struct EngineQualifierTests {
  @Test func `a qualifier matching the alias resolves the column`() throws {
    try roster().expect("SELECT p.Name FROM People AS p WHERE Id = 1",
                        yields: [["Alice"]])
  }

  @Test func `a qualifier matching the table name resolves the column`() throws {
    try roster().expect("SELECT People.Name FROM People WHERE Id = 1",
                        yields: [["Alice"]])
  }

  @Test func `a qualifier naming neither the alias nor the table is reported`() throws {
    // `x` names neither the alias `p` nor the table `People`; a single-relation
    // query rejects it rather than dropping the qualifier and binding `Name`.
    #expect(throws: SQLError.column("Name")) {
      try answer("SELECT x.Name FROM People AS p")
    }
  }

  @Test func `a relation and a view name resolve case-insensitively`() throws {
    // The fixture folds a name like the engine and the WinMD catalog do, so a
    // query need not match the declared relation/view casing.
    let catalog = try Catalog {
      Relation("People", ["Id": .integer, "Name": .text]) {
        Row(1, "Alice")
      }
      try View("Adults", "SELECT Name FROM People", as: ["Name"])
    }
    try catalog.expect("SELECT Name FROM people", yields: [["Alice"]])
    try catalog.expect("SELECT Name FROM adults", yields: [["Alice"]])
  }

  @Test func `a qualifier naming a different table is reported`() throws {
    // The reviewer's case: `Child.Name` against `FROM Parent` must not resolve
    // to `Parent`'s `Name`; the qualifier names a relation not in scope.
    #expect(throws: SQLError.column("Name")) {
      try join("SELECT Child.Name FROM Parent")
    }
  }
}

