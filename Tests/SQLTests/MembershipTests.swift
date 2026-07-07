// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising the `IN` value-list predicate: an integer key `K` that
/// is `NULL` in some rows, so the three-valued corners (a NULL operand, a NULL
/// element) are reachable, and a text `Name` for a cross-kind element (which
/// the run silently non-matches) and for reachable text arithmetic.
private func members() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer, "Name": .text]) {
      Row(1, 10, "a")
      Row(2, 20, "b")
      Row(3, nil, "c")
      Row(4, 30, "d")
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

struct MembershipParsingTests {
  @Test func `parses an IN value list`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K IN (1, 2, 3)")
    #expect(select.predicate
                == .membership(.column("K"),
                               [.literal(.integer(1)), .literal(.integer(2)),
                                .literal(.integer(3))], negated: false))
  }

  @Test func `parses a NOT IN value list`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K NOT IN (1, 2)")
    #expect(select.predicate
                == .membership(.column("K"),
                               [.literal(.integer(1)), .literal(.integer(2))],
                               negated: true))
  }

  @Test func `parses a single-element IN list`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K IN (7)")
    #expect(select.predicate
                == .membership(.column("K"), [.literal(.integer(7))],
                               negated: false))
  }

  @Test func `parses IN over an expression operand`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE K + 1 IN (11, 21)")
    let operand = Expression.binary(.add, .column("K"), .literal(.integer(1)))
    #expect(select.predicate
                == .membership(operand,
                               [.literal(.integer(11)), .literal(.integer(21))],
                               negated: false))
  }

  @Test func `rejects an empty IN list`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE K IN ()")
    }
  }
}

// MARK: - Evaluation

struct MembershipEvaluationTests {
  @Test func `IN admits a matching value`() throws {
    try members().expect("SELECT Id FROM T WHERE K IN (10, 30)",
                         yields: [[1], [4]])
  }

  @Test func `IN rejects a non-matching value`() throws {
    try members().expect("SELECT Id FROM T WHERE K IN (99)", yields: [])
  }

  @Test func `NOT IN admits the complement`() throws {
    // Rows with a non-NULL K not in the list; row 3 (K NULL) is UNKNOWN and
    // dropped.
    try members().expect("SELECT Id FROM T WHERE K NOT IN (10, 30)",
                         yields: [[2]])
  }

  @Test func `a NULL operand makes IN UNKNOWN`() throws {
    // Row 3's K is NULL, so `NULL IN (10, 20)` is UNKNOWN, not FALSE — the row
    // is dropped rather than admitted, and would not be admitted by NOT IN
    // either.
    try members().expect("SELECT Id FROM T WHERE K IN (10, 20)",
                         yields: [[1], [2]])
    try members().expect("SELECT Id FROM T WHERE K NOT IN (10, 20)",
                         yields: [[4]])
  }

  @Test func `a NULL element leaves an unmatched IN UNKNOWN`() throws {
    // Row 3 has K = NULL, so its `K` cell is the NULL element. Over that row,
    // `20 IN (99, K)` is `20 = 99 OR 20 = NULL` — FALSE OR UNKNOWN — which is
    // UNKNOWN, not FALSE: the row is not admitted. `NOT IN` negates that
    // UNKNOWN to UNKNOWN, so it is never TRUE either — the row is dropped both
    // ways.
    try members().empty("SELECT Id FROM T WHERE 20 IN (99, K) AND Id = 3")
    try members().empty("SELECT Id FROM T WHERE 20 NOT IN (99, K) AND Id = 3")
  }

  @Test func `IN folds like an OR of equalities`() throws {
    try members().expect("SELECT Id FROM T WHERE K IN (10, 20, 30)",
                         equals: "SELECT Id FROM T WHERE K = 10 OR K = 20 OR K = 30")
  }
}

// MARK: - Type checking

struct MembershipTypeTests {
  /// Parses `text` to a query, failing on any other statement.
  private func parse(_ text: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      Issue.record("expected a SELECT statement")
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }

  @Test func `a cross-kind element does not fault the schema check`() throws {
    // `K` is an integer column and `'x'` is a text element, but the schema
    // check does NOT reject it: the lowered `K = 'x'` comparison yields FALSE
    // at runtime via `Row.matches` without faulting, so the row still runs and
    // may match the like-kind `10` element. The check must accept what the run
    // accepts — so `K IN (10, 'x')` types exactly as `K IN (10)`.
    let mixed = try parse("SELECT Id FROM T WHERE K IN (10, 'x')")
    let plain = try parse("SELECT Id FROM T WHERE K IN (10)")
    let columns = try members().columns(of: mixed)
    #expect(columns == (try members().columns(of: plain)))
    // The run keeps the `K = 10` row: the text arm silently non-matches.
    try members().expect("SELECT Id FROM T WHERE K IN (10, 'x')",
                         yields: [[1]])
  }

  @Test func `a numeric element of the other numeric kind is admitted`() throws {
    // An integer operand and a double element are comparable (both numeric), so
    // the schema check passes and the run matches by magnitude.
    let query = try parse("SELECT Id FROM T WHERE K IN (10.0, 20.0)")
    _ = try members().columns(of: query)
    try members().expect("SELECT Id FROM T WHERE K IN (10.0, 20.0)",
                         yields: [[1], [2]])
  }

  @Test func `a definite match short-circuits a later bad element`() throws {
    // `1 IN (1, Name + 1)` lowers to `1 = 1 OR 1 = Name + 1`; the first
    // disjunct is a definite constant match, so the OR-chain short-circuits and
    // `Name + 1` (text arithmetic) is unreachable — the type check does not
    // validate it, and the query runs (matching every row).
    let query = try parse("SELECT Id FROM T WHERE 1 IN (1, Name + 1)")
    _ = try members().columns(of: query, validate: true)
    try members().expect("SELECT Id FROM T WHERE 1 IN (1, Name + 1)",
                         yields: [[1], [2], [3], [4]])
  }

  @Test func `a constant expression element prunes a later unreachable element`() throws {
    // `1 IN (1 + 0, Name + 1)` lowers to `1 = 1 + 0 OR 1 = Name + 1`; the first
    // element is a ROW-INDEPENDENT constant expression (not a bare literal)
    // that folds to `1`, a definite match, so the OR-chain short-circuits and
    // `Name + 1` (text arithmetic) is unreachable — the type check must fold
    // the constant element and stop rather than continuing into it, and the
    // run, matching `1 = 1 + 0` first, keeps every row.
    let query = try parse("SELECT Id FROM T WHERE 1 IN (1 + 0, Name + 1)")
    _ = try members().columns(of: query, validate: true)
    try members().expect("SELECT Id FROM T WHERE 1 IN (1 + 0, Name + 1)",
                         yields: [[1], [2], [3], [4]])
  }

