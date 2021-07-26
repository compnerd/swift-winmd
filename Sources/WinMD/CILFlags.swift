// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Contains values that indicate type metadata.
public struct CorTypeAttr: OptionSet {
  public typealias RawValue = UInt32

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Used for type visibility information.
  static let tdVisibilityMask: CorTypeAttr = .init(rawValue: 0x00000007)
  /// Specifies that the type is not in public scope.
  static let tdNotPublic: CorTypeAttr = .init(rawValue: 0x00000000)
  /// Specifies that the type is in public scope.
  static let tdPublic: CorTypeAttr = .init(rawValue: 0x00000001)
  /// Specifies that the type is nested with public visibility.
  static let tdNestedPublic: CorTypeAttr = .init(rawValue: 0x00000002)
  /// Specifies that the type is nested with private visibility.
  static let tdNestedPrivate: CorTypeAttr = .init(rawValue: 0x00000003)
  /// Specifies that the type is nested with family visibility.
  static let tdNestedFamily: CorTypeAttr = .init(rawValue: 0x00000004)
  /// Specifies that the type is nested with assembly visibility.
  static let tdNestedAssembly: CorTypeAttr = .init(rawValue: 0x00000005)
  /// Specifies that the type is nested with family and assembly visibility.
  static let tdNestedFamANDAssem: CorTypeAttr = .init(rawValue: 0x00000006)
  /// Specifies that the type is nested with family or assembly visibility.
  static let tdNestedFamORAssem: CorTypeAttr = .init(rawValue: 0x00000007)

  /// Gets layout information for the type.
  static let tdLayoutMask: CorTypeAttr = .init(rawValue: 0x00000018)
  /// Specifies that the fields of this type are laid out automatically.
  static let tdAutoLayout: CorTypeAttr = .init(rawValue: 0x00000000)
  /// Specifies that the fields of this type are laid out sequentially.
  static let tdSequentialLayout: CorTypeAttr = .init(rawValue: 0x00000008)
  /// Specifies that field layout is supplied explicitly.
  static let tdExplicitLayout: CorTypeAttr = .init(rawValue: 0x00000010)

  /// Gets semantic information about the type.
  static let tdClassSemanticsMask: CorTypeAttr = .init(rawValue: 0x00000020)
  /// Specifies that the type is a class.
  static let tdClass: CorTypeAttr = .init(rawValue: 0x00000000)
  /// Specifies that the type is an interface.
  static let tdInterface: CorTypeAttr = .init(rawValue: 0x00000020)

  /// Specifies that the type is abstract.
  static let tdAbstract: CorTypeAttr = .init(rawValue: 0x00000080)
  /// Specifies that the type cannot be extended.
  static let tdSealed: CorTypeAttr = .init(rawValue: 0x00000100)
  /// Specifies that the class name is special. Its name describes how.
  static let tdSpecialName: CorTypeAttr = .init(rawValue: 0x00000400)

  /// Specifies that the type is imported.
  static let tdImport: CorTypeAttr = .init(rawValue: 0x00001000)
  /// Specifies that the type is serializable.
  static let tdSerializable: CorTypeAttr = .init(rawValue: 0x00002000)
  /// Specifies that this type is a Windows Runtime type.
  static let tdWindowsRuntime: CorTypeAttr = .init(rawValue: 0x00004000)

  /// Gets information about how strings are encoded and formatted.
  static let tdStringFormatMask: CorTypeAttr = .init(rawValue: 0x00030000)
  /// Specifies that this type interprets an `LPTSTR` as ANSI.
  static let tdAnsiClass: CorTypeAttr = .init(rawValue: 0x00000000)
  /// Specifies that this type interprets an `LPTSTR` as Unicode.
  static let tdUnicodeClass: CorTypeAttr = .init(rawValue: 0x00010000)
  /// Specifies that this type interprets an `LPTSTR` automatically.
  static let tdAutoClass: CorTypeAttr = .init(rawValue: 0x00020000)
  /// Specifies that the type has a non-standard encoding, as specified by
  /// `CustomFormatMask`.
  static let tdCustomFormatClass: CorTypeAttr = .init(rawValue: 0x00030000)
  /// Use this mask to get non-standard encoding information for native interop.
  /// The meaning of the values of these two bits is unspecified.
  static let tdCustomFormatMask: CorTypeAttr = .init(rawValue: 0x00C00000)

