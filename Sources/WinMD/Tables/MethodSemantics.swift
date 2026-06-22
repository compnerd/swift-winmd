// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.28.
public enum MethodSemantics: TableSchema {
  public static var number: Int { 24 }

  /// Record Layout
  ///   Semantics (2-byte bitmask of MethodSemanticsAttributes)
  ///   Method (MethodDef Index)
  ///   Association (HasSemantics Coded Index)
  public static let columns = [
    Column(name: "Semantics", type: .constant(2)),
    Column(name: "Method", type: .index(.simple(MethodDef.self))),
    Column(name: "Association", type: .index(.coded(HasSemantics.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.MethodSemantics {
  public var Semantics: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: UInt16(columns[0]))
  }

  public var Method: Record<Metadata.Tables.MethodDef> {
    get throws {
      try database.rows(of: Metadata.Tables.MethodDef.self)[columns[1]]!
    }
  }
}
