/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

/// Tables Stream
///     uint32_t Reserved           ; +0 [0]
///      uint8_t MajorVersion       ; +4
///      uint8_t MinorVersion       ; +5
///      uint8_t HeapSizes          ; +v
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

  public var MajorVersion: UInt8 { self.data[offset: 4] }
  public var MinorVersion: UInt8 { self.data[offset: 5] }
  public var HeapSizes: UInt8 { self.data[offset: 6] }
  public var Valid: UInt64 { self.data[offset: 8] }
  public var Sorted: UInt64 { self.data[offset: 16] }

  internal var tableCount: Int { self.Valid.nonzeroBitCount }
  
  public var Rows: [UInt32] {
    let enterIndex = self.data.index(self.data.startIndex, offsetBy: 24)
    let exitIndex = self.data.index(enterIndex, offsetBy: self.tableCount * MemoryLayout<UInt32>.size)
    
    return .init(unsafeUninitializedCapacity: self.tableCount) {
      self.data.copyBytes(to: $0, from: enterIndex ..< exitIndex)
      $1 = self.tableCount
    }
  }

  public var Tables: [Table] {
    var tables: [Table] = []
    tables.reserveCapacity(self.tableCount)

    let strides: [TableIndex:Int] = self.strides(tables: self.Valid, rows: self.Rows)

    let offset = 24 + tables.count * MemoryLayout<UInt32>.size
    var content = data[data.index(data.startIndex, offsetBy: offset)...]

    return Metadata.Tables.all.compactMap { tableType in
      guard (self.Valid & (1 << tableType.number)) == (1 << tableType.number) else { return nil }
      
      let records = self.Rows[(self.Valid & ((1 << tableType.number) - 1)).nonzeroBitCount]
      let table = tableType.init(from: content, rows: records, strides: strides)
      
      content = content[content.index(content.startIndex, offsetBy: table.data.count)...]
      return table
    }
  }
}

extension TablesStream {
  internal var StringIndexSize: Int { self.HeapSizes & 0x01 == 0x01 ? 4 : 2 }
  internal var GUIDIndexSize: Int { self.HeapSizes & 0x02 == 0x02 ? 4 : 2 }
  internal var BlobIndexSize: Int { self.HeapSizes & 0x04 == 0x04 ? 4 : 2 }
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
    strides[HasConstant] = TableIndexSize(HasConstant.self)
    strides[HasCustomAttribute] = TableIndexSize(HasCustomAttribute.self)
    strides[CustomAttributeType] = TableIndexSize(CustomAttributeType.self)
    strides[HasDeclSecurity] = TableIndexSize(HasDeclSecurity.self)
    strides[TypeDefOrRef] = TableIndexSize(TypeDefOrRef.self)
    strides[Implementation] = TableIndexSize(Implementation.self)
    strides[HasFieldMarshal] = TableIndexSize(HasFieldMarshal.self)
    strides[TypeOrMethodDef] = TableIndexSize(TypeOrMethodDef.self)
    strides[MemberForwarded] = TableIndexSize(MemberForwarded.self)
    strides[MemberRefParent] = TableIndexSize(MemberRefParent.self)
    strides[HasSemantics] = TableIndexSize(HasSemantics.self)
    strides[MethodDefOrRef] = TableIndexSize(MethodDefOrRef.self)
    strides[ResolutionScope] = TableIndexSize(ResolutionScope.self)

    return strides
  }
}
