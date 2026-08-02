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

  @Test func `an aggregate with OVER parses as a window function`() throws {
    // `SUM(x) OVER (…)` is a window function, not a collapsing aggregate: the
    // `OVER` after the aggregate makes the same operand a window fold.
    let expected = Expression.window(
        function: .aggregate(.sum, of: .expression(.column(Column("x")))),
        spec: WindowSpec(partition: [.column(Column("d"))]))
    #expect(try projected(
        "SELECT SUM(x) OVER (PARTITION BY d) FROM T") == expected)
  }

  @Test func `COUNT(*) with OVER parses as a window function`() throws {
    #expect(try projected("SELECT COUNT(*) OVER () FROM T")
                == .window(function: .aggregate(.count, of: .star),
                           spec: WindowSpec()))
  }

  @Test func `an aggregate without OVER stays a collapsing aggregate`() throws {
    // No `OVER`: the aggregate is the ordinary collapsing one, not a window.
    #expect(try projected("SELECT SUM(x) FROM T")
                == .aggregate(.sum, of: .expression(.column(Column("x")))))
  }

  @Test func `a DISTINCT aggregate window carries the quantifier`() throws {
    #expect(try projected("SELECT COUNT(DISTINCT x) OVER () FROM T")
                == .window(
                    function: .aggregate(.count,
                                         of: .expression(.column(Column("x"))),
                                         distinct: true),
                    spec: WindowSpec()))
  }
}

// MARK: - Frame parsing

