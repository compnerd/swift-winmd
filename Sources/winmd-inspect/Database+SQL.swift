// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SQL
internal import WinMD

/// The WinMD → SQL-engine adapter.
///
/// The engine plans and executes a `SELECT` against four protocols — `Catalog`,
/// `Table`, `Cursor`, `Row` — knowing nothing of WinMD. This file makes a WinMD
/// database one of those sources, directly: `WinMD.Storage` is the engine's
/// `Catalog`, with the relation, cursor, and row views layered over WinMD's own
/// `~Escapable` scan types. `Storage` carries all a scan reads — the open
/// tables, the heaps, and the present/sorted bitsets — so no escapable
/// descriptor and no raw pointers are needed: a borrowed `Storage` *is* the
/// catalog, and the borrowed views it vends never outlive it.
///
/// Two virtual columns sit past a relation's real fields, at ordinals outside
/// the `SELECT *` range so a `*` never projects them: `rowid` (the SQLite-style
/// 1-based row index) and `parent` (a list-child's owning parent's `rowid`).
/// `rowid` enables foreign-key joins — an FK is a real column holding a
/// `rowid` — and `parent` enables list joins — a list-child relates to its
/// owner through its run rather than a stored key.

// MARK: - Catalog

extension WinMD.Storage: SQL.Catalog {
  /// The relation named `name`, resolved case-insensitively against the open
  /// tables' schema names.
  ///
  /// A `WinMD.Table`'s description is its schema name (e.g. "TypeDef"); a name
  /// the database has no table for yields `nil`, which the engine reports as
  /// `SQLError.relation`.
  @_lifetime(borrow self)
  internal borrowing func table(named name: String) -> WinMDRelation? {
    for index in 0 ..< relations.count {
      if relations[index].description.caseInsensitiveCompare(name)
          == .orderedSame {
        return WinMDRelation(self, relations[index])
      }
    }
    return nil
  }
}

// MARK: - Table

/// A `SQL.Table` over one open WinMD table.
///
/// Its real columns are the table's fields; two virtual columns follow, at
/// ordinals `width` (`rowid`) and `width + 1` (`parent`), past the `SELECT *`
/// extent. A real cell is typed from its field's `ColumnType`: a `#Strings`
/// index is `.text`, every other column (a constant, a foreign-key index,
/// another heap) is `.integer`. A seek is available on `rowid` (a dense 1-based
/// index, trivially monotonic), on `parent` over a list-child (whose owning
/// run is monotonic in row order), and on the table's intrinsic sort key when
/// the database physically sorts the table.
internal struct WinMDRelation: SQL.Table, ~Escapable {
  /// The borrowed storage the relation reads from.
  private let storage: WinMD.Storage

