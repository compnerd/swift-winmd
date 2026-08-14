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
                == .window(function: .number, spec: WindowSpec()))
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
        function: .dense,
        spec: WindowSpec(order: Order(keys: [Order.Key(column: Column("x"))])))
    #expect(try projected("SELECT DENSE_RANK() OVER (ORDER BY x) FROM T")
                == expected)
  }

  @Test func `a window with a multi-key partition parses`() throws {
    let expected = Expression.window(
        function: .number,
        spec: WindowSpec(partition: [.column(Column("a")), .column(Column("b"))]))
    #expect(try projected(
        "SELECT ROW_NUMBER() OVER (PARTITION BY a, b) FROM T") == expected)
  }

  @Test func `window function names are case-insensitive`() throws {
    #expect(try projected("SELECT row_number() over () FROM T")
                == .window(function: .number, spec: WindowSpec()))
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
                    function: .first(.column(Column("x"))),
                    spec: WindowSpec(order: Order(keys:
                        [Order.Key(column: Column("x"))]))))
  }

  @Test func `NTH_VALUE parses its position argument`() throws {
    #expect(try projected("SELECT NTH_VALUE(x, 2) OVER (ORDER BY x) FROM T")
                == .window(
                    function: .nth(.column(Column("x")), 2),
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

// MARK: - Distribution parsing

/// The distribution functions `NTILE(n)`, `PERCENT_RANK()`, and `CUME_DIST()`
/// parse into an `Expression.window`.
struct DistributionParsingTests {
  @Test func `NTILE parses its bucket count`() throws {
    #expect(try projected("SELECT NTILE(4) OVER (ORDER BY x) FROM T")
                == .window(function: .ntile(4),
                           spec: WindowSpec(order: Order(keys:
                               [Order.Key(column: Column("x"))]))))
  }

  @Test func `PERCENT_RANK and CUME_DIST parse an empty argument list`()
      throws {
    #expect(try projected("SELECT PERCENT_RANK() OVER (ORDER BY x) FROM T")
                == .window(function: .percent,
                           spec: WindowSpec(order: Order(keys:
                               [Order.Key(column: Column("x"))]))))
    #expect(try projected("SELECT CUME_DIST() OVER (ORDER BY x) FROM T")
                == .window(function: .cumulative,
                           spec: WindowSpec(order: Order(keys:
                               [Order.Key(column: Column("x"))]))))
  }

  @Test func `a delimited distribution name stays a scalar call`() throws {
    #expect(try projected("SELECT \"ntile\"(4) FROM T")
                == .call(name: "ntile",
                         arguments: [.literal(.integer(4))]))
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
                == Frame(unit: .rows, start: .preceding(1), end: .current))
  }

  @Test func `RANGE between the partition edges parses`() throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER (ORDER BY x
            RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        FROM T
        """)
                .frame
                == Frame(unit: .range, start: .head,
                         end: .tail))
  }

  @Test func `a following offset parses`() throws {
    #expect(try spec(
        """
        SELECT SUM(x) OVER
            (ORDER BY x ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING)
        FROM T
        """)
                .frame
                == Frame(unit: .rows, start: .current, end: .following(2)))
  }

  @Test func `the single-bound shorthand ends at the current row`() throws {
    // `ROWS <start>` is `BETWEEN <start> AND CURRENT ROW`.
    #expect(try spec(
        "SELECT SUM(x) OVER (ORDER BY x ROWS UNBOUNDED PRECEDING) FROM T")
                .frame
                == Frame(unit: .rows, start: .head,
                         end: .current))
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
                == Frame(unit: .rows, start: .head,
                         end: .current))
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

// MARK: - Window ORDER BY output ordinal

/// A window `ORDER BY` may name a projected output column by its 1-based
/// ordinal — `OVER (ORDER BY 1)` orders on the value of projected column 1,
/// exactly as a query-level `ORDER BY` ordinal names an output. The shared
/// `Query.expanded` prelude binds the ordinal to that column's expression, so
/// the inline form, a `WINDOW` clause definition, and the compile and validate
/// paths resolve it identically.
struct WindowOrderOrdinalTests {
  private func fixture() throws -> FixtureCatalog {
    // Ordering by a (1, 2, 3) differs from ordering by b (also from the source
    // order), so an ordinal naming a distinct column yields a distinct ranking.
    try Catalog {
      Relation("T", ["a": .integer, "b": .integer]) {
        Row(3, 1)
        Row(1, 3)
        Row(2, 2)
      }
    }
  }

  @Test func `an ordinal orders the window by the projected column`() throws {
    // Ordinal 1 names projected column a, so the window orders by a: the row
    // with a=1 numbers 1, a=2 numbers 2, a=3 numbers 3, kept in source order.
    try fixture().expect(
        "SELECT a, b, ROW_NUMBER() OVER (ORDER BY 1) FROM T",
        yields: [[3, 1, 3], [1, 3, 1], [2, 2, 2]])
  }

  @Test func `an ordinal equals the named projected column`() throws {
    try fixture().expect(
        "SELECT a, b, ROW_NUMBER() OVER (ORDER BY 1) FROM T",
        equals: "SELECT a, b, ROW_NUMBER() OVER (ORDER BY a) FROM T")
  }

  @Test func `a second ordinal names the second projected column`() throws {
    try fixture().expect(
        "SELECT a, b, ROW_NUMBER() OVER (ORDER BY 2) FROM T",
        equals: "SELECT a, b, ROW_NUMBER() OVER (ORDER BY b) FROM T")
  }

  @Test func `a named window ORDER BY ordinal equals its inline form`() throws {
    try fixture().expect(
        "SELECT a, b, ROW_NUMBER() OVER w FROM T WINDOW w AS (ORDER BY 1)",
        equals: "SELECT a, b, ROW_NUMBER() OVER (ORDER BY a) FROM T")
  }

  @Test func `a named window ordinal equals its inline ordinal form`() throws {
    try fixture().expect(
        "SELECT a, b, ROW_NUMBER() OVER w FROM T WINDOW w AS (ORDER BY 2)",
        equals: "SELECT a, b, ROW_NUMBER() OVER (ORDER BY 2) FROM T")
  }

  @Test func `a bare-column projection binds a window ORDER BY ordinal`()
      throws {
    // The projection is a plain column list (a, b), so the ordinal binds
    // against the columns positionally — ordinal 1 is a — while the window sits
    // in the query ORDER BY.
    try fixture().expect(
        "SELECT a, b FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 1)",
        equals: "SELECT a, b FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY a)")
  }

  @Test func `the schema advertises the ordinal window's columns`() throws {
    let query = try parse(query:
        "SELECT a, b, ROW_NUMBER() OVER (ORDER BY 1) AS rn FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["a", "b", "rn"])
    #expect(columns.map(\.type) == [.integer, .integer, .integer])
  }
}

// MARK: - A SELECT * window ORDER BY ordinal

/// A window `ORDER BY` ordinal over a `SELECT *` projection binds against the
/// expanded star columns once the source scope resolves — `OVER (ORDER BY 1)`
/// orders the window on the first projected source column, exactly as the
/// equivalent query-level `ORDER BY 1` resolves `*`. A `*` names no window
/// itself, so the window sits in the query `ORDER BY`; the source columns `*`
/// projects are the ordinal surface.
struct StarWindowOrdinalTests {
  private func fixture() throws -> FixtureCatalog {
    // Ordering by column 1 (a) — (1, 2, 3) — differs from the source order, so
    // the ordering the window fixes is observable in the result.
    try Catalog {
      Relation("T", ["a": .integer, "b": .integer]) {
        Row(3, 1)
        Row(1, 3)
        Row(2, 2)
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

  @Test func `an inline ordinal orders the star projection by column one`()
      throws {
    // Ordinal 1 names the first star output column a, so the window orders on
    // a — the rows come out in a order (1, 2, 3), not source order.
    try fixture().expect(
        "SELECT * FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 1)",
        yields: [[1, 3], [2, 2], [3, 1]])
  }

  @Test func `an inline ordinal over star equals the named-column form`()
      throws {
    try fixture().expect(
        "SELECT * FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 1)",
        equals: "SELECT a, b FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY a)")
  }

  @Test func `a second inline ordinal over star names the second column`()
      throws {
    try fixture().expect(
        "SELECT * FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 2)",
        equals: "SELECT a, b FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY b)")
  }

  @Test func `a named window ordinal over star equals its column form`()
      throws {
    try fixture().expect(
        "SELECT * FROM T WINDOW w AS (ORDER BY 1) "
        + "ORDER BY ROW_NUMBER() OVER w",
        equals: "SELECT a, b FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY a)")
  }

  @Test func `an unreferenced star window definition ordinal resolves`()
      throws {
    // An unused `WINDOW` definition is validated by `validate(named:)`; its
    // ordinal 1 range-checks against the star columns and resolves cleanly, so
    // the query yields the plain star projection rather than faulting.
    try fixture().expect(
        "SELECT * FROM T WINDOW w AS (ORDER BY 1)",
        equals: "SELECT * FROM T")
  }

  @Test func `the schema advertises the star window's source columns`() throws {
    let query = try parse(query:
        "SELECT * FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 1)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["a", "b"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }

  @Test func `an inline ordinal past the star columns faults`() throws {
    // Two star output columns (a, b), so ordinal 9 is out of range — the same
    // `.column` (42703) fault a query-level out-of-range ordinal raises, on
    // both the run and validate paths.
    try rejects(
        "SELECT * FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 9)",
        .column("9"))
  }

  @Test func `an unreferenced star window definition out-of-range faults`()
      throws {
    try rejects("SELECT * FROM T WINDOW w AS (ORDER BY 9)", .column("9"))
  }
}

// MARK: - Bare compile entry ordinal binding

extension FixtureCatalog {
  /// The rows `select` yields compiled through the bare `Catalog.compile(_
  /// select:)` entry — the documented direct compile a caller reaches without
  /// the `Query` wrapper `run` enters through (`Query.expanded`/
  /// `Select.inlined`). It optimises and executes the bare plan so a test can
  /// prove the bare entry ranks a window exactly as the `Query` entry does.
  fileprivate func run(bare select: Select)
      throws(SQLError) -> Array<Array<Value>> {
    let context = Context().validating(false).resolving(Subqueries())
    let plan = try compile(select, context).demoted().pushdown()
    return try execute(optimise(plan, context), context).map(\.values)
  }
}

/// The documented bare `Catalog.compile(_ select:)` entry and the `run`
/// (`Query`) entry must bind a window `ORDER BY` output ordinal identically —
/// both against the projected surface — so the two compilation entries yield
/// one window ranking (PR #322). The bare entry runs the same `Select.inlined`
/// prelude the `Query` wrapper runs, so a non-star projection's ordinal is
/// resolved before either reaches the window lowering, which then meets an
/// unbound ordinal only for a genuine `SELECT *`.
struct BareCompileEntryOrdinalTests {
  private func fixture() throws -> FixtureCatalog {
    // a order (3, 1, 2), b order (1, 3, 2), and source order all differ, so
    // which column an ordinal binds to is observable in the ranking.
    try Catalog {
      Relation("T", ["a": .integer, "b": .integer]) {
        Row(3, 1)
        Row(1, 3)
        Row(2, 2)
      }
    }
  }

  @Test func `the bare entry ranks a window like the query entry`() throws {
    let catalog = try fixture()
    let sql = "SELECT b, ROW_NUMBER() OVER (ORDER BY 1) FROM T"
    // Projected column 1 is b, so ordinal 1 orders the window on b (1, 2, 3):
    // b=1 ranks 1, b=2 ranks 2, b=3 ranks 3, kept in source order. Binding to
    // source column a instead would rank the first row 3 — the drift #322
    // reported — so the two results would differ.
    let expected: Array<Array<Value>> = [[.integer(1), .integer(1)],
                                         [.integer(3), .integer(3)],
                                         [.integer(2), .integer(2)]]
    let bare = try catalog.run(bare: parse(select: sql))
    let query = try catalog.run(parse(query: sql), [:])
    #expect(bare == expected)
    #expect(query == expected)
    #expect(bare == query)
  }

  @Test func `the bare entry binds a star ordinal like the query entry`()
      throws {
    let catalog = try fixture()
    let sql = "SELECT * FROM T ORDER BY ROW_NUMBER() OVER (ORDER BY 1)"
    // A `SELECT *` leaves the ordinal for the window lowering, which binds it
    // against the expanded star columns — ordinal 1 is a — so the rows come
    // out in a order (1, 2, 3). Both entries agree.
    let expected: Array<Array<Value>> = [[.integer(1), .integer(3)],
                                         [.integer(2), .integer(2)],
                                         [.integer(3), .integer(1)]]
    let bare = try catalog.run(bare: parse(select: sql))
    let query = try catalog.run(parse(query: sql), [:])
    #expect(bare == expected)
    #expect(bare == query)
  }

  @Test func `the bare entry faults an out-of-range ordinal`() throws {
    let catalog = try fixture()
    // Two projected columns, so ordinal 9 is out of range — `.column` (42703),
    // the same fault the `Query` entry raises on both paths.
    let sql = "SELECT b, ROW_NUMBER() OVER (ORDER BY 9) FROM T"
    #expect(throws: SQLError.column("9")) {
      _ = try catalog.run(bare: parse(select: sql))
    }
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

// MARK: - Distribution execution

/// `NTILE(n)` buckets the ordered partition; `PERCENT_RANK()` and `CUME_DIST()`
/// are ratio ranks over the partition (a double). `columns(of:)` types the
/// column — integer for `NTILE`, double for the ratios — matching the run.
struct DistributionExecutionTests {
  @Test func `NTILE splits the partition into equal buckets`() throws {
    // 5 rows, 2 buckets: the first bucket takes the extra row (3 then 2).
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
        Row(40)
        Row(50)
      }
    }
    try catalog.expect(
        "SELECT x, NTILE(2) OVER (ORDER BY x) FROM T",
        yields: [[10, 1], [20, 1], [30, 1], [40, 2], [50, 2]])
  }

  @Test func `NTILE spreads the remainder across the leading buckets`()
      throws {
    // 5 rows, 3 buckets: the first two buckets take two rows, the last one.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
        Row(40)
        Row(50)
      }
    }
    try catalog.expect(
        "SELECT x, NTILE(3) OVER (ORDER BY x) FROM T",
        yields: [[10, 1], [20, 1], [30, 2], [40, 2], [50, 3]])
  }

  @Test func `PERCENT_RANK is the peer-relative rank`() throws {
    // rank starts 1, 2, 2, 4 → (rank - 1) / (rows - 1) over 4 rows.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, PERCENT_RANK() OVER (ORDER BY x) FROM T",
        yields: [[10, 0.0], [20, 1.0 / 3.0], [20, 1.0 / 3.0], [30, 1.0]])
  }

  @Test func `CUME_DIST counts through the peer group`() throws {
    // Rows through the peer group over total: 1/4, 3/4, 3/4, 4/4.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(20)
        Row(30)
      }
    }
    try catalog.expect(
        "SELECT x, CUME_DIST() OVER (ORDER BY x) FROM T",
        yields: [[10, 0.25], [20, 0.75], [20, 0.75], [30, 1.0]])
  }

  @Test func `NTILE resets per partition`() throws {
    let catalog = try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
        Row(1, 20)
        Row(2, 100)
        Row(2, 200)
      }
    }
    try catalog.expect(
        "SELECT d, x, NTILE(2) OVER (PARTITION BY d ORDER BY x) FROM T",
        yields: [[1, 10, 1], [1, 20, 2], [2, 100, 1], [2, 200, 2]])
  }

  @Test func `the schema types the distribution columns`() throws {
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
      }
    }
    let query = try parse(query:
        """
        SELECT NTILE(2) OVER (ORDER BY x) AS n,
               PERCENT_RANK() OVER (ORDER BY x) AS p,
               CUME_DIST() OVER (ORDER BY x) AS c
        FROM T
        """)
    let columns = try catalog.columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["n", "p", "c"])
    #expect(columns.map(\.type) == [.integer, .double, .double])
  }
}

// MARK: - GROUPS frame execution

/// A `GROUPS` frame is measured in peer groups — maximal runs of rows sharing
/// the window `ORDER BY` key — so `GROUPS BETWEEN n PRECEDING AND m FOLLOWING`
/// frames every row from the start of the peer group `n` groups before the
/// current row's group through the end of the group `m` after it. `CURRENT ROW`
/// is the whole current peer group; the `UNBOUNDED` edges are the partition
/// ends. It differs from the equivalent `ROWS` frame wherever the order key
/// ties, since a group can hold several rows.
struct GroupsFrameExecutionTests {
  /// Ordered by `k` the rows fall in three peer groups — `{1,1}`, `{2}`,
  /// `{3,3}` — so a group frame spans whole ties where the row frame would
  /// split them.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(1, 10)
        Row(1, 20)
        Row(2, 30)
        Row(3, 40)
        Row(3, 50)
      }
    }
  }

  @Test func `SUM over one group either side frames whole peer groups`()
      throws {
    // Group frame [group - 1, group + 1]: the first group sees groups 0-1
    // (10+20+30 = 60); the middle group sees every group (150); the last sees
    // groups 1-2 (30+40+50 = 120). Each row of a group takes its group's frame.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 60], [1, 20, 60], [2, 30, 150],
                 [3, 40, 120], [3, 50, 120]])
  }

  @Test func `the group frame differs from the equivalent row frame`() throws {
    // The same bounds over ROWS count physical rows, splitting the ties: the
    // group frame's 60/60/150/120/120 becomes 30/60/90/120/90.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 30], [1, 20, 60], [2, 30, 90],
                 [3, 40, 120], [3, 50, 90]])
  }

  @Test func `CURRENT ROW frames the whole current peer group`() throws {
    // `GROUPS BETWEEN CURRENT ROW AND CURRENT ROW` is the current group alone:
    // both 1s sum 30, the 2 sums 30, both 3s sum 90.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN CURRENT ROW AND CURRENT ROW)
        FROM T
        """,
        yields: [[1, 10, 30], [1, 20, 30], [2, 30, 30],
                 [3, 40, 90], [3, 50, 90]])
  }

  @Test func `UNBOUNDED PRECEDING runs through the current group`() throws {
    // A running group frame: the partition start through the current group's
    // end — 30, then 60, then 150 for the last group.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[1, 10, 30], [1, 20, 30], [2, 30, 60],
                 [3, 40, 150], [3, 50, 150]])
  }

  @Test func `UNBOUNDED FOLLOWING reaches the partition end`() throws {
    // The current group's start through the partition end: 150, 120, 90.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 150], [1, 20, 150], [2, 30, 120],
                 [3, 40, 90], [3, 50, 90]])
  }

  @Test func `a following-only group frame is empty past the last group`()
      throws {
    // `GROUPS BETWEEN 1 FOLLOWING AND 2 FOLLOWING`: group 0 sees groups 1-2
    // (30+40+50 = 120); group 1 sees group 2 (90); group 2 has no following
    // group, so the frame is empty and SUM is NULL.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN 1 FOLLOWING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 120], [1, 20, 120], [2, 30, 90],
                 [3, 40, nil], [3, 50, nil]])
  }

  @Test func `the schema types a GROUPS-framed aggregate window`() throws {
    // Both paths type the framed column: SUM over integers an integer — the run
    // folds the group frames and validate types the column, run ≡ validate.
    let query = try parse(query:
        """
        SELECT SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS s
        FROM T
        """)
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["s"])
    #expect(columns.map(\.type) == [.integer])
  }

  @Test func `an unordered GROUPS frame is one whole-partition peer group`()
      throws {
    // With no window ORDER BY every partition row is a peer, so the whole
    // partition is a single peer group and `GROUPS BETWEEN CURRENT ROW AND
    // CURRENT ROW` frames it entire — every row takes the partition total
    // (150). Pre-fix this faulted 42601 ("a GROUPS window frame requires an
    // ORDER BY").
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (GROUPS BETWEEN CURRENT ROW AND CURRENT ROW)
        FROM T
        """,
        yields: [[1, 10, 150], [1, 20, 150], [2, 30, 150],
                 [3, 40, 150], [3, 50, 150]])
  }

  @Test func `unordered GROUPS offsets clamp to the single group`() throws {
    // The one peer group has no group before or after it, so `1 PRECEDING`
    // clamps to the partition start and `1 FOLLOWING` to its end — the frame is
    // still the whole partition (150). Pre-fix 42601.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 150], [1, 20, 150], [2, 30, 150],
                 [3, 40, 150], [3, 50, 150]])
  }

  @Test func `an unordered UNBOUNDED GROUPS frame spans the partition`()
      throws {
    // Both partition edges over the single group are the whole partition
    // (150). Pre-fix 42601.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (GROUPS BETWEEN UNBOUNDED PRECEDING
            AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 150], [1, 20, 150], [2, 30, 150],
                 [3, 40, 150], [3, 50, 150]])
  }

  @Test func `an unordered GROUPS frame is per-partition under PARTITION BY`()
      throws {
    // PARTITION BY k with no order: each partition is its own single peer
    // group, so `CURRENT ROW` frames that partition entire — k=1 sums 30, k=2
    // sums 30, k=3 sums 90. Pre-fix 42601.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (PARTITION BY k
            GROUPS BETWEEN CURRENT ROW AND CURRENT ROW)
        FROM T
        """,
        yields: [[1, 10, 30], [1, 20, 30], [2, 30, 30],
                 [3, 40, 90], [3, 50, 90]])
  }

  @Test func `an unordered GROUPS FIRST_VALUE reads the partition first`()
      throws {
    // One whole-partition peer group, so FIRST_VALUE reads the partition's
    // first row (10, in its original unordered position) on every row. Pre-fix
    // 42601.
    try fixture().expect(
        """
        SELECT k, v, FIRST_VALUE(v) OVER (GROUPS BETWEEN UNBOUNDED PRECEDING
            AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 10], [1, 20, 10], [2, 30, 10],
                 [3, 40, 10], [3, 50, 10]])
  }

  @Test func `an unordered GROUPS LAST_VALUE reads the partition last`()
      throws {
    // The mirror: LAST_VALUE reads the partition's last row (50) throughout.
    // Pre-fix 42601.
    try fixture().expect(
        """
        SELECT k, v, LAST_VALUE(v) OVER (GROUPS BETWEEN UNBOUNDED PRECEDING
            AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 50], [1, 20, 50], [2, 30, 50],
                 [3, 40, 50], [3, 50, 50]])
  }
}

