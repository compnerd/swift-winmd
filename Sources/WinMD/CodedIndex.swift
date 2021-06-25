// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal protocol CodedIndex: Hashable {
  static var tables: [TableBase.Type] { get }
}

internal struct HasConstant: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.Param.self,
      Metadata.Tables.FieldDef.self,
      Metadata.Tables.PropertyDef.self,
    ]
  }
}

internal struct HasCustomAttribute: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }
}

internal struct CustomAttributeType: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }
}

internal struct HasDeclSecurity: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.Assembly.self,
    ]
  }
}

internal struct TypeDefOrRef: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.TypeRef.self,
      Metadata.Tables.TypeSpec.self,
    ]
  }
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
}

internal struct HasFieldMarshal: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.FieldDef.self,
      Metadata.Tables.Param.self,
    ]
  }
}

internal struct TypeOrMethodDef: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.TypeDef.self,
      Metadata.Tables.MethodDef.self,
    ]
  }
}

internal struct MemberForwarded: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.FieldDef.self,
      Metadata.Tables.MethodDef.self,
    ]
  }
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
}

internal struct HasSemantics: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.EventDef.self,
      Metadata.Tables.PropertyDef.self,
    ]
  }
}

internal struct MethodDefOrRef: CodedIndex {
  public static var tables: [TableBase.Type] {
    return [
      Metadata.Tables.MethodDef.self,
      Metadata.Tables.MemberRef.self,
    ]
  }
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
}
