// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.11.
public enum DeclSecurity: TableSchema {
  public static var number: Int { 14 }

  /// Record Layout
  ///   Action (2-byte value)
  ///   Parent (HasDeclSecurity Coded Index)
  ///   PermissionSet (Blob Heap Index)
  public static let columns = [
    Column(name: "Action", type: .constant(2)),
    Column(name: "Parent", type: .index(.coded(HasDeclSecurity.self))),
    Column(name: "PermissionSet", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.DeclSecurity {
  public var Action: UInt16 {
    UInt16(columns[0])
  }

  public var PermissionSet: Blob {
    get throws {
      try database.blobs[columns[2]]
    }
  }
}
