// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Signature", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.39.
public enum TypeSpec: TableSchema {
  public static var number: Int { 27 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.TypeSpec {
  public var Signature: Blob {
    @_lifetime(copy self)
    get { blobs[columns[0]] }
  }
}
