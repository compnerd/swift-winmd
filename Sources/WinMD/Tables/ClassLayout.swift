// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.8.
public final class ClassLayout: Table {
  public static var number: Int { 15 }

  /// Record Layout
  ///   PackingSize (2-byte constant)
  ///   ClassSize (4-byte constant)
  ///   Parent (TypeDef Index)
  public static let columns: [Column] = [
    Column(name: "PackingSize", type: .constant(2)),
    Column(name: "ClassSize", type: .constant(4)),
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.ClassLayout {
  public var PackingSize: UInt16 {
    UInt16(columns[0])
  }

  public var ClassSize: UInt32 {
    UInt32(columns[1])
  }

  public var Parent: Record<Metadata.Tables.TypeDef> {
    get throws {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[2]]!
    }
  }
}
