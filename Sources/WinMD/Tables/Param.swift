// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.33.
public enum Param: TableSchema {
  public static var number: Int { 8 }

  /// Record Layout
  ///   Flags (2-byte bitmask of ParamAttributes)
  ///   Sequence (2-byte constant)
  ///   Name (String Heap Index)
  public static let columns = [
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Sequence", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
  ]
}
}

extension Record where Schema == Metadata.Tables.Param {
  public var Flags: CorParamAttr {
    CorParamAttr(rawValue: CorParamAttr.RawValue(columns[0]))
  }

  public var Sequence: UInt16 {
    UInt16(columns[1])
  }

  public var Name: String {
    get throws(WinMDError) {
      try database.strings[columns[2]]
    }
  }
}
