// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.35.
public enum PropertyMap: TableSchema {
  public static var number: Int { 21 }

  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   PropertyList (Property Index)
  public static let columns = [
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
    Column(name: "PropertyList", type: .index(.simple(PropertyDef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.PropertyMap {
  public var Parent: Record<Metadata.Tables.TypeDef> {
    get throws {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[0]]!
    }
  }

  public var PropertyList: TableIterator<Metadata.Tables.PropertyDef> {
    get throws {
      try list(for: 1)
    }
  }
}
