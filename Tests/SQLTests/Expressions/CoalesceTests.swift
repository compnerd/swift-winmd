// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising `COALESCE`: a nullable integer `K` and a text `Name`,
/// so a NULL fallthrough and a type unification are reachable.
private func things() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "K": .integer, "Name": .text]) {
      Row(1, 10, "a")
      Row(2, nil, "b")
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

/// The single output column type of a one-column query's schema.
private func type(of text: String, _ routines: Routines = [:])
    throws -> ValueType {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  let columns = try things().columns(of: query, routines: routines)
  #expect(columns.count == 1)
  return columns[0].type
}

// MARK: - COALESCE

struct CoalesceTests {
  @Test func `COALESCE parses to a first-class node`() throws {
    // `COALESCE(K, 0)` is a first-class `Expression.coalesce` holding each
    // argument ONCE — not the re-referencing `CASE` its ISO definition names.
    let select = try parse(select: "SELECT COALESCE(K, 0) FROM T")
    let expression = Expression.coalesce([.column("K"),
                                          .literal(.integer(0))])
    #expect(select.projection
                == .expressions([Projected(expression: expression)]))
  }

  @Test func `takes the first non-NULL argument`() throws {
    try things().expect("SELECT COALESCE(K, K, 3) FROM T WHERE K IS NULL",
                        yields: [[3]])
  }

  @Test func `an earlier non-NULL argument wins`() throws {
    try things().expect("SELECT COALESCE(K, 99) FROM T WHERE Id = 1",
                        yields: [[10]])
  }

  @Test func `all-NULL arguments yield NULL`() throws {
    try things().expect("SELECT COALESCE(K, K) FROM T WHERE K IS NULL",
                        yields: [[nil]])
  }

  @Test func `mixed integer and double arguments widen to double`() throws {
    // The arguments unify like a CASE's results — the integer widens.
    #expect(try type(of: "SELECT COALESCE(K, 2.5) AS C FROM T") == .double)
    try things().expect("SELECT COALESCE(K, 2.5) FROM T",
                        yields: [[10.0], [2.5]])
  }

  @Test func `rejects a single argument`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT COALESCE(K) FROM T")
    }
  }

  @Test func `irreconcilable argument types fault`() throws {
    // An integer argument beside a text one cannot yield one column type.
    guard case let .select(query) =
        try Statement(parsing: "SELECT COALESCE(K, Name) FROM T") else {
      Issue.record("expected a SELECT statement")
      return
    }
    #expect(throws:
        SQLError.operand("COALESCE arguments have irreconcilable types")) {
      _ = try things().columns(of: query)
    }
  }
}

// MARK: - Argument reachability

