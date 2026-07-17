// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (TypeDef Index)
///   PropertyList (Property Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Parent", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Field(name: "PropertyList", type: .index(.simple(Metadata.Tables.PropertyDef.self))),
]

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.35.
public enum PropertyMap: TableSchema {
  public static var number: Int { 21 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Reference where Schema == Metadata.Tables.PropertyMap {
  public static var Parent: Reference<Schema, Metadata.Tables.TypeDef> {
    Reference<Schema, Metadata.Tables.TypeDef>(0)
  }
}

extension List where Schema == Metadata.Tables.PropertyMap {
  public static var PropertyList: List<Schema, Metadata.Tables.PropertyDef> {
    List<Schema, Metadata.Tables.PropertyDef>(1)
  }
}

extension Row where Schema == Metadata.Tables.PropertyMap {
  public var Parent: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try required(.Parent)
    }
  }

  public var PropertyList: TableIterator<Metadata.Tables.PropertyDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try list(.PropertyList)
    }
  }
}
