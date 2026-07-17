// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   NestedClass (TypeDef Index)
///   EnclosingClass (TypeDef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "NestedClass", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Field(name: "EnclosingClass", type: .index(.simple(Metadata.Tables.TypeDef.self))),
]

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.32.
public enum NestedClass: TableSchema {
  public static var number: Int { 41 }

  /// Sorted by `NestedClass`. See §II.22.32.
  public static var key: Int? { 0 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Reference where Schema == Metadata.Tables.NestedClass {
  public static var NestedClass: Reference<Schema, Metadata.Tables.TypeDef> {
    Reference<Schema, Metadata.Tables.TypeDef>(0)
  }

  public static var EnclosingClass: Reference<Schema, Metadata.Tables.TypeDef> {
    Reference<Schema, Metadata.Tables.TypeDef>(1)
  }
}

extension Row where Schema == Metadata.Tables.NestedClass {
  public var NestedClass: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try required(.NestedClass)
    }
  }

  public var EnclosingClass: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try required(.EnclosingClass)
    }
  }
}
