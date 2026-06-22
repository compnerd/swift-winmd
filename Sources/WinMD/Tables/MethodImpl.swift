// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.27.
public enum MethodImpl: TableSchema {
  public static var number: Int { 25 }

  /// Record Layout
  ///   Class (TypeDef Index)
  ///   MethodBody (MethodDefOrRef Coded Index)
  ///   MethodDeclaration (MethodDefOrRef Coded Index)
  public static let columns = [
    Column(name: "Class", type: .index(.simple(TypeDef.self))),
    Column(name: "MethodBody", type: .index(.coded(MethodDefOrRef.self))),
    Column(name: "MethodDeclaration", type: .index(.coded(MethodDefOrRef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.MethodImpl {
  public var Class: Record<Metadata.Tables.TypeDef> {
    get throws {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }
}
