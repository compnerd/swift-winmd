// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - In-memory adapter

// The `~Escapable` in-memory adapter and its coded-key/counter machinery now
// live in the shared `SQLTestSupport` target, built once for every SQL test.
// The fluent builders (Catalog/Relation/Row/View) author the fixtures below;
// these aliases keep the store's short names for the inline catalogs the
// @testable plan-shape and read-counting tests still assemble directly (with a
// seekable-unordered `coded` column or a shared `counter` the builders do not
// spell). The store's `Relation` construction is named `FixtureRelation` to
// leave the plain `Relation` name to the builder.
private typealias Field = FixtureField
private typealias Counter = FixtureCounter
private typealias Coded = FixtureCoded
private typealias Memory = FixtureCatalog

// MARK: - Fixtures

/// The single-relation catalog: a `People` relation sorted on its `Id` column.
private func people() throws -> Memory {
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

/// A single-relation catalog for compound ordering: a `Grade` relation whose
/// `Class`/`Score` columns hold deliberate ties, so a three-key `ORDER BY
/// Class, Score, Name` needs the third key to settle rows the first two leave
/// equal. The rows are stored out of every non-`Id` order, so a sort is never a
/// no-op.
private func grades() throws -> Memory {
  try Catalog {
    Relation("Grade", ["Id": .integer, "Class": .text, "Score": .integer,
                       "Name": .text], sorted: "Id") {
      Row(1, "B", 90, "Zed")
      Row(2, "A", 80, "Yan")
      Row(3, "A", 80, "Ada")
      Row(4, "B", 90, "Amy")
      Row(5, "A", 80, "Mel")
      Row(6, "A", 70, "Bob")
    }
  }
}

/// A catalog modelling a decoded coded-index key: an `Attribute` relation whose
/// `Parent` column is seekable but not ordered. It stands in for a
/// `CustomAttribute` physically sorted on its raw `Parent` coded index with
/// mixed tags — each row's stored `Parent` is the raw coded cell
/// `(Id << Coded.bits) | tag` (tag `0` a `TypeDef`, tag `1` another table),
/// sorted ascending; the `Row` decodes it, so the column reads as the target
/// `TypeDef` `Id` (tag `0`) or `NULL` (tag `1`). The raw run brackets one
/// tag's equal value, but the tag-1 rows interleaved by row decode to `NULL`, so
/// a range on the decoded column must not seek the raw boundary — it would
/// return other-tag rows that decode outside the range.
///
/// The `Parent` column is seekable-but-unordered, so it is built directly as a
/// `FixtureRelation` with `coded: 0` — the seekable-unordered marker the fluent
/// `Relation` (whose only marker is `sorted:`) does not spell.
private func attributes() -> Memory {
  let fields = [
    Field(name: "Parent", type: .integer),
    Field(name: "Name", type: .text),
  ]
  // Stored `Parent` = `(Id << 2) | tag` (Coded.bits == 2), ascending.
  // Decoded `Parent`:
  //   raw  0 = (0<<2)|0 → NULL (null reference — row 0)
  //   raw  4 = (1<<2)|0 → TypeDef 1     raw  5 = (1<<2)|1 → NULL
  //   raw  8 = (2<<2)|0 → TypeDef 2     raw 13 = (3<<2)|1 → NULL
  //   raw 16 = (4<<2)|0 → TypeDef 4     raw 17 = (4<<2)|1 → NULL
  //   raw 20 = (5<<2)|0 → TypeDef 5     raw 24 = (6<<2)|0 → TypeDef 6
  let records = [
    [.integer(0), .text("null-ref")],
    [.integer(4), .text("td1")],
    [.integer(5), .text("other-a")],
    [.integer(8), .text("td2")],
    [.integer(13), .text("other-b")],
    [.integer(16), .text("td4")],
    [.integer(17), .text("other-c")],
    [.integer(20), .text("td5")],
    [.integer(24), .text("td6")],
  ] as Array<Array<Value>>
  return Memory(["Attribute": FixtureRelation(fields, records, coded: 0)])
}

/// A wide catalog: a `Wide` relation of ten columns, to prove a query that
/// references only a few of them still works (projection pushdown).
///
/// The ten columns and four rows are generated, so it is built directly as a
/// `FixtureRelation` rather than a literal-per-row fluent `Relation`.
private func wide() -> Memory {
  let fields = (0 ..< 10).map { Field(name: "C\($0)", type: .integer) }
  let records = (0 ..< 4).map { row in
    (0 ..< 10).map { Value.integer(row * 10 + $0) }
  }
  return Memory(["Wide": FixtureRelation(fields, records, sorted: 0)])
}

/// The join catalog: a `Parent` relation sorted on `Id`, an unsorted twin
/// `ParentUnsorted` (same rows, no seekable column), and a `Child` relation
/// whose `Pid` is a foreign key to a parent `Id`. The `Ordered` relation has no
/// stored key — a join on it keys off its virtual `Id`.
private func family() throws -> Memory {
  try Catalog {
    Relation("Parent", ["Id": .integer, "Name": .text], sorted: "Id") {
      Row(1, "Ada")
      Row(2, "Bee")
      Row(3, "Cid")
    }
    Relation("ParentUnsorted", ["Id": .integer, "Name": .text]) {
      Row(1, "Ada")
      Row(2, "Bee")
      Row(3, "Cid")
    }
    Relation("Child", ["Pid": .integer, "Name": .text]) {
      Row(1, "Ann")
      Row(1, "Amy")
      Row(2, "Bob")
      Row(9, "Orphan")
    }
    // A keyless relation: its identity is its 1-based row position (`Id`).
    Relation("Ordered", ["Label": .text]) {
      Row("first")
      Row("second")
      Row("third")
    }
  }
}

/// The view catalog: the `family` relations plus two registered views — `Adults`
/// (a single-relation projection over `Parent`) and `Pairs` (a projection over
/// the `Parent`/`Child` foreign-key join). A view is queried like a table, and
/// `Pairs` proves a view whose definition is itself a join.
private func views() throws -> Memory {
  // Registered over the `family` relations, so the view bodies resolve their
  // `Parent`/`Child` against the same base tables the other join tests use.
  let catalog = try Catalog {
    // SELECT Id, Name FROM Parent WHERE Id >= 2 — columns exposed as Key/Label.
    try View("Adults", "SELECT Id, Name FROM Parent WHERE Id >= 2",
             as: ["Key", "Label"])
    // A view over a join, its two projected columns exposed as Parent and Kid.
    try View("Pairs", """
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """, as: ["Parent", "Kid"])
    // A parameterized view whose bound key seeks inside its sub-plan when :id
    // is supplied.
    try View("Picked", "SELECT Id, Name FROM Parent WHERE Id = :id",
             as: ["Key", "Label"])
  }
  return Memory(try family().catalog, views: catalog.registered)
}

/// A catalog with NULL cells: a `Maybe` relation whose `Note` text column is
/// `NULL` in some rows, to exercise three-valued comparison and `IS [NOT] NULL`.
private func nullable() throws -> Memory {
  try Catalog {
    Relation("Maybe", ["Id": .integer, "Note": .text]) {
      Row(1, "alpha")
      Row(2, nil)
      Row(3, "gamma")
      Row(4, nil)
    }
  }
}

/// The null-key join catalog: a `Parent` sorted on `Id` and a `Child` one of
/// whose foreign keys is `NULL`, to prove a `NULL` join key matches nothing.
private func nullableKeys() throws -> Memory {
  try Catalog {
    Relation("Parent", ["Id": .integer, "Name": .text], sorted: "Id") {
      Row(1, "Ada")
      Row(2, "Bee")
    }
    Relation("Child", ["Pid": .integer, "Name": .text]) {
      Row(1, "Ann")
      Row(nil, "Nobody")
      Row(2, "Bob")
    }
  }
}

/// A three-level catalog for multi-way joins: `House` → `Room` → `Item`, each
/// child carrying a foreign key to its parent's `Id`. `House` and `Room` are
/// sorted on `Id`, so a join keyed on `Id` seeks; `Item` is unsorted and scans.
private func lineage() throws -> Memory {
  try Catalog {
    Relation("House", ["Id": .integer, "House": .text], sorted: "Id") {
      Row(1, "Burrow")
      Row(2, "Manor")
    }
    Relation("Room", ["Id": .integer, "Hid": .integer, "Room": .text],
             sorted: "Id") {
      Row(1, 1, "Kitchen")
      Row(2, 1, "Attic")
      Row(3, 2, "Hall")
    }
    Relation("Item", ["Rid": .integer, "Item": .text]) {
      Row(1, "Kettle")
      Row(1, "Pot")
      Row(3, "Banner")
      Row(9, "Lost")
    }
  }
}

/// A chain whose first join's `ON` uses an unqualified column that is unique in
/// the prefix it resolves against but shared by a relation joined only later.
///
/// `Author(Aid, Code)` sorted on `Aid`; `Book(Bid, Aid)` sorted on `Aid`;
/// `Sale(Sid, Code)`. The first join `Author JOIN Book ON Code = Book.Aid` reads
/// the unqualified `Code`, which only `Author` carries within the prefix
/// `{Author, Book}` — yet `Sale`, joined afterwards, also exposes `Code`.
/// Resolving the match against the prefix binds `Code` unambiguously; resolving
/// it against the whole chain would (wrongly) see `Code` in two relations and
/// report `SQLError.ambiguous`.
private func shared() throws -> Memory {
  try Catalog {
    Relation("Author", ["Aid": .integer, "Code": .integer], sorted: "Aid") {
      Row(1, 10)
      Row(2, 20)
    }
    Relation("Book", ["Bid": .integer, "Aid": .integer], sorted: "Aid") {
      Row(100, 10)
      Row(101, 20)
    }
    Relation("Sale", ["Sid": .integer, "Code": .integer]) {
      Row(100, 900)
      Row(101, 901)
    }
  }
}

/// Parses `text` to a query, failing on any other statement.
private func select(_ text: String) throws -> Query {
  try parse(text)
}

/// Parses `text` to a query, failing on any other statement.
private func parse(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

/// Runs `text` against the single-relation `People` catalog.
private func run(_ text: String) throws -> Array<Array<Value>> {
  try people().run(parse(text))
}

/// Runs `text` against the compound-ordering `Grade` catalog.
private func grades(_ text: String) throws -> Array<Array<Value>> {
  try grades().run(parse(text))
}

/// Runs `text` against the coded-key `Attribute` catalog.
private func attributes(_ text: String) throws -> Array<Array<Value>> {
  try attributes().run(parse(text))
}

/// Runs `text` against the join `family` catalog.
private func join(_ text: String) throws -> Array<Array<Value>> {
  try family().run(parse(text))
}

/// Runs `text` against the view catalog.
private func view(_ text: String) throws -> Array<Array<Value>> {
  try views().run(parse(text))
}

/// Runs `text` against the nullable `Maybe` catalog.
private func nullable(_ text: String) throws -> Array<Array<Value>> {
  try nullable().run(parse(text))
}

/// Runs `text` against the three-level `lineage` catalog.
private func lineage(_ text: String) throws -> Array<Array<Value>> {
  try lineage().run(parse(text))
}

// MARK: - Single-relation tests

struct EngineProjectionTests {
  @Test func `SELECT * yields every real column and excludes the virtual Id`() throws {
    let rows = try run("SELECT * FROM People WHERE Id = 1")
    // Three real columns; `Id` is virtual and never in `*`.
    #expect(rows == [[.integer(1), .text("Alice"), .integer(30)]])
  }

  @Test func `SELECT names yields the named columns in order`() throws {
    try people().expect("SELECT Name, Id FROM People WHERE Id = 2",
                        yields: [["Bob", 2]])
  }

  @Test func `a named projection may include the virtual Id column`() throws {
    let rows = try run("SELECT Id, Name FROM People WHERE Name = 'Carol'")
    // Carol is the third row; her 1-based `Id` is 3.
    #expect(rows == [[.integer(3), .text("Carol")]])
  }

  @Test func `an unknown column is reported`() throws {
    #expect(throws: SQLError.column("Missing")) {
      try run("SELECT Missing FROM People")
    }
  }

  @Test func `an unknown relation is reported`() throws {
    try people().expect("SELECT * FROM Absent", fails: .relation("Absent"))
  }
}

struct EngineFilterTests {
  @Test func `equality on a text column`() throws {
    try people().expect("SELECT Id FROM People WHERE Name = 'Carol'",
                        yields: [[3]])
  }

  @Test func `a range on the sorted column`() throws {
    try people().expect("SELECT Id FROM People WHERE Id >= 4",
                        yields: [[4], [5]])
  }

  @Test func `an AND of a seekable conjunct and a residual`() throws {
    let rows = try run("SELECT Name FROM People WHERE Id > 1 AND Age = 30")
    #expect(rows == [[.text("Carol")]])
  }

  @Test func `an OR scans and admits either side`() throws {
    let rows =
        try run("SELECT Id FROM People WHERE Id = 1 OR Name = 'Eve'")
    #expect(rows == [[.integer(1)], [.integer(5)]])
  }

  @Test func `a NOT scans and negates`() throws {
    try people().expect("SELECT Id FROM People WHERE NOT Age = 30",
                        yields: [[2], [4], [5]])
  }

  @Test func `a filter on the virtual Id column`() throws {
    try people().expect("SELECT Name FROM People WHERE Id = 4",
                        yields: [["Dave"]])
  }
}

struct EngineOrderTests {
  @Test func `ORDER BY ascending on an integer column`() throws {
    let rows = try run("SELECT Id FROM People ORDER BY Age ASC")
    // Ages: Bob 25, Eve 25, Alice 30, Carol 30, Dave 40 — a stable sort keeps
    // the scan order within an equal-key group.
    #expect(rows == [[.integer(2)], [.integer(5)], [.integer(1)],
                     [.integer(3)], [.integer(4)]])
  }

  @Test func `ORDER BY descending on a text column`() throws {
    let rows = try run("SELECT Name FROM People ORDER BY Name DESC")
    #expect(rows == [[.text("Eve")], [.text("Dave")], [.text("Carol")],
                     [.text("Bob")], [.text("Alice")]])
  }
}

