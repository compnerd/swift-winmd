// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.12.
public enum EventMap: TableSchema {
  public static var number: Int { 18 }

  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   EventList (Event Index)
  public static let columns = [
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
    Column(name: "EventList", type: .index(.simple(EventDef.self))),
  ]
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
