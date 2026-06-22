// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   MajorVersion (2-byte value)
///   MinorVersion (2-byte value)
///   BuildNumber (2-byte value)
///   RevisionNumber (2-byte value)
///   Flags (4-byte value, CorAssemblyFlags)
///   PublicKeyOrToken (Blob Heap Index)
///   Name (String Heap Index)
///   Culture (String Heap Index)
///   HashValue (Blob Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "MajorVersion", type: .constant(2)),
  Column(name: "MinorVersion", type: .constant(2)),
  Column(name: "BuildNumber", type: .constant(2)),
  Column(name: "RevisionNumber", type: .constant(2)),
  Column(name: "Flags", type: .constant(4)),
  Column(name: "PublicKeyOrToken", type: .index(.heap(.blob))),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "Culture", type: .index(.heap(.string))),
  Column(name: "HashValue", type: .index(.heap(.blob))),
]

extension Metadata.Tables {
/// See §II.22.5.
public enum AssemblyRef: TableSchema {
  public static var number: Int { 35 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }
}
}

extension Record where Schema == Metadata.Tables.AssemblyRef {
  public var MajorVersion: UInt16 {
    UInt16(columns[0])
  }

  public var MinorVersion: UInt16 {
    UInt16(columns[1])
  }

  public var BuildNumber: UInt16 {
    UInt16(columns[2])
  }

  public var RevisionNumber: UInt16 {
    UInt16(columns[3])
  }

  public var Flags: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: CorAssemblyFlags.RawValue(columns[4]))
  }

  public var PublicKeyOrToken: Blob {
    get throws(WinMDError) {
      try database.blobs[columns[5]]
    }
  }

  public var Name: String {
    get throws(WinMDError) {
      try database.strings[columns[6]]
    }
  }

  public var Culture: String {
    get throws(WinMDError) {
      try database.strings[columns[7]]
    }
  }

  public var HashValue: Blob {
    get throws(WinMDError) {
      try database.blobs[columns[8]]
    }
  }
}

extension Record where Schema == Metadata.Tables.AssemblyRef {
  internal var Version: AssemblyVersion {
    AssemblyVersion(MajorVersion, MinorVersion, BuildNumber, RevisionNumber)
  }
}
