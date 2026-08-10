// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport
import func SQLTestSupport.parse

/// The single projected expression of `sql`, recording an issue if the
/// projection is not one expression item.
private func projected(_ sql: String,
                       location: Testing.SourceLocation = #_sourceLocation)
    throws -> Expression {
  let select = try parse(select: sql, location: location)
  guard case let .expressions(items) = select.projection, items.count == 1
  else {
    Issue.record("expected a single projected expression",
                 sourceLocation: location)
    throw SQLError.incomplete(expected: "a projected expression")
  }
  return items[0].expression
}

// MARK: - Parsing

/// The `WINDOW name AS (…)` clause parses into the select's `window` field, and
/// a bare `OVER name` reference into a `WindowSpec` carrying only the base name
/// — the forward reference the resolution prelude later inlines.
struct NamedWindowParsingTests {
  @Test func `a bare OVER name parses as a wholesale window reference`()
      throws {
    // A bare `OVER w` is a window-name reference — the default, unparenthesized
    // `WindowSpec(base:)` — using the named window wholesale, framed or not.
    #expect(try projected("SELECT ROW_NUMBER() OVER w FROM T")
                == .window(function: .number, spec: WindowSpec(base: "w")))
  }

  @Test func `a parenthesised OVER (name) parses as an in-line copy`() throws {
    // `OVER (w)` is a parenthesized in-line specification — `parenthesized:
    // true` — that copies `w`, distinct from the bare form above.
    #expect(try projected("SELECT ROW_NUMBER() OVER (w) FROM T")
                == .window(function: .number,
                           spec: WindowSpec(base: "w", parenthesized: true)))
  }

  @Test func `the WINDOW clause populates the select's named windows`() throws {
    let select = try parse(select:
        "SELECT ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x)")
    let spec = WindowSpec(partition: [.column(Column("d"))],
                          order: Order(keys: [Order.Key(column: Column("x"))]))
    #expect(select.window == [NamedWindow(name: "w", spec: spec)])
  }

  @Test func `multiple named windows parse in source order`() throws {
    let select = try parse(select:
        "SELECT ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (PARTITION BY d), v AS (ORDER BY x)")
    #expect(select.window.map(\.name) == ["w", "v"])
    #expect(select.window[0].spec
                == WindowSpec(partition: [.column(Column("d"))]))
    #expect(select.window[1].spec
                == WindowSpec(order:
                    Order(keys: [Order.Key(column: Column("x"))])))
  }

  @Test func `a named window definition may itself carry a base reference`()
      throws {
    // A named window that references another (`v AS (w …)`) parses with the
    // base name recorded and `parenthesized: true` (an `AS (…)` definition
    // copies its base); the prelude resolves the chained reference through to
    // the base window at use.
    let select = try parse(select:
        "SELECT ROW_NUMBER() OVER v FROM T WINDOW w AS (ORDER BY x), v AS (w)")
    #expect(select.window[1].spec == WindowSpec(base: "w", parenthesized: true))
  }
}

// MARK: - Execution parity (named ≡ inline)

/// A single-relation `T(d, x)` with a partition of three `d = 1` rows (one out
/// of window order) and a lone `d = 2` row — enough for a `PARTITION BY d ORDER
/// BY x` window to number, rank, and total distinctly.
private func partitioned() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["d": .integer, "x": .integer]) {
      Row(1, 10)
      Row(1, 30)
      Row(2, 20)
      Row(1, 20)
    }
  }
}

/// An `OVER w` reference resolves to the `WINDOW` clause's definition, so a
/// named window and the equivalent inline `OVER (…)` compile, run, and validate
/// identically — the parity the inline-before-walk prelude gives by
/// construction.
struct NamedWindowExecutionTests {
  @Test func `a named ranking window yields the inline window's rows`() throws {
    try partitioned().expect(
        "SELECT d, x, ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x)",
        yields: [[1, 10, 1], [1, 30, 3], [2, 20, 1], [1, 20, 2]])
  }

  @Test func `a named ranking window equals its inline form`() throws {
    try partitioned().expect(
        "SELECT d, x, ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x)",
        equals:
        "SELECT d, x, ROW_NUMBER() OVER (PARTITION BY d ORDER BY x) FROM T")
  }

  @Test func `a named aggregate window equals its inline form`() throws {
    try partitioned().expect(
        "SELECT d, x, SUM(x) OVER w FROM T WINDOW w AS (PARTITION BY d)",
        equals: "SELECT d, x, SUM(x) OVER (PARTITION BY d) FROM T")
  }

  @Test func `one named window shared by two functions equals the inline form`()
      throws {
    try partitioned().expect(
        "SELECT RANK() OVER w, SUM(x) OVER w FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x)",
        equals:
        "SELECT RANK() OVER (PARTITION BY d ORDER BY x), "
        + "SUM(x) OVER (PARTITION BY d ORDER BY x) FROM T")
  }

