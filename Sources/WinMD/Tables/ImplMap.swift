// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.22.
public final class ImplMap: Table {
  public static var number: Int { 28 }

  /// Record Layout
  ///   MappingFlags (2-byte bitmask of PInvokeAttributes)
  ///   MemberForwarded (MemberForwarded Coded Index)
  ///   ImportName (String Heap Index)
  ///   ImportScope (ModuleRef Index)
  public static let columns: [Column] = [
    Column(name: "MappingFlags", type: .constant(2)),
    Column(name: "MemberForwarded", type: .index(.coded(MemberForwarded.self))),
    Column(name: "ImportName", type: .index(.heap(.string))),
    Column(name: "ImportScope", type: .index(.simple(ModuleRef.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.ImplMap {
  public var MappingFlags: CorPinvokeMap {
    .init(rawValue: CorPinvokeMap.RawValue(columns[0]))
  }

  public var ImportName: String {
    get throws {
      try database.strings[columns[2]]
    }
  }

  public var ImportScope: Record<Metadata.Tables.ModuleRef> {
    get throws {
      try database.rows(of: Metadata.Tables.ModuleRef.self)[columns[3]]!
    }
  }
}
