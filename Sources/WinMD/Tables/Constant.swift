// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class Constant: Table {
  public static var number: Int { 11 }

  /// Record Layout
  ///   Type (1-byte, 1-byte padding zero)
  ///   Parent (HasConstant Coded Index)
  ///   Value (Blob Heap Index)
  static let columns: [Column] = [
    Column(name: "Type", type: .constant(1)),
    Column(name: StaticString(), type: .constant(1)),
    Column(name: "Parent", type: .index(.coded(HasConstant.self))),
    Column(name: "Value", type: .index(.heap(.blob))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init( rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
