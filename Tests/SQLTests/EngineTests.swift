// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - In-memory adapter

/// A column's name and value kind.
private struct Field: Sendable {
  let name: String
  let kind: ValueKind
}

/// The coded-index encoding the in-memory harness models — a raw cell is
/// `(rowid << bits) | tag`, with the tag in the low `bits` (a real coded index's
/// tag is likewise a small low field, e.g. `HasCustomAttribute.bits == 5`). Two
/// bits keep the fixtures small while still being wide enough that a decoded
/// rowid past `Int.max >> bits` shifts its high bits out of the word and aliases
/// a real low cell — the truncation `WinMDRelation.bound`'s upper-bound guard
/// rejects and this harness mirrors.
private enum Coded {
  static let bits = 2
}

/// An in-memory relation: a fixed schema plus rows of typed values.
///
/// The `sorted` flag marks a single integral column whose rows are stored in
/// ascending order; `bound` reports a boundary for that column and `nil` for any
/// other, so the engine exercises both the seek path and the scan path. Every
/// relation also exposes a virtual `rowid` column — its 1-based row index — at
/// the ordinal just past its real columns, computed by the `Row` rather than
/// stored. This type knows nothing of WinMD — it is the proof the engine is
/// generic.
private struct Relation: Sendable {
  let fields: Array<Field>
  let records: Array<Array<Value>>
  /// The ordinal of the sorted column, or `nil` if the relation is unsorted.
  let sorted: Int?
  /// A seekable-but-unordered coded column, modelling a decoded coded-index key
  /// (e.g. `CustomAttribute.Parent_TypeDef`): its stored cell is the raw coded
  /// value `(rowid << bits) | tag`, physically sorted, and `bound` brackets it —
  /// but the `Row` decodes it (a null reference `rowid == 0` or any non-`0` tag
  /// → `NULL`, else its `rowid`), so the decoded column is not monotonic in row
  /// order. `ordered` reports `false` for it, so the engine seeks only an
  /// equality and scans a range. The tag occupies `Coded.bits` low bits — wide
  /// enough (like a real coded index) that a decoded rowid past
  /// `Int.max >> Coded.bits` shifts its high bits entirely out of the word and
  /// aliases a real low cell, the truncation the seek's upper-bound guard
  /// rejects.
  let coded: Int?

  /// A shared tally the cursor bumps on each row read, or `nil` when a fixture
  /// does not instrument its reads — the proof selection pushdown and hash join
  /// materialise fewer rows.
  let counter: Counter?

  init(_ fields: Array<Field>, _ records: Array<Array<Value>>,
       sorted: Int? = nil, coded: Int? = nil, counter: Counter? = nil) {
    self.fields = fields
    self.records = records
    self.sorted = sorted
    self.coded = coded
    self.counter = counter
  }
}

/// A mutable tally of the rows a cursor reads, shared by reference so a test can
/// inspect it after a run. Tests run serially, so the unchecked `Sendable` is
/// sound.
private final class Counter: @unchecked Sendable {
  var reads = 0
}

/// A `Catalog` over a dictionary of named relations.
///
/// The adapter is an escapable value, so it conforms to the `~Escapable`
/// protocols by omitting `@_lifetime` on its own methods — a borrowed-storage
/// source would instead annotate them. It is the proof the same protocols admit
/// both a Span-backed source and an owned one.
private struct Memory: Catalog {
  let relations: Dictionary<String, Relation>
  let views: Dictionary<String, View>

  init(_ relations: Dictionary<String, Relation>,
       views: Dictionary<String, View> = [:]) {
    self.relations = relations
    self.views = views
  }

  func table(named name: String) -> MemoryTable? {
    guard let relation = relations[name] else { return nil }
    return MemoryTable(relation)
  }

  func view(named name: String) -> View? {
    views[name]
  }
}

/// A `Table` over one in-memory relation, with a virtual `rowid` column.
private struct MemoryTable: Table {
  let relation: Relation

  init(_ relation: Relation) {
    self.relation = relation
  }

  /// The real columns — `rowid` is virtual and excluded from the width, so a
  /// `SELECT *` never yields it.
  var width: Int { relation.fields.count }

  /// The real column names, in ordinal order.
  var names: Array<String> { relation.fields.map(\.name) }

  /// The lone virtual `rowid` column at ordinal `width`.
  var virtuals: Array<String> { ["rowid"] }

  /// One past the highest ordinal — the real width plus the lone virtual
  /// `rowid` column at ordinal `width`.
  var extent: Int { width + 1 }

  func ordinal(of name: String) -> Int? {
    // `rowid` is the virtual column at the ordinal just past the real ones.
    if name == "rowid" { return width }
    return relation.fields.firstIndex { $0.name == name }
  }

  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? {
    // The sorted column seeks against `value` directly; the coded column seeks
    // against the encoded raw cell `(value << Coded.bits) | 0` — the tag-0
    // (TypeDef) encoding of the target `rowid` — exactly as `WinMDRelation`
    // brackets a decoded coded-index key's equal run in the sorted raw column. A
    // decoded row is 1-based, so the coded column reports no boundary for a
    // non-positive `value`: it is a null reference (`rowid == 0`) that no cell
    // equals, so the engine scans and filters rather than seeking the raw run
    // encoding row zero — mirroring `WinMDRelation.bound`'s `value >= 1` guard.
    // It likewise reports no boundary for a `value` past `Int.max >> Coded.bits`,
    // whose shift would truncate its high bits out of the word and alias a real
    // low cell — mirroring the adapter's upper-bound guard, so the engine scans
    // and filters (the huge value matches no decoded cell) instead of seeking the
    // aliased run. Any other column falls back to a scan.
    let target: Int
    switch column {
    case relation.sorted:
      target = value
    case relation.coded where value >= 1 && value <= Int.max >> Coded.bits:
      target = (value << Coded.bits) | 0
    default:
      return nil
    }

    // Partition the ascending column: the first row whose cell is `>= target`
    // (non-strict) or `> target` (strict).
    var lower = 0
    var upper = relation.records.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      guard case let .integer(cell) = relation.records[middle][column] else {
        return nil
      }
      let before = strict ? cell <= target : cell < target
      if before {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  func ordered(_ column: Int) -> Bool {
    // The coded column is seekable but not ordered — its stored raw cells are
    // sorted, but the value the `Row` decodes is not monotonic in row order, so
    // a range must scan rather than consume a boundary.
    relation.coded != column
  }

  func cursor() -> MemoryCursor {
    MemoryCursor(relation)
  }
}

/// An index-addressed cursor over a relation's rows.
private struct MemoryCursor: Cursor {
  let relation: Relation

  init(_ relation: Relation) {
    self.relation = relation
  }

  var count: Int { relation.records.count }

  func row(_ index: Int) -> MemoryRow? {
    guard index < relation.records.count else { return nil }
    relation.counter?.reads += 1
    return MemoryRow(relation, index)
  }
}

/// A positional view over one row's cells, real and virtual.
///
/// A real ordinal (`< width`) reads the stored cell; the virtual `rowid` ordinal
/// (`== width`) computes the 1-based row index. The view is an escapable value —
/// the source carries no borrowed storage — so it omits `@_lifetime`.
private struct MemoryRow: Row {
  let relation: Relation
  let index: Int

  init(_ relation: Relation, _ index: Int) {
    self.relation = relation
    self.index = index
  }

  subscript(_ column: Int) -> Value {
    borrowing get {
      if column == relation.fields.count { return .integer(index + 1) }
      // The coded column decodes its raw cell `(rowid << Coded.bits) | tag` the
      // way a coded-index key does: a tag-`0` (TypeDef) cell whose row is
      // non-null yields the target `rowid`; any other tag (a cell pointing at a
      // different table) or a null reference (`rowid == 0`) yields `NULL` — the
      // same `row == 0` → `NULL` rule `WinMDRow.key` decodes a coded index by.
      if column == relation.coded,
          case let .integer(raw) = relation.records[index][column] {
        let mask = (1 << Coded.bits) - 1
        return raw & mask == 0 && raw >> Coded.bits != 0
            ? .integer(raw >> Coded.bits) : .null
      }
      return relation.records[index][column]
    }
  }
}

// MARK: - Fixtures

/// The single-relation catalog: a `People` relation sorted on its `Id` column.
private func people() -> Memory {
  let fields = [
    Field(name: "Id", kind: .integer),
    Field(name: "Name", kind: .text),
    Field(name: "Age", kind: .integer),
  ]
  let records = [
    [.integer(1), .text("Alice"), .integer(30)],
    [.integer(2), .text("Bob"), .integer(25)],
    [.integer(3), .text("Carol"), .integer(30)],
    [.integer(4), .text("Dave"), .integer(40)],
    [.integer(5), .text("Eve"), .integer(25)],
  ] as Array<Array<Value>>
  return Memory(["People": Relation(fields, records, sorted: 0)])
}

/// A catalog modelling a decoded coded-index key: an `Attribute` relation whose
/// `Parent` column is seekable but not ordered. It stands in for a
/// `CustomAttribute` physically sorted on its raw `Parent` coded index with
/// mixed tags — each row's stored `Parent` is the raw coded cell
/// `(rowid << Coded.bits) | tag` (tag `0` a `TypeDef`, tag `1` another table),
/// sorted ascending; the `Row` decodes it, so the column reads as the target
/// `TypeDef` `rowid` (tag `0`) or `NULL` (tag `1`). The raw run brackets one
/// tag's equal value, but the tag-1 rows interleaved by row decode to `NULL`, so
/// a range on the decoded column must not seek the raw boundary — it would
/// return other-tag rows that decode outside the range.
private func attributes() -> Memory {
  let fields = [
    Field(name: "Parent", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  // Stored `Parent` = `(rowid << 2) | tag` (Coded.bits == 2), ascending.
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
  return Memory(["Attribute": Relation(fields, records, coded: 0)])
}

/// A wide catalog: a `Wide` relation of ten columns, to prove a query that
/// references only a few of them still works (projection pushdown).
private func wide() -> Memory {
  let fields = (0 ..< 10).map { Field(name: "C\($0)", kind: .integer) }
  let records = (0 ..< 4).map { row in
    (0 ..< 10).map { Value.integer(row * 10 + $0) }
  }
  return Memory(["Wide": Relation(fields, records, sorted: 0)])
}

/// The join catalog: a `Parent` relation sorted on `Id`, an unsorted twin
/// `ParentUnsorted` (same rows, no seekable column), and a `Child` relation
/// whose `Pid` is a foreign key to a parent `Id`. The `Ordered` relation has no
/// stored key — a join on it keys off its virtual `rowid`.
private func family() -> Memory {
  let parent = [
    Field(name: "Id", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    Field(name: "Pid", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.integer(1), .text("Amy")],
    [.integer(2), .text("Bob")],
    [.integer(9), .text("Orphan")],
  ] as Array<Array<Value>>

  // A keyless relation: its identity is its 1-based row position (`rowid`).
  let ordered = [
    Field(name: "Label", kind: .text),
  ]
  let labels = [
    [.text("first")],
    [.text("second")],
    [.text("third")],
  ] as Array<Array<Value>>

  return Memory([
    "Parent": Relation(parent, parents, sorted: 0),
    "ParentUnsorted": Relation(parent, parents),
    "Child": Relation(child, children),
    "Ordered": Relation(ordered, labels),
  ])
}

/// The view catalog: the `family` relations plus two registered views — `Adults`
/// (a single-relation projection over `Parent`) and `Pairs` (a projection over
/// the `Parent`/`Child` foreign-key join). A view is queried like a table, and
/// `Pairs` proves a view whose definition is itself a join.
private func views() throws -> Memory {
  // SELECT Id, Name FROM Parent WHERE Id >= 2 — exposed as columns Key, Label.
  let adults = try View(query: select("""
      SELECT Id, Name FROM Parent WHERE Id >= 2
      """), columns: ["Key", "Label"])

  // SELECT Parent.Name, Child.Name FROM Parent JOIN Child ON … — a view over a
  // join, its two projected columns exposed as Parent and Kid.
  let pairs = try View(query: select("""
      SELECT Parent.Name, Child.Name FROM Parent
        JOIN Child ON Child.Pid = Parent.Id
      """), columns: ["Parent", "Kid"])

  // SELECT Id, Name FROM Parent WHERE Id = :id — a parameterized view whose
  // bound key seeks inside its sub-plan when :id is supplied.
  let picked = try View(query: select("""
      SELECT Id, Name FROM Parent WHERE Id = :id
      """), columns: ["Key", "Label"])

  let catalog = family()
  return Memory(catalog.relations,
                views: ["Adults": adults, "Pairs": pairs, "Picked": picked])
}

/// A catalog with NULL cells: a `Maybe` relation whose `Note` text column is
/// `NULL` in some rows, to exercise three-valued comparison and `IS [NOT] NULL`.
private func nullable() -> Memory {
  let fields = [
    Field(name: "Id", kind: .integer),
    Field(name: "Note", kind: .text),
  ]
  let records = [
    [.integer(1), .text("alpha")],
    [.integer(2), .null],
    [.integer(3), .text("gamma")],
    [.integer(4), .null],
  ] as Array<Array<Value>>
  return Memory(["Maybe": Relation(fields, records)])
}

/// The null-key join catalog: a `Parent` sorted on `Id` and a `Child` one of
/// whose foreign keys is `NULL`, to prove a `NULL` join key matches nothing.
private func nullableKeys() -> Memory {
  let parent = [
    Field(name: "Id", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
  ] as Array<Array<Value>>

  let child = [
    Field(name: "Pid", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.null, .text("Nobody")],
    [.integer(2), .text("Bob")],
  ] as Array<Array<Value>>

  return Memory([
    "Parent": Relation(parent, parents, sorted: 0),
    "Child": Relation(child, children),
  ])
}

/// A three-level catalog for multi-way joins: `House` → `Room` → `Item`, each
/// child carrying a foreign key to its parent's `Id`. `House` and `Room` are
/// sorted on `Id`, so a join keyed on `Id` seeks; `Item` is unsorted and scans.
private func lineage() -> Memory {
  let house = [
    Field(name: "Id", kind: .integer),
    Field(name: "House", kind: .text),
  ]
  let houses = [
    [.integer(1), .text("Burrow")],
    [.integer(2), .text("Manor")],
  ] as Array<Array<Value>>

  let room = [
    Field(name: "Id", kind: .integer),
    Field(name: "Hid", kind: .integer),
    Field(name: "Room", kind: .text),
  ]
  let rooms = [
    [.integer(1), .integer(1), .text("Kitchen")],
    [.integer(2), .integer(1), .text("Attic")],
    [.integer(3), .integer(2), .text("Hall")],
  ] as Array<Array<Value>>

  let item = [
    Field(name: "Rid", kind: .integer),
    Field(name: "Item", kind: .text),
  ]
  let items = [
    [.integer(1), .text("Kettle")],
    [.integer(1), .text("Pot")],
    [.integer(3), .text("Banner")],
    [.integer(9), .text("Lost")],
  ] as Array<Array<Value>>

  return Memory([
    "House": Relation(house, houses, sorted: 0),
    "Room": Relation(room, rooms, sorted: 0),
    "Item": Relation(item, items),
  ])
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
private func shared() -> Memory {
  let author = [
    Field(name: "Aid", kind: .integer),
    Field(name: "Code", kind: .integer),
  ]
  let authors = [
    [.integer(1), .integer(10)],
    [.integer(2), .integer(20)],
  ] as Array<Array<Value>>

  let book = [
    Field(name: "Bid", kind: .integer),
    Field(name: "Aid", kind: .integer),
  ]
  let books = [
    [.integer(100), .integer(10)],
    [.integer(101), .integer(20)],
  ] as Array<Array<Value>>

  let sale = [
    Field(name: "Sid", kind: .integer),
    Field(name: "Code", kind: .integer),
  ]
  let sales = [
    [.integer(100), .integer(900)],
    [.integer(101), .integer(901)],
  ] as Array<Array<Value>>

  return Memory([
    "Author": Relation(author, authors, sorted: 0),
    "Book": Relation(book, books, sorted: 1),
    "Sale": Relation(sale, sales),
  ])
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
  try Engine.run(parse(text), people())
}

/// Runs `text` against the wide catalog.
private func wide(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), wide())
}

/// Runs `text` against the coded-key `Attribute` catalog.
private func attributes(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), attributes())
}

/// Runs `text` against the join `family` catalog.
private func join(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), family())
}

/// Runs `text` against the view catalog.
private func view(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), views())
}

