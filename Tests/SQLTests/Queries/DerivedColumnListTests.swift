// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A source `S` (two real columns) and a keyed `T`, exercising the ISO explicit
/// output column list `AS name(a, b)` over a derived table and a named
/// relation.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["x": .integer, "y": .integer]) {
      Row(1, 10)
      Row(2, 20)
      Row(3, 30)
    }
    Relation("T", ["Id": .integer, "V": .integer]) {
      Row(1, 100)
      Row(2, 200)
    }
  }
}

// MARK: - Parsing

struct DerivedColumnListParsingTests {
  @Test func `parses a derived table column list`() throws {
    // `(SELECT …) AS d(a, b)` carries the list on the derived Relation node.
    let select = try parse(select:
        "SELECT d.a FROM (SELECT x, y FROM S) AS d(a, b)")
    let inner = try parse(query: "SELECT x, y FROM S")
    #expect(select.from ==
            Relation(derived: inner, as: "d", columns: ["a", "b"]))
  }

  @Test func `parses a named relation column list`() throws {
    // `T AS x(c, d)` carries the list on the named Relation node.
    let select = try parse(select: "SELECT x.c FROM T AS x(c, d)")
    #expect(select.from ==
            Relation(name: "T", alias: "x", columns: ["c", "d"]))
  }

  @Test func `parses a column list on a bare-alias derived table`() throws {
    // The `AS` is optional, so a bare alias may still carry a column list.
    let select = try parse(select:
        "SELECT d.a FROM (SELECT x, y FROM S) d(a, b)")
    let inner = try parse(query: "SELECT x, y FROM S")
    #expect(select.from ==
            Relation(derived: inner, as: "d", columns: ["a", "b"]))
  }

  @Test func `a column list is optional on a derived table`() throws {
    // Absent a list, the derived Relation node carries an empty column list —
    // the CTE field's shape for an inferred set of names.
    let select = try parse(select: "SELECT d.a FROM (SELECT x AS a FROM S) AS d")
    let inner = try parse(query: "SELECT x AS a FROM S")
    #expect(select.from == Relation(derived: inner, as: "d"))
    #expect(select.from?.columns == [])
  }

  @Test func `a column list is optional on a named relation`() throws {
    // A bare `T` never consumes a following `(` as a column list — the peek
    // fires only after an alias, so a plain named relation stays list-free.
    let select = try parse(select: "SELECT V FROM T")
    #expect(select.from == Relation(name: "T"))
    #expect(select.from?.columns == [])
  }
}

// MARK: - Execution: derived table

struct DerivedColumnListExecutionTests {
  @Test func `a derived table renames its columns by the list`() throws {
    // `(SELECT x, y FROM S) AS d(a, b)` renames the inner `x`, `y` to `a`, `b`;
    // selecting the new names yields the inner rows under them.
    try fixture().expect(
        "SELECT a, b FROM (SELECT x, y FROM S) AS d(a, b) ORDER BY a",
        yields: [[1, 10], [2, 20], [3, 30]])
  }

  @Test func `a derived table renames columns the inner never named`() throws {
    // The list names the OUTPUT columns positionally regardless of the inner
    // spelling — here the inner projects bare `x`, `y`, renamed to `a`, `b`.
    try fixture().expect(
        "SELECT b FROM (SELECT x, y FROM S) AS d(a, b) ORDER BY a",
        yields: [[10], [20], [30]])
  }

  @Test func `a qualified reference resolves the renamed column`() throws {
    // `d.a` resolves through the alias to the renamed first column.
    try fixture().expect(
        "SELECT d.a, d.b FROM (SELECT x, y FROM S) AS d(a, b) ORDER BY d.a",
        yields: [[1, 10], [2, 20], [3, 30]])
  }

  @Test func `SELECT * yields the renamed columns`() throws {
    // A star projection over the renamed derived table exposes the new names in
    // order — the same rows, addressed as `a`, `b`.
    try fixture().expect(
        "SELECT * FROM (SELECT x, y FROM S) AS d(a, b) ORDER BY a",
        yields: [[1, 10], [2, 20], [3, 30]])
  }

  @Test func `a renamed derived table filters on the new name`() throws {
    // A `WHERE` over the renamed column filters the materialised rows.
    try fixture().expect(
        "SELECT a FROM (SELECT x, y FROM S) AS d(a, b) WHERE a > 1 ORDER BY a",
        yields: [[2], [3]])
  }
}

// MARK: - Execution: named relation

struct NamedRelationColumnListTests {
  @Test func `a named relation renames its columns by the list`() throws {
    // `FROM T AS x(c, d)` renames `T`'s real columns `Id`, `V` to `c`, `d`.
    try fixture().expect(
        "SELECT c, d FROM T AS x(c, d) ORDER BY c",
        yields: [[1, 100], [2, 200]])
  }

  @Test func `a qualified reference resolves a named relation's rename`()
      throws {
    // `x.c` reads the renamed first column of the named relation.
    try fixture().expect(
        "SELECT x.c FROM T AS x(c, d) ORDER BY x.c",
        yields: [[1], [2]])
  }

