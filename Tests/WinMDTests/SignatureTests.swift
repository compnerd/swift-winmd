// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

// The element-type opcodes the fixtures use, by their ECMA-335 §II.23.1.16
// values, so the byte arrays read as the spec spells them.
private let DEFAULT: UInt8 = 0x00
private let HASTHIS: UInt8 = 0x20
private let EXPLICITTHIS: UInt8 = 0x40
private let FIELD: UInt8 = 0x06
private let PROPERTY: UInt8 = 0x08
private let VOID: UInt8 = 0x01
private let I4: UInt8 = 0x08
private let U4: UInt8 = 0x09
private let STRING: UInt8 = 0x0e
private let PTR: UInt8 = 0x0f
private let BYREF: UInt8 = 0x10
private let VALUETYPE: UInt8 = 0x11
private let CLASS: UInt8 = 0x12
private let ARRAY: UInt8 = 0x14
private let SZARRAY: UInt8 = 0x1d
private let CMOD_OPT: UInt8 = 0x20

// A `TypeDefOrRefOrSpec` coded index, compressed: low two bits the tag, the
// rest the 1-based row. `TypeRef[0]` is `(1 << 2) | 1 == 5`.
private let typeref0: UInt8 = 0x05

// ECMA-335 §II.23.2 signature decoding. The fixtures are hand-built signature
// blobs — the raw `#Blob` bytes, without the heap length prefix — decoded
// directly through `SignatureDecoder`; the accessor tests additionally wrap a
// signature in a one-blob `#Blob` heap and reach it through a `Row`.
struct SignatureTests {
  @Test func `decodes (i4, string) -> void`() throws {
    let bytes = [DEFAULT, 0x02, VOID, I4, STRING]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()

    #expect(signature.convention == .default)
    #expect(!signature.instance)
    #expect(signature.generics == 0)
    guard case .primitive(.void) = signature.returns else {
      Issue.record("return not void"); return
    }
    #expect(signature.parameters.count == 2)
    guard case .primitive(.int4) = signature.parameters[0],
        case .primitive(.string) = signature.parameters[1] else {
      Issue.record("parameters not (i4, string)"); return
    }
  }

  @Test func `decodes the HASTHIS instance flag`() throws {
    let bytes = [HASTHIS | DEFAULT, 0x00, VOID]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    #expect(signature.instance)
    #expect(signature.parameters.isEmpty)
  }

  @Test func `decodes a pointer parameter`() throws {
    let bytes = [DEFAULT, 0x01, VOID, PTR, I4]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .pointer(pointee) = signature.parameters[0],
        case .primitive(.int4) = pointee else {
      Issue.record("parameter not i4*"); return
    }
  }

  @Test func `decodes a byref parameter`() throws {
    let bytes = [DEFAULT, 0x01, VOID, BYREF, U4]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .reference(referent) = signature.parameters[0],
        case .primitive(.uint4) = referent else {
      Issue.record("parameter not ref u4"); return
    }
  }

  @Test func `decodes an SZARRAY return`() throws {
    let bytes = [DEFAULT, 0x00, SZARRAY, I4]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .array(element) = signature.returns,
        case .primitive(.int4) = element else {
      Issue.record("return not i4[]"); return
    }
  }

  @Test func `decodes a CLASS parameter via a coded index`() throws {
    let bytes = [DEFAULT, 0x01, VOID, CLASS, typeref0]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .named(kind, reference) = signature.parameters[0] else {
      Issue.record("parameter not a named type"); return
    }
    #expect(kind == .class)
    // `TypeRef[0]`: tag 1 (the second of TypeDef/TypeRef/TypeSpec), row 1.
    #expect(reference.tag == 1)
    #expect(reference.row == 1)
  }

  @Test func `decodes a custom-modified parameter`() throws {
    // `const`-modified value type: CMOD_OPT TypeRef[0], then VALUETYPE TypeRef[0].
    let bytes = [DEFAULT, 0x01, VOID, CMOD_OPT, typeref0, VALUETYPE, typeref0]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .modified(base, modifiers) = signature.parameters[0] else {
      Issue.record("parameter not modified"); return
    }
    #expect(modifiers.count == 1)
    #expect(!modifiers[0].required)
    #expect(modifiers[0].type.tag == 1)
    guard case .named(.value, _) = base else {
      Issue.record("modified base not a value type"); return
    }
  }

