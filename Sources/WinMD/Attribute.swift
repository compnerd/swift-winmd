// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.UUID
import typealias Foundation.uuid_t

// MARK: - Value model

/// A decoded custom-attribute argument value (ECMA-335 §II.23.3).
///
/// A `CustomAttrib` blob carries the constructor's fixed arguments and any
/// named field/property arguments as serialised leaves. This is the decoded
/// leaf: the scalar element types the grammar spells (`bool`, `char`, the
/// integers, `r4`/`r8`, a `SerString`), a `System.Type` name kept distinct from
/// a plain string, and an enumeration carrying its type name and underlying
/// integer.
///
/// The per-width integer cases windows-rs keeps (`I1`, `U2`, …) collapse to a
/// single `integer(Int64)` because this only reads metadata; a `u8` that must
/// stay unsigned takes the distinct `unsigned` case so the model is lossless.
/// `enumeration` carries its underlying integer as a nested `AttributeValue` so
/// it inherits that same signedness — a `u8`-backed enum stays `unsigned`, a
/// signed enum stays `integer` — rather than folding through a lossy `Int64`.
/// `array` reserves the `SZARRAY` shape whose producer is deferred; `null` is a
/// null `SerString` or null array.
public indirect enum AttributeValue: Sendable, Hashable {
  case boolean(Bool)
  case integer(Int64)
  case unsigned(UInt64)
  case real(Double)
  case string(String)
  case type(String)
  case enumeration(name: String, value: AttributeValue)
  case array(Array<AttributeValue>)
  case null
}

/// Which member a `NamedArg` assigns (ECMA-335 §II.23.3): the `FIELD`
/// (`0x53`) or `PROPERTY` (`0x54`) byte that leads a `NamedArg`. It is the
/// only disambiguator when an attribute class declares both a field and a
/// property of the same name, so `named()` carries it beside the name and
/// value.
internal enum Member: Sendable, Hashable {
  case field
  case property
}

/// How a `CustomAttrib` blob names the enum type whose underlying integer a
/// value carries (ECMA-335 §II.23.3).
///
/// A `FixedArg`'s enum comes from the constructor signature as a `TypeDefOrRef`
/// coded index (`reference`); a `NamedArg`'s enum is spelled inline as a
/// `SerString` type name after the `0x55` `ENUM` tag (`named`). Neither form
/// encodes the underlying `CorElementType` — a decoder must resolve it from
/// metadata — so this is the key an `underlying` resolver is handed.
internal enum EnumType: Sendable {
  case reference(TypeDefOrRef)
  case named(String)
}

// MARK: - Decoding

/// A cursor decoding a custom-attribute `Value` blob (ECMA-335 §II.23.3).
///
/// A custom-attribute value opens with a `0x0001` prolog, then the
/// constructor's fixed arguments serialised in declaration order, then a
/// `NumNamed` count and that many named field/property arguments. This cursor
/// mirrors `SignatureDecoder`'s shape — it borrows the blob's bytes, advances a
/// position, and is `~Escapable` because it holds a `RawSpan` — and vends the
/// §II.23.3 grammar's leaves:
///
/// - `string()` reads a `PackedLen`-prefixed UTF-8 string, with the `0xFF`
///   null and `0x00` empty markers.
/// - `fixed(_:)` decodes one `FixedArg` *given* its type from the constructor
///   signature — a `FixedArg` carries no leading type tag.
/// - `named()` reads a self-describing `NamedArg`: the `FIELD`/`PROPERTY` byte,
///   the field-or-property type, the name, then the value.
///
/// The `guid()` fast path stays: a `GuidAttribute`'s fixed-arg shape
/// (`u32, u16, u16, u8×8`) is a compile-time constant needing no signature.
internal struct AttributeDecoder: ~Escapable {
  private let bytes: RawSpan
  private var position: Int

  /// Resolves an enum type to the `CorElementType` of its underlying integer.
  ///
  /// A `CustomAttrib` blob names an enum but never its underlying element type
  /// (ECMA-335 §II.23.3), so a value carried as an enum must be read at the
  /// width and signedness of that underlying integer — resolved from metadata,
  /// not assumed to be `I4`. This closure performs that lookup; `nil` means the
  /// enum type could not be resolved, which the caller treats as malformed.
  private let underlying: (EnumType) -> CorElementType?

