// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Flags (4-byte bitmask TypeAttributes)
///   TypeDefId (4-byte value, foreign TypeDef Index)
///   TypeName (String Heap Index)
///   TypeNamespace (String Heap Index)
///   Implementation (Implementation Coded Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Flags", type: .constant(4)),
  Column(name: "TypeDefId", type: .constant(4)),
  Column(name: "TypeName", type: .index(.heap(.string))),
  Column(name: "TypeNamespace", type: .index(.heap(.string))),
  Column(name: "Implementation", type: .index(.coded(Implementation.self))),
]

extension Metadata.Tables {
/// See §II.22.14.
public enum ExportedType: TableSchema {
  public static var number: Int { 39 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.ExportedType {
  public var Flags: CorTypeAttr {
    CorTypeAttr(rawValue: CorTypeAttr.RawValue(columns[0]))
  }

  public var TypeName: String {
    database.strings[columns[2]]
  }

  public var TypeNamespace: String {
    database.strings[columns[3]]
  }
}
