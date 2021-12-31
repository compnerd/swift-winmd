// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The state of compression for a particular database instance.
///
/// The CIL metadata represents a compressed database format. This type
/// provides the context for the decompression of the database. The compression
/// state is expensive to compute, and this simply serves as a cache for the
/// data.
public class DatabaseDecoder {
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
