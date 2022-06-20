// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table.  This is
/// an iterable entity in the record collection of a table.
public struct Record<Table: WinMD.Table> {
  internal let row: Int
  internal let columns: [Int]
  internal let database: Database

  internal init(_ row: Int, _ columns: [Int], _ database: Database) {
    self.row = row
    self.columns = columns
    self.database = database
  }
}

extension Record: CustomDebugStringConvertible {
  public var debugDescription: String {
    return columns.enumerated().map { (column, value) in
      switch Table.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        let value: String = (try? database.strings.get()[value]) ?? "<unknown>"
        return "\(Table.columns[column].name): \(value)"
      default:
        return "\(Table.columns[column].name): \(value)"
      }
    }.joined(separator: ", ")
  }
}

/// Iterator for a `Table`
///
/// Provides a way to iterate a given table in a type-safe manner.  It decodes a
/// particular table to provide access to the records.  This requires an instance
/// of a `DatabaseDecoder` to be able to decompress the table and records.
public struct TableIterator<Table: WinMD.Table>: IteratorProtocol, Sequence {
  public typealias Element = Record<Table>

  private let table: Table
  private let database: Database

  private var cursor: Int

  public init(_ database: Database, _ table: Table, from row: Int = 0) {
    self.database = database
    self.table = table
    self.cursor = row
  }

  /// See `IteratorProtocol.next`
  public mutating func next() -> Self.Element? {
    guard self.cursor < self.table.rows else { return nil }
    defer { self.cursor = self.cursor + 1}
    return self.table[cursor, database]
  }
}
