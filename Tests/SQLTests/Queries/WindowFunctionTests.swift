// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport
import func SQLTestSupport.parse

/// The single projected expression of `sql`, recording an issue if the
/// projection is not one expression item.
private func projected(_ sql: String,
                       location: Testing.SourceLocation = #_sourceLocation)
    throws -> Expression {
  let select = try parse(select: sql, location: location)
  guard case let .expressions(items) = select.projection, items.count == 1
  else {
    Issue.record("expected a single projected expression",
                 sourceLocation: location)
    throw SQLError.incomplete(expected: "a projected expression")
  }
  return items[0].expression
}

// MARK: - Parsing

/// A window ranking function parses into an `Expression.window` carrying its
/// `WindowFunction` and the `OVER (…)` window specification — the empty
/// partition and absent order of a bare `OVER ()`, a `PARTITION BY` key list,
/// and a window `ORDER BY` reusing the query `ORDER BY` grammar.
struct WindowFunctionParsingTests {
  @Test func `ROW_NUMBER over an empty window parses`() throws {
    #expect(try projected("SELECT ROW_NUMBER() OVER () FROM T")
                == .window(function: .rowNumber, spec: WindowSpec()))
  }

  @Test func `a PARTITION BY and ORDER BY window parses`() throws {
    let expected = Expression.window(
        function: .rank,
        spec: WindowSpec(partition: [.column(Column("d"))],
                         order: Order(keys: [Order.Key(column: Column("x"),
                                                       ascending: false)])))
    #expect(try projected(
        "SELECT RANK() OVER (PARTITION BY d ORDER BY x DESC) FROM T")
                == expected)
  }

  @Test func `a window with only an ORDER BY parses`() throws {
    let expected = Expression.window(
        function: .denseRank,
        spec: WindowSpec(order: Order(keys: [Order.Key(column: Column("x"))])))
    #expect(try projected("SELECT DENSE_RANK() OVER (ORDER BY x) FROM T")
                == expected)
  }

  @Test func `a window with a multi-key partition parses`() throws {
    let expected = Expression.window(
        function: .rowNumber,
        spec: WindowSpec(partition: [.column(Column("a")), .column(Column("b"))]))
    #expect(try projected(
        "SELECT ROW_NUMBER() OVER (PARTITION BY a, b) FROM T") == expected)
  }

  @Test func `window function names are case-insensitive`() throws {
    #expect(try projected("SELECT row_number() over () FROM T")
                == .window(function: .rowNumber, spec: WindowSpec()))
  }

  @Test func `a delimited window name stays a scalar call`() throws {
    // A delimited `"rank"` is an ordinary scalar-call name, not the window
    // ranking function, so it parses as a plain call rather than a window.
    #expect(try projected("SELECT \"rank\"() FROM T")
                == .call(name: "rank", arguments: []))
  }

  @Test func `a ranking function without OVER is a syntax error`() {
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT RANK() FROM T")
    }
  }

  @Test func `a ranking function rejects an argument`() {
    // The ranking functions take an empty argument list, so a non-empty one is
    // a syntax error (the `)` is expected immediately).
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT ROW_NUMBER(x) OVER () FROM T")
    }
  }
}

// MARK: - Resolution parity (run ≡ validate)

/// Until the executor lands, a window function is rejected with the 0A000
/// feature-not-supported diagnostic on BOTH the run and the validate paths, so
/// `columns(of:validate:true)` never advertises a schema the run cannot execute
/// (the run ≡ validate tripwire).
struct WindowFunctionRejectionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row(2)
      }
    }
  }

  @Test func `a projected window function faults 0A000 on the run`() throws {
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER (ORDER BY x) FROM T",
        fails: .state("0A000", "a window function is not supported"))
  }

  @Test func `a projected window function faults 0A000 on validate`() {
    #expect(throws:
        SQLError.state("0A000", "a window function is not supported")) {
      let query =
          try parse(query: "SELECT ROW_NUMBER() OVER (ORDER BY x) FROM T")
      _ = try fixture().columns(of: query, validate: true)
    }
  }
}
