// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.21.
public final class GenericParamConstraint: Table {
  public static var number: Int { 44 }

  /// Record Layout
  ///   Owner (GenericParam Index)
  ///   Constraint (TypeDefOrRef Coded Index)
  public static let columns: [Column] = [
    Column(name: "Owner", type: .index(.simple(GenericParam.self))),
    Column(name: "Constraint", type: .index(.coded(TypeDefOrRef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
