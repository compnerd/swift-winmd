// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Contains values that indicate type metadata.  See §II.23.1.15.
public struct CorTypeAttr: OptionSet {
  public typealias RawValue = UInt32

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Used for type visibility information.
  public static var tdVisibilityMask: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000007)
  }
  /// Specifies that the type is not in public scope.
  public static var tdNotPublic: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000000)
  }
  /// Specifies that the type is in public scope.
  public static var tdPublic: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000001)
  }
  /// Specifies that the type is nested with public visibility.
  public static var tdNestedPublic: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000002)
  }
  /// Specifies that the type is nested with private visibility.
  public static var tdNestedPrivate: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000003)
  }
  /// Specifies that the type is nested with family visibility.
  public static var tdNestedFamily: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000004)
  }
  /// Specifies that the type is nested with assembly visibility.
  public static var tdNestedAssembly: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000005)
  }
  /// Specifies that the type is nested with family and assembly visibility.
  public static var tdNestedFamANDAssem: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000006)
  }
  /// Specifies that the type is nested with family or assembly visibility.
  public static var tdNestedFamORAssem: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000007)
  }

  /// Gets layout information for the type.
  public static var tdLayoutMask: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000018)
  }
  /// Specifies that the fields of this type are laid out automatically.
  public static var tdAutoLayout: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000000)
  }
  /// Specifies that the fields of this type are laid out sequentially.
  public static var tdSequentialLayout: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000008)
  }
  /// Specifies that field layout is supplied explicitly.
  public static var tdExplicitLayout: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000010)
  }

  /// Gets semantic information about the type.
  public static var tdClassSemanticsMask: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000020)
  }
  /// Specifies that the type is a class.
  public static var tdClass: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000000)
  }
  /// Specifies that the type is an interface.
  public static var tdInterface: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000020)
  }

  /// Specifies that the type is abstract.
  public static var tdAbstract: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000080)
  }
  /// Specifies that the type cannot be extended.
  public static var tdSealed: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000100)
  }
  /// Specifies that the class name is special. Its name describes how.
  public static var tdSpecialName: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000400)
  }

  /// Specifies that the type is imported.
  public static var tdImport: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00001000)
  }
  /// Specifies that the type is serializable.
  public static var tdSerializable: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00002000)
  }
  /// Specifies that this type is a Windows Runtime type.
  public static var tdWindowsRuntime: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00004000)
  }

  /// Gets information about how strings are encoded and formatted.
  public static var tdStringFormatMask: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00030000)
  }
  /// Specifies that this type interprets an `LPTSTR` as ANSI.
  public static var tdAnsiClass: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000000)
  }
  /// Specifies that this type interprets an `LPTSTR` as Unicode.
  public static var tdUnicodeClass: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00010000)
  }
  /// Specifies that this type interprets an `LPTSTR` automatically.
  public static var tdAutoClass: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00020000)
  }
  /// Specifies that the type has a non-standard encoding, as specified by
  /// `CustomFormatMask`.
  public static var tdCustomFormatClass: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00030000)
  }
  /// Use this mask to get non-standard encoding information for native interop.
  /// The meaning of the values of these two bits is unspecified.
  public static var tdCustomFormatMask: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00C00000)
  }

  /// Specifies that the type must be initialized before the first attempt to
  /// access a static field.
  public static var tdBeforeFieldInit: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00100000)
  }
  /// Specifies that the type is exported, and a type forwarder.
  public static var tdForwarder: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00200000)
  }

  /// This flag and the flags below are used internally by the common language
  /// runtime.
  public static var tdReservedMask: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00040800)
  }
  /// Specifies that the common language runtime should check the name encoding.
  public static var tdRTSpecialName: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00000800)
  }
  /// Specifies that the type has security associated with it.
  public static var tdHasSecurity: CorTypeAttr {
    CorTypeAttr(rawValue: 0x00040000)
  }
}