  /// Specifies that the type must be initialized before the first attempt to
  /// access a static field.
  static let tdBeforeFieldInit: CorTypeAttr = .init(rawValue: 0x00100000)
  /// Specifies that the type is exported, and a type forwarder.
  static let tdForwarder: CorTypeAttr = .init(rawValue: 0x00200000)

  /// This flag and the flags below are used internally by the common language
  /// runtime.
  static let tdReservedMask: CorTypeAttr = .init(rawValue: 0x00040800)
  /// Specifies that the common language runtime should check the name encoding.
  static let tdRTSpecialName: CorTypeAttr = .init(rawValue: 0x00000800)
  /// Specifies that the type has security associated with it.
  static let tdHasSecurity: CorTypeAttr = .init(rawValue: 0x00040000)
}

/// Contains values that describe metadata about a field.
public struct CorFieldAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies accessibility information.
  static let fdFieldAccessMask: CorFieldAttr = .init(rawValue: 0x0007)
  /// Specifies that the field cannot be referenced.
  static let fdPrivateScope: CorFieldAttr = .init(rawValue: 0x0000)
  /// Specifies that the field is accessible only by its parent type.
  static let fdPrivate: CorFieldAttr = .init(rawValue: 0x0001)
  /// Specifies that the field is accessible by derived classes in its assembly.
  static let fdFamANDAssem: CorFieldAttr = .init(rawValue: 0x0002)
  /// Specifies that the field is accessible by all types in its assembly.
  static let fdAssembly: CorFieldAttr = .init(rawValue: 0x0003)
  /// Specifies that the field is accessible only by its type and derived
  /// classes.
  static let fdFamily: CorFieldAttr = .init(rawValue: 0x0004)
  /// Specifies that the field is accessible by derived classes and by all types
  /// in its assembly.
  static let fdFamORAssem: CorFieldAttr = .init(rawValue: 0x0005)
  /// Specifies that the field is accessible by all types with visibility of
  /// this scope.
  static let fdPublic: CorFieldAttr = .init(rawValue: 0x0006)

  /// Specifies that the field is a member of its type rather than an instance
  /// member.
  static let fdStatic: CorFieldAttr = .init(rawValue: 0x0010)
  /// Specifies that the field cannot be changed after it is initialized.
  static let fdInitOnly: CorFieldAttr = .init(rawValue: 0x0020)
  /// Specifies that the field value is a compile-time constant.
  static let fdLiteral: CorFieldAttr = .init(rawValue: 0x0040)
  /// Specifies that the field is not serialized when its type is remoted.
  static let fdNotSerialized: CorFieldAttr = .init(rawValue: 0x0080)

  /// Specifies that the field is special, and that its name describes how.
  static let fdSpecialName: CorFieldAttr = .init(rawValue: 0x0200)

  /// Specifies that the field implementation is forwarded through PInvoke.
  static let fdPinvokeImpl: CorFieldAttr = .init(rawValue: 0x2000)

  /// Reserved for internal use by the common language runtime.
  static let fdReservedMask: CorFieldAttr = .init(rawValue: 0x9500)
  /// Specifies that the common language runtime metadata internal APIs should
  /// check the encoding of the name.
  static let fdRTSpecialName: CorFieldAttr = .init(rawValue: 0x0400)
  /// Specifies that the field contains marshaling information.
  static let fdHasFieldMarshal: CorFieldAttr = .init(rawValue: 0x1000)
  /// Specifies that the field has a default value.
  static let fdHasDefault: CorFieldAttr = .init(rawValue: 0x8000)
  /// Specifies that the field has a relative virtual address.
  static let fdHasFieldRVA: CorFieldAttr = .init(rawValue: 0x0100)
}

