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

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.7.
public enum AssemblyRefProcessor: TableSchema {
  public static var number: Int { 36 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.AssemblyRefProcessor {
  public var Processor: UInt32 {
    UInt32(columns[0])
  }

  public var AssemblyRef: Row<Metadata.Tables.AssemblyRef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try rows(of: Metadata.Tables.AssemblyRef.self)[columns[1]]!
    }
  }
}
