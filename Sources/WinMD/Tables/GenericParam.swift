// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.20.
public final class GenericParam: Table {
  public static var number: Int { 42 }

  /// Record Layout
  ///   Number (2-byte index)
  ///   Flags (2-byte bitmask of GenericParamAttributes)
  ///   Owner (TypeOrMethodDef Coded Index)
  ///   Name (String Heap Index)
  public static let columns: [Column] = [
    Column(name: "Number", type: .constant(2)),
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Owner", type: .index(.coded(TypeOrMethodDef.self))),
    Column(name: "Name", type: .index(.heap(.string))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
