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
  let adults = try View(select: select("""
      SELECT Id, Name FROM Parent WHERE Id >= 2
      """), columns: ["Key", "Label"])

  // SELECT Parent.Name, Child.Name FROM Parent JOIN Child ON … — a view over a
  // join, its two projected columns exposed as Parent and Kid.
  let pairs = try View(select: select("""
      SELECT Parent.Name, Child.Name FROM Parent
        JOIN Child ON Child.Pid = Parent.Id
      """), columns: ["Parent", "Kid"])

  let catalog = family()
  return Memory(catalog.relations, views: ["Adults": adults, "Pairs": pairs])
}

/// Parses `text` to a `SELECT`, failing on any other statement.
private func select(_ text: String) throws -> Select {
  try parse(text)
}

/// Parses `text` to a `SELECT`, failing on any other statement.
private func parse(_ text: String) throws -> Select {
  guard case let .select(select) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
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

  @Test("a view's definition is optimised — its seekable predicate seeks")
  func optimised() throws {
    // `Adults` is `SELECT Id, Name FROM Parent WHERE Id >= 2`, and `Parent` is
    // sorted on `Id`, so the view's sub-plan must seek that run rather than
    // scanning under a `Select`. Compile and optimise an outer query over the
    // view and inspect the `.derived` leaf: its sub-plan must reach a seeked
    // `.scan` (a non-nil seek) and carry no `.select` over a raw scan.
    let catalog = try views()
    let select = try parse("SELECT Key, Label FROM Adults")
    let plan = try Engine.optimise(Engine.compile(select, catalog), catalog)
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
