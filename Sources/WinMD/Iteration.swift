// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table. This is
/// an iterable entity in the record collection of a table.
public struct Record<Schema: TableSchema>: ~Escapable {
  internal let row: Int
  // The open table the record belongs to.  It carries the shared record layout
  // and backing storage, and is also used to reach the following record, which
  // is required for list processing.
  internal let table: Table
  internal let database: Database

  /// The decoded columns of the record.
  ///
  /// The values are read from the backing storage on demand rather than
  /// materialised, so accessing a record does not allocate and only the columns
  /// that are read are decoded.
  internal var columns: Columns {
    @_lifetime(copy self)
    get { Columns(database, table, row) }
  }

  @_lifetime(copy database)
  internal init(_ row: Int, _ table: Table, _ database: Database) {
    self.row = row
    self.table = table
    self.database = database
  }
}

extension Record {
  /// A zero-allocation view over the columns of a record.
  internal struct Columns: ~Escapable {
    private let database: Database
    private let table: Table
    private let row: Int

    @_lifetime(copy database)
    internal init(_ database: Database, _ table: Table, _ row: Int) {
      self.database = database
      self.table = table
      self.row = row
    }

    internal var startIndex: Int { 0 }
    internal var endIndex: Int { table.descriptor.columns.count }
    internal var count: Int { endIndex }

    internal subscript(_ column: Int) -> Int {
      let base = table.range.lowerBound + row * table.descriptor.stride
      let (offset, width) = table.descriptor.columns[column]
      switch width {
      case 1: return Int(database.bytes.read(at: base + offset, as: UInt8.self))
      case 2: return Int(database.bytes.read(at: base + offset, as: UInt16.self))
      case 4: return Int(database.bytes.read(at: base + offset, as: UInt32.self))
      default: fatalError("unsupported column size '\(width)'")
      }
    }
  }
}

extension Record {
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
      Record(row + 1, table, database).columns[column] - 1
    } else {
      nil
    }

    return try database.rows(of: Target.self, from: begin, to: end)
  }
}

extension Record {
  public var debugDescription: String {
    var fields = Array<String>()
    let columns = self.columns
    for column in 0 ..< columns.count {
      let value = columns[column]
      switch Schema.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        let string = database.strings[value]
        fields.append("\(Schema.columns[column].name): \(string)")
      default:
        fields.append("\(Schema.columns[column].name): \(value)")
      }
    }
    return fields.joined(separator: ", ")
  }
}

/// Iterator for a `Table`
///
/// Provides a way to iterate a given table in a type-safe manner. It walks the
/// records of an open `Table`, yielding a typed `Record` for each row.
///
/// A `~Escapable` view cannot conform to `Sequence`/`IteratorProtocol`, so
/// iteration is index-based: walk `0 ..< count`, reading `self[i]`.
public struct TableIterator<Schema: TableSchema>: ~Escapable {
  private let table: Table
  private let database: Database
  private let rows: Int

  @_lifetime(copy database)
  public init(_ database: Database, _ table: Table,
              from row: Int = 0, to count: Int? = nil) {
    self.database = database
    self.table = table
    self.rows = (count ?? Int(table.rows)) - row
    self.start = row
  }

  /// The first row, within the table, that this iterator yields.
  private let start: Int

  /// The number of records the iterator yields.
  public var count: Int {
    rows
  }

  public subscript(_ offset: Int) -> Record<Schema>? {
    @_lifetime(copy self)
    get {
      guard offset < rows else { return nil }
      return Record(start + offset, table, database)
    }
  }
}