  /// The open WinMD table this relation wraps.
  private let table: WinMD.Table

  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage, _ table: WinMD.Table) {
    self.storage = copy storage
    self.table = table
  }

  /// The number of real columns — the extent of a `SELECT *` projection. The
  /// `rowid` and `parent` virtual columns sit past it.
  internal var width: Int {
    table.schema.fields.count
  }

  /// The real column names, in ordinal order — the schema's field names.
  internal var names: Array<String> {
    var names = Array<String>()
    names.reserveCapacity(table.schema.fields.count)
    for index in 0 ..< table.schema.fields.count {
      names.append("\(table.schema.fields[index].name)")
    }
    return names
  }

  /// The virtual column names, in ordinal order — `rowid` at `width`, `parent`
  /// at `width + 1`.
  internal var virtuals: Array<String> {
    ["rowid", "parent"]
  }

  /// One past the highest ordinal this relation can address — its real `width`
  /// plus the two virtual columns (`rowid` and `parent`) it exposes.
  internal var extent: Int {
    parent + 1
  }

  /// The ordinal of the `rowid` virtual column — the first ordinal past the
  /// real fields.
  private var rowid: Int {
    width
  }

  /// The ordinal of the `parent` virtual column — one past `rowid`.
  private var parent: Int {
    width + 1
  }

  internal func ordinal(of name: String) -> Int? {
    for column in 0 ..< table.schema.fields.count
        where "\(table.schema.fields[column].name)"
                  .caseInsensitiveCompare(name) == .orderedSame {
      return column
    }
    if name.caseInsensitiveCompare("rowid") == .orderedSame {
      return rowid
    }
    if name.caseInsensitiveCompare("parent") == .orderedSame {
      return parent
    }
    return nil
  }

  internal func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? {
    let count = Int(table.rows)

    // `rowid` is a dense 1-based index, so the rows are stored in `rowid` order
    // by construction; the boundary for a value is the value itself (less one
    // for a non-strict `>= value`), clamped to the row count.
    if column == rowid {
      let index = strict ? value : value - 1
      return min(max(index, 0), count)
    }

    // `parent` over a list-child is monotonic in row order — a parent owns a
    // contiguous run of children — so binary-search the rows for the boundary
    // against the computed parent `rowid`.
    if column == parent, let link = WinMDRelation.Link(storage, table) {
      return owners(link, value, count, strict: strict)
    }

    // A real column is seekable only when it is the table's intrinsic sort key
    // and this database physically sorts the table; otherwise the engine scans.
    guard table.schema.key == column,
        storage.sorted & (1 << table.number) != 0 else {
      return nil
    }
    return storage.bound(table, column, value, count, strict: strict)
  }

  /// The partition point of the child rows against a parent `rowid` `value`.
  ///
  /// A child row's `parent` is the 1-based row of its owning parent. The owners
  /// are non-decreasing across the child rows (a parent's run precedes the
  /// next), so the boundary is found by binary search: with `strict` false the
  /// first child whose owner is `>= value`, with `strict` true the first whose
  /// owner is `> value`.
  private func owners(_ link: WinMDRelation.Link, _ value: Int, _ count: Int,
                      strict: Bool) -> Int {
    var lo = 0
    var hi = count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      let owner = storage.owner(of: mid, link)
      if owner < value || (strict && owner == value) {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    return lo
  }

  @_lifetime(borrow self)
  internal borrowing func cursor() -> WinMDCursor {
    WinMDCursor(storage, table, WinMDRelation.Link(storage, table))
  }
}

// MARK: - List navigation

extension WinMDRelation {
  /// A list-child's link to its owning parent: the parent's open table and the
  /// ordinal of the parent's list column (the column whose run names this
  /// child's rows).
  internal struct Link {
    /// The parent's open table.
    internal let parent: WinMD.Table
    /// The ordinal of the parent's list column.
    internal let column: Int

    /// The list link for `child`, or `nil` if `child` is not a list-child of
    /// any of the schema's list relationships.
    ///
    /// The five list relationships are the inverse of the schemas' `List`
    /// tokens: `TypeDef.FieldList`(4)→FieldDef, `TypeDef.MethodList`(5)→
    /// MethodDef, `MethodDef.ParamList`(5)→Param, `EventMap.EventList`(1)→
    /// EventDef, `PropertyMap.PropertyList`(1)→PropertyDef. The parent's open
    /// table is looked up by name among the database's relations; an absent
    /// parent (a database without the owning table) is no link.
    internal init?(_ storage: borrowing WinMD.Storage,
                   _ child: borrowing WinMD.Table) {
      for index in Self.lists.indices
          where Self.lists[index].child
                    .caseInsensitiveCompare(child.description) == .orderedSame {
        for relation in 0 ..< storage.relations.count
            where storage.relations[relation].description
                      .caseInsensitiveCompare(Self.lists[index].parent)
                          == .orderedSame {
          self.parent = storage.relations[relation]
          self.column = Self.lists[index].column
          return
        }
      }
      return nil
    }

