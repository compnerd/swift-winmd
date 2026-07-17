// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// Two relations exercising the uncorrelated `EXISTS`/`IN (subquery)`
/// predicates: an outer `T` with an integer key `K` that is `NULL` in one row
/// (so the three-valued corners are reachable), and an inner `S` whose column
/// `V` holds a `NULL` (so `IN (SELECT V …)` sees a NULL element) and a `Flag`
/// used to filter the inner query to empty or to non-empty.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer]) {
      Row(1, 10)
      Row(2, 20)
      Row(3, nil)
      Row(4, 30)
    }
    Relation("S", ["V": .integer, "Flag": .integer]) {
      Row(10, 1)
      Row(20, 1)
      Row(99, 0)
    }
    // A relation whose single column holds a NULL, for the `IN (…, NULL)`
    // corners — `V` is `{2, NULL}` when filtered to its first two rows.
    Relation("N", ["V": .integer]) {
      Row(2)
      Row(nil)
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

/// Parses `text` to a `Statement` — the shape `Catalog.run(_:_:)` takes when a
/// test asserts on invocation side effects rather than on rows alone.
private func parse(statement text: String) throws -> Statement {
  try Statement(parsing: text)
}

// MARK: - Parsing

struct SubqueryParsingTests {
  @Test func `parses EXISTS over a subquery`() throws {
    let select =
        try parse(select: "SELECT Id FROM T WHERE EXISTS (SELECT V FROM S)")
    let inner = try parse(query: "SELECT V FROM S")
    #expect(select.predicate == .exists(inner, negated: false))
  }

  @Test func `parses NOT EXISTS via the negated flag`() throws {
    let select =
        try parse(select: "SELECT Id FROM T WHERE NOT EXISTS (SELECT V FROM S)")
    let inner = try parse(query: "SELECT V FROM S")
    // `NOT EXISTS` carries the `negated` flag directly rather than wrapping the
    // predicate in a `.not`.
    #expect(select.predicate == .exists(inner, negated: true))
  }

  @Test func `parses IN over a subquery`() throws {
    let select =
        try parse(select: "SELECT Id FROM T WHERE K IN (SELECT V FROM S)")
    let inner = try parse(query: "SELECT V FROM S")
    #expect(select.predicate == .within(.column("K"), inner, negated: false))
  }

  @Test func `parses NOT IN over a subquery`() throws {
    let select =
        try parse(select: "SELECT Id FROM T WHERE K NOT IN (SELECT V FROM S)")
    let inner = try parse(query: "SELECT V FROM S")
    #expect(select.predicate == .within(.column("K"), inner, negated: true))
  }

  @Test func `IN over a value list still parses as membership`() throws {
    // The one-token lookahead only takes the subquery arm on a leading SELECT;
    // an ordinary value list stays a `membership`, unchanged.
    let select = try parse(select: "SELECT Id FROM T WHERE K IN (10, 20)")
    #expect(select.predicate
                == .membership(.column("K"),
                               [.literal(.integer(10)), .literal(.integer(20))],
                               negated: false))
  }

  @Test func `parses IN over a subquery with a WHERE`() throws {
    let text = "SELECT Id FROM T WHERE K IN (SELECT V FROM S WHERE Flag = 1)"
    let select = try parse(select: text)
    let inner = try parse(query: "SELECT V FROM S WHERE Flag = 1")
    #expect(select.predicate == .within(.column("K"), inner, negated: false))
  }

  @Test func `parses EXISTS over a UNION subquery`() throws {
    // A subquery is a full `query`, so it may itself be a `UNION`; `Predicate`
    // is `indirect`, so it nests the whole `Query`.
    let text = "SELECT Id FROM T WHERE EXISTS "
        + "(SELECT V FROM S UNION SELECT V FROM N)"
    let select = try parse(select: text)
    let inner = try parse(query: "SELECT V FROM S UNION SELECT V FROM N")
    #expect(select.predicate == .exists(inner, negated: false))
  }
}

// MARK: - EXISTS execution

struct ExistsEvaluationTests {
  @Test func `EXISTS keeps every row when the subquery is non-empty`() throws {
    // The subquery yields rows, so `EXISTS` is TRUE for every outer row — the
    // whole of T survives.
    try fixture().expect("SELECT Id FROM T WHERE EXISTS (SELECT V FROM S)",
                         yields: [[1], [2], [3], [4]])
  }

  @Test func `EXISTS drops every row when the subquery is empty`() throws {
    // The subquery filters to zero rows, so `EXISTS` is FALSE for every outer
    // row — none survive.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT V FROM S WHERE Flag = 9)",
        yields: [])
  }

  @Test func `NOT EXISTS is the negation`() throws {
    // Over the empty subquery, `NOT EXISTS` is TRUE for every row.
    try fixture().expect(
        "SELECT Id FROM T WHERE NOT EXISTS (SELECT V FROM S WHERE Flag = 9)",
        yields: [[1], [2], [3], [4]])
    // Over the non-empty subquery, `NOT EXISTS` is FALSE for every row.
    try fixture().expect(
        "SELECT Id FROM T WHERE NOT EXISTS (SELECT V FROM S)", yields: [])
  }

  @Test func `EXISTS is two-valued over a NULL-valued subquery`() throws {
    // The subquery `N` yields a row whose value is NULL, but `EXISTS` tests
    // cardinality alone — the presence of ANY row is TRUE, never UNKNOWN — so
    // every outer row survives, including row 3 whose own K is NULL.
    try fixture().expect("SELECT Id FROM T WHERE EXISTS (SELECT V FROM N)",
                         yields: [[1], [2], [3], [4]])
  }
}

// MARK: - IN (subquery) execution

struct InQueryEvaluationTests {
  @Test func `IN over a subquery admits a matching value`() throws {
    // S.V is {10, 20, 99}; T rows with K in that set are 1 (10) and 2 (20).
    // Row 4's K (30) is absent, row 3's K is NULL (UNKNOWN, dropped).
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT V FROM S)", yields: [[1], [2]])
  }

  @Test func `IN over a filtered subquery`() throws {
    // Filtered to Flag = 1, S.V is {10, 20}; the run matches the same rows.
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT V FROM S WHERE Flag = 1)",
        yields: [[1], [2]])
  }

  @Test func `NOT IN over a subquery admits the complement`() throws {
    // S filtered to Flag = 1 yields {10, 20} with no NULL, so `NOT IN` is the
    // plain complement over non-NULL K: row 4 (30). Row 3 (K NULL) is UNKNOWN.
    try fixture().expect(
        "SELECT Id FROM T WHERE K NOT IN (SELECT V FROM S WHERE Flag = 1)",
        yields: [[4]])
  }

  @Test func `a NULL operand makes IN over a subquery UNKNOWN`() throws {
    // Row 3's K is NULL, so `NULL IN (SELECT …)` is UNKNOWN, not FALSE — the
    // row is dropped by IN and by NOT IN alike.
    try fixture().empty(
        "SELECT Id FROM T WHERE K IN (SELECT V FROM S WHERE Flag = 1) "
        + "AND Id = 3")
    try fixture().empty(
        "SELECT Id FROM T WHERE K NOT IN (SELECT V FROM S WHERE Flag = 1) "
        + "AND Id = 3")
  }

  @Test func `IN over a subquery folds like the value-list IN`() throws {
    // The subquery yielding {10, 20} matches exactly the value-list IN of the
    // same values — the two share one three-valued membership core.
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT V FROM S WHERE Flag = 1)",
        equals: "SELECT Id FROM T WHERE K IN (10, 20)")
  }
}

// MARK: - The NULL corners

struct InQueryNullCornerTests {
  @Test func `a value present in a NULL-bearing subquery is TRUE`() throws {
    // N.V is {2, NULL}; `2 IN (SELECT V FROM N)` finds the definite `2` match,
    // so it is TRUE regardless of the NULL element — the matching row survives.
    try fixture().expect(
        "SELECT Id FROM T WHERE 2 IN (SELECT V FROM N) AND Id = 1",
        yields: [[1]])
  }

  @Test func `an absent value in a NULL-bearing subquery is UNKNOWN`() throws {
    // `1 IN (SELECT V FROM N)` is `1 = 2 OR 1 = NULL` — FALSE OR UNKNOWN —
    // which is UNKNOWN, not FALSE: the row is not admitted (mirrors the
    // value-list `1 IN (2, NULL)` corner).
    try fixture().empty(
        "SELECT Id FROM T WHERE 1 IN (SELECT V FROM N) AND Id = 1")
  }

  @Test func `NOT IN a NULL-bearing subquery is UNKNOWN for an absent value`()
      throws {
    // `1 NOT IN (SELECT V FROM N)` negates that UNKNOWN to UNKNOWN — never TRUE
    // when a NULL element is present — so the row is dropped, the classic
    // `1 NOT IN (2, NULL)` trap.
    try fixture().empty(
        "SELECT Id FROM T WHERE 1 NOT IN (SELECT V FROM N) AND Id = 1")
  }

  @Test func `IN over an empty subquery is FALSE`() throws {
    // An empty subquery has no witness, so `x IN (empty)` is FALSE — no row
    // survives.
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT V FROM S WHERE Flag = 9)",
        yields: [])
  }

  @Test func `NOT IN over an empty subquery is TRUE`() throws {
    // `NOT IN (empty)` is the negation of FALSE — TRUE — so every row survives,
    // including row 3 whose K is NULL (the NULL trap needs a NULL ELEMENT, and
    // an empty subquery has none).
    try fixture().expect(
        "SELECT Id FROM T WHERE K NOT IN (SELECT V FROM S WHERE Flag = 9)",
        yields: [[1], [2], [3], [4]])
  }

  @Test func `IN over a NULL-bearing subquery keeps only the definite match`()
      throws {
    // `K IN (SELECT V FROM N)` over N.V = {2, NULL}: no outer K equals 2 (K is
    // {10, 20, NULL, 30}), so every row is either UNKNOWN (a NULL element makes
    // an unmatched test UNKNOWN, not FALSE) or, for the NULL-K row, UNKNOWN too
    // — none survives, the three-valued corner over a NULL element.
    try fixture().empty("SELECT Id FROM T WHERE K IN (SELECT V FROM N)")
  }
}

// MARK: - Arity

