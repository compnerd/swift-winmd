// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class MethodImpl: Table {
  public static var number: Int { 25 }

  /// Record Layout
  ///   Class (TypeDef Index)
  ///   MethodBody (MethodDefOrRef Coded Index)
  ///   MethodDeclaration (MethodDefOrRef Coded Index)
  static let columns: [Column] = [
    Column(name: "Class", type: .index(.simple(TypeDef.self))),
    Column(name: "MethodBody", type: .index(.coded(MethodDefOrRef.self))),
    Column(name: "MethodDeclaration", type: .index(.coded(MethodDefOrRef.self))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
