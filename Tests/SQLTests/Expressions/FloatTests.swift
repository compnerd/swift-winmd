// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

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
  try! Cell(cell).evaluate(.compare(.slot(0), op, .constant(constant)),
                           Routines(), [:])
}

/// Evaluates `lhs op rhs` through the engine's arithmetic — a typed `Value`, or
/// a thrown `SQLError` (a divide by zero, a non-numeric operand).
private func arithmetic(_ lhs: Value, _ op: Arithmetic,
                        _ rhs: Value) throws(SQLError) -> Value {
  try Cell(.null).evaluate(.binary(op, .constant(lhs), .constant(rhs)),
                           Routines())
}

private struct Comparing: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let lhs: Value
  internal let op: Comparison
  internal let rhs: Value
  internal let expected: Bool?

  internal var testDescription: String { name }
}

private let kDoubles: Array<Comparing> = [
  Comparing(name: "equal", lhs: .double(1.5), op: .equal,
            rhs: .double(1.5), expected: true),
  Comparing(name: "not equal", lhs: .double(1.5), op: .equal,
            rhs: .double(2.5), expected: false),
  Comparing(name: "unequal", lhs: .double(1.5), op: .unequal,
            rhs: .double(2.5), expected: true),
  Comparing(name: "less", lhs: .double(1.5), op: .lt,
            rhs: .double(2.5), expected: true),
  Comparing(name: "not less", lhs: .double(2.5), op: .lt,
            rhs: .double(1.5), expected: false),
  Comparing(name: "greater", lhs: .double(2.5), op: .gt,
            rhs: .double(1.5), expected: true),
  Comparing(name: "less or equal", lhs: .double(1.5), op: .leq,
            rhs: .double(1.5), expected: true),
  Comparing(name: "greater or equal", lhs: .double(2.5), op: .geq,
            rhs: .double(2.5), expected: true),
]

private let kMixed: Array<Comparing> = [
  Comparing(name: "integer equals double", lhs: .integer(1), op: .equal,
            rhs: .double(1.0), expected: true),
  Comparing(name: "double equals integer", lhs: .double(1.0), op: .equal,
            rhs: .integer(1), expected: true),
  Comparing(name: "unlike magnitudes", lhs: .integer(2), op: .equal,
            rhs: .double(2.5), expected: false),
  Comparing(name: "mixed inequality", lhs: .integer(1), op: .unequal,
            rhs: .double(1.5), expected: true),
  Comparing(name: "integer less than double", lhs: .integer(1), op: .lt,
            rhs: .double(1.5), expected: true),
  Comparing(name: "double greater than integer", lhs: .double(1.5), op: .gt,
            rhs: .integer(1), expected: true),
  Comparing(name: "integer not less than double", lhs: .integer(2), op: .lt,
            rhs: .double(1.5), expected: false),
  Comparing(name: "double less than integer", lhs: .double(0.5), op: .lt,
            rhs: .integer(1), expected: true),
]

private struct Calculating: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let lhs: Value
  internal let op: Arithmetic
  internal let rhs: Value
  internal let expected: Value

  internal var testDescription: String { name }
}

private let kArithmetic: Array<Calculating> = [
  Calculating(name: "double addition", lhs: .double(1.5), op: .add,
              rhs: .double(2.0), expected: .double(3.5)),
  Calculating(name: "double subtraction", lhs: .double(2.5), op: .subtract,
              rhs: .double(1.0), expected: .double(1.5)),
  Calculating(name: "double multiplication", lhs: .double(1.5), op: .multiply,
              rhs: .double(2.0), expected: .double(3.0)),
  Calculating(name: "real division", lhs: .double(5.0), op: .divide,
              rhs: .double(2.0), expected: .double(2.5)),
  Calculating(name: "mixed division", lhs: .integer(5), op: .divide,
              rhs: .double(2.0), expected: .double(2.5)),
  Calculating(name: "mixed multiplication", lhs: .integer(2), op: .multiply,
              rhs: .double(1.5), expected: .double(3.0)),
  Calculating(name: "mixed addition", lhs: .double(1.5), op: .add,
              rhs: .integer(1), expected: .double(2.5)),
  Calculating(name: "integer division", lhs: .integer(5), op: .divide,
              rhs: .integer(2), expected: .integer(2)),
]

private struct Sorting: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let lhs: Value
  internal let rhs: Value
  internal let expected: Bool

  internal var testDescription: String { name }
}

