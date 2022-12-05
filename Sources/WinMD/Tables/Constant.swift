// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.9.
public final class Constant: Table {
  public static var number: Int { 11 }

  /// Record Layout
  ///   Type (1-byte, 1-byte padding zero)
  ///   Parent (HasConstant Coded Index)
  ///   Value (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Type", type: .constant(1)),
    Column(name: StaticString(), type: .constant(1)),
    Column(name: "Parent", type: .index(.coded(HasConstant.self))),
    Column(name: "Value", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init( rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.Constant {
  public var `Type`: CorElementType {
    .init(rawValue: CorElementType.RawValue(columns[0]))
  }

  public var Value: Blob {
    get throws {
      try self.database.blobs[self.columns[4]]
    }
  }
}
