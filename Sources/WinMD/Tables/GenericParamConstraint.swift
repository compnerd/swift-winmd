// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Owner (GenericParam Index)
///   Constraint (TypeDefOrRef Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Owner", type: .index(.simple(Metadata.Tables.GenericParam.self))),
  Field(name: "Constraint", type: .index(.coded(TypeDefOrRef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.21.
public enum GenericParamConstraint: TableSchema {
  public static var number: Int { 44 }

  /// Sorted by `Owner`. See §II.22.21.
  public static var key: Int? { 0 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.GenericParamConstraint {
  public var Owner: Row<Metadata.Tables.GenericParam> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.GenericParam.self)[columns[0]]!
    }
  }
}
