// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

/// A throwaway location for cases that carry one.
private let kHere = SourceLocation(line: 1, column: 1, offset: 0)

private struct State: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let error: SQLError
  internal let expected: String

  internal var testDescription: String { name }
}

private let kStates: Array<State> = [
  State(name: "undefined column", error: .column("Missing"),
        expected: "42703"),
  State(name: "integer magnitude overflow",
        error: .magnitude("integer overflow"), expected: "22003"),
  State(name: "integer literal overflow", error: .overflow("99", at: kHere),
        expected: "22003"),
  State(name: "division by zero", error: .divide, expected: "22012"),
  State(name: "invalid character", error: .character("@", at: kHere),
        expected: "42601"),
  State(name: "unterminated token",
        error: .unterminated("string literal", at: kHere),
        expected: "42601"),
  State(name: "unexpected token",
        error: .unexpected("X", expected: "Y", at: kHere),
        expected: "42601"),
  State(name: "incomplete statement", error: .incomplete(expected: "Z"),
        expected: "42601"),
  State(name: "trailing input", error: .trailing(at: kHere),
        expected: "42601"),
  State(name: "unnamed projection", error: .named("SELECT *"),
        expected: "42601"),
  State(name: "column-count mismatch", error: .columns(expected: 2, got: 3),
        expected: "42601"),
  State(name: "arity mismatch", error: .arity(1, 2), expected: "42601"),
  State(name: "undefined relation", error: .relation("Absent"),
        expected: "42P01"),
  State(name: "ambiguous column", error: .ambiguous("Name"),
        expected: "42702"),
  State(name: "duplicate column", error: .duplicate("Name"),
        expected: "42701"),
  State(name: "undefined function", error: .function("missing"),
        expected: "42883"),
  State(name: "rejected function argument", error: .argument("bad"),
        expected: "22023"),
  State(name: "non-numeric operand",
        error: .operand("operands must be numeric"), expected: "42804"),
  State(name: "unsupported shape",
        error: .unsupported("SELECT * requires a FROM clause"),
        expected: "SS001"),
  State(name: "wrong statement kind",
        error: .statement("CREATE VIEW is not a query"), expected: "SS002"),
  State(name: "recursion", error: .recursion("loop"), expected: "SS003"),
]

@Suite
struct SQLStateTests {
  @Test(arguments: kStates)
  fileprivate func reports(_ test: State) {
    #expect(test.error.sqlstate == test.expected)
  }

  @Test func `.state round-trips its code and message`() {
    let error = SQLError.state("40001", "serialization failure")
    #expect(error.sqlstate == "40001")
    #expect(error.message == "serialization failure")
    #expect(error.description == "serialization failure")
  }

  @Test func `message equals description for a semantic case`() {
    let error = SQLError.column("Missing")
    #expect(error.message == error.description)
    #expect(error.message == "no such column 'Missing'")
  }
}

/// A small relation for driving real queries whose faults were reclassified off
/// the generic `.unsupported` (`SS001`) onto precise ISO SQLSTATE codes. These
/// pin the mapping end-to-end — a query raises, and its `.sqlstate` is the
/// intended code — rather than only the `SQLError` case in isolation.
private func table() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

/// Runs `sql` against `catalog` and returns the SQLSTATE it raises, or `nil` if
/// the run succeeds. Eager rather than `#expect(throws:)`'d — a borrowed
/// `~Escapable` catalog cannot cross an escaping closure.
private func sqlstate(_ sql: String, _ catalog: borrowing FixtureCatalog)
    -> String? {
  do {
    guard case let .select(query) = try Statement(parsing: sql) else {
      return nil
    }
    _ = try catalog.run(query)
    return nil
  } catch let fault {
    return fault.sqlstate
  }
}

@Suite
struct ReclassifiedSQLStateTests {
  @Test func `an empty IN list reports 42601`() throws {
    // A `Predicate.membership` with an empty list, built directly to bypass the
    // parser's `IN ()` rejection, is a syntax error rather than a generic
    // unsupported shape.
    let empty = Query.select(Select(projection: .columns([Column(name: "Id")]),
                                    from: Relation(name: "T"),
                                    predicate: .membership(.column("Id"), [],
                                                           negated: false)))
    let catalog = try table()
    let raised: SQLError?
    do {
      _ = try catalog.run(empty)
      raised = nil
    } catch let fault {
      raised = fault
    }
    #expect(raised?.sqlstate == "42601")
  }

  @Test func `an aggregate in a WHERE reports 42803`() throws {
    #expect(sqlstate("SELECT Id FROM T WHERE COUNT(*) > 1 GROUP BY Id",
                     try table()) == "42803")
  }

  @Test func `a negative OFFSET reports 2201X`() throws {
    // The parser cannot spell a negative count, so drive it through a direct
    // `Limit` the executor would otherwise trap on.
    let select = Select(projection: .columns([Column(name: "Id")]),
                        from: Relation(name: "T"),
                        limit: Limit(count: 1, offset: -1))
    let negative = Query.select(select)
    let catalog = try table()
    let raised: SQLError?
    do {
      _ = try catalog.run(negative)
      raised = nil
    } catch let fault {
      raised = fault
    }
    #expect(raised?.sqlstate == "2201X")
  }

  @Test func `a RIGHT LATERAL join reports 0A000`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
      }
    }
    #expect(sqlstate("SELECT T.Id, d.x FROM T RIGHT JOIN LATERAL " +
                     "(SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1",
                     catalog) == "0A000")
  }
}
