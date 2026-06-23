// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The physical schema of a database instance.
///
/// ECMA-335 §II.24 describes the on-disk physical layout of the metadata: the
/// width of each heap and coded index depends on which tables are present and
/// their row counts. This is the database's physical schema (the RDBMS catalog
/// loaded when the database is opened) — immutable data with no identity. It is
/// computed once at open and read thereafter.
public struct PhysicalSchema {
  public private(set) var strides = Dictionary<Index, Int>()

  public init(_ stream: TablesStream) {
    let valid = stream.Valid
    let rows = stream.Rows

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
    strides[.heap(.blob)] = stream.BlobIndexSize
    strides[.heap(.guid)] = stream.GUIDIndexSize
    strides[.heap(.string)] = stream.StringIndexSize
    // Well-known Coded Indicies
    strides[.coded(CustomAttributeType.self)] = TableIndexSize(CustomAttributeType.self)
    strides[.coded(HasConstant.self)] = TableIndexSize(HasConstant.self)
    strides[.coded(HasCustomAttribute.self)] = TableIndexSize(HasCustomAttribute.self)
    strides[.coded(HasDeclSecurity.self)] = TableIndexSize(HasDeclSecurity.self)
    strides[.coded(HasFieldMarshal.self)] = TableIndexSize(HasFieldMarshal.self)
    strides[.coded(HasSemantics.self)] = TableIndexSize(HasSemantics.self)
    strides[.coded(Implementation.self)] = TableIndexSize(Implementation.self)
    strides[.coded(MemberForwarded.self)] = TableIndexSize(MemberForwarded.self)
    strides[.coded(MemberRefParent.self)] = TableIndexSize(MemberRefParent.self)
    strides[.coded(MethodDefOrRef.self)] = TableIndexSize(MethodDefOrRef.self)
    strides[.coded(ResolutionScope.self)] = TableIndexSize(ResolutionScope.self)
    strides[.coded(TypeDefOrRef.self)] = TableIndexSize(TypeDefOrRef.self)
    strides[.coded(TypeOrMethodDef.self)] = TableIndexSize(TypeOrMethodDef.self)
    // Simple Indicies
    for table in kRegisteredTables {
      if valid & (1 << table.number) == (1 << table.number) {
        strides[.simple(table)] =
            rows[(valid & ((1 << table.number) - 1)).nonzeroBitCount] < (1 << 16)
                ? 2
                : 4
      }
    }
  }
}

extension PhysicalSchema {
  /// The width, in bytes, of a given column type.
  internal func width(of type: ColumnType) -> Int {
    switch type {
    case .constant(let size):
      return size

    case .index(let index):
      guard let stride = strides[index] else {
        fatalError("Unsupported index type: \(index)")
      }
      return stride
    }
  }
}
