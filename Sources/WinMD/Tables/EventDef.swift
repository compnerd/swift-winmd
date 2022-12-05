// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.13.
public final class EventDef: Table {
  public static var number: Int { 20 }

  /// Record Layout
  ///   EventFlags (2-byte bitmask EventAttributes)
  ///   Name (String Heap Index)
  ///   EventType (TypeDefOrRef Coded Index)
  public static let columns: [Column] = [
    Column(name: "EventFlags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "EventType", type: .index(.coded(TypeDefOrRef.self)))
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
