// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// Two relations exercising the uncorrelated DERIVED TABLE: an outer keyed `T`
/// and a source `S` whose `V` a derived table projects/aggregates, plus a `K`
/// keyed on `T` for the JOIN case.
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
    // A relation joined to a derived table over `T` on a shared key.
    Relation("K", ["k": .integer, "Label": .text]) {
      Row(1, "a")
      Row(2, "b")
    }
  }
}



// MARK: - Parsing

struct DerivedTableParsingTests {
  @Test func `parses a derived table in FROM with an alias`() throws {
    let select = try parse(select:
        "SELECT t.a FROM (SELECT V AS a FROM S) AS t")
    let inner = try parse(query: "SELECT V AS a FROM S")
    #expect(select.from == Relation(derived: inner, as: "t"))
  }

  @Test func `parses a derived table alias without AS`() throws {
    // The `AS` is optional the same as a named relation's, so a bare alias
    // after the closing paren names the derived table.
    let select = try parse(select: "SELECT t.a FROM (SELECT V AS a FROM S) t")
    let inner = try parse(query: "SELECT V AS a FROM S")
    #expect(select.from == Relation(derived: inner, as: "t"))
  }

  @Test func `parses a derived table in a JOIN`() throws {
    let select = try parse(select:
        "SELECT T.Id FROM T JOIN (SELECT Id AS k FROM T) AS d ON T.Id = d.k")
    let inner = try parse(query: "SELECT Id AS k FROM T")
    #expect(select.from == Relation(name: "T"))
    #expect(select.joins.count == 1)
    #expect(select.joins[0].relation == Relation(derived: inner, as: "d"))
  }

  @Test func `parses a derived table over a UNION`() throws {
    // A derived table is a full `query`, so it may itself be a `UNION`.
    let select = try parse(select:
        "SELECT t.V FROM (SELECT V FROM S UNION SELECT V FROM T) AS t")
    let inner = try parse(query: "SELECT V FROM S UNION SELECT V FROM T")
    #expect(select.from == Relation(derived: inner, as: "t"))
  }

  @Test func `a parenthesised relation without SELECT is not a derived table`()
      throws {
    // The one-token lookahead only takes the derived-table arm on a leading
    // `SELECT`; anything else in a relation position faults (no parenthesised
    // relation `(a JOIN b)` in this dialect yet).
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT a FROM (T)")
    }
  }

  @Test func `a derived table round-trips by AST equality`() throws {
    // Two parses of the same derived-table query yield equal ASTs — the nested
    // `Query` in `Relation.Source.derived` composes the synthesized
    // `Hashable`/`Equatable`.
    let text = "SELECT t.a FROM (SELECT V AS a FROM S) AS t"
    #expect(try parse(query: text) == parse(query: text))
  }

  @Test func `parses LATERAL before a JOIN derived table and sets the flag`()
      throws {
    // A leading `LATERAL` before a `(SELECT …)` derived table sets the
    // `lateral` flag, so the resolver threads the preceding FROM outward.
    let select = try parse(select:
        "SELECT T.Id FROM T " +
        "JOIN LATERAL (SELECT V AS v FROM S WHERE V = T.Id) AS d ON T.Id = d.v")
    let inner = try parse(query: "SELECT V AS v FROM S WHERE V = T.Id")
    #expect(select.joins.count == 1)
    #expect(select.joins[0].relation
            == Relation(derived: inner, as: "d", lateral: true))
    #expect(select.joins[0].relation.lateral)
  }

  @Test func `a non-lateral derived table has the flag clear`() throws {
    // The default is non-lateral — a plain `(SELECT …)` never sets `lateral`.
    let select = try parse(select:
        "SELECT t.a FROM (SELECT V AS a FROM S) AS t")
    #expect(!(select.from?.lateral ?? true))
  }

  @Test func `LATERAL before a named relation faults`() throws {
    // `LATERAL` introduces a derived table alone, so a named relation after it
    // faults rather than marking the base relation lateral.
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT a FROM T JOIN LATERAL S ON T.Id = S.k")
    }
  }
}

// MARK: - Mandatory alias

struct DerivedTableAliasTests {
  @Test func `a derived table with no alias faults`() throws {
    // ISO requires a derived table be named — `FROM (SELECT …)` with no alias
    // faults at parse.
    #expect(throws: SQLError.self) {
      _ = try parse(select: "SELECT a FROM (SELECT V AS a FROM S)")
    }
  }

  @Test func `a derived table with a trailing keyword and no alias faults`()
      throws {
    // A following clause keyword (`WHERE`) is not an alias, so the missing
    // alias still faults rather than binding the keyword.
    #expect(throws: SQLError.self) {
      _ = try parse(select:
          "SELECT a FROM (SELECT V AS a FROM S) WHERE a > 0")
    }
  }
}

// MARK: - Execution

struct DerivedTableExecutionTests {
  @Test func `a derived table projects its inner column via the alias`()
      throws {
    // `FROM (SELECT V AS a FROM S) AS t` exposes one column `a` under `t`;
    // `t.a` reads it — the inner `V` renamed by the inner projection.
    try fixture().expect(
        "SELECT t.a FROM (SELECT V AS a FROM S) AS t ORDER BY t.a",
        yields: [[10], [20], [30]])
  }

  @Test func `a derived table resolves an unqualified inner column`() throws {
    // The derived column resolves both qualified (`t.a`) and unqualified (`a`),
    // exactly as a base-table alias's columns do.
    try fixture().expect(
        "SELECT a FROM (SELECT V AS a FROM S) AS t ORDER BY a",
        yields: [[10], [20], [30]])
  }

  @Test func `a derived table equals its inner query renamed`() throws {
    // The derived table's rows ARE the inner query's rows, so selecting through
    // the alias equals selecting the inner query directly.
    try fixture().expect(
        "SELECT a FROM (SELECT V AS a FROM S) AS t ORDER BY a",
        equals: "SELECT V AS a FROM S ORDER BY a")
  }

  @Test func `a derived table filters on the alias`() throws {
    // A `WHERE` over the derived column filters the materialised rows.
    try fixture().expect(
        "SELECT a FROM (SELECT V AS a FROM S) AS t WHERE a > 10 ORDER BY a",
        yields: [[20], [30]])
  }

  @Test func `a derived table joins on its alias`() throws {
    // `FROM T JOIN (SELECT Id AS k FROM T) AS d ON T.Id = d.k` — uncorrelated
    // derived table joined on a shared key; each `T` row matches its own `d`
    // row (Id 1, 2, 3), so the join yields three pairs.
    try fixture().expect(
        "SELECT T.Id, d.k FROM T " +
        "JOIN (SELECT Id AS k FROM T) AS d ON T.Id = d.k ORDER BY T.Id",
        yields: [[1, 1], [2, 2], [3, 3]])
  }

  @Test func `a derived table joins a base relation on the alias key`() throws {
    // Join `K` to a derived table over `T`: only the `T` rows whose `Id`
    // matches a `K.k` (1 and 2) pair, so the result is the two labelled rows.
    try fixture().expect(
        "SELECT d.Id, K.Label FROM K " +
        "JOIN (SELECT Id, V FROM T) AS d ON K.k = d.Id ORDER BY d.Id",
        yields: [[1, "a"], [2, "b"]])
  }

  @Test func `a derived table over an aggregate projects the aggregate`()
      throws {
    // `FROM (SELECT MAX(V) AS m FROM S) AS t` — a derived table over a
    // whole-result aggregate has one row, one column `m`, the maximum 30.
    try fixture().expect(
        "SELECT m FROM (SELECT MAX(V) AS m FROM S) AS t", yields: [[30]])
  }

  @Test func `a derived table over a GROUP BY projects each group`() throws {
    // `FROM (SELECT V AS g, COUNT(*) AS n FROM S GROUP BY V) AS t` — one row
    // per distinct `V`, each with count 1.
    try fixture().expect(
        "SELECT g, n FROM " +
        "(SELECT V AS g, COUNT(*) AS n FROM S GROUP BY V) AS t ORDER BY g",
        yields: [[10, 1], [20, 1], [30, 1]])
  }

  @Test func `a derived table over a UNION runs`() throws {
    // The inner query may be a `UNION`; its distinct rows are the derived
    // table's rows.
    try fixture().expect(
        "SELECT v FROM " +
        "(SELECT V AS v FROM S UNION SELECT V AS v FROM T) AS t ORDER BY v",
        yields: [[10], [20], [30]])
  }
}

// MARK: - Schema

struct DerivedTableSchemaTests {
  @Test func `columns reports the derived table's columns`() throws {
    // `columns(of:)` reports the derived table's projected columns — the inner
    // query's output name and type under the alias — matching the run.
    let query =
        try parse(query: "SELECT t.a FROM (SELECT V AS a FROM S) AS t")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "a")
    #expect(columns[0].type == .integer)
  }

  @Test func `columns reports a starred derived table's columns`() throws {
    // A `SELECT *` over a derived table spans its inner query's output columns.
    let query =
        try parse(query: "SELECT * FROM (SELECT Id, V FROM T) AS t")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["Id", "V"])
  }

  @Test func `a derived table over a bad inner column faults`() throws {
    // The inner query is validated exactly as a run validates it: an unknown
    // inner column faults, so the schema is not advertised for a query that
    // cannot run.
    #expect(throws: SQLError.self) {
      let query =
          try parse(query: "SELECT t.a FROM (SELECT Missing AS a FROM S) AS t")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a bad inner column faults the run too`() throws {
    // Typecheck ↔ run parity: the same bad inner column faults the run.
    try fixture().expect(
        "SELECT t.a FROM (SELECT Missing AS a FROM S) AS t",
        fails: .column("Missing"))
  }
}

// MARK: - Duplicate derived output columns

/// A derived table's columns are its inner query's OUTPUT names (the ISO rule),
/// so two same-named ones leave the shadowed column unreachable through the
/// alias — the same case the Parser rejects for a view's or a CTE's inferred
/// column list. A derived table faults it the SAME way (`SQLError.duplicate`),
/// at BOTH `columns(of:)` and a run.
struct DerivedTableDuplicateColumnTests {
  @Test func `a duplicate derived output column faults the run`() throws {
    // `(SELECT Id AS x, V AS x FROM T) AS d` exposes `x` twice; `d.x` would
    // silently read the first. Reject it as a duplicate, exactly as a CTE over
    // the same body faults `SQLError.duplicate`.
    try fixture().expect(
        "SELECT d.x FROM (SELECT Id AS x, V AS x FROM T) AS d",
        fails: .duplicate("x"))
  }

  @Test func `a duplicate derived output column faults the schema path`()
      throws {
    // Schema ↔ run parity: the same duplicate faults `columns(of:)`, so the
    // schema is not advertised for a query the run rejects — the `SQLError`
    // case a view/CTE raises.
    #expect(throws: SQLError.duplicate("x")) {
      let query = try parse(query:
          "SELECT d.x FROM (SELECT Id AS x, V AS x FROM T) AS d")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `distinct derived output columns resolve`() throws {
    // Control: two DIFFERENTLY named output columns resolve fine — the check
    // fires only on a genuine same-name collision.
    try fixture().expect(
        "SELECT d.x, d.y FROM (SELECT Id AS x, V AS y FROM T) AS d " +
        "ORDER BY d.x",
        yields: [[1, 10], [2, 20], [3, 30]])
  }
}

// MARK: - Duplicate same-scope derived aliases

/// Two derived tables sharing an alias in ONE SELECT's own FROM/JOIN collide:
/// the alias-keyed overlay would rebind the earlier under the later, so both
/// FROM items resolve to the later's rows. This matches the existing duplicate
/// RELATION alias behavior (`FROM T AS d JOIN S AS d`, which makes a shared
/// column `SQLError.ambiguous`) rather than silently rebinding — the collision
/// is caught when augmenting THIS SELECT's own derived tables, so a nested or
/// sibling subquery's same-named alias (a DIFFERENT SELECT) is unaffected.
struct DerivedTableDuplicateAliasTests {
  @Test func `duplicate derived aliases fault ambiguous at the run`() throws {
    // `(SELECT Id AS a FROM T) AS d JOIN (SELECT V AS b FROM S) AS d` — a
    // single SELECT with two derived tables aliased `d`. Faults the ALIAS
    // ambiguous rather than letting the later derived `d(b)` rebind over the
    // earlier `d(a)`.
    try fixture().expect(
        "SELECT d.b FROM (SELECT Id AS a FROM T) AS d " +
        "JOIN (SELECT V AS b FROM S) AS d ON 1 = 1",
        fails: .ambiguous("d"))
  }

  @Test func `duplicate derived aliases fault ambiguous at the schema path`()
      throws {
    // Schema ↔ run parity: the same collision faults `columns(of:)`.
    #expect(throws: SQLError.ambiguous("d")) {
      let query = try parse(query:
          "SELECT d.b FROM (SELECT Id AS a FROM T) AS d " +
          "JOIN (SELECT V AS b FROM S) AS d ON 1 = 1")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a duplicate base-table alias's shared column stays ambiguous`()
      throws {
    // The behavior the derived case matches: two base relations sharing the
    // alias `d` leave BOTH in scope, so a shared column is `SQLError.ambiguous`
    // — the same ambiguity family the derived collision now raises.
    try fixture().expect(
        "SELECT d.Id FROM T AS d JOIN S AS d ON 1 = 1",
        fails: .ambiguous("Id"))
  }

  @Test func `distinct derived aliases in one SELECT both resolve`() throws {
    // Control: two derived tables with DIFFERENT aliases in one SELECT's
    // FROM/JOIN each resolve to their OWN columns — no collision.
    try fixture().expect(
        "SELECT c.a, d.b FROM (SELECT Id AS a FROM T) AS c " +
        "JOIN (SELECT V AS b FROM S) AS d ON c.a = 1 ORDER BY d.b",
        yields: [[1, 10], [1, 20], [1, 30]])
  }
}

