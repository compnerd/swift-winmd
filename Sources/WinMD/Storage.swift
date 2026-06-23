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

  @_lifetime(copy bytes, copy relations, copy strings, copy blob, copy guid)
  internal init(bytes: RawSpan, relations: Span<Table>, strings: RawSpan,
                blob: RawSpan, guid: RawSpan, valid: UInt64) {
    self.bytes = bytes
    self.relations = relations
    self.strings = strings
    self.blob = blob
    self.guid = guid
    self.valid = valid
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
}
