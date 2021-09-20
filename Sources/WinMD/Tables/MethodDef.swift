// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class MethodDef: Table {
  public static var number: Int { 6 }

  /// Record Layout
  ///   RVA (4-byte constant)
  ///   ImplFlags (2-byte bitmask of MethodImplAtttributes)
  ///   Flags (2-byte bitmask of MethodAttributes)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  ///   ParamList (Param Index)
  static let columns: [Column] = [
    Column(name: "RVA", type: .constant(4)),
    Column(name: "ImplFlags", type: .constant(2)),
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Signature", type: .index(.heap(.blob))),
    Column(name: "ParamList", type: .index(.simple(Param.self))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