/// An explicit window frame — `(ROWS | RANGE | GROUPS) BETWEEN <start> AND
/// <end>`, or the single-bound `<unit> <start>` shorthand — parses into the
/// `WindowSpec`'s `Frame` after the window `ORDER BY`.
struct WindowFrameParsingTests {
  /// The window `spec` of the single projected window of `sql`.
  private func spec(_ sql: String,
                    location: Testing.SourceLocation = #_sourceLocation)
      throws -> WindowSpec {
    guard case let .window(_, spec) = try projected(sql, location: location)
    else {
      Issue.record("expected a window function", sourceLocation: location)
      throw SQLError.incomplete(expected: "a window function")
    }
    return spec
  }

  @Test func `ROWS BETWEEN a preceding offset and the current row parses`()
      throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER
            (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """)
                .frame
                == Frame(unit: .rows, start: .preceding(1), end: .currentRow))
  }

  @Test func `RANGE between the partition edges parses`() throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER (ORDER BY x
            RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        FROM T
        """)
                .frame
                == Frame(unit: .range, start: .unboundedPreceding,
                         end: .unboundedFollowing))
  }

  @Test func `a following offset parses`() throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER
            (ORDER BY x ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING)
        FROM T
        """)
                .frame
                == Frame(unit: .rows, start: .currentRow, end: .following(2)))
  }

  @Test func `the single-bound shorthand ends at the current row`() throws {
    // `ROWS <start>` is `BETWEEN <start> AND CURRENT ROW`.
    #expect(try spec(
        "SELECT SUM(x) OVER (ORDER BY x ROWS UNBOUNDED PRECEDING) FROM T")
                .frame
                == Frame(unit: .rows, start: .unboundedPreceding,
                         end: .currentRow))
  }

  @Test func `a GROUPS frame parses`() throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER
            (ORDER BY x GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """)
                .frame
                == Frame(unit: .groups, start: .preceding(1),
                         end: .following(1)))
  }

  @Test func `frame keywords are case-insensitive`() throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER
            (ORDER BY x rows between unbounded preceding and current row)
        FROM T
        """)
                .frame
                == Frame(unit: .rows, start: .unboundedPreceding,
                         end: .currentRow))
  }

  @Test func `no frame clause leaves the frame absent`() throws {
    #expect(try spec("SELECT SUM(x) OVER (ORDER BY x) FROM T").frame == nil)
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

// MARK: - RANK / DENSE_RANK execution

/// `RANK()` and `DENSE_RANK()` rank each row within its partition by the window
/// order: peer rows (equal on every order key) share a rank; `RANK` then skips
/// to the 1-based position of the next distinct row, while `DENSE_RANK` takes
/// the immediately following rank, leaving no gap.
struct RankExecutionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
  }

  @Test func `RANK shares a rank on a tie and skips after it`() throws {
    // 10 → 1, the two 20s → 2 (peers), 30 → 4 (RANK skips the used-up 3).
    try fixture().expect(
        "SELECT x, RANK() OVER (ORDER BY x) FROM T",
        yields: [[10, 1], [20, 2], [20, 2], [30, 4]])
  }

  @Test func `DENSE_RANK shares a rank on a tie and leaves no gap`() throws {
    // 10 → 1, the two 20s → 2 (peers), 30 → 3 (no gap).
    try fixture().expect(
        "SELECT x, DENSE_RANK() OVER (ORDER BY x) FROM T",
        yields: [[10, 1], [20, 2], [20, 2], [30, 3]])
  }

  @Test func `RANK ranks each partition independently`() throws {
    let catalog = try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(1, 10)
        Row(1, 20)
        Row(2, 5)
      }
    }
    // d=1: the two 10s → 1, then 20 → 3; d=2's lone 5 → 1.
    try catalog.expect(
        "SELECT d, x, RANK() OVER (PARTITION BY d ORDER BY x) FROM T",
        yields: [[1, 10, 1], [1, 10, 1], [1, 20, 3], [2, 5, 1]])
  }

  @Test func `RANK without an ORDER BY makes every row a peer`() throws {
    // No window ORDER BY: every row is a peer, so RANK is 1 throughout.
    try fixture().expect(
        "SELECT x, RANK() OVER () FROM T",
        yields: [[10, 1], [20, 1], [20, 1], [30, 1]])
  }
}

// MARK: - Aggregate window execution (whole-partition frame)

/// An aggregate window `SUM/COUNT/AVG/MIN/MAX (…) OVER (…)` with no window
/// `ORDER BY` folds the aggregate over the whole partition and assigns that one
/// value to every row of the partition, cardinality-preserving — the aggregate
/// a `GROUP BY` on the same key would fold, spread back over the partition's
/// rows. `columns(of:)` advertises the aggregate's own result type in parity
/// with the run.
struct AggregateWindowExecutionTests {
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

  @Test func `SUM over a partition totals every partition row`() throws {
    // d=1 totals 10 + 30 + 20 = 60 on each of its rows; d=2's lone 20 is 20.
    // The source row order is preserved, each row gaining its partition total.
    try fixture().expect(
        "SELECT d, x, SUM(x) OVER (PARTITION BY d) FROM T",
        yields: [[1, 10, 60], [1, 30, 60], [2, 20, 20], [1, 20, 60]])
  }

  @Test func `COUNT(*) over a partition counts every partition row`() throws {
    try fixture().expect(
        "SELECT d, COUNT(*) OVER (PARTITION BY d) FROM T",
        yields: [[1, 3], [1, 3], [2, 1], [1, 3]])
  }

  @Test func `AVG over a partition averages to a double`() throws {
    // d=1 averages (10 + 30 + 20) / 3 = 20.0 (real division, a double).
    try fixture().expect(
        "SELECT d, AVG(x) OVER (PARTITION BY d) FROM T",
        yields: [[1, 20.0], [1, 20.0], [2, 20.0], [1, 20.0]])
  }

  @Test func `MIN and MAX over a partition take the extremes`() throws {
    try fixture().expect(
        """
        SELECT d, MIN(x) OVER (PARTITION BY d), MAX(x) OVER (PARTITION BY d)
        FROM T
        """,
        yields: [[1, 10, 30], [1, 10, 30], [2, 20, 20], [1, 10, 30]])
  }

  @Test func `an aggregate window with no PARTITION BY is a grand total`()
      throws {
    // No PARTITION BY: the whole input is one partition, so every row gains the
    // grand total 10 + 30 + 20 + 20 = 80.
    try fixture().expect(
        "SELECT x, SUM(x) OVER () FROM T",
        yields: [[10, 80], [30, 80], [20, 80], [20, 80]])
  }

  @Test func `COUNT of a value skips NULLs while COUNT(*) counts rows`()
      throws {
    // COUNT(v) folds only the non-NULL values (2), COUNT(*) every row (3).
    let catalog = try Catalog {
      Relation("T", ["v": .integer]) {
        Row(10)
        Row(nil)
        Row(20)
      }
    }
    try catalog.expect(
        "SELECT COUNT(v) OVER (), COUNT(*) OVER () FROM T",
        yields: [[2, 3], [2, 3], [2, 3]])
  }

  @Test func `a DISTINCT aggregate window folds each value once`() throws {
    // SUM(DISTINCT x) totals 10 + 20 = 30 (the repeated 10 folds once); the
    // plain SUM totals 40, and COUNT(DISTINCT x) is 2.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(10)
        Row(20)
      }
    }
    try catalog.expect(
        """
        SELECT SUM(DISTINCT x) OVER (), SUM(x) OVER (),
               COUNT(DISTINCT x) OVER ()
        FROM T
        """,
        yields: [[30, 40, 2], [30, 40, 2], [30, 40, 2]])
  }

  @Test func `an aggregate window in a compound expression evaluates`()
      throws {
    // A window nested in arithmetic lowers its window leaf to the appended slot
    // and the constant leaf over the source, so `SUM(x) OVER () + 1` widens.
    try fixture().expect(
        "SELECT SUM(x) OVER () + 1 FROM T",
        yields: [[81], [81], [81], [81]])
  }

  @Test func `an empty relation yields no aggregate window rows`() throws {
    let catalog = try Catalog { Relation("T", ["x": .integer]) {} }
    try catalog.empty("SELECT SUM(x) OVER () FROM T")
  }

  @Test func `the schema advertises the aggregate window column types`()
      throws {
    // Both paths type the columns: SUM(x) an integer (integer operand), AVG a
    // double, COUNT an integer — the run yields rows and validate types them.
    let query = try parse(query:
        """
        SELECT SUM(x) OVER () AS s, AVG(x) OVER () AS a,
               COUNT(*) OVER () AS c
        FROM T
        """)
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["s", "a", "c"])
    #expect(columns.map(\.type) == [.integer, .double, .integer])
  }
}

// MARK: - Aggregate window execution (running RANGE frame)

/// An aggregate window with a window `ORDER BY` folds over the default running
/// frame `RANGE UNBOUNDED PRECEDING`: a row's frame is every partition row up
/// to and including its peer group (the rows tied with it on the order key), so
/// the aggregate is cumulative and tied rows share the same running value — the
/// total through the last peer, never a row-by-row step within a tie.
struct RunningAggregateWindowTests {
  @Test func `SUM with ORDER BY is a running total`() throws {
    // Distinct keys are strictly cumulative: 10, 10+20=30, 30+30=60.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, SUM(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 10], [20, 30], [30, 60]])
  }

  @Test func `tied order keys share the running total (RANGE peers)`()
      throws {
    // Ordered by x: 10, 20, 20, 30. The two 20s are peers, so both take the
    // total through the END of their peer group — 10 + 20 + 20 = 50 — not a
    // row-by-row 30 then 50. Then 30 takes 80.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, SUM(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 10], [20, 50], [20, 50], [30, 80]])
  }

  @Test func `COUNT with ORDER BY counts through the peer group`() throws {
    // The two 20s are peers, so both count 3 (the rows through the peer group);
    // 30 counts 4.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, COUNT(*) OVER (ORDER BY x) FROM T",
        yields: [[10, 1], [20, 3], [20, 3], [30, 4]])
  }

  @Test func `AVG with ORDER BY is a running average to a double`() throws {
    // Running average: 10/1 = 10.0, (10+20)/2 = 15.0, the tied 20s both
    // (10+20+20)/3 = ~16.666…, then (…+30)/4 = 20.0.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, AVG(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 10.0], [20, 50.0 / 3.0], [20, 50.0 / 3.0], [30, 20.0]])
  }

  @Test func `MIN and MAX with ORDER BY run cumulatively`() throws {
    // Running MIN stays 10 from the start; running MAX climbs 10, 20, 20, 30.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        """
        SELECT x, MIN(x) OVER (ORDER BY x), MAX(x) OVER (ORDER BY x) FROM T
        """,
        yields: [[10, 10, 10], [20, 10, 20], [20, 10, 20], [30, 10, 30]])
  }

  @Test func `a running window resets per partition`() throws {
    // Each partition runs its own cumulative total in the window order.
    let catalog = try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(2, 100)
        Row(1, 20)
        Row(2, 200)
      }
    }
    // d=1: 10 then 30; d=2: 100 then 300. Source order is preserved.
    try catalog.expect(
        "SELECT d, x, SUM(x) OVER (PARTITION BY d ORDER BY x) FROM T",
        yields: [[1, 10, 10], [2, 100, 100], [1, 20, 30], [2, 200, 300]])
  }

  @Test func `the schema types a running aggregate window`() throws {
    // Both paths type the running column: SUM over integers an integer — the
    // run yields the running totals and validate types the column.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
      }
    }
    let query = try parse(query:
        "SELECT x, SUM(x) OVER (ORDER BY x) AS running FROM T")
    let columns = try catalog.columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x", "running"])
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

  @Test func `a window in a WHERE is rejected`() throws {
    try rejects(
        "SELECT x FROM T WHERE ROW_NUMBER() OVER () > 1",
        .state("0A000",
               "a window function is allowed only in SELECT and ORDER BY"))
  }

  @Test func `a window ORDER BY output ordinal is rejected`() throws {
    try rejects(
        "SELECT ROW_NUMBER() OVER (ORDER BY 1) FROM T",
        .state("0A000",
               "a window ORDER BY output ordinal is not supported"))
  }

  @Test func `an explicit window frame is rejected`() throws {
    try rejects(
        """
        SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        .state("0A000", "an explicit window frame is not yet supported"))
  }

}
