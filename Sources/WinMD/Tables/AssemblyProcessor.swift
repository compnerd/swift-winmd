// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   Processor (4-byte constant)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "Processor", type: .constant(4)),
]

extension Metadata.Tables {
/// See §II.22.4.
public enum AssemblyProcessor: TableSchema {
  public static var number: Int { 33 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Row where Schema == Metadata.Tables.AssemblyProcessor {
  public var Processor: UInt32 {
    UInt32(columns[0])
  }
}
