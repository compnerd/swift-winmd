// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.4.
public final class AssemblyProcessor: Table {
  public static var number: Int { 33 }

  /// Record Layout
  ///   Processor (4-byte constant)
  public static let columns: [Column] = [
    Column(name: "Processor", type: .constant(4)),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.AssemblyProcessor {
  public var Processor: UInt32 {
    UInt32(columns[0])
  }
}
