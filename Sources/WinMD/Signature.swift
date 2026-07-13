// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The calling convention a `MethodSignature` opens with (ECMA-335 §II.23.2.1).
///
/// The first byte of a method signature is a bitmask: the low nibble selects the
/// convention, the high bits carry the `HASTHIS`/`EXPLICITTHIS`/`GENERIC` flags.
/// The flags are surfaced separately on `MethodSignature`; this names the
/// convention the low nibble selects.
public enum CallingConvention: Sendable {
  /// A managed method with a fixed parameter list (`DEFAULT`).
  case `default`
  /// A managed vararg method (`VARARG`).
  case vararg
  /// An unmanaged C call (`C`).
  case c
  /// An unmanaged stdcall (`STDCALL`).
  case stdcall
  /// An unmanaged thiscall (`THISCALL`).
  case thiscall
  /// An unmanaged fastcall (`FASTCALL`).
  case fastcall
}

/// The kind of named type a `SignatureType.named` holds (ECMA-335 §II.23.2.12).
///
/// `CLASS` names a reference type, `VALUETYPE` a value type; both carry a
/// `TypeDefOrRefOrSpec` coded index naming the type.
public enum NamedKind: Sendable {
  case `class`
  case value
}

/// The scope a generic `SignatureType.variable` is bound in (ECMA-335
/// §II.23.2.12).
///
/// `VAR` references the enclosing type's generic parameters, `MVAR` the
/// enclosing method's.
public enum VariableScope: Sendable {
  case type
  case method
}

/// A custom modifier on a type (ECMA-335 §II.23.2.7).
///
/// `CMOD_REQD`/`CMOD_OPT` decorate a type with a `TypeDefOrRefOrSpec` naming the
/// modifier type; `required` distinguishes the two.
public struct Modifier: Sendable {
  /// Whether the modifier is required (`CMOD_REQD`) rather than optional
  /// (`CMOD_OPT`).
  public let required: Bool

  /// The type the modifier names.
  public let type: TypeDefOrRef

  public init(required: Bool, type: TypeDefOrRef) {
    self.required = required
    self.type = type
  }
}

/// The shape of a general (multi-dimensional) array (ECMA-335 §II.23.2.13).
///
/// `SZARRAY` is the common single-dimension, zero-bound case and is modelled by
/// `SignatureType.array`; the general `ARRAY` form additionally carries a rank
/// and an explicit, possibly partial, list of sizes and lower bounds.
public struct ArrayShape: Sendable {
  /// The number of dimensions.
  public let rank: Int

  /// The sizes of the leading dimensions; dimensions beyond this are unsized.
  public let sizes: Array<Int>

  /// The lower bounds of the leading dimensions; dimensions beyond this are
  /// zero-bound.
  public let bounds: Array<Int>

  public init(rank: Int, sizes: Array<Int>, bounds: Array<Int>) {
    self.rank = rank
    self.sizes = sizes
    self.bounds = bounds
  }
}

/// A decoded `#Blob` type signature (ECMA-335 §II.23.2.12).
///
/// This is a structured value tree, not resolved navigation: a `named` type
/// holds the `TypeDefOrRef` coded-index *value* the signature carried, exactly
/// as the SQL AST holds a structured `Predicate` rather than rows. Resolving a
/// named type to a `TypeDef`/`TypeRef` row is separate navigation the consumer
/// performs against a database.
public indirect enum SignatureType: Sendable {
  /// A built-in type (`VOID`, `BOOLEAN`, `I4`, `STRING`, `OBJECT`, …).
  case primitive(PrimitiveType)
  /// An unmanaged pointer to a type (`PTR`).
  case pointer(SignatureType)
  /// A managed reference to a type (`BYREF`).
  case reference(SignatureType)
  /// A single-dimension, zero-bound array of a type (`SZARRAY`).
  case array(SignatureType)
  /// A general, multi-dimensional array of a type (`ARRAY`).
  case matrix(SignatureType, ArrayShape)
  /// A named class or value type (`CLASS`/`VALUETYPE`).
  case named(kind: NamedKind, TypeDefOrRef)
  /// A generic type or method parameter (`VAR`/`MVAR`).
  case variable(scope: VariableScope, Int)
  /// A generic type instantiation (`GENERICINST`).
  case instance(SignatureType, Array<SignatureType>)
  /// A type decorated with one or more custom modifiers (`CMOD_REQD`/
  /// `CMOD_OPT`).
  case modified(SignatureType, modifiers: Array<Modifier>)
  /// A function pointer carrying a nested method signature (`FNPTR`).
  case function(MethodSignature)
}