// MARK: - A derived alias colliding with a same-scope base relation

/// A derived table's alias sharing a RANGE NAME with a BASE/named relation in
/// the SAME SELECT's FROM/JOIN is a duplicate range name: the alias-keyed
/// overlay binds the derived rows under that name, which would SHADOW the base
/// scan — `FROM T JOIN (SELECT V AS a FROM S) AS T` would resolve the base `T`
/// to the derived rows. This is the same ambiguity family a duplicate RELATION
/// alias (`FROM T AS d JOIN S AS d`) raises, and it faults at BOTH `columns(of:
/// )` and a run, BEFORE binding the derived rows, so the base is never
/// shadowed.
struct DerivedTableBaseAliasCollisionTests {
  @Test func `a derived alias colliding with a base relation faults the run`()
      throws {
    // The reviewer's case: a derived table aliased `T` in a JOIN collides with
    // the base `FROM T` of the same SELECT. Faults the ALIAS ambiguous rather
    // than binding the derived `T(a)` over the base `T` scan.
    try fixture().expect(
        "SELECT a FROM T JOIN (SELECT V AS a FROM S) AS T ON 1 = 1",
        fails: .ambiguous("T"))
  }

  @Test func `a derived alias colliding with a base faults the schema path`()
      throws {
    // Schema ↔ run parity: the same collision faults `columns(of:)`, so the
    // schema is not advertised for a query the run rejects.
    #expect(throws: SQLError.ambiguous("T")) {
      let query = try parse(query:
          "SELECT a FROM T JOIN (SELECT V AS a FROM S) AS T ON 1 = 1")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a base relation colliding with a leading derived alias faults`()
      throws {
    // Reverse order — the derived table is the `FROM` item and the base `T` is
    // the JOIN — collides just the same, so a range name's collision does not
    // depend on which side spells the derived alias.
    try fixture().expect(
        "SELECT a FROM (SELECT V AS a FROM S) AS T JOIN T ON 1 = 1",
        fails: .ambiguous("T"))
  }

  @Test func `a base and leading derived collision faults the schema path`()
      throws {
    // Schema ↔ run parity for the reverse order.
    #expect(throws: SQLError.ambiguous("T")) {
      let query = try parse(query:
          "SELECT a FROM (SELECT V AS a FROM S) AS T JOIN T ON 1 = 1")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a derived alias colliding with a named alias faults`() throws {
    // The collision is on the RANGE NAME a qualified reference uses, so a base
    // relation renamed `d` (`FROM S AS d`) collides with a derived table
    // aliased `d` too — not the base's spelling `S`.
    try fixture().expect(
        "SELECT a FROM S AS d JOIN (SELECT V AS a FROM S) AS d ON 1 = 1",
        fails: .ambiguous("d"))
  }

  @Test func `a derived alias not colliding with any base resolves`() throws {
    // Control: a derived alias `d` that no FROM/JOIN range name shares resolves
    // — both its OWN column (`d.a`) and the sibling base relation's (`T.V`).
    try fixture().expect(
        "SELECT d.a, T.V FROM T JOIN (SELECT V AS a FROM S) AS d " +
        "ON d.a = T.V ORDER BY T.V",
        yields: [[10, 10], [20, 20], [30, 30]])
  }

  @Test func `a derived alias equal to an outer relation is not a collision`()
      throws {
    // Scoping, not a same-scope collision: an EXISTS subquery's derived table
    // aliased `T` sits in its OWN SELECT, whose only FROM range is that derived
    // `T` — the enclosing `FROM T` is a DIFFERENT SELECT's range. The inner `T`
    // shadows the outer per normal scoping, so `t.a` reads the derived rows and
    // no duplicate-range fault fires.
    try fixture().expect(
        "SELECT Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM (SELECT V AS a FROM S) AS T " +
                      "WHERE T.a = 10) ORDER BY Id",
        yields: [[1], [2], [3]])
  }

  @Test func `a derived alias colliding with an aliased base's source faults`()
      throws {
    // The base `T` is ALIASED `x`, so its EXPOSED range name is `x`, not `T` —
    // yet `resolve` looks the named relation up by its SOURCE name `T` in the
    // overlay. A derived table aliased `T` would bind under `T` and capture the
    // `T AS x` scan (which keys on `T`), so `x.V` fails or both sides scan the
    // derived rows. Fault the ALIAS ambiguous on the source-name collision,
    // BEFORE binding the derived rows.
    try fixture().expect(
        "SELECT x.V FROM T AS x JOIN (SELECT V AS a FROM S) AS T ON 1 = 1",
        fails: .ambiguous("T"))
  }

  @Test func `an aliased base's source collision faults the schema path`()
      throws {
    // Schema ↔ run parity: the source-name collision faults `columns(of:)` too.
    #expect(throws: SQLError.ambiguous("T")) {
      let query = try parse(query:
          "SELECT x.V FROM T AS x JOIN (SELECT V AS a FROM S) AS T ON 1 = 1")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a leading derived alias colliding with an aliased base source`()
      throws {
    // Reverse order — the derived `T` is the `FROM` item, the aliased base `T
    // AS x` the JOIN — collides on the source `T` just the same.
    try fixture().expect(
        "SELECT x.V FROM (SELECT V AS a FROM S) AS T JOIN T AS x ON 1 = 1",
        fails: .ambiguous("T"))
  }

  @Test func `the reverse aliased-base source collision faults the schema`()
      throws {
    // Schema ↔ run parity for the reverse order.
    #expect(throws: SQLError.ambiguous("T")) {
      let query = try parse(query:
          "SELECT x.V FROM (SELECT V AS a FROM S) AS T JOIN T AS x ON 1 = 1")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a derived alias not sharing an aliased base's source resolves`()
      throws {
    // Control: the base `T AS x`'s source `T` and its range `x` neither equal
    // the derived alias `d`, so `x.V` and `d`'s column both resolve — no
    // source-name collision fires for a derived alias no relation sources.
    try fixture().expect(
        "SELECT x.V, d.a FROM T AS x JOIN (SELECT V AS a FROM S) AS d " +
        "ON d.a = x.V ORDER BY x.V",
        yields: [[10, 10], [20, 20], [30, 30]])
  }
}

// MARK: - SELECT-scoped aliases

struct DerivedTableScopingTests {
  @Test func `sibling EXISTS subqueries reuse an alias without colliding`()
      throws {
    // Two INDEPENDENT derived tables share the alias `t` in two separate
    // `EXISTS` subqueries, each with DIFFERENT columns (`a` from `S`, `b` from
    // `K`). A statement-global overlay bound only the FIRST `t`, so the second
    // `EXISTS`'s `t.b` would mis-resolve to the first `t` (no `b`) and fault.
    // SELECT-scoped, each `t` resolves to its OWN derived table: both
    // subqueries are TRUE (S has V=10, K has k=1), so every `T` row is kept.
    try fixture().expect(
        "SELECT Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM (SELECT V AS a FROM S) AS t " +
                      "WHERE t.a = 10) " +
        "AND EXISTS (SELECT 1 FROM (SELECT k AS b FROM K) AS t " +
                    "WHERE t.b = 1) ORDER BY Id",
        yields: [[1], [2], [3]])
  }

  @Test func `sibling derived tables reuse an alias reading their own rows`()
      throws {
    // Each sibling `t` reads its OWN rows: the first `EXISTS` filters `t.a` to
    // a value only `S` has (30) and the second `t.b` to one only `K` has (2),
    // so both hold and the outer query keeps its row — proof each `t` bound its
    // own materialised relation, not a shared one.
    try fixture().expect(
        "SELECT Id FROM T WHERE Id = 1 " +
        "AND EXISTS (SELECT 1 FROM (SELECT V AS a FROM S) AS t " +
                    "WHERE t.a = 30) " +
        "AND EXISTS (SELECT 1 FROM (SELECT k AS b FROM K) AS t " +
                    "WHERE t.b = 2)",
        yields: [[1]])
  }

  @Test func `an inner derived table shadows an outer CTE of the same name`()
      throws {
    // A CTE `t` is in scope statement-wide, but a derived table aliased `t` in
    // an inner `FROM` SHADOWS it within that SELECT: the derived `t(a)` reads
    // `S`'s `V` renamed, not the CTE's single row `99`. So `SELECT a` yields
    // the three `S` values, never the CTE's `99` (no column `a`). A `WITH` is
    // a statement, so run it through the statement entry rather than the
    // query-only `expect`.
    let statement = try Statement(parsing:
        "WITH t(x) AS (SELECT 99) " +
        "SELECT a FROM (SELECT V AS a FROM S) AS t ORDER BY a")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(10)], [.integer(20)], [.integer(30)]])
  }
}

// MARK: - A nested subquery's own derived alias shadows an enclosing one

/// A nested subquery's OWN derived alias must SHADOW an enclosing same-named
/// derived table, resolving its OWN body's columns rather than the outer one's.
/// Idempotence keys on the derivation's IDENTITY, not its name: an enclosing
/// query's derived `t` in scope is re-materialised over by the subquery's own
/// `t` (a DIFFERENT inner query), while a re-augment of THIS query's SAME
/// derivation is left in place — and a same-named CTE stays visible.
struct DerivedTableNestedShadowTests {
  @Test func `a nested EXISTS subquery derived alias shadows an outer one`()
      throws {
    // The outer `FROM (SELECT Id AS x FROM T) AS t` binds a derived `t` with
    // column `x`; the `EXISTS` subquery's OWN `FROM (SELECT V AS a FROM S) AS
    // t` binds a derived `t` with column `a`. The subquery's `WHERE t.a = 10`
    // must resolve the INNER `t` (column `a`, a value only `S`'s 10 has), never
    // the outer `t` (column `x`). Keying idempotence on the name skipped the
    // inner materialise, so `t.a` mis-resolved to the outer `t`; keying on the
    // derivation's identity re-materialises the inner `t`, so the subquery is
    // TRUE and every outer row is kept.
    try fixture().expect(
        "SELECT x FROM (SELECT Id AS x FROM T) AS t " +
        "WHERE EXISTS (SELECT 1 FROM (SELECT V AS a FROM S) AS t " +
                      "WHERE t.a = 10) ORDER BY x",
        yields: [[1], [2], [3]])
  }

  @Test func `the nested-shadow query advertises the outer schema`() throws {
    // Schema ↔ run parity: `columns(of:)` resolves the inner `t.a` too (never
    // faulting on the outer `t`'s missing `a`), and the RESULT columns are the
    // OUTER query's projection `x` — the enclosing derived `t`'s column.
    let query = try parse(query:
        "SELECT x FROM (SELECT Id AS x FROM T) AS t " +
        "WHERE EXISTS (SELECT 1 FROM (SELECT V AS a FROM S) AS t " +
                      "WHERE t.a = 10)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["x"])
  }

  @Test func `a nested EXISTS shadow reads the inner rows`() throws {
    // The inner `t` reads ITS own rows, not the outer's: `WHERE t.a = 30`
    // filters to a value only `S` has (30), so the subquery holds; had it
    // resolved the outer `t` (column `x` = the `Id`s 1, 2, 3), `t.a` would
    // fault. One outer row is kept.
    try fixture().expect(
        "SELECT x FROM (SELECT Id AS x FROM T) AS t WHERE x = 1 " +
        "AND EXISTS (SELECT 1 FROM (SELECT V AS a FROM S) AS t " +
                    "WHERE t.a = 30)",
        yields: [[1]])
  }

  @Test func `a nested scalar subquery derived alias shadows an outer one`()
      throws {
    // A SCALAR-subquery variant: the outer `FROM (SELECT Id AS x FROM T) AS t`
    // binds derived `t(x)`; the projection's scalar `(SELECT MIN(t.a) FROM
    // (SELECT V AS a FROM S) AS t)` binds its OWN derived `t(a)`. The scalar's
    // `t.a` must resolve the INNER `t` (column `a`), yielding `S`'s minimum 10
    // for every outer row — proof the inner alias shadowed the outer.
    try fixture().expect(
        "SELECT x, (SELECT MIN(t.a) FROM (SELECT V AS a FROM S) AS t) " +
        "FROM (SELECT Id AS x FROM T) AS t ORDER BY x",
        yields: [[1, 10], [2, 10], [3, 10]])
  }
}

// MARK: - Nested derived tables

struct DerivedTableNestingTests {
  @Test func `a derived table nested in a derived table resolves and runs`()
      throws {
    // `FROM (SELECT * FROM (SELECT V FROM S) AS x) AS y` — deriving `y`'s
    // schema must FIRST bind its OWN inner derived table `x`, as the run does,
    // or `x` resolves as unknown. Both the schema and the run resolve the
    // projected column `V` and read `S`'s rows through the two levels.
    let query =
        try parse(query: "SELECT * FROM (SELECT * FROM (SELECT V FROM S) " +
                         "AS x) AS y")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["V"])
    try fixture().expect(
        "SELECT V FROM (SELECT * FROM (SELECT V FROM S) AS x) AS y " +
        "ORDER BY V",
        yields: [[10], [20], [30]])
  }

  @Test func `a nested derived table filters through both levels`() throws {
    // The nested derived table's rows flow up unchanged: a `WHERE` on the
    // outer derived column filters the same rows the inner projected.
    try fixture().expect(
        "SELECT V FROM (SELECT V FROM (SELECT V FROM S) AS x) AS y " +
        "WHERE V > 10 ORDER BY V",
        yields: [[20], [30]])
  }
}

// MARK: - Schema/run validation parity

