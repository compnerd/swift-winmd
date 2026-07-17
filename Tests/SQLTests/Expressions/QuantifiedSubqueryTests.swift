// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// Two relations exercising the uncorrelated quantified `op {ANY|SOME|ALL} (Q)`
/// comparisons: an outer `T` with an integer key `K` that is `NULL` in one row
/// (so the three-valued corners are reachable), and an inner `S` whose column
/// `V` holds a `NULL` (so a quantified comparison sees a NULL element) and a
/// `Flag` used to filter the inner query to empty or to non-empty. `N` holds a
/// single NULL-bearing column for the NULL-element corners.
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
    // A relation whose single column holds a NULL, for the NULL-element
    // corners — `V` is `{2, NULL}`.
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

// MARK: - Parsing

struct QuantifiedSubqueryParsingTests {
  @Test func `parses = ANY over a subquery`() throws {
    let select =
        try parse(select: "SELECT Id FROM T WHERE K = ANY (SELECT V FROM S)")
    let inner = try parse(query: "SELECT V FROM S")
    #expect(select.predicate
                == .quantified(.column("K"), .equal, .any, inner))
  }

  @Test func `parses <> ALL over a subquery`() throws {
    let select =
        try parse(select: "SELECT Id FROM T WHERE K <> ALL (SELECT V FROM S)")
    let inner = try parse(query: "SELECT V FROM S")
    #expect(select.predicate
                == .quantified(.column("K"), .unequal, .all, inner))
  }

  @Test func `parses each comparison operator with a quantifier`() throws {
    let inner = try parse(query: "SELECT V FROM S")
    let cases: [(String, Comparison)] = [
      ("<", .lt), ("<=", .leq), (">", .gt), (">=", .geq),
    ]
    for (spelling, op) in cases {
      let select = try parse(
          select: "SELECT Id FROM T WHERE K \(spelling) ANY (SELECT V FROM S)")
      #expect(select.predicate == .quantified(.column("K"), op, .any, inner))
    }
  }

  @Test func `SOME parses identically to ANY`() throws {
    // `SOME` is a synonym for `ANY`, normalised to `.any` at parse time, so the
    // two spellings produce the SAME AST.
    let some =
        try parse(select: "SELECT Id FROM T WHERE K < SOME (SELECT V FROM S)")
    let any =
        try parse(select: "SELECT Id FROM T WHERE K < ANY (SELECT V FROM S)")
    #expect(some.predicate == any.predicate)
    let inner = try parse(query: "SELECT V FROM S")
    #expect(some.predicate == .quantified(.column("K"), .lt, .any, inner))
  }

  @Test func `parses a quantified comparison over a UNION subquery`() throws {
    // A subquery is a full `query`, so it may itself be a `UNION`.
    let text = "SELECT Id FROM T WHERE K > ALL "
        + "(SELECT V FROM S UNION SELECT V FROM N)"
    let select = try parse(select: text)
    let inner = try parse(query: "SELECT V FROM S UNION SELECT V FROM N")
    #expect(select.predicate
                == .quantified(.column("K"), .gt, .all, inner))
  }
}

// MARK: - = ANY / <> ALL equivalence to IN / NOT IN

struct QuantifiedMembershipEquivalenceTests {
  @Test func `= ANY is IN`() throws {
    // `x = ANY (Q)` is exactly `x IN (Q)` — the same rows.
    try fixture().expect(
        "SELECT Id FROM T WHERE K = ANY (SELECT V FROM S WHERE Flag = 1)",
        equals: "SELECT Id FROM T WHERE K IN (SELECT V FROM S WHERE Flag = 1)")
    try fixture().expect(
        "SELECT Id FROM T WHERE K = ANY (SELECT V FROM S WHERE Flag = 1)",
        yields: [[1], [2]])
  }

  @Test func `<> ALL is NOT IN`() throws {
    // `x <> ALL (Q)` is exactly `x NOT IN (Q)` — the same rows.
    try fixture().expect(
        "SELECT Id FROM T WHERE K <> ALL (SELECT V FROM S WHERE Flag = 1)",
        equals:
            "SELECT Id FROM T WHERE K NOT IN (SELECT V FROM S WHERE Flag = 1)")
    // S filtered to Flag = 1 is {10, 20} with no NULL, so `<> ALL` is the plain
    // complement over non-NULL K: row 4 (30). Row 3 (K NULL) is UNKNOWN.
    try fixture().expect(
        "SELECT Id FROM T WHERE K <> ALL (SELECT V FROM S WHERE Flag = 1)",
        yields: [[4]])
  }
}

// MARK: - Ordering-operator quantifier semantics

struct QuantifiedOrderingTests {
  @Test func `< ANY holds for a value below the maximum`() throws {
    // S filtered to Flag = 1 is {10, 20}; `K < ANY` is TRUE when K is below
    // SOME value, i.e. below the maximum 20. K = 10 qualifies (10 < 20); K = 20
    // and 30 do not; K NULL is UNKNOWN.
    try fixture().expect(
        "SELECT Id FROM T WHERE K < ANY (SELECT V FROM S WHERE Flag = 1)",
        yields: [[1]])
  }

