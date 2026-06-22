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

/// CIL Table Representation
public protocol Table: AnyObject, Sendable {
  /// The CIL defined table number.
  static var number: Int { get }

  /// The columns of the table as defined by the CIL specification.
  static var columns: Array<Column> { get }

  /// The number of rows in the table.
  var rows: UInt32 { get }

  /// The data backing the table.
  var data: ArraySlice<UInt8> { get }

  /// Constructs a new table model.
  init(rows: UInt32, data: ArraySlice<UInt8>)
}

extension Table {
  public subscript(_ row: Int, _ database: Database) -> Record<Self> {
    let decoder = try! database.decoder

    var scan = 0
    let layout = Self.columns.map {
      let width = decoder.width(of: $0.type)
      defer { scan = scan + width }
      return (scan, width)
    }

    let begin = data.index(data.startIndex, offsetBy: row * scan)
    let end = data.index(begin, offsetBy: scan)
    let data = self.data[begin ..< end]

    let record = layout.map { (offset, size) in
      switch size {
      case 1: return Int(data[offset, UInt8.self])
      case 2: return Int(data[offset, UInt16.self])
      case 4: return Int(data[offset, UInt32.self])
      default: fatalError("unsupported column size '\(size)'")
      }
    }

    return Record<Self>(row, record, database, self)
  }
}
