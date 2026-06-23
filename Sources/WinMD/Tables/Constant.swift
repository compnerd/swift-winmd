// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Type (1-byte, 1-byte padding zero)
///   Parent (HasConstant Coded Index)
///   Value (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Type", type: .constant(1)),
  Field(name: StaticString(), type: .constant(1)),
  Field(name: "Parent", type: .index(.coded(HasConstant.self))),
  Field(name: "Value", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.9.
public enum Constant: TableSchema {
  public static var number: Int { 11 }

  /// Sorted by `Parent`. See §II.22.9.
  public static var key: Int? { 2 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.Constant {
  public static var `Type`: Column<Schema, CorElementType> {
    Column<Schema, CorElementType>(0) {
      CorElementType(rawValue: CorElementType.RawValue($0.columns[0]))
    }
  }
}

extension BlobColumn where Schema == Metadata.Tables.Constant {
  public static var Value: BlobColumn<Schema> { BlobColumn<Schema>(3) }
}

extension CodedReference where Schema == Metadata.Tables.Constant {
  public static var Parent: CodedReference<Schema> {
    CodedReference<Schema>(2)
  }
}

extension Row where Schema == Metadata.Tables.Constant {
  public var `Type`: CorElementType {
    self[.Type]
  }

  public var Value: Blob {
    @_lifetime(copy self)
    get { self[.Value] }
  }
}
