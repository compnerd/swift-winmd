// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (2-byte bitmask of PropertyAttributes)
///   Name (String Heap Index)
///   Type (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Flags", type: .constant(2)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Type", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.34.
public enum PropertyDef: TableSchema {
  public static var number: Int { 23 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.PropertyDef {
  public var Flags: CorPropertyAttr {
    CorPropertyAttr(rawValue: CorPropertyAttr.RawValue(columns[0]))
  }

  public var Name: String {
    strings[columns[1]]
  }
}
