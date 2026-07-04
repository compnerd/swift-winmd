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
/// universal virtual column, `Id` (the 1-based row identity), at `width`: `Id`
/// enables foreign-key joins — an FK is a real column holding an `Id`.
///
/// WinMD-specific decodes are *not* virtual columns. A real `#Blob` cell is
/// surfaced as a `.blob` (its raw heap bytes), and the decode is a scalar UDF
/// over it: the `GUID` UDF takes a `CustomAttribute.Value` blob and returns the
/// UUID it names as text, or `NULL` when the blob is not GUID-shaped — the
/// `interfaces` view selects `GUID(c.Value)` to spell a type's IID. Type
/// spellings likewise are not virtual columns: they are language-specific, so
/// the adapter — the neutral conceptual layer — does not bake them. The render
/// spells a return/parameter at render time through the `WinMD.Storage`
/// `decode(return:in:)`/`decode(parameter:for:)` methods, which navigate a
/// method/parameter's signature and apply a target `Dialect`.
///
/// Past `Id` sit a relation's join keys, at ordinals `width + 1` onward —
/// the columns a view equi-joins across. A list-owned table leads the group
/// with its owner foreign key — a column named for the owning table (e.g. a
/// `MethodDef`'s `TypeDef`), whose value is the owning row's `Id` — which
/// enables list joins — a list-child relates to its owner through its run
/// rather than a stored key — and a non-list table simply has no owner column.
/// The coded-index join keys follow: for every real coded-index column a
/// relation has, one decoded column per candidate target table the coded index
/// admits, named `<ColumnName>_<TargetSchemaName>` (e.g. a
/// `CustomAttribute.Parent` of kind `HasCustomAttribute` admitting `TypeDef`
/// yields `Parent_TypeDef`). Its value is the target's 1-based `Id` when the
/// cell's coded index tags that target (and is non-null), else SQL `NULL`, so a
/// view can equi-join across a coded index — `JOIN Target ON
/// child.<col>_<Target> = Target.Id` matches exactly the rows whose coded index
/// points at `Target`. These are derived purely from the schema's coded-index
/// fields and their `CodedIndex.tables`, and — being decoded — are never
/// seekable.

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
    for index in 0 ..< tables.count {
      if tables[index].description.caseInsensitiveCompare(name)
          == .orderedSame {
        return WinMDRelation(self, tables[index])
      }
    }
    return nil
  }

  /// The schema names of every open table — the `INFORMATION_SCHEMA` overlay's
  /// base-relation enumeration, mapped from the database's open relations.
  internal borrowing func relations() -> Array<String> {
    var names = Array<String>()
    names.reserveCapacity(tables.count)
    for index in 0 ..< tables.count {
      names.append("\(tables[index].description)")
    }
    return names
  }
}

// MARK: - Session

/// The interactive shell's mutable state: a `SQL.Catalog` overlaying the
/// session's registered views on a borrowed `WinMD.Storage`.
///
/// The shell lets a session define views (`CREATE VIEW`) and query them. A
/// `Session` borrows the base `storage` and carries the escapable `views` the
/// session has registered — seeded at `init` with the bundled COM-interface
/// views — and a `CREATE VIEW` `register`s another. `table(named:)` delegates to
/// the storage, while `view(named:)` resolves the views case-insensitively
/// (relation names resolve case-insensitively elsewhere), so a registered view
/// shadows a base table of the same name. It is the single state model and does
/// no console I/O; `Shell` drives it. It mirrors the `~Escapable`/`@_lifetime(
/// borrow …)` + `copy storage` pattern of `WinMDRelation`, vending the storage's
/// own `WinMDRelation` so the engine plans over the same source.
internal struct Session: SQL.Catalog, ~Escapable {
  /// The borrowed base storage the session's tables read from.
  internal let storage: WinMD.Storage

  /// The views the session has registered, keyed case-folded.
  internal var registered: Dictionary<String, View>

