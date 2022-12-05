// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.25.
public final class MemberRef: Table {
  public static var number: Int { 10 }

  /// Record Layout
  ///   Class (MemberRefParent Coded Index)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  public static let columns: [Column] = [
    Column(name: "Class", type: .index(.coded(MemberRefParent.self))),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Signature", type: .index(.heap(.blob))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
