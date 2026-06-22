// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Action (2-byte value)
///   Parent (HasDeclSecurity Coded Index)
///   PermissionSet (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Action", type: .constant(2)),
  Column(name: "Parent", type: .index(.coded(HasDeclSecurity.self))),
  Column(name: "PermissionSet", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.11.
public enum DeclSecurity: TableSchema {
  public static var number: Int { 14 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.DeclSecurity {
  public var Action: UInt16 {
    UInt16(columns[0])
  }

  public var PermissionSet: Blob {
    get throws(WinMDError) {
      try database.blobs[columns[2]]
    }
  }
}
