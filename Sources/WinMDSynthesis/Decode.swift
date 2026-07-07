// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import WinMD

/// The target-specific strings the decode composes a type spelling from.
///
/// The composition ALGORITHM — how a pointer wraps its pointee, how a generic
/// reads `Base<Args…>`, how a `const` void-pointer collapses to a raw pointer —
/// is language-neutral and lives in the decode functions; only the literal
/// spellings those functions emit are target-specific. `Dialect` carries every
/// such string, so the same algorithm retargets to another language by handing
/// it a different `Dialect` (built, in the tool, from the loaded language spec).
///
/// A `nil` primitive spelling falls back to the primitive's neutral name, so an
/// incomplete dialect still decodes without trapping.
public struct Dialect: Sendable {
  /// The primitive leaf spellings, keyed by neutral name (`void`, `i4`,
  /// `string`, …). A missing key falls back to the neutral name itself.
  public let primitives: Dictionary<String, String>

  /// The pointer spellings: the `typed` prefixes (`UnsafeMutablePointer`/
  /// `UnsafePointer`) a non-`void` pointee wraps into, and the `untyped`
  /// spellings (`UnsafeMutableRawPointer`/`UnsafeRawPointer`) a `void` pointer
  /// collapses to — each in a mutable and a `const` form.
  public let pointer: (typed: (mutable: String, constant: String),
                       untyped: (mutable: String, constant: String))

  /// The optional marker (`?`) an inner pointer slot carries.
  public let optional: String

  /// The generic delimiters (`<`/`>`).
  public let generic: (open: String, close: String)

  /// The `VAR`/`MVAR` generic-parameter scope prefixes (`T`/`M`).
  public let variable: (type: String, method: String)

  /// The associated-ABI-type projection an unbound generic slot crosses the ABI
  /// through — the member spelling appended to a `VAR`'s declared name so the
  /// slot reads `Element.ABI` (the `.ABI` suffix), the windows-rs `Type::Abi`
  /// mechanism. It is size-correct for BOTH a value and a reference argument,
  /// unlike a fixed-size raw-pointer erasure, so an unbound type variable
  /// projects through it rather than collapsing to `opaque`.
  public let projection: String

  /// The spelling an unresolvable named type (and a function pointer) degrades
  /// to (`UnsafeMutableRawPointer`).
  public let opaque: String

  /// The `System.Guid` classification names — an `iid`, or a `clsid` for a
  /// `clsid`/`classid`-rooted parameter name.
  public let guid: (iid: String, clsid: String)

  /// The projection of a resolved CLR `Identity` to the target's own spelling
  /// (`Windows.Win32.Foundation.HRESULT` → `HRESULT`, …).
  public let known: Dictionary<Identity, String>

  /// Escapes a spelled identifier that collides with a target keyword — the same
  /// rule the render's `ESCAPE` applies to declaration names, applied here to a
  /// named type's simple name so a `protocol`/`repeat`-named type spells
  /// compilably. A non-keyword identifier returns unchanged.
  public let escape: @Sendable (String) -> String

  public init(primitives: Dictionary<String, String>,
              pointer: (typed: (mutable: String, constant: String),
                        untyped: (mutable: String, constant: String)),
              optional: String,
              generic: (open: String, close: String),
              variable: (type: String, method: String),
              projection: String,
              opaque: String,
              guid: (iid: String, clsid: String),
              known: Dictionary<Identity, String>,
              escape: @escaping @Sendable (String) -> String) {
    self.primitives = primitives
    self.pointer = pointer
    self.optional = optional
    self.generic = generic
    self.variable = variable
    self.projection = projection
    self.opaque = opaque
    self.guid = guid
    self.known = known
    self.escape = escape
  }

  /// The generic-parameter declaration clause for the ordered `names`
  /// (`<Element>`, `<Key, Value>`) — the dialect's generic delimiters wrapped
  /// around the comma-separated names — or `nil` for a non-generic declaration
  /// (an empty list), so a caller omits the clause entirely. Variance is
  /// dropped (the target has no declaration-site variance); names spell plain.
  ///
  /// Each name is escaped through the dialect's keyword rule, so a parameter
  /// whose metadata name is a target keyword (`in`, `class`) declares as
  /// `` `in` `` — matching the escaped spelling a `VAR` use of the same
  /// parameter produces, so declaration and use agree.
  public func generics(_ names: Array<String>) -> String? {
    guard !names.isEmpty else { return nil }
    return generic.open + names.map(escape).joined(separator: ", ")
        + generic.close
  }
}