// MARK: - RANGE numeric offset frame execution

/// A numeric-offset `RANGE` frame is value-based: `RANGE BETWEEN n PRECEDING
/// AND m FOLLOWING` frames every row whose single order-key value lies in the
/// band `[current - n, current + m]` (ASC; the direction flips under DESC,
/// where a
/// `PRECEDING` bound is the larger-valued side). It differs from both `ROWS`
/// (physical rows) and `GROUPS` (whole peer groups) wherever the key has gaps
/// or ties, and a NULL key frames only its NULL peers.
struct RangeOffsetFrameExecutionTests {
  /// Gaps (2 → 4 → 7) and a tie (two 2s) so a value band `[k - n, k + m]`
  /// picks out a different row set than a row count or a group count would.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(1, 10)
        Row(2, 20)
        Row(2, 30)
        Row(4, 40)
        Row(7, 50)
      }
    }
  }

  @Test func `SUM bands the order-key value`() throws {
    // Band [k - 1, k + 1]: k=1 sees 1,2,2 (60); each k=2 sees 1,2,2 (60); k=4
    // is isolated (40); k=7 is isolated (50).
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 60], [2, 20, 60], [2, 30, 60],
                 [4, 40, 40], [7, 50, 50]])
  }

  @Test func `the value band differs from the row and group frames`() throws {
    // The same bounds over ROWS count physical neighbours (30/60/90/120/90),
    // and over GROUPS whole peer groups (60/100/100/140/90) — both distinct
    // from the value band's 60/60/60/40/50.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 30], [2, 20, 60], [2, 30, 90],
                 [4, 40, 120], [7, 50, 90]])
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 60], [2, 20, 100], [2, 30, 100],
                 [4, 40, 140], [7, 50, 90]])
  }

  @Test func `an asymmetric band ascends`() throws {
    // Band [k - 1, k + 2] ascending: k=1 sees 1,2,2 (60); each k=2 sees 1,2,2,4
    // (100); k=4 is isolated (40); k=7 is isolated (50).
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 60], [2, 20, 100], [2, 30, 100],
                 [4, 40, 40], [7, 50, 50]])
  }

  @Test func `the band direction flips under DESC`() throws {
    // Descending, a PRECEDING bound is the larger-valued side, so `1 PRECEDING
    // AND 2 FOLLOWING` bands [k - 2, k + 1]: k=1 and each k=2 see 1,2,2 (60);
    // k=4 sees 2,2,4 (90); k=7 is isolated (50) — distinct from the ascending
    // 60/100/100/40/50.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 60], [2, 20, 60], [2, 30, 60],
                 [4, 40, 90], [7, 50, 50]])
  }

  @Test func `a running value band folds to the current value`() throws {
    // `RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING`: the partition start
    // through every row with key ≤ k + 1 — 60, 60, 60, then 100 (adds 4), then
    // 150 (adds 7).
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 60], [2, 20, 60], [2, 30, 60],
                 [4, 40, 100], [7, 50, 150]])
  }

  @Test func `FIRST_VALUE and LAST_VALUE read the value band edges`() throws {
    // Over the band [k - 1, k + 1]: FIRST_VALUE reads the band's first row and
    // LAST_VALUE its last — for the tied 2s the band runs 1,2,2, so LAST_VALUE
    // is 30 (the last of the tie), not each row's own value.
    try fixture().expect(
        """
        SELECT k, FIRST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10], [2, 10], [2, 10], [4, 40], [7, 50]])
    try fixture().expect(
        """
        SELECT k, LAST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 30], [2, 30], [2, 30], [4, 40], [7, 50]])
  }

  @Test func `a NULL order key frames only its NULL peers`() throws {
    // A NULL key is comparable to no value, so its frame is exactly the NULL
    // peer run (here itself, summing 5); a non-NULL row's band never draws the
    // NULL in.
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(nil, 5)
        Row(1, 10)
        Row(2, 20)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[nil, 5, 5], [1, 10, 30], [2, 20, 30]])
  }

  @Test func `a double order key bands over a double column`() throws {
    // The band arithmetic holds for a double key: [k - 1.0, k + 1.0] over
    // 1.0, 2.0, 2.5 — k=1.0 sees 1.0,2.0 (30); k=2.0 sees 1.0,2.0,2.5 (60);
    // k=2.5 sees 2.0,2.5 (50).
    let catalog = try Catalog {
      Relation("T", ["k": .double, "v": .integer]) {
        Row(1.0, 10)
        Row(2.0, 20)
        Row(2.5, 30)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1.0, 10, 30], [2.0, 20, 60], [2.5, 30, 50]])
  }

  @Test func `the schema types a RANGE-offset aggregate window`() throws {
    // Both paths type the framed column: SUM over integers an integer, run ≡
    // validate over the value-banded frame.
    let query = try parse(query:
        """
        SELECT SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS s
        FROM T
        """)
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["s"])
    #expect(columns.map(\.type) == [.integer])
  }
}

// MARK: - Mixed frame units in one query

/// One query projecting windows of different frame units over the same
/// partition, so the per-unit conditional build of the framing geometry — a
/// `ROWS` window reading no partition-sized geometry, a `GROUPS` window the
/// group numbering, a numeric-offset `RANGE` window the order-key values —
/// runs each shape side by side and the values stay correct. A unit test
/// cannot assert the geometry a window leaves unbuilt; it proves the build is
/// still correct under the gating.
struct MixedFrameUnitsExecutionTests {
  /// Gaps (2 → 4 → 7) and a tie (two 2s) so a `ROWS`, a `GROUPS`, and a
  /// numeric-offset `RANGE` frame each pick out a different row set.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(1, 10)
        Row(2, 20)
        Row(2, 30)
        Row(4, 40)
        Row(7, 50)
      }
    }
  }

  @Test func `aggregate windows of three frame units compute together`()
      throws {
    // Over the k-ordered partition: a ROWS running sum of the two rows ending
    // at each (10, 30, 50, 70, 90); a GROUPS current-group sum (10; the tied
    // 2s each 50; 40; 50); and a RANGE band [k - 1, k + 1] sum (the 1 and both
    // 2s each 60; the isolated 4 and 7 each themselves). One query builds each
    // framing to its own unit's geometry.
    try fixture().expect(
        """
        SELECT k, v,
            SUM(v) OVER (ORDER BY k
                ROWS BETWEEN 1 PRECEDING AND CURRENT ROW),
            SUM(v) OVER (ORDER BY k
                GROUPS BETWEEN CURRENT ROW AND CURRENT ROW),
            SUM(v) OVER (ORDER BY k
                RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 10, 10, 60], [2, 20, 30, 50, 60],
                 [2, 30, 50, 50, 60], [4, 40, 70, 40, 40],
                 [7, 50, 90, 50, 50]])
  }

  @Test func `value windows of three frame units compute together`() throws {
    // The frame-sensitive value functions over the same partition: a ROWS
    // FIRST_VALUE of the two rows ending at each (10, 10, 20, 30, 40); a GROUPS
    // current-group LAST_VALUE (10; the tied 2s each 30; 40; 50); and a RANGE
    // band [k - 1, k + 1] LAST_VALUE (the 1 and both 2s each 30, the band's
    // last row; the isolated 4 and 7 each themselves). Each window's extremum
    // reads a framing built to its own unit.
    try fixture().expect(
        """
        SELECT k, v,
            FIRST_VALUE(v) OVER (ORDER BY k
                ROWS BETWEEN 1 PRECEDING AND CURRENT ROW),
            LAST_VALUE(v) OVER (ORDER BY k
                GROUPS BETWEEN CURRENT ROW AND CURRENT ROW),
            LAST_VALUE(v) OVER (ORDER BY k
                RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 10, 10, 30], [2, 20, 10, 30, 30],
                 [2, 30, 20, 30, 30], [4, 40, 30, 40, 40],
                 [7, 50, 40, 50, 50]])
  }
}

// MARK: - Measured-frame ORDER BY key typing

/// A measured frame (`GROUPS`, numeric-offset `RANGE`) types its window `ORDER
/// BY` keys through `Scope.ordering`, the surface its legality gate reads. The
/// typing must agree across every path — the run's subquery resolution, the
/// `SELECT *` projected layout, and the unused named-window validation — so the
/// same query faults or passes identically whether its window is referenced and
/// compiled, referenced and validated, or an unused definition validated then
/// dropped (the run ≡ validate tripwire).
struct MeasuredFrameOrderTypingTests {
  private func rejects(_ make: () throws -> FixtureCatalog, _ sql: String,
                       _ fault: SQLError,
                       location: Testing.SourceLocation = #_sourceLocation)
      throws {
    // The run faults, and `columns(of:validate:true)` faults identically. The
    // fixture is built afresh for each surface — a borrowed catalog cannot be
    // captured by the `#expect(throws:)` closure.
    try make().expect(sql, fails: fault, location: location)
    #expect(throws: fault, sourceLocation: location) {
      _ = try make().columns(of: parse(query: sql, location: location),
                             validate: true)
    }
  }

  // Finding 1: a scalar-subquery order key types through the compilation pre-
  // pass resolution, so a numeric-offset RANGE frame ordering by it resolves
  // rather than faulting the default `.unsupported` subquery context.
  @Test func `a RANGE offset orders by a scalar-subquery key`() throws {
    // `(SELECT MIN(x) FROM T)` is a constant order key (1), so every row is one
    // peer and the band `[1 - 1, 1]` frames the whole partition — `SUM(x)` is
    // the table total (6) on each row. Pre-fix the order-key typing ran under
    // the default `.unsupported` context and faulted 0A000 on both the run and
    // the derive, since the scalar subquery was unresolvable there.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
    }
    let sql =
        """
        SELECT x, SUM(x) OVER (ORDER BY (SELECT MIN(x) FROM T)
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """
    try catalog.expect(sql, yields: [[1, 6], [2, 6], [3, 6]])
    let columns = try catalog.columns(of: parse(query: sql), validate: true)
    #expect(columns.map(\.name) == ["x", "column 2"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }

  // Finding 2: a `SELECT *` window ORDER BY ordinal types through the projected
  // layout, not the combined source-ordinal space. `A JOIN B USING (k)` pulls
  // the merged join key `k` to the leading output, so the projected columns
  // [k, at, bt] (integer, text, text) diverge from the source-ordinal space
  // (whose ordinal 0 is A's leading `at`, text) — a plain `type(at:)` read
  // mistypes the ordinal, deciding a projected column's numeric gate from a
  // different column's type.
  private func joined() throws -> FixtureCatalog {
    try Catalog {
      Relation("A", ["at": .text, "k": .integer]) {
        Row("x", 5)
        Row("y", 9)
      }
      Relation("B", ["bt": .text, "k": .integer]) {
        Row("p", 5)
        Row("q", 9)
      }
    }
  }

  @Test func `a star ordinal on a numeric projected output is accepted`()
      throws {
    // Ordinal 1 names the projected merged key `k` (integer), so the numeric
    // key gate passes and the frame orders by it. Pre-fix `type(at: 0)` read
    // the source ordinal `A.at` (text) and wrongly rejected this valid numeric
    // ordering. Ordering by `k` (5, 9) leaves the star rows in `k`-ascending
    // order.
    let sql =
        """
        SELECT * FROM A JOIN B USING (k)
        ORDER BY SUM(k) OVER (ORDER BY 1
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        """
    try joined().expect(sql, yields: [[5, "x", "p"], [9, "y", "q"]])
    let columns = try joined().columns(of: parse(query: sql), validate: true)
    #expect(columns.map(\.name) == ["k", "at", "bt"])
    #expect(columns.map(\.type) == [.integer, .text, .text])
  }

  @Test func `a star ordinal on a text projected output is rejected`() throws {
    // Ordinal 2 names the projected `at` (text), so the numeric-key gate faults
    // 42601. Pre-fix `type(at: 1)` read the source ordinal `A.k` (integer), so
    // the gate passed and the RANGE offset was silently ignored.
    try rejects(
        { try joined() },
        """
        SELECT * FROM A JOIN B USING (k)
        ORDER BY SUM(k) OVER (ORDER BY 2
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        """,
        .state("42601",
               "a RANGE offset frame requires a numeric ORDER BY key"))
  }

  // Finding 3: an unused named window's measured frame is held to the same
  // order/type requirements a referenced one is, so the two paths agree.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["x": .integer, "name": .text]) {
        Row(1, "a")
        Row(2, "b")
      }
    }
  }

  @Test func `an unused RANGE offset without an ORDER BY faults`() throws {
    // Referencing `w` faults 42601 for the missing single order key; an unused
    // `w` faults identically rather than being accepted and dropped.
    let fault = SQLError.state("42601",
        "a RANGE offset frame requires a single ORDER BY key")
    try rejects(
        { try fixture() },
        """
        SELECT SUM(x) OVER w FROM T
        WINDOW w AS (RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        """,
        fault)
    try rejects(
        { try fixture() },
        """
        SELECT x FROM T
        WINDOW w AS (RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        """,
        fault)
  }

  @Test func `an unused RANGE offset over a non-numeric key faults`() throws {
    // Referencing `w` faults 42601 for the non-numeric order key; an unused `w`
    // faults identically — the same SQLSTATE and message.
    let fault = SQLError.state("42601",
        "a RANGE offset frame requires a numeric ORDER BY key")
    try rejects(
        { try fixture() },
        """
        SELECT COUNT(*) OVER w FROM T
        WINDOW w AS (ORDER BY name RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        """,
        fault)
    try rejects(
        { try fixture() },
        """
        SELECT x FROM T
        WINDOW w AS (ORDER BY name RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        """,
        fault)
  }

  @Test func `an unused GROUPS window without an ORDER BY validates`() throws {
    // A GROUPS frame needs no ORDER BY: with none the whole partition is one
    // peer group. So an unused `w` validates rather than faulting 42601, and
    // referencing it runs the whole-partition frame — run ≡ validate. Pre-fix
    // both the reference and the unused definition faulted 42601 ("a GROUPS
    // window frame requires an ORDER BY").
    let unused =
        """
        SELECT x FROM T
        WINDOW w AS (GROUPS BETWEEN CURRENT ROW AND CURRENT ROW)
        """
    let columns = try fixture().columns(of: parse(query: unused),
                                        validate: true)
    #expect(columns.map(\.name) == ["x"])
    // Referencing `w` runs: the whole partition (x = 1, 2) sums 3 on each row.
    try fixture().expect(
        """
        SELECT SUM(x) OVER w FROM T
        WINDOW w AS (GROUPS BETWEEN CURRENT ROW AND CURRENT ROW)
        """,
        yields: [[3], [3]])
  }
}

// MARK: - RANGE numeric offset frame overflow edges

/// A numeric-offset `RANGE` band edge that runs past `Int`'s range on an
/// extreme order key resolves to an empty edge, not the extreme key's own peer
/// group: a shifted target beyond every key lies off the partition on that
/// side, so its boundary search yields an off-partition sentinel. The direction
/// folds in — an add-overflow sits past the late (high-index) end under `ASC`
/// but past the early end under `DESC`, and a subtract-overflow the reverse.
struct RangeOffsetOverflowTests {
  @Test func `an ASC add-overflow following edge frames nothing`() throws {
    // Ascending, a row keyed `Int.max` with `RANGE BETWEEN 1 FOLLOWING AND 1
    // FOLLOWING` bands `[max + 1, max + 1]`, above every key, so the frame is
    // empty and `SUM` is NULL. Saturating the edge to `Int.max` would wrongly
    // draw the `Int.max` row in (yielding 30).
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(1, 10)
        Row(2, 20)
        Row(Int.max, 30)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 FOLLOWING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 20], [2, 20, nil], [Int.max, 30, nil]])
  }

  @Test func `an ASC subtract-overflow preceding edge frames nothing`()
      throws {
    // Ascending, a row keyed `Int.min` with `RANGE BETWEEN 1 PRECEDING AND 1
    // PRECEDING` bands `[min - 1, min - 1]`, below every key, so the frame is
    // empty and `SUM` is NULL. Saturating the edge to `Int.min` would wrongly
    // draw the `Int.min` row in (yielding 10).
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(Int.min, 10)
        Row(1, 20)
        Row(2, 30)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 PRECEDING)
        FROM T
        """,
        yields: [[Int.min, 10, nil], [1, 20, nil], [2, 30, 20]])
  }

  @Test func `a DESC subtract-overflow following edge frames nothing`()
      throws {
    // Descending, a `FOLLOWING` bound is the smaller-valued side, so a row
    // keyed `Int.min` with `RANGE BETWEEN 1 FOLLOWING AND 1 FOLLOWING` bands
    // `[min - 1, min - 1]`, past the late end of descending order — an empty
    // frame, NULL. This mirrors the ascending add-overflow: the empty edge
    // depends on both the sort and the bound direction, not the sign alone.
    // Saturating to `Int.min` would draw the `Int.min` row in (yielding 30).
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(2, 10)
        Row(1, 20)
        Row(Int.min, 30)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 FOLLOWING AND 1 FOLLOWING)
        FROM T
        """,
        yields: [[2, 10, 20], [1, 20, nil], [Int.min, 30, nil]])
  }

  @Test func `a non-overflow edge near Int.max still frames its band`()
      throws {
    // The fix must not over-empty: an edge that does not overflow bands as
    // before. The `Int.max` row with `RANGE BETWEEN 1 PRECEDING AND CURRENT
    // ROW` shifts to `Int.max - 1`, drawing in the `Int.max - 1` peer (20) and
    // itself (30) for 50 — unchanged by the overflow path.
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(1, 10)
        Row(Int.max - 1, 20)
        Row(Int.max, 30)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[1, 10, 10], [Int.max - 1, 20, 20], [Int.max, 30, 50]])
  }
}

// MARK: - RANGE numeric offset frame NULL runs at an unbounded edge

/// A `NULL` order key sorts to one physical end of window order — the low end
/// under `ASC` (adjacent to `UNBOUNDED PRECEDING`), the high end under `DESC`
/// (adjacent to `UNBOUNDED FOLLOWING`). A numeric-offset `RANGE` edge that runs
/// off the present (non-`NULL`) span resolves to that span's boundary, not the
/// partition's, so a `NULL` run lying on an unbounded side stays in the frame;
/// the frame's intersection with the value-bounded other edge then self-gates
/// whether the run is actually drawn in. These pin that a `NULL` peer adjacent
/// to an unbounded edge is retained while a value-versus-value band leaves it
/// out.
struct RangeOffsetUnboundedNullTests {
  /// Ascending, a leading `NULL` run at the low end of window order, next to
  /// `UNBOUNDED PRECEDING`; distinct values pin which rows the band draws in.
  private func leading() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(nil, 100)
        Row(1, 10)
        Row(2, 20)
      }
    }
  }

  @Test func `UNBOUNDED PRECEDING retains a leading NULL peer`() throws {
    // `RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING`: at k=1 the upper
    // edge shifts to 0, past every present key, resolving to the low `NULL`
    // index rather than an empty edge — the frame is the leading `NULL` row, so
    // `LAST_VALUE` reads its 100, not the empty frame's `NULL`. At k=2 the edge
    // lands on the k=1 row, framing the `NULL` row and the k=1 row, so
    // `LAST_VALUE` reads the k=1 row's 10. The `NULL` key's own frame is its
    // peer group. The frame edge is read directly (not through the aggregate's
    // running fold), so the value functions expose the boundary.
    try leading().expect(
        """
        SELECT k, v, LAST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        FROM T
        """,
        yields: [[nil, 100, 100], [1, 10, 100], [2, 20, 10]])
    // `FIRST_VALUE` pins the leading `NULL` as the frame's first row at k=1 and
    // k=2 alike — 100, the `NULL` row's value, never the empty frame's `NULL`.
    try leading().expect(
        """
        SELECT k, v, FIRST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        FROM T
        """,
        yields: [[nil, 100, 100], [1, 10, 100], [2, 20, 100]])
  }

  @Test func `UNBOUNDED FOLLOWING retains a trailing NULL peer`() throws {
    // Descending, the `NULL` run sits at the high end next to `UNBOUNDED
    // FOLLOWING`. `RANGE BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING`: at k=1
    // the lower edge shifts past the last present key and resolves to the high
    // `NULL` index, so the frame is the trailing `NULL` row and `FIRST_VALUE`
    // reads its 99 (not the empty frame's `NULL`). At k=2 the edge lands on the
    // k=1 row, framing it and the `NULL` row, so `FIRST_VALUE` reads the k=1
    // row's 10. The `NULL` key frames only its peer.
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(2, 20)
        Row(1, 10)
        Row(nil, 99)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, FIRST_VALUE(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING)
        FROM T
        """,
        yields: [[2, 20, 10], [1, 10, 99], [nil, 99, 99]])
  }

  @Test func `an overflow edge retains a leading NULL peer`() throws {
    // The overflow short-circuit takes the same present boundary. Ascending
    // `[NULL, Int.min]` with `RANGE BETWEEN UNBOUNDED PRECEDING AND 1
    // PRECEDING`: at k=Int.min the upper edge subtract-overflows `Int`, so it
    // resolves to the low `NULL` index rather than the `-1` sentinel — the
    // frame is the leading `NULL` row, so `LAST_VALUE` reads its 100, not the
    // empty frame's `NULL`.
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(nil, 100)
        Row(Int.min, 10)
      }
    }
    try catalog.expect(
        """
        SELECT k, v, LAST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        FROM T
        """,
        yields: [[nil, 100, 100], [Int.min, 10, 100]])
  }

  @Test func `a value-versus-value band leaves the NULL run out`() throws {
    // The self-gating regression guard: with both edges value-bounded, a
    // `NULL` run is never drawn in. `RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING`
    // at k=1 has a start edge that cannot reach below the present span, so it
    // stays empty and `SUM` is `NULL`; only the unbounded cases above gain the
    // adjacent `NULL`.
    try leading().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 2 PRECEDING AND 1 PRECEDING)
        FROM T
        """,
        yields: [[nil, 100, 100], [1, 10, nil], [2, 20, 10]])
  }
}

