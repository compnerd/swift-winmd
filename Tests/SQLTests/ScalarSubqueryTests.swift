// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// Two relations exercising the uncorrelated SCALAR subquery: an outer `T`
/// whose integer key `V` ranges over a known set, and an inner source `S`
/// whose `V` a scalar subquery reduces with `MIN`/`MAX`, plus an EMPTY-able
/// `E` (filtered to no rows) for the empty → NULL corner and a MULTI-row `M`
/// (two rows) for the >1-row cardinality fault.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "V": .integer]) {
      Row(1, 10)
      Row(2, 20)
      Row(3, 30)
    }
    Relation("S", ["V": .integer]) {
      Row(10)
      Row(20)
      Row(30)
    }
    // A source with two rows and a text column, for the >1-row fault and the
    // type-of-the-inner-column check.
    Relation("M", ["W": .integer, "Name": .text]) {
      Row(1, "a")
      Row(2, "b")
    }
    // A source that filters to no rows via `Flag`, for the empty → NULL corner.
    Relation("E", ["V": .integer, "Flag": .integer]) {
      Row(99, 0)
    }
  }
}

/// Parses `text` and returns its `Select`, failing on any other shape.
private func parse(select text: String) throws -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

/// Parses `text` to a query, failing on any other statement.
private func parse(query text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

// MARK: - Parsing

struct ScalarSubqueryParsingTests {
  @Test func `parses a scalar subquery in the projection`() throws {
    let select =
        try parse(select: "SELECT (SELECT MAX(V) FROM S) AS m FROM T")
    let inner = try parse(query: "SELECT MAX(V) FROM S")
    guard case let .expressions(items) = select.projection else {
      Issue.record("expected an expressions projection")
      return
    }
    #expect(items.count == 1)
    #expect(items[0].expression == .subquery(inner))
    #expect(items[0].alias == "m")
  }

  @Test func `parses a scalar subquery as a comparison operand`() throws {
    let select = try parse(
        select: "SELECT Id FROM T WHERE V = (SELECT MIN(V) FROM S)")
    let inner = try parse(query: "SELECT MIN(V) FROM S")
    #expect(select.predicate
                == .comparison(left: .column("V"), op: .equal,
                               right: .subquery(inner)))
  }

  @Test func `a parenthesised arithmetic stays arithmetic`() throws {
    // The one-token lookahead only takes the subquery arm on a leading SELECT;
    // `(1 + 2)` is an ordinary parenthesised expression, not a subquery.
    let select = try parse(select: "SELECT (1 + 2) AS n FROM T")
    guard case let .expressions(items) = select.projection else {
      Issue.record("expected an expressions projection")
      return
    }
    #expect(items[0].expression
                == .binary(.add, .literal(.integer(1)),
                           .literal(.integer(2))))
  }

  @Test func `disambiguates a subquery from a group by the SELECT peek`()
      throws {
    // `(SELECT …)` is a subquery; `(1 + V)` is a parenthesised expression —
    // the same leading `(`, resolved by the one token after it.
    let subquery = try parse(select: "SELECT (SELECT MAX(V) FROM S) FROM T")
    let group = try parse(select: "SELECT (1 + V) AS n FROM T")
    guard case let .expressions(subItems) = subquery.projection,
        case let .expressions(groupItems) = group.projection else {
      Issue.record("expected expressions projections")
      return
    }
    if case .subquery = subItems[0].expression {} else {
      Issue.record("expected a scalar subquery")
    }
    #expect(groupItems[0].expression
                == .binary(.add, .literal(.integer(1)), .column("V")))
  }

  @Test func `a scalar subquery round-trips by AST equality`() throws {
    // Two parses of the same scalar-subquery query yield equal ASTs — the
    // nested `Query` composes the synthesized `Hashable`/`Equatable`.
    let text = "SELECT (SELECT MAX(V) FROM S) AS m FROM T"
    #expect(try parse(query: text) == parse(query: text))
  }

  @Test func `a scalar subquery over a UNION parses`() throws {
    // A scalar subquery is a full `query`, so it may itself be a `UNION`.
    let text =
        "SELECT (SELECT V FROM S UNION SELECT W FROM M) FROM T"
    let select = try parse(select: text)
    let inner = try parse(query: "SELECT V FROM S UNION SELECT W FROM M")
    guard case let .expressions(items) = select.projection else {
      Issue.record("expected an expressions projection")
      return
    }
    #expect(items[0].expression == .subquery(inner))
  }
}

// MARK: - Projection execution

struct ScalarSubqueryProjectionTests {
  @Test func `a scalar subquery in the projection is the same per row`()
      throws {
    // `(SELECT MAX(V) FROM S)` is 30 for EVERY outer row — uncorrelated, run
    // once — so each `T` row projects (Id, 30).
    try fixture().expect(
        "SELECT Id, (SELECT MAX(V) FROM S) AS m FROM T ORDER BY Id",
        yields: [[1, 30], [2, 30], [3, 30]])
  }

  @Test func `a scalar subquery folds like its literal value`() throws {
    // The scalar collapses to a constant 30, so projecting it equals
    // projecting the literal 30 for every row.
    try fixture().expect(
        "SELECT Id, (SELECT MAX(V) FROM S) FROM T",
        equals: "SELECT Id, 30 FROM T")
  }

  @Test func `a scalar subquery types from its inner column`() throws {
    // The scalar's TYPE is the inner projection's single-column type: `MAX(V)`
    // over an integer column is integer, and a text inner column makes the
    // scalar text.
    let integer = try parse(query: "SELECT (SELECT MAX(V) FROM S) AS m FROM T")
    let integerColumns = try fixture().columns(of: integer, validate: true)
    #expect(integerColumns.count == 1)
    #expect(integerColumns[0].type == .integer)

    let text = try parse(query:
        "SELECT (SELECT MAX(Name) FROM M) AS n FROM T")
    let textColumns = try fixture().columns(of: text, validate: true)
    #expect(textColumns[0].type == .text)
  }
}

// MARK: - Comparison execution

struct ScalarSubqueryComparisonTests {
  @Test func `a scalar subquery as a comparison operand filters`() throws {
    // `WHERE V = (SELECT MIN(V) FROM S)` keeps the row whose V is the minimum
    // (10) — row 1.
    try fixture().expect(
        "SELECT Id FROM T WHERE V = (SELECT MIN(V) FROM S)", yields: [[1]])
  }

  @Test func `a scalar subquery comparison folds like its value`() throws {
    // The scalar collapses to 10, so the comparison equals `V = 10`.
    try fixture().expect(
        "SELECT Id FROM T WHERE V = (SELECT MIN(V) FROM S)",
        equals: "SELECT Id FROM T WHERE V = 10")
  }

  @Test func `a scalar subquery works in arithmetic`() throws {
    // The scalar is an ordinary expression, so it composes in arithmetic:
    // `V - (SELECT MIN(V) FROM S)` is `V - 10`.
    try fixture().expect(
        "SELECT V - (SELECT MIN(V) FROM S) AS d FROM T ORDER BY d",
        yields: [[0], [10], [20]])
  }
}

// MARK: - Empty and NULL

struct ScalarSubqueryEmptyTests {
  @Test func `an empty scalar subquery yields NULL`() throws {
    // A scalar subquery over an empty source is NULL (not an error, not zero) —
    // `E` filtered to `Flag = 1` has no row.
    try fixture().expect(
        "SELECT Id, (SELECT V FROM E WHERE Flag = 1) AS m FROM T ORDER BY Id",
        yields: [[1, nil], [2, nil], [3, nil]])
  }

  @Test func `an empty scalar subquery NULL propagates in arithmetic`()
      throws {
    // The empty scalar is NULL, and NULL propagates through `+` — every row's
    // computed column is NULL.
    try fixture().expect(
        "SELECT V + (SELECT V FROM E WHERE Flag = 1) AS s FROM T",
        yields: [[nil], [nil], [nil]])
  }

  @Test func `an empty scalar subquery in a comparison admits no row`()
      throws {
    // `V = NULL` is UNKNOWN for every row, so the filter admits none.
    try fixture().empty(
        "SELECT Id FROM T WHERE V = (SELECT V FROM E WHERE Flag = 1)")
  }
}

// MARK: - Cardinality

struct ScalarSubqueryCardinalityTests {
  @Test func `a scalar subquery over more than one row faults`() throws {
    // `M` has two rows, so `(SELECT W FROM M)` yields two — a scalar subquery
    // admits at most one, so the run raises `SQLError.cardinality`.
    try fixture().expect(
        "SELECT (SELECT W FROM M) FROM T", fails: .cardinality)
  }

  @Test func `exactly one row collapses to its cell`() throws {
    // Filtered to one row, the same source yields a single value — no fault,
    // the lone cell (1) for every outer row.
    try fixture().expect(
        "SELECT Id, (SELECT W FROM M WHERE W = 1) AS w FROM T ORDER BY Id",
        yields: [[1, 1], [2, 1], [3, 1]])
  }

  @Test func `the cardinality error carries the SS SQLSTATE`() throws {
    // The cardinality violation is an engine-specific `SS`-class condition.
    #expect(SQLError.cardinality.sqlstate == "SS006")
  }
}

