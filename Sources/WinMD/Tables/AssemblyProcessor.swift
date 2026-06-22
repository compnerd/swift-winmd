// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.4.
public enum AssemblyProcessor: TableSchema {
  public static var number: Int { 33 }

  /// Record Layout
  ///   Processor (4-byte constant)
  public static let columns = [
    Column(name: "Processor", type: .constant(4)),
  ]
}
}

extension Record where Schema == Metadata.Tables.AssemblyProcessor {
  public var Processor: UInt32 {
    UInt32(columns[0])
  }
}