struct EngineCompoundOrderTests {
  @Test func `a single-key ORDER BY still orders as before`() throws {
    // The one-key case is unchanged: ages ascending, ties kept in scan order.
    let rows = try run("SELECT Id FROM People ORDER BY Age ASC")
    #expect(rows == [[.integer(2)], [.integer(5)], [.integer(1)],
                     [.integer(3)], [.integer(4)]])
  }

  @Test func `two keys order by the first, then the second`() throws {
    // Age ascending, ties by Name ascending: {Bob,Eve} at 25 → Bob, Eve;
    // {Alice,Carol} at 30 → Alice, Carol; then Dave.
    let rows = try run("SELECT Name FROM People ORDER BY Age, Name")
    #expect(rows == [[.text("Bob")], [.text("Eve")], [.text("Alice")],
                     [.text("Carol")], [.text("Dave")]])
  }

  @Test func `each key carries its own direction`() throws {
    // Age descending, ties by Name ascending: Dave(40); Alice, Carol (30);
    // Bob, Eve (25).
    let rows =
        try run("SELECT Name FROM People ORDER BY Age DESC, Name ASC")
    #expect(rows == [[.text("Dave")], [.text("Alice")], [.text("Carol")],
                     [.text("Bob")], [.text("Eve")]])
  }

  @Test func `a later key breaks ties the first key leaves`() throws {
    // Age ascending leaves {Bob,Eve} and {Alice,Carol} tied; a DESC Name key
    // reorders each pair against the scan order (Eve before Bob, Carol before
    // Alice) — proof the second key, not the input order, settles the ties.
    let rows = try run("SELECT Name FROM People ORDER BY Age ASC, Name DESC")
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
    try people().expect("""
        SELECT Name FROM People
          ORDER BY Age DESC, Name ASC FETCH FIRST 2 ROWS ONLY
        """,
        yields: [["Dave"], ["Alice"]])
  }

  @Test func `OFFSET then FETCH pages into a compound order`() throws {
    // The full compound order is Dave, Alice, Carol, Bob, Eve; skip 1, take 2.
    try people().expect("""
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
    let seek = try run("SELECT Id FROM People WHERE Id >= 2 AND Id <= 4")
    #expect(seek == [[.integer(2)], [.integer(3)], [.integer(4)]])

    let scan =
        try run("SELECT Id FROM People WHERE Name >= 'Bob' AND Name <= 'Dave'")
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
/// `(Id << Coded.bits) | tag`, decoded to the `TypeDef` `Id` or `NULL`).
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
    // positive but past `Int.max >> Coded.bits`, so `(value << 2) | 0` shifts the
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
    #expect(seeks(equalPlan))
    #expect(!filters(equalPlan))

    let less = try parse("SELECT Name FROM Attribute WHERE Parent < 5")
    let lessPlan =
        try catalog.optimise(catalog.compile(less), [:])
    #expect(!seeks(lessPlan))
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
    #expect(seeks(plan))
  }

  @Test func `an empty sorted fixture still plans a seek`() throws {
    // A sorted relation with no rows has no leading cell to disqualify the
    // seek; it plans a seek over the empty range, not a scan.
    let catalog = try Catalog {
      Relation("T", ["Id": .integer], sorted: "Id")
    }
    let query = try parse("SELECT * FROM T WHERE Id = 1")
    let plan = try catalog.optimise(catalog.compile(query), [:])
    #expect(seeks(plan))
  }
}

struct EngineQualifierTests {
  @Test func `a qualifier matching the alias resolves the column`() throws {
    try people().expect("SELECT p.Name FROM People AS p WHERE Id = 1",
                        yields: [["Alice"]])
  }

  @Test func `a qualifier matching the table name resolves the column`() throws {
    try people().expect("SELECT People.Name FROM People WHERE Id = 1",
                        yields: [["Alice"]])
  }

  @Test func `a qualifier naming neither the alias nor the table is reported`() throws {
    // `x` names neither the alias `p` nor the table `People`; a single-relation
    // query rejects it rather than dropping the qualifier and binding `Name`.
    #expect(throws: SQLError.column("Name")) {
      try run("SELECT x.Name FROM People AS p")
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

// MARK: - Join tests

struct EngineJoinTests {
  @Test func `a join on a foreign key pairs each child with its parent`() throws {
    let rows = try join("""
        SELECT * FROM Parent JOIN Child ON Child.Pid = Parent.Id
        """)
    // The orphan child (Pid 9) and the childless parent (Cid) drop out.
    #expect(rows == [
      [.integer(1), .text("Ada"), .integer(1), .text("Ann")],
      [.integer(1), .text("Ada"), .integer(1), .text("Amy")],
      [.integer(2), .text("Bee"), .integer(2), .text("Bob")],
    ])
  }

  @Test func `a qualified projection selects across both relations`() throws {
    try family().expect("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """,
        yields: [["Ada", "Ann"], ["Ada", "Amy"], ["Bee", "Bob"]])
  }

  @Test func `a join keys off the inner relation's virtual Id`() throws {
    // `Ordered` has no stored key; its identity is its 1-based `Id`. The
    // child's `Pid` joins to that virtual column.
    let rows = try join("""
        SELECT Ordered.Label, Child.Name FROM Child
          JOIN Ordered ON Ordered.Id = Child.Pid
        """)
    // Pid 1 → "first" (Ann, Amy), Pid 2 → "second" (Bob); Pid 9 has no row.
    #expect(rows == [
      [.text("first"), .text("Ann")],
      [.text("first"), .text("Amy")],
      [.text("second"), .text("Bob")],
    ])
  }

  @Test func `a join keyed off the OUTER relation's virtual Id does not collide`() throws {
    // The combined ordinal space lays the inner relation past the outer's
    // `extent` — its real width plus the virtual columns it exposes — so an
    // outer virtual column never shares an ordinal with an inner real one. Here
    // `Ordered` is the OUTER relation, and the join keys off its virtual `Id`
    // at ordinal `width`; the inner `Child.Pid` is a real column at ordinal 0.
    // Were the inner laid at the outer's `width` (or at a base collapsed to 0
    // by a `1 << 32` reserve on a 32-bit host), `Child.Pid` would land on the
    // outer `Id`'s ordinal and the join's cells would corrupt one another.
    let rows = try join("""
        SELECT Ordered.Id, Child.Name FROM Ordered
          JOIN Child ON Child.Pid = Ordered.Id
        """)
    // Id 1 → Ann, Amy; Id 2 → Bob; Id 3 has no child; Pid 9 no parent.
    #expect(rows == [
      [.integer(1), .text("Ann")],
      [.integer(1), .text("Amy")],
      [.integer(2), .text("Bob")],
    ])
  }

  @Test func `a WHERE spans both relations`() throws {
    try family().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada' AND Child.Name = 'Amy'
        """,
        yields: [["Amy"]])
  }

  @Test func `ORDER BY orders across the join`() throws {
    try family().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          ORDER BY Child.Name ASC
        """,
        yields: [["Amy"], ["Ann"], ["Bob"]])
  }

  @Test func `an unqualified name in both relations is ambiguous`() throws {
    #expect(throws: SQLError.ambiguous("Name")) {
      try join("SELECT Name FROM Parent JOIN Child ON Child.Pid = Parent.Id")
    }
  }

  @Test func `a self-join's shared table name makes a qualified name ambiguous`() throws {
    #expect(throws: SQLError.ambiguous("Id")) {
      try join("""
          SELECT Parent.Name FROM Parent JOIN Parent ON Parent.Id = Parent.Id
          """)
    }
  }

  @Test func `a duplicated alias makes a shared qualified column ambiguous`() throws {
    // `x.Pid` resolves by column (the Child side only); `x.Name` is on both,
    // so the shared alias is ambiguous rather than binding silently to outer.
    #expect(throws: SQLError.ambiguous("Name")) {
      try join("""
          SELECT x.Name FROM Parent AS x JOIN Child AS x ON x.Pid = x.Pid
          """)
    }
  }

  @Test func `a parent with no matching child contributes no rows`() throws {
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Cid'
        """)
    #expect(rows.isEmpty)
  }

  @Test func `the seek probe and the scan probe return identical results`() throws {
    // The join seeks `Child.Pid = Parent.Id` when the inner relation is
    // seekable on the key, and scans it otherwise. Both inner orderings — the
    // sorted `Parent` and its unsorted twin used as the inner — must agree.
    let seek = try join("""
        SELECT Parent.Name, Child.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid ORDER BY Child.Name ASC
        """)
    let scan = try join("""
        SELECT P.Name, Child.Name FROM Child
          JOIN ParentUnsorted AS P ON P.Id = Child.Pid ORDER BY Child.Name ASC
        """)
    #expect(seek == scan)
    #expect(seek == [
      [.text("Ada"), .text("Amy")],
      [.text("Ada"), .text("Ann")],
      [.text("Bee"), .text("Bob")],
    ])
  }
}

// MARK: - Non-equi join tests

struct EngineNonEquiJoinTests {
  @Test func `an inequality ON pairs every row the predicate admits`() throws {
    // `ON Parent.Id < Child.Pid` is a pure inequality — no equi conjunct —
    // so it is a nested loop: for each parent, every child whose Pid exceeds
    // its Id, in outer-major order.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """)
    #expect(rows == [
      [.text("Ada"), .text("Bob")],
      [.text("Ada"), .text("Orphan")],
      [.text("Bee"), .text("Orphan")],
      [.text("Cid"), .text("Orphan")],
    ])
  }

  @Test func `a pure inequality ON plans a residual product, not a hash join`() throws {
    // No `column = column` conjunct, so `nest` cannot form a `.join`; the level
    // stays a `.select` over a `.product` — the nested-loop shape.
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `a mixed ON hashes the equi conjunct and filters the residual`() throws {
    // `ON Child.Pid = Parent.Id AND Child.Name < 'B'`: the equality hash-joins
    // each child to its parent; the residual inequality beside the key then
    // keeps only pairs whose child name sorts before 'B' — dropping Bob, the
    // sole B-name.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id AND Child.Name < 'B'
        """)
    // Equi pairs (Ada,Ann),(Ada,Amy),(Bee,Bob); the residual drops (Bee,Bob).
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
    ])
  }

  @Test func `a mixed ON still plans a hash join for its equi conjunct`() throws {
    // The `column = column` conjunct becomes a `.join`; the inequality
    // survives as a residual `.select` over it — the equi fast-path still
    // triggers.
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id AND Parent.Name < Child.Name
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(joins(plan))
  }

  @Test func `an expression equality ON is a residual, not a hash key`() throws {
    // `ON Child.Pid = Parent.Id + 1` equates a column with an EXPRESSION, so
    // it is not a bare `column = column` key: it lowers to a residual over the
    // product (nested loop), not a hash join.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id + 1
        """)
    // Parent 1 (Ada) → Pid 2: Bob. Parent 2 (Bee) → Pid 3: none.
    // Parent 3 (Cid) → Pid 4: none.
    #expect(rows == [[.text("Ada"), .text("Bob")]])
  }

  @Test func `an expression equality ON plans a residual product`() throws {
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id + 1
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `a non-equi ON equals the eager product filtered`() throws {
    // The nested-loop join over an inequality must yield exactly the eager
    // cross product filtered by the same predicate, in outer-major order.
    let catalog = try family()
    let parents = try catalog.run(parse("SELECT Name, Id FROM Parent"))
    let children = try catalog.run(parse("SELECT Name, Pid FROM Child"))
    var expected = Array<Array<Value>>()
    for parent in parents {
      for child in children where less(parent[1], child[1]) {
        expected.append([parent[0], child[0]])
      }
    }
    let rows = try catalog.run(parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """))
    #expect(rows == expected)
  }

  @Test func `an unsafe ON conjunct before an equi key is preserved`() throws {
    // `ON (1 / A.x) = 0 AND A.k = B.k` over a product pair where `A.x = 0` and
    // `A.k <> B.k`. The hash join evaluates its key equality BEFORE any
    // residual, so hoisting `A.k = B.k` to a key would drop the non-matching
    // pair and skip the division the earlier unsafe conjunct owes. The unsafe
    // leading conjunct bars extraction, so the WHOLE ON stays a residual over
    // the product and the division raises `SQLError.divide` rather than the
    // query returning no rows.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(parse("""
          SELECT A.k FROM A JOIN B ON (1 / A.x) = 0 AND A.k = B.k
          """))
    }
  }

  @Test func `an unsafe-prefixed ON extracts no equi key, planning a residual`() throws {
    // The same `ON (1 / A.x) = 0 AND A.k = B.k`: the unsafe leading conjunct
    // bars the equi from becoming a `match`, so `nest` forms no `.join` — the
    // level is a residual `.select` over a `.product`, the whole ON per pair.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    let select = try parse("""
        SELECT A.k FROM A JOIN B ON (1 / A.x) = 0 AND A.k = B.k
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `an equi key before an unsafe residual extracts no key, planning a residual`() throws {
    // `ON A.k = B.k AND (1 / A.x) = 0` (equi FIRST) has an unsafe conjunct, so
    // NO key is extracted and the WHOLE ON lowers to a residual over the
    // product. A hash key would skip a NULL-key pair before the unsafe RHS ran,
    // suppressing the divide the left-to-right Kleene AND owes — so the equi
    // must NOT hoist while an unsafe conjunct FOLLOWS it.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    let plan = try catalog.optimise(catalog.compile(parse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """)).pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `a nullable ON key before an unsafe residual raises`() throws {
    // `ON A.k = B.k AND (1 / A.x) = 0` with `A.k` NULL and `A.x = 0`. The
    // equality is UNKNOWN (a NULL operand), so the Kleene AND must still
    // evaluate the unsafe RHS `(1 / A.x) = 0` and raise `SQLError.divide`.
    // Extracting `A.k = B.k` to a hash key would skip the NULL key and DROP the
    // pair before the RHS ran, returning no rows — so no key is hoisted and the
    // WHOLE ON stays a residual over the product that raises.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.integer(0), .null]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    let plan = try catalog.optimise(catalog.compile(parse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """)).pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(parse("""
          SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
          """))
    }
  }

  @Test func `a definite-false ON key before an unsafe residual short-circuits without raising`() throws {
    // `ON A.k = B.k AND (1 / A.x) = 0` with `A.k = 5`, `B.k = 3` (non-NULL,
    // definitely UNEQUAL) and `A.x = 0`. The equality is definite FALSE, so the
    // Kleene AND short-circuits (`false` dominates) and never evaluates the
    // unsafe RHS — no rows, no raise. Both the product+select and the residual
    // agree, distinguishing a definite-FALSE key from the UNKNOWN NULL one.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.integer(0), .integer(5)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                    [[.integer(3)]] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `a safe non-equi before an equi still extracts the equi key`() throws {
    // SAFE-prefix — `ON A.p < B.q AND A.k = B.k`. The leading `<` is safe
    // (comparing two cells never raises), so it does not bar extraction: the
    // equi `A.k = B.k` still becomes a hash key beside the residual inequality.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "k", type: .integer),
                     Field(name: "p", type: .integer)],
                    [[.integer(1), .integer(5)],
                     [.integer(2), .integer(10)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer),
                     Field(name: "q", type: .integer)],
                    [[.integer(1), .integer(8)],
                     [.integer(2), .integer(3)]] as Array<Array<Value>>),
    ])
    let text = """
        SELECT A.k, B.q FROM A JOIN B ON A.p < B.q AND A.k = B.k
        """
    // Key pairs (1,1) with 5 < 8 kept; (2,2) with 10 < 3 dropped.
    let rows = try catalog.run(parse(text))
    #expect(rows == [[.integer(1), .integer(8)]])
    let plan =
        try catalog.optimise(catalog.compile(parse(text)).pushdown(), [:])
    #expect(joins(plan))
  }

  @Test func `a pure equi ON still plans a hash join`() throws {
    // The equi fast-path is unchanged: an all-`column = column` ON extracts
    // its key and folds into a `.join`.
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(joins(plan))
  }

  @Test func `a nullable ON gate drops a pair before an unsafe WHERE`() throws {
    // `A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0`, `A.k` NULL and `A.x` = 0.
    // The residual `ON` gate `A.k < B.k` is UNKNOWN (a NULL operand), so the
    // pair is DROPPED at the gate and the `WHERE` never runs on it — no rows,
    // no raise. The gate is a distribution BARRIER: the `WHERE` stays a
    // SEPARATE `select` above the residual `ON` gate rather than fused into one
    // throwing `A.k < B.k AND (1 / A.x) = 0` over the product.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                            Field(name: "k", type: .integer)],
                           [[.integer(0), .null]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                           [[.integer(2)]] as Array<Array<Value>>),
    ])
    let text = "SELECT A.k FROM A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0"
    let plan =
        try catalog.optimise(catalog.compile(parse(text)).pushdown(), [:])
    #expect(separated(plan))
    #expect(residual(plan))
    #expect(try catalog.run(parse(text)).isEmpty)
  }

  @Test func `a surviving ON pair still runs the unsafe WHERE`() throws {
    // CONTROL — the same `A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0`, but now
    // `A.k` = 1 and `B.k` = 2, so the `ON` gate is TRUE and the pair PASSES it.
    // The `WHERE` then runs on the surviving pair and `(1 / A.x) = 0` with
    // `A.x` = 0 raises `SQLError.divide` — the `WHERE` still applies after the
    // gate.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                            Field(name: "k", type: .integer)],
                           [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                           [[.integer(2)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(parse("""
          SELECT A.k FROM A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0
          """))
    }
  }

  @Test func `a safe WHERE over a non-equi ON join returns correct rows`()
      throws {
    // A SAFE `WHERE` over a non-equi `ON` join yields the same rows the eager
    // product filtered by both `ON` and `WHERE` would — whether or not the safe
    // `WHERE` fuses with the gate. `ON Parent.Id < Child.Pid WHERE Child.Name
    // <> 'Orphan'` pairs each parent with a later-keyed child, then drops the
    // Orphan child.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid WHERE Child.Name <> 'Orphan'
        """)
    #expect(rows == [[.text("Ada"), .text("Bob")]])
  }

  @Test func `a leftover ON match gates a pair before an unsafe WHERE`() throws {
    // `A JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE (1 / A.x) = 0`, with
    // `A.k1` matching, `A.k2` NULL, and `A.x` = 0. `nest` folds ONE equi key
    // (`A.k1 = B.k1`) into the hash `.join`, leaving `A.k2 = B.k2` as the
    // gate's own residual under the join. The surviving `k1` pair reaches that
    // leftover match, which is UNKNOWN (a NULL `A.k2`), so the pair is DROPPED
    // at the gate BEFORE the `WHERE` runs — no rows, no raise. The `ON` gate is
    // a BARRIER even though it is PURE-equi: the `WHERE` stays a SEPARATE
    // `select` above the leftover-match gate rather than fused into a throwing
    // `A.k2 = B.k2 AND (1 / A.x) = 0` that would divide by zero on the pair.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                            Field(name: "k1", type: .integer),
                            Field(name: "k2", type: .integer)],
                           [[.integer(0), .integer(1), .null]]
                             as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k1", type: .integer),
                            Field(name: "k2", type: .integer)],
                           [[.integer(1), .integer(5)]]
                             as Array<Array<Value>>),
    ])
    let text = """
        SELECT A.k1 FROM A
          JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE (1 / A.x) = 0
        """
    let plan =
        try catalog.optimise(catalog.compile(parse(text)).pushdown(), [:])
    // The equi key still hash-joins; the leftover match gates above it, and the
    // `WHERE` is a SEPARATE `select` above that gate, not fused with the match.
    #expect(joins(plan))
    #expect(stacked(plan))
    #expect(try catalog.run(parse(text)).isEmpty)
  }

  @Test func `both ON matches passing lets the unsafe WHERE raise`() throws {
    // CONTROL — the same two-key `ON` and unsafe `WHERE`, but now BOTH keys
    // match (`A.k2` = 5 = `B.k2`), so the pair passes the whole `ON` gate. The
    // `WHERE` then runs on the surviving pair and `(1 / A.x) = 0` with `A.x`
    // = 0 raises `SQLError.divide` — the `WHERE` still applies after the gate.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                            Field(name: "k1", type: .integer),
                            Field(name: "k2", type: .integer)],
                           [[.integer(0), .integer(1), .integer(5)]]
                             as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k1", type: .integer),
                            Field(name: "k2", type: .integer)],
                           [[.integer(1), .integer(5)]]
                             as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(parse("""
          SELECT A.k1 FROM A
            JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE (1 / A.x) = 0
          """))
    }
  }

  @Test func `a two-equality pure-equi ON with a safe WHERE joins correctly`()
      throws {
    // The equi fast-path is intact under the always-barrier rule: a two-key
    // pure-equi `ON` still hash-joins (one key folded, the other gating over
    // the join) and a SAFE `WHERE` above returns the expected rows. `A.k1` and
    // `A.k2` pick out exactly the `B` row whose BOTH keys match; the `WHERE`
    // then keeps only the tagged pair.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "k1", type: .integer),
                            Field(name: "k2", type: .integer),
                            Field(name: "tag", type: .text)],
                           [[.integer(1), .integer(5), .text("keep")],
                            [.integer(1), .integer(9), .text("drop")]]
                             as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k1", type: .integer),
                            Field(name: "k2", type: .integer),
                            Field(name: "note", type: .text)],
                           [[.integer(1), .integer(5), .text("bee")],
                            [.integer(1), .integer(9), .text("cee")]]
                             as Array<Array<Value>>),
    ])
    let text = """
        SELECT A.tag, B.note FROM A
          JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE A.tag = 'keep'
        """
    let plan =
        try catalog.optimise(catalog.compile(parse(text)).pushdown(), [:])
    #expect(joins(plan))
    #expect(try catalog.run(parse(text)) == [[.text("keep"), .text("bee")]])
  }

  @Test func `a single-equality ON still plans a hash join and behaves`() throws {
    // A single-equality pure-equi `ON A.k = B.k` folds its ONE key into the
    // hash `.join` and carries no leftover conjunct, so the `WHERE` sits
    // above the join. A matching pair runs the `WHERE`; a NULL key drops the
    // pair at the join, so the `WHERE` never runs on it. `A` holds a matching
    // row (`k` = 1, `x` = 1) and a NULL-key row (`k` NULL, `x` = 0): the match
    // returns the pair `WHERE A.x = 1` admits, and the NULL-key row is dropped
    // before the unsafe `(1 / A.x)` would ever divide.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                            Field(name: "k", type: .integer)],
                           [[.integer(1), .integer(1)],
                            [.integer(0), .null]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "k", type: .integer)],
                           [[.integer(1)]] as Array<Array<Value>>),
    ])
    let text = "SELECT A.k FROM A JOIN B ON A.k = B.k WHERE (1 / A.x) = 1"
    let plan =
        try catalog.optimise(catalog.compile(parse(text)).pushdown(), [:])
    #expect(joins(plan))
    #expect(try catalog.run(parse(text)) == [[.integer(1)]])
  }
}

// MARK: - Outer join tests

struct EngineOuterJoinTests {
  @Test func `a LEFT JOIN preserves an unmatched left row, right NULL`() throws {
    // Every parent survives; Cid, with no child, emits once with the child
    // columns NULL — the NULL-extension. Matched parents emit each pair.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
      [.text("Cid"), .null],
    ])
  }

  @Test func `LEFT OUTER JOIN is the same as LEFT JOIN`() throws {
    // The `OUTER` noise word is optional and changes nothing.
    let terse = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    let verbose = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT OUTER JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(terse == verbose)
  }

  @Test func `a RIGHT JOIN preserves an unmatched right row, left NULL`() throws {
    // Every child survives, right-major; the Orphan (Pid 9) has no parent and
    // emits once with the parent columns NULL.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          RIGHT JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
      [.null, .text("Orphan")],
    ])
  }

  @Test func `a FULL JOIN preserves the unmatched rows of both sides`() throws {
    // The left-major pairs and the childless Cid (right NULL), then the
    // parentless Orphan (left NULL) — both sides' unmatched rows survive.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          FULL JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
      [.text("Cid"), .null],
      [.null, .text("Orphan")],
    ])
  }

  @Test func `an ON conjunct keeps an unmatched left row a WHERE would drop`() throws {
    // ON vs WHERE. Restricting the MATCH with `AND Child.Name = 'Amy'` keeps
    // every parent — the ON governs matching alone, so a parent that now
    // matches no child is still emitted NULL-extended. Only Ada matches Amy.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id AND Child.Name = 'Amy'
        """)
    #expect(rows == [
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .null],
      [.text("Cid"), .null],
    ])
  }

  @Test func `the same predicate in WHERE drops the unmatched rows`() throws {
    // Moving the predicate to a post-join WHERE filters AFTER the outer join,
    // so the NULL-extended rows (whose Child.Name is NULL) fail `= 'Amy'` and
    // drop — turning the LEFT join back to inner-like. This is the ON-vs-WHERE
    // distinction the outer join preserves.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id WHERE Child.Name = 'Amy'
        """)
    #expect(rows == [[.text("Ada"), .text("Amy")]])
  }

  @Test func `a WHERE IS NULL over a LEFT join finds the unmatched rows`() throws {
    // The anti-join idiom: a LEFT join then `WHERE Child.Name IS NULL` keeps
    // only the parents with no child — Cid.
    let rows = try join("""
        SELECT Parent.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id WHERE Child.Name IS NULL
        """)
    #expect(rows == [[.text("Cid")]])
  }

  @Test func `a LEFT JOIN with a non-equi ON preserves unmatched rows`() throws {
    // Outer joins compose with Part 1's non-equi ON: `ON Parent.Id > Child.Pid`
    // pairs each parent with the children below it, and NULL-extends a parent
    // that dominates none. Child Pids are 1,1,2,9. Ada(1) > none; Bee(2) >
    // Pid 1 (Ann, Amy); Cid(3) > Pids 1,1,2 (Ann, Amy, Bob).
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Parent.Id > Child.Pid
        """)
    #expect(rows == [
      [.text("Ada"), .null],
      [.text("Bee"), .text("Ann")],
      [.text("Bee"), .text("Amy")],
      [.text("Cid"), .text("Ann")],
      [.text("Cid"), .text("Amy")],
      [.text("Cid"), .text("Bob")],
    ])
  }

  @Test func `a LEFT JOIN plans an outer node, not a distributed product`() throws {
    // The ON must stay on the outer node — never distributed into a product or
    // nested into a hash join — or an unmatched row would be dropped. So the
    // plan reaches an `.outer` node and NOT a `.join`.
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(outers(plan))
    #expect(!joins(plan))
  }

  @Test func `an inner join then a LEFT join preserves the middle unmatched`() throws {
    // A mixed chain: House JOIN Room (inner) then LEFT JOIN Item. The empty
    // Attic (no item) survives the LEFT join NULL-extended, while the inner
    // House-Room pairs are formed first.
    let rows = try lineage("""
        SELECT House.House, Room.Room, Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          LEFT JOIN Item ON Item.Rid = Room.Id
        """)
    #expect(rows == [
      [.text("Burrow"), .text("Kitchen"), .text("Kettle")],
      [.text("Burrow"), .text("Kitchen"), .text("Pot")],
      [.text("Burrow"), .text("Attic"), .null],
      [.text("Manor"), .text("Hall"), .text("Banner")],
    ])
  }

  @Test func `an empty right side NULL-extends every left row`() throws {
    // With no child matching, a LEFT join still emits every parent, right
    // NULL — the width comes from the plan, not from a right row.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = 999
        """)
    #expect(rows == [
      [.text("Ada"), .null],
      [.text("Bee"), .null],
      [.text("Cid"), .null],
    ])
  }
}