// MARK: - Width

struct ScalarSubqueryWidthTests {
  @Test func `a two-column scalar subquery faults at compile`() throws {
    // A scalar subquery must project EXACTLY ONE column; a two-column inner
    // query is `SQLError.arity`, checked cursor-free from the compiled width,
    // so it faults even though `M` has rows.
    try fixture().expect(
        "SELECT (SELECT W, Name FROM M) FROM T", fails: .arity(1, 2))
  }

  @Test func `a two-column scalar subquery faults the schema check`() throws {
    // The schema path enforces the SAME single-column arity as the run —
    // `columns(of:)` faults exactly where a run would.
    let query = try parse(query: "SELECT (SELECT W, Name FROM M) FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.arity(1, 2)) {
      try resolve()
    }
  }
}

// MARK: - Type checking

struct ScalarSubqueryTypeTests {
  @Test func `columns validates a scalar-subquery query`() throws {
    let query = try parse(query: "SELECT (SELECT MAX(V) FROM S) FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad inner column faults the schema check`() throws {
    // The inner query is type-checked, so an unknown column inside it faults
    // validation exactly as a run would reject it.
    let query = try parse(query: "SELECT (SELECT Missing FROM S) FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }

  @Test func `a bad inner relation faults the run`() throws {
    // A scalar subquery over a missing relation faults the run as a top-level
    // query over it would.
    try fixture().expect(
        "SELECT (SELECT V FROM Nope) FROM T", fails: .relation("Nope"))
  }

  @Test func `a scalar subquery select-list fault is validated`() throws {
    // A scalar subquery EVALUATES its select list (it collapses the cell), so
    // its ORIGINAL shape is type-checked — a `(SELECT 1 / 0 …)` faults
    // `.divide` at BOTH validate and run, unlike the EXISTS probe.
    let query = try parse(query: "SELECT (SELECT 1 / 0 FROM S) FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(
        "SELECT (SELECT 1 / 0 FROM S) FROM T", fails: .divide)
  }
}

// MARK: - Correlated resolution

struct ScalarSubqueryCorrelationTests {
  @Test func `a scalar subquery naming an outer column resolves`() throws {
    // A scalar subquery referencing an OUTER column (`T.V`, not in the inner
    // `S`'s scope) is a CORRELATED reference: it lowers to a synthetic bound
    // param bound from the outer row and the subquery re-runs per row. `T.V`
    // matches `S.V` for every row, so the scalar collapses to that value.
    let query = try parse(query:
        "SELECT (SELECT V FROM S WHERE V = T.V) FROM T")
    // `columns(of:)` VALIDATES the correlated query — resolving the correlated
    // column against the outer scope exactly as the run does — rather than
    // faulting `SQLError.column`.
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    try fixture().expect(
        "SELECT (SELECT V FROM S WHERE V = T.V) FROM T",
        yields: [[10], [20], [30]])
  }

  @Test func `a correlated column in the inner projection is unsupported`()
      throws {
    // The minimal (b) cut admits a correlated column ONLY in the inner
    // subquery's WHERE. One in the inner PROJECTION (`SELECT T.V …`) needs the
    // general outer-row evaluator, so it is DIAGNOSED unsupported at BOTH
    // `columns(of:)` and run rather than mis-resolved.
    let query = try parse(query: "SELECT (SELECT T.V FROM S) FROM T")
    #expect(throws: SQLError.self) {
      try fixture().columns(of: query, validate: true)
    }
    try fixture().expect(
        "SELECT (SELECT T.V FROM S) FROM T",
        fails: .state("0A000",
            "a correlated column is only supported in a subquery's WHERE"))
  }

  @Test func `a FROM-less correlated projection subquery is unsupported`()
      throws {
    // A FROM-less scalar subquery in the PROJECTION that names an outer column
    // (`SELECT (SELECT T.Id) FROM T`) is a correlated reference in a barred
    // clause position. The cut is intrinsic to the projection entry
    // (`Schema.terms` bars its seam), so this FROM-less projection CANNOT admit
    // the correlation — run and `columns(of:)` REJECT it with the SAME fault,
    // never lowering `T.Id` to a run-time `Term.parameter` that would (wrongly)
    // execute.
    let query = try parse(query: "SELECT (SELECT T.Id) FROM T")
    #expect(throws: SQLError.self) {
      try fixture().columns(of: query, validate: true)
    }
    try fixture().expect(
        "SELECT (SELECT T.Id) FROM T",
        fails: .state("0A000",
            "a correlated column is only supported in a subquery's WHERE"))
  }

  @Test func `a correlated WHERE subquery still admits and runs`() throws {
    // The parity case: a correlated column in the inner subquery's WHERE — an
    // ADMITTING clause position, unchanged by the projection barring — still
    // lowers `T.V` to a correlated `Term.parameter` and RUNS per outer row.
    // `(SELECT V FROM S WHERE V = T.V)` collapses to each row's own `V`, so
    // `= V` keeps every row.
    let query = try parse(query:
        "SELECT V FROM T WHERE (SELECT V FROM S WHERE V = T.V) = V")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    try fixture().expect(
        "SELECT V FROM T WHERE (SELECT V FROM S WHERE V = T.V) = V " +
        "ORDER BY V",
        yields: [[10], [20], [30]])
  }
}

// MARK: - Cross-role cache identity

/// Identical inner SQL used in more than one ROLE at once — scalar, `IN`, and
/// `EXISTS` — must materialise under DISTINCT cache entries, so a scalar read
/// never hits an `IN`/`EXISTS` entry and vice versa. The run-time cache keys on
/// `(scope, query, role)`; keying without the role collapsed the three onto one
/// entry, so an `IN` reading a scalar entry faulted (no rows) and an `EXISTS`
/// reading a scalar entry mis-read `present`.
struct ScalarSubqueryRoleTests {
  @Test func `the same SQL as a scalar and an IN filter each read their own`()
      throws {
    // The reviewer's case: `(SELECT W FROM M WHERE W = 1)` occurs BOTH as a
    // scalar projection AND as an `IN` value set — identical inner SQL. The
    // scalar yields its cell (1) for every row, and the `IN` filters `1 IN
    // {1}` to keep every row, each from its OWN entry — no cross-read.
    try fixture().expect(
        """
        SELECT (SELECT W FROM M WHERE W = 1) AS w FROM T \
        WHERE 1 IN (SELECT W FROM M WHERE W = 1) ORDER BY w
        """,
        yields: [[1], [1], [1]])
  }

  @Test func `the same SQL as a scalar and an EXISTS both see the row`()
      throws {
    // `(SELECT W FROM M WHERE W = 1)` occurs as a scalar AND an `EXISTS`. The
    // EXISTS sees `present == true` (the subquery has a row) from its OWN
    // existential entry, NOT the scalar entry, so every row is kept and the
    // scalar projects its cell (1).
    try fixture().expect(
        """
        SELECT (SELECT W FROM M WHERE W = 1) AS w FROM T \
        WHERE EXISTS (SELECT W FROM M WHERE W = 1) ORDER BY w
        """,
        yields: [[1], [1], [1]])
  }

  @Test func `an EXISTS over identical scalar SQL with no row keeps nothing`()
      throws {
    // The scalar occurrence over an empty filter is NULL, and the EXISTS over
    // the IDENTICAL empty SQL is FALSE (no row) — read from its own
    // existential entry, not the scalar's `present`. So the filter admits none.
    try fixture().empty(
        """
        SELECT (SELECT W FROM M WHERE W = 99) AS w FROM T \
        WHERE EXISTS (SELECT W FROM M WHERE W = 99)
        """)
  }

  @Test func `the same SQL as a scalar and an IN and an EXISTS all coexist`()
      throws {
    // All three roles over identical SQL at once: the scalar cell (1), the `IN`
    // membership (`1 IN {1}` true), and the `EXISTS` probe (has a row) each
    // read their OWN entry, so every row is kept and projects the cell.
    try fixture().expect(
        """
        SELECT (SELECT W FROM M WHERE W = 1) AS w FROM T \
        WHERE 1 IN (SELECT W FROM M WHERE W = 1) \
        AND EXISTS (SELECT W FROM M WHERE W = 1) ORDER BY w
        """,
        yields: [[1], [1], [1]])
  }

  @Test func `a reachable scalar faults even with an unreachable IN twin`()
      throws {
    // Identical inner SQL `(SELECT 1 / 0 FROM S)` occurs BOTH as a REACHABLE
    // scalar projection AND in an UNREACHABLE `IN` leg (`1 = 1 OR …`, whose OR
    // short-circuits past the `IN`). Now that an `IN` materialises LAZILY, the
    // valued twin no longer runs — and its eager arity/type derivation is TOTAL
    // (no `.divide`) — so it cannot stand in for the scalar's operand check. The
    // reachable scalar's own operand validation must still fault `.divide`. A
    // valued twin must NOT suppress the scalar's deferred recording.
    let query = try parse(query:
        """
        SELECT (SELECT 1 / 0 FROM S) FROM T \
        WHERE 1 = 1 OR 5 IN (SELECT 1 / 0 FROM S)
        """)
    #expect(throws: SQLError.divide) {
      try fixture().columns(of: query, validate: true)
    }
    try fixture().expect(
        """
        SELECT (SELECT 1 / 0 FROM S) FROM T \
        WHERE 1 = 1 OR 5 IN (SELECT 1 / 0 FROM S)
        """,
        fails: .divide)
  }

