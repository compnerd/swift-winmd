// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Class (MemberRefParent Coded Index)
///   Name (String Heap Index)
///   Signature (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Class", type: .index(.coded(MemberRefParent.self))),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Signature", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.25.
public enum MemberRef: TableSchema {
  public static var number: Int { 10 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.MemberRef {
  public var Name: String {
    strings[columns[1]]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { blobs[columns[2]] }
  }
}
