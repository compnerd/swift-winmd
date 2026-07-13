// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import struct Foundation.UUID

@testable import WinMD

// ECMA-335 §II.23.3 custom-attribute value decoding. The fixtures are hand-built
// `Value` blobs — the raw bytes a `GuidAttribute`'s `#Blob` carries (no heap
// length prefix) — decoded directly through `AttributeDecoder`: the `0x0001`
// prolog then the GUID as `u32, u16, u16, u8×8`.
struct AttributeTests {
  // The `IUnknown` IID `00000000-0000-0000-C000-000000000046`, the canonical
  // root-interface value, serialised as the constructor lays it out.
  private let unknown: Array<UInt8> = [
    0x01, 0x00,                                      // prolog
    0x00, 0x00, 0x00, 0x00,                          // data1 (u32, LE)
    0x00, 0x00,                                      // data2 (u16, LE)
    0x00, 0x00,                                      // data3 (u16, LE)
    0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,  // data4 (8 bytes)
    0x00, 0x00,                                      // NumNamed (no named args)
  ]

  @Test func `decodes IUnknown's IID`() throws {
    let bytes = unknown
    var decoder = AttributeDecoder(bytes.span.bytes)
    let guid = try decoder.guid()
    #expect("\(guid)" == "00000000-0000-0000-C000-000000000046")
  }

