// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.34.
public enum PropertyDef: TableSchema {
  public static var number: Int { 23 }

  /// Record Layout
  ///   Flags (2-byte bitmask of PropertyAttributes)
  ///   Name (String Heap Index)
  ///   Type (Blob Heap Index)
  public static let columns = [
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Type", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.PropertyDef {
  public var Flags: CorPropertyAttr {
    CorPropertyAttr(rawValue: CorPropertyAttr.RawValue(columns[0]))
  }

  public var Name: String {
    get throws(WinMDError) {
      try database.strings[columns[1]]
    }
  }
}
