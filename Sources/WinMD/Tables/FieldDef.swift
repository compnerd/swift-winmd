// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (2-byte bitmask of FieldAttributes)
///   Name (String Heap Index)
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Flags", type: .constant(2)),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "Signature", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.15.
public enum FieldDef: TableSchema {
  public static var number: Int { 4 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.FieldDef {
  public var Flags: CorFieldAttr {
    CorFieldAttr(rawValue: CorFieldAttr.RawValue(columns[0]))
  }

  public var Name: String {
    database.strings[columns[1]]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[2]] }
  }
}
