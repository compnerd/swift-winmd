// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

private func parse(query text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

@Suite struct ScalarCallInventoryTests {
  @Test("a bare-column query names no calls")
  func none() throws {
    #expect(try parse(query: "SELECT a, b FROM t").calls == [])
  }

  @Test("a projected call is named")
  func projection() throws {
    #expect(try parse(query: "SELECT f(a) AS x FROM t").calls == ["f"])
  }

  @Test("calls nested in arguments and arithmetic are all named")
  func nested() throws {
    let calls = try parse(query: "SELECT f(g(a) + h(b)) AS x FROM t").calls
    #expect(calls == ["f", "g", "h"])
  }

  @Test("a call in the WHERE is named")
  func predicate() throws {
    #expect(try parse(query: "SELECT a FROM t WHERE f(a) = 1").calls == ["f"])
  }

  @Test("a call in the HAVING is named")
  func having() throws {
    let calls = try parse(query: """
        SELECT a FROM t GROUP BY a HAVING f(a) = 1
        """).calls
    #expect(calls == ["f"])
  }

  @Test("a call in a later UNION arm is named")
  func laterArm() throws {
    let calls = try parse(query: """
        SELECT a FROM t UNION SELECT f(b) FROM u
        """).calls
    #expect(calls == ["f"])
  }

  @Test("a call in an aggregate operand is named")
  func aggregateOperand() throws {
    #expect(try parse(query: "SELECT SUM(f(a)) FROM t").calls == ["f"])
  }
}
