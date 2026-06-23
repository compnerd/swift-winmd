// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Name (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Name", type: .index(.heap(.string))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.31.
public enum ModuleRef: TableSchema {
  public static var number: Int { 26 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.ModuleRef {
  public static var Name: Column<Schema, String> {
    Column<Schema, String>(0) { $0.strings[$0.columns[0]] }
  }
}

extension Row where Schema == Metadata.Tables.ModuleRef {
  public var Name: String {
    self[.Name]
  }
}