/// Contains values that describe method implementation features.
public struct CorMethodImpl: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Flags that describe code type.
  static let miCodeTypeMask: CorMethodImpl = .init(rawValue: 0x0003)
  /// Specifies that the method implementation is Microsoft intermediate
  /// language (MSIL).
  static let miIL: CorMethodImpl = .init(rawValue: 0x0000)
  /// Specifies that the method implementation is native.
  static let miNative: CorMethodImpl = .init(rawValue: 0x0001)
  /// Specifies that the method implementation is OPTIL.
  static let miOPTIL: CorMethodImpl = .init(rawValue: 0x0002)
  /// Specifies that the method implementation is provided by the common
  /// language runtime.
  static let miRuntime: CorMethodImpl = .init(rawValue: 0x0003)

  /// Flags that indicate whether the code is managed or unmanaged.
  static let miManagedMask: CorMethodImpl = .init(rawValue: 0x0004)
  /// Specifies that the method implementation is unmanaged.
  static let miUnmanaged: CorMethodImpl = .init(rawValue: 0x0004)
  /// Specifies that the method implementation is managed.
  static let miManaged: CorMethodImpl = .init(rawValue: 0x0000)

  /// Specifies that the method is defined. This flag is used primarily in merge
  /// scenarios.
  static let miForwardRef: CorMethodImpl = .init(rawValue: 0x0010)
  /// Specifies that the method signature cannot be mangled for an `HRESULT`
  /// conversion.
  static let miPreserveSig: CorMethodImpl = .init(rawValue: 0x0080)

  /// Reserved for internal use by the common language runtime.
  static let miInternalCall: CorMethodImpl = .init(rawValue: 0x1000)
  /// Specifies that the method is single-threaded through its body.
  static let miSynchronized: CorMethodImpl = .init(rawValue: 0x0020)
  /// Specifies that the method cannot be inlined.
  static let miNoInlining: CorMethodImpl = .init(rawValue: 0x0008)
  /// Specifies that the method should be inlined if possible.
  static let miAggressiveInlining: CorMethodImpl = .init(rawValue: 0x0100)
  /// Specifies that the method should not be optimized.
  static let miNoOptimization: CorMethodImpl = .init(rawValue: 0x0040)
  /// The maximum valid value for a `CorMethodImpl`.
  static let miMaxMethodImplVal: CorMethodImpl = .init(rawValue: 0xffff)
}

