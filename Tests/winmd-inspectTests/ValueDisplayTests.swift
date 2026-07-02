// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQL

// MARK: - Boolean

@Suite("BOOLEAN display")
private struct BooleanDisplayTests {
  @Test("a boolean renders as TRUE or FALSE")
  func spelling() {
    #expect(Value.boolean(true).display == "TRUE")
    #expect(Value.boolean(false).display == "FALSE")
  }
}

// MARK: - Double

@Suite("DOUBLE display")
private struct DoubleDisplayTests {
  @Test("a double renders through its round-tripping description")
  func description() {
    #expect(Value.double(3.14).display == "3.14")
    #expect(Value.double(2.5).display == "2.5")
  }

  @Test("a whole double keeps its .0, marking it approximate-numeric")
  func whole() {
    #expect(Value.double(1.0).display == "1.0")
    #expect(Value.double(1000.0).display == "1000.0")
  }
}

// MARK: - Blob

@Suite("BLOB display")
private struct BlobDisplayTests {
  @Test("a blob renders as a lowercase-hex x'…' literal")
  func hex() {
    #expect(Value.blob([0x53, 0x51, 0x4c]).display == "x'53514c'")
  }

  @Test("hex is lowercase and keeps a byte's leading zero")
  func lowercaseAndPadding() {
    #expect(Value.blob([0x00, 0x0f, 0xab, 0xff]).display == "x'000fabff'")
  }

  @Test("an empty blob renders as x''")
  func empty() {
    #expect(Value.blob([]).display == "x''")
  }
}
