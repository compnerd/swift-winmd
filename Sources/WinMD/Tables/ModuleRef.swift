// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.31.
public enum ModuleRef: TableSchema {
  public static var number: Int { 26 }

  /// Record Layout
  ///   Name (String Heap Index)
  public static let columns = [
    Column(name: "Name", type: .index(.heap(.string))),
  ]
}
}

extension Record where Schema == Metadata.Tables.ModuleRef {
  public var Name: String {
    get throws {
      try database.strings[columns[0]]
    }
  }
}
