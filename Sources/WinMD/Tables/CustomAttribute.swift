// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.10.
public final class CustomAttribute: Table {
  public static var number: Int { 12 }

  /// Record Layout
  ///   Parent (HasCustomAttribute Coded Index)
  ///   Type (CustomAttributeType Coded Index)
  ///   Value (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Parent", type: .index(.coded(HasCustomAttribute.self))),
    Column(name: "Type", type: .index(.coded(CustomAttributeType.self))),
    Column(name: "Value", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.CustomAttribute {
  public var Value: Blob {
    get throws {
      try database.blobs[columns[2]]
    }
  }
}