/// The per-dialect decode functions, emitting a target type spelling as text.
///
/// The views + templates path renders text, so the type mapping is a pure
/// function from a decoded `SignatureType` (and a `Dialect`) to its spelling —
/// ABI-faithful rules serving as the synthesis oracle. A named type resolves
/// through the injected `Resolver` table (the metaschema's component-schema
/// mapping) and the dialect's well-known table to the target module's spelling;
/// `System.Guid` decodes to `IID`/`CLSID` by a parameter-name hint; pointers,
/// references, and arrays decode to the pointer family; the primitives to the
/// dialect's leaf table. This is the decode-function tier: the type structure
/// composes the dialect's strings declaratively.
extension SignatureType {
  /// The type spelling of `self` in `dialect`, resolving named types through
  /// `resolver` and disambiguating a `System.Guid` by the `parameter`-name hint.
  ///
  /// A `VAR` generic variable spells its declared parameter's name when the
  /// owner's ordered `generics` names are supplied (`VAR 0` of `<Element>`
  /// spells `Element`); absent them (the DB-free path) it degrades to the
  /// dialect's positional placeholder (`T0`). The names index by the variable's
  /// operand; an out-of-range operand falls back to the placeholder. An `MVAR`
  /// (method-level) variable always spells its placeholder — only the
  /// type-level names are threaded here.
  public func decode(parameter: String? = nil,
                     generics: Array<String>? = nil, with resolver: Resolver,
                     dialect: Dialect) -> String {
    switch self {
    case let .primitive(primitive):
      primitive.spelling(dialect)
    case let .pointer(pointee):
      pointee.spelling(parameter: parameter, generics: generics, const: false,
                       erase: false, with: resolver, dialect: dialect)
    case let .reference(referent):
      referent.spelling(parameter: parameter, generics: generics, const: false,
                        erase: false, with: resolver, dialect: dialect)
    case let .array(element):
      element.spelling(parameter: parameter, generics: generics, const: false,
                       erase: false, with: resolver, dialect: dialect)
    case let .matrix(element, _):
      element.spelling(parameter: parameter, generics: generics, const: false,
                       erase: false, with: resolver, dialect: dialect)
    case let .named(kind, reference):
      reference.spelling(kind: kind, parameter: parameter, with: resolver,
                         dialect: dialect)
    case let .variable(scope, index):
      scope.spelling(index, generics: generics, dialect: dialect)
    case let .instance(base, arguments):
      base.specialized(by: arguments, parameter: parameter, generics: generics,
                       with: resolver, dialect: dialect)
    case let .modified(inner, _):
      inner.decode(parameter: parameter, generics: generics, with: resolver,
                   dialect: dialect)
    case .function:
      dialect.opaque
    }
  }
}

// MARK: - ABI erasure

/// Whether a type crosses the WinRT ABI as an erased interface pointer or keeps
/// its own representation — the reference-vs-value distinction the vtable ABI
/// draws.
///
/// A WinRT interface, runtime class, delegate, generic instantiation, or
/// `System.Object` (`ELEMENT_TYPE_OBJECT`, i.e. `IInspectable`) is a COM object
/// reference: at the ABI it is an erased interface pointer
/// (`IInspectable`/`IUnknown`, i.e. a raw pointer), never its own declared
/// spelling. Any other primitive, an enum, or a struct is a value: it crosses
/// the ABI as itself. This is the same partition windows-rs draws with its
/// `TypeKind` (`InterfaceType` vs `CopyType`/`CloneType`); see
/// `SignatureType.abi(…)` for the rationale and the parallel.
public enum ABI: Sendable {
  /// A reference type — erased to an interface pointer at the ABI (windows-rs
  /// `InterfaceType`, whose `Type::Abi` is `*mut c_void`).
  case reference
  /// A value type — carried as its own representation at the ABI (windows-rs
  /// `CopyType`/`CloneType`, whose `Type::Abi` is `Self`).
  case value
}