/// Contains values that describe metadata about a field.  See §II.23.1.5.
public struct CorFieldAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies accessibility information.
  public static var fdFieldAccessMask: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0007)
  }
  /// Specifies that the field cannot be referenced.
  public static var fdPrivateScope: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0000)
  }
  /// Specifies that the field is accessible only by its parent type.
  public static var fdPrivate: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0001)
  }
  /// Specifies that the field is accessible by derived classes in its assembly.
  public static var fdFamANDAssem: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0002)
  }
  /// Specifies that the field is accessible by all types in its assembly.
  public static var fdAssembly: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0003)
  }
  /// Specifies that the field is accessible only by its type and derived
  /// classes.
  public static var fdFamily: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0004)
  }
  /// Specifies that the field is accessible by derived classes and by all types
  /// in its assembly.
  public static var fdFamORAssem: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0005)
  }
  /// Specifies that the field is accessible by all types with visibility of
  /// this scope.
  public static var fdPublic: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0006)
  }

  /// Specifies that the field is a member of its type rather than an instance
  /// member.
  public static var fdStatic: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0010)
  }
  /// Specifies that the field cannot be changed after it is initialized.
  public static var fdInitOnly: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0020)
  }
  /// Specifies that the field value is a compile-time constant.
  public static var fdLiteral: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0040)
  }
  /// Specifies that the field is not serialized when its type is remoted.
  public static var fdNotSerialized: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0080)
  }

  /// Specifies that the field is special, and that its name describes how.
  public static var fdSpecialName: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0200)
  }

  /// Specifies that the field implementation is forwarded through PInvoke.
  public static var fdPinvokeImpl: CorFieldAttr {
    CorFieldAttr(rawValue: 0x2000)
  }

  /// Reserved for internal use by the common language runtime.
  public static var fdReservedMask: CorFieldAttr {
    CorFieldAttr(rawValue: 0x9500)
  }
  /// Specifies that the common language runtime metadata internal APIs should
  /// check the encoding of the name.
  public static var fdRTSpecialName: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0400)
  }
  /// Specifies that the field contains marshaling information.
  public static var fdHasFieldMarshal: CorFieldAttr {
    CorFieldAttr(rawValue: 0x1000)
  }
  /// Specifies that the field has a default value.
  public static var fdHasDefault: CorFieldAttr {
    CorFieldAttr(rawValue: 0x8000)
  }
  /// Specifies that the field has a relative virtual address.
  public static var fdHasFieldRVA: CorFieldAttr {
    CorFieldAttr(rawValue: 0x0100)
  }
}

/// Contains values that describe method implementation features.  See
/// §II.23.1.11.
public struct CorMethodImpl: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Flags that describe code type.
  public static var miCodeTypeMask: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0003)
  }
  /// Specifies that the method implementation is Microsoft intermediate
  /// language (MSIL).
  public static var miIL: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0000)
  }
  /// Specifies that the method implementation is native.
  public static var miNative: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0001)
  }
  /// Specifies that the method implementation is OPTIL.
  public static var miOPTIL: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0002)
  }
  /// Specifies that the method implementation is provided by the common
  /// language runtime.
  public static var miRuntime: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0003)
  }

  /// Flags that indicate whether the code is managed or unmanaged.
  public static var miManagedMask: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0004)
  }
  /// Specifies that the method implementation is unmanaged.
  public static var miUnmanaged: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0004)
  }
  /// Specifies that the method implementation is managed.
  public static var miManaged: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0000)
  }

  /// Specifies that the method is defined. This flag is used primarily in merge
  /// scenarios.
  public static var miForwardRef: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0010)
  }
  /// Specifies that the method signature cannot be mangled for an `HRESULT`
  /// conversion.
  public static var miPreserveSig: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0080)
  }

  /// Reserved for internal use by the common language runtime.
  public static var miInternalCall: CorMethodImpl {
    CorMethodImpl(rawValue: 0x1000)
  }
  /// Specifies that the method is single-threaded through its body.
  public static var miSynchronized: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0020)
  }
  /// Specifies that the method cannot be inlined.
  public static var miNoInlining: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0008)
  }
  /// Specifies that the method should be inlined if possible.
  public static var miAggressiveInlining: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0100)
  }
  /// Specifies that the method should not be optimized.
  public static var miNoOptimization: CorMethodImpl {
    CorMethodImpl(rawValue: 0x0040)
  }
  /// The maximum valid value for a `CorMethodImpl`.
  public static var miMaxMethodImplVal: CorMethodImpl {
    CorMethodImpl(rawValue: 0xffff)
  }
}

