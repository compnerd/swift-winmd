// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (HasCustomAttribute Coded Index)
///   Type (CustomAttributeType Coded Index)
///   Value (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Parent", type: .index(.coded(HasCustomAttribute.self))),
  Column(name: "Type", type: .index(.coded(CustomAttributeType.self))),
  Column(name: "Value", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.10.
public enum CustomAttribute: TableSchema {
  public static var number: Int { 12 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.CustomAttribute {
  public var Value: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[2]] }
  }
}