struct DerivedTableSchemaParityTests {
  @Test func `a bad inner predicate faults the schema-only path`() throws {
    // The inner body's `WHERE Missing = 1` names an unknown column. The
    // schema-only path (`validate: true`) compiles and type-checks the WHOLE
    // inner body — not just the first-arm projection — so it FAULTS the unknown
    // column exactly as the run does, keeping schema/run parity.
    #expect(throws: SQLError.self) {
      let query = try parse(query:
          "SELECT t.a FROM (SELECT V AS a FROM S WHERE Missing = 1) AS t")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a bad inner predicate faults the run too`() throws {
    // Typecheck ↔ run parity: the same bad inner predicate column faults the
    // run.
    try fixture().expect(
        "SELECT t.a FROM (SELECT V AS a FROM S WHERE Missing = 1) AS t",
        fails: .column("Missing"))
  }

  @Test func `a bad inner column outside the first arm faults the schema path`()
      throws {
    // The inner body's bad column is in a later `UNION` arm, which the
    // first-arm projection derive never sees; the whole-body compile the
    // schema-only path now runs catches it, matching the run.
    #expect(throws: SQLError.self) {
      let query = try parse(query:
          "SELECT t.a FROM (SELECT V AS a FROM S " +
          "UNION SELECT Missing AS a FROM S) AS t")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a valid inner body still advertises its schema`() throws {
    // A derived table whose inner body has a WELL-FORMED predicate still
    // reports its schema on the schema-only path — the whole-body validation
    // accepts exactly what runs, so a valid body is not rejected.
    let query = try parse(query:
        "SELECT t.a FROM (SELECT V AS a FROM S WHERE V > 10) AS t")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "a")
    #expect(columns[0].type == .integer)
  }

  @Test func `validate false skips a derived body's operand check`() throws {
    // A derived body whose projection `Label + 1` faults ONLY when type-checked
    // (text plus integer), guarded by `WHERE k = 0` so the run empties before
    // it evaluates. With `validate: false` — a derive after a successful run —
    // the body is TRUSTED, so headers return WITHOUT the operand fault, exactly
    // as the NON-derived path does (its empty run never evaluates the
    // projection). An earlier round validated the body unconditionally, so this
    // faulted `.operand` before returning headers.
    let query = try parse(query:
        "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d")
    let columns = try fixture().columns(of: query, validate: false)
    #expect(columns.map(\.name) == ["x"])
  }

  @Test func `validate true still faults a bad derived body`() throws {
    // Parity with a run: with `validate: true` the SAME body still faults its
    // ill-typed projection, so the schema path advertises no schema for a
    // derived table a run would fault once it reached the projection.
    #expect(throws: SQLError.self) {
      let query = try parse(query:
          "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d")
      _ = try fixture().columns(of: query, validate: true)
    }
  }
}

// MARK: - A run must not eager-type-check a derived body

/// A RUN preflight (`compile`) must NOT eager-type-check a derived body: an
/// expression a data-dependent filter never reaches is lenient at run — the
/// executor faults only on an expression a SURVIVING row evaluates, exactly as
/// the NON-derived query does. The eager body type-check stays for the EXPLICIT
/// schema path (`columns(of:validate:true)`), which stays strict.
struct DerivedTableRunLenienceTests {
  @Test func `a filtered-out ill-typed body runs to zero rows`() throws {
    // `FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d` — the body's text
    // arithmetic `Label + 1` faults ONLY when evaluated, but `WHERE k = 0` (no
    // `K` row has `k = 0`) empties the derived table before the projection
    // runs. The run preflight compiles the OUTER query WITHOUT eager-type-
    // checking the derived body, so the run returns ZERO rows rather than
    // faulting `.operand` — an earlier round rejected it before materialising.
    try fixture().empty(
        "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d")
  }

  @Test func `the derived form matches the non-derived form`() throws {
    // Parity with the non-derived query: `SELECT Label + 1 FROM K WHERE k = 0`
    // also runs to zero rows (the filter drops every row before the
    // projection). The derived-table wrapper must behave identically — empty.
    try fixture().empty("SELECT Label + 1 FROM K WHERE k = 0")
  }

  @Test func `columns validate true still faults the filtered-out body`()
      throws {
    // The EXPLICIT schema path stays STRICT: `columns(of:validate:true)` on the
    // SAME body still faults `.operand`, so a caller asking to validate the
    // schema gets the ill-typed projection rejected even though a run empties.
    #expect(throws: SQLError.operand("operands must be numeric")) {
      let query = try parse(query:
          "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a reached ill-typed body still faults at run`() throws {
    // Lenient is NOT never: a body whose `WHERE` KEEPS a row (`k = 1` matches
    // `K`'s first row) reaches the ill-typed `Label + 1` at run, so the
    // executor faults `.operand` — only an UNEVALUATED expression is spared.
    try fixture().expect(
        "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 1) AS d",
        fails: .operand("operands must be numeric"))
  }
}

// MARK: - A WITH trailing query threads validate to a derived body

/// The `WITH` schema path (`columns(of statement:)`) must thread `validate` to
/// its trailing query's derived tables exactly as the non-`WITH` path does: a
/// `validate: false` derive after a successful run TRUSTS a derived body a
/// filter empties rather than re-type-checking it, while `validate: true` stays
/// strict.
struct DerivedTableWithValidateThreadingTests {
  @Test func `validate false trusts a filtered-out body in the trailing query`()
      throws {
    // The trailing query wraps the SAME filtered-out ill-typed body under a
    // `WITH`. A run empties (the body never evaluates `Label + 1`); a
    // `validate: false` derive after that run must return the headers WITHOUT
    // the `.operand` fault, matching the non-`WITH` path. The `WITH` path
    // re-augmented the trailing query's derived table with the DEFAULT
    // `validate: true` before this fix, so it still faulted `.operand`.
    let statement = try Statement(parsing:
        "WITH c(x) AS (SELECT 1) " +
        "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d")
    let rows = try fixture().run(statement, .standard)
    #expect(rows.isEmpty)
    let columns = try fixture().columns(of: statement, validate: false)
    #expect(columns.map(\.name) == ["x"])
  }

  @Test func `validate true still faults the trailing query's body`() throws {
    // The EXPLICIT schema path stays STRICT under `WITH` too: `validate: true`
    // on the same trailing-query body still faults its ill-typed projection.
    #expect(throws: SQLError.operand("operands must be numeric")) {
      let statement = try Statement(parsing:
          "WITH c(x) AS (SELECT 1) " +
          "SELECT * FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d")
      _ = try fixture().columns(of: statement, validate: true)
    }
  }
}

// MARK: - Uncorrelated boundary

struct DerivedTableCorrelationTests {
  @Test func `a derived table referencing an outer column faults`() throws {
    // PR-3 is UNCORRELATED: the inner query resolves against the base catalog,
    // NOT its sibling/outer FROM items, so a reference to the outer `T.Id`
    // resolves as an unknown column (no LATERAL yet).
    try fixture().expect(
        "SELECT T.Id FROM T " +
        "JOIN (SELECT V AS v FROM S WHERE V = T.Id) AS d ON T.Id = d.v",
        fails: .column("Id"))
  }

  @Test func `a derived table referencing a sibling column faults`() throws {
    // A reference to a sibling derived table's column is likewise unknown —
    // the inner query sees neither its outer nor its sibling FROM items.
    try fixture().expect(
        "SELECT a.v FROM (SELECT V AS v FROM S) AS a " +
        "JOIN (SELECT a.v AS w FROM S) AS b ON a.v = b.w",
        fails: .column("v"))
  }
}

// MARK: - No correlation into an ENCLOSING row (non-LATERAL, under a subquery)

/// A non-LATERAL derived table nested inside a CORRELATED subquery must NOT see
/// the enclosing query's row either — the same no-LATERAL rule a sibling
/// reference obeys applies outward across the enclosing subquery boundary.
///
/// Folding the correlation stack into `Context` made the derived-body scope
/// inherit the enclosing subquery's `outer`, so the STRICT schema/typecheck
/// pass bound the derived body's `T.k` to the caller's row while the lenient
/// run shape pass recorded NO correlation for it and then FAULTED at execution
/// — a schema/run MISMATCH. Clearing the correlation stack entering derived
/// materialisation restores the documented no-LATERAL behaviour: the derived
/// body cannot see `T.k`, so BOTH passes fault CONSISTENTLY.
struct DerivedTableEnclosingCorrelationTests {
  /// An outer `T` and an inner `S`, each with a `k` a derived body would try to
  /// equate — so the leak, had it bound, would have compiled.
  private func keyed() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["k": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("S", ["k": .integer]) {
        Row(1)
      }
    }
  }

  @Test func `a derived body under a correlated IN cannot see the outer row`()
      throws {
    // `… 1 IN (SELECT x FROM (SELECT 1 AS x FROM S WHERE S.k = T.k) AS d)` —
    // the `IN` subquery correlates against `T`, but the derived body `d` is
    // non-LATERAL, so its `T.k` is an unknown column at BOTH the schema pass
    // and the run, never bound outward to the caller's row.
    let sql =
        "SELECT k FROM T " +
        "WHERE 1 IN (SELECT x FROM " +
        "(SELECT 1 AS x FROM S WHERE S.k = T.k) AS d)"
    try keyed().expect(sql, fails: .column("k"))
  }

  @Test func `the schema pass faults the derived body exactly as the run does`()
      throws {
    // Schema ↔ run parity: the STRICT `columns(of:)` pass faults the derived
    // body's `T.k` too, rather than binding it while the run faults — the
    // mismatch the leak introduced.
    let query = try parse(query:
        "SELECT k FROM T " +
        "WHERE 1 IN (SELECT x FROM " +
        "(SELECT 1 AS x FROM S WHERE S.k = T.k) AS d)")
    #expect(throws: SQLError.self) {
      _ = try keyed().columns(of: query, validate: true)
    }
  }

  @Test func `a non-correlated derived body under a subquery still runs`()
      throws {
    // Control: the SAME shape with an UNCORRELATED derived body (`S.k = 1`, no
    // outer reference) resolves and runs — clearing the correlation stack does
    // not disturb a legitimate derived table. `1 IN {1}` keeps every `T` row.
    try keyed().expect(
        "SELECT k FROM T " +
        "WHERE 1 IN (SELECT x FROM " +
        "(SELECT 1 AS x FROM S WHERE S.k = 1) AS d) ORDER BY k",
        yields: [[1], [2]])
  }
}

// MARK: - Set-operation arm scoping

/// A derived table's alias is scoped to the ARM that names it: a `setop` never
/// hoists both arms' derived aliases into one shared map, so a left arm's
/// `FROM T` resolves the base relation (or a same-named CTE), never a
/// `derived T` the right arm named.
struct DerivedTableSetOperationScopingTests {
  @Test func `a set-op arm derived alias does not bind the other arm`()
      throws {
    // The RIGHT arm names a derived table aliased `T`; the LEFT arm's `FROM T`
    // must resolve the BASE `T` (columns `Id`, `V`), NOT the right arm's
    // `derived T` (whose only column is `a`). Hoisting both arms into one map
    // bound the right `T` query-wide, so `SELECT Id FROM T` faulted on the
    // unknown `Id`. Per-arm scoping keeps the base `T`, so the left arm scans
    // its rows and `UNION ALL` appends the right arm's.
    // `UNION ALL` keeps arm order, so no trailing sort is needed (and a bare
    // union's `ORDER BY` would bind to the right arm's select, not the union).
    try fixture().expect(
        "SELECT Id FROM T " +
        "UNION ALL SELECT a FROM (SELECT V AS a FROM S) AS T",
        yields: [[1], [2], [3], [10], [20], [30]])
  }

  @Test func `a set-op arm resolves a CTE the other arm shadows`() throws {
    // A statement CTE `T(Id)` is in scope for both arms; the RIGHT arm shadows
    // it within its own scope with a `derived T`. The LEFT arm's `FROM T` must
    // resolve the CTE (rows 100, 200), never the right arm's derived `T`. A
    // shared arm map bound the right `T` query-wide, hiding the CTE from the
    // left arm.
    let statement = try Statement(parsing:
        "WITH T(Id) AS (SELECT 100 UNION ALL SELECT 200) " +
        "SELECT Id FROM T " +
        "UNION ALL SELECT a FROM (SELECT V AS a FROM S) AS T")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(100)], [.integer(200)],
                     [.integer(10)], [.integer(20)], [.integer(30)]])
  }

  @Test func `a set-op arm derived alias is invisible at the schema path too`()
      throws {
    // Schema ↔ run parity: `columns(of:)` derives the first (left) arm's
    // projection against the BASE `T`, so the result column is `Id`, not the
    // right arm's `a`.
    let query = try parse(query:
        "SELECT Id FROM T " +
        "UNION ALL SELECT a FROM (SELECT V AS a FROM S) AS T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["Id"])
  }
}

// MARK: - No LATERAL: sibling FROM items are invisible

/// A derived table is UNCORRELATED/no-LATERAL: its inner query resolves against
/// the enclosing OUTER scope only, so a sibling `FROM`/`JOIN` item is invisible
/// inside it.
struct DerivedTableSiblingVisibilityTests {
  @Test func `a derived table cannot read an earlier sibling as a relation`()
      throws {
    // `FROM (…) AS a JOIN (SELECT v FROM a) AS b` — `b`'s inner query names the
    // SIBLING `a` as a relation. Threading the accumulating sibling map let
    // `b` read `a` as a CTE; the outer-scope-only rule now faults on the
    // unknown relation `a` (no LATERAL).
    try fixture().expect(
        "SELECT b.v FROM (SELECT V AS v FROM S) AS a " +
        "JOIN (SELECT v FROM a) AS b ON a.v = b.v",
        fails: .relation("a"))
  }

