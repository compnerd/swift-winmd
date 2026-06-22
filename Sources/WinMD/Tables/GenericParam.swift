// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Number (2-byte index)
///   Flags (2-byte bitmask of GenericParamAttributes)
///   Owner (TypeOrMethodDef Coded Index)
///   Name (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Number", type: .constant(2)),
  Column(name: "Flags", type: .constant(2)),
  Column(name: "Owner", type: .index(.coded(TypeOrMethodDef.self))),
  Column(name: "Name", type: .index(.heap(.string))),
]

extension Metadata.Tables {
/// See §II.22.20.
public enum GenericParam: TableSchema {
  public static var number: Int { 42 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.GenericParam {
  public var Number: UInt16 {
    UInt16(columns[0])
  }

  public var Flags: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: CorGenericParamAttr.RawValue(columns[1]))
  }

  public var Name: String {
    get throws(WinMDError) {
      try database.strings[columns[3]]
    }
  }
}