extension SignatureType {
  /// How `self` crosses the WinRT ABI — a reference (an erased interface
  /// pointer) or a value (its own representation).
  ///
  /// The distinction is structural, so no resolver is needed: a `CLASS`-kinded
  /// named type (an interface, runtime class, or delegate — all
  /// `ELEMENT_TYPE_CLASS` in metadata) and the `ELEMENT_TYPE_OBJECT` primitive
  /// (`System.Object`, i.e. WinRT's `IInspectable` — an object reference
  /// despite being a primitive element type) are references; a
  /// `VALUETYPE`-kinded named type (a struct or enum) and every other
  /// primitive are values. A generic instantiation (`GENERICINST`) follows its
  /// base's kind: an instantiation over a `CLASS` base (a generic interface
  /// like `IReference`/`IVector`) is a reference and erases, while one over a
  /// `VALUETYPE` base (a generic struct) is a value and keeps its own decoded
  /// spelling. Two primitives stay values despite
  /// being reference-shaped in the type system: the WinRT `String`
  /// (`ELEMENT_TYPE_STRING`) is an `HSTRING` handle carried by value
  /// (windows-rs `CloneType`), and `System.TypedReference`
  /// (`ELEMENT_TYPE_TYPEDBYREF`) is a value type.
  ///
  /// A modifier is transparent, and so is indirection: a BYREF, pointer, array,
  /// or matrix classifies as its (recursively unwrapped) ELEMENT, so a byref or
  /// array of a class reference is itself a reference (its element erases),
  /// while a pointer or array of a value stays a value.
  ///
  /// A `VAR`/`MVAR` generic type variable is ARGUMENT-DEPENDENT. WinRT erases a
  /// generic parameter's ABI by its concrete argument's kind — `IVector<Int32>`
  /// carries an `Int32` value (4 bytes), `IVector<IFoo>` an interface pointer
  /// (8 bytes) — so a type variable cannot be classified in isolation. When the
  /// binding `arguments` of the enclosing instantiation are supplied and a
  /// type-level `VAR`'s operand indexes them, the variable classifies as its
  /// BOUND argument (a value argument keeps its value ABI, a reference argument
  /// erases). Absent a binding — the generic DEFINITION render, whose wrapper
  /// is itself Swift-generic over the unknown parameter — the variable is a
  /// reference for a fixed classification; `abi(…)` PROJECTS such an unbound
  /// type-level slot through its element's associated ABI type
  /// (`Element.ABI`, size-correct for a value AND a reference argument) rather
  /// than collapsing it to the opaque pointer, and `projects` reports it so the
  /// wrapper forwards through `ABIProjectable` rather than a fixed-size cast. A
  /// method-level `MVAR` is never substituted (only type-level bindings thread
  /// here) and so stays a reference.
  ///
  /// This is the classification half of the ABI-erasure keystone; `abi(…)`
  /// produces the matching erased spelling.
  public func classification(substituting arguments: Array<SignatureType>?
                               = nil) -> ABI {
    switch self {
    case .named(kind: .class, _), .primitive(.object):
      .reference
    case .named(kind: .value, _), .primitive, .function:
      .value
    case let .variable(scope, index):
      // A bound type-level variable classifies as its concrete argument; an
      // unbound one (the definition render) or a method-level `MVAR` erases.
      if case .type = scope, let arguments, arguments.indices.contains(index) {
        arguments[index].classification()
      } else {
        .reference
      }
    case let .instance(base, arguments):
      // A GENERICINST's own kind follows its base, and its arguments become the
      // bindings a variable in the base's slots substitutes against.
      base.classification(substituting: arguments)
    case let .modified(inner, _),
         let .pointer(inner),
         let .reference(inner),
         let .array(inner),
         let .matrix(inner, _):
      inner.classification(substituting: arguments)
    }
  }

  /// The ABI classification of `self` with no binding — the generic-definition
  /// spelling, where a type variable erases as a reference. Argument-dependent
  /// callers use `classification(substituting:)`.
  public var classification: ABI {
    classification()
  }

