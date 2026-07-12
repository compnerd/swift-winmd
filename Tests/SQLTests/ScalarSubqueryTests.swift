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

// MARK: - Uncorrelated boundary

struct ScalarSubqueryCorrelationTests {
  @Test func `a scalar subquery naming an outer column fails to resolve`()
      throws {
    // Correlation is a LATER slice: a scalar subquery referencing an OUTER
    // column (`T.Id`, not in the inner `S`'s scope) does not resolve — the
    // inner query faults `SQLError.column` exactly as an unresolved column
    // does today. This asserts the CURRENT behaviour; it does NOT implement
    // correlation.
    let query = try parse(query:
        "SELECT (SELECT V FROM S WHERE V = T.Id) FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Id")) {
      try resolve()
    }
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
