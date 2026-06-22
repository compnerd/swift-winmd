// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The physical layout of a table's records.
///
/// Within a given database every column has a fixed width, so a record is a
/// packed fixed-width tuple: column `i` lives at a constant byte offset within
/// the record, and the record itself begins at `row * stride`. The offsets are
/// pre-summed so that locating a column is constant time rather than a walk over
/// the widths of the preceding columns.
internal struct TupleDescriptor {
  /// The byte count of a single record.
  internal let stride: Int

  /// The byte offset and width of each column, in column order.
  internal let columns: Array<(offset: Int, width: Int)>

  internal init(_ columns: Span<Column>, _ decoder: DatabaseDecoder) {
    var offset = 0
    var columns_ = Array<(offset: Int, width: Int)>()
    columns_.reserveCapacity(columns.count)
    for index in columns.indices {
      let width = decoder.width(of: columns[index].type)
      columns_.append((offset, width))
      offset = offset + width
    }
    self.columns = columns_
    self.stride = offset
  }
}
