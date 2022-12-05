// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.12.
public final class EventMap: Table {
  public static var number: Int { 18 }

  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   EventList (Event Index)
  public static let columns: [Column] = [
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
    Column(name: "EventList", type: .index(.simple(EventDef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
