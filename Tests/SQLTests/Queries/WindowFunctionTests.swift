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

// MARK: - LEAD / LAG parsing

/// The offset window functions `LEAD`/`LAG(value [, offset [, default]])` parse
/// into an `Expression.window` carrying the offset `WindowFunction` and the
/// `OVER (…)` specification.
struct OffsetFunctionParsingTests {
  @Test func `LAG with only a value parses`() throws {
    #expect(try projected("SELECT LAG(x) OVER (ORDER BY x) FROM T")
                == .window(
                    function: .lag(.column(Column("x"))),
                    spec: WindowSpec(order: Order(keys:
                        [Order.Key(column: Column("x"))]))))
  }

  @Test func `LEAD with an offset and default parses`() throws {
    #expect(try projected("SELECT LEAD(x, 2, 0) OVER (ORDER BY x) FROM T")
                == .window(
                    function: .lead(.column(Column("x")), offset: 2,
                                    default: .literal(.integer(0))),
                    spec: WindowSpec(order: Order(keys:
                        [Order.Key(column: Column("x"))]))))
  }

  @Test func `an offset function without OVER is a syntax error`() {
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT LAG(x) FROM T")
    }
  }

  @Test func `a delimited offset name stays a scalar call`() throws {
    #expect(try projected("SELECT \"lag\"(x) FROM T")
                == .call(name: "lag", arguments: [.column(Column("x"))]))
  }
}

// MARK: - Value function parsing

/// The frame-sensitive positional functions `FIRST_VALUE`/`LAST_VALUE(value)`
/// and `NTH_VALUE(value, n)` parse into an `Expression.window`.
struct ValueFunctionParsingTests {
  @Test func `FIRST_VALUE parses`() throws {
    #expect(try projected("SELECT FIRST_VALUE(x) OVER (ORDER BY x) FROM T")
                == .window(
                    function: .firstValue(.column(Column("x"))),
                    spec: WindowSpec(order: Order(keys:
                        [Order.Key(column: Column("x"))]))))
  }

  @Test func `NTH_VALUE parses its position argument`() throws {
    #expect(try projected("SELECT NTH_VALUE(x, 2) OVER (ORDER BY x) FROM T")
                == .window(
                    function: .nthValue(.column(Column("x")), 2),
                    spec: WindowSpec(order: Order(keys:
                        [Order.Key(column: Column("x"))]))))
  }

  @Test func `NTH_VALUE without a position is a syntax error`() {
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT NTH_VALUE(x) OVER (ORDER BY x) FROM T")
    }
  }

  @Test func `a delimited value name stays a scalar call`() throws {
    #expect(try projected("SELECT \"first_value\"(x) FROM T")
                == .call(name: "first_value", arguments: [.column(Column("x"))]))
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

// MARK: - LEAD / LAG execution

