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
private let _fields: InlineArray<_, Field> = [
  Field(name: "HashAlgId", type: .constant(4)),
  Field(name: "MajorVersion", type: .constant(2)),
  Field(name: "MinorVersion", type: .constant(2)),
  Field(name: "BuildNumber", type: .constant(2)),
  Field(name: "RevisionNumber", type: .constant(2)),
  Field(name: "Flags", type: .constant(4)),
  Field(name: "PublicKey", type: .index(.heap(.blob))),
  Field(name: "Name", type: .index(.heap(.string))),
  Field(name: "Culture", type: .index(.heap(.string))),
]

private let _offsets = offsets(_fields)

extension Metadata.Tables {
/// See §II.22.2.
public enum Assembly: TableSchema {
  public static var number: Int { 32 }

  public static var fields: Span<Field> {
    @_lifetime(immortal) get { _fields.span }
  }

  public static func offset(_ i: Int) -> Int {
    _offsets[i]
  }
}
}

extension Column where Schema == Metadata.Tables.Assembly {
  public static var HashAlgId: Column<Schema, CorHashAlgorithm> {
    Column<Schema, CorHashAlgorithm>(0) {
      CorHashAlgorithm(rawValue: CorHashAlgorithm.RawValue($0.columns[0]))!
    }
  }

  public static var MajorVersion: Column<Schema, UInt16> {
    Column<Schema, UInt16>(1) { UInt16($0.columns[1]) }
  }

  public static var MinorVersion: Column<Schema, UInt16> {
    Column<Schema, UInt16>(2) { UInt16($0.columns[2]) }
  }

  public static var BuildNumber: Column<Schema, UInt16> {
    Column<Schema, UInt16>(3) { UInt16($0.columns[3]) }
  }

  public static var RevisionNumber: Column<Schema, UInt16> {
    Column<Schema, UInt16>(4) { UInt16($0.columns[4]) }
  }

  public static var Flags: Column<Schema, CorAssemblyFlags> {
    Column<Schema, CorAssemblyFlags>(5) {
      CorAssemblyFlags(rawValue: CorAssemblyFlags.RawValue($0.columns[5]))
    }
  }

  public static var Name: Column<Schema, String> {
    Column<Schema, String>(7) { $0.strings[$0.columns[7]] }
  }

  public static var Culture: Column<Schema, String> {
    Column<Schema, String>(8) { $0.strings[$0.columns[8]] }
  }
}

extension BlobColumn where Schema == Metadata.Tables.Assembly {
  public static var PublicKey: BlobColumn<Schema> {
    BlobColumn<Schema>(6)
  }
}

extension Row where Schema == Metadata.Tables.Assembly {
  public var HashAlgId: CorHashAlgorithm {
    self[.HashAlgId]
  }

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

  public var PublicKey: Blob {
    @_lifetime(copy self)
    get { self[.PublicKey] }
  }

  public var Name: String {
    self[.Name]
  }

  public var Culture: String {
    self[.Culture]
  }
}

extension Row where Schema == Metadata.Tables.Assembly {
  internal var Version: AssemblyVersion  {
    AssemblyVersion(MajorVersion, MinorVersion, BuildNumber, RevisionNumber)
  }
}
