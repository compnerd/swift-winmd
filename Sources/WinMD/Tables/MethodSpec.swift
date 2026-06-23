// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Method (MethodDefOrRef Coded Index)
///   Instantiation (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Method", type: .index(.coded(MethodDefOrRef.self))),
  Field(name: "Instantiation", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.29.
public enum MethodSpec: TableSchema {
  public static var number: Int { 43 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.MethodSpec {
  public var Instantiation: Blob {
    @_lifetime(copy self)
    get { blobs[columns[1]] }
  }
}
