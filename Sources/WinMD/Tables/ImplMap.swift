// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   MappingFlags (2-byte bitmask of PInvokeAttributes)
///   MemberForwarded (MemberForwarded Coded Index)
///   ImportName (String Heap Index)
///   ImportScope (ModuleRef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "MappingFlags", type: .constant(2)),
  Column(name: "MemberForwarded", type: .index(.coded(MemberForwarded.self))),
  Column(name: "ImportName", type: .index(.heap(.string))),
  Column(name: "ImportScope", type: .index(.simple(Metadata.Tables.ModuleRef.self))),
]

extension Metadata.Tables {
/// See §II.22.22.
public enum ImplMap: TableSchema {
  public static var number: Int { 28 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.ImplMap {
  public var MappingFlags: CorPinvokeMap {
    CorPinvokeMap(rawValue: CorPinvokeMap.RawValue(columns[0]))
  }

  public var ImportName: String {
    get throws(WinMDError) {
      try database.strings[columns[2]]
    }
  }

  public var ImportScope: Record<Metadata.Tables.ModuleRef> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.ModuleRef.self)[columns[3]]!
    }
  }
}