/// Runs `text` against the nullable `Maybe` catalog.
private func nullable(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), nullable())
}

/// Runs `text` against the three-level `lineage` catalog.
private func lineage(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), lineage())
}

/// Runs `text` against the `shared`-column chain catalog.
private func shared(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), shared())
}

// MARK: - Single-relation tests

struct EngineProjectionTests {
  @Test("SELECT * yields every real column and excludes the virtual rowid")
  func star() throws {
    let rows = try run("SELECT * FROM People WHERE Id = 1")
    // Three real columns; `rowid` is virtual and never in `*`.
    #expect(rows == [[.integer(1), .text("Alice"), .integer(30)]])
  }

  @Test("SELECT names yields the named columns in order")
  func named() throws {
    let rows = try run("SELECT Name, Id FROM People WHERE Id = 2")
    #expect(rows == [[.text("Bob"), .integer(2)]])
  }

  @Test("a named projection may include the virtual rowid column")
  func virtual() throws {
    let rows = try run("SELECT rowid, Name FROM People WHERE Name = 'Carol'")
    // Carol is the third row; her 1-based `rowid` is 3.
    #expect(rows == [[.integer(3), .text("Carol")]])
  }

  @Test("an unknown column is reported")
  func unknown() throws {
    #expect(throws: SQLError.column("Missing")) {
      try run("SELECT Missing FROM People")
    }
  }

  @Test("an unknown relation is reported")
  func relation() throws {
    #expect(throws: SQLError.relation("Absent")) {
      try run("SELECT * FROM Absent")
    }
  }
}

struct EngineFilterTests {
  @Test("equality on a text column")
  func text() throws {
    let rows = try run("SELECT Id FROM People WHERE Name = 'Carol'")
    #expect(rows == [[.integer(3)]])
  }

  @Test("a range on the sorted column")
  func range() throws {
    let rows = try run("SELECT Id FROM People WHERE Id >= 4")
    #expect(rows == [[.integer(4)], [.integer(5)]])
  }

  @Test("an AND of a seekable conjunct and a residual")
  func conjunction() throws {
    let rows = try run("SELECT Name FROM People WHERE Id > 1 AND Age = 30")
    #expect(rows == [[.text("Carol")]])
  }

  @Test("an OR scans and admits either side")
  func disjunction() throws {
    let rows =
        try run("SELECT Id FROM People WHERE Id = 1 OR Name = 'Eve'")
    #expect(rows == [[.integer(1)], [.integer(5)]])
  }

  @Test("a NOT scans and negates")
  func negation() throws {
    let rows = try run("SELECT Id FROM People WHERE NOT Age = 30")
    #expect(rows == [[.integer(2)], [.integer(4)], [.integer(5)]])
  }

  @Test("a filter on the virtual rowid column")
  func virtual() throws {
    let rows = try run("SELECT Name FROM People WHERE rowid = 4")
    #expect(rows == [[.text("Dave")]])
  }
}

struct EngineOrderTests {
  @Test("ORDER BY ascending on an integer column")
  func ascending() throws {
    let rows = try run("SELECT Id FROM People ORDER BY Age ASC")
    // Ages: Bob 25, Eve 25, Alice 30, Carol 30, Dave 40 — a stable sort keeps
    // the scan order within an equal-key group.
    #expect(rows == [[.integer(2)], [.integer(5)], [.integer(1)],
                     [.integer(3)], [.integer(4)]])
  }

  @Test("ORDER BY descending on a text column")
  func descending() throws {
    let rows = try run("SELECT Name FROM People ORDER BY Name DESC")
    #expect(rows == [[.text("Eve")], [.text("Dave")], [.text("Carol")],
                     [.text("Bob")], [.text("Alice")]])
  }
}

struct EngineProjectionPushdownTests {
  @Test("a query referencing few columns of a wide relation works")
  func few() throws {
    // The relation has ten columns; the query reads only C0 (filter, project),
    // C5 (project), and C8 (order). The leaf materialises just those, but the
    // result is exactly as if every column were copied.
    let rows = try wide("""
        SELECT C5, C0 FROM Wide WHERE C0 >= 10 ORDER BY C8 DESC
        """)
    #expect(rows == [
      [.integer(35), .integer(30)],
      [.integer(25), .integer(20)],
      [.integer(15), .integer(10)],
    ])
  }
}

struct EngineSeekTests {
  @Test("the seek path and the scan path return identical results")
  func equivalence() throws {
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
/// `(rowid << Coded.bits) | tag`, decoded to the `TypeDef` `rowid` or `NULL`).
/// The engine-level plan-shape assertion complements the two result assertions.
struct EngineCodedKeyTests {
  @Test("a range on an unordered coded key scans and admits only its own rows")
  func range() throws {
    // `Parent < 5` must return only the TypeDef-tagged rows whose decoded
    // `rowid` is `< 5` (td1, td2, td4) — never the other-tag rows (other-a, -b,
    // -c), which decode to NULL. Before the fix the raw boundary
    // `0 ..< bound(5)` seeked the low raw run, sweeping in the interleaved NULLs.
    let rows = try attributes("SELECT Name FROM Attribute WHERE Parent < 5")
    #expect(rows == [[.text("td1")], [.text("td2")], [.text("td4")]])
  }

  @Test("a range equals the correct scan-and-filter result")
  func equivalence() throws {
    // The seek path (`Parent < 5`) must equal a filter that cannot seek at all
    // (`Name < 'z'` over the same rows, restricted to the tagged ones) — i.e.
    // the range yields exactly the rows a full scan-and-filter would.
    let seek = try attributes("SELECT Name FROM Attribute WHERE Parent < 5")
    let scan = try attributes("""
        SELECT Name FROM Attribute WHERE Parent < 5 AND Name < 'z'
        """)
    #expect(seek == scan)
  }

  @Test("an equality on an unordered coded key still seeks its exact run")
  func equality() throws {
    // Equality is always seekable — the exact coded run brackets exactly the
    // rows that decode to the value, and a join rechecks — so `Parent = 4`
    // returns just td4.
    let rows = try attributes("SELECT Name FROM Attribute WHERE Parent = 4")
    #expect(rows == [[.text("td4")]])
  }

  @Test("an equality on zero rejects a null coded reference rather than seeking")
  func null() throws {
    // A decoded row is 1-based, so `Parent = 0` is `NULL = 0` for every row —
    // UNKNOWN, admitting none. Row 0's stored raw cell is `(0 << 2) | 0 == 0`,
    // which encodes exactly the target the equality would seek; before the fix
    // `bound(0, …)` bracketed that raw run and `Engine.seek` consumed it with no
    // residual recheck, leaking the null-reference row. The fix returns `nil`
    // for a non-positive decoded rowid, so the query scans and filters, and the
    // decoded `NULL` correctly fails `= 0`.
    let rows = try attributes("SELECT Name FROM Attribute WHERE Parent = 0")
    #expect(rows.isEmpty)
  }

  @Test("an equality too large to encode rejects rather than seeking an alias")
  func overflow() throws {
    // A decoded rowid must be encodable without truncation. `(1 << 62) + 6` is
    // positive but past `Int.max >> Coded.bits`, so `(value << 2) | 0` shifts the
    // high `1` clear out of the word and aliases raw `24` — the same raw cell as
    // `td6` (`(6 << 2) | 0`). Before the upper-bound guard, `bound` bracketed
    // that aliased run and `Engine.seek` consumed the standalone equality with no
    // residual recheck, returning td6 for a value no decoded key equals. The
    // guard returns `nil` for the unencodable value, so the query scans and
    // filters — every decoded key is a small rowid or NULL, none equals the huge
    // value — and admits nothing.
    let alias = (1 << 62) + 6
    let rows =
        try attributes("SELECT Name FROM Attribute WHERE Parent = \(alias)")
    #expect(rows.isEmpty)
  }

  @Test("an equality plans a seek, a range plans a scan-and-filter")
  func plan() throws {
    // The plan shape proves the gate directly: equality reaches a seeked scan
    // with no residual filter; a range reaches a raw scan under a filter.
    let catalog = attributes()

    let equal = try parse("SELECT Name FROM Attribute WHERE Parent = 4")
    let equalPlan =
        try Engine.optimise(Engine.compile(equal, catalog), catalog, [:])
    #expect(seeks(equalPlan))
    #expect(!filters(equalPlan))

    let less = try parse("SELECT Name FROM Attribute WHERE Parent < 5")
    let lessPlan =
        try Engine.optimise(Engine.compile(less, catalog), catalog, [:])
    #expect(!seeks(lessPlan))
    #expect(filters(lessPlan))
  }
}

struct EngineQualifierTests {
  @Test("a qualifier matching the alias resolves the column")
  func alias() throws {
    let rows = try run("SELECT p.Name FROM People AS p WHERE Id = 1")
    #expect(rows == [[.text("Alice")]])
  }

  @Test("a qualifier matching the table name resolves the column")
  func name() throws {
    let rows = try run("SELECT People.Name FROM People WHERE Id = 1")
    #expect(rows == [[.text("Alice")]])
  }

  @Test("a qualifier naming neither the alias nor the table is reported")
  func foreign() throws {
    // `x` names neither the alias `p` nor the table `People`; a single-relation
    // query rejects it rather than dropping the qualifier and binding `Name`.
    #expect(throws: SQLError.column("Name")) {
      try run("SELECT x.Name FROM People AS p")
    }
  }

  @Test("a qualifier naming a different table is reported")
  func mismatch() throws {
    // The reviewer's case: `Child.Name` against `FROM Parent` must not resolve
    // to `Parent`'s `Name`; the qualifier names a relation not in scope.
    #expect(throws: SQLError.column("Name")) {
      try join("SELECT Child.Name FROM Parent")
    }
  }
}

