// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.26.
public final class MethodDef: Table {
  public static var number: Int { 6 }

  /// Record Layout
  ///   RVA (4-byte constant)
  ///   ImplFlags (2-byte bitmask of MethodImplAtttributes)
  ///   Flags (2-byte bitmask of MethodAttributes)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  ///   ParamList (Param Index)
  public static let columns: [Column] = [
    Column(name: "RVA", type: .constant(4)),
    Column(name: "ImplFlags", type: .constant(2)),
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Signature", type: .index(.heap(.blob))),
    Column(name: "ParamList", type: .index(.simple(Param.self))),
  ]

  public let rows: UInt32
  public let data: ArraySlice<UInt8>

  public required init(rows: UInt32, data: ArraySlice<UInt8>) {
    self.rows = rows
    self.data = data
  }
}
}

extension Record where Table == Metadata.Tables.MethodDef {
  public var RVA: UInt32 {
    UInt32(self.columns[0])
  }

  public var ImplFlags: CorMethodImpl {
    .init(rawValue: CorMethodImpl.RawValue(self.columns[1]))
  }

  public var Flags: CorMethodAttr {
    .init(rawValue: CorMethodAttr.RawValue(self.columns[2]))
  }

  public var Name: String {
    get throws {
      try self.database.strings[self.columns[3]]
    }
  }

  public var Signature: Blob {
    get throws {
      try self.database.blobs[self.columns[4]]
    }
  }

  public var ParamList: TableIterator<Metadata.Tables.Param> {
    get throws {
      try list(for: 5)
    }
  }
}
