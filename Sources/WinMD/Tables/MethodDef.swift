// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Metadata.Tables {
/// See §II.22.26.
public enum MethodDef: TableSchema {
  public static var number: Int { 6 }

  /// Record Layout
  ///   RVA (4-byte constant)
  ///   ImplFlags (2-byte bitmask of MethodImplAttributes)
  ///   Flags (2-byte bitmask of MethodAttributes)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  ///   ParamList (Param Index)
  public static let columns = [
    Column(name: "RVA", type: .constant(4)),
    Column(name: "ImplFlags", type: .constant(2)),
    Column(name: "Flags", type: .constant(2)),
    Column(name: "Name", type: .index(.heap(.string))),
    Column(name: "Signature", type: .index(.heap(.blob))),
    Column(name: "ParamList", type: .index(.simple(Param.self))),
  ]
}
}

extension Record where Schema == Metadata.Tables.MethodDef {
  public var RVA: UInt32 {
    UInt32(columns[0])
  }

  public var ImplFlags: CorMethodImpl {
    CorMethodImpl(rawValue: CorMethodImpl.RawValue(columns[1]))
  }

  public var Flags: CorMethodAttr {
    CorMethodAttr(rawValue: CorMethodAttr.RawValue(columns[2]))
  }

  public var Name: String {
    get throws {
      try database.strings[columns[3]]
    }
  }

  public var Signature: Blob {
    get throws {
      try database.blobs[columns[4]]
    }
  }

  public var ParamList: TableIterator<Metadata.Tables.Param> {
    get throws {
      try list(for: 5)
    }
  }
}