private let kSorting: Array<Sorting> = [
  Sorting(name: "ascending doubles", lhs: .double(1.5), rhs: .double(2.5),
          expected: true),
  Sorting(name: "descending doubles", lhs: .double(2.5), rhs: .double(1.5),
          expected: false),
  Sorting(name: "NULL first", lhs: .null, rhs: .double(1.5), expected: true),
  Sorting(name: "double after NULL", lhs: .double(1.5), rhs: .null,
          expected: false),
  Sorting(name: "integer before double", lhs: .integer(1), rhs: .double(1.5),
          expected: true),
  Sorting(name: "double before integer", lhs: .double(1.5), rhs: .integer(2),
          expected: true),
  Sorting(name: "double after integer", lhs: .double(2.5), rhs: .integer(2),
          expected: false),
]

private struct Lowering: Sendable, CustomTestStringConvertible {
  internal let literal: Literal
  internal let expected: Value

  internal var testDescription: String { "\(literal)" }
}

private let kLiterals: Array<Lowering> = [
  Lowering(literal: .double(3.14), expected: .double(3.14)),
  Lowering(literal: .integer(3), expected: .integer(3)),
]

// MARK: - Comparison

@Suite
private struct DoubleComparisonTests {
  @Test(arguments: kDoubles)
  fileprivate func compares(_ test: Comparing) {
    #expect(compare(test.lhs, test.op, test.rhs) == test.expected)
  }
}

// MARK: - Mixed integer/double

@Suite
private struct MixedNumericComparisonTests {
  @Test(arguments: kMixed)
  fileprivate func compares(_ test: Comparing) {
    #expect(compare(test.lhs, test.op, test.rhs) == test.expected)
  }
}

// MARK: - Arithmetic

@Suite
private struct DoubleArithmeticTests {
  @Test(arguments: kArithmetic)
  fileprivate func calculates(_ test: Calculating) throws {
    #expect(try arithmetic(test.lhs, test.op, test.rhs) == test.expected)
  }

  @Test func `a double divide by zero raises, matching the integer policy`() {
    #expect(throws: SQLError.divide) {
      try arithmetic(.double(1.0), .divide, .double(0.0))
    }
    #expect(throws: SQLError.divide) {
      try arithmetic(.double(1.0), .divide, .integer(0))
    }
  }

  @Test func `a non-finite double result is rejected, never returned`() {
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

  @Test func `a non-finite double literal is rejected at lowering`() throws {
    // A directly-built `Literal.double(.nan/.infinity)` (the lexer never makes
    // one) is rejected when lowered to a `Value`, so no non-finite double
    // enters a plan; a finite literal lowers unchanged.
    #expect(throws: SQLError.self) { _ = try value(of: .double(.nan)) }
    #expect(throws: SQLError.self) { _ = try value(of: .double(.infinity)) }
    let finite = try value(of: .double(1.5))
    #expect(finite == .double(1.5))
  }

  @Test func `a routine returning a non-finite double is rejected`() {
    // A registered routine is a public `Value` producer that bypasses the
    // literal/arithmetic checks; a NaN or inf result is rejected at the call
    // boundary so it never reaches dedup, ordering, or a recursive UNION.
    let routines: Routines =
        ["nan": Routine(returns: .double, parameters: []) {
          _ in .double(.nan)
        },
         "huge": Routine(returns: .double, parameters: []) {
          _ in .double(.infinity)
        }]
    #expect(throws: SQLError.self) {
      try Cell(.null).evaluate(.apply(name: "nan", arguments: []), routines)
    }
    #expect(throws: SQLError.self) {
      try Cell(.null).evaluate(.apply(name: "huge", arguments: []), routines)
    }
  }
}

// MARK: - NULL

@Suite
private struct DoubleNullTests {
  @Test func `a NULL operand is UNKNOWN in a comparison`() {
    #expect(compare(.double(1.5), .equal, .null) == nil)
    #expect(compare(.double(1.5), .lt, .null) == nil)
  }

  @Test func `a NULL operand propagates through arithmetic`() throws {
    #expect(try arithmetic(.double(1.5), .add, .null) == .null)
    #expect(try arithmetic(.null, .multiply, .double(1.5)) == .null)
  }
}

// MARK: - Sort

@Suite
private struct DoubleSortTests {
  @Test(arguments: kSorting)
  fileprivate func sorts(_ test: Sorting) {
    #expect(less(test.lhs, test.rhs) == test.expected)
  }

  @Test func `a double past Int.max still orders against Int.max, not a false tie`() {
    // `Double(Int.max)` rounds to 2^63, past `Int` — but `Int.max` (2^63 - 1)
    // is still strictly less, so the pair orders one way, never false both ways
    // (which would leave MIN/MAX and sort order-dependent).
    #expect(less(.integer(.max), .double(Double(Int.max))) == true)
    #expect(less(.double(Double(Int.max)), .integer(.max)) == false)
  }
}

// MARK: - Literal

@Suite
private struct DoubleLiteralTests {
  @Test(arguments: kLiterals)
  fileprivate func lowers(_ test: Lowering) throws {
    #expect(try value(of: test.literal) == test.expected)
  }
}