  @Test func `a valid scalar with an unreachable IN twin validates and runs`()
      throws {
    // The parity case: the SAME scalar-and-unreachable-IN shape with a VALID
    // body (`(SELECT W FROM M WHERE W = 1)`) validates AND runs — the scalar
    // cell (1) per row, the `IN` leg unreached (OR short-circuits). Proof the
    // fix defers-and-validates the reachable scalar without over-faulting.
    let query = try parse(query:
        """
        SELECT (SELECT W FROM M WHERE W = 1) AS w FROM T \
        WHERE 1 = 1 OR 5 IN (SELECT W FROM M WHERE W = 1) ORDER BY w
        """)
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    try fixture().expect(
        """
        SELECT (SELECT W FROM M WHERE W = 1) AS w FROM T \
        WHERE 1 = 1 OR 5 IN (SELECT W FROM M WHERE W = 1) ORDER BY w
        """,
        yields: [[1], [1], [1]])
  }

  @Test func `a multi-row subquery faults as a scalar but succeeds as an IN`()
      throws {
    // `(SELECT W FROM M)` yields TWO rows. As a scalar occurrence it faults
    // `SQLError.cardinality`; the identical SQL as an `IN` value set is valid.
    // The scalar entry faults the run — role-correct semantics on shared SQL.
    try fixture().expect(
        """
        SELECT (SELECT W FROM M) AS w FROM T \
        WHERE 1 IN (SELECT W FROM M)
        """,
        fails: .cardinality)
  }

  @Test func `a multi-row subquery as an IN alone keeps its matching rows`()
      throws {
    // The SAME multi-row `(SELECT W FROM M)` used ONLY as an `IN` (no scalar
    // occurrence) succeeds: `M` holds {1, 2}, so `1 IN (SELECT W FROM M)` is
    // true and every `T` row is kept — proof the `IN` role materialises full.
    try fixture().expect(
        "SELECT Id FROM T WHERE 1 IN (SELECT W FROM M) ORDER BY Id",
        yields: [[1], [2], [3]])
  }
}

// MARK: - Lazy short-circuit materialisation

/// A scalar subquery materialises LAZILY, on the first evaluation of its
/// `Term.subquery` — NOT eagerly before the plan runs — so an occurrence in an
/// unreachable `CASE`/`COALESCE` arm never executes, honouring the engine's
/// short-circuit and reachability semantics. A reached occurrence still runs
/// (and enforces cardinality / surfaces an inner fault), memoised so a value
/// over a single row is the SAME across every outer row.
struct ScalarSubqueryLazyTests {
  @Test func `a multi-row scalar in a skipped CASE arm never runs`() throws {
    // The reviewer's exact case: the `THEN` arm holds a multi-row scalar
    // subquery, but its guard `1 = 0` is FALSE, so the arm is never selected —
    // the scalar never runs, so no `.cardinality` fault. Every row yields the
    // `ELSE` 0.
    try fixture().expect(
        """
        SELECT CASE WHEN 1 = 0 THEN (SELECT W FROM M) ELSE 0 END AS c \
        FROM T ORDER BY c
        """,
        yields: [[0], [0], [0]])
  }

  @Test func `a multi-row scalar in a reached CASE arm still faults`() throws {
    // The mirror: with the guard `1 = 1` TRUE, the arm IS selected, so the
    // multi-row scalar DOES run and faults `.cardinality` — the reachable arm
    // enforces the ISO cardinality rule.
    try fixture().expect(
        "SELECT CASE WHEN 1 = 1 THEN (SELECT W FROM M) ELSE 0 END FROM T",
        fails: .cardinality)
  }

  @Test func `a multi-row scalar in a skipped COALESCE arm never runs`()
      throws {
    // `COALESCE` short-circuits at the first non-NULL argument: the first arm
    // `V` is never NULL, so the second arm's multi-row scalar subquery is never
    // reached — no `.cardinality` fault, every row yields its `V`.
    try fixture().expect(
        """
        SELECT COALESCE(V, (SELECT W FROM M)) AS c FROM T ORDER BY c
        """,
        yields: [[10], [20], [30]])
  }

  @Test func `a multi-row scalar in a reached COALESCE arm faults`() throws {
    // When the first `COALESCE` argument IS NULL, the second arm is reached, so
    // its multi-row scalar subquery runs and faults `.cardinality`. `E`
    // filtered to no rows is a NULL first argument for every outer row.
    try fixture().expect(
        """
        SELECT COALESCE((SELECT V FROM E WHERE Flag = 1), \
        (SELECT W FROM M)) FROM T
        """,
        fails: .cardinality)
  }

  @Test func `a divide-by-zero scalar in a skipped CASE arm never runs`()
      throws {
    // A throwing inner query (`1 / 0`) in an unreachable arm never evaluates,
    // so its `.divide` never fires — the same short-circuit the multi-row case
    // shows, over an arithmetic fault.
    try fixture().expect(
        """
        SELECT CASE WHEN 1 = 0 THEN (SELECT 1 / 0 FROM S) ELSE 0 END AS c \
        FROM T ORDER BY c
        """,
        yields: [[0], [0], [0]])
  }

  @Test func `a divide-by-zero scalar in a reached CASE arm faults`() throws {
    // The reachable arm runs the throwing inner query, so `.divide` fires — the
    // lazy path preserves the fault a reached scalar must surface.
    try fixture().expect(
        "SELECT CASE WHEN 1 = 1 THEN (SELECT 1 / 0 FROM S) ELSE 0 END FROM T",
        fails: .divide)
  }

  @Test func `a reached single-row scalar yields its value across all rows`()
      throws {
    // Materialise-once: a reached scalar over a SINGLE row collapses to its
    // cell (1) and is memoised, so it reads the SAME value for every outer row
    // — the guard `1 = 1` reaches it, and all three `T` rows project 1.
    try fixture().expect(
        """
        SELECT CASE WHEN 1 = 1 THEN (SELECT W FROM M WHERE W = 1) \
        ELSE 0 END AS w FROM T ORDER BY w
        """,
        yields: [[1], [1], [1]])
  }

  @Test func `a skipped scalar arm folds like its reachable literal`() throws {
    // The skipped-arm query yields exactly what the same CASE with the scalar
    // replaced by a never-run placeholder would — every row is the `ELSE` 0 —
    // so the lazy skip changes nothing but WHETHER the scalar executes.
    try fixture().expect(
        """
        SELECT CASE WHEN 1 = 0 THEN (SELECT W FROM M) ELSE 0 END FROM T
        """,
        equals: "SELECT 0 FROM T")
  }
}

// MARK: - Validation ↔ run parity

