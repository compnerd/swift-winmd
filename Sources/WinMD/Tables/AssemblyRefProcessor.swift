// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.7.
public final class AssemblyRefProcessor: Table {
  public static var number: Int { 36 }

  /// Record Layout
  ///   Processor (4-byte constant)
  ///   AssemblyRef (AssemblyRef Index)
  public static let columns: [Column] = [
    Column(name: "Processor", type: .constant(4)),
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