  /// Opens a session over `storage`, seeding the bundled COM-interface views —
  /// or, where a `-I` `search` directory shadows or adds one, its view.
  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage,
                search: Array<String> = []) {
    self.storage = copy storage
    self.registered = Session.bundled(search: search)
  }

  /// Opens a session over `storage` with an explicit `views` set — the seam a
  /// test drives to register a custom or overriding view set without the
  /// bundled seed.
  @_lifetime(borrow storage)
  internal init(_ storage: borrowing WinMD.Storage,
                _ views: Dictionary<String, View>) {
    self.storage = copy storage
    self.registered = views
  }

  /// Registers `view` under `name` (case-folded, the way `view(named:)`
  /// resolves it) — the `CREATE VIEW` path.
  internal mutating func register(_ name: String, _ view: View) {
    registered[name.lowercased()] = view
  }

  @_lifetime(borrow self)
  internal borrowing func table(named name: String) -> WinMDRelation? {
    storage.table(named: name)
  }

  internal borrowing func view(named name: String) -> View? {
    registered[name.lowercased()]
  }

  /// The base relations the session exposes — the storage's open tables, the
  /// same set `table(named:)` resolves against.
  internal borrowing func relations() -> Array<String> {
    storage.relations()
  }

  /// The names of the views the session registers — the registered and bundled
  /// set `view(named:)` resolves, so the `INFORMATION_SCHEMA` overlay lists
  /// them with a `'VIEW'` table type beside the base `relations()`. The stored
  /// map is keyed case-folded; a view's own declared name is not retained, so
  /// the folded keys are the names the overlay reports.
  internal borrowing func views() -> Array<String> {
    Array(registered.keys)
  }
}

// MARK: - WinMD scalar UDFs

extension Session {
  /// The WinMD-domain scalar UDFs a query resolves against — the decode
  /// primitives the adapter surfaces over its `.blob` columns rather than
  /// baking as decoded virtual columns.
  ///
  /// The `GUID(blob)` entry decodes a `CustomAttribute.Value` blob to the UUID
  /// it names; the bundled `interfaces` view selects it to spell a type's IID.
  /// It is an escapable, value → value function — no borrowed storage — so it
  /// threads through the interactive `Session.run` and merges into the render's
  /// language routines uniformly. The engine's standard-library prelude
  /// (`Routines.standard`, e.g. `BITAND`) is folded in here so it reaches the
  /// session and render paths, which pass these routines EXPLICITLY rather than
  /// relying on the engine's default seeding.
  internal static var routines: Routines {
    // `GUID` returns the UUID as text, so it is declared `.text` — the result
    // type the schema walk and the `INFORMATION_SCHEMA` `data_type` a view's
    // `GUID(...)` column reports read.
    Routines.standard.registering("guid", returns: .text, Session.guid)
  }

  /// `GUID(blob)` — the UUID a `GuidAttribute` `CustomAttribute` value blob
  /// names, as its canonical text, or `NULL` when the blob is not GUID-shaped.
  ///
  /// A pure per-row codec, the value → value form of the WinMD `iid` decode:
  /// the `interfaces` view applies it only to the rows it has already navigated
  /// to a `GuidAttribute`, so a non-GUID blob simply yields `NULL` (preserving
  /// the old `guid` virtual column's NULL-on-mismatch behaviour). A NULL
  /// argument propagates to NULL; a non-blob argument is `SQLError.argument`.
  private static func guid(_ arguments: Array<Value>)
      throws(SQLError) -> Value {
    guard arguments.count == 1 else {
      throw .argument("GUID takes one argument")
    }
    if case .null = arguments[0] { return .null }
    guard case let .blob(bytes) = arguments[0] else {
      throw .argument("GUID requires a blob argument")
    }
    guard let uuid = try? WinMD.iid(decoding: bytes) else { return .null }
    return .text("\(uuid)")
  }
}

// MARK: - Table