  /// Whether `self` is an unbound generic slot that crosses the ABI through its
  /// element's ASSOCIATED ABI type (`Element.ABI`) rather than a fixed erasure
  /// — an unbound type-level `VAR` (recursively, under indirection or a
  /// modifier). The generic-definition wrapper projects such a slot through the
  /// `ABIProjectable` conformance (`toABI()`/`fromABI(_:)`), not a fixed-size
  /// `unsafeBitCast`, so it is size-correct for a value AND a reference
  /// instantiation. A concrete reference (a `CLASS` named type) is NOT
  /// projected — its erased pointer is a pointer either way, so its cast is
  /// size-safe — and a value is not projected either. A bound variable (the
  /// specialisation path) resolves to its concrete argument, so it never
  /// projects.
  public var projects: Bool {
    switch self {
    case let .variable(scope, _):
      if case .type = scope { true } else { false }
    case let .modified(inner, _),
         let .pointer(inner),
         let .reference(inner),
         let .array(inner),
         let .matrix(inner, _):
      inner.projects
    case .named, .primitive, .instance, .function:
      false
    }
  }

  /// The ABI-erased spelling of `self` in `dialect` — the type as it actually
  /// crosses the WinRT vtable, resolving named types through `resolver`.
  ///
  /// WinRT's ABI erases every object reference to an interface pointer: an
  /// interface, runtime class, delegate, or generic-interface instantiation is
  /// passed as an `IInspectable`/`IUnknown` — a raw pointer — never as its own
  /// declared type. A value keeps its own representation. This is the erasure
  /// that lets
  /// the projected ABI protocols drop their generic, reference-typed
  /// parameters in favour of a single erased pointer, dissolving the vtable
  /// inheritance problem — the keystone the projection and template steps build
  /// on.
  ///
  /// It mirrors windows-rs `AbiType<T> = <T as Type>::Abi`, whose `TypeKind`
  /// draws the same partition: `InterfaceType` erases to `*mut c_void` (the
  /// `opaque` raw pointer here), while `CopyType`/`CloneType` keep `Self`.
  ///
  /// The mapping:
  /// - a scalar reference (a `CLASS`-kinded named type, a `GENERICINST` over a
  ///   `CLASS` base, or the `ELEMENT_TYPE_OBJECT` primitive —
  ///   `System.Object`/`IInspectable`) spells the dialect's `opaque` raw
  ///   pointer — the erased interface pointer;
  /// - a scalar value spells its own `decode(…)` — including a `GENERICINST`
  ///   over a `VALUETYPE` base, which keeps its decoded generic spelling — with
  ///   one deliberate exception: the WinRT `String` (`ELEMENT_TYPE_STRING`)
  ///   keeps its
  ///   `HSTRING` handle rather than erasing to a plain pointer — a value-like
  ///   handle, not an object reference, matching windows-rs treating `HSTRING`
  ///   as a `CloneType`;
  /// - an indirection wrapper (a BYREF, pointer, array, or matrix) COMPOSES the
  ///   same pointer/array spelling `decode(…)` builds, but over its element's
  ///   erased `abi(…)` rather than its `decode(…)`. So a byref or array of a
  ///   class reference erases its element — `reference(IFoo)` spells a pointer
  ///   over the opaque pointer, not over `IFoo` — while a pointer or array of a
  ///   value is unchanged (`pointer(int)` → `UnsafeMutablePointer<CInt>`), its
  ///   erased element being its own `decode(…)`. A `.modified` type is
  ///   transparent to its inner type, exactly as `classification` treats it.
  /// When the binding `substituting` arguments of the enclosing instantiation
  /// are supplied, a type-level `VAR` slot erases by its BOUND argument: a
  /// value argument keeps its own value ABI (`IVector<Int32>.GetAt -> Int32`
  /// spells `CInt`, no pointer erasure), a reference argument erases to the
  /// opaque pointer. Absent a binding — the generic DEFINITION render — an
  /// unbound type-level `VAR` PROJECTS through its declared name's associated
  /// ABI type (`Element.ABI`, the `projection` suffix), which is `Element`
  /// itself for a value instantiation and the opaque pointer for a reference
  /// one, so the slot is size-correct either way and the wrapper projects
  /// through `ABIProjectable` rather than a fixed-size cast.
  public func abi(parameter: String? = nil, generics: Array<String>? = nil,
                  substituting arguments: Array<SignatureType>? = nil,
                  with resolver: Resolver, dialect: Dialect) -> String {
    switch self {
    case let .pointer(element), let .reference(element),
         let .array(element), let .matrix(element, _):
      element.spelling(parameter: parameter, generics: generics,
                       substituting: arguments, const: false, erase: true,
                       with: resolver, dialect: dialect)
    case let .modified(inner, _):
      inner.abi(parameter: parameter, generics: generics,
                substituting: arguments, with: resolver, dialect: dialect)
    case let .variable(scope, index):
      // A bound type-level variable erases as its concrete argument (a value
      // keeps its own ABI, a reference erases). An UNBOUND type-level variable
      // — the generic DEFINITION render — projects through its declared name's
      // associated ABI type (`Element.ABI`, the windows-rs `Type::Abi`
      // mechanism): size-correct for a value AND a reference instantiation,
      // unlike a fixed-size raw-pointer erasure. A method-level `MVAR` (never
      // substituted here) and an out-of-range operand have no declared name to
      // project, so they still collapse to the opaque pointer.
      if case .type = scope, let arguments, arguments.indices.contains(index) {
        arguments[index].abi(parameter: parameter, with: resolver,
                             dialect: dialect)
      } else if case .type = scope, let generics,
                generics.indices.contains(index) {
        scope.spelling(index, generics: generics, dialect: dialect)
            + dialect.projection
      } else {
        dialect.opaque
      }
    case .primitive, .named, .instance, .function:
      switch classification(substituting: arguments) {
      case .reference:
        dialect.opaque
      case .value:
        decode(parameter: parameter, generics: generics, with: resolver,
               dialect: dialect)
      }
    }
  }
}

