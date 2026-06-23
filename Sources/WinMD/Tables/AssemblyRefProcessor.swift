// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Processor (4-byte constant)
///   AssemblyRef (AssemblyRef Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Processor", type: .constant(4)),
  Field(name: "AssemblyRef", type: .index(.simple(Metadata.Tables.AssemblyRef.self))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.7.
public enum AssemblyRefProcessor: TableSchema {
  public static var number: Int { 36 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.AssemblyRefProcessor {
  public static var Processor: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }
}

extension Reference where Schema == Metadata.Tables.AssemblyRefProcessor {
  public static var AssemblyRef: Reference<Schema, Metadata.Tables.AssemblyRef> {
    Reference<Schema, Metadata.Tables.AssemblyRef>(1)
  }
}

extension Row where Schema == Metadata.Tables.AssemblyRefProcessor {
  public var Processor: UInt32 {
    self[.Processor]
  }

  public var AssemblyRef: Row<Metadata.Tables.AssemblyRef> {
    @_lifetime(copy self)
    get throws(WinMDError) {
      try required(.AssemblyRef)
    }
  }
}
