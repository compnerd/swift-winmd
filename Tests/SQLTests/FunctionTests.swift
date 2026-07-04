// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

@Suite struct RoutineTests {
  @Test("a routine's return type defaults to integer")
  func defaultReturn() {
    #expect(Routine { _ in .integer(0) }.returns == .integer)
  }

  @Test("a routine carries its declared return type")
  func declaredReturn() {
    #expect(Routine(returns: .text) { _ in .text("x") }.returns == .text)
  }

  @Test("a routine is called to compute a value")
  func callable() throws {
    let double = Routine { arguments in
      guard case let .integer(x) = arguments[0] else { return .null }
      return .integer(x * 2)
    }
    #expect(try double([.integer(21)]) == .integer(42))
  }

  @Test("a bare-closure literal registers an integer-returning routine")
  func bareClosureLiteral() {
    // A client's documented shape: a bare closure with no declared return type
    // registers a routine returning the `.integer` default.
    let routines: Routines = ["upper": { _ in .text("X") }]
    #expect(routines["upper"]?.returns == .integer)
  }

  @Test("registering declares a return type, defaulting to integer")
  func registering() {
    let routines = Routines()
        .registering("t", returns: .text) { _ in .text("x") }
        .registering("i") { _ in .integer(0) }
    #expect(routines.returns == ["t": .text, "i": .integer])
  }

  @Test("the name subscript resolves case-insensitively")
  func lookup() {
    let routines: Routines = ["Tag": { _ in .text("x") }]
    #expect(routines["TAG"] != nil)
    #expect(routines["nope"] == nil)
  }

  @Test("the standard prelude declares BITAND returning an integer")
  func standardBitand() {
    #expect(Routines.standard.returns == ["bitand": .integer])
  }
}