/// Whether `plan` reaches an `.outer` node — the outer-join operator.
private func outers(_ plan: Plan) -> Bool {
  switch plan {
  case .outer:
    true
  case let .select(_, source):
    outers(source)
  case let .project(_, source):
    outers(source)
  case let .sort(_, source):
    outers(source)
  case let .limit(_, _, source):
    outers(source)
  case let .distinct(source):
    outers(source)
  case let .derived(_, sub, _, _):
    outers(sub)
  case let .product(left, right):
    outers(left) || outers(right)
  case let .join(source, _, _, _, _, _, _):
    outers(source)
  case let .setop(_, left, right, _):
    outers(left) || outers(right)
  case let .aggregate(_, _, source):
    outers(source)
  case .single, .scan:
    false
  }
}

// MARK: - Multi-way join tests

struct EngineMultiJoinTests {
  @Test func `a three-relation chain joins across two foreign keys`() throws {
    let rows = try lineage("""
        SELECT House.House, Room.Room, Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
        """)
    // Burrow's Kitchen holds the Kettle and Pot; its Attic is empty. Manor's
    // Hall holds the Banner. The item with no room (Rid 9) drops out.
    #expect(rows == [
      [.text("Burrow"), .text("Kitchen"), .text("Kettle")],
      [.text("Burrow"), .text("Kitchen"), .text("Pot")],
      [.text("Manor"), .text("Hall"), .text("Banner")],
    ])
  }

  @Test func `a chain seeks each inner relation keyed on its sorted column`() throws {
    // Walking the chain the other way: `Item` is the outer scan, and both inner
    // relations are seeked on their sorted `Id` — the multi-way nest rewrite
    // turning every `Select`-over-`Product` level into an index-nested loop.
    let rows = try lineage("""
        SELECT Item.Item, Room.Room, House.House FROM Item
          JOIN Room ON Room.Id = Item.Rid
          JOIN House ON House.Id = Room.Hid
        """)
    #expect(rows == [
      [.text("Kettle"), .text("Kitchen"), .text("Burrow")],
      [.text("Pot"), .text("Kitchen"), .text("Burrow")],
      [.text("Banner"), .text("Hall"), .text("Manor")],
    ])
  }

  @Test func `a WHERE filters across a three-relation chain`() throws {
    try lineage().expect("""
        SELECT Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
          WHERE House.House = 'Burrow' AND Item.Item = 'Pot'
        """,
        yields: [["Pot"]])
  }

  @Test func `an unqualified name in more than one relation of a chain is ambiguous`() throws {
    // `Id` sits in both `House` and `Room`; across the chain it resolves in more
    // than one relation, so an unqualified reference is ambiguous.
    #expect(throws: SQLError.ambiguous("Id")) {
      try lineage("""
          SELECT Id FROM House
            JOIN Room ON Room.Hid = House.Id
            JOIN Item ON Item.Rid = Room.Id
          """)
    }
  }

  @Test func `an early ON referencing a not-yet-joined relation is rejected`() throws {
    // The first join's `ON` qualifies a column with `Item`, a relation joined
    // only LATER. Resolving the match against just the prefix — `House` and
    // `Room` — the qualifier names no relation in scope, so the query is
    // rejected (`SQLError.column`) rather than resolving `Item`'s slot from a
    // product that does not yet contain it and trapping or indexing wrong.
    #expect(throws: SQLError.column("Rid")) {
      try lineage("""
          SELECT House.House FROM House
            JOIN Room ON Item.Rid = House.Id
            JOIN Item ON Item.Rid = Room.Id
          """)
    }
  }

  @Test func `a valid early ON whose columns are all in its prefix runs`() throws {
    // Each `ON` references only the prefix it resolves against, so the whole
    // chain compiles and runs — mirroring `chain`, which the prefix-scope fix
    // leaves unchanged.
    let rows = try lineage("""
        SELECT House.House, Room.Room, Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
        """)
    #expect(rows == [
      [.text("Burrow"), .text("Kitchen"), .text("Kettle")],
      [.text("Burrow"), .text("Kitchen"), .text("Pot")],
      [.text("Manor"), .text("Hall"), .text("Banner")],
    ])
  }

  @Test func `an unqualified early-ON column a later relation shares is not ambiguous`() throws {
    // The first join's `ON` reads unqualified `Code`, unique within its prefix
    // `{Author, Book}` even though `Sale` — joined only later — also carries a
    // `Code`. Resolving the match against the prefix binds it; resolving against
    // the whole chain would see two `Code`s and report `SQLError.ambiguous`.
    try shared().expect("""
        SELECT Author.Aid, Book.Bid, Sale.Code FROM Author
          JOIN Book ON Code = Book.Aid
          JOIN Sale ON Sale.Sid = Book.Bid
        """,
        yields: [[1, 100, 900], [2, 101, 901]])
  }
}

// MARK: - View tests

struct EngineViewTests {
  @Test func `a view resolves and queries like a table`() throws {
    // `SELECT * FROM Adults` runs the view's `SELECT Id, Name FROM Parent
    // WHERE Id >= 2`, exposing the columns as `Key`/`Label`.
    let rows = try view("SELECT * FROM Adults")
    #expect(rows == [
      [.integer(2), .text("Bee")],
      [.integer(3), .text("Cid")],
    ])
  }

  @Test func `a projection over a view selects the view's columns by name`() throws {
    try views().expect("SELECT Label FROM Adults", yields: [["Bee"], ["Cid"]])
  }

  @Test func `a WHERE over a view filters its rows`() throws {
    try views().expect("SELECT Label FROM Adults WHERE Key = 3",
                       yields: [["Cid"]])
  }

  @Test func `an ORDER BY over a view orders its rows`() throws {
    try views().expect("SELECT Label FROM Adults ORDER BY Label DESC",
                       yields: [["Cid"], ["Bee"]])
  }

  @Test func `a view whose definition is a join resolves and queries`() throws {
    // `Pairs` denormalises the `Parent`/`Child` foreign-key join; querying it
    // runs the inner join and exposes its two columns as `Parent`/`Kid`.
    let rows = try view("SELECT * FROM Pairs")
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test func `a projection and filter over a join view selects across its columns`() throws {
    try views().expect("SELECT Kid FROM Pairs WHERE Parent = 'Ada'",
                       yields: [["Ann"], ["Amy"]])
  }

  @Test func `an unknown column of a view is reported`() throws {
    #expect(throws: SQLError.column("Missing")) {
      try view("SELECT Missing FROM Adults")
    }
  }

  @Test func `a SELECT * view over-declaring its columns is rejected at resolution`() throws {
    // `Parent` is two columns wide, but the view declares three. A `SELECT *`
    // has no statically known arity, so the parser admits the list; the engine
    // catches the mismatch at resolution rather than indexing past a row.
    let star = try View(query: select("SELECT * FROM Parent"),
                        columns: ["a", "b", "c"])
    let catalog = Memory(try family().catalog, views: ["Star": star])
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
      try catalog.run(parse("SELECT a FROM Star"))
    }
  }

  @Test func `a SELECT * view whose explicit list matches the width resolves`() throws {
    // The same `SELECT *` view declared with the right number of columns
    // resolves and queries — the backstop passes the well-formed view through.
    let star = try View(query: select("SELECT * FROM Parent"),
                        columns: ["a", "b"])
    let catalog = Memory(try family().catalog, views: ["Star": star])
    let rows = try catalog.run(parse("SELECT b FROM Star WHERE a = 1"))
    #expect(rows == [[.text("Ada")]])
  }

  @Test func `a view's definition is optimised — its seekable predicate seeks`() throws {
    // `Adults` is `SELECT Id, Name FROM Parent WHERE Id >= 2`, and `Parent` is
    // sorted on `Id`, so the view's sub-plan must seek that run rather than
    // scanning under a `Select`. Compile and optimise an outer query over the
    // view and inspect the `.derived` leaf: its sub-plan must reach a seeked
    // `.scan` (a non-nil seek) and carry no `.select` over a raw scan.
    let catalog = try views()
    let select = try parse("SELECT Key, Label FROM Adults")
    let plan = try catalog.optimise(catalog.compile(select), [:])
    let sub = try #require(derived(plan))
    #expect(seeks(sub))
    #expect(!filters(sub))
  }
}

/// The sub-plan of the first `.derived` leaf reachable from `plan`, or `nil`.
private func derived(_ plan: Plan) -> Plan? {
  switch plan {
  case let .derived(_, sub, _, _):
    sub
  case let .select(_, source):
    derived(source)
  case let .project(_, source):
    derived(source)
  case let .sort(_, source):
    derived(source)
  case let .product(left, right):
    derived(left) ?? derived(right)
  case let .outer(left, right, _, _):
    derived(left) ?? derived(right)
  case let .setop(_, left, right, _):
    derived(left) ?? derived(right)
  case let .limit(_, _, source):
    derived(source)
  case let .distinct(source):
    derived(source)
  case let .aggregate(_, _, source):
    derived(source)
  case .single, .scan, .join:
    nil
  }
}

/// Whether `plan` reaches a `.scan` carrying a non-nil seek.
private func seeks(_ plan: Plan) -> Bool {
  switch plan {
  case let .scan(_, _, seek):
    seek != nil
  case let .select(_, source):
    seeks(source)
  case let .project(_, source):
    seeks(source)
  case let .sort(_, source):
    seeks(source)
  case let .derived(_, sub, _, _):
    seeks(sub)
  case let .product(left, right):
    seeks(left) || seeks(right)
  case let .join(outer, _, _, _, _, _, _):
    // A pushed-down key seeks the join's OUTER leaf, so a seek can live inside
    // the join rather than only atop a bare scan.
    seeks(outer)
  case let .outer(left, right, _, _):
    seeks(left) || seeks(right)
  case let .setop(_, left, right, _):
    seeks(left) || seeks(right)
  case let .limit(_, _, source):
    seeks(source)
  case let .distinct(source):
    seeks(source)
  case let .aggregate(_, _, source):
    seeks(source)
  case .single:
    false
  }
}

/// Whether `plan` wraps a raw (unseeked) `.scan` in a `.select` — the
/// un-optimised shape the fix eliminates from a view's sub-plan.
private func filters(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .scan(_, _, nil)):
    true
  case let .select(_, source):
    filters(source)
  case let .project(_, source):
    filters(source)
  case let .sort(_, source):
    filters(source)
  case let .derived(_, sub, _, _):
    filters(sub)
  case let .product(left, right):
    filters(left) || filters(right)
  case let .outer(left, right, _, _):
    filters(left) || filters(right)
  case let .setop(_, left, right, _):
    filters(left) || filters(right)
  case let .limit(_, _, source):
    filters(source)
  case let .distinct(source):
    filters(source)
  case let .aggregate(_, _, source):
    filters(source)
  case .single, .scan, .join:
    false
  }
}

/// Whether a single-relation filter rides below a `join` or `product` boundary —
/// the shape selection pushdown produces (a `.select` or a seeked `.scan` inside
/// a join's outer operand or a product's arm), as opposed to a `WHERE` left
/// floating atop the whole chain.
private func pushed(_ plan: Plan) -> Bool {
  switch plan {
  case let .join(outer, _, _, _, _, _, _):
    seeks(outer) || floats(outer) || pushed(outer)
  case let .product(left, right):
    seeks(left) || floats(left) || pushed(left) || seeks(right)
        || floats(right) || pushed(right)
  case let .outer(left, right, _, _):
    seeks(left) || floats(left) || pushed(left) || seeks(right)
        || floats(right) || pushed(right)
  case let .select(_, source):
    pushed(source)
  case let .project(_, source):
    pushed(source)
  case let .sort(_, source):
    pushed(source)
  case let .derived(_, sub, _, _):
    pushed(sub)
  case let .setop(_, left, right, _):
    pushed(left) || pushed(right)
  case let .limit(_, _, source):
    pushed(source)
  case let .distinct(source):
    pushed(source)
  case let .aggregate(_, _, source):
    pushed(source)
  case .single, .scan:
    false
  }
}

/// Whether `plan` is (or reaches through unary operators) a `.select` — a filter
/// standing over a source.
private func floats(_ plan: Plan) -> Bool {
  switch plan {
  case .select:
    true
  case let .project(_, source):
    floats(source)
  case let .sort(_, source):
    floats(source)
  case let .derived(_, sub, _, _):
    floats(sub)
  case let .limit(_, _, source):
    floats(source)
  default:
    false
  }
}

/// Whether `plan` reaches a `.join` node — the index-nested-loop/hash join path,
/// as opposed to a residual `.product` filtered by the ON predicate.
private func joins(_ plan: Plan) -> Bool {
  switch plan {
  case .join:
    true
  case let .select(_, source):
    joins(source)
  case let .project(_, source):
    joins(source)
  case let .sort(_, source):
    joins(source)
  case let .limit(_, _, source):
    joins(source)
  case let .distinct(source):
    joins(source)
  case let .derived(_, sub, _, _):
    joins(sub)
  case let .product(left, right):
    joins(left) || joins(right)
  case let .outer(left, right, _, _):
    joins(left) || joins(right)
  case let .setop(_, left, right, _):
    joins(left) || joins(right)
  case let .aggregate(_, _, source):
    joins(source)
  case .single, .scan:
    false
  }
}

/// Whether `plan` reaches a `.select` standing directly over a `.product` — the
/// residual product-under-select the streaming path fuses and filters row by
/// row rather than materialising whole.
private func residual(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .product):
    true
  case let .select(_, source):
    residual(source)
  case let .project(_, source):
    residual(source)
  case let .sort(_, source):
    residual(source)
  case let .limit(_, _, source):
    residual(source)
  case let .distinct(source):
    residual(source)
  case let .derived(_, sub, _, _):
    residual(sub)
  case let .product(left, right):
    residual(left) || residual(right)
  case let .join(outer, _, _, _, _, _, _):
    residual(outer)
  case let .outer(left, right, _, _):
    residual(left) || residual(right)
  case let .setop(_, left, right, _):
    residual(left) || residual(right)
  case let .aggregate(_, _, source):
    residual(source)
  case .single, .scan:
    false
  }
}

/// Whether `plan` reaches a `.select` standing directly over ANOTHER `.select`
/// over a `.product` — the WHERE-above-a-separate-ON-gate shape the barrier
/// preserves (the outer `select` the `WHERE`, the inner the residual `ON`
/// gate), as opposed to one fused `.select(ON AND WHERE, product)`.
private func separated(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .select(_, .product)):
    true
  case let .select(_, source):
    separated(source)
  case let .project(_, source):
    separated(source)
  case let .sort(_, source):
    separated(source)
  case let .limit(_, _, source):
    separated(source)
  case let .distinct(source):
    separated(source)
  case let .derived(_, sub, _, _):
    separated(sub)
  case let .product(left, right):
    separated(left) || separated(right)
  case let .join(outer, _, _, _, _, _, _):
    separated(outer)
  case let .outer(left, right, _, _):
    separated(left) || separated(right)
  case let .setop(_, left, right, _):
    separated(left) || separated(right)
  case let .aggregate(_, _, source):
    separated(source)
  case .single, .scan:
    false
  }
}

/// Whether `plan` reaches a `.select` standing over ANOTHER `.select` over a
/// `.join` — the WHERE-above-a-leftover-ON-gate shape the always-barrier rule
/// preserves for a pure-equi `ON` whose extra equi key `nest` leaves gating
/// over the hash join (the outer `select` the `WHERE`, the inner the leftover
/// match), as opposed to one fused `.select(match AND WHERE, join)`.
private func stacked(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .select(_, .join)):
    true
  case let .select(_, source):
    stacked(source)
  case let .project(_, source):
    stacked(source)
  case let .sort(_, source):
    stacked(source)
  case let .limit(_, _, source):
    stacked(source)
  case let .distinct(source):
    stacked(source)
  case let .derived(_, sub, _, _):
    stacked(sub)
  case let .product(left, right):
    stacked(left) || stacked(right)
  case let .join(outer, _, _, _, _, _, _):
    stacked(outer)
  case let .outer(left, right, _, _):
    stacked(left) || stacked(right)
  case let .setop(_, left, right, _):
    stacked(left) || stacked(right)
  case let .aggregate(_, _, source):
    stacked(source)
  case .single, .scan:
    false
  }
}

// MARK: - Selection-pushdown tests

