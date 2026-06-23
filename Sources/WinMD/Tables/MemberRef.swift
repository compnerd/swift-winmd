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

extension Column where Schema == Metadata.Tables.MemberRef {
  public static var Name: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.MemberRef {
  public static var Signature: BlobColumn<Schema> { BlobColumn<Schema>(2) }
}

extension CodedReference where Schema == Metadata.Tables.MemberRef {
  public static var Class: CodedReference<Schema> {
    CodedReference<Schema>(0)
  }
}

extension Row where Schema == Metadata.Tables.MemberRef {
  public var Name: String {
    self[.Name]
  }

  public var Signature: Blob {
    @_lifetime(copy self)
    get { self[.Signature] }
  }
}
