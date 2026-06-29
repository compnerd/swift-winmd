// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import WinMD

/// The per-dialect decode functions, emitting the Swift type spelling as text.
///
/// The views + templates path renders text, so the type mapping is a pure
/// function from a decoded `SignatureType` to its Swift spelling — ABI-faithful
/// rules serving as the synthesis oracle. A named type resolves through the
/// injected `Resolver`
/// table (the metaschema's component-schema mapping) and a well-known table to
/// the `COM` module's spelling; `System.Guid` decodes to `IID`/`CLSID` by a
/// parameter-name hint; pointers, references, and arrays decode to the
/// `Unsafe*Pointer` family; the primitives to the `C*` typealias set. This is
/// the decode-function tier: a registered closure per primitive, composed
/// declaratively by the type structure.
extension SignatureType {
  /// The Swift type spelling of `self`, resolving named types through
  /// `resolver` and disambiguating a `System.Guid` by the `parameter`-name hint.
  public func decode(parameter: String? = nil,
                     with resolver: Resolver) -> String {
    switch self {
    case let .primitive(primitive):
      primitive.spelling
    case let .pointer(pointee):
      pointee.spelling(parameter: parameter, const: false, with: resolver)
    case let .reference(referent):
      referent.spelling(parameter: parameter, const: false, with: resolver)
    case let .array(element):
      element.spelling(parameter: parameter, const: false, with: resolver)
    case let .matrix(element, _):
      element.spelling(parameter: parameter, const: false, with: resolver)
    case let .named(kind, reference):
      reference.spelling(kind: kind, parameter: parameter, with: resolver)
    case let .variable(scope, index):
      "\(scope.prefix)\(index)"
    case let .instance(base, arguments):
      base.specialized(by: arguments, parameter: parameter, with: resolver)
    case let .modified(inner, _):
      inner.decode(parameter: parameter, with: resolver)
    case .function:
      "UnsafeMutableRawPointer"
    }
  }
}

// MARK: - Primitives

extension PrimitiveType {
  /// The Swift spelling of a built-in element type: the `C*` typealiases, the
  /// opaque pointer for `object`/`typedref`, and the WinRT `HSTRING` for
  /// `System.String` (`ELEMENT_TYPE_STRING`) — a WinMD `String` is an `HSTRING`
  /// handle at the ABI, not a `PCWSTR` buffer. `PWSTR`/`PCWSTR` arrive as
  /// pointer/named metadata, never `ELEMENT_TYPE_STRING`, so they decode through
  /// those paths instead.
  fileprivate var spelling: String {
    switch self {
    case .void:     "Void"
    case .boolean:  "CBool"
    case .char:     "Unicode.UTF16.CodeUnit"
    case .int1:     "CChar"
    case .uint1:    "CUnsignedChar"
    case .int2:     "CShort"
    case .uint2:    "CUnsignedShort"
    case .int4:     "CInt"
    case .uint4:    "CUnsignedInt"
    case .int8:     "CLongLong"
    case .uint8:    "CUnsignedLongLong"
    case .float:    "CFloat"
    case .double:   "CDouble"
    case .intptr:   "Int"
    case .uintptr:  "UInt"
    case .string:   "HSTRING"
    case .object:   "UnsafeMutableRawPointer"
    case .typedref: "UnsafeMutableRawPointer"
    }
  }
}

// MARK: - Indirection

extension SignatureType {
  /// Decodes a pointer/reference/array to a pointer over its decoded pointee,
  /// where `self` is the pointee.
  ///
  /// `void*` collapses to `UnsafeMutableRawPointer` (or `UnsafeRawPointer` when
  /// `const`). A pointer-to-pointer keeps an *optional* inner element so a
  /// caller can pass a null inner slot: a `void**` (including `const void **`)
  /// is a pointer to an optional raw pointer (immutable when the inner `void`
  /// is `const`), and an `int**`/`IFoo**` a pointer to an optional typed pointer.
  /// Otherwise a non-`void` pointee decodes as `Unsafe{Mutable}Pointer<Pointee>`,
  /// mutable unless a `const` modifier marks the pointee.
  fileprivate func spelling(parameter: String?, const: Bool,
                            with resolver: Resolver) -> String {
    switch self {
    case .primitive(.void):
      const ? "UnsafeRawPointer" : "UnsafeMutableRawPointer"
    case .pointer(.primitive(.void)):
      wrap("UnsafeMutableRawPointer?", const: const)
    case let .pointer(.modified(.primitive(.void), modifiers)):
      wrap(modifiers.constant(with: resolver) ? "UnsafeRawPointer?"
                                              : "UnsafeMutableRawPointer?",
           const: const)
    case .pointer:
      // A non-`void` pointer-to-pointer: the inner pointer slot is itself
      // nullable, so mark the decoded element optional (as the `void**` cases).
      wrap(decode(parameter: parameter, with: resolver) + "?", const: const)
    case let .modified(inner, modifiers):
      inner.spelling(parameter: parameter,
                     const: modifiers.constant(with: resolver),
                     with: resolver)
    default:
      wrap(decode(parameter: parameter, with: resolver), const: const)
    }
  }
}