/// Validation (`columns(of:)`) must AGREE with execution on which scalar
/// subqueries it faults on: a scalar occurrence's inner-query OPERAND
/// validation is DEFERRED to the reachability walk, mirroring the lazy executor
/// — so an occurrence in an unreachable `CASE`/`COALESCE` arm is NOT validated
/// (it never runs), while a REACHED bad scalar still faults at validation (it
/// would fault at run). The cursor-free ARITY/TYPE derivation stays EAGER and
/// SEPARATE: a two-column scalar in a skipped arm still faults `.arity`.
struct ScalarSubqueryValidationParityTests {
  @Test func `a divide scalar in a skipped CASE arm validates and runs`()
      throws {
    // The reviewer's case: `columns(of:)` for a skipped THEN arm's throwing
    // scalar SUCCEEDS (no `.divide`) — the operand validation defers to the
    // reachability walk, which skips the unreachable arm — AND the query RUNS
    // successfully, so validation and execution AGREE.
    let query = try parse(query:
        "SELECT CASE WHEN 1 = 0 THEN (SELECT 1 / 0 FROM S) ELSE 0 END FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns.first?.type == .integer)
    try fixture().expect(
        """
        SELECT CASE WHEN 1 = 0 THEN (SELECT 1 / 0 FROM S) ELSE 0 END AS c \
        FROM T ORDER BY c
        """,
        yields: [[0], [0], [0]])
  }

  @Test func `a divide scalar in a reached CASE arm faults validation`()
      throws {
    // The mirror: with the guard `1 = 1` TRUE, the arm IS reached, so the walk
    // records the scalar and its inner query IS validated — `columns(of:)`
    // faults `.divide` exactly as the run does. Parity in the other direction:
    // validation still rejects what the executor faults on.
    let query = try parse(query:
        "SELECT CASE WHEN 1 = 1 THEN (SELECT 1 / 0 FROM S) ELSE 0 END FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(
        "SELECT CASE WHEN 1 = 1 THEN (SELECT 1 / 0 FROM S) ELSE 0 END FROM T",
        fails: .divide)
  }

  @Test func `a two-column scalar in a skipped arm still faults arity`()
      throws {
    // ARITY stays EAGER and reachability-INDEPENDENT — the cursor-free width
    // check is SEPARATE from the deferred operand validation — so a two-column
    // scalar subquery in an UNREACHABLE arm STILL faults `SQLError.arity`, even
    // though its inner-query operand validation would defer.
    let query = try parse(query:
        """
        SELECT CASE WHEN 1 = 0 THEN (SELECT W, Name FROM M) ELSE 0 END \
        FROM T
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.arity(1, 2)) {
      try resolve()
    }
  }

  @Test func `a bad inner column in a skipped arm faults both alike`() throws {
    // A bad inner COLUMN is a STRUCTURAL resolution fault the COMPILE path
    // raises for EVERY subquery — reachability-independent, unlike the operand
    // `.divide` above — so it fires at BOTH validate and run REGARDLESS of the
    // arm's reachability. The run itself faults `.column` (compile resolves the
    // scalar's inner columns to build the plan), so `columns(of:)` faulting
    // `.column` PRESERVES parity — validation rejects exactly what the executor
    // rejects. Only the OPERAND fault (`1 / 0`) the typecheck detects and the
    // lazy executor skips needed deferring; a bad column never did.
    let query = try parse(query:
        """
        SELECT CASE WHEN 1 = 0 THEN (SELECT Missing FROM S) ELSE 0 END \
        FROM T
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
    try fixture().expect(
        "SELECT CASE WHEN 1 = 0 THEN (SELECT Missing FROM S) ELSE 0 END FROM T",
        fails: .column("Missing"))
  }

  @Test func `a bad inner column in a reached arm faults validation`() throws {
    // A reached scalar with a bad inner column faults `SQLError.column` at
    // validation exactly as the run rejects it — parity in the reached
    // direction, the same structural fault the skipped case shows.
    let query = try parse(query:
        """
        SELECT CASE WHEN 1 = 1 THEN (SELECT Missing FROM S) ELSE 0 END \
        FROM T
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }

  @Test func `a divide scalar in a skipped COALESCE arm validates`() throws {
    // `COALESCE` short-circuits at the first non-NULL argument. A CONSTANT
    // non-NULL first argument makes the second arm STATICALLY unreachable — the
    // reachability the validation walk honours — so the throwing scalar's
    // operand validation defers and is never reached: `columns(of:)` SUCCEEDS
    // and the query RUNS. (A non-constant first argument like a column is NOT
    // statically known non-NULL, so validation would treat the second arm as
    // reachable — the walk mirrors only the STATIC short-circuit.)
    let query = try parse(query:
        "SELECT COALESCE(1, (SELECT 1 / 0 FROM S)) FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    try fixture().expect(
        "SELECT COALESCE(1, (SELECT 1 / 0 FROM S)) AS c FROM T ORDER BY c",
        yields: [[1], [1], [1]])
  }
}

// MARK: - IN/EXISTS validation ↔ run parity

/// An `IN (Q)`/`EXISTS` occurrence is materialised LAZILY at run — one in a
/// skipped `CASE`/`COALESCE` arm or a short-circuited `AND`/`OR` leg never
/// runs. Its inner-query OPERAND validation must therefore DEFER to the
/// reachability walk, exactly as a scalar's does: an occurrence in an
/// unreachable arm is NOT validated (matching the lazy run), while a REACHED
/// bad-bodied one still faults at both validate and run (parity both
/// directions). An `IN` validates its ORIGINAL shape (its value set is read),
/// an EXISTS-only occurrence the cardinality PROBE (its retained `WHERE` still
/// faults, its dropped select list does not).
struct SubqueryValidationParityTests {
  @Test func `an IN in a skipped CASE arm validates and runs`() throws {
    // The reviewer's case: the `1 IN (SELECT 1 / 0 …)` sits in the ELSE arm of
    // a CASE whose `1 = 1` guard is constant TRUE, so the arm is unreachable.
    // The operand validation defers to the walk, which skips the arm —
    // `columns(of:)` does NOT fault `.divide` — and the query RUNS, yielding
    // the reached `0` for every row. Validation and execution AGREE.
    let sql = """
        SELECT CASE WHEN 1 = 1 THEN 0 \
                    ELSE CASE WHEN 1 IN (SELECT 1 / 0 FROM S) THEN 1 END END \
             AS c FROM T ORDER BY c
        """
    let columns = try fixture().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try fixture().expect(sql, yields: [[0], [0], [0]])
  }

  @Test func `an EXISTS in a skipped CASE arm validates and runs`() throws {
    // The EXISTS mirror: `EXISTS (SELECT V FROM S WHERE 1 / 0 = 1)` — a
    // THROWING operand the cardinality PROBE RETAINS (it keeps the `WHERE`) —
    // sits in the skipped ELSE arm. Its operand validation defers, so
    // `columns(of:)` does NOT fault and the query RUNS the reached `0`.
    let sql = """
        SELECT CASE WHEN 1 = 1 THEN 0 \
                    ELSE CASE WHEN EXISTS (SELECT V FROM S WHERE 1 / 0 = 1) \
                              THEN 1 END END \
             AS c FROM T ORDER BY c
        """
    let columns = try fixture().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try fixture().expect(sql, yields: [[0], [0], [0]])
  }

  @Test func `a reached bad IN faults both validate and run`() throws {
    // Parity the other way: with the guard TRUE the arm IS reached, so the walk
    // records the `IN` and its ORIGINAL shape IS validated — `columns(of:)`
    // faults `.divide` exactly as the run does.
    let sql = """
        SELECT CASE WHEN 1 = 1 \
                    THEN CASE WHEN 1 IN (SELECT 1 / 0 FROM S) THEN 1 \
                              ELSE 0 END \
                    ELSE 0 END FROM T
        """
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: parse(query: sql), validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(sql, fails: .divide)
  }

  @Test func `a reached bad EXISTS faults both validate and run`() throws {
    // The EXISTS mirror in the reached direction: the retained `WHERE`'s
    // `1 / 0` faults `.divide` at BOTH validate and run once the arm reached.
    let sql = """
        SELECT CASE WHEN 1 = 1 \
                    THEN CASE WHEN EXISTS (SELECT V FROM S WHERE 1 / 0 = 1) \
                              THEN 1 ELSE 0 END \
                    ELSE 0 END FROM T
        """
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: parse(query: sql), validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(sql, fails: .divide)
  }

  @Test func `a reached IN in the WHERE still faults`() throws {
    // The plain WHERE case is not short-circuited past, so a bad-bodied `IN`
    // there is REACHED and faults `.divide` at both validate and run — the lazy
    // deferral does not weaken the always-reached position.
    let sql = "SELECT Id FROM T WHERE 1 IN (SELECT 1 / 0 FROM S)"
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: parse(query: sql), validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(sql, fails: .divide)
  }
}

// MARK: - Join-ON correlation prefix scope

/// A `JOIN … ON` subquery correlates against the join PREFIX scope — the
/// relations available AT that join point — not the full join, which includes
/// relations joined LATER. A correlated reference in an EARLY `ON` to a
/// LATER-joined relation faults `SQLError.column` exactly as a DIRECT reference
/// in that `ON` would, rather than mis-binding a slot not present when the
/// early join's `ON` evaluates.
private func joins() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["a": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("B", ["b": .integer]) {
      Row(1)
    }
    Relation("C", ["Ck": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("X", ["k": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

struct JoinOnCorrelationPrefixTests {
  @Test func `an early ON correlating to a later join faults at run`() throws {
    // `A JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = C.Ck) JOIN C …` names
    // `C` in the A×B join's `ON`, but `C` joins LATER, so it is out of that
    // join's prefix scope. The correlated reference faults `SQLError.column`
    // (spelled by its bare name, as a direct `C.Ck` there would) rather than
    // reading a slot not present when the A×B `ON` evaluates.
    try joins().expect(
        """
        SELECT A.a FROM A \
        JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = C.Ck) \
        JOIN C ON C.Ck = A.a
        """,
        fails: .column("Ck"))
  }

  @Test func `an early ON correlating to a later join faults the check`()
      throws {
    // The schema path enforces the SAME prefix scope — `columns(of:)` faults
    // `SQLError.column` exactly where the run does, keeping typecheck↔run
    // parity.
    let query = try parse(query:
        """
        SELECT A.a FROM A \
        JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = C.Ck) \
        JOIN C ON C.Ck = A.a
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try joins().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Ck")) {
      try resolve()
    }
  }

  @Test func `an ON correlating to a PREFIX relation still works`() throws {
    // A correlation to a relation IN the prefix (`A`, the FROM relation) is
    // valid: `ON EXISTS (SELECT 1 FROM X WHERE X.k = A.a)` binds `A.a` from the
    // A×B row and probes `X`. `X` holds {1, 2}, so the `EXISTS` is true for
    // every `A` row (a=1, a=2), and the later `C` join matches `C.Ck = A.a`,
    // yielding both `A` rows.
    try joins().expect(
        """
        SELECT A.a FROM A \
        JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = A.a) \
        JOIN C ON C.Ck = A.a ORDER BY A.a
        """,
        yields: [[1], [2]])
  }
}

// MARK: - Reached-role validation shape

