// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Action (2-byte value)
///   Parent (HasDeclSecurity Coded Index)
///   PermissionSet (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Action", type: .constant(2)),
  Field(name: "Parent", type: .index(.coded(HasDeclSecurity.self))),
  Field(name: "PermissionSet", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.11.
public enum DeclSecurity: TableSchema {
  public static var number: Int { 14 }

  /// Sorted by `Parent`. See §II.22.11.
  public static var key: Int? { 1 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.DeclSecurity {
  public var Action: UInt16 {
    UInt16(columns[0])
  }

  public var PermissionSet: Blob {
    @_lifetime(copy self)
    get { blobs[columns[2]] }
  }
}
