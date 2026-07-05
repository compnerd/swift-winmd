// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct BlobsHeapTests {
  // A heap holding a single blob at offset 0: the compressed-length `prefix`
  // followed by `count` bytes of `fill`.
  private func buffer(prefix: Array<UInt8>, count: Int,
                      fill: UInt8 = 0xab) -> Array<UInt8> {
    prefix + Array(repeating: fill, count: count)
  }

  @Test func `reads a single-byte compressed length`() {
    let bytes = buffer(prefix: [0x03], count: 3)
    let heap = BlobsHeap(bytes.span.bytes)
    #expect(heap[0].count == 3)
  }

  // A length of 0x20...0x7F is held in a single byte (high bit clear). The
  // previous `first & 0xE0` discriminator mis-routed these to the 2-byte form
  // (0x40...0x5F) or rejected them outright (0x20...0x3F, 0x60...0x7F).
  @Test func `reads single-byte lengths across the high-bit boundary`() {
    for length in [0x20, 0x40, 0x5f, 0x7f] {
      let bytes = buffer(prefix: [UInt8(length)], count: length)
      let heap = BlobsHeap(bytes.span.bytes)
      #expect(heap[0].count == length)
    }
  }

  // 0x80...0x3FFF is held in two bytes (top two bits "10").
  @Test func `reads a two-byte compressed length`() {
    let bytes = buffer(prefix: [0x81, 0x00], count: 0x100)
    let heap = BlobsHeap(bytes.span.bytes)
    #expect(heap[0].count == 0x100)
  }

  // 0x4000... is held in four bytes (top three bits "110").
  @Test func `reads a four-byte compressed length`() {
    let bytes = buffer(prefix: [0xc0, 0x00, 0x40, 0x00], count: 0x4000)
    let heap = BlobsHeap(bytes.span.bytes)
    #expect(heap[0].count == 0x4000)
  }

  @Test func `exposes the blob payload bytes`() {
    let bytes = buffer(prefix: [0x04], count: 4, fill: 0xcd)
    let heap = BlobsHeap(bytes.span.bytes)
    let blob = heap[0]
    #expect(blob.count == 4)
    #expect(blob.load(at: 0, as: UInt8.self) == 0xcd)
    #expect(blob.load(at: 3, as: UInt8.self) == 0xcd)
  }
}
