// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class PropertyDef: Table {
  public static var number: Int { 23 }

  /// Record Layout
  ///   Flags (2-byte bitmask of PropertyAttributes)
  ///   Name (String Heap Index)
  ///   Type (Blob Heap Index)
  static let columns: [Column] = [
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Type", type: .index(.heap(.blob))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
