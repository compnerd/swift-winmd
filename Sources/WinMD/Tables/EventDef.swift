// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.13.
public enum EventDef: TableSchema {
  public static var number: Int { 20 }

  /// Record Layout
  ///   EventFlags (2-byte bitmask EventAttributes)
  ///   Name (String Heap Index)
  ///   EventType (TypeDefOrRef Coded Index)
  public static let columns = [
    Column(name: "EventFlags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "EventType", type: .index(.coded(TypeDefOrRef.self)))
  ]
}
}

extension Record where Schema == Metadata.Tables.EventDef {
  public var EventFlags: CorEventAttr {
    CorEventAttr(rawValue: CorEventAttr.RawValue(columns[0]))
  }

  public var Name: String {
    get throws(WinMDError) {
      try database.strings[columns[1]]
    }
  }
}
