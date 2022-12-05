// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.3.
public final class AssemblyRefOS: Table {
  public static var number: Int { 37 }

  /// Record Layout
  ///   OSPlatformId (4-byte constant)
  ///   OSMajorVersion (4-byte constant)
  ///   OSMinorVersion (4-byte constant)
  ///   AssemblyRef (AssemblyRef Index)
  public static let columns: [Column] = [
    Column(name: "OSPlatformId", type: .constant(4)),
    Column(name: "OSMajorVersion", type: .constant(4)),
    Column(name: "OSMinorVersion", type: .constant(4)),
    Column(name: "AssemblyRef", type: .index(.simple(AssemblyRef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.AssemblyRefOS {
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
    get throws {
      try database.rows(of: Metadata.Tables.AssemblyRef.self)[columns[3]]!
    }
  }
}