/// Parses `text` to a `Query`, failing on any other shape.
private func query(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

struct CoalesceReachabilityTests {
  @Test func `a constant non-NULL prefix leaves a later argument unreachable`()
      throws {
    // The executor returns the constant `1` and never evaluates
    // `missing_udf()` — an unregistered routine a run would fault `.function`
    // on — so the typecheck, mirroring that short-circuit, must NOT validate
    // the unreachable call. `columns(of:)` succeeds and the run yields the `1`.
    let text = "SELECT COALESCE(1, missing_udf()) FROM T"
    _ = try things().columns(of: query(text))
    try things().expect(text, yields: [[1], [1]])
  }

  @Test func `a constant non-NULL prefix determines the column type`() throws {
    // The reachable prefix (the constant `1`) shapes the column — an integer —
    // exactly as a constant-TRUE CASE guard's branch does; the unreachable text
    // argument does not unify into it.
    #expect(try type(of: "SELECT COALESCE(1, missing_udf()) AS C FROM T")
                == .integer)
  }

  @Test func `a bad operand after a constant prefix is unreachable`() throws {
    // `Name + 1` over the text `Name` would fault `.operand` if reached, but
    // the constant `1` selects first, so it is unreachable and not validated.
    _ = try things().columns(of: query("SELECT COALESCE(1, Name + 1) FROM T"))
  }

  @Test func `a constant NULL prefix does NOT stop validation`() throws {
    // COALESCE steps PAST a NULL argument, so a later one is reachable and MUST
    // be validated. `NULL` is not an expression literal (it is UNKNOWN, spelled
    // only in `IS NULL`), so a DETERMINISTIC routine folding to `.null` stands
    // in for the constant-NULL prefix: `missing_udf()` after it still faults
    // `.function`.
    let routines = try Routines()
        .registering("nought", returns: .integer, deterministic: true) { _ in
          .null
        }
    #expect(throws: SQLError.function("missing_udf")) {
      _ = try things().columns(of:
          query("SELECT COALESCE(nought(), missing_udf()) FROM T"),
          routines: routines)
    }
  }

  @Test func `a non-constant prefix does NOT stop validation`() throws {
    // A row-dependent argument (`K`, a nullable integer) is not a definite
    // selection — the run may fall through it — so a later argument is
    // reachable and validated: `missing_udf()` after `K` still faults
    // `.function` (both integer-typed, so the fault is the unknown call, not a
    // type clash).
    #expect(throws: SQLError.function("missing_udf")) {
      _ = try things().columns(of:
          query("SELECT COALESCE(K, missing_udf()) FROM T"))
    }
  }

  @Test func `a constant NULL prefix does NOT shape the type`() throws {
    // A run skips a NULL argument and moves on, so an argument that folds to a
    // constant `.null` can never be returned — its DECLARED type must not unify
    // into the column, exactly as a `CASE` omits a skipped branch's result
    // type. `null_text()` is a DETERMINISTIC routine declaring `.text` yet
    // folding to `.null`, so `COALESCE(null_text(), 1)` can only ever yield the
    // integer `1`: merging the `.text` would clash with the `.integer` and
    // reject the query, so the constant-NULL arm's type is skipped. It
    // type-checks, runs to `1`, and the column derives `.integer`.
    let routines = try Routines()
        .registering("null_text", returns: .text, deterministic: true) { _ in
          .null
        }
    let text = "SELECT COALESCE(null_text(), 1) FROM T"
    _ = try things().columns(of: query(text), routines: routines)
    #expect(try type(of: text, routines) == .integer)
    try things().expect(text, yields: [[1], [1]], routines: routines)
  }

  @Test func `a COUNT prefix leaves a later argument unreachable`() throws {
    // `COUNT(*)` is always non-NULL (a row count of 0 or more), so it is the
    // definite selection — the executor returns it and never evaluates the
    // later `missing_udf()`, an unregistered routine a run would fault
    // `.function` on. The typecheck, mirroring that short-circuit, must NOT
    // validate the unreachable call. `columns(of:)` succeeds over the
    // whole-result group and the run yields the count (2).
    let text = "SELECT COALESCE(COUNT(*), missing_udf()) FROM T"
    _ = try things().columns(of: query(text))
    try things().expect(text, yields: [[2]])
  }

  @Test func `a COUNT prefix determines the column type`() throws {
    // The reachable prefix (`COUNT(*)`) shapes the column — an integer — and
    // the unreachable later argument does not unify into it.
    #expect(try type(of: "SELECT COALESCE(COUNT(*), missing_udf()) AS C FROM T")
                == .integer)
  }

  @Test func `a SUM prefix does NOT stop validation`() throws {
    // Unlike COUNT, SUM is NULL over an empty group, so it is NOT a definite
    // selection — the run may fall through it — and a later argument stays
    // reachable and MUST be validated: `missing_udf()` after `SUM(K)` still
    // faults `.function`.
    #expect(throws: SQLError.function("missing_udf")) {
      _ = try things().columns(of:
          query("SELECT COALESCE(SUM(K), missing_udf()) FROM T"))
    }
  }

  @Test func `a SUM prefix falls back to a reachable later argument`() throws {
    // The CONTROL for the COUNT stop: `COALESCE(SUM(x), 0)` still validates and
    // derives the later `0` (SUM is nullable, not a stop), unifying to
    // `.integer`, and runs — SUM over the two-row group is the sum of K.
    let text = "SELECT COALESCE(SUM(K), 0) FROM T"
    #expect(try type(of: text) == .integer)
    try things().expect(text, yields: [[10]])
  }
}

// MARK: - Constant folding

/// A deterministic native routine reporting whether its single argument is a
/// `.double` — 1 when it is, else 0. It DISTINGUISHES `.double(1.0)` from
/// `.integer(1)`, so the constant fold's coercion of a COALESCE's selected
/// value is OBSERVABLE through it. Its declared parameter `type` matches the
/// COALESCE's derived type so the static arity/type check (which demands an
/// exact match) passes.
private func doubling(taking type: ValueType) throws -> Routines {
  try Routines()
      .registering("is_double", returns: .integer, parameters: [type],
                   deterministic: true) { arguments in
        if case .double = arguments[0] { return .integer(1) }
        return .integer(0)
      }
}

/// An `is_double(<coalesce>) = 1` reachability predicate — TRUE only when the
/// COALESCE's constant fold reports its selected value as a `.double`.
private func predicate(over coalesce: Expression) -> Predicate {
  .comparison(left: .call(name: "is_double", arguments: [coalesce]),
              op: .equal, right: .literal(.integer(1)))
}

/// The schema validator folds a ROW-INDEPENDENT `COALESCE` (via
/// `constant(_ expression:)`) to decide a `WHERE` arm's reachability, so its
/// selected value must carry the SAME type the run's `Term.coalesce` supplies —
/// the unified type `derive` advertises — or the fold sees a value the run
/// never produces. The fold coerces the selected value to that unified type,
/// mirroring the executor (`Value.coerced`) and the sibling empty-group fold.
///
/// This engine types a COALESCE by its REACHABLE prefix: a constant non-NULL
/// argument is the definite selection, so it both sets the unified type and is
/// the folded value — the coercion is therefore the identity on the constant
/// path, but it keeps the fold pinned to the advertised type rather than a raw
/// selected value, matching the run exactly.
struct CoalesceConstantTests {
  @Test func `a mixed COALESCE folds to its selected reachable value`() throws {
    // `COALESCE(1, 2.5)` selects the constant `1` — the definite selection that
    // makes `2.5` unreachable — so it types as `.integer` and the fold yields
    // `.integer(1)`, exactly as the run's `Term.coalesce` does over the same
    // `.integer` lowered type: `is_double` reports FALSE, so the predicate
    // folds definitely FALSE.
    let coalesce = Expression.coalesce([.literal(.integer(1)),
                                        .literal(.double(2.5))])
    let folded = Scope([]).constant(predicate(over: coalesce),
                                    try doubling(taking: .integer))
    #expect(folded == false)
  }

