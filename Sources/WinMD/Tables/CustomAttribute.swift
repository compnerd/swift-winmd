// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (HasCustomAttribute Coded Index)
///   Type (CustomAttributeType Coded Index)
///   Value (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Parent", type: .index(.coded(HasCustomAttribute.self))),
  Field(name: "Type", type: .index(.coded(CustomAttributeType.self))),
  Field(name: "Value", type: .index(.heap(.blob))),
]

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.10.
public enum CustomAttribute: TableSchema {
  public static var number: Int { 12 }

  /// Sorted by `Parent`. See §II.22.10.
  public static var key: Int? { 0 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension BlobColumn where Schema == Metadata.Tables.CustomAttribute {
  public static var Value: BlobColumn<Schema> { BlobColumn<Schema>(2) }
}

extension CodedReference where Schema == Metadata.Tables.CustomAttribute {
  public static var Parent: CodedReference<Schema> {
    CodedReference<Schema>(0)
  }

  public static var `Type`: CodedReference<Schema> {
    CodedReference<Schema>(1)
  }
}

extension Row where Schema == Metadata.Tables.CustomAttribute {
  public var Value: Blob {
    @_lifetime(copy self)
    get { self[.Value] }
  }
}