  @Test func `decodes a field signature`() throws {
    let bytes = [FIELD, I4]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.field()
    guard case .primitive(.int4) = signature.type else {
      Issue.record("field not i4"); return
    }
  }

  @Test func `decodes a property signature`() throws {
    // PROPERTY, no index parameters, an I4 property type.
    let bytes = [PROPERTY, 0x00, I4]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.property()
    #expect(!signature.instance)
    guard case .primitive(.int4) = signature.type else {
      Issue.record("property not i4"); return
    }
    #expect(signature.parameters.isEmpty)
  }

  @Test func `decodes the property HASTHIS instance flag`() throws {
    let bytes = [PROPERTY | HASTHIS, 0x00, STRING]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.property()
    #expect(signature.instance)
    guard case .primitive(.string) = signature.type else {
      Issue.record("property not string"); return
    }
  }

  @Test func `decodes an indexer property's index parameters`() throws {
    // PROPERTY, two index parameters (I4, STRING), a U4 property type.
    let bytes = [PROPERTY, 0x02, U4, I4, STRING]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.property()
    guard case .primitive(.uint4) = signature.type else {
      Issue.record("property not u4"); return
    }
    #expect(signature.parameters.count == 2)
    guard case .primitive(.int4) = signature.parameters[0],
        case .primitive(.string) = signature.parameters[1] else {
      Issue.record("index parameters not (i4, string)"); return
    }
  }