/// A join catalog whose inner `Child` relation tallies its row reads, plus a
/// view `Kin` over the `Parent`/`Child` join — to prove a `WHERE` over the view
/// prunes the join's inputs BEFORE the join runs rather than after. The counter
/// rides the `Parent` relation (sorted on `Id`), so a pushed seekable key reads
/// fewer of its rows regardless of the inner join strategy.
private func counted() throws -> (catalog: Memory, reads: Counter) {
  let reads = Counter()
  let parent = [
    Field(name: "Id", type: .integer),
    Field(name: "Name", type: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    Field(name: "Pid", type: .integer),
    Field(name: "Kid", type: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.integer(1), .text("Amy")],
    [.integer(2), .text("Bob")],
    [.integer(3), .text("Cody")],
  ] as Array<Array<Value>>

  let kin = try View(query: select("""
      SELECT Parent.Id, Parent.Name, Child.Kid FROM Parent
        JOIN Child ON Child.Pid = Parent.Id
      """), columns: ["Key", "Name", "Kid"])
  let catalog =
      Memory([
        "Parent": FixtureRelation(parent, parents, sorted: 0, counter: reads),
        "Child": FixtureRelation(child, children),
      ], views: ["Kin": kin])
  return (catalog, reads)
}

/// A catalog for pushing a filter through a UNION view's arms: two relations
/// whose shared output column `Key` sits at DIFFERENT body ordinals — `Alpha`
/// has it first (sorted, so seekable), `Beta` last (unsorted) — exposed by a
/// `Both` view as one column. A `WHERE Key = ?` over the view must rebase PER
/// arm (each arm maps `Key` to its own body slot), pushing below every arm's
/// projection and seeking inside the `Alpha` arm.
private func spanned() throws -> Memory {
  let alpha = [
    Field(name: "Key", type: .integer),
    Field(name: "Tag", type: .text),
  ]
  let alphas = [
    [.integer(1), .text("a1")],
    [.integer(2), .text("a2")],
    [.integer(3), .text("a3")],
  ] as Array<Array<Value>>

  let beta = [
    Field(name: "Tag", type: .text),
    Field(name: "Key", type: .integer),
  ]
  let betas = [
    [.text("b1"), .integer(1)],
    [.text("b2"), .integer(2)],
  ] as Array<Array<Value>>

  // Arm 1 projects Alpha.Key (body slot 0, seekable) then Tag; arm 2 projects
  // Beta.Key (body slot 1, unseekable) then Tag — the same output `Key` at
  // differing body slots.
  let both = try View(query: select("""
      SELECT Key, Tag FROM Alpha UNION ALL SELECT Key, Tag FROM Beta
      """), columns: ["Key", "Tag"])
  return Memory([
    "Alpha": FixtureRelation(alpha, alphas, sorted: 0),
    "Beta": FixtureRelation(beta, betas),
  ], views: ["Both": both])
}

/// Whether `plan` reaches a `.union` every arm of which carries a filter pushed
/// below its projection — a seeked scan or a `.select` over its scan inside each
/// arm's body, the per-arm rebase this fix enables.
private func injected(_ plan: Plan) -> Bool {
  switch plan {
  case let .setop(_, left, right, _):
    (seeks(left) || floats(left)) && (seeks(right) || floats(right))
  case let .select(_, source):
    injected(source)
  case let .project(_, source):
    injected(source)
  case let .sort(_, source):
    injected(source)
  case let .limit(_, _, source):
    injected(source)
  case let .distinct(source):
    injected(source)
  case let .derived(_, sub, _, _):
    injected(sub)
  case let .product(left, right):
    injected(left) || injected(right)
  case let .outer(left, right, _, _):
    injected(left) || injected(right)
  case let .join(outer, _, _, _, _, _, _):
    injected(outer)
  case let .aggregate(_, _, source):
    injected(source)
  case .single, .scan:
    false
  }
}

struct EnginePushdownTests {
  @Test func `a single-relation WHERE conjunct rides below the join`() throws {
    // `WHERE Parent.Name = 'Ada'` references only the outer relation, so it
    // pushes to the Parent leaf inside the join rather than filtering the whole
    // product afterwards — `pushed` sees a filter within the join's outer.
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada'
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(pushed(plan))
  }

  @Test func `pushdown down a seekable outer key seeks that leaf inside the join`() throws {
    // `WHERE Parent.Id = 2` is seekable; pushed to the Parent leaf it becomes a
    // seek inside the join's outer, not a scan-then-filter atop the product.
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Id = 2
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(seeks(plan))
    #expect(pushed(plan))
  }

  @Test func `a trailing seekable conjunct survives a rebuilt three-term AND`() throws {
    // Pushdown flattens a single-table filter through `conjuncts` and rebuilds
    // it via `conjunction`. A right-leaning rebuild would bury the trailing
    // `Id = 5` under a nested AND, hidden from `seek` (which inspects only a
    // top-level AND's two immediate children); the left-leaning rebuild keeps it
    // the immediate RHS, as the parser produced it, so the sort-key seek
    // survives the three-term AND.
    let catalog = Memory([
      "T": FixtureRelation([
        Field(name: "Name", type: .text),
        Field(name: "Age", type: .integer),
        Field(name: "Id", type: .integer),
      ], [
        [.text("a"), .integer(1), .integer(5)],
        [.text("b"), .integer(2), .integer(6)],
      ] as Array<Array<Value>>, sorted: 2),
    ])
    let select = try parse("""
        SELECT Name FROM T WHERE Name <> 'x' AND Age > 0 AND Id = 5
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(seeks(plan))
  }

  @Test func `a seekable conjunct grouped after an unsafe one does not bypass its throw`() throws {
    // The left fold rebuilds `(1 / x) = 0 AND (name <> 'z' AND id < 0)` — parsed
    // as `A AND (B AND C)` — into `((A AND B) AND C)`, promoting the seekable
    // `id < 0` to the top-level RHS `seek` inspects. On an id-sorted table whose
    // `id < 0` run is empty, seeking that run drops every row before the earlier
    // `(1 / x) = 0` division runs, suppressing the throw the scan owes. `seek`
    // seeks a conjunct only when the residual is safe, so the unsafe division
    // residual bars the seek: the plan scans, and it raises.
    let catalog = Memory([
      "T": FixtureRelation([
        Field(name: "x", type: .integer),
        Field(name: "name", type: .text),
        Field(name: "id", type: .integer),
      ], [
        [.integer(0), .text("a"), .integer(5)],
      ] as Array<Array<Value>>, sorted: 2),
    ])
    let select = try parse("""
        SELECT id FROM T WHERE (1 / x) = 0 AND (name <> 'z' AND id < 0)
        """)

    // The unsafe `(1 / x) = 0` residual bars the `id < 0` seek — the plan scans.
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(!seeks(plan))

    // …and the scan raises the division rather than seeking past the empty run.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `pushdown preserves the join's result`() throws {
    // The pushed plan must return exactly the un-pushed join's rows.
    try family().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada'
        """,
        yields: [["Ann"], ["Amy"]])
  }

  @Test func `a non-key predicate on the joined-in relation still uses the join`() throws {
    // `WHERE Parent.Name <> 'zz'` references only the joined-in `Parent`, so
    // pushdown wraps that inner leaf as `Select(_, Scan(Parent))` before the
    // join folds it in. `nest` must look through that pushed filter and still
    // form a `Join` — not fall back to a residual product filtered by the ON
    // predicate (O(left × filtered-right)).
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Parent.Name <> 'zz'
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(joins(plan))

    // …and it returns the correct rows: every child with a matching parent,
    // the joined-in predicate keeping all of them (no parent is named 'zz').
    try family().expect("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Parent.Name <> 'zz'
        """,
        yields: [["Ann", "Ada"], ["Amy", "Ada"], ["Bob", "Bee"]])
  }

  @Test func `a spanning WHERE leaves the join path with a residual above it`() throws {
    // `WHERE Parent.Name <> Child.Name` references BOTH joined relations, so it
    // descends no further than the product and stays as a residual. The ON
    // match must remain adjacent to the product — folded in with the spanning
    // conjunct — so `nest` still finds it and forms a `Join`, keeping the
    // spanning predicate as a `Select` ABOVE the join rather than degrading to a
    // filtered Cartesian `product`.
    let catalog = try family()
    let select = try parse("""
        SELECT Child.Name, Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id WHERE Parent.Name <> Child.Name
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(joins(plan))
    #expect(floats(plan))

    // …and it returns the join's rows filtered by the spanning predicate: every
    // matched pair survives, none sharing a name across the two relations.
    try family().expect("""
        SELECT Child.Name, Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id WHERE Parent.Name <> Child.Name
        """,
        yields: [["Ann", "Ada"], ["Amy", "Ada"], ["Bob", "Bee"]])
  }

  @Test func `a WHERE over a join view prunes its rows before the join runs`() throws {
    // `Kin` is the Parent/Child join; `WHERE Key = 2` over it must push INTO the
    // view's sub-plan and seek Parent to the single matching row before joining,
    // so only that parent's rows are read — not the whole relation.
    let (culled, pruned) = try counted()
    let rows = try culled.run(parse("SELECT Kid FROM Kin WHERE Key = 2"))
    #expect(rows == [[.text("Bob")]])

    // The un-pushed baseline: the same view with no `WHERE` reads every parent
    // row — three.
    let (whole, full) = try counted()
    _ = try whole.run(parse("SELECT Kid FROM Kin"))
    #expect(full.reads == 3)

    // Pushed, the seek reads the one matching parent — a single row.
    #expect(pruned.reads == 1)
  }

  @Test func `the pushed view result matches the unfiltered view filtered late`() throws {
    // Running the view then filtering must agree with the pushed plan.
    let (catalog, _) = try counted()
    let all = try catalog.run(parse("SELECT Key, Kid FROM Kin"))
    let culled = all.filter { $0[0] == .integer(2) }.map { [$0[1]] }
    let filtered =
        try catalog.run(parse("SELECT Kid FROM Kin WHERE Key = 2"))
    #expect(filtered == culled)
  }

  @Test func `a slotless predicate stays above the join and skips an empty product`() throws {
    // `WHERE (1 / 0) = 0` reads no slots, so it must stay at the product level
    // and run per pair — not ride down to the left input. `B` is empty, so the
    // join's product is empty and the throwing expression is never evaluated;
    // the query returns no rows. Pushed to the left, it would run once per left
    // row and raise `SQLError.divide`.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer)],
                    [[.integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "y", type: .integer)],
                    [] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / 0) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `a throwing single-side predicate stays above the join, skips an empty product`() throws {
    // `WHERE (1 / A.x) = 0` reads only `A`'s slot but CAN throw (division), so —
    // like a slotless throwing predicate — it must stay at the product level, not
    // ride down to `A`. `B` is empty, so the product is empty and the division is
    // never evaluated; the query returns no rows. Pushed to `A` (x = 0) it would
    // divide by zero and raise `SQLError.divide`.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "y", type: .integer)],
                    [] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / A.x) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `an unsafe conjunct bars a later safe one from suppressing its throw`() throws {
    // `WHERE (1 / A.x) = 0 AND A.x <> 0`: left-to-right, the division runs first
    // and raises on the matching pair (`A.x = 0` joined to `B.y = 0`). The safe
    // `A.x <> 0` must NOT ride down to `A` — doing so would drop the row before
    // the division runs, silently returning no rows. The earlier unsafe conjunct
    // is an ordering barrier, so the query raises as the un-pushed `AND` would.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "y", type: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.self) {
      _ = try catalog.run(parse("""
          SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / A.x) = 0 AND A.x <> 0
          """))
    }
  }

  @Test func `a lifted inner filter keeps its place before a later unsafe residual`() throws {
    // `WHERE Parent.Name = 'nope' AND (1 / Child.x) = 0`: left-to-right, the
    // false `Parent.Name` check short-circuits before the division on the
    // matching pair (Child.x = 0). `Parent.Name = 'nope'` is a single-side inner
    // filter that nest lifts out of the join — it must stay BEFORE the unsafe
    // division in the residual, not be appended after it, or the division runs
    // first and raises. The matching Parent is named 'other', so the row is
    // excluded with no throw.
    let catalog = Memory([
      "Child": FixtureRelation([Field(name: "Pid", type: .integer),
                         Field(name: "x", type: .integer)],
                        [[.integer(1), .integer(0)]] as Array<Array<Value>>),
      "Parent": FixtureRelation([Field(name: "Id", type: .integer),
                          Field(name: "Name", type: .text)],
                         [[.integer(1), .text("other")]]
                             as Array<Array<Value>>),
    ])
    let rows = try catalog.run(parse("""
        SELECT Child.x FROM Child JOIN Parent ON Parent.Id = Child.Pid
          WHERE Parent.Name = 'nope' AND (1 / Child.x) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `a WHERE over a UNION view pushes into every arm's projection`() throws {
    // `Both` unions `Alpha` and `Beta`, whose shared `Key` output column sits at
    // DIFFERING body slots. `WHERE Key = 2` must rebase PER ARM — the union root
    // fails a single pre-rebased filter — pushing below each arm's projection
    // and seeking the sorted `Alpha` arm.
    let catalog = try spanned()
    let select = try parse("SELECT Tag FROM Both WHERE Key = 2")
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(injected(plan))
    #expect(seeks(plan))

    // …and the rows are exactly the union filtered late: `a2` from Alpha and
    // `b2` from Beta.
    let rows = try catalog.run(select)
    #expect(rows == [[.text("a2")], [.text("b2")]])
  }

  @Test func `a view's throwing projection term is not suppressed by a pushed filter`() throws {
    // The view projects `1 / z`, which raises on the `z = 0` row. `derive`
    // evaluates every projected column for every view row, so `SELECT id FROM V
    // WHERE id <> 0` raises even though `id <> 0` would exclude that row —
    // pushing `id <> 0` below the view's Project would filter the row first and
    // silently skip the division, so a view whose projection can throw is never
    // pushed into.
    let t = [Field(name: "id", type: .integer),
             Field(name: "z", type: .integer)]
    let rows = [[.integer(0), .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT id, 1 / z FROM T"),
                        columns: ["id", "q"])
    let catalog = Memory(["T": FixtureRelation(t, rows)], views: ["V": view])
    #expect(throws: SQLError.self) {
      _ = try catalog.run(parse("SELECT id FROM V WHERE id <> 0"))
    }
  }

  @Test func `an unsafe outer conjunct bars a later push into a view`() throws {
    // `V` is `SELECT x FROM T` with `T.x` sorted and a single `x = 0` row.
    // `SELECT x FROM V WHERE (1 / x) = 0 AND x = 1`: left-to-right, the division
    // runs on the `x = 0` row and raises. The safe seekable `x = 1` must NOT push
    // into the view past the earlier unsafe `(1 / x) = 0` — doing so would SEEK
    // the view (`T.x` sorted) to `x = 1`, dropping the `x = 0` row before the
    // outer division ever runs, silently returning no rows. The unsafe outer
    // conjunct is an ordering barrier, so the query raises as the un-pushed `AND`
    // would.
    let t = [Field(name: "x", type: .integer)]
    let rows = [[.integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x FROM T"), columns: ["x"])
    let catalog = Memory(["T": FixtureRelation(t, rows, sorted: 0)],
                         views: ["V": view])
    #expect(throws: SQLError.self) {
      _ = try catalog.run(parse("SELECT x FROM V WHERE (1 / x) = 0 AND x = 1"))
    }
  }

  @Test func `a nullable conjunct is not pushed below a later unsafe conjunct`() throws {
    // `WHERE A.x = 1 AND (1 / B.y) = 0`: the evaluator's `AND` does not short-
    // circuit, so on the matching pair (A.x NULL, B.y = 0) the UNKNOWN left
    // still runs the right, and the division raises. The safe `A.x = 1`
    // references a slot, so a NULL there makes it UNKNOWN — pushing it to `A`'s
    // scan would drop the A.x-NULL row before the join, so the later unsafe
    // `(1 / B.y) = 0` never runs and the throw the `AND` owes is suppressed. A
    // nullable conjunct must NOT ride past a LATER unsafe conjunct, so `A.x = 1`
    // stays a product-level residual and the query raises.
    let catalog = Memory([
      "A": FixtureRelation([Field(name: "x", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.null, .integer(0)]] as Array<Array<Value>>),
      "B": FixtureRelation([Field(name: "y", type: .integer),
                     Field(name: "k", type: .integer)],
                    [[.integer(0), .integer(0)]] as Array<Array<Value>>),
    ])
    let select = try parse("""
        SELECT A.x FROM A JOIN B ON A.k = B.k
          WHERE A.x = 1 AND (1 / B.y) = 0
        """)

    // `A.x = 1` is nullable and precedes the unsafe division, so it is NOT
    // pushed to the `A` leaf — it floats at the product level.
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(!pushed(plan))
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `a nullable conjunct is not pushed into a view below a later unsafe one`() throws {
    // `V` exposes safe columns `x` and `y`. `SELECT x FROM V WHERE x = 1 AND
    // (1 / y) = 0`: the `AND` does not short-circuit, so on the (x NULL, y = 0)
    // row the UNKNOWN left still runs the division, which raises. Pushing the
    // nullable `x = 1` into the view would drop the x-NULL row before the outer
    // division runs, suppressing the throw. A nullable conjunct must NOT be
    // injected past a LATER unsafe outer conjunct, so `x = 1` stays outer and
    // the query raises.
    let t = [Field(name: "x", type: .integer),
             Field(name: "y", type: .integer)]
    let rows = [[.null, .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x, y FROM T"),
                        columns: ["x", "y"])
    let catalog = Memory(["T": FixtureRelation(t, rows)], views: ["V": view])
    let select = try parse("SELECT x FROM V WHERE x = 1 AND (1 / y) = 0")

    // `x = 1` is nullable and precedes the unsafe division, so it is NOT
    // injected into the view — it floats above the derived leaf.
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `a slotless bound conjunct is not pushed into a view below a later unsafe one`() throws {
    // A `.bound` predicate compares against a run-time `:parameter` and reads no
    // slot, yet it is UNKNOWN when the parameter is unbound (or bound to NULL).
    // `SELECT x FROM V WHERE 1 = :missing AND (1 / y) = 0` with `:missing`
    // unbound: the outer `AND` does not short-circuit, so on the (y = 0) row the
    // UNKNOWN left still runs the division, which raises. Injecting the slotless
    // `1 = :missing` into the view would drop every row first, suppressing the
    // throw. A bound conjunct is nullable despite reading no slot, so it stays
    // outer and the query raises.
    let t = [Field(name: "x", type: .integer),
             Field(name: "y", type: .integer)]
    let rows = [[.integer(1), .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x, y FROM T"),
                        columns: ["x", "y"])
    let catalog = Memory(["T": FixtureRelation(t, rows)], views: ["V": view])
    let select = try parse("SELECT x FROM V WHERE 1 = :missing AND (1 / y) = 0")

    // `1 = :missing` is a slotless bound predicate, hence nullable; it precedes
    // the unsafe division, so it is NOT injected into the view — it floats above
    // the derived leaf.
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try catalog.run(select)
    }
  }

  @Test func `a throwing WHERE is not evaluated for a pair an UNKNOWN ON rejects`() throws {
    // `A JOIN V ON A.k = V.k WHERE (1 / A.x) = 0` where `V` is a derived view,
    // so `nest` cannot fold the product into a `Join`. On the `A` row with a
    // NULL `k` and `x = 0`, the ON match is UNKNOWN — the join forms no pair for
    // it — but `evaluate(.and)` does not short-circuit, so folding the match and
    // WHERE into one AND would evaluate `(1 / 0)` and raise. Keeping the match a
    // separate inner gate drops that pair before the WHERE runs, so the query
    // does not raise: the matched `x = 1` row fails `(1 / 1) = 0`, leaving no
    // rows.
    let a = [Field(name: "x", type: .integer), Field(name: "k", type: .integer)]
    let catalog = Memory([
      "A": FixtureRelation(a, [[.integer(1), .integer(1)],
                        [.integer(0), .null]] as Array<Array<Value>>),
      "T": FixtureRelation([Field(name: "k", type: .integer)],
                    [[.integer(1)]] as Array<Array<Value>>),
    ], views: ["V": try View(query: select("SELECT k FROM T"),
                             columns: ["k"])])
    let select =
        try parse("SELECT A.x FROM A JOIN V ON A.k = V.k WHERE (1 / A.x) = 0")

    // The UNKNOWN-ON pair (A.k NULL) is dropped by the match gate before the
    // division runs, so the query returns rows rather than raising.
    #expect(try catalog.run(select) == [])
  }
}

// MARK: - Hash-join tests

/// A join catalog whose inner `Parent` is UNSORTED (so its join key is not
/// seekable and the executor hashes it) and tallies its row reads — to prove the
/// hash build scans the inner exactly once rather than once per outer record.
private func hashable() -> (catalog: Memory, reads: Counter) {
  let reads = Counter()
  let parent = [
    Field(name: "Id", type: .integer),
    Field(name: "Name", type: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    Field(name: "Pid", type: .integer),
    Field(name: "Kid", type: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.integer(1), .text("Amy")],
    [.integer(2), .text("Bob")],
    [.integer(9), .text("Orphan")],
  ] as Array<Array<Value>>

  let catalog = Memory([
    "Parent": FixtureRelation(parent, parents, counter: reads),
    "Child": FixtureRelation(child, children),
  ])
  return (catalog, reads)
}

struct EngineHashJoinTests {
  @Test func `a hash join over an unsorted inner scans it exactly once`() throws {
    // `Parent` is unsorted, so its `Id` is not seekable and the join hashes it.
    // Four outer children probe the map, but the inner is read only three times
    // — its row count — not twelve (once per outer).
    let (catalog, reads) = hashable()
    let rows = try catalog.run(parse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """))
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
    #expect(reads.reads == 3)
  }

  @Test func `a coded-index inner key seeks rather than hashing the whole inner`() throws {
    // The join strategy is chosen by probing the inner key for seekability. A
    // decoded coded-index column is 1-based and rejects the null reference `0`,
    // so probing with `0` would call it unseekable and hash every inner row;
    // probing with a valid `1` finds it seekable, so a selective join seeks the
    // coded run instead. `Attribute.Parent` is such a column (stored raw
    // `(Id << 2) | tag`, decoded to a Id), and one `Type` (Id 6) probes it.
    let reads = Counter()
    let type = [Field(name: "Id", type: .integer)]
    let types = [[.integer(6)]] as Array<Array<Value>>
    let attribute = [
      Field(name: "Parent", type: .integer),
      Field(name: "Name", type: .text),
    ]
    let attributes = [
      [.integer(0), .text("null-ref")],
      [.integer(4), .text("td1")],
      [.integer(8), .text("td2")],
      [.integer(16), .text("td4")],
      [.integer(20), .text("td5")],
      [.integer(24), .text("td6")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Type": FixtureRelation(type, types),
      "Attribute": FixtureRelation(attribute, attributes, coded: 0,
                                   counter: reads),
    ])
    let rows = try catalog.run(parse("""
        SELECT Attribute.Name FROM Type
          JOIN Attribute ON Attribute.Parent = Type.Id
        """))
    #expect(rows == [[.text("td6")]])
    // Seeked: only the `Parent = 6` run (the single `td6` row) is read, not all
    // six. Before the fix — probing seekability with `0` — the coded column
    // tested unseekable and the join hashed, reading every attribute row.
    #expect(reads.reads == 1)
  }

  @Test func `an empty outer skips the hash build of an unseekable inner`() throws {
    // A contradictory outer WHERE prunes every `Child`, so the outer is empty
    // and no probe can match. The inner `Parent` is unsorted (unseekable), so
    // the join would hash it — but with no probes the build is pointless. The
    // empty-outer short-circuit returns before scanning, so ZERO inner rows are
    // read; the nested-loop path this replaced already read none for an empty
    // outer, and a large unseekable inner must not be fully scanned to answer
    // nothing.
    let (catalog, reads) = hashable()
    let rows = try catalog.run(parse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Child.Pid < 0
        """))
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }

  @Test func `an all-NULL-key outer skips the hash build of an unseekable inner`() throws {
    // The outer is NON-empty but every `Child.Pid` is NULL (a `WHERE Pid IS
    // NULL` keeps only the null-keyed rows), and a NULL key joins to nothing —
    // so no probe can match. The inner `Parent` is unsorted (unseekable), so the
    // join would hash it; but with no non-null probe the build is pointless. The
    // no-probe guard returns before scanning, so ZERO inner rows are read — the
    // nested-loop path this replaced read none for an all-null outer too.
    let reads = Counter()
    let parent = [
      Field(name: "Id", type: .integer),
      Field(name: "Name", type: .text),
    ]
    let parents = [
      [.integer(1), .text("Ada")],
      [.integer(2), .text("Bee")],
    ] as Array<Array<Value>>
    let child = [
      Field(name: "Pid", type: .integer),
      Field(name: "Kid", type: .text),
    ]
    let children = [
      [.integer(1), .text("Ann")],
      [.null, .text("Nemo")],
      [.null, .text("Nobody")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Parent": FixtureRelation(parent, parents, counter: reads),
      "Child": FixtureRelation(child, children),
    ])
    let rows = try catalog.run(parse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Child.Pid IS NULL
        """))
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }

  @Test func `the hash probe and the seek probe return identical results`() throws {
    // The sorted `Parent` seeks; its unsorted twin hashes. Both inner orderings
    // must agree — the hash preserves the seek path's outer-major, inner-cursor
    // order.
    let seek = try join("""
        SELECT Parent.Name, Child.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """)
    let hash = try join("""
        SELECT P.Name, Child.Name FROM Child
          JOIN ParentUnsorted AS P ON P.Id = Child.Pid
        """)
    #expect(hash == seek)
    #expect(hash == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test func `a hash join emits matches outer-major in inner cursor order`() throws {
    // The unsorted twin forces the hash path. Without an ORDER BY the result
    // must be outer-major (each child in scan order), and a bucket's inner rows
    // in the inner's cursor order — exactly the nested loop's order.
    let forced = try join("""
        SELECT Child.Name, P.Name FROM Child
          JOIN ParentUnsorted AS P ON P.Id = Child.Pid
        """)
    #expect(forced == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test func `a NULL key joins to nothing under the hash path`() throws {
    // The child with a NULL foreign key is the outer row; a NULL key hashes to
    // nothing, and a NULL inner key is never bucketed. `Parent` here is unsorted
    // so the join hashes.
    let parent = [
      Field(name: "Id", type: .integer),
      Field(name: "Name", type: .text),
    ]
    let parents = [
      [.integer(1), .text("Ada")],
      [.integer(2), .text("Bee")],
    ] as Array<Array<Value>>
    let child = [
      Field(name: "Pid", type: .integer),
      Field(name: "Name", type: .text),
    ]
    let children = [
      [.integer(1), .text("Ann")],
      [.null, .text("Nobody")],
      [.integer(2), .text("Bob")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Parent": FixtureRelation(parent, parents),
      "Child": FixtureRelation(child, children),
    ])
    let rows = try catalog.run(parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """))
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test func `a seekable inner filter seeks the hash inner rather than scanning it`() throws {
    // `Parent.Code` (the join key) is unseekable, so the join hashes the inner;
    // `Parent.Id` is sorted (seekable and ordered). `Child JOIN Parent ON
    // Parent.Code = Child.Code WHERE Parent.Id < 0` pushes `Parent.Id < 0` onto
    // the inner. Applied DURING inner materialisation, that contradictory
    // seekable filter seeks the inner to an empty run — every `Id` is positive —
    // so ZERO Parent rows are read and the query returns []. Before the fix the
    // filter rode the residual ABOVE the join, so the whole inner was scanned and
    // bucketed (three reads) before the filter matched none of it.
    let reads = Counter()
    let parent = [
      Field(name: "Id", type: .integer),
      Field(name: "Code", type: .integer),
    ]
    let parents = [
      [.integer(1), .integer(10)],
      [.integer(2), .integer(20)],
      [.integer(3), .integer(30)],
    ] as Array<Array<Value>>
    let child = [
      Field(name: "Code", type: .integer),
      Field(name: "Kid", type: .text),
    ]
    let children = [
      [.integer(10), .text("Ann")],
      [.integer(20), .text("Bob")],
    ] as Array<Array<Value>>
    // `Parent` is sorted on `Id` (column 0), so `Id` seeks but the join key
    // `Code` (column 1) does not — forcing the hash path.
    let catalog = Memory([
      "Parent": FixtureRelation(parent, parents, sorted: 0, counter: reads),
      "Child": FixtureRelation(child, children),
    ])
    let rows = try catalog.run(parse("""
        SELECT Child.Kid, Parent.Id FROM Child
          JOIN Parent ON Parent.Code = Child.Code WHERE Parent.Id < 0
        """))
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }
}

// MARK: - Streaming-product tests

struct EngineStreamingProductTests {
  @Test func `a join whose inner is a view leaves a residual product-under-select`() throws {
    // The nest rewrite folds a bare scan into an index-nested join, but the
    // inner here is the `Adults` VIEW (a `derived` leaf), so nest cannot fire
    // and the level stays a `select` over a `product` — the shape the streaming
    // executor fuses.
    let catalog = try views()
    let select = try parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """)
    let plan =
        try catalog.optimise(catalog.compile(select).pushdown(), [:])
    #expect(residual(plan))
  }

  @Test func `the streamed product filters row by row to the right rows`() throws {
    // `Adults` is Parent rows with Id >= 2 (Key 2 → Bee, 3 → Cid); only the
    // child whose Pid equals a Key survives — Bob (Pid 2) against Bee.
    let catalog = try views()
    let rows = try catalog.run(parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """))
    #expect(rows == [[.text("Bob"), .text("Bee")]])
  }

  @Test func `the streamed product equals the eager product filtered`() throws {
    // Cross the two inputs by hand — every child paired with every adult in
    // outer-major order — and keep the pairs the ON equality admits. The fused
    // streaming operator must yield exactly this, in this order.
    let catalog = try views()
    let children = try catalog.run(parse("SELECT Name, Pid FROM Child"))
    let adults = try catalog.run(parse("SELECT Label, Key FROM Adults"))

    var eager = Array<Array<Value>>()
    for child in children {
      for adult in adults where child[1] == adult[1] {
        eager.append([child[0], adult[0]])
      }
    }

    let streamed = try catalog.run(parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """))
    #expect(streamed == eager)
  }

  @Test func `a residual product with UNKNOWN pairs drops them`() throws {
    // A NULL-keyed pair evaluates the ON equality to UNKNOWN, which the fused
    // filter drops exactly as `admitted` would — no NULL child reaches a match.
    let child = [
      Field(name: "Pid", type: .integer),
      Field(name: "Name", type: .text),
    ]
    let children = [
      [.integer(2), .text("Bob")],
      [.null, .text("Nobody")],
    ] as Array<Array<Value>>
    let adults = try View(query: select("""
        SELECT Id, Name FROM Base WHERE Id >= 2
        """), columns: ["Key", "Label"])
    let base = [
      Field(name: "Id", type: .integer),
      Field(name: "Name", type: .text),
    ]
    let bases = [
      [.integer(2), .text("Bee")],
      [.integer(3), .text("Cid")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Child": FixtureRelation(child, children),
      "Base": FixtureRelation(base, bases, sorted: 0),
    ], views: ["Adults": adults])
    let rows = try catalog.run(parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """))
    #expect(rows == [[.text("Bob"), .text("Bee")]])
  }
}

// MARK: - Scalar-function tests

/// Routines with a demonstration scalar function `add`, which sums two integer
/// cells — standing in for the per-dialect decode functions a synthesis
/// projection calls. Built from `Routines.standard` so the prelude (`UPPER`,
/// `BITAND`, …) resolves here as it does at the engine's public entry points,
/// which seed the prelude by default; the string built-in `UPPER` folds a text
/// cell to upper case, so no demo `upper` is registered (it is protected).
private func routines() -> Routines {
  try! Routines.standard
    .registering("add", parameters: [.integer, .integer]) {
      arguments throws(SQLError) in
      guard arguments.count == 2,
          case let .integer(lhs) = arguments[0],
          case let .integer(rhs) = arguments[1] else {
        throw .argument("add expects two integer arguments")
      }
      return .integer(lhs + rhs)
    }
}

/// Runs `text` against the `People` catalog through the demonstration routines.
private func functionRun(_ text: String) throws -> Array<Array<Value>> {
  try people().run(parse(text), routines())
}

struct EngineFunctionTests {
  @Test func `a registered function projects over a column`() throws {
    let rows = try functionRun("SELECT upper(Name) FROM People WHERE Id = 1")
    #expect(rows == [[.text("ALICE")]])
  }

  @Test func `a function projects beside a bare column`() throws {
    let rows =
        try functionRun("SELECT Id, upper(Name) FROM People WHERE Id = 3")
    #expect(rows == [[.integer(3), .text("CAROL")]])
  }

  @Test func `a function takes more than one column argument`() throws {
    let rows = try functionRun("SELECT add(Id, Age) FROM People WHERE Id = 2")
    // Bob: Id 2 + Age 25 = 27.
    #expect(rows == [[.integer(27)]])
  }

  @Test func `a function takes a literal argument`() throws {
    let rows = try functionRun("SELECT add(Id, 100) FROM People WHERE Id = 4")
    #expect(rows == [[.integer(104)]])
  }

  @Test func `a function call nests another function call`() throws {
    let rows =
        try functionRun("SELECT add(add(Id, 1), Age) FROM People WHERE Id = 5")
    // Eve: (5 + 1) + 25 = 31.
    #expect(rows == [[.integer(31)]])
  }

  @Test func `an unregistered function is reported`() throws {
    #expect(throws: SQLError.function("missing")) {
      try functionRun("SELECT missing(Name) FROM People")
    }
  }

  @Test func `a function rejecting its arguments reports the fault`() throws {
    // The run path does not statically type-check a call — it invokes the
    // routine, whose own kind check faults an INTEGER passed to the text
    // built-in UPPER.
    #expect(throws: SQLError.argument("UPPER requires a text argument")) {
      try functionRun("SELECT upper(Id) FROM People WHERE Id = 1")
    }
  }

  @Test func `a function call resolves its name case-insensitively`() throws {
    // The built-in `UPPER` resolves through the seeded prelude; the natural SQL
    // spelling UPPER resolves to it, as table and column identifiers do.
    let rows = try functionRun("SELECT UPPER(Name) FROM People WHERE Id = 1")
    #expect(rows == [[.text("ALICE")]])
  }

  @Test func `the prelude BITAND yields the bitwise AND of two integers`() throws {
    // BITAND ships in the prelude (`Routines.standard`): `routines()` never
    // registers it, yet the call resolves through the seeded prelude and folds
    // case-insensitively. 12 & 10 = 8; 6 & 3 = 2.
    #expect(try functionRun("SELECT BITAND(12, 10) FROM People WHERE Id = 1")
            == [[.integer(8)]])
    #expect(try functionRun("SELECT bitand(6, 3) FROM People WHERE Id = 1")
            == [[.integer(2)]])
  }

  @Test func `BITAND reports a function-argument fault, not a UNION arity error`() throws {
    // The wrong argument count is a function-argument fault (`.argument`), not
    // `.arity` — whose message is the UNION column-count mismatch.
    #expect(throws: SQLError.argument("BITAND takes two arguments")) {
      try functionRun("SELECT BITAND(1) FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.argument("BITAND requires integer arguments")) {
      try functionRun("SELECT BITAND('a', 1) FROM People WHERE Id = 1")
    }
  }

  @Test func `registering over a protected prelude routine is rejected`() throws {
    // BITAND is a protected standard built-in, so a caller cannot shadow it
    // through `registering`: the binding faults (SQLSTATE 42723) rather than
    // silently changing what a query naming BITAND computes. The prelude one
    // therefore always wins at the query's call site.
    #expect(throws: SQLError.state("42723",
        "'bitand' is a standard routine and cannot be redefined")) {
      try Routines.standard
          .registering("bitand", parameters: [.integer, .integer]) {
            _ throws(SQLError) in .integer(-1)
          }
    }
  }

  @Test func `routine names colliding only by case merge without trapping`() throws {
    // "tag" and "TAG" fold to one name; the registry merges them (the later-
    // sorting original spelling wins) instead of trapping on the duplicate.
    let routines: Routines =
        ["tag": Routine(returns: .text, parameters: [.text]) {
          _ in .text("lower")
        },
         "TAG": Routine(returns: .text, parameters: [.text]) {
          _ in .text("upper")
        }]
    let query = try parse("SELECT tag(Name) FROM People WHERE Id = 1")
    let rows = try people().run(query, routines)
    #expect(rows == [[.text("lower")]])
  }

  @Test func `a predicate filters on a scalar function call`() throws {
    // The documented contract: a predicate may call a registered function;
    // `upper(Name) = 'ALICE'` decodes the column before comparing.
    let rows =
        try functionRun("SELECT Id FROM People WHERE upper(Name) = 'ALICE'")
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a predicate compares a function result to an integer`() throws {
    let rows =
        try functionRun("SELECT Name FROM People WHERE add(Id, 10) = 12")
    #expect(rows == [[.text("Bob")]])
  }
}

// MARK: - Defined function (CREATE FUNCTION) tests

/// The routines with the DEFINED functions each `CREATE FUNCTION` in `defs`
/// registers, seeded from the standard prelude — the consumer's registration
/// path, folding a parsed `CREATE FUNCTION` into a `Routines`.
private func defining(_ defs: String...) throws -> Routines {
  var routines = Routines.standard
  for def in defs {
    guard case let .function(name, function) = try Statement(parsing: def)
    else {
      throw SQLError.incomplete(expected: "a CREATE FUNCTION statement")
    }
    routines = try routines.registering(name, function)
  }
  return routines
}

struct EngineDefinedFunctionTests {
  @Test func `a defined function evaluates its body over the arguments`() throws {
    let routines =
        try defining("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                         + "AS n + n")
    let rows =
        try people().run(parse("SELECT twice(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; twice(30) = 60.
    #expect(rows == [[.integer(60)]])
  }

  @Test func `a defined function binds each parameter to its argument by position`() throws {
    let routines =
        try defining("CREATE FUNCTION span(lo INTEGER, hi INTEGER) "
                         + "RETURNS INTEGER AS hi - lo")
    let rows =
        try people().run(parse("SELECT span(Id, Age) FROM People WHERE Id = 4"),
                         routines)
    // Dave: Id 4, Age 40; span(4, 40) = 36.
    #expect(rows == [[.integer(36)]])
  }

  @Test func `a defined function projects beside a bare column`() throws {
    let routines =
        try defining("CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1")
    let rows =
        try people().run(parse("SELECT Id, inc(Age) FROM People WHERE Id = 2"),
                         routines)
    // Bob: Id 2, Age 25; inc(25) = 26.
    #expect(rows == [[.integer(2), .integer(26)]])
  }

  @Test func `a defined function filters in a predicate`() throws {
    let routines =
        try defining("CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1")
    let rows =
        try people().run(parse("SELECT Name FROM People WHERE inc(Age) = 31"),
                         routines)
    // Alice and Carol are 30; inc(30) = 31.
    #expect(rows == [[.text("Alice")], [.text("Carol")]])
  }

  @Test func `a parameterless defined function yields its constant body`() throws {
    let routines =
        try defining("CREATE FUNCTION answer() RETURNS INTEGER AS 40 + 2")
    let rows =
        try people().run(parse("SELECT answer() FROM People WHERE Id = 1"),
                         routines)
    #expect(rows == [[.integer(42)]])
  }

  @Test func `a defined function propagates a NULL argument through its body`() throws {
    // A NULL bound to a parameter propagates through the body's arithmetic (SQL
    // null propagation), so the result is NULL rather than a fault.
    let routines =
        try defining("CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1")
    let catalog = try Catalog {
      Relation("N", ["Id": .integer, "V": .integer]) {
        Row(1, nil)
      }
    }
    let rows = try catalog.run(parse("SELECT inc(V) FROM N WHERE Id = 1"),
                               routines)
    #expect(rows == [[.null]])
  }

  @Test func `a call with the wrong argument count faults with the declared arity`() throws {
    // The declared `parameters` contract is what the static type-check (the
    // `call` contract check, the schema path drives) validates a call against,
    // exactly as it does a native routine's signature — a wrong argument count
    // is a function-argument fault reporting the declared arity.
    let routines =
        try defining("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                         + "AS n + n")
    #expect(throws: SQLError.argument("twice takes 1 arguments")) {
      try people().columns(of: parse("SELECT twice(Id, Age) FROM People"),
                           routines: routines)
    }
  }

  @Test func `a call with a wrong argument kind faults against the parameter type`() throws {
    // A definitively-wrong argument type (text where an integer parameter is
    // declared) is rejected by the same `call` contract check.
    let routines =
        try defining("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                         + "AS n + n")
    #expect(throws: SQLError.argument("twice requires integer arguments")) {
      try people().columns(of: parse("SELECT twice(Name) FROM People"),
                           routines: routines)
    }
  }

  @Test func `typing reports the declared RETURNS of a defined function`() throws {
    // The result-schema walk types a `f(...)` call by the routine's declared
    // return type without running it, so a defined function's declared RETURNS
    // is what the output column reports.
    let routines =
        try defining("CREATE FUNCTION label(n INTEGER) RETURNS TEXT AS 'x'")
    let columns =
        try people().columns(of: parse("SELECT label(Id) AS L FROM People"),
                             routines: routines)
    #expect(columns.count == 1)
    #expect(columns[0] == OutputColumn(name: "L", type: .text))
  }

  @Test func `a defined function body naming an unknown parameter faults at define`() throws {
    // The body is lowered against its parameters at registration, so a reference
    // to a name the function does not declare faults there — the moment a
    // `CREATE FUNCTION` binds — not at each later call.
    #expect(throws: SQLError.column("m")) {
      _ = try defining("CREATE FUNCTION f(n INTEGER) RETURNS INTEGER AS m + 1")
    }
  }

  @Test func `a defined function body referencing a query parameter faults at define`() throws {
    // A body's inputs are its declared parameters, not query bindings: a routine
    // body is evaluated with only its argument record, so a `:parameter` (here
    // reached through a CASE guard) would always be UNBOUND and silently pick
    // the ELSE branch. Registration rejects the `.bound`.
    #expect(throws:
        SQLError.argument("the body cannot reference a query parameter")) {
      _ = try defining("CREATE FUNCTION f() RETURNS INTEGER AS "
                           + "CASE WHEN 1 = :p THEN 1 ELSE 0 END")
    }
  }

  @Test func `a later defined function shadows an earlier one of the same name`() throws {
    // A later registration wins (the house rule the flat registry follows), so
    // the second `inc` — adding 100 — is the one a call resolves.
    let routines = try defining(
        "CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 1",
        "CREATE FUNCTION inc(n INTEGER) RETURNS INTEGER AS n + 100")
    let rows =
        try people().run(parse("SELECT inc(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; the shadowing inc adds 100 → 130.
    #expect(rows == [[.integer(130)]])
  }

  @Test func `a body naming its own unregistered name faults as unresolved`() throws {
    // `f() RETURNS INTEGER AS f() + 1` with NO prior `f` early-binds against a
    // map without `f`, so the body's own call is unresolved: registration
    // faults `SQLError.function` — the unregistered-callee case — not a
    // self-reference one. Early binding admits no recursion; there is nothing
    // to bind to.
    #expect(throws: SQLError.function("f")) {
      _ = try defining("CREATE FUNCTION f() RETURNS INTEGER AS f() + 1")
    }
  }

  @Test func `a self-referential redefinition captures the prior function`() throws {
    // `f() AS f() + 1` REPLACING a prior `f` is well-defined under early
    // binding: the new body captures the OLD `f` and computes `f_old() + 1`,
    // terminating. With `f_old()` = 0, `SELECT f()` returns 0 + 1 = 1.
    let routines = try defining(
        "CREATE FUNCTION f() RETURNS INTEGER AS 0",
        "CREATE FUNCTION f() RETURNS INTEGER AS f() + 1")
    let rows =
        try people().run(parse("SELECT f() FROM People WHERE Id = 1"),
                         routines)
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a body calling a different existing function still registers`() throws {
    // A body calling a distinct, already-registered routine early-binds it and
    // registers cleanly — the common composition case.
    let routines = try defining(
        "CREATE FUNCTION g(n INTEGER) RETURNS INTEGER AS n + 1",
        "CREATE FUNCTION f(n INTEGER) RETURNS INTEGER AS g(n) + 1")
    let rows =
        try people().run(parse("SELECT f(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; g(30) = 31, f(30) = g(30) + 1 = 32.
    #expect(rows == [[.integer(32)]])
  }

  @Test func `a body calling a prelude routine registers against empty routines`() throws {
    // Registered against EMPTY routines — NOT `defining`, which seeds the
    // prelude — a body calling BITAND still resolves it: registration merges
    // `Routines.standard` under the caller's routines (the run/columns
    // precedence), so `lowbit(n) AS BITAND(n, 1)` binds the built-in rather
    // than faulting `SQLError.function("BITAND")`.
    guard case let .function(name, function) =
        try Statement(parsing: "CREATE FUNCTION lowbit(n INTEGER) "
                          + "RETURNS INTEGER AS BITAND(n, 1)")
    else { throw SQLError.incomplete(expected: "a CREATE FUNCTION statement") }
    let routines = try Routines().registering(name, function)
    let rows =
        try people().run(parse("SELECT lowbit(Age) FROM People WHERE Id = 1"),
                         routines)
    // Alice's Age is 30; BITAND(30, 1) = 0 (30 is even).
    #expect(rows == [[.integer(0)]])
    let odd =
        try people().run(parse("SELECT lowbit(Id) FROM People WHERE Id = 3"),
                         routines)
    // Id 3 is odd; BITAND(3, 1) = 1.
    #expect(odd == [[.integer(1)]])
  }

  @Test func `a body calling a still-unknown routine faults at registration`() throws {
    // Merging the prelude into the capture must not mask a genuinely-unknown
    // callee: a body naming `nope`, bound by neither the prelude nor a prior
    // registration, is still unresolved and faults `SQLError.function` at
    // registration — the guard against over-merging.
    #expect(throws: SQLError.function("nope")) {
      _ = try defining("CREATE FUNCTION f() RETURNS INTEGER AS nope()")
    }
  }

  @Test func `a body binds its callee at definition, not at call time`() throws {
    // The round-5 root case at the parse level. `g` returns INTEGER 1; `f() AS
    // g()` captures that INTEGER `g`. Redefining `g` to a TEXT body shadows it
    // for QUERIES, but `f` closed over the old `g`, so `SELECT f()` still
    // returns the INTEGER 1 — consistent with f's advertised INTEGER schema —
    // while `SELECT g()` sees the new TEXT `g` (query-level latest-wins holds).
    let routines = try defining(
        "CREATE FUNCTION g() RETURNS INTEGER AS 1",
        "CREATE FUNCTION f() RETURNS INTEGER AS g()",
        "CREATE FUNCTION g() RETURNS TEXT AS 'x'")
    let captured =
        try people().run(parse("SELECT f() FROM People WHERE Id = 1"),
                         routines)
    #expect(captured == [[.integer(1)]])
    let latest =
        try people().run(parse("SELECT g() FROM People WHERE Id = 1"),
                         routines)
    #expect(latest == [[.text("x")]])
  }
}

// MARK: - NULL tests

struct EngineNullTests {
  @Test func `IS NULL admits only the NULL rows`() throws {
    try nullable().expect("SELECT Id FROM Maybe WHERE Note IS NULL",
                          yields: [[2], [4]])
  }

  @Test func `IS NOT NULL admits only the non-NULL rows`() throws {
    let rows = try nullable("SELECT Id FROM Maybe WHERE Note IS NOT NULL")
    #expect(rows == [[.integer(1)], [.integer(3)]])
  }

  @Test func `a comparison against a NULL cell is UNKNOWN and rejects`() throws {
    // For the NULL rows (2, 4) `Note = 'alpha'` is UNKNOWN, not false, so they
    // are not admitted; only the row whose Note equals 'alpha' survives.
    try nullable().expect("SELECT Id FROM Maybe WHERE Note = 'alpha'",
                          yields: [[1]])
  }

  @Test func `NOT of a NULL comparison stays UNKNOWN and rejects`() throws {
    // The NULL rows are UNKNOWN; NOT UNKNOWN is UNKNOWN, so they still reject —
    // only the non-null, non-'alpha' row survives.
    let rows = try nullable("SELECT Id FROM Maybe WHERE NOT Note = 'alpha'")
    #expect(rows == [[.integer(3)]])
  }

  @Test func `a NULL cell projects as a NULL value`() throws {
    try nullable().expect("SELECT Note FROM Maybe WHERE Id = 2",
                          yields: [[nil]])
  }

  @Test func `ORDER BY ascending sorts NULL keys first, then by value`() throws {
    // NULL holds a stable position — first in ascending order — so the non-null
    // notes still sort among themselves ('alpha' before 'gamma') rather than
    // tying with the nulls and leaving the order undefined.
    try nullable().expect("SELECT Id FROM Maybe ORDER BY Note ASC",
                          yields: [[2], [4], [1], [3]])
  }

  @Test func `ORDER BY descending sorts NULL keys last`() throws {
    try nullable().expect("SELECT Id FROM Maybe ORDER BY Note DESC",
                          yields: [[3], [1], [2], [4]])
  }

  @Test func `a NULL outer join key matches no inner row`() throws {
    // The child with a NULL foreign key is the outer row; a NULL key equi-joins
    // to nothing, so it contributes no pair — `Parent` is sorted, so the inner
    // is seeked and the NULL key is skipped before probing.
    let rows = try nullableKeys().run(parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """))
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }
}

