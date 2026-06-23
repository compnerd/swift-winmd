// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (2-byte bitmask of FieldAttributes)
///   Name (String Heap Index)
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Flags", type: .constant(2)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Signature", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.15.
public enum FieldDef: TableSchema {
  public static var number: Int { 4 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.FieldDef {
  public var Flags: CorFieldAttr {
    CorFieldAttr(rawValue: CorFieldAttr.RawValue(columns[0]))
  }

  public var Name: String {
    strings[columns[1]]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { blobs[columns[2]] }
  }
}