/// The deferred type-check picks each reached occurrence's validation SHAPE
/// from the ROLE it reached in PER OCCURRENCE — an `existential` reach
/// validates the EXISTS cardinality PROBE (no projection), a `scalar`/`valued`
/// reach the original — NOT from the union of every role the query occupies in
/// the select. So the SAME inner SQL reached ONLY as an `EXISTS` validates the
/// probe even where an UNREACHED `CASE`/`COALESCE` arm has it as a scalar; the
/// union would mis-mark it "evaluated" and validate the original projection,
/// faulting `.divide` on a `1 / 0` the run never evaluates.
struct SubqueryReachedRoleShapeTests {
  @Test func `an EXISTS reach validates the probe past an unreached scalar`()
      throws {
    // `EXISTS (SELECT 1 / 0 FROM S)` is REACHED (the WHERE runs it), so its
    // cardinality PROBE — a constant projection dropping the `1 / 0` — is
    // validated: no `.divide`. The IDENTICAL inner `(SELECT 1 / 0 FROM S)` also
    // occurs as a SCALAR in the ELSE arm of a `1 = 0` CASE, which is UNREACHED,
    // so its original projection is NOT validated. A global role union would
    // have marked the query "evaluated" (scalar) and faulted `.divide`.
    let sql = """
        SELECT Id FROM T \
        WHERE EXISTS (SELECT 1 / 0 FROM S) \
          AND (CASE WHEN 1 = 0 THEN (SELECT 1 / 0 FROM S) ELSE 0 END) = 0 \
        ORDER BY Id
        """
    let columns = try fixture().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try fixture().expect(sql, yields: [[1], [2], [3]])
  }

  @Test func `a reached scalar with a bad projection still faults`() throws {
    // Parity the other way: with the CASE guard `1 = 1` the scalar arm IS
    // reached, so the SCALAR role's ORIGINAL projection is validated — its
    // `1 / 0` faults `.divide` at both validate and run, unchanged by the
    // EXISTS occurrence sharing the identical inner SQL.
    let sql = """
        SELECT Id FROM T \
        WHERE EXISTS (SELECT 1 / 0 FROM S) \
          AND (CASE WHEN 1 = 1 THEN (SELECT 1 / 0 FROM S) ELSE 0 END) = 0
        """
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: parse(query: sql), validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(sql, fails: .divide)
  }
}

// MARK: - Join-ON short-circuit validation parity

/// A join `ON` predicate short-circuits its `AND`/`OR` at RUN — the join
/// evaluator steps the lowered conjunction and never materialises a subquery a
/// FALSE left conjunct settles past. So an `ON` subquery runs through the SAME
/// reachability/short-circuit walk the WHERE/HAVING do, PREFIX-scoped: one in a
/// short-circuited leg is NOT eager-validated (matching the lazy run), while a
/// REACHED `ON` subquery IS validated (parity both directions). The prefix
/// scope is intact — a correlated `ON` column to a later-joined relation still
/// faults.
struct JoinOnShortCircuitValidationTests {
  @Test func `a short-circuited ON subquery is not validated and runs`()
      throws {
    // `ON 1 = 0 AND 1 IN (SELECT 1 / 0 FROM S)` short-circuits on the constant
    // FALSE left, so the join never materialises the `1 IN (…)` — the walk
    // skips it, `columns(of:)` does NOT fault `.divide`, and the join RUNS. The
    // FALSE `ON` matches no A×S pair, so the query yields no rows.
    let sql = """
        SELECT A.a FROM A \
        JOIN B ON 1 = 0 AND 1 IN (SELECT 1 / 0 FROM S)
        """
    let columns = try mixed().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try mixed().expect(sql, yields: [])
  }

  @Test func `a reached ON subquery with a bad body still faults`() throws {
    // Parity: with the left conjunct `1 = 1` the `IN` IS reached, so its
    // ORIGINAL is validated — its `1 / 0` faults `.divide` at both validate and
    // run, exactly as an always-reached WHERE occurrence does.
    let sql = """
        SELECT A.a FROM A \
        JOIN B ON 1 = 1 AND 1 IN (SELECT 1 / 0 FROM S)
        """
    let resolve = { () throws -> Array<OutputColumn> in
      try mixed().columns(of: parse(query: sql), validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try mixed().expect(sql, fails: .divide)
  }

  @Test func `a reached EXISTS in the ON validates its probe and runs`()
      throws {
    // A REACHED `ON` EXISTS whose retained body is CLEAN validates and runs:
    // its cardinality probe drops the select list, and `X` holds {1, 2}, so the
    // EXISTS is TRUE for every A×B pair — the join yields the A rows.
    let sql = """
        SELECT A.a FROM A \
        JOIN B ON 1 = 1 AND EXISTS (SELECT 1 / 0 FROM X) ORDER BY A.a
        """
    let columns = try mixed().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try mixed().expect(sql, yields: [[1], [2]])
  }

  @Test func `an early ON correlating to a later join still faults`() throws {
    // Prefix-scoping is intact under the short-circuit walk: `ON 1 = 1 AND
    // EXISTS (SELECT 1 FROM X WHERE X.k = C.Ck)` names `C` in the A×B `ON`, but
    // `C` joins LATER, out of that join's prefix — so the correlated reference
    // faults `SQLError.column` at both validate and run, per batch-1/4.
    let sql = """
        SELECT A.a FROM A \
        JOIN B ON 1 = 1 AND EXISTS (SELECT 1 FROM X WHERE X.k = C.Ck) \
        JOIN C ON C.Ck = A.a
        """
    let resolve = { () throws -> Array<OutputColumn> in
      try joins().columns(of: parse(query: sql), validate: true)
    }
    #expect(throws: SQLError.column("Ck")) {
      try resolve()
    }
    try joins().expect(sql, fails: .column("Ck"))
  }
}

/// A join fixture reused by the `ON` short-circuit tests — `A`×`B` supplies the
/// join pairs, `S` the throwing inner source, `X` a clean one.
private func mixed() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["a": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("B", ["b": .integer]) {
      Row(1)
    }
    Relation("S", ["V": .integer]) {
      Row(10)
    }
    Relation("X", ["k": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

// MARK: - Correlated plan cache occurrence identity

/// The correlated per-outer-row PLAN cache keys on the full occurrence `Subkey`
/// (scope + query + role), not just the inner `Query`. Two occurrences of the
/// IDENTICAL inner SQL — one under a `.caller` scope and one under a
/// `.view(name)` body, whose correlated column resolves to a DIFFERENT ordinal
/// — each compile and execute their OWN plan; keying by the query alone made a
/// later occurrence reuse the first's plan (its synthetic-parameter names and
/// resolved layout), reading the wrong outer cell.
private func occurrences() throws -> FixtureCatalog {
  try Catalog {
    Relation("Src", ["m": .integer]) {
      Row(10)
      Row(20)
      Row(30)
    }
    // The caller's outer relation — its correlated column `k` at ordinal 0.
    Relation("Outer1", ["k": .integer]) {
      Row(10)
      Row(20)
    }
    // The view's outer relation — a leading `pad` puts its correlated column
    // `k` at ordinal 1, a DIFFERENT ordinal from `Outer1.k`.
    Relation("Outer2", ["pad": .integer, "k": .integer]) {
      Row(0, 20)
      Row(0, 30)
    }
    // A view whose body holds the SAME correlated inner SQL the caller uses,
    // over `Outer2` (correlated `k` at ordinal 1) — the `.view` occurrence.
    try View("VW", "SELECT (SELECT m FROM Src WHERE m = k) AS mm FROM Outer2",
             as: ["mm"])
  }
}

struct CorrelatedPlanCacheIdentityTests {
  @Test func `identical correlated SQL under a caller and a view each hold`()
      throws {
    // `(SELECT m FROM Src WHERE m = k)` appears BOTH in the caller (over
    // `Outer1`, `k` at ordinal 0) and in view `VW`'s body (over `Outer2`, `k`
    // at ordinal 1) — identical inner SQL, DISTINCT scope AND ordinal. Each
    // occurrence runs its OWN plan: the caller yields `Outer1.k` ∈ {10, 20}
    // matched against `Src` → {10, 20}; the view yields `Outer2.k` ∈ {20, 30}
    // → {20, 30}. A query-only cache key would reuse the first plan (wrong
    // ordinal/parameter), so the two arms would not both resolve correctly.
    try occurrences().expect(
        """
        SELECT (SELECT m FROM Src WHERE m = k) AS c FROM Outer1 \
        UNION ALL \
        SELECT mm FROM VW ORDER BY 1
        """,
        yields: [[10], [20], [20], [30]])
  }
}

// MARK: - Nested correlation bubble-up

/// A correlation discovered while compiling a subquery NESTED inside another
/// subquery must BUBBLE UP to mark the CONTAINING subquery correlated. An INNER
/// `EXISTS` naming a column of a scope TWO levels up (`T.id`, above the middle
/// `U` query) makes the MIDDLE `EXISTS` correlated to `T` too, so it re-executes
/// per `T` row and threads the binding down — rather than being treated as
/// uncorrelated and re-run without the `T` scope.
private func nested() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    // A single-row source so the MIDDLE `EXISTS` over `U` is non-empty exactly
    // when its own nested `EXISTS` over `V` is — isolating the bubble-up.
    Relation("U", ["u": .integer]) {
      Row(0)
    }
    // The innermost source — its `x` matches only `T` rows 2 and 3.
    Relation("V", ["x": .integer]) {
      Row(2)
      Row(3)
    }
  }
}

struct NestedCorrelationBubbleUpTests {
  @Test func `a two-level nested correlation resolves and runs per T row`()
      throws {
    // The INNER `EXISTS (SELECT 1 FROM V WHERE V.x = T.id)` correlates to `T.id`
    // — two levels up, above the middle `U` query. The correlation bubbles up so
    // the MIDDLE `EXISTS` is correlated to `T` and re-runs per `T` row. `V.x` ∈
    // {2, 3}, so only `T` rows 2 and 3 satisfy the inner `EXISTS`; `U` has a
    // row, so the middle `EXISTS` mirrors the inner. Result: rows 2 and 3.
    try nested().expect(
        """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM U \
                      WHERE EXISTS (SELECT 1 FROM V WHERE V.x = T.id)) \
        ORDER BY id
        """,
        yields: [[2], [3]])
  }

  @Test func `a two-level nested correlation validates`() throws {
    // The schema path resolves the bubbled-up correlation the SAME as the run —
    // `columns(of:)` validates the two-level correlated query rather than
    // faulting `SQLError.column` on the enclosing `T.id`.
    let query = try parse(query:
        """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM U \
                      WHERE EXISTS (SELECT 1 FROM V WHERE V.x = T.id))
        """)
    let columns = try nested().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }
}

// MARK: - Correlated scope-depth disambiguation

/// A three-level nest whose INNERMOST subquery correlates to TWO enclosing
/// scopes at once — its immediate parent `U` and its grandparent `T` — where
/// the referenced columns share the SAME combined ordinal (both 0, each its
/// scope's sole column). Keying the synthetic parameter on the ordinal ALONE
/// collides the two onto one binding, so both terms would read the same cell
/// and the inner filter returns the wrong rows; keying on scope DEPTH + ordinal
/// keeps them distinct.
private func scoped() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    // One row, so the MIDDLE `EXISTS` over `U` is non-empty exactly when its
    // nested `EXISTS` over `V` is — its sole column `u` is 5, the value `V.y`
    // must match.
    Relation("U", ["u": .integer]) {
      Row(5)
    }
    // `V.x` matches `T.id` in {2, 3}, but only `(2, 5)` also has `V.y = U.u`
    // (5): so only `T` row 2 satisfies BOTH correlated terms. A collided
    // binding (both terms reading one cell) would drop row 2 too, yielding [].
    Relation("V", ["x": .integer, "y": .integer]) {
      Row(2, 5)
      Row(3, 9)
    }
  }
}

