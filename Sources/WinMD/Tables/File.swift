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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.19.
public enum File: TableSchema {
  public static var number: Int { 38 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.File {
  public static var Flags: Column<Schema, CorFileFlags> {
    Column<Schema, CorFileFlags>(0) {
      CorFileFlags(rawValue: CorFileFlags.RawValue($0.columns[0]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.File {
  public static var HashValue: BlobColumn<Schema> { BlobColumn<Schema>(2) }
}

extension Row where Schema == Metadata.Tables.File {
  public var Flags: CorFileFlags {
    self[.Flags]
  }

  public var Name: String {
    self[.Name]
  }

  public var HashValue: Blob {
    @_lifetime(copy self)
    get { self[.HashValue] }
  }
}
