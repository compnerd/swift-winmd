// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import OrderedCollections

/// A singular record from a table.
///
/// A record, or colloquailly a row, is a singular entity in a table.  This is
/// an iterable entity in the record collection of a table.
@dynamicMemberLookup
internal struct Record: IteratorProtocol {
  internal typealias HeapRefs = (blob: BlobsHeap, guid: GUIDHeap, string: StringsHeap)

  public typealias Element = Self

  private let table: Table
  private let layout: OrderedDictionary<String, (Int, Int)>
  private let stride: Int
  private var cursor: Int

  private let heaps: HeapRefs?

  internal init(table: Table, layout: OrderedDictionary<String, (Int, Int)>,
                stride: Int, row cursor: Int, heaps: HeapRefs?) {
    self.table = table
    self.layout = layout
    self.stride = stride
    self.cursor = cursor
    self.heaps = heaps
  }

  /// See `IteratorProtocol.next`
  public mutating func next() -> Self.Element? {
    if self.cursor < self.table.rows {
      // XXX(compnerd) Why is this `defer`-ed?
      defer { self.cursor = self.cursor + 1 }
      return Self(table: self.table, layout: self.layout, stride: self.stride,
                  row: self.cursor, heaps: self.heaps)
    }
    return nil
  }

  /// Access a field ("column") of the record.
  ///
  /// A field of the record, or colloquially a column, is accessed by name in
  /// practice.  The name is used to identify the offset and stride of the field
  /// in the record data.  Because the CIL database is a compressed database of
  /// tables which encodes everything as integers, the return type is always an
  /// integer.  This may be a value or an index into another table (or index).
  internal subscript(dynamicMember field: String) -> Int {
    guard let (offset, size) = self.layout[field] else {
      fatalError("Unknown field \(field)")
    }

    let begin: ArraySlice<UInt8>.Index =
        self.table.data.index(self.table.data.startIndex,
                              offsetBy: self.cursor * self.stride)
    let end: ArraySlice<UInt8>.Index =
        self.table.data.index(begin, offsetBy: self.stride)
    let data: ArraySlice<UInt8> = self.table.data[begin ..< end]

    switch size {
    case 1: return Int(data[offset, UInt8.self])
    case 2: return Int(data[offset, UInt16.self])
    case 4: return Int(data[offset, UInt32.self])
    default:
      fatalError("Unsupported size \(size)")
    }
  }
}

/// The names of the fields of a record for a given table.
internal func fields(of table: Table) -> [StaticString] {
  return fields(of: type(of: table))
}

/// The names of the fields of a record for a given table.
internal func fields(of table: Table.Type) -> [StaticString] {
  return table.columns.lazy.map { $0.name }
}

extension Record: CustomDebugStringConvertible {
  /// See `CustomDebugStringConvertible.debugDescription`.
  public var debugDescription: String {
    let columns: [Column] = type(of: self.table).columns
    return self.layout.enumerated().map {
      switch columns[$0.0].type {
      case let .index(.heap(heap)) where heap == .string:
        let index = self[dynamicMember: $0.1.0]
        if let strings = self.heaps?.string {
          return "\($0.1.0): \(strings[index])"
        } else {
          return "\($0.1.0): \(index)"
        }
      default:
        return "\($0.1.0): \(self[dynamicMember: $0.1.0])"
      }
    }.joined(separator: ", ")
  }
}

/// A collection of records from a table.
///
/// Decodes and provides a set of records which can be iterated.  This requires
/// the database compression state to be able to decode the table data.
internal struct Records: Sequence {
  public typealias Iterator = Record

  private let table: Table

  private let layout: OrderedDictionary<String, (Int, Int)>
  private let stride: Int

  private let heaps: Record.HeapRefs?

  internal init(of table: Table, decoder: DatabaseDecoder,
                heaps: Record.HeapRefs? = nil) {
    self.table = table

    var scan: Int = 0
    self.layout = OrderedDictionary<String, (Int, Int)>(uniqueKeysWithValues: Array<(String, (Int, Int))>(type(of: table).columns.map {
      let width = decoder.width(of: $0.type)
      defer { scan = scan + width }
      return (String(describing: $0.name), (scan, width))
    }))
    self.stride = scan

    self.heaps = heaps
  }

  /// See `Sequence.makeIterator()`.
  @inlinable
  public __consuming func makeIterator() -> Self.Iterator {
    Self.Iterator(table: self.table, layout: self.layout, stride: self.stride,
                  row: 0, heaps: self.heaps)
  }
}