/// A `SQL.Table` over one open WinMD table.
///
/// Its real columns are the table's fields; the virtual columns follow, past the
/// `SELECT *` extent: `Id` at `width`, then the join keys — the owner foreign
/// key (on a list-owned table only) leading the coded-index join keys. A real
/// cell is typed from its field's `ColumnType`: a `#Strings` index is `.text`,
/// a `#Blob` index is a `.blob`, every other column (a constant, a foreign-key
/// index, another heap) is `.integer`. A seek is available on `Id` (a dense
/// 1-based index, trivially monotonic), on the owner foreign key over a
/// list-child (whose owning run is monotonic in row order), and on the table's
/// intrinsic sort key when the database physically sorts the table.
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
  /// `Id` and owner-foreign-key virtual columns sit past it.
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

  /// The value type of each real field, in ordinal order — mirroring how a
  /// `WinMDRow` cell decides its `Value`: a `#Strings` heap index is `.text`, a
  /// `#Blob` heap index a `.blob`, every other column (a constant, a
  /// foreign-key index, another heap) an `.integer`. The virtual columns are
  /// not typed here.
  internal var types: Array<ValueType> {
    var types = Array<ValueType>()
    types.reserveCapacity(table.schema.fields.count)
    for index in 0 ..< table.schema.fields.count {
      switch table.schema.fields[index].type {
      case .index(.heap(.string)):
        types.append(.text)
      case .index(.heap(.blob)):
        types.append(.blob)
      default:
        types.append(.integer)
      }
    }
    return types
  }

  /// The virtual column names, in ordinal order — `Id` at `width`, then its
  /// join keys: the owner foreign key (on a list-owned table only) leading the
  /// coded-index join keys.
  internal var virtuals: Array<String> {
    let owner = self.owner.map { [$0] } ?? [] // the list-ownership key
    return ["Id"] // the universal identity, at `width`
        + owner // present only on a list-owned table
        + keys.map(\.name) // coded-index join keys
  }

  /// One past the highest ordinal this relation can address — its real `width`
  /// plus the universal `Id` and its join keys (the owner foreign key when
  /// list-owned, then the coded-index join keys).
  internal var extent: Int {
    width // real fields
        + 1 // `Id`
        + (owner == nil ? 0 : 1) // the owner foreign key
        + keys.count // coded-index join keys
  }

  /// The ordinal of the `Id` virtual column — the first ordinal past the
  /// real fields.
  private var id: Int {
    width
  }

  /// The name of the owner foreign-key column on a list-owned table — the
  /// owning table's schema name (e.g. `TypeDef` for a `MethodDef`) — or `nil`
  /// when the table owns no list (it then has no owner column).
  ///
  /// The name comes straight from the list `Link`'s parent table, so it never
  /// collides with a real field: no list-child schema carries a field spelled
  /// like its owner's table.
  private var owner: String? {
    WinMDRelation.Link(storage, table)
        .map { "\($0.parent.description)" }
  }

  /// The ordinal of the owner foreign-key column on a list-owned table — the
  /// first join-key ordinal, immediately past `Id` — or `nil` when the table
  /// owns no list (it then has no owner column).
  private var owned: Int? {
    owner == nil ? nil : width + 1
  }

  internal func ordinal(of name: String) -> Int? {
    for column in 0 ..< table.schema.fields.count
        where "\(table.schema.fields[column].name)"
                  .caseInsensitiveCompare(name) == .orderedSame {
      return column
    }
    if name.caseInsensitiveCompare("Id") == .orderedSame {
      return id
    }
    // The join keys follow `Id`. The owner foreign key (on a list-owned table)
    // leads them; the coded-index join keys follow at `owned + 1` onward (or,
    // on a non-list table, at the first join-key ordinal).
    let base = id + 1
    if let owner, let owned,
        name.caseInsensitiveCompare(owner) == .orderedSame {
      return owned
    }
    let keys = self.keys
    let lead = owned == nil ? base : base + 1
    for index in keys.indices
        where keys[index].name.caseInsensitiveCompare(name) == .orderedSame {
      return lead + index
    }
    return nil
  }

  internal func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? {
    let count = Int(table.rows)

    // `Id` is a dense 1-based index, so the rows are stored in `Id` order
    // by construction; the boundary for a value is the value itself (less one
    // for a non-strict `>= value`), clamped to the row count.
    if column == id {
      let index = strict ? value : value - 1
      return min(max(index, 0), count)
    }

    // The owner foreign key over a list-child is monotonic in row order — an
    // owner owns a contiguous run of children — so binary-search the rows for
    // the boundary against the computed owner `Id`.
    if column == owned, let link = WinMDRelation.Link(storage, table) {
      return owners(link, value, count, strict: strict)
    }

    // A coded-index join key seeks when its underlying raw coded-index column is
    // the table's intrinsic sort key and the database physically sorts the table
    // (e.g. `CustomAttribute.Parent`, on which the table is sorted): a target
    // `Id` `value` encodes to the raw coded cell `(value << bits) | tag`,
    // whose equal run the raw column's binary search brackets. The join's own
    // equality re-tests the decoded key per row, so the seek need only bracket
    // the run — its precision is an optimisation, not a correctness burden.
    //
    // A decoded row is 1-based, so only `value >= 1` is a valid target Id: a
    // non-positive `value` is a null coded-index reference (`WinMDRow.key`
    // decodes any coded index whose row is zero as SQL `NULL`), which no cell can
    // equal — `NULL = 0` is UNKNOWN. Returning `nil` for it defers to a full
    // scan + filter, where the decoded `NULL` correctly fails the comparison,
    // rather than seeking the raw run that encodes row zero (which `Catalog.seek`
    // would consume without a residual recheck, leaking those rows).
    //
    // The upper bound `value <= Int.max >> key.kind.bits` rejects a decoded
    // Id too large to encode without truncation: Swift's `<<` discards the
    // bits shifted past the word, so a larger `value` would alias `encoded` to a
    // real raw coded cell (e.g. with `bits == 5`, `(1 << 59) + 1` encodes to raw
    // `35`, the same cell as `TypeDef` row 1), and `Catalog.seek` would consume
    // the standalone equality without a residual recheck and return the aliased
    // run. Below the bound `value << bits` fits in `Int` and `| tag` only sets
    // the low bits the shift cleared (`tag < 2^bits`), so `encoded <= Int.max`.
    // Returning `nil` for an unencodable `value` defers to a full scan + filter,
    // which rejects it (no real decoded key equals the huge value).
    if let key = key(for: column), value >= 1,
        value <= Int.max >> key.kind.bits, key.column == table.schema.key,
        storage.sorted & (1 << table.number) != 0 {
      let encoded = (value << key.kind.bits) | key.tag
      return storage.bound(table, key.column, encoded, count, strict: strict)
    }

    // A real column is seekable only when it is the table's intrinsic sort key
    // and this database physically sorts the table; otherwise the engine scans.
    guard table.schema.key == column,
        storage.sorted & (1 << table.number) != 0 else {
      return nil
    }
    return storage.bound(table, column, value, count, strict: strict)
  }

  /// A coded-index join key is seekable but not ordered: its `bound` brackets
  /// the raw coded run for one tag, yet the raw column interleaves the other
  /// tags by row (which decode to `NULL` for this key), so the decoded column
  /// is not monotonic. A range must not consume its boundary — the engine seeks
  /// its equality (the join re-tests per row) and scans a range. Every other
  /// column is ordered where it is seekable.
  internal func ordered(_ column: Int) -> Bool {
    key(for: column) == nil
  }

  /// The coded-index join `Key` exposed at ordinal `column`, or `nil` when
  /// `column` is not one of this table's coded-index join keys.
  ///
  /// The coded-index join keys occupy the ordinals past `Id` and — on a
  /// list-owned table — the owner foreign key, in the order `keys` exposes
  /// them; this maps `column` back through that layout, the inverse of
  /// `ordinal(of:)`'s coded-index-key arm.
  private func key(for column: Int) -> Key? {
    let base = id + 1
    let lead = owned == nil ? base : base + 1
    let index = column - lead
    let all = keys
    guard index >= 0, index < all.count else { return nil }
    return all[index]
  }

  /// The partition point of the child rows against an owner `Id` `value`.
  ///
  /// A child row's owner is the 1-based row of its owning parent. The owners
  /// are non-decreasing across the child rows (an owner's run precedes the
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
  /// 1-based `Id` in `target`; any other cell yields SQL `NULL`.
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
        for relation in 0 ..< storage.tables.count
            where storage.tables[relation].description
                      .caseInsensitiveCompare(Self.lists[index].parent)
                          == .orderedSame {
          self.parent = storage.tables[relation]
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
  /// The 1-based `Id` of the parent that owns the child row at `row`.
  ///
  /// A parent at row `p` owns the children `[parent[col] - 1, next[col] - 1)`,
  /// the runs partitioning the child rows in parent order. Binary-search the
  /// parent rows for the one whose run contains `row`: the last parent whose
  /// 0-based run start is `<= row`. The parent's 1-based `Id` is `p + 1`.
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
/// link, so the rows it vends can compute the owner foreign-key column.
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
/// `.text`, a `#Blob` heap index as an owning `.blob` (the raw heap payload,
/// for a scalar UDF such as `GUID` to decode), every other column `.integer`;
/// `Id` (`count`) is the 1-based row index; and the join keys follow it — on
/// a list-owned table the owner foreign-key ordinal is the owning parent row's
/// 1-based `Id` (zero for a row no owner claims) and the coded-index join keys
/// follow it, while on a non-list table the coded-index join keys follow `Id`
/// directly. A coded-index join-key ordinal decodes a coded-index cell to the
/// target's 1-based `Id`, or SQL `NULL` when the cell points elsewhere or is
/// null.
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
      // The real fields are `[0, count)`; `Id` is `count`, then the join
      // keys follow it.
      if column == tuple.count {
        return .integer(tuple.index + 1)
      }
      if column > tuple.count {
        // Past `Id`: the join keys. On a list-owned table the owner foreign key
        // leads them (the owning parent's 1-based `Id`, zero for a row no owner
        // claims) and the coded-index join keys follow it; on a non-list table
        // the coded-index join keys follow `Id` directly.
        let virtual = column - (tuple.count + 1)
        guard let link else { return self.key(virtual) }
        return virtual == 0
            ? .integer(storage.owner(of: tuple.index, link))
            : self.key(virtual - 1)
      }
      if case .index(.heap(.string)) = tuple.type(of: column) {
        return .text((try? tuple.string(column)) ?? "")
      }
      if case .index(.heap(.blob)) = tuple.type(of: column) {
        guard let blob = try? tuple.blob(column) else { return .null }
        var bytes = Array<UInt8>()
        bytes.reserveCapacity(blob.count)
        for i in 0 ..< blob.count {
          bytes.append(blob.load(at: i, as: UInt8.self))
        }
        return .blob(bytes)
      }
      return .integer(tuple[column])
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
  /// non-null, the value is that 1-based row (the target relation's `Id`),
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
}

