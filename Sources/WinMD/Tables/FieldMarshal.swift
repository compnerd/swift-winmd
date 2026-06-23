// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (HasFieldMarshal Coded Index)
///   NativeType (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Parent", type: .index(.coded(HasFieldMarshal.self))),
  Field(name: "NativeType", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.17.
public enum FieldMarshal: TableSchema {
  public static var number: Int { 13 }

  /// Sorted by `Parent`. See §II.22.17.
  public static var key: Int? { 0 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension BlobColumn where Schema == Metadata.Tables.FieldMarshal {
  public static var NativeType: BlobColumn<Schema> { BlobColumn<Schema>(1) }
}

extension Row where Schema == Metadata.Tables.FieldMarshal {
  public var NativeType: Blob {
    @_lifetime(copy self)
    get { self[.NativeType] }
  }
}
