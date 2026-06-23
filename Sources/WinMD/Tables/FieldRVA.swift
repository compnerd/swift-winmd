// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   RVA (4-byte constant)
///   Column (Column Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "RVA", type: .constant(4)),
  Field(name: "Column", type: .index(.simple(Metadata.Tables.FieldDef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.18.
public enum FieldRVA: TableSchema {
  public static var number: Int { 29 }

  /// Sorted by `Column`. See §II.22.18.
  public static var key: Int? { 1 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.FieldRVA {
  public static var RVA: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }
}

extension Row where Schema == Metadata.Tables.FieldRVA {
  public var RVA: UInt32 {
    self[.RVA]
  }

  public var Column: Row<Metadata.Tables.FieldDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.FieldDef.self)[columns[1]]!
    }
  }
}
