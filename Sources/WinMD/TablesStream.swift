/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
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
  private let data: Data

  public init(data: Data) {
    self.data = data
  }

  public var MajorVersion: UInt8 {
    return data.read(offset: 4)
  }

  public var MinorVersion: UInt8 {
    return data.read(offset: 5)
  }

  public var HeapSizes: UInt8 {
    return data.read(offset: 6)
  }

  public var Valid: UInt64 {
    return data.read(offset: 8)
  }

  public var Sorted: UInt64 {
    return data.read(offset: 16)
  }

  public var Rows: [UInt32] {
    let tables: Int = Valid.nonzeroBitCount
    let nbytes: Int = tables * MemoryLayout<UInt32>.size
    let begin: Data.Index = data.index(data.startIndex, offsetBy: 24)
    let end: Data.Index = data.index(begin, offsetBy: nbytes)
    return Array<UInt32>(unsafeUninitializedCapacity: tables) {
      data.copyBytes(to: $0, from: begin ..< end)
      $1 = tables
    }
  }

  public var Tables: [Table] {
    let valid: UInt64 = Valid
    let rows: [UInt32] = Rows

    var tables: [Table] = []
    tables.reserveCapacity(valid.nonzeroBitCount)

    let strides: [TableIndex:Int] = self.strides(tables: valid, rows: rows)

    let offset = 24 + valid.nonzeroBitCount * MemoryLayout<UInt32>.size 
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