/// Contains values that describe the features of a method.  See §II.23.1.10.
public struct CorMethodAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies member access.
  public static var mdMemberAccessMask: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0007)
  }
  /// Specifies that the member cannot be referenced.
  public static var mdPrivateScope: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0000)
  }
  /// Specifies that the member is accessible only by the parent type.
  public static var mdPrivate: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0001)
  }
  /// Specifies that the member is accessible by subtypes only in this assembly.
  public static var mdFamANDAssem: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0002)
  }
  /// Specifies that the member is accessibly by anyone in the assembly.
  public static var mdAssem: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0003)
  }
  /// Specifies that the member is accessible only by type and subtypes.
  public static var mdFamily: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0004)
  }
  /// Specifies that the member is accessible by derived classes and by other
  /// types in its assembly.
  public static var mdFamORAssem: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0005)
  }
  /// Specifies that the member is accessible by all types with access to the
  /// scope.
  public static var mdPublic: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0006)
  }

  /// Specifies that the member is defined as part of the type rather than as a
  /// member of an instance.
  public static var mdStatic: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0010)
  }
  /// Specifies that the method cannot be overridden.
  public static var mdFinal: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0020)
  }
  /// Specifies that the method can be overridden.
  public static var mdVirtual: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0040)
  }
  /// Specifies that the method hides by name and signature, rather than just by
  /// name.
  public static var mdHideBySig: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0080)
  }

  /// Specifies virtual table layout.
  public static var mdVtableLayoutMask: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0100)
  }
  /// Specifies that the slot used for this method in the virtual table be
  /// reused. This is the default.
  public static var mdReuseSlot: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0000)
  }
  /// Specifies that the method always gets a new slot in the virtual table.
  public static var mdNewSlot: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0100)
  }

  /// Specifies that the method can be overridden by the same types to which it
  /// is visible.
  public static var mdCheckAccessOnOverride: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0200)
  }
  /// Specifies that the method is not implemented.
  public static var mdAbstract: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0400)
  }
  /// Specifies that the method is special, and that its name describes how.
  public static var mdSpecialName: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0800)
  }

  /// Specifies that the method implementation is forwarded using PInvoke.
  public static var mdPinvokeImpl: CorMethodAttr {
    CorMethodAttr(rawValue: 0x2000)
  }
  /// Specifies that the method is a managed method exported to unmanaged code.
  public static var mdUnmanagedExport: CorMethodAttr {
    CorMethodAttr(rawValue: 0x0008)
  }

  /// Reserved for internal use by the common language runtime.
  public static var mdReservedMask: CorMethodAttr {
    CorMethodAttr(rawValue: 0xd000)
  }
  /// Specifies that the common language runtime should check the encoding of
  /// the method name.
  public static var mdRTSpecialName: CorMethodAttr {
    CorMethodAttr(rawValue: 0x1000)
  }
  /// Specifies that the method has security associated with it.
  public static var mdHasSecurity: CorMethodAttr {
    CorMethodAttr(rawValue: 0x4000)
  }
  /// Specifies that the method calls another method containing security code.
  public static var mdRequireSecObject: CorMethodAttr {
    CorMethodAttr(rawValue: 0x8000)
  }
}

/// Contains values that describe the metadata of a method parameter.  See
/// §II.23.1.13.
public struct CorParamAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the parameter is passed into the method call.
  public static var pdIn: CorParamAttr {
    CorParamAttr(rawValue: 0x0001)
  }
  /// Specifies that the parameter is passed from the method return.
  public static var pdOut: CorParamAttr {
    CorParamAttr(rawValue: 0x0002)
  }
  /// Specifies that the parameter is optional.
  public static var pdOptional: CorParamAttr {
    CorParamAttr(rawValue: 0x0010)
  }

  /// Reserved for internal use by the common language runtime.
  public static var pdReservedMask: CorParamAttr {
    CorParamAttr(rawValue: 0xf000)
  }
  /// Specifies that the parameter has a default value.
  public static var pdHasDefault: CorParamAttr {
    CorParamAttr(rawValue: 0x1000)
  }
  /// Specifies that the parameter has marshaling information.
  public static var pdHasFieldMarshal: CorParamAttr {
    CorParamAttr(rawValue: 0x2000)
  }

  /// Unused.
  public static var pdUnused: CorParamAttr {
    CorParamAttr(rawValue: 0xcfe0)
  }
}