// MARK: - Bound-parameter / correlated-subquery tests

/// Runs `text` against the `family` catalog with the given parameter bindings.
private func boundRun(_ text: String, _ bindings: Bindings)
    throws -> Array<Array<Value>> {
  try family().run(parse(text), Routines(), bindings: bindings)
}

struct EngineBoundTests {
  @Test func `a bound parameter filters rows by an outer value`() throws {
    // The child relation keyed on a bound parent id — the section primitive: a
    // template renders an interface's methods by binding the interface key and
    // running the child query.
    let rows = try boundRun("SELECT Name FROM Child WHERE Pid = :pid",
                            ["pid": .integer(1)])
    #expect(rows == [[.text("Ann")], [.text("Amy")]])
  }

  @Test func `a bound text parameter compares against a text column`() throws {
    let rows = try boundRun("SELECT Id FROM Parent WHERE Name = :who",
                            ["who": .text("Bee")])
    #expect(rows == [[.integer(2)]])
  }

  @Test func `an unbound parameter admits no row`() throws {
    let rows = try boundRun("SELECT Name FROM Child WHERE Pid = :pid", [:])
    #expect(rows.isEmpty)
  }

  @Test func `a bound parameter conjoined with another predicate`() throws {
    let rows = try boundRun("""
        SELECT Name FROM Child WHERE Pid = :pid AND Name = 'Amy'
        """, ["pid": .integer(1)])
    #expect(rows == [[.text("Amy")]])
  }

