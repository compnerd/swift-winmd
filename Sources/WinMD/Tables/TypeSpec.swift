// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class TypeSpec: Table {
  public static var number: Int { 27 }

  /// Record Layout
  ///   Signature (Blob Heap Index)
  static let columns: [Column] = [
    Column(name: "Signature", type: .index(.heap(.blob))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