  @Test func `a non-matching constant expression element keeps a later element reachable`() throws {
    // `2 IN (1 + 0, Name + 1)` folds the first element to `1`, which `2` does
    // NOT match, so `Name + 1` stays reachable — the pruning is PRECISE, not
    // over-eager — and its text arithmetic must still fault the type check,
    // matching the run, which would evaluate `2 = Name + 1` and fault.
    let query = try parse("SELECT Id FROM T WHERE 2 IN (1 + 0, Name + 1)")
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `no definite match leaves a bad element reachable`() throws {
    // `2 IN (1, Name + 1)` never definitely matches `1`, so `Name + 1` is
    // reachable and its text arithmetic must still fault the type check.
    let query = try parse("SELECT Id FROM T WHERE 2 IN (1, Name + 1)")
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a constant routine call element prunes a later unreachable element`() throws {
    // `1 IN (BITAND(1, 1), Name + 1)` lowers to `1 = BITAND(1, 1) OR 1 = Name
    // + 1`; the first element is a ROW-INDEPENDENT scalar CALL — every argument
    // folds constant — so it folds to the routine's value `1`, a definite
    // match, and the OR-chain short-circuits before `Name + 1` (text
    // arithmetic). The type check must fold the call through the SAME routine
    // the run invokes and stop, and the run, matching `1 = BITAND(1, 1)` first,
    // keeps every row. (`BITAND` is a standard prelude routine, seeded like the
    // existing constant-expression tests.)
    let text = "SELECT Id FROM T WHERE 1 IN (BITAND(1, 1), Name + 1)"
    let query = try parse(text)
    _ = try members().columns(of: query, validate: true)
    try members().expect(text, yields: [[1], [2], [3], [4]])
  }

  @Test func `a non-deterministic routine call is not folded when pruning`() throws {
    // `1 IN (probe(), Name + 1)` lowers to `1 = probe() OR 1 = Name + 1`.
    // `probe` is registered NOT DETERMINISTIC (ISO's default for a host
    // closure), so the schema check must NOT execute it to fold the first
    // element — a non-deterministic routine could return one value here and
    // another when the run reaches the call, wrongly pruning a later element.
    // With the call unfolded, `Name + 1` stays reachable and its text
    // arithmetic faults the type check, matching the run's guarantee. (`probe`
    // returns `1`, which WOULD match `1` and short-circuit had it been folded —
    // proving the gate keys off the characteristic, not the value.)
    let routines = try Routines()
        .registering("probe", returns: .integer, deterministic: false) { _ in
          .integer(1)
        }
    let text = "SELECT Id FROM T WHERE 1 IN (probe(), Name + 1)"
    let query = try parse(text)
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, routines: routines, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a deterministic routine call is folded when pruning`() throws {
    // The same query with `probe` declared DETERMINISTIC (ISO
    // `DETERMINISTIC`): the schema check MAY fold `probe()` to `1`, a definite
    // match, so the OR-chain short-circuits before `Name + 1` and its text
    // arithmetic is never reached — `columns(of:)` succeeds. The ONLY change
    // from the prior test is the `deterministic` flag, so the gate keys off it.
    let routines = try Routines()
        .registering("probe", returns: .integer, deterministic: true) { _ in
          .integer(1)
        }
    let text = "SELECT Id FROM T WHERE 1 IN (probe(), Name + 1)"
    let query = try parse(text)
    _ = try members().columns(of: query, routines: routines, validate: true)
    try members().expect(text, yields: [[1], [2], [3], [4]],
                         routines: routines)
  }

  @Test func `a non-matching constant routine call element keeps a later element reachable`() throws {
    // `2 IN (BITAND(1, 1), Name + 1)` folds the first element through the
    // routine to `1`, which `2` does NOT match, so `Name + 1` stays reachable
    // — the routine fold is PRECISE, not over-eager — and its text arithmetic
    // must still fault the type check, matching the run.
    let text = "SELECT Id FROM T WHERE 2 IN (BITAND(1, 1), Name + 1)"
    let query = try parse(text)
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a constant CASE element prunes a later unreachable element`() throws {
    // `1 IN (CASE WHEN 1 = 1 THEN 1 ELSE Name + 1 END, Name + 1)` lowers to `1
    // = <CASE> OR 1 = Name + 1`; the CASE is ROW-INDEPENDENT — its guard `1 =
    // 1` folds TRUE, so it folds to its branch result `1` (the row-dependent
    // ELSE `Name + 1` is unreachable and never folded) — a definite match, so
    // the OR-chain short-circuits and the trailing `Name + 1` (text arithmetic)
    // is unreachable. The type check must fold the constant CASE and stop, and
    // the run, matching `1 = <CASE>` first, keeps every row.
    let text = "SELECT Id FROM T WHERE 1 IN "
        + "(CASE WHEN 1 = 1 THEN 1 ELSE Name + 1 END, Name + 1)"
    let query = try parse(text)
    _ = try members().columns(of: query, validate: true)
    try members().expect(text, yields: [[1], [2], [3], [4]])
  }

  @Test func `a non-matching constant CASE element keeps a later element reachable`() throws {
    // `2 IN (CASE WHEN 1 = 1 THEN 1 ELSE Name + 1 END, Name + 1)` folds the
    // CASE to `1`, which `2` does NOT match, so the trailing `Name + 1` stays
    // reachable — the CASE fold is PRECISE, not over-eager — and its text
    // arithmetic must still fault the type check, matching the run.
    let text = "SELECT Id FROM T WHERE 2 IN "
        + "(CASE WHEN 1 = 1 THEN 1 ELSE Name + 1 END, Name + 1)"
    let query = try parse(text)
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a row-dependent CASE guard leaves a later element reachable`() throws {
    // `1 IN (CASE WHEN Id = 2 THEN 1 ELSE 0 END, Name + 1)` cannot fold the
    // CASE: its guard `Id = 2` is ROW-DEPENDENT, so `constant` yields `nil` —
    // the CASE is not a definite match (the run cannot guarantee it equals `1`
    // on every row) and the trailing `Name + 1` (text arithmetic) stays
    // reachable, so its text arithmetic must still fault the type check.
    let text = "SELECT Id FROM T WHERE 1 IN "
        + "(CASE WHEN Id = 2 THEN 1 ELSE 0 END, Name + 1)"
    let query = try parse(text)
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a constant-expression CASE guard prunes a later unreachable element`() throws {
    // `1 IN (CASE WHEN 1 + 0 = 1 THEN 1 END, Name + 1)` lowers to `1 = <CASE>
    // OR 1 = Name + 1`; the CASE guard `1 + 0 = 1` is ROW-INDEPENDENT but NOT
    // bare literals — its left operand is arithmetic. Folding the guard through
    // `constant(_ expression:)` decides it TRUE, so the CASE folds to `1`, a
    // definite match, and the OR-chain short-circuits before `Name + 1` (text
    // arithmetic). The type check must fold the constant guard and stop, and
    // the run, matching `1 = <CASE>` first, keeps every row.
    let text = "SELECT Id FROM T WHERE 1 IN "
        + "(CASE WHEN 1 + 0 = 1 THEN 1 END, Name + 1)"
    let query = try parse(text)
    _ = try members().columns(of: query, validate: true)
    try members().expect(text, yields: [[1], [2], [3], [4]])
  }

  @Test func `a non-matching constant-expression CASE guard keeps a later element reachable`() throws {
    // `1 IN (CASE WHEN 1 + 0 = 2 THEN 1 END, Name + 1)`: the guard `1 + 0 = 2`
    // folds FALSE and the CASE has no ELSE, so it yields NULL — `1 = NULL` is
    // UNKNOWN, NOT a definite match — so the trailing `Name + 1` (text
    // arithmetic) stays reachable and must still fault the type check, matching
    // the run. The pruning is PRECISE: a folded-FALSE guard prunes nothing.
    let text = "SELECT Id FROM T WHERE 1 IN "
        + "(CASE WHEN 1 + 0 = 2 THEN 1 END, Name + 1)"
    let query = try parse(text)
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a non-deterministic CASE guard leaves a later element reachable`() throws {
    // `1 IN (CASE WHEN probe() = 1 THEN 1 END, Name + 1)` with `probe`
    // registered NOT DETERMINISTIC: the guard's `probe()` operand does not fold
    // through `constant(_ expression:)` (the determinism gate), so the guard is
    // `nil`, the CASE is `nil`, and the trailing `Name + 1` (text arithmetic)
    // stays reachable and must still fault the type check. The determinism gate
    // flows through the comparison fold — a non-deterministic operand keeps the
    // guard undecided rather than deciding a match the run might not make.
    let routines = try Routines()
        .registering("probe", returns: .integer, deterministic: false) { _ in
          .integer(1)
        }
    let text = "SELECT Id FROM T WHERE 1 IN "
        + "(CASE WHEN probe() = 1 THEN 1 END, Name + 1)"
    let query = try parse(text)
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, routines: routines, validate: true)
    }
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try resolve()
    }
  }

  @Test func `a constant-expression IS NOT NULL CASE guard prunes a later unreachable element`() throws {
    // `1 IN (CASE WHEN 1 + 0 IS NOT NULL THEN 1 END, Name + 1)`: the guard `1 +
    // 0 IS NOT NULL` is ROW-INDEPENDENT but NOT a bare literal. Folding its
    // operand through `constant(_ expression:)` yields the concrete value `1`,
    // which is not NULL, so `IS NOT NULL` folds TRUE — the CASE folds to `1`, a
    // definite match, and the OR-chain short-circuits before `Name + 1` (text
    // arithmetic). This exercises the generalised `.null` predicate fold.
    let text = "SELECT Id FROM T WHERE 1 IN "
        + "(CASE WHEN 1 + 0 IS NOT NULL THEN 1 END, Name + 1)"
    let query = try parse(text)
    _ = try members().columns(of: query, validate: true)
    try members().expect(text, yields: [[1], [2], [3], [4]])
  }

  @Test func `an empty-group HAVING IN short-circuits a faulting element`()
      throws {
    // A whole-result aggregate over an empty source projects one empty group,
    // whose HAVING `1 IN (1, 1 / 0)` the schema path (`columns(of:)`) folds. The
    // OR-chain short-circuits on the literal `1 = 1`, so `1 / 0` is unreachable
    // and must not fault `.divide` — the schema resolves and the query runs.
    let query = try parse(
        "SELECT COUNT(*) FROM T WHERE 1 = 0 HAVING 1 IN (1, 1 / 0)")
    let columns = try members().columns(of: query)
    #expect(columns.count == 1)
    try members().expect(
        "SELECT COUNT(*) FROM T WHERE 1 = 0 HAVING 1 IN (1, 1 / 0)",
        yields: [[0]])
  }

  @Test func `an empty-group HAVING empty IN faults the fold`() throws {
    // The whole-result-aggregate empty-group HAVING fold —
    // `empty(_:Predicate)`, the surface `OutputColumn.typecheck` drives over
    // the single empty group a statically-false WHERE leaves — reaches its
    // `.membership` arm WITHOUT a prior `check`, so it must reject an EMPTY
    // list itself, as `check` and `lower` do. An empty membership otherwise
    // folds FALSE (TRUE under `NOT IN`), silently keeping the group past a list
    // both `check` and `lower` reject. The parser rejects `IN ()`, so build the
    // empty `NOT IN` as a raw AST and fold it directly on a `Scope` (as
    // `Scope([]).empty(_:Expression)` is exercised elsewhere), isolating the
    // fold from the compile-path guard.
    let having = Predicate.membership(.literal(.integer(1)), [], negated: true)
    #expect(throws:
        SQLError.unsupported("IN requires a non-empty value list")) {
      _ = try Scope([]).empty(having)
    }
  }

  /// A `SELECT Id FROM T WHERE <predicate>` built directly, so a
  /// `Predicate.membership` with an EMPTY value list reaches the engine —
  /// bypassing the parser, which rejects `IN ()`.
  private func select(where predicate: Predicate) -> Query {
    .select(Select(projection: .columns([Column(name: "Id")]),
                   from: Relation(name: "T"), predicate: predicate))
  }

  @Test func `an empty IN list faults the schema check, not a crash`() throws {
    // `Predicate.membership` is public, so a caller can build an EMPTY list
    // directly, bypassing the parser's `IN ()` rejection. The lowering has no
    // OR-chain seed for an empty list, so it FAULTS the schema check (an
    // unsupported shape) rather than trapping on the force-unwrap.
    let query = select(where: .membership(.column("Id"), [], negated: false))
    let resolve = { () throws -> Array<OutputColumn> in
      try members().columns(of: query, validate: true)
    }
    #expect(throws:
        SQLError.unsupported("IN requires a non-empty value list")) {
      try resolve()
    }
  }

  @Test func `an empty IN list faults the run, not a crash`() throws {
    // The same direct-AST empty list must FAULT the run's compile/lowering (the
    // OR-chain reduction) rather than crashing on the force-unwrap.
    let query = select(where: .membership(.column("Id"), [], negated: false))
    #expect(throws:
        SQLError.unsupported("IN requires a non-empty value list")) {
      _ = try members().run(query)
    }
  }
}

