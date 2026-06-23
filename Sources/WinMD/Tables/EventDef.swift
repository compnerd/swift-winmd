// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   EventFlags (2-byte bitmask EventAttributes)
///   Name (String Heap Index)
///   EventType (TypeDefOrRef Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "EventFlags", type: .constant(2)),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "EventType", type: .index(.coded(TypeDefOrRef.self)))
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.13.
public enum EventDef: TableSchema {
  public static var number: Int { 20 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.EventDef {
  public static var EventFlags: Column<Schema, CorEventAttr> {
    Column<Schema, CorEventAttr>(0) {
      CorEventAttr(rawValue: CorEventAttr.RawValue($0.columns[0]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(1) { $0.strings[$0.columns[1]] }
  }
}

extension Row where Schema == Metadata.Tables.EventDef {
  public var EventFlags: CorEventAttr {
    self[.EventFlags]
  }

  public var Name: String {
    self[.Name]
  }
}