/// A built-in element type (ECMA-335 §II.23.1.16).
///
/// These are the `ELEMENT_TYPE_*` leaves that carry no further operands: the
/// numeric and character primitives, plus `VOID`, `STRING`, `OBJECT`, the native
/// integers, and the typed reference.
public enum PrimitiveType: Sendable {
  case void
  case boolean
  case char
  case int1
  case uint1
  case int2
  case uint2
  case int4
  case uint4
  case int8
  case uint8
  case float
  case double
  /// A native signed integer (`I`).
  case intptr
  /// A native unsigned integer (`U`).
  case uintptr
  case string
  case object
  /// A typed reference (`TYPEDBYREF`).
  case typedref
}

/// A decoded method signature (ECMA-335 §II.23.2.1).
public struct MethodSignature: Sendable {
  /// The calling convention the leading byte selects.
  public let convention: CallingConvention

  /// Whether the method has an implicit `this` parameter (`HASTHIS`).
  public let `instance`: Bool

  /// Whether `this` is passed explicitly as the first parameter
  /// (`EXPLICITTHIS`).
  public let explicit: Bool

  /// The count of generic parameters (`GENERIC`); zero for a non-generic method.
  public let generics: Int

  /// The return type.
  public let returns: SignatureType

  /// The parameter types, in order.
  public let parameters: Array<SignatureType>

  public init(convention: CallingConvention, instance: Bool, explicit: Bool,
              generics: Int, returns: SignatureType,
              parameters: Array<SignatureType>) {
    self.convention = convention
    self.instance = instance
    self.explicit = explicit
    self.generics = generics
    self.returns = returns
    self.parameters = parameters
  }
}

/// A decoded field signature (ECMA-335 §II.23.2.4).
public struct FieldSignature: Sendable {
  /// The field's type.
  public let type: SignatureType

  public init(type: SignatureType) {
    self.type = type
  }
}

/// A decoded property signature (ECMA-335 §II.23.2.5).
public struct PropertySignature: Sendable {
  /// Whether the property has an implicit `this` parameter (`HASTHIS`).
  public let `instance`: Bool

  /// The property's type.
  public let type: SignatureType

  /// The index parameter types, in order; empty for a non-indexer property.
  public let parameters: Array<SignatureType>

  public init(instance: Bool, type: SignatureType,
              parameters: Array<SignatureType>) {
    self.instance = `instance`
    self.type = type
    self.parameters = parameters
  }
}

// MARK: - Decoding

