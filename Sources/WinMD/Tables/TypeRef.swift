// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class TypeRef: Table {
  public static var number: Int { 1 }

  /// Record Layout
  ///   ResolutionScope (ResolutionScope Coded Index)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  static let columns: [Column] = [
    Column(name: "ResolutionScope", type: .index(.coded(ResolutionScope.self))),
    Column(name: "TypeName", type: .index(.heap(.string))),
    Column(name: "TypeNamespace", type: .index(.heap(.string))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
