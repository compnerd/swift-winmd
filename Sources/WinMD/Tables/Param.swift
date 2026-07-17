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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.33.
public enum Param: TableSchema {
  public static var number: Int { 8 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.Param {
  public static var Flags: Column<Schema, CorParamAttr> {
    Column<Schema, CorParamAttr>(0) {
      CorParamAttr(rawValue: CorParamAttr.RawValue($0.columns[0]))
    }
  }

  public static var Sequence: Column<Schema, UInt16> {
    Column<Schema, UInt16>(1) { UInt16($0.columns[1]) }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(2) { $0.strings[$0.columns[2]] }
  }
}

extension Row where Schema == Metadata.Tables.Param {
  public var Flags: CorParamAttr {
    self[.Flags]
  }

  public var Sequence: UInt16 {
    self[.Sequence]
  }

  public var Name: String {
    self[.Name]
  }
}