/// Contains values that describe the metadata of an event.  See §II.23.1.4.
public struct CorEventAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the event is special, and that its name describes how.
  public static var evSpecialName: CorEventAttr {
    CorEventAttr(rawValue: 0x0200)
  }
  /// Reserved for internal use by the common language runtime.
  public static var evRTSpecialName: CorEventAttr {
    CorEventAttr(rawValue: 0x0400)
  }

  /// Specifies that the common language runtime should check the encoding of
  /// the event name.
  public static var evReservedMask: CorEventAttr {
    CorEventAttr(rawValue: 0x0400)
  }
}

/// Contains values that describe the metadata of a property.  See §II.23.1.14.
public struct CorPropertyAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the property is special, and that its name describes how.
  public static var prSpecialName: CorPropertyAttr {
    CorPropertyAttr(rawValue: 0x0200)
  }
  /// Specifies that the common language runtime metadata internal APIs should
  /// check the encoding of the property name.
  public static var prRTSpecialName: CorPropertyAttr {
    CorPropertyAttr(rawValue: 0x0400)
  }
  /// Specifies that the property has a default value.
  public static var prHasDefault: CorPropertyAttr {
    CorPropertyAttr(rawValue: 0x1000)
  }

  /// Unused.
  public static var prUnused: CorPropertyAttr {
    CorPropertyAttr(rawValue: 0xe9ff)
  }
  /// Reserved for internal use by the common language runtime.
  public static var prReservedMask: CorPropertyAttr {
    CorPropertyAttr(rawValue: 0xf400)
  }
}

/// Contains values that describe the relationship between a method and an
/// associated property or event.  See §II.23.1.12.
public struct CorMethodSemanticsAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the method is a `set` accessor for a property.
  public static var msSetter: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: 0x0001)
  }
  /// Specifies that the method is a `get` accessor for a property.
  public static var msGetter: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: 0x0002)
  }
  /// Specifies that the method has a relationship to a property or an event
  /// other than those defined here.
  public static var msOther: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: 0x0004)
  }
  /// Specifies that the method adds handler methods for an event.
  public static var msAddOn: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: 0x0008)
  }
  /// Specifies that the method removes handler methods for an event.
  public static var msRemoveOn: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: 0x0010)
  }
  /// Specifies that the method raises an event.
  public static var msFire: CorMethodSemanticsAttr {
    CorMethodSemanticsAttr(rawValue: 0x0020)
  }
}

