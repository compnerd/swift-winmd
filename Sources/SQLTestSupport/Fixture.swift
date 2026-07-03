// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQL

/// An owned, escapable in-memory adapter — the shared fixture store the SQL
/// engine's tests run their queries against.
///
/// The store models a data source entirely in memory: a `FixtureCatalog` over
/// a dictionary of named `FixtureRelation`s and registered `View`s, vending a
/// `FixtureTable`/`FixtureCursor`/`FixtureRow` stack the engine walks through
/// its public adapter protocols. Because the storage is owned rather than
/// borrowed, every conformer omits `@_lifetime` — the same trick a
/// `Span`-backed source would replace with lifetime annotations — which is
/// exactly what a `borrowing Engine.run` admits. It is the proof the engine's
/// protocols admit an owned source as readily as a mapped-file one, and the
/// single copy of the adapter both `EngineTests` and `LimitTests` build
/// fixtures over.

/// A column's name and value kind.
public struct FixtureField: Sendable {
  public let name: String
  public let kind: ValueKind

  public init(name: String, kind: ValueKind) {
    self.name = name
    self.kind = kind
  }
}

/// The coded-index encoding the in-memory harness models — a raw cell is
/// `(Id << bits) | tag`, with the tag in the low `bits` (a real coded
/// index's tag is likewise a small low field, e.g.
/// `HasCustomAttribute.bits == 5`). Two bits keep the fixtures small while
/// still being wide enough that a decoded `Id` past `Int.max >> bits` shifts
/// its high bits out of the word and aliases a real low cell — the truncation
/// `WinMDRelation.bound`'s upper-bound guard
/// rejects and this harness mirrors.
public enum FixtureCoded {
  public static let bits = 2
}

/// A mutable tally of the rows a cursor reads, shared by reference so a test
/// can inspect it after a run. Tests run serially, so the unchecked `Sendable`
/// is sound.
public final class FixtureCounter: @unchecked Sendable {
  public var reads = 0

  public init() {}
}

/// An in-memory relation: a fixed schema plus rows of typed values.
///
/// The `sorted` flag marks a single integral column whose rows are stored in
/// ascending order; `bound` reports a boundary for that column and `nil` for
/// any other, so the engine exercises both the seek path and the scan path.
/// Every relation also exposes a virtual `Id` column — its 1-based row index
/// — at the ordinal just past its real columns, computed by the `Row` rather
/// than stored. This type knows nothing of WinMD — it is the proof the engine
/// is generic.
public struct FixtureRelation: Sendable {
  public let fields: Array<FixtureField>
  public let records: Array<Array<Value>>
  /// The ordinal of the sorted column, or `nil` if the relation is unsorted.
  public let sorted: Int?
  /// A seekable-but-unordered coded column, modelling a decoded coded-index
  /// key (e.g. `CustomAttribute.Parent_TypeDef`): its stored cell is the raw
  /// coded value `(Id << bits) | tag`, physically sorted, and `bound`
  /// brackets it — but the `Row` decodes it (a null reference `Id == 0` or
  /// any non-`0` tag → `NULL`, else its `Id`), so the decoded column is not
  /// monotonic in row order. `ordered` reports `false` for it, so the engine
  /// seeks only an equality and scans a range. The tag occupies
  /// `FixtureCoded.bits` low bits — wide enough (like a real coded index) that
  /// a decoded `Id` past
  /// `Int.max >> FixtureCoded.bits` shifts its high bits entirely out of the
  /// word and aliases a real low cell, the truncation the seek's upper-bound
  /// guard rejects.
  public let coded: Int?

  /// A shared tally the cursor bumps on each row read, or `nil` when a fixture
  /// does not instrument its reads — the proof selection pushdown and hash join
  /// materialise fewer rows.
  public let counter: FixtureCounter?

  public init(_ fields: Array<FixtureField>,
              _ records: Array<Array<Value>>,
              sorted: Int? = nil, coded: Int? = nil,
              counter: FixtureCounter? = nil) {
    self.fields = fields
    self.records = records
    self.sorted = sorted
    self.coded = coded
    self.counter = counter
  }
}

/// A `Catalog` over a dictionary of named relations.
///
/// The adapter is an escapable value, so it conforms to the `~Escapable`
/// protocols by omitting `@_lifetime` on its own methods — a borrowed-storage
/// source would instead annotate them. It is the proof the same protocols admit
/// both a Span-backed source and an owned one.
public struct FixtureCatalog: Catalog {
  public let relations: Dictionary<String, FixtureRelation>
  public let views: Dictionary<String, SQL.View>

  public init(_ relations: Dictionary<String, FixtureRelation>,
              views: Dictionary<String, SQL.View> = [:]) {
    self.relations = relations
    self.views = views
  }

  public func table(named name: String) -> FixtureTable? {
    // Fold the lookup like the engine and the WinMD catalog do, so a query's
    // casing need not match the fixture's declared relation name.
    let folded = name.lowercased()
    return relations.first { $0.key.lowercased() == folded }
        .map { FixtureTable($0.value) }
  }

  public func view(named name: String) -> SQL.View? {
    let folded = name.lowercased()
    return views.first { $0.key.lowercased() == folded }?.value
  }
}

