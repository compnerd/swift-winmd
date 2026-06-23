// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Semantics (2-byte bitmask of MethodSemanticsAttributes)
///   Method (MethodDef Index)
///   Association (HasSemantics Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Semantics", type: .constant(2)),
  Field(name: "Method", type: .index(.simple(Metadata.Tables.MethodDef.self))),
  Field(name: "Association", type: .index(.coded(HasSemantics.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.28.
public enum MethodSemantics: TableSchema {
  public static var number: Int { 24 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.MethodSemantics {
  public var Semantics: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: UInt16(columns[0]))
  }

  public var Method: Row<Metadata.Tables.MethodDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.MethodDef.self)[columns[1]]!
    }
  }
}