  @_lifetime(copy bytes)
  internal init(_ bytes: RawSpan,
                underlying: @escaping (EnumType) -> CorElementType? =
                    { _ in nil }) {
    self.bytes = bytes
    self.position = 0
    self.underlying = underlying
  }

  /// Reads a little-endian fixed-width value and advances past it.
  private mutating func read<T: BitwiseCopyable>(as _: T.Type = T.self)
      throws(WinMDError) -> T {
    let width = MemoryLayout<T>.size
    guard position + width <= bytes.byteCount else { throw .BadImageFormat }
    let value = bytes.read(at: position, as: T.self)
    position = position + width
    return value
  }

  /// Reads the next raw byte and advances past it.
  private mutating func byte() throws(WinMDError) -> UInt8 {
    try read(as: UInt8.self)
  }

  /// Reads the fixed `0x0001` prolog and advances past it.
  internal mutating func prolog() throws(WinMDError) {
    guard try read(as: UInt16.self) == 0x0001 else { throw .BadImageFormat }
  }

  /// Reads a `PackedLen` (compressed unsigned integer) and advances past it
  /// (ECMA-335 §II.23.2).
  ///
  /// The lead byte selects the encoding: `0x00..0x7f` is 1 byte, `0x80..0xbf`
  /// 2 bytes, `0xc0..0xdf` 4 bytes; `0xe0` and above is not a defined encoding.
  /// A well-formed encoding must fit within the blob. This mirrors
  /// `SignatureDecoder.width`/`compressed`, guarding the shared
  /// `RawSpan.compressed` against a malformed lead byte or an over-read.
  private mutating func length() throws(WinMDError) -> Int {
    guard position < bytes.byteCount else { throw .BadImageFormat }
    let lead = bytes.read(at: position, as: UInt8.self)
    let width = switch lead {
    case 0x00 ... 0x7f: 1
    case 0x80 ... 0xbf: 2
    case 0xc0 ... 0xdf: 4
    default:            throw .BadImageFormat
    }
    guard position + width <= bytes.byteCount else { throw .BadImageFormat }
    let (begin, value) = bytes.compressed(at: position)
    position = begin
    return value
  }

  /// Reads a `SerString` and advances past it (ECMA-335 §II.23.3).
  ///
  /// A `SerString` is a single `0xFF` byte for a null string, or a `PackedLen`
  /// byte count followed by that many UTF-8 bytes (a count of zero is the empty
  /// string). Returns `nil` for the `0xFF` null marker.
  ///
  /// The bytes are decoded with a *validating* UTF-8 pass: an invalid byte
  /// sequence is malformed metadata and throws, rather than silently
  /// substituting U+FFFD replacement characters and accepting a corrupted
  /// name or value.
  internal mutating func string() throws(WinMDError) -> String? {
    guard position < bytes.byteCount else { throw .BadImageFormat }
    guard bytes.read(at: position, as: UInt8.self) != 0xff else {
      position = position + 1
      return nil
    }
    let count = try length()
    guard position + count <= bytes.byteCount else { throw .BadImageFormat }
    let span = bytes.extracting(position ..< position + count)
    guard let value = String(validating: span, as: UTF8.self) else {
      throw .BadImageFormat
    }
    position = position + count
    return value
  }

