// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Signature", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.36.
public enum StandAloneSig: TableSchema {
  public static var number: Int { 17 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Row where Schema == Metadata.Tables.StandAloneSig {
  public var Signature: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[0]] }
  }
}