  @Test func `a correlated section runs a child query per outer row`() throws {
    // The relational shape of a template's nested section: the outer query
    // yields the parents; for each, the child query is re-run with the parent's
    // key bound, producing that parent's children — exactly an interface →
    // methods expansion.
    let catalog = try family()
    let parents = try catalog.run(parse("SELECT Id, Name FROM Parent"))
    let query = try parse("SELECT Name FROM Child WHERE Pid = :pid")

    var sections = Array<(parent: String, children: Array<String>)>()
    for parent in parents {
      let key = parent[0]
      let children = try catalog.run(query, Routines(), bindings: ["pid": key])
      guard case let .text(name) = parent[1] else { continue }
      sections.append((name, children.map { row in
        guard case let .text(child) = row[0] else { return "" }
        return child
      }))
    }

    #expect(sections.count == 3)
    #expect(sections[0].parent == "Ada")
    #expect(sections[0].children == ["Ann", "Amy"])
    #expect(sections[1].parent == "Bee")
    #expect(sections[1].children == ["Bob"])
    #expect(sections[2].parent == "Cid")
    #expect(sections[2].children.isEmpty)
  }

  @Test func `an unbound parameter under NOT still admits no rows`() throws {
    // A missing binding is UNKNOWN, not false; NOT preserves UNKNOWN rather
    // than inverting it into a match, so the predicate admits nothing.
    let rows = try boundRun("SELECT Name FROM Child WHERE NOT Pid = :pid", [:])
    #expect(rows.isEmpty)
  }

  @Test func `a bound parameter under NOT inverts the match`() throws {
    let rows = try boundRun("SELECT Name FROM Child WHERE NOT Pid = :pid",
                            ["pid": .integer(1)])
    #expect(rows == [[.text("Bob")], [.text("Orphan")]])
  }

  @Test func `a bound key plans a seek when its value is known`() throws {
    // Parent is sorted on Id; with `:id` bound the planner resolves it and
    // seeks the run rather than scanning and filtering the whole relation.
    let select = try parse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = try family()
    let plan = try catalog.optimise(catalog.compile(select),
                                    ["id": .integer(2)])
    #expect(seeks(plan))
    #expect(!filters(plan))
  }

  @Test func `an unbound key cannot seek and scans under the filter`() throws {
    let select = try parse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = try family()
    let plan = try catalog.optimise(catalog.compile(select), [:])
    #expect(!seeks(plan))
    #expect(filters(plan))
  }

  @Test func `a bound key inside a view seeks when its parameter is supplied`() throws {
    // A parameterized view (`… WHERE Id = :id` over sorted Parent): the bound
    // key seeks inside the view's sub-plan rather than scanning it once :id is
    // supplied, so a reusable view is as fast as the inlined query.
    let select = try parse("SELECT Key, Label FROM Picked")
    let catalog = try views()
    let plan = try catalog.optimise(catalog.compile(select),
                                    ["id": .integer(2)])
    let sub = try #require(derived(plan))
    #expect(seeks(sub))
    #expect(!filters(sub))
  }
}

// MARK: - UNION tests

/// A three-relation catalog for `UNION`: `Lhs` and `Rhs` each hold a single
/// `Tag` text column, sharing the value `shared` so a union across them proves
/// cross-relation dedup; the values are otherwise distinct. `Extra` repeats the
/// `a` already in `Lhs`, so a trailing `UNION ALL Extra` keeps it a second
/// time — proving an inner `UNION`'s dedup survives an outer `UNION ALL`.
///
/// The relations are `Lhs`/`Rhs` rather than `Left`/`Right`, now that the
/// latter are reserved outer-join keywords.
private func tags() -> Memory {
  let fields = [Field(name: "Tag", type: .text)]
  let left = [
    [.text("a")],
    [.text("shared")],
  ] as Array<Array<Value>>
  let right = [
    [.text("shared")],
    [.text("b")],
  ] as Array<Array<Value>>
  let extra = [
    [.text("a")],
  ] as Array<Array<Value>>
  return Memory([
    "Lhs": FixtureRelation(fields, left),
    "Rhs": FixtureRelation(fields, right),
    "Extra": FixtureRelation(fields, extra),
  ])
}

struct EngineUnionTests {
  @Test func `UNION removes whole-row duplicates, keeping the first occurrence`() throws {
    // People's Age repeats (30 for Alice and Carol, 25 for Bob and Eve); a
    // UNION of the relation with itself collapses every duplicate row.
    let rows = try people().run(parse("""
        SELECT Age FROM People UNION SELECT Age FROM People
        """))
    #expect(rows == [[.integer(30)], [.integer(25)], [.integer(40)]])
  }

  @Test func `UNION ALL keeps every row of every arm in source order`() throws {
    let rows = try people().run(parse("""
        SELECT Age FROM People UNION ALL SELECT Age FROM People
        """))
    let ages = [30, 25, 30, 40, 25].map { Value.integer($0) }
    #expect(rows == (ages + ages).map { [$0] })
  }

  @Test func `a UNION across two relations of matching arity merges and dedups`() throws {
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
        """))
    // `shared` appears in both arms but survives once, first occurrence kept.
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a UNION ALL across two relations keeps the shared row twice`() throws {
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs UNION ALL SELECT Tag FROM Rhs
        """))
    #expect(rows == [
      [.text("a")],
      [.text("shared")],
      [.text("shared")],
      [.text("b")],
    ])
  }

  @Test func `an inner UNION dedups before a trailing UNION ALL appends its arm`() throws {
    // (Lhs UNION Rhs) UNION ALL Extra. The inner UNION dedups `shared`
    // across Lhs and Rhs to one row — `a, shared, b` — and the outer UNION
    // ALL then appends Extra's `a` WITHOUT deduplicating, so `a` recurs. A
    // chain flattened to the trailing `all` would instead keep both copies of
    // `shared`; honouring each node's own flag keeps exactly one.
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
          UNION ALL SELECT Tag FROM Extra
        """))
    #expect(rows == [
      [.text("a")],
      [.text("shared")],
      [.text("b")],
      [.text("a")],
    ])
  }

  @Test func `a UNION of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(1, 2)) {
      try people().run(parse("""
          SELECT Id FROM People UNION SELECT Id, Name FROM People
          """))
    }
  }

  @Test func `a view defined as a UNION resolves and queries`() throws {
    let both = try View(query: select("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
        """), columns: ["Tag"])
    let catalog = Memory(tags().catalog, views: ["Both": both])
    let rows = try catalog.run(parse("SELECT Tag FROM Both"))
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a bound parameter threads into every arm of a UNION`() throws {
    // Both arms key on the same `:pid`; the binding reaches each alike, so the
    // union is the parent's children drawn from two queries over the relation.
    let rows = try family().run(parse("""
        SELECT Name FROM Child WHERE Pid = :pid
          UNION ALL SELECT Name FROM Child WHERE Pid = :pid
        """), Routines(), bindings: ["pid": .integer(1)])
    #expect(rows == [
      [.text("Ann")],
      [.text("Amy")],
      [.text("Ann")],
      [.text("Amy")],
    ])
  }
}

// MARK: - INTERSECT / EXCEPT tests

/// A two-relation catalog for `INTERSECT`/`EXCEPT` multiplicity: `A` and `B`
/// each hold a single integer `N`, with duplicates chosen so the operators'
/// `ALL` counts differ from their distinct forms. `A` holds `1` twice, `2`
/// thrice, `3` once and `4` once; `B` holds `2` twice, `3` once, `5` once. Thus
/// `2` and `3` are common (with differing multiplicities), `1`/`4` are A-only,
/// and `5` is B-only — enough to exercise `min` (INTERSECT ALL) and the floored
/// difference (EXCEPT ALL).
private func multiset() -> Memory {
  let fields = [Field(name: "N", type: .integer)]
  let a = [1, 1, 2, 2, 2, 3, 4].map { [Value.integer($0)] }
  let b = [2, 2, 3, 5].map { [Value.integer($0)] }
  return Memory([
    "A": FixtureRelation(fields, a),
    "B": FixtureRelation(fields, b),
  ])
}

struct EngineIntersectExceptTests {
  @Test func `INTERSECT keeps the distinct rows present in both arms`() throws {
    // `2` and `3` occur in both A and B; the distinct INTERSECT keeps each
    // once, in A's (left) order, and drops A-only `1`/`4` and B-only `5`.
    let rows = try multiset().run(parse("""
        SELECT N FROM A INTERSECT SELECT N FROM B
        """))
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `INTERSECT ALL keeps each common row to the lesser multiplicity`() throws {
    // A holds `2` thrice and B twice, so INTERSECT ALL keeps `min(3, 2)` = two;
    // `3` is once in each, so one — every occurrence in A's order.
    let rows = try multiset().run(parse("""
        SELECT N FROM A INTERSECT ALL SELECT N FROM B
        """))
    #expect(rows == [[.integer(2)], [.integer(2)], [.integer(3)]])
  }

  @Test func `EXCEPT keeps the distinct left rows absent from the right`() throws {
    // A's distinct rows not in B are `1` and `4`; `2`/`3` are removed (present
    // in B), first occurrence order preserved.
    let rows = try multiset().run(parse("""
        SELECT N FROM A EXCEPT SELECT N FROM B
        """))
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }

  @Test func `EXCEPT ALL removes one left row per matching right row`() throws {
    // A: 1,1,2,2,2,3,4. B removes one `2` per its two copies (leaving one `2`)
    // and its one `3` (leaving none); `1` (twice) and `4` are untouched — every
    // survivor in A's order.
    let rows = try multiset().run(parse("""
        SELECT N FROM A EXCEPT ALL SELECT N FROM B
        """))
    #expect(rows == [
      [.integer(1)],
      [.integer(1)],
      [.integer(2)],
      [.integer(4)],
    ])
  }

  @Test func `INTERSECT binds tighter than UNION`() throws {
    // `A UNION B INTERSECT C` is `A UNION (B INTERSECT C)` per ISO precedence.
    // Here the reused `tags()` relations give `B INTERSECT C` = `Rhs INTERSECT
    // Extra`: Rhs is {shared, b}, Extra is {a}, so the intersection is empty
    // and the whole result is just Lhs's distinct rows.
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs
          UNION SELECT Tag FROM Rhs
          INTERSECT SELECT Tag FROM Extra
        """))
    #expect(rows == [[.text("a")], [.text("shared")]])
  }

  @Test func `UNION and EXCEPT are same precedence, left-associative`() throws {
    // `A UNION B EXCEPT C` binds as `(A UNION B) EXCEPT C`. Lhs UNION Rhs is
    // {a, shared, b}; EXCEPT Extra ({a}) removes `a`, leaving {shared, b}. A
    // right-associative reading — `A UNION (B EXCEPT C)` — would instead keep
    // `a` (from Lhs), so the result proves the left grouping.
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs
          UNION SELECT Tag FROM Rhs
          EXCEPT SELECT Tag FROM Extra
        """))
    #expect(rows == [[.text("shared")], [.text("b")]])
  }

  @Test func `INTERSECT of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(1, 2)) {
      try people().run(parse("""
          SELECT Id FROM People INTERSECT SELECT Id, Name FROM People
          """))
    }
  }

  @Test func `EXCEPT of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(2, 1)) {
      try people().run(parse("""
          SELECT Id, Name FROM People EXCEPT SELECT Id FROM People
          """))
    }
  }

  @Test func `a view defined as an EXCEPT resolves and queries`() throws {
    let diff = try View(query: select("""
        SELECT N FROM A EXCEPT SELECT N FROM B
        """), columns: ["N"])
    let catalog = Memory(multiset().catalog, views: ["Diff": diff])
    let rows = try catalog.run(parse("SELECT N FROM Diff"))
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }
}

