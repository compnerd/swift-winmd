// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Signature", type: .index(.heap(.blob))),
]

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.36.
public enum StandAloneSig: TableSchema {
  public static var number: Int { 17 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension BlobColumn where Schema == Metadata.Tables.StandAloneSig {
  public static var Signature: BlobColumn<Schema> { BlobColumn<Schema>(0) }
}

extension Row where Schema == Metadata.Tables.StandAloneSig {
  public var Signature: Blob {
    @_lifetime(copy self)
    get { self[.Signature] }
  }
}
