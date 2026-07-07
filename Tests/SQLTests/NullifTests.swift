// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising `NULLIF`: a nullable integer `K` and a text `Name`, so
/// a NULL result and a first-argument type are both reachable.
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

/// Parses `text` to a `Query`, failing on any other shape.
private func query(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
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

// MARK: - NULLIF

struct NullifTests {
  @Test func `NULLIF parses to a first-class node`() throws {
    // `NULLIF(K, 0)` is a first-class `Expression.nullif` holding `K` ONCE —
    // not the re-referencing `CASE` its ISO definition names.
    let select = try parse(select: "SELECT NULLIF(K, 0) FROM T")
    let expression = Expression.nullif(.column("K"), .literal(.integer(0)))
    #expect(select.projection
                == .expressions([Projected(expression: expression)]))
  }

  @Test func `equal arguments yield NULL`() throws {
    try things().expect("SELECT NULLIF(1, 1)", yields: [[nil]])
  }

  @Test func `unequal integer arguments yield the first`() throws {
    try things().expect("SELECT NULLIF(1, 2)", yields: [[1]])
  }

  @Test func `unequal text arguments yield the first`() throws {
    try things().expect("SELECT NULLIF('a', 'b')", yields: [["a"]])
  }

  @Test func `the column type is the first argument's`() throws {
    // The NULL result imposes no type; the ELSE (the first argument) types it.
    #expect(try type(of: "SELECT NULLIF(Name, 'x') AS C FROM T") == .text)
  }

  @Test func `rejects a single argument`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT NULLIF(K) FROM T")
    }
  }
}

// MARK: - Derivation resolves both operands

/// A `People` catalog with a text `Name` — the base for a derive-level test.
private func people() -> FixtureCatalog {
  FixtureCatalog(
    ["People": FixtureRelation([FixtureField(name: "Name", type: .text)], [])])
}

/// The type `derive` reports for the sole projected expression of `text`, over
/// a `People` scope — the schema-only derive surface (`scope(of:)` reads no
/// cursor and skips `compile`), so `derive` alone resolves the operands.
private func derived(_ text: String) throws -> ValueType {
  let select = try parse(select: text)
  guard case let .expressions(items) = select.projection, items.count == 1
  else {
    Issue.record("expected a single projected expression")
    throw SQLError.incomplete(expected: "one projected expression")
  }
  let scope = try people().scope(of: select, Context())
  return try scope.derive(items[0].expression)
}

/// The `derive` surface RESOLVES column references without `compile`'s
/// lowering, so `derive` alone must resolve BOTH NULLIF operands: the LHS
/// shapes the result type and the RHS resolves for its errors, exactly as the
/// `||`/arithmetic derive branch derives both sides.
struct NullifDerivationTests {
  @Test func `deriving NULLIF resolves the second operand`() throws {
    // `derive` — the schema-only surface a `columns(of:validate:false)` and an
    // unreachable projection take, which RESOLVES column references — must
    // derive both `NULLIF` operands, so an unresolved RHS `Missing` faults
    // `SQLError.column` rather than the branch silently returning the LHS type,
    // mirroring the arithmetic `.binary` derive branch.
    #expect(throws: SQLError.column("Missing")) {
      _ = try derived("SELECT NULLIF(1, Missing) FROM People")
    }
  }

  @Test func `a resolved NULLIF derives the first operand's type`() throws {
    // A `NULLIF` whose operands both resolve derives the LHS type — the text
    // `Name`, not the integer RHS — the result being either `v1` or NULL.
    #expect(try derived("SELECT NULLIF(Name, 0) FROM People") == .text)
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

struct NullifOperandTests {
  /// A single-row table, so a per-row operand runs once for the one row.
  private func one() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `the NULLIF operand is evaluated once`() throws {
    // `stepper()` yields 0, then 1, …; non-deterministic, so unfoldable.
    // `NULLIF(stepper(), 99)` must evaluate `stepper()` EXACTLY ONCE — yielding
    // 0, which ≠ 99, so it returns that SAME 0. The old CASE desugar embedded
    // the operand in both the `= 99` equality and the `ELSE`, calling
    // `stepper()` twice: the equality compared 0 and the ELSE returned a
    // DIFFERENT 1. The first-class node holds the operand, so the counter reads
    // exactly 1 and the value returned is the one compared.
    let counter = Counter()
    let routines = try Routines()
        .registering("stepper", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try one().expect("SELECT NULLIF(stepper(), 99) FROM T", yields: [[0]],
                     routines: routines)
    #expect(counter.count == 1)
  }
}
