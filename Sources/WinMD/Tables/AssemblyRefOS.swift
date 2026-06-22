// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   OSPlatformId (4-byte constant)
///   OSMajorVersion (4-byte constant)
///   OSMinorVersion (4-byte constant)
///   AssemblyRef (AssemblyRef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "OSPlatformId", type: .constant(4)),
  Column(name: "OSMajorVersion", type: .constant(4)),
  Column(name: "OSMinorVersion", type: .constant(4)),
  Column(name: "AssemblyRef", type: .index(.simple(Metadata.Tables.AssemblyRef.self))),
]

extension Metadata.Tables {
/// See §II.22.3.
public enum AssemblyRefOS: TableSchema {
  public static var number: Int { 37 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.AssemblyRefOS {
  public var OSPlatformId: UInt32 {
    UInt32(columns[0])
  }

  public var OSMajorVersion: UInt32 {
    UInt32(columns[1])
  }

  public var OSMinorVerison: UInt32 {
    UInt32(columns[2])
  }

  public var AssemblyRef: Record<Metadata.Tables.AssemblyRef> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.AssemblyRef.self)[columns[3]]!
    }
  }
}
