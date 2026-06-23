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

  /// The decoded physical schema (index and column widths) of the database.
  ///
  /// This is invariant for the lifetime of the database — it depends only on
  /// which tables are present and their row counts — so it is decoded once when
  /// the database is opened rather than rebuilt on every record access.
  public let catalog: PhysicalSchema

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
  // omit it.  Its absence is tolerated at open and surfaced as an error only on
  // use, so its location is stored as an optional region rather than a borrowed
  // sub-span.  `Region` is escapable, so it can be held by an `Optional`.
  private let user: Region?

  // MARK: - Streams

  public var stream: TablesStream {
    @_lifetime(copy self)
    get {
      TablesStream(bytes, base: range.lowerBound, limit: range.upperBound)
    }
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

  // MARK: - Initializers

  @_lifetime(copy bytes)
  public init(_ bytes: RawSpan) throws(WinMDError) {
    let dos = try DOSFile(bytes)
    let pe = try PEFile(from: dos)
    let cil = try Assembly(from: pe)

    self.bytes = bytes

    let stream = try TablesStream(from: cil)
    self.range = stream.base ..< stream.limit
    self.catalog = PhysicalSchema(stream)
    self.relations = try stream.relations(catalog)

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

  @_lifetime(copy self)
  public func rows<Schema: TableSchema>(of schema: Schema.Type,
                                        from begin: Int = 0,
                                        to end: Int? = nil) throws(WinMDError)
      -> TableIterator<Schema> {
    guard let table =
        relations.first(where: { $0.number == Schema.number }) else {
      throw .TableNotFound
    }
    return TableIterator<Schema>(self, table, from: begin, to: end)
  }
}
