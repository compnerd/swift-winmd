// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.36.
public enum StandAloneSig: TableSchema {
  public static var number: Int { 17 }

  /// Record Layout
  ///   Signature (Blob Heap Index)
  public static let columns = [
    Column(name: "Signature", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.StandAloneSig {
  public var Signature: Blob {
    get throws {
      try database.blobs[columns[0]]
    }
  }
}
