// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table.  This is
/// an iterable entity in the record collection of a table.
public struct Record<Table: WinMD.Table> {
  internal let row: [Int]
  internal let heaps: Database.Heaps

  internal init(_ row: [Int], _ heaps: Database.Heaps) {
    self.row = row
    self.heaps = heaps
  }
}

extension Record: CustomDebugStringConvertible {
  public var debugDescription: String {
    return row.enumerated().map { (column, value) in
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

  private let decoder: DatabaseDecoder
  private let table: Table
  private let heaps: Database.Heaps

  private var cursor: Int

  public init(_ table: Table, _ decoder: DatabaseDecoder,
              _ heaps: Database.Heaps, from row: Int = 0) {
    self.decoder = decoder
    self.table = table
    self.heaps = heaps
    self.cursor = row
  }

  /// See `IteratorProtocol.next`
  public mutating func next() -> Self.Element? {
    guard self.cursor < self.table.rows else { return nil }

    defer { self.cursor = self.cursor + 1}

    var scan: Int = 0
    let layout: [(Int, Int)] = Table.columns.map {
      let width = decoder.width(of: $0.type)
      defer { scan = scan + width }
      return (scan, width)
    }

    let begin: ArraySlice<UInt8>.Index =
        self.table.data.index(self.table.data.startIndex,
                              offsetBy: self.cursor * scan)
    let end: ArraySlice<UInt8>.Index =
        self.table.data.index(begin, offsetBy: scan)
    let data: ArraySlice<UInt8> = self.table.data[begin ..< end]

    let record: [Int] = layout.map { (offset, size) in
      switch size {
      case 1: return Int(data[offset, UInt8.self])
      case 2: return Int(data[offset, UInt16.self])
      case 4: return Int(data[offset, UInt32.self])
      default: fatalError("unsupported column size '\(size)'")
      }
    }

    return Record<Table>(record, self.heaps)
  }
}
