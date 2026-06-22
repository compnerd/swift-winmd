// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Offset (4-byte constant)
///   Field (Field Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Offset", type: .constant(4)),
  Column(name: "Field", type: .index(.simple(Metadata.Tables.FieldDef.self))),
]

extension Metadata.Tables {
/// See §II.22.16.
public enum FieldLayout: TableSchema {
  public static var number: Int { 16 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.FieldLayout {
  public var Offset: UInt32 {
    UInt32(columns[0])
  }

  public var Field: Record<Metadata.Tables.FieldDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.FieldDef.self)[columns[1]]!
    }
  }
}