  @Test func `a sibling-reading derived table faults the schema path too`()
      throws {
    // Schema ↔ run parity: the same sibling reference faults `columns(of:)`,
    // so the schema is not advertised for a query the run rejects.
    #expect(throws: SQLError.self) {
      let query = try parse(query:
          "SELECT b.v FROM (SELECT V AS v FROM S) AS a " +
          "JOIN (SELECT v FROM a) AS b ON a.v = b.v")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `independent sibling derived tables both resolve`() throws {
    // Control: two sibling derived tables that do NOT reference each other
    // still resolve and run — each materialises against the shared outer scope
    // (the base catalog), so both read `S` and join on their own columns.
    try fixture().expect(
        "SELECT a.v FROM (SELECT V AS v FROM S) AS a " +
        "JOIN (SELECT V AS w FROM S) AS b ON a.v = b.w ORDER BY a.v",
        yields: [[10], [20], [30]])
  }
}

// MARK: - Self-named derived alias resolves the base relation in its body

/// A derived alias may share the name of the BASE relation its own body
/// references — `(SELECT … FROM T) AS T`. Its body's `FROM T` must resolve the
/// BASE `T`, never the derived alias itself, on BOTH the schema-only and the
/// run paths: `augment` materialises the body against the alias-free outer
/// scope, so the run→compile double augmentation is IDEMPOTENT (the second
/// pass, whose context already binds the derived `T`, still reads the base).
struct DerivedTableSelfNamedAliasTests {
  @Test func `a derived alias resolves the base relation its body names`()
      throws {
    // `(SELECT Id AS a FROM T) AS T` — the inner `FROM T` reads the BASE `T`
    // (columns `Id`, `V`), projecting `Id AS a`, and the derived alias is also
    // `T`. Before the idempotent fix the schema-only augment re-materialised
    // the body against the already-bound one-column derived `T`, faulting
    // `.column("Id")`; now the body resolves the base `T` on both paths.
    try fixture().expect(
        "SELECT a FROM (SELECT Id AS a FROM T) AS T ORDER BY a",
        yields: [[1], [2], [3]])
  }

  @Test func `a self-named derived alias advertises its schema`() throws {
    // Schema ↔ run parity: `columns(of:)` derives the body against the base
    // `T`, so the result column is the inner projection `a`, not a fault.
    let query =
        try parse(query: "SELECT a FROM (SELECT Id AS a FROM T) AS T")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "a")
    #expect(columns[0].type == .integer)
  }

  @Test func `a self-named derived alias under a JOIN reads the base`() throws {
    // A variant where the inner body references the base relation by the SAME
    // name as the alias, joined to another relation: `(SELECT Id AS k FROM T)
    // AS T` joined to `K` on the key. The inner `FROM T` still resolves the
    // base `T`, so the join pairs `K.k` with the base rows (1, 2).
    try fixture().expect(
        "SELECT T.k, K.Label FROM (SELECT Id AS k FROM T) AS T " +
        "JOIN K ON K.k = T.k ORDER BY T.k",
        yields: [[1, "a"], [2, "b"]])
  }
}

// MARK: - Set-op SELECT * arity resolves an arm's own derived aliases

/// A set operation's `SELECT *` arm resolves its OWN derived aliases for the
/// cross-arm arity check. The top-level augment collects NO arm-local
/// derivations (arms are scoped), so the star-arity check augments each arm's
/// own aliases into a PER-ARM scope first — per arm, so a left arm's alias
/// never leaks to the right — matching what each arm produces at run.
struct DerivedTableSetOperationStarTests {
  @Test func `a set-op SELECT * arm resolves its own derived table`() throws {
    // `SELECT * FROM (SELECT V FROM S) AS d UNION ALL SELECT V FROM S` — the
    // left `SELECT *` spans the arm-local derived `d` (one column `V`). Before
    // the fix the star-arity check ran with no arm-local binding and faulted on
    // the unknown relation `d`; now it augments `d` per arm, so both arms are
    // one column wide and the union appends `S`'s rows to themselves.
    // `UNION ALL` keeps arm order (a bare union's `ORDER BY` binds the last
    // arm's select, not the union), so no trailing sort is used.
    try fixture().expect(
        "SELECT * FROM (SELECT V FROM S) AS d UNION ALL SELECT V FROM S",
        yields: [[10], [20], [30], [10], [20], [30]])
  }

  @Test func `a set-op SELECT * arm advertises its arity at the schema path`()
      throws {
    // Schema ↔ run parity: `columns(of:)` compiles the whole set operation, so
    // the star arm's width (derived `d`'s one column) matches the other arm's,
    // and the result column is the first arm's `V`.
    let query = try parse(query:
        "SELECT * FROM (SELECT V FROM S) AS d UNION ALL SELECT V FROM S")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["V"])
  }

  @Test func `a set-op SELECT * in the right arm resolves its own derived`()
      throws {
    // A variant with the derived table in the RIGHT arm's `SELECT *`: the left
    // arm is a plain `SELECT V FROM S`, the right `SELECT * FROM (SELECT V FROM
    // S) AS d`. The right arm's `d` must resolve for its star arity (one
    // column), so the arities match and the union runs.
    try fixture().expect(
        "SELECT V FROM S UNION ALL SELECT * FROM (SELECT V FROM S) AS d",
        yields: [[10], [20], [30], [10], [20], [30]])
  }

  @Test func `a set-op arm star derived alias does not leak to the other arm`()
      throws {
    // No leak: the left arm's derived `d` is scoped to that arm, so the right
    // arm's own `SELECT * FROM (…) AS d` resolves ITS own `d` — both arms name
    // `d` for their own derived table without colliding. A one-column output
    // each, so the union runs. (`UNION ALL` keeps arm order; the right arm
    // reads `T`'s `V` values 10, 20, 30.)
    try fixture().expect(
        "SELECT * FROM (SELECT V FROM S) AS d " +
        "UNION ALL SELECT * FROM (SELECT V FROM T) AS d",
        yields: [[10], [20], [30], [10], [20], [30]])
  }
}

// MARK: - Cyclic-view guard through derived-table materialisation

/// A catalog with a CYCLIC view — `Loop`'s body reaches back to itself through
/// a derived table — and a NON-cyclic view `Src` over the base `S`. Resolving
/// `Loop` must fault `.recursion`, not recurse to a stack overflow; `Src`
/// resolves as any other view.
private func views() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["V": .integer]) {
      Row(10)
      Row(20)
      Row(30)
    }
    // A view whose body names itself through a derived table.
    try View("Loop", "SELECT * FROM (SELECT * FROM Loop) AS d", as: ["V"])
    // A well-formed view a derived table can resolve.
    try View("Src", "SELECT V FROM S", as: ["V"])
  }
}

// MARK: - A derived alias preserves a same-named CTE (and base tables)

/// Stripping a derived alias from the scope its body resolves against must drop
/// ONLY the derived binding, KEEPING a same-named CTE (or base table): the
/// alias being defined is out of scope in its own body, but an enclosing CTE of
/// that name is visible. A blanket name-drop removed the CTE too, so a
/// CTE-shadowing derived body faulted.
struct DerivedTableCTEShadowTests {
  @Test func `a derived body resolves an enclosing CTE of its own alias name`()
      throws {
    // `WITH t(x) AS (SELECT 1) SELECT * FROM (SELECT x FROM t) AS t` — the
    // inner `FROM t` is inside the derived table ALSO aliased `t`; the alias
    // being defined is out of scope in its own body, so `t` resolves the CTE
    // (projecting its `x` = 1), not the derived table itself. A name-blanket
    // drop removed the CTE, faulting `.relation("t")` (or resolving a base).
    let statement = try Statement(parsing:
        "WITH t(x) AS (SELECT 1) SELECT * FROM (SELECT x FROM t) AS t")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)]])
  }

  @Test func `the CTE-shadowing derived body advertises its schema`() throws {
    // Schema ↔ run parity: `columns(of:)` derives the body against the CTE `t`
    // too, so the result column is the CTE's `x`, resolved rather than faulted.
    let statement = try Statement(parsing:
        "WITH t(x) AS (SELECT 1) SELECT * FROM (SELECT x FROM t) AS t")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.map(\.name) == ["x"])
  }

  @Test func `a self-named derived body over a base table reads the base`()
      throws {
    // Control (no CTE): the SAME shape over the BASE relation `T` resolves the
    // base — the body's `FROM T` reads columns `Id`, `V`, projecting `Id`, and
    // the derived alias is also `T`. Dropping only the derived binding leaves
    // the base reachable (a base table is not in the overlay), so this is the
    // round-2/3 behaviour intact.
    try fixture().expect(
        "SELECT Id FROM (SELECT Id FROM T) AS T ORDER BY Id",
        yields: [[1], [2], [3]])
  }

  @Test func `a sibling derived alias stays invisible to a CTE-shadowing body`()
      throws {
    // A sibling derived alias remains invisible (round-2), yet a same-named CTE
    // is visible: a CTE `a(v)` (one row 7) is in scope, a sibling `FROM (…) AS
    // a` binds a derived `a` (three rows), and `b`'s body `FROM a` must read
    // the CTE `a`, NOT the sibling derived `a`. So `b` yields the CTE's single
    // 7 and the cross join to the three-row sibling `a` gives 7 three times;
    // had `b` read the sibling derived `a` it would be three rows, product 9.
    let statement = try Statement(parsing:
        "WITH a(v) AS (SELECT 7) " +
        "SELECT b.v FROM (SELECT V AS v FROM S) AS a " +
        "JOIN (SELECT v FROM a) AS b ON b.v = b.v ORDER BY b.v")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(7)], [.integer(7)], [.integer(7)]])
  }
}

// MARK: - A CTE shadowed by a derived alias stays visible to a lazy scalar

