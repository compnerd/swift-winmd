// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class Param: Table {
  public static var number: Int { 8 }

  /// Record Layout
  ///   Flags (2-byte bitmask of ParamAttributes)
  ///   Sequence (2-byte constant)
  ///   Name (String Heap Index)
  static let columns: [Column] = [
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Sequence", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
