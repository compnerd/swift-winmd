/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

extension Metadata.Tables {
internal struct AssemblyProcessor: Table {
  /// Record Layout
  ///   Processor (4-byte constant)
  typealias RecordLayout = (Int)

  let layout: RecordLayout
  let stride: Int
  let rows: Int
  let data: ArraySlice<UInt8>

  public static var number: Int { 33 }

  public init(from data: ArraySlice<UInt8>, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4)
    self.stride = 4

    self.rows = Int(rows)
    self.data = data.prefix(self.rows * self.stride)
  }
}
}
