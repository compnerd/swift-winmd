// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.35.
public final class PropertyMap: Table {
  public static var number: Int { 21 }

  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   PropertyList (Property Index)
  public static let columns: [Column] = [
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
    Column(name: "PropertyList", type: .index(.simple(PropertyDef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
