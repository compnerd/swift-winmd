// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.27.
public final class MethodImpl: Table {
  public static var number: Int { 25 }

  /// Record Layout
  ///   Class (TypeDef Index)
  ///   MethodBody (MethodDefOrRef Coded Index)
  ///   MethodDeclaration (MethodDefOrRef Coded Index)
  public static let columns: [Column] = [
    Column(name: "Class", type: .index(.simple(TypeDef.self))),
    Column(name: "MethodBody", type: .index(.coded(MethodDefOrRef.self))),
    Column(name: "MethodDeclaration", type: .index(.coded(MethodDefOrRef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.MethodImpl {
  public var Class: Record<Metadata.Tables.TypeDef> {
    get throws {
      try self.database.rows(of: Metadata.Tables.TypeDef.self)[self.columns[0]]!
    }
  }
}
