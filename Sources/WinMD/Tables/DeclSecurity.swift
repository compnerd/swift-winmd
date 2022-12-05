// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.11.
public final class DeclSecurity: Table {
  public static var number: Int { 14 }

  /// Record Layout
  ///   Action (2-byte value)
  ///   Parent (HasDeclSecurity Coded Index)
  ///   PermissionSet (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Action", type: .constant(2)),
    Column(name: "Parent", type: .index(.coded(HasDeclSecurity.self))),
    Column(name: "PermissionSet", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
