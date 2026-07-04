// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

@Suite struct RoutineTests {
  @Test("a routine's return type defaults to integer")
  func defaultReturn() {
    #expect(Routine(parameters: []) { _ in .integer(0) }.returns == .integer)
  }

  @Test("a routine carries its declared return type")
  func declaredReturn() {
    #expect(Routine(returns: .text, parameters: []) { _ in .text("x") }
                .returns == .text)
  }

  @Test("a routine carries its declared parameter contract")
  func declaredParameters() {
    let routine = Routine(parameters: [.integer, .text]) { _ in .integer(0) }
    #expect(routine.parameters == [.integer, .text])
  }

  @Test("a routine is called to compute a value")
  func callable() throws {
    let double = Routine(parameters: [.integer]) { arguments in
      guard case let .integer(x) = arguments[0] else { return .null }
      return .integer(x * 2)
    }
    #expect(try double([.integer(21)]) == .integer(42))
  }

  @Test("a Routine literal registers its declared signature")
  func routineLiteral() {
    // A client's documented shape: the literal value is a `Routine`, so each
    // registration declares its full signature — its parameters and return
    // type.
    let routines: Routines =
        ["upper": Routine(returns: .text, parameters: [.text]) {
          _ in .text("X")
        }]
    #expect(routines["upper"]?.returns == .text)
    #expect(routines["upper"]?.parameters == [.text])
  }

  @Test("registering declares a signature, the return defaulting to integer")
  func registering() {
    let routines = Routines()
        .registering("t", returns: .text, parameters: [.text]) {
          _ in .text("x")
        }
        .registering("i", parameters: [.integer]) { _ in .integer(0) }
    #expect(routines["t"]?.returns == .text)
    #expect(routines["i"]?.returns == .integer)
  }

  @Test("the name subscript resolves case-insensitively")
  func lookup() {
    let routines: Routines =
        ["Tag": Routine(returns: .text, parameters: []) { _ in .text("x") }]
    #expect(routines["TAG"] != nil)
    #expect(routines["nope"] == nil)
  }

  @Test("the standard prelude declares BITAND over two integers")
  func standardBitand() {
    #expect(Routines.standard["bitand"]?.returns == .integer)
    #expect(Routines.standard["bitand"]?.parameters == [.integer, .integer])
  }
}