/// A `Table` over one in-memory relation, with a virtual `Id` column.
public struct FixtureTable: Table {
  public let relation: FixtureRelation

  public init(_ relation: FixtureRelation) {
    self.relation = relation
  }

  /// The real columns — `Id` is virtual and excluded from the width, so a
  /// `SELECT *` never yields it.
  public var width: Int { relation.fields.count }

  /// The real column names, in ordinal order.
  public var names: Array<String> { relation.fields.map(\.name) }

  /// The lone virtual `Id` column at ordinal `width`.
  public var virtuals: Array<String> { ["Id"] }

  /// One past the highest ordinal — the real width plus the lone virtual
  /// `Id` column at ordinal `width`.
  public var extent: Int { width + 1 }

  public func ordinal(of name: String) -> Int? {
    // A real column resolves first; `Id` is the virtual column at the ordinal
    // just past the real ones, which a real `Id` column of its own shadows.
    if let real = relation.fields.firstIndex(where: { $0.name == name }) {
      return real
    }
    return name == "Id" ? width : nil
  }

  public func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? {
    // The sorted column seeks against `value` directly; the coded column seeks
    // against the encoded raw cell `(value << FixtureCoded.bits) | 0` — the
    // tag-0 (TypeDef) encoding of the target `Id` — exactly as
    // `WinMDRelation` brackets a decoded coded-index key's equal run in the
    // sorted raw column. A decoded row is 1-based, so the coded column reports
    // no boundary for a non-positive `value`: it is a null reference
    // (`Id == 0`) that no cell equals, so the engine scans and filters
    // rather than seeking the raw run encoding row zero — mirroring
    // `WinMDRelation.bound`'s `value >= 1` guard. It likewise reports no
    // boundary for a `value` past `Int.max >> FixtureCoded.bits`, whose shift
    // would truncate its high bits out of the word and alias a real low cell —
    // mirroring the adapter's upper-bound guard, so the engine scans and
    // filters (the huge value matches no decoded cell) instead of seeking the
    // aliased run. Any other column falls back to a scan.
    let target: Int? = switch column {
    case relation.sorted:
      value
    case relation.coded
        where value >= 1 && value <= Int.max >> FixtureCoded.bits:
      (value << FixtureCoded.bits) | 0
    default:
      nil
    }
    guard let target else { return nil }

    // NULLs sort FIRST in the engine's ascending order, so a sorted column
    // whose leading cell is non-integer holds NULL rows a direct seek would
    // bracket into its range — and the optimiser drops the residual predicate
    // for an equality seek, returning those NULLs as false matches. Abandon
    // the seek so the engine scans and filters, preserving the predicate. An
    // EMPTY relation has no such cell and still seeks (an empty 0 ..< 0 range).
    if let first = relation.records.first {
      guard case .integer = first[column] else { return nil }
    }

    // Partition the (now all-integer) ascending column: the first row whose
    // cell is `>= target` (non-strict) or `> target` (strict).
    return relation.records.partitioning { row in
      guard case let .integer(cell) = row[column] else { return false }
      return strict ? cell > target : cell >= target
    }
  }

  public func ordered(_ column: Int) -> Bool {
    // The coded column is seekable but not ordered — its stored raw cells are
    // sorted, but the value the `Row` decodes is not monotonic in row order, so
    // a range must scan rather than consume a boundary.
    relation.coded != column
  }

  public func cursor() -> FixtureCursor {
    FixtureCursor(relation)
  }
}

/// An index-addressed cursor over a relation's rows.
public struct FixtureCursor: SQL.Cursor {
  public let relation: FixtureRelation

  public init(_ relation: FixtureRelation) {
    self.relation = relation
  }

  public var count: Int { relation.records.count }

  public func row(_ index: Int) -> FixtureRow? {
    guard index < relation.records.count else { return nil }
    relation.counter?.reads += 1
    return FixtureRow(relation, index)
  }
}

/// A positional view over one row's cells, real and virtual.
///
/// A real ordinal (`< width`) reads the stored cell; the virtual `Id`
/// ordinal (`== width`) computes the 1-based row index. The view is an
/// escapable value — no borrowed storage — so it omits `@_lifetime`.
public struct FixtureRow: SQL.Row {
  public let relation: FixtureRelation
  public let index: Int

  public init(_ relation: FixtureRelation, _ index: Int) {
    self.relation = relation
    self.index = index
  }

  public subscript(_ column: Int) -> Value {
    borrowing get {
      if column == relation.fields.count { return .integer(index + 1) }
      // The coded column decodes its raw cell `(Id << FixtureCoded.bits) |
      // tag` the way a coded-index key does: a tag-`0` (TypeDef) cell whose row
      // is non-null yields the target `Id`; any other tag (a cell pointing
      // at a different table) or a null reference (`Id == 0`) yields
      // `NULL` — the same `row == 0` → `NULL` rule `WinMDRow.key` decodes a
      // coded index by.
      if column == relation.coded,
          case let .integer(raw) = relation.records[index][column] {
        let mask = (1 << FixtureCoded.bits) - 1
        return raw & mask == 0 && raw >> FixtureCoded.bits != 0
                 ? .integer(raw >> FixtureCoded.bits)
                 : .null
      }
      return relation.records[index][column]
    }
  }
}
