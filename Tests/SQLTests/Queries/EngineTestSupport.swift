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
typealias EngineField = FixtureField
typealias EngineCounter = FixtureCounter
typealias EngineCoded = FixtureCoded
typealias EngineMemory = FixtureCatalog

// MARK: - Fixtures

/// The single-relation catalog: a `People` relation sorted on its `Id` column.
func enginePeople() throws -> EngineMemory {
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
func engineGrades() throws -> EngineMemory {
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
/// `(Id << EngineCoded.bits) | tag` (tag `0` a `TypeDef`, tag `1` another table),
/// sorted ascending; the `Row` decodes it, so the column reads as the target
/// `TypeDef` `Id` (tag `0`) or `NULL` (tag `1`). The raw run brackets one
/// tag's equal value, but the tag-1 rows interleaved by row decode to `NULL`, so
/// a range on the decoded column must not seek the raw boundary — it would
/// return other-tag rows that decode outside the range.
///
/// The `Parent` column is seekable-but-unordered, so it is built directly as a
/// `FixtureRelation` with `coded: 0` — the seekable-unordered marker the fluent
/// `Relation` (whose only marker is `sorted:`) does not spell.
func engineAttributes() -> EngineMemory {
  let fields = [
    EngineField(name: "Parent", type: .integer),
    EngineField(name: "Name", type: .text),
  ]
  // Stored `Parent` = `(Id << 2) | tag` (EngineCoded.bits == 2), ascending.
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
  return EngineMemory(["Attribute": FixtureRelation(fields, records, coded: 0)])
}

/// A wide catalog: a `Wide` relation of ten columns, to prove a query that
/// references only a few of them still works (projection pushdown).
///
/// The ten columns and four rows are generated, so it is built directly as a
/// `FixtureRelation` rather than a literal-per-row fluent `Relation`.
func engineWide() -> EngineMemory {
  let fields = (0 ..< 10).map { EngineField(name: "C\($0)", type: .integer) }
  let records = (0 ..< 4).map { row in
    (0 ..< 10).map { Value.integer(row * 10 + $0) }
  }
  return EngineMemory(["Wide": FixtureRelation(fields, records, sorted: 0)])
}

/// The join catalog: a `Parent` relation sorted on `Id`, an unsorted twin
/// `ParentUnsorted` (same rows, no seekable column), and a `Child` relation
/// whose `Pid` is a foreign key to a parent `Id`. The `Ordered` relation has no
/// stored key — a join on it keys off its virtual `Id`.
func engineFamily() throws -> EngineMemory {
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
func engineViews() throws -> EngineMemory {
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
  return EngineMemory(try engineFamily().catalog, views: catalog.registered)
}

/// A catalog with NULL cells: a `Maybe` relation whose `Note` text column is
/// `NULL` in some rows, to exercise three-valued comparison and `IS [NOT] NULL`.
func engineNullable() throws -> EngineMemory {
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
func engineNullableKeys() throws -> EngineMemory {
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
func engineLineage() throws -> EngineMemory {
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
func engineShared() throws -> EngineMemory {
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
func engineSelect(_ text: String) throws -> Query {
  try engineParse(text)
}

/// Parses `text` to a query, failing on any other statement.
func engineParse(_ text: String) throws -> Query {
  try parse(query: text)
}

/// Runs `text` against the single-relation `People` catalog.
func engineRun(_ text: String) throws -> Array<Array<Value>> {
  try enginePeople().run(engineParse(text))
}

/// Runs `text` against the compound-ordering `Grade` catalog.
func engineGrades(_ text: String) throws -> Array<Array<Value>> {
  try engineGrades().run(engineParse(text))
}

/// Runs `text` against the coded-key `Attribute` catalog.
func engineAttributes(_ text: String) throws -> Array<Array<Value>> {
  try engineAttributes().run(engineParse(text))
}

/// Runs `text` against the join `family` catalog.
func engineJoin(_ text: String) throws -> Array<Array<Value>> {
  try engineFamily().run(engineParse(text))
}

/// Runs `text` against the view catalog.
func engineView(_ text: String) throws -> Array<Array<Value>> {
  try engineViews().run(engineParse(text))
}

/// Runs `text` against the nullable `Maybe` catalog.
func engineNullable(_ text: String) throws -> Array<Array<Value>> {
  try engineNullable().run(engineParse(text))
}

/// Runs `text` against the three-level `lineage` catalog.
func engineLineage(_ text: String) throws -> Array<Array<Value>> {
  try engineLineage().run(engineParse(text))
}