  @Test func `an all-integer COALESCE is not coerced`() throws {
    // `COALESCE(1, 2)` unifies to `.integer`, so the selected `1` stays
    // `.integer(1)`: no spurious coercion to `.double`. `is_double` reports
    // FALSE, so the predicate folds definitely FALSE.
    let coalesce = Expression.coalesce([.literal(.integer(1)),
                                        .literal(.integer(2))])
    let folded = Scope([]).constant(predicate(over: coalesce),
                                    try doubling(taking: .integer))
    #expect(folded == false)
  }

  @Test func `the constant fold matches the run`() throws {
    // The fold and the run must yield the SAME value for a ROW-INDEPENDENT
    // COALESCE. Selecting a `.double` constant yields `.double`; selecting an
    // integer constant past a NULL-folding double routine yields `.integer`
    // (the reachable prefix types it), each coerced to the derived type the run
    // lowers — so `is_double` agrees with the run over the folded value.
    let nulldouble = try Routines()
        .registering("null_double", returns: .double, deterministic: true) {
          _ in .null
        }
    // Selects the `.double` constant: fold is `.double(2.5)`.
    let picksDouble = Expression.coalesce([.literal(.double(2.5)),
                                           .literal(.integer(1))])
    #expect(Scope([]).constant(predicate(over: picksDouble),
                               try doubling(taking: .double)) == true)
    // NULL double prefix skipped, integer `1` selected: fold is `.integer(1)`.
    let picksInteger =
        Expression.coalesce([.call(name: "null_double", arguments: []),
                             .literal(.integer(1))])
    #expect(Scope([]).constant(predicate(over: picksInteger),
                               try doubling(taking: .integer)
                                   .merging(nulldouble)) == false)
  }
}

// MARK: - Typecheck agrees with the run

/// The `WHERE` reachability fold and the run must AGREE on a ROW-INDEPENDENT
/// `COALESCE`: an arm the run reaches must be type-checked, so the COALESCE's
/// coerced fold value cannot let validation skip a projection execution runs —
/// mirroring the CASE-coercion end-to-end shape.
struct CoalesceTypecheckTests {
  @Test func `a reachable projection is type-checked`() throws {
    // `WHERE is_double(COALESCE(2.5, 1)) = 1 AND …` — the COALESCE selects the
    // `.double` constant, so `is_double` reports 1 and the guard folds TRUE:
    // the AND's right arm is reachable, so the projection's `Name + 1` (text
    // arithmetic) is validated and faults, exactly as the run reaches it.
    let text = """
        SELECT Name + 1 AS C FROM T
          WHERE is_double(COALESCE(2.5, 1)) = 1 AND Id = 1
        """
    #expect(throws: SQLError.operand("operands must be numeric")) {
      _ = try things().columns(of: query(text),
                               routines: doubling(taking: .double))
    }
  }

  @Test func `an unreachable projection is skipped`() throws {
    // The CONTROL: `COALESCE(1, 2)` folds to the integer `1`, so `is_double`
    // reports 0 and `= 1` folds FALSE — the AND's right arm is unreachable and
    // its `Name + 1` is NOT validated, so the query type-checks. (The run
    // likewise never reaches it.)
    let text = """
        SELECT Name + 1 AS C FROM T
          WHERE is_double(COALESCE(1, 2)) = 1 AND Id = 1
        """
    let columns = try things().columns(of: query(text),
                                       routines: doubling(taking: .integer))
    #expect(columns.count == 1)
  }
}

// MARK: - Operand evaluated once

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so the non-deterministic
/// `stepper()` routine registered against it both observes successive values
/// and records how many times the run invoked it. The engine evaluates a row's
/// projection synchronously on one thread, so the box needs no lock.
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

struct CoalesceOperandTests {
  /// A single-row table, so a per-row operand runs once for the one row.
  private func one() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `each COALESCE argument is evaluated once`() throws {
    // `stepper()` yields 0, then 1, 2, …; it is NON-deterministic so the engine
    // cannot fold it. `COALESCE(stepper(), 99)` must evaluate `stepper()`
    // EXACTLY ONCE — yielding 0, a non-NULL value it returns. The old CASE
    // desugar re-referenced the argument in both its `IS NOT NULL` guard and
    // its `THEN`, calling `stepper()` twice: the guard saw 0 (non-NULL) and the
    // THEN returned a DIFFERENT 1. The first-class node holds the argument, so
    // the counter reads exactly 1 and the value returned is the one tested.
    let counter = Counter()
    let routines = try Routines()
        .registering("stepper", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try one().expect("SELECT COALESCE(stepper(), 99) FROM T", yields: [[0]],
                     routines: routines)
    #expect(counter.count == 1)
  }
}
