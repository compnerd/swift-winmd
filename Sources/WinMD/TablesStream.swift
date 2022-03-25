// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Tables Stream
///
/// The layout of the tables stream is as follows:
///
///     uint32_t Reserved           ; +0 [0]
///      uint8_t MajorVersion       ; +4
///      uint8_t MinorVersion       ; +5
///      uint8_t HeapSizes          ; +6
///      uint8_t Reserved           ; +7 [1]
///     uint64_t Valid              ; +8
///     uint64_t Sorted             ; +16
///     uint32_t Rows[]             ; +24
///      uint8_t Tables[]
///
/// The most common operation is access of `Rows` and `Tables`, which are both
/// computationally expensive.  The `Rows` computation is expensive due to the
/// allocation of the returned `Array`.  The `Tables` computation is expensive
/// as it requires the re-creationg of the table data.
public struct TablesStream {
  private let data: ArraySlice<UInt8>

  public init(data: ArraySlice<UInt8>) {
    self.data = data
  }

  public init(from assembly: Assembly) throws {
    guard let stream = assembly.Metadata.stream(named: Metadata.Stream.Tables) else {
      throw WinMDError.MissingTableStream
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

  // TODO(compnerd) add caching support for the `Tables` array.
  public var Tables: [Table] {
    get throws {
      var tables: [Table] = []
      tables.reserveCapacity(Valid.nonzeroBitCount)

      let rows: [UInt32] = Rows
      let decoder: DatabaseDecoder = DatabaseDecoder(self)

      // The row data begins at offset 24 (see the structure layout above).  The
      // rows are stored in a packaed series of 32-bit words, one-per-table.  We
      // re-use the `rows.count` as we have already computed the value for reuse
      // in the subseuquent loop.
      var offset: Int = 24 + rows.count * MemoryLayout<UInt32>.size

      for table in kRegisteredTables {
        guard Valid & (1 << table.number) == (1 << table.number) else { continue }

        let records: UInt32 =
            rows[(Valid & ((1 << table.number) - 1)).nonzeroBitCount]
        let words: Int = Int(records) * decoder.stride(of: table)

        guard let startIndex: ArraySlice<UInt8>.Index =
            data.index(data.startIndex, offsetBy: offset,
                       limitedBy: data.endIndex),
            let endIndex: ArraySlice<UInt8>.Index =
                data.index(startIndex, offsetBy: words,
                           limitedBy: data.endIndex) else {
          throw WinMDError.InvalidIndex
        }

        tables.append(table.init(rows: records, data: data[startIndex ..< endIndex]))
        offset = offset + Int(records) * decoder.stride(of: table)
      }

      return tables
    }
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