struct CorrelatedScopeDepthTests {
  @Test func `two same-ordinal correlations from different scopes run right`()
      throws {
    // `V.x = T.id` correlates to the GRANDPARENT `T` (ordinal 0), `V.y = U.u`
    // to the PARENT `U` (also ordinal 0). Depth-keyed synthetic params keep
    // them distinct, so each term reads its OWN binding: only `T` row 2 matches
    // (`V.x = 2 = id` AND `V.y = 5 = u`). An ordinal-only key would collide the
    // two onto `:__correlated_0`, one overwriting the other, yielding [].
    try scoped().expect(
        """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM U \
                      WHERE EXISTS (SELECT 1 FROM V \
                                    WHERE V.x = T.id AND V.y = U.u)) \
        ORDER BY id
        """,
        yields: [[2]])
  }

  @Test func `two same-ordinal correlations from different scopes validate`()
      throws {
    // The schema path resolves BOTH correlations the same as the run — no
    // `SQLError.column` on either enclosing reference.
    let query = try parse(query:
        """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM U \
                      WHERE EXISTS (SELECT 1 FROM V \
                                    WHERE V.x = T.id AND V.y = U.u))
        """)
    let columns = try scoped().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }
}

// MARK: - Correlated lookup ambiguity shadowing

/// An `Outer` scope resolves a correlated column NEAREST enclosing scope first
/// (lexical scoping). The three outcomes of a per-scope probe must stay DISTINCT
/// — found binds, not-found keeps walking outward, and AMBIGUOUS (the name in
/// more than one relation of a scope) SHADOWS the farther scopes by faulting
/// `SQLError.ambiguous`, never falling through to rebind the name to a farther
/// relation. A `try?` that collapsed ambiguous onto not-found silently rebound
/// a nearer-ambiguous name to an outer column.
private func relation(_ name: String, _ columns: Array<String>)
    -> (SQLEngine.Relation, Schema) {
  (SQLEngine.Relation(name: name),
   Schema(width: columns.count, extent: columns.count, names: columns,
          types: columns.map { _ in .integer }, virtuals: []))
}

struct CorrelatedAmbiguityShadowTests {
  @Test func `a nearer ambiguous scope shadows a farther one`() throws {
    // Outer `T(id)`; middle `U(id, u) JOIN V(id, v)` both expose `id`. A bare
    // `id` correlating outward binds at the NEAREST enclosing scope — the middle
    // — where it is AMBIGUOUS, so the lookup faults `SQLError.ambiguous` rather
    // than walking past to rebind it to the farther `T.id`.
    let outer = Outer([Scope([relation("T", ["id"])])])
        .nested(under: Scope([relation("U", ["id", "u"]),
                              relation("V", ["id", "v"])]))
    #expect(throws: SQLError.ambiguous("id")) {
      _ = try outer.parameter(for: "id")
    }
    // The schema-derive probe shadows identically, so validate and run AGREE.
    #expect(throws: SQLError.ambiguous("id")) {
      _ = try outer.type(for: "id")
    }
  }

  @Test func `an unambiguous nearer name still correlates`() throws {
    // `u` is bound by ONLY `U` of the middle scope — unambiguous — so it
    // correlates to the middle (a non-nil parameter, its outer type). Proof the
    // shadowing faults ONLY on ambiguity, never a clean nearer match.
    let outer = Outer([Scope([relation("T", ["id"])])])
        .nested(under: Scope([relation("U", ["id", "u"]),
                              relation("V", ["id", "v"])]))
    #expect(try outer.parameter(for: "u") != nil)
    #expect(try outer.type(for: "u") == .integer)
  }

  @Test func `a name absent from the nearer scope resolves outward`() throws {
    // `key` is absent from the middle `U JOIN V` but present in outer `T` — a
    // NOT-FOUND at the nearer scope keeps the walk moving outward, so it still
    // resolves to `T`. Only AMBIGUITY stops the walk; absence does not.
    let outer = Outer([Scope([relation("T", ["key"])])])
        .nested(under: Scope([relation("U", ["u"]),
                              relation("V", ["v"])]))
    #expect(try outer.parameter(for: "key") != nil)
    #expect(try outer.type(for: "key") == .integer)
  }
}

// MARK: - Correlated EXISTS cardinality probe

