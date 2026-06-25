// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A borrowed view over a CIL metadata database.
///
/// The database is a `~Escapable` view over a caller-owned byte buffer: the
/// caller is responsible for keeping the buffer alive for as long as the
/// database (and anything derived from it) is in use.
public struct Database: ~Escapable {
  /// The backing buffer.
  internal let bytes: RawSpan

  /// The absolute byte range of the tables stream within the buffer.
  ///
  /// Locating a stream means parsing the metadata stream headers, so resolving
  /// it on each access would re-parse those headers every time. It is invariant
  /// for the file's lifetime, so it is located once when the database is opened.
  private let range: Range<Int>

  /// The open tables of the database.
  ///
  /// The tables present in a database and their record layouts are fixed once
  /// the file is mapped, so they are opened once when the database is opened and
  /// reused for every query rather than reconstructed on each access.
  private let relations: Array<Table>

  // The heaps, located once when the database is opened. A heap is invariant
  // for the file's lifetime, and an absent heap fails the open rather than being
  // tolerated and surfaced as an error on use. They are stored as borrowed
  // sub-spans of the backing buffer.
  private let blob: RawSpan
  private let guid: RawSpan
  private let string: RawSpan

  // The "User Strings" (`#US`) heap is optional: metadata-only files frequently
  // omit it. Its absence is tolerated at open and surfaced as an error only on
  // use, so its location is stored as an optional region rather than a borrowed
  // sub-span. `Region` is escapable, so it can be held by an `Optional`.
  private let user: Region?

  // MARK: - Streams

  public var stream: TablesStream {
    @_lifetime(copy self)
    get {
      TablesStream(bytes, base: range.lowerBound, limit: range.upperBound)
    }
  }

  /// The physical schema (index and column widths) of the database.
  ///
  /// This is a thin view over the tables stream: the widths it computes depend
  /// only on which tables are present and their row counts, both of which are
  /// invariant for the file's lifetime, so it carries no state of its own.
  public var catalog: PhysicalSchema {
    @_lifetime(copy self)
    get { PhysicalSchema(stream) }
  }

  // MARK: - Heaps

  public var blobs: BlobsHeap {
    @_lifetime(copy self)
    get { BlobsHeap(blob) }
  }

  public var guids: GUIDHeap {
    @_lifetime(copy self)
    get { GUIDHeap(guid) }
  }

  public var strings: StringsHeap {
    @_lifetime(copy self)
    get { StringsHeap(string) }
  }

  public var literals: UserStringsHeap {
    @_lifetime(copy self)
    get throws(WinMDError) {
      guard let user else { throw .UserStringsHeapNotFound }
      return UserStringsHeap(bytes.extracting(user.offset ..< user.offset + user.size))
    }
  }

  // MARK: - Tables

  public var tables: Array<Table> {
    relations
  }

  /// A borrowed, ARC-free projection of the readable state for the cursors.
  ///
  /// The row cursors only read out of the backing buffer and the open tables,
  /// so they carry this trivial view rather than the whole `Database` and avoid
  /// retaining the relations buffer on every copy. `package` so the SQL-engine
  /// adapter, which conforms `Storage` to the engine's `Catalog`, opens it from
  /// the database.
  package var storage: Storage {
    @_lifetime(borrow self)
    get {
      Storage(bytes: bytes, relations: relations.span, strings: string,
              blob: blob, guid: guid, valid: stream.Valid,
              sorted: stream.Sorted)
    }
  }

