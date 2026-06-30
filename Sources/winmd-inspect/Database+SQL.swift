// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SQL
internal import WinMDSynthesis
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
/// Virtual columns sit past a relation's real fields, at ordinals outside the
/// `SELECT *` range so a `*` never projects them. Every relation exposes the one
/// universal virtual column, `rowid` (the SQLite-style 1-based row index), at
/// `width`: `rowid` enables foreign-key joins — an FK is a real column holding a
/// `rowid`.
///
/// Three tables expose a further per-table virtual column that decodes
/// WinMD-specific data, at ordinals `width + 1` onward: `ReturnType` on
/// `MethodDef` (the decoded type spelling of the signature's return), `ParamType`
/// on `Param` (the decoded type spelling of the parameter, navigated through its
/// owning method's signature), and `guid` on `CustomAttribute` (the UUID its
/// `Value` blob names, or `NULL` when the blob is not GUID-shaped — the
/// `interfaces` view navigates to a type's `GuidAttribute` and selects this
/// codec to spell its IID). The extras are keyed by the relation's schema name;
/// they are computed in `WinMDRow` and, being decoded rather than stored, are
/// never seekable.
///
/// Past the extras sit a relation's join keys, at ordinals `width + 1 + extras`
/// onward — the columns a view equi-joins across. A list-owned table leads the
/// group with `parent` (the list-child's owning parent's `rowid`), which enables
/// list joins — a list-child relates to its owner through its run rather than a
/// stored key — and a non-list table simply has no `parent` column. The
/// coded-index join keys follow: for every real coded-index column a relation
/// has, one decoded column per candidate target table the coded index admits,
/// named `<ColumnName>_<TargetSchemaName>` (e.g. a `CustomAttribute.Parent` of
/// kind `HasCustomAttribute` admitting `TypeDef` yields `Parent_TypeDef`). Its
/// value is the target's 1-based `rowid` when the cell's coded index tags that
/// target (and is non-null), else SQL `NULL`, so a view can equi-join across a
/// coded index — `JOIN Target ON child.<col>_<Target> = Target.rowid` matches
/// exactly the rows whose coded index points at `Target`. These are derived
/// purely from the schema's coded-index fields and their `CodedIndex.tables`,
/// and — being decoded — are never seekable.

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

// MARK: - Session

/// The interactive shell's mutable state: a `SQL.Catalog` overlaying the
/// session's registered views on a borrowed `WinMD.Storage`.
///
/// The shell lets a session define views (`CREATE VIEW`) and query them. A
/// `Session` borrows the base `storage` and carries the escapable `views` the
/// session has registered, and a `CREATE VIEW` `register`s another.
/// `table(named:)` delegates to the storage, while `view(named:)` resolves the
/// views case-insensitively (relation names resolve case-insensitively
/// elsewhere), so a registered view shadows a base table of the same name. It is
/// the single state model and does no console I/O; `Shell` drives it. It mirrors
/// the `~Escapable`/`@_lifetime(borrow …)` + `copy storage` pattern of
/// `WinMDRelation`, vending the storage's own `WinMDRelation` so the engine plans
/// over the same source.
internal struct Session: SQL.Catalog, ~Escapable {
  /// The borrowed base storage the session's tables read from.
  internal let storage: WinMD.Storage

  /// The views the session has registered, keyed case-folded.
  internal var views: Dictionary<String, View>

  /// Opens a session over `storage` with an explicit `views` set — the seam a
  /// test drives to register a custom or overriding view set.
  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage,
                _ views: Dictionary<String, View>) {
    self.storage = copy storage
    self.views = views
  }

  /// Registers `view` under `name` (case-folded, the way `view(named:)`
  /// resolves it) — the `CREATE VIEW` path.
  internal mutating func register(_ name: String, _ view: View) {
    views[name.lowercased()] = view
  }

  @_lifetime(borrow self)
  internal borrowing func table(named name: String) -> WinMDRelation? {
    storage.table(named: name)
  }

  internal borrowing func view(named name: String) -> View? {
    views[name.lowercased()]
  }
}

