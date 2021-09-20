// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
internal final class EventDef: Table {
  public static var number: Int { 20 }

  /// Record Layout
  ///   EventFlags (2-byte bitmask EventAttributes)
  ///   Name (String Heap Index)
  ///   EventType (TypeDefOrRef Coded Index)
  static let columns: [Column] = [
    Column(name: "EventFlags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "EventType", type: .index(.coded(TypeDefOrRef.self)))
  ]

  let rows: UInt32
  let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
