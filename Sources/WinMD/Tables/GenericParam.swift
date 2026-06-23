// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Number (2-byte index)
///   Flags (2-byte bitmask of GenericParamAttributes)
///   Owner (TypeOrMethodDef Coded Index)
///   Name (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Number", type: .constant(2)),
  Field(name: "Flags", type: .constant(2)),
  Field(name: "Owner", type: .index(.coded(TypeOrMethodDef.self))),
  Field(name: "Name", type: .index(.heap(.string))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.20.
public enum GenericParam: TableSchema {
  public static var number: Int { 42 }

  /// Sorted by `Owner`. See §II.22.20.
  public static var key: Int? { 2 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.GenericParam {
  public var Number: UInt16 {
    UInt16(columns[0])
  }

  public var Flags: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: CorGenericParamAttr.RawValue(columns[1]))
  }

  public var Name: String {
    strings[columns[3]]
  }
}