// MARK: - Signature decode

extension WinMD.Storage {
  /// The open table whose schema name is `schema`, resolved case-insensitively
  /// against the database's relations — the signature decode's table lookup, the
  /// same keying `WinMDRelation.Link` uses to find a list parent.
  internal borrowing func opened(_ schema: String) -> WinMD.Table? {
    for index in 0 ..< tables.count
        where tables[index].description
                  .caseInsensitiveCompare(schema) == .orderedSame {
      return tables[index]
    }
    return nil
  }

  /// The decoded type spelling of the return of the `MethodDef` at 1-based
  /// `method` `Id`, in `dialect`, or `nil` when the row or its signature
  /// does not decode.
  ///
  /// This is the signature-navigation the adapter once baked as the
  /// `ReturnType` virtual column, relocated so the render can spell a return at
  /// render time with a target `Dialect`: it opens the `MethodDef` row, decodes
  /// its `prototype` signature, builds a `Resolver` over the storage, and
  /// decodes the return. `nil` mirrors the old NULL — an absent row, an
  /// undecodable signature, or an unresolvable one.
  internal borrowing func decode(return method: Int,
                                 in dialect: Dialect) -> String? {
    guard let table = opened("MethodDef") else { return nil }
    let cursor = WinMD.Cursor(copy self, table)
    guard let tuple = cursor[method - 1],
        let row = Row<Metadata.Tables.MethodDef>(tuple),
        let signature = try? row.prototype,
        let resolver = try? Resolver(of: signature, with: self) else {
      return nil
    }
    return signature.returns.decode(with: resolver, dialect: dialect)
  }

