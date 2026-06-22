// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table. This is
/// an iterable entity in the record collection of a table.
public struct Record<Schema: TableSchema> {
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
    Columns(table, row)
  }

  internal init(_ row: Int, _ table: Table, _ database: Database) {
    self.row = row
    self.table = table
    self.database = database
  }
}

extension Record {
  /// A zero-allocation view over the columns of a record.
  internal struct Columns: RandomAccessCollection {
    private let table: Table
    private let row: Int

    internal init(_ table: Table, _ row: Int) {
      self.table = table
      self.row = row
    }

    internal var startIndex: Int { 0 }
    internal var endIndex: Int { table.descriptor.columns.count }

    internal subscript(_ column: Int) -> Int {
      let base = row * table.descriptor.stride
      let (offset, width) = table.descriptor.columns[column]
      switch width {
      case 1: return Int(table.data[base + offset, UInt8.self])
      case 2: return Int(table.data[base + offset, UInt16.self])
      case 4: return Int(table.data[base + offset, UInt32.self])
      default: fatalError("unsupported column size '\(width)'")
      }
    }
  }
}

extension Record {
  internal func list<Target: TableSchema>(for column: Int) throws(WinMDError)
      -> TableIterator<Target> {
    // Lists are stored as a single index in the current row. This marks the
    // beginning of the list, and the next row indicates the index of one past
    // the end.
    let begin = columns[column]
    let end: Int? = if row + 1 < table.rows {
      Record(row + 1, table, database).columns[column] - 1
    } else {
      nil
    }

    return try database.rows(of: Target.self, from: begin, to: end)
  }
}

extension Record: CustomDebugStringConvertible {
  public var debugDescription: String {
    columns.enumerated().map { (column, value) in
      switch Schema.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        let value = database.strings[value]
        return "\(Schema.columns[column].name): \(value)"
      default:
        return "\(Schema.columns[column].name): \(value)"
      }
    }.joined(separator: ", ")
  }
}

/// Iterator for a `Table`
///
/// Provides a way to iterate a given table in a type-safe manner. It walks the
/// records of an open `Table`, yielding a typed `Record` for each row.
public struct TableIterator<Schema: TableSchema>: IteratorProtocol, Sequence {
  public typealias Element = Record<Schema>

  private let table: Table
  private let database: Database
  private let rows: Int

  private var cursor: Int

  public init(_ database: Database, _ table: Table,
              from row: Int = 0, to count: Int? = nil) {
    self.database = database
    self.table = table
    self.cursor = row
    self.rows = count ?? Int(table.rows)
  }

  /// See `IteratorProtocol.next`
  public mutating func next() -> Self.Element? {
    guard cursor < rows else { return nil }
    defer { cursor = cursor + 1}
    return Record(cursor, table, database)
  }

  public subscript(_ offset: Int) -> Self.Element? {
    guard (cursor + offset) < rows else { return nil }
    return Record(cursor + offset, table, database)
  }
}