  @Test func `<= ANY holds for a value at or below the maximum`() throws {
    // `K <= ANY {10, 20}` is TRUE at or below the maximum 20: K = 10 and 20.
    try fixture().expect(
        "SELECT Id FROM T WHERE K <= ANY (SELECT V FROM S WHERE Flag = 1)",
        yields: [[1], [2]])
  }

  @Test func `> ALL holds for a value above the maximum`() throws {
    // `K > ALL {10, 20}` is TRUE only above EVERY value, i.e. above the maximum
    // 20: K = 30 qualifies; K = 10 and 20 do not; K NULL is UNKNOWN.
    try fixture().expect(
        "SELECT Id FROM T WHERE K > ALL (SELECT V FROM S WHERE Flag = 1)",
        yields: [[4]])
  }

  @Test func `>= ALL holds for a value at or above the maximum`() throws {
    // `K >= ALL {10, 20}` is TRUE at or above the maximum 20: K = 20 and 30.
    try fixture().expect(
        "SELECT Id FROM T WHERE K >= ALL (SELECT V FROM S WHERE Flag = 1)",
        yields: [[2], [4]])
  }
}

// MARK: - Empty-subquery identities

struct QuantifiedEmptyTests {
  @Test func `op ANY over an empty subquery is FALSE`() throws {
    // `x > ANY (empty)` has no witness, so it is FALSE for every row — no row
    // survives (the Kleene-OR identity FALSE).
    try fixture().expect(
        "SELECT Id FROM T WHERE K > ANY (SELECT V FROM S WHERE Flag = 9)",
        yields: [])
  }

  @Test func `op ALL over an empty subquery is TRUE`() throws {
    // `x > ALL (empty)` is vacuously TRUE for every row — every row survives,
    // including row 3 whose K is NULL, since no comparison is ever made (the
    // Kleene-AND identity TRUE).
    try fixture().expect(
        "SELECT Id FROM T WHERE K > ALL (SELECT V FROM S WHERE Flag = 9)",
        yields: [[1], [2], [3], [4]])
  }
}

// MARK: - The NULL corners

struct QuantifiedNullCornerTests {
  @Test func `a NULL operand makes a quantified comparison UNKNOWN`() throws {
    // Row 3's K is NULL, so `NULL < ANY (…)` and `NULL > ALL (…)` are UNKNOWN
    // (every comparison against NULL is UNKNOWN) — the row is dropped by both.
    try fixture().empty(
        "SELECT Id FROM T WHERE K < ANY (SELECT V FROM S WHERE Flag = 1) "
        + "AND Id = 3")
    try fixture().empty(
        "SELECT Id FROM T WHERE K > ALL (SELECT V FROM S WHERE Flag = 1) "
        + "AND Id = 3")
  }

  @Test func `ANY over a NULL element still finds a definite witness`() throws {
    // N.V is {2, NULL}; `10 > ANY (SELECT V FROM N)` finds the definite
    // `10 > 2` TRUE — a TRUE witness dominates the UNKNOWN from the NULL
    // element — so the row survives.
    try fixture().expect(
        "SELECT Id FROM T WHERE 10 > ANY (SELECT V FROM N) AND Id = 1",
        yields: [[1]])
  }

  @Test func `ANY over a NULL element with no witness is UNKNOWN`() throws {
    // `1 > ANY (SELECT V FROM N)` is `1 > 2 OR 1 > NULL` — FALSE OR UNKNOWN —
    // which is UNKNOWN, not FALSE: the row is not admitted (the same NULL-OR
    // corner the value-list `IN` has).
    try fixture().empty(
        "SELECT Id FROM T WHERE 1 > ANY (SELECT V FROM N) AND Id = 1")
  }

  @Test func `ALL over a NULL element with no false is UNKNOWN`() throws {
    // `10 > ALL (SELECT V FROM N)` is `10 > 2 AND 10 > NULL` — TRUE AND UNKNOWN
    // — which is UNKNOWN, not TRUE: no definite FALSE settles it, so the NULL
    // leaves it undecided and the row is dropped (the `NOT IN (…NULL…)` trap
    // generalised to `> ALL`).
    try fixture().empty(
        "SELECT Id FROM T WHERE 10 > ALL (SELECT V FROM N) AND Id = 1")
  }

  @Test func `ALL over a NULL element with a definite false is FALSE`() throws {
    // `1 > ALL (SELECT V FROM N)` is `1 > 2 AND 1 > NULL` — a definite FALSE
    // (`1 > 2`) dominates the UNKNOWN under Kleene AND — so it is FALSE and the
    // row is dropped, exactly as a run does.
    try fixture().empty(
        "SELECT Id FROM T WHERE 1 > ALL (SELECT V FROM N) AND Id = 1")
  }
}

// MARK: - Arity