/// Specifies options for a PInvoke call.  See §II.23.1.8.
public struct CorPinvokeMap: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Use each member name as specified.
  public static var pmNoMangle: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0001)
  }

  /// Reserved.
  public static var pmCharSetMask: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0006)
  }
  /// Reserved.
  public static var pmCharSetNotSpec: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0000)
  }
  /// Marshal strings as multiple-byte character strings.
  public static var pmCharSetAnsi: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0002)
  }
  /// Marshal strings as Unicode 2-byte characters.
  public static var pmCharSetUnicode: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0004)
  }
  /// Automatically marshal strings appropriately for the target operating
  /// system. The default is Unicode on Windows.
  public static var pmCharSetAuto: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0006)
  }

  /// Reserved.
  public static var pmBestFitUseAssem: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0000)
  }
  /// Perform best-fit mapping of Unicode characters that lack an exact match in
  /// the ANSI character set.
  public static var pmBestFitEnabled: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0010)
  }
  /// Do not perform best-fit mapping of Unicode characters. In this case, all
  /// unmappable characters will be replaced by a ‘?’.
  public static var pmBestFitDisabled: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0020)
  }
  /// Reserved.
  public static var pmBestFitMask: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0030)
  }

  /// Reserved.
  public static var pmThrowOnUnmappableCharUseAssem: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0000)
  }
  /// Throw an exception when the interop marshaler encounters an unmappable
  /// character.
  public static var pmThrowOnUnmappableCharEnabled: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x1000)
  }
  /// Do not throw an exception when the interop marshaler encounters an
  /// unmappable character.
  public static var pmThrowOnUnmappableCharDisabled: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x2000)
  }
  /// Reserved.
  public static var pmThrowOnUnmappableCharMask: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x3000)
  }

  /// Allow the callee to call the Win32 SetLastError function before returning
  /// from the attributed method.
  public static var pmSupportsLastError: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0040)
  }

  /// Reserved.
  public static var pmCallConvMask: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0700)
  }
  /// Use the default platform calling convention. For example, on Windows the
  /// default is `stdcall` and on Windows CE .NET it is `cdecl`.
  public static var pmCallConvWinapi: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0100)
  }
  /// Use the `cdecl` calling convention. In this case, the caller cleans the
  /// stack. This enables calling functions with `varargs` (that is, functions
  /// that accept a variable number of parameters).
  public static var pmCallConvCdecll: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0200)
  }
  /// Use the `stdcall` calling convention. In this case, the callee cleans the
  /// stack. This is the default convention for calling unmanaged functions with
  /// platform invoke.
  public static var pmCallConvStdcall: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0300)
  }
  /// Use the `thiscall` calling convention. In this case, the first parameter
  /// is the this pointer and is stored in register ECX. Other parameters are
  /// pushed on the stack. The `thiscall` calling convention is used to call
  /// methods on classes exported from an unmanaged DLL.
  public static var pmCallConvThiscall: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0400)
  }
  /// Reserved.
  public static var pmCallConvFastcall: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0x0500)
  }

  /// Reserved.
  public static var pmMaxValue: CorPinvokeMap {
    CorPinvokeMap(rawValue: 0xffff)
  }
}

/// Contains values that describe the hash algorithm.  See §II.23.1.1.
public enum CorHashAlgorithm: UInt32 {
  case none = 0x0000
  case md5  = 0x8003
  case sha1 = 0x8004
}

/// Contains values that describe the metadata applied to an assembly
/// compilation.  See §II.23.1.2.
public struct CorAssemblyFlags: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Indicates that the assembly reference holds the full, unhashed public key.
  public static var afPublicKey: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0001)
  }
  /// Indicates that the processor architecture is unspecified.
  public static var afPA_None: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0000)
  }
  /// Indicates that the processor architecture is neutral (PE32).
  public static var afPA_MSIL: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0010)
  }
  /// Indicates that the processor architecture is x86 (PE32).
  public static var afPA_x86: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0020)
  }
  /// Indicates that the processor architecture is Itanium (PE32+).
  public static var afPA_IA64: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0030)
  }
  /// Indicates that the processor architecture is AMD X64 (PE32+).
  public static var afPA_AMD64: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0040)
  }
  /// Indicates that the processor architecture is ARM (PE32).
  public static var afPA_ARM: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0050)
  }
  /// Indicates that the assembly is a reference assembly; that is, it applies
  /// to any architecture but cannot run on any architecture. Thus, the flag is
  /// the same as afPA_Mask.
  public static var afPA_NoPlatform: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0070)
  }
  /// Indicates that the processor architecture flags should be propagated to
  /// the `AssemblyRef` record.
  public static var afPA_Specified: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0080)
  }
  /// A mask that describes the processor architecture.
  public static var afPA_Mask: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0070)
  }
  /// Specifies that the processor architecture description is included.
  public static var afPA_FullMask: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x00f0)
  }
  /// Indicates a shift count in the processor architecture flags to and from
  /// the index.
  public static var afPA_Shift: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0004)
  }

  /// Indicates the corresponding value from the
  /// `DebuggableAttribute.DebuggingModes` of the `DebuggableAttribute`.
  public static var afEnableJITcompileTracking: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x8000)
  }
  /// Indicates the corresponding value from the
  /// `DebuggableAttribute.DebuggingModes` of the `DebuggableAttribute`.
  public static var afDisableJITcompileOptimizer: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x4000)
  }

  /// Indicates that the assembly can be retargeted at run time to an assembly
  /// from a different publisher.
  public static var afRetargetable: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0100)
  }
  /// Indicates the default content type.
  public static var afContentType_Default: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0000)
  }
  /// Indicates the Windows Runtime content type.
  public static var afContentType_WindowsRuntime: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0200)
  }
  /// A mask that describes the content type.
  public static var afContentType_Mask: CorAssemblyFlags {
    CorAssemblyFlags(rawValue: 0x0e00)
  }
}