/// `LEAD`/`LAG(value [, offset [, default]]) OVER (…)` read the `value` a fixed
/// number of rows after (`LEAD`) or before (`LAG`) the current row in the
/// window order, yielding the default (or NULL) at a partition edge.
/// `columns(of:)` types the column as the value expression in parity with the
/// run.
struct OffsetFunctionExecutionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
        Row(40)
      }
    }
  }

  @Test func `LAG reads the previous row, NULL at the start`() throws {
    try fixture().expect(
        "SELECT x, LAG(x) OVER (ORDER BY x) FROM T",
        yields: [[10, nil], [20, 10], [30, 20], [40, 30]])
  }

  @Test func `LEAD reads the next row, NULL at the end`() throws {
    try fixture().expect(
        "SELECT x, LEAD(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 20], [20, 30], [30, 40], [40, nil]])
  }

  @Test func `LAG honours an offset and a default at the edge`() throws {
    // Two rows back, default 99 where the offset runs off the start.
    try fixture().expect(
        "SELECT x, LAG(x, 2, 99) OVER (ORDER BY x) FROM T",
        yields: [[10, 99], [20, 99], [30, 10], [40, 20]])
  }

  @Test func `LEAD honours an offset and a default at the edge`() throws {
    try fixture().expect(
        "SELECT x, LEAD(x, 1, 0) OVER (ORDER BY x) FROM T",
        yields: [[10, 20], [20, 30], [30, 40], [40, 0]])
  }

  @Test func `an explicit NULL default reconciles with any value type`()
      throws {
    // A literal NULL default is type-neutral — the value type's NULL — so it is
    // valid for a text value, not rejected as irreconcilable with the `.integer`
    // placeholder a bare NULL derives as. The last row takes the NULL.
    let catalog = try Catalog {
      Relation("T", ["id": .integer, "name": .text]) {
        Row(1, "a")
        Row(2, "b")
      }
    }
    try catalog.expect(
        "SELECT id, LEAD(name, 1, NULL) OVER (ORDER BY id) FROM T",
        yields: [[1, "b"], [2, nil]])
  }

  @Test func `a reconcilable default coerces to the value type`() throws {
    // With integer `x` the column is integer, so a double default (`2.0`) is
    // cast to integer at the edge row rather than reaching it as a double —
    // every value of the window column is an integer.
    try fixture().expect(
        "SELECT x, LEAD(x, 1, 2.0) OVER (ORDER BY x) FROM T",
        yields: [[10, 20], [20, 30], [30, 40], [40, 2]])
    let query = try parse(query:
        "SELECT LEAD(x, 1, 2.0) OVER (ORDER BY x) FROM T")
    #expect(try fixture().columns(of: query, validate: true).map(\.type)
                == [.integer])
  }

  @Test func `a huge offset runs off the partition without overflowing`()
      throws {
    // `index + Int.max` would overflow-trap at the second row; the offset
    // instead recognises the target is off the end and yields NULL (no default)
    // or the default everywhere.
    try fixture().expect(
        "SELECT x, LEAD(x, 9223372036854775807) OVER (ORDER BY x) FROM T",
        yields: [[10, nil], [20, nil], [30, nil], [40, nil]])
    try fixture().expect(
        "SELECT x, LAG(x, 9223372036854775807, 0) OVER (ORDER BY x) FROM T",
        yields: [[10, 0], [20, 0], [30, 0], [40, 0]])
  }

  @Test func `the default is evaluated at the current row`() throws {
    // At the first row the offset runs off the start, so the default `x * 10`
    // is evaluated there (10 * 10 = 100); the rest read the previous row.
    try fixture().expect(
        "SELECT x, LAG(x, 1, x * 10) OVER (ORDER BY x) FROM T",
        yields: [[10, 100], [20, 10], [30, 20], [40, 30]])
  }

  @Test func `LAG resets per partition`() throws {
    let catalog = try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(2, 100)
        Row(1, 20)
        Row(2, 200)
      }
    }
    // Each partition's first row has no previous row (NULL); source order is
    // preserved.
    try catalog.expect(
        "SELECT d, x, LAG(x) OVER (PARTITION BY d ORDER BY x) FROM T",
        yields: [[1, 10, nil], [2, 100, nil], [1, 20, 10], [2, 200, 100]])
  }

  @Test func `the schema types an offset window`() throws {
    // Both paths type the column as the value expression: LAG(x) an integer —
    // the run yields the neighbours and validate types the column.
    let query = try parse(query:
        "SELECT x, LAG(x) OVER (ORDER BY x) AS prev FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x", "prev"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }
}

// MARK: - FIRST_VALUE / LAST_VALUE / NTH_VALUE execution

