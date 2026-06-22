// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (2-byte bitmask of PropertyAttributes)
///   Name (String Heap Index)
///   Type (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Flags", type: .constant(2)),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "Type", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.34.
public enum PropertyDef: TableSchema {
  public static var number: Int { 23 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
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
