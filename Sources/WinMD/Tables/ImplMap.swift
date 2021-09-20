// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class ImplMap: Table {
  public static var number: Int { 28 }

  /// Record Layout
  ///   MappingFlags (2-byte bitmask of PInvokeAttributes)
  ///   MemberForwarded (MemberForwarded Coded Index)
  ///   ImportName (String Heap Index)
  ///   ImportScope (ModuleRef Index)
  static let columns: [Column] = [
    Column(name: "MappingFlags", type: .constant(2)),
    Column(name: "MemberForwarded", type: .index(.coded(MemberForwarded.self))),
    Column(name: "ImportName", type: .index(.heap(.string))),
    Column(name: "ImportScope", type: .index(.simple(ModuleRef.self))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
