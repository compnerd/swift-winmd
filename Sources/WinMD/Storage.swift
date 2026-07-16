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
///
/// It is `package`-scoped (along with the members the query scan reads) so the
/// SQL-engine adapter, which conforms it to the engine's `Catalog`, reaches it
/// across the module boundary.
package struct Storage: ~Escapable {
  /// The backing buffer.
  internal let bytes: RawSpan

  /// The open tables of the database, borrowed from `Database.relations`.
  package let tables: Span<Table>

  /// The "Strings" (`#Strings`) heap.
  internal let strings: RawSpan

  /// The "Blob" (`#Blob`) heap.
  internal let blob: RawSpan

  /// The "GUID" (`#GUID`) heap.
  internal let guid: RawSpan

  /// The bitset of present tables (`TablesStream.Valid`).
  package let valid: UInt64

  /// The bitset of physically sorted tables (`TablesStream.Sorted`).
  ///
  /// Bit `N` is set iff table `N` is stored ordered by its sort key. A reverse
  /// foreign-key lookup against a sorted table is a binary search; against an
  /// unsorted one it is a linear scan.
  package let sorted: UInt64

  @_lifetime(copy bytes, copy relations, copy strings, copy blob, copy guid)
  package init(bytes: RawSpan, relations: Span<Table>, strings: RawSpan,
                blob: RawSpan, guid: RawSpan, valid: UInt64, sorted: UInt64) {
    self.bytes = bytes
    self.tables = relations
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
    // `tables` is dense and ordered by table number, so a present table's
    // slot is the number of present tables below it: the population count of
    // the lower bits of `Valid` (the same slot the row counts are read from).
    if valid & (1 << Schema.number) == 0 {
      throw .TableNotFound
    }
    let slot = (valid & ((1 << Schema.number) - 1)).nonzeroBitCount
    return TableIterator<Schema>(self, tables[slot], from: begin, to: end)
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
    if valid & (1 << schema.number) == 0 { return nil }
    let slot = (valid & ((1 << schema.number) - 1)).nonzeroBitCount
    let table = tables[slot]
    guard row >= 0, row < Int(table.rows) else { return nil }
    return Tuple(row, table, self)
  }

  /// The row a `TypeDefOrRef` coded index references, or `nil` if it is null.
  ///
  /// The storage-level sibling of `Database.resolve`: the index's tag selects
  /// `TypeDef`/`TypeRef`/`TypeSpec` and its row is 1-based, so this opens the
  /// named table at `row - 1`. A null reference (`row == 0`) yields `nil`. It is
  /// `package` so the `WinMDSynthesis` decode helper resolves the references a
  /// signature names against a borrowed `Storage` rather than a `Database`.
  @_lifetime(copy self)
  package func resolve(_ reference: TypeDefOrRef) throws(WinMDError) -> Tuple? {
    if reference.row == 0 { return nil }
    guard reference.tag < TypeDefOrRef.tables.count,
        let schema = TypeDefOrRef.tables[reference.tag] else {
      throw .BadImageFormat
    }
    guard let tuple = try tuple(reference.row - 1, of: schema) else {
      throw .BadImageFormat
    }
    return tuple
  }

  /// The rows of `schema` whose foreign-key `column` references `target`.
  ///
  /// The runtime (non-generic) sibling of `Database.referencing`: it opens the
  /// owning table from a `TableSchema.Type` value, computes the encoded key an
  /// owning row would hold to point at `target`, and returns the matching rows.
  /// The cost is `O(log n)` when the table is sorted on `column` and `O(rows)`
  /// otherwise; see `Database.referencing` for the encoding and the contract.
  @_lifetime(copy self)
  internal func referencing(_ target: borrowing Tuple,
                            in schema: TableSchema.Type,
                            by column: Int)
      throws(WinMDError) -> Filter<Cursor> {
    if valid & (1 << schema.number) == 0 {
      throw .TableNotFound
    }
    let slot = (valid & ((1 << schema.number) - 1)).nonzeroBitCount
    let table = tables[slot]

    // The stored cell an owning row holds to name `target`. ECMA-335 rows are
    // 1-based, so `target`'s 0-based row is stored as `target.row + 1`.
    let row = target.row + 1
    guard column >= 0, column < schema.fields.count else { throw .InvalidColumn }
    let encoded: Int = switch schema.fields[column].type {
    case let .index(.simple(referent)):
      // A simple index must name `target`'s own table.
      if referent == target.table.schema {
        row
      } else {
        throw .InvalidColumn
      }
    case let .index(.coded(coded)):
      // A coded index tags the row with the position of `target`'s table among
      // the index's tables: `(row << bits) | tag`.
      if let tag = tag(of: target.table.schema, in: coded) {
        (row << coded.bits) | tag
      } else {
        throw .InvalidColumn
      }
    default:
      throw .InvalidColumn
    }

    // A table physically sorted on this very column holds its matches as a
    // contiguous run; binary-search the `[lower, upper)` bound of `encoded`.
    if schema.key == column, sorted & (1 << schema.number) != 0 {
      let count = Int(table.rows)
      let lower = bound(table, column, encoded, count, strict: false)
      let upper = bound(table, column, encoded, count, strict: true)
      let cursor = Cursor(self, table, from: lower, to: upper)
      return Filter(cursor, { _ in true })
    }

    // Otherwise scan, matching the raw cell against the encoded key.
    let cursor = Cursor(self, table)
    return cursor.where { $0[column] == encoded }
  }

  /// The rows whose simple-index foreign-key column the `column` token
  /// addresses references `target`.
  ///
  /// Typed reverse navigation: the `Reference` token names the owning `Owner`
  /// table and the column's ordinal, so this resolves to the generic
  /// `referencing(_:in:by:)` with no string or ordinal at the call site.
  @_lifetime(copy self)
  internal func referencing<Owner, Target>(_ target: borrowing Row<Target>,
                                           by column: Reference<Owner, Target>)
      throws(WinMDError) -> Filter<Cursor> {
    try referencing(target.columns, in: Owner.self, by: column.ordinal)
  }

  /// The rows whose coded-index foreign-key column the `column` token addresses
  /// references `target`.
  @_lifetime(copy self)
  internal func referencing<Owner, Target>(_ target: borrowing Row<Target>,
                                           by column: CodedReference<Owner>)
      throws(WinMDError) -> Filter<Cursor> {
    try referencing(target.columns, in: Owner.self, by: column.ordinal)
  }

  /// The partition point of `column` against `value` over `[0, count)`.
  ///
  /// `column` is the sorted key of `table`, so its cells are non-decreasing.
  /// With `strict == false` this is the lower bound (the first row whose cell is
  /// `>= value`); with `strict == true` the upper bound (the first row whose
  /// cell is `> value`). Together they bracket the run equal to `value`. The
  /// search is `O(log count)`. Shared by the reverse-foreign-key lookup, the
  /// structured-query sorted-index executor (`Cursor.where(_: Predicate)`), and
  /// the SQL-engine adapter's seekable-column `bound`.
  package func bound(_ table: Table, _ column: Int, _ value: Int, _ count: Int,
                     strict: Bool) -> Int {
    var lo = 0
    var hi = count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      let cell = Tuple(mid, table, self)[column]
      if cell < value || (strict && cell == value) {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    return lo
  }

  /// The tag of `schema` within the tables of `coded`, or `nil` if absent.
  ///
  /// The tag is the position of the table in the coded index's table list,
  /// found by a linear metatype comparison (`Span` admits no `firstIndex`).
  private func tag(of schema: TableSchema.Type,
                   in coded: CodedIndex.Type) -> Int? {
    for index in 0 ..< coded.tables.count {
      if let table = coded.tables[index], table == schema {
        return index
      }
    }
    return nil
  }
}
