// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.38.
public final class TypeRef: Table {
  public static var number: Int { 1 }

  /// Record Layout
  ///   ResolutionScope (ResolutionScope Coded Index)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  public static let columns: [Column] = [
    Column(name: "ResolutionScope", type: .index(.coded(ResolutionScope.self))),
    Column(name: "TypeName", type: .index(.heap(.string))),
    Column(name: "TypeNamespace", type: .index(.heap(.string))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.TypeRef {
  public var TypeName: String {
    get throws {
      try database.strings[columns[1]]
    }
  }

  public var TypeNamespace: String {
    get throws {
      try database.strings[columns[2]]
    }
  }
}
