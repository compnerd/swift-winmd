// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.39.
public enum TypeSpec: TableSchema {
  public static var number: Int { 27 }

  /// Record Layout
  ///   Signature (Blob Heap Index)
  public static let columns = [
    Column(name: "Signature", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.TypeSpec {
  public var Signature: Blob {
    get throws {
      try database.blobs[columns[0]]
    }
  }
}
