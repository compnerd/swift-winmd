// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.UUID

extension Metadata.Tables {
/// See §II.22.30.
public final class Module: Table {
  public static var number: Int { 0 }

  /// Record Layout
  ///   Generation (2-byte value, reserved, MBZ)
  ///   Name (String Heap Index)
  ///   Mvid (Module Version ID) (GUID Heap Index)
  ///   EncId (GUID Heap Index, reserved, MBZ)
  ///   EncBaseId (GUID Heap Index, reserved, MBZ)
  public static let columns: [Column] = [
    Column(name: "Generation", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Mvid", type: .index(.heap(.guid))),
    Column(name: "EncId", type: .index(.heap(.guid))),
    Column(name: "EncBaseId", type: .index(.heap(.guid))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.Module {
  public var Generation: UInt16 {
    UInt16(columns[0])
  }

  public var Name: String {
    get throws {
      try database.strings[columns[1]]
    }
  }

  public var Mvid: UUID {
    get throws {
      try database.guids[columns[2]]
    }
  }

  public var EncId: UUID {
    get throws {
      try database.guids[columns[3]]
    }
  }

  public var EncBaseId: UUID {
    get throws {
      try database.guids[columns[4]]
    }
  }
}
