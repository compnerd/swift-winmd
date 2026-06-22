// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Processor (4-byte constant)
///   AssemblyRef (AssemblyRef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Processor", type: .constant(4)),
  Column(name: "AssemblyRef", type: .index(.simple(Metadata.Tables.AssemblyRef.self))),
]

extension Metadata.Tables {
/// See §II.22.7.
public enum AssemblyRefProcessor: TableSchema {
  public static var number: Int { 36 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.AssemblyRefProcessor {
  public var Processor: UInt32 {
    UInt32(columns[0])
  }

  public var AssemblyRef: Record<Metadata.Tables.AssemblyRef> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.AssemblyRef.self)[columns[1]]!
    }
  }
}
