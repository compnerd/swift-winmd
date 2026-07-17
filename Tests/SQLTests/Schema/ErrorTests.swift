// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

/// A throwaway location for cases that carry one.
private let here = SourceLocation(line: 1, column: 1, offset: 0)

@Suite
struct SQLStateTests {
  @Test func `an undefined column reports 42703`() {
    #expect(SQLError.column("Missing").sqlstate == "42703")
  }

  @Test func `an integer overflow reports 22003`() {
    #expect(SQLError.magnitude("integer overflow").sqlstate == "22003")
    // The lexer's out-of-range literal is the same data exception.
    #expect(SQLError.overflow("99", at: here).sqlstate == "22003")
  }

  @Test func `a division by zero reports 22012`() {
    #expect(SQLError.divide.sqlstate == "22012")
  }

  @Test func `a syntax error reports 42601`() {
    #expect(SQLError.character("@", at: here).sqlstate == "42601")
    #expect(SQLError.unterminated("string literal", at: here).sqlstate
                == "42601")
    #expect(
        SQLError.unexpected("X", expected: "Y", at: here).sqlstate == "42601")
    #expect(SQLError.incomplete(expected: "Z").sqlstate == "42601")
    #expect(SQLError.trailing(at: here).sqlstate == "42601")
    #expect(SQLError.named("SELECT *").sqlstate == "42601")
    #expect(SQLError.columns(expected: 2, got: 3).sqlstate == "42601")
    #expect(SQLError.arity(1, 2).sqlstate == "42601")
  }

  @Test func `an undefined relation reports 42P01`() {
    #expect(SQLError.relation("Absent").sqlstate == "42P01")
  }

  @Test func `an ambiguous column reports 42702`() {
    #expect(SQLError.ambiguous("Name").sqlstate == "42702")
  }

  @Test func `a duplicate column reports 42701`() {
    #expect(SQLError.duplicate("Name").sqlstate == "42701")
  }

  @Test func `an undefined function reports 42883`() {
    #expect(SQLError.function("missing").sqlstate == "42883")
  }

  @Test func `a rejected function argument reports 22023`() {
    #expect(SQLError.argument("bad").sqlstate == "22023")
  }

  @Test func `a non-numeric arithmetic operand reports 42804`() {
    #expect(
        SQLError.operand("operands must be numeric").sqlstate == "42804")
  }

  @Test func `an engine-specific condition reports the SwiftSQL SS class`() {
    // Engine-specific faults with no standard ISO code squat on the
    // implementation-defined `SS` (SwiftSQL) class rather than borrow a
    // standard one.
    #expect(SQLError.unsupported("SELECT * requires a FROM clause").sqlstate
            == "SS001")
    #expect(SQLError.statement("CREATE VIEW is not a query").sqlstate
            == "SS002")
    #expect(SQLError.recursion("loop").sqlstate == "SS003")
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