/// Contains values that describe the type of file defined in a call to
/// `IMetaDataAssemblyEmit::DefineFile`.  See §II.23.1.6.
public struct CorFileFlags: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Indicates that the file is not a resource file.
  public static var ffContainsMetaData: CorFileFlags {
    CorFileFlags(rawValue: 0x0000)
  }
  /// Indicates that the file, possibly a resource file, does not contain metadata.
  public static var ffContainsNoMetaData: CorFileFlags {
    CorFileFlags(rawValue: 0x0001)
  }
}

/// Indicates the visibility of resources encoded in an assembly manifest.  See
/// §II.23.1.9.
public struct CorManifestResourceFlags: OptionSet {
  public typealias RawValue = UInt32

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Reserved.
  public static var mrVisibilityMask: CorManifestResourceFlags {
    CorManifestResourceFlags(rawValue: 0x0007)
  }
  /// The resources are public.
  public static var mrPublic: CorManifestResourceFlags {
    CorManifestResourceFlags(rawValue: 0x0001)
  }
  /// The resources are private.
  public static var mrPrivate: CorManifestResourceFlags {
    CorManifestResourceFlags(rawValue: 0x0002)
  }
}

/// Contains values that describe the `Type` parameters for generic types, as
/// used in calls to `IMetaDataEmit2::DefineGenericParam`.  See §II.23.1.7.
public struct CorGenericParamAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Parameter variance applies only to generic parameters for interfaces and
  /// delegates.
  public static var gpVarianceMask: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0003)
  }
  /// Indicates the absence of variance.
  public static var gpNonVariant: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0000)
  }
  /// Indicates covariance.
  public static var gpCovariant: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0001)
  }
  /// Indicates contravariance.
  public static var gpContravariant: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0002)
  }

  /// Special constraints can apply to any `Type` parameter.
  public static var gpSpecialConstraintMask: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x001c)
  }
  /// Indicates that no constraint applies to the `Type` parameter.
  public static var gpNoSpecialConstraint: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0000)
  }
  /// Indicates that the `Type` parameter must be a reference type.
  public static var gpReferenceTypeConstraint: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0004)
  }
  /// Indicates that the `Type` parameter must be a value type that cannot be a
  /// null value.
  public static var gpNotNullableValueTypeConstraint: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0008)
  }
  /// Indicates that the `Type` parameter must have a default public constructor
  /// that takes no parameters.
  public static var gpDefaultConstructorConstraint: CorGenericParamAttr {
    CorGenericParamAttr(rawValue: 0x0010)
  }
}

