// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table.  This is
/// an iterable entity in the record collection of a table.
public struct Record<Table: WinMD.Table> {
  internal let columns: [Int]
  internal let heaps: Database.Heaps

  internal init(_ columns: [Int], _ heaps: Database.Heaps) {
    self.columns = columns
    self.heaps = heaps
  }
}

extension Record: CustomDebugStringConvertible {
  public var debugDescription: String {
    return columns.enumerated().map { (column, value) in
      switch Table.columns[column].type {
      case let .index(.heap(heap)) where heap == .string:
        return "\(Table.columns[column].name): \(heaps.string[value])"
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
  private let heaps: Database.Heaps
  private let decoder: DatabaseDecoder

  private var cursor: Int

  public init(_ table: Table, _ heaps: Database.Heaps,
              _ decoder: DatabaseDecoder, from row: Int = 0) {
    self.table = table
    self.heaps = heaps
    self.decoder = decoder
    self.cursor = row
  }

  /// See `IteratorProtocol.next`
  public mutating func next() -> Self.Element? {
    guard self.cursor < self.table.rows else { return nil }
    defer { self.cursor = self.cursor + 1}
    return self.table[cursor, decoder, heaps]
  }
}
