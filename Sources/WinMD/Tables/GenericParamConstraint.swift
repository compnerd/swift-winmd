// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.21.
public enum GenericParamConstraint: TableSchema {
  public static var number: Int { 44 }

  /// Record Layout
  ///   Owner (GenericParam Index)
  ///   Constraint (TypeDefOrRef Coded Index)
  public static let columns = [
    Column(name: "Owner", type: .index(.simple(GenericParam.self))),
    Column(name: "Constraint", type: .index(.coded(TypeDefOrRef.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.GenericParamConstraint {
  public var Owner: Record<Metadata.Tables.GenericParam> {
    get throws(WinMDError) {
      try database.rows(of: Metadata.Tables.GenericParam.self)[columns[0]]!
    }
  }
}