// MARK: - Table

/// A `SQL.Table` over one open WinMD table.
///
/// Its real columns are the table's fields; the virtual columns follow, past the
/// `SELECT *` extent: `rowid` at `width`, then the table's per-table decoded
/// extras (`ReturnType`/`ParamType`/`guid`) at `width + 1` onward, then the join
/// keys — `parent` (on a list-owned table only) leading the coded-index join
/// keys. A real cell is typed from its field's `ColumnType`: a `#Strings` index
/// is `.text`, every other column (a constant, a foreign-key index, another
/// heap) is `.integer`. A seek is available on `rowid` (a dense 1-based index,
/// trivially monotonic), on `parent` over a list-child (whose owning run is
/// monotonic in row order), and on the table's intrinsic sort key when the
/// database physically sorts the table; the decoded extras are not seekable.
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

  /// The virtual column names, in ordinal order — `rowid` at `width`, this
  /// table's decoded extras at `width + 1` onward, then its join keys: `parent`
  /// (on a list-owned table only) leading the coded-index join keys.
  internal var virtuals: Array<String> {
    let parent = WinMDRelation.Link(storage, table) == nil ? [] : ["parent"]
    return ["rowid"] // the universal identity, at `width`
        + extras // decoded codec columns
        + parent // the list-ownership key, present only on a list-owned table
        + keys.map(\.name) // coded-index join keys
  }

  /// One past the highest ordinal this relation can address — its real `width`
  /// plus the universal `rowid`, this table's decoded extras, and its join keys
  /// (`parent` when list-owned, then the coded-index join keys).
  internal var extent: Int {
    width // real fields
        + 1 // `rowid`
        + extras.count // decoded codec columns
        + (WinMDRelation.Link(storage, table) == nil ? 0 : 1) // `parent`
        + keys.count // coded-index join keys
  }

  /// The ordinal of the `rowid` virtual column — the first ordinal past the
  /// real fields.
  private var rowid: Int {
    width
  }

  /// The ordinal of the `parent` virtual column on a list-owned table — the
  /// first join-key ordinal, past `rowid` and the decoded extras — or `nil` when
  /// the table owns no list (it then has no `parent` column).
  private var parent: Int? {
    WinMDRelation.Link(storage, table) == nil
        ? nil
        : width + 1 + extras.count
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
    // The decoded extras follow `rowid`: extra `i` sits at `rowid + 1 + i`.
    let extras = self.extras
    for index in extras.indices
        where extras[index].caseInsensitiveCompare(name) == .orderedSame {
      return rowid + 1 + index
    }
    // The join keys follow the extras. `parent` (on a list-owned table) leads
    // them; the coded-index join keys follow at `parent + 1` onward (or, on a
    // non-list table, at the first join-key ordinal).
    let base = rowid + 1 + extras.count
    if let parent, name.caseInsensitiveCompare("parent") == .orderedSame {
      return parent
    }
    let keys = self.keys
    let lead = parent == nil ? base : base + 1
    for index in keys.indices
        where keys[index].name.caseInsensitiveCompare(name) == .orderedSame {
      return lead + index
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

// MARK: - Per-table extras

extension WinMDRelation {
  /// The decoded extra virtual column names of this relation's table, in
  /// ordinal order — the single source of truth `virtuals`, `extent`, `parent`,
  /// and `ordinal(of:)` derive from (keyed by the table's schema name, through
  /// the shared `extras(of:)` core).
  ///
  /// Three tables decode a WinMD-specific column past `rowid`: `MethodDef` a
  /// `ReturnType` (the signature's decoded return), `Param` a `ParamType` (the
  /// parameter's decoded type), and `CustomAttribute` a `guid` (the GUID its
  /// `Value` blob names, for the `GuidAttribute` rows the `interfaces` view
  /// selects). Every other table exposes only `rowid` and `parent`, so it has
  /// no extras. `WinMDRow.extras` computes the same list by the same keying.
  internal var extras: Array<String> {
    WinMDRelation.extras(of: table.description)
  }

  /// The decoded extra virtual column names of the table named `schema`, keyed
  /// by its schema name — the shared core `WinMDRelation.extras` and
  /// `WinMDRow.extras` both derive from, so a row (which carries only its
  /// schema name) and a relation (which carries the open table) yield the same
  /// extras.
  internal static func extras(of schema: String) -> Array<String> {
    switch schema {
    case "MethodDef":       ["ReturnType"]
    case "Param":           ["ParamType"]
    case "CustomAttribute": ["guid"]
    default:                Array<String>()
    }
  }
}

// MARK: - Coded-index join keys

extension WinMDRelation {
  /// A decoded coded-index join key: a real coded-index column resolved against
  /// one of the candidate target tables the coded index admits.
  ///
  /// The `column` is the ordinal of the real coded-index field, `kind` the
  /// coded index it encodes, `tag` the position of `target` within the index's
  /// tables (the tag a cell carries when it points at `target`), and `name` the
  /// `<ColumnName>_<TargetSchemaName>` the join key is exposed under. A cell
  /// whose decoded tag is `tag` and whose row is non-null yields that row's
  /// 1-based `rowid` in `target`; any other cell yields SQL `NULL`.
  internal struct Key {
    /// The ordinal of the real coded-index column.
    internal let column: Int
    /// The coded index the column encodes.
    internal let kind: CodedIndex.Type
    /// The tag selecting `target` among the coded index's tables.
    internal let tag: Int
    /// The candidate target table the key navigates to.
    internal let target: TableSchema.Type
    /// The join key's exposed name, `<ColumnName>_<TargetSchemaName>`.
    internal let name: String

    /// The join keys a single coded-index `column` named `name` of kind `kind`
    /// admits — one per non-nil candidate target table, tagged by its position
    /// in `kind.tables` and named `<name>_<TargetSchemaName>`. The shared
    /// per-column expansion `WinMDRelation.keys` and `WinMDRow.keys` both build
    /// their list from.
    internal static func all(column: Int, named name: String,
                             kind: CodedIndex.Type) -> Array<Key> {
      var keys = Array<Key>()
      for tag in 0 ..< kind.tables.count {
        guard let target = kind.tables[tag] else { continue }
        keys.append(Key(column: column, kind: kind, tag: tag, target: target,
                        name: "\(name)_\(target)"))
      }
      return keys
    }
  }

  /// The coded-index join keys of this relation's table, in ordinal order — the
  /// single source of truth `virtuals`, `ordinal(of:)`, and `WinMDRow` derive
  /// from (the last via the shared `Key.all` expansion).
  ///
  /// For every real coded-index field (a column whose `ColumnType` is
  /// `.index(.coded(kind))`), one key per candidate target table the coded
  /// index admits (the non-nil entries of `kind.tables`), ordered by field
  /// ordinal then by the target's tag within `kind.tables`. The naming is
  /// `<ColumnName>_<TargetSchemaName>`. Schema-driven: no table or column is
  /// special-cased.
  internal var keys: Array<Key> {
    let fields = table.schema.fields
    var keys = Array<Key>()
    for column in 0 ..< fields.count {
      guard case let .index(.coded(kind)) = fields[column].type else {
        continue
      }
      keys.append(contentsOf:
          Key.all(column: column, named: "\(fields[column].name)", kind: kind))
    }
    return keys
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
    return WinMDRow(tuple, storage, link, cursor.relation.description)
  }
}

// MARK: - Row

/// A `SQL.Row` over one WinMD row.
///
/// A cell is read by ordinal as a typed `Value`: a real ordinal (`< count`)
/// reads the WinMD cell — a `#Strings` heap index resolves through the heap as
/// `.text`, every other column is `.integer`; `rowid` (`count`) is the 1-based
/// row index; a per-table extra ordinal (`count + 1` onward) decodes the table's
/// WinMD-specific column (`ReturnType`/`ParamType`/`guid`); and the join keys
/// follow the extras — on a list-owned table the `parent` ordinal is the owning
/// parent row's 1-based `rowid` (zero for a row no parent owns) and the
/// coded-index join keys follow it, while on a non-list table the coded-index
/// join keys follow the extras directly. A coded-index join-key ordinal decodes
/// a coded-index cell to the target's 1-based `rowid`, or SQL `NULL` when the
/// cell points elsewhere or is null.
internal struct WinMDRow: SQL.Row, ~Escapable {
  /// The WinMD row this view reads.
  private let tuple: WinMD.Tuple

  /// The borrowed storage the parent navigation reads from.
  private let storage: WinMD.Storage

  /// The relation's list link, when it is a list-child.
  private let link: WinMDRelation.Link?

  /// The relation's schema name — the key for this table's decoded extras
  /// (`WinMD.Tuple` does not expose its table's name, so it is carried in).
  private let schema: String

  @_lifetime(copy tuple, copy storage)
  internal init(_ tuple: borrowing WinMD.Tuple,
                _ storage: borrowing WinMD.Storage,
                _ link: WinMDRelation.Link?, _ schema: String) {
    self.tuple = copy tuple
    self.storage = copy storage
    self.link = link
    self.schema = schema
  }

  internal subscript(_ column: Int) -> Value {
    borrowing get {
      // The real fields are `[0, count)`; `rowid` is `count`, the decoded extras
      // are `count + 1` onward, then the join keys.
      if column == tuple.count {
        return .integer(tuple.index + 1)
      }
      if column > tuple.count {
        // Past `rowid`: the decoded extras occupy `[0, extras.count)` of the
        // virtual range, then the join keys. On a list-owned table `parent`
        // leads the join keys (the owning parent's 1-based `rowid`, zero for a
        // row no parent owns) and the coded-index join keys follow it; on a
        // non-list table the coded-index join keys follow the extras directly.
        let extras = self.extras.count
        let virtual = column - (tuple.count + 1)
        if virtual < extras { return extra(virtual) }
        let key = virtual - extras
        guard let link else { return self.key(key) }
        return key == 0
            ? .integer(storage.owner(of: tuple.index, link))
            : self.key(key - 1)
      }
      if case .index(.heap(.string)) = tuple.type(of: column) {
        return .text((try? tuple.string(column)) ?? "")
      }
      return .integer(tuple[column])
    }
  }

  /// The decoded extra virtual column names of this row's table, in ordinal
  /// order — the schema-keyed sibling of `WinMDRelation.extras`, so a row
  /// (which carries only its schema name) derives the same extras a relation
  /// does from the open table (both through the shared
  /// `WinMDRelation.extras(of:)` core).
  private var extras: Array<String> {
    WinMDRelation.extras(of: schema)
  }

  /// The decoded value of this table's `index`th extra virtual column.
  ///
  /// The extras are keyed by the table's schema name (the same keying `extras`
  /// exposes); each decodes its WinMD-specific cell. An out-of-range index — no
  /// such extra — is SQL `NULL`.
  private func extra(_ index: Int) -> Value {
    switch (schema, index) {
    case ("MethodDef", 0):       returns()
    case ("Param", 0):           parameter()
    case ("CustomAttribute", 0): guid()
    default:                     .null
    }
  }

  /// The coded-index join keys of this row's tuple, in ordinal order — the
  /// tuple-derived sibling of `WinMDRelation.keys`, so a row (which carries only
  /// its `Tuple`) derives the same keys, in the same order, a relation does from
  /// the open table (both through the shared `Key.all` expansion).
  private var keys: Array<WinMDRelation.Key> {
    var keys = Array<WinMDRelation.Key>()
    for column in 0 ..< tuple.count {
      guard case let .index(.coded(kind)) = tuple.type(of: column) else {
        continue
      }
      keys.append(contentsOf: WinMDRelation.Key
          .all(column: column, named: "\(tuple.name(of: column))", kind: kind))
    }
    return keys
  }

  /// The decoded value of this row's `index`th coded-index join key.
  ///
  /// The keys are derived from the tuple's coded-index fields, in the order
  /// `keys` exposes them. The key's column cell is decoded as its coded index;
  /// when the cell's tag selects the key's target table and its row is
  /// non-null, the value is that 1-based row (the target relation's `rowid`),
  /// so a view can equi-join on it. A cell pointing at another target, a null
  /// reference (`row == 0`), or an out-of-range index is SQL `NULL`.
  private func key(_ index: Int) -> Value {
    let keys = self.keys
    guard index >= 0, index < keys.count else { return .null }
    let key = keys[index]
    let value = key.kind.init(rawValue: tuple[key.column])
    guard value.tag == key.tag, value.row != 0 else { return .null }
    return .integer(value.row)
  }

  /// The `guid` extra of a `CustomAttribute` row — the UUID its `Value` blob
  /// names, decoded as an ECMA-335 §II.23.3 `GuidAttribute` value, or SQL
  /// `NULL` when the blob is not GUID-shaped.
  ///
  /// A pure per-row codec: the `interfaces` view selects it only on the rows it
  /// has already navigated to a `GuidAttribute`, so a non-Guid attribute's
  /// non-GUID blob simply yields `NULL`.
  private func guid() -> Value {
    guard let column = tuple.ordinal(for: "Value"),
        let uuid = try? tuple.iid(column) else {
      return .null
    }
    return .text("\(uuid)")
  }

  /// The `ReturnType` extra of a `MethodDef` row — the decoded type spelling of
  /// the signature's return, or SQL `NULL` when the signature does not decode.
  private func returns() -> Value {
    guard let row = Row<Metadata.Tables.MethodDef>(tuple),
        let signature = try? row.prototype else {
      return .null
    }
    guard let resolver = try? Resolver(of: signature, with: storage) else {
      return .null
    }
    return .text(signature.returns.decode(with: resolver))
  }

  /// The `ParamType` extra of a `Param` row — the decoded type spelling of the
  /// parameter, navigated through its owning method's signature.
  ///
  /// The `Param.Sequence` cell is the 1-based parameter position; `Sequence == 0`
  /// is the return pseudo-parameter and `Sequence > parameters.count` is out of
  /// range, both SQL `NULL`. The owning `MethodDef` is the `parent` virtual
  /// column's row, opened through the list `link`.
  private func parameter() -> Value {
    guard let link,
        let sequence = tuple.ordinal(for: "Sequence") else { return .null }
    let position = tuple[sequence]
    // The owning `MethodDef` is the `parent` virtual column's row (its 1-based
    // `rowid`), opened positionally through the list link's parent table. An
    // owner of zero is no parent (malformed/partial metadata: an empty
    // `MethodDef` table, or a first `ParamList` past this row), so the
    // parameter is unowned and yields SQL `NULL` rather than indexing a
    // negative row through the cursor.
    let owner = storage.owner(of: tuple.index, link)
    guard owner != 0 else { return .null }
    let cursor = WinMD.Cursor(storage, link.parent)
    guard let method = cursor[owner - 1],
        let row = Row<Metadata.Tables.MethodDef>(method),
        let signature = try? row.prototype else {
      return .null
    }
    // `Sequence == 0` is the return parameter; `Sequence == N` is the 1-based
    // `parameters[N - 1]`. Anything outside that range yields SQL `NULL`.
    guard position >= 1, position <= signature.parameters.count else {
      return .null
    }
    guard let resolver = try? Resolver(of: signature, with: storage) else {
      return .null
    }
    // The parameter's own `Name` is the `System.Guid` `IID`/`CLSID` hint; for
    // any other type the decoder ignores it, so passing it is always safe.
    let name = tuple.ordinal(for: "Name").flatMap { try? tuple.string($0) }
    return .text(signature.parameters[position - 1]
        .decode(parameter: name, with: resolver))
  }
}
