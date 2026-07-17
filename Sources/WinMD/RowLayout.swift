// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Field {
  /// The narrow width, in bytes, of the column.
  ///
  /// A constant column is always its declared size. An index column is assumed
  /// to be its compressed (2-byte) form; the extra two bytes of a wide index are
  /// accounted for separately via the per-table width bitset.
  internal var width: Int {
    switch type {
    case let .constant(size):
      size
    case .index:
      2
    }
  }
}

/// The narrow byte offset of each column, in column order.
///
/// Field `i`'s narrow offset is the prefix sum of the narrow widths of the
/// fields preceding it. These offsets are a compile-time property of a schema;
/// the wide indices of a particular database shift them by the width bitset at
/// read time.
internal func offsets<let N: Int>(of fields: InlineArray<N, Field>)
    -> InlineArray<N, Int> {
  InlineArray<N, Int> { index in
    var offset = 0
    for position in 0 ..< index {
      offset = offset + fields[position].width
    }
    return offset
  }
}
