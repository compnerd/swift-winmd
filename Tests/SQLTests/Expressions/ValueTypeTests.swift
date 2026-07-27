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
/// `true`, `false`, or `nil` (UNKNOWN) — the path a real `WHERE` takes. An
/// incomparable pair faults `42804`, so this is throwing.
private func compare(_ cell: Value, _ op: Comparison,
                     _ constant: Value) throws(SQLError) -> Bool? {
  try Cell(cell).evaluate(.compare(.slot(0), op, .constant(constant)),
                          Routines(), [:])
}

/// Whether evaluating `cell op constant` faults the ISO comparability error
/// `42804` — an incomparable cross-kind pair.
private func incomparable(_ cell: Value, _ op: Comparison,
                          _ constant: Value) -> Bool {
  do {
    _ = try compare(cell, op, constant)
    return false
  } catch {
    if case .state("42804", _) = error { return true }
    return false
  }
}

// MARK: - Boolean

@Suite
private struct BooleanValueTests {
  @Test func `false orders before true`() throws {
    #expect(try compare(.boolean(false), .lt, .boolean(true)) == true)
    #expect(try compare(.boolean(true), .lt, .boolean(false)) == false)
    #expect(try compare(.boolean(false), .lt, .boolean(false)) == false)
    #expect(try compare(.boolean(true), .gt, .boolean(false)) == true)
  }

  @Test func `like booleans compare equal`() throws {
    #expect(try compare(.boolean(true), .equal, .boolean(true)) == true)
    #expect(try compare(.boolean(true), .equal, .boolean(false)) == false)
    #expect(try compare(.boolean(false), .unequal, .boolean(true)) == true)
  }

  @Test func `the boundary relations follow the false < true order`() throws {
    #expect(try compare(.boolean(false), .leq, .boolean(false)) == true)
    #expect(try compare(.boolean(false), .leq, .boolean(true)) == true)
    #expect(try compare(.boolean(true), .leq, .boolean(false)) == false)
    #expect(try compare(.boolean(true), .geq, .boolean(true)) == true)
    #expect(try compare(.boolean(false), .geq, .boolean(true)) == false)
  }
}

// MARK: - Blob

@Suite
private struct BlobValueTests {
  @Test func `like blobs compare by byte equality`() throws {
    #expect(try compare(.blob([0x53, 0x51, 0x4c]), .equal,
                        .blob([0x53, 0x51, 0x4c])) == true)
    #expect(try compare(.blob([0x53, 0x51, 0x4c]), .equal,
                        .blob([0x53, 0x51])) == false)
    #expect(try compare(.blob([]), .equal, .blob([])) == true)
    #expect(try compare(.blob([0x00]), .unequal, .blob([])) == true)
  }

  @Test func `blobs order lexicographically — memcmp over the bytes`() throws {
    // A byte difference decides: `0x01` < `0x02`.
    #expect(try compare(.blob([0x01]), .lt, .blob([0x02])) == true)
    #expect(try compare(.blob([0x02]), .lt, .blob([0x01])) == false)
    // A proper prefix orders before the longer string.
    #expect(try compare(.blob([0x01]), .lt, .blob([0x01, 0x00])) == true)
    #expect(try compare(.blob([]), .lt, .blob([0x00])) == true)
    // A high byte outweighs a longer tail.
    #expect(try compare(.blob([0x02]), .gt, .blob([0x01, 0xff])) == true)
  }

  @Test func `the boundary relations follow the lexicographic order`() throws {
    #expect(try compare(.blob([0x01]), .leq, .blob([0x01])) == true)
    #expect(try compare(.blob([0x01]), .leq, .blob([0x02])) == true)
    #expect(try compare(.blob([0x02]), .leq, .blob([0x01])) == false)
    #expect(try compare(.blob([0x02]), .geq, .blob([0x01])) == true)
    #expect(try compare(.blob([0x01]), .geq, .blob([0x02])) == false)
  }
}

// MARK: - Cross-type

@Suite
private struct CrossTypeComparisonTests {
  @Test func `unlike types fault — the ISO comparability rule`() {
    // Every non-null cross-kind pair is a data-type mismatch (42804), not a
    // silent FALSE — the ISO rule a comparison's operands must be comparable.
    #expect(incomparable(.boolean(true), .equal, .integer(1)))
    #expect(incomparable(.integer(1), .equal, .boolean(true)))
    #expect(incomparable(.boolean(false), .equal, .integer(0)))
    #expect(incomparable(.blob([0x41]), .equal, .text("A")))
    #expect(incomparable(.text("A"), .equal, .blob([0x41])))
    #expect(incomparable(.blob([0x01]), .lt, .integer(2)))
    #expect(incomparable(.boolean(true), .lt, .text("z")))
  }

  @Test func `the fault names both operand domains`() {
    #expect(throws: SQLError.state("42804",
                                   "cannot compare boolean with integer")) {
      try compare(.boolean(true), .equal, .integer(1))
    }
  }

  @Test func `a NULL operand is UNKNOWN, not a fault`() throws {
    // NULL is comparable with anything — the comparison is UNKNOWN, never the
    // cross-kind fault, so three-valued logic is unchanged.
    #expect(try compare(.boolean(true), .equal, .null) == nil)
    #expect(try compare(.blob([0x01]), .lt, .null) == nil)
  }
}