  @Test func `SELECT * yields a named relation's renamed columns`() throws {
    // A star projection over the renamed named relation exposes `c`, `d` — the
    // real columns only, never the virtual `Id`.
    try fixture().expect(
        "SELECT * FROM T AS x(c, d) ORDER BY c",
        yields: [[1, 100], [2, 200]])
  }

  @Test func `a named relation's virtual Id survives a column list`() throws {
    // The list renames only the REAL columns; the virtual `Id` stays
    // addressable by its own name.
    try fixture().expect(
        "SELECT x.Id, x.c FROM T AS x(c, d) ORDER BY x.Id",
        yields: [[1, 1], [2, 2]])
  }
}

// MARK: - Faults

struct ColumnListFaultTests {
  @Test func `a derived table list of too few columns faults`() throws {
    // The list must name one column per output; two outputs against a one-name
    // list is `SQLError.columns`, the CTE/view arity fault.
    try fixture().expect(
        "SELECT a FROM (SELECT x, y FROM S) AS d(a)",
        fails: .columns(expected: 2, got: 1))
  }

  @Test func `a derived table list of too many columns faults`() throws {
    try fixture().expect(
        "SELECT a FROM (SELECT x FROM S) AS d(a, b)",
        fails: .columns(expected: 1, got: 2))
  }

  @Test func `a named relation list of the wrong arity faults`() throws {
    // `T` has two real columns; a three-name list mismatches.
    try fixture().expect(
        "SELECT c FROM T AS x(c, d, e)",
        fails: .columns(expected: 2, got: 3))
  }

  @Test func `a derived table list with a duplicate name faults`() throws {
    // A repeated name (case-insensitively) leaves the shadowed column
    // unreachable, so it faults `SQLError.duplicate`, as a CTE's does.
    try fixture().expect(
        "SELECT a FROM (SELECT x, y FROM S) AS d(a, A)",
        fails: .duplicate("A"))
  }

  @Test func `a named relation list with a duplicate name faults`() throws {
    try fixture().expect(
        "SELECT c FROM T AS x(c, c)",
        fails: .duplicate("c"))
  }
}

// MARK: - Execution: LATERAL derived table

struct LateralColumnListTests {
  @Test func `a column list renames a lateral body's duplicate inner names`()
      throws {
    // The reviewer's case: the body projects `T.Id AS x` TWICE — a duplicate
    // INNER name the `d(a, b)` list renames positionally to the unique EXPOSED
    // `a`, `b`. The compile-path validation in `lateral` must check the RENAMED
    // names, so this runs (both columns = `T.Id`) rather than faulting the
    // inner duplicate — parity with the schema pass.
    try fixture().expect(
        "SELECT d.a, d.b FROM T " +
        "JOIN LATERAL (SELECT T.Id AS x, T.Id AS x) AS d(a, b) ON 1 = 1 " +
        "ORDER BY d.a",
        yields: [[1, 1], [2, 2]])
  }

  @Test func `a column list renames a lateral body's distinct columns`()
      throws {
    // A list over DISTINCT inner columns renames them positionally, unchanged
    // by the fix — the body projects two real columns, addressed as `a`, `b`.
    try fixture().expect(
        "SELECT d.a, d.b FROM T " +
        "JOIN LATERAL (SELECT T.Id, T.V) AS d(a, b) ON 1 = 1 " +
        "ORDER BY d.a",
        yields: [[1, 100], [2, 200]])
  }

  @Test func `a lateral column list of the wrong arity faults`() throws {
    // A one-name list against a two-column body mismatches —
    // `SQLError.columns`, as the non-lateral seam faults.
    try fixture().expect(
        "SELECT d.a FROM T " +
        "JOIN LATERAL (SELECT T.Id, T.V) AS d(a) ON 1 = 1",
        fails: .columns(expected: 2, got: 1))
  }

  @Test func `a lateral column list with a duplicate exposed name faults`()
      throws {
    // A duplicate in the EXPOSED list leaves a renamed column unreachable, so
    // it still faults `SQLError.duplicate` — the check runs against the renamed
    // names, and here THEY collide.
    try fixture().expect(
        "SELECT d.a FROM T " +
        "JOIN LATERAL (SELECT T.Id, T.V) AS d(a, a) ON 1 = 1",
        fails: .duplicate("a"))
  }
}

// MARK: - No regression

struct ColumnListRegressionTests {
  @Test func `a derived table with no list still resolves inner names`()
      throws {
    // The optional list is absent, so the inner projection's names stand — the
    // pre-existing behaviour is unchanged.
    try fixture().expect(
        "SELECT a FROM (SELECT x AS a FROM S) AS d ORDER BY a",
        yields: [[1], [2], [3]])
  }

  @Test func `a named relation with no list still resolves real names`()
      throws {
    // A plain aliased base relation keeps its own column names.
    try fixture().expect(
        "SELECT x.V FROM T AS x ORDER BY x.V",
        yields: [[100], [200]])
  }
}
