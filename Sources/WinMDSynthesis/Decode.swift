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
              opaque: String,
              guid: (iid: String, clsid: String),
              known: Dictionary<Identity, String>,
              escape: @escaping @Sendable (String) -> String) {
    self.primitives = primitives
    self.pointer = pointer
    self.optional = optional
    self.generic = generic
    self.variable = variable
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
  public func generics(_ names: Array<String>) -> String? {
    guard !names.isEmpty else { return nil }
    return generic.open + names.joined(separator: ", ") + generic.close
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
                       with: resolver, dialect: dialect)
    case let .reference(referent):
      referent.spelling(parameter: parameter, generics: generics, const: false,
                        with: resolver, dialect: dialect)
    case let .array(element):
      element.spelling(parameter: parameter, generics: generics, const: false,
                       with: resolver, dialect: dialect)
    case let .matrix(element, _):
      element.spelling(parameter: parameter, generics: generics, const: false,
                       with: resolver, dialect: dialect)
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
  /// Decodes a pointer/reference/array to a pointer over its decoded pointee,
  /// where `self` is the pointee.
  ///
  /// `void*` collapses to the mutable raw pointer (or the const raw pointer when
  /// `const`). A pointer-to-pointer keeps an *optional* inner element so a
  /// caller can pass a null inner slot: a `void**` (including `const void **`)
  /// is a pointer to an optional raw pointer (immutable when the inner `void`
  /// is `const`), and an `int**`/`IFoo**` a pointer to an optional typed pointer.
  /// Otherwise a non-`void` pointee decodes as `Unsafe{Mutable}Pointer<Pointee>`,
  /// mutable unless a `const` modifier marks the pointee.
  fileprivate func spelling(parameter: String?, generics: Array<String>?,
                            const: Bool, with resolver: Resolver,
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
      // nullable, so mark the decoded element optional (as the `void**` cases).
      wrap(decode(parameter: parameter, generics: generics, with: resolver,
                  dialect: dialect) + dialect.optional,
           const: const, dialect: dialect)
    case let .modified(inner, modifiers):
      inner.spelling(parameter: parameter, generics: generics,
                     const: modifiers.constant(with: resolver),
                     with: resolver, dialect: dialect)
    default:
      wrap(decode(parameter: parameter, generics: generics, with: resolver,
                  dialect: dialect),
           const: const, dialect: dialect)
    }
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
  fileprivate func spelling(_ index: Int, generics: Array<String>?,
                            dialect: Dialect) -> String {
    if case .type = self, let generics, index >= 0, index < generics.count {
      return generics[index]
    }
    return "\(prefix(dialect))\(index)"
  }
}
