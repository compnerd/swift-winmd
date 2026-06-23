// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   OSPlatformID (4-byte constant)
///   OSMajorVersion (4-byte constant)
///   OSMinorVersion (4-byte constant)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "OSPlatformID", type: .constant(4)),
  Field(name: "OSMajorVersion", type: .constant(4)),
  Field(name: "OSMinorVersion", type: .constant(4)),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
public enum AssemblyOS: TableSchema {
  public static var number: Int { 34 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.AssemblyOS {
  public static var OSPlatformID: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }

  public static var OSMajorVersion: Column<Schema, UInt32> {
    Column<Schema, UInt32>(1) { UInt32($0.columns[1]) }
  }

  public static var OSMinorVersion: Column<Schema, UInt32> {
    Column<Schema, UInt32>(2) { UInt32($0.columns[2]) }
  }
}

extension Row where Schema == Metadata.Tables.AssemblyOS {
  public var OSPlatformID: UInt32 {
    self[.OSPlatformID]
  }

  public var OSMajorVersion: UInt32 {
    self[.OSMajorVersion]
  }

  public var OSMinorVersion: UInt32 {
    self[.OSMinorVersion]
  }
}
