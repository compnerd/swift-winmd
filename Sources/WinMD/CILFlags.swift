// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public struct CorTypeAttr: OptionSet {
  public let rawValue: UInt32

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let tdVisibilityMask: CorTypeAttr = .init(rawValue: 0x00000007)
  static let tdNotPublic: CorTypeAttr = .init(rawValue: 0x00000000)
  static let tdPublic: CorTypeAttr = .init(rawValue: 0x00000001)
  static let tdNestedPublic: CorTypeAttr = .init(rawValue: 0x00000002)
  static let tdNestedPrivate: CorTypeAttr = .init(rawValue: 0x00000003)
  static let tdNestedFamily: CorTypeAttr = .init(rawValue: 0x00000004)
  static let tdNestedAssembly: CorTypeAttr = .init(rawValue: 0x00000005)
  static let tdNestedFamANDAssem: CorTypeAttr = .init(rawValue: 0x00000006)
  static let tdNestedFamORAssem: CorTypeAttr = .init(rawValue: 0x00000007)

  static let tdLayoutMask: CorTypeAttr = .init(rawValue: 0x00000018)
  static let tdAutoLayout: CorTypeAttr = .init(rawValue: 0x00000000)
  static let tdSequentialLayout: CorTypeAttr = .init(rawValue: 0x00000008)
  static let tdExplicitLayout: CorTypeAttr = .init(rawValue: 0x00000010)

  static let tdClassSemanticsMask: CorTypeAttr = .init(rawValue: 0x00000020)
  static let tdClass: CorTypeAttr = .init(rawValue: 0x00000000)
  static let tdInterface: CorTypeAttr = .init(rawValue: 0x00000020)

  static let tdAbstract: CorTypeAttr = .init(rawValue: 0x00000080)
  static let tdSealed: CorTypeAttr = .init(rawValue: 0x00000100)
  static let tdSpecialName: CorTypeAttr = .init(rawValue: 0x00000400)

  static let tdImport: CorTypeAttr = .init(rawValue: 0x00001000)
  static let tdSerializable: CorTypeAttr = .init(rawValue: 0x00002000)
  static let tdWindowsRuntime: CorTypeAttr = .init(rawValue: 0x00004000)

  static let tdStringFormatMask: CorTypeAttr = .init(rawValue: 0x00030000)
  static let tdAnsiClass: CorTypeAttr = .init(rawValue: 0x00000000)
  static let tdUnicodeClass: CorTypeAttr = .init(rawValue: 0x00010000)
  static let tdAutoClass: CorTypeAttr = .init(rawValue: 0x00020000)
  static let tdCustomFormatClass: CorTypeAttr = .init(rawValue: 0x00030000)
  static let tdCustomFormatMask: CorTypeAttr = .init(rawValue: 0x00C00000)

  static let tdBeforeFieldInit: CorTypeAttr = .init(rawValue: 0x00100000)
  static let tdForwarder: CorTypeAttr = .init(rawValue: 0x00200000)

  static let tdReservedMask: CorTypeAttr = .init(rawValue: 0x00040800)
  static let tdRTSpecialName: CorTypeAttr = .init(rawValue: 0x00000800)
  static let tdHasSecurity: CorTypeAttr = .init(rawValue: 0x00040000)
}