// MARK: - Join tests

struct EngineJoinTests {
  @Test("a join on a foreign key pairs each child with its parent")
  func star() throws {
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

  @Test("a qualified projection selects across both relations")
  func qualified() throws {
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test("a join keys off the inner relation's virtual rowid")
  func virtual() throws {
    // `Ordered` has no stored key; its identity is its 1-based `rowid`. The
    // child's `Pid` joins to that virtual column.
    let rows = try join("""
        SELECT Ordered.Label, Child.Name FROM Child
          JOIN Ordered ON Ordered.rowid = Child.Pid
        """)
    // Pid 1 → "first" (Ann, Amy), Pid 2 → "second" (Bob); Pid 9 has no row.
    #expect(rows == [
      [.text("first"), .text("Ann")],
      [.text("first"), .text("Amy")],
      [.text("second"), .text("Bob")],
    ])
  }

  @Test("a join keyed off the OUTER relation's virtual rowid does not collide")
  func outerVirtual() throws {
    // The combined ordinal space lays the inner relation past the outer's
    // `extent` — its real width plus the virtual columns it exposes — so an
    // outer virtual column never shares an ordinal with an inner real one. Here
    // `Ordered` is the OUTER relation, and the join keys off its virtual `rowid`
    // at ordinal `width`; the inner `Child.Pid` is a real column at ordinal 0.
    // Were the inner laid at the outer's `width` (or at a base collapsed to 0
    // by a `1 << 32` reserve on a 32-bit host), `Child.Pid` would land on the
    // outer `rowid`'s ordinal and the join's cells would corrupt one another.
    let rows = try join("""
        SELECT Ordered.rowid, Child.Name FROM Ordered
          JOIN Child ON Child.Pid = Ordered.rowid
        """)
    // rowid 1 → Ann, Amy; rowid 2 → Bob; rowid 3 has no child; Pid 9 no parent.
    #expect(rows == [
      [.integer(1), .text("Ann")],
      [.integer(1), .text("Amy")],
      [.integer(2), .text("Bob")],
    ])
  }

  @Test("a WHERE spans both relations")
  func predicate() throws {
    let rows = try join("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada' AND Child.Name = 'Amy'
        """)
    #expect(rows == [[.text("Amy")]])
  }

  @Test("ORDER BY orders across the join")
  func order() throws {
    let rows = try join("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          ORDER BY Child.Name ASC
        """)
    #expect(rows == [[.text("Amy")], [.text("Ann")], [.text("Bob")]])
  }

  @Test("an unqualified name in both relations is ambiguous")
  func ambiguous() throws {
    #expect(throws: SQLError.ambiguous("Name")) {
      try join("SELECT Name FROM Parent JOIN Child ON Child.Pid = Parent.Id")
    }
  }

  @Test("a self-join's shared table name makes a qualified name ambiguous")
  func selfJoin() throws {
    #expect(throws: SQLError.ambiguous("Id")) {
      try join("""
          SELECT Parent.Name FROM Parent JOIN Parent ON Parent.Id = Parent.Id
          """)
    }
  }

  @Test("a duplicated alias makes a shared qualified column ambiguous")
  func duplicate() throws {
    // `x.Id`/`x.Pid` resolve by column (one side each); `x.Name` is on both,
    // so the shared alias is ambiguous rather than binding silently to outer.
    #expect(throws: SQLError.ambiguous("Name")) {
      try join("""
          SELECT x.Name FROM Parent AS x JOIN Child AS x ON x.Id = x.Pid
          """)
    }
  }

  @Test("a parent with no matching child contributes no rows")
  func empty() throws {
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Cid'
        """)
    #expect(rows.isEmpty)
  }

  @Test("the seek probe and the scan probe return identical results")
  func equivalence() throws {
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

// MARK: - Multi-way join tests

struct EngineMultiJoinTests {
  @Test("a three-relation chain joins across two foreign keys")
  func chain() throws {
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

  @Test("a chain seeks each inner relation keyed on its sorted column")
  func seeked() throws {
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

  @Test("a WHERE filters across a three-relation chain")
  func filtered() throws {
    let rows = try lineage("""
        SELECT Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
          WHERE House.House = 'Burrow' AND Item.Item = 'Pot'
        """)
    #expect(rows == [[.text("Pot")]])
  }

  @Test("an unqualified name in more than one relation of a chain is ambiguous")
  func ambiguous() throws {
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

  @Test("an early ON referencing a not-yet-joined relation is rejected")
  func premature() throws {
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

  @Test("a valid early ON whose columns are all in its prefix runs")
  func prefixed() throws {
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

  @Test("an unqualified early-ON column a later relation shares is not ambiguous")
  func disambiguated() throws {
    // The first join's `ON` reads unqualified `Code`, unique within its prefix
    // `{Author, Book}` even though `Sale` — joined only later — also carries a
    // `Code`. Resolving the match against the prefix binds it; resolving against
    // the whole chain would see two `Code`s and report `SQLError.ambiguous`.
    let rows = try shared("""
        SELECT Author.Aid, Book.Bid, Sale.Code FROM Author
          JOIN Book ON Code = Book.Aid
          JOIN Sale ON Sale.Sid = Book.Bid
        """)
    #expect(rows == [
      [.integer(1), .integer(100), .integer(900)],
      [.integer(2), .integer(101), .integer(901)],
    ])
  }
}

// MARK: - View tests

struct EngineViewTests {
  @Test("a view resolves and queries like a table")
  func table() throws {
    // `SELECT * FROM Adults` runs the view's `SELECT Id, Name FROM Parent
    // WHERE Id >= 2`, exposing the columns as `Key`/`Label`.
    let rows = try view("SELECT * FROM Adults")
    #expect(rows == [
      [.integer(2), .text("Bee")],
      [.integer(3), .text("Cid")],
    ])
  }

  @Test("a projection over a view selects the view's columns by name")
  func projection() throws {
    let rows = try view("SELECT Label FROM Adults")
    #expect(rows == [[.text("Bee")], [.text("Cid")]])
  }

  @Test("a WHERE over a view filters its rows")
  func filter() throws {
    let rows = try view("SELECT Label FROM Adults WHERE Key = 3")
    #expect(rows == [[.text("Cid")]])
  }

  @Test("an ORDER BY over a view orders its rows")
  func order() throws {
    let rows = try view("SELECT Label FROM Adults ORDER BY Label DESC")
    #expect(rows == [[.text("Cid")], [.text("Bee")]])
  }

  @Test("a view whose definition is a join resolves and queries")
  func join() throws {
    // `Pairs` denormalises the `Parent`/`Child` foreign-key join; querying it
    // runs the inner join and exposes its two columns as `Parent`/`Kid`.
    let rows = try view("SELECT * FROM Pairs")
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test("a projection and filter over a join view selects across its columns")
  func joinProjection() throws {
    let rows = try view("SELECT Kid FROM Pairs WHERE Parent = 'Ada'")
    #expect(rows == [[.text("Ann")], [.text("Amy")]])
  }

  @Test("an unknown column of a view is reported")
  func unknown() throws {
    #expect(throws: SQLError.column("Missing")) {
      try view("SELECT Missing FROM Adults")
    }
  }

  @Test("a SELECT * view over-declaring its columns is rejected at resolution")
  func wideStar() throws {
    // `Parent` is two columns wide, but the view declares three. A `SELECT *`
    // has no statically known arity, so the parser admits the list; the engine
    // catches the mismatch at resolution rather than indexing past a row.
    let star = try View(query: select("SELECT * FROM Parent"),
                        columns: ["a", "b", "c"])
    let catalog = Memory(family().relations, views: ["Star": star])
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
      try Engine.run(parse("SELECT a FROM Star"), catalog)
    }
  }

  @Test("a SELECT * view whose explicit list matches the width resolves")
  func matchedStar() throws {
    // The same `SELECT *` view declared with the right number of columns
    // resolves and queries — the backstop passes the well-formed view through.
    let star = try View(query: select("SELECT * FROM Parent"),
                        columns: ["a", "b"])
    let catalog = Memory(family().relations, views: ["Star": star])
    let rows = try Engine.run(parse("SELECT b FROM Star WHERE a = 1"), catalog)
    #expect(rows == [[.text("Ada")]])
  }

  @Test("a view's definition is optimised — its seekable predicate seeks")
  func optimised() throws {
    // `Adults` is `SELECT Id, Name FROM Parent WHERE Id >= 2`, and `Parent` is
    // sorted on `Id`, so the view's sub-plan must seek that run rather than
    // scanning under a `Select`. Compile and optimise an outer query over the
    // view and inspect the `.derived` leaf: its sub-plan must reach a seeked
    // `.scan` (a non-nil seek) and carry no `.select` over a raw scan.
    let catalog = try views()
    let select = try parse("SELECT Key, Label FROM Adults")
    let plan = try Engine.optimise(Engine.compile(select, catalog), catalog,
                                   [:])
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
  case let .sort(_, _, source):
    derived(source)
  case let .product(left, right):
    derived(left) ?? derived(right)
  case let .union(left, right, _):
    derived(left) ?? derived(right)
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
  case let .sort(_, _, source):
    seeks(source)
  case let .derived(_, sub, _, _):
    seeks(sub)
  case let .product(left, right):
    seeks(left) || seeks(right)
  case let .join(outer, _, _, _, _, _, _):
    // A pushed-down key seeks the join's OUTER leaf, so a seek can live inside
    // the join rather than only atop a bare scan.
    seeks(outer)
  case let .union(left, right, _):
    seeks(left) || seeks(right)
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
  case let .sort(_, _, source):
    filters(source)
  case let .derived(_, sub, _, _):
    filters(sub)
  case let .product(left, right):
    filters(left) || filters(right)
  case let .union(left, right, _):
    filters(left) || filters(right)
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
  case let .select(_, source):
    pushed(source)
  case let .project(_, source):
    pushed(source)
  case let .sort(_, _, source):
    pushed(source)
  case let .derived(_, sub, _, _):
    pushed(sub)
  case let .union(left, right, _):
    pushed(left) || pushed(right)
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
  case let .sort(_, _, source):
    floats(source)
  case let .derived(_, sub, _, _):
    floats(sub)
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
  case let .sort(_, _, source):
    joins(source)
  case let .derived(_, sub, _, _):
    joins(sub)
  case let .product(left, right):
    joins(left) || joins(right)
  case let .union(left, right, _):
    joins(left) || joins(right)
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
  case let .sort(_, _, source):
    residual(source)
  case let .derived(_, sub, _, _):
    residual(sub)
  case let .product(left, right):
    residual(left) || residual(right)
  case let .join(outer, _, _, _, _, _, _):
    residual(outer)
  case let .union(left, right, _):
    residual(left) || residual(right)
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
    Field(name: "Id", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    Field(name: "Pid", kind: .integer),
    Field(name: "Kid", kind: .text),
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
        "Parent": Relation(parent, parents, sorted: 0, counter: reads),
        "Child": Relation(child, children),
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
    Field(name: "Key", kind: .integer),
    Field(name: "Tag", kind: .text),
  ]
  let alphas = [
    [.integer(1), .text("a1")],
    [.integer(2), .text("a2")],
    [.integer(3), .text("a3")],
  ] as Array<Array<Value>>

  let beta = [
    Field(name: "Tag", kind: .text),
    Field(name: "Key", kind: .integer),
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
    "Alpha": Relation(alpha, alphas, sorted: 0),
    "Beta": Relation(beta, betas),
  ], views: ["Both": both])
}

/// Whether `plan` reaches a `.union` every arm of which carries a filter pushed
/// below its projection — a seeked scan or a `.select` over its scan inside each
/// arm's body, the per-arm rebase this fix enables.
private func injected(_ plan: Plan) -> Bool {
  switch plan {
  case let .union(left, right, _):
    (seeks(left) || floats(left)) && (seeks(right) || floats(right))
  case let .select(_, source):
    injected(source)
  case let .project(_, source):
    injected(source)
  case let .sort(_, _, source):
    injected(source)
  case let .derived(_, sub, _, _):
    injected(sub)
  case let .product(left, right):
    injected(left) || injected(right)
  case let .join(outer, _, _, _, _, _, _):
    injected(outer)
  case .single, .scan:
    false
  }
}

struct EnginePushdownTests {
  @Test("a single-relation WHERE conjunct rides below the join")
  func placement() throws {
    // `WHERE Parent.Name = 'Ada'` references only the outer relation, so it
    // pushes to the Parent leaf inside the join rather than filtering the whole
    // product afterwards — `pushed` sees a filter within the join's outer.
    let catalog = family()
    let select = try parse("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada'
        """)
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(pushed(plan))
  }

  @Test("pushdown down a seekable outer key seeks that leaf inside the join")
  func seeked() throws {
    // `WHERE Parent.Id = 2` is seekable; pushed to the Parent leaf it becomes a
    // seek inside the join's outer, not a scan-then-filter atop the product.
    let catalog = family()
    let select = try parse("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Id = 2
        """)
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(seeks(plan))
    #expect(pushed(plan))
  }

  @Test("a trailing seekable conjunct survives a rebuilt three-term AND")
  func seekable() throws {
    // Pushdown flattens a single-table filter through `conjuncts` and rebuilds
    // it via `conjunction`. A right-leaning rebuild would bury the trailing
    // `Id = 5` under a nested AND, hidden from `seek` (which inspects only a
    // top-level AND's two immediate children); the left-leaning rebuild keeps it
    // the immediate RHS, as the parser produced it, so the sort-key seek
    // survives the three-term AND.
    let catalog = Memory([
      "T": Relation([
        Field(name: "Name", kind: .text),
        Field(name: "Age", kind: .integer),
        Field(name: "Id", kind: .integer),
      ], [
        [.text("a"), .integer(1), .integer(5)],
        [.text("b"), .integer(2), .integer(6)],
      ] as Array<Array<Value>>, sorted: 2),
    ])
    let select = try parse("""
        SELECT Name FROM T WHERE Name <> 'x' AND Age > 0 AND Id = 5
        """)
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(seeks(plan))
  }

  @Test("a seekable conjunct grouped after an unsafe one does not bypass its throw")
  func grouped() throws {
    // The left fold rebuilds `(1 / x) = 0 AND (name <> 'z' AND id < 0)` — parsed
    // as `A AND (B AND C)` — into `((A AND B) AND C)`, promoting the seekable
    // `id < 0` to the top-level RHS `seek` inspects. On an id-sorted table whose
    // `id < 0` run is empty, seeking that run drops every row before the earlier
    // `(1 / x) = 0` division runs, suppressing the throw the scan owes. `seek`
    // seeks a conjunct only when the residual is safe, so the unsafe division
    // residual bars the seek: the plan scans, and it raises.
    let catalog = Memory([
      "T": Relation([
        Field(name: "x", kind: .integer),
        Field(name: "name", kind: .text),
        Field(name: "id", kind: .integer),
      ], [
        [.integer(0), .text("a"), .integer(5)],
      ] as Array<Array<Value>>, sorted: 2),
    ])
    let select = try parse("""
        SELECT id FROM T WHERE (1 / x) = 0 AND (name <> 'z' AND id < 0)
        """)

    // The unsafe `(1 / x) = 0` residual bars the `id < 0` seek — the plan scans.
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(!seeks(plan))

    // …and the scan raises the division rather than seeking past the empty run.
    #expect(throws: SQLError.self) {
      _ = try Engine.run(select, catalog)
    }
  }

  @Test("pushdown preserves the join's result")
  func correctness() throws {
    // The pushed plan must return exactly the un-pushed join's rows.
    let rows = try join("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada'
        """)
    #expect(rows == [[.text("Ann")], [.text("Amy")]])
  }

  @Test("a non-key predicate on the joined-in relation still uses the join")
  func inner() throws {
    // `WHERE Parent.Name <> 'zz'` references only the joined-in `Parent`, so
    // pushdown wraps that inner leaf as `Select(_, Scan(Parent))` before the
    // join folds it in. `nest` must look through that pushed filter and still
    // form a `Join` — not fall back to a residual product filtered by the ON
    // predicate (O(left × filtered-right)).
    let catalog = family()
    let select = try parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Parent.Name <> 'zz'
        """)
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(joins(plan))

    // …and it returns the correct rows: every child with a matching parent,
    // the joined-in predicate keeping all of them (no parent is named 'zz').
    let rows = try join("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Parent.Name <> 'zz'
        """)
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test("a spanning WHERE leaves the join path with a residual above it")
  func spanning() throws {
    // `WHERE Parent.Name <> Child.Name` references BOTH joined relations, so it
    // descends no further than the product and stays as a residual. The ON
    // match must remain adjacent to the product — folded in with the spanning
    // conjunct — so `nest` still finds it and forms a `Join`, keeping the
    // spanning predicate as a `Select` ABOVE the join rather than degrading to a
    // filtered Cartesian `product`.
    let catalog = family()
    let select = try parse("""
        SELECT Child.Name, Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id WHERE Parent.Name <> Child.Name
        """)
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(joins(plan))
    #expect(floats(plan))

    // …and it returns the join's rows filtered by the spanning predicate: every
    // matched pair survives, none sharing a name across the two relations.
    let rows = try join("""
        SELECT Child.Name, Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id WHERE Parent.Name <> Child.Name
        """)
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test("a WHERE over a join view prunes its rows before the join runs")
  func view() throws {
    // `Kin` is the Parent/Child join; `WHERE Key = 2` over it must push INTO the
    // view's sub-plan and seek Parent to the single matching row before joining,
    // so only that parent's rows are read — not the whole relation.
    let (culled, pruned) = try counted()
    let rows = try Engine.run(parse("SELECT Kid FROM Kin WHERE Key = 2"),
                              culled)
    #expect(rows == [[.text("Bob")]])

    // The un-pushed baseline: the same view with no `WHERE` reads every parent
    // row — three.
    let (whole, full) = try counted()
    _ = try Engine.run(parse("SELECT Kid FROM Kin"), whole)
    #expect(full.reads == 3)

    // Pushed, the seek reads the one matching parent — a single row.
    #expect(pruned.reads == 1)
  }

  @Test("the pushed view result matches the unfiltered view filtered late")
  func equivalence() throws {
    // Running the view then filtering must agree with the pushed plan.
    let (catalog, _) = try counted()
    let all = try Engine.run(parse("SELECT Key, Kid FROM Kin"), catalog)
    let culled = all.filter { $0[0] == .integer(2) }.map { [$0[1]] }
    let filtered =
        try Engine.run(parse("SELECT Kid FROM Kin WHERE Key = 2"), catalog)
    #expect(filtered == culled)
  }

  @Test("a slotless predicate stays above the join and skips an empty product")
  func slotless() throws {
    // `WHERE (1 / 0) = 0` reads no slots, so it must stay at the product level
    // and run per pair — not ride down to the left input. `B` is empty, so the
    // join's product is empty and the throwing expression is never evaluated;
    // the query returns no rows. Pushed to the left, it would run once per left
    // row and raise `SQLError.divide`.
    let catalog = Memory([
      "A": Relation([Field(name: "x", kind: .integer)],
                    [[.integer(1)]] as Array<Array<Value>>),
      "B": Relation([Field(name: "y", kind: .integer)],
                    [] as Array<Array<Value>>),
    ])
    let rows = try Engine.run(parse("""
        SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / 0) = 0
        """), catalog)
    #expect(rows.isEmpty)
  }

  @Test("a throwing single-side predicate stays above the join, skips an empty product")
  func hazardous() throws {
    // `WHERE (1 / A.x) = 0` reads only `A`'s slot but CAN throw (division), so —
    // like a slotless throwing predicate — it must stay at the product level, not
    // ride down to `A`. `B` is empty, so the product is empty and the division is
    // never evaluated; the query returns no rows. Pushed to `A` (x = 0) it would
    // divide by zero and raise `SQLError.divide`.
    let catalog = Memory([
      "A": Relation([Field(name: "x", kind: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
      "B": Relation([Field(name: "y", kind: .integer)],
                    [] as Array<Array<Value>>),
    ])
    let rows = try Engine.run(parse("""
        SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / A.x) = 0
        """), catalog)
    #expect(rows.isEmpty)
  }

  @Test("an unsafe conjunct bars a later safe one from suppressing its throw")
  func barrier() throws {
    // `WHERE (1 / A.x) = 0 AND A.x <> 0`: left-to-right, the division runs first
    // and raises on the matching pair (`A.x = 0` joined to `B.y = 0`). The safe
    // `A.x <> 0` must NOT ride down to `A` — doing so would drop the row before
    // the division runs, silently returning no rows. The earlier unsafe conjunct
    // is an ordering barrier, so the query raises as the un-pushed `AND` would.
    let catalog = Memory([
      "A": Relation([Field(name: "x", kind: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
      "B": Relation([Field(name: "y", kind: .integer)],
                    [[.integer(0)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.self) {
      _ = try Engine.run(parse("""
          SELECT A.x FROM A JOIN B ON A.x = B.y WHERE (1 / A.x) = 0 AND A.x <> 0
          """), catalog)
    }
  }

  @Test("a lifted inner filter keeps its place before a later unsafe residual")
  func lifted() throws {
    // `WHERE Parent.Name = 'nope' AND (1 / Child.x) = 0`: left-to-right, the
    // false `Parent.Name` check short-circuits before the division on the
    // matching pair (Child.x = 0). `Parent.Name = 'nope'` is a single-side inner
    // filter that nest lifts out of the join — it must stay BEFORE the unsafe
    // division in the residual, not be appended after it, or the division runs
    // first and raises. The matching Parent is named 'other', so the row is
    // excluded with no throw.
    let catalog = Memory([
      "Child": Relation([Field(name: "Pid", kind: .integer),
                         Field(name: "x", kind: .integer)],
                        [[.integer(1), .integer(0)]] as Array<Array<Value>>),
      "Parent": Relation([Field(name: "Id", kind: .integer),
                          Field(name: "Name", kind: .text)],
                         [[.integer(1), .text("other")]]
                             as Array<Array<Value>>),
    ])
    let rows = try Engine.run(parse("""
        SELECT Child.x FROM Child JOIN Parent ON Parent.Id = Child.Pid
          WHERE Parent.Name = 'nope' AND (1 / Child.x) = 0
        """), catalog)
    #expect(rows.isEmpty)
  }

  @Test("a WHERE over a UNION view pushes into every arm's projection")
  func union() throws {
    // `Both` unions `Alpha` and `Beta`, whose shared `Key` output column sits at
    // DIFFERING body slots. `WHERE Key = 2` must rebase PER ARM — the union root
    // fails a single pre-rebased filter — pushing below each arm's projection
    // and seeking the sorted `Alpha` arm.
    let catalog = try spanned()
    let select = try parse("SELECT Tag FROM Both WHERE Key = 2")
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(injected(plan))
    #expect(seeks(plan))

    // …and the rows are exactly the union filtered late: `a2` from Alpha and
    // `b2` from Beta.
    let rows = try Engine.run(select, catalog)
    #expect(rows == [[.text("a2")], [.text("b2")]])
  }

  @Test("a view's throwing projection term is not suppressed by a pushed filter")
  func throwingView() throws {
    // The view projects `1 / z`, which raises on the `z = 0` row. `derive`
    // evaluates every projected column for every view row, so `SELECT id FROM V
    // WHERE id <> 0` raises even though `id <> 0` would exclude that row —
    // pushing `id <> 0` below the view's Project would filter the row first and
    // silently skip the division, so a view whose projection can throw is never
    // pushed into.
    let t = [Field(name: "id", kind: .integer),
             Field(name: "z", kind: .integer)]
    let rows = [[.integer(0), .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT id, 1 / z FROM T"),
                        columns: ["id", "q"])
    let catalog = Memory(["T": Relation(t, rows)], views: ["V": view])
    #expect(throws: SQLError.self) {
      _ = try Engine.run(parse("SELECT id FROM V WHERE id <> 0"), catalog)
    }
  }

  @Test("an unsafe outer conjunct bars a later push into a view")
  func gated() throws {
    // `V` is `SELECT x FROM T` with `T.x` sorted and a single `x = 0` row.
    // `SELECT x FROM V WHERE (1 / x) = 0 AND x = 1`: left-to-right, the division
    // runs on the `x = 0` row and raises. The safe seekable `x = 1` must NOT push
    // into the view past the earlier unsafe `(1 / x) = 0` — doing so would SEEK
    // the view (`T.x` sorted) to `x = 1`, dropping the `x = 0` row before the
    // outer division ever runs, silently returning no rows. The unsafe outer
    // conjunct is an ordering barrier, so the query raises as the un-pushed `AND`
    // would.
    let t = [Field(name: "x", kind: .integer)]
    let rows = [[.integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x FROM T"), columns: ["x"])
    let catalog = Memory(["T": Relation(t, rows, sorted: 0)],
                         views: ["V": view])
    #expect(throws: SQLError.self) {
      _ = try Engine.run(parse("SELECT x FROM V WHERE (1 / x) = 0 AND x = 1"),
                         catalog)
    }
  }

  @Test("a nullable conjunct is not pushed below a later unsafe conjunct")
  func nullable() throws {
    // `WHERE A.x = 1 AND (1 / B.y) = 0`: the evaluator's `AND` does not short-
    // circuit, so on the matching pair (A.x NULL, B.y = 0) the UNKNOWN left
    // still runs the right, and the division raises. The safe `A.x = 1`
    // references a slot, so a NULL there makes it UNKNOWN — pushing it to `A`'s
    // scan would drop the A.x-NULL row before the join, so the later unsafe
    // `(1 / B.y) = 0` never runs and the throw the `AND` owes is suppressed. A
    // nullable conjunct must NOT ride past a LATER unsafe conjunct, so `A.x = 1`
    // stays a product-level residual and the query raises.
    let catalog = Memory([
      "A": Relation([Field(name: "x", kind: .integer),
                     Field(name: "k", kind: .integer)],
                    [[.null, .integer(0)]] as Array<Array<Value>>),
      "B": Relation([Field(name: "y", kind: .integer),
                     Field(name: "k", kind: .integer)],
                    [[.integer(0), .integer(0)]] as Array<Array<Value>>),
    ])
    let select = try parse("""
        SELECT A.x FROM A JOIN B ON A.k = B.k
          WHERE A.x = 1 AND (1 / B.y) = 0
        """)

    // `A.x = 1` is nullable and precedes the unsafe division, so it is NOT
    // pushed to the `A` leaf — it floats at the product level.
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(!pushed(plan))
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try Engine.run(select, catalog)
    }
  }

  @Test("a nullable conjunct is not pushed into a view below a later unsafe one")
  func nullableView() throws {
    // `V` exposes safe columns `x` and `y`. `SELECT x FROM V WHERE x = 1 AND
    // (1 / y) = 0`: the `AND` does not short-circuit, so on the (x NULL, y = 0)
    // row the UNKNOWN left still runs the division, which raises. Pushing the
    // nullable `x = 1` into the view would drop the x-NULL row before the outer
    // division runs, suppressing the throw. A nullable conjunct must NOT be
    // injected past a LATER unsafe outer conjunct, so `x = 1` stays outer and
    // the query raises.
    let t = [Field(name: "x", kind: .integer),
             Field(name: "y", kind: .integer)]
    let rows = [[.null, .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x, y FROM T"),
                        columns: ["x", "y"])
    let catalog = Memory(["T": Relation(t, rows)], views: ["V": view])
    let select = try parse("SELECT x FROM V WHERE x = 1 AND (1 / y) = 0")

    // `x = 1` is nullable and precedes the unsafe division, so it is NOT
    // injected into the view — it floats above the derived leaf.
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try Engine.run(select, catalog)
    }
  }

  @Test("a slotless bound conjunct is not pushed into a view below a later unsafe one")
  func boundView() throws {
    // A `.bound` predicate compares against a run-time `:parameter` and reads no
    // slot, yet it is UNKNOWN when the parameter is unbound (or bound to NULL).
    // `SELECT x FROM V WHERE 1 = :missing AND (1 / y) = 0` with `:missing`
    // unbound: the outer `AND` does not short-circuit, so on the (y = 0) row the
    // UNKNOWN left still runs the division, which raises. Injecting the slotless
    // `1 = :missing` into the view would drop every row first, suppressing the
    // throw. A bound conjunct is nullable despite reading no slot, so it stays
    // outer and the query raises.
    let t = [Field(name: "x", kind: .integer),
             Field(name: "y", kind: .integer)]
    let rows = [[.integer(1), .integer(0)]] as Array<Array<Value>>
    let view = try View(query: select("SELECT x, y FROM T"),
                        columns: ["x", "y"])
    let catalog = Memory(["T": Relation(t, rows)], views: ["V": view])
    let select = try parse("SELECT x FROM V WHERE 1 = :missing AND (1 / y) = 0")

    // `1 = :missing` is a slotless bound predicate, hence nullable; it precedes
    // the unsafe division, so it is NOT injected into the view — it floats above
    // the derived leaf.
    let plan =
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(floats(plan))

    // …and the query raises rather than silently dropping the row.
    #expect(throws: SQLError.self) {
      _ = try Engine.run(select, catalog)
    }
  }

  @Test("a throwing WHERE is not evaluated for a pair an UNKNOWN ON rejects")
  func gatedMatch() throws {
    // `A JOIN V ON A.k = V.k WHERE (1 / A.x) = 0` where `V` is a derived view,
    // so `nest` cannot fold the product into a `Join`. On the `A` row with a
    // NULL `k` and `x = 0`, the ON match is UNKNOWN — the join forms no pair for
    // it — but `evaluate(.and)` does not short-circuit, so folding the match and
    // WHERE into one AND would evaluate `(1 / 0)` and raise. Keeping the match a
    // separate inner gate drops that pair before the WHERE runs, so the query
    // does not raise: the matched `x = 1` row fails `(1 / 1) = 0`, leaving no
    // rows.
    let a = [Field(name: "x", kind: .integer), Field(name: "k", kind: .integer)]
    let catalog = Memory([
      "A": Relation(a, [[.integer(1), .integer(1)],
                        [.integer(0), .null]] as Array<Array<Value>>),
      "T": Relation([Field(name: "k", kind: .integer)],
                    [[.integer(1)]] as Array<Array<Value>>),
    ], views: ["V": try View(query: select("SELECT k FROM T"),
                             columns: ["k"])])
    let select =
        try parse("SELECT A.x FROM A JOIN V ON A.k = V.k WHERE (1 / A.x) = 0")

    // The UNKNOWN-ON pair (A.k NULL) is dropped by the match gate before the
    // division runs, so the query returns rows rather than raising.
    #expect(try Engine.run(select, catalog) == [])
  }
}

// MARK: - Hash-join tests

/// A join catalog whose inner `Parent` is UNSORTED (so its join key is not
/// seekable and the executor hashes it) and tallies its row reads — to prove the
/// hash build scans the inner exactly once rather than once per outer record.
private func hashable() -> (catalog: Memory, reads: Counter) {
  let reads = Counter()
  let parent = [
    Field(name: "Id", kind: .integer),
    Field(name: "Name", kind: .text),
  ]
  let parents = [
    [.integer(1), .text("Ada")],
    [.integer(2), .text("Bee")],
    [.integer(3), .text("Cid")],
  ] as Array<Array<Value>>

  let child = [
    Field(name: "Pid", kind: .integer),
    Field(name: "Kid", kind: .text),
  ]
  let children = [
    [.integer(1), .text("Ann")],
    [.integer(1), .text("Amy")],
    [.integer(2), .text("Bob")],
    [.integer(9), .text("Orphan")],
  ] as Array<Array<Value>>

  let catalog = Memory([
    "Parent": Relation(parent, parents, counter: reads),
    "Child": Relation(child, children),
  ])
  return (catalog, reads)
}

struct EngineHashJoinTests {
  @Test("a hash join over an unsorted inner scans it exactly once")
  func single() throws {
    // `Parent` is unsorted, so its `Id` is not seekable and the join hashes it.
    // Four outer children probe the map, but the inner is read only three times
    // — its row count — not twelve (once per outer).
    let (catalog, reads) = hashable()
    let rows = try Engine.run(parse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """), catalog)
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Amy"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
    #expect(reads.reads == 3)
  }

  @Test("a coded-index inner key seeks rather than hashing the whole inner")
  func coded() throws {
    // The join strategy is chosen by probing the inner key for seekability. A
    // decoded coded-index column is 1-based and rejects the null reference `0`,
    // so probing with `0` would call it unseekable and hash every inner row;
    // probing with a valid `1` finds it seekable, so a selective join seeks the
    // coded run instead. `Attribute.Parent` is such a column (stored raw
    // `(rowid << 2) | tag`, decoded to a rowid), and one `Type` (Id 6) probes it.
    let reads = Counter()
    let type = [Field(name: "Id", kind: .integer)]
    let types = [[.integer(6)]] as Array<Array<Value>>
    let attribute = [
      Field(name: "Parent", kind: .integer),
      Field(name: "Name", kind: .text),
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
      "Type": Relation(type, types),
      "Attribute": Relation(attribute, attributes, coded: 0, counter: reads),
    ])
    let rows = try Engine.run(parse("""
        SELECT Attribute.Name FROM Type
          JOIN Attribute ON Attribute.Parent = Type.Id
        """), catalog)
    #expect(rows == [[.text("td6")]])
    // Seeked: only the `Parent = 6` run (the single `td6` row) is read, not all
    // six. Before the fix — probing seekability with `0` — the coded column
    // tested unseekable and the join hashed, reading every attribute row.
    #expect(reads.reads == 1)
  }

  @Test("an empty outer skips the hash build of an unseekable inner")
  func empty() throws {
    // A contradictory outer WHERE prunes every `Child`, so the outer is empty
    // and no probe can match. The inner `Parent` is unsorted (unseekable), so
    // the join would hash it — but with no probes the build is pointless. The
    // empty-outer short-circuit returns before scanning, so ZERO inner rows are
    // read; the nested-loop path this replaced already read none for an empty
    // outer, and a large unseekable inner must not be fully scanned to answer
    // nothing.
    let (catalog, reads) = hashable()
    let rows = try Engine.run(parse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Child.Pid < 0
        """), catalog)
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }

  @Test("an all-NULL-key outer skips the hash build of an unseekable inner")
  func allNull() throws {
    // The outer is NON-empty but every `Child.Pid` is NULL (a `WHERE Pid IS
    // NULL` keeps only the null-keyed rows), and a NULL key joins to nothing —
    // so no probe can match. The inner `Parent` is unsorted (unseekable), so the
    // join would hash it; but with no non-null probe the build is pointless. The
    // no-probe guard returns before scanning, so ZERO inner rows are read — the
    // nested-loop path this replaced read none for an all-null outer too.
    let reads = Counter()
    let parent = [
      Field(name: "Id", kind: .integer),
      Field(name: "Name", kind: .text),
    ]
    let parents = [
      [.integer(1), .text("Ada")],
      [.integer(2), .text("Bee")],
    ] as Array<Array<Value>>
    let child = [
      Field(name: "Pid", kind: .integer),
      Field(name: "Kid", kind: .text),
    ]
    let children = [
      [.integer(1), .text("Ann")],
      [.null, .text("Nemo")],
      [.null, .text("Nobody")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Parent": Relation(parent, parents, counter: reads),
      "Child": Relation(child, children),
    ])
    let rows = try Engine.run(parse("""
        SELECT Child.Kid, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid WHERE Child.Pid IS NULL
        """), catalog)
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }

  @Test("the hash probe and the seek probe return identical results")
  func equivalence() throws {
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

  @Test("a hash join emits matches outer-major in inner cursor order")
  func order() throws {
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

  @Test("a NULL key joins to nothing under the hash path")
  func null() throws {
    // The child with a NULL foreign key is the outer row; a NULL key hashes to
    // nothing, and a NULL inner key is never bucketed. `Parent` here is unsorted
    // so the join hashes.
    let parent = [
      Field(name: "Id", kind: .integer),
      Field(name: "Name", kind: .text),
    ]
    let parents = [
      [.integer(1), .text("Ada")],
      [.integer(2), .text("Bee")],
    ] as Array<Array<Value>>
    let child = [
      Field(name: "Pid", kind: .integer),
      Field(name: "Name", kind: .text),
    ]
    let children = [
      [.integer(1), .text("Ann")],
      [.null, .text("Nobody")],
      [.integer(2), .text("Bob")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Parent": Relation(parent, parents),
      "Child": Relation(child, children),
    ])
    let rows = try Engine.run(parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """), catalog)
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }

  @Test("a seekable inner filter seeks the hash inner rather than scanning it")
  func filtered() throws {
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
      Field(name: "Id", kind: .integer),
      Field(name: "Code", kind: .integer),
    ]
    let parents = [
      [.integer(1), .integer(10)],
      [.integer(2), .integer(20)],
      [.integer(3), .integer(30)],
    ] as Array<Array<Value>>
    let child = [
      Field(name: "Code", kind: .integer),
      Field(name: "Kid", kind: .text),
    ]
    let children = [
      [.integer(10), .text("Ann")],
      [.integer(20), .text("Bob")],
    ] as Array<Array<Value>>
    // `Parent` is sorted on `Id` (column 0), so `Id` seeks but the join key
    // `Code` (column 1) does not — forcing the hash path.
    let catalog = Memory([
      "Parent": Relation(parent, parents, sorted: 0, counter: reads),
      "Child": Relation(child, children),
    ])
    let rows = try Engine.run(parse("""
        SELECT Child.Kid, Parent.Id FROM Child
          JOIN Parent ON Parent.Code = Child.Code WHERE Parent.Id < 0
        """), catalog)
    #expect(rows.isEmpty)
    #expect(reads.reads == 0)
  }
}

// MARK: - Streaming-product tests

struct EngineStreamingProductTests {
  @Test("a join whose inner is a view leaves a residual product-under-select")
  func shape() throws {
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
        try Engine.optimise(Engine.compile(select, catalog).pushdown(),
                            catalog, [:])
    #expect(residual(plan))
  }

  @Test("the streamed product filters row by row to the right rows")
  func correctness() throws {
    // `Adults` is Parent rows with Id >= 2 (Key 2 → Bee, 3 → Cid); only the
    // child whose Pid equals a Key survives — Bob (Pid 2) against Bee.
    let catalog = try views()
    let rows = try Engine.run(parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """), catalog)
    #expect(rows == [[.text("Bob"), .text("Bee")]])
  }

  @Test("the streamed product equals the eager product filtered")
  func equivalence() throws {
    // Cross the two inputs by hand — every child paired with every adult in
    // outer-major order — and keep the pairs the ON equality admits. The fused
    // streaming operator must yield exactly this, in this order.
    let catalog = try views()
    let children = try Engine.run(parse("SELECT Name, Pid FROM Child"), catalog)
    let adults = try Engine.run(parse("SELECT Label, Key FROM Adults"), catalog)

    var eager = Array<Array<Value>>()
    for child in children {
      for adult in adults where child[1] == adult[1] {
        eager.append([child[0], adult[0]])
      }
    }

    let streamed = try Engine.run(parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """), catalog)
    #expect(streamed == eager)
  }

  @Test("a residual product with UNKNOWN pairs drops them")
  func unknown() throws {
    // A NULL-keyed pair evaluates the ON equality to UNKNOWN, which the fused
    // filter drops exactly as `admitted` would — no NULL child reaches a match.
    let child = [
      Field(name: "Pid", kind: .integer),
      Field(name: "Name", kind: .text),
    ]
    let children = [
      [.integer(2), .text("Bob")],
      [.null, .text("Nobody")],
    ] as Array<Array<Value>>
    let adults = try View(query: select("""
        SELECT Id, Name FROM Base WHERE Id >= 2
        """), columns: ["Key", "Label"])
    let base = [
      Field(name: "Id", kind: .integer),
      Field(name: "Name", kind: .text),
    ]
    let bases = [
      [.integer(2), .text("Bee")],
      [.integer(3), .text("Cid")],
    ] as Array<Array<Value>>
    let catalog = Memory([
      "Child": Relation(child, children),
      "Base": Relation(base, bases, sorted: 0),
    ], views: ["Adults": adults])
    let rows = try Engine.run(parse("""
        SELECT Child.Name, Adults.Label FROM Child
          JOIN Adults ON Adults.Key = Child.Pid
        """), catalog)
    #expect(rows == [[.text("Bob"), .text("Bee")]])
  }
}

// MARK: - Scalar-function tests

/// Routines with two demonstration scalar functions: `upper`, which folds a
/// text cell to upper case, and `add`, which sums two integer cells. These
/// stand in for the per-dialect decode functions a synthesis projection calls.
private func routines() -> Routines {
  Routines()
    .registering("upper") { arguments throws(SQLError) in
      guard case let .text(text) = arguments.first else {
        throw .argument("upper expects one text argument")
      }
      return .text(text.uppercased())
    }
    .registering("add") { arguments throws(SQLError) in
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
  try Engine.run(parse(text), people(), routines())
}

struct EngineFunctionTests {
  @Test("a registered function projects over a column")
  func projection() throws {
    let rows = try functionRun("SELECT upper(Name) FROM People WHERE Id = 1")
    #expect(rows == [[.text("ALICE")]])
  }

  @Test("a function projects beside a bare column")
  func mixed() throws {
    let rows =
        try functionRun("SELECT Id, upper(Name) FROM People WHERE Id = 3")
    #expect(rows == [[.integer(3), .text("CAROL")]])
  }

  @Test("a function takes more than one column argument")
  func multiple() throws {
    let rows = try functionRun("SELECT add(Id, Age) FROM People WHERE Id = 2")
    // Bob: Id 2 + Age 25 = 27.
    #expect(rows == [[.integer(27)]])
  }

  @Test("a function takes a literal argument")
  func literal() throws {
    let rows = try functionRun("SELECT add(Id, 100) FROM People WHERE Id = 4")
    #expect(rows == [[.integer(104)]])
  }

  @Test("a function call nests another function call")
  func nested() throws {
    let rows =
        try functionRun("SELECT add(add(Id, 1), Age) FROM People WHERE Id = 5")
    // Eve: (5 + 1) + 25 = 31.
    #expect(rows == [[.integer(31)]])
  }

  @Test("an unregistered function is reported")
  func unknown() throws {
    #expect(throws: SQLError.function("missing")) {
      try functionRun("SELECT missing(Name) FROM People")
    }
  }

  @Test("a function rejecting its arguments reports the fault")
  func invalid() throws {
    #expect(throws: SQLError.argument("upper expects one text argument")) {
      try functionRun("SELECT upper(Id) FROM People WHERE Id = 1")
    }
  }

  @Test("a function call resolves its name case-insensitively")
  func folded() throws {
    // `upper` is registered; the natural SQL spelling UPPER resolves to it, as
    // table and column identifiers do.
    let rows = try functionRun("SELECT UPPER(Name) FROM People WHERE Id = 1")
    #expect(rows == [[.text("ALICE")]])
  }

  @Test("the built-in BITAND yields the bitwise AND of two integers")
  func bitand() throws {
    // BITAND is an engine built-in: `routines()` never registers it, yet the
    // call resolves and folds case-insensitively. 12 & 10 = 8; 6 & 3 = 2.
    #expect(try functionRun("SELECT BITAND(12, 10) FROM People WHERE Id = 1")
            == [[.integer(8)]])
    #expect(try functionRun("SELECT bitand(6, 3) FROM People WHERE Id = 1")
            == [[.integer(2)]])
  }

  @Test("BITAND reports a function-argument fault, not a UNION arity error")
  func bitandFaults() throws {
    // The wrong argument count is a function-argument fault (`.argument`), not
    // `.arity` — whose message is the UNION column-count mismatch.
    #expect(throws: SQLError.argument("BITAND takes two arguments")) {
      try functionRun("SELECT BITAND(1) FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.argument("BITAND requires integer arguments")) {
      try functionRun("SELECT BITAND('a', 1) FROM People WHERE Id = 1")
    }
  }

  @Test("a registered function cannot shadow the built-in BITAND")
  func bitandNotShadowed() throws {
    // A built-in resolves ahead of a registered function of the same name, so
    // an unqualified `BITAND` is always the built-in, not the user's closure.
    let user = Routines().registering("bitand") { _ throws(SQLError) in
      .integer(-1)
    }
    let query = try parse("SELECT BITAND(6, 3) FROM People WHERE Id = 1")
    let rows = try Engine.run(query, people(), user)
    #expect(rows == [[.integer(2)]])
  }

  @Test("routine names colliding only by case merge without trapping")
  func collision() throws {
    // "tag" and "TAG" fold to one name; the registry merges them (the later-
    // sorting original spelling wins) instead of trapping on the duplicate.
    let lower: Scalar = { _ in .text("lower") }
    let upper: Scalar = { _ in .text("upper") }
    let routines: Routines = ["tag": lower, "TAG": upper]
    let query = try parse("SELECT tag(Name) FROM People WHERE Id = 1")
    let rows = try Engine.run(query, people(), routines)
    #expect(rows == [[.text("lower")]])
  }

  @Test("a predicate filters on a scalar function call")
  func predicate() throws {
    // The documented contract: a predicate may call a registered function;
    // `upper(Name) = 'ALICE'` decodes the column before comparing.
    let rows =
        try functionRun("SELECT Id FROM People WHERE upper(Name) = 'ALICE'")
    #expect(rows == [[.integer(1)]])
  }

  @Test("a predicate compares a function result to an integer")
  func arithmetic() throws {
    let rows =
        try functionRun("SELECT Name FROM People WHERE add(Id, 10) = 12")
    #expect(rows == [[.text("Bob")]])
  }
}

// MARK: - NULL tests

struct EngineNullTests {
  @Test("IS NULL admits only the NULL rows")
  func isNull() throws {
    let rows = try nullable("SELECT Id FROM Maybe WHERE Note IS NULL")
    #expect(rows == [[.integer(2)], [.integer(4)]])
  }

  @Test("IS NOT NULL admits only the non-NULL rows")
  func isNotNull() throws {
    let rows = try nullable("SELECT Id FROM Maybe WHERE Note IS NOT NULL")
    #expect(rows == [[.integer(1)], [.integer(3)]])
  }

  @Test("a comparison against a NULL cell is UNKNOWN and rejects")
  func comparison() throws {
    // For the NULL rows (2, 4) `Note = 'alpha'` is UNKNOWN, not false, so they
    // are not admitted; only the row whose Note equals 'alpha' survives.
    let rows = try nullable("SELECT Id FROM Maybe WHERE Note = 'alpha'")
    #expect(rows == [[.integer(1)]])
  }

  @Test("NOT of a NULL comparison stays UNKNOWN and rejects")
  func negated() throws {
    // The NULL rows are UNKNOWN; NOT UNKNOWN is UNKNOWN, so they still reject —
    // only the non-null, non-'alpha' row survives.
    let rows = try nullable("SELECT Id FROM Maybe WHERE NOT Note = 'alpha'")
    #expect(rows == [[.integer(3)]])
  }

  @Test("a NULL cell projects as a NULL value")
  func projection() throws {
    let rows = try nullable("SELECT Note FROM Maybe WHERE Id = 2")
    #expect(rows == [[.null]])
  }

  @Test("ORDER BY ascending sorts NULL keys first, then by value")
  func orderAscending() throws {
    // NULL holds a stable position — first in ascending order — so the non-null
    // notes still sort among themselves ('alpha' before 'gamma') rather than
    // tying with the nulls and leaving the order undefined.
    let rows = try nullable("SELECT Id FROM Maybe ORDER BY Note ASC")
    #expect(rows == [[.integer(2)], [.integer(4)], [.integer(1)], [.integer(3)]])
  }

  @Test("ORDER BY descending sorts NULL keys last")
  func orderDescending() throws {
    let rows = try nullable("SELECT Id FROM Maybe ORDER BY Note DESC")
    #expect(rows == [[.integer(3)], [.integer(1)], [.integer(2)], [.integer(4)]])
  }

  @Test("a NULL outer join key matches no inner row")
  func join() throws {
    // The child with a NULL foreign key is the outer row; a NULL key equi-joins
    // to nothing, so it contributes no pair — `Parent` is sorted, so the inner
    // is seeked and the NULL key is skipped before probing.
    let rows = try Engine.run(parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """), nullableKeys())
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
  try Engine.run(parse(text), family(), Routines(), bindings: bindings)
}

struct EngineBoundTests {
  @Test("a bound parameter filters rows by an outer value")
  func filter() throws {
    // The child relation keyed on a bound parent id — the section primitive: a
    // template renders an interface's methods by binding the interface key and
    // running the child query.
    let rows = try boundRun("SELECT Name FROM Child WHERE Pid = :pid",
                            ["pid": .integer(1)])
    #expect(rows == [[.text("Ann")], [.text("Amy")]])
  }

  @Test("a bound text parameter compares against a text column")
  func text() throws {
    let rows = try boundRun("SELECT Id FROM Parent WHERE Name = :who",
                            ["who": .text("Bee")])
    #expect(rows == [[.integer(2)]])
  }

  @Test("an unbound parameter admits no row")
  func unbound() throws {
    let rows = try boundRun("SELECT Name FROM Child WHERE Pid = :pid", [:])
    #expect(rows.isEmpty)
  }

  @Test("a bound parameter conjoined with another predicate")
  func conjunction() throws {
    let rows = try boundRun("""
        SELECT Name FROM Child WHERE Pid = :pid AND Name = 'Amy'
        """, ["pid": .integer(1)])
    #expect(rows == [[.text("Amy")]])
  }

  @Test("a correlated section runs a child query per outer row")
  func correlated() throws {
    // The relational shape of a template's nested section: the outer query
    // yields the parents; for each, the child query is re-run with the parent's
    // key bound, producing that parent's children — exactly an interface →
    // methods expansion.
    let catalog = family()
    let parents = try Engine.run(parse("SELECT Id, Name FROM Parent"), catalog)
    let query = try parse("SELECT Name FROM Child WHERE Pid = :pid")

    var sections = Array<(parent: String, children: Array<String>)>()
    for parent in parents {
      let key = parent[0]
      let children = try Engine.run(query, catalog, Routines(),
                                    bindings: ["pid": key])
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

  @Test("an unbound parameter under NOT still admits no rows")
  func negated() throws {
    // A missing binding is UNKNOWN, not false; NOT preserves UNKNOWN rather
    // than inverting it into a match, so the predicate admits nothing.
    let rows = try boundRun("SELECT Name FROM Child WHERE NOT Pid = :pid", [:])
    #expect(rows.isEmpty)
  }

  @Test("a bound parameter under NOT inverts the match")
  func inverted() throws {
    let rows = try boundRun("SELECT Name FROM Child WHERE NOT Pid = :pid",
                            ["pid": .integer(1)])
    #expect(rows == [[.text("Bob")], [.text("Orphan")]])
  }

  @Test("a bound key plans a seek when its value is known")
  func seek() throws {
    // Parent is sorted on Id; with `:id` bound the planner resolves it and
    // seeks the run rather than scanning and filtering the whole relation.
    let select = try parse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = family()
    let plan = try Engine.optimise(Engine.compile(select, catalog), catalog,
                                   ["id": .integer(2)])
    #expect(seeks(plan))
    #expect(!filters(plan))
  }

  @Test("an unbound key cannot seek and scans under the filter")
  func scan() throws {
    let select = try parse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = family()
    let plan = try Engine.optimise(Engine.compile(select, catalog), catalog,
                                   [:])
    #expect(!seeks(plan))
    #expect(filters(plan))
  }

  @Test("a bound key inside a view seeks when its parameter is supplied")
  func nested() throws {
    // A parameterized view (`… WHERE Id = :id` over sorted Parent): the bound
    // key seeks inside the view's sub-plan rather than scanning it once :id is
    // supplied, so a reusable view is as fast as the inlined query.
    let select = try parse("SELECT Key, Label FROM Picked")
    let catalog = try views()
    let plan = try Engine.optimise(Engine.compile(select, catalog), catalog,
                                   ["id": .integer(2)])
    let sub = try #require(derived(plan))
    #expect(seeks(sub))
    #expect(!filters(sub))
  }
}

// MARK: - UNION tests

/// A three-relation catalog for `UNION`: `Left` and `Right` each hold a single
/// `Tag` text column, sharing the value `shared` so a union across them proves
/// cross-relation dedup; the values are otherwise distinct. `Extra` repeats the
/// `a` already in `Left`, so a trailing `UNION ALL Extra` keeps it a second
/// time — proving an inner `UNION`'s dedup survives an outer `UNION ALL`.
private func tags() -> Memory {
  let fields = [Field(name: "Tag", kind: .text)]
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
    "Left": Relation(fields, left),
    "Right": Relation(fields, right),
    "Extra": Relation(fields, extra),
  ])
}

struct EngineUnionTests {
  @Test("UNION removes whole-row duplicates, keeping the first occurrence")
  func dedup() throws {
    // People's Age repeats (30 for Alice and Carol, 25 for Bob and Eve); a
    // UNION of the relation with itself collapses every duplicate row.
    let rows = try Engine.run(parse("""
        SELECT Age FROM People UNION SELECT Age FROM People
        """), people())
    #expect(rows == [[.integer(30)], [.integer(25)], [.integer(40)]])
  }

  @Test("UNION ALL keeps every row of every arm in source order")
  func all() throws {
    let rows = try Engine.run(parse("""
        SELECT Age FROM People UNION ALL SELECT Age FROM People
        """), people())
    let ages = [30, 25, 30, 40, 25].map { Value.integer($0) }
    #expect(rows == (ages + ages).map { [$0] })
  }

  @Test("a UNION across two relations of matching arity merges and dedups")
  func merge() throws {
    let rows = try Engine.run(parse("""
        SELECT Tag FROM Left UNION SELECT Tag FROM Right
        """), tags())
    // `shared` appears in both arms but survives once, first occurrence kept.
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test("a UNION ALL across two relations keeps the shared row twice")
  func mergeAll() throws {
    let rows = try Engine.run(parse("""
        SELECT Tag FROM Left UNION ALL SELECT Tag FROM Right
        """), tags())
    #expect(rows == [
      [.text("a")],
      [.text("shared")],
      [.text("shared")],
      [.text("b")],
    ])
  }

  @Test("an inner UNION dedups before a trailing UNION ALL appends its arm")
  func nestedAll() throws {
    // (Left UNION Right) UNION ALL Extra. The inner UNION dedups `shared`
    // across Left and Right to one row — `a, shared, b` — and the outer UNION
    // ALL then appends Extra's `a` WITHOUT deduplicating, so `a` recurs. A
    // chain flattened to the trailing `all` would instead keep both copies of
    // `shared`; honouring each node's own flag keeps exactly one.
    let rows = try Engine.run(parse("""
        SELECT Tag FROM Left UNION SELECT Tag FROM Right
          UNION ALL SELECT Tag FROM Extra
        """), tags())
    #expect(rows == [
      [.text("a")],
      [.text("shared")],
      [.text("b")],
      [.text("a")],
    ])
  }

  @Test("a UNION of arms projecting differing column counts is rejected")
  func arity() throws {
    #expect(throws: SQLError.arity(1, 2)) {
      try Engine.run(parse("""
          SELECT Id FROM People UNION SELECT Id, Name FROM People
          """), people())
    }
  }

  @Test("a view defined as a UNION resolves and queries")
  func view() throws {
    let both = try View(query: select("""
        SELECT Tag FROM Left UNION SELECT Tag FROM Right
        """), columns: ["Tag"])
    let catalog = Memory(tags().relations, views: ["Both": both])
    let rows = try Engine.run(parse("SELECT Tag FROM Both"), catalog)
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test("a bound parameter threads into every arm of a UNION")
  func bound() throws {
    // Both arms key on the same `:pid`; the binding reaches each alike, so the
    // union is the parent's children drawn from two queries over the relation.
    let rows = try Engine.run(parse("""
        SELECT Name FROM Child WHERE Pid = :pid
          UNION ALL SELECT Name FROM Child WHERE Pid = :pid
        """), family(), Routines(), bindings: ["pid": .integer(1)])
    #expect(rows == [
      [.text("Ann")],
      [.text("Amy")],
      [.text("Ann")],
      [.text("Amy")],
    ])
  }
}

// MARK: - Arithmetic tests

struct EngineArithmeticTests {
  @Test("literal arithmetic evaluates over a row")
  func literal() throws {
    // One row of `People` drives the projection; the value is the same for each,
    // and `Id = 1` selects exactly one.
    let rows = try run("SELECT 2 + 3 FROM People WHERE Id = 1")
    #expect(rows == [[.integer(5)]])
  }

  @Test("multiplication binds tighter than addition")
  func precedence() throws {
    let rows = try run("SELECT 2 + 3 * 4 FROM People WHERE Id = 1")
    #expect(rows == [[.integer(14)]])
  }

  @Test("parentheses override precedence")
  func grouping() throws {
    let rows = try run("SELECT (2 + 3) * 4 FROM People WHERE Id = 1")
    #expect(rows == [[.integer(20)]])
  }

  @Test("subtraction and division are left-associative")
  func associativity() throws {
    // (20 - 5) - 3 = 12, not 20 - (5 - 3) = 18; (100 / 5) / 2 = 10.
    let difference = try run("SELECT 20 - 5 - 3 FROM People WHERE Id = 1")
    #expect(difference == [[.integer(12)]])
    let quotient = try run("SELECT 100 / 5 / 2 FROM People WHERE Id = 1")
    #expect(quotient == [[.integer(10)]])
  }

  @Test("integer division truncates")
  func integerDivision() throws {
    let rows = try run("SELECT 7 / 2 FROM People WHERE Id = 1")
    #expect(rows == [[.integer(3)]])
  }

  @Test("arithmetic over a column computes per row")
  func column() throws {
    let rows = try run("SELECT Age + 1 FROM People WHERE Id = 2")
    // Bob's Age is 25; 25 + 1 = 26.
    #expect(rows == [[.integer(26)]])
  }

  @Test("arithmetic mixes columns and a function call")
  func mixed() throws {
    let rows = try functionRun("SELECT add(Id, 1) * 10 FROM People WHERE Id = 3")
    // Carol: (3 + 1) * 10 = 40.
    #expect(rows == [[.integer(40)]])
  }

  @Test("a NULL operand propagates to a NULL result")
  func nullPropagation() throws {
    // `Note` is NULL for row 2; `Id + Note` mixes a present integer with a NULL,
    // so the whole expression is NULL rather than a fault.
    let rows = try nullable("SELECT Id + Note FROM Maybe WHERE Id = 2")
    #expect(rows == [[.null]])
  }

  @Test("division by zero faults")
  func divideByZero() throws {
    #expect(throws: SQLError.divide) {
      try run("SELECT Id / 0 FROM People WHERE Id = 1")
    }
  }

  @Test("arithmetic overflow faults instead of trapping")
  func overflow() throws {
    // `Int.max + 1` and a multiply past the boundary report overflow as a
    // `SQLError` rather than trapping (and aborting) the process.
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try run("SELECT 9223372036854775807 + 1 FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try run("SELECT 9223372036854775807 * 2 FROM People WHERE Id = 1")
    }
  }

  @Test("a parenthesised expression opens a predicate")
  func parenthesisedExpression() throws {
    // `(Age + 1)` is the grouped left operand of the comparison, not a predicate
    // group; it matches Dave (40 + 1 = 41). A leading `(` no longer forces a
    // predicate-group parse.
    let matched = try run("SELECT Id FROM People WHERE (Age + 1) = 41")
    #expect(matched == [[.integer(4)]])
    // A grouped expression works before `IS NULL` too; `Id + 1` is never NULL.
    let none = try run("SELECT Id FROM People WHERE (Id + 1) IS NULL")
    #expect(none.isEmpty)
  }

  @Test("a text operand faults as a type error")
  func textOperand() throws {
    #expect(throws: SQLError.operand("operands must be integers")) {
      try run("SELECT Name + 1 FROM People WHERE Id = 1")
    }
  }

  @Test("arithmetic in a predicate filters rows")
  func predicate() throws {
    // `Age + 1 = 26` holds for everyone aged 25 (Bob and Eve); the arithmetic
    // is evaluated per row on the WHERE side too.
    let rows = try run("SELECT Name FROM People WHERE Age + 1 = 26")
    #expect(rows == [[.text("Bob")], [.text("Eve")]])
  }
}

// MARK: - Scalar (FROM-less) SELECT tests

struct EngineScalarSelectTests {
  @Test("a FROM-less literal yields exactly one row")
  func literal() throws {
    // No relation, so the projection runs against a single empty row; the
    // catalog is never consulted for a table.
    let rows = try run("SELECT 42")
    #expect(rows == [[.integer(42)]])
  }

  @Test("a FROM-less arithmetic computes a scalar")
  func arithmetic() throws {
    let rows = try run("SELECT 1 + 1")
    #expect(rows == [[.integer(2)]])
  }

  @Test("FROM-less arithmetic honours precedence")
  func precedence() throws {
    let rows = try run("SELECT 2 + 3 * 4")
    #expect(rows == [[.integer(14)]])
  }

  @Test("a FROM-less multi-column projection yields one row of each value")
  func multiColumn() throws {
    let rows = try run("SELECT 1, 2, 3")
    #expect(rows == [[.integer(1), .integer(2), .integer(3)]])
  }

  @Test("a FROM-less projection mixes text and integer expressions")
  func mixed() throws {
    let rows = try run("SELECT 'x', 10 / 2")
    #expect(rows == [[.text("x"), .integer(5)]])
  }

  @Test("a FROM-less scalar call evaluates against the single row")
  func call() throws {
    let rows = try functionRun("SELECT add(40, 2)")
    #expect(rows == [[.integer(42)]])
  }

  @Test("a NULL-yielding FROM-less expression projects NULL")
  func null() throws {
    // The bare literal NULL is not in the grammar, but a NULL arises from a
    // function returning it; `nothing` yields NULL for the single row.
    let routines: Routines = ["nothing": { _ in .null }]
    let rows = try Engine.run(parse("SELECT nothing()"), people(), routines)
    #expect(rows == [[.null]])
  }

  @Test("a FROM-less SELECT * is rejected — no relation to expand")
  func star() throws {
    #expect(throws: SQLError.unsupported("SELECT * requires a FROM clause")) {
      try run("SELECT *")
    }
  }

  @Test("a FROM-less bare column is rejected — no column to bind")
  func column() throws {
    #expect(throws: SQLError.column("Name")) {
      try run("SELECT Name")
    }
  }

  @Test("a directly-built FROM-less select with clauses is rejected")
  func clauses() throws {
    // The parser never builds a FROM-less select carrying a WHERE, ORDER BY, or
    // JOIN, but `Select.init` is public, so a direct `Select(from: nil, …)` can.
    // The engine must reject it rather than silently drop the clause — a false
    // predicate would otherwise still return the scalar row.
    let fault =
        SQLError.unsupported("a WHERE, ORDER BY, or JOIN requires a FROM clause")
    let filtered = try EngineScalarSelectTests.select(
        "SELECT 1 FROM People WHERE Id = 99")
    #expect(throws: fault) {
      try Engine.run(.select(Select(projection: filtered.projection,
                                    from: nil,
                                    predicate: filtered.predicate)), people())
    }
    let ordered =
        try EngineScalarSelectTests.select("SELECT Id FROM People ORDER BY Id")
    #expect(throws: fault) {
      try Engine.run(.select(Select(projection: ordered.projection, from: nil,
                                    order: ordered.order)), people())
    }
    let joined = try EngineScalarSelectTests.select(
        "SELECT Id FROM People JOIN Pets ON Pets.Owner = People.Id")
    #expect(throws: fault) {
      try Engine.run(.select(Select(projection: joined.projection, from: nil,
                                    joins: joined.joins)), people())
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

  @Test("a FROM-less arm of a UNION combines with a FROM arm")
  func union() throws {
    // Both arms project one integer column; the FROM-less arm contributes its
    // single computed row, deduplicating against the People ages.
    let rows = try Engine.run(parse("""
        SELECT 100 UNION ALL SELECT Age FROM People WHERE Id = 1
        """), people())
    #expect(rows == [[.integer(100)], [.integer(30)]])
  }

  @Test("an existing SELECT … FROM … query is unaffected")
  func regression() throws {
    // The FROM-optional grammar leaves a normal query parsing and running
    // exactly as before.
    let rows = try run("SELECT Name FROM People WHERE Id = 1")
    #expect(rows == [[.text("Alice")]])
  }
}

