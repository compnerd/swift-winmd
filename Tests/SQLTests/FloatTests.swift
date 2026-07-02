// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - Harness

/// A one-cell row that yields a fixed `Value` at slot `0` — the minimal `Row`
/// that drives the comparison and arithmetic choke points (`matches` and
/// `Arithmetic.apply`, reached through `evaluate`) over a `double` cell without
/// a whole relation.
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
  try! evaluate(.compare(.slot(0), op, .constant(constant)),
                Cell(cell), Routines(), [:])
}

/// Evaluates `lhs op rhs` through the engine's arithmetic — a typed `Value`, or
/// a thrown `SQLError` (a divide by zero, a non-numeric operand).
private func arithmetic(_ lhs: Value, _ op: Arithmetic,
                        _ rhs: Value) throws(SQLError) -> Value {
  try evaluate(.binary(op, .constant(lhs), .constant(rhs)),
               Cell(.null), Routines())
}

// MARK: - Comparison

@Suite("DOUBLE comparison")
private struct DoubleComparisonTests {
  @Test("like doubles compare by magnitude")
  func equality() {
    #expect(compare(.double(1.5), .equal, .double(1.5)) == true)
    #expect(compare(.double(1.5), .equal, .double(2.5)) == false)
    #expect(compare(.double(1.5), .unequal, .double(2.5)) == true)
  }

  @Test("doubles order by magnitude")
  func ordering() {
    #expect(compare(.double(1.5), .lt, .double(2.5)) == true)
    #expect(compare(.double(2.5), .lt, .double(1.5)) == false)
    #expect(compare(.double(2.5), .gt, .double(1.5)) == true)
    #expect(compare(.double(1.5), .leq, .double(1.5)) == true)
    #expect(compare(.double(2.5), .geq, .double(2.5)) == true)
  }
}

// MARK: - Mixed integer/double

@Suite("mixed integer/double comparison")
private struct MixedComparisonTests {
  @Test("an integer equals a like-valued double — numeric, not cross-type")
  func numericEquality() {
    // Both operands are numeric, so `1 = 1.0` is TRUE, not a cross-kind miss.
    #expect(compare(.integer(1), .equal, .double(1.0)) == true)
    #expect(compare(.double(1.0), .equal, .integer(1)) == true)
    #expect(compare(.integer(2), .equal, .double(2.5)) == false)
    #expect(compare(.integer(1), .unequal, .double(1.5)) == true)
  }

  @Test("an integer orders against a double by magnitude")
  func numericOrdering() {
    #expect(compare(.integer(1), .lt, .double(1.5)) == true)
    #expect(compare(.double(1.5), .gt, .integer(1)) == true)
    #expect(compare(.integer(2), .lt, .double(1.5)) == false)
    #expect(compare(.double(0.5), .lt, .integer(1)) == true)
  }
}

// MARK: - Arithmetic