public struct CorFieldAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let fdFieldAccessMask: CorFieldAttr = .init(rawValue: 0x0007)
  static let fdPrivateScope: CorFieldAttr = .init(rawValue: 0x0000)
  static let fdPrivate: CorFieldAttr = .init(rawValue: 0x0001)
  static let fdFamANDAssem: CorFieldAttr = .init(rawValue: 0x0002)
  static let fdAssembly: CorFieldAttr = .init(rawValue: 0x0003)
  static let fdFamily: CorFieldAttr = .init(rawValue: 0x0004)
  static let fdFamORAssem: CorFieldAttr = .init(rawValue: 0x0005)
  static let fdPublic: CorFieldAttr = .init(rawValue: 0x0006)

  static let fdStatic: CorFieldAttr = .init(rawValue: 0x0010)
  static let fdInitOnly: CorFieldAttr = .init(rawValue: 0x0020)
  static let fdLiteral: CorFieldAttr = .init(rawValue: 0x0040)
  static let fdNotSerialized: CorFieldAttr = .init(rawValue: 0x0080)

  static let fdSpecialName: CorFieldAttr = .init(rawValue: 0x0200)

  static let fdPinvokeImpl: CorFieldAttr = .init(rawValue: 0x2000)

  static let fdReservedMask: CorFieldAttr = .init(rawValue: 0x9500)
  static let fdRTSpecialName: CorFieldAttr = .init(rawValue: 0x0400)
  static let fdHasFieldMarshal: CorFieldAttr = .init(rawValue: 0x1000)
  static let fdHasDefault: CorFieldAttr = .init(rawValue: 0x8000)
  static let fdHasFieldRVA: CorFieldAttr = .init(rawValue: 0x0100)
}

public struct CorMethodImpl: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let miCodeTypeMask: CorMethodImpl = .init(rawValue: 0x0003)
  static let miIL: CorMethodImpl = .init(rawValue: 0x0000)
  static let miNative: CorMethodImpl = .init(rawValue: 0x0001)
  static let miOPTIL: CorMethodImpl = .init(rawValue: 0x0002)
  static let miRuntime: CorMethodImpl = .init(rawValue: 0x0003)

  static let miManagedMask: CorMethodImpl = .init(rawValue: 0x0004)
  static let miUnmanaged: CorMethodImpl = .init(rawValue: 0x0004)
  static let miManaged: CorMethodImpl = .init(rawValue: 0x0000)

  static let miForwardRef: CorMethodImpl = .init(rawValue: 0x0010)
  static let miPreserveSig: CorMethodImpl = .init(rawValue: 0x0080)

  static let miInternalCall: CorMethodImpl = .init(rawValue: 0x1000)
  static let miSynchronized: CorMethodImpl = .init(rawValue: 0x0020)
  static let miNoInlining: CorMethodImpl = .init(rawValue: 0x0008)
  static let miAggressiveInlining: CorMethodImpl = .init(rawValue: 0x0100)
  static let miNoOptimization: CorMethodImpl = .init(rawValue: 0x0040)
  static let miMaxMethodImplVal: CorMethodImpl = .init(rawValue: 0xffff)
}

public struct CorMethodAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let mdMemberAccessMask: CorMethodAttr = .init(rawValue: 0x0007)
  static let mdPrivateScope: CorMethodAttr = .init(rawValue: 0x0000)
  static let mdPrivate: CorMethodAttr = .init(rawValue: 0x0001)
  static let mdFamANDAssem: CorMethodAttr = .init(rawValue: 0x0002)
  static let mdAssem: CorMethodAttr = .init(rawValue: 0x0003)
  static let mdFamily: CorMethodAttr = .init(rawValue: 0x0004)
  static let mdFamORAssem: CorMethodAttr = .init(rawValue: 0x0005)
  static let mdPublic: CorMethodAttr = .init(rawValue: 0x0006)

  static let mdStatic: CorMethodAttr = .init(rawValue: 0x0010)
  static let mdFinal: CorMethodAttr = .init(rawValue: 0x0020)
  static let mdVirtual: CorMethodAttr = .init(rawValue: 0x0040)
  static let mdHideBySig: CorMethodAttr = .init(rawValue: 0x0080)

  static let mdVtableLayoutMask: CorMethodAttr = .init(rawValue: 0x0100)
  static let mdReuseSlot: CorMethodAttr = .init(rawValue: 0x0000)
  static let mdNewSlot: CorMethodAttr = .init(rawValue: 0x0100)

  static let mdCheckAccessOnOverride: CorMethodAttr = .init(rawValue: 0x0200)
  static let mdAbstract: CorMethodAttr = .init(rawValue: 0x0400)
  static let mdSpecialName: CorMethodAttr = .init(rawValue: 0x0800)

  static let mdPinvokeImpl: CorMethodAttr = .init(rawValue: 0x2000)
  static let mdUnmanagedExport: CorMethodAttr = .init(rawValue: 0x0008)

  static let mdReservedMask: CorMethodAttr = .init(rawValue: 0xd000)
  static let mdRTSpecialName: CorMethodAttr = .init(rawValue: 0x1000)
  static let mdHasSecurity: CorMethodAttr = .init(rawValue: 0x4000)
  static let mdRequireSecObject: CorMethodAttr = .init(rawValue: 0x8000)
}

