// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.17.
public enum FieldMarshal: TableSchema {
  public static var number: Int { 13 }

  /// Record Layout
  ///   Parent (HasFieldMarshal Coded Index)
  ///   NativeType (Blob Heap Index)
  public static let columns = [
    Column(name: "Parent", type: .index(.coded(HasFieldMarshal.self))),
    Column(name: "NativeType", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.FieldMarshal {
  public var NativeType: Blob {
    get throws(WinMDError) {
      try database.blobs[columns[1]]
    }
  }
}