/// Contains values that describe the features of a method.
public struct CorMethodAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies member access.
  static let mdMemberAccessMask: CorMethodAttr = .init(rawValue: 0x0007)
  /// Specifies that the member cannot be referenced.
  static let mdPrivateScope: CorMethodAttr = .init(rawValue: 0x0000)
  /// Specifies that the member is accessible only by the parent type.
  static let mdPrivate: CorMethodAttr = .init(rawValue: 0x0001)
  /// Specifies that the member is accessible by subtypes only in this assembly.
  static let mdFamANDAssem: CorMethodAttr = .init(rawValue: 0x0002)
  /// Specifies that the member is accessibly by anyone in the assembly.
  static let mdAssem: CorMethodAttr = .init(rawValue: 0x0003)
  /// Specifies that the member is accessible only by type and subtypes.
  static let mdFamily: CorMethodAttr = .init(rawValue: 0x0004)
  /// Specifies that the member is accessible by derived classes and by other
  /// types in its assembly.
  static let mdFamORAssem: CorMethodAttr = .init(rawValue: 0x0005)
  /// Specifies that the member is accessible by all types with access to the
  /// scope.
  static let mdPublic: CorMethodAttr = .init(rawValue: 0x0006)

  /// Specifies that the member is defined as part of the type rather than as a
  /// member of an instance.
  static let mdStatic: CorMethodAttr = .init(rawValue: 0x0010)
  /// Specifies that the method cannot be overridden.
  static let mdFinal: CorMethodAttr = .init(rawValue: 0x0020)
  /// Specifies that the method can be overridden.
  static let mdVirtual: CorMethodAttr = .init(rawValue: 0x0040)
  /// Specifies that the method hides by name and signature, rather than just by
  /// name.
  static let mdHideBySig: CorMethodAttr = .init(rawValue: 0x0080)

  /// Specifies virtual table layout.
  static let mdVtableLayoutMask: CorMethodAttr = .init(rawValue: 0x0100)
  /// Specifies that the slot used for this method in the virtual table be
  /// reused. This is the default.
  static let mdReuseSlot: CorMethodAttr = .init(rawValue: 0x0000)
  /// Specifies that the method always gets a new slot in the virtual table.
  static let mdNewSlot: CorMethodAttr = .init(rawValue: 0x0100)

  /// Specifies that the method can be overridden by the same types to which it
  /// is visible.
  static let mdCheckAccessOnOverride: CorMethodAttr = .init(rawValue: 0x0200)
  /// Specifies that the method is not implemented.
  static let mdAbstract: CorMethodAttr = .init(rawValue: 0x0400)
  /// Specifies that the method is special, and that its name describes how.
  static let mdSpecialName: CorMethodAttr = .init(rawValue: 0x0800)

  /// Specifies that the method implementation is forwarded using PInvoke.
  static let mdPinvokeImpl: CorMethodAttr = .init(rawValue: 0x2000)
  /// Specifies that the method is a managed method exported to unmanaged code.
  static let mdUnmanagedExport: CorMethodAttr = .init(rawValue: 0x0008)

  /// Reserved for internal use by the common language runtime.
  static let mdReservedMask: CorMethodAttr = .init(rawValue: 0xd000)
  /// Specifies that the common language runtime should check the encoding of
  /// the method name.
  static let mdRTSpecialName: CorMethodAttr = .init(rawValue: 0x1000)
  /// Specifies that the method has security associated with it.
  static let mdHasSecurity: CorMethodAttr = .init(rawValue: 0x4000)
  /// Specifies that the method calls another method containing security code.
  static let mdRequireSecObject: CorMethodAttr = .init(rawValue: 0x8000)
}

/// Contains values that describe the metadata of a method parameter.
public struct CorParamAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the parameter is passed into the method call.
  static let pdIn: CorParamAttr = .init(rawValue: 0x0001)
  /// Specifies that the parameter is passed from the method return.
  static let pdOut: CorParamAttr = .init(rawValue: 0x0002)
  /// Specifies that the parameter is optional.
  static let pdOptional: CorParamAttr = .init(rawValue: 0x0010)

  /// Reserved for internal use by the common language runtime.
  static let pdReservedMask: CorParamAttr = .init(rawValue: 0xf000)
  /// Specifies that the parameter has a default value.
  static let pdHasDefault: CorParamAttr = .init(rawValue: 0x1000)
  /// Specifies that the parameter has marshaling information.
  static let pdHasFieldMarshal: CorParamAttr = .init(rawValue: 0x2000)

  /// Unused.
  static let pdUnused: CorParamAttr = .init(rawValue: 0xcfe0)
}

/// Contains values that describe the metadata of an event.
public struct CorEventAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the event is special, and that its name describes how.
  static let evSpecialName: CorEventAttr = .init(rawValue: 0x0200)
  /// Reserved for internal use by the common language runtime.
  static let evRTSpecialName: CorEventAttr = .init(rawValue: 0x0400)

  /// Specifies that the common language runtime should check the encoding of
  /// the event name.
  static let evReservedMask: CorEventAttr = .init(rawValue: 0x0400)
}

