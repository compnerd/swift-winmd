// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Record Layout
///   HashAlgId (4-byte constant of type AssemblyHashAlgorithm)
///   MajorVersion (2-byte constant)
///   MinorVersion (2-byte constant)
///   BuildNumber (2-byte constant)
///   RevisionNumber (2-byte constant)
///   Flags (4-byte bitmask of type AssemblyFlags)
///   PublicKey (Blob Heap Index)
///   Name (String Heap Index)
///   Culture (String Heap Index)
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _columns: InlineArray<_, Column> = [
  Column(name: "HashAlgId", type: .constant(4)),
  Column(name: "MajorVersion", type: .constant(2)),
  Column(name: "MinorVersion", type: .constant(2)),
  Column(name: "BuildNumber", type: .constant(2)),
  Column(name: "RevisionNumber", type: .constant(2)),
  Column(name: "Flags", type: .constant(4)),
  Column(name: "PublicKey", type: .index(.heap(.blob))),
  Column(name: "Name", type: .index(.heap(.string))),
  Column(name: "Culture", type: .index(.heap(.string))),
]

private let _offsets = offsets(_columns)

extension Metadata.Tables {
/// See §II.22.2.
public enum Assembly: TableSchema {
  public static var number: Int { 32 }

  public static var columns: Span<Column> {
    @_lifetime(immortal) get { _columns.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.Assembly {
  public var HashAlgId: CorHashAlgorithm {
    CorHashAlgorithm(rawValue: CorHashAlgorithm.RawValue(columns[0]))!
  }

  public var MajorVersion: UInt16 {
    UInt16(columns[1])
  }

  public var MinorVersion: UInt16 {
    UInt16(columns[2])
  }

  public var BuildNumber: UInt16 {
    UInt16(columns[3])
  }

  public var RevisionNumber: UInt16 {
    UInt16(columns[4])
  }

  public var Flags: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: CorAssemblyFlags.RawValue(columns[5]))
  }

  public var PublicKey: Blob {
    @_lifetime(copy self)
    get { database.blobs[columns[6]] }
  }

  public var Name: String {
    database.strings[columns[7]]
  }

  public var Culture: String {
    database.strings[columns[8]]
  }
}

extension Row where Schema == Metadata.Tables.Assembly {
  internal var Version: AssemblyVersion  {
    AssemblyVersion(MajorVersion, MinorVersion, BuildNumber, RevisionNumber)
  }
}