// MARK: - WITH (non-recursive) tests

/// Parses `text` to a statement and runs it against `catalog`.
private func statement<C: Catalog & ~Escapable>(_ text: String,
                                                _ catalog: borrowing C)
    throws -> Array<Array<Value>> {
  try Engine.run(Statement(parsing: text), catalog)
}

struct EngineWithTests {
  @Test("a non-recursive CTE materialises as an inline view")
  func inline() throws {
    // The CTE `adults` is materialised once and the trailing query reads it
    // like a table — the inline-view shape of a non-recursive WITH.
    let rows = try statement("""
        WITH adults (Key, Label) AS (SELECT Id, Name FROM Parent WHERE Id >= 2)
          SELECT Label FROM adults
        """, family())
    #expect(rows == [[.text("Bee")], [.text("Cid")]])
  }

  @Test("a CTE infers its columns and filters on them")
  func inferred() throws {
    let rows = try statement("""
        WITH grown AS (SELECT Id, Name FROM Parent)
          SELECT Name FROM grown WHERE Id = 3
        """, family())
    #expect(rows == [[.text("Cid")]])
  }

  @Test("a later CTE reads an earlier one (chained CTEs)")
  func chained() throws {
    // `b` resolves `a` — the resolver consults the CTEs materialised so far, so
    // a later member sees an earlier one.
    let rows = try statement("""
        WITH a (Id, Name) AS (SELECT Id, Name FROM Parent WHERE Id >= 2),
             b (Who) AS (SELECT Name FROM a WHERE Id = 3)
          SELECT Who FROM b
        """, family())
    #expect(rows == [[.text("Cid")]])
  }

