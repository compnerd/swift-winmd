// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   PackingSize (2-byte constant)
///   ClassSize (4-byte constant)
///   Parent (TypeDef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "PackingSize", type: .constant(2)),
  Field(name: "ClassSize", type: .constant(4)),
  Field(name: "Parent", type: .index(.simple(Metadata.Tables.TypeDef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.8.
public enum ClassLayout: TableSchema {
  public static var number: Int { 15 }

  /// Sorted by `Parent`. See §II.22.8.
  public static var key: Int? { 2 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.ClassLayout {
  public var PackingSize: UInt16 {
    UInt16(columns[0])
  }

  public var ClassSize: UInt32 {
    UInt32(columns[1])
  }

  public var Parent: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.TypeDef.self)[columns[2]]!
    }
  }
}
