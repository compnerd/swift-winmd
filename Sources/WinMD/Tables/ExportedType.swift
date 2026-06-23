// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (4-byte bitmask TypeAttributes)
///   TypeDefId (4-byte value, foreign TypeDef Index)
///   TypeName (String Heap Index)
///   TypeNamespace (String Heap Index)
///   Implementation (Implementation Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Flags", type: .constant(4)),
  Field(name: "TypeDefId", type: .constant(4)),
  Field(name: "TypeName", type: .index(.heap(.string))),
  Field(name: "TypeNamespace", type: .index(.heap(.string))),
  Field(name: "Implementation", type: .index(.coded(Implementation.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.14.
public enum ExportedType: TableSchema {
  public static var number: Int { 39 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.ExportedType {
  public var Flags: CorTypeAttr {
    CorTypeAttr(rawValue: CorTypeAttr.RawValue(columns[0]))
  }

  public var TypeName: String {
    strings[columns[2]]
  }

  public var TypeNamespace: String {
    strings[columns[3]]
  }
}