/// Contains values that describe the metadata of a property.
public struct CorPropertyAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the property is special, and that its name describes how.
  static let prSpecialName: CorPropertyAttr = .init(rawValue: 0x0200)
  /// Specifies that the common language runtime metadata internal APIs should
  /// check the encoding of the property name.
  static let prRTSpecialName: CorPropertyAttr = .init(rawValue: 0x0400)
  /// Specifies that the property has a default value.
  static let prHasDefault: CorPropertyAttr = .init(rawValue: 0x1000)

  /// Unused.
  static let prUnused: CorPropertyAttr = .init(rawValue: 0xe9ff)
  /// Reserved for internal use by the common language runtime.
  static let prReservedMask: CorPropertyAttr = .init(rawValue: 0xf400)
}

/// Contains values that describe the relationship between a method and an
/// associated property or event.
public struct CorMethodSemanticsAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Specifies that the method is a `set` accessor for a property.
  static let msSetter: CorMethodSemanticsAttr = .init(rawValue: 0x0001)
  /// Specifies that the method is a `get` accessor for a property.
  static let msGetter: CorMethodSemanticsAttr = .init(rawValue: 0x0002)
  /// Specifies that the method has a relationship to a property or an event
  /// other than those defined here.
  static let msOther: CorMethodSemanticsAttr = .init(rawValue: 0x0004)
  /// Specifies that the method adds handler methods for an event.
  static let msAddOn: CorMethodSemanticsAttr = .init(rawValue: 0x0008)
  /// Specifies that the method removes handler methods for an event.
  static let msRemoveOn: CorMethodSemanticsAttr = .init(rawValue: 0x0010)
  /// Specifies that the method raises an event.
  static let msFire: CorMethodSemanticsAttr = .init(rawValue: 0x0020)
}

/// Specifies options for a PInvoke call.
public struct CorPinvokeMap: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Use each member name as specified.
  static let pmNoMangle: CorPinvokeMap = .init(rawValue: 0x0001)

  /// Reserved.
  static let pmCharSetMask: CorPinvokeMap = .init(rawValue: 0x0006)
  /// Reserved.
  static let pmCharSetNotSpec: CorPinvokeMap = .init(rawValue: 0x0000)
  /// Marshal strings as multiple-byte character strings.
  static let pmCharSetAnsi: CorPinvokeMap = .init(rawValue: 0x0002)
  /// Marshal strings as Unicode 2-byte characters.
  static let pmCharSetUnicode: CorPinvokeMap = .init(rawValue: 0x0004)
  /// Automatically marshal strings appropriately for the target operating
  /// system. The default is Unicode on Windows.
  static let pmCharSetAuto: CorPinvokeMap = .init(rawValue: 0x0006)

  /// Reserved.
  static let pmBestFitUseAssem: CorPinvokeMap = .init(rawValue: 0x0000)
  /// Perform best-fit mapping of Unicode characters that lack an exact match in
  /// the ANSI character set.
  static let pmBestFitEnabled: CorPinvokeMap = .init(rawValue: 0x0010)
  /// Do not perform best-fit mapping of Unicode characters. In this case, all
  /// unmappable characters will be replaced by a ‘?’.
  static let pmBestFitDisabled: CorPinvokeMap = .init(rawValue: 0x0020)
  /// Reserved.
  static let pmBestFitMask: CorPinvokeMap = .init(rawValue: 0x0030)

  /// Reserved.
  static let pmThrowOnUnmappableCharUseAssem: CorPinvokeMap = .init(rawValue: 0x0000)
  /// Throw an exception when the interop marshaler encounters an unmappable
  /// character.
  static let pmThrowOnUnmappableCharEnabled: CorPinvokeMap = .init(rawValue: 0x1000)
  /// Do not throw an exception when the interop marshaler encounters an
  /// unmappable character.
  static let pmThrowOnUnmappableCharDisabled: CorPinvokeMap = .init(rawValue: 0x2000)
  /// Reserved.
  static let pmThrowOnUnmappableCharMask: CorPinvokeMap = .init(rawValue: 0x3000)

  /// Allow the callee to call the Win32 SetLastError function before returning
  /// from the attributed method.
  static let pmSupportsLastError: CorPinvokeMap = .init(rawValue: 0x0040)

  /// Reserved.
  static let pmCallConvMask: CorPinvokeMap = .init(rawValue: 0x0700)
  /// Use the default platform calling convention. For example, on Windows the
  /// default is `stdcall` and on Windows CE .NET it is `cdecl`.
  static let pmCallConvWinapi: CorPinvokeMap = .init(rawValue: 0x0100)
  /// Use the `cdecl` calling convention. In this case, the caller cleans the
  /// stack. This enables calling functions with `varargs` (that is, functions
  /// that accept a variable number of parameters).
  static let pmCallConvCdecll: CorPinvokeMap = .init(rawValue: 0x0200)
  /// Use the `stdcall` calling convention. In this case, the callee cleans the
  /// stack. This is the default convention for calling unmanaged functions with
  /// platform invoke.
  static let pmCallConvStdcall: CorPinvokeMap = .init(rawValue: 0x0300)
  /// Use the `thiscall` calling convention. In this case, the first parameter
  /// is the this pointer and is stored in register ECX. Other parameters are
  /// pushed on the stack. The `thiscall` calling convention is used to call
  /// methods on classes exported from an unmanaged DLL.
  static let pmCallConvThiscall: CorPinvokeMap = .init(rawValue: 0x0400)
  /// Reserved.
  static let pmCallConvFastcall: CorPinvokeMap = .init(rawValue: 0x0500)

  /// Reserved.
  static let pmMaxValue: CorPinvokeMap = .init(rawValue: 0xffff)
}

