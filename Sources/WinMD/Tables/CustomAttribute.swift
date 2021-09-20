// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class CustomAttribute: Table {
  public static var number: Int { 12 }

  /// Record Layout
  ///   Parent (HasCustomAttribute Coded Index)
  ///   Type (CustomAttributeType Coded Index)
  ///   Value (Blob Heap Index)
  static let columns: [Column] = [
    Column(name: "Parent", type: .index(.coded(HasCustomAttribute.self))),
    Column(name: "Type", type: .index(.coded(CustomAttributeType.self))),
    Column(name: "Value", type: .index(.heap(.blob))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
