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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.15.
public enum FieldDef: TableSchema {
  public static var number: Int { 4 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.FieldDef {
  public static var Flags: Column<Schema, CorFieldAttr> {
    Column<Schema, CorFieldAttr>(0) {
      CorFieldAttr(rawValue: CorFieldAttr.RawValue($0.columns[0]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.FieldDef {
  public static var Signature: BlobColumn<Schema> {
    BlobColumn<Schema>(2)
  }
}

extension Row where Schema == Metadata.Tables.FieldDef {
  public var Flags: CorFieldAttr {
    self[.Flags]
  }

  public var Name: String {
    self[.Name]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { self[.Signature] }
  }
}
