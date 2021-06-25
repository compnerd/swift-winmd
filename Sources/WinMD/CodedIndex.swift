// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause


internal protocol CodedIndex: Hashable {
  /// The tables that the coded index may index.
  static var tables: [TableBase.Type] { get }

  /// The value of the coded index.
  var rawValue: Int { get }

  /// Creates a new instance with the specified value.
  init(rawValue: Int)
}

extension CodedIndex {
  internal static var mask: Int {
    (1 << (64 - (Self.tables.count - 1).leadingZeroBitCount)) - 1
  }

  internal var tag: Int {
    self.rawValue & Self.mask
  }

  internal var row: Int {
    self.rawValue >> Self.mask.nonzeroBitCount
  }
}

internal struct HasConstant: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.Param.self,
      Metadata.Tables.FieldDef.self,
      Metadata.Tables.PropertyDef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct HasCustomAttribute: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct CustomAttributeType: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct HasDeclSecurity: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.Assembly.self,
    ]
  }

  internal var rawValue: Int
}

internal struct TypeDefOrRef: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.TypeRef.self,
      Metadata.Tables.TypeSpec.self,
    ]
  }

  internal var rawValue: Int
}

// FIXME(compnerd) Exported vs Manifest Resource
internal struct Implementation: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.File.self,
      Metadata.Tables.ExportedType.self,
      Metadata.Tables.AssemblyRef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct HasFieldMarshal: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.FieldDef.self,
      Metadata.Tables.Param.self,
    ]
  }

  internal var rawValue: Int
}

internal struct TypeOrMethodDef: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.MethodDef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct MemberForwarded: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.FieldDef.self,
      Metadata.Tables.MethodDef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct MemberRefParent: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.ModuleRef.self,
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.TypeRef.self,
      Metadata.Tables.TypeSpec.self,
    ]
  }

  internal var rawValue: Int
}

internal struct HasSemantics: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.EventDef.self,
      Metadata.Tables.PropertyDef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct MethodDefOrRef: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }

  internal var rawValue: Int
}

internal struct ResolutionScope: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.Module.self,
      Metadata.Tables.ModuleRef.self,
      Metadata.Tables.AssemblyRef.self,
      Metadata.Tables.TypeRef.self,
    ]
  }

  internal var rawValue: Int
}