public struct CorParamAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let pdIn: CorParamAttr = .init(rawValue: 0x0001)
  static let pdOut: CorParamAttr = .init(rawValue: 0x0002)
  static let pdOptional: CorParamAttr = .init(rawValue: 0x0010)

  static let pdReservedMask: CorParamAttr = .init(rawValue: 0xf000)
  static let pdHasDefault: CorParamAttr = .init(rawValue: 0x1000)
  static let pdHasFieldMarshal: CorParamAttr = .init(rawValue: 0x2000)

  static let pdUnused: CorParamAttr = .init(rawValue: 0xcfe0)
}

public struct CorEventAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let evSpecialName: CorEventAttr = .init(rawValue: 0x0200)
  static let evRTSpecialName: CorEventAttr = .init(rawValue: 0x0400)

  static let evReservedMask: CorEventAttr = .init(rawValue: 0x0400)
}

public struct CorPropertyAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let prSpecialName: CorPropertyAttr = .init(rawValue: 0x0200)
  static let prRTSpecialName: CorPropertyAttr = .init(rawValue: 0x0400)
  static let prHasDefault: CorPropertyAttr = .init(rawValue: 0x1000)

  static let prUnused: CorPropertyAttr = .init(rawValue: 0xe9ff)
  static let prReservedMask: CorPropertyAttr = .init(rawValue: 0xf400)
}

public struct CorMethodSemanticsAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let msSetter: CorMethodSemanticsAttr = .init(rawValue: 0x0001)
  static let msGetter: CorMethodSemanticsAttr = .init(rawValue: 0x0002)
  static let msOther: CorMethodSemanticsAttr = .init(rawValue: 0x0004)
  static let msAddOn: CorMethodSemanticsAttr = .init(rawValue: 0x0008)
  static let msRemoveOn: CorMethodSemanticsAttr = .init(rawValue: 0x0010)
  static let msFire: CorMethodSemanticsAttr = .init(rawValue: 0x0020)
}

public struct CorPinvokeMap: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let pmNoMangle: CorPinvokeMap = .init(rawValue: 0x0001)

  static let pmCharSetMask: CorPinvokeMap = .init(rawValue: 0x0006)
  static let pmCharSetNotSpec: CorPinvokeMap = .init(rawValue: 0x0000)
  static let pmCharSetAnsi: CorPinvokeMap = .init(rawValue: 0x0002)
  static let pmCharSetUnicode: CorPinvokeMap = .init(rawValue: 0x0004)
  static let pmCharSetAuto: CorPinvokeMap = .init(rawValue: 0x0006)

  static let pmBestFitUseAssem: CorPinvokeMap = .init(rawValue: 0x0000)
  static let pmBestFitEnabled: CorPinvokeMap = .init(rawValue: 0x0010)
  static let pmBestFitDisabled: CorPinvokeMap = .init(rawValue: 0x0020)
  static let pmBestFitMask: CorPinvokeMap = .init(rawValue: 0x0030)

  static let pmThrowOnUnmappableCharUseAssem: CorPinvokeMap = .init(rawValue: 0x0000)
  static let pmThrowOnUnmappableCharEnabled: CorPinvokeMap = .init(rawValue: 0x1000)
  static let pmThrowOnUnmappableCharDisabled: CorPinvokeMap = .init(rawValue: 0x2000)
  static let pmThrowOnUnmappableCharMask: CorPinvokeMap = .init(rawValue: 0x3000)

  static let pmSupportsLastError: CorPinvokeMap = .init(rawValue: 0x0040)

  static let pmCallConvMask: CorPinvokeMap = .init(rawValue: 0x0700)
  static let pmCallConvWinapi: CorPinvokeMap = .init(rawValue: 0x0100)
  static let pmCallConvCdecll: CorPinvokeMap = .init(rawValue: 0x0200)
  static let pmCallConvStdcall: CorPinvokeMap = .init(rawValue: 0x0300)
  static let pmCallConvThiscall: CorPinvokeMap = .init(rawValue: 0x0400)
  static let pmCallConvFastcall: CorPinvokeMap = .init(rawValue: 0x0500)

  static let pmMaxValue: CorPinvokeMap = .init(rawValue: 0xffff)
}