/// A LAZY scalar subquery resolves against the PRE-AUGMENT scope, exactly as
/// the eager `EXISTS`/`IN (Q)` subqueries do. For `WITH d(x) AS (…) SELECT
/// (SELECT x FROM d) FROM (SELECT y FROM T) AS d`, the derived `d` OVERWRITES
/// the CTE `d` in the executor's augmented overlay before the lazy scalar runs;
/// resolving the scalar against that overlay (subscoped) could not restore the
/// hidden CTE, faulting `.relation("d")`. Threading the pre-augment scope — the
/// one the eager paths ran against, CTEs intact — lets the scalar read the CTE.
struct DerivedTableCTEShadowScalarTests {
  @Test func `a lazy scalar reads a CTE a derived alias shadows`() throws {
    // The scalar `(SELECT x FROM d)` reads the CTE `d` (one row, x = 1), NOT
    // the shadowing derived `d`; the outer FROM's derived `d` yields three rows
    // (T's Ids), so each output row is the CTE's 1.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) " +
        "SELECT (SELECT x FROM d) FROM (SELECT Id AS y FROM T) AS d")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)], [.integer(1)], [.integer(1)]])
  }

  @Test func `the CTE-shadowing lazy scalar advertises its schema`() throws {
    // Schema ↔ run parity: `columns(of:)` derives the scalar against the CTE
    // `d` too, so the projection resolves rather than faulting `.relation`.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) " +
        "SELECT (SELECT x FROM d) FROM (SELECT Id AS y FROM T) AS d")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.count == 1)
  }

  @Test func `an eager EXISTS reads a CTE a derived alias shadows`() throws {
    // Parity check: the eager `EXISTS` path already reads the CTE `d` (round
    // 8/9). `EXISTS (SELECT 1 FROM d)` over the CTE `d` (non-empty) is TRUE for
    // every outer row, so all three derived `d` rows survive — the behaviour
    // the lazy scalar now matches.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) " +
        "SELECT y FROM (SELECT Id AS y FROM T) AS d " +
        "WHERE EXISTS (SELECT 1 FROM d) ORDER BY y")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `an eager IN reads a CTE a derived alias shadows`() throws {
    // Parity check for the `IN (Q)` eager role: `Id IN (SELECT x FROM d)` folds
    // over the CTE `d`'s single value 1, so only the derived row with Id = 1
    // survives — the CTE, not the shadowing derived `d`, feeds the membership.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) " +
        "SELECT y FROM (SELECT Id AS y FROM T) AS d " +
        "WHERE y IN (SELECT x FROM d) ORDER BY y")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a lazy scalar over the shadowing derived alias itself works`()
      throws {
    // Control: a scalar subquery that DOES name the shadowing derived `d`
    // resolves it where intended. Here the scalar `(SELECT MAX(y) FROM e)`
    // reads a DIFFERENT derived alias `e`, and the outer derived `d` (aliased
    // to avoid the source `T` collision) drives the rows; the scalar collapses
    // to MAX = 3, so each of the three rows carries 3.
    let statement = try Statement(parsing:
        "WITH c(x) AS (SELECT 1) " +
        "SELECT (SELECT MAX(y) FROM (SELECT Id AS y FROM T) AS e) " +
        "FROM (SELECT Id FROM T) AS d")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(3)], [.integer(3)], [.integer(3)]])
  }
}

// MARK: - A CTE body threads validate to its own derived tables (round 14)

/// A CTE (`WITH`) body's OWN derived tables must be validated with the same
/// leniency the run uses: `with` validates a CTE with `typecheck: false` (defer
/// operand checks to execution), so the CTE-body's schema-only `augment`/
/// `compile` must derive a nested derived table with `validate: false` too — a
/// data-dependent-empty body a filter drops must not fault a CTE that runs
/// empty, exactly as the equivalent non-derived CTE runs. The strict schema
/// path (`typecheck: true`) keeps the eager body type-check.
struct DerivedTableCTEBodyValidateThreadingTests {
  @Test func `a filtered-out body in a CTE runs to zero rows`() throws {
    // The reviewer's case: the CTE `c(x)`'s body wraps the SAME filtered-out
    // ill-typed derived table (`Label + 1` under `WHERE k = 0`, which drops
    // every `K` row). A run must empty rather than fault `.operand` — the CTE
    // validation threaded `typecheck: false`, so the CTE-body's derived table
    // derives with `validate: false`. Before the fix the CTE-body augment/
    // compile defaulted to `validate: true` and faulted during validation.
    let statement = try Statement(parsing:
        "WITH c(x) AS (SELECT x FROM " +
        "(SELECT Label + 1 AS x FROM K WHERE k = 0) AS d) SELECT * FROM c")
    let rows = try fixture().run(statement, .standard)
    #expect(rows.isEmpty)
  }

  @Test func `the CTE form matches the non-derived CTE`() throws {
    // Parity: the equivalent CTE whose body is NON-derived
    // (`SELECT Label + 1 AS x FROM K WHERE k = 0`) also runs to zero rows — the
    // filter drops every row before the projection. The derived-table wrapper
    // inside the CTE body must behave identically.
    let derived = try Statement(parsing:
        "WITH c(x) AS (SELECT x FROM " +
        "(SELECT Label + 1 AS x FROM K WHERE k = 0) AS d) SELECT * FROM c")
    let plain = try Statement(parsing:
        "WITH c(x) AS (SELECT Label + 1 AS x FROM K WHERE k = 0) " +
        "SELECT * FROM c")
    let lhs = try fixture().run(derived, .standard)
    let rhs = try fixture().run(plain, .standard)
    #expect(lhs.isEmpty)
    #expect(lhs == rhs)
  }

  @Test func `columns validate false returns the CTE headers`() throws {
    // A `validate: false` derive after the run TRUSTS the CTE-body's derived
    // table rather than eager-type-checking it, so it returns the trailing
    // query's headers WITHOUT the `.operand` fault.
    let statement = try Statement(parsing:
        "WITH c(x) AS (SELECT x FROM " +
        "(SELECT Label + 1 AS x FROM K WHERE k = 0) AS d) SELECT * FROM c")
    let columns = try fixture().columns(of: statement, validate: false)
    #expect(columns.map(\.name) == ["x"])
  }

  @Test func `columns validate true still faults the CTE body`() throws {
    // The EXPLICIT schema path stays STRICT: `validate: true` threads
    // `typecheck: true` into the CTE validation, so the CTE-body's derived
    // table is eager-type-checked and its ill-typed `Label + 1` still faults
    // `.operand`.
    #expect(throws: SQLError.operand("operands must be numeric")) {
      let statement = try Statement(parsing:
          "WITH c(x) AS (SELECT x FROM " +
          "(SELECT Label + 1 AS x FROM K WHERE k = 0) AS d) SELECT * FROM c")
      _ = try fixture().columns(of: statement, validate: true)
    }
  }

  @Test func `a reached ill-typed body in a CTE still faults at run`() throws {
    // Lenient is NOT never: a CTE-body derived table whose `WHERE` KEEPS a row
    // (`k = 1` matches `K`'s first row) reaches the ill-typed `Label + 1` at
    // run, so the executor faults `.operand` — only an UNEVALUATED body is
    // spared.
    let statement = try Statement(parsing:
        "WITH c(x) AS (SELECT x FROM " +
        "(SELECT Label + 1 AS x FROM K WHERE k = 1) AS d) SELECT * FROM c")
    #expect(throws: SQLError.operand("operands must be numeric")) {
      _ = try fixture().run(statement, .standard)
    }
  }
}

// MARK: - A subquery body threads validate to its own derived tables (sweep)

/// The unifying sweep found `subquery(of:)` compiled an `EXISTS`/`IN (Q)`/
/// scalar subquery's body with the DEFAULT `validate: true`, so a filtered-out
/// derived table NESTED in a subquery body leaked the eager type-check onto the
/// RUN path. `compile(select)`/`group`/`subquery(of:)` now thread `validate`,
/// so a run derives a subquery-body derived table LENIENTLY while a schema
/// check keeps it strict.
struct DerivedTableSubqueryBodyValidateThreadingTests {
  @Test func `a filtered-out body in an EXISTS subquery runs`() throws {
    // The `EXISTS` subquery's body nests the SAME filtered-out ill-typed
    // derived table. The subquery has no surviving row, so the `EXISTS` is
    // FALSE and the outer query keeps no row — but it must not FAULT `.operand`
    // during the run preflight. Before the sweep `subquery(of:)` eager-type-
    // checked the derived body and faulted.
    try fixture().empty(
        "SELECT Id FROM T WHERE EXISTS " +
        "(SELECT 1 FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d)")
  }

  @Test func `columns validate true still faults the subquery body`() throws {
    // The EXPLICIT schema path stays STRICT: `validate: true` eager-type-checks
    // the subquery-body's derived table, so the ill-typed `Label + 1` faults
    // `.operand`.
    #expect(throws: SQLError.operand("operands must be numeric")) {
      let query = try parse(query:
          "SELECT Id FROM T WHERE EXISTS " +
          "(SELECT 1 FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS d)")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a reached ill-typed body in a subquery still faults at run`()
      throws {
    // Lenient is NOT never: a subquery-body derived table whose `WHERE` keeps a
    // row reaches the ill-typed `Label + 1` at run, so the executor faults
    // `.operand`.
    try fixture().expect(
        "SELECT Id FROM T WHERE EXISTS " +
        "(SELECT 1 FROM (SELECT Label + 1 AS x FROM K WHERE k = 1) AS d)",
        fails: .operand("operands must be numeric"))
  }
}

// MARK: - A short-circuited subquery's nested derived body is not validated

/// The reachability walk is the SOLE validation gate: schema/shape derivation
/// is ALWAYS lenient (a derived body's columns/types derive WITHOUT evaluating
/// its projection), and validation applies ONLY to nodes the walk REACHES — so
/// a derived body nested under a SHORT-CIRCUITED subquery is not validated at
/// ANY depth. `WHERE 1 = 0 AND 1 IN (SELECT x FROM (SELECT 1 / 0 …) AS d)`
/// short-circuits the `IN` away, so its nested derived `d` never materialises;
/// before the fix the schema pre-pass eager-compiled `d` with `validate: true`
/// and faulted `.divide` for a query the run drops.
struct DerivedTableSubqueryReachabilityGateTests {
  @Test func `an unreached subquery's nested derived body is not validated`()
      throws {
    // `1 = 0` short-circuits the AND, so the `IN` never materialises — the
    // nested derived `d`'s ill-typed `1 / 0` projection is unreached. The
    // STRICT schema path must NOT fault: the walk did not reach the subquery,
    // so nothing nested under it is validated.
    let query = try parse(query:
        "SELECT V FROM S WHERE 1 = 0 AND 1 IN " +
        "(SELECT x FROM (SELECT 1 / 0 AS x FROM S) AS d)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["V"])
  }

  @Test func `an unreached subquery's nested derived body runs empty`() throws {
    // The run drops every row on the false `WHERE` before the `IN`, so the
    // nested derived body never evaluates — the query returns empty, not a
    // `.divide` fault.
    try fixture().empty(
        "SELECT V FROM S WHERE 1 = 0 AND 1 IN " +
        "(SELECT x FROM (SELECT 1 / 0 AS x FROM S) AS d)")
  }

  @Test func `a reached subquery's nested derived body still faults`() throws {
    // Parity: `1 = 1` does NOT short-circuit, so the walk REACHES the `IN` and
    // validates its nested derived body — the ill-typed `1 / 0` faults
    // `.divide` under the strict schema path, exactly as before the fix.
    #expect(throws: SQLError.divide) {
      let query = try parse(query:
          "SELECT V FROM S WHERE 1 = 1 AND 1 IN " +
          "(SELECT x FROM (SELECT 1 / 0 AS x FROM S) AS d)")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a reached subquery's nested derived body faults at run`() throws {
    // The reached `IN` materialises the nested derived body at run, so the
    // ill-typed `1 / 0` faults `.divide` — the reached-node strict parity.
    try fixture().expect(
        "SELECT V FROM S WHERE 1 = 1 AND 1 IN " +
        "(SELECT x FROM (SELECT 1 / 0 AS x FROM S) AS d)",
        fails: .divide)
  }

  @Test func `a deeper-nested unreached derived body is not validated`()
      throws {
    // Depth-independence: the ill-typed derived body is nested a derived table
    // under a subquery under a derived table. `1 = 0` short-circuits the outer
    // `IN`, so NOTHING nested under it — at any depth — is validated.
    let query = try parse(query:
        "SELECT V FROM S WHERE 1 = 0 AND 1 IN " +
        "(SELECT y FROM (SELECT x AS y FROM " +
        "(SELECT 1 / 0 AS x FROM S) AS e) AS d)")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["V"])
  }

  @Test func `a deeper-nested reached derived body still faults`() throws {
    // Parity at depth: `1 = 1` reaches the outer `IN`, so its whole nested
    // stack validates and the innermost `1 / 0` faults `.divide`.
    #expect(throws: SQLError.divide) {
      let query = try parse(query:
          "SELECT V FROM S WHERE 1 = 1 AND 1 IN " +
          "(SELECT y FROM (SELECT x AS y FROM " +
          "(SELECT 1 / 0 AS x FROM S) AS e) AS d)")
      _ = try fixture().columns(of: query, validate: true)
    }
  }
}

// MARK: - A set-operation VIEW body runs each arm with its arm-local aliases

/// A view whose body is a set operation with a DERIVED TABLE in an arm: the
/// `derive` path must run each arm with its arm-local derived aliases (as the
/// top-level `run` does), not execute the precompiled whole-`setop` plan under
/// an overlay that binds none.
private func setopViews() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "V": .integer]) {
      Row(1, 10)
      Row(2, 20)
    }
    // A derived table in the LEFT arm.
    try View("VL", "SELECT * FROM (SELECT Id FROM T) AS d " +
                   "UNION ALL SELECT Id FROM T", as: ["Id"])
    // A derived table in the RIGHT arm.
    try View("VR", "SELECT Id FROM T " +
                   "UNION ALL SELECT * FROM (SELECT Id FROM T) AS d",
             as: ["Id"])
    // A LEFT arm whose IN subquery names the arm's ENCLOSING derived `d`. The
    // arm's `FROM (…) AS d` is a SELECT-scoped derived alias, INVISIBLE to the
    // arm's own nested `IN` subquery's FROM — so `(SELECT Id FROM d)` faults
    // `.relation("d")` exactly as it would for a base-table alias.
    try View("VI", "SELECT Id FROM (SELECT Id FROM T) AS d " +
                   "WHERE Id IN (SELECT Id FROM d) " +
                   "UNION ALL SELECT Id FROM T", as: ["Id"])
    // A RIGHT arm whose IN subquery names its ENCLOSING derived `d` — the same
    // SELECT-scoped-alias fault as `VI`, in the right arm.
    try View("VJ", "SELECT Id FROM T " +
                   "UNION ALL SELECT Id FROM (SELECT Id FROM T) AS d " +
                   "WHERE Id IN (SELECT Id FROM d)", as: ["Id"])
  }
}

struct DerivedTableSetOperationViewTests {
  @Test func `selecting a set-op view with a left-arm derived table runs`()
      throws {
    // The view body's LEFT arm scans the arm-local derived `d`; executing the
    // precompiled `setop` plan under an arm-less overlay faulted resolving the
    // `d` scan. Per-arm run binds `d`, so the view returns the union rows.
    try setopViews().expect("SELECT Id FROM VL ORDER BY Id",
                            yields: [[1], [1], [2], [2]])
  }

  @Test func `selecting a set-op view with a right-arm derived table runs`()
      throws {
    // The variant with the derived table in the RIGHT arm resolves the same
    // way — each arm runs with its own derived aliases.
    try setopViews().expect("SELECT Id FROM VR ORDER BY Id",
                            yields: [[1], [1], [2], [2]])
  }

  @Test func `a set-op view with a derived-table arm advertises its schema`()
      throws {
    // Schema ↔ run parity: the view's `columns(of:)`/schema resolves the arms'
    // derived aliases too (compile augments each arm per arm for the star-arity
    // check), so the view advertises its one column `Id`.
    let query = try parse(query: "SELECT Id FROM VL")
    let columns = try setopViews().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["Id"])
  }

  @Test func `a set-op left arm IN subquery cannot see its enclosing derived`()
      throws {
    // The LEFT arm's `IN (SELECT Id FROM d)` names the arm's ENCLOSING derived
    // `d`. A derived-table alias is SELECT-scoped, so it is INVISIBLE to a
    // nested subquery's FROM (as a base-table alias would be) — the subquery
    // faults `.relation("d")`, at a run.
    try setopViews().expect("SELECT Id FROM VI ORDER BY Id",
                            fails: .relation("d"))
  }

  @Test func `a set-op right arm IN subquery cannot see its enclosing derived`()
      throws {
    // The RIGHT-arm variant faults the same way — the arm's enclosing derived
    // `d` is invisible to its nested `IN` subquery's FROM.
    try setopViews().expect("SELECT Id FROM VJ ORDER BY Id",
                            fails: .relation("d"))
  }

  @Test func `a set-op arm IN subquery over enclosing derived faults schema`()
      throws {
    // Schema ↔ run parity: `columns(of:)` faults `.relation("d")` on the arm's
    // nested `IN` subquery naming the enclosing derived alias exactly as a run
    // does.
    let query = try parse(query: "SELECT Id FROM VI")
    #expect(throws: SQLError.relation("d")) {
      _ = try setopViews().columns(of: query, validate: true)
    }
  }
}

