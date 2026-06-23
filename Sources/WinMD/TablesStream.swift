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
/// Used transiently during database parsing. It operates on the whole-buffer
/// span; `base` is the absolute byte offset of the stream within the buffer.
public struct TablesStream: ~Escapable {
  internal let bytes: RawSpan
  internal let base: Int
  /// The absolute byte offset of the end of the stream within the buffer.
  ///
  /// Table ranges are bounds-checked against this, not the whole buffer, so a
  /// malformed stream whose records run past its declared extent is rejected
  /// rather than read out of the adjacent heaps.
  internal let limit: Int

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan, base: Int, limit: Int) {
    self.bytes = bytes
    self.base = base
    self.limit = limit
  }

  @_lifetime(copy assembly)
  internal init(from assembly: Assembly) throws(WinMDError) {
    guard let stream =
        assembly.Metadata.stream(named: Metadata.Stream.Tables) else {
      throw .MissingTableStream
    }
    self.init(assembly.bytes, base: stream.offset,
              limit: stream.offset + stream.size)
  }

  public var MajorVersion: UInt8 {
    bytes.read(at: base + 4, as: UInt8.self)
  }

  public var MinorVersion: UInt8 {
    bytes.read(at: base + 5, as: UInt8.self)
  }

  public var HeapSizes: UInt8 {
    bytes.read(at: base + 6, as: UInt8.self)
  }

  public var Valid: UInt64 {
    bytes.read(at: base + 8, as: UInt64.self)
  }

  public var Sorted: UInt64 {
    bytes.read(at: base + 16, as: UInt64.self)
  }

  /// Opens the tables present in the stream.
  ///
  /// Each table's record layout is resolved against `catalog` once, here, and
  /// carried by the returned `Table` for the lifetime of the database. Each
  /// table records its absolute byte range within the backing buffer.
  internal func relations(_ catalog: borrowing PhysicalSchema)
      throws(WinMDError) -> Array<Table> {
    var relations = Array<Table>()
    relations.reserveCapacity(Valid.nonzeroBitCount)

    // The row data begins at offset 24 (see the structure layout above). The
    // rows are stored in a packed series of 32-bit words, one-per-table.
    // Offsets are absolute into the backing buffer.
    var offset = base + 24 + Valid.nonzeroBitCount * MemoryLayout<UInt32>.size

    for schema in kRegisteredTables {
      guard Valid & (1 << schema.number) == (1 << schema.number) else { continue }

      let slot = (Valid & ((1 << schema.number) - 1)).nonzeroBitCount
      let records =
          bytes.read(at: base + 24 + slot * MemoryLayout<UInt32>.size,
                     as: UInt32.self)

      // Resolve the record layout into a width bitset and a stride: bit `i` is
      // set iff column `i` is an index the catalog widened to 4 bytes.
      let columns = schema.columns
      var wide: UInt32 = 0
      var stride = 0
      for index in columns.indices {
        let type = columns[index].type
        let width = catalog.width(of: type)
        if case .index = type, width == 4 {
          wide |= 1 << index
        }
        stride = stride + width
      }
      let words = Int(records) * stride

      guard offset >= base, offset + words <= limit else {
        throw .InvalidIndex
      }

      relations.append(Table(schema, rows: records,
                             range: offset ..< offset + words,
                             wide: wide, stride: stride))
      offset = offset + words
    }

    return relations
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
