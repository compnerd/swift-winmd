// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The column type in a table.
///
/// All columns contain integral values. The width of the column may be
/// constant or a variable width index.
internal enum ColumnType: Sendable {
  case constant(Int)
  case index(Index)
}

extension ColumnType: Hashable {
}

/// A table column.
///
/// Accessible columns have a name which the user can use to reference the
/// column, and a type which indicates how to read the value of the column.
public struct Column: Sendable {
  let name: StaticString
  let type: ColumnType
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
  static var columns: Span<Column> { get }
}

/// An open metadata table: the records of one `TableSchema` within a database.
///
/// The physical layout of the records — the `TupleDescriptor` — is resolved
/// once when the table is opened and shared by every record read from it.
public final class Table {
  /// The schema this table is an instance of.
  internal let schema: TableSchema.Type

  /// The physical layout of the table's records.
  internal let descriptor: TupleDescriptor

  /// The number of records in the table.
  internal let rows: UInt32

  /// The records, as a packed sequence of fixed-width tuples.
  internal let data: ArraySlice<UInt8>

  internal var number: Int { schema.number }

  internal init(_ schema: TableSchema.Type, rows: UInt32,
                data: ArraySlice<UInt8>, descriptor: TupleDescriptor) {
    self.schema = schema
    self.descriptor = descriptor
    self.rows = rows
    self.data = data
  }
}

extension Table: CustomStringConvertible {
  public var description: String {
    String(describing: schema)
  }
}