struct InQueryArityTests {
  @Test func `IN over a two-column subquery faults with an arity error`()
      throws {
    // `IN (Q)` requires `Q` project exactly ONE column; a two-column subquery
    // is `SQLError.arity`, checked from the compiled width, so it faults even
    // though S has rows.
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT V, Flag FROM S)",
        fails: .arity(1, 2))
  }

  @Test func `IN over a two-column subquery faults the schema check too`()
      throws {
    // The schema path enforces the SAME single-column arity as the run, so
    // validation matches execution.
    let query = try parse(
        query: "SELECT Id FROM T WHERE K IN (SELECT V, Flag FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.arity(1, 2)) {
      try resolve()
    }
  }
}

// MARK: - Type checking

struct SubqueryTypeTests {
  @Test func `columns validates a query using EXISTS`() throws {
    let query =
        try parse(query: "SELECT Id FROM T WHERE EXISTS (SELECT V FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `columns validates a query using IN over a subquery`() throws {
    let query =
        try parse(query: "SELECT Id FROM T WHERE K IN (SELECT V FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad inner column faults the schema check`() throws {
    // The inner query is type-checked too, so an unknown column inside it
    // faults validation exactly as a run would reject it.
    let query = try parse(
        query: "SELECT Id FROM T WHERE EXISTS (SELECT Missing FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }

  @Test func `a bad routine in the inner query faults the schema check`()
      throws {
    // An unregistered routine inside the subquery faults validation as the run
    // would (`SQLError.function`).
    let query = try parse(
        query: "SELECT Id FROM T WHERE K IN (SELECT nope(V) FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.function("nope")) {
      try resolve()
    }
  }

  @Test func `a bad relation in the inner query faults the run`() throws {
    // A subquery over a missing relation faults the run exactly as a top-level
    // query over it would.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT V FROM Nope)",
        fails: .relation("Nope"))
  }

  @Test func `an EXISTS select-list fault is not validated`() throws {
    // The run of an EXISTS-only occurrence goes through the cardinality probe,
    // whose constant projection never evaluates the original `1 / 0` select
    // list — so validation type-checks the PROBED shape and does NOT surface a
    // `.divide` the run never raises. Validation matches the run: `columns`
    // returns clean headers and the query runs, admitting every `T` row.
    let query =
        try parse(query: "SELECT Id FROM T WHERE EXISTS (SELECT 1 / 0 FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT 1 / 0 FROM S)",
        yields: [[1], [2], [3], [4]])
  }

  @Test func `an IN select-list fault is validated`() throws {
    // An `IN (Q)` reads the select-list column, so the run evaluates it — and
    // validation type-checks the ORIGINAL shape, surfacing the `.divide` at
    // BOTH validate and run, unlike the EXISTS probe.
    let query =
        try parse(query: "SELECT Id FROM T WHERE K IN (SELECT 1 / 0 FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT 1 / 0 FROM S)", fails: .divide)
  }

  @Test func `an EXISTS bad inner relation is still validated`() throws {
    // The probe RETAINS the subquery's FROM/`WHERE`, so a genuinely-bad inner
    // relation still faults validation for an EXISTS-only occurrence — only the
    // select list and sort keys are spared, not the row source.
    let query =
        try parse(query: "SELECT Id FROM T WHERE EXISTS (SELECT 1 FROM Nope)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.relation("Nope")) {
      try resolve()
    }
  }
}

// MARK: - ORDER BY expression subqueries

struct OrderBySubqueryTests {
  @Test func `an EXISTS in an ORDER BY expression is materialised`() throws {
    // S is non-empty, so the `EXISTS` sort key folds to K for every row — the
    // subquery in the ORDER BY expression must be materialised (once) exactly
    // as it is in the projection or WHERE. K ascending sorts NULL (row 3)
    // first, then 10, 20, 30.
    try fixture().expect(
        "SELECT Id FROM T "
        + "ORDER BY CASE WHEN EXISTS (SELECT V FROM S) THEN K ELSE 0 END, Id",
        yields: [[3], [1], [2], [4]])
  }

  @Test func `an ORDER BY EXISTS folds like the equivalent inline key`()
      throws {
    // With S non-empty the sort key IS K, so ordering on it equals ordering on
    // K directly — the subquery lowers to the same result the plain key does.
    try fixture().expect(
        "SELECT Id FROM T "
        + "ORDER BY CASE WHEN EXISTS (SELECT V FROM S) THEN K ELSE 0 END, Id",
        equals: "SELECT Id FROM T ORDER BY K, Id")
  }

  @Test func `an IN (subquery) in an ORDER BY expression is materialised`()
      throws {
    // The ORDER BY key is 0 for rows whose K is IN S.V ({10, 20, 99}) and 1
    // otherwise — rows 1 (10) and 2 (20) match, rows 3 (NULL) and 4 (30) do
    // not — so the matched rows sort first, ties broken by Id.
    try fixture().expect(
        "SELECT Id FROM T "
        + "ORDER BY CASE WHEN K IN (SELECT V FROM S) THEN 0 ELSE 1 END, Id",
        yields: [[1], [2], [3], [4]])
  }

  @Test func `columns validates an ORDER BY expression subquery`() throws {
    // The schema path collects and validates the ORDER BY subquery too, so
    // `columns(of:)` accepts exactly what the run accepts.
    let query = try parse(query:
        "SELECT Id FROM T "
        + "ORDER BY CASE WHEN EXISTS (SELECT V FROM S) THEN K ELSE 0 END")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad ORDER BY subquery column faults the schema check`()
      throws {
    // A bad column inside an ORDER BY subquery faults validation exactly as the
    // run would — the typecheck collects the same positions the run does.
    let query = try parse(query:
        "SELECT Id FROM T "
        + "ORDER BY CASE WHEN EXISTS (SELECT Missing FROM S) THEN K "
        + "ELSE 0 END")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }
}

// MARK: - Aggregate argument and FILTER subqueries

struct AggregateSubqueryTests {
  @Test func `an EXISTS in an aggregate argument is materialised`() throws {
    // The subquery in the aggregate ARGUMENT must be materialised like any
    // other projection subquery. S is non-empty, so the CASE folds to K, and
    // SUM over T's non-NULL K ({10, 20, 30}) is 60.
    try fixture().expect(
        "SELECT SUM(CASE WHEN EXISTS (SELECT V FROM S) THEN K ELSE 0 END) "
        + "FROM T",
        yields: [[60]])
  }

  @Test func `an EXISTS in an aggregate FILTER is materialised`() throws {
    // The subquery in the aggregate FILTER must be materialised too. The
    // FILTER admits every row (S non-empty), so SUM(K) folds T's non-NULL K to
    // 60; over the empty subquery it admits none and folds to NULL.
    try fixture().expect(
        "SELECT SUM(K) FILTER (WHERE EXISTS (SELECT V FROM S)) FROM T",
        yields: [[60]])
    try fixture().expect(
        "SELECT SUM(K) FILTER (WHERE EXISTS (SELECT V FROM S WHERE Flag = 9)) "
        + "FROM T",
        yields: [[nil]])
  }

  @Test func `an aggregate FILTER subquery folds like the inline predicate`()
      throws {
    // A `FILTER (WHERE EXISTS (non-empty))` admits every row, so it equals no
    // filter at all — the subquery lowers to the same fold the bare SUM does.
    try fixture().expect(
        "SELECT SUM(K) FILTER (WHERE EXISTS (SELECT V FROM S)) FROM T",
        equals: "SELECT SUM(K) FROM T")
  }

  @Test func `a grouped aggregate argument subquery is materialised`() throws {
    // Grouped by K, each group's aggregate argument nests the subquery; S
    // non-empty makes the CASE 1, so each of the four groups counts 1.
    try fixture().expect(
        "SELECT K, "
        + "SUM(CASE WHEN EXISTS (SELECT V FROM S) THEN 1 ELSE 0 END) "
        + "FROM T GROUP BY K ORDER BY K",
        yields: [[nil, 1], [10, 1], [20, 1], [30, 1]])
  }

  @Test func `a grouped ORDER BY aggregate subquery is materialised`() throws {
    // The grouped ORDER BY sorts on an aggregate whose argument nests the
    // subquery — neither projected nor in a HAVING — so the grouped resolve
    // must materialise it (in both the run and the schema path).
    try fixture().expect(
        "SELECT K FROM T GROUP BY K "
        + "ORDER BY SUM(CASE WHEN EXISTS (SELECT V FROM S) THEN 1 ELSE 0 END), "
        + "K",
        yields: [[nil], [10], [20], [30]])
  }

  @Test func `columns validates an aggregate argument subquery`() throws {
    let query = try parse(query:
        "SELECT SUM(CASE WHEN EXISTS (SELECT V FROM S) THEN K ELSE 0 END) "
        + "FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `columns validates an aggregate FILTER subquery`() throws {
    let query = try parse(query:
        "SELECT SUM(K) FILTER (WHERE EXISTS (SELECT V FROM S)) FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `columns validates a grouped ORDER BY aggregate subquery`()
      throws {
    let query = try parse(query:
        "SELECT K FROM T GROUP BY K "
        + "ORDER BY SUM(CASE WHEN EXISTS (SELECT V FROM S) THEN 1 ELSE 0 END), "
        + "K")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad aggregate FILTER subquery column faults the check`()
      throws {
    // A bad column inside an aggregate FILTER subquery faults validation as the
    // run would — the typecheck descends into the FILTER exactly as the run
    // materialiser does.
    let query = try parse(query:
        "SELECT SUM(K) FILTER (WHERE EXISTS (SELECT Missing FROM S)) FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }

  @Test func `columns validates a grouped ORDER BY CORRELATED subquery`()
      throws {
    // Batch 7, Item 1: a grouped query whose ORDER BY aggregate argument nests
    // a CORRELATED subquery (`S.V = T.K`, the inner `T.K` an outer column of the
    // grouped select). The run path's `group` gives the ORDER BY subquery
    // lowering the enclosing scope, so it resolves `T.K` and runs; VALIDATION
    // must thread the SAME enclosing scope, else it compiles the inner query
    // with NO outer scope and falsely faults `SQLError.column("K")`. It must
    // succeed exactly as the run does.
    let query = try parse(query:
        "SELECT K FROM T GROUP BY K "
        + "ORDER BY SUM(CASE WHEN EXISTS "
        + "(SELECT 1 FROM S WHERE S.V = T.K) THEN 1 ELSE 0 END), K")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a grouped ORDER BY CORRELATED subquery orders the run`() throws {
    // The correlated `EXISTS (SELECT 1 FROM S WHERE S.V = T.K)` is TRUE for the
    // groups whose `K` is in `S.V` ({10, 20, 99}) — groups 10 and 20 — and
    // FALSE for groups NULL and 30, so the ORDER BY key is 0 for {NULL, 30} and
    // 1 for {10, 20}. Sorting on that key then `K` yields NULL, 30 (key 0) then
    // 10, 20 (key 1). The run must execute the per-group correlated subquery and
    // order the groups by it.
    try fixture().expect(
        "SELECT K FROM T GROUP BY K "
        + "ORDER BY SUM(CASE WHEN EXISTS "
        + "(SELECT 1 FROM S WHERE S.V = T.K) THEN 1 ELSE 0 END), K",
        yields: [[nil], [30], [10], [20]])
  }
}

// MARK: - Deferred execution

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so a `NOT DETERMINISTIC`
/// routine records how many times a run invoked it. The engine evaluates a
/// query on one thread, so the box needs no lock.
private final class Counter: @unchecked Sendable {
  private(set) var count = 0

  func next() -> Int {
    count += 1
    return count
  }
}

/// A subquery executes at RUN time, not during `compile` — so a SCHEMA-ONLY
/// path (`columns(of:)`) opens NO cursor and runs no inner query, and a run
/// materialises each UNCORRELATED subquery at most ONCE.
///
/// This is the architectural fix: PR-1 materialised subqueries eagerly in
/// `compile`, so asking for the headers of a query nesting an
/// `EXISTS`/`IN (subquery)` scanned the inner relation — surfacing data-
/// dependent errors before the query ever ran. Execution now defers to `run`.
struct SubqueryDeferralTests {
  /// A routine registry whose `tick()` counts its invocations, over the
  /// standard prelude so the ordinary comparisons still resolve.
  private func routines(_ counter: Counter) throws -> Routines {
    try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
  }

  @Test func `columns does not execute an EXISTS subquery`() throws {
    // Asking for the result headers must NOT run the inner query: the schema
    // path shares `compile`'s lowering, which now carries the subquery as data
    // rather than running it. The counting `tick()` inside the subquery is
    // never invoked, so the counter stays at 0 — proving compile opens no
    // cursor on `S`.
    let counter = Counter()
    let query = try parse(
        query: "SELECT Id FROM T WHERE EXISTS (SELECT tick() FROM S)")
    let columns =
        try fixture().columns(of: query, routines: routines(counter),
                              validate: true)
    #expect(columns.count == 1)
    #expect(counter.count == 0)
  }

  @Test func `columns defers a select-list fault an EXISTS probe skips`()
      throws {
    // The subquery's select list divides by a NON-constant zero (`Flag - 1`,
    // which is 0 for S's two `Flag = 1` rows), but it is used ONLY by `EXISTS`,
    // which needs cardinality — not the projected value. `columns(of:)` returns
    // the headers WITHOUT triggering the divide (the schema path opens no
    // cursor), and the RUN materialises the occurrence as a cardinality PROBE
    // that never evaluates the select list, so it does NOT fault either:
    // `EXISTS` over non-empty `S` is TRUE, every row of `T` is admitted.
    let query = try parse(
        query: "SELECT Id FROM T WHERE EXISTS (SELECT 1 / (Flag - 1) FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    // The run does NOT surface the divide — the EXISTS probe never evaluates
    // `1 / (Flag - 1)` — so every outer row is admitted (S is non-empty).
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT 1 / (Flag - 1) FROM S)",
        yields: [[1], [2], [3], [4]])
  }

  @Test func `columns does not execute an IN subquery`() throws {
    // The `IN (subquery)` schema path is cursor-free too: its single-column
    // arity is decided from the compiled width, never by running the inner
    // query, so `tick()` stays uninvoked.
    let counter = Counter()
    let query = try parse(
        query: "SELECT Id FROM T WHERE K IN (SELECT tick() FROM S)")
    let columns =
        try fixture().columns(of: query, routines: routines(counter),
                              validate: true)
    #expect(columns.count == 1)
    #expect(counter.count == 0)
  }

  @Test func `an EXISTS subquery probes cardinality without its select list`()
      throws {
    // The subquery is used ONLY by `EXISTS`, which needs cardinality — not the
    // projected value — so it materialises as a PROBE that never evaluates the
    // select list. `tick()` sits in the select list, so the probe never invokes
    // it: the counter stays 0 (not 3, not 12), and
    // `EXISTS` over non-empty `S` is still TRUE, admitting every row of `T`.
    let counter = Counter()
    let statement =
        try parse(statement:
            "SELECT Id FROM T WHERE EXISTS (SELECT tick() FROM S)")
    let rows = try fixture().run(statement, routines(counter))
    let expected: Array<Array<Value>> =
        [[.integer(1)], [.integer(2)], [.integer(3)], [.integer(4)]]
    #expect(rows == expected)
    #expect(counter.count == 0)
  }

  @Test func `an IN subquery runs exactly once per outer-query run`() throws {
    // Likewise `IN (subquery)`: the single materialised column is computed once
    // and folded against each outer row, so `tick()` runs once per S row (3),
    // not once per (outer row × S row).
    let counter = Counter()
    let statement =
        try parse(statement:
            "SELECT Id FROM T WHERE K IN (SELECT tick() FROM S)")
    _ = try fixture().run(statement, routines(counter))
    #expect(counter.count == 3)
  }

  @Test func `a short-circuited subquery still materialises (follow-up)`()
      throws {
    // KNOWN LIMITATION of this slice: subqueries materialise at the START of a
    // run, so one in an arm an `AND`/`OR` short-circuit would never reach STILL
    // executes. `1 = 0 AND EXISTS (…)` is statically FALSE, yet the subquery is
    // materialised up front — here as an EXISTS cardinality PROBE, which never
    // evaluates the select-list `tick()`, so the counter stays 0. Per-arm
    // laziness — threading a runner to the evaluation site so an unreached arm
    // skips its subquery — is a follow-up; the once-per-run materialisation
    // this slice lands does not depend on it. This test PINS the current
    // behaviour so the follow-up flips it deliberately.
    let counter = Counter()
    let statement =
        try parse(statement:
            "SELECT Id FROM T WHERE 1 = 0 AND EXISTS (SELECT tick() FROM S)")
    let rows = try fixture().run(statement, routines(counter))
    #expect(rows.isEmpty)
    #expect(counter.count == 0)
  }
}

// MARK: - EXISTS cardinality probe

/// An `EXISTS (Q)` occurrence is materialised as a cardinality PROBE — the row
/// source is tested for ANY row WITHOUT evaluating the select list or sort
/// keys, honouring the subquery's original `OFFSET`/`FETCH` — while an `IN (Q)`
/// occurrence materialises its single column of values. So a fault or a per-row
/// side effect that lives in an EXISTS subquery's SELECT LIST never fires, but
/// an `IN`'s column is still read.
struct ExistsProbeTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
      }
      Relation("S", ["V": .integer, "Flag": .integer]) {
        Row(10, 1)
        Row(20, 1)
        Row(99, 0)
      }
    }
  }

  @Test func `EXISTS over a dividing select list is safe when non-empty`()
      throws {
    // `SELECT 1 / 0 FROM S` divides by a CONSTANT zero — a run of its select
    // list would fault `.divide`. Used by `EXISTS`, it materialises as a probe
    // that never evaluates the select list, so `EXISTS` over the non-empty `S`
    // is TRUE with NO `.divide` — every row of `T` is admitted.
    try fixture().expect("SELECT Id FROM T WHERE EXISTS (SELECT 1 / 0 FROM S)",
                         yields: [[1], [2]])
  }

  @Test func `EXISTS over an empty source is FALSE`() throws {
    // The probe over an empty row source yields no row, so `EXISTS` is FALSE —
    // every outer row is dropped. `Flag = 9` matches no `S` row.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT 1 / 0 FROM S WHERE Flag = 9)",
        yields: [])
  }

  @Test func `NOT EXISTS over a dividing select list negates without faulting`()
      throws {
    // `NOT EXISTS` over the non-empty `S` is FALSE — still no `.divide`, since
    // the probe skips the select list — so every outer row is dropped.
    try fixture().expect(
        "SELECT Id FROM T WHERE NOT EXISTS (SELECT 1 / 0 FROM S)",
        yields: [])
  }

  @Test func `IN still evaluates its subquery column`() throws {
    // An `IN (Q)` needs the column of VALUES, so its select list IS evaluated —
    // it is NOT probed. `S.V` is {10, 20, 99}, so the outer rows whose `K` is
    // in that set survive (both `T` rows).
    try fixture().expect("SELECT Id FROM T WHERE K IN (SELECT V FROM S)",
                         yields: [[1], [2]])
  }

  @Test func `IN over a dividing select list still faults`() throws {
    // Because `IN` reads the column, a dividing select list DOES fault — the
    // opposite of the `EXISTS` probe — proving the two occurrences materialise
    // differently.
    try fixture().expect("SELECT Id FROM T WHERE K IN (SELECT 1 / 0 FROM S)",
                         fails: .divide)
  }

  @Test func `EXISTS over a FROM-less SELECT is TRUE`() throws {
    // A FROM-less `SELECT 1` yields exactly one row and cannot carry a limit,
    // so its probe is a limit-free `SELECT <constant>` — it compiles (a
    // FROM-less select with a limit would be rejected) and yields one row, so
    // `EXISTS` is TRUE and every outer row is admitted.
    try fixture().expect("SELECT Id FROM T WHERE EXISTS (SELECT 1)",
                         yields: [[1], [2]])
  }

  @Test func `EXISTS honours a FETCH FIRST 0 ROWS limit as FALSE`() throws {
    // The probe keeps the subquery's ORIGINAL `FETCH FIRST 0 ROWS ONLY`, so the
    // row source yields zero rows and `EXISTS` is FALSE — a synthetic one-row
    // cap must NOT override the original limit. Every outer row is dropped, and
    // the dividing select list still never evaluates (no `.divide`).
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT 1 / 0 FROM S FETCH FIRST 0 ROWS ONLY)",
        yields: [])
  }

  @Test func `EXISTS honours an OFFSET past the end as FALSE`() throws {
    // `S` has three rows; `OFFSET 5 ROWS` skips past every one, so the probe
    // sees no row and `EXISTS` is FALSE — the preserved OFFSET is not
    // overridden.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT V FROM S OFFSET 5 ROWS)",
        yields: [])
  }

  @Test func `EXISTS with a positive FETCH over a non-empty source is TRUE`()
      throws {
    // A `FETCH FIRST 2 ROWS ONLY` keeps rows, so the non-empty `S` still yields
    // a row through the probe and `EXISTS` is TRUE — every outer row admitted.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT V FROM S FETCH FIRST 2 ROWS ONLY)",
        yields: [[1], [2]])
  }
}

// MARK: - DISTINCT EXISTS cardinality probe

/// A `DISTINCT` EXISTS-only subquery is probed too, provided it carries no
/// `OFFSET`: `DISTINCT` collapses a non-empty source to at least one distinct
/// row, so `SELECT DISTINCT 1 FROM S` is non-empty iff `S` is — the constant
/// projection preserves existence WITHOUT evaluating the original select list.
/// A `DISTINCT` EXISTS WITH an `OFFSET` stays a FULL run: an offset skips
/// distinct rows, so emptiness depends on the REAL distinct count, which the
/// constant projection would collapse.
struct DistinctExistsProbeTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
      }
      // `V` holds three distinct values, so an `OFFSET` up to two still leaves
      // a distinct row and past three leaves none.
      Relation("S", ["V": .integer, "Flag": .integer]) {
        Row(10, 1)
        Row(20, 1)
        Row(99, 0)
      }
    }
  }

  @Test func `DISTINCT EXISTS over a dividing select list is safe`() throws {
    // A `DISTINCT` EXISTS without an `OFFSET` is probed — `SELECT DISTINCT 1`
    // yields one distinct row iff `S` is non-empty — so the original `1 / 0`
    // select list never evaluates and `EXISTS` is TRUE with NO `.divide`.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT DISTINCT 1 / 0 FROM S)",
        yields: [[1], [2]])
  }

  @Test func `DISTINCT EXISTS over an empty source is FALSE`() throws {
    // The probe over an empty source yields no distinct row, so `EXISTS` is
    // FALSE — every outer row dropped, the select list still never evaluated.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT DISTINCT 1 / 0 FROM S WHERE Flag = 9)",
        yields: [])
  }

  @Test func `columns validates a DISTINCT EXISTS dividing select list`()
      throws {
    // The type-check validates the SAME probed shape the run evaluates, so the
    // `1 / 0` select list is not checked and validation is clean — matching the
    // run, which does not fault.
    let query = try parse(
        query: "SELECT Id FROM T WHERE EXISTS (SELECT DISTINCT 1 / 0 FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `DISTINCT EXISTS honours a FETCH FIRST 0 ROWS limit as FALSE`()
      throws {
    // The probe keeps the original `FETCH FIRST 0 ROWS ONLY`, so it pages zero
    // rows and `EXISTS` is FALSE — every outer row dropped.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT DISTINCT V FROM S FETCH FIRST 0 ROWS ONLY)",
        yields: [])
  }

  @Test func `DISTINCT EXISTS with a positive FETCH is TRUE`() throws {
    // A `FETCH FIRST 2 ROWS ONLY` keeps the one distinct probe row, so the
    // non-empty `S` yields it and `EXISTS` is TRUE — every outer row admitted.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT DISTINCT V FROM S FETCH FIRST 2 ROWS ONLY)",
        yields: [[1], [2]])
  }

  @Test func `DISTINCT EXISTS with an OFFSET reflects the real distinct count`()
      throws {
    // `S.V` has three distinct values. `OFFSET 5 ROWS` skips past every one, so
    // the FULL run — the probe is NOT taken for a DISTINCT-with-OFFSET select —
    // yields no distinct row and `EXISTS` is FALSE.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT DISTINCT V FROM S OFFSET 5 ROWS)",
        yields: [])
    // `OFFSET 1 ROWS` leaves two of the three distinct rows, so `EXISTS` is
    // TRUE — the real distinct count, not the collapsed single probe row.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT DISTINCT V FROM S OFFSET 1 ROWS)",
        yields: [[1], [2]])
  }

  @Test func `DISTINCT EXISTS with an OFFSET runs the select list`() throws {
    // A DISTINCT-with-OFFSET select is NOT probe-eligible: its emptiness needs
    // the real distinct count, so the FULL run evaluates the projection — the
    // `1 / 0` genuinely faults `.divide`, proving the probe was not taken.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT DISTINCT 1 / 0 FROM S OFFSET 5 ROWS)",
        fails: .divide)
  }
}

// MARK: - Aggregate EXISTS cardinality probe

/// An aggregate/grouped EXISTS-only subquery WITHOUT a `HAVING` is probed too,
/// via a cardinality/group-preserving shape whose target is a trivial
/// `COUNT(*)` (the original target is irrelevant to existence). A WHOLE-RESULT
/// aggregate (no `GROUP BY`) yields EXACTLY ONE row regardless of the source —
/// even an empty one — so `EXISTS` is TRUE modulo the limit; a GROUPED one
/// yields ONE ROW PER GROUP, so existence is the source's non-emptiness after
/// `WHERE`. The probe keeps FROM/`WHERE`/`GROUP BY` and the original
/// `OFFSET`/`FETCH` but never evaluates the original target, so `SUM(1 / 0)`
/// does not fault. A `HAVING` subquery is NOT probed — group survival depends
/// on the aggregate VALUES, not a source-only fact — so it stays a full run.
struct AggregateExistsProbeTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
      }
      // `Flag` doubles as the grouping column `g`: {1, 1, 0} spans two groups.
      Relation("S", ["V": .integer, "Flag": .integer]) {
        Row(10, 1)
        Row(20, 1)
        Row(99, 0)
      }
    }
  }

  @Test func `whole-result aggregate EXISTS over a dividing target is TRUE`()
      throws {
    // A whole-result `SUM(1 / 0)` would fault `.divide` if run. Used by an
    // EXISTS-only occurrence, it probes via `COUNT(*)`, which yields exactly
    // one row over the non-empty `S` — so `EXISTS` is TRUE with NO `.divide`
    // and every outer row is admitted.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT SUM(1 / 0) FROM S)",
        yields: [[1], [2]])
  }

  @Test func `whole-result aggregate EXISTS over an empty source is TRUE`()
      throws {
    // A whole-result aggregate yields EXACTLY ONE row even over an empty source
    // (`SUM` of no rows is NULL, but it is still one row), so its probe —
    // `COUNT(*)` over the empty `S` — yields one row and `EXISTS` is TRUE. The
    // dividing target still never evaluates.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT SUM(1 / 0) FROM S WHERE Flag = 9)",
        yields: [[1], [2]])
  }

  @Test func `columns validates a whole-result aggregate EXISTS`() throws {
    // The type-check validates the SAME probed `COUNT(*)` shape the run uses,
    // so the `1 / 0` target is not checked — clean, matching the run.
    let query = try parse(
        query: "SELECT Id FROM T WHERE EXISTS (SELECT SUM(1 / 0) FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `whole-result aggregate EXISTS honours FETCH FIRST 0 as FALSE`()
      throws {
    // The probe keeps the original `FETCH FIRST 0 ROWS ONLY`, so it pages away
    // the one aggregate row and `EXISTS` is FALSE — every outer row dropped.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT SUM(V) FROM S FETCH FIRST 0 ROWS ONLY)",
        yields: [])
  }

  @Test func `grouped aggregate EXISTS over a dividing target is TRUE`()
      throws {
    // A grouped `SUM(1 / 0)` probes via `COUNT(*)` keeping the `GROUP BY`,
    // which yields one row per group — the non-empty `S` has groups, so
    // `EXISTS` is TRUE with NO `.divide` and every outer row is admitted.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT SUM(1 / 0) FROM S GROUP BY Flag)",
        yields: [[1], [2]])
  }

  @Test func `grouped aggregate EXISTS over an empty source is FALSE`()
      throws {
    // A grouped aggregate yields ONE ROW PER GROUP, so an empty source has NO
    // groups and NO rows — unlike the whole-result case — so the probe yields
    // nothing and `EXISTS` is FALSE. Every outer row is dropped.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS "
        + "(SELECT SUM(1 / 0) FROM S WHERE Flag = 9 GROUP BY Flag)",
        yields: [])
  }

  @Test func `columns validates a grouped aggregate EXISTS`() throws {
    // The probed grouped `COUNT(*)` shape validates the SAME way the run does,
    // so the `1 / 0` target is not checked — clean, matching the run.
    let query = try parse(query:
        "SELECT Id FROM T WHERE EXISTS "
        + "(SELECT SUM(1 / 0) FROM S GROUP BY Flag)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `HAVING aggregate EXISTS is a full run reflecting the filter`()
      throws {
    // A `HAVING` is NOT probe-eligible: group survival depends on the aggregate
    // VALUES. So it runs in FULL and `EXISTS` reflects the real HAVING-filtered
    // group count. Group `Flag = 1` sums to 30 (> 0) and `Flag = 0` to 99, so
    // both survive — `EXISTS` is TRUE and every outer row is admitted.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS "
        + "(SELECT SUM(V) FROM S GROUP BY Flag HAVING SUM(V) > 0)",
        yields: [[1], [2]])
    // With a HAVING that no group meets, the full run yields no group and
    // `EXISTS` is FALSE — every outer row dropped.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS "
        + "(SELECT SUM(V) FROM S GROUP BY Flag HAVING SUM(V) > 1000)",
        yields: [])
  }

  @Test func `HAVING aggregate EXISTS runs a dividing aggregate`() throws {
    // Because a `HAVING` subquery is a full run, an aggregate-in-`HAVING`
    // `1 / 0` is genuinely NEEDED to decide group survival, so it faults
    // `.divide` — the probe was not taken.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS "
        + "(SELECT SUM(V) FROM S GROUP BY Flag HAVING SUM(1 / 0) > 0)",
        fails: .divide)
  }

  @Test func `aggregate EXISTS still faults a bad inner relation`() throws {
    // The probe RETAINS the subquery's FROM/`WHERE`/`GROUP BY`, so a
    // genuinely-bad inner relation still faults — only the target is spared.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT SUM(V) FROM Nope GROUP BY Flag)",
        fails: .relation("Nope"))
  }

  @Test func `IN over an aggregate subquery still evaluates its target`()
      throws {
    // An aggregate IN subquery is unaffected by the EXISTS probe: `IN` reads
    // the aggregate VALUE, so the target runs and a dividing one faults.
    try fixture().expect(
        "SELECT Id FROM T WHERE K IN (SELECT SUM(1 / 0) FROM S)",
        fails: .divide)
  }
}

// MARK: - Reserved-relation subqueries

/// A reserved `definition_schema.`/`information_schema.` relation named ONLY
/// inside a nested `EXISTS`/`IN (subquery)` is augmented into the context — the
/// relation-name collector descends into subqueries, so the store overlay is
/// materialised before the subquery's WIDTH compile AND its run, exactly as if
/// the outer query had named it. The outer relation `T` names no reserved
/// relation, so the coverage comes entirely from the descent.
struct SubqueryReservedRelationTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
    }
  }

  @Test func `EXISTS over definition_schema.tables compiles and runs`() throws {
    // The reserved store relation is named ONLY inside the subquery. Before the
    // fix its overlay was not materialised (the collector did not descend), so
    // the WIDTH compile faulted `SQLError.relation`. It now resolves and, since
    // `definition_schema.tables` lists `T`, `EXISTS` is TRUE for every row.
    try fixture().expect(
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT table_name FROM definition_schema.tables)",
        yields: [[1], [2]])
  }

  @Test func `IN over information_schema.columns compiles and runs`() throws {
    // The subquery-only reference is a portable `information_schema.` view over
    // the store; its body names `definition_schema.columns`, augmented through
    // the same descent. `information_schema.columns` lists T's `Id` column, so
    // `'Id' IN (…)` is TRUE and every row survives.
    try fixture().expect(
        "SELECT Id FROM T WHERE 'Id' IN "
        + "(SELECT column_name FROM information_schema.columns)",
        yields: [[1], [2]])
  }

  @Test func `columns validates a subquery-only reserved reference`() throws {
    // The schema path shares the same `augment`, so `columns(of:validate:)`
    // resolves the subquery-only reserved relation exactly as the run does.
    let query = try parse(query:
        "SELECT Id FROM T "
        + "WHERE EXISTS (SELECT table_name FROM definition_schema.tables)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a reserved relation in the OUTER position still works`() throws {
    // The pre-existing coverage: the reserved relation named in the OUTER FROM
    // is unaffected by the descent — the collector still gathers it directly.
    try fixture().expect(
        "SELECT table_name FROM definition_schema.tables "
        + "WHERE table_name = 'T'",
        yields: [["T"]])
  }

  @Test func `a non-reserved subquery is unaffected by the descent`() throws {
    // A subquery over an ordinary base relation collects its name too, but it
    // is not reserved, so `augment` adds nothing and ordinary resolution holds.
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("S", ["V": .integer]) {
        Row(7)
      }
    }.expect("SELECT Id FROM T WHERE EXISTS (SELECT V FROM S)",
             yields: [[1], [2]])
  }
}

// MARK: - CASE-guard subquery validation

/// A projection `CASE` whose guard nests an `EXISTS`/`IN (subquery)` is
/// validated by `columns(of:validate: true)` — the subquery-check threads
/// through the projection/`ORDER BY`/`HAVING` validation, so a query that runs
/// is not rejected as unsupported.
struct SubqueryConditionalValidationTests {
  @Test func `columns validates a projection CASE EXISTS guard`() throws {
    // `SELECT CASE WHEN EXISTS (…) THEN Id ELSE 0 END` — the guard's subquery is
    // validated in the projection-check path, so the query type-checks.
    let query = try parse(query:
        "SELECT CASE WHEN EXISTS (SELECT V FROM S) THEN Id ELSE 0 END FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `columns validates a projection CASE IN guard`() throws {
    // The `IN (subquery)` guard is validated the same way, its single-column
    // arity enforced from the compiled width.
    let query = try parse(query:
        "SELECT CASE WHEN K IN (SELECT V FROM S) THEN Id ELSE 0 END FROM T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a projection CASE EXISTS guard runs correctly`() throws {
    // S is non-empty, so the guard is TRUE for every row and the CASE yields
    // Id; the projection-position subquery lowers and runs as a WHERE one.
    try fixture().expect(
        "SELECT CASE WHEN EXISTS (SELECT V FROM S) THEN Id ELSE 0 END FROM T",
        yields: [[1], [2], [3], [4]])
  }

  @Test func `a bad projection CASE guard subquery column faults the check`()
      throws {
    // A bad column inside the projection CASE guard's subquery faults the
    // validation exactly as a run would — the check descends the guard.
    let query = try parse(query:
        "SELECT CASE WHEN EXISTS (SELECT Missing FROM S) THEN Id ELSE 0 END "
        + "FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }
}

// MARK: - View predicate-pushdown subquery inheritance

/// An outer `WHERE EXISTS/IN (Q)` conjunct that pushes INTO a simple view still
/// resolves against the result the top-level `run` materialised: the view
/// sub-plan INHERITS (merges) the caller's subquery cache rather than replacing
/// it with a view-body-only one. Without the merge the pushed conjunct's `Q`,
/// keyed in the caller's cache, would be missing from the view-only cache and
/// fault "a subquery result was not materialised".
struct ViewPushdownSubqueryTests {
  /// `VW` projects bare columns of `T`, so an outer conjunct over its output
  /// columns pushes below the projection into the view sub-plan.
  private func view() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
        Row(3, nil)
        Row(4, 30)
      }
      Relation("S", ["V": .integer, "Flag": .integer]) {
        Row(10, 1)
        Row(20, 1)
        Row(99, 0)
      }
      try View("VW", "SELECT Id, K FROM T", as: ["Id", "K"])
    }
  }

  /// A view whose OWN body nests an `EXISTS`, over `T` filtered by that inner
  /// subquery — its own subquery must still resolve alongside a pushed outer
  /// one.
  private func nested() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
      }
      Relation("S", ["V": .integer, "Flag": .integer]) {
        Row(10, 1)
      }
      try View("VN", "SELECT Id, K FROM T WHERE EXISTS (SELECT V FROM S)",
               as: ["Id", "K"])
    }
  }

  /// The INVERSE of `nested`: the view `VN`'s body has the SAME
  /// `EXISTS (SELECT V FROM S)` but over an EMPTY base `S`, so its body filters
  /// EVERY row out. A caller that binds a NON-empty CTE `S` must NOT leak into
  /// the view body — the body reads its own (empty) base.
  private func hollow() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
      }
      // An EMPTY base `S`, so the view body's `EXISTS (SELECT V FROM S)` is
      // FALSE and filters every row.
      Relation("S", ["V": .integer, "Flag": .integer]) { }
      try View("VN", "SELECT Id, K FROM T WHERE EXISTS (SELECT V FROM S)",
               as: ["Id", "K"])
    }
  }

  @Test func `an outer EXISTS pushed into a view resolves`() throws {
    // The outer `WHERE EXISTS (SELECT V FROM S)` conjunct pushes below `VW`'s
    // projection into its sub-plan; the pushed `Q` resolves against the result
    // the top-level run materialised (the caller's cache, MERGED into the
    // view's), not a view-only cache that lacks it. S is non-empty, so the
    // EXISTS is TRUE and every view row survives.
    try view().expect("SELECT Id FROM VW WHERE EXISTS (SELECT V FROM S)",
                      yields: [[1], [2], [3], [4]])
  }

  @Test func `an outer EXISTS pushed into a view drops rows when empty`()
      throws {
    // The pushed EXISTS is FALSE (the inner query filters to zero rows), so no
    // view row survives — the pushed subquery still resolves, just to empty.
    try view().expect(
        "SELECT Id FROM VW WHERE EXISTS (SELECT V FROM S WHERE Flag = 9)",
        yields: [])
  }

  @Test func `an outer IN pushed into a view resolves`() throws {
    // An `IN (Q)` conjunct pushes into the view the same way; S.V is {10, 20,
    // 99}, so the view rows whose K is in that set survive (Id 1 and 2).
    try view().expect("SELECT Id FROM VW WHERE K IN (SELECT V FROM S)",
                      yields: [[1], [2]])
  }

  @Test func `a view whose body nests a subquery still resolves`() throws {
    // `VN`'s body itself nests `EXISTS (SELECT V FROM S)`; the merge unions the
    // view's own materialised subqueries with the caller's, so the body's
    // subquery resolves too. S is non-empty, so the body keeps every row.
    try nested().expect("SELECT Id FROM VN", yields: [[1], [2]])
  }

  @Test func `a view body subquery and a pushed outer one both resolve`()
      throws {
    // Both the view body's OWN `EXISTS` and the outer `EXISTS` pushed into it
    // must resolve — the two caches are layered. S is non-empty, so both are
    // TRUE and every row survives.
    try nested().expect("SELECT Id FROM VN WHERE EXISTS (SELECT V FROM S)",
                        yields: [[1], [2]])
  }

  @Test func `a pushed outer subquery reads the caller CTE not the view base`()
      throws {
    // Bug 1: the view body's `EXISTS (SELECT V FROM S)` reads BASE `S`
    // (non-empty), and the caller's AST-IDENTICAL outer `EXISTS (SELECT V FROM
    // S)` — pushed into the view — must read the caller's CTE `S`, an EMPTY
    // relation shadowing the base. The two subqueries share a `Query` VALUE
    // but resolve under DIFFERENT overlays: keying the run-time cache by the
    // `Query` alone (the old merge) collapsed them, so the pushed conjunct read
    // the view body's base-`S` result and wrongly kept every row. Layering the
    // caller's cache OVER the view's keeps the contexts distinct: the pushed
    // EXISTS reads the empty CTE and is FALSE, dropping every row, while the
    // view body's own EXISTS still reads base `S` and keeps them — so the
    // result is EMPTY, NOT the base-table interpretation's two rows.
    let statement = try parse(statement:
        "WITH S(V) AS (SELECT Id FROM T WHERE 1 = 0) "
        + "SELECT Id FROM VN WHERE EXISTS (SELECT V FROM S)")
    let rows = try nested().run(statement, .standard)
    // The pushed EXISTS resolves against the EMPTY caller CTE — no rows left.
    #expect(rows.isEmpty)
    // And this DIFFERS from the base-table interpretation the collapsed cache
    // gave, proving the caches are kept distinct: reading base `S` (non-empty)
    // for the pushed EXISTS would have kept both view rows.
    let base: Array<Array<Value>> = [[.integer(1)], [.integer(2)]]
    #expect(rows != base)
  }

  @Test func `a view body subquery reads the view base not the caller CTE`()
      throws {
    // Bug 2, the INVERSE direction: the VIEW BODY's `EXISTS (SELECT V FROM S)`
    // resolves against the view's OWN base `S` (here EMPTY), and the caller's
    // AST-IDENTICAL `WITH S AS (SELECT 1)` CTE must NOT leak into that body.
    // Keying the run-time cache by the `Query` VALUE alone let the caller's
    // (non-empty) CTE result win the merge, so the view body's own EXISTS
    // wrongly read the CTE and kept every row. Keying by OCCURRENCE — each
    // subquery's resolution `Subscope` composed with its AST — keeps the
    // contexts distinct: the body's `.view(vn)` EXISTS reads the empty base
    // and drops every row, while the caller's `.caller` pushed EXISTS reads the
    // non-empty CTE and keeps them. The view filters CORRECTLY (its base `S` is
    // empty), so the result is EMPTY.
    let statement = try parse(statement:
        "WITH S(V) AS (SELECT 1) "
        + "SELECT Id FROM VN WHERE EXISTS (SELECT V FROM S)")
    let rows = try hollow().run(statement, .standard)
    // The view body's EXISTS reads its EMPTY base `S`, filtering every row —
    // NOT the caller's non-empty CTE, which would have kept both rows.
    #expect(rows.isEmpty)
    let leaked: Array<Array<Value>> = [[.integer(1)], [.integer(2)]]
    #expect(rows != leaked)
  }

  @Test func `both subquery directions stay distinct`() throws {
    // Prove distinctness BOTH ways against ONE catalog: the view body's EXISTS
    // over base `S` and the caller's pushed EXISTS over CTE `S` read DIFFERENT
    // results for the same AST. With base `S` NON-empty (view keeps rows) and
    // the caller CTE EMPTY (pushed EXISTS drops rows), the result is EMPTY —
    // only correct if each subquery reads its OWN context. A single collapsed
    // entry (whichever won) could not give this: the caller-CTE value would
    // make the view body drop too (still empty, but for the wrong reason), so
    // this pairs with the base-`S`-empty/CTE-non-empty inverse above — together
    // they pin BOTH directions.
    let empty = try parse(statement:
        "WITH S(V) AS (SELECT Id FROM T WHERE 1 = 0) "
        + "SELECT Id FROM VN WHERE EXISTS (SELECT V FROM S)")
    #expect(try nested().run(empty, .standard).isEmpty)
    // Caller CTE non-empty: the pushed EXISTS is TRUE and the view body's own
    // EXISTS (base `S` non-empty) is TRUE too, so every row survives — the
    // caller's CTE result did NOT collapse the view body's base read.
    let full = try parse(statement:
        "WITH S(V) AS (SELECT 1) "
        + "SELECT Id FROM VN WHERE EXISTS (SELECT V FROM S)")
    let kept: Array<Array<Value>> = [[.integer(1)], [.integer(2)]]
    #expect(try nested().run(full, .standard) == kept)
  }
}

// MARK: - IN (subquery) pushdown nullability

/// An `IN (Q)` predicate is THREE-VALUED — UNKNOWN when its materialised
/// subquery holds a NULL and nothing matches — so it must be treated NULLABLE
/// for predicate pushdown even when it is slotless (a constant operand): a
/// conjunct carrying `IN (Q)` must NOT be pushed AHEAD of a later unsafe
/// conjunct, or pushdown would drop the UNKNOWN rows before the unsafe one runs
/// and suppress a throw the non-short-circuiting `AND` owes. An `EXISTS (Q)` is
/// genuinely TWO-valued (never UNKNOWN), so it stays freely pushable.
struct InPushdownNullabilityTests {
  /// A view over bare `T` columns, and an `S` whose single column `N` holds
  /// only a NULL — so `1 IN (SELECT N FROM S)` is UNKNOWN (no match, a NULL
  /// element).
  private func view() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("S", ["N": .integer]) {
        Row(nil)
      }
      try View("VW", "SELECT Id FROM T", as: ["Id"])
    }
  }

  @Test func `an IN subquery conjunct is not pushed ahead of an unsafe one`()
      throws {
    // Bug 2: `1 IN (SELECT N FROM S)` is UNKNOWN (S.N is a lone NULL, no
    // match). Under the un-pushed semantics the non-short-circuiting `AND`
    // still evaluates `(1 / 0) = 0` for every view row, raising `.divide`.
    // Classifying the slotless `IN (Q)` NON-nullable would let pushdown inject
    // it into the view ahead of the unsafe division: the UNKNOWN rows would be
    // dropped inside the view before the outer `(1 / 0) = 0` ran, suppressing
    // the throw. Treating `.within` as NULLABLE keeps the `IN` conjunct OUTER
    // (a later conjunct is unsafe), so the division runs and the query THROWS.
    try view().expect(
        "SELECT Id FROM VW WHERE 1 IN (SELECT N FROM S) AND (1 / 0) = 0",
        fails: .divide)
  }

  @Test func `an EXISTS conjunct still pushes into a view`() throws {
    // `EXISTS (Q)` is TWO-valued — a decided non-empty test, never UNKNOWN —
    // so it stays freely pushable. `S` is non-empty, so the pushed `EXISTS` is
    // TRUE and every view row survives; the pushdown resolves it against the
    // caller's materialised cache exactly as before.
    try view().expect("SELECT Id FROM VW WHERE EXISTS (SELECT N FROM S)",
                      yields: [[1], [2]])
  }
}

