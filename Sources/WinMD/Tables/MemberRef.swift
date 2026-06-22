// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.25.
public enum MemberRef: TableSchema {
  public static var number: Int { 10 }

  /// Record Layout
  ///   Class (MemberRefParent Coded Index)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  public static let columns = [
    Column(name: "Class", type: .index(.coded(MemberRefParent.self))),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Signature", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.MemberRef {
  public var Name: String {
    get throws {
      try database.strings[columns[1]]
    }
  }

  public var Signature: Blob {
    get throws {
      try database.blobs[columns[2]]
    }
  }
}