/// Contains values that describe the metadata applied to an assembly
/// compilation.
public struct CorAssemblyFlags: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Indicates that the assembly reference holds the full, unhashed public key.
  static let afPublicKey: CorAssemblyFlags = .init(rawValue: 0x0001)
  /// Indicates that the processor architecture is unspecified.
  static let afPA_None: CorAssemblyFlags = .init(rawValue: 0x0000)
  /// Indicates that the processor architecture is neutral (PE32).
  static let afPA_MSIL: CorAssemblyFlags = .init(rawValue: 0x0010)
  /// Indicates that the processor architecture is x86 (PE32).
  static let afPA_x86: CorAssemblyFlags = .init(rawValue: 0x0020)
  /// Indicates that the processor architecture is Itanium (PE32+).
  static let afPA_IA64: CorAssemblyFlags = .init(rawValue: 0x0030)
  /// Indicates that the processor architecture is AMD X64 (PE32+).
  static let afPA_AMD64: CorAssemblyFlags = .init(rawValue: 0x0040)
  /// Indicates that the processor architecture is ARM (PE32).
  static let afPA_ARM: CorAssemblyFlags = .init(rawValue: 0x0050)
  /// Indicates that the assembly is a reference assembly; that is, it applies
  /// to any architecture but cannot run on any architecture. Thus, the flag is
  /// the same as afPA_Mask.
  static let afPA_NoPlatform: CorAssemblyFlags = .init(rawValue: 0x0070)
  /// Indicates that the processor architecture flags should be propagated to
  /// the `AssemblyRef` record.
  static let afPA_Specified: CorAssemblyFlags = .init(rawValue: 0x0080)
  /// A mask that describes the processor architecture.
  static let afPA_Mask: CorAssemblyFlags = .init(rawValue: 0x0070)
  /// Specifies that the processor architecture description is included.
  static let afPA_FullMask: CorAssemblyFlags = .init(rawValue: 0x00f0)
  /// Indicates a shift count in the processor architecture flags to and from
  /// the index.
  static let afPA_Shift: CorAssemblyFlags = .init(rawValue: 0x0004)

  /// Indicates the corresponding value from the
  /// `DebuggableAttribute.DebuggingModes` of the `DebuggableAttribute`.
  static let afEnableJITcompileTracking: CorAssemblyFlags = .init(rawValue: 0x8000)
  /// Indicates the corresponding value from the
  /// `DebuggableAttribute.DebuggingModes` of the `DebuggableAttribute`.
  static let afDisableJITcompileOptimizer: CorAssemblyFlags = .init(rawValue: 0x4000)

  /// Indicates that the assembly can be retargeted at run time to an assembly
  /// from a different publisher.
  static let afRetargetable: CorAssemblyFlags = .init(rawValue: 0x0100)
  /// Indicates the default content type.
  static let afContentType_Default: CorAssemblyFlags = .init(rawValue: 0x0000)
  /// Indicates the Windows Runtime content type.
  static let afContentType_WindowsRuntime: CorAssemblyFlags = .init(rawValue: 0x0200)
  /// A mask that describes the content type.
  static let afContentType_Mask: CorAssemblyFlags = .init(rawValue: 0x0e00)
}

