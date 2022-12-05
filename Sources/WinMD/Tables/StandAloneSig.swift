// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.36.
public final class StandAloneSig: Table {
  public static var number: Int { 17 }

  /// Record Layout
  ///   Signature (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Signature", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.StandAloneSig {
  public var Signature: Blob {
    get throws {
      try self.database.blobs[self.columns[0]]
    }
  }
}