  /// Decodes one `FixedArg` given its type from the constructor signature
  /// (ECMA-335 §II.23.3).
  ///
  /// A `FixedArg` carries no leading type tag, so the type drives the read: a
  /// primitive maps to the matching fixed-width read, `STRING` to a
  /// `SerString`, a named reference type to a `System.Type` name (a
  /// `SerString`), and a named value type (an enum) to its underlying integer
  /// — read at the width and signedness the enum's underlying `CorElementType`
  /// resolves to, not a hardcoded `I4`. `SZARRAY` is deferred and throws.
  internal mutating func fixed(_ type: SignatureType)
      throws(WinMDError) -> AttributeValue {
    switch type {
    case .primitive(.boolean):
      switch try read(as: UInt8.self) {
      case 0: return .boolean(false)
      case 1: return .boolean(true)
      default: throw .BadImageFormat
      }
    case .primitive(.char):
      return .integer(Int64(try read(as: UInt16.self)))
    case .primitive(.int1):
      return .integer(Int64(try read(as: Int8.self)))
    case .primitive(.uint1):
      return .integer(Int64(try read(as: UInt8.self)))
    case .primitive(.int2):
      return .integer(Int64(try read(as: Int16.self)))
    case .primitive(.uint2):
      return .integer(Int64(try read(as: UInt16.self)))
    case .primitive(.int4):
      return .integer(Int64(try read(as: Int32.self)))
    case .primitive(.uint4):
      return .integer(Int64(try read(as: UInt32.self)))
    case .primitive(.int8):
      return .integer(try read(as: Int64.self))
    case .primitive(.uint8):
      return .unsigned(try read(as: UInt64.self))
    case .primitive(.float):
      return .real(Double(try read(as: Float32.self)))
    case .primitive(.double):
      return .real(try read(as: Float64.self))
    case .primitive(.string):
      guard let value = try string() else { return .null }
      return .string(value)
    case .named(kind: .class, _):
      guard let value = try string() else { return .null }
      return .type(value)
    case let .named(kind: .value, reference):
      return try integer(of: .reference(reference))
    default:
      throw .BadImageFormat
    }
  }

  /// Reads an enum value at its underlying integer width and signedness
  /// (ECMA-335 §II.23.3).
  ///
  /// The blob names the enum type but not its underlying `CorElementType`, so
  /// `underlying` resolves it from metadata: a `U4`-backed (flags) enum reads
  /// four *unsigned* bytes — a value at or above `0x80000000` stays positive
  /// rather than decoding negative under an `I4` read — and a narrower or wider
  /// enum consumes exactly its own width. An enum type that cannot be resolved,
  /// or one whose underlying type is not an integer, is malformed.
  private mutating func integer(of enumeration: EnumType)
      throws(WinMDError) -> AttributeValue {
    guard let element = underlying(enumeration),
        let primitive = integral(element) else { throw .BadImageFormat }
    return try fixed(.primitive(primitive))
  }

  /// The `PrimitiveType` an integer `CorElementType` names, or `nil` for a
  /// non-integer element type. An enum's underlying type must be one of the
  /// integral primitives (`bool`/`char`/`i1`..`u8`); anything else is invalid.
  private func integral(_ element: CorElementType) -> PrimitiveType? {
    switch element {
    case .etBoolean: .boolean
    case .etChar:    .char
    case .etInt1:    .int1
    case .etUInt1:   .uint1
    case .etInt2:    .int2
    case .etUInt2:   .uint2
    case .etInt4:    .int4
    case .etUInt4:   .uint4
    case .etInt8:    .int8
    case .etUInt8:   .uint8
    default:         nil
    }
  }

  /// Decodes one `NamedArg` and advances past it (ECMA-335 §II.23.3).
  ///
  /// A `NamedArg` is a `FIELD` (`0x53`) or `PROPERTY` (`0x54`) byte, a
  /// self-describing `FieldOrPropType` byte, the `SerString` name, then the
  /// value. The type is read before the name but drives the value read after
  /// it: a bare element-type byte selects a primitive or string; `0x50` a
  /// `System.Type` name (a `SerString`); `0x55` an enum, spelled as a
  /// `SerString` type name then its underlying integer. `0x51` (boxed) and
  /// `0x1d` (`SZARRAY`) are deferred and throw.
  ///
  /// The `FIELD`/`PROPERTY` byte is returned as the `Member` kind: it is the
  /// only disambiguator when a class declares both a field and a property of
  /// the same name, so a caller must know which member to assign.
  internal mutating func named() throws(WinMDError)
      -> (member: Member, name: String, value: AttributeValue) {
    let lead = try byte()
    let member: Member = switch lead {
    case 0x53: .field
    case 0x54: .property
    default:   throw .BadImageFormat
    }

    let element = CorElementType(rawValue: try byte())
    let primitive: PrimitiveType? = switch element {
    case .etBoolean: .boolean
    case .etChar:    .char
    case .etInt1:    .int1
    case .etUInt1:   .uint1
    case .etInt2:    .int2
    case .etUInt2:   .uint2
    case .etInt4:    .int4
    case .etUInt4:   .uint4
    case .etInt8:    .int8
    case .etUInt8:   .uint8
    case .etFloat:   .float
    case .etDouble:  .double
    case .etString:  .string
    default:         nil
    }

    if let primitive {
      guard let name = try string() else { throw .BadImageFormat }
      return (member, name, try fixed(.primitive(primitive)))
    }

    switch element.rawValue {
    case 0x50:       // TYPE (System.Type)
      guard let name = try string() else { throw .BadImageFormat }
      guard let value = try string() else { return (member, name, .null) }
      return (member, name, .type(value))
    case 0x55:       // ENUM
      guard let type = try string() else { throw .BadImageFormat }
      guard let name = try string() else { throw .BadImageFormat }
      let value = try integer(of: .named(type))
      return (member, name, .enumeration(name: type, value: value))
    default:
      throw .BadImageFormat
    }
  }