/// An outer `T` keyed by `k` and an inner `U` keyed by `k`, so a correlated
/// EXISTS matches an outer row against the inner source per row — the shape
/// exercising the per-outer-row cardinality PROBE (the correlated EXISTS must
/// test non-emptiness WITHOUT evaluating the inner select list, exactly as the
/// uncorrelated EXISTS probe does).
private func existence() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["id": .integer, "k": .integer]) {
      Row(1, 1)
      Row(2, 2)
      Row(3, 3)
    }
    Relation("U", ["k": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

struct CorrelatedExistsProbeTests {
  @Test func `a correlated EXISTS probes without evaluating a divide`()
      throws {
    // `EXISTS (SELECT 1 / 0 FROM U WHERE U.k = T.k)` is correlated to `T.k`, so
    // it re-runs per outer row — but through the cardinality PROBE, whose
    // constant projection never evaluates the `1 / 0` select list. `U.k` ∈ {1,
    // 2} matches `T` rows 1 and 2 (EXISTS TRUE, no `.divide`); row 3 matches
    // none (FALSE). The FULL plan would have evaluated `1 / 0` and faulted.
    let sql = """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 / 0 FROM U WHERE U.k = T.k) ORDER BY id
        """
    let columns = try existence().columns(of: parse(query: sql),
                                                 validate: true)
    #expect(columns.count == 1)
    try existence().expect(sql, yields: [[1], [2]])
  }

  @Test func `a correlated EXISTS with a normal projection still works`()
      throws {
    // The same correlation with an ORDINARY select list runs identically — the
    // probe keeps the FROM/`WHERE`, so the row source and its correlation still
    // decide existence: rows 1 and 2 match, row 3 does not.
    let sql = """
        SELECT id FROM T \
        WHERE EXISTS (SELECT k FROM U WHERE U.k = T.k) ORDER BY id
        """
    try existence().expect(sql, yields: [[1], [2]])
  }
}

// MARK: - Local ambiguity is a hard error, not outer correlation

/// A correlated `.column` lowering resolves against its OWN relations FIRST,
/// falling through to outer correlation only when the name binds NONE of them.
/// A name bound by MORE than one local relation is LOCALLY AMBIGUOUS — a hard
/// `SQLError.ambiguous`, NOT a fall-through: swallowing it into outer
/// correlation would silently rebind an ambiguous inner name to an enclosing
/// column of the same spelling (the wrong row value). A genuinely-not-found
/// local name still correlates to the outer.
private func ambiguity() throws -> FixtureCatalog {
  try Catalog {
    // The outer relation exposes `id` AND `label`, either a candidate for an
    // inner name to (wrongly) correlate to.
    Relation("T", ["id": .integer, "label": .integer]) {
      Row(1, 100)
      Row(2, 200)
    }
    // The inner join's two relations BOTH expose `id`, so a bare `id` in the
    // inner `WHERE` is LOCALLY ambiguous.
    Relation("U", ["id": .integer, "u": .integer]) {
      Row(1, 5)
    }
    Relation("V", ["id": .integer, "v": .integer]) {
      Row(1, 5)
    }
  }
}

struct CorrelatedLocalAmbiguityTests {
  @Test func `a locally ambiguous inner name faults at run`() throws {
    // `EXISTS (SELECT 1 FROM U JOIN V ON U.u = V.v WHERE id = 1)`: `id` binds
    // BOTH `U.id` and `V.id`, so it is a LOCAL ambiguity — a hard
    // `SQLError.ambiguous("id")`, NOT a silent rebind to the outer `T.id`.
    let sql = """
        SELECT T.label FROM T \
        WHERE EXISTS (SELECT 1 FROM U JOIN V ON U.u = V.v WHERE id = 1)
        """
    try ambiguity().expect(sql, fails: .ambiguous("id"))
  }

  @Test func `a locally ambiguous inner name faults the check`() throws {
    // The schema path faults the SAME `SQLError.ambiguous("id")`, keeping
    // typecheck↔run parity — not swallowing the ambiguity into a correlation.
    let sql = """
        SELECT T.label FROM T \
        WHERE EXISTS (SELECT 1 FROM U JOIN V ON U.u = V.v WHERE id = 1)
        """
    let query = try parse(query: sql)
    let resolve = { () throws -> Array<OutputColumn> in
      try ambiguity().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.ambiguous("id")) { try resolve() }
  }

  @Test func `a not-found inner name still correlates`() throws {
    // `label` binds NONE of the inner relations (`U`, `V`), so it is a genuine
    // correlated reference to the outer `T.label` — bound per outer row. `U`
    // holds a row, so the `EXISTS` is TRUE for the `T` row whose `label` is 100
    // (row 1) and FALSE for row 2 (`label` 200).
    let sql = """
        SELECT T.id FROM T \
        WHERE EXISTS (SELECT 1 FROM U JOIN V ON U.u = V.v WHERE label = 100) \
        ORDER BY T.id
        """
    try ambiguity().expect(sql, yields: [[1]])
  }
}

// MARK: - Correlated parameters are nullable for pushdown

/// A correlated column lowers to a `Term.parameter` whose per-outer-row value
/// can be NULL, so a SLOTLESS comparison over it (`outer = 1`) can be UNKNOWN.
/// Selection pushdown must treat such a conjunct as NULLABLE — the same
/// treatment a `Filter.bound` parameter gets — so it never rides AHEAD of a
/// LATER unsafe conjunct the non-short-circuiting inner `AND` still owes. Moving
/// it ahead would drop the UNKNOWN row before the unsafe conjunct (a `1 / 0`)
/// runs, suppressing a throw the `AND` order owes.
private func pushdown() throws -> FixtureCatalog {
  try Catalog {
    // A single outer row whose correlated key is NULL, so `T.k = 1` is UNKNOWN.
    Relation("T", ["k": .integer]) {
      Row(nil)
    }
    Relation("P", ["j": .integer]) {
      Row(1)
    }
    // A single `Q` row whose `y` is zero, so `(1 / Q.y) = 0` FAULTS `.divide`
    // when reached.
    Relation("Q", ["j": .integer, "y": .integer]) {
      Row(1, 0)
    }
  }
}

struct CorrelatedPushdownNullableTests {
  @Test func `a correlated slotless conjunct does not ride ahead of a divide`()
      throws {
    // `EXISTS (SELECT 1 FROM P JOIN Q ON P.j = Q.j WHERE T.k = 1 AND
    // (1 / Q.y) = 0)`: `T.k` is NULL, so `T.k = 1` is UNKNOWN, and the inner
    // `AND` (which does NOT short-circuit an UNKNOWN left) reaches `(1 / Q.y)
    // = 0` on the matching P×Q pair — a `.divide`. Treating the correlated
    // `T.k = 1` as non-nullable would let pushdown descend it below the join,
    // dropping the pair BEFORE the divide and hiding the fault; treating it
    // nullable (like a `.bound`) keeps it ahead of the unsafe conjunct, so the
    // divide runs and faults.
    let sql = """
        SELECT k FROM T \
        WHERE EXISTS (SELECT 1 FROM P JOIN Q ON P.j = Q.j \
        WHERE T.k = 1 AND (1 / Q.y) = 0)
        """
    try pushdown().expect(sql, fails: .divide)
  }
}

// MARK: - A qualifier-shadowing local alias is a hard error, not correlation

/// A QUALIFIED correlated reference resolves against its OWN relations first: a
/// qualifier a LOCAL relation answers (its alias, else its table name) that
/// names a column the relation LACKS is a hard `SQLError.column` — the local
/// alias SHADOWS a same-qualifier ENCLOSING relation, so the miss faults
/// against the inner relation rather than falling through to bind the outer
/// one. Only a qualifier NO local relation answers (a genuine correlated
/// reference) walks outward. Two shapes exercise this: a SINGLE-relation inner
/// subquery whose alias matches an outer alias (Item 1), and a JOINED inner
/// scope whose local alias matches an outer alias (Item 2).
private func shadowing() throws -> FixtureCatalog {
  try Catalog {
    // The outer relation `T` aliased `x(v)`, a same-qualifier candidate an
    // inner `x.v` would (wrongly) correlate to.
    Relation("T", ["v": .integer]) {
      Row(1)
    }
    // The inner source `S` — aliased `x` inside the subquery — carries NO
    // column `v`, so `x.v` against it is a QUALIFIED MISS on the local alias.
    Relation("S", ["w": .integer]) {
      Row(1)
    }
    // A second inner relation to join `S` with, for the joined-scope shape.
    Relation("R", ["w": .integer]) {
      Row(1)
    }
  }
}

struct CorrelatedQualifierShadowTests {
  @Test func `a single-relation qualifier shadow faults, not correlates`()
      throws {
    // Item 1. Under outer `T AS x(v)`, the subquery `(SELECT 1 FROM S AS x
    // WHERE x.v = 1)` names `x.v` — the local alias `x` (the inner `S AS x`)
    // answers the qualifier but LACKS `v`, a hard `.column`. It must NOT fall
    // through to read the outer `T AS x`'s `v`. Pre-fix the `try?` swallowed
    // the miss and correlated to the outer `x.v`, silently succeeding.
    let sql = """
        SELECT v FROM T AS x \
        WHERE EXISTS (SELECT 1 FROM S AS x WHERE x.v = 1)
        """
    try shadowing().expect(sql, fails: .column("v"))
  }

  @Test func `a single-relation qualifier shadow faults the check`() throws {
    // The schema path faults the SAME `SQLError.column("v")`, keeping
    // typecheck↔run parity — the derive probe shadows the outer alias too.
    let sql = """
        SELECT v FROM T AS x \
        WHERE EXISTS (SELECT 1 FROM S AS x WHERE x.v = 1)
        """
    let query = try parse(query: sql)
    #expect(throws: SQLError.column("v")) {
      try shadowing().columns(of: query, validate: true)
    }
  }

  @Test func `a joined qualifier shadow faults, not correlates`() throws {
    // Item 2. Under outer `T AS x(v)`, the JOINED inner scope `S AS x JOIN R
    // ON x.w = R.w` binds a local alias `x` (the inner `S`). An inner `x.v`
    // names the local `x`, which LACKS `v` — a hard `.column` shadowing the
    // outer `x`. Pre-fix the blanket `.column`→`nil` in `find` let the lookup
    // walk outward and rebind `x.v` to the OUTER row.
    let sql = """
        SELECT v FROM T AS x \
        WHERE EXISTS (SELECT 1 FROM S AS x JOIN R ON x.w = R.w \
        WHERE x.v = 1)
        """
    try shadowing().expect(sql, fails: .column("v"))
  }

  @Test func `a joined qualifier shadow faults the check`() throws {
    // The schema path faults the SAME `SQLError.column("v")` for the joined
    // shape — `Scope.find` propagates the qualified miss rather than swallowing
    // it — so validation and run AGREE.
    let sql = """
        SELECT v FROM T AS x \
        WHERE EXISTS (SELECT 1 FROM S AS x JOIN R ON x.w = R.w \
        WHERE x.v = 1)
        """
    let query = try parse(query: sql)
    #expect(throws: SQLError.column("v")) {
      try shadowing().columns(of: query, validate: true)
    }
  }

  @Test func `a qualifier no local relation answers still correlates`()
      throws {
    // PARITY. A genuinely-correlated qualified reference — the qualifier `T` is
    // NOT a local alias of the inner `S AS s` — still correlates to the outer
    // `T` and works: `T.v` binds the outer row (1), so `s.w = T.v` matches the
    // lone `S` row and the EXISTS is TRUE, projecting the outer `v`.
    let sql = """
        SELECT v FROM T \
        WHERE EXISTS (SELECT 1 FROM S AS s WHERE s.w = T.v) \
        ORDER BY v
        """
    try shadowing().expect(sql, yields: [[1]])
  }
}