// MARK: - Lazy subquery pushdown safety

/// A LAZY subquery (`EXISTS`/`IN`/quantified) is NEVER pushdown-`safe`: under
/// lazy materialisation its FIRST evaluation RUNS the inner query, which may
/// FAULT. A subquery conjunct beside a SEEKABLE conjunct must therefore NOT be
/// classified safe and left as a residual over a seeked (narrowed) scan: the
/// non-short-circuiting inner `AND` owes the throw for a row the seek skips, so
/// riding the subquery below the seek SUPPRESSES that throw.
///
/// `T` is SORTED on `Id`, so `Id < 0` is a seekable predicate over an EMPTY
/// run; `S.z` is zero, so `1 / z` FAULTS `.divide` the moment the subquery is
/// evaluated. With the subquery the LEFT conjunct (`subquery AND Id < 0`), the
/// non-short-circuiting `AND` evaluates the subquery FIRST for every scanned
/// row, so a correct run FAULTS. Pre-fix the subquery reported `safe`, so the
/// planner seeked on `Id < 0` (an empty run) and left the subquery a residual
/// over ZERO rows — never evaluating it, wrongly returning zero rows and hiding
/// the throw. Post-fix the subquery is NOT safe, the seek keeps it above the
/// scan, and the run FAULTS as the left-to-right `AND` owes.
struct LazySubqueryPushdownSafetyTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer], sorted: "Id") {
        Row(1)
        Row(2)
      }
      Relation("S", ["z": .integer]) {
        Row(0)
      }
      try View("VW", "SELECT Id FROM T", as: ["Id"])
    }
  }

  @Test func `an EXISTS conjunct is not seeked past a skipped row`() throws {
    // Pre-fix: the uncorrelated `EXISTS` reported `safe`, so it rode below the
    // `Id < 0` seek as a residual over the empty run and never evaluated —
    // returning zero rows, SUPPRESSING the `.divide` the leading conjunct owes.
    // Post-fix it is NOT safe, so the seek keeps it and the run faults.
    try fixture().expect(
        """
        SELECT Id FROM VW \
        WHERE EXISTS (SELECT 1 FROM S WHERE 1 / z = 0) AND Id < 0
        """,
        fails: .divide)
  }

  @Test func `an IN conjunct is not seeked past a skipped row`() throws {
    // The `IN (Q)` variant: `Id IN (SELECT 1 / z FROM S)` faults on the first
    // reach. Pre-fix the `.within` term was `safe` and rode below the empty
    // `Id < 0` seek, suppressing the throw; post-fix the run faults `.divide`.
    try fixture().expect(
        "SELECT Id FROM VW WHERE Id IN (SELECT 1 / z FROM S) AND Id < 0",
        fails: .divide)
  }

  @Test func `a quantified conjunct is not seeked past a skipped row`()
      throws {
    // The quantified `= ANY (Q)` variant: `Id = ANY (SELECT 1 / z FROM S)`
    // faults on the first reach. Pre-fix the `.quantified` term was `safe` and
    // rode below the empty `Id < 0` seek, suppressing the throw; post-fix the
    // run faults `.divide`.
    try fixture().expect(
        "SELECT Id FROM VW WHERE Id = ANY (SELECT 1 / z FROM S) AND Id < 0",
        fails: .divide)
  }

  @Test func `an EXISTS still drops rows behind a short-circuiting filter`()
      throws {
    // The safety change does NOT over-fault: with the SEEKABLE `Id < 0` the
    // LEFT conjunct, the non-short-circuiting `AND`'s Kleene evaluation returns
    // FALSE from the leading `Id < 0` for every row without reaching the
    // subquery, so the run yields zero rows rather than faulting — the subquery
    // stays genuinely unreached.
    try fixture().empty(
        """
        SELECT Id FROM VW \
        WHERE Id < 0 AND EXISTS (SELECT 1 FROM S WHERE 1 / z = 0)
        """)
  }
}

