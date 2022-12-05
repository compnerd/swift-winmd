// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.33.
public final class Param: Table {
  public static var number: Int { 8 }

  /// Record Layout
  ///   Flags (2-byte bitmask of ParamAttributes)
  ///   Sequence (2-byte constant)
  ///   Name (String Heap Index)
  public static let columns: [Column] = [
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Sequence", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.Param {
  public var Flags: CorParamAttr {
    .init(rawValue: CorParamAttr.RawValue(self.columns[0]))
  }

  public var Sequence: UInt16 {
    UInt16(self.columns[1])
  }

  public var Name: String {
    get throws {
      try self.database.strings[self.columns[2]]
    }
  }
}
