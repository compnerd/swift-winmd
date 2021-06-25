// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A compressed index which is an index into a predefined set of tables.
///
/// The tagged-union is formed by encoding the descriminator in the bottom
/// log(n) bits and the index in the remaining bits.  The raw value is either
/// 16-bits if all the tables use a 16-bit index or 32-bit otherwise.
internal protocol CodedIndex: Hashable {
  /// The tables that the `CodedIndex` descriminates across.
  ///
  /// The order of the tables is important.  The tag identifies the table and
  /// indexes through them, therefore, it is critical the index of the table
  /// corresponds to the tag value.
  static var tables: [TableBase.Type] { get }

  /// The value of the coded index.
  var rawValue: Int { get }

  /// Creates a new instance with the specified value.
  init(rawValue: Int)
}

extension CodedIndex {
  /// The mask to extract the descriminator from the `CodedIndex`.
  internal static var mask: Int {
    (1 << (64 - (Self.tables.count - 1).leadingZeroBitCount)) - 1
  }

  /// The table descriminator used to select between the tables.
  internal var tag: Int {
    self.rawValue & Self.mask
  }

  /// The row for the selected table that the index identifies.
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
