// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport


// MARK: - LATERAL execution

/// A parent `T` and a child `S` keyed on `T.Id`, so a LATERAL body's right side
/// VARIES per outer row — the proof of real correlation a once-materialised
/// constant relation could not produce.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    // `S.k` references `T.Id`: Id 1 has two children, Id 2 one, Id 3 none.
    Relation("S", ["k": .integer, "x": .integer]) {
      Row(1, 100)
      Row(1, 101)
      Row(2, 200)
    }
  }
}

/// A LATERAL derived table resolves its body against the PRECEDING FROM and
/// re-evaluates it per that row — a correlated apply. The right side differs per
/// left row (impossible for a once-materialised constant), and an INNER apply
/// drops a left row whose body yields nothing.
struct LateralExecutionTests {
  @Test func `a LATERAL body yields per-outer-row-varying rows`() throws {
    // `… JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1` — the
    // body's `T.Id` correlates to the preceding `T`, so `d` re-runs per `T` row
    // over the children keyed on THAT `Id`: Id 1 → {100, 101}, Id 2 → {200},
    // Id 3 → {} (dropped, INNER apply). The right side VARIES per left row.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200]])
  }

  @Test func `an INNER LATERAL apply drops a left row with no right rows`()
      throws {
    // `T.Id` 3 has no child in `S`, so the INNER apply drops it — only 1 and 2
    // survive, each once (a `COUNT`-shaped scalar lateral body).
    try fixture().expect(
        "SELECT T.Id, d.n FROM T " +
        "JOIN LATERAL (SELECT COUNT(*) AS n FROM S WHERE S.k = T.Id) AS d " +
        "ON d.n > 0 ORDER BY T.Id",
        yields: [[1, 2], [2, 1]])
  }

  @Test func `a LATERAL apply's ON further filters the pair`() throws {
    // The join `ON` filters the concatenated pair after the apply: keep only the
    // children whose `x` exceeds 100, so Id 1 keeps just 101 and Id 2 keeps 200.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON d.x > 100 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 101], [2, 200]])
  }

  @Test func `a LATERAL apply materialises a correlated column the outer drops`()
      throws {
    // The outer projects only `d.x`, never `T.Id` — but the apply still reads
    // `T.Id` from the left record to bind the body's correlation, so the
    // preceding column is materialised (given a slot) even though no outer
    // clause references it.
    try fixture().expect(
        "SELECT d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY d.x",
        yields: [[100], [101], [200]])
  }

  @Test func `a LATERAL body advertises its output schema`() throws {
    // A lateral body's SHAPE is correlation-independent — its projection names
    // its OWN relation `S`, so `columns(of:)` reports the body's output column
    // `x` under `d` even though the body's WHERE correlates against `T`.
    let query = try parse(query:
        "SELECT d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "x")
    #expect(columns[0].type == .integer)
  }

  @Test func `a NON-lateral body still faults the preceding column`() throws {
    // PARITY: the SAME body WITHOUT `LATERAL` still faults the unknown
    // preceding column — the no-LATERAL rule is intact (a non-lateral body is
    // resolved independently of its call site).
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1",
        fails: .column("Id"))
  }

  @Test func `a LATERAL first FROM item faults`() throws {
    // A lateral derived table needs a PRECEDING FROM item; as the sole FROM
    // relation it has nothing to correlate against, so it faults.
    try fixture().expect(
        "SELECT d.x FROM LATERAL (SELECT x FROM S) AS d",
        fails: .state("42601",
            "a LATERAL derived table needs a preceding FROM item"))
  }

