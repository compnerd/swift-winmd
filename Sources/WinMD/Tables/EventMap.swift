// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (TypeDef Index)
///   EventList (Event Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Parent", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Field(name: "EventList", type: .index(.simple(Metadata.Tables.EventDef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.12.
public enum EventMap: TableSchema {
  public static var number: Int { 18 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.EventMap {
  public var Parent: Row<Metadata.Tables.TypeDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }

  public var EventList: TableIterator<Metadata.Tables.EventDef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try list(for: 1)
    }
  }
}
