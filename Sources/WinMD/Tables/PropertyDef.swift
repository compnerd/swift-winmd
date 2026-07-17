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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.34.
public enum PropertyDef: TableSchema {
  public static var number: Int { 23 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.PropertyDef {
  public static var Flags: Column<Schema, CorPropertyAttr> {
    Column<Schema, CorPropertyAttr>(0) {
      CorPropertyAttr(rawValue: CorPropertyAttr.RawValue($0.columns[0]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.PropertyDef {
  public static var `Type`: BlobColumn<Schema> { BlobColumn<Schema>(2) }
}

extension Row where Schema == Metadata.Tables.PropertyDef {
  public var Flags: CorPropertyAttr {
    self[.Flags]
  }

  public var Name: String {
    self[.Name]
  }
}
