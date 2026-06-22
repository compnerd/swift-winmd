// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.16.
public enum FieldLayout: TableSchema {
  public static var number: Int { 16 }

  /// Record Layout
  ///   Offset (4-byte constant)
  ///   Field (Field Index)
  public static let columns = [
    Column(name: "Offset", type: .constant(4)),
    Column(name: "Field", type: .index(.simple(FieldDef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.FieldLayout {
  public var Offset: UInt32 {
    UInt32(columns[0])
  }

  public var Field: Record<Metadata.Tables.FieldDef> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.FieldDef.self)[columns[1]]!
    }
  }
}
