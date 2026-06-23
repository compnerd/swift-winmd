// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   NestedClass (TypeDef Index)
///   EnclosingClass (TypeDef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "NestedClass", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Column(name: "EnclosingClass", type: .index(.simple(Metadata.Tables.TypeDef.self))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.32.
public enum NestedClass: TableSchema {
  public static var number: Int { 41 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.NestedClass {
  public var NestedClass: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }

  public var EnclosingClass: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.TypeDef.self)[columns[1]]!
    }
  }
}