// MARK: - RANGE numeric offset frame band search

/// A numeric-offset `RANGE` band edge is located by a direction-aware binary
/// search over the partition's precomputed non-`NULL` key span, replacing the
/// per-row linear scan. These pin the search's tie boundaries — a `start` edge
/// takes the first of a tie run at or after the lower edge (a lower bound) and
/// an `end` edge the last of a tie run at or before the upper edge (an upper
/// bound) — under both `ASC` and `DESC`, so the search matches the old scan.
struct RangeOffsetBandSearchTests {
  /// Ties (three 3s) and gaps (1 → 3 → 5 → 8) with distinct values, so a value
  /// band's membership and its `FIRST_VALUE`/`LAST_VALUE` edges reveal exactly
  /// which slot the search lands on.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(1, 10)
        Row(3, 20)
        Row(3, 30)
        Row(3, 40)
        Row(5, 50)
        Row(8, 60)
      }
    }
  }

  @Test func `an ascending band draws the tie-correct rows`() throws {
    // Band [k - 2, k + 2] ascending: k=1 sees 1,3,3,3 (100); each k=3 sees
    // 1,3,3,3,5 (150); k=5 sees 3,3,3,5 (140); k=8 is isolated (60). The tie
    // run of 3s is wholly in or out of a band, never split.
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 100], [3, 20, 150], [3, 30, 150],
                 [3, 40, 150], [5, 50, 140], [8, 60, 60]])
  }

  @Test func `ascending edges land on the tie run bounds`() throws {
    // FIRST_VALUE reads the start edge, LAST_VALUE the end edge of [k - 2,
    // k + 2]. k=5's start edge (value 3) is the FIRST of the tie run (20, a
    // lower bound); k=1's end edge (value 3) is the LAST of the tie run (40, an
    // upper bound). k=8's start edge (value 6) has no exact key, so it lands on
    // the next key up (60); k=5's end edge (value 7) lands on the key below
    // (50).
    try fixture().expect(
        """
        SELECT k, FIRST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10], [3, 10], [3, 10], [3, 10], [5, 20], [8, 60]])
    try fixture().expect(
        """
        SELECT k, LAST_VALUE(v) OVER (ORDER BY k
            RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 40], [3, 50], [3, 50], [3, 50], [5, 50], [8, 60]])
  }

  @Test func `a descending band draws the tie-correct rows`() throws {
    // Descending, a PRECEDING bound is the larger-valued side, so `1 PRECEDING
    // AND 2 FOLLOWING` bands [k - 2, k + 1]: k=1 is isolated (10); each k=3
    // sees 1,3,3,3 (100); k=5 sees 3,3,3,5 (140); k=8 is isolated (60).
    try fixture().expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10, 10], [3, 20, 100], [3, 30, 100],
                 [3, 40, 100], [5, 50, 140], [8, 60, 60]])
  }

  @Test func `descending edges land on the tie run bounds`() throws {
    // Under DESC window order (8,5,3,3,3,1) the band [k - 2, k + 1].
    // FIRST_VALUE reads the frame's first row (the larger-keyed side),
    // LAST_VALUE its last
    // (the smaller). Each k=3's frame runs 3,3,3,1, so FIRST_VALUE is the first
    // of the tie run (20) and LAST_VALUE the trailing key 1 (10); k=5's frame
    // runs 5,3,3,3, so LAST_VALUE is the last of the tie run (40).
    try fixture().expect(
        """
        SELECT k, FIRST_VALUE(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10], [3, 20], [3, 20], [3, 20], [5, 50], [8, 60]])
    try fixture().expect(
        """
        SELECT k, LAST_VALUE(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 PRECEDING AND 2 FOLLOWING)
        FROM T
        """,
        yields: [[1, 10], [3, 10], [3, 10], [3, 10], [5, 40], [8, 60]])
  }

  @Test func `a NULL peer run stays outside every value band`() throws {
    // Two NULL keys form a peer run the search excludes from `present`: under
    // ASC the NULLs sort to the low index end, under DESC to the high end, so
    // each spans a different edge of the non-NULL range. Either way a NULL row
    // frames only its NULL peers (5,7 → 12) and no non-NULL band draws a NULL
    // in — k=1's band [0,2] sees 1,2 (30), never the NULLs beside it.
    let catalog = try Catalog {
      Relation("T", ["k": .integer, "v": .integer]) {
        Row(nil, 5)
        Row(nil, 7)
        Row(1, 10)
        Row(2, 20)
        Row(4, 40)
      }
    }
    let band: Array<Array<(any ValueConvertible)?>> =
        [[nil, 5, 12], [nil, 7, 12], [1, 10, 30],
         [2, 20, 30], [4, 40, 40]]
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: band)
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k DESC
            RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)
        FROM T
        """,
        yields: band)
  }

  @Test func `the band holds across a larger partition`() throws {
    // A correctness-at-size check, not a benchmark — a unit test cannot assert
    // big-O. A few dozen keyed rows with ties and gaps, each row's band
    // [k - 2, k + 3] computed independently by a brute-force value-membership
    // scan (the naive definition the binary search replaces) and matched
    // against the engine's searched band, so the search stays correct at size.
    let keys = [0, 0, 1, 3, 3, 3, 4, 7, 7, 10, 10, 10, 11, 12, 14, 14,
                17, 17, 17, 20, 21, 21, 24, 24, 24, 25, 28, 30, 30, 33]
    let catalog = FixtureCatalog(
        ["T": FixtureRelation(
            [FixtureField(name: "k", type: .integer),
             FixtureField(name: "v", type: .integer)],
            keys.indices.map { [.integer(keys[$0]), .integer($0)] })])
    let expected: Array<Array<(any ValueConvertible)?>> =
        keys.indices.map { slot in
          let key = keys[slot]
          let total = keys.indices
              .filter { keys[$0] >= key - 2 && keys[$0] <= key + 3 }
              .reduce(0, +)
          return [key, slot, total]
        }
    try catalog.expect(
        """
        SELECT k, v, SUM(v) OVER (ORDER BY k
            RANGE BETWEEN 2 PRECEDING AND 3 FOLLOWING)
        FROM T
        """,
        yields: expected)
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

  @Test func `a window nested in a window operand is rejected`() throws {
    // A window is not a scalar, so it may not be another window's operand. The
    // grouped surface made this resolvable (its `term` has a window registry),
    // so `windowing` rejects it uniformly, before resolving, on every surface.
    try rejects(
        "SELECT LEAD(RANK() OVER (ORDER BY x), 1) OVER (ORDER BY x) FROM T",
        .state("0A000",
               "a window function is not allowed in a window function"))
  }

  @Test func `a window nested in a window ORDER BY is rejected`() throws {
    try rejects(
        "SELECT RANK() OVER (ORDER BY RANK() OVER (ORDER BY x)) FROM T",
        .state("0A000",
               "a window function is not allowed in a window function"))
  }

  @Test func `a window nested in an aggregate window argument is rejected`()
      throws {
    try rejects(
        "SELECT SUM(ROW_NUMBER() OVER ()) OVER () FROM T",
        .state("0A000",
               "a window function is not allowed in a window function"))
  }

  @Test func `a window ORDER BY ordinal naming a window output is rejected`()
      throws {
    // Ordinal 1 names the sole projected column, which is the window itself; a
    // window cannot order by another window's value (it does not exist until
    // every windowing is computed from the source rows), so it faults on both
    // paths.
    try rejects(
        "SELECT ROW_NUMBER() OVER (ORDER BY 1) FROM T",
        .state("0A000",
               "a window ORDER BY cannot order by a window output column"))
  }

  @Test func `a window ORDER BY ordinal past the projection faults`() throws {
    // Two projected columns (x and the window), so ordinal 5 is out of range —
    // the same `.column` (42703) fault, spelled as the ordinal, a query-level
    // out-of-range ORDER BY ordinal raises, on both paths.
    try rejects("SELECT x, ROW_NUMBER() OVER (ORDER BY 5) FROM T",
                .column("5"))
  }

  @Test func `a window ORDER BY ordinal below one faults`() throws {
    // An ordinal is 1-based, so 0 is out of range and faults `.column`.
    try rejects("SELECT x, ROW_NUMBER() OVER (ORDER BY 0) FROM T",
                .column("0"))
  }

  @Test func `a RANGE offset frame without an ORDER BY is rejected`() throws {
    // A numeric-offset RANGE band measures against the single order-key value;
    // with no ORDER BY there is none, so both paths fault 42601. (A numeric
    // RANGE offset over one ordered key now executes — see the offset suite.)
    try rejects(
        """
        SELECT SUM(x) OVER (RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        .state("42601",
               "a RANGE offset frame requires a single ORDER BY key"))
  }

  @Test func `a RANGE offset frame with two ORDER BY keys is rejected`()
      throws {
    // The band measures one value, so a pair of order keys is ambiguous —
    // 42601 on both the run and validate paths.
    let sql =
        """
        SELECT SUM(a) OVER (ORDER BY a, b
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """
    let fault = SQLError.state("42601",
        "a RANGE offset frame requires a single ORDER BY key")
    try Catalog {
      Relation("T", ["a": .integer, "b": .integer]) { Row(1, 2) }
    }.expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try Catalog {
        Relation("T", ["a": .integer, "b": .integer]) { Row(1, 2) }
      }.columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a RANGE offset frame over a non-numeric key is rejected`()
      throws {
    // The offset arithmetic is numeric, so a text order key cannot be banded
    // (the engine has no datetime/interval arithmetic) — 42601 on both paths.
    let sql =
        """
        SELECT COUNT(*) OVER (ORDER BY name
            RANGE BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """
    let fault = SQLError.state("42601",
        "a RANGE offset frame requires a numeric ORDER BY key")
    try Catalog {
      Relation("T", ["name": .text]) { Row("a") }
    }.expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try Catalog {
        Relation("T", ["name": .text]) { Row("a") }
      }.columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `an unordered GROUPS frame frames the whole partition`() throws {
    // A GROUPS frame needs no ORDER BY — with none every partition row is a
    // peer, so the whole partition is one peer group and the frame resolves
    // against it. `1 PRECEDING AND CURRENT ROW` clamps to the partition start
    // and the single group's end, framing every row (the table total). Pre-fix
    // this faulted 42601 ("a GROUPS window frame requires an ORDER BY").
    try Catalog {
      Relation("T", ["x": .integer]) {
        Row(10)
        Row(20)
        Row(30)
      }
    }.expect(
        """
        SELECT SUM(x) OVER (GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        yields: [[60], [60], [60]])
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

  @Test func `NTILE with a non-positive bucket count is rejected`() throws {
    try rejects(
        "SELECT NTILE(0) OVER (ORDER BY x) FROM T",
        .state("22023", "NTILE requires a positive bucket count"))
  }

  @Test func `NTH_VALUE with a zero position is rejected`() throws {
    // Position 0 is meaningless (positions are 1-based) — rejected at parse, so
    // the executor never computes the frame index `lo + 0 - 1` and subscripts a
    // row before the partition start.
    try rejects(
        "SELECT NTH_VALUE(x, 0) OVER (ORDER BY x) FROM T",
        .state("22023", "NTH_VALUE requires a positive position"))
  }

  @Test func `an unused named window is validated before being dropped`()
      throws {
    // With no window function, the WINDOW clause is dropped — but not before
    // each definition is validated: an undefined base and an unresolvable ORDER
    // BY column each fault, rather than the query silently executing.
    try rejects("SELECT x FROM T WINDOW w AS (missing)",
                .state("42704", "window \"missing\" is not defined"))
    try rejects("SELECT x FROM T WINDOW w AS (ORDER BY nonesuch)",
                .column("nonesuch"))
  }

  @Test func `an unused but valid named window still runs`() throws {
    // A resolvable unused definition is not an error — the query runs.
    try fixture().expect("SELECT x FROM T WINDOW w AS (ORDER BY x)",
                         yields: [[1], [2]])
  }

  @Test func `an unused definition is validated even beside a used window`()
      throws {
    // A window function is present, so the query runs the window path — but an
    // undefined base in an unused definition is still an error, not accepted
    // because nothing references it.
    try rejects("SELECT ROW_NUMBER() OVER () FROM T WINDOW bad AS (missing)",
                .state("42704", "window \"missing\" is not defined"))
  }

  @Test func `an unused definition is validated in an aggregate query`()
      throws {
    // An aggregate query with no window used validates its `WINDOW` clause on
    // the base scope (in `front`), like any query — an undefined base still
    // faults rather than the query grouping regardless.
    try rejects("SELECT SUM(x) FROM T WINDOW bad AS (missing)",
                .state("42704", "window \"missing\" is not defined"))
  }

  @Test func `an unused valid definition runs in an aggregate query`() throws {
    // The one aggregate makes this a whole-result aggregation with no window
    // used, so the unused `WINDOW w` validates on the input scope — `x` is an
    // ordinary column there, NOT a non-GROUP BY column faulting `.grouping`, as
    // it would were the definition (wrongly) validated on the grouped surface
    // where no window ever computes. The query runs, counting the two rows.
    try fixture().expect("SELECT COUNT(*) FROM T WINDOW w AS (ORDER BY x)",
                         yields: [[2]])
    #expect(try fixture().columns(
        of: parse(query: "SELECT COUNT(*) FROM T WINDOW w AS (ORDER BY x)"),
        validate: true).count == 1)
  }

  @Test func `an unused bad-column definition faults in an aggregate query`()
      throws {
    // The base-scope validation still catches an unresolvable column in an
    // unused definition of an aggregate query — it is not silently accepted
    // because no window references it.
    try rejects("SELECT COUNT(*) FROM T WINDOW w AS (ORDER BY nonesuch)",
                .column("nonesuch"))
  }

  @Test func `an unused definition may name an aggregate`() throws {
    // A dead definition is validated for well-formedness only, so an aggregate
    // in its spec is admitted (its argument resolves) with no grouped slot to
    // materialise — the one check that fits both an ordinary column and an
    // aggregate, since a used definition validates strictly by its inlined
    // form. It holds whether the query aggregates (a whole-result COUNT) …
    try fixture().expect("SELECT COUNT(*) FROM T WINDOW w AS (ORDER BY SUM(x))",
                         yields: [[2]])
    // … or not (a plain projection): the aggregate in the unused spec neither
    // makes the query aggregate nor faults.
    try fixture().expect("SELECT x FROM T WINDOW w AS (ORDER BY SUM(x))",
                         yields: [[1], [2]])
    for sql in ["SELECT COUNT(*) FROM T WINDOW w AS (ORDER BY SUM(x))",
                "SELECT x FROM T WINDOW w AS (ORDER BY SUM(x))"] {
      #expect(try fixture().columns(of: parse(query: sql), validate: true)
                  .count == 1)
    }
  }

  @Test func `an unused aggregate definition over a bad column faults`()
      throws {
    // Well-formedness still resolves the aggregate's argument, so an
    // unresolvable column inside a dead definition's aggregate faults.
    try rejects("SELECT x FROM T WINDOW w AS (ORDER BY SUM(nonesuch))",
                .column("nonesuch"))
  }

  @Test func `an unused definition validates an aggregate FILTER`() throws {
    // The FILTER of an aggregate in a dead definition is a per-row predicate,
    // so an unresolved column in it faults rather than being silently dropped …
    try rejects(
        "SELECT x FROM T WINDOW w AS " +
        "(ORDER BY SUM(x) FILTER (WHERE nonesuch > 0))",
        .column("nonesuch"))
    // … while a resolvable FILTER runs.
    try fixture().expect(
        "SELECT x FROM T WINDOW w AS (ORDER BY SUM(x) FILTER (WHERE x > 0))",
        yields: [[1], [2]])
  }

  @Test func `an unused definition validates a CASE guard`() throws {
    // A CASE guard in a dead definition's spec is a per-row predicate too — an
    // aggregate-free guard's unresolved column faults …
    try rejects(
        "SELECT x FROM T WINDOW w AS " +
        "(ORDER BY CASE WHEN nonesuch > 0 THEN SUM(x) END)",
        .column("nonesuch"))
    // … while a guard that itself aggregates (valid only in a grouped context)
    // is not spuriously rejected — the aggregate operand recurses leniently.
    try fixture().expect(
        "SELECT x FROM T WINDOW w AS " +
        "(ORDER BY CASE WHEN SUM(x) > 0 THEN x END)",
        yields: [[1], [2]])
    // … yet a non-aggregate leaf beside the aggregate in such a guard is still
    // validated: the walk admits each operand, so `nonesuch` faults rather than
    // the whole aggregate-bearing guard being skipped.
    try rejects(
        "SELECT x FROM T WINDOW w AS " +
        "(ORDER BY CASE WHEN SUM(x) > nonesuch THEN x END)",
        .column("nonesuch"))
  }

  @Test func `an unused definition rejects a nested aggregate`() throws {
    // An aggregate's argument is a scalar, so it may not contain an aggregate.
    // An unused definition's argument is resolved through the same strict
    // `term` a referenced one is, so the nesting faults rather than the inner
    // aggregate being recursively admitted.
    try rejects("SELECT x FROM T WINDOW w AS (ORDER BY SUM(SUM(x)))",
                .state("42803", "an aggregate is not allowed here"))
  }

  @Test func `an unused definition faults a context-free error as a used one`()
      throws {
    // The contract: an unused definition is validated for every context-free
    // error a referenced one is — a nested aggregate, an unresolved column in
    // an aggregate argument, FILTER, or CASE guard, a window in an argument —
    // differing only in the grouping rule a dead definition is spared. A parity
    // guard over the class: each malformed spec faults identically whether the
    // window is referenced (`OVER w`) or left unused. It catches a future
    // divergence mechanically rather than one reviewed case at a time.
    func outcome(_ sql: String) throws -> SQLError? {
      do {
        _ = try fixture().columns(of: parse(query: sql), validate: true)
        return nil
      } catch let error as SQLError {
        return error
      }
    }
    let specs = [
      "ORDER BY SUM(SUM(x))",
      "ORDER BY SUM(x + COUNT(x))",
      "ORDER BY SUM(nonesuch)",
      "ORDER BY SUM(x) FILTER (WHERE nonesuch > 0)",
      "ORDER BY CASE WHEN SUM(x) > nonesuch THEN x END",
      "ORDER BY SUM(ROW_NUMBER() OVER ())",
    ]
    for spec in specs {
      let referenced =
          try outcome("SELECT ROW_NUMBER() OVER w FROM T WINDOW w AS (\(spec))")
      let unused = try outcome("SELECT x FROM T WINDOW w AS (\(spec))")
      #expect(referenced == unused, "\(spec)")
    }
  }

  @Test func `an unused definition resolves against the whole join scope`()
      throws {
    // `w` names a column of the joined `U`, absent from the FROM relation alone;
    // it resolves against the full join scope the query's own clauses see, so
    // the valid definition does not spuriously fault.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("U", ["y": .integer]) {
        Row(2)
        Row(3)
      }
    }
    try catalog.expect(
        """
        SELECT T.x FROM T JOIN U ON T.x = U.y WINDOW w AS (ORDER BY U.y)
        """,
        yields: [[2]])
  }

  @Test func `an unused definition's own subquery is collected`() throws {
    // The subquery lives only in the unused definition, not the projection or
    // ORDER BY, so the subquery pre-pass must gather it too — otherwise
    // validating `w` faults as if the subquery were in an unsupported position.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("U", ["y": .integer]) {
        Row(9)
      }
    }
    try catalog.expect(
        "SELECT x FROM T WINDOW w AS (ORDER BY (SELECT 1 FROM U))",
        yields: [[1], [2]])
  }

  @Test func `an unused definition's reversed frame is rejected`() throws {
    // An unused definition's frame is validated structurally like a referenced
    // one's: a reversed `CURRENT ROW AND 1 PRECEDING` faults rather than the
    // query silently running.
    try rejects(
        "SELECT x FROM T WINDOW w AS (ROWS BETWEEN CURRENT ROW AND 1 PRECEDING)",
        .state("42601", "a window frame start follows its end"))
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

  @Test func `a frame on a distribution function is rejected`() throws {
    try rejects(
        """
        SELECT CUME_DIST() OVER (ORDER BY x
            ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        FROM T
        """,
        .state("0A000", "a window frame is not supported for CUME_DIST"))
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

  @Test func `a window ORDER BY ordinal orders on the reported value`()
      throws {
    // The window ORDER BY names projected column 1 — the tick() value — so the
    // ordering key and the reported value are one output, a single evaluation.
    // tick() yields 1, 2, 3 once per row, the window orders on those, and the
    // row numbered k reports tick() k, so the ranking matches the reported
    // column. Evaluating the ordinal-named value twice would order on 1, 2, 3
    // yet report 4, 5, 6 — six calls, the ranking not matching the value.
    let (counter, routines) = try ticking()
    try fixture().expect(
        "SELECT tick(), ROW_NUMBER() OVER (ORDER BY 1) FROM T",
        yields: [[1, 1], [2, 2], [3, 3]], routines: routines)
    #expect(counter.count == 3)
  }

  @Test func `a grouped window ORDER BY ordinal orders on the reported value`()
      throws {
    // Each row groups alone (x is distinct), so the ordinal-named tick() value
    // reaches the window over grouped output. Materialised once below the
    // window, tick() yields 1, 2, 3 per group, the window orders on those, and
    // the row numbered k reports tick() k — the ranking matches the reported
    // column, three calls. Building the window without the materialisation
    // evaluates the ordinal-named value twice, ordering on 1, 2, 3 yet
    // reporting 4, 5, 6 over six calls, the ranking not matching the value.
    let (counter, routines) = try ticking()
    try fixture().expect(
        "SELECT tick(), ROW_NUMBER() OVER (ORDER BY 1) FROM T GROUP BY x",
        yields: [[1, 1], [2, 2], [3, 3]], routines: routines)
    #expect(counter.count == 3)
  }

  @Test func `an explicit window key equal to a projection stays independent`()
      throws {
    // The window key is written directly, not as an ordinal — it merely equals
    // the projected tick(). The two occurrences must evaluate independently:
    // the window orders on its own tick() (1, 2, 3, so the rows rank 1, 2, 3)
    // and the projection reports a separate tick() (4, 5, 6), six calls in all.
    // Treating the coincidental equality as an ordinal reference would fold the
    // two into one hoisted tick(), collapsing to three calls and reporting the
    // ordered 1, 2, 3 — a changed ranking and changed values.
    let (counter, routines) = try ticking()
    try fixture().expect(
        "SELECT tick(), ROW_NUMBER() OVER (ORDER BY tick()) FROM T",
        yields: [[4, 1], [5, 2], [6, 3]], routines: routines)
    #expect(counter.count == 6)
  }

  @Test func `distinct ordinal outputs hoist to independent slots`() throws {
    // Two select-list columns hold the same stateful expression and the window
    // orders on both by ordinal (`ORDER BY 1, 2`). The ordinals name separate
    // outputs, so each is hoisted to its own slot and evaluated independently.
    // The below-window projection computes both columns per row, left to right,
    // so column 0 yields tick() 1, 3, 5 and column 1 yields 2, 4, 6 — six calls
    // in all — and the window orders by (column 0, column 1). Keying the hoist
    // on term equality instead of the output index would fold the two
    // occurrences into one shared slot, calling tick() three times and
    // reporting identical columns.
    let (counter, routines) = try ticking()
    try fixture().expect(
        "SELECT tick(), tick(), ROW_NUMBER() OVER (ORDER BY 1, 2) FROM T",
        yields: [[1, 2, 1], [3, 4, 2], [5, 6, 3]], routines: routines)
    #expect(counter.count == 6)
  }

  @Test func `an ordinal and an explicit equal key stay independent`() throws {
    // One window orders on projected column 0 by ordinal, a second orders on a
    // directly written `tick()` that merely equals that column. The ordinal key
    // shares its one hoisted tick() with output 0 (three calls, 1, 2, 3, the
    // rows ranking 1, 2, 3), while the explicit key carries no output and stays
    // an independent evaluation (its own tick() 4, 5, 6, ranking 1, 2, 3). Six
    // calls in all. Redirecting every structurally equal key would collapse the
    // explicit key onto the ordinal's slot, calling tick() only three times.
    let (counter, routines) = try ticking()
    try fixture().expect(
        """
        SELECT tick(), ROW_NUMBER() OVER (ORDER BY 1),
               ROW_NUMBER() OVER (ORDER BY tick())
        FROM T
        """,
        yields: [[1, 1, 1], [2, 2, 2], [3, 3, 3]], routines: routines)
    #expect(counter.count == 6)
  }
}

@Suite("Window functions over a join")
struct WindowOverJoinTests {
  // `T.id` 4 has no `U` match, so an inner join (and a CROSS APPLY) drops it
  // while a LEFT join keeps it NULL-extended; `T.g` groups ids 1,2 and 3,4.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["id": .integer, "g": .integer]) {
        Row(1, 10)
        Row(2, 10)
        Row(3, 20)
        Row(4, 20)
      }
      Relation("U", ["id": .integer, "v": .integer]) {
        Row(1, 100)
        Row(2, 200)
        Row(3, 500)
      }
    }
  }

  @Test func `ROW_NUMBER over an inner join orders by a joined column`()
      throws {
    // The inner join drops `id` 4; the window ranks the three surviving rows by
    // the joined `U.v` descending (500, 200, 100), and the output keeps the
    // join (source) order, each row carrying its rank.
    try fixture().expect(
        "SELECT T.id, ROW_NUMBER() OVER (ORDER BY U.v DESC) " +
        "FROM T JOIN U ON T.id = U.id",
        yields: [[1, 3], [2, 2], [3, 1]])
  }

  @Test func `SUM partitions a window by a joined column`() throws {
    // Partition by `T.g`: g=10 sums U.v 100 + 200 = 300, g=20 has only id 3's
    // 500 (id 4 dropped by the inner join). Each partition row gains its total.
    try fixture().expect(
        "SELECT T.id, SUM(U.v) OVER (PARTITION BY T.g) " +
        "FROM T JOIN U ON T.id = U.id",
        yields: [[1, 300], [2, 300], [3, 500]])
  }

  @Test func `run and validate agree on a window over a join`() throws {
    // The schema path types the same two-column shape the run produces — the
    // parity `compile` gates: no join-specific rejection survives.
    let sql = "SELECT T.id, SUM(U.v) OVER (PARTITION BY T.g) " +
              "FROM T JOIN U ON T.id = U.id"
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
    try fixture().expect(sql, yields: [[1, 300], [2, 300], [3, 500]])
  }

  @Test func `COUNT(*) over a LEFT join counts the NULL-extended row`() throws {
    // The LEFT join keeps `id` 4 (no `U` match, NULL-extended), so the whole-
    // partition `COUNT(*)` is 4 — the window sees every post-join row.
    try fixture().expect(
        "SELECT T.id, COUNT(*) OVER () FROM T LEFT JOIN U ON T.id = U.id",
        yields: [[1, 4], [2, 4], [3, 4], [4, 4]])
  }

  @Test func `ROW_NUMBER over a CROSS APPLY orders by the apply body`() throws {
    // A correlated CROSS APPLY body projects each row's matching `U.v`; `id` 4
    // matches none and is dropped, and the window ranks the survivors by `d.v`
    // descending over the apply-bearing chain.
    try fixture().expect(
        "SELECT T.id, ROW_NUMBER() OVER (ORDER BY d.v DESC) FROM T " +
        "JOIN LATERAL (SELECT U.v FROM U WHERE U.id = T.id) AS d ON 1 = 1",
        yields: [[1, 3], [2, 2], [3, 1]])
  }

  @Test func `a window in the outer ORDER BY sorts the joined output`() throws {
    // The query orders by the window rank itself (`U.v` descending), so the
    // output rows come out id 3, 2, 1 rather than in join order.
    try fixture().expect(
        "SELECT T.id FROM T JOIN U ON T.id = U.id " +
        "ORDER BY ROW_NUMBER() OVER (ORDER BY U.v DESC)",
        yields: [[3], [2], [1]])
  }

  @Test func `two windows over a join compute independently`() throws {
    // A ranking and a grand-total aggregate window share the join source, each
    // appending its own slot: rank by `U.v` ascending, and the total 800.
    try fixture().expect(
        "SELECT T.id, ROW_NUMBER() OVER (ORDER BY U.v), SUM(U.v) OVER () " +
        "FROM T JOIN U ON T.id = U.id",
        yields: [[1, 1, 800], [2, 2, 800], [3, 3, 800]])
  }

  @Test func `the WHERE filters the join before the window`() throws {
    // `U.v > 100` drops id 1 below the window, so `COUNT(*) OVER ()` counts the
    // two surviving post-join rows, not all three.
    try fixture().expect(
        "SELECT T.id, COUNT(*) OVER () FROM T JOIN U ON T.id = U.id " +
        "WHERE U.v > 100",
        yields: [[2, 2], [3, 2]])
  }

  @Test func `a running frame accumulates over the join`() throws {
    // A `ROWS UNBOUNDED PRECEDING → CURRENT ROW` frame over the join, ordered
    // by `U.v`, runs the cumulative sum 100, 300, 800.
    try fixture().expect(
        """
        SELECT T.id, SUM(U.v) OVER (ORDER BY U.v
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM T JOIN U ON T.id = U.id
        """,
        yields: [[1, 100], [2, 300], [3, 800]])
  }

  @Test func `a window partitions by a USING merged column`() throws {
    // `USING (id)` merges the join key to one column; partitioning the window
    // by that merged `id` makes each row its own partition, so the count is 1.
    try fixture().expect(
        "SELECT id, COUNT(*) OVER (PARTITION BY id) FROM T JOIN U USING (id)",
        yields: [[1, 1], [2, 1], [3, 1]])
  }

  @Test func `a window in a join ON is still rejected`() throws {
    // Broadening the window source to a join does not admit a window function
    // in a join ON — it has no per-row meaning there, on a join as on one
    // relation.
    try fixture().expect(
        "SELECT T.id FROM T JOIN U ON ROW_NUMBER() OVER () = 1",
        fails: .state("0A000",
            "a window function is allowed only in SELECT and ORDER BY"))
  }

  @Test func `a window beside an aggregate over a join is supported`() throws {
    // A window beside an aggregate over a join computes over the grouped rows:
    // the whole-table `SUM(U.v)` is 800 (id 4 dropped by the inner join) and
    // the single grouped row's `ROW_NUMBER() OVER ()` is 1.
    try fixture().expect(
        "SELECT SUM(U.v), ROW_NUMBER() OVER () FROM T JOIN U ON T.id = U.id",
        yields: [[800, 1]])
  }
}