// MARK: - A set-op arm's scalar subquery cannot see its enclosing derived

/// A set-op view whose arms carry a scalar subquery `(SELECT MAX(a) FROM d)`
/// naming the arm's ENCLOSING derived alias `d`. A derived-table alias is
/// SELECT-scoped, INVISIBLE to a nested scalar subquery's FROM (as a base-table
/// alias would be), so the scalar faults `.relation("d")` — the same
/// outer-derived-alias-in-subquery fault the `IN`/`EXISTS` variants raise. A
/// scalar over a SHARED base relation stays legal.
private func setopScalarViews() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["V": .integer]) {
      Row(10)
      Row(20)
      Row(30)
    }
    Relation("U", ["V": .integer]) {
      Row(40)
      Row(50)
    }
    // A scalar subquery `(SELECT MAX(a) FROM d)` naming the arm's ENCLOSING
    // derived `d`: the alias is SELECT-scoped, so the scalar's FROM cannot see
    // it and faults `.relation("d")` at both arms.
    try View("VMax",
             "SELECT (SELECT MAX(a) FROM d) AS m " +
             "FROM (SELECT V AS a FROM S WHERE V < 30) AS d " +
             "UNION ALL " +
             "SELECT (SELECT MAX(a) FROM d) AS m " +
             "FROM (SELECT V AS a FROM S WHERE V > 10) AS d",
             as: ["m"])
    // A single arm whose scalar subquery names the enclosing derived `d` in
    // both its projection and its WHERE — the same fault, in a single SELECT.
    try View("VTwice",
             "SELECT (SELECT MAX(a) FROM d) AS m " +
             "FROM (SELECT V AS a FROM S) AS d " +
             "WHERE (SELECT MAX(a) FROM d) = 30",
             as: ["m"])
    // Two arms with IDENTICAL scalar text reading a SHARED base relation `U`
    // (no derived alias): legal and the same value in both arms — both yield
    // MAX(U) = 50.
    try View("VShared",
             "SELECT (SELECT MAX(V) FROM U) AS m FROM S WHERE V = 10 " +
             "UNION ALL " +
             "SELECT (SELECT MAX(V) FROM U) AS m FROM S WHERE V = 20",
             as: ["m"])
  }
}

struct DerivedTableSetOperationScalarTests {
  @Test func `a set-op arm scalar subquery cannot see its enclosing derived`()
      throws {
    // A scalar subquery `(SELECT MAX(a) FROM d)` in each arm names the arm's
    // ENCLOSING derived `d`. The derived alias is SELECT-scoped, invisible to
    // the scalar subquery's FROM, so it faults `.relation("d")` at a run — the
    // scalar variant of the outer-derived-alias-in-subquery fault.
    try setopScalarViews().expect("SELECT m FROM VMax",
                                  fails: .relation("d"))
  }

  @Test func `a set-op arm scalar over an enclosing derived faults schema`()
      throws {
    // Schema ↔ run parity: `columns(of:)` faults `.relation("d")` on the arm's
    // scalar subquery naming the enclosing derived alias exactly as a run does.
    let query = try parse(query: "SELECT m FROM VMax")
    #expect(throws: SQLError.relation("d")) {
      _ = try setopScalarViews().columns(of: query, validate: true)
    }
  }

  @Test func `a single-arm scalar cannot see its enclosing derived`() throws {
    // The scalar subquery `(SELECT MAX(a) FROM d)`, reached in both the
    // projection and the WHERE of a single arm, names the enclosing derived
    // `d` — invisible to its FROM, so it faults `.relation("d")`.
    try setopScalarViews().expect("SELECT m FROM VTwice",
                                  fails: .relation("d"))
  }

  @Test func `two arms sharing a non-arm-local scalar both yield it`() throws {
    // Control: two arms with IDENTICAL scalar text over a SHARED relation `U`
    // (no arm-local `d`) each correctly yield MAX(U) = 50 — arm isolation does
    // not perturb a scalar that reads no arm-local relation.
    try setopScalarViews().expect("SELECT m FROM VShared",
                                  yields: [[50], [50]])
  }
}

// MARK: - A set-op view's optimiser augment threads validate leniently

/// Selecting from a SET-OPERATION view runs the run-path optimiser, which
/// re-augments each leaf arm to bind its arm-local derived aliases. That
/// per-arm augment defaulted to `validate: true`, so an arm's data-dependent-
/// empty derived body (`Label + 1 AS x` under `WHERE k = 0`, no surviving row)
/// was TYPE-CHECKED during optimisation and faulted `.operand` — even though
/// `overlay(name:)` above and the run's materialise paths are lenient. The
/// per-arm optimiser augment now threads `validate: false` (the optimiser needs
/// schema/name bindings only), so a set-op view arm runs exactly as its
/// single-arm and non-derived equivalents do.
private func setopValidateViews() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["V": .integer]) {
      Row(10)
      Row(20)
    }
    Relation("K", ["k": .integer, "Label": .text]) {
      Row(1, "a")
      Row(2, "b")
    }
    // A LEFT arm whose derived table has a filtered-out ill-typed body
    // (`Label + 1` under `WHERE k = 0`, dropping every `K` row); the RIGHT arm
    // is plain. The whole run yields only the right arm's rows.
    try View("VF", "SELECT x FROM " +
                   "(SELECT Label + 1 AS x FROM K WHERE k = 0) AS d " +
                   "UNION ALL SELECT V FROM S", as: ["x"])
    // The same filtered-out ill-typed derived table in a SINGLE-arm view — no
    // set operation, so the optimiser takes the whole-view overlay path.
    try View("VS", "SELECT x FROM " +
                   "(SELECT Label + 1 AS x FROM K WHERE k = 0) AS d",
             as: ["x"])
    // A REACHED ill-typed arm body (`k = 2` keeps a `K` row) still faults at
    // run — leniency spares only an UNEVALUATED expression.
    try View("VB", "SELECT x FROM " +
                   "(SELECT Label + 1 AS x FROM K WHERE k = 2) AS d " +
                   "UNION ALL SELECT V FROM S", as: ["x"])
  }
}

struct DerivedTableSetOperationValidateTests {
  @Test func `a set-op arm's filtered-out derived body runs lenient`() throws {
    // The reviewer's case: the left arm's derived body is ill-typed but
    // filtered out. The optimiser's per-arm augment threaded `validate: true`
    // and faulted `.operand` before `derive` executed the view; threading
    // `validate: false` runs it, yielding only the right arm's `S` rows.
    try setopValidateViews().expect("SELECT * FROM VF ORDER BY x",
                                    yields: [[10], [20]])
  }

  @Test func `the set-op arm matches the single-arm view`() throws {
    // Parity: the SINGLE-arm view over the SAME filtered-out derived body runs
    // to zero rows — the optimiser's whole-view overlay was already lenient
    // (`overlay(name:)` passes `validate: false`), and the set-op arm now
    // matches it, both running WITHOUT the `.operand` fault.
    try setopValidateViews().empty("SELECT * FROM VS")
  }

  @Test func `a reached ill-typed arm body still faults at run`() throws {
    // Leniency is NOT never: the arm's `WHERE k = 2` KEEPS a `K` row, so the
    // run reaches the ill-typed `Label + 1` and the executor faults `.operand`.
    try setopValidateViews().expect("SELECT * FROM VB",
                                    fails: .operand("operands must be numeric"))
  }
}

// MARK: - A derived alias is not a recursive relation reference

/// The `WITH RECURSIVE` fixpoint detector inspects a relation's SOURCE, not its
/// binding name: a derived table's alias is not a recursive reference, while a
/// genuine self-reference nested inside a derived body IS.
struct DerivedTableRecursionReferenceTests {
  @Test func `a shadowing derived alias is not a recursive reference`() throws {
    // `WITH RECURSIVE a(n) AS (SELECT 1 UNION ALL SELECT n FROM (SELECT 2 AS n)
    // AS a) SELECT n FROM a` — the second arm's `FROM (…) AS a` merely NAMES a
    // derived table `a`; it does not reference the CTE `a`, so the CTE is NOT
    // recursive and the arm runs ONCE (never to the recursion cap). The
    // `UNION ALL` keeps both arms: the anchor 1, then the derived table's 2.
    let statement = try Statement(parsing:
        "WITH RECURSIVE a(n) AS " +
        "(SELECT 1 UNION ALL SELECT n FROM (SELECT 2 AS n) AS a) " +
        "SELECT n FROM a ORDER BY n")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }

  @Test func `a self-reference nested in a derived body is detected`() throws {
    // `WITH RECURSIVE a(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM (SELECT n
    // FROM a) AS d WHERE n < 3) …` — the second arm's derived body `FROM a`
    // genuinely references the CTE `a`, so the CTE IS recursive and routes
    // through the fixpoint. Detecting the nested reference is what makes the
    // recursion fire: the frontier climbs 1 → 2 → 3 and stops (`n < 3` empties
    // it), yielding 1, 2, 3. Were the nested `a` NOT seen, the arm would run
    // ONCE against an unbound `a` and fault.
    let statement = try Statement(parsing:
        "WITH RECURSIVE a(n) AS " +
        "(SELECT 1 UNION ALL " +
        "SELECT n + 1 FROM (SELECT n FROM a) AS d WHERE n < 3) " +
        "SELECT n FROM a ORDER BY n")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }
}

struct DerivedTableCyclicViewTests {
  @Test func `a derived table over a cyclic view faults recursion at run`()
      throws {
    // The view body's derived table names the view under resolution. The
    // `visited` guard, threaded through `augment`/`materialise` into the
    // schema-derivation compile, catches the re-entry and faults `.recursion`
    // rather than recursing to a stack overflow.
    try views().expect("SELECT * FROM Loop", fails: .recursion("Loop"))
  }

  @Test func `a derived table over a cyclic view faults recursion at columns`()
      throws {
    // Schema ↔ run parity: `columns(of:)` compiles the same cyclic body, so it
    // raises the same `.recursion` — never a hang — as the run.
    let query = try parse(query: "SELECT * FROM Loop")
    let raised: SQLError?
    do {
      _ = try views().columns(of: query, validate: true)
      raised = nil
    } catch let fault as SQLError {
      raised = fault
    }
    #expect(raised == .recursion("Loop"))
  }

  @Test func `a derived table over a non-cyclic view resolves`() throws {
    // Control: a derived table over a well-formed view still resolves and runs
    // — the guard fires only on a genuine cycle.
    try views().expect(
        "SELECT V FROM (SELECT * FROM Src) AS d ORDER BY V",
        yields: [[10], [20], [30]])
  }

  @Test func `a non-cyclic view derived table advertises its schema`() throws {
    // Schema ↔ run parity for the control: `columns(of:)` derives the column
    // through the view and the derived table without faulting.
    let query = try parse(query: "SELECT V FROM (SELECT * FROM Src) AS d")
    let columns = try views().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["V"])
  }
}

// MARK: - Cyclic-view guard on a PLAIN FROM (no derived table)

/// A catalog with cyclic views whose bodies name each other (and one that names
/// itself) through a PLAIN `FROM`, not a derived table. `A` reads `B` and `B`
/// reads `A`; `Self` reads `Self`. The `Loop` fixture above cycles through a
/// derived table (which re-enters the guard via `augment`/`materialise`); this
/// fixture cycles through the direct `resolve(relation:)` view path, so it
/// covers the plain-`FROM` guard the derived-table one does not exercise. A
/// non-cyclic `Src` over the base `S` resolves as any other view.
private func cyclicViews() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["V": .integer]) {
      Row(10)
      Row(20)
      Row(30)
    }
    // Two views whose bodies read each other — a 2-view cycle.
    try View("A", "SELECT * FROM B", as: ["V"])
    try View("B", "SELECT * FROM A", as: ["V"])
    // A view whose body reads itself — a self-cycle.
    try View("Self", "SELECT * FROM Self", as: ["V"])
    // A well-formed control view.
    try View("Src", "SELECT V FROM S", as: ["V"])
  }
}

struct CyclicViewPlainFromTests {
  @Test func `a two-view cycle faults recursion at run`() throws {
    // `run` compiles `SELECT * FROM A` before it executes; `resolve` enters
    // `A`'s body, whose `FROM B` enters `B`'s body, whose `FROM A` re-enters a
    // visited view and faults `.recursion` — never a stack overflow. The fault
    // is raised at COMPILE, so no row ever materialises.
    try cyclicViews().expect("SELECT * FROM A", fails: .recursion("A"))
  }

  @Test func `a two-view cycle faults recursion at columns`() throws {
    // Schema ↔ run parity: `columns(of:)` compiles the same cyclic chain, so it
    // raises the same `.recursion` — never a hang — as the run does.
    let query = try parse(query: "SELECT * FROM A")
    let raised: SQLError?
    do {
      _ = try cyclicViews().columns(of: query, validate: true)
      raised = nil
    } catch let fault as SQLError {
      raised = fault
    }
    #expect(raised == .recursion("A"))
  }

  @Test func `a self-referential view faults recursion at run`() throws {
    // A view whose body reads itself through a plain `FROM` re-enters the
    // visited guard on its own name at compile and faults `.recursion` rather
    // than recursing to a stack overflow.
    try cyclicViews().expect("SELECT * FROM Self", fails: .recursion("Self"))
  }

  @Test func `a self-referential view faults recursion at columns`() throws {
    // Schema ↔ run parity for the self-cycle: `columns(of:)` raises the same
    // `.recursion` the run does.
    let query = try parse(query: "SELECT * FROM Self")
    let raised: SQLError?
    do {
      _ = try cyclicViews().columns(of: query, validate: true)
      raised = nil
    } catch let fault as SQLError {
      raised = fault
    }
    #expect(raised == .recursion("Self"))
  }