// MARK: - Primitives

extension PrimitiveType {
  /// The neutral dialect key of a built-in element type — the key the dialect's
  /// primitive table maps to a spelling.
  ///
  /// `ELEMENT_TYPE_STRING` is the WinRT `String` — an `HSTRING` handle, not a
  /// `PCWSTR` buffer (which arrives as pointer/named metadata, never
  /// `ELEMENT_TYPE_STRING`, so it decodes through those paths instead).
  fileprivate var key: String {
    switch self {
    case .void:     "void"
    case .boolean:  "bool"
    case .char:     "char"
    case .int1:     "i1"
    case .uint1:    "u1"
    case .int2:     "i2"
    case .uint2:    "u2"
    case .int4:     "i4"
    case .uint4:    "u4"
    case .int8:     "i8"
    case .uint8:    "u8"
    case .float:    "f4"
    case .double:   "f8"
    case .intptr:   "iptr"
    case .uintptr:  "uptr"
    case .string:   "string"
    case .object:   "object"
    case .typedref: "typedref"
    }
  }

  /// The `dialect` spelling of a built-in element type — its primitive-table
  /// entry, or (absent one) the neutral key as a fallback.
  fileprivate func spelling(_ dialect: Dialect) -> String {
    dialect.primitives[key] ?? key
  }
}

// MARK: - Indirection