// MARK: - DISTINCT tests

struct EngineDistinctTests {
  @Test func `DISTINCT removes duplicate rows, keeping the first occurrence`() throws {
    // People's Age repeats (30 for Alice and Carol, 25 for Bob and Eve);
    // DISTINCT collapses each duplicate to its first appearance, in row order.
    try people().expect("SELECT DISTINCT Age FROM People",
                        yields: [[30], [25], [40]])
  }

  @Test func `a plain SELECT keeps every duplicate row`() throws {
    try people().expect("SELECT Age FROM People",
                        yields: [[30], [25], [30], [40], [25]])
  }

  @Test func `SELECT ALL is the plain, non-deduplicating select`() throws {
    try people().expect("SELECT ALL Age FROM People",
                        yields: [[30], [25], [30], [40], [25]])
  }

  @Test func `DISTINCT dedups on the whole projected row, not one column`() throws {
    // Grade's (Class, Score) pairs repeat — (A, 80) three times, (B, 90)
    // twice — while a single column would over-collapse. DISTINCT keeps one of
    // each distinct pair, first occurrence in row order.
    try grades().expect("SELECT DISTINCT Class, Score FROM Grade",
                        yields: [["B", 90], ["A", 80], ["A", 70]])
  }

  @Test func `DISTINCT dedups rows a projection maps together`() throws {
    // Bob (25) and Eve (25), Alice (30) and Carol (30) share an Age; projecting
    // Age alone collapses each pair even though their other columns differ.
    try people().expect("SELECT DISTINCT Age FROM People WHERE Age < 40",
                        yields: [[30], [25]])
  }

  @Test func `DISTINCT binds to its own arm within a UNION ALL`() throws {
    // DISTINCT is a per-SELECT quantifier: it dedups the LEFT arm alone (its
    // repeated Ages collapse to 30, 25, 40), then the UNION ALL appends the
    // right arm's rows without deduplicating across the arms.
    try people().expect("""
        SELECT DISTINCT Age FROM People
          UNION ALL SELECT Age FROM People WHERE Id = 1
        """, yields: [[30], [25], [40], [30]])
  }

  @Test func `DISTINCT combines with ORDER BY, ordering the deduplicated rows`() throws {
    // The distinct Ages, then ascending: dedup keeps 30, 25, 40; ORDER BY sorts
    // them 25, 30, 40.
    try people().expect("SELECT DISTINCT Age FROM People ORDER BY Age",
                        yields: [[25], [30], [40]])
  }

  @Test func `DISTINCT dedups before OFFSET/FETCH pages the result`() throws {
    // Three distinct Ages ordered 25, 30, 40; FETCH FIRST 2 pages the
    // deduplicated, ordered rows — proving the cap sits above the dedup.
    try people().expect("""
        SELECT DISTINCT Age FROM People ORDER BY Age FETCH FIRST 2 ROWS ONLY
        """, yields: [[25], [30]])
  }

  @Test func `DISTINCT over an aggregate dedups the grouped rows`() throws {
    // Grouping People by Age yields one row per distinct Age (25, 30, 40), each
    // with its COUNT; projecting only the COUNT leaves 2, 2, 1 — DISTINCT then
    // collapses the two 2s to one.
    try people().expect("""
        SELECT DISTINCT COUNT(*) FROM People GROUP BY Age
        """, yields: [[2], [1]])
  }

  @Test func `a view defined with DISTINCT deduplicates when queried`() throws {
    let ages = try View(query: select("SELECT DISTINCT Age FROM People"),
                        columns: ["Age"])
    let catalog = Memory(try people().catalog, views: ["Ages": ages])
    try catalog.expect("SELECT Age FROM Ages", yields: [[30], [25], [40]])
  }

  @Test func `DISTINCT ordering on a non-projected column faults`() throws {
    // Name is not in the DISTINCT output, so after dedup each Age stands for
    // several Names — the order is ill-defined; the standard rejects it.
    try people().expect("SELECT DISTINCT Age FROM People ORDER BY Name",
                        fails: .distinct("Name"))
  }

  @Test func `DISTINCT ordering on a projected column pages correctly`() throws {
    // Age is a select-list column, so ordering (and paging) on it is well
    // defined: the deduplicated Ages sort 25, 30, 40, and OFFSET 1 drops the
    // first.
    try people().expect("""
        SELECT DISTINCT Age FROM People ORDER BY Age
          OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY
        """, yields: [[30], [40]])
  }

  @Test func `DISTINCT over a join rejects a hidden ORDER BY key`() throws {
    // Child.Name is not projected, so ordering the deduplicated Parent.Name
    // rows on it is ill-defined across the two joined relations.
    try family().expect("""
        SELECT DISTINCT Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id ORDER BY Child.Name
        """, fails: .distinct("Name"))
  }

  @Test func `SS005 is the DISTINCT ORDER BY SQLSTATE`() {
    #expect(SQLError.distinct("Name").sqlstate == "SS005")
  }

  @Test func `grouped DISTINCT rejects ordering on a non-output GROUP BY key`() throws {
    // The output is only COUNT(*); Age is the grouping key but not projected,
    // so ordering (and paging) on it after dedup is ill-defined — the same rule
    // the non-aggregate path enforces, in grouped-slot space.
    try people().expect("""
        SELECT DISTINCT COUNT(*) FROM People GROUP BY Age ORDER BY Age
        """, fails: .distinct("Age"))
  }

  @Test func `grouped DISTINCT orders on a projected aggregate alias`() throws {
    // The counts per Age are 2, 2, 1; DISTINCT collapses the two 2s, leaving
    // {1, 2}. Ordering on the projected alias `c` is well defined — ascending
    // yields 1, 2.
    try people().expect("""
        SELECT DISTINCT COUNT(*) AS c FROM People GROUP BY Age ORDER BY c
        """, yields: [[1], [2]])
  }
}

// MARK: - Arithmetic tests

struct EngineArithmeticTests {
  @Test func `literal arithmetic evaluates over a row`() throws {
    // One row of `People` drives the projection; the value is the same for each,
    // and `Id = 1` selects exactly one.
    try people().expect("SELECT 2 + 3 FROM People WHERE Id = 1", yields: [[5]])
  }

  @Test func `multiplication binds tighter than addition`() throws {
    try people().expect("SELECT 2 + 3 * 4 FROM People WHERE Id = 1",
                        yields: [[14]])
  }

  @Test func `parentheses override precedence`() throws {
    try people().expect("SELECT (2 + 3) * 4 FROM People WHERE Id = 1",
                        yields: [[20]])
  }

  @Test func `subtraction and division are left-associative`() throws {
    // (20 - 5) - 3 = 12, not 20 - (5 - 3) = 18; (100 / 5) / 2 = 10.
    let difference = try run("SELECT 20 - 5 - 3 FROM People WHERE Id = 1")
    #expect(difference == [[.integer(12)]])
    let quotient = try run("SELECT 100 / 5 / 2 FROM People WHERE Id = 1")
    #expect(quotient == [[.integer(10)]])
  }

  @Test func `integer division truncates`() throws {
    try people().expect("SELECT 7 / 2 FROM People WHERE Id = 1", yields: [[3]])
  }

  @Test func `arithmetic over a column computes per row`() throws {
    let rows = try run("SELECT Age + 1 FROM People WHERE Id = 2")
    // Bob's Age is 25; 25 + 1 = 26.
    #expect(rows == [[.integer(26)]])
  }

  @Test func `arithmetic mixes columns and a function call`() throws {
    let rows = try functionRun("SELECT add(Id, 1) * 10 FROM People WHERE Id = 3")
    // Carol: (3 + 1) * 10 = 40.
    #expect(rows == [[.integer(40)]])
  }

  @Test func `a NULL operand propagates to a NULL result`() throws {
    // `Note` is NULL for row 2; `Id + Note` mixes a present integer with a NULL,
    // so the whole expression is NULL rather than a fault.
    try nullable().expect("SELECT Id + Note FROM Maybe WHERE Id = 2",
                          yields: [[nil]])
  }

  @Test func `division by zero faults`() throws {
    #expect(throws: SQLError.divide) {
      try run("SELECT Id / 0 FROM People WHERE Id = 1")
    }
  }

  @Test func `arithmetic overflow faults instead of trapping`() throws {
    // `Int.max + 1` and a multiply past the boundary report overflow as a
    // `SQLError` rather than trapping (and aborting) the process.
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try run("SELECT 9223372036854775807 + 1 FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try run("SELECT 9223372036854775807 * 2 FROM People WHERE Id = 1")
    }
  }

  @Test func `a parenthesised expression opens a predicate`() throws {
    // `(Age + 1)` is the grouped left operand of the comparison, not a predicate
    // group; it matches Dave (40 + 1 = 41). A leading `(` no longer forces a
    // predicate-group parse.
    let matched = try run("SELECT Id FROM People WHERE (Age + 1) = 41")
    #expect(matched == [[.integer(4)]])
    // A grouped expression works before `IS NULL` too; `Id + 1` is never NULL.
    let none = try run("SELECT Id FROM People WHERE (Id + 1) IS NULL")
    #expect(none.isEmpty)
  }

  @Test func `a text operand faults as a type error`() throws {
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try run("SELECT Name + 1 FROM People WHERE Id = 1")
    }
  }

  @Test func `arithmetic in a predicate filters rows`() throws {
    // `Age + 1 = 26` holds for everyone aged 25 (Bob and Eve); the arithmetic
    // is evaluated per row on the WHERE side too.
    try people().expect("SELECT Name FROM People WHERE Age + 1 = 26",
                        yields: [["Bob"], ["Eve"]])
  }
}

// MARK: - Scalar (FROM-less) SELECT tests

struct EngineScalarSelectTests {
  @Test func `a FROM-less literal yields exactly one row`() throws {
    // No relation, so the projection runs against a single empty row; the
    // catalog is never consulted for a table.
    try people().expect("SELECT 42", yields: [[42]])
  }

  @Test func `a FROM-less arithmetic computes a scalar`() throws {
    try people().expect("SELECT 1 + 1", yields: [[2]])
  }

  @Test func `FROM-less arithmetic honours precedence`() throws {
    try people().expect("SELECT 2 + 3 * 4", yields: [[14]])
  }

  @Test func `a FROM-less multi-column projection yields one row of each value`() throws {
    try people().expect("SELECT 1, 2, 3", yields: [[1, 2, 3]])
  }

  @Test func `a FROM-less projection mixes text and integer expressions`() throws {
    try people().expect("SELECT 'x', 10 / 2", yields: [["x", 5]])
  }

  @Test func `a FROM-less scalar call evaluates against the single row`() throws {
    let rows = try functionRun("SELECT add(40, 2)")
    #expect(rows == [[.integer(42)]])
  }

  @Test func `a boolean literal lowers to its truth value`() throws {
    try people().expect("SELECT TRUE, FALSE", yields: [[true, false]])
  }

  @Test func `a hex blob literal lowers to its bytes`() throws {
    // The `x'53514c'` literal lexes, parses, and lowers to the three-byte
    // blob `SQL`, projected as a `Value.blob`.
    try people().expect("SELECT x'53514c'",
                        yields: [[[0x53, 0x51, 0x4c] as Array<UInt8>]])
  }

  @Test func `a boolean operand faults as a non-numeric type error`() throws {
    // Neither boolean nor blob is numeric, so arithmetic over either faults
    // exactly as text does — the type-checker rejects any non-numeric operand.
    try people().expect("SELECT TRUE + 1",
                        fails: .operand("operands must be numeric"))
  }

  @Test func `a blob operand faults as a non-numeric type error`() throws {
    try people().expect("SELECT x'00' + 1",
                        fails: .operand("operands must be numeric"))
  }

  @Test func `a NULL-yielding FROM-less expression projects NULL`() throws {
    // The bare literal NULL is not in the grammar, but a NULL arises from a
    // function returning it; `nothing` yields NULL for the single row.
    let routines: Routines =
        ["nothing": Routine(parameters: []) { _ in .null }]
    let rows = try people().run(parse("SELECT nothing()"), routines)
    #expect(rows == [[.null]])
  }

  @Test func `a FROM-less SELECT * is rejected — no relation to expand`() throws {
    #expect(throws: SQLError.unsupported("SELECT * requires a FROM clause")) {
      try run("SELECT *")
    }
  }

  @Test func `a FROM-less bare column is rejected — no column to bind`() throws {
    try people().expect("SELECT Name", fails: .column("Name"))
  }

  @Test func `a directly-built FROM-less select with clauses is rejected`() throws {
    // The parser never builds a FROM-less select carrying a WHERE, GROUP BY,
    // HAVING, ORDER BY, OFFSET/FETCH, or JOIN, but a direct `Select(from: nil,
    // …)` can. The engine rejects it rather than silently drop the clause — a
    // false predicate or HAVING would otherwise still return the scalar row.
    let fault =
        SQLError.unsupported(
            "a WHERE, GROUP BY, HAVING, ORDER BY, OFFSET/FETCH, or JOIN " +
            "requires a FROM clause")
    let filtered = try EngineScalarSelectTests.select(
        "SELECT 1 FROM People WHERE Id = 99")
    #expect(throws: fault) {
      try people().run(.select(Select(projection: filtered.projection,
                                    from: nil,
                                    predicate: filtered.predicate)))
    }
    let grouped = try EngineScalarSelectTests.select(
        "SELECT Id FROM People GROUP BY Id")
    #expect(throws: fault) {
      try people().run(.select(Select(projection: grouped.projection, from: nil,
                                    grouping: grouped.grouping)))
    }
    let filteredGroup = try EngineScalarSelectTests.select(
        "SELECT Id FROM People GROUP BY Id HAVING COUNT(*) > 0")
    #expect(throws: fault) {
      try people().run(.select(Select(projection: filteredGroup.projection,
                                    from: nil,
                                    having: filteredGroup.having)))
    }
    let ordered =
        try EngineScalarSelectTests.select("SELECT Id FROM People ORDER BY Id")
    #expect(throws: fault) {
      try people().run(.select(Select(projection: ordered.projection, from: nil,
                                    order: ordered.order)))
    }
    let limited = try EngineScalarSelectTests.select(
        "SELECT Id FROM People FETCH FIRST 1 ROW ONLY")
    #expect(throws: fault) {
      try people().run(.select(Select(projection: limited.projection, from: nil,
                                    limit: limited.limit)))
    }
    let joined = try EngineScalarSelectTests.select(
        "SELECT Id FROM People JOIN Pets ON Pets.Owner = People.Id")
    #expect(throws: fault) {
      try people().run(.select(Select(projection: joined.projection, from: nil,
                                    joins: joined.joins)))
    }
  }

  /// The `Select` of a parsed single-`SELECT` query — for building the FROM-less
  /// shapes the parser will not, by re-homing a clause onto a `from: nil` select.
  private static func select(_ text: String) throws -> Select {
    guard case let .select(select) = try parse(text) else {
      throw SQLError.incomplete(expected: "a SELECT")
    }
    return select
  }

  @Test func `a FROM-less arm of a UNION combines with a FROM arm`() throws {
    // Both arms project one integer column; the FROM-less arm contributes its
    // single computed row, deduplicating against the People ages.
    let rows = try people().run(parse("""
        SELECT 100 UNION ALL SELECT Age FROM People WHERE Id = 1
        """))
    #expect(rows == [[.integer(100)], [.integer(30)]])
  }

  @Test func `an existing SELECT … FROM … query is unaffected`() throws {
    // The FROM-optional grammar leaves a normal query parsing and running
    // exactly as before.
    try people().expect("SELECT Name FROM People WHERE Id = 1",
                        yields: [["Alice"]])
  }
}

// MARK: - WITH (non-recursive) tests

/// Parses `text` to a statement and runs it against `catalog`.
private func statement<C: Catalog & ~Escapable>(_ text: String,
                                                _ catalog: borrowing C)
    throws -> Array<Array<Value>> {
  try catalog.run(Statement(parsing: text))
}

struct EngineWithTests {
  @Test func `a non-recursive CTE materialises as an inline view`() throws {
    // The CTE `adults` is materialised once and the trailing query reads it
    // like a table — the inline-view shape of a non-recursive WITH.
    let rows = try statement("""
        WITH adults (Key, Label) AS (SELECT Id, Name FROM Parent WHERE Id >= 2)
          SELECT Label FROM adults
        """, family())
    #expect(rows == [[.text("Bee")], [.text("Cid")]])
  }

  @Test func `a JOIN matches an integer key to an equal double key`() throws {
    // The optimized join paths (hash bucket, seek/final check, CTE nested loop)
    // must use the same mixed-numeric equality a predicate does: `1` and `1.0`
    // are equal, so the row joins rather than being dropped by a raw-`Value`
    // key comparison.
    let rows = try statement("""
        WITH a (x) AS (SELECT 1), b (x) AS (SELECT 1.0)
          SELECT * FROM a JOIN b ON a.x = b.x
        """, family())
    #expect(rows == [[.integer(1), .double(1.0)]])
  }

