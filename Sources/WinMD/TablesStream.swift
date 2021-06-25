// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Tables Stream
///     uint32_t Reserved           ; +0 [0]
///      uint8_t MajorVersion       ; +4
///      uint8_t MinorVersion       ; +5
///      uint8_t HeapSizes          ; +6
///      uint8_t Reserved           ; +7 [1]
///     uint64_t Valid              ; +8
///     uint64_t Sorted             ; +16
///     uint32_t Rows[]             ; +24
///      uint8_t Tables[]
internal struct TablesStream {
  private let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public var MajorVersion: UInt8 {
    return self.data[4, UInt8.self]
  }

  public var MinorVersion: UInt8 {
    return self.data[5, UInt8.self]
  }

  public var HeapSizes: UInt8 {
    return self.data[6, UInt8.self]
  }

  public var Valid: UInt64 {
    return self.data[8, UInt64.self]
  }

  public var Sorted: UInt64 {
    return self.data[16, UInt64.self]
  }

  public var Rows: [UInt32] {
    let tables: Int = Valid.nonzeroBitCount
    let nbytes: Int = tables * MemoryLayout<UInt32>.size
    let begin: ArraySlice<UInt8>.Index =
        data.index(data.startIndex, offsetBy: 24)
    let end: ArraySlice<UInt8>.Index =
        data.index(begin, offsetBy: nbytes)
    return Array<UInt32>(unsafeUninitializedCapacity: tables) {
      data.copyBytes(to: $0, from: begin ..< end)
      $1 = tables
    }
  }

  public var Tables: [TableBase] {
    let valid: UInt64 = Valid
    let rows: [UInt32] = Rows

    var tables: [TableBase] = []
    tables.reserveCapacity(valid.nonzeroBitCount)

    let strides: [TableIndex:Int] = self.strides(tables: valid, rows: rows)

    let offset = 24 + rows.count * MemoryLayout<UInt32>.size
    var content = data[data.index(data.startIndex, offsetBy: offset)...]

    Metadata.Tables.forEach { table in
      if valid & (1 << table.number) == (1 << table.number) {
        let records = rows[(valid & ((1 << table.number) - 1)).nonzeroBitCount]
        tables.append(table.init(from: content, rows: records, strides: strides))
        content = content[content.index(content.startIndex, offsetBy: tables.last!.data.count)...]
      }
    }

    return tables
  }
}

extension TablesStream {
  internal var StringIndexSize: Int {
    (HeapSizes >> 0) & 1 == 1 ? 4 : 2
  }

  internal var GUIDIndexSize: Int {
    (HeapSizes >> 1) & 1 == 1 ? 4 : 2
  }

  internal var BlobIndexSize: Int {
    (HeapSizes >> 2) & 1 == 1 ? 4 : 2
  }
}

extension TablesStream {
  private func strides(tables: UInt64, rows: [UInt32]) -> [TableIndex:Int] {
    var strides: [TableIndex:Int] = [:]

    func TableIndexSize<T: CodedIndex>(_ index: T.Type) -> Int {
      let TagLength = (index.tables.count - 1).nonzeroBitCount
      return index.tables.map {
        let count = rows[(tables & ((1 << $0.number) - 1)).nonzeroBitCount]
        let range = 1 << (16 - TagLength)
        return count < range
      }.contains(false) ? 4 : 2
    }

    // Required Heaps
    strides[.blob] = BlobIndexSize
    strides[.guid] = GUIDIndexSize
    strides[.string] = StringIndexSize

    // Simple Indices
    Metadata.Tables.forEach { table in
      if tables & (1 << table.number) == (1 << table.number) {
        strides[.simple(table)] =
            rows[(tables & ((1 << table.number) - 1)).nonzeroBitCount] < (1 << 16)
                ? 2
                : 4
      }
    }

    // Coded Indices
    strides[HasConstant.self] = TableIndexSize(HasConstant.self)
    strides[HasCustomAttribute.self] = TableIndexSize(HasCustomAttribute.self)
    strides[CustomAttributeType.self] = TableIndexSize(CustomAttributeType.self)
    strides[HasDeclSecurity.self] = TableIndexSize(HasDeclSecurity.self)
    strides[TypeDefOrRef.self] = TableIndexSize(TypeDefOrRef.self)
    strides[Implementation.self] = TableIndexSize(Implementation.self)
    strides[HasFieldMarshal.self] = TableIndexSize(HasFieldMarshal.self)
    strides[TypeOrMethodDef.self] = TableIndexSize(TypeOrMethodDef.self)
    strides[MemberForwarded.self] = TableIndexSize(MemberForwarded.self)
    strides[MemberRefParent.self] = TableIndexSize(MemberRefParent.self)
    strides[HasSemantics.self] = TableIndexSize(HasSemantics.self)
    strides[MethodDefOrRef.self] = TableIndexSize(MethodDefOrRef.self)
    strides[ResolutionScope.self] = TableIndexSize(ResolutionScope.self)

    return strides
  }
}
