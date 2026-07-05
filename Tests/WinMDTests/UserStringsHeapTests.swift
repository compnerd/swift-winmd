// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct UserStringsHeapTests {
  // Offset 0 is always the empty entry: a zero-length blob.
  @Test func `decodes the empty entry at offset 0`() {
    let bytes: Array<UInt8> = [0x00]
    let heap = UserStringsHeap(bytes.span.bytes)
    #expect(heap[0] == "")
  }

  // "Hi" → UTF-16LE `48 00 69 00`, plus a terminal byte `00`, giving a payload
  // of five bytes, prefixed by the single-byte compressed length `0x05`.
  @Test func `decodes a UTF-16 string with a single-byte length`() {
    let bytes: Array<UInt8> = [0x05, 0x48, 0x00, 0x69, 0x00, 0x00]
    let heap = UserStringsHeap(bytes.span.bytes)
    #expect(heap[0] == "Hi")
  }

  // The same "Hi" payload, but encoded with a two-byte compressed length
  // (`0x80 0x05`) to exercise the wider length form.
  @Test func `decodes a UTF-16 string with a two-byte length`() {
    let bytes: Array<UInt8> = [0x80, 0x05, 0x48, 0x00, 0x69, 0x00, 0x00]
    let heap = UserStringsHeap(bytes.span.bytes)
    #expect(heap[0] == "Hi")
  }

  // A non-zero code unit alongside the terminal flag set, confirming the
  // terminal byte is ignored for the decoded value.
  @Test func `ignores the terminal byte when decoding`() {
    // "é" (U+00E9) → UTF-16LE `E9 00`, terminal flag `01`, length `0x03`.
    let bytes: Array<UInt8> = [0x03, 0xe9, 0x00, 0x01]
    let heap = UserStringsHeap(bytes.span.bytes)
    #expect(heap[0] == "\u{00e9}")
  }

  // A multi-code-unit string whose code units begin at an odd byte offset (the
  // single-byte length prefix puts `begin` at 1), proving the unaligned read
  // path. "Hello" → UTF-16LE, terminal flag `00`, length `0x0b`.
  @Test func `decodes a multi-code-unit string at an odd offset`() {
    let bytes: Array<UInt8> = [0x0b, 0x48, 0x00, 0x65, 0x00, 0x6c, 0x00,
                               0x6c, 0x00, 0x6f, 0x00, 0x00]
    let heap = UserStringsHeap(bytes.span.bytes)
    #expect(heap[0] == "Hello")
  }

  // A non-ASCII string requiring a surrogate pair, again starting at an odd
  // `begin`. "😀" (U+1F600) → UTF-16LE surrogates `D83D DE00` i.e. bytes
  // `3D D8 00 DE`, terminal flag `01`, length `0x05`.
  @Test func `decodes a surrogate-pair string at an odd offset`() {
    let bytes: Array<UInt8> = [0x05, 0x3d, 0xd8, 0x00, 0xde, 0x01]
    let heap = UserStringsHeap(bytes.span.bytes)
    #expect(heap[0] == "\u{1f600}")
  }
}
