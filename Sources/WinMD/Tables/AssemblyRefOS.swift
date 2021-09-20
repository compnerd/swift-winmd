// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class AssemblyRefOS: Table {
  public static var number: Int { 37 }

  /// Record Layout
  ///   OSPlatformId (4-byte constant)
  ///   OSMajorVersion (4-byte constant)
  ///   OSMinorVersion (4-byte constant)
  ///   AssemblyRef (AssemblyRef Index)
  static let columns: [Column] = [
    Column(name: "OSPlatformId", type: .constant(4)),
    Column(name: "OSMajorVersion", type: .constant(4)),
    Column(name: "OSMinorVersion", type: .constant(4)),
    Column(name: "AssemblyRef", type: .index(.simple(AssemblyRef.self))),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
