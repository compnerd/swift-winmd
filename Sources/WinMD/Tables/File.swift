// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (4-byte bitmask of FileAttributes)
///   Name (String Heap Index)
///   HashValue (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Flags", type: .constant(4)),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "HashValue", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.19.
public enum File: TableSchema {
  public static var number: Int { 38 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Row where Schema == Metadata.Tables.File {
  public var Flags: CorFileFlags {
    CorFileFlags(rawValue: CorFileFlags.RawValue(columns[0]))
  }

  public var Name: String {
    database.strings[columns[1]]
  }

  public var HashValue: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[2]] }
  }
}
