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
private let _fields: InlineArray<_, Field> = [
  Field(name: "MajorVersion", type: .constant(2)),
  Field(name: "MinorVersion", type: .constant(2)),
  Field(name: "BuildNumber", type: .constant(2)),
  Field(name: "RevisionNumber", type: .constant(2)),
  Field(name: "Flags", type: .constant(4)),
  Field(name: "PublicKeyOrToken", type: .index(.heap(.blob))),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Culture", type: .index(.heap(.string))),
  Field(name: "HashValue", type: .index(.heap(.blob))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.5.
public enum AssemblyRef: TableSchema {
  public static var number: Int { 35 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Row where Schema == Metadata.Tables.AssemblyRef {
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
    @_lifetime(copy self)
    get { blobs[columns[5]] }
  }

  public var Name: String {
    strings[columns[6]]
  }

  public var Culture: String {
    strings[columns[7]]
  }

  public var HashValue: Blob {
    @_lifetime(copy self)
    get { blobs[columns[8]] }
  }
}

extension Row where Schema == Metadata.Tables.AssemblyRef {
  internal var Version: AssemblyVersion {
    AssemblyVersion(MajorVersion, MinorVersion, BuildNumber, RevisionNumber)
  }
}