/// A cursor decoding a `#Blob` signature byte stream (ECMA-335 §II.23.2).
///
/// The cursor borrows the blob's bytes and advances a position through them,
/// reading compressed integers with the shared `RawSpan.compressed` and recursing
/// over the `Type` grammar. It is `~Escapable` because it holds a `RawSpan`.
internal struct SignatureDecoder: ~Escapable {
  private let bytes: RawSpan
  private var position: Int

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan) {
    self.bytes = bytes
    self.position = 0
  }

  /// Reads the next raw byte and advances past it.
  private mutating func byte() throws(WinMDError) -> UInt8 {
    guard position < bytes.byteCount else { throw .BadImageFormat }
    let value = bytes.read(at: position, as: UInt8.self)
    position = position + 1
    return value
  }

  /// Throws unless every byte of the blob has been consumed. A top-level
  /// signature must fill its `#Blob` entry exactly; trailing bytes after an
  /// otherwise-valid prefix are malformed metadata, not a shorter signature.
  internal borrowing func end() throws(WinMDError) {
    guard position == bytes.byteCount else { throw .BadImageFormat }
  }

  /// Validates the compressed-integer encoding at `position` and returns its
  /// length in bytes (ECMA-335 §II.23.2).
  ///
  /// The lead byte selects the encoding: `0x00..0x7f` is 1 byte, `0x80..0xbf`
  /// 2 bytes, and `0xc0..0xdf` 4 bytes; `0xe0` and above is not a defined
  /// encoding. A well-formed encoding must also fit within the blob. This guards
  /// the shared `RawSpan.compressed`, which would otherwise `fatalError` or read
  /// past the end on malformed input.
  private func width() throws(WinMDError) -> Int {
    guard position < bytes.byteCount else { throw .BadImageFormat }
    let lead = bytes.read(at: position, as: UInt8.self)
    let length = switch lead {
    case 0x00 ... 0x7f: 1
    case 0x80 ... 0xbf: 2
    case 0xc0 ... 0xdf: 4
    default:            throw .BadImageFormat
    }
    guard position + length <= bytes.byteCount else { throw .BadImageFormat }
    return length
  }

  /// Reads the next compressed unsigned integer and advances past it.
  private mutating func compressed() throws(WinMDError) -> Int {
    _ = try width()
    let (begin, value) = bytes.compressed(at: position)
    position = begin
    return value
  }

  /// Reads the next compressed *signed* integer and advances past it.
  ///
  /// The value is stored as its compressed-unsigned encoding rotated left by one
  /// bit with the sign in the least-significant bit (ECMA-335 §II.23.2): the
  /// magnitude is `value >> 1`, and a set low bit selects the negative value
  /// `magnitude - 2^(databits - 1)`, where `databits` is 7, 14, or 29 for the
  /// 1-, 2-, or 4-byte encoding.
  private mutating func compressedSigned() throws(WinMDError) -> Int {
    let length = try width()
    let (begin, value) = bytes.compressed(at: position)
    position = begin
    let databits = switch length {
    case 1:  7
    case 2:  14
    default: 29
    }
    let magnitude = value >> 1
    return value & 1 == 1 ? magnitude - (1 << (databits - 1)) : magnitude
  }

  /// Reads a `TypeDefOrRefOrSpec` coded index and advances past it.
  ///
  /// In a signature the coded index is a compressed unsigned integer whose low
  /// two bits are the tag selecting `TypeDef`/`TypeRef`/`TypeSpec` and whose
  /// remaining bits are the 1-based row (ECMA-335 §II.23.2.8) — the same bit
  /// layout `TypeDefOrRef` decodes, so the decoded value is its `rawValue`.
  private mutating func reference() throws(WinMDError) -> TypeDefOrRef {
    try TypeDefOrRef(rawValue: compressed())
  }

  /// Reads any leading `CMOD_REQD`/`CMOD_OPT` run, in order.
  private mutating func modifiers() throws(WinMDError) -> Array<Modifier> {
    var modifiers = Array<Modifier>()
    while true {
      guard position < bytes.byteCount else { break }
      let element = CorElementType(rawValue: bytes.read(at: position, as: UInt8.self))
      guard element == .etCModReqd || element == .etCModOpt else { break }
      position = position + 1
      try modifiers.append(Modifier(required: element == .etCModReqd,
                                    type: reference()))
    }
    return modifiers
  }

  /// Decodes one `Type` (ECMA-335 §II.23.2.12), including any leading custom
  /// modifiers. `VOID` is accepted only when `erasable` — a return type, or a
  /// pointer's pointee (`PTR CustomMod* VOID`); in any other position it is
  /// malformed metadata.
  internal mutating func type(erasable: Bool = false) throws(WinMDError)
      -> SignatureType {
    let modifiers = try modifiers()
    let bare = try unmodified(erasable: erasable)
    return modifiers.isEmpty ? bare : .modified(bare, modifiers: modifiers)
  }

  /// Decodes one `Type` without consuming leading custom modifiers.
  private mutating func unmodified(erasable: Bool) throws(WinMDError)
      -> SignatureType {
    let element = CorElementType(rawValue: try byte())
    return switch element {
    case .etVoid:
      if erasable { .primitive(.void) } else { throw .BadImageFormat }
    case .etBoolean:     .primitive(.boolean)
    case .etChar:        .primitive(.char)
    case .etInt1:        .primitive(.int1)
    case .etUInt1:       .primitive(.uint1)
    case .etInt2:        .primitive(.int2)
    case .etUInt2:       .primitive(.uint2)
    case .etInt4:        .primitive(.int4)
    case .etUInt4:       .primitive(.uint4)
    case .etInt8:        .primitive(.int8)
    case .etUInt8:       .primitive(.uint8)
    case .etFloat:       .primitive(.float)
    case .etDouble:      .primitive(.double)
    case .etInt:         .primitive(.intptr)
    case .etUInt:        .primitive(.uintptr)
    case .etString:      .primitive(.string)
    case .etObject:      .primitive(.object)
    case .etTypedByRef:  .primitive(.typedref)
    case .etPtr:         try .pointer(type(erasable: true))
    case .etByRef:       try .reference(type())
    case .etSzArray:     try .array(type())
    case .etClass:       try .named(kind: .class, reference())
    case .etValueType:   try .named(kind: .value, reference())
    case .etVar:         try .variable(scope: .type, compressed())
    case .etMVar:        try .variable(scope: .method, compressed())
    case .etArray:       try matrix()
    case .etGenericInst: try instance()
    case .etFnPtr:       try .function(method())
    default:             throw .BadImageFormat
    }
  }

  /// Decodes the operands of a general `ARRAY` (ECMA-335 §II.23.2.13).
  ///
  /// The element type is followed by the rank, then a count and that many
  /// sizes, then a count and that many lower bounds; the sizes are compressed
  /// unsigned and the lower bounds compressed signed.
  private mutating func matrix() throws(WinMDError) -> SignatureType {
    let element = try type()
    let rank = try compressed()
    guard rank >= 1 else { throw .BadImageFormat }

    var sizes = Array<Int>()
    var count = try compressed()
    guard count <= rank else { throw .BadImageFormat }
    for _ in 0 ..< count {
      try sizes.append(compressed())
    }

    var bounds = Array<Int>()
    count = try compressed()
    guard count <= rank else { throw .BadImageFormat }
    for _ in 0 ..< count {
      try bounds.append(compressedSigned())
    }

    return .matrix(element,
                   ArrayShape(rank: rank, sizes: sizes, bounds: bounds))
  }

  /// Decodes the operands of `GENERICINST` (ECMA-335 §II.23.2.12).
  ///
  /// A `CLASS`/`VALUETYPE` named type follows, then a generic-argument count and
  /// that many type arguments.
  private mutating func instance() throws(WinMDError) -> SignatureType {
    let element = CorElementType(rawValue: try byte())
    let kind: NamedKind = switch element {
    case .etClass:     .class
    case .etValueType: .value
    default:           throw .BadImageFormat
    }
    let base: SignatureType = try .named(kind: kind, reference())

    var arguments = Array<SignatureType>()
    for _ in try 0 ..< compressed() {
      try arguments.append(type())
    }
    return .instance(base, arguments)
  }

  /// Decodes a method signature (ECMA-335 §II.23.2.1), the body of a method-def,
  /// member-ref, or `FNPTR`.
  internal mutating func method() throws(WinMDError) -> MethodSignature {
    let prolog = try byte()
    guard prolog & 0x80 == 0 else { throw .BadImageFormat }

    let `instance` = prolog & 0x20 != 0    // HASTHIS
    let explicit = prolog & 0x40 != 0      // EXPLICITTHIS
    let generic = prolog & 0x10 != 0       // GENERIC
    guard `instance` || !explicit else { throw .BadImageFormat }

    let convention: CallingConvention = switch prolog & 0x0f {
    case 0x00: .default
    case 0x01: .c
    case 0x02: .stdcall
    case 0x03: .thiscall
    case 0x04: .fastcall
    case 0x05: .vararg
    default: throw .BadImageFormat
    }

    let generics = generic ? try compressed() : 0
    let count = try compressed()
    let returns = try type(erasable: true)

    var parameters = Array<SignatureType>()
    for _ in 0 ..< count {
      try parameters.append(type())
    }

    return MethodSignature(convention: convention, instance: `instance`,
                           explicit: explicit, generics: generics,
                           returns: returns, parameters: parameters)
  }

  /// Decodes a field signature (ECMA-335 §II.23.2.4): a `FIELD` prolog byte
  /// followed by a single `Type`.
  internal mutating func field() throws(WinMDError) -> FieldSignature {
    let prolog = try byte()
    guard prolog == 0x06 else { throw .BadImageFormat }
    return FieldSignature(type: try type())
  }

  /// Decodes a property signature (ECMA-335 §II.23.2.5): a `PROPERTY` prolog
  /// byte (`0x08`, optionally OR'd with `HASTHIS` `0x20`), a parameter count,
  /// the property's `Type`, then that many index-parameter `Type`s.
  ///
  /// The count precedes the property type and names the index parameters an
  /// indexer property carries; a plain property has a count of zero and no
  /// index parameters.
  internal mutating func property() throws(WinMDError) -> PropertySignature {
    let prolog = try byte()
    guard prolog & ~0x20 == 0x08 else { throw .BadImageFormat }
    let `instance` = prolog & 0x20 != 0    // HASTHIS

    let count = try compressed()
    let type = try type()

    var parameters = Array<SignatureType>()
    for _ in 0 ..< count {
      try parameters.append(self.type())
    }

    return PropertySignature(instance: `instance`, type: type,
                             parameters: parameters)
  }
}