  @Test func `a JOIN matches a large integer to its rounded double past 2^53`() throws {
    // Above 2^53 an integer is not exactly representable as `Double`; the
    // predicate treats `9007199254740993` and `9007199254740993.0` as equal by
    // promoting the integer to `Double` (both round to 2^53), so the optimized
    // join must too — a fold-double-to-Int key would drop the row.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740993),
             b (x) AS (SELECT 9007199254740993.0)
          SELECT a.x FROM a JOIN b ON a.x = b.x
        """, family())
    #expect(rows == [[.integer(9007199254740993)]])
  }

  @Test func `a JOIN keeps distinct large integer keys unequal (exact integers)`() throws {
    // Two integers that round to the SAME Double past 2^53 are still unequal as
    // integers, so an integer/integer join must NOT pair them — the hash bucket
    // may collide, but the residual `matches` check keeps integer equality
    // exact.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740992),
             b (x) AS (SELECT 9007199254740993)
          SELECT a.x FROM a JOIN b ON a.x = b.x
        """, family())
    #expect(rows.isEmpty)
  }

  @Test func `UNION deduplicates numerically-equal rows across kinds`() throws {
    // `1` and `1.0` are the same numeric value, so UNION keeps one — the first
    // arm's — not both; the dedup uses the numeric equality, not raw `Value`.
    #expect(try statement("SELECT 1 UNION SELECT 1.0", family())
            == [[.integer(1)]])
    // UNION ALL keeps every row.
    #expect(try statement("SELECT 1 UNION ALL SELECT 1.0", family())
            == [[.integer(1)], [.double(1.0)]])
  }

  @Test func `UNION dedup keeps distinct integers a rounded double sits between`() throws {
    // Dedup is EXACT: `2^53.0` equals the integer `2^53` (folds to it), but NOT
    // the integer `2^53 + 1`. So an earlier approximate row must not absorb
    // both distinct integers — the `2^53 + 1` row survives regardless of order.
    let rows = try statement("""
        SELECT 9007199254740992.0
          UNION SELECT 9007199254740992
          UNION SELECT 9007199254740993
        """, family())
    #expect(rows == [[.double(9007199254740992.0)],
                     [.integer(9007199254740993)]])
  }

  @Test func `ORDER BY orders mixed integer/double keys by magnitude`() throws {
    let rows = try statement("""
        WITH a (x) AS (SELECT 3 UNION ALL SELECT 1.5) SELECT x FROM a ORDER BY x
        """, family())
    #expect(rows == [[.double(1.5)], [.integer(3)]])
  }

  @Test func `ORDER BY over mixed keys past 2^53 stays a total order`() throws {
    // A double ties two distinct integers under promotion; the comparator must
    // stay a strict weak ordering (transitive), keeping the larger integer last
    // rather than misordering it ahead of the smaller via the stable tie-break.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740993
                       UNION ALL SELECT 9007199254740993.0
                       UNION ALL SELECT 9007199254740992)
          SELECT x FROM a ORDER BY x
        """, family())
    #expect(rows.count == 3)
    #expect(rows.last == [.integer(9007199254740993)])
  }

  @Test func `a CTE infers its columns and filters on them`() throws {
    let rows = try statement("""
        WITH grown AS (SELECT Id, Name FROM Parent)
          SELECT Name FROM grown WHERE Id = 3
        """, family())
    #expect(rows == [[.text("Cid")]])
  }

  @Test func `a later CTE reads an earlier one (chained CTEs)`() throws {
    // `b` resolves `a` — the resolver consults the CTEs materialised so far, so
    // a later member sees an earlier one.
    let rows = try statement("""
        WITH a (Id, Name) AS (SELECT Id, Name FROM Parent WHERE Id >= 2),
             b (Who) AS (SELECT Name FROM a WHERE Id = 3)
          SELECT Who FROM b
        """, family())
    #expect(rows == [[.text("Cid")]])
  }

  @Test func `a CTE shadows a base relation of the same name`() throws {
    // `Parent` is a base relation; the CTE of the same name shadows it, so the
    // trailing query reads the CTE's rows, not the base table's.
    let rows = try statement("""
        WITH Parent (Id, Name) AS (SELECT Id, Name FROM Parent WHERE Id = 1)
          SELECT Name FROM Parent
        """, family())
    #expect(rows == [[.text("Ada")]])
  }

  @Test func `the trailing query joins a CTE against a base relation`() throws {
    // The CTE `kids` joins to the base `Parent` on the foreign key — proving a
    // materialised relation and a base one combine in one query.
    let rows = try statement("""
        WITH kids (Pid, Kid) AS (SELECT Pid, Name FROM Child)
          SELECT Parent.Name, kids.Kid FROM Parent
            JOIN kids ON kids.Pid = Parent.Id
        """, family())
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test func `a CTE's Id virtual column resolves`() throws {
    let rows = try statement("""
        WITH a (Tag) AS (SELECT Name FROM Parent)
          SELECT Id, Tag FROM a WHERE Id = 2
        """, family())
    #expect(rows == [[.integer(2), .text("Bee")]])
  }

  @Test func `a CTE column list of the wrong arity is rejected at parse`() throws {
    #expect(throws: SQLError.columns(expected: 2, got: 1)) {
      try statement("""
          WITH a (x) AS (SELECT Id, Name FROM Parent) SELECT x FROM a
          """, family())
    }
  }

  @Test func `an unknown column of a CTE is reported`() throws {
    #expect(throws: SQLError.column("Missing")) {
      try statement("""
          WITH a (Id) AS (SELECT Id FROM Parent) SELECT Missing FROM a
          """, family())
    }
  }

  @Test func `a CTE whose body is a UNION materialises both arms`() throws {
    let rows = try statement("""
        WITH both (Tag) AS (SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs)
          SELECT Tag FROM both
        """, tags())
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a CTE column list wider than its SELECT * body is rejected, not trapped`() throws {
    // `Parent` is a two-column relation, but the column list declares three
    // names; the `SELECT *` body's width is known only after it compiles, so
    // the declared arity is checked against the body's compiled width, faulting
    // with `SQLError.columns` rather than trapping when a later read indexes a
    // cell the row does not have.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try statement("""
          WITH a (x, y, z) AS (SELECT * FROM Parent) SELECT x FROM a
          """, family())
    }
  }

  @Test func `a zero-row SELECT * CTE body of the wrong arity is rejected`() throws {
    // `Parent` is a two-column relation, but the column list declares three
    // names. The body `WHERE Id < 0` yields no rows, so a per-row check would
    // pass it through vacuously and register `a` with a three-column schema
    // over a two-column body; the trailing `SELECT z` then reads an ordinal the
    // body never projects. The body's compiled width is checked against the
    // declared arity BEFORE materialising, regardless of the row count, so the
    // mismatch faults with `SQLError.columns` rather than silently returning
    // data.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try statement("""
          WITH a (x, y, z) AS (SELECT * FROM Parent WHERE Id < 0)
            SELECT z FROM a
            UNION SELECT 99 AS z FROM Parent WHERE Id = 1
          """, family())
    }
  }

  @Test func `a WITH list rejects a case-insensitively duplicate query name`() throws {
    // Two CTEs share a name (`a` and `A`), so the second would silently
    // overwrite the first in the materialised scope — a typo in a multi-CTE
    // query changing the result. The duplicate is rejected before materialising.
    #expect(throws: SQLError.redefinition("A")) {
      try statement("""
          WITH a (x) AS (SELECT Id FROM Parent),
               A (x) AS (SELECT Id FROM Parent)
            SELECT x FROM a
          """, family())
    }
  }

  @Test func `a WHERE pushed onto a joined-in CTE filters its rows before the join`() throws {
    // `kids` is joined to `Parent` on the foreign key, and a single-relation
    // `WHERE kids.Kid = 'Amy'` is pushed onto the CTE inner; only the matching
    // CTE row may join, so a CTE row with any other `Kid` is excluded rather than
    // paired.
    let rows = try statement("""
        WITH kids (Pid, Kid) AS (SELECT Pid, Name FROM Child)
          SELECT Parent.Name, kids.Kid FROM Parent
            JOIN kids ON kids.Pid = Parent.Id
            WHERE kids.Kid = 'Amy'
        """, family())
    #expect(rows == [[.text("Ada"), .text("Amy")]])
  }

  @Test func `a statement CTE does not leak into a registered view's body`() throws {
    // `Adults` is a view over the base `Parent`; a statement-local
    // `WITH Parent (Id) AS …` must NOT reach into the view's stored body, so
    // `SELECT Id FROM Adults` still reads the base `Parent`'s ids — a view means
    // what it was registered to mean regardless of the caller's WITH. Were the
    // caller's CTEs threaded into the view body, `Adults`'s `FROM Parent` would
    // bind to the CTE and the query would return `99`.
    let adults =
        try View(query: select("SELECT Id FROM Parent"), columns: ["Id"])
    let catalog = Memory(try family().catalog, views: ["Adults": adults])
    let rows = try statement("""
        WITH Parent (Id) AS (SELECT 99 AS Id FROM Parent WHERE Id = 1)
          SELECT Id FROM Adults
        """, catalog)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `a top-level FROM a CTE still resolves to the CTE, not the base relation`() throws {
    // The complement of `viewScoping`: at the STATEMENT level a CTE that names a
    // base relation still shadows it, so a trailing `FROM Parent` reads the CTE
    // — the scoping fix narrows only a view's body, never the statement query.
    let adults =
        try View(query: select("SELECT Id FROM Parent"), columns: ["Id"])
    let catalog = Memory(try family().catalog, views: ["Adults": adults])
    let rows = try statement("""
        WITH Parent (Id) AS (SELECT 99 AS Id FROM Parent WHERE Id = 1)
          SELECT Id FROM Parent
        """, catalog)
    #expect(rows == [[.integer(99)]])
  }

  @Test func `a WITH RECURSIVE arm that never names the CTE runs once, not to a cap`() throws {
    // Every member of a `WITH RECURSIVE` list is syntactically marked recursive,
    // but neither arm of this UNION ALL reads `a`, so it is not recursive in
    // truth: it runs once, yielding exactly its two rows, rather than re-running
    // an arm that adds nothing new until the recursion cap fires.
    let rows = try statement("""
        WITH RECURSIVE a (n) AS (
          SELECT 1 AS n FROM Extra UNION ALL SELECT 2 AS n FROM Extra
        )
        SELECT n FROM a
        """, tags())
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }

  @Test func `a WITH RECURSIVE whose anchor reads a same-named base is not recursive`() throws {
    // The CTE `Parent` shares a base relation's name; only the ANCHOR reads that
    // base (the CTE is not in scope there), while the recursive arm reads
    // `Extra` and never names the CTE. Self-reference is detected in the arm
    // alone, so this is NOT routed through the fixpoint: the two arms materialise
    // once (UNION ALL) instead of the arm re-running to the recursion cap.
    let catalog = Memory([
      "Parent": FixtureRelation([Field(name: "Id", type: .integer)],
                         [[.integer(1)], [.integer(2)]] as Array<Array<Value>>),
      "Extra": FixtureRelation([Field(name: "Id", type: .integer)],
                        [[.integer(3)]] as Array<Array<Value>>),
    ])
    let rows = try statement("""
        WITH RECURSIVE Parent (Id) AS (
          SELECT Id FROM Parent UNION ALL SELECT Id FROM Extra
        )
        SELECT Id FROM Parent
        """, catalog)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }
}

// MARK: - WITH RECURSIVE tests

/// A one-row seed catalog: a `Seed` relation of a single row, the FROM-less
/// `SELECT 1` the dialect lacks expressed as `SELECT 1 FROM Seed`. It also
/// carries an `Edge(Src, Dst)` relation for a transitive-closure test.
private func seed() -> Memory {
  let one = [Field(name: "One", type: .integer)]
  let seedRows = [[.integer(1)]] as Array<Array<Value>>

  let edge = [
    Field(name: "Src", type: .integer),
    Field(name: "Dst", type: .integer),
  ]
  // 1 -> 2 -> 3 -> 4, a simple chain whose closure is every reachable pair.
  let edges = [
    [.integer(1), .integer(2)],
    [.integer(2), .integer(3)],
    [.integer(3), .integer(4)],
  ] as Array<Array<Value>>

  return Memory([
    "Seed": FixtureRelation(one, seedRows),
    "Edge": FixtureRelation(edge, edges),
  ])
}

/// Routines with an `inc` scalar — `inc(n) = n + 1` — standing in for the `+`
/// the dialect lacks, so a recursive counter can advance.
private func counting() -> Routines {
  try! Routines().registering("inc", parameters: [.integer]) {
    arguments throws(SQLError) in
    guard case let .integer(n) = arguments.first else {
      throw .argument("inc expects one integer argument")
    }
    return .integer(n + 1)
  }
}

struct EngineRecursiveTests {
  @Test func `a recursive counter enumerates 1..5`() throws {
    // The canonical recursive CTE: seed with 1, then inc(n) while n < 5. The
    // anchor reads the one-row Seed; the recursive arm names the CTE `c`.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c WHERE n < 5
        )
        SELECT n FROM c
        """)
    let rows = try seed().run(query, counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test func `a recursive counter runs through Catalog.run(_:statement:)`() throws {
    let rows = try seed().run(Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c WHERE n < 3
        )
        SELECT n FROM c
        """), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `a non-UNION recursive CTE validates its compiled width`() throws {
    // A `WITH RECURSIVE` member whose body is not a UNION runs once, but must
    // still match its declared arity. Here the body resolves `Parent` against
    // the base relation of the same name (two columns) under a three-column
    // list; the non-UNION path validates the compiled width and faults rather
    // than binding narrow rows that trap when the trailing `SELECT z` reads the
    // absent ordinal.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      _ = try family().run(Statement(parsing: """
          WITH RECURSIVE Parent (x, y, z) AS (SELECT * FROM Parent)
            SELECT z FROM Parent
          """))
    }
  }

  @Test func `a recursive CTE with more than one recursive arm is rejected`() throws {
    // The body has TWO self-referential arms; the engine models one anchor plus
    // one recursive arm, so the earlier recursive arm would land in the anchor
    // (compiled with the CTE not in scope). Reject it with a clear `unsupported`
    // diagnostic rather than failing obscurely as an unresolved relation.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL SELECT inc(n) AS n FROM c WHERE n < 3
          UNION ALL SELECT inc(n) AS n FROM c WHERE n < 5
        )
        SELECT n FROM c
        """)
    #expect(throws: SQLError.unsupported(
        "recursive WITH references the CTE outside its final UNION arm")) {
      _ = try seed().run(query, counting())
    }
  }

  @Test func `a recursive reference before the final UNION arm is rejected`() throws {
    // The self-reference (`FROM Parent`) is a MIDDLE arm and the final arm is
    // non-recursive, so the recursive-arm check (which inspects the final arm)
    // sees no recursion and the CTE would take the run-once path — compiling the
    // middle `FROM Parent` against a same-named base (silently wrong) or, with
    // none, an unresolved relation. With no same-named base/view it is rejected
    // as an unsupported recursive shape.
    let query = try Statement(parsing: """
        WITH RECURSIVE Parent (Id) AS (
          SELECT 1 AS Id FROM Seed
          UNION ALL SELECT inc(Id) AS Id FROM Parent WHERE Id < 3
          UNION ALL SELECT 99 AS Id FROM Seed
        )
        SELECT Id FROM Parent
        """)
    #expect(throws: SQLError.unsupported(
        "recursive WITH references the CTE outside its final UNION arm")) {
      _ = try seed().run(query, counting())
    }
  }

  @Test func `a recursive CTE whose anchor reads a same-named base still evaluates`() throws {
    // `Parent` intentionally shadows a base relation of the same name: the anchor
    // `SELECT Id FROM Parent` reads the BASE (the CTE is not in scope for the
    // base case), seeding the recursion, while the right arm's `FROM Parent` is
    // the true self-reference. The multiple-recursive-arm guard must NOT reject
    // this — the anchor's reference resolves to an existing base relation, so it
    // is a valid seed, not a misplaced recursive arm.
    let catalog = Memory([
      "Parent": FixtureRelation([Field(name: "Id", type: .integer)],
                         [[.integer(1)]] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(Statement(parsing: """
        WITH RECURSIVE Parent (Id) AS (
          SELECT Id FROM Parent
          UNION ALL SELECT inc(Id) AS Id FROM Parent WHERE Id < 5
        )
        SELECT Id FROM Parent
        """), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test func `a recursive CTE whose anchor reads a same-named view still evaluates`() throws {
    // Like `anchorShadowsBase`, but the same-named seed is a registered VIEW,
    // not a base table: the anchor `SELECT id FROM v` resolves to the view (the
    // CTE is not in scope for the base case), and the right arm is the true
    // self-reference. The guard must accept a view seed as well as a table.
    let view = try View(query: select("SELECT Id FROM Parent"), columns: ["id"])
    let catalog = Memory([
      "Parent": FixtureRelation([Field(name: "Id", type: .integer)],
                         [[.integer(1)]] as Array<Array<Value>>),
    ], views: ["v": view])
    let rows = try catalog.run(Statement(parsing: """
        WITH RECURSIVE v (id) AS (
          SELECT id FROM v
          UNION ALL SELECT inc(id) AS id FROM v WHERE id < 5
        )
        SELECT id FROM v
        """), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test func `UNION dedups rows a UNION ALL recursion would repeat`() throws {
    // The recursive arm re-derives n from 1 without a guard's monotonic bound,
    // but a bare UNION dedups whole rows, so the fixpoint is the distinct set
    // 1..4 reached and nothing new thereafter — it terminates where UNION ALL
    // would loop. inc advances; the WHERE caps the run, and UNION drops dupes.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION
          SELECT inc(n) AS n FROM c WHERE n < 4
        )
        SELECT n FROM c
        """)
    let rows = try seed().run(query, counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)]])
  }

  @Test func `a bare UNION dedups duplicate anchor seed rows`() throws {
    // The anchor is itself a UNION ALL that yields `1` twice, so the seed
    // carries a duplicate; the recursive arm (`n < 1`) adds nothing new. A bare
    // outer UNION dedups the seed exactly as it dedups an iteration step, so the
    // duplicate anchor rows collapse to the single distinct row `1` rather than
    // leaking both into the result.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT 1 AS n FROM Seed
          UNION
          SELECT inc(n) AS n FROM c WHERE n < 1
        )
        SELECT n FROM c
        """)
    let rows = try seed().run(query, counting())
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a transitive-closure self-join reaches every descendant`() throws {
    // The closure of the edge chain 1->2->3->4: seed with the direct edges,
    // then extend each known reach (Src, Dst) by an edge out of Dst. The
    // recursive arm joins the CTE to the base Edge relation.
    let query = try Statement(parsing: """
        WITH RECURSIVE reach (Src, Dst) AS (
          SELECT Src, Dst FROM Edge
          UNION ALL
          SELECT reach.Src, Edge.Dst FROM reach
            JOIN Edge ON Edge.Src = reach.Dst
        )
        SELECT Src, Dst FROM reach ORDER BY Src ASC
        """)
    let rows = try seed().run(query)
    // Direct: (1,2)(2,3)(3,4); extended: (1,3)(2,4); further: (1,4).
    let pairs = rows.map { row -> (Int, Int) in
      guard case let .integer(a) = row[0], case let .integer(b) = row[1]
      else { return (0, 0) }
      return (a, b)
    }
    #expect(Set(pairs.map { "\($0.0)-\($0.1)" }) == [
      "1-2", "2-3", "3-4", "1-3", "2-4", "1-4",
    ])
  }

  @Test func `a recursive arm of the wrong width faults, not traps, before rebinding`() throws {
    // `Edge` is a two-column relation, but the column list declares three
    // names; the anchor's `SELECT *` compiles to a two-wide plan the fixpoint
    // would bind under the three-column schema, so the recursive arm's read of
    // the absent third ordinal would trap in `Materialised.record`. The
    // anchor's compiled width is checked against the declared arity BEFORE it
    // seeds the working set, so the fault surfaces as `SQLError.columns` rather
    // than a trap.
    let query = try Statement(parsing: """
        WITH RECURSIVE t (a, b, c) AS (
          SELECT * FROM Edge
          UNION ALL
          SELECT a, b, c FROM t WHERE a < 0
        )
        SELECT a FROM t
        """)
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try seed().run(query)
    }
  }

  @Test func `a zero-row SELECT * anchor of the wrong width faults, not passes`() throws {
    // `Edge` is a two-column relation, but the column list declares three
    // names. The anchor `WHERE Src < 0` yields no rows, so a per-row check
    // would seed nothing to validate and bind the CTE under a three-column
    // schema; the recursive arm's read of the absent third ordinal would then
    // trap. The anchor's compiled width is checked against the declared arity
    // BEFORE it seeds the working set, regardless of how many rows it produces,
    // so the fault surfaces as `SQLError.columns`.
    let query = try Statement(parsing: """
        WITH RECURSIVE t (a, b, c) AS (
          SELECT * FROM Edge WHERE Src < 0
          UNION ALL
          SELECT a, b, c FROM t WHERE a < 0
        )
        SELECT a FROM t
        """)
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try seed().run(query)
    }
  }

  @Test func `a runaway recursion is capped with SQLError.recursion`() throws {
    // inc(n) with no terminating WHERE produces an unbounded sequence of new
    // rows; UNION ALL keeps every one, so the fixpoint is never reached and the
    // cap fires.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c
        )
        SELECT n FROM c
        """)
    #expect(throws: SQLError.recursion("c")) {
      try seed().run(query, counting())
    }
  }
}
