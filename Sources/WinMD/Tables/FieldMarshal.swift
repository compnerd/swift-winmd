// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (HasFieldMarshal Coded Index)
///   NativeType (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Parent", type: .index(.coded(HasFieldMarshal.self))),
  Column(name: "NativeType", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.17.
public enum FieldMarshal: TableSchema {
  public static var number: Int { 13 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.FieldMarshal {
  public var NativeType: Blob {
    database.blobs[columns[1]]
  }
}