  @Test func `a non-cyclic view resolves`() throws {
    // Control: a well-formed view beside the cyclic ones still resolves and
    // runs — the guard fires only on a genuine cycle.
    try cyclicViews().expect("SELECT V FROM Src ORDER BY V",
                             yields: [[10], [20], [30]])
  }
}

// MARK: - An enclosing derived alias is invisible to a nested subquery's FROM

/// A derived-table alias in the outer SELECT's FROM is SELECT-scoped: it names
/// a relation only in the OWNING SELECT's own FROM/JOIN and expressions, NOT
/// inside a nested `EXISTS`/`IN`/scalar subquery's FROM — a subquery does not
/// see the enclosing query's FROM relations, exactly as a base-table alias in
/// the enclosing FROM is invisible. So `FROM d` inside the subquery faults
/// `.relation("d")` (the enclosing derived `d` is stripped), while a same-named
/// CTE stays visible, the subquery's OWN derived table still resolves, and a
/// correlated COLUMN reference still works (that is orthogonal to FROM scope).
struct DerivedTableSubqueryScopeTests {
  @Test func `an EXISTS subquery FROM cannot see the enclosing derived alias`()
      throws {
    // The reviewer's case: `EXISTS (SELECT 1 FROM d)` names the enclosing
    // derived `d`. The alias is SELECT-scoped, invisible to the subquery's
    // FROM, so it faults `.relation("d")` at a run.
    try fixture().expect(
        "SELECT x FROM (SELECT 1 AS x) AS d WHERE EXISTS (SELECT 1 FROM d)",
        fails: .relation("d"))
  }

  @Test func `an EXISTS subquery FROM cannot see the derived alias at columns`()
      throws {
    // Schema ↔ run parity: `columns(of:)` faults `.relation("d")` on the same
    // subquery FROM naming the enclosing derived alias.
    let query = try parse(query:
        "SELECT x FROM (SELECT 1 AS x) AS d WHERE EXISTS (SELECT 1 FROM d)")
    #expect(throws: SQLError.relation("d")) {
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `an enclosing base-table alias is invisible to the subquery too`()
      throws {
    // The SAME fault a base-table alias `d` in the enclosing FROM raises: a
    // nested subquery's `FROM d` sees neither an enclosing base-table alias nor
    // an enclosing derived alias — both are SELECT-scoped range variables.
    try fixture().expect(
        "SELECT Id FROM T AS d WHERE EXISTS (SELECT 1 FROM d)",
        fails: .relation("d"))
  }

  @Test func `an IN subquery FROM cannot see the enclosing derived alias`()
      throws {
    // The `IN` variant: `Id IN (SELECT Id FROM d)` names the enclosing derived
    // `d`, invisible to the subquery's FROM — the same `.relation("d")` fault.
    try fixture().expect(
        "SELECT x FROM (SELECT 1 AS x, 1 AS Id) AS d " +
        "WHERE Id IN (SELECT Id FROM d)",
        fails: .relation("d"))
  }

  @Test func `a scalar subquery FROM cannot see the enclosing derived alias`()
      throws {
    // The scalar variant: `(SELECT MAX(x) FROM d)` names the enclosing derived
    // `d` — invisible to its FROM, so it faults `.relation("d")`.
    try fixture().expect(
        "SELECT x FROM (SELECT 1 AS x) AS d " +
        "WHERE (SELECT MAX(x) FROM d) = 1",
        fails: .relation("d"))
  }

  @Test func `a same-named CTE stays visible inside the subquery`() throws {
    // A CTE `d` is statement-scoped, so it IS visible inside a nested
    // subquery's FROM — the enclosing derived `d` is stripped, not the CTE. The
    // `EXISTS (SELECT 1 FROM d)` resolves the CTE `d` (one row), so the
    // subquery is TRUE and the outer derived row is kept.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) " +
        "SELECT y FROM (SELECT 2 AS y) AS d WHERE EXISTS (SELECT 1 FROM d)")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(2)]])
  }

  @Test func `a same-named CTE resolves inside the subquery at columns`()
      throws {
    // Schema ↔ run parity: `columns(of:)` resolves the CTE `d` inside the
    // subquery FROM too (never faulting on the stripped enclosing derived `d`),
    // advertising the outer projection `y`.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) " +
        "SELECT y FROM (SELECT 2 AS y) AS d WHERE EXISTS (SELECT 1 FROM d)")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.map(\.name) == ["y"])
  }

  @Test func `a subquery's own derived table still resolves`() throws {
    // The subquery augments its OWN derived table `e` — the strip drops only
    // the ENCLOSING derived aliases, so `EXISTS (SELECT 1 FROM (SELECT 2 AS z)
    // AS e)` resolves `e` and the subquery is TRUE, keeping the outer row.
    try fixture().expect(
        "SELECT x FROM (SELECT 1 AS x) AS d " +
        "WHERE EXISTS (SELECT 1 FROM (SELECT 2 AS z) AS e)",
        yields: [[1]])
  }

  @Test func `an uncorrelated EXISTS over a base table still runs`() throws {
    // Orthogonal to the derived-alias strip: a nested subquery over a BASE
    // relation (`EXISTS (SELECT 1 FROM S)`) resolves and runs exactly as
    // before — stripping the ENCLOSING derived aliases keeps base tables (and
    // CTEs) in the subquery's FROM scope. `S` is non-empty, so every outer
    // derived row is kept.
    try fixture().expect(
        "SELECT x FROM (SELECT Id AS x FROM T) AS d " +
        "WHERE EXISTS (SELECT 1 FROM S) ORDER BY x",
        yields: [[1], [2], [3]])
  }
}

// MARK: - A CTE a derived BODY's own FROM shadows stays visible to its subquery

/// The schema-path analog of the round-8 CTE-not-hidden test: a derived
/// table's BODY whose own FROM alias shadows an enclosing CTE, with a NESTED
/// subquery in that body naming the CTE. The body's schema is derived through
/// `materialise`, which augments the body's own FROM alias OVER the CTE in its
/// overlay — so subscoping that overlay for the nested subquery would leave the
/// CTE unbound. The schema walk must resolve the body's nested subqueries
/// against the PRE-augment context (CTE intact), matching the run path, so
/// `columns(of:)` and a run both read the CTE inside the nested subquery.
struct DerivedTableBodyCTEShadowSubqueryTests {
  @Test func `a body FROM alias shadows a CTE its nested subquery still reads`()
      throws {
    // `WITH t(x) AS (SELECT 1) SELECT * FROM (SELECT y FROM (SELECT 2 AS y)
    // AS t WHERE EXISTS (SELECT x FROM t)) AS d` — the outer derived body's own
    // `FROM (SELECT 2 AS y) AS t` SHADOWS the CTE `t`, and the body's nested
    // `EXISTS (SELECT x FROM t)` names `t` — which resolves the CTE
    // (statement-scoped, visible in a subquery), reading its `x` = 1. The CTE
    // has one row, so the EXISTS is TRUE and the body yields `y` = 2. Before
    // the fix the schema walk's overlay OVERWROTE the CTE with the body's
    // derived `t`, so subscoping dropped it and `SELECT x FROM t` faulted.
    let statement = try Statement(parsing:
        "WITH t(x) AS (SELECT 1) " +
        "SELECT * FROM (SELECT y FROM (SELECT 2 AS y) AS t " +
                       "WHERE EXISTS (SELECT x FROM t)) AS d")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(2)]])
  }

  @Test func `the CTE-in-nested-subquery body advertises its schema`() throws {
    // Schema ↔ run parity: `columns(of:)` derives the body against the CTE `t`
    // inside the nested subquery too — resolving `SELECT x FROM t` rather than
    // faulting on the body's derived `t` (no column `x`) — advertising the
    // outer projection `y`.
    let statement = try Statement(parsing:
        "WITH t(x) AS (SELECT 1) " +
        "SELECT * FROM (SELECT y FROM (SELECT 2 AS y) AS t " +
                       "WHERE EXISTS (SELECT x FROM t)) AS d")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.map(\.name) == ["y"])
  }
}

// MARK: - The optimiser does not execute a view's derived-table body

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so the non-deterministic
/// `tick()` routine registered against it records how many times a run invoked
/// it. The engine evaluates a projection synchronously on one thread, so the
/// box needs no lock.
private final class Counter: @unchecked Sendable {
  /// The number of times `next()` has been called.
  private(set) var count = 0

  /// Increments the count and returns the current value.
  func next() -> Int {
    count += 1
    return count
  }
}

/// The optimiser augments a view body SCHEMA-ONLY (`rows: false`), so it never
/// executes a derived table's body during optimisation. A stateful routine in a
/// view's `FROM (SELECT tick() …)` runs at `derive`/run alone — exactly ONCE
/// for `SELECT * FROM v`, not doubled by an optimise-time materialisation.
struct DerivedTableViewOptimiseTests {
  @Test func `a view's stateful derived-body routine runs exactly once`()
      throws {
    // `CREATE VIEW v AS SELECT x FROM (SELECT tick() AS x FROM T) AS d` — the
    // derived body calls the non-deterministic COUNTING routine `tick()` once
    // per `T` row. `T` has one row, so a single execution of the view invokes
    // `tick()` EXACTLY once. When the optimiser materialised the derived body
    // (`rows: true`) it ran the body during optimisation AND again at `derive`,
    // so the counter read TWICE; `rows: false` binds the alias schema-only, so
    // the single execution at run is the only invocation.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
      try View("v", "SELECT x FROM (SELECT tick() AS x FROM T) AS d",
               as: ["x"])
    }
    let rows = try catalog.run(Statement(parsing: "SELECT * FROM v"),
                               routines)
    #expect(rows == [[.integer(1)]])
    #expect(counter.count == 1)
  }
}

// MARK: - A derived body executes exactly once, and only after validation

/// A derived table's body is materialised (executed) ONLY after `compile`
/// validates the whole query, and each level of a nested derived table runs its
/// body EXACTLY once. A stateful `tick()` in the body records the invocations:
/// an invalid query executes it 0×, a valid single-level derived table 1×, and
/// a nested derived table 1× — never doubled by an output-schema-discovery
/// materialisation ahead of the single run.
struct DerivedTableExecutionOnceTests {
  /// A single-row `T`, a counting `tick()`, and the catalog registering it — so
  /// one execution of a body naming `tick()` once per row invokes it once.
  private func harness() throws -> (Counter, Routines, FixtureCatalog) {
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
    }
    return (counter, routines, catalog)
  }

  @Test func `an invalid query never executes the derived body`() throws {
    // `SELECT missing FROM (SELECT tick() AS x FROM T) AS d` FAILS during
    // column resolution — `missing` is unknown — so it must NEVER execute the
    // derived body's stateful `tick()`. `run` compiles/VALIDATES the whole
    // query (schema-only) BEFORE materialising any derived rows, so the fault
    // is raised with the body executed ZERO times. Materialising ahead of the
    // compile would have run `tick()` for a query that cannot run.
    let (counter, routines, catalog) = try harness()
    let query =
        try parse(query: "SELECT missing FROM (SELECT tick() AS x FROM T) AS d")
    #expect(throws: SQLError.column("missing")) {
      _ = try catalog.run(query, routines)
    }
    #expect(counter.count == 0)
  }

  @Test func `columns of an invalid query never executes the derived body`()
      throws {
    // Schema ↔ run parity: `columns(of:)` faults the same unknown column and,
    // being schema-only throughout, likewise executes the body zero times.
    let (counter, routines, catalog) = try harness()
    let query =
        try parse(query: "SELECT missing FROM (SELECT tick() AS x FROM T) AS d")
    #expect(throws: SQLError.column("missing")) {
      _ = try catalog.columns(of: query, routines: routines)
    }
    #expect(counter.count == 0)
  }

  @Test func `a nested derived body executes exactly once`() throws {
    // `SELECT x FROM (SELECT x FROM (SELECT tick() AS x FROM T) AS n) AS d` — a
    // derived table whose own body nests a derived table. The output-schema
    // discovery augment used to materialise (`rows: true`) the nested body once
    // to derive `d`'s schema, then the single run materialised it AGAIN, so
    // `tick()` fired TWICE and the query returned the SECOND value. Discovery
    // is now schema-only (`rows: false`), so the nested body runs EXACTLY once
    // and the query returns the first (only) value.
    let (counter, routines, catalog) = try harness()
    let query = try parse(query:
        "SELECT x FROM (SELECT x FROM (SELECT tick() AS x FROM T) AS n) AS d")
    let rows = try catalog.run(query, routines)
    #expect(rows == [[.integer(1)]])
    #expect(counter.count == 1)
  }

  @Test func `a single-level derived body executes exactly once`() throws {
    // Control: a valid single-level derived table runs its body exactly once.
    let (counter, routines, catalog) = try harness()
    let query =
        try parse(query: "SELECT x FROM (SELECT tick() AS x FROM T) AS d")
    let rows = try catalog.run(query, routines)
    #expect(rows == [[.integer(1)]])
    #expect(counter.count == 1)
  }
}

// MARK: - A view-body lazy scalar reads the view's scope, not the caller's

/// A base relation `T` and a view `Count` whose body has a lazy SCALAR subquery
/// `(SELECT COUNT(*) FROM T)` over that BASE `T`. The base has three rows, so
/// the view's scalar collapses to three regardless of the caller.
private func scopedScalarView() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["V": .integer]) {
      Row(10)
      Row(20)
      Row(30)
    }
    // A one-row anchor a caller-scope scalar projects over (a FROM-less
    // `WITH … SELECT <scalar>` is not a query shape the grammar accepts).
    Relation("One", ["V": .integer]) {
      Row(1)
    }
    // The scalar `(SELECT COUNT(*) FROM T)` is a LAZY scalar occurrence keyed
    // under `.view("count")`; it must resolve against the BASE `T` (count 3),
    // never a caller CTE `T`.
    try View("Count", "SELECT (SELECT COUNT(*) FROM T) AS n", as: ["n"])
  }
}

