// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.5.
public final class AssemblyRef: Table {
  public static var number: Int { 35 }

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
  public static let columns: [Column] = [
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

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.AssemblyRef {
  public var MajorVersion: UInt16 {
    UInt16(self.columns[0])
  }

  public var MinorVersion: UInt16 {
    UInt16(self.columns[1])
  }

  public var BuildNumber: UInt16 {
    UInt16(self.columns[2])
  }

  public var RevisionNumber: UInt16 {
    UInt16(self.columns[3])
  }

  public var Flags: CorAssemblyFlags {
    .init(rawValue: CorAssemblyFlags.RawValue(self.columns[4]))
  }

  public var PublicKeyOrToken: Blob {
    get throws {
      try self.database.blobs[self.columns[5]]
    }
  }

  public var Name: String {
    get throws {
      try self.database.strings[self.columns[6]]
    }
  }

  public var Culture: String {
    get throws {
      try self.database.strings[self.columns[7]]
    }
  }

  public var HashValue: Blob {
    get throws {
      try self.database.blobs[self.columns[8]]
    }
  }
}

extension Record where Table == Metadata.Tables.AssemblyRef {
  internal var Version: AssemblyVersion  {
    AssemblyVersion(MajorVersion, MinorVersion, BuildNumber, RevisionNumber)
  }
}