    /// The list-child → (parent, list column) map — the inverse of the schemas'
    /// `List` tokens. A relation is matched by its schema name (`description`).
    private static let lists:
        InlineArray<_, (child: String, parent: String, column: Int)> = [
      (child: "FieldDef", parent: "TypeDef", column: 4),
      (child: "MethodDef", parent: "TypeDef", column: 5),
      (child: "Param", parent: "MethodDef", column: 5),
      (child: "EventDef", parent: "EventMap", column: 1),
      (child: "PropertyDef", parent: "PropertyMap", column: 1),
    ]
  }
}

extension WinMD.Storage {
  /// The 1-based `rowid` of the parent that owns the child row at `row`.
  ///
  /// A parent at row `p` owns the children `[parent[col] - 1, next[col] - 1)`,
  /// the runs partitioning the child rows in parent order. Binary-search the
  /// parent rows for the one whose run contains `row`: the last parent whose
  /// 0-based run start is `<= row`. The parent's 1-based `rowid` is `p + 1`.
  internal func owner(of row: Int, _ link: WinMDRelation.Link) -> Int {
    let cursor = WinMD.Cursor(copy self, link.parent)
    var lo = 0
    var hi = cursor.count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      // The parent's list cell is the 1-based start of its child run; less one
      // is the run's 0-based start.
      let start = (cursor[mid]?[link.column] ?? 0) - 1
      if start <= row {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    return lo
  }
}

// MARK: - Cursor

/// A `SQL.Cursor` over the rows of one open WinMD table.
///
/// It wraps WinMD's own `~Escapable` `Cursor` and carries the relation's list
/// link, so the rows it vends can compute the `parent` virtual column.
internal struct WinMDCursor: SQL.Cursor, ~Escapable {
  /// The borrowed storage the cursor reads from.
  private let storage: WinMD.Storage

  /// WinMD's scan over the table's rows.
  private let cursor: WinMD.Cursor

  /// The relation's list link, when it is a list-child.
  private let link: WinMDRelation.Link?

  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage, _ table: WinMD.Table,
               _ link: WinMDRelation.Link?) {
    self.storage = copy storage
    self.cursor = WinMD.Cursor(copy storage, table)
    self.link = link
  }

  internal var count: Int {
    cursor.count
  }

  @_lifetime(copy self)
  internal borrowing func row(_ index: Int) -> WinMDRow? {
    guard let tuple = cursor[index] else { return nil }
    return WinMDRow(tuple, storage, link)
  }
}

// MARK: - Row

/// A `SQL.Row` over one WinMD row.
///
/// A cell is read by ordinal as a typed `Value`: a real ordinal (`< count`)
/// reads the WinMD cell — a `#Strings` heap index resolves through the heap as
/// `.text`, every other column is `.integer`; `rowid` is the 1-based row index
/// 1-based row index; the `parent` virtual ordinal is the owning parent row's
/// 1-based `rowid` (zero for a row no parent owns).
internal struct WinMDRow: SQL.Row, ~Escapable {
  /// The WinMD row this view reads.
  private let tuple: WinMD.Tuple

  /// The borrowed storage the parent navigation reads from.
  private let storage: WinMD.Storage

  /// The relation's list link, when it is a list-child.
  private let link: WinMDRelation.Link?

  @_lifetime(copy tuple, copy storage)
  internal init(_ tuple: borrowing WinMD.Tuple,
                _ storage: borrowing WinMD.Storage,
                _ link: WinMDRelation.Link?) {
    self.tuple = copy tuple
    self.storage = copy storage
    self.link = link
  }

  internal subscript(_ column: Int) -> Value {
    borrowing get {
      // The real fields are `[0, count)`; `rowid` is `count`, `parent` is
      // `count + 1`.
      if column == tuple.count {
        return .integer(tuple.index + 1)
      }
      if column == tuple.count + 1 {
        guard let link else { return .integer(0) }
        return .integer(storage.owner(of: tuple.index, link))
      }
      if case .index(.heap(.string)) = tuple.type(of: column) {
        return .text((try? tuple.string(column)) ?? "")
      }
      return .integer(tuple[column])
    }
  }
}