/// The run-time subquery cache tracks the pre-augment relation scope PER
/// `Subscope`, so a view-body LAZY scalar resolves under the VIEW overlay, not
/// the caller's. A single left-hand scope let a caller CTE `T` mask the view's
/// own base `T`: `WITH T AS (…) SELECT * FROM Count` resolved the view scalar's
/// `(SELECT COUNT(*) FROM T)` against the caller CTE `T` (five rows) instead of
/// the base `T` (three) the view compiled against — the round-15 fault.
struct DerivedTableViewScalarScopeTests {
  @Test func `a view scalar reads the view's T not the caller CTE`() throws {
    // `WITH T AS (five distinct rows) SELECT * FROM Count` — the caller binds a
    // CTE `T` of five rows, shadowing the base `T` in the CALLER's scope. The
    // view `Count`'s body scalar `(SELECT COUNT(*) FROM T)` was compiled over
    // the base `T` (three rows), so it must collapse to 3, NOT the caller CTE's
    // 5. The lazy scalar now resolves under its own `.view("count")` scope (the
    // view's base `T`), not the merged caller scope.
    let statement = try Statement(parsing:
        "WITH T(V) AS (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 " +
        "UNION ALL SELECT 4 UNION ALL SELECT 5) SELECT * FROM Count")
    let rows = try scopedScalarView().run(statement, .standard)
    #expect(rows == [[.integer(3)]])
  }

  @Test func `the caller-CTE view scalar advertises the view's schema`()
      throws {
    // Schema ↔ run parity: `columns(of:)` derives the view scalar under the
    // same `.view` scope, advertising the view's projection `n` rather than
    // faulting or shifting to the caller CTE.
    let statement = try Statement(parsing:
        "WITH T(V) AS (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 " +
        "UNION ALL SELECT 4 UNION ALL SELECT 5) SELECT * FROM Count")
    let columns = try scopedScalarView().columns(of: statement, validate: true)
    #expect(columns.map(\.name) == ["n"])
  }

  @Test func `a caller-scope scalar still reads the caller CTE`() throws {
    // No regression on the `.caller` scope: a TOP-LEVEL scalar
    // `(SELECT COUNT(*) FROM T)` — textually in the caller, keyed `.caller` —
    // reads the caller CTE `T` (five rows), the scope its own occurrence ran
    // against. The per-`Subscope` map keeps the caller scalar on the caller
    // scope and the view scalar on the view scope at once.
    let statement = try Statement(parsing:
        "WITH T(V) AS (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 " +
        "UNION ALL SELECT 4 UNION ALL SELECT 5) " +
        "SELECT (SELECT COUNT(*) FROM T) AS n FROM One")
    let rows = try scopedScalarView().run(statement, .standard)
    #expect(rows == [[.integer(5)]])
  }
}

// MARK: - The direct-select compile entry binds derived aliases

/// The `compile(_ select:)` entry — reached DIRECTLY by a caller that already
/// holds a `Select` (not wrapped in a `Query`) — must bind THIS select's own
/// FROM derived aliases before resolving its relations, the same as the `Query`
/// wrapper (`compile(.select(select))`) and `run` do. Compiling the reviewer's
/// `SELECT a FROM (SELECT V AS a FROM S) AS d` through the bare-select entry
/// must resolve `d` and project `a` rather than fault `.relation("d")` or bind
/// against an unrelated `d`, matching the query path (schema/run parity).
struct DerivedTableDirectCompileTests {
  @Test func `the direct-select entry resolves a derived alias`() throws {
    // The bare `compile(select)` binds `d` before resolving FROM, so the plan
    // is one column wide (`a`) — no `.relation("d")`.
    let select =
        try parse(select: "SELECT a FROM (SELECT V AS a FROM S) AS d")
    let plan = try fixture().compile(select)
    #expect(plan.width == 1)
  }

  @Test func `the direct-select and query entries agree on width`() throws {
    // Parity: the bare-select entry and the `Query` wrapper resolve the same
    // derived alias to the same plan width — the fix does not fault one path.
    let select =
        try parse(select: "SELECT a FROM (SELECT V AS a FROM S) AS d")
    let catalog = try fixture()
    let bare = try catalog.compile(select)
    let wrapped = try catalog.compile(.select(select))
    #expect(bare.width == wrapped.width)
  }

  @Test func `the direct-select schema entry resolves a derived alias`()
      throws {
    // `columns(of select:)` — the schema counterpart of the bare-select entry —
    // advertises the derived alias's projected column `a`, matching the run.
    let select =
        try parse(select: "SELECT a FROM (SELECT V AS a FROM S) AS d")
    let columns = try fixture().columns(of: select, Context())
    #expect(columns.map(\.name) == ["a"])
  }

  @Test func `the run yields the derived alias's rows`() throws {
    // Run parity: the SAME SQL succeeds through `run`, projecting `a` (the `S`
    // values) — the direct-select entry now matches it.
    try fixture().expect(
        "SELECT a FROM (SELECT V AS a FROM S) AS d ORDER BY a",
        yields: [[10], [20], [30]])
  }

  @Test func `a self-named direct-select derived alias reads the base`()
      throws {
    // No double-augment regression: a derived alias equal to a base relation
    // (`(SELECT V AS a FROM S) AS S`) still reads the BASE `S` in its body —
    // the wrapper's augment and this entry's augment key on the derivation
    // identity, so the wrapped path does not re-derive and the body's own `S`
    // is the base.
    let select =
        try parse(select: "SELECT a FROM (SELECT V AS a FROM S) AS S")
    let plan = try fixture().compile(select)
    #expect(plan.width == 1)
  }
}

// MARK: - A grouped ORDER BY aggregate subquery reads the shadowed CTE

/// The last CTE-overwrite-class path: a GROUPED `ORDER BY` sorting on an
/// aggregate over a SCALAR subquery that names a CTE a same-named derived alias
/// shadows. The aggregate's argument subquery is lowered through the grouped
/// path, so its scope must reveal the base — the derived alias `d` shadows
/// the CTE `d` non-destructively, and the subquery's `FROM d` resolves the CTE
/// beneath. The layered overlay makes this structural: no per-path pre-augment
/// threading, the reveal exposes the CTE the derived layer shadowed.
struct DerivedTableGroupedOrderScalarShadowTests {
  @Test func `a grouped ORDER BY aggregate subquery reads the shadowed CTE`()
      throws {
    // `WITH d(x) AS (SELECT 1) SELECT y FROM (SELECT 2 AS y) AS d GROUP BY y
    // ORDER BY SUM((SELECT x FROM d))` — the scalar `(SELECT x FROM d)` in
    // the ORDER BY aggregate names the CTE `d` (x = 1), NOT the shadowing
    // `d` (whose column is `y`). One group (y = 2), so `SUM` folds the single
    // scalar value 1; the row is the group's `y` = 2. Had the scalar read the
    // derived `d`, `x` would not resolve and it would fault.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) SELECT y FROM (SELECT 2 AS y) AS d " +
        "GROUP BY y ORDER BY SUM((SELECT x FROM d))")
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(2)]])
  }

  @Test func `the grouped ORDER BY subquery advertises the outer schema`()
      throws {
    // Schema ↔ run parity: `columns(of:, validate: true)` resolves the ORDER
    // BY aggregate's scalar subquery against the revealed base too, reading the
    // CTE `d` rather than faulting on the shadowing derived `d`, and advertises
    // the outer projection `y`.
    let statement = try Statement(parsing:
        "WITH d(x) AS (SELECT 1) SELECT y FROM (SELECT 2 AS y) AS d " +
        "GROUP BY y ORDER BY SUM((SELECT x FROM d))")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.map(\.name) == ["y"])
  }
}

// MARK: - A derived-table run stays lenient in output discovery

/// The caller's `validate` flag threads through the derived-table OUTPUT
/// DISCOVERY (the schema walk that names a derived table's columns before a
/// run), so a derived-table RUN stays LENIENT like the surrounding non-derived
/// path: a scalar subquery a data-dependent filter drops from the result is
/// NOT strictly validated before execution. A `WHERE k = 0` over `K` (keyed
/// 1, 2) filters EVERY row out, so the inner `Label + 1` — a text-plus-integer
/// operand that would fault if evaluated — never runs, exactly as the
/// non-derived form runs to zero rows without touching it. The strict
/// `columns(of:, validate: true)` preflight still faults, so the fix narrows
/// to the lenient run path without disabling validation.
struct DerivedTableLenientOutputTests {
  @Test func `a derived run over a filtered-out inner scalar returns nothing`()
      throws {
    // The inner scalar `(SELECT x FROM (SELECT Label + 1 AS x FROM K WHERE
    // k = 0) AS n)` sits over a doubly-nested derived table whose `WHERE k = 0`
    // drops every row, so `Label + 1` never evaluates and the outer derived
    // table `d` yields zero rows. The output discovery for the run must thread
    // `validate: false` into the nested derived body, or it eager-type-checks
    // `Label + 1` and faults BEFORE execution.
    try fixture().empty(
        "SELECT * FROM (SELECT (SELECT x " +
        "                      FROM (SELECT Label + 1 AS x FROM K " +
        "                            WHERE k = 0) AS n) AS s " +
        "               FROM K WHERE k = 0) AS d")
  }

  @Test func `a derived run equals its non-derived form`() throws {
    // Run ↔ non-derived parity: wrapping the SELECT in a derived table changes
    // nothing — both return zero rows without faulting on `Label + 1`.
    try fixture().expect(
        "SELECT * FROM (SELECT (SELECT x " +
        "                      FROM (SELECT Label + 1 AS x FROM K " +
        "                            WHERE k = 0) AS n) AS s " +
        "               FROM K WHERE k = 0) AS d",
        equals:
        "SELECT (SELECT x " +
        "        FROM (SELECT Label + 1 AS x FROM K WHERE k = 0) AS n) AS s " +
        "FROM K WHERE k = 0")
  }

  @Test func `a simple derived run over a filtered scalar returns nothing`()
      throws {
    // The isolating case: a derived table wrapping a scalar over a
    // filtered-empty relation. `WHERE k = 0` drops every row, so `Label + 1`
    // never evaluates and the derived table `d` yields nothing.
    try fixture().empty(
        "SELECT * FROM (SELECT (SELECT Label + 1 FROM K WHERE k = 0) AS s " +
        "               FROM K WHERE k = 0) AS d")
  }

  @Test func `the strict preflight still faults on the inner scalar`() throws {
    // Parity: `columns(of:, validate: true)` — the EXPLICIT schema path — still
    // eager-type-checks the inner body and faults on `Label + 1`, proving the
    // fix narrows to the lenient run path and does not disable validation.
    #expect(throws: SQLError.self) {
      let query = try parse(query:
          "SELECT * FROM (SELECT (SELECT x " +
          "                      FROM (SELECT Label + 1 AS x FROM K " +
          "                            WHERE k = 0) AS n) AS s " +
          "               FROM K WHERE k = 0) AS d")
      _ = try fixture().columns(of: query, validate: true)
    }
  }
}

// MARK: - All-NULL derived column unification

/// A derived table that projects a constant-NULL column places NO type
/// constraint on it, exactly as a bare constant-NULL set-operation arm does.
/// `materialise` carries the fold's per-column unconstrained marker through the
/// derived-table binding (and through an `AS d(a)` rename), so a transparent
/// `(SELECT NULLIF('a','a') AS x) AS d` wrapper unifies with a later typed arm
/// ORDER-INDEPENDENTLY rather than folding as its literal-fix type and
/// faulting.
struct DerivedTableNullUnificationTests {
  @Test func `an all-NULL derived column unifies with an integer arm`()
      throws {
    // `x` is a constant NULL, so the enclosing UNION must treat it as
    // unconstrained and unify it with the `1` arm — the reviewer's case, which
    // faulted before the marker survived the derived-table binding.
    try fixture().expect(
        "SELECT x FROM (SELECT NULLIF('a', 'a') AS x) AS d UNION SELECT 1",
        yields: [[nil], [1]])
  }

  @Test func `an all-NULL derived column unifies regardless of arm order`()
      throws {
    // The order-independence case: the integer arm leads. Without the marker
    // the derived column would fold as its literal-fix type and fault; the
    // marker unifies it either way.
    try fixture().expect(
        "SELECT 1 AS n UNION SELECT x FROM (SELECT NULLIF('a', 'a') AS x) AS d",
        yields: [[1], [nil]])
  }

  @Test func `an all-NULL derived column unifies through an AS d(a) rename`()
      throws {
    // The crux: the unconstrained marker must survive the positional
    // column-list rename, so `d(a)` over a constant-NULL body still unifies
    // with the `1` arm rather than taking a concrete literal-fix type.
    try fixture().expect(
        "SELECT a FROM (SELECT NULLIF('a', 'a') AS x) AS d(a) UNION SELECT 1",
        yields: [[nil], [1]])
  }

  @Test func `a concrete derived column still types normally`() throws {
    // The regression guard: a genuinely text derived column must NOT be
    // over-marked as unconstrained, so a UNION with an integer arm still faults
    // on the irreconcilable text/integer pair.
    try fixture().expect(
        "SELECT x FROM (SELECT 'a' AS x) AS d UNION SELECT 1",
        fails: .operand("UNION arms have irreconcilable types"))
  }
}
