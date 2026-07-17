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

private let offsets = WinMD.offsets(of: _fields)

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
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.DeclSecurity {
  public static var Action: Column<Schema, UInt16> {
    Column<Schema, UInt16>(0) { UInt16($0.columns[0]) }
  }
}

extension BlobColumn where Schema == Metadata.Tables.DeclSecurity {
  public static var PermissionSet: BlobColumn<Schema> { BlobColumn<Schema>(2) }
}

extension CodedReference where Schema == Metadata.Tables.DeclSecurity {
  public static var Parent: CodedReference<Schema> {
    CodedReference<Schema>(1)
  }
}

extension Row where Schema == Metadata.Tables.DeclSecurity {
  public var Action: UInt16 {
    self[.Action]
  }

  public var PermissionSet: Blob {
    @_lifetime(copy self)
    get { self[.PermissionSet] }
  }
}
