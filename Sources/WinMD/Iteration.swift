// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table. This is
/// an iterable entity in the record collection of a table.
public struct Record<Table: WinMD.Table> {
  internal let row: Int
  internal let data: ArraySlice<UInt8>
  internal let descriptor: TupleDescriptor
  internal let database: Database
  // Do not expose the table to even internal users as this is used soley to get
  // a reference to the next record, which is required for list processing.
  private let table: Table

  /// The decoded columns of the record.
  ///
  /// The values are read from the backing storage on demand rather than
  /// materialised, so accessing a record does not allocate and only the columns
  /// that are read are decoded.
  internal var columns: Columns {
    Columns(data: data, descriptor: descriptor)
  }

  internal init(_ row: Int, _ data: ArraySlice<UInt8>,
                _ descriptor: TupleDescriptor, _ database: Database,
                _ table: Table) {
    self.row = row
    self.data = data
    self.descriptor = descriptor
    self.database = database
    self.table = table
  }
}

extension Record {
  /// A zero-allocation view over the columns of a record.
  internal struct Columns: RandomAccessCollection {
    private let data: ArraySlice<UInt8>
    private let descriptor: TupleDescriptor

    internal init(data: ArraySlice<UInt8>, descriptor: TupleDescriptor) {
      self.data = data
      self.descriptor = descriptor
    }

    internal var startIndex: Int { 0 }
    internal var endIndex: Int { descriptor.columns.count }

    internal subscript(_ column: Int) -> Int {
      let (offset, width) = descriptor.columns[column]
      switch width {
      case 1: return Int(data[offset, UInt8.self])
      case 2: return Int(data[offset, UInt16.self])
      case 4: return Int(data[offset, UInt32.self])
      default: fatalError("unsupported column size '\(width)'")
      }
    }
  }
}

extension Record {
  internal func list<Target: WinMD.Table>(for column: Int) throws
      -> TableIterator<Target> {
    // Lists are stored as a single index in the current row. This marks the
    // beginning of the list, and the next row indicates the index of one past
    // the end.
    let begin = columns[column]
    let end: Int? = if row + 1 < table.rows {
      table[row + 1, database].columns[column] - 1
    } else {
      nil
    }

    return try database.rows(of: Target.self, from: begin, to: end)
  }
}

extension Record: CustomDebugStringConvertible {
  public var debugDescription: String {
    columns.enumerated().map { (column, value) in
      switch Table.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        let value = (try? database.strings[value]) ?? "<unknown>"
        return "\(Table.columns[column].name): \(value)"
      default:
        return "\(Table.columns[column].name): \(value)"
      }
    }.joined(separator: ", ")
  }
}

/// Iterator for a `Table`
///
/// Provides a way to iterate a given table in a type-safe manner. It decodes a
/// particular table to provide access to the records. This requires an instance
/// of a `DatabaseDecoder` to be able to decompress the table and records.
public struct TableIterator<Table: WinMD.Table>: IteratorProtocol, Sequence {
  public typealias Element = Record<Table>

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
    return table[cursor, database]
  }

  public subscript(_ offset: Int) -> Self.Element? {
    guard (cursor + offset) < rows else { return nil }
    return table[cursor + offset, database]
  }
}
