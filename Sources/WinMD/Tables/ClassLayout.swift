// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.8.
public enum ClassLayout: TableSchema {
  public static var number: Int { 15 }

  /// Record Layout
  ///   PackingSize (2-byte constant)
  ///   ClassSize (4-byte constant)
  ///   Parent (TypeDef Index)
  public static let columns = [
    Column(name: "PackingSize", type: .constant(2)),
    Column(name: "ClassSize", type: .constant(4)),
    Column(name: "Parent", type: .index(.simple(TypeDef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.ClassLayout {
  public var PackingSize: UInt16 {
    UInt16(columns[0])
  }

  public var ClassSize: UInt32 {
    UInt32(columns[1])
  }

  public var Parent: Record<Metadata.Tables.TypeDef> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.TypeDef.self)[columns[2]]!
    }
  }
}
