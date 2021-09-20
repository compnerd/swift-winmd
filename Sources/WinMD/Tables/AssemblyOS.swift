// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class AssemblyOS: Table {
  public static var number: Int { 34 }

  /// Record Layout
  ///   OSPlatformID (4-byte constant)
  ///   OSMajorVersion (4-byte constant)
  ///   OSMinorVersion (4-byte constant)
  static let columns: [Column] = [
    Column(name: "OSPlatformID", type: .constant(4)),
    Column(name: "OSMajorVersion", type: .constant(4)),
    Column(name: "OSMinorVersion", type: .constant(4)),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