  // MARK: - Initializers

  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) throws(WinMDError) {
    let dos = try DOSFile(bytes)
    let pe = try PEFile(from: dos)
    let cil = try Assembly(from: pe)

    self.bytes = bytes

    let stream = try TablesStream(from: cil)
    self.range = stream.base ..< stream.limit
    self.relations = try stream.relations(PhysicalSchema(stream))

    guard let blobs = cil.Metadata.stream(named: Metadata.Stream.Blob) else {
      throw .BlobsHeapNotFound
    }
    self.blob = bytes.extracting(blobs.offset ..< blobs.offset + blobs.size)

    guard let guids = cil.Metadata.stream(named: Metadata.Stream.GUID) else {
      throw .GUIDHeapNotFound
    }
    self.guid = bytes.extracting(guids.offset ..< guids.offset + guids.size)

    guard let strings = cil.Metadata.stream(named: Metadata.Stream.Strings) else {
      throw .StringsHeapNotFound
    }
    self.string =
        bytes.extracting(strings.offset ..< strings.offset + strings.size)

    // The "User Strings" heap is optional: tolerate its absence at open and
    // surface it as an error only on use.
    self.user = cil.Metadata.stream(named: Metadata.Stream.UserStrings)
  }

  // MARK: - subscripting

  @_lifetime(borrow self)
  public func rows<Schema: TableSchema>(of schema: Schema.Type,
                                        from begin: Int = 0,
                                        to end: Int? = nil) throws(WinMDError)
      -> TableIterator<Schema> {
    let storage = self.storage
    return try storage.rows(of: schema, from: begin, to: end)
  }

  /// The rows of an already-open table, read positionally.
  @_lifetime(borrow self)
  public func rows(of table: Table) -> Cursor {
    Cursor(storage, table)
  }

  /// The row a `TypeDefOrRef` coded index — e.g. one a decoded signature's
  /// `named` type carries — references, or `nil` if it is null.
  ///
  /// The index's tag selects `TypeDef`/`TypeRef`/`TypeSpec` and its row is
  /// 1-based; this opens the named table at `row - 1`. A `TypeSpec` reference,
  /// which itself names a `#Blob` signature rather than a `TypeName`, resolves to
  /// the `TypeSpec` row.
  @_lifetime(borrow self)
  public func resolve(_ reference: TypeDefOrRef) throws(WinMDError) -> Tuple? {
    guard reference.row != 0 else { return nil }
    guard reference.tag < TypeDefOrRef.tables.count,
        let schema = TypeDefOrRef.tables[reference.tag]
    else { throw .BadImageFormat }
    let storage = self.storage
    guard let tuple = try storage.tuple(reference.row - 1, of: schema) else {
      throw .BadImageFormat
    }
    return tuple
  }

  /// The rows of `schema` whose foreign-key `column` references `target`.
  ///
  /// This is reverse navigation: the inverse of `Tuple.resolve`. Where
  /// `resolve` follows a row's foreign key forward to the one row it names,
  /// `referencing` finds every row of `schema` whose `column` names `target`.
  ///
  /// The stored cell an owning row holds to point at `target` is computed from
  /// `column`'s type and `target`'s 0-based row (ECMA-335 rows are 1-based, so
  /// the stored row is `target.row + 1`):
  ///   - a `simple` index to table `S` requires `S` to be `target`'s table and
  ///     stores `target.row + 1`;
  ///   - a `coded` index `C` stores `((target.row + 1) << C.bits) | tag`, where
  ///     `tag` is the position of `target`'s table within `C.tables`.
  /// A column of any other kind is not a foreign key and is a usage error.
  ///
  /// When `schema` is physically sorted on this very column — its intrinsic
  /// `key` is `column` and the runtime `Sorted` bit is set — the matching rows
  /// form a contiguous run, found by binary search in `O(log n)`. Otherwise the
  /// result is an `O(rows)` linear scan that yields the same matches.
  @_lifetime(borrow self)
  public func referencing(_ target: borrowing Tuple,
                          in schema: TableSchema.Type,
                          by column: Int) throws(WinMDError) -> Filter {
    let storage = self.storage
    return try storage.referencing(target, in: schema, by: column)
  }

  /// The rows whose simple-index foreign-key `column` references `target`.
  ///
  /// Typed reverse navigation: the owning column descriptor — a `Reference`
  /// token naming the owning `Owner` table and the column's ordinal — supplies
  /// both the owning relation and the ordinal, so the call site needs no
  /// string or ordinal: `database.referencing(row, by: NestedClass.NestedClass)`.
  /// This is the typed wrapper over the generic `referencing(_:in:by:)`; see it
  /// for the encoding and the `O(log n)` / `O(rows)` contract.
  @_lifetime(borrow self)
  public func referencing<Owner, Target>(_ target: borrowing Row<Target>,
                                         by column: Reference<Owner, Target>)
      throws(WinMDError) -> Filter {
    let storage = self.storage
    return try storage.referencing(target, by: column)
  }

  /// The rows whose coded-index foreign-key `column` references `target`.
  ///
  /// As above, but the owning column is a coded index, so the descriptor is a
  /// `CodedReference` token and the `target` can be any table the index admits:
  /// `database.referencing(row, by: CustomAttribute.Parent)`.
  @_lifetime(borrow self)
  public func referencing<Owner, Target>(_ target: borrowing Row<Target>,
                                         by column: CodedReference<Owner>)
      throws(WinMDError) -> Filter {
    let storage = self.storage
    return try storage.referencing(target, by: column)
  }
}
