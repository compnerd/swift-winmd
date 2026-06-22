// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.23.
public enum InterfaceImpl: TableSchema {
  public static var number: Int { 9 }

  /// Record Layout
  ///   Class (TypeDef Index)
  ///   Interface (TypeDefOrRef Coded Index)
  public static let columns = [
    Column(name: "Class", type: .index(.simple(TypeDef.self))),
    Column(name: "Interface", type: .index(.coded(TypeDefOrRef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.InterfaceImpl {
  public var Class: Record<Metadata.Tables.TypeDef> {
    get throws {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }
}