  @Test func `two named windows resolve independently`() throws {
    try partitioned().expect(
        "SELECT ROW_NUMBER() OVER w, RANK() OVER v FROM T "
        + "WINDOW w AS (ORDER BY x), v AS (PARTITION BY d ORDER BY x)",
        equals:
        "SELECT ROW_NUMBER() OVER (ORDER BY x), "
        + "RANK() OVER (PARTITION BY d ORDER BY x) FROM T")
  }

  @Test func `a refinement adds an ORDER BY to the base partition`() throws {
    // `OVER (w ORDER BY x)` refines the base `w` (a PARTITION BY) by adding an
    // ORDER BY — the ISO merge equals the fully-spelled inline window.
    try partitioned().expect(
        "SELECT d, x, ROW_NUMBER() OVER (w ORDER BY x) FROM T "
        + "WINDOW w AS (PARTITION BY d)",
        equals:
        "SELECT d, x, ROW_NUMBER() OVER (PARTITION BY d ORDER BY x) FROM T")
  }

  @Test func `a chained reference resolves through to the base`() throws {
    // `v AS (w)` chains to `w`; `OVER v` resolves through both to `w`'s spec.
    try partitioned().expect(
        "SELECT d, x, ROW_NUMBER() OVER v FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x), v AS (w)",
        equals:
        "SELECT d, x, ROW_NUMBER() OVER (PARTITION BY d ORDER BY x) FROM T")
  }

  @Test func `a refinement adds a frame to a frameless base`() throws {
    // A reference may add a frame the base lacks; the merged window equals the
    // inline form carrying the base's PARTITION/ORDER plus the added frame.
    try partitioned().expect(
        "SELECT d, x, SUM(x) OVER (w ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) "
        + "FROM T WINDOW w AS (PARTITION BY d ORDER BY x)",
        equals:
        "SELECT d, x, SUM(x) OVER (PARTITION BY d ORDER BY x "
        + "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM T")
  }

  @Test func `a parenthesised copy equals the bare form when frameless`()
      throws {
    // `OVER (w)` copies a frameless `w`, yielding the same rows as the bare
    // `OVER w` and the fully inline form.
    try partitioned().expect(
        "SELECT d, x, ROW_NUMBER() OVER (w) FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x)",
        equals:
        "SELECT d, x, ROW_NUMBER() OVER (PARTITION BY d ORDER BY x) FROM T")
  }

  @Test func `a bare reference to a framed window uses it wholesale`() throws {
    // A bare `OVER w` inherits the named window entirely — its frame included —
    // so a framed named window is usable by reference (only a refinement is
    // barred from building on a framed base).
    try partitioned().expect(
        "SELECT d, x, SUM(x) OVER w FROM T "
        + "WINDOW w AS (PARTITION BY d ORDER BY x "
        + "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)",
        equals:
        "SELECT d, x, SUM(x) OVER (PARTITION BY d ORDER BY x "
        + "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM T")
  }

  @Test func `a named window orders the query result the same as inline`()
      throws {
    try partitioned().expect(
        "SELECT x, ROW_NUMBER() OVER w AS rn FROM T "
        + "WINDOW w AS (ORDER BY x) ORDER BY rn DESC",
        equals:
        "SELECT x, ROW_NUMBER() OVER (ORDER BY x) AS rn FROM T "
        + "ORDER BY rn DESC")
  }

  @Test func `the schema advertises the named window's column`() throws {
    let query = try parse(query:
        "SELECT x, ROW_NUMBER() OVER w AS rn FROM T WINDOW w AS (ORDER BY x)")
    let columns = try partitioned().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x", "rn"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }
}

// MARK: - A subquery inside a named window's spec

/// `T(d, x)` beside a one-row `S(y)` whose lone value shifts a window key — a
/// scalar subquery inside a window specification the structural walks must
/// descend after the reference is inlined.
private func correlated() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["d": .integer, "x": .integer]) {
      Row(1, 10)
      Row(1, 30)
      Row(1, 20)
    }
    Relation("S", ["y": .integer]) {
      Row(100)
    }
  }
}

/// After the prelude inlines an `OVER w` reference, the named window's own
/// specification is an ordinary sub-tree, so the subquery/aggregate/comparison
/// walks descend it exactly as they do an inline `OVER (…)` spec — a subquery in
/// the named window resolves and runs, and a defective one faults, identically
/// to the inline form.
struct NamedWindowSpecWalkTests {
  @Test func `a subquery in a named window's ORDER BY equals the inline form`()
      throws {
    try correlated().expect(
        "SELECT x, ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (ORDER BY x + (SELECT MIN(y) FROM S))",
        equals:
        "SELECT x, ROW_NUMBER() OVER (ORDER BY x + (SELECT MIN(y) FROM S)) "
        + "FROM T")
  }

