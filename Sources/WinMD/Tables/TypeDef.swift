// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class TypeDef: Table {
  public static var number: Int { 2 }

  /// Record Layout
  ///   Flags (4-byte bitmask of TypeAttributes)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  ///   Extends (TypeDefOrRef Coded Index)
  ///   FieldList (Field Index)
  ///   MethodList (MethodDef Index)
  static let columns: [Column] = [
    Column(name: "Flags", type: .constant(4)),
    Column(name: "TypeName", type: .index(.heap(.string))),
    Column(name: "TypeNamespace", type: .index(.heap(.string))),
    Column(name: "Extends", type: .index(.coded(TypeDefOrRef.self))),
    Column(name: "FieldList", type: .index(.simple(FieldDef.self))),
    Column(name: "MethodList", type: .index(.simple(MethodDef.self))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
