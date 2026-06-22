// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.7.
public enum AssemblyRefProcessor: TableSchema {
  public static var number: Int { 36 }

  /// Record Layout
  ///   Processor (4-byte constant)
  ///   AssemblyRef (AssemblyRef Index)
  public static let columns = [
    Column(name: "Processor", type: .constant(4)),
    Column(name: "AssemblyRef", type: .index(.simple(AssemblyRef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.AssemblyRefProcessor {
  public var Processor: UInt32 {
    UInt32(columns[0])
  }

  public var AssemblyRef: Record<Metadata.Tables.AssemblyRef> {
    get throws {
      try database.rows(of: Metadata.Tables.AssemblyRef.self)[columns[1]]!
    }
  }
}
