// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.2.
public final class Assembly: Table {
  public static var number: Int { 32 }

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
  public static let columns: [Column] = [
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

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}
