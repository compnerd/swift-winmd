// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.29.
public enum MethodSpec: TableSchema {
  public static var number: Int { 43 }

  /// Record Layout
  ///   Method (MethodDefOrRef Coded Index)
  ///   Instantiation (Blob Heap Index)
  public static let columns = [
    Column(name: "Method", type: .index(.coded(MethodDefOrRef.self))),
    Column(name: "Instantiation", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.MethodSpec {
  public var Instantiation: Blob {
    get throws(WinMDError) {
      try database.blobs[columns[1]]
    }
  }
}