/// `FIRST_VALUE`/`LAST_VALUE`/`NTH_VALUE(value [, n]) OVER (…)` read the value
/// at the first, last, or n-th row of the window frame. They are
/// frame-sensitive:
/// over the default frame (the partition start through the current peer group)
/// `LAST_VALUE` reads the current row, the classic gotcha. `columns(of:)` types
/// the column as the value expression in parity with the run.
struct ValueFunctionExecutionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
        Row(40)
      }
    }
  }

  @Test func `FIRST_VALUE reads the partition first over the default frame`()
      throws {
    // The default frame starts at the partition, so every row reads the first.
    try fixture().expect(
        "SELECT x, FIRST_VALUE(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 10], [20, 10], [30, 10], [40, 10]])
  }

  @Test func `LAST_VALUE over the default frame reads the current row`()
      throws {
    // The gotcha: the default frame ends at the current peer group, so with
    // distinct order keys LAST_VALUE is each row's own value, not the last.
    try fixture().expect(
        "SELECT x, LAST_VALUE(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 10], [20, 20], [30, 30], [40, 40]])
  }

  @Test func `LAST_VALUE over the whole frame reads the partition last`()
      throws {
    try fixture().expect(
        """
        SELECT x, LAST_VALUE(x) OVER (ORDER BY x
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[10, 40], [20, 40], [30, 40], [40, 40]])
  }

  @Test func `FIRST_VALUE is frame-sensitive`() throws {
    // A moving `1 PRECEDING AND CURRENT ROW` frame's first row is the previous
    // row (or the current one at the partition start).
    try fixture().expect(
        """
        SELECT x, FIRST_VALUE(x) OVER (ORDER BY x
            ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 10], [30, 20], [40, 30]])
  }

  @Test func `NTH_VALUE reads the n-th frame row, NULL when too short`()
      throws {
    // Default frame: the 2nd row is absent at the first row (NULL), then the
    // 2nd partition value (20) once the frame reaches it.
    try fixture().expect(
        "SELECT x, NTH_VALUE(x, 2) OVER (ORDER BY x) FROM T",
        yields: [[10, nil], [20, 20], [30, 20], [40, 20]])
  }

  @Test func `a huge NTH_VALUE position is NULL without overflowing`() throws {
    // `lo + n - 1` would overflow-trap; the position instead recognises the
    // frame holds fewer than `n` rows and yields NULL.
    try fixture().expect(
        "SELECT x, NTH_VALUE(x, 9223372036854775807) OVER (ORDER BY x) FROM T",
        yields: [[10, nil], [20, nil], [30, nil], [40, nil]])
  }

  @Test func `NTH_VALUE over the whole frame reads the n-th partition row`()
      throws {
    try fixture().expect(
        """
        SELECT x, NTH_VALUE(x, 3) OVER (ORDER BY x
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[10, 30], [20, 30], [30, 30], [40, 30]])
  }

  @Test func `LAST_VALUE shares the peer group over the default frame`()
      throws {
    // The tied 20s' peer group ends at the last 20, so both read 20.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, LAST_VALUE(x) OVER (ORDER BY x) FROM T",
        yields: [[10, 10], [20, 20], [20, 20], [30, 30]])
  }

  @Test func `a value function resets per partition`() throws {
    let catalog = try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(2, 100)
        Row(1, 20)
        Row(2, 200)
      }
    }
    // Each partition reads its own first value; source order is preserved.
    try catalog.expect(
        "SELECT d, x, FIRST_VALUE(x) OVER (PARTITION BY d ORDER BY x) FROM T",
        yields: [[1, 10, 10], [2, 100, 100], [1, 20, 10], [2, 200, 100]])
  }

  @Test func `the schema types a value window`() throws {
    let query = try parse(query:
        "SELECT x, FIRST_VALUE(x) OVER (ORDER BY x) AS f FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x", "f"])
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

  @Test func `a RANGE numeric offset frame is rejected`() throws {
    // A RANGE frame measured by an n PRECEDING/FOLLOWING order-key offset is
    // not yet computed; only the partition edges and the peer group are.
    try rejects(
        """
        SELECT SUM(x) OVER (ORDER BY x
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        .state("0A000", "a RANGE numeric offset frame is not yet supported"))
  }

  @Test func `a GROUPS frame is rejected`() throws {
    try rejects(
        """
        SELECT SUM(x) OVER (ORDER BY x
            GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        .state("0A000", "a GROUPS window frame is not yet supported"))
  }

  @Test func `a frame starting at UNBOUNDED FOLLOWING is rejected`() throws {
    // The parser spells it, but the start would follow every row, so the frame
    // is empty for all but the partition's last row — a misleading total rather
    // than the required error.
    try rejects(
        """
        SELECT SUM(x) OVER (ORDER BY x
            ROWS BETWEEN UNBOUNDED FOLLOWING AND CURRENT ROW)
        FROM T
        """,
        .state("42601", "a window frame cannot start at UNBOUNDED FOLLOWING"))
  }

  @Test func `the single-bound UNBOUNDED FOLLOWING frame is rejected`() throws {
    // `ROWS UNBOUNDED FOLLOWING` is the shorthand for `BETWEEN UNBOUNDED
    // FOLLOWING AND CURRENT ROW` — the same invalid start.
    try rejects(
        "SELECT SUM(x) OVER (ORDER BY x ROWS UNBOUNDED FOLLOWING) FROM T",
        .state("42601", "a window frame cannot start at UNBOUNDED FOLLOWING"))
  }

  @Test func `a frame ending at UNBOUNDED PRECEDING is rejected`() throws {
    try rejects(
        """
        SELECT SUM(x) OVER (ORDER BY x
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED PRECEDING)
        FROM T
        """,
        .state("42601", "a window frame cannot end at UNBOUNDED PRECEDING"))
  }

  @Test func `a start from a later category than the end is rejected`() throws {
    // CURRENT ROW (category 2) starts after 1 PRECEDING (category 1) ends, and
    // 1 FOLLOWING (3) after CURRENT ROW (2) — each frames nothing rather than
    // raising the error, so both are rejected by the bound-category ordering.
    try rejects(
        "SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN CURRENT ROW AND 1 PRECEDING)"
            + " FROM T",
        .state("42601", "a window frame start follows its end"))
    try rejects(
        "SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW)"
            + " FROM T",
        .state("42601", "a window frame start follows its end"))
    try rejects(
        "SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN 1 FOLLOWING AND 1 PRECEDING)"
            + " FROM T",
        .state("42601", "a window frame start follows its end"))
  }

  @Test func `reversed offsets within one category are rejected`() throws {
    // Same category, but the offsets order the bounds: 2 PRECEDING is nearer the
    // current row than 5 PRECEDING (so the start is later), and 5 FOLLOWING is
    // farther than 2 FOLLOWING — each an empty frame rather than the error.
    try rejects(
        "SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN 2 PRECEDING AND 5 PRECEDING)"
            + " FROM T",
        .state("42601", "a window frame start follows its end"))
    try rejects(
        "SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN 5 FOLLOWING AND 2 FOLLOWING)"
            + " FROM T",
        .state("42601", "a window frame start follows its end"))
  }

  @Test func `an offset function without an ORDER BY is rejected`() throws {
    // LEAD/LAG read a neighbour of the window order, so an unordered window has
    // no neighbour — rejected on both paths.
    try rejects(
        "SELECT LAG(x) OVER () FROM T",
        .state("0A000", "LAG requires an ORDER BY"))
  }

  @Test func `a frame on an offset function is rejected`() throws {
    try rejects(
        """
        SELECT LEAD(x) OVER (ORDER BY x
            ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        .state("0A000", "a window frame is not supported for LEAD"))
  }

  @Test func `NTH_VALUE with a zero position is rejected`() throws {
    // Position 0 is meaningless (positions are 1-based) — rejected at parse, so
    // the executor never computes the frame index `lo + 0 - 1` and subscripts a
    // row before the partition start.
    try rejects(
        "SELECT NTH_VALUE(x, 0) OVER (ORDER BY x) FROM T",
        .state("22023", "NTH_VALUE requires a positive position"))
  }

  @Test func `a LEAD default irreconcilable with the value is rejected`()
      throws {
    // Integer `x` and a text default share no common type, so the default
    // cannot stand in at a partition edge — rejected on both paths, never
    // advertised as an integer column a text value then reaches.
    try rejects(
        "SELECT LEAD(x, 1, 'a') OVER (ORDER BY x) FROM T",
        .operand("a LEAD/LAG default and value have irreconcilable types"))
  }

  @Test func `a frame on a ranking function is rejected`() throws {
    // A ranking function reads its position, not a frame — a frame on it is
    // rejected rather than silently ignored.
    try rejects(
        "SELECT ROW_NUMBER() OVER (ORDER BY x ROWS UNBOUNDED PRECEDING) FROM T",
        .state("0A000",
               "a window frame is not supported for ROW_NUMBER"))
  }

}

// MARK: - Explicit frame execution

/// An aggregate window with an explicit `ROWS`/`RANGE` frame folds the
/// aggregate over each row's framed slice rather than the default running
/// frame: `ROWS` bounds are physical row offsets (a moving window), `RANGE`
/// bounds are the partition edges or — for `CURRENT ROW` — the current row's
/// peer group. `columns(of:)` types the framed column in parity with the run.
struct WindowFrameExecutionTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
        Row(40)
      }
    }
  }

  @Test func `ROWS one preceding through current row is a moving sum`()
      throws {
    // Each row sums itself and the one before: 10, 10+20, 20+30, 30+40.
    try fixture().expect(
        """
        SELECT x, SUM(x) OVER (ORDER BY x
            ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 30], [30, 50], [40, 70]])
  }

  @Test func `ROWS unbounded preceding through current row is the running sum`()
      throws {
    // The explicit spelling of the default running frame: 10, 30, 60, 100.
    try fixture().expect(
        """
        SELECT x,
               SUM(x) OVER
                   (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 30], [30, 60], [40, 100]])
  }

  @Test func `an explicit cumulative RANGE frame shares its peers`() throws {
    // RANGE UNBOUNDED PRECEDING AND CURRENT ROW: the two tied 20s share the
    // total through their peer group (10 + 20 + 20 = 50) — the streaming
    // accumulator folds each row once as the peer-group end advances, and a peer
    // reads the value the first of its group reached.
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
        SELECT x, SUM(x) OVER (ORDER BY x
            RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 50], [20, 50], [30, 80]])
  }

  @Test func `a cumulative frame streams DISTINCT once per new value`() throws {
    // SUM(DISTINCT x) over a cumulative ROWS frame folds each row once into the
    // running distinct set, so a repeated value adds nothing: 10, 30, 30, 60.
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
        SELECT x, SUM(DISTINCT x) OVER
            (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 30], [20, 30], [30, 60]])
  }

  @Test func `ROWS current row through unbounded following is a reverse sum`()
      throws {
    // Each row sums itself and every later row: 100, 90, 70, 40. This is the
    // reverse-cumulative fast path — one running accumulator folded in reverse.
    try fixture().expect(
        """
        SELECT x,
               SUM(x) OVER
                   (ORDER BY x ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[10, 100], [20, 90], [30, 70], [40, 40]])
  }

  @Test func `a reverse cumulative RANGE frame shares its peers`() throws {
    // RANGE CURRENT ROW AND UNBOUNDED FOLLOWING: the two tied 20s share the
    // total from their peer-group start through the end (20 + 20 + 30 = 70) —
    // the reverse running accumulator folds each row once as the lower bound
    // retreats, and a peer reads the value the last of its group reached.
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
        SELECT x, SUM(x) OVER (ORDER BY x
            RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[10, 80], [20, 70], [20, 70], [30, 30]])
  }

  @Test func `a zero offset bound frames the current row`() throws {
    // `0 PRECEDING` and `0 FOLLOWING` both name the current row, so these frames
    // are the single current row — SUM is the row's own value, not a rejected
    // inversion — whether the zero is the end or the start.
    try fixture().expect(
        """
        SELECT x, SUM(x) OVER
            (ORDER BY x ROWS BETWEEN CURRENT ROW AND 0 PRECEDING)
        FROM T
        """,
        yields: [[10, 10], [20, 20], [30, 30], [40, 40]])
    try fixture().expect(
        """
        SELECT x, SUM(x) OVER
            (ORDER BY x ROWS BETWEEN 0 FOLLOWING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 20], [30, 30], [40, 40]])
  }

  @Test func `a zero RANGE offset bound is the current peer group`() throws {
    // Under RANGE, `0 FOLLOWING` is the current row's peer group (it normalizes
    // to CURRENT ROW), not a rejected numeric offset — the two tied 20s share
    // their peer-group total 40.
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
        SELECT x, SUM(x) OVER
            (ORDER BY x RANGE BETWEEN CURRENT ROW AND 0 FOLLOWING)
        FROM T
        """,
        yields: [[10, 10], [20, 40], [20, 40], [30, 30]])
  }

  @Test func `a huge FOLLOWING bound clamps to the partition end`() throws {
    // `index + Int.max` would overflow-trap at the second row; the bound
    // instead saturates past the end, so the frame reaches the last row exactly
    // as UNBOUNDED FOLLOWING does — the reverse sum 100, 90, 70, 40.
    try fixture().expect(
        """
        SELECT x,
               SUM(x) OVER (ORDER BY x
                   ROWS BETWEEN CURRENT ROW AND 9223372036854775807 FOLLOWING)
        FROM T
        """,
        yields: [[10, 100], [20, 90], [30, 70], [40, 40]])
  }

  @Test func `ROWS between the partition edges totals the whole partition`()
      throws {
    try fixture().expect(
        """
        SELECT x,
               SUM(x) OVER (ORDER BY x
                   ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[10, 100], [20, 100], [30, 100], [40, 100]])
  }

  @Test func `a ROWS frame off the partition end is empty`() throws {
    // COUNT over `2 FOLLOWING AND 3 FOLLOWING`: the last rows frame past the
    // end and count nothing (0), the earlier rows count their tail.
    try fixture().expect(
        """
        SELECT x,
               COUNT(*) OVER
                   (ORDER BY x ROWS BETWEEN 2 FOLLOWING AND 3 FOLLOWING)
        FROM T
        """,
        yields: [[10, 2], [20, 1], [30, 0], [40, 0]])
  }

  @Test func `RANGE unbounded preceding through current row shares peers`()
      throws {
    // RANGE CURRENT ROW is the peer group, so tied rows share the running total
    // through the last peer — the explicit spelling of the default frame.
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
        SELECT x, SUM(x) OVER (ORDER BY x
            RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[10, 10], [20, 50], [20, 50], [30, 80]])
  }

  @Test func `RANGE current row through unbounded following shares peers`()
      throws {
    // From the peer group's start through the partition end: the tied 20s both
    // sum 20 + 20 + 30 = 70.
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
        SELECT x, SUM(x) OVER (ORDER BY x
            RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[10, 80], [20, 70], [20, 70], [30, 30]])
  }

  @Test func `a moving frame resets per partition`() throws {
    let catalog = try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(2, 100)
        Row(1, 20)
        Row(2, 200)
        Row(1, 30)
      }
    }
    // Each partition runs its own moving sum over `1 PRECEDING AND CURRENT
    // ROW`; d=1: 10, 30, 50; d=2: 100, 300. Source order is preserved.
    try catalog.expect(
        """
        SELECT d, x,
               SUM(x) OVER (PARTITION BY d ORDER BY x
                   ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[1, 10, 10], [2, 100, 100], [1, 20, 30],
                 [2, 200, 300], [1, 30, 50]])
  }

  @Test func `the schema types a framed aggregate window`() throws {
    // Both paths type the framed column: SUM over integers an integer — the run
    // yields the moving totals and validate types the column.
    let query = try parse(query:
        """
        SELECT x,
               SUM(x) OVER
                   (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS m
        FROM T
        """)
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x", "m"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }
}

// MARK: - Non-deterministic argument evaluation

/// A shared call counter a stateful routine increments, so a non-deterministic
/// `tick()` both yields the sequence `1, 2, 3, …` and records how many times the
/// run invoked it. The engine evaluates one window over one thread, so the box
/// needs no lock.
private final class Counter: @unchecked Sendable {
  private(set) var count = 0
  func next() -> Int { count += 1; return count }
}

/// A window's argument or value calls a source row's routine once per input row,
/// not once per frame that contains the row nor once per output that reads it —
/// so a stateful or non-deterministic routine (`tick()`) folds and reads one
/// value per row, the result a single evaluation per input yields.
struct WindowNonDeterminismTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
      }
    }
  }

  private func ticking() throws -> (Counter, Routines) {
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    return (counter, routines)
  }

  @Test func `a framed aggregate argument folds once per source row`() throws {
    // A running frame contains the first row in every frame. Re-evaluating per
    // frame would call tick() six times and fold 1, then 2+3, then 4+5+6 — the
    // misleading 1, 5, 15. Evaluated once per row (1, 2, 3), the running sums
    // are 1, 3, 6.
    let (counter, routines) = try ticking()
    try fixture().expect(
        """
        SELECT SUM(tick()) OVER
            (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[1], [3], [6]], routines: routines)
    #expect(counter.count == 3)
  }

  @Test func `a positional value reads one evaluation per source row`() throws {
    // FIRST_VALUE reads the partition's first row's value throughout. Re-reading
    // it per output would call tick() afresh each time and return the changing
    // 1, 2, 3; materialised once per row, every output is the first value, 1.
    let (counter, routines) = try ticking()
    try fixture().expect(
        "SELECT FIRST_VALUE(tick()) OVER (ORDER BY x) FROM T",
        yields: [[1], [1], [1]], routines: routines)
    #expect(counter.count == 3)
  }

  @Test func `an offset value is evaluated once per source row`() throws {
    // LEAD reads the next row's value. Materialising each source row's value
    // once (tick() 1, 2, 3) reads the next row's value — 2, 3, then NULL past
    // the end — three calls, one per input row. Evaluating only at the shifted
    // target would call tick() twice and return 1, 2, NULL.
    let (counter, routines) = try ticking()
    try fixture().expect(
        "SELECT LEAD(tick()) OVER (ORDER BY x) FROM T",
        yields: [[2], [3], [nil]], routines: routines)
    #expect(counter.count == 3)
  }

  @Test func `a framed argument is skipped when its FILTER rejects the row`()
      throws {
    // The FILTER is false for every row, so the throwing argument 1 / 0 is never
    // evaluated and each frame folds nothing — SUM is NULL, not a raised error.
    try fixture().expect(
        """
        SELECT SUM(1 / 0) FILTER (WHERE 1 = 0) OVER
            (ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[nil], [nil], [nil]])
  }

  @Test func `repeated non-deterministic windows evaluate independently`()
      throws {
    // Two occurrences of the same non-deterministic window must not share one
    // appended slot: each materialises its own per-row values. The first window
    // reads tick() 1, 2, 3 (first value 1); the second reads 4, 5, 6 (first
    // value 4); six calls in all — not one deduped slot reading 1, 1.
    let (counter, routines) = try ticking()
    try fixture().expect(
        """
        SELECT FIRST_VALUE(tick()) OVER (ORDER BY x),
               FIRST_VALUE(tick()) OVER (ORDER BY x)
        FROM T
        """,
        yields: [[1, 4], [1, 4], [1, 4]], routines: routines)
    #expect(counter.count == 6)
  }
}
