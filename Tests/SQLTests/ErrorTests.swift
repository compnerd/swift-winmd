// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

/// A throwaway location for cases that carry one.
private let here = SourceLocation(line: 1, column: 1, offset: 0)

@Suite("SQLSTATE")
struct SQLStateTests {
  @Test("an undefined column reports 42703")
  func column() {
    #expect(SQLError.column("Missing").sqlstate == "42703")
  }

  @Test("an integer overflow reports 22003")
  func magnitude() {
    #expect(SQLError.magnitude("integer overflow").sqlstate == "22003")
    // The lexer's out-of-range literal is the same data exception.
    #expect(SQLError.overflow("99", at: here).sqlstate == "22003")
  }

  @Test("a division by zero reports 22012")
  func divide() {
    #expect(SQLError.divide.sqlstate == "22012")
  }

  @Test("a syntax error reports 42601")
  func syntax() {
    #expect(SQLError.character("@", at: here).sqlstate == "42601")
    #expect(SQLError.unterminated(at: here).sqlstate == "42601")
    #expect(
        SQLError.unexpected("X", expected: "Y", at: here).sqlstate == "42601")
    #expect(SQLError.incomplete(expected: "Z").sqlstate == "42601")
    #expect(SQLError.trailing(at: here).sqlstate == "42601")
    #expect(SQLError.named("SELECT *").sqlstate == "42601")
    #expect(SQLError.columns(expected: 2, got: 3).sqlstate == "42601")
    #expect(SQLError.arity(1, 2).sqlstate == "42601")
  }

  @Test("an undefined relation reports 42P01")
  func relation() {
    #expect(SQLError.relation("Absent").sqlstate == "42P01")
  }

  @Test("an ambiguous column reports 42702")
  func ambiguous() {
    #expect(SQLError.ambiguous("Name").sqlstate == "42702")
  }

  @Test("a duplicate column reports 42701")
  func duplicate() {
    #expect(SQLError.duplicate("Name").sqlstate == "42701")
  }

  @Test("an undefined function reports 42883")
  func function() {
    #expect(SQLError.function("missing").sqlstate == "42883")
  }

  @Test("a rejected function argument reports 22023")
  func argument() {
    #expect(SQLError.argument("bad").sqlstate == "22023")
  }

  @Test("a non-integer arithmetic operand reports 42804")
  func operand() {
    #expect(
        SQLError.operand("operands must be integers").sqlstate == "42804")
  }

  @Test(".state round-trips its code and message")
  func passthrough() {
    let error = SQLError.state("40001", "serialization failure")
    #expect(error.sqlstate == "40001")
    #expect(error.message == "serialization failure")
    #expect(error.description == "serialization failure")
  }

  @Test("message equals description for a semantic case")
  func message() {
    let error = SQLError.column("Missing")
    #expect(error.message == error.description)
    #expect(error.message == "no such column 'Missing'")
  }
}
