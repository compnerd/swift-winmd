// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A borrowed, ARC-free projection of a database's readable state.
///
/// `Database` owns `relations: Array<Table>`, the one ARC-bearing type in the
/// library. The row cursors only ever read out of the backing buffer and the
/// open tables, so rather than carry the whole `Database` — which would retain
/// and release the relations buffer on every cursor copy — they carry this
/// trivial view: a `Span<Table>` into the relations plus the read spans. The
/// existing `~Escapable` lifetime dependency keeps it sound.
internal struct Storage: ~Escapable {
  /// The backing buffer.
  internal let bytes: RawSpan

  /// The open tables of the database, borrowed from `Database.relations`.
  internal let relations: Span<Table>

  /// The "Strings" (`#Strings`) heap.
  internal let strings: RawSpan

  /// The "Blob" (`#Blob`) heap.
  internal let blob: RawSpan

  /// The "GUID" (`#GUID`) heap.
  internal let guid: RawSpan

  /// The bitset of present tables (`TablesStream.Valid`).
  internal let valid: UInt64

  /// The bitset of physically sorted tables (`TablesStream.Sorted`).
  ///
  /// Bit `N` is set iff table `N` is stored ordered by its sort key. A reverse
  /// foreign-key lookup against a sorted table is a binary search; against an
  /// unsorted one it is a linear scan.
  internal let sorted: UInt64

  @_lifetime(copy bytes, copy relations, copy strings, copy blob, copy guid)
  internal init(bytes: RawSpan, relations: Span<Table>, strings: RawSpan,
                blob: RawSpan, guid: RawSpan, valid: UInt64, sorted: UInt64) {
    self.bytes = bytes
    self.relations = relations
    self.strings = strings
    self.blob = blob
    self.guid = guid
    self.valid = valid
    self.sorted = sorted
  }

  @_lifetime(copy self)
  internal func rows<Schema: TableSchema>(of schema: Schema.Type,
                                          from begin: Int = 0,
                                          to end: Int? = nil) throws(WinMDError)
      -> TableIterator<Schema> {
    // `relations` is dense and ordered by table number, so a present table's
    // slot is the number of present tables below it: the population count of
    // the lower bits of `Valid` (the same slot the row counts are read from).
    guard valid & (1 << Schema.number) != 0 else {
      throw .TableNotFound
    }
    let slot = (valid & ((1 << Schema.number) - 1)).nonzeroBitCount
    return TableIterator<Schema>(self, relations[slot], from: begin, to: end)
  }

  /// The `Tuple` at the 0-based `row` of the table described by `schema`.
  ///
  /// This is the runtime (non-generic) sibling of `rows(of:)`: it opens a table
  /// from a `TableSchema.Type` *value* rather than a static `Schema`, which is
  /// what foreign-key navigation needs — the target table of an index is only
  /// known at runtime, off the column's `Index`. The present table's slot is
  /// found by the same population-count math as `rows(of:)`, off `schema.number`
  /// read from the metatype. `row` is bounds-checked against the table's row
  /// count; an absent table or an out-of-range row yields `nil`.
  @_lifetime(copy self)
  internal func tuple(_ row: Int, of schema: TableSchema.Type)
      throws(WinMDError) -> Tuple? {
    guard valid & (1 << schema.number) != 0 else { return nil }
    let slot = (valid & ((1 << schema.number) - 1)).nonzeroBitCount
    let table = relations[slot]
    guard row >= 0, row < Int(table.rows) else { return nil }
    return Tuple(row, table, self)
  }
}