public struct CorAssemblyFlags: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let afPublicKey: CorAssemblyFlags = .init(rawValue: 0x0001)
  static let afPA_None: CorAssemblyFlags = .init(rawValue: 0x0000)
  static let afPA_MSIL: CorAssemblyFlags = .init(rawValue: 0x0010)
  static let afPA_x86: CorAssemblyFlags = .init(rawValue: 0x0020)
  static let afPA_IA64: CorAssemblyFlags = .init(rawValue: 0x0030)
  static let afPA_AMD64: CorAssemblyFlags = .init(rawValue: 0x0040)
  static let afPA_ARM: CorAssemblyFlags = .init(rawValue: 0x0050)
  static let afPA_NoPlatform: CorAssemblyFlags = .init(rawValue: 0x0070)
  static let afPA_Specified: CorAssemblyFlags = .init(rawValue: 0x0080)
  static let afPA_Mask: CorAssemblyFlags = .init(rawValue: 0x0070)
  static let afPA_FullMask: CorAssemblyFlags = .init(rawValue: 0x00f0)
  static let afPA_Shift: CorAssemblyFlags = .init(rawValue: 0x0004)

  static let afEnableJITcompileTracking: CorAssemblyFlags = .init(rawValue: 0x8000)
  static let afDisableJITcompileOptimizer: CorAssemblyFlags = .init(rawValue: 0x4000)

  static let afRetargetable: CorAssemblyFlags = .init(rawValue: 0x0100)
  static let afContentType_Default: CorAssemblyFlags = .init(rawValue: 0x0000)
  static let afContentType_WindowsRuntime: CorAssemblyFlags = .init(rawValue: 0x0200)
  static let afContentType_Mask: CorAssemblyFlags = .init(rawValue: 0x0e00)
}

public struct CorFileFlags: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let ffContainsMetaData: CorFileFlags = .init(rawValue: 0x0000)
  static let ffContainsNoMetaData: CorFileFlags = .init(rawValue: 0x0001)
}

public struct CorManifestResourceFlags: OptionSet {
  public let rawValue: UInt32

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let mrVisibilityMask: CorManifestResourceFlags = .init(rawValue: 0x0007)
  static let mrPublic: CorManifestResourceFlags = .init(rawValue: 0x0001)
  static let mrPrivate: CorManifestResourceFlags = .init(rawValue: 0x0002)
}

public struct CorGenericParamAttr: OptionSet {
  public let rawValue: UInt16

  public init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let gpVarianceMask: CorGenericParamAttr = .init(rawValue: 0x0003)
  static let gpNonVariant: CorGenericParamAttr = .init(rawValue: 0x0000)
  static let gpCovariant: CorGenericParamAttr = .init(rawValue: 0x0001)
  static let gpContravariant: CorGenericParamAttr = .init(rawValue: 0x0002)

  static let gpSpecialConstraintMask: CorGenericParamAttr = .init(rawValue: 0x001c)
  static let gpNoSpecialConstraint: CorGenericParamAttr = .init(rawValue: 0x0000)
  static let gpReferenceTypeConstraint: CorGenericParamAttr = .init(rawValue: 0x0004)
  static let gpNotNullableValueTypeConstraint: CorGenericParamAttr = .init(rawValue: 0x0008)
  static let gpDefaultConstructorConstraint: CorGenericParamAttr = .init(rawValue: 0x0010)
}
