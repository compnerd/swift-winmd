// Copyright © 2021 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The column type in a table.
/// 
/// All columns contain integral values.  The width of the column may be
/// constant or a variable width index.
internal enum ColumnType {
  case constant(Int)
  case index(Index)
}

extension ColumnType: Hashable {
}

/// A table column.
/// 
/// Accessible columns have a name which the user can use to reference the
/// column, and a type which indicates how to read the value of the column.
internal struct Column {
  let name: StaticString
  let type: ColumnType
}

/// CIL Table Representation
internal protocol Table: AnyObject {
  /// The CIL defined table number.
  static var number: Int { get }

  /// The columns of the table as defined by the CIL specification.
  static var columns: [Column] { get }

  /// The number of rows in the table.
  var rows: UInt32 { get }

  /// The data backing the table.
  var data: ArraySlice<UInt8> { get }

  /// Constructs a new table model.
  init(rows: UInt32, data: ArraySlice<UInt8>)
}