// MARK: - Blob decoding

/// The `MethodSignature` a raw method-signature `#Blob` payload decodes to
/// (ECMA-335 §II.23.2.1).
///
/// This is the escapable, bytes → value form of `Row<MethodDef>.prototype`: a
/// caller that has already copied a `MethodDef.Signature` `#Blob` out of the
/// borrowed scan (the SQL adapter's `.blob` cell, whose payload is the
/// length-prefix-stripped signature) decodes it here, without a `Row`. It
/// mirrors `iid(decoding:)`, the analogous decode over a copied
/// `CustomAttribute.Value` blob. `bytes` must be the WHOLE signature — the
/// decode consumes every byte (`end()`) — and, as `prototype` requires, name a
/// `DEFAULT`/`VARARG` convention; anything else is malformed metadata and
/// throws.
public func decode(method bytes: Array<UInt8>) throws(WinMDError)
    -> MethodSignature {
  var decoder = SignatureDecoder(bytes.span.bytes)
  let signature = try decoder.method()
  guard signature.convention == .default ||
      signature.convention == .vararg else { throw .BadImageFormat }
  try decoder.end()
  return signature
}

// MARK: - Accessors

extension Row where Schema == Metadata.Tables.MethodDef {
  /// The decoded method signature (ECMA-335 §II.23.2.1).
  ///
  /// Distinct from the `Signature` accessor, which vends the raw `#Blob`; this
  /// decodes that blob into a structured `MethodSignature`.
  public var prototype: MethodSignature {
    get throws(WinMDError) {
      let entry = try blob(.Signature)
      var decoder = SignatureDecoder(entry.bytes)
      let signature = try decoder.method()
      guard signature.convention == .default ||
          signature.convention == .vararg else { throw .BadImageFormat }
      try decoder.end()
      return signature
    }
  }
}

extension Row where Schema == Metadata.Tables.FieldDef {
  /// The decoded field signature (ECMA-335 §II.23.2.4).
  ///
  /// Distinct from the `Signature` accessor, which vends the raw `#Blob`; this
  /// decodes that blob into a structured `FieldSignature`.
  public var declaration: FieldSignature {
    get throws(WinMDError) {
      let entry = try blob(.Signature)
      var decoder = SignatureDecoder(entry.bytes)
      let signature = try decoder.field()
      try decoder.end()
      return signature
    }
  }
}

extension Row where Schema == Metadata.Tables.PropertyDef {
  /// The decoded property signature (ECMA-335 §II.23.2.5).
  ///
  /// Distinct from the `Type` accessor, which vends the raw `#Blob`; this
  /// decodes that blob into a structured `PropertySignature`.
  public var declaration: PropertySignature {
    get throws(WinMDError) {
      let entry = try blob(.Type)
      var decoder = SignatureDecoder(entry.bytes)
      let signature = try decoder.property()
      try decoder.end()
      return signature
    }
  }
}
