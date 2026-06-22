// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Class (TypeDef Index)
///   MethodBody (MethodDefOrRef Coded Index)
///   MethodDeclaration (MethodDefOrRef Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Class", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Column(name: "MethodBody", type: .index(.coded(MethodDefOrRef.self))),
  Column(name: "MethodDeclaration", type: .index(.coded(MethodDefOrRef.self))),
]

extension Metadata.Tables {
/// See §II.22.27.
public enum MethodImpl: TableSchema {
  public static var number: Int { 25 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.MethodImpl {
  public var Class: Record<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }
}
