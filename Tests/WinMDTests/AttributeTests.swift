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

  @Test("decodes IUnknown's IID")
  func iunknown() throws {
    var bytes = unknown
    var decoder = AttributeDecoder(bytes.span.bytes)
    let guid = try decoder.guid()
    #expect("\(guid)" == "00000000-0000-0000-C000-000000000046")
  }

  @Test("decodes a fully-populated GUID, fields little-endian")
  func populated() throws {
    // The well-known `ISequentialStream` IID exercises every field: data1/2/3
    // are little-endian, the data4 tail is in order.
    var bytes: Array<UInt8> = [
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

  @Test("renders the canonical uppercase, zero-padded spelling")
  func description() {
    let guid = UUID(uuid: (0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03,
                           0x00, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a))
    #expect("\(guid)" == "00000001-0002-0003-0004-05060708090A")
  }

  @Test("rejects a blob without the 0x0001 prolog")
  func badProlog() {
    var bytes: Array<UInt8> = [
      0x00, 0x00,                                      // wrong prolog
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test("rejects a blob too short for the GUID")
  func truncated() {
    // The prolog and data1, then the blob ends before data2/data3/data4.
    var bytes: Array<UInt8> = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test("rejects an empty blob")
  func empty() {
    var bytes = Array<UInt8>()
    var decoder = AttributeDecoder(bytes.span.bytes)
    #expect(throws: WinMDError.BadImageFormat) {
      _ = try decoder.guid()
    }
  }

  @Test("rejects a blob missing the NumNamed count")
  func missingNumNamed() {
    // The prolog and a full GUID, but the blob ends before the mandatory
    // 2-byte `NumNamed` count (ECMA-335 §II.23.3).
    var bytes: Array<UInt8> = [
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

  @Test("rejects a blob with a non-zero NumNamed count")
  func namedArguments() {
    // A `[Guid]` has no named arguments, so `NumNamed` must be 0; a non-zero
    // count is malformed for this attribute (ECMA-335 §II.23.3).
    var bytes: Array<UInt8> = [
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
}
