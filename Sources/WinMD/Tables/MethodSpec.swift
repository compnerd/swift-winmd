// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.29.
public final class MethodSpec: Table {
  public static var number: Int { 43 }

  /// Record Layout
  ///   Method (MethodDefOrRef Coded Index)
  ///   Instantiation (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Method", type: .index(.coded(MethodDefOrRef.self))),
    Column(name: "Instantiation", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.MethodSpec {
  public var Instantiation: Blob {
    get throws {
      try database.blobs[columns[1]]
    }
  }
}