  @Test("a CTE shadows a base relation of the same name")
  func shadow() throws {
    // `Parent` is a base relation; the CTE of the same name shadows it, so the
    // trailing query reads the CTE's rows, not the base table's.
    let rows = try statement("""
        WITH Parent (Id, Name) AS (SELECT Id, Name FROM Parent WHERE Id = 1)
          SELECT Name FROM Parent
        """, family())
    #expect(rows == [[.text("Ada")]])
  }

  @Test("the trailing query joins a CTE against a base relation")
  func joinBase() throws {
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

  @Test("a CTE's rowid virtual column resolves")
  func rowid() throws {
    let rows = try statement("""
        WITH a (Tag) AS (SELECT Name FROM Parent)
          SELECT rowid, Tag FROM a WHERE rowid = 2
        """, family())
    #expect(rows == [[.integer(2), .text("Bee")]])
  }

  @Test("a CTE column list of the wrong arity is rejected at parse")
  func arity() throws {
    #expect(throws: SQLError.columns(expected: 2, got: 1)) {
      try statement("""
          WITH a (only) AS (SELECT Id, Name FROM Parent) SELECT only FROM a
          """, family())
    }
  }

  @Test("an unknown column of a CTE is reported")
  func unknown() throws {
    #expect(throws: SQLError.column("Missing")) {
      try statement("""
          WITH a (Id) AS (SELECT Id FROM Parent) SELECT Missing FROM a
          """, family())
    }
  }

  @Test("a CTE whose body is a UNION materialises both arms")
  func union() throws {
    let rows = try statement("""
        WITH both (Tag) AS (SELECT Tag FROM Left UNION SELECT Tag FROM Right)
          SELECT Tag FROM both
        """, tags())
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test("a CTE column list wider than its SELECT * body is rejected, not trapped")
  func widthMismatch() throws {
    // `Parent` is a two-column relation, but the column list declares three
    // names; the `SELECT *` body's width is known only after materialisation, so
    // the declared arity is checked against the produced rows and faults with
    // `SQLError.columns` rather than trapping when a later read indexes a cell
    // the row does not have.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try statement("""
          WITH a (x, y, z) AS (SELECT * FROM Parent) SELECT x FROM a
          """, family())
    }
  }

  @Test("a WHERE pushed onto a joined-in CTE filters its rows before the join")
  func joinPushedFilter() throws {
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

  @Test("a WITH RECURSIVE arm that never names the CTE runs once, not to a cap")
  func nonSelfReferentialUnionAll() throws {
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
}

// MARK: - WITH RECURSIVE tests

/// A one-row seed catalog: a `Seed` relation of a single row, the FROM-less
/// `SELECT 1` the dialect lacks expressed as `SELECT 1 FROM Seed`. It also
/// carries an `Edge(Src, Dst)` relation for a transitive-closure test.
private func seed() -> Memory {
  let one = [Field(name: "One", kind: .integer)]
  let seedRows = [[.integer(1)]] as Array<Array<Value>>

  let edge = [
    Field(name: "Src", kind: .integer),
    Field(name: "Dst", kind: .integer),
  ]
  // 1 -> 2 -> 3 -> 4, a simple chain whose closure is every reachable pair.
  let edges = [
    [.integer(1), .integer(2)],
    [.integer(2), .integer(3)],
    [.integer(3), .integer(4)],
  ] as Array<Array<Value>>

  return Memory([
    "Seed": Relation(one, seedRows),
    "Edge": Relation(edge, edges),
  ])
}

/// Routines with an `inc` scalar — `inc(n) = n + 1` — standing in for the `+`
/// the dialect lacks, so a recursive counter can advance.
private func counting() -> Routines {
  Routines().registering("inc") { arguments throws(SQLError) in
    guard case let .integer(n) = arguments.first else {
      throw .argument("inc expects one integer argument")
    }
    return .integer(n + 1)
  }
}

struct EngineRecursiveTests {
  @Test("a recursive counter enumerates 1..5")
  func counter() throws {
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
    let rows = try Engine.run(query, seed(), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test("a recursive counter runs through Engine.run(_:statement:)")
  func statement() throws {
    let rows = try Engine.run(Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c WHERE n < 3
        )
        SELECT n FROM c
        """), seed(), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test("UNION dedups rows a UNION ALL recursion would repeat")
  func dedup() throws {
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
    let rows = try Engine.run(query, seed(), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)]])
  }

  @Test("a bare UNION dedups duplicate anchor seed rows")
  func anchorDedup() throws {
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
    let rows = try Engine.run(query, seed(), counting())
    #expect(rows == [[.integer(1)]])
  }

  @Test("a transitive-closure self-join reaches every descendant")
  func closure() throws {
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
    let rows = try Engine.run(query, seed())
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

  @Test("a runaway recursion is capped with SQLError.recursion")
  func runaway() throws {
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
      try Engine.run(query, seed(), counting())
    }
  }
}
