// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

// MARK: - Harness

/// A one-cell row that yields a fixed `Value` at slot `0` — the minimal `Row`
/// that drives the comparison choke point (`matches`, reached through
/// `evaluate`) over a `boolean` or `blob` cell without a whole relation.
///
/// The source carries no borrowed storage, so it omits `@_lifetime`.
private struct Cell: Row {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }

  subscript(_ column: Int) -> Value {
    borrowing get { value }
  }
}

/// Evaluates `cell op constant` through the engine's three-valued comparison —
/// `true`, `false`, or `nil` (UNKNOWN) — the path a real `WHERE` takes.
private func compare(_ cell: Value, _ op: Comparison,
                     _ constant: Value) -> Bool? {
  try! Cell(cell).evaluate(.compare(.slot(0), op, .constant(constant)),
                           Routines(), [:])
}

// MARK: - Boolean

@Suite
private struct BooleanValueTests {
  @Test func `false orders before true`() {
    #expect(compare(.boolean(false), .lt, .boolean(true)) == true)
    #expect(compare(.boolean(true), .lt, .boolean(false)) == false)
    #expect(compare(.boolean(false), .lt, .boolean(false)) == false)
    #expect(compare(.boolean(true), .gt, .boolean(false)) == true)
  }

  @Test func `like booleans compare equal`() {
    #expect(compare(.boolean(true), .equal, .boolean(true)) == true)
    #expect(compare(.boolean(true), .equal, .boolean(false)) == false)
    #expect(compare(.boolean(false), .unequal, .boolean(true)) == true)
  }

  @Test func `the boundary relations follow the false < true order`() {
    #expect(compare(.boolean(false), .leq, .boolean(false)) == true)
    #expect(compare(.boolean(false), .leq, .boolean(true)) == true)
    #expect(compare(.boolean(true), .leq, .boolean(false)) == false)
    #expect(compare(.boolean(true), .geq, .boolean(true)) == true)
    #expect(compare(.boolean(false), .geq, .boolean(true)) == false)
  }
}

// MARK: - Blob

@Suite
private struct BlobValueTests {
  @Test func `like blobs compare by byte equality`() {
    #expect(compare(.blob([0x53, 0x51, 0x4c]), .equal,
                    .blob([0x53, 0x51, 0x4c])) == true)
    #expect(compare(.blob([0x53, 0x51, 0x4c]), .equal,
                    .blob([0x53, 0x51])) == false)
    #expect(compare(.blob([]), .equal, .blob([])) == true)
    #expect(compare(.blob([0x00]), .unequal, .blob([])) == true)
  }

  @Test func `blobs order lexicographically — memcmp over the bytes`() {
    // A byte difference decides: `0x01` < `0x02`.
    #expect(compare(.blob([0x01]), .lt, .blob([0x02])) == true)
    #expect(compare(.blob([0x02]), .lt, .blob([0x01])) == false)
    // A proper prefix orders before the longer string.
    #expect(compare(.blob([0x01]), .lt, .blob([0x01, 0x00])) == true)
    #expect(compare(.blob([]), .lt, .blob([0x00])) == true)
    // A high byte outweighs a longer tail.
    #expect(compare(.blob([0x02]), .gt, .blob([0x01, 0xff])) == true)
  }

  @Test func `the boundary relations follow the lexicographic order`() {
    #expect(compare(.blob([0x01]), .leq, .blob([0x01])) == true)
    #expect(compare(.blob([0x01]), .leq, .blob([0x02])) == true)
    #expect(compare(.blob([0x02]), .leq, .blob([0x01])) == false)
    #expect(compare(.blob([0x02]), .geq, .blob([0x01])) == true)
    #expect(compare(.blob([0x01]), .geq, .blob([0x02])) == false)
  }
}

// MARK: - Cross-type

@Suite
private struct CrossTypeComparisonTests {
  @Test func `unlike types never match — no coercion`() {
    // Every non-null cross-type pair falls to the switch's `default: false`.
    #expect(compare(.boolean(true), .equal, .integer(1)) == false)
    #expect(compare(.integer(1), .equal, .boolean(true)) == false)
    #expect(compare(.boolean(false), .equal, .integer(0)) == false)
    #expect(compare(.blob([0x41]), .equal, .text("A")) == false)
    #expect(compare(.text("A"), .equal, .blob([0x41])) == false)
    #expect(compare(.blob([0x01]), .lt, .integer(2)) == false)
    #expect(compare(.boolean(true), .lt, .text("z")) == false)
  }

  @Test func `a NULL operand is UNKNOWN, not false`() {
    #expect(compare(.boolean(true), .equal, .null) == nil)
    #expect(compare(.blob([0x01]), .lt, .null) == nil)
  }
}