  @Test func `an unknown column in a named window's spec faults on both paths`()
      throws {
    // The window `ORDER BY` resolves over the source scope after inlining, so
    // an unknown column faults `.column` — the same fault the inline form
    // raises, on both the run and validate paths (the tripwire guards parity).
    try correlated().expect(
        "SELECT ROW_NUMBER() OVER w FROM T WINDOW w AS (ORDER BY nonesuch)",
        fails: .column("nonesuch"))
  }

  @Test func `a wide scalar subquery in a named window's spec faults`() throws {
    // A scalar subquery projecting two columns is an arity error the subquery
    // walk raises where the spec is descended — inlined named or inline alike.
    try correlated().expect(
        "SELECT ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (ORDER BY (SELECT d, x FROM T))",
        fails: .arity(1, 2))
  }
}

// MARK: - Faults

/// A named window reference to an undefined window, a duplicate `WINDOW` name,
/// and the ISO refinement violations — adding a `PARTITION BY`, refining a
/// framed window, overriding the base's `ORDER BY`, and a cyclic reference —
/// each fault a clean diagnostic on both run and validate paths, the prelude
/// running in the shared `Query.expanded` so the two cannot diverge.
struct NamedWindowFaultTests {
  private func fixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["d": .integer, "x": .integer]) {
        Row(1, 10)
      }
    }
  }

  @Test func `an OVER naming an undefined window faults`() throws {
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER w FROM T",
        fails: .state("42704", "window \"w\" is not defined"))
  }

  @Test func `an OVER naming an undefined window with other windows faults`()
      throws {
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER missing FROM T WINDOW w AS (ORDER BY x)",
        fails: .state("42704", "window \"missing\" is not defined"))
  }

  @Test func `a duplicate WINDOW name faults`() throws {
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (ORDER BY x), w AS (ORDER BY d)",
        fails: .state("42601", "window \"w\" is already defined"))
  }

  @Test func `a duplicate WINDOW name is case-insensitive`() throws {
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER w FROM T "
        + "WINDOW w AS (ORDER BY x), W AS (ORDER BY d)",
        fails: .state("42601", "window \"W\" is already defined"))
  }

  @Test func `a reference that adds a PARTITION BY faults`() throws {
    // A reference inherits the base's partitioning; it may not add its own.
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER (w PARTITION BY d) FROM T "
        + "WINDOW w AS (ORDER BY x)",
        fails: .state("42601",
                      "a window referencing \"w\" cannot add a PARTITION BY"))
  }

  @Test func `refining a framed window faults`() throws {
    // A refinement copies the base, so it cannot copy a framed one — here the
    // reference adds its own frame over an already-framed `w`.
    try fixture().expect(
        "SELECT SUM(x) OVER (w ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) "
        + "FROM T WINDOW w AS (ORDER BY x ROWS BETWEEN 1 PRECEDING AND "
        + "CURRENT ROW)",
        fails: .state("42601",
                      "window \"w\" has a frame and cannot be copied"))
  }

  @Test func `a parenthesised copy of a framed window faults`() throws {
    // `OVER (w)` is an in-line spec that copies `w`, so a framed `w` is
    // rejected even though the reference adds no clauses — unlike a bare
    // `OVER w`, which uses the framed window wholesale.
    try fixture().expect(
        "SELECT SUM(x) OVER (w) FROM T "
        + "WINDOW w AS (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)",
        fails: .state("42601",
                      "window \"w\" has a frame and cannot be copied"))
  }

  @Test func `overriding the base's ORDER BY faults`() throws {
    // A reference adds an ORDER BY only when the base has none.
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER (w ORDER BY d) FROM T "
        + "WINDOW w AS (ORDER BY x)",
        fails: .state("42601",
                      "window \"w\" already orders and its ORDER BY "
                      + "cannot be overridden"))
  }

  @Test func `a definition referencing a later window is out of scope`()
      throws {
    // A definition sees only earlier `WINDOW` entries, so `v AS (w)` cannot
    // reference a `w` defined after it — even though a projection's `OVER w`
    // could, the whole clause being in scope there.
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER v FROM T "
        + "WINDOW v AS (w), w AS (ORDER BY x)",
        fails: .state("42704", "window \"w\" is not defined"))
  }

  @Test func `a self-referencing window is out of its own scope`() throws {
    // A window references only an earlier definition; a self-reference names a
    // not-yet-defined window — undefined under the prefix rule, not a cycle.
    try fixture().expect(
        "SELECT ROW_NUMBER() OVER w FROM T WINDOW w AS (w)",
        fails: .state("42704", "window \"w\" is not defined"))
  }

  @Test func `a definition copying a framed window faults`() throws {
    // A bare `v AS (w)` copies `w` into a new window, so `w` may carry no frame
    // — unlike a direct `OVER w`, which uses a framed `w` wholesale.
    try fixture().expect(
        "SELECT SUM(x) OVER v FROM T WINDOW w AS "
        + "(ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), v AS (w)",
        fails: .state("42601", "window \"w\" has a frame and cannot be a base"))
  }
}
