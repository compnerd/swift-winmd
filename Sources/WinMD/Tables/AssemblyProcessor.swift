// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class AssemblyProcessor: Table {
  public static var number: Int { 33 }

  /// Record Layout
  ///   Processor (4-byte constant)
  static let columns: [Column] = [
    Column(name: "Processor", type: .constant(4)),
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
