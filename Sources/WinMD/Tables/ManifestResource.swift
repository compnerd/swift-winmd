// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Offset (4-byte constant)
///   Flags (4-byte bitmask of ManifestResourceAttributes)
///   Name (String Heap Index)
///   Implementation (Implementation Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Offset", type: .constant(4)),
  Column(name: "Flags", type: .constant(4)),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "Implementation", type: .index(.coded(Implementation.self))),
]

extension Metadata.Tables {
/// See §II.22.24.
public enum ManifestResource: TableSchema {
  public static var number: Int { 40 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.ManifestResource {
  public var Offset: UInt32 {
    UInt32(columns[0])
  }

  public var Flags: CorManifestResourceFlags {
    CorManifestResourceFlags(rawValue: UInt32(columns[1]))
  }

  public var Name: String {
    get throws(WinMDError) {
      try database.strings[columns[2]]
    }
  }
}
