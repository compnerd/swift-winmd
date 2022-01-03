// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
public final class ManifestResource: Table {
  public static var number: Int { 40 }

  /// Record Layout
  ///   Offset (4-byte constant)
  ///   Flags (4-byte bitmask of ManifestResourceAttributes)
  ///   Name (String Heap Index)
  ///   Implementation (Implementation Coded Index)
  public static let columns: [Column] = [
    Column(name: "Offset", type: .constant(4)),
    Column(name: "Flags", type: .constant(4)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Implementation", type: .index(.coded(Implementation.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