  @Test func `a CTE is visible inside a LATERAL body`() throws {
    // The lateral body resolves against the SAME scope its call site sees, so
    // an enclosing CTE `c` is visible inside it — the structural fix unified
    // the lateral body's resolution scope with the outer query's. The schema
    // pass derives the body's output column `x`, and the run correlates it per
    // `T` row: `c` holds the single value 1, so the body matches only the `T`
    // row whose `Id` is 1 (an INNER apply drops Ids 2 and 3, which `c` never
    // equals).
    let statement = try Statement(parsing:
        "WITH c(x) AS (SELECT 1 AS x) SELECT d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM c WHERE x = T.Id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "x")
    #expect(columns[0].type == .integer)
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a bad function in a LATERAL body faults the schema check`()
      throws {
    // PARITY: the schema pass validates the lateral body exactly as the run
    // executes it, so an unregistered `bad` function in the body faults the
    // strict `columns(of:validate:true)` schema check with the same
    // `SQLError.function` the run raises — the schema is not advertised for a
    // lateral body a run would reject.
    #expect(throws: SQLError.function("bad")) {
      let query = try parse(query:
          "SELECT d.x FROM T " +
          "JOIN LATERAL (SELECT bad(S.x) AS x FROM S WHERE S.k = T.Id) AS d " +
          "ON 1 = 1")
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `validate false does not eagerly fault a bad LATERAL body`()
      throws {
    // LENIENT PARITY: with `validate: false` — the run-shape pass — the same
    // bad-function lateral body is NOT eager-checked, so deriving its headers
    // returns the body's output column `x` WITHOUT the `.function` fault,
    // matching the engine's reachability-gated validation (the strict schema
    // path faults it; the lenient one trusts it).
    let query = try parse(query:
        "SELECT d.x FROM T " +
        "JOIN LATERAL (SELECT bad(S.x) AS x FROM S WHERE S.k = T.Id) AS d " +
        "ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: false)
    #expect(columns.map(\.name) == ["x"])
  }

  @Test func `a LATERAL body exposes its virtual Id per left row`() throws {
    // A lateral derived table exposes the universal virtual `Id` at its real
    // width, so `d.Id` names the 1-based position of the row WITHIN this left
    // row's body output — reset per outer row, exactly as a non-lateral derived
    // table's `Id` numbers its own materialised rows. Id 1 → children {100,
    // 101} → d.Id {1, 2}; Id 2 → {200} → d.Id {1}; Id 3 → {} (dropped). The
    // apply materialises the body output through the same `RelationInstance`
    // `Id` derivation, so `d.Id` yields the id rather than trapping past the
    // real columns.
    try fixture().expect(
        "SELECT d.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.Id",
        yields: [[1, 100], [2, 101], [1, 200]])
  }

  @Test func `a LATERAL virtual Id matches a non-lateral derived Id`() throws {
    // PARITY: the per-left-row `d.Id` a lateral body advertises numbers its own
    // output the SAME way a non-lateral derived table numbers its materialised
    // rows — the FIRST left row (`T.Id` 1) has two children, so its lateral
    // `d.Id`s are 1 and 2, exactly a non-lateral `(SELECT x FROM S WHERE S.k =
    // 1) AS d`'s Ids over the same two rows.
    try fixture().expect(
        "SELECT d.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "WHERE T.Id = 1 ORDER BY d.Id",
        equals:
        "SELECT d.Id, d.x " +
        "FROM (SELECT x FROM S WHERE S.k = 1) AS d ORDER BY d.Id")
  }

  @Test func `a LATERAL virtual Id resolves in the ON`() throws {
    // The virtual `Id` is also readable from the join `ON`: `d.Id = 1` keeps
    // only the FIRST body row per left row, so Id 1 keeps just its first child
    // (100) and Id 2 keeps 200 (its lone, first, child). The apply materialises
    // the virtual `Id` into the pair the `ON` evaluates, so a `d.Id` reference
    // there resolves rather than trapping.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON d.Id = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [2, 200]])
  }

  @Test func `a LATERAL body advertises its virtual Id column`() throws {
    // The strict schema path advertises the lateral body's virtual `Id`
    // alongside its real column `x`, so `columns(of:validate: true)` reports
    // both — the `Id` a run materialises at the body's width.
    let query = try parse(query:
        "SELECT d.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["Id", "x"])
  }

  @Test func `a LATERAL body cannot see a caller derived alias`() throws {
    // STRUCTURAL PARITY: the lateral body's PLAN compile resolves its `FROM`
    // over the SAME revealed base the schema/validation pass does — base plus
    // CTEs plus store, this select's derived aliases STRIPPED — so a body
    // naming a CALLER derived alias `e` faults the unknown relation
    // CONSISTENTLY at both the schema pass and the run, rather than the
    // run-only compile scanning the caller's `e` while the schema pass faults.
    // The caller reference sits in the set-operation body's LATER arm (`…
    // UNION ALL SELECT x FROM e`), the arm the run-path shape pass
    // (`materialise`, `rows: false`) does NOT derive — so ONLY the plan compile
    // ever resolved it, the exact path the unified revealed base now closes.
    let sql =
        "SELECT d.x FROM T " +
        "JOIN (SELECT 9 AS y) AS e ON 1 = 1 " +
        "JOIN LATERAL (SELECT 0 AS x UNION ALL SELECT x FROM e) AS d ON 1 = 1"
    // The run faults the unknown relation the body's later arm names.
    try fixture().expect(sql, fails: .relation("e"))
    // The strict schema path faults it identically — schema and run agree.
    #expect(throws: SQLError.relation("e")) {
      let query = try parse(query: sql)
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a shadowed CTE in a LATERAL body resolves the same at compile and run`()
      throws {
    // EXECUTION/COMPILE PARITY: a CTE `e` SHADOWED by a caller derived alias
    // `e` is in scope of the lateral body's `FROM e`. Compile resolves the body
    // over the REVEALED base (CTEs plus store, this select's derived aliases
    // STRIPPED), so it binds the CTE `e` (x = 1). The per-outer-row apply must
    // re-run that plan under the SAME revealed overlay — else it scans the
    // UNREVEALED caller derived alias `e` (x = 2) and yields the WRONG rows.
    // The CTE matches `T.Id` 1, the derived alias would match `T.Id` 2, so the
    // divergence is a visible wrong row, not merely an empty result. The run
    // yields the CTE's row and `columns(of:validate: true)` agrees — schema,
    // compile, and execution resolve the body's `FROM` identically.
    let statement = try Statement(parsing:
        "WITH e(x) AS (SELECT 1 AS x) SELECT T.Id, d.x FROM T " +
        "JOIN (SELECT 2 AS x) AS e ON 1 = 1 " +
        "JOIN LATERAL (SELECT x FROM e WHERE x = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id")
    let columns = try fixture().columns(of: statement, validate: true)
    #expect(columns.map(\.name) == ["Id", "x"])
    let rows = try fixture().run(statement, .standard)
    #expect(rows == [[.integer(1), .integer(1)]])
  }
}

// MARK: - OUTER APPLY (LEFT LATERAL joins)

/// A `LEFT JOIN LATERAL` (T-SQL `OUTER APPLY`, ISO `LEFT JOIN LATERAL`)
/// NULL-extends a left row whose correlated body admits no surviving pair —
/// preserving it, unlike the `.inner` CROSS APPLY that drops it. A `.right` or
/// `.full` LATERAL stays unsupported: the body correlates to the left, so a
/// RIGHT/FULL apply makes no sense and faults at compile.
struct OuterApplyTests {
  @Test func `OUTER APPLY NULL-extends a left row with no right rows`() throws {
    // `T.Id` 3 has no child in `S`, so the OUTER apply (`LEFT JOIN LATERAL`)
    // PRESERVES it NULL-extended: Id 1 → {100, 101}, Id 2 → {200}, Id 3 →
    // (3, NULL) — the left row kept with a NULL right column.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200], [3, nil]])
  }

  @Test func `the INNER CROSS APPLY twin drops the unmatched row`() throws {
    // CONTRAST: the SAME body under `JOIN LATERAL` (INNER/CROSS APPLY) DROPS
    // `T.Id` 3 — the drop the OUTER apply above replaces with a NULL-extended
    // row. Only 1 and 2 survive.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200]])
  }

  @Test func `OUTER APPLY NULL-extends when the ON filters all right rows`()
      throws {
    // A body that DOES produce rows but whose every merged pair fails the join
    // `ON` still counts as unmatched: `ON d.x > 1000` rejects every child, so
    // EACH left row — even Ids 1 and 2 with children — is NULL-extended, just
    // as Id 3 (no children) is. No pair survives, so all three preserve NULL.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d " +
        "ON d.x > 1000 ORDER BY T.Id",
        yields: [[1, nil], [2, nil], [3, nil]])
  }

  @Test func `a RIGHT LATERAL join is unsupported`() throws {
    // A RIGHT apply is nonsensical — the body correlates to the LEFT, so there
    // is nothing to preserve on the right. The compile guard faults it.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "RIGHT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1",
        fails: .state("0A000", "a RIGHT/FULL LATERAL join is not supported"))
  }

  @Test func `a FULL LATERAL join is unsupported`() throws {
    // FULL apply is nonsensical for the same reason as RIGHT — the correlated
    // body has no independent right extent to preserve. The guard faults it.
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "FULL JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1",
        fails: .state("0A000", "a RIGHT/FULL LATERAL join is not supported"))
  }
}

// MARK: - LATERAL body projects a preceding-FROM column (ISO scoping)

/// Per ISO 9075 a LATERAL derived table's preceding-FROM references are in
/// scope throughout its query expression, INCLUDING the SELECT list — so a
/// lateral body may PROJECT a preceding column, unlike an ordinary correlated
/// subquery (whose projection this engine bars). The bar is lifted for the
/// LATERAL body ALONE: the body's `Resolution`/`SubqueryCheck` admit a
/// correlated column everywhere, so a projected preceding column lowers to a
/// `Term.parameter` the apply binds per outer row; the ordinary subquery
/// projection bar is untouched.
struct LateralProjectionCorrelationTests {
  @Test func `a LATERAL body projects a preceding column`() throws {
    // `JOIN LATERAL (SELECT T.Id AS id) AS d ON 1 = 1` — the body's PROJECTION
    // names the preceding `T.Id`, which ISO puts in scope throughout the body.
    // The strict schema path derives `id` typed from `T.Id` (`.integer`), and a
    // run yields `d.id == T.Id` for each left row — the projected preceding
    // column bound per outer row through the apply's correlation.
    let query = try parse(query:
        "SELECT d.id FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "id")
    #expect(columns[0].type == .integer)
    try fixture().expect(
        "SELECT d.id FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id) AS d ON 1 = 1 " +
        "ORDER BY d.id",
        yields: [[1], [2], [3]])
  }

  @Test func `a LATERAL body projects a BARE preceding column`() throws {
    // The BARE-COLUMN twin of the aliased case above: a LATERAL body projecting
    // a preceding `T.Id` WITHOUT an alias collapses to `Projection.columns` —
    // the simpler path. The schema-derive `.columns` case must consult the SAME
    // lateral correlation surface the aliased expression path does, else a bare
    // preceding column faults `SQLError.column("Id")` at schema/run even though
    // the aliased form works. The strict schema path derives `Id` typed from
    // the preceding `T.Id` (`.integer`), and a run yields `d.Id == T.Id` for
    // each left row.
    let query = try parse(query:
        "SELECT d.Id FROM T " +
        "JOIN LATERAL (SELECT T.Id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "Id")
    #expect(columns[0].type == .integer)
    try fixture().expect(
        "SELECT T.Id, d.Id FROM T " +
        "JOIN LATERAL (SELECT T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id",
        yields: [[1, 1], [2, 2], [3, 3]])
  }

  @Test func `an ordinary subquery still cannot project a BARE outer column`()
      throws {
    // The bare-column exemption is GATED on the lateral surface, not opened for
    // the `.columns` path generally: an ordinary (non-lateral) derived table
    // whose body projects a bare preceding `T.Id` STILL faults `.unsupported`
    // at the strict schema check — the barred projection surface of an ordinary
    // subquery diagnoses the correlated bare column exactly as it does the
    // aliased one. This pins the exemption to the LATERAL `everywhere` surface.
    let query = try parse(query:
        "SELECT d.Id FROM T " +
        "JOIN (SELECT T.Id) AS d ON 1 = 1")
    #expect(throws: SQLError.column("Id")) {
      _ = try fixture().columns(of: query, validate: true)
    }
  }

  @Test func `a LATERAL body projects a preceding and a body column`() throws {
    // A MIXED projection — the preceding `T.Id AS a` beside the body's own
    // `x AS b` — proves a projected correlated column and a projected local
    // column coexist. The body re-runs per `T` row over the children keyed on
    // THAT `Id`: Id 1 → {100, 101}, Id 2 → {200}, Id 3 → {} (dropped, INNER
    // apply). `a` reads the bound preceding `T.Id`, `b` the body's own `x`.
    try fixture().expect(
        "SELECT d.a, d.b FROM T " +
        "JOIN LATERAL (SELECT T.Id AS a, x AS b FROM S " +
        "WHERE S.k = T.Id) AS d " +
        "ON 1 = 1 ORDER BY d.a, d.b",
        yields: [[1, 100], [1, 101], [2, 200]])
  }

  @Test func `a LATERAL body advertises a projected preceding column mixed`()
      throws {
    // The strict schema path derives BOTH output columns of the mixed body —
    // `a` typed from the preceding `T.Id`, `b` from the body's own `x` — so
    // `columns(of:validate: true)` reports the correlated projection's shape.
    let query = try parse(query:
        "SELECT d.a, d.b FROM T " +
        "JOIN LATERAL (SELECT T.Id AS a, x AS b FROM S " +
        "WHERE S.k = T.Id) AS d " +
        "ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["a", "b"])
    #expect(columns.map(\.type) == [.integer, .integer])
  }

  @Test func `an ordinary subquery projection still cannot correlate`() throws {
    // The bar lift is LATERAL-ONLY: an ordinary correlated SCALAR SUBQUERY in
    // the projection — `SELECT (SELECT T.Id) FROM T` — STILL faults
    // `.unsupported`, since a subquery's projection is a barred clause position
    // (no evaluator for an outer column there). This pins the LATERAL-only
    // scoping — the everywhere-correlation admission is set for a LATERAL body
    // alone, never an ordinary subquery.
    try fixture().expect(
        "SELECT (SELECT T.Id) FROM T",
        fails: .state("0A000",
            "a correlated column is only supported in a subquery's WHERE"))
  }

  @Test func `an ordinary nested subquery inside a LATERAL body is not lateralised`()
      throws {
    // The LATERAL everywhere-correlation admission covers ONLY the lateral
    // body's OWN projection, NEVER a nested ordinary subquery WITHIN it. So an
    // ordinary correlated scalar subquery in the lateral body's projection —
    // `SELECT (SELECT T.Id) AS x` — is barred `.unsupported` at the strict
    // schema check EXACTLY as the non-lateral twin `SELECT (SELECT T.Id) FROM T`
    // is, since the nested subquery builds its OWN Resolution with the lateral
    // flag cleared (`everywhere: false`). Threading the lateral flag into the
    // nested subquery instead admitted its `T.Id` everywhere and lowered it to a
    // correlated parameter the nested subquery never wires — a WRONG, mismatched
    // fault (`no such column 'Id'`) rather than the correct barred `.unsupported`
    // — the bug the cleared flag fixes.
    let query = try parse(query:
        "SELECT d.x FROM T " +
        "JOIN LATERAL (SELECT (SELECT T.Id) AS x) AS d ON 1 = 1")
    #expect(throws: SQLError.state("0A000",
        "a correlated column is only supported in a subquery's WHERE")) {
      _ = try fixture().columns(of: query, validate: true)
    }
  }
}

// MARK: - LATERAL aggregate body correlates a preceding-FROM column

/// An AGGREGATE lateral body — one that groups, projects a grouped column, or
/// filters through `HAVING` — must resolve a preceding-FROM reference through
/// the SAME correlation surface a non-grouped lateral body does. The grouped
/// lowering (`Grouping.term`, `Grouping.init`, and `group`'s key computation)
/// once consulted only the local scope, so a valid apply projecting or grouping
/// on a preceding column faulted `SQLError.column` at schema/compile instead of
/// producing one aggregate row per left row. Threading the lateral surface
/// through the grouped key/projection/HAVING lowering lifts the fault for a
/// LATERAL body ALONE — the ordinary grouped-subquery bar is untouched (the
/// negative oracle below pins it).
struct LateralAggregateCorrelationTests {
  @Test func `a LATERAL aggregate body projects a preceding column`() throws {
    // The reviewer's exact case: `JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n
    // FROM S WHERE S.k = T.Id) AS d ON 1 = 1` — a whole-result aggregate body
    // that also PROJECTS the preceding `T.Id`. The strict schema path derives
    // `id` (typed from `T.Id`) and `n` (`COUNT` → integer), and a run yields one
    // row per `T` with `n` the count of `S` rows keyed on that `Id`: Id 1 → 2,
    // Id 2 → 1, Id 3 → 0 (a `COUNT` over the empty match still emits its row).
    let query = try parse(query:
        "SELECT d.id, d.n FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n FROM S " +
        "WHERE S.k = T.Id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["id", "n"])
    #expect(columns.map(\.type) == [.integer, .integer])
    try fixture().expect(
        "SELECT d.id, d.n FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n FROM S " +
        "WHERE S.k = T.Id) AS d ON 1 = 1 ORDER BY d.id",
        yields: [[1, 2], [2, 1], [3, 0]])
  }

  @Test func `a LATERAL aggregate body groups on a preceding column`() throws {
    // A GROUP BY on the preceding `T.Id` — a per-invocation constant, so it forms
    // ONE group per left row over that invocation's SOURCE rows. The grouping key
    // lowers to a `Term.parameter` the apply binds per outer row (not a slot the
    // body's own scope holds), so the schema derives and the run yields one
    // grouped row per left row WITH source rows: Id 1 → {100, 101} → n 2, Id 2 →
    // {200} → n 1. Id 3 has NO source rows (its `WHERE` matches nothing), so its
    // GROUP BY forms NO group — an empty body the INNER apply drops (unlike the
    // whole-result COUNT above, which emits one empty group per left row).
    let query = try parse(query:
        "SELECT d.id, d.n FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n FROM S " +
        "WHERE S.k = T.Id GROUP BY T.Id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["id", "n"])
    try fixture().expect(
        "SELECT d.id, d.n FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n FROM S " +
        "WHERE S.k = T.Id GROUP BY T.Id) AS d ON 1 = 1 ORDER BY d.id",
        yields: [[1, 2], [2, 1]])
  }

  @Test func `a LATERAL aggregate body filters HAVING on a preceding column`()
      throws {
    // A HAVING that references the preceding `T.Id` resolves through the grouped
    // lowering's correlation surface (a `Term.parameter`, a per-invocation
    // constant). `HAVING T.Id >= 0` holds for every left row, so the whole-result
    // aggregate's lone group survives each invocation: one row per `T`, `n` the
    // count of its children.
    let query = try parse(query:
        "SELECT d.id, d.n FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n FROM S " +
        "WHERE S.k = T.Id HAVING T.Id >= 0) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["id", "n"])
    try fixture().expect(
        "SELECT d.id, d.n FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id, COUNT(*) AS n FROM S " +
        "WHERE S.k = T.Id HAVING T.Id >= 0) AS d ON 1 = 1 ORDER BY d.id",
        yields: [[1, 2], [2, 1], [3, 0]])
  }

  @Test func `an ordinary grouped subquery projection still cannot correlate`()
      throws {
    // The grouped bar lift is LATERAL-ONLY: an ordinary correlated grouped
    // SCALAR SUBQUERY that PROJECTS an outer column — `SELECT (SELECT T.Id FROM S
    // GROUP BY S.k) FROM T` — STILL faults `.unsupported`, since a subquery's
    // grouped projection is a barred clause position. This pins the exemption on
    // the LATERAL `everywhere` surface, never opened for every grouped subquery.
    try fixture().expect(
        "SELECT (SELECT T.Id FROM S GROUP BY S.k) FROM T",
        fails: .state("0A000",
            "a correlated column is only supported in a subquery's WHERE"))
  }

  @Test func `a LATERAL join under an aggregate is still unsupported`() throws {
    // A LATERAL join whose OUTER query aggregates is a DIFFERENT, still-rejected
    // case: the grouped plan forms its single-relation chain differently from the
    // correlated apply, so it faults rather than mis-plan. The grouped-body fix
    // does not touch this guard.
    try fixture().expect(
        "SELECT COUNT(*) AS n FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1",
        fails: .state("0A000",
            "a LATERAL join under an aggregate is not supported"))
  }
}

// MARK: - Set-op SELECT * LATERAL arm arity

/// A set operation whose `SELECT *` arm is a LATERAL join must derive that
/// arm's star arity against the PRECEDING FROM, exactly as the per-arm
/// compile does — the arity check threads the running prefix scope so the
/// lateral body's preceding-column reference resolves.
struct LateralSetOperationStarTests {
  @Test func `a set-op SELECT * LATERAL arm resolves its arity with the prefix`()
      throws {
    // A LATERAL arm's star arity must derive the body's projected preceding
    // column against the PRECEDING FROM, exactly as the per-arm compile does.
    // Each arm is `SELECT * FROM T JOIN LATERAL (SELECT T.Id AS id) AS d` — two
    // columns wide (`T.Id` + `d.id`). The arity check must thread the running
    // prefix scope so `T.Id` resolves; without it the lateral body derived
    // against NO scope and faulted the arity check even though the per-arm
    // compile passes the prefix and runs. Both arms are two columns, so the
    // union's arity matches and it resolves.
    let query = try parse(query:
        "SELECT * FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id) AS d ON 1 = 1 " +
        "UNION ALL SELECT * FROM T " +
        "JOIN LATERAL (SELECT T.Id AS id) AS d ON 1 = 1")
    let columns = try fixture().columns(of: query, validate: true)
    #expect(columns.map(\.name) == ["Id", "id"])
  }
}
