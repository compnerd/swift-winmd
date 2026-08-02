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

// MARK: - ROW_NUMBER execution

/// `ROW_NUMBER() OVER (…)` numbers each row 1-based within its partition, in the
/// window's order, appending the number to every source row (cardinality-
/// preserving). Its `columns(of:)` schema advertises the integer window column
/// in parity with the run.
struct RowNumberExecutionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(1, 30)
        Row(2, 20)
        Row(1, 20)
      }
    }
  }

  @Test func `ROW_NUMBER numbers each partition in the window order`() throws {
    // d=1 rows ordered by x (10, 20, 30) number 1, 2, 3; d=2's lone row is 1.
    // The output keeps the source row order, each row gaining its number.
    try fixture().expect(
        "SELECT d, x, ROW_NUMBER() OVER (PARTITION BY d ORDER BY x) FROM T",
        yields: [[1, 10, 1], [1, 30, 3], [2, 20, 1], [1, 20, 2]])
  }

  @Test func `ROW_NUMBER over one partition numbers every row`() throws {
    // No PARTITION BY: the whole input is one partition, ordered by x — the two
    // x=20 rows tie but ROW_NUMBER is still distinct, keeping their input order.
    try fixture().expect(
        "SELECT x, ROW_NUMBER() OVER (ORDER BY x) FROM T",
        yields: [[10, 1], [30, 4], [20, 2], [20, 3]])
  }

  @Test func `a query ORDER BY sorts the numbered rows`() throws {
    try fixture().expect(
        """
        SELECT x, ROW_NUMBER() OVER (ORDER BY x) AS rn FROM T ORDER BY rn DESC
        """,
        yields: [[30, 4], [20, 3], [20, 2], [10, 1]])
  }

  @Test func `an empty partition yields no rows`() throws {
    let catalog = try Catalog { Relation("T", ["x": .integer]) {} }
    try catalog.empty("SELECT ROW_NUMBER() OVER (ORDER BY x) FROM T")
  }

  @Test func `the schema advertises the integer window column`() throws {
    let query = try parse(query:
        "SELECT x, ROW_NUMBER() OVER (ORDER BY x) AS rn FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x", "rn"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }
}

// MARK: - Resolution parity (run ≡ validate)

/// A window function the executor does not yet compute, or one written outside
/// the SELECT list and `ORDER BY`, is rejected with the 0A000 feature
/// diagnostic on BOTH the run and the validate paths, so `columns(of:
/// validate:true)` never advertises a schema the run cannot execute (the run ≡
/// validate tripwire).
struct WindowFunctionRejectionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row(2)
      }
    }
  }

  private func rejects(_ sql: String, _ fault: SQLError,
                       location: Testing.SourceLocation = #_sourceLocation)
      throws {
    // The run faults, and `columns(of:validate:true)` faults identically — the
    // schema never types a shape the run rejects.
    try fixture().expect(sql, fails: fault, location: location)
    #expect(throws: fault, sourceLocation: location) {
      _ = try fixture().columns(of: parse(query: sql, location: location),
                                validate: true)
    }
  }

  @Test func `an unsupported ranking function faults 0A000`() throws {
    try rejects("SELECT RANK() OVER (ORDER BY x) FROM T",
                .state("0A000", "RANK is not yet supported"))
  }

  @Test func `a window in a WHERE is rejected`() throws {
    try rejects(
        "SELECT x FROM T WHERE ROW_NUMBER() OVER () > 1",
        .state("0A000",
               "a window function is allowed only in SELECT and ORDER BY"))
  }
}
