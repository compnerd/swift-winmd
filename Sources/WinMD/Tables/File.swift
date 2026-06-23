// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (4-byte bitmask of FileAttributes)
///   Name (String Heap Index)
///   HashValue (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Flags", type: .constant(4)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "HashValue", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.19.
public enum File: TableSchema {
  public static var number: Int { 38 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.File {
  public var Flags: CorFileFlags {
    CorFileFlags(rawValue: CorFileFlags.RawValue(columns[0]))
  }

  public var Name: String {
    strings[columns[1]]
  }

  public var HashValue: Blob {
    @_lifetime(copy self)
    get { blobs[columns[2]] }
  }
}
