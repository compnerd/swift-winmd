// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.10.
public enum CustomAttribute: TableSchema {
  public static var number: Int { 12 }

  /// Record Layout
  ///   Parent (HasCustomAttribute Coded Index)
  ///   Type (CustomAttributeType Coded Index)
  ///   Value (Blob Heap Index)
  public static let columns = [
    Column(name: "Parent", type: .index(.coded(HasCustomAttribute.self))),
    Column(name: "Type", type: .index(.coded(CustomAttributeType.self))),
    Column(name: "Value", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.CustomAttribute {
  public var Value: Blob {
    get throws {
      try database.blobs[columns[2]]
    }
  }
}
