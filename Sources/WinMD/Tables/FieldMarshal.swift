// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.17.
public final class FieldMarshal: Table {
  public static var number: Int { 13 }

  /// Record Layout
  ///   Parent (HasFieldMarshal Coded Index)
  ///   NativeType (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Parent", type: .index(.coded(HasFieldMarshal.self))),
    Column(name: "NativeType", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.FieldMarshal {
  public var NativeType: Blob {
    get throws {
      try database.blobs[columns[1]]
    }
  }
}
