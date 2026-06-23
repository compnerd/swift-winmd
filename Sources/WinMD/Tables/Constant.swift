// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Type (1-byte, 1-byte padding zero)
///   Parent (HasConstant Coded Index)
///   Value (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Type", type: .constant(1)),
  Column(name: StaticString(), type: .constant(1)),
  Column(name: "Parent", type: .index(.coded(HasConstant.self))),
  Column(name: "Value", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.9.
public enum Constant: TableSchema {
  public static var number: Int { 11 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.Constant {
  public var `Type`: CorElementType {
    CorElementType(rawValue: CorElementType.RawValue(columns[0]))
  }

  public var Value: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[4]] }
  }
}