extension SignatureType {
  /// Decodes a pointer/reference/array to a pointer over its pointee, where
  /// `self` is the pointee.
  ///
  /// `void*` collapses to the mutable raw pointer (or the const raw pointer when
  /// `const`). A pointer-to-pointer keeps an *optional* inner element so a
  /// caller can pass a null inner slot: a `void**` (including `const void **`)
  /// is a pointer to an optional raw pointer (immutable when the inner `void`
  /// is `const`), and an `int**`/`IFoo**` a pointer to an optional typed pointer.
  /// Otherwise a non-`void` pointee decodes as `Unsafe{Mutable}Pointer<Pointee>`,
  /// mutable unless a `const` modifier marks the pointee.
  ///
  /// When `erase` is set the pointee spelling is its ABI-erased `abi(…)` rather
  /// than its `decode(…)`, so the SAME pointer/array composition wraps the
  /// erased element — a byref/array of a class reference wraps the opaque
  /// pointer, not the named type. The `void` collapses are already raw ABI
  /// forms, so `erase` leaves them untouched; only the wrapped leaf differs.
  fileprivate func spelling(parameter: String?, generics: Array<String>?,
                            substituting arguments: Array<SignatureType>? = nil,
                            const: Bool, erase: Bool, with resolver: Resolver,
                            dialect: Dialect) -> String {
    switch self {
    case .primitive(.void):
      const ? dialect.pointer.untyped.constant : dialect.pointer.untyped.mutable
    case .pointer(.primitive(.void)):
      wrap(dialect.pointer.untyped.mutable + dialect.optional, const: const,
           dialect: dialect)
    case let .pointer(.modified(.primitive(.void), modifiers)):
      wrap((modifiers.constant(with: resolver)
              ? dialect.pointer.untyped.constant
              : dialect.pointer.untyped.mutable) + dialect.optional,
           const: const, dialect: dialect)
    case .pointer:
      // A non-`void` pointer-to-pointer: the inner pointer slot is itself
      // nullable, so mark the leaf element optional (as the `void**` cases).
      wrap(leaf(parameter: parameter, generics: generics,
                substituting: arguments, erase: erase, with: resolver,
                dialect: dialect) + dialect.optional,
           const: const, dialect: dialect)
    case let .modified(inner, modifiers):
      inner.spelling(parameter: parameter, generics: generics,
                     substituting: arguments,
                     const: modifiers.constant(with: resolver), erase: erase,
                     with: resolver, dialect: dialect)
    default:
      wrap(leaf(parameter: parameter, generics: generics,
                substituting: arguments, erase: erase, with: resolver,
                dialect: dialect),
           const: const, dialect: dialect)
    }
  }

  /// The leaf pointee spelling a wrapper wraps: the element's ABI-erased
  /// `abi(…)` when `erase` is set, otherwise its plain `decode(…)`. A wrapped
  /// class reference thus erases to the opaque pointer under `erase`, while a
  /// value is spelled identically either way (its `abi(…)` is its `decode(…)`).
  /// Under `erase` the binding `arguments` thread on so a wrapped type variable
  /// erases by its bound argument (a byref of a value-bound `VAR` wraps the
  /// value ABI, not the opaque pointer).
  private func leaf(parameter: String?, generics: Array<String>?,
                    substituting arguments: Array<SignatureType>?, erase: Bool,
                    with resolver: Resolver, dialect: Dialect) -> String {
    erase ? abi(parameter: parameter, generics: generics,
                substituting: arguments, with: resolver, dialect: dialect)
          : decode(parameter: parameter, generics: generics, with: resolver,
                   dialect: dialect)
  }
}