/// Contains values that describe the type of file defined in a call to
/// `IMetaDataAssemblyEmit::DefineFile`.
public struct CorFileFlags: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Indicates that the file is not a resource file.
  static let ffContainsMetaData: CorFileFlags = .init(rawValue: 0x0000)
  /// Indicates that the file, possibly a resource file, does not contain metadata.
  static let ffContainsNoMetaData: CorFileFlags = .init(rawValue: 0x0001)
}

/// Indicates the visibility of resources encoded in an assembly manifest.
public struct CorManifestResourceFlags: OptionSet {
  public typealias RawValue = UInt32

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Reserved.
  static let mrVisibilityMask: CorManifestResourceFlags = .init(rawValue: 0x0007)
  /// The resources are public.
  static let mrPublic: CorManifestResourceFlags = .init(rawValue: 0x0001)
  /// The resources are private.
  static let mrPrivate: CorManifestResourceFlags = .init(rawValue: 0x0002)
}

/// Contains values that describe the `Type` parameters for generic types, as
/// used in calls to `IMetaDataEmit2::DefineGenericParam`.
public struct CorGenericParamAttr: OptionSet {
  public typealias RawValue = UInt16

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Parameter variance applies only to generic parameters for interfaces and
  /// delegates.
  static let gpVarianceMask: CorGenericParamAttr = .init(rawValue: 0x0003)
  /// Indicates the absence of variance.
  static let gpNonVariant: CorGenericParamAttr = .init(rawValue: 0x0000)
  /// Indicates covariance.
  static let gpCovariant: CorGenericParamAttr = .init(rawValue: 0x0001)
  /// Indicates contravariance.
  static let gpContravariant: CorGenericParamAttr = .init(rawValue: 0x0002)

  /// Special constraints can apply to any `Type` parameter.
  static let gpSpecialConstraintMask: CorGenericParamAttr = .init(rawValue: 0x001c)
  /// Indicates that no constraint applies to the `Type` parameter.
  static let gpNoSpecialConstraint: CorGenericParamAttr = .init(rawValue: 0x0000)
  /// Indicates that the `Type` parameter must be a reference type.
  static let gpReferenceTypeConstraint: CorGenericParamAttr = .init(rawValue: 0x0004)
  /// Indicates that the `Type` parameter must be a value type that cannot be a
  /// null value.
  static let gpNotNullableValueTypeConstraint: CorGenericParamAttr = .init(rawValue: 0x0008)
  /// Indicates that the `Type` parameter must have a default public constructor
  /// that takes no parameters.
  static let gpDefaultConstructorConstraint: CorGenericParamAttr = .init(rawValue: 0x0010)
}

/// Specifies a common language runtime `Type`, a type modifier, or information
/// about a type in a metadata type signature.
public struct CorElementType: OptionSet {
  public typealias RawValue = UInt8

