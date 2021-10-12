// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import OrderedCollections

internal enum Heap {
  case blob
  case guid
  case string
}

internal enum Index {
  case heap(Heap)
  case simple(Table.Type)
  case coded(CodedIndex.Type)
}

extension Index: Equatable {
  public static func == (lhs: Index, rhs: Index) -> Bool {
    switch (lhs, rhs) {
    case let (.heap(lhs), .heap(rhs)):
      return lhs == rhs
    case let (.simple(lhs), .simple(rhs)):
      return lhs == rhs
    case let (.coded(lhs), .coded(rhs)):
      return lhs == rhs
    default:
      return false
    }
  }
}

extension Index: Hashable {
  public func hash(into hasher: inout Hasher) {
    switch self {
    case let .heap(heap):
      hasher.combine(heap)
    case let .simple(table):
      // FIXME(compnerd) is this correct?
      hasher.combine(ObjectIdentifier(table))
    case let .coded(coded):
      // FIXME(compnerd) is this correct?
      hasher.combine(ObjectIdentifier(coded))
    }
  }
}

/// The state of comprression for a particular database instance.
///
/// The CIL metadata represents a compressed database format. This type
/// provides the context for the decompression of the database. The compression
/// state is expensive to compute, and this simply serves as a cache for the
/// data.
internal class DatabaseDecoder {
  public private(set) var strides: [Index:Int] = [:]

  public init(_ stream: TablesStream) {
    let valid: UInt64 = stream.Valid
    let rows: [UInt32] = stream.Rows

    func TableIndexSize<T: CodedIndex>(_ index: T.Type) -> Int {
      // The number of tables that the index can refer to is the number of bits
      // required to select between then - [0 ..< count].
      let bits = (index.tables.count - 1).nonzeroBitCount
      // The remaining bits serve as the index for the selected table.
      let range = 1 << (16 - bits)
      return index.tables.map {
        // Ensure that the table is present, as not all tables are required to
        // be present. If the table is not present, the number of rows that can
        // be indexed is unknown, so we must assume that we need a wide index.
        guard valid & (1 << $0.number) == (1 << $0.number) else { return false }
        let count = rows[(valid & ((1 << $0.number) - 1)).nonzeroBitCount]
        // If the number of rows in the table is less than the range, we can use
        // the compressed width, otherwise, we need the full 32-bits for the
        // index.
        return count < range
      }.contains(false) ? 4 : 2
    }

    // Well-known Heaps
    self.strides[.heap(.blob)] = stream.BlobIndexSize
    self.strides[.heap(.guid)] = stream.GUIDIndexSize
    self.strides[.heap(.string)] = stream.StringIndexSize
    // Well-known Coded Indicies
    self.strides[.coded(CustomAttributeType.self)] = TableIndexSize(CustomAttributeType.self)
    self.strides[.coded(HasConstant.self)] = TableIndexSize(HasConstant.self)
    self.strides[.coded(HasCustomAttribute.self)] = TableIndexSize(HasCustomAttribute.self)
    self.strides[.coded(HasDeclSecurity.self)] = TableIndexSize(HasDeclSecurity.self)
    self.strides[.coded(HasFieldMarshal.self)] = TableIndexSize(HasFieldMarshal.self)
    self.strides[.coded(HasSemantics.self)] = TableIndexSize(HasSemantics.self)
    self.strides[.coded(Implementation.self)] = TableIndexSize(Implementation.self)
    self.strides[.coded(MemberForwarded.self)] = TableIndexSize(MemberForwarded.self)
    self.strides[.coded(MemberRefParent.self)] = TableIndexSize(MemberRefParent.self)
    self.strides[.coded(MethodDefOrRef.self)] = TableIndexSize(MethodDefOrRef.self)
    self.strides[.coded(ResolutionScope.self)] = TableIndexSize(ResolutionScope.self)
    self.strides[.coded(TypeDefOrRef.self)] = TableIndexSize(TypeDefOrRef.self)
    self.strides[.coded(TypeOrMethodDef.self)] = TableIndexSize(TypeOrMethodDef.self)
    // Simple Indicies
    Metadata.Tables.forEach {
      if valid & (1 << $0.number) == (1 << $0.number) {
        self.strides[.simple($0)] =
            rows[(valid & ((1 << $0.number) - 1)).nonzeroBitCount] < (1 << 16)
                ? 2
                : 4
      }
    }
  }
}

internal enum ColumnType {
  case constant(Int)
  case index(Index)
}

extension ColumnType: Hashable {
}

internal struct Column {
  let name: StaticString
  let type: ColumnType
}

extension DatabaseDecoder {
  /// The stride of a table in the database, which is the byte count of a row.
  internal func stride(of table: Table) -> Int {
    return stride(of: type(of: table))
  }

  /// The stride of a table in the database, which is the byte count of a row.
  internal func stride(of table: Table.Type) -> Int {
    return layout(of: table).reduce(0, +)
  }

  /// The layout of a record of the table, byte count of each column.
  internal func layout(of table: Table) -> [Int] {
    return layout(of: type(of: table))
  }

  /// The layout of a record of the table, byte count of each column.
  internal func layout(of table: Table.Type) -> [Int] {
    return table.columns.lazy.map { width(of: $0.type) }
  }

  /// The width, in bytes, of a given column type.
  internal func width(of type: ColumnType) -> Int {
    switch type {
    case .constant(let size):
      return size

    case .index(let index):
      guard let stride = self.strides[index] else {
        fatalError("Unsupported index type: \(index)")
      }
      return stride
    }
  }
}

/// CIL Table Representation
internal protocol Table: AnyObject {
  /// The CIL defined table number.
  static var number: Int { get }

  /// The columns of the table as defined by the CIL specification.
  static var columns: [Column] { get }

  /// The number of rows in the table.
  var rows: UInt32 { get }

  /// The data backing the table.
  var data: ArraySlice<UInt8> { get }

  /// Constructs a new table model.
  init(rows: UInt32, data: ArraySlice<UInt8>)
}

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
