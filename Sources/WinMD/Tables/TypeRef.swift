// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   ResolutionScope (ResolutionScope Coded Index)
///   TypeName (String Heap Index)
///   TypeNamespace (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "ResolutionScope", type: .index(.coded(ResolutionScope.self))),
  Column(name: "TypeName", type: .index(.heap(.string))),
  Column(name: "TypeNamespace", type: .index(.heap(.string))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.38.
public enum TypeRef: TableSchema {
  public static var number: Int { 1 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.TypeRef {
  public var TypeName: String {
    database.strings[columns[1]]
  }

  public var TypeNamespace: String {
    database.strings[columns[2]]
  }
}
