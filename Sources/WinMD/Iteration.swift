// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular row from a table.
///
/// A row is a singular entity in a table. This is an iterable entity in the
/// row collection of a table.
public struct Row<Schema: TableSchema>: ~Escapable {
  internal let row: Int
  // The open table the row belongs to. It carries the shared record layout
  // and backing storage, and is also used to reach the following row, which
  // is required for list processing.
  internal let table: Table
  internal let storage: Storage

  /// The decoded columns of the row.
  ///
  /// The values are read from the backing storage on demand rather than
  /// materialised, so accessing a row does not allocate and only the columns
  /// that are read are decoded.
  internal var columns: Tuple {
    @_lifetime(copy self)
    get { Tuple(row, table, storage) }
  }

  @_lifetime(copy storage)
  internal init(_ row: Int, _ table: Table, _ storage: Storage) {
    self.row = row
    self.table = table
    self.storage = storage
  }
}

/// A positional, type-erased view over the columns of a single row.
///
/// Reading a row is entirely layout-driven from the runtime `Table` plus the
/// backing buffer, so a `Tuple` reads any table's row without the table's
/// static `Schema`. The values are read from the backing storage on demand
/// rather than materialised, so accessing a row does not allocate and only the
/// columns that are read are decoded.
public struct Tuple: ~Escapable {
  internal let row: Int
  internal let table: Table
  internal let storage: Storage

  @_lifetime(copy storage)
  internal init(_ row: Int, _ table: Table, _ storage: Storage) {
    self.row = row
    self.table = table
    self.storage = storage
  }

  /// The number of columns in the row.
  public var count: Int { table.schema.columns.count }

  /// The raw decoded value of column `column`.
  public subscript(_ column: Int) -> Int {
    // Recover the column's offset and width from the schema's narrow layout
    // and the table's width bitset.
    let base = table.range.lowerBound + row * table.stride
                  + table.offset(column)
    let width = table.width(column)
    switch width {
    case 1: return Int(storage.bytes.read(at: base, as: UInt8.self))
    case 2: return Int(storage.bytes.read(at: base, as: UInt16.self))
    case 4: return Int(storage.bytes.read(at: base, as: UInt32.self))
    default: fatalError("unsupported column size '\(width)'")
    }
  }

  /// The name of column `column`.
  public func name(of column: Int) -> StaticString {
    table.schema.columns[column].name
  }

  /// The type of column `column`.
  public func type(of column: Int) -> ColumnType {
    table.schema.columns[column].type
  }
}

// A row dumped column-by-column is a debugging representation, so this would be
// a `CustomDebugStringConvertible` conformance — but that protocol requires
// `Escapable`, which `Tuple` is not. Vend `debugDescription` directly and
// restore the conformance once the protocol admits `~Escapable` types.
extension Tuple /* : CustomDebugStringConvertible */ {
  public var debugDescription: String {
    var fields = Array<String>()
    for column in 0 ..< count {
      let value = self[column]
      switch table.schema.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        let string = StringsHeap(storage.strings)[value]
        fields.append("\(name(of: column)): \(string)")
      default:
        fields.append("\(name(of: column)): \(value)")
      }
    }
    return fields.joined(separator: ", ")
  }
}

extension Row {
  /// The "Strings" (`#Strings`) heap.
  internal var strings: StringsHeap {
    @_lifetime(copy self)
    get { StringsHeap(storage.strings) }
  }

  /// The "Blob" (`#Blob`) heap.
  internal var blobs: BlobsHeap {
    @_lifetime(copy self)
    get { BlobsHeap(storage.blob) }
  }

  /// The "GUID" (`#GUID`) heap.
  internal var guids: GUIDHeap {
    @_lifetime(copy self)
    get { GUIDHeap(storage.guid) }
  }

  /// The rows of the named table.
  @_lifetime(copy self)
  internal func rows<Target: TableSchema>(of schema: Target.Type,
                                        from begin: Int = 0,
                                        to end: Int? = nil) throws(WinMDError)
      -> TableIterator<Target> {
    let storage = self.storage
    return try storage.rows(of: schema, from: begin, to: end)
  }
}

extension Row {
  @_lifetime(copy self)
  internal func list<Target: TableSchema>(for column: Int) throws(WinMDError)
      -> TableIterator<Target> {
    // Lists are stored as a single index in the current row. This marks the
    // beginning of the list, and the next row indicates the index of one past
    // the end. ECMA-335 row indices are 1-based, so the stored value `N` is the
    // 0-based start `N - 1`; the next row's stored start is the 0-based
    // exclusive upper bound of this run.
    let begin = columns[column] - 1
    let end: Int? = if row + 1 < table.rows {
      Row(row + 1, table, storage).columns[column] - 1
    } else {
      nil
    }

    return try storage.rows(of: Target.self, from: begin, to: end)
  }
}

// As with `Tuple`, restore the `CustomDebugStringConvertible` conformance once
// the protocol admits `~Escapable` types.
extension Row /* : CustomDebugStringConvertible */ {
  public var debugDescription: String {
    columns.debugDescription
  }
}

/// Iterator for a `Table`
///
/// Provides a way to iterate a given table in a type-safe manner. It walks the
/// rows of an open `Table`, yielding a typed `Row` for each row.
///
/// A `~Escapable` view cannot conform to `Sequence`/`IteratorProtocol`, so
/// iteration is index-based: walk `0 ..< count`, reading `self[i]`.
public struct TableIterator<Schema: TableSchema>: ~Escapable {
  private let table: Table
  private let storage: Storage
  private let rows: Int

  @_lifetime(copy storage)
  internal init(_ storage: Storage, _ table: Table,
                from row: Int = 0, to count: Int? = nil) {
    self.storage = storage
    self.table = table
    self.rows = (count ?? Int(table.rows)) - row
    self.start = row
  }

  /// The first row, within the table, that this iterator yields.
  private let start: Int

  /// The number of rows the iterator yields.
  public var count: Int {
    rows
  }

  public subscript(_ offset: Int) -> Row<Schema>? {
    @_lifetime(copy self)
    get {
      guard offset < rows else { return nil }
      return Row(start + offset, table, storage)
    }
  }
}

/// A non-generic scan over an open table.
///
/// `Cursor` mirrors `TableIterator` but is driven entirely by the runtime
/// `Table`, so it walks the rows of any table — yielding a type-erased `Tuple`
/// for each — without the table's static `Schema`.
///
/// A `~Escapable` view cannot conform to `Sequence`/`IteratorProtocol`, so
/// iteration is index-based: walk `0 ..< count`, reading `self[i]`.
public struct Cursor: ~Escapable {
  private let table: Table
  private let storage: Storage
  private let rows: Int

  @_lifetime(copy storage)
  internal init(_ storage: Storage, _ table: Table,
                from row: Int = 0, to count: Int? = nil) {
    self.storage = storage
    self.table = table
    self.rows = (count ?? Int(table.rows)) - row
    self.start = row
  }

  /// The first row, within the table, that this cursor yields.
  private let start: Int

  /// The number of rows the cursor yields.
  public var count: Int {
    rows
  }

  public subscript(_ offset: Int) -> Tuple? {
    @_lifetime(copy self)
    get { offset < rows ? Tuple(start + offset, table, storage) : nil }
  }
}