struct QuantifiedArityTests {
  @Test func `a two-column quantified subquery faults at compile`() throws {
    // A quantified comparison requires its subquery project exactly ONE column;
    // a two-column subquery is `SQLError.arity`, checked from the compiled
    // width, so it faults even though S has rows — reusing IN's arity check.
    try fixture().expect(
        "SELECT Id FROM T WHERE K < ANY (SELECT V, Flag FROM S)",
        fails: .arity(1, 2))
  }

  @Test func `a two-column quantified subquery faults the schema check too`()
      throws {
    // The schema path enforces the SAME single-column arity as the run.
    let query = try parse(
        query: "SELECT Id FROM T WHERE K < ANY (SELECT V, Flag FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.arity(1, 2)) {
      try resolve()
    }
  }
}

// MARK: - Type checking

struct QuantifiedTypeCheckingTests {
  @Test func `columns validates a quantified query matching the run`() throws {
    let query = try parse(
        query: "SELECT Id FROM T WHERE K < ANY (SELECT V FROM S)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `a bad inner column faults the schema check`() throws {
    // The inner query is type-checked too, so an unknown column inside it
    // faults validation exactly as a run would reject it.
    let query = try parse(
        query: "SELECT Id FROM T WHERE K > ALL (SELECT Missing FROM S)")
    let resolve = { () throws -> Array<OutputColumn> in
      try fixture().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.column("Missing")) {
      try resolve()
    }
  }
}

// MARK: - Correlated quantified execution

/// An outer relation and an inner relation sharing a key `k`, so a quantified
/// subquery referencing an outer column is CORRELATED: its lone column depends
/// on the enclosing row, forcing the per-outer-row re-execution the discovered
/// correlation threads (rather than a once-memoised uncorrelated run).
private func correlated() throws -> FixtureCatalog {
  try Catalog {
    Relation("Toll", ["x": .integer, "k": .integer]) {
      Row(10, 1)
      Row(20, 2)
      Row(99, 3)
    }
    Relation("Inn", ["x": .integer, "k": .integer]) {
      Row(10, 1)
      Row(20, 2)
      Row(30, 2)
    }
  }
}

struct CorrelatedQuantifiedTests {
  @Test func `a correlated = ANY binds the outer key per row`() throws {
    // `Toll.x = ANY (SELECT i.x FROM Inn i WHERE i.k = Toll.k)` correlates to
    // `Toll.k`, so the inner column is re-materialised per outer row: row
    // (10, 1) → {10} (10 = ANY → TRUE), row (20, 2) → {20, 30} (TRUE), row
    // (99, 3) → {} (FALSE). A `[:]`-correlation eval would re-run the inner
    // query WITHOUT the outer scope and fail to bind `Toll.k`.
    let sql = """
        SELECT x FROM Toll \
        WHERE x = ANY (SELECT i.x FROM Inn i WHERE i.k = Toll.k) \
        ORDER BY x
        """
    let columns = try correlated().columns(of: parse(query: sql),
                                           validate: true)
    #expect(columns.count == 1)
    try correlated().expect(sql, yields: [[10], [20]])
  }

  @Test func `a correlated <> ALL keeps the row with no inner match`() throws {
    // `<> ALL` over the per-row inner column: row (10, 1) → 10 <> ALL {10} is
    // FALSE, row (20, 2) → 20 <> ALL {20, 30} is FALSE, row (99, 3) → 99 <> ALL
    // {} is TRUE (an empty ALL is vacuously TRUE). Only row 99 survives.
    let sql = """
        SELECT x FROM Toll \
        WHERE x <> ALL (SELECT i.x FROM Inn i WHERE i.k = Toll.k) \
        ORDER BY x
        """
    let columns = try correlated().columns(of: parse(query: sql),
                                           validate: true)
    #expect(columns.count == 1)
    try correlated().expect(sql, yields: [[99]])
  }

  @Test func `a correlated > ALL exceeds the per-row inner column`() throws {
    // `> ALL` over the per-row inner column: row (10, 1) → 10 > ALL {10} FALSE,
    // row (20, 2) → 20 > ALL {20, 30} FALSE, row (99, 3) → 99 > ALL {} TRUE
    // (empty ALL). Only row 99 exceeds its (empty) inner column.
    let sql = """
        SELECT x FROM Toll \
        WHERE x > ALL (SELECT i.x FROM Inn i WHERE i.k = Toll.k) \
        ORDER BY x
        """
    try correlated().expect(sql, yields: [[99]])
  }

  @Test func `an uncorrelated quantified still memoises once`() throws {
    // With NO outer reference the quantified subquery is uncorrelated — empty
    // correlation — so it materialises its column ONCE (memoised), folded per
    // outer row: `Inn.x` ∈ {10, 20, 30}, so `Toll.x = ANY {10, 20, 30}` keeps
    // rows 10 and 20 (99 is absent).
    let sql = """
        SELECT x FROM Toll \
        WHERE x = ANY (SELECT i.x FROM Inn i) ORDER BY x
        """
    let columns = try correlated().columns(of: parse(query: sql),
                                           validate: true)
    #expect(columns.count == 1)
    try correlated().expect(sql, yields: [[10], [20]])
  }
}
