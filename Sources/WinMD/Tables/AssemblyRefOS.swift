// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   OSPlatformId (4-byte constant)
///   OSMajorVersion (4-byte constant)
///   OSMinorVersion (4-byte constant)
///   AssemblyRef (AssemblyRef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "OSPlatformId", type: .constant(4)),
  Field(name: "OSMajorVersion", type: .constant(4)),
  Field(name: "OSMinorVersion", type: .constant(4)),
  Field(name: "AssemblyRef", type: .index(.simple(Metadata.Tables.AssemblyRef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.3.
public enum AssemblyRefOS: TableSchema {
  public static var number: Int { 37 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.AssemblyRefOS {
  public static var OSPlatformId: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }

  public static var OSMajorVersion: Column<Schema, UInt32> {
    Column<Schema, UInt32>(1) { UInt32($0.columns[1]) }
  }

  public static var OSMinorVerison: Column<Schema, UInt32> {
    Column<Schema, UInt32>(2) { UInt32($0.columns[2]) }
  }
}

extension Row where Schema == Metadata.Tables.AssemblyRefOS {
  public var OSPlatformId: UInt32 {
    self[.OSPlatformId]
  }

  public var OSMajorVersion: UInt32 {
    self[.OSMajorVersion]
  }

  public var OSMinorVerison: UInt32 {
    self[.OSMinorVerison]
  }

  public var AssemblyRef: Row<Metadata.Tables.AssemblyRef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.AssemblyRef.self)[columns[3]]!
    }
  }
}
