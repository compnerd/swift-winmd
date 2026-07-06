// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising the `CASE` expression: an integer `K` that is `NULL`
/// in one row (so a searched guard and a simple operand meet a NULL), and a
/// text `Name` to unify or clash result types against.
private func things() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer, "Name": .text]) {
      Row(1, 10, "a")
      Row(2, 20, "b")
      Row(3, nil, "c")
    }
  }
}

// MARK: - Parsing

/// Parses `text` and returns its `Select`, failing on any other shape.
private func parse(select text: String) throws -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

struct CaseParsingTests {
  @Test func `parses a searched CASE`() throws {
    let select = try parse(select: """
        SELECT CASE WHEN K = 10 THEN 1 ELSE 0 END FROM T
        """)
    let branch = When(when: .comparison(left: .column("K"), op: .equal,
                                        right: .literal(.integer(10))),
                      then: .literal(.integer(1)))
    let expression = Expression.case([branch], else: .literal(.integer(0)))
    #expect(select.projection == .expressions([Projected(expression: expression)]))
  }

  @Test func `normalises a simple CASE to a searched one`() throws {
    // `CASE K WHEN 10 THEN 1 …` becomes `CASE WHEN K = 10 THEN 1 …`.
    let select = try parse(select: """
        SELECT CASE K WHEN 10 THEN 1 WHEN 20 THEN 2 END FROM T
        """)
    let first = When(when: .comparison(left: .column("K"), op: .equal,
                                       right: .literal(.integer(10))),
                     then: .literal(.integer(1)))
    let second = When(when: .comparison(left: .column("K"), op: .equal,
                                        right: .literal(.integer(20))),
                      then: .literal(.integer(2)))
    let expression = Expression.case([first, second], else: nil)
    #expect(select.projection == .expressions([Projected(expression: expression)]))
  }

  @Test func `a CASE with no ELSE has a nil else`() throws {
    let select = try parse(select: "SELECT CASE WHEN K = 10 THEN 1 END FROM T")
    guard case let .expressions(items) = select.projection,
        case let .case(_, otherwise) = items[0].expression else {
      Issue.record("expected a CASE projection")
      return
    }
    #expect(otherwise == nil)
  }

  @Test func `rejects a CASE with no WHEN`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT CASE ELSE 0 END FROM T")
    }
  }

  @Test func `rejects an unterminated CASE`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT CASE WHEN K = 1 THEN 2 FROM T")
    }
  }
}

// MARK: - Evaluation

struct CaseEvaluationTests {
  @Test func `takes the first matching branch`() throws {
    // K = 10 (row 1) → 1; K = 20 (row 2) → 2; row 3 (K NULL) → the ELSE, 0.
    try things().expect("""
        SELECT CASE WHEN K = 10 THEN 1 WHEN K = 20 THEN 2 ELSE 0 END FROM T
        """, yields: [[1], [2], [0]])
  }

  @Test func `an earlier branch wins over a later one`() throws {
    // Both guards hold for K = 10, but the first wins.
    try things().expect("""
        SELECT CASE WHEN K = 10 THEN 100 WHEN K >= 10 THEN 200 ELSE 0 END
          FROM T WHERE Id = 1
        """, yields: [[100]])
  }

  @Test func `no matching branch and no ELSE yields NULL`() throws {
    // No K equals 99, and there is no ELSE, so every row yields NULL.
    try things().expect("SELECT CASE WHEN K = 99 THEN 1 END FROM T",
                        yields: [[nil], [nil], [nil]])
  }

  @Test func `an UNKNOWN guard skips its branch`() throws {
    // Row 3's K is NULL, so `K = 10` is UNKNOWN — the branch is skipped, not
    // taken — and the ELSE yields 9. Rows 1 and 2 take a matching branch.
    try things().expect("""
        SELECT CASE WHEN K = 10 THEN 1 WHEN K = 20 THEN 2 ELSE 9 END FROM T
        """, yields: [[1], [2], [9]])
  }

  @Test func `a simple CASE with a NULL operand takes the ELSE`() throws {
    // Row 3's K is NULL, so `K = 10`/`K = 20` are both UNKNOWN (a NULL operand
    // matches no WHEN value); the ELSE yields 0. Rows 1 and 2 match.
    try things().expect("""
        SELECT CASE K WHEN 10 THEN 1 WHEN 20 THEN 2 ELSE 0 END FROM T
        """, yields: [[1], [2], [0]])
  }

  @Test func `a CASE in a WHERE filters rows`() throws {
    // Keep rows whose CASE yields a truthy 1: K = 10 or K = 20.
    try things().expect("""
        SELECT Id FROM T
          WHERE CASE WHEN K = 10 THEN 1 WHEN K = 20 THEN 1 ELSE 0 END = 1
        """, yields: [[1], [2]])
  }