/// Wraps an already-decoded `pointee` spelling in `Unsafe{Mutable}Pointer<…>`.
private func wrap(_ pointee: String, const: Bool) -> String {
  "\(const ? "UnsafePointer" : "UnsafeMutablePointer")<\(pointee)>"
}

extension Array where Element == Modifier {
  /// Whether the run carries the `IsConst` custom modifier — the only modifier
  /// that marks a pointee `const`.
  ///
  /// A `CMOD_REQD`/`CMOD_OPT` can name any type, so a non-`IsConst` modifier
  /// must leave the pointee mutable. Each modifier's type resolves through
  /// `resolver` (which already collects modifier identities) and is matched
  /// against the `IsConst` identity.
  fileprivate func constant(with resolver: Resolver) -> Bool {
    contains { resolver.resolve($0.type, kind: .class) == kIsConst }
  }
}

/// The `System.Runtime.CompilerServices.IsConst` modopt a `const` pointee
/// carries — the sole custom modifier the decode treats as `const`.
private let kIsConst =
    Identity(namespace: "System.Runtime.CompilerServices", name: "IsConst")

// MARK: - Named types

extension TypeDefOrRef {
  /// The Swift spelling of the named type `self` references, resolved through
  /// `resolver` and the well-known table.
  ///
  /// A resolved `System.Guid` renders as `IID`/`CLSID` by the parameter-name
  /// hint; otherwise the `Identity` is looked up in the well-known table
  /// (`HRESULT`, `BOOL`, …), a miss rendering the type's own simple name. An
  /// unresolvable reference renders an opaque pointer.
  fileprivate func spelling(kind: NamedKind, parameter: String?,
                            with resolver: Resolver) -> String {
    guard let identity = resolver.resolve(self, kind: kind) else {
      return kOpaque
    }
    if identity == kGuid {
      return classification(parameter)
    }
    return kWellKnown[identity] ?? identity.name
  }
}

/// The opaque pointer an unresolvable type degrades to — and that a generic
/// over such a base degrades to, rather than emit a meaningless
/// `UnsafeMutableRawPointer<…>`.
private let kOpaque = "UnsafeMutableRawPointer"

/// The `System.Guid` identity that decodes to `IID`/`CLSID`.
private let kGuid = Identity(namespace: "System", name: "Guid")

/// Classifies a `System.Guid` parameter as `IID` or `CLSID` by its name: a
/// `clsid`/`classid`-rooted name is a `CLSID`, everything else an `IID`; the
/// default, absent a hint, is `IID`.
private func classification(_ parameter: String?) -> String {
  guard let parameter else { return "IID" }
  let lowercased = parameter.lowercased()
  return lowercased.contains("clsid") || lowercased.contains("classid")
      ? "CLSID"
      : "IID"
}

/// The well-known projection of resolved CLR types to `COM` module symbols.
private let kWellKnown: Dictionary<Identity, String> = [
  Identity(namespace: "Windows.Win32.Foundation", name: "HRESULT"):
      "HRESULT",
  Identity(namespace: "Windows.Win32.Foundation", name: "BOOL"):
      "BOOL",
]

// MARK: - Structural cases

extension SignatureType {
  /// Decodes a `GENERICINST` of `self` specialised `by` arguments to
  /// `Base<Args…>`.
  ///
  /// A CLR generic definition's `TypeName` carries an arity suffix (e.g.
  /// `IReference``1`); it is stripped before composing the Swift generic so the
  /// spelling reads `IReference<…>`, not `IReference``1<…>`. The `parameter`-name
  /// hint flows to the arguments as well, so a `System.Guid` argument of a
  /// parameter named `clsid` spells `CLSID` rather than the default `IID`.
  fileprivate func specialized(by arguments: Array<SignatureType>,
                               parameter: String?,
                               with resolver: Resolver) -> String {
    let base = decode(parameter: parameter, with: resolver)
    // An unresolved base (e.g. a TypeSpec with no identity) decodes to the
    // opaque pointer; a generic over it is meaningless Swift, so degrade to that
    // opaque pointer rather than emit `UnsafeMutableRawPointer<…>`.
    guard base != kOpaque else { return base }
    let name = base.prefix { $0 != "`" }
    let arguments = arguments
        .map { $0.decode(parameter: parameter, with: resolver) }
        .joined(separator: ", ")
    return "\(name)<\(arguments)>"
  }
}

extension VariableScope {
  /// The `T`/`M` placeholder prefix for a `VAR`/`MVAR` generic parameter scope.
  fileprivate var prefix: String {
    switch self {
    case .type:   "T"
    case .method: "M"
    }
  }
}
