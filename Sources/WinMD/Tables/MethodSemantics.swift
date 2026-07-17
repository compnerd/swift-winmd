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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.28.
public enum MethodSemantics: TableSchema {
  public static var number: Int { 24 }

  /// Sorted by `Association`. See §II.22.28.
  public static var key: Int? { 2 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.MethodSemantics {
  public static var Semantics: Column<Schema, CorMethodSemanticsAttr> {
    Column<Schema, CorMethodSemanticsAttr>(0) {
      CorMethodSemanticsAttr(rawValue: UInt16($0.columns[0]))
    }
  }
}

extension Reference where Schema == Metadata.Tables.MethodSemantics {
  public static var Method: Reference<Schema, Metadata.Tables.MethodDef> {
    Reference<Schema, Metadata.Tables.MethodDef>(1)
  }
}

extension CodedReference where Schema == Metadata.Tables.MethodSemantics {
  public static var Association: CodedReference<Schema> {
    CodedReference<Schema>(2)
  }
}

extension Row where Schema == Metadata.Tables.MethodSemantics {
  public var Semantics: CorMethodSemanticsAttr {
    self[.Semantics]
  }

  public var Method: Row<Metadata.Tables.MethodDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try required(.Method)
    }
  }
}
