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

private let offsets = WinMD.offsets(of: _fields)

extension Metadata.Tables {
/// See §II.22.5.
public enum AssemblyRef: TableSchema {
  public static var number: Int { 35 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.AssemblyRef {
  public static var MajorVersion: Column<Schema, UInt16> {
    Column<Schema, UInt16>(0) { UInt16($0.columns[0]) }
  }

  public static var MinorVersion: Column<Schema, UInt16> {
    Column<Schema, UInt16>(1) { UInt16($0.columns[1]) }
  }

  public static var BuildNumber: Column<Schema, UInt16> {
    Column<Schema, UInt16>(2) { UInt16($0.columns[2]) }
  }

  public static var RevisionNumber: Column<Schema, UInt16> {
    Column<Schema, UInt16>(3) { UInt16($0.columns[3]) }
  }

  public static var Flags: Column<Schema, CorAssemblyFlags> {
    Column<Schema, CorAssemblyFlags>(4) {
      CorAssemblyFlags(rawValue: CorAssemblyFlags.RawValue($0.columns[4]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(6) { $0.strings[$0.columns[6]] }
  }

  public static var Culture: Column<Schema, String> {
    Column<Schema, String>(7) { $0.strings[$0.columns[7]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.AssemblyRef {
  public static var PublicKeyOrToken: BlobColumn<Schema> {
    BlobColumn<Schema>(5)
  }

  public static var HashValue: BlobColumn<Schema> {
    BlobColumn<Schema>(8)
  }
}

extension Row where Schema == Metadata.Tables.AssemblyRef {
  public var MajorVersion: UInt16 {
    self[.MajorVersion]
  }

  public var MinorVersion: UInt16 {
    self[.MinorVersion]
  }

  public var BuildNumber: UInt16 {
    self[.BuildNumber]
  }

  public var RevisionNumber: UInt16 {
    self[.RevisionNumber]
  }

  public var Flags: CorAssemblyFlags {
    self[.Flags]
  }

  public var PublicKeyOrToken: Blob {
    @_lifetime(copy self)
    get { self[.PublicKeyOrToken] }
  }

  public var Name: String {
    self[.Name]
  }

  public var Culture: String {
    self[.Culture]
  }

  public var HashValue: Blob {
    @_lifetime(copy self)
    get { self[.HashValue] }
  }
}

extension Row where Schema == Metadata.Tables.AssemblyRef {
  internal var Version: AssemblyVersion {
    AssemblyVersion(MajorVersion, MinorVersion, BuildNumber, RevisionNumber)
  }
}
