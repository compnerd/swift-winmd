// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising the `||` concatenation operator: two text columns and
/// one that is `NULL` in a row, so the NULL-propagation corner is reachable.
private func things() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "A": .text, "B": .text]) {
      Row(1, "a", "b")
      Row(2, "c", nil)
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

// MARK: - Parsing

struct ConcatParsingTests {
  @Test func `parses a concatenation`() throws {
    let select = try parse(select: "SELECT A || B FROM T")
    let concat = Expression.binary(.concatenate, .column("A"),
                                   .column("B"))
    #expect(select.projection
                == .expressions([Projected(expression: concat)]))
  }

  @Test func `concatenation is left-associative`() throws {
    // `a || b || c` reads `(a || b) || c`.
    let select = try parse(select: "SELECT 'a' || 'b' || 'c'")
    let inner = Expression.binary(.concatenate, .literal(.string("a")),
                                  .literal(.string("b")))
    let outer = Expression.binary(.concatenate, inner,
                                  .literal(.string("c")))
    #expect(select.projection
                == .expressions([Projected(expression: outer)]))
  }
}

// MARK: - Evaluation

struct ConcatEvaluationTests {
  @Test func `concatenates two text values`() throws {
    try things().expect("SELECT 'a' || 'b'", yields: [["ab"]])
  }

  @Test func `a NULL right operand propagates NULL`() throws {
    // Row 2's Last is NULL, so `First || Last` is NULL.
    try things().expect("SELECT A || B FROM T WHERE Id = 2",
                        yields: [[nil]])
  }

  @Test func `a NULL left operand propagates NULL`() throws {
    // Row 2's Last is NULL on the left this time.
    try things().expect("SELECT B || A FROM T WHERE Id = 2",
                        yields: [[nil]])
  }

  @Test func `concatenates over columns in a projection`() throws {
    // Row 1 joins "a" and "b"; row 2's Last is NULL, so the result is NULL.
    try things().expect("SELECT A || B FROM T",
                        yields: [["ab"], [nil]])
  }

  @Test func `a non-text operand faults`() throws {
    // `||` is a character-string operator; a numeric operand is a type error,
    // as arithmetic faults on a non-numeric one.
    try things().expect("SELECT 'a' || 1", fails:
        .operand("|| operands must be text"))
  }

  @Test func `a statically-NULL operand concatenates as NULL`() throws {
    // `CASE WHEN 1 = 0 THEN 1 END` yields NULL yet derives `.integer` (the
    // no-branch schema default). `||` returns NULL for a NULL operand BEFORE
    // it inspects kinds, so this VALIDATES — the output-schema text guard
    // admits the folded NULL rather than rejecting the `.integer` type — and
    // runs, yielding NULL; the caller need not fall back to a CASE desugar.
    try things().expect("SELECT (CASE WHEN 1 = 0 THEN 1 END) || 'x'",
                        yields: [[nil]])
  }

  @Test func `a folded-NULL side admits a non-text other operand`() throws {
    // `Arithmetic.apply` returns NULL before inspecting EITHER kind, so a
    // statically-NULL side makes the whole `||` valid regardless of the OTHER
    // operand's type: `(CASE WHEN 1 = 0 THEN 1 END) || 1` — a folded NULL
    // beside a bare integer — validates and yields NULL rather than being
    // rejected for the integer right operand.
    try things().expect("SELECT (CASE WHEN 1 = 0 THEN 1 END) || 1",
                        yields: [[nil]])
  }
}

// MARK: - Derivation

/// Parses `text` to a `Query`, failing on any other shape.
private func query(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

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

struct ConcatDerivationTests {
  @Test func `deriving a concatenation resolves both operands`() throws {
    // `derive` — the schema-only surface a `columns(of:validate:false)` and an
    // unreachable projection take, which RESOLVES column references — must
    // derive both `||` operands, so an unresolved `Missing` faults
    // `SQLError.column` rather than the branch silently advertising a `text`
    // column, mirroring the arithmetic `.binary` derive branch.
    #expect(throws: SQLError.column("Missing")) {
      _ = try derived("SELECT Missing || 'x' FROM People")
    }
  }

  @Test func `a resolved concatenation derives text`() throws {
    // A `||` whose operands both resolve still derives a `.text` column —
    // resolution succeeds and the result type is text regardless of the
    // operands' own types.
    #expect(try derived("SELECT Name || 'x' FROM People") == .text)
  }
}
