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
