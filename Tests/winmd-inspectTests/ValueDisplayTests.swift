// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQLEngine

// MARK: - Boolean

@Suite
private struct BooleanDisplayTests {
  @Test func `a boolean renders as TRUE or FALSE`() {
    #expect(Value.boolean(true).display == "TRUE")
    #expect(Value.boolean(false).display == "FALSE")
  }
}

// MARK: - Double

@Suite
private struct DoubleDisplayTests {
  @Test func `a double renders through its round-tripping description`() {
    #expect(Value.double(3.14).display == "3.14")
    #expect(Value.double(2.5).display == "2.5")
  }

  @Test func `a whole double keeps its .0, marking it approximate-numeric`() {
    #expect(Value.double(1.0).display == "1.0")
    #expect(Value.double(1000.0).display == "1000.0")
  }
}

// MARK: - Blob

@Suite
private struct BlobDisplayTests {
  @Test func `a blob renders as a lowercase-hex x'…' literal`() {
    #expect(Value.blob([0x53, 0x51, 0x4c]).display == "x'53514c'")
  }

  @Test func `hex is lowercase and keeps a byte's leading zero`() {
    #expect(Value.blob([0x00, 0x0f, 0xab, 0xff]).display == "x'000fabff'")
  }

  @Test func `an empty blob renders as x''`() {
    #expect(Value.blob([]).display == "x''")
  }
}
