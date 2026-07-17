// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Offset (4-byte constant)
///   Column (Column Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Offset", type: .constant(4)),
  Field(name: "Column", type: .index(.simple(Metadata.Tables.FieldDef.self))),
]

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.16.
public enum FieldLayout: TableSchema {
  public static var number: Int { 16 }

  /// Sorted by `Column`. See §II.22.16.
  public static var key: Int? { 1 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.FieldLayout {
  public static var Offset: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }
}

extension Reference where Schema == Metadata.Tables.FieldLayout {
  public static var Column: Reference<Schema, Metadata.Tables.FieldDef> {
    Reference<Schema, Metadata.Tables.FieldDef>(1)
  }
}

extension Row where Schema == Metadata.Tables.FieldLayout {
  public var Offset: UInt32 {
    self[.Offset]
  }

  public var Column: Row<Metadata.Tables.FieldDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try required(.Column)
    }
  }
}
