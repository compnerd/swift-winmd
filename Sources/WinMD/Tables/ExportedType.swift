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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.14.
public enum ExportedType: TableSchema {
  public static var number: Int { 39 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.ExportedType {
  public static var Flags: Column<Schema, CorTypeAttr> {
    Column<Schema, CorTypeAttr>(0) {
      CorTypeAttr(rawValue: CorTypeAttr.RawValue($0.columns[0]))
    }
  }

  public static var TypeDefId: Column<Schema, UInt32> {
    Column<Schema, UInt32>(1) { UInt32($0.columns[1]) }
  }

  public static var TypeName: Column<Schema, String> {
    Column<Schema, String>(2) { $0.strings[$0.columns[2]] }
  }

  public static var TypeNamespace: Column<Schema, String> {
    Column<Schema, String>(3) { $0.strings[$0.columns[3]] }
  }
}

extension CodedReference where Schema == Metadata.Tables.ExportedType {
  public static var Implementation: CodedReference<Schema> {
    CodedReference<Schema>(4)
  }
}

extension Row where Schema == Metadata.Tables.ExportedType {
  public var Flags: CorTypeAttr {
    self[.Flags]
  }

  public var TypeName: String {
    self[.TypeName]
  }

  public var TypeNamespace: String {
    self[.TypeNamespace]
  }
}
