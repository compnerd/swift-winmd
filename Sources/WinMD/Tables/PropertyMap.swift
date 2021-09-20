// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class PropertyMap: Table {
  public static var number: Int { 21 }

  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   PropertyList (Property Index)
  static let columns: [Column] = [
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
    Column(name: "PropertyList", type: .index(.simple(PropertyDef.self))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
