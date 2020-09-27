/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

internal protocol Table {
  static var number: Int { get }

  var rows: UInt32 { get }
  var data: Data { get }

  init(from data: Data, rows: UInt32, strides: [TableIndex:Int])
}

enum TableIndex {
case string
case guid
case blob
case simple(Table.Type)
case coded(ObjectIdentifier)
}

extension TableIndex: Hashable {
  static func == (_ lhs: TableIndex, _ rhs: TableIndex) -> Bool {
    switch (lhs, rhs) {
    case (.string, .string):
      return true
    case (.guid, .guid):
      return true
    case (.blob, .blob):
      return true
    case let (.simple(LHSTable), .simple(RHSTable)) where LHSTable == RHSTable:
      return true
    case let (.coded(LHSSet), .coded(RHSSet)) where LHSSet == RHSSet:
      return true
    default: return false
    }
  }

  func hash(into hasher: inout Hasher) {
    switch self {
    case .string:
      hasher.combine(3)
    case .guid:
      hasher.combine(2)
    case .blob:
      hasher.combine(1)
    case let .simple(table):
      hasher.combine(ObjectIdentifier(table))
    case let .coded(index):
      index.hash(into: &hasher)
    }
  }
}

extension Dictionary where Key == TableIndex, Value == Int {
  internal subscript(_ table: Table.Type) -> Int? {
    get { return self[.simple(table)] }
    set { self[.simple(table)] = newValue }
  }

  internal subscript<T: CodedIndex>(_ index: T.Type) -> Int? {
    get { return self[.coded(ObjectIdentifier(index))] }
    set { self[.coded(ObjectIdentifier(index))] = newValue }
  }
}

extension Metadata {
  internal enum Tables {
  }
}

func stride<RecordLayout>(of layout: RecordLayout) -> Int {
  return Mirror(reflecting: layout).children.map { $0.value as! Int }.reduce(0, +)
}

