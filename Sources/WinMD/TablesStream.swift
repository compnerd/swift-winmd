// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
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
public struct TablesStream {
  private let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public init?(from assembly: Assembly) {
    guard let stream = assembly.Metadata.stream(named: Metadata.Stream.Tables) else {
      return nil
    }
    self.init(data: stream)
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

  public var Tables: [Table] {
    let valid: UInt64 = Valid
    let rows: [UInt32] = Rows

    var tables: [Table] = []
    tables.reserveCapacity(valid.nonzeroBitCount)

    let offset = 24 + rows.count * MemoryLayout<UInt32>.size
    var content = data[data.index(data.startIndex, offsetBy: offset)...]
    let decoder: DatabaseDecoder = DatabaseDecoder(self)

    Metadata.Tables.forEach { table in
      if valid & (1 << table.number) == (1 << table.number) {
        let records = rows[(valid & ((1 << table.number) - 1)).nonzeroBitCount]

        let startIndex = content.startIndex
        let endIndex =
            content.index(startIndex,
                          offsetBy: Int(records) * decoder.stride(of: table))

        tables.append(table.init(rows: records,
                                 data: content.prefix(upTo: endIndex)))

        content = content[endIndex...]
      }
    }

    return tables
  }
}

extension TablesStream {
  public func forEach(_ body: (Table) throws -> Void) rethrows {
    return try self.Tables.forEach(body)
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