  @Test func `decodes a fully-populated GUID, fields little-endian`() throws {
    // The well-known `ISequentialStream` IID exercises every field: data1/2/3
    // are little-endian, the data4 tail is in order.
    let bytes: Array<UInt8> = [
      0x01, 0x00,
      0x30, 0x3a, 0x73, 0x0c,                          // data1 -> 0c733a30
      0x1c, 0x2a,                                      // data2 -> 2a1c
      0xce, 0x11,                                      // data3 -> 11ce
      0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d,  // data4
      0x00, 0x00,                                      // NumNamed (no named args)
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    let guid = try decoder.guid()
    #expect("\(guid)" == "0C733A30-2A1C-11CE-ADE5-00AA0044773D")
  }

  @Test func `renders the canonical uppercase, zero-padded spelling`() {
    let guid = UUID(uuid: (0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03,
                           0x00, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a))
    #expect("\(guid)" == "00000001-0002-0003-0004-05060708090A")
  }

  @Test func `rejects a blob without the 0x0001 prolog`() {
    let bytes: Array<UInt8> = [
      0x00, 0x00,                                      // wrong prolog
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test func `rejects a blob too short for the GUID`() {
    // The prolog and data1, then the blob ends before data2/data3/data4.
    let bytes: Array<UInt8> = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test func `rejects an empty blob`() {
    let bytes = Array<UInt8>()
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test func `rejects a blob missing the NumNamed count`() {
    // The prolog and a full GUID, but the blob ends before the mandatory
    // 2-byte `NumNamed` count (ECMA-335 §II.23.3).
    let bytes: Array<UInt8> = [
      0x01, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test func `rejects a blob with a non-zero NumNamed count`() {
    // A `[Guid]` has no named arguments, so `NumNamed` must be 0; a non-zero
    // count is malformed for this attribute (ECMA-335 §II.23.3).
    let bytes: Array<UInt8> = [
      0x01, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
      0x01, 0x00,                                      // NumNamed = 1
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  // A `FixedArg` carries no leading type tag (ECMA-335 §II.23.3), so each is
  // decoded by handing `fixed(_:)` the type the constructor signature would
  // supply. The fixtures are the raw serialised leaf bytes.
  @Test func `decodes a boolean FixedArg`() throws {
    var atrue = AttributeDecoder(([0x01] as Array<UInt8>).span.bytes)
    #expect(try atrue.fixed(.primitive(.boolean)) == .boolean(true))
    var afalse = AttributeDecoder(([0x00] as Array<UInt8>).span.bytes)
    #expect(try afalse.fixed(.primitive(.boolean)) == .boolean(false))
  }

  @Test func `rejects a boolean FixedArg byte outside 0 and 1`() {
    // ECMA-335 §II.23.3 encodes a bool as a single byte that must be 0 or 1;
    // any other value is malformed.
    var decoder = AttributeDecoder(([0x02] as Array<UInt8>).span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.fixed(.primitive(.boolean))
    }
  }

  @Test func `rejects a named boolean whose byte is outside 0 and 1`() {
    // The named path routes a bool value through `fixed`, so the same guard
    // must fault a malformed byte. FIELD (0x53), BOOLEAN (0x02), name "B".
    let bytes: Array<UInt8> = [
      0x53,                                            // FIELD
      0x02,                                            // BOOLEAN type
      0x01, 0x42,                                      // name "B"
      0x02,                                            // value 2 (malformed)
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.named()
    }
  }

  @Test func `decodes a char FixedArg`() throws {
    let bytes: Array<UInt8> = [0x41, 0x00]              // U+0041 'A', LE u16
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(try decoder.fixed(.primitive(.char)) == .integer(0x41))
  }

  @Test func `decodes the signed integer FixedArgs`() throws {
    let i1: Array<UInt8> = [0xff]                       // -1
    let i2: Array<UInt8> = [0x00, 0x80]                 // -32768
    let i4: Array<UInt8> = [0xff, 0xff, 0xff, 0xff]     // -1
    let i8: Array<UInt8> = [0xfe, 0xff, 0xff, 0xff,     // -2
                            0xff, 0xff, 0xff, 0xff]
    var d1 = AttributeDecoder(i1.span.bytes)
    #expect(try d1.fixed(.primitive(.int1)) == .integer(-1))
    var d2 = AttributeDecoder(i2.span.bytes)
    #expect(try d2.fixed(.primitive(.int2)) == .integer(-32768))
    var d4 = AttributeDecoder(i4.span.bytes)
    #expect(try d4.fixed(.primitive(.int4)) == .integer(-1))
    var d8 = AttributeDecoder(i8.span.bytes)
    #expect(try d8.fixed(.primitive(.int8)) == .integer(-2))
  }

  @Test func `decodes the unsigned integer FixedArgs`() throws {
    let u1: Array<UInt8> = [0xff]                       // 255
    let u2: Array<UInt8> = [0xff, 0xff]                 // 65535
    let u4: Array<UInt8> = [0xff, 0xff, 0xff, 0xff]     // 4294967295
    let u8: Array<UInt8> = [0xff, 0xff, 0xff, 0xff,     // UInt64.max
                            0xff, 0xff, 0xff, 0xff]
    var d1 = AttributeDecoder(u1.span.bytes)
    #expect(try d1.fixed(.primitive(.uint1)) == .integer(255))
    var d2 = AttributeDecoder(u2.span.bytes)
    #expect(try d2.fixed(.primitive(.uint2)) == .integer(65535))
    var d4 = AttributeDecoder(u4.span.bytes)
    #expect(try d4.fixed(.primitive(.uint4)) == .integer(4294967295))
    var d8 = AttributeDecoder(u8.span.bytes)
    #expect(try d8.fixed(.primitive(.uint8)) == .unsigned(.max))
  }

  @Test func `decodes the floating-point FixedArgs`() throws {
    let r4: Array<UInt8> = [0x00, 0x00, 0x80, 0x3f]     // 1.0 (r4)
    let r8: Array<UInt8> = [0x00, 0x00, 0x00, 0x00,     // 2.0 (r8)
                            0x00, 0x00, 0x00, 0x40]
    var d4 = AttributeDecoder(r4.span.bytes)
    #expect(try d4.fixed(.primitive(.float)) == .real(1.0))
    var d8 = AttributeDecoder(r8.span.bytes)
    #expect(try d8.fixed(.primitive(.double)) == .real(2.0))
  }

  @Test func `decodes a string FixedArg`() throws {
    let bytes: Array<UInt8> = [0x03, 0x66, 0x6f, 0x6f]  // len 3, "foo"
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(try decoder.fixed(.primitive(.string)) == .string("foo"))
  }

  @Test func `decodes a System.Type FixedArg as a type name`() throws {
    // A named reference type in the constructor signature (System.Type) is
    // serialised as a `SerString` naming the type.
    let name = "System.Int32"
    let bytes = [UInt8(name.utf8.count)] + Array(name.utf8)
    var decoder = AttributeDecoder(bytes.span.bytes)
    let reference = TypeDefOrRef(rawValue: 0)
    #expect(try decoder.fixed(.named(kind: .class, reference))
              == .type(name))
  }

  @Test func `decodes an i4-backed enum FixedArg`() throws {
    // A named value type (an enum) is serialised as its underlying integer,
    // read at the width the resolved underlying `CorElementType` names — here
    // a signed i4.
    let bytes: Array<UInt8> = [0xff, 0xff, 0xff, 0xff]  // -1 as i4
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etInt4 }
    let reference = TypeDefOrRef(rawValue: 0)
    #expect(try decoder.fixed(.named(kind: .value, reference))
              == .integer(-1))
  }

  @Test func `decodes a u4-backed enum FixedArg unsigned`() throws {
    // A flags enum is commonly backed by u4; a value at or above 0x80000000
    // must stay positive, not decode negative under an i4 read.
    let bytes: Array<UInt8> = [0x00, 0x00, 0x00, 0x80]  // 0x80000000
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etUInt4 }
    let reference = TypeDefOrRef(rawValue: 0)
    #expect(try decoder.fixed(.named(kind: .value, reference))
              == .integer(0x8000_0000))
  }

  @Test func `decodes a narrower u1-backed enum FixedArg`() throws {
    // A byte-backed enum consumes exactly one byte, not four.
    let bytes: Array<UInt8> = [0xff, 0xaa, 0xaa, 0xaa]  // only the first byte
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etUInt1 }
    let reference = TypeDefOrRef(rawValue: 0)
    #expect(try decoder.fixed(.named(kind: .value, reference))
              == .integer(255))
  }

  @Test func `rejects an enum FixedArg whose type cannot resolve`() {
    // With no resolvable underlying type the read cannot proceed; guessing i4
    // would silently mis-decode, so this is malformed.
    let bytes: Array<UInt8> = [0x02, 0x00, 0x00, 0x00]
    var decoder = AttributeDecoder(bytes.span.bytes)
    let reference = TypeDefOrRef(rawValue: 0)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.fixed(.named(kind: .value, reference))
    }
  }

  @Test func `defers a SZARRAY FixedArg`() {
    let bytes: Array<UInt8> = [0x00, 0x00, 0x00, 0x00]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.fixed(.array(.primitive(.int4)))
    }
  }