@Suite("Window functions over grouped output")
struct WindowOverGroupedTests {
  // Groups: dept 1 sums 300 (count 2), dept 2 sums 600 (count 2), dept 3 sums
  // 500 (count 1). The aggregate node yields one row per group in key first-
  // appearance order (dept 1, 2, 3), the order the window then reads.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("Emp", ["dept": .integer, "sal": .integer]) {
        Row(1, 100)
        Row(1, 200)
        Row(2, 300)
        Row(2, 300)
        Row(3, 500)
      }
    }
  }

  @Test func `RANK orders the groups by an aggregate`() throws {
    // The window ranks the grouped rows by `SUM(sal)` ascending (300, 500, 600
    // → ranks 1, 2, 3), each group's row carrying its rank; the output stays in
    // group order (dept 1, 2, 3).
    try fixture().expect(
        "SELECT dept, SUM(sal), RANK() OVER (ORDER BY SUM(sal)) " +
        "FROM Emp GROUP BY dept",
        yields: [[1, 300, 1], [2, 600, 3], [3, 500, 2]])
  }

  @Test func `a grand-total aggregate window sums the group totals`() throws {
    // `SUM(SUM(sal)) OVER ()` folds the outer aggregate over every grouped
    // row — the group totals summed, 300 + 600 + 500 = 1400 — over each row.
    try fixture().expect(
        "SELECT dept, SUM(sal), SUM(SUM(sal)) OVER () FROM Emp GROUP BY dept",
        yields: [[1, 300, 1400], [2, 600, 1400], [3, 500, 1400]])
  }

  @Test func `ROW_NUMBER orders the groups by a COUNT`() throws {
    // Ordering the grouped rows by `COUNT(*)` ascending, dept 3 (count 1) is
    // first; dept 1 and 2 tie on count 2 and break by group order, so the
    // ROW_NUMBER is 1 for dept 3, 2 for dept 1, 3 for dept 2.
    try fixture().expect(
        "SELECT dept, COUNT(*), ROW_NUMBER() OVER (ORDER BY COUNT(*)) " +
        "FROM Emp GROUP BY dept",
        yields: [[1, 2, 2], [2, 2, 3], [3, 1, 1]])
  }

  @Test func `a window orders by a group key`() throws {
    // A bare window over a `GROUP BY` key ranks the groups by that key — no
    // aggregate involved, the key read from its grouped slot.
    try fixture().expect(
        "SELECT dept, RANK() OVER (ORDER BY dept) FROM Emp GROUP BY dept",
        yields: [[1, 1], [2, 2], [3, 3]])
  }

  @Test func `a window partitions by a group key`() throws {
    // Partitioning by the `GROUP BY` key makes each group its own partition, so
    // the whole-partition `COUNT(*)` is 1 for every group.
    try fixture().expect(
        "SELECT dept, COUNT(*) OVER (PARTITION BY dept) " +
        "FROM Emp GROUP BY dept",
        yields: [[1, 1], [2, 1], [3, 1]])
  }

  @Test func `HAVING filters the groups below the window`() throws {
    // HAVING drops dept 1 (300) before the window computes, so the surviving
    // dept 3 (500) and dept 2 (600) rank 1 and 2 — not 2 and 3, which they
    // would were the window computed over all three groups.
    try fixture().expect(
        "SELECT dept, SUM(sal), RANK() OVER (ORDER BY SUM(sal)) " +
        "FROM Emp GROUP BY dept HAVING SUM(sal) >= 500",
        yields: [[2, 600, 2], [3, 500, 1]])
  }

  @Test func `the query ORDER BY sorts on the window`() throws {
    // The query orders by the window rank descending (aliased `r`), so the
    // output comes out dept 2 (rank 3), dept 3 (rank 2), dept 1 (rank 1).
    try fixture().expect(
        "SELECT dept, SUM(sal), RANK() OVER (ORDER BY SUM(sal)) AS r " +
        "FROM Emp GROUP BY dept ORDER BY r DESC",
        yields: [[2, 600, 3], [3, 500, 2], [1, 300, 1]])
  }

  @Test func `DISTINCT dedups the windowed rows`() throws {
    // `COUNT(*) OVER ()` counts the three grouped rows, so every row carries 3;
    // DISTINCT then collapses them to a single row.
    try fixture().expect(
        "SELECT DISTINCT COUNT(*) OVER () FROM Emp GROUP BY dept",
        yields: [[3]])
  }

  @Test func `two windows over grouped output compute independently`() throws {
    // A ranking and a grand-total aggregate window share the grouped source,
    // each appending its own slot: rank by `SUM(sal)`, and the total 1400.
    try fixture().expect(
        "SELECT dept, RANK() OVER (ORDER BY SUM(sal)), SUM(SUM(sal)) OVER () " +
        "FROM Emp GROUP BY dept",
        yields: [[1, 1, 1400], [2, 3, 1400], [3, 2, 1400]])
  }

  @Test func `a window nests in an arithmetic compound`() throws {
    // `RANK() OVER (…) + 1` lowers the window leaf to its appended slot and the
    // literal to a constant, so each group's rank is offset by one.
    try fixture().expect(
        "SELECT dept, RANK() OVER (ORDER BY SUM(sal)) + 1 " +
        "FROM Emp GROUP BY dept",
        yields: [[1, 2], [2, 4], [3, 3]])
  }

  @Test func `a running frame accumulates over the groups`() throws {
    // A `ROWS UNBOUNDED PRECEDING → CURRENT ROW` frame over the group totals,
    // ordered by dept, runs the cumulative total 300, 900, 1400.
    try fixture().expect(
        """
        SELECT dept, SUM(SUM(sal)) OVER (ORDER BY dept
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM Emp GROUP BY dept
        """,
        yields: [[1, 300], [2, 900], [3, 1400]])
  }

  @Test func `LEAD reads the next group's aggregate with a default`() throws {
    // `LEAD(SUM(sal), 1, 0)` over the groups ordered by dept reads the next
    // group's total (300 → 600, 600 → 500) and the default 0 past the last
    // group — the value and default both aggregates the group node folds, the
    // default reconciled to the value's integer type.
    try fixture().expect(
        "SELECT dept, SUM(sal), LEAD(SUM(sal), 1, 0) OVER (ORDER BY dept) " +
        "FROM Emp GROUP BY dept",
        yields: [[1, 300, 600], [2, 600, 500], [3, 500, 0]])
  }

  @Test func `a window over a whole-table aggregate is one row`() throws {
    // With no `GROUP BY` the aggregate is the single whole-table group, so the
    // window computes over one row: the grand `SUM(sal)` 1400, ranked 1.
    try fixture().expect(
        "SELECT SUM(sal), RANK() OVER (ORDER BY SUM(sal)) FROM Emp",
        yields: [[1400, 1]])
  }

  @Test func `run and validate agree on a window over grouped output`()
      throws {
    // The schema path types the same three-column shape the run produces — the
    // parity `compile` gates, no grouped-specific rejection surviving.
    let sql = "SELECT dept, SUM(sal), RANK() OVER (ORDER BY SUM(sal)) " +
              "FROM Emp GROUP BY dept"
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 3)
    try fixture().expect(sql,
                         yields: [[1, 300, 1], [2, 600, 3], [3, 500, 2]])
  }

  @Test func `a non-grouped column in a window operand is rejected`() throws {
    // A window `ORDER BY` naming a column that is neither a `GROUP BY` key nor
    // aggregated has no grouped value — the standard grouping rule rejects it,
    // on both the run and validate paths.
    let sql = "SELECT dept, RANK() OVER (ORDER BY sal) FROM Emp GROUP BY dept"
    try fixture().expect(sql, fails: .grouping("sal"))
    #expect(throws: SQLError.grouping("sal")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a window over GROUPING SETS sees every set's rows`() throws {
    // A window over a `GROUPING SETS` query numbers across the union of every
    // set's rows (ISO 9075), not one arm's grouped rows — the per-dept totals
    // (dept 1 300, dept 2 600, dept 3 500) AND the grand total (1400), ranked
    // together by `SUM(sal)`: 300 → 1, 500 → 2, 600 → 3, 1400 → 4. The former
    // `0A000` deferral is gone — the window rides above the union of arms.
    try fixture().expect(
        "SELECT dept, SUM(sal), ROW_NUMBER() OVER (ORDER BY SUM(sal)) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept), ())",
        yields: [[1, 300, 1], [2, 600, 3], [3, 500, 2], [nil, 1400, 4]])
  }

  @Test func `an aggregate in a grouped window FILTER is rejected`() throws {
    // A FILTER is a per-row gate, so it may not itself contain an aggregate —
    // the rule a collapsing aggregate's FILTER obeys. The grouped surface could
    // otherwise resolve the inner `SUM(sal)` to a grouped slot and lower it, so
    // the shared window `check` enforces the rule surface-independently and the
    // run and validate paths reject alike, rather than run admitting a shape
    // the type-derive faults.
    let sql = "SELECT SUM(SUM(sal)) FILTER (WHERE SUM(sal) > 0) OVER () " +
              "FROM Emp GROUP BY dept"
    let fault = SQLError.state("42803",
                               "an aggregate is not allowed in a FILTER")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a window in a HAVING is rejected`() throws {
    // A window is allowed only in the SELECT list and `ORDER BY`; one in a
    // HAVING has no per-row meaning there, rejected ahead of the grouped
    // routing.
    let sql = "SELECT dept FROM Emp GROUP BY dept " +
              "HAVING RANK() OVER (ORDER BY dept) > 1"
    let fault = SQLError.state(
        "0A000", "a window function is allowed only in SELECT and ORDER BY")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a whole-table aggregate window routes through group`() throws {
    // No GROUP BY and no other projected aggregate, so the aggregate that makes
    // this a grouped query hides in the window's own operand — `SUM(sal)` is
    // 1400 over the whole-table group, and the outer `SUM(…) OVER ()` sums that
    // lone row. The routing must reach the grouped path, not the plain window
    // path (which would fault 42803 lowering the inner aggregate).
    let sql = "SELECT SUM(SUM(sal)) OVER () FROM Emp"
    try fixture().expect(sql, yields: [[1400]])
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 1)
  }

  @Test func `a positional window over a whole-table aggregate routes`()
      throws {
    // Same routing gate for a positional window whose operand is the aggregate:
    // `FIRST_VALUE(SUM(sal)) OVER ()` reads the lone whole-table group's 1400.
    try fixture().expect(
        "SELECT FIRST_VALUE(SUM(sal)) OVER () FROM Emp",
        yields: [[1400]])
  }

  @Test func `a named grouped window resolves an aggregate spec`() throws {
    // `WINDOW w AS (ORDER BY SUM(sal))` names an aggregate, which `front`
    // cannot resolve on the base scope; the grouped surface revalidates it, the
    // named form matches the inline `RANK() OVER (ORDER BY SUM(sal))`. Ranks by
    // SUM(sal) ascending (300, 500, 600 → dept 1, 3, 2), output in group order.
    try fixture().expect(
        "SELECT dept, RANK() OVER w FROM Emp GROUP BY dept " +
        "WINDOW w AS (ORDER BY SUM(sal))",
        yields: [[1, 1], [2, 3], [3, 2]])
  }

  @Test func `an unused definition runs in a grouped query`() throws {
    // The definition's ORDER BY names a non-grouped column, but no window is
    // computed (nothing references `w`), so it validates on the input scope —
    // `sal` an ordinary column there — not the grouped surface. The grouped
    // query runs, counting each department (contrast the used window below).
    let sql = "SELECT dept, COUNT(*) FROM Emp GROUP BY dept " +
              "WINDOW w AS (ORDER BY sal)"
    try fixture().expect(sql, yields: [[1, 2], [2, 2], [3, 1]])
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
  }

  @Test func `an unused aggregate definition beside a used window runs`()
      throws {
    // A window is used (`ROW_NUMBER`), so the query validates every definition;
    // the unused `w` names an aggregate whose grouped slot nothing computes.
    // Its well-formedness (`SUM(sal)`'s argument resolves) is confirmed without
    // requiring a collected grouped slot, so the query runs — the row number
    // over the three grouped departments — rather than faulting the internal
    // uncollected-aggregate error.
    let sql = "SELECT dept, ROW_NUMBER() OVER () FROM Emp GROUP BY dept " +
              "WINDOW w AS (ORDER BY SUM(sal))"
    try fixture().expect(sql, yields: [[1, 1], [2, 2], [3, 3]])
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
  }

  @Test func `a used grouped window on a non-grouped column is rejected`()
      throws {
    // The window is used, so its definition validates on the grouped surface,
    // where `sal` — neither a GROUP BY key nor aggregated — faults `.grouping`
    // on both paths. The unused form above validates on the input scope; a used
    // window imposes the grouped context its rows are computed over.
    let sql = "SELECT dept, RANK() OVER w FROM Emp GROUP BY dept " +
              "WINDOW w AS (ORDER BY sal)"
    try fixture().expect(sql, fails: .grouping("sal"))
    #expect(throws: SQLError.grouping("sal")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a window nested in a grouped window operand is rejected`()
      throws {
    // With the grouped surface's window registry, `LEAD`'s value operand could
    // With the grouped surface's window registry, `LEAD`'s value operand could
    // resolve the inner `RANK` to an appended slot the executor has not filled
    // — it computes every windowing from the grouped records first, so the
    // outer would read past the record. The nested window is rejected before
    // lowering, on the run and validate paths alike.
    let sql = "SELECT LEAD(RANK() OVER (ORDER BY SUM(sal)), 1) " +
              "OVER (ORDER BY dept) FROM Emp GROUP BY dept"
    let fault = SQLError.state(
        "0A000", "a window function is not allowed in a window function")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `an aggregate window reachable only from ORDER BY routes`()
      throws {
    // The one aggregate hides in a window that appears solely in the query
    // ORDER BY, never the projection — so the aggregate routing must scan the
    // ORDER BY too (the `expressions` set `windows` already scanned), or the
    // query takes the plain window path and lowers the inner `SUM(sal)` through
    // the base scope, faulting 42803. Over the lone whole-table group the
    // window ranks one row, ordering the literal projection trivially.
    let sql = "SELECT 1 FROM Emp ORDER BY RANK() OVER (ORDER BY SUM(sal))"
    try fixture().expect(sql, yields: [[1]])
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 1)
  }
}

