// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Class (TypeDef Index)
///   MethodBody (MethodDefOrRef Coded Index)
///   MethodDeclaration (MethodDefOrRef Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Class", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Field(name: "MethodBody", type: .index(.coded(MethodDefOrRef.self))),
  Field(name: "MethodDeclaration", type: .index(.coded(MethodDefOrRef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.27.
public enum MethodImpl: TableSchema {
  public static var number: Int { 25 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.MethodImpl {
  public var Class: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }
}
