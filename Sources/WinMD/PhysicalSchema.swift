// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The physical schema of a database instance.
///
/// ECMA-335 §II.24 describes the on-disk physical layout of the metadata: the
/// width of each heap and coded index depends on which tables are present and
/// their row counts. This is the database's physical schema (the RDBMS catalog
/// loaded when the database is opened) — immutable data with no identity. It is
/// a thin view over the tables stream; widths are derived from the stream bytes
/// on demand rather than cached.
public struct PhysicalSchema: ~Escapable {
  private let stream: TablesStream

  @_lifetime(copy stream)
  public init(_ stream: TablesStream) {
    self.stream = stream
  }
}

extension PhysicalSchema {
  /// The number of rows in a table, read from the stream's row-count array.
  ///
  /// `Valid` is a bitmask of the present tables; the row counts are stored in
  /// table-number order for the present tables only, so the slot for a table is
  /// the population count of the lower bits of `Valid`.
  internal func rows(of number: Int) -> UInt32 {
    let slot = (stream.Valid & ((1 << number) - 1)).nonzeroBitCount
    let offset = stream.base + 24 + slot * MemoryLayout<UInt32>.size
    return stream.bytes.read(at: offset, as: UInt32.self)
  }

  /// The width, in bytes, of a coded index over `index`'s tables.
  private func width<T: CodedIndex>(of index: T.Type) -> Int {
    let valid = stream.Valid
    let tables = index.tables
    // The number of tables that the index can refer to is the number of bits
    // required to select between then - [0 ..< count].
    let bits = (tables.count - 1).nonzeroBitCount
    // The remaining bits serve as the index for the selected table.
    let range = 1 << (16 - bits)
    for tag in tables.indices {
      let table = tables[tag]
      // A table is not required to be present; if it is absent the number of
      // rows that can be indexed is unknown, so we must assume a wide index. A
      // present table forces the full 32-bit index once its row count reaches
      // the range; below it the compressed width suffices.
      guard valid & (1 << table.number) != 0 else { return 4 }
      if rows(of: table.number) >= range { return 4 }
    }
    return 2
  }
}

extension PhysicalSchema {
  /// The width, in bytes, of a given index.
  internal func width(of index: Index) -> Int {
    switch index {
    case .heap(.blob):
      stream.BlobIndexSize
    case .heap(.guid):
      stream.GUIDIndexSize
    case .heap(.string):
      stream.StringIndexSize
    case let .simple(table):
      // An absent table has no rows, so a compressed (2-byte) index suffices.
      stream.Valid & (1 << table.number) == 0
          || rows(of: table.number) < (1 << 16) ? 2 : 4
    case let .coded(coded):
      width(of: coded)
    }
  }

  /// The width, in bytes, of a given column type.
  internal func width(of type: ColumnType) -> Int {
    switch type {
    case let .constant(size):
      size
    case let .index(index):
      width(of: index)
    }
  }
}
