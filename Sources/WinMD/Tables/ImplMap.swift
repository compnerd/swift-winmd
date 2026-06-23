// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   MappingFlags (2-byte bitmask of PInvokeAttributes)
///   MemberForwarded (MemberForwarded Coded Index)
///   ImportName (String Heap Index)
///   ImportScope (ModuleRef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "MappingFlags", type: .constant(2)),
  Field(name: "MemberForwarded", type: .index(.coded(MemberForwarded.self))),
  Field(name: "ImportName", type: .index(.heap(.string))),
  Field(name: "ImportScope", type: .index(.simple(Metadata.Tables.ModuleRef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.22.
public enum ImplMap: TableSchema {
  public static var number: Int { 28 }

  /// Sorted by `MemberForwarded`. See §II.22.22.
  public static var key: Int? { 1 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.ImplMap {
  public var MappingFlags: CorPinvokeMap {
    CorPinvokeMap(rawValue: CorPinvokeMap.RawValue(columns[0]))
  }

  public var ImportName: String {
    strings[columns[2]]
  }

  public var ImportScope: Row<Metadata.Tables.ModuleRef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.ModuleRef.self)[columns[3]]!
    }
  }
}
