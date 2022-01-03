// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
public final class ExportedType: Table {
  public static var number: Int { 39 }

  /// Record Layout
  ///   Flags (4-byte bitmask TypeAttributes)
  ///   TypeDefId (4-byte value, foreign TypeDef Index)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  ///   Implementation (Implementation Coded Index)
  public static let columns: [Column] = [
    Column(name: "Flags", type: .constant(4)),
    Column(name: "TypeDefId", type: .constant(4)),
    Column(name: "TypeName", type: .index(.heap(.string))),
    Column(name: "TypeNamespace", type: .index(.heap(.string))),
    Column(name: "Implementation", type: .index(.coded(Implementation.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
