// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Parent (TypeDef Index)
///   EventList (Event Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Parent", type: .index(.simple(Metadata.Tables.TypeDef.self))),
  Column(name: "EventList", type: .index(.simple(Metadata.Tables.EventDef.self))),
]

extension Metadata.Tables {
/// See §II.22.12.
public enum EventMap: TableSchema {
  public static var number: Int { 18 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.EventMap {
  public var Parent: Record<Metadata.Tables.TypeDef> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }

  public var EventList: TableIterator<Metadata.Tables.EventDef> {
    get throws(WinMDError) {
      try list(for: 1)
    }
  }
}
