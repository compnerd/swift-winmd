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
private let _columns: InlineArray<_, Column> = [
  Column(name: "Generation", type: .constant(2)),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "Mvid", type: .index(.heap(.guid))),
  Column(name: "EncId", type: .index(.heap(.guid))),
  Column(name: "EncBaseId", type: .index(.heap(.guid))),
]

extension Metadata.Tables {
/// See §II.22.30.
public enum Module: TableSchema {
  public static var number: Int { 0 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Row where Schema == Metadata.Tables.Module {
  public var Generation: UInt16 {
    UInt16(columns[0])
  }

  public var Name: String {
    database.strings[columns[1]]
  }

  public var Mvid: UUID {
    get throws(WinMDError) {
      try database.guids[columns[2]]
    }
  }

  public var EncId: UUID {
    get throws(WinMDError) {
      try database.guids[columns[3]]
    }
  }

  public var EncBaseId: UUID {
    get throws(WinMDError) {
      try database.guids[columns[4]]
    }
  }
}
