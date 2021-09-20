// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class ModuleRef: Table {
  public static var number: Int { 26 }

  /// Record Layout
  ///   Name (String Heap Index)
  static let columns: [Column] = [
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
