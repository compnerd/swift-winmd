// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Method (MethodDefOrRef Coded Index)
///   Instantiation (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Method", type: .index(.coded(MethodDefOrRef.self))),
  Column(name: "Instantiation", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.29.
public enum MethodSpec: TableSchema {
  public static var number: Int { 43 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.MethodSpec {
  public var Instantiation: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[1]] }
  }
}
