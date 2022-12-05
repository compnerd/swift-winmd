// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.37.
public final class TypeDef: Table {
  public static var number: Int { 2 }

  /// Record Layout
  ///   Flags (4-byte bitmask of TypeAttributes)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  ///   Extends (TypeDefOrRef Coded Index)
  ///   FieldList (Field Index)
  ///   MethodList (MethodDef Index)
  public static let columns: [Column] = [
    Column(name: "Flags", type: .constant(4)),
    Column(name: "TypeName", type: .index(.heap(.string))),
    Column(name: "TypeNamespace", type: .index(.heap(.string))),
    Column(name: "Extends", type: .index(.coded(TypeDefOrRef.self))),
    Column(name: "FieldList", type: .index(.simple(FieldDef.self))),
    Column(name: "MethodList", type: .index(.simple(MethodDef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.TypeDef {
  public var Flags: CorTypeAttr {
    .init(rawValue: CorTypeAttr.RawValue(self.columns[0]))
  }

  public var TypeName: String {
    get throws {
      try self.database.strings[self.columns[1]]
    }
  }

  public var TypeNamespace: String {
    get throws {
      try self.database.strings[self.columns[2]]
    }
  }

  public var FieldList: TableIterator<Metadata.Tables.FieldDef> {
    get throws {
      try list(for: 4)
    }
  }

  public var MethodList: TableIterator<Metadata.Tables.MethodDef> {
    get throws {
      try list(for: 5)
    }
  }
}