  @Test func `a mixed CASE coerces the integer branch to double`() throws {
    // The results unify to `.double`, so the schema advertises the column as
    // double; the executor must COERCE the selected branch's value to match.
    // Row 1 takes the integer THEN `1`, which widens to `.double(1.0)` rather
    // than staying `.integer(1)`; rows 2 and 3 take the double ELSE `2.5`.
    try things().expect(
        "SELECT CASE WHEN Id = 1 THEN 1 ELSE 2.5 END AS C FROM T",
        yields: [[1.0], [2.5], [2.5]])
  }

  @Test func `an all-integer CASE is not coerced`() throws {
    // The results unify to `.integer` — no widening — so each branch value is
    // yielded unchanged as an integer, never a spurious double.
    try things().expect(
        "SELECT CASE WHEN Id = 1 THEN 1 ELSE 2 END AS C FROM T",
        yields: [[1], [2], [2]])
  }

  @Test func `a no-match mixed CASE with no ELSE stays NULL`() throws {
    // A mixed integer/double CASE unifies to `.double`, but no K matches and
    // there is no ELSE, so every row yields NULL — coercion to `.double` leaves
    // NULL as NULL, never a double.
    try things().expect("""
        SELECT CASE WHEN K = 98 THEN 1 WHEN K = 99 THEN 2.5 END AS C FROM T
        """, yields: [[nil], [nil], [nil]])
  }
}

// MARK: - Type unification

struct CaseTypeTests {
  private func parse(_ text: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      Issue.record("expected a SELECT statement")
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }

  /// The single output column type of a one-column query's schema.
  private func type(of text: String) throws -> ValueType {
    let columns = try things().columns(of: parse(text))
    #expect(columns.count == 1)
    return columns[0].type
  }

  @Test func `like result types unify to that type`() throws {
    #expect(try type(of: "SELECT CASE WHEN K = 1 THEN K ELSE 0 END AS C FROM T")
                == .integer)
  }

  @Test func `mixed integer and double results widen to double`() throws {
    #expect(try type(of:
        "SELECT CASE WHEN K = 1 THEN 1 ELSE 2.5 END AS C FROM T") == .double)
  }

  @Test func `irreconcilable result types fault`() throws {
    // An integer result beside a text result cannot yield one column type.
    let query = try parse(
        "SELECT CASE WHEN K = 1 THEN 1 ELSE Name END AS C FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try things().columns(of: query)
    }
    #expect(throws:
        SQLError.operand("CASE results have irreconcilable types")) {
      try resolve()
    }
  }

  @Test func `running an irreconcilable CASE faults like the type check`()
      throws {
    // A row-dependent guard (`Id = 2`, matched by a fixture row) keeps both the
    // text `Name` branch and the integer `0` ELSE reachable — a constant guard
    // would drop an arm and mask the clash. Lowering unifies the reachable
    // result types just as the type check does, so the RUN faults with the same
    // error rather than leaking a text value at a column typed by the first
    // branch; `columns(of:)` faults identically, so the two paths AGREE.
    let text =
        "SELECT CASE WHEN Id = 2 THEN Name ELSE 0 END FROM T"
    try things().expect(text,
        fails: .operand("CASE results have irreconcilable types"))
    let resolve = { () throws -> Array<OutputColumn> in
      try things().columns(of: parse(text))
    }
    #expect(throws:
        SQLError.operand("CASE results have irreconcilable types")) {
      try resolve()
    }
  }
}

// MARK: - Branch reachability

/// The type check honours the executor's short-circuit: a `WHEN` whose guard is
/// statically constant-FALSE has an unreachable result the run never evaluates,
/// so its operands are not validated; once an earlier guard is constant-TRUE
/// every later branch and the `ELSE` are unreachable too.
struct CaseReachabilityTests {
  private func parse(_ text: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      Issue.record("expected a SELECT statement")
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }

  @Test func `a constant-false guard's bad result is unreachable`() throws {
    // `1 = 0` is statically false, so `Name + 1` (text arithmetic) is never
    // evaluated — the type check validates the reachable `ELSE 0` only and the
    // column types as its integer.
    let query = try parse(
        "SELECT CASE WHEN 1 = 0 THEN Name + 1 ELSE 0 END AS C FROM T")
    let columns = try things().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .integer)
  }

  @Test func `a constant-false-guarded bad branch runs`() throws {
    // The same query runs: the false guard skips `Name + 1`, so every row takes
    // the ELSE 0.
    try things().expect(
        "SELECT CASE WHEN 1 = 0 THEN Name + 1 ELSE 0 END FROM T",
        yields: [[0], [0], [0]])
  }

  @Test func `a reachable bad result still faults`() throws {
    // `Id = 1` is per-row, not statically false, so `Name + 1` IS reachable and
    // the text arithmetic must still fault.
    let query = try parse(
        "SELECT CASE WHEN Id = 1 THEN Name + 1 ELSE 0 END AS C FROM T")
    let resolve = { () throws -> Array<OutputColumn> in
      try things().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a constant-true guard makes a later bad branch unreachable`()
      throws {
    // `1 = 1` is statically true, so the first branch always wins and the later
    // `WHEN 1 = 1 THEN Name + 1` is unreachable — its operands are not
    // validated, so the type check passes and the column types as the first
    // result's integer.
    let query = try parse("""
        SELECT CASE WHEN 1 = 1 THEN 0 WHEN 1 = 1 THEN Name + 1 END AS C FROM T
        """)
    let columns = try things().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .integer)
  }

  @Test func `an earlier branch before a constant-true guard stays reachable`()
      throws {
    // `WHEN 1 = 1` is constant-TRUE, but it comes AFTER the row-dependent `WHEN
    // Id = 1`, which a row with `Id = 1` still matches — so that earlier branch
    // is REACHABLE and its `Name + 1` (text arithmetic) must still fault. The
    // constant-TRUE guard drops only the STRICTLY-LATER branches and the ELSE,
    // not the branches before it.
    let query = try parse("""
        SELECT CASE WHEN Id = 1 THEN Name + 1 WHEN 1 = 1 THEN 0 END AS C FROM T
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try things().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `an earlier branch clashing a constant-true guard's type reports`()
      throws {
    // The earlier reachable `THEN Name` (text) and the constant-TRUE guard's
    // `THEN 0` (integer) both shape the column, so their irreconcilable types
    // must be reported rather than the constant-TRUE branch's alone winning.
    let query = try parse("""
        SELECT CASE WHEN Id = 1 THEN Name WHEN 1 = 1 THEN 0 END AS C FROM T
        """)
    let resolve = { () throws -> Array<OutputColumn> in
      try things().columns(of: query, validate: true)
    }
    #expect(throws:
        SQLError.operand("CASE results have irreconcilable types")) {
      try resolve()
    }
  }
}

// MARK: - Empty-group folding

/// The schema validator folds the projection over the single empty group a
/// constant-false `WHERE` leaves (`Scope.empty`), exactly as a run does — so a
/// CASE there must COERCE its selected value to the unified result type, just
/// as the executor's `Row.conditional` does, or the folded value clashes the
/// advertised column type and a routine argument the run accepts is rejected.
struct CaseEmptyGroupTests {
  private func parse(_ text: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      Issue.record("expected a SELECT statement")
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }

  /// `CASE WHEN COUNT(*) = 0 THEN COUNT(*) ELSE 2.5 END` — a mixed CASE whose
  /// guard is NOT statically decidable (a `COUNT(*)` operand), so BOTH arms are
  /// reachable and the result unifies to `.double`. Over the empty group
  /// `COUNT(*)` is `0`, so the guard folds TRUE and the integer `COUNT(*)` arm
  /// is selected — folding to `0`, which must WIDEN to the unified `.double`.
  private func mixed() -> Expression {
    let guard0 = Predicate.comparison(left: .aggregate(.count, of: .star),
                                      op: .equal,
                                      right: .literal(.integer(0)))
    let branch = When(when: guard0,
                      then: .aggregate(.count, of: .star))
    return .case([branch], else: .literal(.double(2.5)))
  }

  @Test func `the empty-group fold coerces the selected value`() throws {
    // The whole-result group over no rows folds `COUNT(*)` to `0`; the CASE
    // unifies to `.double`, so the fold yields `.double(0.0)`, not
    // `.integer(0)` — matching the run, whose executor coerces the same value.
    #expect(try Scope([]).empty(mixed()) == .double(0.0))
  }

  @Test func `a DOUBLE routine accepts the coerced empty-group CASE`()
      throws {
    // `f(x DOUBLE) RETURNS DOUBLE AS x` over the mixed CASE: the constant-false
    // WHERE leaves one empty group, so `columns(of:)` folds the projection and
    // dispatches the routine over the folded argument. The coerced
    // `.double(0.0)` satisfies the DOUBLE parameter — schema validation
    // SUCCEEDS, as the run does; a raw `.integer(0)` would fault
    // `SQLError.argument`.
    let f = Function(parameters: [Function.Parameter(name: "x", type: .double)],
                     returns: .double, body: .column("x"))
    let routines = try Routines().registering("f", f)
    let query = try parse("""
        SELECT f(CASE WHEN COUNT(*) = 0 THEN COUNT(*) ELSE 2.5 END) AS C
          FROM T WHERE 1 = 0
        """)
    let columns = try things().columns(of: query, routines: routines,
                                       validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .double)
  }
}