// MARK: - Operand evaluated once

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so the non-deterministic
/// `stepper()` routine registered against it can both observe successive values
/// and record how many times the run invoked it. The engine evaluates a row's
/// filter synchronously on one thread, so the box needs no lock; `@unchecked`
/// satisfies the `@Sendable` routine closure's capture.
private final class Counter: @unchecked Sendable {
  /// The number of times `next()` has been called.
  private(set) var count = 0

  /// Increments the count and returns the PREVIOUS value — the sequence `0, 1,
  /// 2, …` across successive calls.
  func next() -> Int {
    defer { count += 1 }
    return count
  }
}

struct MembershipOperandTests {
  /// A single-row table, so a per-row operand is evaluated once for the one row
  /// under test.
  private func one() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `the IN operand is evaluated once per row`() throws {
    // `stepper()` yields 0 on its first call, then 1, 2, …; it is
    // NON-deterministic so the engine cannot fold it. Over the one row,
    // `stepper() IN (1, 2)` must evaluate the operand EXACTLY ONCE — yielding
    // 0 — and 0 ∉ {1, 2}, so the row is EXCLUDED. The old OR-chain lowered this
    // to `stepper() = 1 OR stepper() = 2`, re-evaluating the operand: the first
    // call yields 0 (0 ≠ 1) and the SECOND yields 2 (2 = 2), wrongly ADMITTING
    // the row and calling `stepper()` twice. The first-class membership filter
    // caches the operand, so the row is dropped and the counter reads exactly
    // 1.
    let counter = Counter()
    let routines = try Routines()
        .registering("stepper", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try one().expect("SELECT Id FROM T WHERE stepper() IN (1, 2)", yields: [],
                     routines: routines)
    #expect(counter.count == 1)
  }
}