/// Wraps an already-decoded `pointee` spelling in the dialect's typed-pointer
/// family (`Unsafe{Mutable}Pointer<…>`).
private func wrap(_ pointee: String, const: Bool, dialect: Dialect) -> String {
  let prefix = const ? dialect.pointer.typed.constant
                     : dialect.pointer.typed.mutable
  return "\(prefix)\(dialect.generic.open)\(pointee)\(dialect.generic.close)"
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
/// carries — the sole custom modifier the decode treats as `const`. This is an
/// ABI marker, not a target spelling, so it stays fixed across dialects.
private let kIsConst =
    Identity(namespace: "System.Runtime.CompilerServices", name: "IsConst")

// MARK: - Named types

extension TypeDefOrRef {
  /// The `dialect` spelling of the named type `self` references, resolved
  /// through `resolver` and the dialect's well-known table.
  ///
  /// A resolved `System.Guid` renders as `IID`/`CLSID` by the parameter-name
  /// hint; otherwise the `Identity` is looked up in the well-known table
  /// (`HRESULT`, `BOOL`, …), a miss rendering the type's own simple name. An
  /// unresolvable reference renders the dialect's opaque pointer.
  fileprivate func spelling(kind: NamedKind, parameter: String?,
                            with resolver: Resolver,
                            dialect: Dialect) -> String {
    guard let identity = resolver.resolve(self, kind: kind) else {
      return dialect.opaque
    }
    if identity == kGuid {
      return classification(parameter, dialect: dialect)
    }
    // A named type's simple name is a bare identifier that may collide with a
    // target keyword (`protocol`, `repeat`); escape it as the render escapes a
    // declaration name. A well-known spelling is curated and never a keyword.
    return dialect.known[identity] ?? dialect.escape(identity.name)
  }
}

/// The `System.Guid` identity that decodes to `IID`/`CLSID`.
private let kGuid = Identity(namespace: "System", name: "Guid")

/// Classifies a `System.Guid` parameter as the dialect's `CLSID`/`IID` by its
/// name: a `clsid`/`classid`-rooted name is a `CLSID`, everything else an `IID`;
/// the default, absent a hint, is `IID`.
private func classification(_ parameter: String?, dialect: Dialect) -> String {
  guard let parameter else { return dialect.guid.iid }
  let lowercased = parameter.lowercased()
  return lowercased.contains("clsid") || lowercased.contains("classid")
      ? dialect.guid.clsid
      : dialect.guid.iid
}

// MARK: - Structural cases

extension SignatureType {
  /// Decodes a `GENERICINST` of `self` specialised `by` arguments to
  /// `Base<Args…>`.
  ///
  /// A CLR generic definition's `TypeName` carries an arity suffix (e.g.
  /// `IReference``1`); it is stripped before composing the generic so the
  /// spelling reads `IReference<…>`, not `IReference``1<…>`. The `parameter`-name
  /// hint flows to the arguments as well, so a `System.Guid` argument of a
  /// parameter named `clsid` spells `CLSID` rather than the default `IID`.
  fileprivate func specialized(by arguments: Array<SignatureType>,
                               parameter: String?, generics: Array<String>?,
                               with resolver: Resolver,
                               dialect: Dialect) -> String {
    let base = decode(parameter: parameter, with: resolver, dialect: dialect)
    // An unresolved base (e.g. a TypeSpec with no identity) decodes to the
    // opaque pointer; a generic over it is meaningless, so degrade to that
    // opaque pointer rather than emit `UnsafeMutableRawPointer<…>`.
    guard base != dialect.opaque else { return base }
    // Strip the CLR arity suffix, THEN escape the base identifier: the full
    // `Foo``1` never matches a keyword, so a keyword base (`protocol``1`) must
    // be escaped after the strip, not before, to spell `` `protocol`<…> ``.
    let name = dialect.escape(String(base.prefix { $0 != "`" }))
    let arguments = arguments
        .map { $0.decode(parameter: parameter, generics: generics,
                         with: resolver, dialect: dialect) }
        .joined(separator: ", ")
    return "\(name)\(dialect.generic.open)\(arguments)\(dialect.generic.close)"
  }
}

extension VariableScope {
  /// The `T`/`M` placeholder prefix for a `VAR`/`MVAR` generic parameter scope,
  /// as `dialect` spells it.
  fileprivate func prefix(_ dialect: Dialect) -> String {
    switch self {
    case .type:   dialect.variable.type
    case .method: dialect.variable.method
    }
  }

  /// The spelling of the generic variable at `index` in this scope: the
  /// declared parameter's name when this is a type-level `VAR`, the owner's
  /// ordered `generics` names are supplied, and the operand is in range (`VAR
  /// 0` of `<Element>` → `Element`); otherwise the positional placeholder
  /// (`\(prefix)\(index)`). A method-level `MVAR` always spells its
  /// placeholder — only type-level names are threaded — as does an out-of-range
  /// operand. The lower bound guards a negative operand: the metadata decoder
  /// emits none, but the enum case is public, so a malformed programmatic
  /// `VAR -1` degrades to the placeholder rather than trap on `generics[-1]`.
  ///
  /// The declared name is escaped through the dialect's keyword rule, so a
  /// parameter whose metadata name is a target keyword (`in`, `class`) spells
  /// its use as `` `in` `` — a raw keyword would be an invalid type reference
  /// (`UnsafeMutablePointer<in>`) — matching the escaped spelling
  /// `Dialect.generics(_:)` gives the same parameter's declaration.
  fileprivate func spelling(_ index: Int, generics: Array<String>?,
                            dialect: Dialect) -> String {
    if case .type = self, let generics, index >= 0, index < generics.count {
      return dialect.escape(generics[index])
    }
    return "\(prefix(dialect))\(index)"
  }
}
