// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   RVA (4-byte constant)
///   ImplFlags (2-byte bitmask of MethodImplAttributes)
///   Flags (2-byte bitmask of MethodAttributes)
///   Name (String Heap Index)
///   Signature (Blob Heap Index)
///   ParamList (Param Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "RVA", type: .constant(4)),
  Field(name: "ImplFlags", type: .constant(2)),
  Field(name: "Flags", type: .constant(2)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Signature", type: .index(.heap(.blob))),
  Field(name: "ParamList", type: .index(.simple(Metadata.Tables.Param.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.26.
public enum MethodDef: TableSchema {
  public static var number: Int { 6 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.MethodDef {
  public var RVA: UInt32 {
    UInt32(columns[0])
  }

  public var ImplFlags: CorMethodImpl {
    CorMethodImpl(rawValue: CorMethodImpl.RawValue(columns[1]))
  }

  public var Flags: CorMethodAttr {
    CorMethodAttr(rawValue: CorMethodAttr.RawValue(columns[2]))
  }

  public var Name: String {
    strings[columns[3]]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { blobs[columns[4]] }
  }

  public var ParamList: TableIterator<Metadata.Tables.Param> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try list(for: 5)
    }
  }
}