  /// Decodes a `GuidAttribute` value: the prolog, then the GUID as the
  /// constructor serialises it — `u32, u16, u16, u8×8` (ECMA-335 §II.23.3).
  ///
  /// The constructor serialises `data1`/`data2`/`data3` little-endian, but a
  /// COM GUID's canonical spelling shows those three fields big-endian — which
  /// is exactly the byte order `UUID` stores. Swap the integer fields to
  /// big-endian and carry `data4` in order so `description` renders the
  /// canonical `[Guid(...)]` form.
  internal mutating func guid() throws(WinMDError) -> UUID {
    try prolog()
    let data1: UInt32 = try read()
    let data2: UInt16 = try read()
    let data3: UInt16 = try read()
    let uuid: uuid_t = try (
      UInt8(truncatingIfNeeded: data1 >> 24),
      UInt8(truncatingIfNeeded: data1 >> 16),
      UInt8(truncatingIfNeeded: data1 >> 8),
      UInt8(truncatingIfNeeded: data1),
      UInt8(truncatingIfNeeded: data2 >> 8),
      UInt8(truncatingIfNeeded: data2),
      UInt8(truncatingIfNeeded: data3 >> 8),
      UInt8(truncatingIfNeeded: data3),
      read(), read(), read(), read(),
      read(), read(), read(), read())
    let value = UUID(uuid: uuid)
    guard try read(as: UInt16.self) == 0 else { throw .BadImageFormat }
    guard position == bytes.byteCount else { throw .BadImageFormat }
    return value
  }
}

// MARK: - GuidAttribute value

/// The UUID a `GuidAttribute` `CustomAttribute` value blob names, decoding the
/// raw `bytes` as an ECMA-335 §II.23.3 `GuidAttribute` value.
///
/// This is the escapable, value → value form of `Tuple.iid(_:)`: a caller that
/// has already copied a `CustomAttribute.Value` blob out of the borrowed scan
/// (the SQL adapter's `.blob` cell) decodes it here, without a `Tuple`. A blob
/// that is not a GUID-shaped `GuidAttribute` value throws.
public func iid(decoding bytes: Array<UInt8>) throws(WinMDError) -> UUID {
  var decoder = AttributeDecoder(bytes.span.bytes)
  return try decoder.guid()
}

extension Tuple {
  /// The UUID a `GuidAttribute` `CustomAttribute` row's `Value` blob names, by
  /// decoding the `#Blob` heap cell at `column` as an ECMA-335 §II.23.3
  /// `GuidAttribute` value.
  ///
  /// A `Row`/`Tuple` is a borrowed view that cannot escape the scan, so the
  /// blob's bytes are copied out and run through `AttributeDecoder` after. This
  /// is the codec the SQL adapter's `guid` scalar function over a
  /// `CustomAttribute` `#Blob` reads (mapping a failure to SQL `NULL`);
  /// `Row<TypeDef>.iid` performs the equivalent decode inline as it
  /// navigates to the attribute. A malformed
  /// `Value` blob throws.
  public func iid(_ column: Int) throws(WinMDError) -> UUID {
    let blob = try blob(column)
    var bytes = Array<UInt8>()
    bytes.reserveCapacity(blob.count)
    for i in 0 ..< blob.count {
      bytes.append(blob.load(at: i, as: UInt8.self))
    }
    return try WinMD.iid(decoding: bytes)
  }
}
