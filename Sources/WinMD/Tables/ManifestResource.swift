// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Offset (4-byte constant)
///   Flags (4-byte bitmask of ManifestResourceAttributes)
///   Name (String Heap Index)
///   Implementation (Implementation Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Offset", type: .constant(4)),
  Field(name: "Flags", type: .constant(4)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Implementation", type: .index(.coded(Implementation.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.24.
public enum ManifestResource: TableSchema {
  public static var number: Int { 40 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.ManifestResource {
  public static var Offset: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }

  public static var Flags: Column<Schema, CorManifestResourceFlags> {
    Column<Schema, CorManifestResourceFlags>(1) {
      CorManifestResourceFlags(rawValue: UInt32($0.columns[1]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(2) { $0.strings[$0.columns[2]] }
  }
}

extension Row where Schema == Metadata.Tables.ManifestResource {
  public var Offset: UInt32 {
    self[.Offset]
  }

  public var Flags: CorManifestResourceFlags {
    self[.Flags]
  }

  public var Name: String {
    self[.Name]
  }
}
