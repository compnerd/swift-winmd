// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Signature", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.39.
public enum TypeSpec: TableSchema {
  public static var number: Int { 27 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.TypeSpec {
  public var Signature: Blob {
    get throws(WinMDError) {
      try database.blobs[columns[0]]
    }
  }
}
