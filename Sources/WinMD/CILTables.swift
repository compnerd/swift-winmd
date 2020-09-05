/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **/

import Foundation

extension Set where Element == ObjectIdentifier {
  fileprivate init(_ metatypes: [Table.Type]) {
    self.init(metatypes.map { ObjectIdentifier($0) })
  }
}

internal let HasConstantTables: [Table.Type] = [
  Metadata.Tables.Param.self,
  Metadata.Tables.Field.self,
  Metadata.Tables.Property.self,
]
internal let HasConstant: Set<ObjectIdentifier> = Set(HasConstantTables)

internal let HasCustomAttributeTables: [Table.Type] = [
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.MemberRef.self,
]
internal let HasCustomAttribute: Set<ObjectIdentifier> =
    Set(HasCustomAttributeTables)

internal let CustomAttributeTypeTables: [Table.Type] = [
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.MemberRef.self,
]
internal let CustomAttributeType: Set<ObjectIdentifier> =
    Set(CustomAttributeTypeTables)

internal let HasDeclSecurityTables: [Table.Type] = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.Assembly.self,
]
internal let HasDeclSecurity: Set<ObjectIdentifier> = Set(HasDeclSecurityTables)

internal let TypeDefOrRefTables: [Table.Type] = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.TypeRef.self,
  Metadata.Tables.TypeSpec.self,
]
internal let TypeDefOrRef: Set<ObjectIdentifier> = Set(TypeDefOrRefTables)

// FIXME(compnerd) Exported vs Manifest Resource
internal let ImplementationTables: [Table.Type] = [
  Metadata.Tables.File.self,
  Metadata.Tables.ExportedType.self,
  Metadata.Tables.AssemblyRef.self,
]
internal let Implementation: Set<ObjectIdentifier> = Set(ImplementationTables)

internal let HasFieldMarshalTables: [Table.Type] = [
  Metadata.Tables.Field.self,
  Metadata.Tables.Param.self,
]
internal let HasFieldMarshal: Set<ObjectIdentifier> = Set(HasFieldMarshalTables)

internal let TypeOrMethodDefTables: [Table.Type] = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.MethodDef.self,
]
internal let TypeOrMethodDef: Set<ObjectIdentifier> = Set(TypeOrMethodDefTables)

internal let MemberForwardedTables: [Table.Type] = [
  Metadata.Tables.Field.self,
  Metadata.Tables.MethodDef.self,
]
internal let MemberForwarded: Set<ObjectIdentifier> = Set(MemberForwardedTables)

internal let MemberRefParentTables: [Table.Type] = [
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.ModuleRef.self,
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.TypeRef.self,
  Metadata.Tables.TypeSpec.self,
]
internal let MemberRefParent: Set<ObjectIdentifier> = Set(MemberRefParentTables)

internal let HasSemanticsTables: [Table.Type] = [
  Metadata.Tables.Event.self,
  Metadata.Tables.Property.self,
]
internal let HasSemantics: Set<ObjectIdentifier> = Set(HasSemanticsTables)

internal let MethodDefOrRefTables: [Table.Type] = [
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.MemberRef.self,
]
internal let MethodDefOrRef: Set<ObjectIdentifier> = Set(MethodDefOrRefTables)

internal let ResolutionScopeTables: [Table.Type] = [
  Metadata.Tables.Module.self,
  Metadata.Tables.ModuleRef.self,
  Metadata.Tables.AssemblyRef.self,
  Metadata.Tables.TypeRef.self,
]
internal let ResolutionScope: Set<ObjectIdentifier> = Set(ResolutionScopeTables)

enum TableIndex {
case string
case guid
case blob
case simple(Table.Type)
case coded(Set<ObjectIdentifier>)
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
    case let .simple(t):
      hasher.combine(ObjectIdentifier(t))
    case let .coded(s):
      s.hash(into: &hasher)
    }
  }
}

internal protocol Table {
  static var number: Int { get }
  var data: Data { get }

  init(from data: Data, rows: UInt32, strides: [TableIndex:Int])
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
    self.layout = (4, 4, 4, strides[.simple(AssemblyRef.self)]!)
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
    self.layout = (4, strides[.simple(AssemblyRef.self)]!)
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
    self.layout = (2, 4, strides[.simple(TypeDef.self)]!)
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
    self.layout = (1, 1, strides[.coded(HasConstant)]!, strides[.blob]!)
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
    self.layout = (strides[.coded(HasCustomAttribute)]!, strides[.coded(CustomAttributeType)]!, strides[.blob]!)
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
    self.layout = (2, strides[.coded(HasDeclSecurity)]!, strides[.blob]!)
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
    self.layout = (strides[.simple(TypeDef.self)]!, strides[.simple(Event.self)]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct Event: Table {
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
    self.layout = (2, strides[.string]!, strides[.coded(TypeDefOrRef)]!)
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
    self.layout = (4, 4, strides[.string]!, strides[.string]!, strides[.coded(Implementation)]!)
    self.rows = rows

    self.data = data.prefix(Int(rows) * stride(of: self.layout))
  }
}

internal struct Field: Table {
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
    self.layout = (4, strides[.simple(Field.self)]!)
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
    self.layout = (strides[.coded(HasFieldMarshal)]!, strides[.blob]!)
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
    self.layout = (4, strides[.simple(Field.self)]!)
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
    self.layout = (2, 2, strides[.coded(TypeOrMethodDef)]!, strides[.string]!)
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
    self.layout = (strides[.simple(GenericParam.self)]!, strides[.coded(TypeDefOrRef)]!)
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
    self.layout = (2, strides[.coded(MemberForwarded)]!, strides[.string]!, strides[.simple(ModuleRef.self)]!)
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
    self.layout = (strides[.simple(TypeDef.self)]!, strides[.coded(TypeDefOrRef)]!)
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
    self.layout = (4, 4, strides[.string]!, strides[.coded(Implementation)]!)
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
    self.layout = (strides[.coded(MemberRefParent)]!, strides[.string]!, strides[.blob]!)
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
    self.layout = (4, 2, 2, strides[.string]!, strides[.blob]!, strides[.simple(Param.self)]!)
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
    self.layout = (strides[.simple(TypeDef.self)]!, strides[.coded(MethodDefOrRef)]!, strides[.coded(MethodDefOrRef)]!)
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
    self.layout = (2, strides[.simple(MethodDef.self)]!, strides[.coded(HasSemantics)]!)
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
    self.layout = (strides[.coded(MethodDefOrRef)]!, strides[.blob]!)
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
    self.layout = (strides[.simple(TypeDef.self)]!, strides[.simple(TypeDef.self)]!)
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

internal struct Property: Table {
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
    self.layout = (strides[.simple(TypeDef.self)]!, strides[.simple(Property.self)]!)
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
    self.layout = (4, strides[.string]!, strides[.string]!, strides[.coded(TypeDefOrRef)]!, strides[.simple(Field.self)]!, strides[.simple(MethodDef.self)]!)
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
    self.layout = (strides[.coded(ResolutionScope)]!, strides[.string]!, strides[.string]!)
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
      Event.self,
      ExportedType.self,
      Field.self,
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
      Property.self,
      PropertyMap.self,
      StandAloneSig.self,
      TypeDef.self,
      TypeRef.self,
      TypeSpec.self,
    ]).sorted(by: { $0.number < $1.number }).map(body)
  }
}