@Suite("DOUBLE arithmetic")
private struct DoubleArithmeticTests {
  @Test("double arithmetic yields a double")
  func likeTyped() throws {
    #expect(try arithmetic(.double(1.5), .add, .double(2.0)) == .double(3.5))
    #expect(try arithmetic(.double(2.5), .subtract, .double(1.0))
                == .double(1.5))
    #expect(try arithmetic(.double(1.5), .multiply, .double(2.0))
                == .double(3.0))
  }

  @Test("double division is real, not truncated")
  func realDivision() throws {
    #expect(try arithmetic(.double(5.0), .divide, .double(2.0))
                == .double(2.5))
  }

  @Test("a mixed integer/double is numeric and yields a double")
  func mixed() throws {
    // `5 / 2.0` is real division `2.5`, and `2 * 1.5` is `3.0` — the integer
    // promotes to `Double`, so the result is approximate-numeric.
    #expect(try arithmetic(.integer(5), .divide, .double(2.0))
                == .double(2.5))
    #expect(try arithmetic(.integer(2), .multiply, .double(1.5))
                == .double(3.0))
    #expect(try arithmetic(.double(1.5), .add, .integer(1))
                == .double(2.5))
  }

  @Test("an integer pair still divides as integers")
  func integerDivisionUnchanged() throws {
    // The mixed-numeric widening does not touch the exact-numeric path: `5 / 2`
    // is still `2`, not `2.5`.
    #expect(try arithmetic(.integer(5), .divide, .integer(2)) == .integer(2))
  }

  @Test("a double divide by zero raises, matching the integer policy")
  func divideByZero() {
    #expect(throws: SQLError.divide) {
      try arithmetic(.double(1.0), .divide, .double(0.0))
    }
    #expect(throws: SQLError.divide) {
      try arithmetic(.double(1.0), .divide, .integer(0))
    }
  }

  @Test("a non-finite double result is rejected, never returned")
  func nonFinite() {
    // An overflow to `inf` (a magnitude past `Double`'s range) faults rather
    // than returning `inf`.
    #expect(throws: SQLError.self) {
      try arithmetic(.double(1e308), .multiply, .double(1e308))
    }
    // A NaN from an indeterminate form (`inf - inf`) faults — never returned,
    // since NaN is unequal to itself and would break dedup and ordering.
    #expect(throws: SQLError.self) {
      try arithmetic(.double(.infinity), .subtract, .double(.infinity))
    }
  }

  @Test("a non-finite double literal is rejected at lowering")
  func nonFiniteLiteral() throws {
    // A directly-built `Literal.double(.nan/.infinity)` (the lexer never makes
    // one) is rejected when lowered to a `Value`, so no non-finite double
    // enters a plan; a finite literal lowers unchanged.
    #expect(throws: SQLError.self) { _ = try value(of: .double(.nan)) }
    #expect(throws: SQLError.self) { _ = try value(of: .double(.infinity)) }
    let finite = try value(of: .double(1.5))
    #expect(finite == .double(1.5))
  }

  @Test("a routine returning a non-finite double is rejected")
  func nonFiniteRoutine() {
    // A registered routine is a public `Value` producer that bypasses the
    // literal/arithmetic checks; a NaN or inf result is rejected at the call
    // boundary so it never reaches dedup, ordering, or a recursive UNION.
    let routines: Routines = ["nan": { _ in .double(.nan) },
                              "huge": { _ in .double(.infinity) }]
    #expect(throws: SQLError.self) {
      try evaluate(.apply(name: "nan", arguments: []), Cell(.null), routines)
    }
    #expect(throws: SQLError.self) {
      try evaluate(.apply(name: "huge", arguments: []), Cell(.null), routines)
    }
  }
}

// MARK: - NULL

@Suite("DOUBLE NULL propagation")
private struct DoubleNullTests {
  @Test("a NULL operand is UNKNOWN in a comparison")
  func comparison() {
    #expect(compare(.double(1.5), .equal, .null) == nil)
    #expect(compare(.double(1.5), .lt, .null) == nil)
  }

  @Test("a NULL operand propagates through arithmetic")
  func propagation() throws {
    #expect(try arithmetic(.double(1.5), .add, .null) == .null)
    #expect(try arithmetic(.null, .multiply, .double(1.5)) == .null)
  }
}

// MARK: - Sort

@Suite("DOUBLE sort ordering")
private struct DoubleSortTests {
  @Test("doubles sort ascending by magnitude, NULL first")
  func ordering() {
    // `less` is the sort primitive: NULL precedes every value, and two doubles
    // order by magnitude.
    #expect(less(.double(1.5), .double(2.5)) == true)
    #expect(less(.double(2.5), .double(1.5)) == false)
    #expect(less(.null, .double(1.5)) == true)
    #expect(less(.double(1.5), .null) == false)
  }

  @Test("a mixed integer/double slot sorts by magnitude")
  func mixed() {
    // A slot that happens to mix exact and approximate numerics still orders by
    // magnitude rather than tying at the kind boundary.
    #expect(less(.integer(1), .double(1.5)) == true)
    #expect(less(.double(1.5), .integer(2)) == true)
    #expect(less(.double(2.5), .integer(2)) == false)
  }

  @Test("a double past Int.max still orders against Int.max, not a false tie")
  func beyondIntRange() {
    // `Double(Int.max)` rounds to 2^63, past `Int` — but `Int.max` (2^63 - 1)
    // is still strictly less, so the pair orders one way, never false both ways
    // (which would leave MIN/MAX and sort order-dependent).
    #expect(less(.integer(.max), .double(Double(Int.max))) == true)
    #expect(less(.double(Double(Int.max)), .integer(.max)) == false)
  }
}

// MARK: - Literal

@Suite("DOUBLE literal parsing")
private struct DoubleLiteralTests {
  @Test("a decimal literal lowers to a double value")
  func fraction() throws {
    let lowered = try value(of: .double(3.14))
    #expect(lowered == .double(3.14))
  }

  @Test("an integer literal stays an integer value")
  func integer() throws {
    let lowered = try value(of: .integer(3))
    #expect(lowered == .integer(3))
  }
}
