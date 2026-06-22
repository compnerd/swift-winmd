// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.19.
public enum File: TableSchema {
  public static var number: Int { 38 }

  /// Record Layout
  ///   Flags (4-byte bitmask of FileAttributes)
  ///   Name (String Heap Index)
  ///   HashValue (Blob Heap Index)
  public static let columns = [
    Column(name: "Flags", type: .constant(4)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "HashValue", type: .index(.heap(.blob))),
  ]
}
}

extension Record where Schema == Metadata.Tables.File {
  public var Flags: CorFileFlags {
    CorFileFlags(rawValue: CorFileFlags.RawValue(columns[0]))
  }

  public var Name: String {
    get throws {
      try database.strings[columns[1]]
    }
  }

  public var HashValue: Blob {
    get throws {
      try database.blobs[columns[2]]
    }
  }
}
