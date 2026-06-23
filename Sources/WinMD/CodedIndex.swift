// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A compressed index which is an index into a predefined set of tables.
///
/// The tagged-union is formed by encoding the discriminator in the bottom
/// log(n) bits and the index in the remaining bits. The raw value is either
/// 16-bits if all the tables use a 16-bit index or 32-bit otherwise.
public protocol CodedIndex: CustomDebugStringConvertible, Sendable {
  typealias RawValue = Int

  /// The tables that the `CodedIndex` discriminates across.
  ///
  /// The order of the tables is important. The tag identifies the table and
  /// indexes through them, therefore, it is critical the index of the table
  /// corresponds to the tag value.
  static var tables: Span<TableSchema.Type?> { get }

  /// The value of the coded index.
  var rawValue: RawValue { get }

  /// Creates a new instance with the specified value.
  init(rawValue: RawValue)
}

extension CodedIndex {
  /// The number of tag bits needed to select among the index's tables.
  ///
  /// The tag occupies the low `ceil(log2(n))` bits — "log n" in ECMA-335
  /// §II.24.2.6 — and the remaining bits hold the row.
  public static var bits: Int {
    64 - (Self.tables.count - 1).leadingZeroBitCount
  }

  /// The mask to extract the discriminator from the `CodedIndex`.
  public static var mask: RawValue {
    (1 << bits) - 1
  }

  /// The table discriminator used to select between the tables.
  public var tag: RawValue {
    rawValue & Self.mask
  }

  /// The row for the selected table that the index identifies.
  public var row: RawValue {
    rawValue >> Self.bits
  }
}

extension CodedIndex {
  /// See `CustomDebugStringConvertible.debugDescription`.
  public var debugDescription: String {
    let table = if let schema = Self.tables[tag] {
      "\(schema)"
    } else {
      "reserved"
    }
    return "\(table) Row \(row)"
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _typeDefOrRef: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.TypeRef.self,
  Metadata.Tables.TypeSpec.self,
]

public struct TypeDefOrRef: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _typeDefOrRef.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _hasConstant: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.FieldDef.self,
  Metadata.Tables.Param.self,
  Metadata.Tables.PropertyDef.self,
]

public struct HasConstant: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _hasConstant.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _hasCustomAttribute: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.FieldDef.self,
  Metadata.Tables.TypeRef.self,
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.Param.self,
  Metadata.Tables.InterfaceImpl.self,
  Metadata.Tables.MemberRef.self,
  Metadata.Tables.Module.self,
  Metadata.Tables.DeclSecurity.self,
  Metadata.Tables.PropertyDef.self,
  Metadata.Tables.EventDef.self,
  Metadata.Tables.StandAloneSig.self,
  Metadata.Tables.ModuleRef.self,
  Metadata.Tables.TypeSpec.self,
  Metadata.Tables.Assembly.self,
  Metadata.Tables.AssemblyRef.self,
  Metadata.Tables.File.self,
  Metadata.Tables.ExportedType.self,
  Metadata.Tables.ManifestResource.self,
  Metadata.Tables.GenericParam.self,
  Metadata.Tables.GenericParamConstraint.self,
  Metadata.Tables.MethodSpec.self,
]

public struct HasCustomAttribute: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _hasCustomAttribute.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _hasFieldMarshal: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.FieldDef.self,
  Metadata.Tables.Param.self,
]

public struct HasFieldMarshal: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _hasFieldMarshal.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _hasDeclSecurity: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.Assembly.self,
]

public struct HasDeclSecurity: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _hasDeclSecurity.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _memberRefParent: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.TypeRef.self,
  Metadata.Tables.ModuleRef.self,
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.TypeSpec.self,
]

public struct MemberRefParent: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _memberRefParent.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _hasSemantics: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.EventDef.self,
  Metadata.Tables.PropertyDef.self,
]

public struct HasSemantics: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _hasSemantics.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _methodDefOrRef: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.MemberRef.self,
]

public struct MethodDefOrRef: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _methodDefOrRef.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _memberForwarded: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.FieldDef.self,
  Metadata.Tables.MethodDef.self,
]

public struct MemberForwarded: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _memberForwarded.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// FIXME(compnerd) Exported vs Manifest Resource
// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _implementation: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.File.self,
  Metadata.Tables.AssemblyRef.self,
  Metadata.Tables.ExportedType.self,
]

public struct Implementation: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _implementation.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _customAttributeType: InlineArray<_, TableSchema.Type?> = [
  nil,  // reserved
  nil,  // reserved
  Metadata.Tables.MethodDef.self,
  Metadata.Tables.MemberRef.self,
  nil,  // reserved
]

public struct CustomAttributeType: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _customAttributeType.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _resolutionScope: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.Module.self,
  Metadata.Tables.ModuleRef.self,
  Metadata.Tables.AssemblyRef.self,
  Metadata.Tables.TypeRef.self,
]

public struct ResolutionScope: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _resolutionScope.span }
  }

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

// TODO(compnerd) fold into the accessor when immortal inline spans land.
private let _typeOrMethodDef: InlineArray<_, TableSchema.Type?> = [
  Metadata.Tables.TypeDef.self,
  Metadata.Tables.MethodDef.self,
]

public struct TypeOrMethodDef: CodedIndex {
  public static var tables: Span<TableSchema.Type?> {
    @_lifetime(immortal)
    get { _typeOrMethodDef.span }
  }

  public let rawValue: Int

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }
}