  public let rawValue: RawValue

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  /// Used internally.
  static let etEnd: CorElementType = .init(rawValue: 0x00)
  /// A void type.
  static let etVoid: CorElementType = .init(rawValue: 0x01)
  /// A Boolean type.
  static let etBoolean: CorElementType = .init(rawValue: 0x02)
  /// A character type.
  static let etChar: CorElementType = .init(rawValue: 0x03)
  /// A signed 1-byte integer.
  static let etInt1: CorElementType = .init(rawValue: 0x04)
  /// An unsigned 1-byte integer.
  static let etUInt1: CorElementType = .init(rawValue: 0x05)
  /// A signed 2-byte integer.
  static let etInt2: CorElementType = .init(rawValue: 0x06)
  /// An unsigned 2-byte integer.
  static let etUInt2: CorElementType = .init(rawValue: 0x07)
  /// A signed 4-byte integer.
  static let etInt4: CorElementType = .init(rawValue: 0x08)
  /// An unsigned 4-byte integer.
  static let etUInt4: CorElementType = .init(rawValue: 0x09)
  /// A signed 8-byte integer.
  static let etInt8: CorElementType = .init(rawValue: 0x0a)
  /// An unsigned 8-byte integer.
  static let etUInt8: CorElementType = .init(rawValue: 0x0b)
  /// A 4-byte floating point.
  static let etFloat: CorElementType = .init(rawValue: 0x0c)
  /// An 8-byte floating point.
  static let etDouble: CorElementType = .init(rawValue: 0x0d)
  /// A System.String type.
  static let etString: CorElementType = .init(rawValue: 0x0e)

  /// A pointer type modifier.
  static let etPtr: CorElementType = .init(rawValue: 0x0f)
  /// A reference type modifier.
  static let etByRef: CorElementType = .init(rawValue: 0x10)

  /// A value type modifier.
  static let etValueType: CorElementType = .init(rawValue: 0x11)
  /// A class type modifier.
  static let etClass: CorElementType = .init(rawValue: 0x12)
  /// A class variable type modifier.
  static let etVar: CorElementType = .init(rawValue: 0x13)
  /// A multi-dimensional array type modifier.
  static let etArray: CorElementType = .init(rawValue: 0x14)
  /// A type modifier for generic types.
  static let etGenericInst: CorElementType = .init(rawValue: 0x15)
  /// A typed reference.
  static let etTypedByRef: CorElementType = .init(rawValue: 0x16)

  /// Size of a native integer.
  static let etInt: CorElementType = .init(rawValue: 0x18)
  /// Size of an unsigned native integer.
  static let etUInt: CorElementType = .init(rawValue: 0x19)
  /// A pointer to a function.
  static let etFnPtr: CorElementType = .init(rawValue: 0x1b)
  /// A System.Object type.
  static let etObject: CorElementType = .init(rawValue: 0x1c)
  /// A single-dimensional, zero lower-bound array type modifier.
  static let etSzArray: CorElementType = .init(rawValue: 0x1d)
  /// A method variable type modifier.
  static let etMVar: CorElementType = .init(rawValue: 0x1e)

  /// A C language required modifier.
  static let etCModReqd: CorElementType = .init(rawValue: 0x1f)
  /// A C language optional modifier.
  static let etCModOpt: CorElementType = .init(rawValue: 0x20)

  /// Used internally.
  static let etInternal: CorElementType = .init(rawValue: 0x21)
  /// An invalid type.
  static let etMax: CorElementType = .init(rawValue: 0x22)

  /// Used internally.
  static let etModifier: CorElementType = .init(rawValue: 0x40)
  /// A type modifier that is a sentinel for a list of a variable number of
  /// parameters.
  static let etSentinel: CorElementType = .init(rawValue: 0x01 | CorElementType.etModifier.rawValue)
  /// Used internally.
  static let etPinned: CorElementType = .init(rawValue: 0x05 | CorElementType.etModifier.rawValue)
}
