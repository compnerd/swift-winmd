// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
public final class InterfaceImpl: Table {
  public static var number: Int { 9 }

  /// Record Layout
  ///   Class (TypeDef Index)
  ///   Interface (TypeDefOrRef Coded Index)
  public static let columns: [Column] = [
    Column(name: "Class", type: .index(.simple(TypeDef.self))),
    Column(name: "Interface", type: .index(.coded(TypeDefOrRef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