@Suite("Window functions over GROUPING SETS / ROLLUP / CUBE output")
struct WindowOverGroupingSetsTests {
  // Groups: dept 1 sums 300, dept 2 sums 600, dept 3 sums 500; the grand total
  // is 1400. A window over a grouping-sets query sees all of them — the per-set
  // grouped rows and the NULL-extended super-aggregate rows — as one result.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("Emp", ["dept": .integer, "sal": .integer]) {
        Row(1, 100)
        Row(1, 200)
        Row(2, 300)
        Row(2, 300)
        Row(3, 500)
      }
    }
  }

  // A two-dimensional relation for the ROLLUP/CUBE and partition cases.
  // Per-(Region, Product): East/A 15, East/B 20, West/A 7, West/B 3. Per-Region
  // East 35, West 10; per-Product A 22, B 23; grand total 45.
  private func sales() throws -> FixtureCatalog {
    try Catalog {
      Relation("Sales", ["Region": .text, "Product": .text, "Qty": .integer]) {
        Row("East", "A", 10)
        Row("East", "A", 5)
        Row("East", "B", 20)
        Row("West", "A", 7)
        Row("West", "B", 3)
      }
    }
  }

  @Test func `ROW_NUMBER numbers across every set's rows`() throws {
    // The window orders the union of the `(dept)` rows and the `()` grand-total
    // row by `SUM(sal)`, numbering across all four: 300 → 1, 500 → 2, 600 → 3,
    // 1400 → 4. The output stays in union order (the per-dept arm, then the
    // grand total), each row carrying its number.
    try fixture().expect(
        "SELECT dept, SUM(sal), ROW_NUMBER() OVER (ORDER BY SUM(sal)) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept), ())",
        yields: [[1, 300, 1], [2, 600, 3], [3, 500, 2], [nil, 1400, 4]])
  }

  @Test func `an aggregate-argument window reads the union`() throws {
    // `SUM(SUM(sal)) OVER ()` sums the grouped totals across the whole result —
    // the three per-dept totals and the grand total, 300 + 600 + 500 + 1400 =
    // 2800 — over each row. The inner `SUM(sal)` is a column the union already
    // computed; the outer window reads it and does not re-aggregate.
    try fixture().expect(
        "SELECT dept, SUM(SUM(sal)) OVER () " +
        "FROM Emp GROUP BY GROUPING SETS ((dept), ())",
        yields: [[1, 2800], [2, 2800], [3, 2800], [nil, 2800]])
  }

  @Test func `an ordered frame accumulates over the union`() throws {
    // A running `ROWS UNBOUNDED PRECEDING → CURRENT ROW` frame over the union,
    // ordered by `SUM(sal)` (300, 500, 600, 1400), runs the cumulative total;
    // each row reports the sum up to its ordered position — dept 1 300, dept 3
    // 800, dept 2 1400, the grand total 2800 — output in union order.
    try fixture().expect(
        """
        SELECT dept, SUM(sal), SUM(SUM(sal)) OVER (ORDER BY SUM(sal)
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        FROM Emp GROUP BY GROUPING SETS ((dept), ())
        """,
        yields: [[1, 300, 300], [2, 600, 1400], [3, 500, 800],
                 [nil, 1400, 2800]])
  }

  @Test func `a window partitions by a grouping-set key`() throws {
    // `COUNT(*) OVER (PARTITION BY Region)` partitions the union by Region: the
    // two East `(Region, Product)` rows form one partition (count 2), the two
    // West rows another (count 2), and the NULL-extended grand-total row — its
    // Region rolled up to NULL — its own partition (count 1). A super-aggregate
    // NULL is an ordinary partition value, not skipped.
    try sales().expect(
        "SELECT Region, Product, SUM(Qty), COUNT(*) OVER (PARTITION BY Region) "
        + "FROM Sales GROUP BY GROUPING SETS ((Region, Product), ())",
        yields: [["East", "A", 15, 2], ["East", "B", 20, 2],
                 ["West", "A", 7, 2], ["West", "B", 3, 2],
                 [nil, nil, 45, 1]])
  }

  @Test func `a ROLLUP output feeds a window`() throws {
    // `ROLLUP(Region, Product)` unions the full grouping, the per-Region level
    // (Product a super-aggregate NULL), and the grand total. `ROW_NUMBER() OVER
    // (ORDER BY SUM(Qty))` numbers across all seven rows by their total: 3 → 1,
    // 7 → 2, 10 → 3, 15 → 4, 20 → 5, 35 → 6, 45 → 7, output in level order.
    try sales().expect(
        "SELECT Region, Product, SUM(Qty), "
        + "ROW_NUMBER() OVER (ORDER BY SUM(Qty)) "
        + "FROM Sales GROUP BY ROLLUP(Region, Product)",
        yields: [["East", "A", 15, 4], ["East", "B", 20, 5],
                 ["West", "A", 7, 2], ["West", "B", 3, 1],
                 ["East", nil, 35, 6], ["West", nil, 10, 3],
                 [nil, nil, 45, 7]])
  }

  @Test func `a CUBE output feeds a window`() throws {
    // `CUBE(Region, Product)` unions all four subsets — `(Region, Product)`,
    // `(Product)`, `(Region)`, `()` — nine rows. `ROW_NUMBER() OVER (ORDER BY
    // SUM(Qty))` numbers across every one by its total: 3 → 1, 7 → 2, 10 → 3,
    // 15 → 4, 20 → 5, 22 → 6, 23 → 7, 35 → 8, 45 → 9, output in subset order.
    try sales().expect(
        "SELECT Region, Product, SUM(Qty), "
        + "ROW_NUMBER() OVER (ORDER BY SUM(Qty)) "
        + "FROM Sales GROUP BY CUBE(Region, Product)",
        yields: [["East", "A", 15, 4], ["East", "B", 20, 5],
                 ["West", "A", 7, 2], ["West", "B", 3, 1],
                 [nil, "A", 22, 6], [nil, "B", 23, 7],
                 ["East", nil, 35, 8], ["West", nil, 10, 3],
                 [nil, nil, 45, 9]])
  }

  @Test func `the query ORDER BY sorts on the window output`() throws {
    // The query orders by the window number descending (aliased `n`), so the
    // union rows come out grand total (4), dept 2 (3), dept 3 (2), dept 1 (1).
    try fixture().expect(
        "SELECT dept, SUM(sal), ROW_NUMBER() OVER (ORDER BY SUM(sal)) AS n " +
        "FROM Emp GROUP BY GROUPING SETS ((dept), ()) ORDER BY n DESC",
        yields: [[nil, 1400, 4], [2, 600, 3], [3, 500, 2], [1, 300, 1]])
  }

  @Test func `run and validate agree on a windowed GROUPING SETS`() throws {
    // Both paths enter `Query.expanded`, so they drive the one rewrite over the
    // union: the schema path types the same three-column shape the run
    // produces, no grouping-sets deferral surviving on either.
    let sql = "SELECT dept, SUM(sal), ROW_NUMBER() OVER (ORDER BY SUM(sal)) " +
              "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 3)
    try fixture().expect(sql,
                         yields: [[1, 300, 1], [2, 600, 3], [3, 500, 2],
                                  [nil, 1400, 4]])
  }

  @Test func `an unaliased windowed aggregate keeps its positional header`()
      throws {
    // The outer projection surfaces the same ISO output headers the unwrapped
    // grouped form does — a bare group column its name, an unnamed aggregate
    // its positional `column N` — never the internal `*gwN` name the lowering
    // gives the derived union it reads. The window's own unnamed output takes
    // the next positional header.
    let windowed = "SELECT dept, SUM(sal), " +
                   "ROW_NUMBER() OVER (ORDER BY SUM(sal)) FROM Emp " +
                   "GROUP BY GROUPING SETS ((dept), ())"
    let grouped = "SELECT dept, SUM(sal) FROM Emp " +
                  "GROUP BY GROUPING SETS ((dept), ())"
    let headers = try fixture().columns(of: parse(query: windowed),
                                        validate: true).map(\.name)
    let plain = try fixture().columns(of: parse(query: grouped),
                                      validate: true).map(\.name)
    // The first two headers match the non-windowed grouped form exactly.
    #expect(Array(headers.prefix(2)) == plain)
    #expect(headers == ["dept", "column 2", "column 3"])
  }

  @Test func `an aliased windowed aggregate keeps its alias header`() throws {
    // An explicit `AS` on a projected aggregate keeps its alias, and a bare
    // group column keeps its name — the outer projection carries the original
    // ISO output name, not the derived `*gwN` column it reads.
    let sql = "SELECT dept, SUM(sal) AS total, " +
              "ROW_NUMBER() OVER (ORDER BY SUM(sal)) AS n FROM Emp " +
              "GROUP BY GROUPING SETS ((dept), ())"
    let headers = try fixture().columns(of: parse(query: sql),
                                        validate: true).map(\.name)
    #expect(headers == ["dept", "total", "n"])
  }

  @Test func `a non-grouped operand over GROUPING SETS is rejected`() throws {
    // A window `ORDER BY` naming a column neither grouped nor aggregated has no
    // grouped value in any arm — the standard grouping rule rejects it as it
    // does on the plain grouped path, on both the run and validate paths.
    let sql = "SELECT dept, RANK() OVER (ORDER BY sal) " +
              "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    try fixture().expect(sql, fails: .grouping("sal"))
    #expect(throws: SQLError.grouping("sal")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a window FILTER over GROUPING SETS is deferred`() throws {
    // An aggregate window's `FILTER` is a per-row `Predicate` no derived union
    // column stands in for, so it remains deferred — faulting the feature
    // diagnostic on both the run and validate paths, in parity.
    let sql = "SELECT dept, SUM(sal) FILTER (WHERE sal > 0) OVER () " +
              "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    let fault = SQLError.state(
        "0A000", "a window FILTER with GROUPING SETS is not yet supported")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `an incomparable outer wrapper over GROUPING SETS faults`()
      throws {
    // A scalar wrapping a window — `NULLIF(ROW_NUMBER() OVER (), 'x')` — lives
    // in the outer window layer, its window operand lifted to a `*gwN` union
    // column. The wrapper's implicit `window = 'x'` compares an integer to
    // text, incomparable (42804). The direct lowering type-checks the arm
    // union but once skipped the outer layer, so the run reached `matches` and
    // faulted while `columns(of:validate:)` accepted it. Both paths now fault
    // over the union scope, matching the ordinary grouped-window form.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') " +
              "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    let fault = SQLError.state(
        "42804", "cannot compare integer with character varying")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `an incomparable ORDER BY wrapper over GROUPING SETS faults`()
      throws {
    // The same mismatch in a query `ORDER BY` wrapper — the lowering lifts the
    // sort key over the union too, so its comparability is validated over the
    // union scope exactly as the projection's is, faulting 42804 on both paths.
    let sql = "SELECT dept FROM Emp GROUP BY GROUPING SETS ((dept), ()) " +
              "ORDER BY NULLIF(ROW_NUMBER() OVER (), 'x')"
    let fault = SQLError.state(
        "42804", "cannot compare integer with character varying")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a comparable outer wrapper over GROUPING SETS is accepted`()
      throws {
    // The outer validation must not over-reject a well-typed wrapper: comparing
    // the integer window to an integer is comparable, so `NULLIF(ROW_NUMBER()
    // OVER (), 5)` runs — numbering the four union rows 1…4 (none equal 5, so
    // each stays), accepted by both paths.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 5) " +
              "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 1)
    try fixture().expect(sql, yields: [[1], [2], [3], [4]])
  }

  @Test func `an outer wrapper faults the same over sets and plain grouping`()
      throws {
    // Parity: the ordinary (non-grouping-sets) grouped-window form of the same
    // incomparable wrapper faults identically, so the direct sets lowering does
    // not diverge from the grouped path it mirrors.
    let sets = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') " +
               "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    let plain = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') " +
                "FROM Emp GROUP BY dept"
    let fault = SQLError.state(
        "42804", "cannot compare integer with character varying")
    try fixture().expect(sets, fails: fault)
    try fixture().expect(plain, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sets), validate: true)
    }
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: plain), validate: true)
    }
  }

  @Test func `a capped output-referencing sort validates the projection`()
      throws {
    // A row-dropping cap leaves the projection above it unreachable — but an
    // `ORDER BY 1` names that output, pulling its projection below the sort
    // (below the cap), where the run still evaluates it. The incomparable
    // `NULLIF(ROW_NUMBER() OVER (), 'x')` (integer versus text) faults
    // 42804 on the run under `FETCH FIRST 0`, and validate must fault
    // identically: the outer layer inherits the ordinary path's sort-output
    // resolution, so the ordinal key resolves to the projection expression the
    // sort recomputes and validates it even where the projection block is
    // skipped. A bespoke skip of the ordinal key accepted the query — the
    // run ≠ validate hole this closes.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') FROM Emp " +
              "GROUP BY GROUPING SETS ((dept), ()) ORDER BY 1 " +
              "FETCH FIRST 0 ROWS ONLY"
    let fault = SQLError.state(
        "42804", "cannot compare integer with character varying")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a capped unreferenced projection stays unreachable`() throws {
    // The companion guarding against over-rejection: the same incomparable
    // wrapper under `FETCH FIRST 0` but with no output-referencing sort. The
    // projection sits above the cap and no sort names it, so it stays
    // unreachable — the run drops every row without evaluating it, yielding the
    // empty page, and validate accepts its one column rather than faulting a
    // wrapper the run never reaches.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') FROM Emp " +
              "GROUP BY GROUPING SETS ((dept), ()) FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 1)
  }

  // A parent `T` and a keyed child `U`, so a correlated LATERAL body's grouping
  // varies per outer row: Id 1 has two children (100, 101), Id 2 one (200), and
  // Id 3 none. The child keys reach back to `T.Id`, the correlation a once-
  // materialised derived table would sever.
  private func correlated() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
      Relation("U", ["k": .integer, "v": .integer]) {
        Row(1, 100)
        Row(1, 101)
        Row(2, 200)
      }
    }
  }

  // A grouped `Emp` beside a `U` with no `dept` column, so unqualified `dept`
  // in a subquery over `U` is a genuine correlation to the group key (not a
  // local column, and `dept` is no adapter column either) — the unqualified-
  // ambiguous residual the qualified-free rewrite arm-lifts. `U.v` is 1, 2, 3.
  private func colliding() throws -> FixtureCatalog {
    try Catalog {
      Relation("Emp", ["dept": .integer, "sal": .integer]) {
        Row(1, 100)
        Row(2, 300)
        Row(3, 500)
      }
      Relation("U", ["v": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
    }
  }

  // A parent `T` with a `T.Id = 0` group and a child `U`, so a fallback
  // dividing `SUM(U.v)` by the group key `T.Id` faults `.divide` if evaluated —
  // the eager arm-lift's hazard a lazy outer host avoids.
  private func zeroed() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(0)
      }
      Relation("U", ["k": .integer, "v": .integer]) {
        Row(0, 5)
      }
    }
  }

  @Test func `a correlated LATERAL windowed GROUPING SETS resolves the outer`()
      throws {
    // The windowed grouping-sets query is a correlated LATERAL body: its arms
    // reference the enclosing `T.Id`, so the union rides a LATERAL apply that
    // retains that correlation rather than an uncorrelated derived table. Per
    // `T` row, `ROLLUP(T.Id)` over the children keyed on `T.Id` yields a
    // per-group row and the grand total, and `ROW_NUMBER() OVER (ORDER BY
    // SUM(U.v))` numbers them: Id 1 → two rows summing 201 numbered 1, 2; Id
    // 2 → two rows summing 200 numbered 1, 2; Id 3 → its lone grand total (no
    // children) numbered 1.
    try correlated().expect(
        "SELECT T.Id, d.n FROM T JOIN LATERAL (" +
        "SELECT ROW_NUMBER() OVER (ORDER BY SUM(U.v)) AS n " +
        "FROM U WHERE U.k = T.Id GROUP BY ROLLUP(T.Id)) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.n",
        yields: [[1, 1], [1, 2], [2, 1], [2, 2], [3, 1]])
  }

  @Test func `run and validate agree on a correlated LATERAL windowed query`()
      throws {
    // Both paths enter `Query.expanded` and drive the one lateral-apply
    // rewrite, so the schema path types the same two-column shape a run
    // produces — the correlated body resolving `T.Id` on both.
    let sql = "SELECT T.Id, d.n FROM T JOIN LATERAL (" +
              "SELECT ROW_NUMBER() OVER (ORDER BY SUM(U.v)) AS n " +
              "FROM U WHERE U.k = T.Id GROUP BY ROLLUP(T.Id)) AS d ON 1 = 1"
    #expect(try correlated().columns(of: parse(query: sql), validate: true)
                .count == 2)
    try correlated().expect(
        sql + " ORDER BY T.Id, d.n",
        yields: [[1, 1], [1, 2], [2, 1], [2, 2], [3, 1]])
  }

  @Test func `a non-windowed LATERAL GROUPING SETS returns the same grouping`()
      throws {
    // The parity the windowed form must match: the same correlated body without
    // the window resolves `T.Id` identically, one row per group per outer row —
    // Id 1 and Id 2 their per-group sum and grand total (equal here), Id 3 only
    // its grand-total NULL. The windowed form numbers exactly these rows.
    try correlated().expect(
        "SELECT T.Id, d.s FROM T JOIN LATERAL (" +
        "SELECT SUM(U.v) AS s FROM U WHERE U.k = T.Id " +
        "GROUP BY ROLLUP(T.Id)) AS d ON 1 = 1 ORDER BY T.Id, d.s",
        yields: [[1, 201], [1, 201], [2, 200], [2, 200], [3, nil]])
  }

  @Test func `an unused WINDOW faults over a windowed GROUPING SETS query`()
      throws {
    // A used `ROW_NUMBER()` window beside an unused named window whose ORDER BY
    // names a non-existent column. The rewrite carries the original WINDOW
    // clause onto the arm union, so the arm's front validates every definition
    // against the grouped source before dropping it — faulting the undefined
    // `nonesuch` on both the run and validate paths, as the ordinary and
    // non-windowed aggregate forms do, rather than silently accepting it.
    let sql = "SELECT dept, ROW_NUMBER() OVER () FROM Emp " +
              "GROUP BY GROUPING SETS ((dept), ()) " +
              "WINDOW bad AS (ORDER BY nonesuch)"
    try fixture().expect(sql, fails: .column("nonesuch"))
    #expect(throws: SQLError.column("nonesuch")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `an unused WINDOW faults over a single-set GROUPING SETS`()
      throws {
    // A single grouping set takes the fast path that reconstructs an ordinary
    // grouped `Select`; that reconstruction must carry the `WINDOW` clause, or
    // an unused definition naming a non-existent column is silently accepted
    // where the multi-set path and the ordinary grouped query both reject it.
    let sql = "SELECT dept, ROW_NUMBER() OVER () FROM Emp " +
              "GROUP BY GROUPING SETS ((dept)) " +
              "WINDOW bad AS (ORDER BY nonesuch)"
    try fixture().expect(sql, fails: .column("nonesuch"))
    #expect(throws: SQLError.column("nonesuch")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a directly-built negative limit faults over GROUPING SETS`()
      throws {
    // The windowed grouping-sets lowering validates the row limit before its
    // early return; else a public-AST-built negative `Limit` reaches the
    // executor's slice and precondition-traps, where the ordinary path faults
    // the query error. Run and validate fault identically.
    let query = try parse(
        query: "SELECT dept, ROW_NUMBER() OVER () FROM Emp " +
               "GROUP BY GROUPING SETS ((dept), ())")
    guard case let .select(base) = query.body else {
      Issue.record("expected a single SELECT")
      return
    }
    func rebuilt(_ limit: Limit) -> Select {
      Select(distinct: base.distinct, projection: base.projection,
             from: base.from, joins: base.joins, predicate: base.predicate,
             grouping: base.grouping, having: base.having,
             window: base.window, order: base.order, limit: limit)
    }
    let offset: Query = .select(rebuilt(Limit(count: 1, offset: -1)))
    #expect(throws:
        SQLError.state("2201X", "OFFSET row count must be non-negative")) {
      try fixture().run(offset)
    }
    #expect(throws:
        SQLError.state("2201X", "OFFSET row count must be non-negative")) {
      _ = try fixture().columns(of: offset, validate: true)
    }
    let count: Query = .select(rebuilt(Limit(count: -1)))
    #expect(throws:
        SQLError.state("2201W", "FETCH row count must be non-negative")) {
      try fixture().run(count)
    }
  }

  @Test func `a valid unused WINDOW definition is accepted and dropped`()
      throws {
    // An unused named window whose ORDER BY names a real column is well-formed,
    // so it validates and is dropped — the query runs exactly as it would with
    // no WINDOW clause, matching the ordinary grouped path's treatment of an
    // unused definition.
    let sql = "SELECT dept, ROW_NUMBER() OVER (ORDER BY SUM(sal)) FROM Emp " +
              "GROUP BY GROUPING SETS ((dept), ()) WINDOW w AS (ORDER BY dept)"
    try fixture().expect(sql, yields: [[1, 1], [2, 3], [3, 2], [nil, 4]])
  }

  @Test func `a stateful leaf evaluates independently at each site`() throws {
    // A non-deterministic `tick()` in the projection and in the window `ORDER
    // BY` is not collapsed onto one shared union column: each site evaluates
    // independently — six calls over the three groups, not three — matching the
    // plain grouped-window path, not reading one shared value. Under grounded-
    // outer the projection `tick()` is group-independent, so it stays in the
    // outer projection and evaluates after the window; only the window key
    // `tick()` lifts to an arm column (`*gw0`) and evaluates before it. The arm
    // evaluates its lone key per group (1, 2, 3), the window numbers by that
    // ascending key (ranks 1, 2, 3), and the outer projection then evaluates
    // its own `tick()` per output row (4, 5, 6) — the same values, and the same
    // six calls, the ordinary `GROUP BY dept` companion below reports.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT tick(), ROW_NUMBER() OVER (ORDER BY tick()) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))",
        yields: [[4, 1], [5, 2], [6, 3]], routines: routines)
    #expect(counter.count == 6)
  }

  @Test func `the single set matches the ordinary grouped-window path`()
      throws {
    // The grounded-outer oracle: the single-set `GROUPING SETS ((dept))`
    // spelling of the query above must observe exactly what the ordinary `GROUP
    // BY dept` windowed query does — the window key `tick()` evaluated first as
    // the ranking input (1, 2, 3), the projection `tick()` evaluated after the
    // window (4, 5, 6), six calls in all. This is the reference the grouping-
    // sets form is pinned to; before grounded-outer the grouping-sets form
    // reported 1, 3, 5 (both `tick()`s in the arm), diverging from it.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT tick(), ROW_NUMBER() OVER (ORDER BY tick()) " +
        "FROM Emp GROUP BY dept",
        yields: [[4, 1], [5, 2], [6, 3]], routines: routines)
    #expect(counter.count == 6)
  }

  @Test func `a capped projection-only fault drops with the page`() throws {
    // #137: a projection-only pure scalar that would fault (`1 / 0`) is group-
    // independent, so grounded-outer keeps it in the outer projection above the
    // `Project(Limit(Sort))` cap rather than in an arm below it. A zero `FETCH`
    // drops every row before the projection runs, so the division never
    // happens and the query returns the empty page — matching the ordinary
    // grouped-window path. Before grounded-outer the `1 / 0` lifted into the
    // arm, dividing per group and faulting `.divide` even though no row
    // survived. `columns(of: validate:)` agrees — the outer projection sits
    // above the cap, so a dropped page leaves it unreachable and validate types
    // its two columns rather than faulting a division the run never reaches.
    let sql = "SELECT 1 / 0, ROW_NUMBER() OVER () FROM Emp " +
              "GROUP BY GROUPING SETS ((dept)) FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
  }

  @Test func `an ordinal-linked window key shares the reported leaf`() throws {
    // The window `ORDER BY 1` names column 1 — the `tick()` value — so
    // the ordinal links the key to that output: both must read one evaluation.
    // The lifter shares its `*gwN` leaf across the projection and the ordinal-
    // linked key, so `tick()` is evaluated once per group (1, 2, 3), the window
    // orders on those, and the row numbered k reports `tick()` k — the ranking
    // matching the reported column, three calls. Sharing only by determinism
    // would give the ordinal its own leaf, evaluating `tick()` twice per group,
    // ordering on 2, 4, 6 yet reporting 1, 3, 5 over six calls — the reported
    // value diverging from the ranking, as the directly written key above does.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT tick(), ROW_NUMBER() OVER (ORDER BY 1) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))",
        yields: [[1, 1], [2, 2], [3, 3]], routines: routines)
    #expect(counter.count == 3)
  }

  @Test func `an unnamed windowed output stays an ordinal-only header`()
      throws {
    // An originally-unnamed windowed grouping-sets output feeding an outer
    // set-op carrier keeps its synthesized `column N` display header and stays
    // ordinal-only: a delimited `ORDER BY "column N"` binds no output — the
    // synthesized header is not a spellable name — so it faults `.column`, as
    // it does over any derived union, not the outer carrier capturing it.
    let arm = "SELECT SUM(sal), ROW_NUMBER() OVER () FROM Emp " +
              "GROUP BY GROUPING SETS ((dept))"
    // The two outputs display as the positional headers, marked synthesized.
    let headers = try fixture().columns(of: parse(query: arm), validate: true)
        .map(\.name)
    #expect(headers == ["column 1", "column 2"])
    // Feeding an outer UNION, a delimited-name ORDER BY on either synthesized
    // header faults; the ordinal still orders that output.
    let union = "\(arm) UNION SELECT dept, dept FROM Emp"
    try fixture().expect("\(union) ORDER BY \"column 1\"",
                         fails: .column("column 1"))
    try fixture().expect("\(union) ORDER BY \"column 2\"",
                         fails: .column("column 2"))
    #expect(throws: SQLError.column("column 1")) {
      _ = try fixture().columns(of: parse(query:
          "\(union) ORDER BY \"column 1\""), validate: true)
    }
  }

  @Test func `an unused WINDOW faults over a single-set windowed query`()
      throws {
    // A single grouping set takes `expand`'s fast path, which reconstructs a
    // plain grouped select rather than a union. It carries the WINDOW clause
    // onto that select as the multi-set arms do, so the arm compile validates
    // every definition against the grouped source — the undefined `nonesuch`
    // faulting on both the run and validate paths, as the multi-set and
    // ordinary grouped forms do, not silently accepted on a one-set query.
    let sql = "SELECT dept, ROW_NUMBER() OVER () FROM Emp " +
              "GROUP BY GROUPING SETS ((dept)) " +
              "WINDOW bad AS (ORDER BY nonesuch)"
    try fixture().expect(sql, fails: .column("nonesuch"))
    #expect(throws: SQLError.column("nonesuch")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a valid unused WINDOW is accepted over a single-set query`()
      throws {
    // The companion: a single-set windowed grouping-sets query with a well-
    // formed unused named window validates and drops it, running exactly as it
    // would with no WINDOW clause. The fast path carries the definition through
    // validation, not around it — so a valid one is accepted, not rejected.
    let sql = "SELECT dept, ROW_NUMBER() OVER (ORDER BY SUM(sal)) FROM Emp " +
              "GROUP BY GROUPING SETS ((dept)) WINDOW w AS (ORDER BY dept)"
    try fixture().expect(sql, yields: [[1, 1], [2, 3], [3, 2]])
  }

  @Test func `an unused WINDOW faults over a non-windowed single set`()
      throws {
    // The single-set fast path is shared by the non-windowed grouping-sets
    // form, so an ordinary single-set grouping-sets query with a bad unused
    // WINDOW definition validates it too — faulting `nonesuch` on both paths,
    // as the multi-set and ordinary grouped forms do, rather than dropping the
    // clause unvalidated because there is only one set.
    let sql = "SELECT dept FROM Emp GROUP BY GROUPING SETS ((dept)) " +
              "WINDOW bad AS (ORDER BY nonesuch)"
    try fixture().expect(sql, fails: .column("nonesuch"))
    #expect(throws: SQLError.column("nonesuch")) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a negative OFFSET over a windowed GROUPING SETS faults`() throws {
    // The parser cannot spell a negative count, but a directly built `Limit`
    // can. The windowed grouping-sets lowering used to take its early return
    // before the row-limit guard, passing the negative offset to `limited`,
    // where the negative slice precondition-traps; the guard now runs ahead of
    // that return, so the query faults 2201X on both the run and validate
    // paths, as an ordinary select does, rather than crashing the process.
    let base = try parse(select:
        "SELECT dept, ROW_NUMBER() OVER (ORDER BY SUM(sal)) FROM Emp " +
        "GROUP BY GROUPING SETS ((dept), ())")
    let select = Select(projection: base.projection, from: base.from,
                        grouping: base.grouping,
                        limit: Limit(count: 1, offset: -1))
    let query = Query.select(select)
    let catalog = try fixture()
    let fault = SQLError.state("2201X", "OFFSET row count must be non-negative")
    let ran: SQLError?
    do {
      _ = try catalog.run(query)
      ran = nil
    } catch let raised {
      ran = raised
    }
    #expect(ran == fault)
    let derived: SQLError?
    do {
      _ = try catalog.columns(of: query, validate: true)
      derived = nil
    } catch let raised {
      derived = raised
    }
    #expect(derived == fault)
  }

  @Test func `a negative FETCH over a windowed GROUPING SETS faults`() throws {
    // The same guard covers a negative FETCH count: a directly built `Limit`
    // with a negative count reaches the windowed grouping-sets lowering and
    // used to trap in `limited`'s prefix; it now faults 2201W ahead of the
    // early return, on both the run and validate paths, as an ordinary select
    // does.
    let base = try parse(select:
        "SELECT dept, ROW_NUMBER() OVER (ORDER BY SUM(sal)) FROM Emp " +
        "GROUP BY GROUPING SETS ((dept), ())")
    let select = Select(projection: base.projection, from: base.from,
                        grouping: base.grouping, limit: Limit(count: -1))
    let query = Query.select(select)
    let catalog = try fixture()
    let fault = SQLError.state("2201W", "FETCH row count must be non-negative")
    let ran: SQLError?
    do {
      _ = try catalog.run(query)
      ran = nil
    } catch let raised {
      ran = raised
    }
    #expect(ran == fault)
    let derived: SQLError?
    do {
      _ = try catalog.columns(of: query, validate: true)
      derived = nil
    } catch let raised {
      derived = raised
    }
    #expect(derived == fault)
  }

  @Test func `a capped projection CASE fault drops with the page`() throws {
    // #137, the `CASE` shape: a projection-only `CASE` whose result would fault
    // (`CASE WHEN 1 = 1 THEN 1 / 0 END`) is group-independent — its `WHEN`
    // guard and `THEN` result name no grouped data — so grounded-outer keeps it
    // in the outer projection above the `Project(Limit(Sort))` cap, not an arm
    // below it. A zero `FETCH` drops every row before the projection runs, so
    // the division never happens and the query returns the empty page, matching
    // the ordinary `GROUP BY dept` companion. Before this the `CASE` was hard-
    // coded grounded and lifted into the arm, dividing per group and faulting
    // even though no row survived. `columns(of: validate:)` agrees over the
    // union scope, typing its two columns rather than faulting a division no
    // run reaches.
    let sql = "SELECT CASE WHEN 1 = 1 THEN 1 / 0 END, ROW_NUMBER() OVER () " +
              "FROM Emp GROUP BY GROUPING SETS ((dept)) FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
    let plain = "SELECT CASE WHEN 1 = 1 THEN 1 / 0 END, ROW_NUMBER() OVER () " +
                "FROM Emp GROUP BY dept FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(plain)
  }

  @Test func `a projection-only CASE evaluates in the outer projection`()
      throws {
    // A stateful `CASE WHEN 1 = 1 THEN tick() END` in the projection is group-
    // independent, so it stays in the outer projection and evaluates after the
    // window — its `tick()` per output row — while the window `ORDER BY tick()`
    // lifts to an arm column evaluated per group before it. Six calls over the
    // three groups: the arm key 1, 2, 3 (the ranking input), then the
    // projection 4, 5, 6, matching the ordinary `GROUP BY dept` companion.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT CASE WHEN 1 = 1 THEN tick() END, " +
        "ROW_NUMBER() OVER (ORDER BY tick()) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))",
        yields: [[4, 1], [5, 2], [6, 3]], routines: routines)
    #expect(counter.count == 6)
  }

  @Test func `the single-set CASE matches the ordinary grouped-window path`()
      throws {
    // The oracle for the `CASE` above: the ordinary `GROUP BY dept` windowed
    // form observes exactly the same values — the arm key `tick()` 1, 2, 3, the
    // projection `CASE`'s `tick()` 4, 5, 6, six calls — the reference the
    // grouping-sets form is pinned to.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT CASE WHEN 1 = 1 THEN tick() END, " +
        "ROW_NUMBER() OVER (ORDER BY tick()) FROM Emp GROUP BY dept",
        yields: [[4, 1], [5, 2], [6, 3]], routines: routines)
    #expect(counter.count == 6)
  }

  @Test func `a grounded CASE keeps its structure in the outer projection`()
      throws {
    // A grounded window-free `CASE` — `CASE WHEN dept = 1 THEN SUM(sal) ELSE 0
    // END` — keeps its `CASE` structure in the outer projection and lifts only
    // the grouped values its guard and branches reference: the `dept` guard
    // column and the `SUM(sal)` branch each become a `*gwN` arm column, the
    // `CASE` itself evaluated outer above the window. Over the single set dept
    // 1 yields SUM 300, dept 2 and 3 the `ELSE` 0 (their guard false), each
    // numbered, matching the ordinary `GROUP BY dept` form. Before this fix the
    // whole `CASE` lifted into the arm; the values are the same here, but the
    // capped finding below shows why keeping the structure outer matters.
    let sets = "SELECT CASE WHEN dept = 1 THEN SUM(sal) ELSE 0 END, " +
               "ROW_NUMBER() OVER () FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[300, 1], [0, 2], [0, 3]])
    let plain = "SELECT CASE WHEN dept = 1 THEN SUM(sal) ELSE 0 END, " +
                "ROW_NUMBER() OVER () FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[300, 1], [0, 2], [0, 3]])
  }

  @Test func `a grounded CASE above a zero FETCH drops with the page`() throws {
    // The finding: a grounded `CASE` whose branch would fault — `CASE WHEN dept
    // = 1 THEN 1 / 0 END` — keeps its structure in the outer projection above
    // the `Project(Limit(Sort))` cap, only its `dept` guard column lifted to a
    // `*gwN` arm. A zero `FETCH` drops every row before the outer `CASE` runs,
    // so the division never happens and the query returns the empty page,
    // matching the ordinary `GROUP BY dept` companion. Before this fix the
    // whole grounded `CASE` lifted into the arm below the cap, dividing per
    // group and faulting `.divide` though no row survived. `columns(of:
    // validate:)` agrees over the union scope — the outer `CASE` sits above the
    // cap, so a dropped page leaves it unreachable and validate types its two
    // columns rather than faulting a division the run never reaches.
    let sql =
        "SELECT CASE WHEN dept = 1 THEN 1 / 0 END, ROW_NUMBER() OVER () " +
        "FROM Emp GROUP BY GROUPING SETS ((dept)) FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
    let plain =
        "SELECT CASE WHEN dept = 1 THEN 1 / 0 END, ROW_NUMBER() OVER () " +
        "FROM Emp GROUP BY dept FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(plain)
  }

  @Test func `a grounded CASE's stateful branch evaluates in the outer`()
      throws {
    // A grounded `CASE` with a grouped guard and a stateful branch — `CASE WHEN
    // dept = 1 THEN tick() ELSE 0 END` — lifts only the `dept` guard column to
    // an arm while the `tick()` branch stays outer, evaluated after the window
    // per output row. The window `ORDER BY tick()` lifts its own `tick()` to a
    // separate arm column evaluated per group before the window. So the arm
    // ticks 1, 2, 3 (the ranking input, ranks 1, 2, 3) and the outer `CASE`'s
    // branch ticks once for the dept-1 row (4) — four calls, matching the
    // ordinary `GROUP BY dept` companion. Before this fix the whole `CASE`
    // lifted into the arm, so its branch `tick()` evaluated before the window,
    // reporting 1 rather than the outer 4.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT CASE WHEN dept = 1 THEN tick() ELSE 0 END, " +
        "ROW_NUMBER() OVER (ORDER BY tick()) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))",
        yields: [[4, 1], [0, 2], [0, 3]], routines: routines)
    #expect(counter.count == 4)
    let other = Counter()
    let plain = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(other.next())
        }
    try fixture().expect(
        "SELECT CASE WHEN dept = 1 THEN tick() ELSE 0 END, " +
        "ROW_NUMBER() OVER (ORDER BY tick()) FROM Emp GROUP BY dept",
        yields: [[4, 1], [0, 2], [0, 3]], routines: plain)
    #expect(other.count == 4)
  }

  @Test func `a windowed CASE over GROUPING SETS is deferred`() throws {
    // Preserving #136: a `CASE` nesting a window — `CASE WHEN dept = 1 THEN
    // ROW_NUMBER() OVER () END` — is a per-row `Predicate`/window shape no
    // `*gwN` column stands in for, so it still faults the feature diagnostic on
    // both the run and validate paths, unchanged by the window-free `CASE`
    // recursion this fix adds.
    let sql = "SELECT CASE WHEN dept = 1 THEN ROW_NUMBER() OVER () END " +
              "FROM Emp GROUP BY GROUPING SETS ((dept))"
    let fault = SQLError.state(
        "0A000", "a window in a CASE with GROUPING SETS is not yet supported")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a CASE nesting an uncorrelated subquery recurses`() throws {
    // A window-free `CASE` whose branch nests an uncorrelated scalar subquery —
    // `CASE WHEN T.Id = 1 THEN (SELECT SUM(U.v) FROM U) END` — recurses: the
    // `T.Id` guard lifts to a `*gwN` arm column while the subquery stays outer,
    // hosted by the union-scope `Resolution`, so the whole `CASE` sits in the
    // outer projection above the cap rather than lifting whole to an arm. Over
    // the single set `T.Id` 1 yields the subquery's 401, `T.Id` 2 and 3 the
    // `ELSE` NULL (guard false), each numbered, matching the ordinary `GROUP BY
    // T.Id` form.
    let sets = "SELECT CASE WHEN T.Id = 1 THEN (SELECT SUM(U.v) FROM U) END, " +
               "ROW_NUMBER() OVER () FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[401, 1], [nil, 2], [nil, 3]])
    let plain =
        "SELECT CASE WHEN T.Id = 1 THEN (SELECT SUM(U.v) FROM U) END, " +
        "ROW_NUMBER() OVER () FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[401, 1], [nil, 2], [nil, 3]])
  }

  @Test func `an uncorrelated scalar subquery hosts in the outer layer`()
      throws {
    // An uncorrelated scalar subquery in the projection is hosted in the outer
    // window layer through the union-scope `Resolution`, not lifted to an arm,
    // so it resolves against the union output and evaluates once per output
    // row. `(SELECT SUM(U.v) FROM U)` sums every child, the same 401 for all
    // groups, each numbered, matching the ordinary `GROUP BY T.Id` form.
    let sets = "SELECT T.Id, (SELECT SUM(U.v) FROM U), ROW_NUMBER() OVER () " +
               "FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[1, 401, 1], [2, 401, 2],
                                           [3, 401, 3]])
    // The validate twin resolves the hosted subquery over the union scope too,
    // so `columns(of: validate:)` types its three columns rather than faulting
    // a subquery it cannot host — run ≡ validate over the outer layer.
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 3)
    let plain = "SELECT T.Id, (SELECT SUM(U.v) FROM U), ROW_NUMBER() OVER () " +
                "FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[1, 401, 1], [2, 401, 2],
                                            [3, 401, 3]])
  }

  @Test func `an uncorrelated subquery hosts over multiple sets`() throws {
    // The multi-set companion: with two grouping sets the arm union is a real
    // `UNION ALL`, and the uncorrelated `(SELECT SUM(U.v) FROM U)` is hosted in
    // the outer layer over that union — evaluated once per output row, the same
    // 401 for every per-set row and the NULL-extended grand-total row alike.
    // `SUM(T.Id)` groups to each `T.Id` per set and to 6 for the grand total,
    // the window numbering across all four union rows.
    let sets = "SELECT SUM(T.Id), (SELECT SUM(U.v) FROM U), " +
               "ROW_NUMBER() OVER () FROM T GROUP BY GROUPING SETS ((T.Id), ())"
    try correlated().expect(sets, yields: [[1, 401, 1], [2, 401, 2],
                                           [3, 401, 3], [6, 401, 4]])
  }

  @Test func `a qualified-correlated subquery hosts outer over the union`()
      throws {
    // A scalar subquery correlated to a group key by a qualified-free reference
    // — `(SELECT SUM(U.v) FROM U WHERE U.k = T.Id)` names the enclosing `T.Id`,
    // qualified by the outer alias. The lifter rewrites that free reference to
    // its `*gwN` union column and hosts the subquery in the outer layer, where
    // the union-scope `Resolution` resolves the `*gwN` as a correlated outer
    // parameter — the mechanism a correlated outer host earlier deferred (the
    // union scope now exposes the lifted group key). Over the single set `T.Id`
    // 1 sums its children 201, `T.Id` 2 sums 200, `T.Id` 3 none (NULL), each
    // numbered, matching the ordinary `GROUP BY T.Id` form. The hosted subquery
    // types over the union scope too, so run ≡ validate.
    let sets = "SELECT T.Id, (SELECT SUM(U.v) FROM U WHERE U.k = T.Id), " +
               "ROW_NUMBER() OVER () FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[1, 201, 1], [2, 200, 2],
                                           [3, nil, 3]])
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 3)
    let plain = "SELECT T.Id, (SELECT SUM(U.v) FROM U WHERE U.k = T.Id), " +
                "ROW_NUMBER() OVER () FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[1, 201, 1], [2, 200, 2],
                                            [3, nil, 3]])
  }

  @Test func `a set-op carrier ORDER BY correlation hosts outer`() throws {
    // Finding: a hosted scalar subquery is a set operation whose query-level
    // `ORDER BY` carrier — riding above the `UNION` — references the group key
    // by a qualified `T.Id`. The lifter now rewrites the carrier's `ORDER BY`
    // alongside the body, so the correlation lifts to its `*gwN` union column
    // and the subquery hosts outer; copying the carrier verbatim left `T.Id`
    // unresolved over the `*gwN`-only union scope and faulted `.column`. Both
    // arms take `MAX(U.v)` = 200, the `UNION` yields one row, and the carrier
    // orders it by the correlated key — 200 for every group, each numbered,
    // matching the ordinary `GROUP BY T.Id` form on both run and validate.
    let sets = "SELECT (SELECT MAX(U.v) FROM U UNION " +
               "SELECT MAX(U.v) FROM U ORDER BY T.Id), " +
               "ROW_NUMBER() OVER () FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[200, 1], [200, 2], [200, 3]])
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 2)
    let plain = "SELECT (SELECT MAX(U.v) FROM U UNION " +
                "SELECT MAX(U.v) FROM U ORDER BY T.Id), " +
                "ROW_NUMBER() OVER () FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[200, 1], [200, 2], [200, 3]])
  }

  @Test func `a set-op carrier ORDER BY output name is not lifted`() throws {
    // The regression the carrier rewrite must not break: a hosted set-op scalar
    // subquery whose carrier `ORDER BY` names a set-op output column (`m`), not
    // a correlation. An unqualified carrier key binds the union output by ISO
    // output-alias precedence — a local output, never a group-key reference —
    // so the rewrite leaves it verbatim and never blocks, the subquery still
    // hosting outer, not mistaking it for a correlation. The subquery is 200
    // for every group, ordered by its own output, each numbered, matching the
    // ordinary `GROUP BY T.Id` form on both run and validate.
    let sets = "SELECT T.Id, (SELECT MAX(U.v) AS m FROM U UNION " +
               "SELECT MAX(U.v) FROM U ORDER BY m), " +
               "ROW_NUMBER() OVER () FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[1, 200, 1], [2, 200, 2],
                                           [3, 200, 3]])
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 3)
    let plain = "SELECT T.Id, (SELECT MAX(U.v) AS m FROM U UNION " +
                "SELECT MAX(U.v) FROM U ORDER BY m), " +
                "ROW_NUMBER() OVER () FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[1, 200, 1], [2, 200, 2],
                                            [3, 200, 3]])
  }

  @Test func `a colliding carrier output name stays hosted above the cap`()
      throws {
    // The carrier-local guard is load-bearing when the output name collides
    // with the group key: a hosted set-op scalar subquery whose carrier `ORDER
    // BY` names an output aliased `Id` — the group key's bare name. Read as a
    // body reference it would block (`Id` is a group key) and fall back to arm-
    // lift, evaluating the subquery's `1 / 0` per group and faulting `.divide`
    // even under a zero `FETCH`. Bound as the local output it is (a carrier key
    // rides the set-op output), the subquery hosts outer above the
    // `Project(Limit(Sort))` cap, so the dropped page never evaluates it and
    // returns the empty page — matching the ordinary `GROUP BY T.Id` form.
    // `columns(of: validate:)` agrees over the union scope, typing two columns.
    let sql = "SELECT (SELECT 1 / 0 AS Id FROM U UNION " +
              "SELECT 1 / 0 FROM U ORDER BY Id), ROW_NUMBER() OVER () " +
              "FROM T GROUP BY GROUPING SETS ((T.Id)) FETCH FIRST 0 ROWS ONLY"
    try correlated().empty(sql)
    #expect(try correlated().columns(of: parse(query: sql), validate: true)
                .count == 2)
    let plain = "SELECT (SELECT 1 / 0 AS Id FROM U UNION " +
                "SELECT 1 / 0 FROM U ORDER BY Id), ROW_NUMBER() OVER () " +
                "FROM T GROUP BY T.Id FETCH FIRST 0 ROWS ONLY"
    try correlated().empty(plain)
  }

  @Test func `a bare-column subquery projecting the key hosts outer`() throws {
    // F4/F7: a hosted scalar subquery whose projection is a bare column list is
    // the correlated group key itself — `(SELECT T.Id FROM U FETCH FIRST 1 ROW
    // ONLY)`. The lifter rewrites `T.Id` to its `*gwN` union column, but the
    // `.columns` rewrite retained a rewritten list only when a column changed
    // identity: a shortcut that returned the original whenever every rewritten
    // item was still a `.column` discarded the `*gwN` reference — it is still a
    // `.column` — leaving the original `T.Id`, which cannot bind in the
    // `*gwN`-only union scope and faulted. Comparing each rewritten column to
    // its origin by full `Column` identity keeps the `*gw0` reference and
    // aliases it back to the original name, so the subquery hosts outer and
    // resolves it as a correlated outer parameter. `FETCH FIRST 1 ROW ONLY`
    // keeps the scalar single-row; the subquery yields the group key — `T.Id`
    // 1 → 1, 2 → 2, 3 → 3 — each numbered, matching the ordinary `GROUP BY
    // T.Id` form on both run and validate.
    let sets = "SELECT (SELECT T.Id FROM U FETCH FIRST 1 ROW ONLY), " +
               "ROW_NUMBER() OVER () FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[1, 1], [2, 2], [3, 3]])
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 2)
    let plain = "SELECT (SELECT T.Id FROM U FETCH FIRST 1 ROW ONLY), " +
                "ROW_NUMBER() OVER () FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[1, 1], [2, 2], [3, 3]])
  }

  @Test func `a bare-column subquery projecting a local column rides through`()
      throws {
    // The regression the retained rewrite must not disturb: a hosted scalar
    // subquery projecting a bare column that is NOT a correlation — `(SELECT
    // U.v FROM U WHERE U.k = 2 FETCH FIRST 1 ROW ONLY)` names `U`'s own local
    // column, no group key. The `.columns` rewrite leaves every column intact
    // (`U.v` is not a key and stays verbatim), so the list compares equal to
    // its origin and the subquery rides through — hosted outer, uncorrelated,
    // the same 200 per group. Each row numbered, matching the ordinary `GROUP
    // BY T.Id` form on both run and validate.
    let sets = "SELECT T.Id, (SELECT U.v FROM U WHERE U.k = 2 " +
               "FETCH FIRST 1 ROW ONLY), ROW_NUMBER() OVER () " +
               "FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[1, 200, 1], [2, 200, 2],
                                           [3, 200, 3]])
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 3)
    let plain = "SELECT T.Id, (SELECT U.v FROM U WHERE U.k = 2 " +
                "FETCH FIRST 1 ROW ONLY), ROW_NUMBER() OVER () " +
                "FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[1, 200, 1], [2, 200, 2],
                                            [3, 200, 3]])
  }

  @Test func `a correlated EXISTS CASE guard hosts outer over the union`()
      throws {
    // Finding 1: a correlated predicate subquery in a `CASE` guard — `EXISTS
    // (SELECT U.k FROM U WHERE U.k = T.Id)` — was hosted verbatim and could not
    // bind `T.Id` (the outer scope holds only `*gwN`), faulting `.column`. The
    // lifter now rewrites the guard subquery's free qualified `T.Id` to its
    // `*gwN` union column and hosts it, so it resolves against the union scope
    // as a correlated outer parameter. `T.Id` 1 has a child `k = 1` and 2 has
    // `k = 2` (guard true → 1); `T.Id` 3 has none (false → 0), each numbered,
    // matching the ordinary `GROUP BY T.Id` form on both run and validate.
    let sets =
        "SELECT CASE WHEN EXISTS (SELECT U.k FROM U WHERE U.k = T.Id) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () " +
        "FROM T GROUP BY GROUPING SETS ((T.Id))"
    try correlated().expect(sets, yields: [[1, 1], [1, 2], [0, 3]])
    #expect(try correlated().columns(of: parse(query: sets), validate: true)
                .count == 2)
    let plain =
        "SELECT CASE WHEN EXISTS (SELECT U.k FROM U WHERE U.k = T.Id) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () FROM T GROUP BY T.Id"
    try correlated().expect(plain, yields: [[1, 1], [1, 2], [0, 3]])
  }

  @Test func `a correlated LEAD fallback over a zero group stays lazy`()
      throws {
    // Finding 2: a `LEAD` fallback nests a scalar subquery correlated to the
    // group key by a qualified `T.Id` — `(SELECT SUM(U.v) / T.Id FROM U)` —
    // a `T.Id = 0` group. Arm-lifting the fallback evaluated it eagerly per
    // group, dividing `SUM(U.v)` by zero and faulting `.divide`. Hosting it in
    // the outer `LEAD` (its qualified `T.Id` rewritten to `*gwN`) keeps it a
    // lazily evaluated operand: offset 0 always lands on the current row, so
    // fallback never evaluates and the division never happens — the row is the
    // current `T.Id` (0), matching the ordinary `GROUP BY T.Id` form.
    let sets = "SELECT LEAD(T.Id, 0, (SELECT SUM(U.v) / T.Id FROM U)) " +
               "OVER (ORDER BY T.Id) FROM T GROUP BY GROUPING SETS ((T.Id))"
    try zeroed().expect(sets, yields: [[0]])
    let plain = "SELECT LEAD(T.Id, 0, (SELECT SUM(U.v) / T.Id FROM U)) " +
                "OVER (ORDER BY T.Id) FROM T GROUP BY T.Id"
    try zeroed().expect(plain, yields: [[0]])
  }

  @Test func `an unqualified key-colliding subquery still arm-lifts`()
      throws {
    // The residual the qualified-free rewrite leaves arm-lifted: a scalar
    // subquery whose only correlation is an unqualified `dept` — `(SELECT
    // SUM(U.v) FROM U WHERE U.v > dept)`. `dept` unqualified might be a local
    // base column of `U`, undecidable pre-schema, so the lifter cannot safely
    // rewrite it to `*gwN` and host the subquery — it falls back to arm-lift (a
    // `*gwN` column), where the arm's grouped scope binds `dept` to the group.
    // Hosting it verbatim would leave `dept` unresolved over the `*gwN`-only
    // union scope and fault `.column`; arm-lifted it returns rows — `dept` 1
    // sums `U.v > 1` (2 + 3 = 5), 2 sums `> 2` (3), 3 sums `> 3` (none, NULL) —
    // the same values the ordinary `GROUP BY dept` yields, value-correct if
    // eager, only forgoing the lazy outer host.
    let sets = "SELECT dept, (SELECT SUM(U.v) FROM U WHERE U.v > dept), " +
               "ROW_NUMBER() OVER () FROM Emp GROUP BY GROUPING SETS ((dept))"
    try colliding().expect(sets, yields: [[1, 5, 1], [2, 3, 2], [3, nil, 3]])
    let plain = "SELECT dept, (SELECT SUM(U.v) FROM U WHERE U.v > dept), " +
                "ROW_NUMBER() OVER () FROM Emp GROUP BY dept"
    try colliding().expect(plain, yields: [[1, 5, 1], [2, 3, 2], [3, nil, 3]])
  }

  @Test func `a grouped IN-subquery guard substitutes its left operand`()
      throws {
    // Finding: a window-free `CASE` guard `dept IN (SELECT e.dept FROM Emp AS
    // e)` bears a subquery beside a grounded left operand. The subquery stays
    // hosted whole by the union-scope `Resolution`, but the left `dept` — a
    // group value the `*gwN`-only outer scope cannot resolve — must substitute
    // to its `*gw0` arm column, exactly as `dept` does in a scalar position.
    // Returning the guard verbatim left `dept` unresolved, faulting `.column`.
    // Every group's `dept` (1, 2, 3) is in the subquery's `{1, 2, 3}`, so the
    // guard is true and the `CASE` yields 1, each numbered, matching the
    // ordinary `GROUP BY dept` companion.
    let sets =
        "SELECT CASE WHEN dept IN (SELECT e.dept FROM Emp AS e) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[1, 1], [1, 2], [1, 3]])
    let plain =
        "SELECT CASE WHEN dept IN (SELECT e.dept FROM Emp AS e) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[1, 1], [1, 2], [1, 3]])
  }

  @Test func `an unqualified IN-subquery guard resolves the inner locally`()
      throws {
    // The reviewer's example (gs-2): `CASE WHEN dept IN (SELECT dept FROM Emp)
    // THEN 1 ELSE 0 END` over `GROUPING SETS ((dept))`. The guard's left `dept`
    // is the group key, substituted to its `*gw0` arm column; the subquery's
    // unqualified inner `dept` collides with that key name, so the rewrite walk
    // blocks and the membership hosts verbatim — resolving `dept` locally to
    // its own `Emp`, an uncorrelated subquery, not the group key. Every group's
    // `dept` is in the subquery's `{1, 2, 3}`, so `CASE` yields 1 per group,
    // each numbered, matching the ordinary `GROUP BY dept` companion on run and
    // validate. The windowed CASE value that still defers (#136) is covered by
    // `a windowed CASE over GROUPING SETS is deferred` above.
    let sets =
        "SELECT CASE WHEN dept IN (SELECT dept FROM Emp) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[1, 1], [1, 2], [1, 3]])
    #expect(try fixture().columns(of: parse(query: sets), validate: true)
                .count == 2)
    let plain =
        "SELECT CASE WHEN dept IN (SELECT dept FROM Emp) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[1, 1], [1, 2], [1, 3]])
  }

  @Test func `a grouped quantified guard substitutes its left operand`()
      throws {
    // The quantified form of the same finding: `dept = ANY (SELECT e.dept FROM
    // Emp AS e)` bears the subquery beside the grounded left `dept`, which
    // substitutes to its `*gw0` arm column while the subquery stays hosted
    // whole. `= ANY` over the subquery's `{1, 2, 3}` holds for every group's
    // `dept`, so the `CASE` yields 1, matching the ordinary `GROUP BY dept`
    // companion; before the fix the left `dept` was left unresolved, faulting
    // `.column`.
    let sets =
        "SELECT CASE WHEN dept = ANY (SELECT e.dept FROM Emp AS e) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[1, 1], [1, 2], [1, 3]])
    let plain =
        "SELECT CASE WHEN dept = ANY (SELECT e.dept FROM Emp AS e) " +
        "THEN 1 ELSE 0 END, ROW_NUMBER() OVER () FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[1, 1], [1, 2], [1, 3]])
  }

  @Test func `a local key-colliding subquery hosts outer and stays lazy`()
      throws {
    // Finding: a `LEAD` default nests a scalar subquery whose columns are all
    // qualified by its own alias `e` — `(SELECT SUM(e.sal) / 0 FROM Emp AS e
    // WHERE e.dept = e.dept)`. It is uncorrelated: every reference is bound
    // within its own `FROM Emp AS e`, none free. The bare-name intersection
    // wrongly read the local `e.dept` as the group key `dept` and arm-lifted
    // the subquery — evaluated eagerly per group, dividing by zero. Classified
    // by free variables it hosts outer and rides the executor's conditional
    // evaluation: offset 0 always lands on the current row, so the default
    // never evaluates and the subquery never divides — each group's `dept`
    // returned, matching the ordinary `GROUP BY dept` companion.
    let sets =
        "SELECT LEAD(dept, 0, " +
        "(SELECT SUM(e.sal) / 0 FROM Emp AS e WHERE e.dept = e.dept)) " +
        "OVER (ORDER BY dept) FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[1], [2], [3]])
    let plain =
        "SELECT LEAD(dept, 0, " +
        "(SELECT SUM(e.sal) / 0 FROM Emp AS e WHERE e.dept = e.dept)) " +
        "OVER (ORDER BY dept) FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[1], [2], [3]])
  }

  @Test func `a local subquery colliding a key hosts above a zero FETCH`()
      throws {
    // The projection half: an uncorrelated scalar subquery whose local `e.dept`
    // collides with the group key `dept` — `(SELECT SUM(e.sal) / 0 FROM Emp AS
    // e WHERE e.dept = e.dept)` — is hosted in the outer layer above the
    // `Project(Limit(Sort))` cap, not arm-lifted below it. A zero `FETCH` drops
    // every row before the projection runs, so the division never happens and
    // the query returns the empty page, matching the ordinary `GROUP BY dept`
    // companion. The bare-name intersection arm-lifted it and divided per
    // group; free-variable classification keeps it outer and lazy. `columns(of:
    // validate:)` agrees over the union scope, typing its two columns.
    let sql =
        "SELECT (SELECT SUM(e.sal) / 0 FROM Emp AS e WHERE e.dept = e.dept), " +
        "ROW_NUMBER() OVER () FROM Emp " +
        "GROUP BY GROUPING SETS ((dept)) FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
    let plain =
        "SELECT (SELECT SUM(e.sal) / 0 FROM Emp AS e WHERE e.dept = e.dept), " +
        "ROW_NUMBER() OVER () FROM Emp GROUP BY dept FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(plain)
  }

  @Test func `a stateful derived source materialises per arm`() throws {
    // The finding: a windowed grouping-sets over a stateful derived table must
    // materialise that source per arm — as the non-windowed grouping-sets over
    // the same source does — not once for both arms. The window layer rides
    // above the arm union, so the query keeps a `.select` body and once took
    // the ordinary executor, which materialises the derived `d` a single time
    // and scans those rows in every arm. Routed through the carrier-aware
    // executor, the `.window` descent carries the union to the setop leaf,
    // where each arm augments its own `d` — so `tick()` runs afresh per arm.
    //
    // The `(x)` arm ticks 1..5, each its own group summing to itself; the `()`
    // arm ticks a fresh 6..10 summing to 40. Ten calls, the grand total 40 —
    // where a single materialisation reused 1..5 and summed the grand total to
    // 15 over five calls. The `tick()` count matches the non-windowed
    // companion below, proving the `.window` carrier descent (dead before) is
    // now reached.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT tick() AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x), ())",
        yields: [[1, 1], [2, 2], [3, 3], [4, 4], [5, 5], [40, 6]],
        routines: routines)
    #expect(counter.count == 10)
  }

  @Test func `the non-windowed form is the per-arm reference`() throws {
    // The reference the windowed form is pinned to: the equivalent non-windowed
    // grouping-sets over the same stateful derived source. It expands to a
    // `UNION ALL` whose arms run per arm, so `tick()` runs afresh in each — the
    // `(x)` arm 1..5, the `()` arm a fresh 6..10 summing to 40, ten calls. The
    // windowed form above reports the same aggregate column and the same ten
    // calls; the second column is the constant `0` here, `ROW_NUMBER()` there.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT SUM(x), 0 FROM (SELECT tick() AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x), ())",
        yields: [[1, 0], [2, 0], [3, 0], [4, 0], [5, 0], [40, 0]],
        routines: routines)
    #expect(counter.count == 10)
  }

  @Test func `a deterministic derived source is unchanged by the routing`()
      throws {
    // The no-regression guard: routing a windowed grouping-sets through the
    // carrier-aware executor must not alter a deterministic source's rows.
    // Materialising `sal` once or per arm yields the identical values, so the
    // grouped sums and the row numbers are the same either way — the `(x)`
    // groups 100, 200, 600 (the two 300s), 500 and the grand total 1400.
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x), ())",
        yields: [[100, 1], [200, 2], [600, 3], [500, 4], [1400, 5]])
  }

  @Test func `a derived source under a capped sort executes per arm`() throws {
    // A query `ORDER BY … FETCH n` over a windowed grouping-sets fuses into a
    // `top` above the window: the generic optimiser a `.select`-bodied plan
    // takes fuses a bounded limit over a sort, where the set-operation
    // carrier's own optimise never does. The carrier-aware descent must carry
    // the union through that `top` to the setop leaf — else the leaf scans a
    // derived `d` the revealed context no longer binds and faults `.relation`,
    // breaking run ≡ validate. Over a derived source ordered by the aggregate
    // and paged to three rows, the head is 100, 200, 500 — the arms
    // materialising `sal` per arm (the same deterministic values either way).
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER (ORDER BY SUM(x)) " +
        "FROM (SELECT sal AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x), ()) ORDER BY 1 FETCH FIRST 3 ROWS ONLY",
        yields: [[100, 1], [200, 2], [500, 3]])
  }

  @Test func `a single-set derived source materialises for the lone arm`()
      throws {
    // The finding: a single-set `GROUPING SETS ((x))` reduces to one grouped
    // arm — `decompose` returns a plain `.select`, not a `.setop` — so its arm
    // union is not carrier-routed. The per-arm carrier path assumes a setop and
    // never materialises the lone arm's derived `d`, and the schema-only bind
    // it pairs with drops `d`'s rows, so the query faulted an unknown relation.
    // A single arm augments and runs through the ordinary per-query path
    // instead: `d` materialises once (one arm, so per-arm and per-query
    // coincide) and the grouped window reads it. The `(x)` groups are 100, 200,
    // 600 (the two 300s), 500, numbered 1..4 — exactly the ordinary `GROUP BY
    // x` companion below.
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x))",
        yields: [[100, 1], [200, 2], [600, 3], [500, 4]])
  }

  @Test func `the ordinary derived companion is the single-set reference`()
      throws {
    // The reference the single-set form is pinned to: the ordinary `GROUP BY x`
    // windowed query over the same derived source, which the mature grouped-
    // window path has always handled. Its grouped sums and row numbers are the
    // single-set spelling's, proving the single arm reaches this path.
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d GROUP BY x",
        yields: [[100, 1], [200, 2], [600, 3], [500, 4]])
  }

  @Test func `a stateful single-set derived source matches the ordinary form`()
      throws {
    // A single set has one arm, so per-arm and per-query materialisation
    // coincide: the ordinary per-query path materialises the stateful `d` once
    // and its lone arm reads those rows, the same as an arm materialising its
    // own copy. `tick()` runs once per source row (five Emp rows, five calls),
    // each `x` distinct so each groups alone summing to itself — 1..5, numbered
    // 1..5 — the identical `tick()` count and rows the ordinary `GROUP BY x`
    // companion yields.
    let sets = Counter()
    let plain = Counter()
    func routines(_ counter: Counter) throws -> Routines {
      try Routines.standard
          .registering("tick", returns: .integer, deterministic: false) { _ in
            .integer(counter.next())
          }
    }
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT tick() AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x))",
        yields: [[1, 1], [2, 2], [3, 3], [4, 4], [5, 5]],
        routines: try routines(sets))
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT tick() AS x FROM Emp) d GROUP BY x",
        yields: [[1, 1], [2, 2], [3, 3], [4, 4], [5, 5]],
        routines: try routines(plain))
    #expect(sets.count == 5)
    #expect(plain.count == sets.count)
  }

  @Test func `a grand-total single set matches the implicit-group window`()
      throws {
    // The other single set: `GROUPING SETS (())`, the grand total. It too is
    // one arm — `expand` returns the lone grouped `.select` — so it runs the
    // ordinary per-query path over the derived source. The whole result is one
    // group summing 1400, `ROW_NUMBER()` numbering the single row 1 — matching
    // the `GROUP BY ()` implicit-group window companion below.
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS (())",
        yields: [[1400, 1]])
    try fixture().expect(
        "SELECT SUM(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d GROUP BY ()",
        yields: [[1400, 1]])
  }

  @Test func `a single-set GROUPING is zero over the derived source`() throws {
    // In a single set every argument is a grouping key of the lone set, so
    // `GROUPING(x)` is 0 for every group — the standard result when no column
    // is rolled up, identical to the ordinary `GROUP BY x` companion. A window
    // makes this the windowed single-arm shape, so it confirms the single arm
    // reaching the ordinary path preserves `GROUPING`.
    try fixture().expect(
        "SELECT SUM(x), GROUPING(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d " +
        "GROUP BY GROUPING SETS ((x))",
        yields: [[100, 0, 1], [200, 0, 2], [600, 0, 3], [500, 0, 4]])
    try fixture().expect(
        "SELECT SUM(x), GROUPING(x), ROW_NUMBER() OVER () " +
        "FROM (SELECT sal AS x FROM Emp) d GROUP BY x",
        yields: [[100, 0, 1], [200, 0, 2], [600, 0, 3], [500, 0, 4]])
  }

  @Test func `a grand-total set with an offset drops the unreachable wrapper`()
      throws {
    // The finding: the grand-total single set `GROUPING SETS (())` produces one
    // whole-result row, so a positive `OFFSET` skips it and the outer
    // projection never runs. `NULLIF(ROW_NUMBER() OVER (), 'x')` (integer
    // versus text) would fault 42804 if reachable, but the cap discards the
    // sole row first — the run returns the empty page and `columns(of:
    // validate:)` accepts its one column. Deriving the outer layer's single-row
    // flag from the decomposition (one arm, no keys) makes both paths treat the
    // grand total as single-row, as the ordinary whole-result aggregate oracle
    // below does. Before this the flag was hard-coded multi-row, so the offset
    // left the projection reachable and the comparability preflight faulted
    // 42804 though the run dropped the row before `NULLIF` could run.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') " +
              "FROM Emp GROUP BY GROUPING SETS (()) OFFSET 1 ROW"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 1)
    // The ordinary single-row oracle: a whole-result aggregate makes the row
    // count one, so the same offset skips the sole row and elides its
    // projection alike, on both paths.
    let plain = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x'), SUM(sal) " +
                "FROM Emp OFFSET 1 ROW"
    try fixture().empty(plain)
    #expect(try fixture().columns(of: parse(query: plain), validate: true)
                .count == 2)
  }

  @Test func `a grand-total set without an offset still faults its wrapper`()
      throws {
    // The regression guard against over-sparing: the one grand-total row is
    // produced with no cap, so the outer projection is reachable and the
    // incomparable `NULLIF(ROW_NUMBER() OVER (), 'x')` faults 42804 on both
    // paths — unchanged by the derivation, which spares the projection only
    // when a row-dropping cap makes it unreachable.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') " +
              "FROM Emp GROUP BY GROUPING SETS (())"
    let fault = SQLError.state(
        "42804", "cannot compare integer with character varying")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a non-empty single set stays multi-row under an offset`()
      throws {
    // The regression guard against under-sparing: `GROUPING SETS ((dept))`
    // groups by `dept` — three groups, so `OFFSET 1` leaves rows and the outer
    // projection is reachable. The single-row flag is false for a non-empty
    // single set (one arm, but keys present), so the incomparable wrapper still
    // faults 42804 on both paths, unchanged.
    let sql = "SELECT NULLIF(ROW_NUMBER() OVER (), 'x') " +
              "FROM Emp GROUP BY GROUPING SETS ((dept)) OFFSET 1 ROW"
    let fault = SQLError.state(
        "42804", "cannot compare integer with character varying")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a valid grand-total window with an offset returns the page`()
      throws {
    // The derivation must not over-reject a well-typed grand total: `SUM(sal)`
    // over the one whole-result group is 1400, `ROW_NUMBER() OVER ()` numbers
    // it 1, and `OFFSET 1` skips that sole row — the empty page, on both paths,
    // matching the ordinary whole-result aggregate window oracle below.
    let sql = "SELECT SUM(sal), ROW_NUMBER() OVER () " +
              "FROM Emp GROUP BY GROUPING SETS (()) OFFSET 1 ROW"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
    let plain = "SELECT SUM(sal), ROW_NUMBER() OVER () FROM Emp OFFSET 1 ROW"
    try fixture().empty(plain)
  }

  @Test func `a windowed GROUPING SETS NULL arm infers the union's text`()
      throws {
    // The finding: a constant NULL in a windowed grouping-sets arm places no
    // type constraint on the set-op's unified column, so the text arm decides
    // it — column 1 infers text. The schema twin now derives the complete
    // `ResolvedColumn` (type AND `unconstrained` mask) through the ordinary
    // projection-output logic, so it no longer hand-stamps the NULL a
    // constrained integer the merge rejects against the text arm (42804). The
    // text arm is a `VALUES` row — this dialect projects a computed row through
    // `VALUES`, not a FROM-less `SELECT`.
    let sql = "SELECT NULL, ROW_NUMBER() OVER () " +
              "FROM Emp GROUP BY GROUPING SETS ((dept)) " +
              "UNION ALL VALUES ('x', 1)"
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .map(\.type) == [.text, .integer])
    try fixture().expect(sql,
                         yields: [[nil, 1], [nil, 2], [nil, 3], ["x", 1]])
    // The oracle: the equivalent ordinary grouped-window arm of the same shape
    // infers the same types and rows — the windowed grouping-sets arm must
    // resolve exactly as its `GROUP BY dept` companion does.
    let plain = "SELECT NULL, ROW_NUMBER() OVER () " +
                "FROM Emp GROUP BY dept UNION ALL VALUES ('x', 1)"
    #expect(try fixture().columns(of: parse(query: plain), validate: true)
                .map(\.type) == [.text, .integer])
    try fixture().expect(plain,
                         yields: [[nil, 1], [nil, 2], [nil, 3], ["x", 1]])
  }

  @Test func `a windowed GROUPING SETS arm second still infers text`()
      throws {
    // The windowed arm as the second operand: the leading text arm still
    // unifies with the trailing NULL, so column 1 infers text regardless of
    // arm order — the trailing windowed arm's NULL stays unconstrained through
    // the merge, not a hand-stamped integer that would fault 42804.
    let sql = "VALUES ('x', 1) UNION ALL " +
              "SELECT NULL, ROW_NUMBER() OVER () " +
              "FROM Emp GROUP BY GROUPING SETS ((dept))"
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .map(\.type) == [.text, .integer])
    try fixture().expect(sql,
                         yields: [["x", 1], [nil, 1], [nil, 2], [nil, 3]])
  }

  @Test func `a constrained windowed GROUPING SETS rejects a text union`()
      throws {
    // The regression guard against over-relaxing: `ROW_NUMBER() OVER ()` is a
    // genuine constrained integer, not a constant NULL, so column 1 keeps its
    // integer constraint and the text arm is irreconcilable — the merge faults
    // 42804 on both paths, unchanged by the mask-preserving derivation.
    let sql = "SELECT ROW_NUMBER() OVER (), 1 " +
              "FROM Emp GROUP BY GROUPING SETS ((dept)) " +
              "UNION ALL VALUES ('x', 1)"
    let fault = SQLError.operand("UNION arms have irreconcilable types")
    try fixture().expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try fixture().columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `an unused LEAD default never evaluates over GROUPING SETS`()
      throws {
    // The finding: a `LEAD` whose offset always lands on an existing row —
    // offset 0 reads the current row — never needs its default, so the default
    // must not evaluate. `Window.position` evaluates a `LEAD`/`LAG` default
    // only for an out-of-range target, so force-lifting the `1 / 0` default
    // into a `*gwN` arm column, evaluated eagerly per group, wrongly raised
    // division-by-zero. Kept in the outer window function — only its grouped
    // values lifted — the default rides the executor's conditional evaluation,
    // so offset 0 never divides and each group's `dept` is returned, matching
    // the ordinary `GROUP BY dept` companion. Before the fix the grouping-sets
    // form faulted `.divide` while the ordinary form did not. (The finding's
    // bare `OVER ()` faults `0A000` first — `LEAD` requires an `ORDER BY` — so
    // the window carries the order the offset reads along.)
    let sets = "SELECT LEAD(dept, 0, 1 / 0) OVER (ORDER BY dept) " +
               "FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[1], [2], [3]])
    let plain = "SELECT LEAD(dept, 0, 1 / 0) OVER (ORDER BY dept) " +
                "FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[1], [2], [3]])
  }

  @Test func `an unused LEAD default subquery never evaluates`() throws {
    // The subquery half of the finding: a `LEAD` default nesting a scalar
    // subquery — `LEAD(dept, 0, (SELECT SUM(sal) / 0 FROM Emp))` — is
    // hosted in the outer window function, not force-lifted to an arm, so it
    // rides the executor's conditional evaluation exactly as a scalar default
    // does. Offset 0 always lands on the current row, so the default never
    // evaluates and the subquery never divides — each group's `dept` is
    // returned, matching the ordinary `GROUP BY dept` companion. Were the
    // subquery arm-lifted (evaluated eagerly per group) the division would
    // fault, as it would for a `1 / 0` default.
    let sets =
        "SELECT LEAD(dept, 0, (SELECT SUM(sal) / 0 FROM Emp)) " +
        "OVER (ORDER BY dept) FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[1], [2], [3]])
    let plain =
        "SELECT LEAD(dept, 0, (SELECT SUM(sal) / 0 FROM Emp)) " +
        "OVER (ORDER BY dept) FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[1], [2], [3]])
  }

  @Test func `an uncorrelated subquery under a zero FETCH is not evaluated`()
      throws {
    // #138: an uncorrelated scalar subquery in the projection is hosted in the
    // outer layer above the `Project(Limit(Sort))` cap — not in an arm below it
    // — so a zero `FETCH` that drops every row leaves it unreached and the
    // subquery never evaluates. `(SELECT SUM(sal) / 0 FROM Emp)` never divides,
    // the query returns the empty page, matching the ordinary `GROUP BY dept`
    // companion. `columns(of: validate:)` agrees — the outer projection sits
    // above the cap, so a dropped page leaves it unreachable and validate types
    // its two columns rather than faulting a division no run reaches.
    let sql =
        "SELECT (SELECT SUM(sal) / 0 FROM Emp), ROW_NUMBER() OVER () " +
        "FROM Emp " +
        "GROUP BY GROUPING SETS ((dept)) FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(sql)
    #expect(try fixture().columns(of: parse(query: sql), validate: true)
                .count == 2)
    let plain =
        "SELECT (SELECT SUM(sal) / 0 FROM Emp), ROW_NUMBER() OVER () " +
        "FROM Emp " +
        "GROUP BY dept FETCH FIRST 0 ROWS ONLY"
    try fixture().empty(plain)
  }

  @Test func `a needed LEAD default still returns over GROUPING SETS`()
      throws {
    // The default still works when the offset genuinely runs off the partition:
    // offset 100 lands past every row, so `Window.position` evaluates the
    // default for each. Keeping the default in the outer window layer preserves
    // that path — every group takes the default `99` — matching the ordinary
    // `GROUP BY dept` companion, so the outer default is used exactly when the
    // executor needs it. A non-faulting default also validates cleanly over
    // the union scope, so run and validate agree, as the ordinary form does.
    let sets = "SELECT LEAD(dept, 100, 99) OVER (ORDER BY dept) " +
               "FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[99], [99], [99]])
    #expect(try fixture().columns(of: parse(query: sets), validate: true)
                .count == 1)
    let plain = "SELECT LEAD(dept, 100, 99) OVER (ORDER BY dept) " +
                "FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[99], [99], [99]])
    #expect(try fixture().columns(of: parse(query: plain), validate: true)
                .count == 1)
  }

  @Test func `a stateful LEAD default evaluates once per out-of-range target`()
      throws {
    // A stateful default `tick()` must evaluate once per out-of-range target,
    // not once per group. The window orders the three groups by `dept` (1, 2,
    // 3); `LEAD(dept, 1, …)` reads the next group for the first two (2, 3) and
    // runs off the end for the last, evaluating the default once — `tick()`
    // yields 1 — so the rows are 2, 3, 1 over one call. Force-lifting the
    // default into the arm evaluated it per group (three calls) and reported
    // the arm's per-group tick (…, 3) rather than the single outer evaluation,
    // diverging from the ordinary `GROUP BY dept` companion, which evaluates
    // the default once (1). Kept outer, the two forms agree in rows and count.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try fixture().expect(
        "SELECT LEAD(dept, 1, tick()) OVER (ORDER BY dept) " +
        "FROM Emp GROUP BY GROUPING SETS ((dept))",
        yields: [[2], [3], [1]], routines: routines)
    #expect(counter.count == 1)
    let other = Counter()
    let plain = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(other.next())
        }
    try fixture().expect(
        "SELECT LEAD(dept, 1, tick()) OVER (ORDER BY dept) " +
        "FROM Emp GROUP BY dept",
        yields: [[2], [3], [1]], routines: plain)
    #expect(other.count == 1)
  }

  @Test func `a grouped-dependent LEAD default lifts only its grouped value`()
      throws {
    // A default depending on a grouped value — `SUM(sal)` — lifts that value
    // to a `*gwN` arm column while the default expression itself stays in the
    // outer window function. Offset 100 runs off the partition, so each group
    // takes its own `SUM(sal)` default — 300, 600, 500 — the grouped value
    // computed in the arm and read by the conditionally evaluated outer
    // default, matching the ordinary `GROUP BY dept` companion. The default
    // validates cleanly over the union scope (its grouped leaf resolved in the
    // arm), so run and validate agree, as the ordinary form does.
    let sets = "SELECT LEAD(dept, 100, SUM(sal)) OVER (ORDER BY dept) " +
               "FROM Emp GROUP BY GROUPING SETS ((dept))"
    try fixture().expect(sets, yields: [[300], [600], [500]])
    #expect(try fixture().columns(of: parse(query: sets), validate: true)
                .count == 1)
    let plain = "SELECT LEAD(dept, 100, SUM(sal)) OVER (ORDER BY dept) " +
                "FROM Emp GROUP BY dept"
    try fixture().expect(plain, yields: [[300], [600], [500]])
    #expect(try fixture().columns(of: parse(query: plain), validate: true)
                .count == 1)
  }

  @Test func `an unused LEAD default never evaluates over multiple sets`()
      throws {
    // The multi-set companion of the finding: with two grouping sets the arm
    // union is a genuine `UNION ALL`, and the outer window still holds the
    // conditionally evaluated `1 / 0` default. Offset 0 reads each row's own
    // `dept` — the grand-total row's rolled-up NULL included — so at run the
    // default never evaluates and no division occurs. Before the fix the arm's
    // eager `1 / 0` faulted `.divide`. (Validate constant-folds the `1 / 0`
    // default and faults it identically to the ordinary grouped-window form —
    // a pre-existing property of the validator shared by both paths — so this
    // asserts only the run; the non-faulting defaults above cover run ≡
    // validate over the union scope.)
    let sql = "SELECT dept, LEAD(dept, 0, 1 / 0) OVER (ORDER BY dept) " +
              "FROM Emp GROUP BY GROUPING SETS ((dept), ())"
    try fixture().expect(sql, yields: [[1, 1], [2, 2], [3, 3], [nil, nil]])
  }

  // The finding's body: a window over two grouping sets, reading a derived
  // source `d`. The carrier-aware routing that per-arm re-materialises `d`
  // lived only in the top-level `run`; a view body and a correlated subquery
  // reached their own executor entry points, which recognised a union only by
  // a `.setop` body and so scanned the schema-only `d` once — dropping the arm
  // rows. Every entry point now consults the one `union(windowed:)` decision.
  private var body: String {
    "SELECT SUM(x), ROW_NUMBER() OVER () " +
    "FROM (SELECT sal AS x FROM Emp) d GROUP BY GROUPING SETS ((x), ())"
  }

  // The finding's body over an `Emp` beside a view `v` whose body is exactly
  // it, so a run of the view and a run of the body share one catalog.
  private func viewed() throws -> FixtureCatalog {
    try Catalog {
      Relation("Emp", ["dept": .integer, "sal": .integer]) {
        Row(1, 100)
        Row(1, 200)
        Row(2, 300)
        Row(2, 300)
        Row(3, 500)
      }
      try View("v", body, as: ["s", "n"])
    }
  }

  @Test func `a windowed GROUPING SETS view matches the top-level result`()
      throws {
    // Selecting from the view returns the same groups running the body at top
    // level does — the per-arm materialised union, not an empty schema-only
    // `d`. Both run the same plan, so the row order coincides.
    try viewed().expect("SELECT s, n FROM v", equals: body)
  }

  @Test func `a windowed GROUPING SETS view yields the per-set groups`()
      throws {
    // The concrete groups: the `(x)` arm sums each distinct salary (100, 200,
    // 500, and the two 300s to 600) and the `()` arm the grand total 1400. The
    // window numbers them by that ascending sum, so ordering the view output by
    // it reads out 100, 200, 500, 600, 1400 numbered 1 through 5.
    let ordered = "SELECT SUM(x) AS s, "
                + "ROW_NUMBER() OVER (ORDER BY SUM(x)) AS n "
                + "FROM (SELECT sal AS x FROM Emp) d "
                + "GROUP BY GROUPING SETS ((x), ())"
    let catalog = try Catalog {
      Relation("Emp", ["dept": .integer, "sal": .integer]) {
        Row(1, 100)
        Row(1, 200)
        Row(2, 300)
        Row(2, 300)
        Row(3, 500)
      }
      try View("v", ordered, as: ["s", "n"])
    }
    try catalog.expect(
        "SELECT s, n FROM v ORDER BY s",
        yields: [[100, 1], [200, 2], [500, 3], [600, 4], [1400, 5]])
  }

  @Test func `a correlated LATERAL windowed GROUPING SETS over a source`()
      throws {
    // The body as a correlated LATERAL over a derived source `d`: `d` reads all
    // of `U`, and a body-level `WHERE d.k = T.Id` correlates to the enclosing
    // row, so the apply runs through `executed` per outer row. Per `T` row the
    // arms re-materialise `d` and filter it to that row's children: Id 1 sums
    // 100, 101 and the total 201; Id 2 sums 200 and the equal total; Id 3 has
    // no children, so only its grand-total NULL. Before the fix `executed`
    // scanned the schema-only `d` and dropped the arm rows.
    try correlated().expect(
        "SELECT T.Id, d.s, d.n FROM T JOIN LATERAL (" +
        "SELECT SUM(x) AS s, ROW_NUMBER() OVER (ORDER BY SUM(x)) AS n " +
        "FROM (SELECT k, v AS x FROM U) d WHERE d.k = T.Id " +
        "GROUP BY GROUPING SETS ((x), ())) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.n",
        yields: [[1, 100, 1], [1, 101, 2], [1, 201, 3],
                 [2, 200, 1], [2, 200, 2], [3, nil, 1]])
  }

  @Test func `a stateful source re-materialises per arm in a view`() throws {
    // A counting `tick()` in the derived source over the single-row `T` fires
    // once per arm materialisation: the two grouping sets drive two arms, so
    // both a top-level run and a view run invoke it twice. Before the fix the
    // view scanned the schema-only source, never materialising it — zero calls,
    // the arm rows dropped.
    let sql = "SELECT SUM(x), ROW_NUMBER() OVER () " +
              "FROM (SELECT tick() AS x FROM T) d " +
              "GROUP BY GROUPING SETS ((x), ())"
    let top = Counter()
    let plain = try Catalog { Relation("T", ["v": .integer]) { Row(0) } }
    try plain.expect(sql, yields: [[1, 1], [2, 2]],
                     routines: ticking(top))
    #expect(top.count == 2)
    let counter = Counter()
    let catalog = try Catalog {
      Relation("T", ["v": .integer]) { Row(0) }
      try View("v", sql, as: ["s", "n"])
    }
    try catalog.expect("SELECT s, n FROM v", yields: [[1, 1], [2, 2]],
                       routines: ticking(counter))
    #expect(counter.count == 2)
  }

  // The windowed grouping-sets arm reading a derived source, its window ordered
  // so the row number is a function of the sum.
  private var arm: String {
    "SELECT SUM(x) AS s, ROW_NUMBER() OVER (ORDER BY SUM(x)) AS r " +
    "FROM (SELECT sal AS x FROM Emp) d GROUP BY GROUPING SETS ((x), ())"
  }

  @Test func `a windowed GROUPING SETS UNION arm keeps its groups`() throws {
    // The windowed grouping-sets body as an explicit `UNION ALL` arm carried by
    // an outer `ORDER BY`, so the arm descends through `arms` — the recursive
    // twin of `executed`. Its per-set sums (100, 200, 500, 600 and the grand
    // total 1400) must survive beside the plain second arm's rows, not collapse
    // to the lone schema-only grand total the unfixed `arms` leaf produced.
    try fixture().expect(
        "(\(arm)) UNION ALL (SELECT dept, dept FROM Emp) ORDER BY s, r",
        yields: [[1, 1], [1, 1], [2, 2], [2, 2], [3, 3],
                 [100, 1], [200, 2], [500, 3], [600, 4], [1400, 5]])
  }

  @Test func `a view union with a windowed GROUPING SETS arm keeps groups`()
      throws {
    // The same union as a view body, so the arm descends through the view-body
    // `setop` twin. Selecting from the view returns the per-set groups beside
    // the plain arm, matching the top-level union.
    let catalog = try Catalog {
      Relation("Emp", ["dept": .integer, "sal": .integer]) {
        Row(1, 100)
        Row(1, 200)
        Row(2, 300)
        Row(2, 300)
        Row(3, 500)
      }
      try View("v", "(\(arm)) UNION ALL (SELECT dept, dept FROM Emp)",
               as: ["s", "r"])
    }
    try catalog.expect(
        "SELECT s, r FROM v ORDER BY s, r",
        yields: [[1, 1], [1, 1], [2, 2], [2, 2], [3, 3],
                 [100, 1], [200, 2], [500, 3], [600, 4], [1400, 5]])
  }

  /// A non-deterministic routine set whose `tick()` returns `counter`'s next
  /// value, so a run counts how many times the source it sits in materialised.
  private func ticking(_ counter: Counter) throws -> Routines {
    try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
  }
}
