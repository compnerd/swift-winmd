// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Name (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Name", type: .index(.heap(.string))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.31.
public enum ModuleRef: TableSchema {
  public static var number: Int { 26 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.ModuleRef {
  public var Name: String {
    database.strings[columns[0]]
  }
}