/// Specifies a common language runtime `Type`, a type modifier, or information
/// about a type in a metadata type signature.  See §II.23.1.16.
public struct CorElementType: OptionSet {
  public typealias RawValue = UInt8

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Used internally.
  public static var etEnd: CorElementType {
    CorElementType(rawValue: 0x00)
  }
  /// A void type.
  public static var etVoid: CorElementType {
    CorElementType(rawValue: 0x01)
  }
  /// A Boolean type.
  public static var etBoolean: CorElementType {
    CorElementType(rawValue: 0x02)
  }
  /// A character type.
  public static var etChar: CorElementType {
    CorElementType(rawValue: 0x03)
  }
  /// A signed 1-byte integer.
  public static var etInt1: CorElementType {
    CorElementType(rawValue: 0x04)
  }
  /// An unsigned 1-byte integer.
  public static var etUInt1: CorElementType {
    CorElementType(rawValue: 0x05)
  }
  /// A signed 2-byte integer.
  public static var etInt2: CorElementType {
    CorElementType(rawValue: 0x06)
  }
  /// An unsigned 2-byte integer.
  public static var etUInt2: CorElementType {
    CorElementType(rawValue: 0x07)
  }
  /// A signed 4-byte integer.
  public static var etInt4: CorElementType {
    CorElementType(rawValue: 0x08)
  }
  /// An unsigned 4-byte integer.
  public static var etUInt4: CorElementType {
    CorElementType(rawValue: 0x09)
  }
  /// A signed 8-byte integer.
  public static var etInt8: CorElementType {
    CorElementType(rawValue: 0x0a)
  }
  /// An unsigned 8-byte integer.
  public static var etUInt8: CorElementType {
    CorElementType(rawValue: 0x0b)
  }
  /// A 4-byte floating point.
  public static var etFloat: CorElementType {
    CorElementType(rawValue: 0x0c)
  }
  /// An 8-byte floating point.
  public static var etDouble: CorElementType {
    CorElementType(rawValue: 0x0d)
  }
  /// A System.String type.
  public static var etString: CorElementType {
    CorElementType(rawValue: 0x0e)
  }

  /// A pointer type modifier.
  public static var etPtr: CorElementType {
    CorElementType(rawValue: 0x0f)
  }
  /// A reference type modifier.
  public static var etByRef: CorElementType {
    CorElementType(rawValue: 0x10)
  }

  /// A value type modifier.
  public static var etValueType: CorElementType {
    CorElementType(rawValue: 0x11)
  }
  /// A class type modifier.
  public static var etClass: CorElementType {
    CorElementType(rawValue: 0x12)
  }
  /// A class variable type modifier.
  public static var etVar: CorElementType {
    CorElementType(rawValue: 0x13)
  }
  /// A multi-dimensional array type modifier.
  public static var etArray: CorElementType {
    CorElementType(rawValue: 0x14)
  }
  /// A type modifier for generic types.
  public static var etGenericInst: CorElementType {
    CorElementType(rawValue: 0x15)
  }
  /// A typed reference.
  public static var etTypedByRef: CorElementType {
    CorElementType(rawValue: 0x16)
  }

  /// Size of a native integer.
  public static var etInt: CorElementType {
    CorElementType(rawValue: 0x18)
  }
  /// Size of an unsigned native integer.
  public static var etUInt: CorElementType {
    CorElementType(rawValue: 0x19)
  }
  /// A pointer to a function.
  public static var etFnPtr: CorElementType {
    CorElementType(rawValue: 0x1b)
  }
  /// A System.Object type.
  public static var etObject: CorElementType {
    CorElementType(rawValue: 0x1c)
  }
  /// A single-dimensional, zero lower-bound array type modifier.
  public static var etSzArray: CorElementType {
    CorElementType(rawValue: 0x1d)
  }
  /// A method variable type modifier.
  public static var etMVar: CorElementType {
    CorElementType(rawValue: 0x1e)
  }

  /// A C language required modifier.
  public static var etCModReqd: CorElementType {
    CorElementType(rawValue: 0x1f)
  }
  /// A C language optional modifier.
  public static var etCModOpt: CorElementType {
    CorElementType(rawValue: 0x20)
  }

  /// Used internally.
  public static var etInternal: CorElementType {
    CorElementType(rawValue: 0x21)
  }
  /// An invalid type.
  public static var etMax: CorElementType {
    CorElementType(rawValue: 0x22)
  }

  /// Used internally.
  public static var etModifier: CorElementType {
    CorElementType(rawValue: 0x40)
  }
  /// A type modifier that is a sentinel for a list of a variable number of
  /// parameters.
  public static var etSentinel: CorElementType {
    CorElementType(rawValue: 0x01 | CorElementType.etModifier.rawValue)
  }
  /// Used internally.
  public static var etPinned: CorElementType {
    CorElementType(rawValue: 0x05 | CorElementType.etModifier.rawValue)
  }
}