  @Test func `rejects a property signature with a non-PROPERTY prolog`() {
    // A FIELD (0x06) prolog names a field, not a property; `property()` must
    // reject it (ECMA-335 §II.23.2.5).
    let bytes = [FIELD, 0x00, I4]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.property() }
  }

  @Test func `rejects an unknown element type`() {
    let bytes = [DEFAULT, 0x00, 0xff]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `rejects an unsupported calling convention`() {
    // The prolog's low nibble names the calling convention (ECMA-335 §II.23.2.1);
    // 0x09 and 0x0f are not defined values, so the decoder must reject them rather
    // than silently treating them as the DEFAULT convention.
    let nine = [0x09 as UInt8, 0x00, VOID]
    var nineDecoder = SignatureDecoder(nine.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try nineDecoder.method() }

    let fifteen = [0x0f as UInt8, 0x00, VOID]
    var fifteenDecoder = SignatureDecoder(fifteen.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try fifteenDecoder.method() }
  }

  @Test func `rejects a truncated signature`() {
    let bytes = [DEFAULT, 0x01, VOID]    // missing the parameter
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `rejects an invalid compressed-integer lead byte`() {
    // The parameter count is a compressed integer; `0xe0` is `111xxxxx`, not a
    // defined encoding, so decoding must fault rather than read past the blob.
    let bytes = [DEFAULT, 0xe0, VOID]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `rejects a compressed integer running off the blob end`() {
    // `0x80` opens a 2-byte encoding but no second byte follows; `0xc0` opens a
    // 4-byte one with only one byte left. Either must fault, not crash.
    let two = [DEFAULT, 0x80]
    var twoDecoder = SignatureDecoder(two.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try twoDecoder.method() }

    let four = [DEFAULT, 0xc0]
    var fourDecoder = SignatureDecoder(four.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try fourDecoder.method() }
  }

  @Test func `decodes a multidimensional ARRAY's negative lower bound`() throws {
    // `i4[*]` returning from a method: rank 1, no explicit sizes, one lower
    // bound of -3 (compressed signed `0x7b`, ECMA-335 §II.23.2).
    let bytes = [DEFAULT, 0x00, ARRAY, I4, 0x01, 0x00, 0x01, 0x7b]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .matrix(element, shape) = signature.returns,
        case .primitive(.int4) = element else {
      Issue.record("return not an i4 matrix"); return
    }
    #expect(shape.rank == 1)
    #expect(shape.sizes.isEmpty)
    #expect(shape.bounds == [-3])
  }

  @Test func `decodes a multidimensional ARRAY's 4-byte negative lower bound`() throws {
    // A lower bound whose magnitude exceeds 2^13 needs the 4-byte compressed
    // signed form, which carries 29 payload bits (5 in the lead byte + 24
    // following), so the negative correction subtracts 2^28. The bound -16384
    // (magnitude 16384 > 2^13) encodes rotated to value 536838145, i.e. the
    // 4-byte big-endian word `0xdf 0xff 0x80 0x01` (ECMA-335 §II.23.2). A
    // 28-bit correction would decode it 2^27 (134217728) too high.
    let bytes =
        [DEFAULT, 0x00, ARRAY, I4, 0x01, 0x00, 0x01, 0xdf, 0xff, 0x80, 0x01]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .matrix(element, shape) = signature.returns,
        case .primitive(.int4) = element else {
      Issue.record("return not an i4 matrix"); return
    }
    #expect(shape.rank == 1)
    #expect(shape.sizes.isEmpty)
    #expect(shape.bounds == [-16384])
  }

  @Test func `rejects an ARRAY with more sizes than its rank`() {
    // ECMA-335 §II.23.2.13 constrains `NumSizes` to `<= Rank`. Here rank is 1 but
    // NumSizes is 2 (two sizes, no lower bounds) — the decoder must reject it.
    let bytes = [DEFAULT, 0x00, ARRAY, I4, 0x01, 0x02, 0x01, 0x02, 0x00]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `rejects an ARRAY with more lower bounds than its rank`() {
    // Likewise `NumLoBounds` must be `<= Rank`. Rank is 1 but NumLoBounds is 2
    // (no sizes, two bounds) — the decoder must reject it.
    let bytes = [DEFAULT, 0x00, ARRAY, I4, 0x01, 0x00, 0x02, 0x01, 0x02]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `decodes a well-formed ARRAY at its rank's limits`() throws {
    // Rank 2 with NumSizes 2 and NumLoBounds 2 — both at the rank limit — decodes
    // to a 2x3 matrix lower-bounded at (0, 1).
    let bytes =
        [DEFAULT, 0x00, ARRAY, I4, 0x02, 0x02, 0x02, 0x03, 0x02, 0x00, 0x02]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    guard case let .matrix(element, shape) = signature.returns,
        case .primitive(.int4) = element else {
      Issue.record("return not an i4 matrix"); return
    }
    #expect(shape.rank == 2)
    #expect(shape.sizes == [2, 3])
    #expect(shape.bounds == [0, 1])
  }

  @Test func `rejects a zero-rank ARRAY`() {
    // ECMA-335 §II.23.2.13 requires `Rank >= 1`. Here rank is 0 (with no sizes
    // and no lower bounds); both `<= Rank` guards pass vacuously, so the rank
    // guard itself must reject it.
    let bytes = [DEFAULT, 0x00, ARRAY, I4, 0x00, 0x00, 0x00]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `rejects EXPLICITTHIS without HASTHIS`() {
    // ECMA-335 §II.23.2.1: EXPLICITTHIS (0x40) is only valid alongside HASTHIS
    // (0x20). A prolog of 0x40 alone — explicit but not instance — is malformed.
    let bytes = [EXPLICITTHIS | DEFAULT, 0x00, VOID]
    var decoder = SignatureDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) { _ = try decoder.method() }
  }

  @Test func `decodes EXPLICITTHIS alongside HASTHIS`() throws {
    // A prolog of 0x60 sets both HASTHIS and EXPLICITTHIS, which is well-formed.
    let bytes = [EXPLICITTHIS | HASTHIS | DEFAULT, 0x00, VOID]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let signature = try decoder.method()
    #expect(signature.instance)
    #expect(signature.explicit)
  }

  // MARK: - Accessors through a Row

  // A `MethodDef` row whose `Signature` cell (ordinal 4) is the heap offset 0;
  // the blob heap there holds `DEFAULT, 0, VOID` — `() -> void`. The other cells
  // are zero. The narrow stride is RVA (4) + ImplFlags (2) + Flags (2) + three
  // 2-byte indices = 14.
  private static let method: Array<UInt8> = [
    0x00, 0x00, 0x00, 0x00,    // RVA
    0x00, 0x00,                // ImplFlags
    0x00, 0x00,                // Flags
    0x00, 0x00,                // Name
    0x00, 0x00,                // Signature (heap offset 0)
    0x00, 0x00,                // ParamList
  ]

  // A blob heap: a single blob at offset 0, length-prefixed.
  private static let methodBlob: Array<UInt8> = [0x03, DEFAULT, 0x00, VOID]

  // A `FieldDef` row whose `Signature` cell (ordinal 2) is the heap offset 0.
  // The narrow stride is Flags (2) + two 2-byte indices = 6.
  private static let fieldRecord: Array<UInt8> = [
    0x00, 0x00,                // Flags
    0x00, 0x00,                // Name
    0x00, 0x00,                // Signature (heap offset 0)
  ]

  // A blob heap holding `FIELD, I4`, length-prefixed.
  private static let fieldBlob: Array<UInt8> = [0x02, FIELD, I4]

  private static let empty = Array<UInt8>()

  @Test func `decodes a MethodDef signature through the row accessor`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.methodBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    let signature = try rows[0]!.prototype
    guard case .primitive(.void) = signature.returns else {
      Issue.record("return not void"); return
    }
    #expect(signature.parameters.isEmpty)
  }

  @Test func `decodes a FieldDef signature through the row accessor`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.fieldBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    let signature = try rows[0]!.declaration
    guard case .primitive(.int4) = signature.type else {
      Issue.record("field not i4"); return
    }
  }

  // A `PropertyDef` row whose `Type` cell (ordinal 2) is the heap offset 0.
  // The narrow stride is Flags (2) + Name (2) + Type (2) = 6.
  private static let propertyRecord: Array<UInt8> = [
    0x00, 0x00,                // Flags
    0x00, 0x00,                // Name
    0x00, 0x00,                // Type (heap offset 0)
  ]

  // A blob heap holding `PROPERTY, 0, I4` — a plain `I4` property — length-
  // prefixed.
  private static let propertyBlob: Array<UInt8> = [0x03, PROPERTY, 0x00, I4]

  // A blob heap holding `PROPERTY, 1, STRING, I4` — a `String this[i4]`
  // indexer — length-prefixed.
  private static let indexerBlob: Array<UInt8> =
      [0x04, PROPERTY, 0x01, STRING, I4]

  // A blob heap holding a `FIELD, I4` field signature under a `PropertyDef`
  // row: the FIELD prolog is not a property, so `declaration` must reject it.
  private static let propertyFieldBlob: Array<UInt8> = [0x02, FIELD, I4]

  @Test func `decodes a PropertyDef signature through the row accessor`() throws {
    let relations =
        [Table(Metadata.Tables.PropertyDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.propertyRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.propertyBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 23, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.PropertyDef.self)
    let signature = try rows[0]!.declaration
    guard case .primitive(.int4) = signature.type else {
      Issue.record("property not i4"); return
    }
    #expect(signature.parameters.isEmpty)
  }

  @Test func `decodes a PropertyDef indexer through the row accessor`() throws {
    let relations =
        [Table(Metadata.Tables.PropertyDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.propertyRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.indexerBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 23, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.PropertyDef.self)
    let signature = try rows[0]!.declaration
    guard case .primitive(.string) = signature.type else {
      Issue.record("property not string"); return
    }
    #expect(signature.parameters.count == 1)
    guard case .primitive(.int4) = signature.parameters[0] else {
      Issue.record("index parameter not i4"); return
    }
  }

  @Test func `rejects a PropertyDef signature with a non-PROPERTY prolog`() throws {
    let relations =
        [Table(Metadata.Tables.PropertyDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.propertyRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.propertyFieldBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 23, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.PropertyDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  // A field signature whose prolog is `FIELD | GENERIC` (`0x16`): the `GENERIC`
  // high bit is a method-signature flag, invalid on a field, whose first byte
  // must be exactly `0x06` (ECMA-335 §II.23.2.4). The masked check accepted it;
  // the exact check rejects it.
  private static let fieldGenericBlob: Array<UInt8> = [0x02, 0x16, I4]

  // A field signature whose prolog is `FIELD | HASTHIS` (`0x26`): the `HASTHIS`
  // high bit is likewise a method-signature flag, invalid on a field.
  private static let fieldHasThisBlob: Array<UInt8> = [0x02, 0x26, I4]

  @Test func `rejects a field signature whose prolog carries the GENERIC flag`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.fieldGenericBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  @Test func `rejects a field signature whose prolog carries the HASTHIS flag`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.fieldHasThisBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  // A blob holding a valid `DEFAULT, 0, VOID` method signature followed by a
  // stray byte; the top-level accessor must consume the whole blob and reject
  // the trailing byte as malformed metadata, not silently ignore it.
  private static let methodTrailingBlob: Array<UInt8> =
      [0x04, DEFAULT, 0x00, VOID, 0xff]

  // A blob with a valid `FIELD, I4` field signature followed by a stray byte.
  private static let fieldTrailingBlob: Array<UInt8> =
      [0x03, FIELD, I4, 0xff]

  @Test func `rejects a method signature with trailing bytes`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.methodTrailingBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a field signature with trailing bytes`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.fieldTrailingBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  // A method blob whose prolog sets the reserved high bit `0x80`: the only
  // valid prolog bits are the low-nibble convention plus GENERIC/HASTHIS/
  // EXPLICITTHIS (ECMA-335 §II.23.2.1), so the reserved bit is malformed.
  private static let reservedPrologBlob: Array<UInt8> =
      [0x03, 0x80, 0x00, VOID]

  // Method blobs whose prolog's low nibble names a non-method convention —
  // FIELD (0x06), LOCAL_SIG (0x07), PROPERTY (0x08); a `MethodSignature` opens
  // only with a method convention, so each is malformed.
  private static let fieldConventionBlob: Array<UInt8> =
      [0x03, 0x06, 0x00, VOID]
  private static let localConventionBlob: Array<UInt8> =
      [0x03, 0x07, 0x00, VOID]
  private static let propertyConventionBlob: Array<UInt8> =
      [0x03, 0x08, 0x00, VOID]

  @Test func `rejects a method prolog with the reserved high bit set`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.reservedPrologBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a method prolog naming the FIELD convention`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.fieldConventionBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a method prolog naming the LOCAL_SIG convention`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.localConventionBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a method prolog naming the PROPERTY convention`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.propertyConventionBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  // MARK: - The signature accessors validate the #Blob entry

  // A blob heap whose entry at offset 0 opens with a length-prefix lead byte
  // `0xe0` — `111xxxxx`, not a defined compressed encoding (ECMA-335 §II.23.2).
  // Opening it must throw, not trap reading a nonsense length.
  private static let badPrefixBlob: Array<UInt8> = [0xe0, DEFAULT, 0x00, VOID]

  // A blob heap whose entry's length prefix (`0x7f` — 1 byte, value 127) runs
  // far past the 1-byte payload actually present, so the delimited extent
  // exceeds the heap. Opening it must throw, not read out of bounds.
  private static let longPrefixBlob: Array<UInt8> = [0x7f, DEFAULT]

  @Test func `rejects a #Blob signature entry with an invalid length-prefix lead`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.badPrefixBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a #Blob signature entry whose length runs past the heap`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.longPrefixBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a #Blob field entry with an invalid length-prefix lead`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.badPrefixBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  @Test func `rejects a #Blob field entry whose length runs past the heap`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.longPrefixBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  @Test func `a well-formed #Blob signature entry still decodes through the accessor`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.methodBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    let signature = try rows[0]!.prototype
    guard case .primitive(.void) = signature.returns else {
      Issue.record("return not void"); return
    }
    #expect(signature.parameters.isEmpty)
  }

  // MARK: - VOID is positional

  // A method blob `DEFAULT, count 1, I4 return, VOID parameter`: VOID names the
  // absent type, legal only as a return or a pointer's pointee (ECMA-335
  // §II.23.2.12), so a standalone VOID parameter is malformed metadata.
  private static let voidParameterBlob: Array<UInt8> =
      [0x04, DEFAULT, 0x01, I4, VOID]

  // A field blob `FIELD, VOID`: a field can never have the absent type.
  private static let voidFieldBlob: Array<UInt8> = [0x02, FIELD, VOID]

  // A method blob `DEFAULT, count 0, VOID return`: VOID is legal as a return.
  private static let voidReturnBlob: Array<UInt8> =
      [0x03, DEFAULT, 0x00, VOID]

  // A method blob `DEFAULT, count 1, I4 return, PTR VOID parameter`: `void*`
  // (PVOID/LPVOID) stays legal — VOID is the pointee of a PTR.
  private static let voidPointerBlob: Array<UInt8> =
      [0x05, DEFAULT, 0x01, I4, PTR, VOID]

  @Test func `rejects a VOID method parameter`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.voidParameterBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a VOID field type`() throws {
    let relations =
        [Table(Metadata.Tables.FieldDef.self, rows: 1, range: 0 ..< 6,
               wide: 0, stride: 6)]
    let storage = Storage(bytes: SignatureTests.fieldRecord.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.voidFieldBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 4, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.FieldDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.declaration }
  }

  @Test func `decodes a VOID return`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.voidReturnBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    let signature = try rows[0]!.prototype
    guard case .primitive(.void) = signature.returns else {
      Issue.record("return not void"); return
    }
    #expect(signature.parameters.isEmpty)
  }

  @Test func `decodes a VOID pointer parameter`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.voidPointerBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    let signature = try rows[0]!.prototype
    guard case let .pointer(pointee) = signature.parameters[0],
        case .primitive(.void) = pointee else {
      Issue.record("parameter not void*"); return
    }
  }

  // MARK: - The MethodDef convention is DEFAULT or VARARG

  // ECMA-335 §II.23.2.1 limits a MethodDefSig's calling convention to DEFAULT
  // or VARARG (plus the HASTHIS/EXPLICITTHIS/GENERIC flags); the unmanaged
  // C/STDCALL/THISCALL/FASTCALL conventions (0x01–0x04) belong to a
  // StandAloneMethodSig, not a method-def. Each unmanaged-convention blob is a
  // `() -> void` body the shared `method()` accepts but the `prototype`
  // accessor must reject. The names follow the convention the low nibble selects.
  private static let cConventionBlob: Array<UInt8> =
      [0x03, 0x01, 0x00, VOID]
  private static let stdcallConventionBlob: Array<UInt8> =
      [0x03, 0x02, 0x00, VOID]
  private static let thiscallConventionBlob: Array<UInt8> =
      [0x03, 0x03, 0x00, VOID]
  private static let fastcallConventionBlob: Array<UInt8> =
      [0x03, 0x04, 0x00, VOID]

  // A method blob naming the VARARG convention (low nibble 0x05): a valid
  // MethodDefSig convention that must still decode through `prototype`.
  private static let varargConventionBlob: Array<UInt8> =
      [0x03, 0x05, 0x00, VOID]

  // Drives the `prototype` accessor over a one-blob heap, expecting a throw.
  private func expectPrototypeRejects(_ blob: Array<UInt8>) throws {
    let blob = blob
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: blob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    #expect(throws: WinMDError.BadImageFormat) { _ = try rows[0]!.prototype }
  }

  @Test func `rejects a MethodDef prolog naming the unmanaged C convention`() throws {
    try expectPrototypeRejects(SignatureTests.cConventionBlob)
  }

  @Test func `rejects a MethodDef prolog naming the unmanaged STDCALL convention`() throws {
    try expectPrototypeRejects(SignatureTests.stdcallConventionBlob)
  }

  @Test func `rejects a MethodDef prolog naming the unmanaged THISCALL convention`() throws {
    try expectPrototypeRejects(SignatureTests.thiscallConventionBlob)
  }

  @Test func `rejects a MethodDef prolog naming the unmanaged FASTCALL convention`() throws {
    try expectPrototypeRejects(SignatureTests.fastcallConventionBlob)
  }

  @Test func `decodes a DEFAULT-convention MethodDef through prototype`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.methodBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    let signature = try rows[0]!.prototype
    #expect(signature.convention == .default)
  }

  @Test func `decodes a VARARG-convention MethodDef through prototype`() throws {
    let relations =
        [Table(Metadata.Tables.MethodDef.self, rows: 1, range: 0 ..< 14,
               wide: 0, stride: 14)]
    let storage = Storage(bytes: SignatureTests.method.span.bytes,
                          relations: relations.span,
                          strings: SignatureTests.empty.span.bytes,
                          blob: SignatureTests.varargConventionBlob.span.bytes,
                          guid: SignatureTests.empty.span.bytes,
                          valid: 1 << 6, sorted: 0)
    let rows = try storage.rows(of: Metadata.Tables.MethodDef.self)
    let signature = try rows[0]!.prototype
    #expect(signature.convention == .vararg)
  }

  // MARK: - method() itself admits the unmanaged conventions

  @Test func `decodes an FNPTR carrying an unmanaged STDCALL convention`() throws {
    // FNPTR (0x1b) wraps a nested method signature, and a function pointer
    // (calli) legitimately names an unmanaged convention. The inner method's
    // prolog is 0x03 (THISCALL) over a `() -> void` body. The `prototype`
    // restriction is specific to a top-level MethodDefSig; `type()` — the FNPTR
    // path — must still admit the unmanaged convention without throwing, which
    // proves the shared `method()` itself is not restricted.
    let FNPTR: UInt8 = 0x1b
    let bytes = [FNPTR, 0x03, 0x00, VOID]
    var decoder = SignatureDecoder(bytes.span.bytes)
    let type = try decoder.type()
    guard case let .function(signature) = type else {
      Issue.record("type not a function pointer"); return
    }
    #expect(signature.convention == .thiscall)
  }
}
