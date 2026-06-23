// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Processor (4-byte constant)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _fields: InlineArray<_, Field> = [
  Field(name: "Processor", type: .constant(4)),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.4.
public enum AssemblyProcessor: TableSchema {
  public static var number: Int { 33 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.AssemblyProcessor {
  public static var Processor: Column<Schema, UInt32> {
    Column<Schema, UInt32>(0) { UInt32($0.columns[0]) }
  }
}

extension Row where Schema == Metadata.Tables.AssemblyProcessor {
  public var Processor: UInt32 {
    self[.Processor]
  }
}
