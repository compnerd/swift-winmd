// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.32.
public enum NestedClass: TableSchema {
  public static var number: Int { 41 }

  /// Record Layout
  ///   NestedClass (TypeDef Index)
  ///   EnclosingClass (TypeDef Index)
  public static let columns = [
    Column(name: "NestedClass", type: .index(.simple(TypeDef.self))),
    Column(name: "EnclosingClass", type: .index(.simple(TypeDef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.NestedClass {
  public var NestedClass: Record<Metadata.Tables.TypeDef> {
    get throws {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }

  public var EnclosingClass: Record<Metadata.Tables.TypeDef> {
    get throws {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[1]]!
    }
  }
}
