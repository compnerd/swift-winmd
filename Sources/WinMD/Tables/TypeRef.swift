// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   ResolutionScope (ResolutionScope Coded Index)
///   TypeName (String Heap Index)
///   TypeNamespace (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "ResolutionScope", type: .index(.coded(ResolutionScope.self))),
  Field(name: "TypeName", type: .index(.heap(.string))),
  Field(name: "TypeNamespace", type: .index(.heap(.string))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.38.
public enum TypeRef: TableSchema {
  public static var number: Int { 1 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.TypeRef {
  public static var TypeName: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }

  public static var TypeNamespace: Column<Schema, String> {
    Column<Schema, String>(2) { $0.strings[$0.columns[2]] }
  }
}

extension Row where Schema == Metadata.Tables.TypeRef {
  public var TypeName: String {
    self[.TypeName]
  }

  public var TypeNamespace: String {
    self[.TypeNamespace]
  }
}
