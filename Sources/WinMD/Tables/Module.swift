// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import struct Foundation.UUID

/// Record Layout
///   Generation (2-byte value, reserved, MBZ)
///   Name (String Heap Index)
///   Mvid (Module Version ID) (GUID Heap Index)
///   EncId (GUID Heap Index, reserved, MBZ)
///   EncBaseId (GUID Heap Index, reserved, MBZ)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Generation", type: .constant(2)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Mvid", type: .index(.heap(.guid))),
  Field(name: "EncId", type: .index(.heap(.guid))),
  Field(name: "EncBaseId", type: .index(.heap(.guid))),
]

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.30.
public enum Module: TableSchema {
  public static var number: Int { 0 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.Module {
  public static var Generation: Column<Schema, UInt16> {
    Column<Schema, UInt16>(0) { UInt16($0.columns[0]) }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }
}

extension Row where Schema == Metadata.Tables.Module {
  public var Generation: UInt16 {
    self[.Generation]
  }

  public var Name: String {
    self[.Name]
  }

  public var Mvid: UUID {
    get throws(WinMDError) {
      try guids[columns[2]]
    }
  }

  public var EncId: UUID {
    get throws(WinMDError) {
      try guids[columns[3]]
    }
  }

  public var EncBaseId: UUID {
    get throws(WinMDError) {
      try guids[columns[4]]
    }
  }
}
