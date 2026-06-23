// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Class (TypeDef Index)
///   Interface (TypeDefOrRef Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Class", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Column(name: "Interface", type: .index(.coded(TypeDefOrRef.self))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.23.
public enum InterfaceImpl: TableSchema {
  public static var number: Int { 9 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.InterfaceImpl {
  public var Class: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }
}
