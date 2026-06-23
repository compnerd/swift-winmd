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

extension Column where Schema == Metadata.Tables.MethodDef {
  public static var RVA: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }

  public static var ImplFlags: Column<Schema, CorMethodImpl> {
    Column<Schema, CorMethodImpl>(1) {
      CorMethodImpl(rawValue: CorMethodImpl.RawValue($0.columns[1]))
    }
  }

  public static var Flags: Column<Schema, CorMethodAttr> {
    Column<Schema, CorMethodAttr>(2) {
      CorMethodAttr(rawValue: CorMethodAttr.RawValue($0.columns[2]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(3) { $0.strings[$0.columns[3]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.MethodDef {
  public static var Signature: BlobColumn<Schema> { BlobColumn<Schema>(4) }
}

extension Row where Schema == Metadata.Tables.MethodDef {
  public var RVA: UInt32 {
    self[.RVA]
  }

  public var ImplFlags: CorMethodImpl {
    self[.ImplFlags]
  }

  public var Flags: CorMethodAttr {
    self[.Flags]
  }

  public var Name: String {
    self[.Name]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { self[.Signature] }
  }

  public var ParamList: TableIterator<Metadata.Tables.Param> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try list(for: 5)
    }
  }
}
