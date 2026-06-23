// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (2-byte bitmask of ParamAttributes)
///   Sequence (2-byte constant)
///   Name (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Flags", type: .constant(2)),
  Field(name: "Sequence", type: .constant(2)),
  Field(name: "Name", type: .index(.heap(.string))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.33.
public enum Param: TableSchema {
  public static var number: Int { 8 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.Param {
  public var Flags: CorParamAttr {
    CorParamAttr(rawValue: CorParamAttr.RawValue(columns[0]))
  }

  public var Sequence: UInt16 {
    UInt16(columns[1])
  }

  public var Name: String {
    strings[columns[2]]
  }
}