  /// The decoded type spelling of the `Param` at 1-based `parameter` `Id`, in
  /// `dialect`, navigated through its owning method's signature — or `nil` when
  /// it does not decode.
  ///
  /// This is the signature-navigation the adapter once baked as the `ParamType`
  /// virtual column, relocated so the render can spell a parameter at render
  /// time. The `Param.Sequence` cell is the 1-based parameter position:
  /// `Sequence == 0` is the return pseudo-parameter and `Sequence >
  /// parameters.count` is out of range, both `nil`. The owning `MethodDef` is
  /// found through the `Param` list link — an owner of zero is no parent
  /// (malformed/partial metadata), so the parameter is unowned and yields `nil`
  /// rather than indexing a negative row. The parameter's own `Name` is the
  /// `System.Guid` `IID`/`CLSID` hint; for any other type the decoder ignores
  /// it, so threading it is always safe.
  internal borrowing func decode(parameter: Int,
                                 for dialect: Dialect) -> String? {
    guard let table = opened("Param") else { return nil }
    let params = WinMD.Cursor(copy self, table)
    guard let param = params[parameter - 1],
        let sequence = param.ordinal(for: "Sequence"),
        let link = WinMDRelation.Link(self, table) else {
      return nil
    }
    let position = param[sequence]
    let origin = owner(of: parameter - 1, link)
    guard origin != 0 else { return nil }
    let methods = WinMD.Cursor(copy self, link.parent)
    guard let method = methods[origin - 1],
        let row = Row<Metadata.Tables.MethodDef>(method),
        let signature = try? row.prototype else {
      return nil
    }
    guard position >= 1, position <= signature.parameters.count else {
      return nil
    }
    guard let resolver = try? Resolver(of: signature, with: self) else {
      return nil
    }
    let name = param.ordinal(for: "Name").flatMap { try? param.string($0) }
    return signature.parameters[position - 1]
        .decode(parameter: name, with: resolver, dialect: dialect)
  }
}
