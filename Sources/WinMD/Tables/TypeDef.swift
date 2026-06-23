// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (4-byte bitmask of TypeAttributes)
///   TypeName (String Heap Index)
///   TypeNamespace (String Heap Index)
///   Extends (TypeDefOrRef Coded Index)
///   FieldList (Column Index)
///   MethodList (MethodDef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Flags", type: .constant(4)),
  Field(name: "TypeName", type: .index(.heap(.string))),
  Field(name: "TypeNamespace", type: .index(.heap(.string))),
  Field(name: "Extends", type: .index(.coded(TypeDefOrRef.self))),
  Field(name: "FieldList", type: .index(.simple(Metadata.Tables.FieldDef.self))),
  Field(name: "MethodList", type: .index(.simple(Metadata.Tables.MethodDef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.37.
public enum TypeDef: TableSchema {
  public static var number: Int { 2 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.TypeDef {
  public static var Flags: Column<Schema, CorTypeAttr> {
    Column<Schema, CorTypeAttr>(0) {
      CorTypeAttr(rawValue: CorTypeAttr.RawValue($0.columns[0]))
    }
  }

  public static var TypeName: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }

  public static var TypeNamespace: Column<Schema, String> {
    Column<Schema, String>(2) { $0.strings[$0.columns[2]] }
  }
}

extension CodedReference where Schema == Metadata.Tables.TypeDef {
  public static var Extends: CodedReference<Schema> {
    CodedReference<Schema>(3)
  }
}

extension List where Schema == Metadata.Tables.TypeDef {
  public static var FieldList: List<Schema, Metadata.Tables.FieldDef> {
    List<Schema, Metadata.Tables.FieldDef>(4)
  }

  public static var MethodList: List<Schema, Metadata.Tables.MethodDef> {
    List<Schema, Metadata.Tables.MethodDef>(5)
  }
}

extension Row where Schema == Metadata.Tables.TypeDef {
  public var Flags: CorTypeAttr {
    self[.Flags]
  }

  public var TypeName: String {
    self[.TypeName]
  }

  public var TypeNamespace: String {
    self[.TypeNamespace]
  }

  public var FieldList: TableIterator<Metadata.Tables.FieldDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try list(.FieldList)
    }
  }

  public var MethodList: TableIterator<Metadata.Tables.MethodDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try list(.MethodList)
    }
  }
}