// MARK: - Correlated subquery own derived tables

/// A CORRELATED subquery with its OWN `WITH` item or derived table must AUGMENT
/// that own relation before executing its precompiled plan per outer row — the
/// same augmentation the uncorrelated `run`/`probe` paths perform — so the
/// derived/CTE relation binds during per-outer-row execution rather than
/// faulting `SQLError.relation` (or resolving to an unintended base relation).
struct CorrelatedOwnDerivationTests {
  /// An outer `T(Id)` alone — the correlated subqueries below carry their OWN
  /// inner derivation.
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
    }
  }

  @Test func `a correlated EXISTS binds its own derived table`() throws {
    // Pre-fix: the correlated `execute(plan, context)` ran the precompiled plan
    // under only the parent overlay, so the plan's `.scan("d")` for the derived
    // table `(SELECT 1 AS k) AS d` faulted `SQLError.relation("d")`. Post-fix
    // the execute path augments the subquery's own derived rows first, binding
    // `d`. The self-contained `d.k` is 1, correlated `= T.Id` in the subquery's
    // WHERE, so the EXISTS is TRUE only for the outer row `Id = 1`.
    try fixture().expect(
        """
        SELECT Id FROM T \
        WHERE EXISTS (SELECT 1 FROM (SELECT 1 AS k) AS d WHERE d.k = T.Id)
        """,
        yields: [[1]])
  }

  @Test func `a correlated scalar subquery binds its own derived table`()
      throws {
    // The scalar variant: `(SELECT d.k FROM (SELECT 1 AS k) AS d WHERE d.k =
    // T.Id)` derives `d.k` (a self-contained 1) and correlates it `= T.Id` per
    // outer row, collapsing to 1 for `Id = 1` and NULL (no matching row) for
    // the rest. Pre-fix it faulted `.relation("d")`; post-fix `d` binds a row.
    try fixture().expect(
        """
        SELECT (SELECT d.k FROM (SELECT 1 AS k) AS d WHERE d.k = T.Id) \
        FROM T
        """,
        yields: [[1], [nil], [nil]])
  }

  @Test func `a correlated IN binds its own derived table`() throws {
    // The `IN (Q)` variant: `Id IN (SELECT d.k FROM (SELECT 1 AS k) AS d WHERE
    // d.k = T.Id)` — the correlated subquery yields its self-contained `d.k`
    // (1) only when `d.k = T.Id`, so it is TRUE for `Id = 1` alone. Pre-fix the
    // per-row execute faulted `.relation("d")`; post-fix `d` binds each row.
    try fixture().expect(
        """
        SELECT Id FROM T \
        WHERE Id IN (SELECT d.k FROM (SELECT 1 AS k) AS d WHERE d.k = T.Id)
        """,
        yields: [[1]])
  }

  @Test func `a correlated EXISTS setop binds each arm's derived table`()
      throws {
    // The SET-OPERATION shape: the correlated `EXISTS` subquery is a `UNION
    // ALL` whose LEFT arm derives its own `d` and correlates it `d.k = T.Id`,
    // and whose RIGHT arm is a bare `SELECT 2`. Pre-fix the correlated
    // augment-and-execute augmented at the QUERY level, binding no arm-local
    // `d`, so the left arm's `.scan("d")` faulted `.relation("d")`; post-fix
    // it augments EACH ARM, so `d` binds per outer row. The right arm always
    // yields a row, so the EXISTS is TRUE for every outer row.
    try fixture().expect(
        """
        SELECT Id FROM T WHERE EXISTS ( \
        SELECT k FROM (SELECT 1 AS k) AS d WHERE d.k = T.Id \
        UNION ALL SELECT 2)
        """,
        yields: [[1], [2], [3]])
  }

  @Test func `a correlated IN setop keeps only the row its arm derives`()
      throws {
    // A DISCRIMINATING setop: `Id IN (SELECT d.k … WHERE d.k = T.Id UNION ALL
    // SELECT 9)`. The right arm contributes the constant 9 (never an `Id`), so
    // the membership turns ONLY on the left arm's per-row correlated
    // derivation — `d.k` (1) is in the column iff `T.Id = 1`. So only the outer
    // row `Id = 1` is kept, proving each arm augments its OWN `d` under the
    // per-row correlation rather than merely not faulting.
    try fixture().expect(
        """
        SELECT Id FROM T WHERE Id IN ( \
        SELECT d.k FROM (SELECT 1 AS k) AS d WHERE d.k = T.Id \
        UNION ALL SELECT 9)
        """,
        yields: [[1]])
  }
}