  @Test func `reads a SerString`() throws {
    let bytes: Array<UInt8> = [0x03, 0x62, 0x61, 0x72]  // len 3, "bar"
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(try decoder.string() == "bar")
  }

  @Test func `reads a null SerString as nil`() throws {
    let bytes: Array<UInt8> = [0xff]                    // null marker
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(try decoder.string() == nil)
  }

  @Test func `reads an empty SerString`() throws {
    let bytes: Array<UInt8> = [0x00]                    // len 0
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(try decoder.string() == "")
  }

  @Test func `reads a multi-byte UTF-8 SerString`() throws {
    // "é€" — a two-byte and a three-byte sequence — decodes exactly, with no
    // replacement characters.
    let text = "é€"
    let bytes = [UInt8(text.utf8.count)] + Array(text.utf8)
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(try decoder.string() == text)
  }

  @Test func `rejects a SerString with invalid UTF-8`() {
    // A lone 0x80 continuation byte is invalid UTF-8; a validating decode
    // rejects it rather than substituting a U+FFFD replacement character.
    let bytes: Array<UInt8> = [0x02, 0x80, 0x41]        // len 2, bad bytes
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.string()
    }
  }

  @Test func `decodes a named field argument`() throws {
    // FIELD (0x53), STRING (0x0e), name "Doc", value "hi".
    let bytes: Array<UInt8> = [
      0x53,                                            // FIELD
      0x0e,                                            // STRING type
      0x03, 0x44, 0x6f, 0x63,                          // name "Doc"
      0x02, 0x68, 0x69,                                // value "hi"
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    let (member, name, value) = try decoder.named()
    #expect(member == .field)
    #expect(name == "Doc")
    #expect(value == .string("hi"))
  }

  @Test func `decodes a named property argument`() throws {
    // PROPERTY (0x54), I4 (0x08), name "Count", value 7.
    let bytes: Array<UInt8> = [
      0x54,                                            // PROPERTY
      0x08,                                            // I4 type
      0x05, 0x43, 0x6f, 0x75, 0x6e, 0x74,              // name "Count"
      0x07, 0x00, 0x00, 0x00,                          // value 7
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    let (member, name, value) = try decoder.named()
    #expect(member == .property)
    #expect(name == "Count")
    #expect(value == .integer(7))
  }

  @Test func `decodes a named enum argument carrying its type name`() throws {
    // FIELD (0x53), ENUM (0x55), enum type "E", name "Kind", value 3.
    let bytes: Array<UInt8> = [
      0x53,                                            // FIELD
      0x55,                                            // ENUM type
      0x01, 0x45,                                      // enum type "E"
      0x04, 0x4b, 0x69, 0x6e, 0x64,                    // name "Kind"
      0x03, 0x00, 0x00, 0x00,                          // value 3 (i4)
    ]
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etInt4 }
    let (member, name, value) = try decoder.named()
    #expect(member == .field)
    #expect(name == "Kind")
    // A signed underlying enum carries its value as a nested `.integer`.
    #expect(value == .enumeration(name: "E", value: .integer(3)))
  }

  @Test func `decodes a named u4-backed flags enum unsigned`() throws {
    // A u4-backed flags enum value at or above 0x80000000 must stay positive
    // and consume four bytes, not decode negative under an i4 read. A `u4`
    // still widens into a signed `.integer` (its bit-31 value fits `Int64`).
    let bytes: Array<UInt8> = [
      0x53,                                            // FIELD
      0x55,                                            // ENUM type
      0x01, 0x46,                                      // enum type "F"
      0x04, 0x4b, 0x69, 0x6e, 0x64,                    // name "Kind"
      0x00, 0x00, 0x00, 0x80,                          // value 0x80000000
    ]
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etUInt4 }
    let (member, name, value) = try decoder.named()
    #expect(member == .field)
    #expect(name == "Kind")
    #expect(value == .enumeration(name: "F", value: .integer(0x8000_0000)))
  }

  @Test func `decodes a named u8-backed enum bit 63 set unsigned`() throws {
    // The reviewer's case: a `u8`-backed enum value with bit 63 set must stay
    // unsigned. It resolves through `integer(of:)` to a `.unsigned` leaf, which
    // the named path now preserves inside `.enumeration` rather than funneling
    // through `Int64` (which would surface -9223372036854775808).
    let bytes: Array<UInt8> = [
      0x53,                                            // FIELD
      0x55,                                            // ENUM type
      0x01, 0x47,                                      // enum type "G"
      0x04, 0x4b, 0x69, 0x6e, 0x64,                    // name "Kind"
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,  // 0x8000000000000000
    ]
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etUInt8 }
    let (member, name, value) = try decoder.named()
    #expect(member == .field)
    #expect(name == "Kind")
    #expect(value == .enumeration(name: "G",
                                  value: .unsigned(0x8000_0000_0000_0000)))
  }

  @Test func `matches the fixed-arg u8 enum representation`() throws {
    // The fixed-arg path (already correct) and the named path now agree: both
    // carry a `u8`-backed enum's value as a `.unsigned` leaf.
    let bytes: Array<UInt8> = [
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,  // 0x8000000000000000
    ]
    var decoder = AttributeDecoder(bytes.span.bytes) { _ in .etUInt8 }
    let reference = TypeDefOrRef(rawValue: 0)
    let fixed = try decoder.fixed(.named(kind: .value, reference))
    #expect(fixed == .unsigned(0x8000_0000_0000_0000))

    let named: Array<UInt8> = [
      0x53,                                            // FIELD
      0x55,                                            // ENUM type
      0x01, 0x47,                                      // enum type "G"
      0x04, 0x4b, 0x69, 0x6e, 0x64,                    // name "Kind"
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,  // 0x8000000000000000
    ]
    var other = AttributeDecoder(named.span.bytes) { _ in .etUInt8 }
    let (_, _, value) = try other.named()
    #expect(value == .enumeration(name: "G", value: fixed))
  }

  @Test func `rejects a named enum whose type cannot resolve`() {
    let bytes: Array<UInt8> = [
      0x53,                                            // FIELD
      0x55,                                            // ENUM type
      0x01, 0x45,                                      // enum type "E"
      0x04, 0x4b, 0x69, 0x6e, 0x64,                    // name "Kind"
      0x03, 0x00, 0x00, 0x00,                          // value 3
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.named()
    }
  }

  @Test func `decodes a named System.Type argument`() throws {
    // PROPERTY (0x54), TYPE (0x50), name "T", value "System.Object".
    let type = "System.Object"
    let bytes: Array<UInt8> = [
      0x54,                                            // PROPERTY
      0x50,                                            // TYPE
      0x01, 0x54,                                      // name "T"
    ] + [UInt8(type.utf8.count)] + Array(type.utf8)
    var decoder = AttributeDecoder(bytes.span.bytes)
    let (member, name, value) = try decoder.named()
    #expect(member == .property)
    #expect(name == "T")
    #expect(value == .type(type))
  }

  @Test func `distinguishes a same-named field and property`() throws {
    // A field "X" and a property "X" differ only by the leading FIELD/
    // PROPERTY byte; both carry I4 (0x08) value 1.
    let field: Array<UInt8> = [
      0x53,                                            // FIELD
      0x08,                                            // I4 type
      0x01, 0x58,                                      // name "X"
      0x01, 0x00, 0x00, 0x00,                          // value 1
    ]
    let property: Array<UInt8> = [
      0x54,                                            // PROPERTY
      0x08,                                            // I4 type
      0x01, 0x58,                                      // name "X"
      0x01, 0x00, 0x00, 0x00,                          // value 1
    ]
    var afield = AttributeDecoder(field.span.bytes)
    var aproperty = AttributeDecoder(property.span.bytes)
    let (fmember, fname, fvalue) = try afield.named()
    let (pmember, pname, pvalue) = try aproperty.named()
    #expect(fmember == .field)
    #expect(pmember == .property)
    #expect(fname == pname)
    #expect(fvalue == pvalue)
    #expect(fmember != pmember)
  }

  @Test func `rejects a named argument with a bad field-or-prop byte`() {
    let bytes: Array<UInt8> = [0x00, 0x0e, 0x00]        // not FIELD/PROPERTY
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.named()
    }
  }

  @Test func `rejects a SerString claiming more bytes than remain`() {
    let bytes: Array<UInt8> = [0x08, 0x61, 0x62]        // len 8, only 2 bytes
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.string()
    }
  }

  @Test func `rejects a FixedArg past the end of the blob`() {
    let bytes: Array<UInt8> = [0x00]                    // one byte, need four
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.fixed(.primitive(.int4))
    }
  }
}