// MARK: - Per-occurrence prefix/correlation resolution

/// The join-prefix correlation plan is keyed PER OCCURRENCE, not by inner SQL
/// text. The SAME `EXISTS (SELECT … WHERE X.k = x)` in an early `JOIN … ON`
/// (whose PREFIX exposes `x` in only ONE relation) and in the `WHERE` (whose
/// FULL scope exposes `x` in TWO relations) resolves EACH against ITS site's
/// scope: the `ON` occurrence binds the prefix's lone `x`, while the `WHERE`
/// occurrence resolves against the full scope and REJECTS the now-ambiguous `x`
/// — not reusing the first occurrence's narrower prefix binding.
private func occurrence() throws -> FixtureCatalog {
  try Catalog {
    // The FROM relation, the only `x` in the FIRST join's prefix.
    Relation("A", ["x": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("B", ["b": .integer]) {
      Row(1)
    }
    // A later-joined relation that ALSO exposes `x`, making a bare `x`
    // ambiguous in the full `WHERE` scope.
    Relation("C", ["x": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("X", ["k": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

struct CorrelatedOccurrenceScopeTests {
  @Test func `an ON occurrence binds its prefix scope`() throws {
    // In the FIRST join's `ON`, the prefix is `{A, B}` — only `A` exposes `x`,
    // so `EXISTS (SELECT 1 FROM X WHERE X.k = x)` binds `A.x` unambiguously.
    // `X` holds {1, 2}, so the `EXISTS` is TRUE for every `A` row.
    let sql = """
        SELECT A.x FROM A \
        JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = x) ORDER BY A.x
        """
    try occurrence().expect(sql, yields: [[1], [2]])
  }

  @Test func `a WHERE occurrence resolves against the full scope`() throws {
    // The IDENTICAL `EXISTS (SELECT 1 FROM X WHERE X.k = x)` also appears in the
    // `WHERE`, AFTER `C` (which also exposes `x`) has joined. Its correlated `x`
    // is out of `X`'s own relation and correlates against the FULL `{A, B, C}`
    // scope, where `x` is bound by BOTH `A` and `C` — an AMBIGUOUS enclosing
    // reference. The correlation lookup faults `SQLError.ambiguous` per ITS
    // site (the nearer ambiguous scope shadows any farther one) rather than
    // reusing the `ON` occurrence's unambiguous prefix `A.x`.
    let sql = """
        SELECT A.x FROM A \
        JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = x) \
        JOIN C ON C.x = A.x \
        WHERE EXISTS (SELECT 1 FROM X WHERE X.k = x)
        """
    try occurrence().expect(sql, fails: .ambiguous("x"))
  }

  @Test func `a WHERE occurrence faults the check per its site`() throws {
    // The schema path resolves each occurrence per ITS site too, so the WHERE
    // occurrence faults `SQLError.ambiguous("x")` at `columns(of:)` exactly as
    // the run does — typecheck↔run parity, not the first occurrence's prefix.
    let sql = """
        SELECT A.x FROM A \
        JOIN B ON EXISTS (SELECT 1 FROM X WHERE X.k = x) \
        JOIN C ON C.x = A.x \
        WHERE EXISTS (SELECT 1 FROM X WHERE X.k = x)
        """
    let query = try parse(query: sql)
    let resolve = { () throws -> Array<OutputColumn> in
      try occurrence().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.ambiguous("x")) { try resolve() }
  }
}

// MARK: - A correlated EXISTS probe honours the outer run's lenience

/// A CORRELATED `EXISTS` recompiles its cardinality PROBE per occurrence, and
/// that recompile must inherit the enclosing run's `validate` flag rather than
/// silently defaulting to a strict schema check. An outer `run` (`validate:
/// false`) proves the query runnable and must NOT eager-type-check a
/// data-dependent-empty derived body the probe never reaches; a strict
/// `columns(of:validate:true)` over the SAME query still faults it — parity
/// in both directions.
private func lenient() throws -> FixtureCatalog {
  try Catalog {
    // The outer relation the EXISTS correlates against.
    Relation("T", ["id": .integer]) {
      Row(1)
    }
    // The inner source whose derived body projects `Label + 1` — text plus
    // integer, a `.operand` fault WHEN type-checked — under a `WHERE k = 0`
    // that matches NO row, so a run empties the body before it ever evaluates
    // the projection.
    Relation("S", ["k": .integer, "Label": .text]) {
      Row(5, "a")
    }
  }
}

struct CorrelatedExistsProbeLenienceTests {
  @Test func `a run does not fault a probe's filtered-out body`() throws {
    // `EXISTS (SELECT 1 FROM (SELECT Label + 1 AS x FROM S WHERE k = 0) AS d
    // WHERE d.x = T.id)`: the derived body's `WHERE k = 0` filters every `S`
    // row, so `Label + 1` never runs. The correlated EXISTS recompiles its
    // PROBE per outer row; under the lenient outer run that recompile must
    // trust the filtered-out projection rather than fault `.operand`. The body
    // is empty, so the EXISTS is FALSE for the sole `T` row and the run yields
    // no rows.
    let sql = """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM \
        (SELECT Label + 1 AS x FROM S WHERE k = 0) AS d WHERE d.x = T.id)
        """
    try lenient().empty(sql)
  }

  @Test func `a strict check still faults the probe's body`() throws {
    // Parity: a strict `columns(of:validate:true)` over the SAME query eager-
    // type-checks the derived body's reachable projection and faults its ill-
    // typed `Label + 1`, so the schema path advertises nothing for a query a
    // run would fault once a row reached the projection.
    let sql = """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM \
        (SELECT Label + 1 AS x FROM S WHERE k = 0) AS d WHERE d.x = T.id)
        """
    let query = try parse(query: sql)
    let resolve = { () throws -> Array<OutputColumn> in
      try lenient().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }
}

// MARK: - FROM-less scope frame (correlation across an empty frame)

/// A FROM-less SELECT is STILL a scope FRAME. The example
/// `SELECT id FROM T WHERE (SELECT CASE WHEN EXISTS (SELECT 1 FROM S WHERE
/// S.x = T.id) THEN 1 END) = 1` nests a FROM-less middle scalar subquery whose
/// own body holds an `EXISTS` correlating to the OUTER `T` — a scope past the
/// empty FROM-less frame. The middle plan runs over a single empty record, so
/// `T.id` must thread through the empty frame as `.bound`, NOT bind from a
/// `.slot` of that empty record. `S.x` ∈ {2, 3}, so the CASE is 1 exactly for
/// `T` rows 2 and 3, which the equality `= 1` keeps.
private func fromless() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    Relation("S", ["x": .integer]) {
      Row(2)
      Row(3)
    }
  }
}

struct FromlessScopeFrameTests {
  @Test func `a correlation across a FROM-less frame runs per outer row`()
      throws {
    // The middle `(SELECT CASE WHEN EXISTS (...) THEN 1 END)` is FROM-less, so
    // its plan runs over a single EMPTY record. The inner `EXISTS`'s `T.id`
    // names the OUTER `T`, one frame OUT past the empty FROM-less frame — so it
    // resolves `.bound` and threads through per outer `T` row, rather than
    // binding a `.slot` of the empty record (which would trap or read wrong).
    // `S.x` ∈ {2, 3}, so the CASE is 1 for `T` rows 2 and 3.
    try fromless().expect(
        """
        SELECT id FROM T \
        WHERE (SELECT CASE WHEN EXISTS \
                          (SELECT 1 FROM S WHERE S.x = T.id) THEN 1 END) = 1 \
        ORDER BY id
        """,
        yields: [[2], [3]])
  }

  @Test func `a correlation across a FROM-less frame validates`() throws {
    // The schema path resolves the correlation threaded through the FROM-less
    // frame the SAME as the run — no `SQLError.column` on the enclosing `T.id`.
    let query = try parse(query:
        """
        SELECT id FROM T \
        WHERE (SELECT CASE WHEN EXISTS \
                          (SELECT 1 FROM S WHERE S.x = T.id) THEN 1 END) = 1
        """)
    let columns = try fromless().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }
}

// MARK: - Immediate correlation parity (no FROM-less frame)

struct ImmediateCorrelationParityTests {
  @Test func `a directly correlated EXISTS with a real FROM stays a slot`()
      throws {
    // PARITY: the SAME inner `EXISTS (SELECT 1 FROM S WHERE S.x = T.id)` with
    // NO FROM-less middle correlates to the IMMEDIATE enclosing `T` — one real
    // frame out — so it resolves `.slot` and reads the outer row directly. The
    // FROM-less empty-frame rule must not over-thread this immediate case.
    // `S.x` ∈ {2, 3}, so only `T` rows 2 and 3 satisfy the EXISTS.
    try fromless().expect(
        """
        SELECT id FROM T \
        WHERE EXISTS (SELECT 1 FROM S WHERE S.x = T.id) \
        ORDER BY id
        """,
        yields: [[2], [3]])
  }
}