// MARK: - HAVING subquery reachability

/// A whole-result aggregate under a statically-false `WHERE` emits one empty
/// group; its `HAVING EXISTS/IN (Q)` is evaluated over that group at RUN and
/// can be TRUE (the subquery is row-independent), so the projection is
/// potentially reachable. `columns(of:validate:)` must NOT prune it as
/// unreachable — it validates the projection so the schema agrees with the run.
/// A subquery-free HAVING keeps the existing precise pruning.
struct HavingSubqueryReachabilityTests {
  @Test func `a HAVING subquery keeps the projection reachable to validate`()
      throws {
    // `WHERE 1 = 0` empties the group, but `HAVING EXISTS (SELECT 1)` is TRUE
    // at run, so the projection RUNS and its `1 / 0` raises `.divide`. The
    // schema path must not falsely advertise clean headers: with the HAVING
    // carrying a subquery it is not-definitely-empty, so validation reaches the
    // projection and surfaces the same `.divide` the run raises.
    let query = try parse(query:
        "SELECT 1 / 0 FROM T WHERE 1 = 0 HAVING EXISTS (SELECT V FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
  }

  @Test func `the HAVING-subquery projection fault matches the run`() throws {
    // The run raises `.divide` too — the group passes the true HAVING and the
    // projection's `1 / 0` evaluates — so schema and run agree.
    try fixture().expect(
        "SELECT 1 / 0 FROM T WHERE 1 = 0 HAVING EXISTS (SELECT V FROM S)",
        fails: .divide)
  }

  @Test func `a subquery-free HAVING under a false WHERE still prunes`()
      throws {
    // No subquery in the HAVING, so the precise empty-group fold applies: the
    // constant-false `HAVING 1 = 0` drops the lone empty group, leaving the
    // `1 / 0` projection unreachable — `columns` returns clean headers WITHOUT
    // faulting, exactly as before this fix.
    let query = try parse(query:
        "SELECT 1 / 0 FROM T WHERE 1 = 0 HAVING 1 = 0")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a subquery-free true HAVING still validates the projection`()
      throws {
    // A subquery-free HAVING that folds TRUE over the empty group keeps the
    // projection reachable exactly as before — so a `1 / 0` still faults
    // `.divide`, unchanged by the subquery carve-out.
    let query = try parse(query:
        "SELECT 1 / 0 FROM T WHERE 1 = 0 HAVING 1 = 1")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.divide) {
      try resolve()
    }
  }
}

// MARK: - Projection/sort subquery reachability

/// The empty-fold analog of the HAVING carve-out, extended to PROJECTION and
/// SORT expressions: a whole-result aggregate under a statically-false `WHERE`
/// emits one empty group, and a projection/sort expression that nests an
/// `EXISTS`/`IN (Q)` guard is potentially reachable — the subquery is
/// row-independent and may keep the group at RUN. `columns(of:validate:)` must
/// VALIDATE its subquery-guarded branches rather than prune them by the empty
/// fold (which treats the guard as UNKNOWN), so the schema agrees with the run.
/// A subquery-FREE guarded expression keeps the precise empty-fold pruning.
struct ProjectionSubqueryReachabilityTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer, "K": .integer]) {
        Row(1, 10)
        Row(2, 20)
      }
      Relation("S", ["V": .integer, "Flag": .integer]) {
        Row(10, 1)
      }
    }
  }

  @Test func `columns validates a subquery-guarded projection CASE`() throws {
    // `WHERE 1 = 0` empties the group; the `CASE` guard `EXISTS (SELECT V FROM
    // S)` folds UNKNOWN in the empty fold, which would prune the THEN arm — but
    // the subquery is TRUE at RUN, so the THEN arm's `1 / 0` runs. The empty
    // fold must NOT prune a subquery-guarded branch: validation reaches BOTH
    // arms and surfaces the `.divide` the run raises.
    let query = try parse(query:
        "SELECT CASE WHEN EXISTS (SELECT V FROM S) THEN 1 / 0 "
        + "ELSE COUNT(*) END FROM T WHERE 1 = 0")
    #expect(throws: SQLError.divide) {
      try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `the subquery-guarded projection fault matches the run`() throws {
    // The run raises `.divide` too — `EXISTS` is TRUE over the empty group, so
    // the THEN arm's `1 / 0` evaluates — so schema and run agree.
    try fixture().expect(
        "SELECT CASE WHEN EXISTS (SELECT V FROM S) THEN 1 / 0 "
        + "ELSE COUNT(*) END FROM T WHERE 1 = 0",
        fails: .divide)
  }

  @Test func `a subquery-free guarded projection CASE still prunes`() throws {
    // No subquery in the guard, so the precise empty-group fold applies: the
    // constant-false guard `1 = 0` selects the ELSE arm, leaving the `1 / 0`
    // THEN unreachable — `columns` returns clean headers WITHOUT faulting,
    // exactly as before this fix.
    let query = try parse(query:
        "SELECT CASE WHEN 1 = 0 THEN 1 / 0 ELSE COUNT(*) END "
        + "FROM T WHERE 1 = 0")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `columns validates a subquery-guarded sort CASE`() throws {
    // The ORDER BY sits BELOW the limit and evaluates over the empty group's
    // row unconditionally, so a subquery-guarded sort expression is validated
    // the same as a projection one: the `EXISTS`-guarded `1 / 0` sort key
    // surfaces `.divide`, not a pruned clean header.
    let query = try parse(query:
        "SELECT COUNT(*) FROM T WHERE 1 = 0 "
        + "ORDER BY CASE WHEN EXISTS (SELECT V FROM S) THEN 1 / 0 ELSE 1 END")
    #expect(throws: SQLError.divide) {
      try fixture().columns(of: query, validate: true)
    }
  }
}

// MARK: - FROM-less scalar subqueries

/// A FROM-less scalar `SELECT <expr-list>` whose projection nests an
/// UNCORRELATED `EXISTS`/`IN (subquery)` compiles, validates, and runs exactly
/// as the identical projection does with a FROM clause. The scalar lowering
/// (`projection.scalar`) is the ONE compile path that otherwise threads the
/// DEFAULT unsupported subquery map, so a subquery there faulted at compile
/// before the run-time cache was ever built; the map is now threaded through so
/// the term lowers, and `run`'s cache (built from `query.subqueries`, which
/// descends the projection) materialises the subquery the evaluator reads.
struct FromlessScalarSubqueryTests {
  @Test func `a scalar EXISTS yields 1 when the subquery is non-empty`()
      throws {
    // No outer FROM; the subquery's own `FROM T` is fine. `T` is non-empty, so
    // `EXISTS` is TRUE and the CASE yields 1.
    try fixture().expect(
        "SELECT CASE WHEN EXISTS (SELECT Id FROM T) THEN 1 ELSE 0 END",
        yields: [[1]])
  }

  @Test func `a scalar EXISTS yields 0 when the subquery is empty`() throws {
    // The subquery filters to zero rows, so `EXISTS` is FALSE and the CASE
    // yields 0 — the scalar projection runs against the single empty row.
    try fixture().expect(
        "SELECT CASE WHEN EXISTS (SELECT Id FROM T WHERE Id = 99) "
        + "THEN 1 ELSE 0 END",
        yields: [[0]])
  }

  @Test func `a scalar NOT EXISTS is the negation`() throws {
    // Over the empty subquery `NOT EXISTS` is TRUE (yields 1); over the
    // non-empty one it is FALSE (yields 0).
    try fixture().expect(
        "SELECT CASE WHEN NOT EXISTS (SELECT Id FROM T WHERE Id = 99) "
        + "THEN 1 ELSE 0 END",
        yields: [[1]])
    try fixture().expect(
        "SELECT CASE WHEN NOT EXISTS (SELECT Id FROM T) THEN 1 ELSE 0 END",
        yields: [[0]])
  }

  @Test func `a scalar IN over a subquery folds the membership test`() throws {
    // `S.V` is {10, 20, 99}; the scalar `10 IN (…)` is TRUE (yields 1) and
    // `77 IN (…)` is FALSE (yields 0) — the value-list `IN` core over the
    // subquery's single materialised column.
    try fixture().expect(
        "SELECT CASE WHEN 10 IN (SELECT V FROM S) THEN 1 ELSE 0 END",
        yields: [[1]])
    try fixture().expect(
        "SELECT CASE WHEN 77 IN (SELECT V FROM S) THEN 1 ELSE 0 END",
        yields: [[0]])
  }

  @Test func `a scalar IN over a two-column subquery faults with arity`()
      throws {
    // The `IN (Q)` single-column arity is decided from the subquery's compiled
    // WIDTH at compile — cursor-free — so a two-column subquery faults
    // `SQLError.arity` on the FROM-less path exactly as on the FROM'd one.
    try fixture().expect(
        "SELECT CASE WHEN 1 IN (SELECT Id, K FROM T) THEN 1 ELSE 0 END",
        fails: .arity(1, 2))
  }

  @Test func `columns validates a scalar EXISTS projection`() throws {
    // The schema path compiles and type-checks the same FROM-less scalar
    // projection, so `columns(of:validate:)` accepts exactly what the run does.
    let query = try parse(query:
        "SELECT CASE WHEN EXISTS (SELECT Id FROM T) THEN 1 ELSE 0 END")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad inner column in a scalar subquery faults the check`()
      throws {
    // A bad column inside the scalar projection's subquery faults the
    // validation exactly as a run would — the check reaches the subquery.
    let query = try parse(query:
        "SELECT CASE WHEN EXISTS (SELECT Missing FROM T) THEN 1 ELSE 0 END")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }

  @Test func `a plain scalar SELECT without a subquery is unaffected`() throws {
    // A FROM-less scalar select carrying NO subquery lowers exactly as before —
    // the threaded map is empty and the projection is a plain constant.
    try fixture().expect("SELECT 1 + 2", yields: [[3]])
  }
}

// MARK: - FROM-less scalar reserved-relation subqueries

/// A reserved `definition_schema.` relation named ONLY inside a subquery of a
/// FROM-less scalar `SELECT` still augments and runs — the relation-name
/// collector descends the projection's subqueries the same on this path, so the
/// store overlay is materialised before the subquery's width compile and run.
struct FromlessScalarReservedRelationTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
    }
  }

  @Test func `a scalar EXISTS over definition_schema.tables runs`() throws {
    // The reserved store relation is named ONLY inside the subquery of a
    // FROM-less scalar select; the descent still augments it, so the width
    // compile resolves and the run materialises it. It lists `T`, so `EXISTS`
    // is TRUE and the CASE yields 1.
    try fixture().expect(
        "SELECT CASE WHEN EXISTS "
        + "(SELECT table_name FROM definition_schema.tables) "
        + "THEN 1 ELSE 0 END",
        yields: [[1]])
  }

  @Test func `columns validates a scalar reserved-relation subquery`() throws {
    // The schema path shares the same augment, so `columns(of:validate:)`
    // resolves the subquery-only reserved relation exactly as the run does.
    let query = try parse(query:
        "SELECT CASE WHEN EXISTS "
        + "(SELECT table_name FROM definition_schema.tables) "
        + "THEN 1 ELSE 0 END")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }
}

// MARK: - Per-occurrence correlated plan cache

/// Two outer relations whose correlated key `k` sits at DIFFERENT ordinals —
/// `Outer1.k` at ordinal 0, `Outer2.k` at ordinal 1 — and one inner source
/// `Src`, so the SAME scalar subquery SQL `(SELECT m FROM Src WHERE m = k)` in
/// each arm of a `UNION ALL` compiles under a DIFFERENT outer layout: the left
/// arm binds `:__correlated_0_0`, the right `:__correlated_0_1`.
private func layouts() throws -> FixtureCatalog {
  try Catalog {
    Relation("Outer1", ["k": .integer, "a": .integer]) {
      Row(1, 100)
      Row(2, 200)
    }
    Relation("Outer2", ["b": .integer, "k": .integer]) {
      Row(300, 3)
      Row(400, 4)
    }
    Relation("Src", ["m": .integer]) {
      Row(1)
      Row(2)
      Row(3)
      Row(4)
    }
  }
}

/// Batch 7, Item 2: identical CORRELATED inner SQL in two set-operation arms
/// under DIFFERENT outer layouts must each execute the plan keyed to ITS OWN
/// correlation. Keying the plan cache by the occurrence `Subkey` alone
/// (scope + query + role) collapses the two arms — same `.caller` scope, same
/// AST, same `.scalar` role — so the right arm read the LEFT arm's plan (which
/// binds `:__correlated_0_0`) while its own row binds `:__correlated_0_1`,
/// yielding NULL. The `PlanKey` composes the correlation's parameter names into
/// the cache identity, so each arm finds its own plan.
struct CorrelatedPlanOccurrenceTests {
  @Test func `identical correlated SQL in two UNION ALL arms binds each`()
      throws {
    // `Outer1.k` at ordinal 0 → `:__correlated_0_0`; `Outer2.k` at ordinal 1 →
    // `:__correlated_0_1`. The scalar `(SELECT m FROM Src WHERE m = k)` returns
    // its lone matching `m` per outer row: the left arm over `k` {1, 2} yields
    // 1, 2; the right arm over `k` {3, 4} yields 3, 4. Pre-fix the right arm
    // read the left arm's plan and yielded NULL, NULL.
    try layouts().expect(
        """
        SELECT (SELECT m FROM Src WHERE m = k) FROM Outer1 \
        UNION ALL SELECT (SELECT m FROM Src WHERE m = k) FROM Outer2
        """,
        yields: [[1], [2], [3], [4]])
  }
}

/// A join `ON` in a correlated subquery whose equality references an ENCLOSING
/// column: an outer `T`, and a subquery joining `U` and `V` whose `ON`
/// correlates `V.x` to the outer `T.Id`.
///
/// `V.x` matches `T.Id` ∈ {1, 2}; `U` is a single row, so the correlated
/// `EXISTS (SELECT 1 FROM U JOIN V ON V.x = T.Id)` is TRUE exactly for those
/// outer rows. The uncorrelated parity `ON V.x = U.y` is a genuine
/// column = column equi-join key (`U.y` = 2 matches `V.x` = 2), so it is STILL
/// extracted as the hash-join match key and the join runs.
private func joined() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
      Row(4)
    }
    Relation("U", ["y": .integer]) {
      Row(2)
    }
    Relation("V", ["x": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

struct CorrelatedJoinOnTests {
  @Test func `a correlated join ON stays the residual filter`() throws {
    // `ON V.x = T.Id` lowers to `compare(.slot, .equal, .parameter)` — a
    // CORRELATED equality against the outer `T.Id`, not a column = column key.
    // Reading the key off the lowered term leaves it the residual `ON` filter,
    // evaluated per outer `T` row (`V.x = :outer_Id`). Pre-fix the fast path
    // re-resolved the ORIGINAL AST via `match(V.x, T.Id)`, which consults ONLY
    // the join prefix (`U`, `V`) and faulted `SQLError.column("Id")` on the
    // already-lowered outer column. `V.x` ∈ {1, 2} matches `T.Id` ∈ {1, 2}.
    try joined().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT 1 FROM U JOIN V ON V.x = T.Id)",
        yields: [[1], [2]])
  }

  @Test func `columns validates a correlated join ON`() throws {
    // The schema path must accept exactly what the run does — no prefix-only
    // re-resolution fault on the correlated outer column.
    let query = try parse(query:
        "SELECT Id FROM T WHERE EXISTS (SELECT 1 FROM U JOIN V ON V.x = T.Id)")
    let columns = try joined().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `an uncorrelated join ON still extracts its equi key`() throws {
    // PARITY: `ON V.x = U.y` is a genuine column = column equality lowering to
    // `compare(.slot, .equal, .slot)`, so it is STILL extracted as the
    // hash-join match key (see `EngineNonEquiJoinTests` for the plan-shape
    // guard). `U.y` = 2 matches `V.x` = 2, so the join is non-empty and the
    // UNCORRELATED `EXISTS` is TRUE for EVERY outer `T` row.
    try joined().expect(
        "SELECT Id FROM T WHERE EXISTS (SELECT 1 FROM U JOIN V ON V.x = U.y)",
        yields: [[1], [2], [3], [4]])
  }
}
