// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The column type in a table.
///
/// All columns contain integral values. The width of the column may be
/// constant or a variable width index.
public enum ColumnType: Sendable {
  case constant(Int)
  case index(Index)
}

extension ColumnType: Hashable {
}

/// The schema of a CIL metadata table.
///
/// This is the static, compile-time description of a table as defined by the
/// CIL specification (ECMA-335 §II.22). It carries no data; an open table is
/// represented by a `Table`.
public protocol TableSchema: Sendable {
  /// The CIL defined table number.
  static var number: Int { get }

  /// The columns of the table as defined by the CIL specification.
  static var fields: Span<Field> { get }

  /// The narrow byte offset of column `i` within a record.
  ///
  /// This is the prefix sum of the preceding columns' narrow widths (a
  /// compile-time property of the schema); a database's wide indices shift it
  /// by its width bitset at read time.
  static func offset(_ i: Int) -> Int
}

/// An open metadata table: the records of one `TableSchema` within a database.
///
/// The physical layout of the records is resolved once when the table is opened
/// and shared by every record read from it. It is captured as a width bitset —
/// `wide` has bit `i` set iff column `i` is an index the catalog resolved to its
/// wide (4-byte) form — and the record `stride`. A column's offset and width are
/// recovered from the schema's narrow offsets and this bitset on demand.
public struct Table: Sendable {
  /// The schema this table is an instance of.
  internal let schema: TableSchema.Type

  /// The set of columns the catalog resolved to a wide (4-byte) index.
  ///
  /// Bit `i` is set iff column `i` is an index column whose width is 4 bytes in
  /// this database. A constant column's bit is always clear.
  internal let wide: UInt32

  /// The byte count of a single record.
  internal let stride: Int

  /// The number of records in the table.
  internal let rows: UInt32

  /// The absolute byte range of the records within the backing buffer.
  ///
  /// The records are a packed sequence of fixed-width tuples; `range` locates
  /// them within `Database.bytes`.
  internal let range: Range<Int>

  internal var number: Int { schema.number }

  internal init(_ schema: TableSchema.Type, rows: UInt32,
                range: Range<Int>, wide: UInt32, stride: Int) {
    self.schema = schema
    self.wide = wide
    self.stride = stride
    self.rows = rows
    self.range = range
  }

  /// The byte offset of column `i` within a record.
  ///
  /// Each wide index before column `i` shifts it by two bytes beyond its narrow
  /// offset.
  internal func offset(_ i: Int) -> Int {
    schema.offset(i) + 2 * (wide & ((1 << i) - 1)).nonzeroBitCount
  }

  /// The byte width of column `i`.
  ///
  /// A column widens by two bytes beyond its narrow width when its bit is set.
  internal func width(_ i: Int) -> Int {
    schema.fields[i].width + 2 * Int((wide >> i) & 1)
  }
}

extension Table: CustomStringConvertible {
  public var description: String {
    String(describing: schema)
  }
}
