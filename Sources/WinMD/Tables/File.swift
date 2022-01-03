// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
public final class File: Table {
  public static var number: Int { 38 }

  /// Record Layout
  ///   Flags (4-byte bitmask of FileAttributes)
  ///   Name (String Heap Index)
  ///   HashValue (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Flags", type: .constant(4)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "HashValue", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
