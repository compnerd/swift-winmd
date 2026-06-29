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

  init(_ fields: Array<Field>, _ records: Array<Array<Value>>,
       sorted: Int? = nil) {
    self.fields = fields
    self.records = records
    self.sorted = sorted
  }
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
    // Only the relation's sorted column is seekable; anything else falls back
    // to a scan.
    guard relation.sorted == column else { return nil }

    // Partition the ascending column: the first row whose cell is `>= value`
    // (non-strict) or `> value` (strict).
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
  case .scan, .join:
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
  case let .union(left, right, _):
    seeks(left) || seeks(right)
  case .join:
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
  case .scan, .join:
    false
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