extension Metadata.Tables {
internal struct Assembly: Table {
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
  typealias RecordLayout = (Int, Int, Int, Int, Int, Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 32 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, 2, 2, 2, 2, 4, strides[.blob]!, strides[.string]!, strides[.string]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct AssemblyOS: Table {
  /// Record Layout
  ///   OSPlatformID (4-byte constant)
  ///   OSMajorVersion (4-byte constant)
  ///   OSMinorVersion (4-byte constant)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 34 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, 4, 4)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct AssemblyProcessor: Table {
  /// Record Layout
  ///   Processor (4-byte constant)
  typealias RecordLayout = (Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 33 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct AssemblyRef: Table {
  /// Record Layout
  ///   MajorVersion (2-byte value)
  ///   MinorVersion (2-byte value)
  ///   BuildNumber (2-byte value)
  ///   RevisionNumber (2-byte value)
  ///   Flags (4-byte value, CorAssemblyFlags)
  ///   PublicKeyOrToken (Blob Heap Index)
  ///   Name (String Heap Index)
  ///   Culutre (String Heap Index)
  ///   HashValue (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int, Int, Int, Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 35 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, 2, 2, 2, 4, strides[.blob]!, strides[.string]!, strides[.string]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct AssemblyRefOS: Table {
  /// Record Layout
  ///   OSPlatformId (4-byte constant)
  ///   OSMajorVersion (4-byte constant)
  ///   OSMinorVersion (4-byte constant)
  ///   AssemblyRef (AssemblyRef Index)
  typealias RecordLayout = (Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 37 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, 4, 4, strides[AssemblyRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct AssemblyRefProcessor: Table {
  /// Record Layout
  ///   Processor (4-byte constant)
  ///   AssemblyRef (AssemblyRef Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 36 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, strides[AssemblyRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct ClassLayout: Table {
  /// Record Layout
  ///   PackingSize (2-byte constant)
  ///   ClassSize (4-byte constant)
  ///   Parent (TypeDef Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 15 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, 4, strides[TypeDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct Constant: Table {
  /// Record Layout
  ///   Type (1-byte, 1-byte padding zero)
  ///   Parent (HasConstant Coded Index)
  ///   Value (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 11 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (1, 1, strides[HasConstant.self]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct CustomAttribute: Table {
  /// Record Layout
  ///   Parent (HasCustomAttribute Coded Index)
  ///   Type (CustomAttributeType Coded Index)
  ///   Value (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 12 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[HasCustomAttribute.self]!, strides[CustomAttributeType.self]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct DeclSecurity: Table {
  /// Record Layout
  ///   Action (2-byte value)
  ///   Parent (HasDeclSecurity Coded Index)
  ///   PermissionSet (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 14 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[HasDeclSecurity.self]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct EventMap: Table {
  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   EventList (Event Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 18 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[TypeDef.self]!, strides[EventDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct EventDef: Table {
  /// Record Layout
  ///   EventFlags (2-byte bitmask EventAttributes)
  ///   Name (String Heap Index)
  ///   EventType (TypeDefOrRef Coded Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 20 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[.string]!, strides[TypeDefOrRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct ExportedType: Table {
  /// Record Layout
  ///   Flags (4-byte bitmask TypeAttributes)
  ///   TypeDefId (4-byte value, foreign TypeDef Index)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  ///   Implementation (Implementation Coded Index)
  typealias RecordLayout = (Int, Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 39 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, 4, strides[.string]!, strides[.string]!, strides[Implementation.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct FieldDef: Table {
  /// Record Layout
  ///   Flags (2-byte bitmask of FieldAttributes)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 4 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[.string]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct FieldLayout: Table {
  /// Record Layout
  ///   Offset (4-byte constant)
  ///   Field (Field Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 16 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, strides[FieldDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct FieldMarshal: Table {
  /// Record Layout
  ///   Parent (HasFieldMarshal Coded Index)
  ///   NativeType (Blob Heap Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 13 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[HasFieldMarshal.self]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct FieldRVA: Table {
  /// Record Layout
  ///   RVA (4-byte constant)
  ///   Field (Field Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 29 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, strides[FieldDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct File: Table {
  /// Record Layout
  ///   Flags (4-byte bitmask of FileAttributes)
  ///   Name (String Heap Index)
  ///   HashValue (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 38 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, strides[.string]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct GenericParam: Table {
  /// Record Layout
  ///   Number (2-byte index)
  ///   Flags (2-byte bitmask of GenericParamAttributes)
  ///   Owner (TypeOrMethodDef Coded Index)
  ///   Name (String Heap Index)
  typealias RecordLayout = (Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 42 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, 2, strides[TypeOrMethodDef.self]!, strides[.string]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct GenericParamConstraint: Table {
  /// Record Layout
  ///   Owner (GenericParam Index)
  ///   Constraint (TypeDefOrRef Coded Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 44 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[GenericParam.self]!, strides[TypeDefOrRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct ImplMap: Table {
  /// Record Layout
  ///   MappingFlags (2-byte bitmask of PInvokeAttributes)
  ///   MemberForwarded (MemberForwarded Coded Index)
  ///   ImportName (String Heap Index)
  ///   ImportScope (ModuleRef Index)
  typealias RecordLayout = (Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 28 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[MemberForwarded.self]!, strides[.string]!, strides[ModuleRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct InterfaceImpl: Table {
  /// Record Layout
  ///   Class (TypeDef Index)
  ///   Interface (TypeDefOrRef Coded Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 9 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[TypeDef.self]!, strides[TypeDefOrRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct ManifestResource: Table {
  /// Record Layout
  ///   Offset (4-byte constant)
  ///   Flags (4-byte bitmask of ManifestResourceAttributes)
  ///   Name (String Heap Index)
  ///   Implementation (Implementation Coded Index)
  typealias RecordLayout = (Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 40 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, 4, strides[.string]!, strides[Implementation.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct MemberRef: Table {
  /// Record Layout
  ///   Class (MemberRefParent Coded Index)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 10 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[MemberRefParent.self]!, strides[.string]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct MethodDef: Table {
  /// Record Layout
  ///   RVA (4-byte constant)
  ///   ImplFlags (2-byte bitmask of MethodImplAtttributes)
  ///   Flags (2-byte bitmask of MethodAttributes)
  ///   Name (String Heap Index)
  ///   Signature (Blob Heap Index)
  ///   ParamList (Param Index)
  typealias RecordLayout = (Int, Int, Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 6 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, 2, 2, strides[.string]!, strides[.blob]!, strides[Param.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct MethodImpl: Table {
  /// Record Layout
  ///   Class (TypeDef Index)
  ///   MethodBody (MethodDefOrRef Coded Index)
  ///   MethodDeclaration (MethodDefOrRef Coded Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 25 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[TypeDef.self]!, strides[MethodDefOrRef.self]!, strides[MethodDefOrRef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct MethodSemantics: Table {
  /// Record Layout
  ///   Semantics (2-byte bitmask of MethodSemanticsAttributes)
  ///   Method (MethodDef Index)
  ///   Association (HasSemantics Coded Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 24 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[MethodDef.self]!, strides[HasSemantics.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct MethodSpec: Table {
  /// Record Layout
  ///   Method (MethodDefOrRef Coded Index)
  ///   Instantiation (Blob Heap Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 43 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[MethodDefOrRef.self]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct Module: Table {
  /// Record Layout
  ///   Generation (2-byte value, reserved, MBZ)
  ///   Name (String Heap Index)
  ///   Mvid (Module Version ID) (GUID Heap Index)
  ///   EncId (GUID Heap Index, reserved, MBZ)
  ///   EncBaseId (GUID Heap Index, reserved, MBZ)
  typealias RecordLayout = (Int, Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 0 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[.string]!, strides[.guid]!, strides[.guid]!, strides[.guid]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct ModuleRef: Table {
  /// Record Layout
  ///   Name (String Heap Index)
  typealias RecordLayout = (Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 26 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[.string]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct NestedClass: Table {
  /// Record Layout
  ///   NestedClass (TypeDef Index)
  ///   EnclosingClass (TypeDef Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 41 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[TypeDef.self]!, strides[TypeDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct Param: Table {
  /// Record Layout
  ///   Flags (2-byte bitmask of ParamAttributes)
  ///   Sequence (2-byte constant)
  ///   Name (String Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 8 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, 2, strides[.string]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct PropertyDef: Table {
  /// Record Layout
  ///   Flags (2-byte bitmask of PropertyAttributes)
  ///   Name (String Heap Index)
  ///   Type (Blob Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 23 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (2, strides[.string]!, strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct PropertyMap: Table {
  /// Record Layout
  ///   Parent (TypeDef Index)
  ///   PropertyList (Property Index)
  typealias RecordLayout = (Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 21 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[TypeDef.self]!, strides[PropertyDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct StandAloneSig: Table {
  /// Record Layout
  ///   Signature (Blob Heap Index)
  typealias RecordLayout = (Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 17 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct TypeDef: Table {
  /// Record Layout
  ///   Flags (4-byte bitmask of TypeAttributes)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  ///   Extends (TypeDefOrRef Coded Index)
  ///   FieldList (Field Index)
  ///   MethodList (MethodDef Index)
  typealias RecordLayout = (Int, Int, Int, Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 2 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (4, strides[.string]!, strides[.string]!, strides[TypeDefOrRef.self]!, strides[FieldDef.self]!, strides[MethodDef.self]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct TypeRef: Table {
  /// Record Layout
  ///   ResolutionScope (ResolutionScope Coded Index)
  ///   TypeName (String Heap Index)
  ///   TypeNamespace (String Heap Index)
  typealias RecordLayout = (Int, Int, Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 1 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[ResolutionScope.self]!, strides[.string]!, strides[.string]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct TypeSpec: Table {
  /// Record Layout
  ///   Signature (Blob Heap Index)
  typealias RecordLayout = (Int)

  let layout: RecordLayout
  let rows: UInt32
  let data: Data

  public static var number: Int { 27 }

  public init(from data: Data, rows: UInt32, strides: [TableIndex:Int]) {
    self.layout = (strides[.blob]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}
}

extension Metadata.Tables {
  static func forEach(_ body: (Table.Type) -> Void) {
    _ = Array<Table.Type>([
      Assembly.self,
      AssemblyOS.self,
      AssemblyProcessor.self,
      AssemblyRef.self,
      AssemblyRefOS.self,
      AssemblyRefProcessor.self,
      ClassLayout.self,
      Constant.self,
      CustomAttribute.self,
      DeclSecurity.self,
      EventMap.self,
      EventDef.self,
      ExportedType.self,
      FieldDef.self,
      FieldLayout.self,
      FieldMarshal.self,
      FieldRVA.self,
      File.self,
      GenericParam.self,
      GenericParamConstraint.self,
      ImplMap.self,
      InterfaceImpl.self,
      ManifestResource.self,
      MemberRef.self,
      MethodDef.self,
      MethodImpl.self,
      MethodSemantics.self,
      MethodSpec.self,
      Module.self,
      ModuleRef.self,
      NestedClass.self,
      Param.self,
      PropertyDef.self,
      PropertyMap.self,
      StandAloneSig.self,
      TypeDef.self,
      TypeRef.self,
      TypeSpec.self,
    ]).sorted(by: { $0.number < $1.number }).map(body)
  }
}
