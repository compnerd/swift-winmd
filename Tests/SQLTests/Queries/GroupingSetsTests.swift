// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// MARK: - Fixtures

/// A `Sales` relation of `Region`/`Product`/`Qty` rows — two regions, two
/// products, and a numeric to `SUM` — the groupable shape a `GROUP BY GROUPING
/// SETS` exercises. Per-(Region, Product) sums: East/A 15 (10 + 5), East/B 20,
/// West/A 7, West/B 3. Per-Region sums: East 35, West 10. Grand total 45.
private func sales() throws -> FixtureCatalog {
  try Catalog {
    Relation("Sales", ["Region": .text, "Product": .text, "Qty": .integer]) {
      Row("East", "A", 10)
      Row("East", "A", 5)
      Row("East", "B", 20)
      Row("West", "A", 7)
      Row("West", "B", 3)
    }
  }
}

/// An `N` relation of `A`/`V` rows — a numeric grouping column and a numeric to
/// `SUM` — for the general-expression and duplicate-set cases. Per-A sums: 1 is
/// 150 (100 + 50), 2 is 30. Grand total 180.
private func nums() throws -> FixtureCatalog {
  try Catalog {
    Relation("N", ["A": .integer, "V": .integer]) {
      Row(1, 100)
      Row(1, 50)
      Row(2, 30)
    }
  }
}

// MARK: - GROUPING SETS core

struct GroupingSetsTests {
  @Test func `three sets union the per-(a,b), per-a, and grand-total groupings`()
      throws {
    // `GROUPING SETS ((Region, Product), (Region), ())` desugars to a UNION ALL
    // of three arms: the full grouping (both columns present), the per-Region
    // grouping (Product a super-aggregate NULL), and the grand total (both
    // NULL). Arm order then row order within each arm.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product), (Region), ())
        """, yields: [
          ["East", "A", 15], ["East", "B", 20],
          ["West", "A", 7], ["West", "B", 3],
          ["East", nil, 35], ["West", nil, 10],
          [nil, nil, 45],
        ])
  }

  @Test func `the result columns type through set-operation unification`()
      throws {
    // A NULL-padded column takes the SIBLING arm's type via the set-operation
    // merge (a constant-NULL arm constrains nothing): Region and Product stay
    // `.text` despite the arms that NULL them, and the SUM is `.integer`. The
    // schema derive (run ≡ columns) agrees with the run above.
    let cat = try sales()
    let columns = try cat.columns(of: parse(query: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product), (Region), ())
        """), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "Product", type: .text),
      OutputColumn(name: "column 3", type: .integer),
    ])
  }

  @Test func `the grand-total set is present when written and absent when not`()
      throws {
    // With `()` the grand-total row (both NULL, SUM 45) is emitted; without it
    // only the per-Region rows are, so the two queries differ by exactly that
    // one row.
    let cat = try sales()
    try cat.expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        """, yields: [["East", 35], ["West", 10], [nil, 45]])
    try cat.expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
        """, yields: [["East", 35], ["West", 10]])
  }

  @Test func `a set member may be a general grouping expression`() throws {
    // `(A + 1)` groups on the arithmetic key — 1 → 2, 2 → 3 — exactly as a
    // plain `GROUP BY A + 1` would, and the projected `A + 1` is kept in that
    // arm and NULL in the grand-total arm.
    try nums().expect("""
        SELECT A + 1, SUM(V)
          FROM N
         GROUP BY GROUPING SETS ((A + 1), ())
        """, yields: [[2, 150], [3, 30], [nil, 180]])
  }

  @Test func `HAVING filters each set's own groups`() throws {
    // HAVING is copied into every arm, so it filters per set: over `((Region),
    // ())` with `SUM(Qty) > 20`, the per-Region East (35) survives, West (10)
    // is dropped, and the grand total (45) survives.
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        HAVING SUM(Qty) > 20
        """, yields: [["East", 35], [nil, 45]])
  }

  @Test func `ORDER BY orders the combined result on the outer wrapper`()
      throws {
    // The query-level ORDER BY rides the `ordered` carrier over the union,
    // resolved through the setop's output scope. Ordering by Region then
    // Product (NULLs first here) interleaves the arms into one sorted result.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product), (Region), ())
         ORDER BY Region, Product
        """, yields: [
          [nil, nil, 45],
          ["East", nil, 35], ["East", "A", 15], ["East", "B", 20],
          ["West", nil, 10], ["West", "A", 7], ["West", "B", 3],
        ])
  }

  @Test func `ORDER BY may name an aggregate over the combined result`() throws {
    // An ORDER BY naming a PROJECTED aggregate (`SUM(Qty)`) resolves to that
    // output column of the union — the setop-output scope orders on the
    // already-computed SUM: ascending 10 (West), 35 (East), 45 (total).
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY SUM(Qty)
        """, yields: [["West", 10], ["East", 35], [nil, 45]])
  }

  @Test func `OFFSET and FETCH page the ordered combined result`() throws {
    // The row limit rides the `ordered` carrier too: ordered by SUM ascending
    // (10, 35, 45), OFFSET 1 skips West (10) and FETCH NEXT 1 takes East (35).
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY SUM(Qty)
         OFFSET 1 ROW FETCH NEXT 1 ROW ONLY
        """, yields: [["East", 35]])
  }

  @Test func `a duplicate set is kept, not deduplicated`() throws {
    // UNION ALL (not UNION) combines the arms, so a set written twice
    // contributes its rows twice rather than collapsing.
    try nums().expect("""
        SELECT A, SUM(V)
          FROM N
         GROUP BY GROUPING SETS ((A), (A))
        """, yields: [[1, 150], [2, 30], [1, 150], [2, 30]])
  }

  // MARK: - Findings dissolved by compile-time expansion

  @Test func `the empty set yields ONE grand-total row, not one per input`()
      throws {
    // Finding 1: the `()` set builds a GENUINE grand-total aggregate — `group`
    // on `[]` = ONE row over the whole result — rather than an empty `GROUP BY`
    // the parser-desugar read as no grouping (`SELECT NULL FROM Sales`, one
    // NULL row PER input row). Here the per-Region arm yields East/West and the
    // `()` arm yields EXACTLY ONE `[nil]` grand-total row.
    let cat = try sales()
    try cat.expect("""
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        """, yields: [["East"], ["West"], [nil]])
    // run ≡ columns(of:): the derived schema agrees with the run.
    let columns = try cat.columns(of: parse(query: """
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        """), validate: true)
    #expect(columns == [OutputColumn(name: "Region", type: .text)])
  }

  @Test func `HAVING on an absent key sees the super-aggregate NULL`() throws {
    // Finding 2: `HAVING Region IS NULL` lowers through the SAME grouped `term`
    // the projection does, so in the `()` arm — where Region is absent from the
    // set — it is a super-aggregate NULL rather than a rejected non-grouped
    // column. Only the grand-total row (Region NULL) survives; every per-Region
    // group (Region NOT NULL) is filtered.
    let cat = try sales()
    try cat.expect("""
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        HAVING Region IS NULL
        """, yields: [[nil]])
    let columns = try cat.columns(of: parse(query: """
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        HAVING Region IS NULL
        """), validate: true)
    #expect(columns == [OutputColumn(name: "Region", type: .text)])
  }

  @Test func `ORDER BY an UNPROJECTED aggregate materialises a hidden column`()
      throws {
    // Finding 3: `ORDER BY MAX(Qty)` names an aggregate the select list does
    // NOT project, so the setop-output scope cannot recompute it. The
    // expansion MATERIALISES `MAX(Qty)` as a hidden trailing column in EVERY
    // arm (equal arity for the UNION ALL), the carrier orders on it, and TRIMS
    // it from the output — so the result has exactly the two projected columns.
    // Per-Region MAX(Qty): East 20, West 7; the `()` grand-total MAX is 20.
    // Ascending MAX orders West (7), then East (20) and the total (20) — the
    // two 20s in arm order (per-Region East before the grand total).
    let cat = try sales()
    try cat.expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY MAX(Qty)
        """, yields: [["West", 10], ["East", 35], [nil, 45]])
    // The hidden MAX column is trimmed: exactly two output columns.
    let columns = try cat.columns(of: parse(query: """
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY MAX(Qty)
        """), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "column 2", type: .integer),
    ])
  }

  @Test func `a qualified key NULLs its unqualified projection in the () arm`()
      throws {
    // Finding 4: `GROUPING SETS ((n.A), ())` groups on the QUALIFIED `n.A`, but
    // the select list projects the UNQUALIFIED `A`. The absent-key NULL is
    // matched by RESOLVED identity (the lowered term treats `n.A` ≡ `A`), so
    // the `()` arm NULLs `A` rather than rejecting a non-grouped column — the
    // parser's old qualifier-PRESENCE matcher failed this. Per-A rows then the
    // grand total.
    let cat = try nums()
    try cat.expect("""
        SELECT A
          FROM N AS n
         GROUP BY GROUPING SETS ((n.A), ())
        """, yields: [[1], [2], [nil]])
    let columns = try cat.columns(of: parse(query: """
        SELECT A
          FROM N AS n
         GROUP BY GROUPING SETS ((n.A), ())
        """), validate: true)
    #expect(columns == [OutputColumn(name: "A", type: .integer)])
  }

  @Test func `ORDER BY a projected key over a key-only projection`() throws {
    // A key-only projection (no aggregate) `SELECT Region` parses as a bare
    // `columns` list; the `ordered` carrier resolves the ORDER BY over the
    // union's output columns. An ORDER BY naming the ALREADY-projected key
    // orders on that output — it is NOT materialised as a hidden column and the
    // identity projection keeps the one real column. NULLs sort first
    // ascending, so the `()` arm's grand-total NULL leads, then East/West.
    let cat = try sales()
    try cat.expect("""
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY Region
        """, yields: [[nil], ["East"], ["West"]])
    // run ≡ columns(of:): exactly the one real output column, hidden trimmed.
    let columns = try cat.columns(of: parse(query: """
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY Region
        """), validate: true)
    #expect(columns == [OutputColumn(name: "Region", type: .text)])
  }

  @Test func `positional ORDER BY resolves over the wrapper`() throws {
    // A positional `ORDER BY 1` names the first output column, resolved by the
    // setop-output scope's ordinary ordinal ORDER BY over the union's outputs —
    // not faulted as an input column `1`. It matches `ORDER BY Region` above.
    try sales().expect("""
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY 1
        """, yields: [[nil], ["East"], ["West"]])
  }

  @Test func `ORDER BY a projected key descending over a key-only projection`()
      throws {
    // The DESC variant: NULLs sort last descending, so West/East lead and the
    // grand-total NULL trails — the carrier still keeps the one real key.
    try sales().expect("""
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY Region DESC
        """, yields: [["West"], ["East"], [nil]])
  }

  @Test func `ORDER BY a grouping key with a co-projected aggregate`() throws {
    // A grouping-key ORDER BY with an aggregate co-projected: the carrier keeps
    // both output columns and orders on the projected key. NULLs first
    // ascending — the grand total (45) leads, then East (35), West (10).
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY Region
        """, yields: [[nil, 45], ["East", 35], ["West", 10]])
  }

  // MARK: - ORDER BY an unprojected grouping column (materialised hidden)

  @Test func `ORDER BY an unprojected grouping column matches the plain form`()
      throws {
    // `Region` is a GROUP BY key but is NOT projected (only `SUM(Qty)` is), so
    // the setop-output scope cannot bind it — yet the plain grouped path takes
    // `ORDER BY Region` (a grouped column is orderable). The GROUPING SETS form
    // must AGREE: `expand` materialises the unprojected grouped column as a
    // hidden trailing column in every arm (the aggregate case's machinery), the
    // carrier orders on it, and trims it — so the result is exactly `SUM(Qty)`,
    // ordered by Region. Ascending Region: East 35, West 10.
    let cat = try sales()
    try cat.expect("""
        SELECT SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region)) ORDER BY Region
        """, equals: """
        SELECT SUM(Qty) FROM Sales GROUP BY Region ORDER BY Region
        """)
    try cat.expect("""
        SELECT SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region)) ORDER BY Region
        """, yields: [[35], [10]])
    // The hidden Region column is trimmed: exactly the one aggregate output.
    let columns = try cat.columns(of: parse(query: """
        SELECT SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region)) ORDER BY Region
        """), validate: true)
    #expect(columns == [OutputColumn(name: "column 1", type: .integer)])
  }

  @Test func `ORDER BY an unprojected key sorts the grand-total NULL per arm`()
      throws {
    // With a grand-total set `((Region), ())` the unprojected `Region` sort key
    // carries the arm's own value: the per-Region arm carries East/West, the
    // `()` arm NULLs Region (the super-aggregate NULL). Ascending Region sorts
    // the NULL first, matching the plain grouped form's absent-key ordering (a
    // plain grouped query cannot express the grand-total arm, so the direct
    // oracle is the NULL placement itself). SUM: grand total 45, East 35, West
    // 10.
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region), ()) ORDER BY Region
        """, yields: [[45], [35], [10]])
  }

  @Test func `ORDER BY a non-grouped column faults like the plain form`()
      throws {
    // `Product` is neither projected nor a GROUP BY key of the `((Region))`
    // arm. The plain grouped path REJECTS `ORDER BY Product` (a non-grouped,
    // non-aggregated column). The GROUPING SETS form must fault IDENTICALLY:
    // `expand` materialises the column into each arm's projection, and the
    // arm's grouped resolver rejects it with the SAME grouping fault, never the
    // old carrier's `no such column` over the setop output.
    let cat = try sales()
    let fault = SQLError.grouping("Product")
    cat.expect("""
        SELECT SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region)) ORDER BY Product
        """, fails: fault)
    cat.expect("""
        SELECT SUM(Qty) FROM Sales GROUP BY Region ORDER BY Product
        """, fails: fault)
  }

  @Test func `ORDER BY a PROJECTED grouping column is not materialised hidden`()
      throws {
    // The regression guard for the fix above: when the grouping column IS
    // projected (`SELECT Region, SUM(Qty)`), `ORDER BY Region` must resolve to
    // that EXISTING output — NOT materialise a spurious hidden column — so the
    // schema stays the two real outputs. Ascending Region: East 35, West 10.
    let cat = try sales()
    try cat.expect("""
        SELECT Region, SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region)) ORDER BY Region
        """, yields: [["East", 35], ["West", 10]])
    let columns = try cat.columns(of: parse(query: """
        SELECT Region, SUM(Qty) FROM Sales
         GROUP BY GROUPING SETS ((Region)) ORDER BY Region
        """), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "column 2", type: .integer),
    ])
  }

  // MARK: - SELECT * rejection (wrapped and unwrapped)

  @Test func `a grouped SELECT * is rejected the same as a plain GROUP BY`()
      throws {
    // A grouped `SELECT *` is ill-formed (a grouped projection must be
    // explicit). The GROUPING SETS form must reject it with the IDENTICAL fault
    // the plain grouped query raises — the arm resolver's grouped `.all`
    // rejection — whether or not a query-level ORDER BY carries it. `expand`
    // keeps the `.all` verbatim in every arm and returns the bare union (never
    // the `ordered` carrier) for a `SELECT *`, so the arm resolver throws.
    let cat = try sales()
    let star = SQLError.state("0A000",
                              "SELECT * is not allowed with GROUP BY or " +
                              "aggregates")
    // The plain grouped `SELECT *` — the baseline fault.
    cat.expect("SELECT * FROM Sales GROUP BY Region", fails: star)
    // The BARE grouping-sets form (no ORDER BY / DISTINCT / limit).
    cat.expect("""
        SELECT * FROM Sales GROUP BY GROUPING SETS ((Region))
        """, fails: star)
    // The CARRIED form (a query-level ORDER BY) faults IDENTICALLY.
    cat.expect("""
        SELECT * FROM Sales GROUP BY GROUPING SETS ((Region)) ORDER BY Region
        """, fails: star)
    // run ≡ columns(of:): the schema derive faults the same, not a schema.
    #expect(throws: star) {
      _ = try cat.columns(of: parse(query: """
          SELECT * FROM Sales GROUP BY GROUPING SETS ((Region)) ORDER BY Region
          """), validate: true)
    }
  }

  // MARK: - validate/CTE see the expanded arms

  @Test func `a faulting grand-total arm faults validate and a CTE body`()
      throws {
    // The `()` grand-total arm emits ONE row EVEN under `WHERE 1 = 0` (the
    // empty group still produces the grand total), so `1 / 0` IS evaluated at
    // run and faults — the un-expanded `.sets` (where `WHERE 1 = 0` spares the
    // projection) hid this from validation. `Query.expanded` now runs at the
    // WITH schema path and the CTE validation entries too, so the validate path
    // and a CTE body fault IDENTICALLY to the run.
    let cat = try sales()
    let sql = """
        SELECT 1 / 0 AS x
          FROM Sales
         WHERE 1 = 0
         GROUP BY GROUPING SETS ((Region), ())
        """
    // The run faults.
    cat.expect(sql, fails: .divide)
    // `columns(of:…, validate: true)` faults — before it returned a schema.
    #expect(throws: SQLError.divide) {
      _ = try cat.columns(of: parse(query: sql), validate: true)
    }
    // The same query as a CTE body faults under the schema derive too.
    let cte = "WITH t AS (\(sql)) SELECT * FROM t"
    #expect(throws: SQLError.divide) {
      _ = try cat.run(Statement(parsing: cte))
    }
    #expect(throws: SQLError.divide) {
      _ = try cat.columns(of: Statement(parsing: cte), validate: true)
    }
    // The same query as the TRAILING WITH query faults under the schema derive.
    let trailing = "WITH u AS (SELECT 1 AS x) \(sql)"
    #expect(throws: SQLError.divide) {
      _ = try cat.run(Statement(parsing: trailing))
    }
    #expect(throws: SQLError.divide) {
      _ = try cat.columns(of: Statement(parsing: trailing), validate: true)
    }
  }

  @Test func `a non-faulting grouping-sets CTE body validates and types`()
      throws {
    // The parity guard: a NON-faulting grouping-sets CTE body still validates
    // and its `columns(of:)` types resolve correctly — expansion at the CTE
    // entry must not over-reject a legal body. The body projects Region and a
    // SUM over the two-set grouping; as a CTE the trailing `SELECT *` reports
    // the CTE's declared columns, and the rows match the run.
    let cat = try sales()
    let sql = """
        WITH t (Region, Total) AS (
          SELECT Region, SUM(Qty)
            FROM Sales
           GROUP BY GROUPING SETS ((Region), ())
        )
        SELECT * FROM t
        """
    // The rows: per-Region East 35 / West 10, then the grand total 45.
    let rows = try cat.run(Statement(parsing: sql))
    #expect(rows == [
      [.text("East"), .integer(35)],
      [.text("West"), .integer(10)],
      [.null, .integer(45)],
    ])
    // The schema derive validates and reports the CTE's declared columns.
    let columns = try cat.columns(of: Statement(parsing: sql), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "Total", type: .integer),
    ])
  }

  // MARK: - Setop-output scope and ORDER BY resolution

  @Test func `ORDER BY a select-list alias orders on that output`() throws {
    // A query-level `ORDER BY total` names the select-list ALIAS `total` (the
    // `SUM(Qty)` output), NOT a base column. The setop-output scope resolves it
    // the SAME way a plain `SELECT … ORDER BY <alias>` does — over the union's
    // output — rather than materialising a hidden column the grouped lowering
    // cannot resolve. Ascending SUM: West 10, East 35.
    let cat = try sales()
    try cat.expect("""
        SELECT Region, SUM(Qty) AS total
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
         ORDER BY total
        """, yields: [["West", 10], ["East", 35]])
    // run ≡ columns(of:): the alias is the output name, not a hidden column.
    let columns = try cat.columns(of: parse(query: """
        SELECT Region, SUM(Qty) AS total
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
         ORDER BY total
        """), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "total", type: .integer),
    ])
  }

  @Test func `a bare-column projection survives the ORDER BY wrapper`() throws {
    // A key-only `SELECT Region` (a bare `columns` projection) with a
    // query-level `ORDER BY` rides the `ordered` carrier, whose identity
    // projection keeps the REAL output column Region — not zero columns — for
    // every projection kind. Ascending, East before West.
    let cat = try sales()
    try cat.expect("""
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
         ORDER BY Region
        """, yields: [["East"], ["West"]])
    let columns = try cat.columns(of: parse(query: """
        SELECT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
         ORDER BY Region
        """), validate: true)
    #expect(columns == [OutputColumn(name: "Region", type: .text)])
  }

  @Test func `duplicate output names keep their positional identity`() throws {
    // Two outputs aliased the SAME name (`Region AS x, Product AS x`) keep
    // their POSITIONAL identity through the union, so the 2nd output stays
    // Product rather than collapsing onto the first `x` (Region). `ORDER BY 1`
    // sorts on the first output. Region then Product within each Region.
    let cat = try sales()
    try cat.expect("""
        SELECT Region AS x, Product AS x, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product))
         ORDER BY 1
        """, yields: [
          ["East", "A", 15], ["East", "B", 20],
          ["West", "A", 7], ["West", "B", 3],
        ])
    // The duplicate output name survives the carrier (as a plain query's does).
    let columns = try cat.columns(of: parse(query: """
        SELECT Region AS x, Product AS x, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product))
         ORDER BY 1
        """), validate: true)
    #expect(columns == [
      OutputColumn(name: "x", type: .text),
      OutputColumn(name: "x", type: .text),
      OutputColumn(name: "column 3", type: .integer),
    ])
  }

  @Test func `ORDER BY a duplicate output name faults ambiguous, as plain GROUP BY`()
      throws {
    // A bare `ORDER BY x` over TWO outputs aliased `x` (`Region AS x, Product
    // AS x`) rides the setop-output scope's ORDINARY ORDER BY resolution, which
    // faults `SQLError.ambiguous` — NOT a silent order by the first `x`. The
    // plain grouped `… GROUP BY Region, Product ORDER BY x` is the ORACLE: it
    // faults the same `.ambiguous("x")`, so the two forms agree.
    let cat = try sales()
    let ambiguous = SQLError.ambiguous("x")
    // The GROUPING SETS wrapped form faults ambiguous at run and schema derive.
    cat.expect("""
        SELECT Region AS x, Product AS x
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product))
         ORDER BY x
        """, fails: ambiguous)
    #expect(throws: ambiguous) {
      _ = try cat.columns(of: parse(query: """
          SELECT Region AS x, Product AS x
            FROM Sales
           GROUP BY GROUPING SETS ((Region, Product))
           ORDER BY x
          """), validate: true)
    }
    // The plain grouped ORACLE faults IDENTICALLY.
    cat.expect("""
        SELECT Region AS x, Product AS x
          FROM Sales
         GROUP BY Region, Product
         ORDER BY x
        """, fails: ambiguous)
  }

  @Test func `ORDER BY a duplicate BARE projected name faults ambiguous`()
      throws {
    // Two BARE (unaliased) projections resolving to the same output name — here
    // `Region` projected twice — order by that name faults `.ambiguous` the
    // same as the aliased case. The plain grouped form is the oracle.
    let cat = try sales()
    let ambiguous = SQLError.ambiguous("Region")
    cat.expect("""
        SELECT Region, Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
         ORDER BY Region
        """, fails: ambiguous)
    cat.expect("""
        SELECT Region, Region
          FROM Sales
         GROUP BY Region
         ORDER BY Region
        """, fails: ambiguous)
  }

  @Test func `ORDER BY 1 resolves the duplicate-name query by position`()
      throws {
    // Positional `ORDER BY 1` is the UNAMBIGUOUS way to order the
    // duplicate-name query: it names the first output by position, so it
    // resolves where the bare name faults. Region then Product ascending.
    try sales().expect("""
        SELECT Region AS x, Product AS x
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product))
         ORDER BY 1
        """, yields: [
          ["East", "A"], ["East", "B"],
          ["West", "A"], ["West", "B"],
        ])
  }

  @Test func `ORDER BY an unprojected aggregate still materialises after the fix`()
      throws {
    // Regression guard for the shared mechanism: an unprojected `ORDER BY
    // MAX(Qty)` is neither a projected expression NOR an output name, so it is
    // still MATERIALISED as a hidden synthetic column and ordered on. Ascending
    // per-Region MAX(Qty): West 7, East 20.
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region))
         ORDER BY MAX(Qty)
        """, yields: [["West", 10], ["East", 35]])
  }

  // MARK: - Setop-output scope dissolves the scope-less matcher

  @Test func `ORDER BY a display header column N faults, as over a plain union`()
      throws {
    // The result-schema DISPLAY header `column N` (an unnamed output's
    // positional name) is NOT a bindable output name — the setop-output scope
    // names an unnamed output non-spellably, so `ORDER BY "column 2"` faults
    // `.column`, EXACTLY as `SELECT * FROM (union) AS g ORDER BY "column N"`
    // does over any derived union. Before, the text wrapper exposed the header
    // as a derived-table column and WRONGLY accepted it.
    let cat = try sales()
    let fault = SQLError.column("column 2")
    cat.expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY "column 2"
        """, fails: fault)
    // The plain-union ORACLE faults the same over its display header.
    cat.expect("""
        SELECT * FROM (
          SELECT Region FROM Sales GROUP BY Region
        ) AS g ORDER BY "column 1"
        """, fails: SQLError.column("column 1"))
  }

  @Test func `ORDER BY a qualified key resolves to its projected output`()
      throws {
    // A qualified `ORDER BY n.Region` whose BARE name is a projected output
    // resolves to that output through the setop-output scope (a set-operation
    // result carries no source qualifier), the SAME as the plain grouped
    // `ORDER BY n.Region` lowering `n.Region` to the group-key slot ≡ the
    // projected `Region`. Before, the scope-less matcher MATERIALISED
    // `n.Region` as a hidden `*gs0` column, and under DISTINCT that hidden
    // column faulted `must appear in the SELECT DISTINCT list`. Now an output.
    // The `()` arm's grand-total NULL leads ascending, then per-Region.
    let cat = try nums()
    try cat.expect("""
        SELECT DISTINCT A
          FROM N AS n
         GROUP BY GROUPING SETS ((n.A), ())
         ORDER BY n.A
        """, yields: [[nil], [1], [2]])
    let columns = try cat.columns(of: parse(query: """
        SELECT DISTINCT A
          FROM N AS n
         GROUP BY GROUPING SETS ((n.A), ())
         ORDER BY n.A
        """), validate: true)
    #expect(columns == [OutputColumn(name: "A", type: .integer)])
  }

  @Test func `ORDER BY a qualified non-grouped name faults like the plain form`()
      throws {
    // The other half of the qualified case: a qualified `ORDER BY n.Product`
    // whose bare name is NEITHER a projected output NOR a grouping key. The
    // plain grouped ORACLE (`GROUP BY Region ORDER BY n.Product`) faults
    // `.grouping` — a non-grouped, non-aggregated column — NOT `.column`. The
    // GROUPING SETS form must AGREE: `expand` materialises the column into each
    // arm and the arm's grouped resolver rejects it with the SAME `.grouping`
    // fault. (This assertion previously expected `.column("Product")` from the
    // old scope-less matcher, which disagreed with the plain form — an existing
    // assertion that encoded that divergence, now corrected to the oracle.)
    let cat = try sales()
    let fault = SQLError.grouping("Product")
    cat.expect("""
        SELECT Region
          FROM Sales AS n
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY n.Product
        """, fails: fault)
    cat.expect("""
        SELECT Region FROM Sales AS n GROUP BY Region ORDER BY n.Product
        """, fails: fault)
  }

  @Test func `ORDER BY a qualified unprojected grouping column matches plain`()
      throws {
    // A qualified `ORDER BY n.Region` whose bare name is NOT projected but IS a
    // grouping key: the plain grouped form ACCEPTS it (ordering on the group
    // key). The GROUPING SETS form agrees — `expand` materialises it hidden,
    // the carrier resolves the qualified key through the arm's grouped space to
    // its hidden slot, orders on it, and trims it. Ascending Region: East 35,
    // West 10.
    let cat = try sales()
    try cat.expect("""
        SELECT SUM(Qty) FROM Sales AS n
         GROUP BY GROUPING SETS ((Region)) ORDER BY n.Region
        """, equals: """
        SELECT SUM(Qty) FROM Sales AS n GROUP BY Region ORDER BY n.Region
        """)
    try cat.expect("""
        SELECT SUM(Qty) FROM Sales AS n
         GROUP BY GROUPING SETS ((Region)) ORDER BY n.Region
        """, yields: [[35], [10]])
  }

  @Test func `a qualified key does not alias-match a different output by name`()
      throws {
    // The output named `Region` is `Product AS Region` — its RESOLVED identity
    // is `Product`, NOT `s.Region`. A qualified `ORDER BY s.Region` references
    // the grouped INPUT column `s.Region`, a grouping key that is NOT
    // projected. The is-projected check must use RESOLVED IDENTITY, not the
    // BARE name: matching `s.Region` to the alias `Region` by bare name SKIPS
    // hidden materialisation, and the setop-output scope cannot resolve the
    // qualified `s.Region` — so the carrier faulted (or mis-bound to Product).
    // The qualified key routes through the arm's grouped resolver, materialises
    // hidden, and matches the plain grouped form that sorts by the grouped
    // `s.Region`.
    let cat = try sales()
    try cat.expect("""
        SELECT Product AS Region, SUM(Qty) FROM Sales AS s
         GROUP BY GROUPING SETS ((s.Region, Product)) ORDER BY s.Region
        """, equals: """
        SELECT Product AS Region, SUM(Qty) FROM Sales AS s
         GROUP BY s.Region, Product ORDER BY s.Region
        """)
    // run ≡ columns(of:): the alias `Region` and the aggregate, hidden trimmed.
    let columns = try cat.columns(of: parse(query: """
        SELECT Product AS Region, SUM(Qty) FROM Sales AS s
         GROUP BY GROUPING SETS ((s.Region, Product)) ORDER BY s.Region
        """), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "column 2", type: .integer),
    ])
  }

  @Test func `an unqualified key still binds a select alias per ISO precedence`()
      throws {
    // The GUARD for the fix above: the bare-name output match still applies to
    // an UNQUALIFIED key. `ORDER BY Region` where `Region` is the select alias
    // for `Product` binds the OUTPUT alias (ISO output-alias precedence: a bare
    // name → a select-list alias), NOT the input column `Region`, so it sorts
    // by the projected Product value — the plain grouped form is the oracle.
    let cat = try sales()
    try cat.expect("""
        SELECT Product AS Region, SUM(Qty) FROM Sales AS s
         GROUP BY GROUPING SETS ((s.Region, Product)) ORDER BY Region
        """, equals: """
        SELECT Product AS Region, SUM(Qty) FROM Sales AS s
         GROUP BY s.Region, Product ORDER BY Region
        """)
  }

  @Test func `DISTINCT combines with a query-level ORDER BY over the union`()
      throws {
    // `SELECT DISTINCT` with a query-level ORDER BY: the carrier dedups the
    // union's rows and orders them. Over `((Region), ())` the per-Region rows
    // (35, 10) and the grand total (45) are already distinct; ORDER BY the
    // aggregate ascending gives West 10, East 35, total 45.
    try sales().expect("""
        SELECT DISTINCT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY SUM(Qty)
        """, yields: [["West", 10], ["East", 35], [nil, 45]])
  }

  @Test func `DISTINCT rejects a hidden unprojected-aggregate sort key`()
      throws {
    // Under `SELECT DISTINCT`, an ORDER BY expression that is NOT in the select
    // list is an ERROR (ISO 9075). An unprojected `ORDER BY MAX(Qty)` would be
    // MATERIALISED as a hidden `*gsN` column, but that slot is NOT a real
    // output — the DISTINCT check sees only the REAL outputs (`0 ..< real`), so
    // the key is REJECTED with the same `.distinct` fault the plain grouped
    // form raises, rather than passing as if the hidden slot were projected and
    // rebinding the sort OUTSIDE the real projection (which crashed).
    let cat = try sales()
    let fault = SQLError.distinct("an expression")
    cat.expect("""
        SELECT DISTINCT Region
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY MAX(Qty)
        """, fails: fault)
    // The plain grouped ORACLE rejects the same non-selected sort key.
    cat.expect("""
        SELECT DISTINCT Region FROM Sales GROUP BY Region ORDER BY MAX(Qty)
        """, fails: fault)
    // run ≡ columns(of:): the schema derive faults identically, not a schema.
    #expect(throws: fault) {
      _ = try cat.columns(of: parse(query: """
          SELECT DISTINCT Region
            FROM Sales
           GROUP BY GROUPING SETS ((Region), ())
           ORDER BY MAX(Qty)
          """), validate: true)
    }
  }

  // MARK: - Carrier ORDER BY joins the validation walk

  @Test func `validate faults an unknown routine in a carrier ORDER BY`()
      throws {
    // The `ordered` carrier's ORDER BY is a NEW expression surface: it must
    // join the validation walk, else a reachable faulting sort key
    // `columns(of:)` ACCEPTS the run raises on. An unknown routine (`ORDER BY
    // missing(Region)`) faults `.function` at run; validate now faults
    // IDENTICALLY over the same setop-output scope, closing the run-vs-validate
    // gap.
    let cat = try sales()
    let sql = """
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY missing(Region)
        """
    let fault = SQLError.function("missing")
    cat.expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try cat.columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `validate faults an ill-typed operand in a carrier ORDER BY`()
      throws {
    // The operand counterpart: `ORDER BY SUM(Qty) + 'x'` mixes a number and a
    // string, faulting `.operand` at run; validate now faults IDENTICALLY,
    // rather than returning a schema for a query the run rejects.
    let cat = try sales()
    let sql = """
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY SUM(Qty) + 'x'
        """
    let fault = SQLError.operand("operands must be numeric")
    cat.expect(sql, fails: fault)
    #expect(throws: fault) {
      _ = try cat.columns(of: parse(query: sql), validate: true)
    }
  }

  @Test func `a valid carrier ORDER BY still validates and resolves`() throws {
    // The parity guard: a VALID carrier ORDER BY expression (an already-checked
    // call over an output) still validates and resolves its schema — the walk
    // must not over-reject. `UPPER(Region)` orders the union by the uppercased
    // region; the schema derive agrees with the run.
    let cat = try sales()
    let sql = """
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY UPPER(Region)
        """
    try cat.expect(sql, yields: [[nil, 45], ["East", 35], ["West", 10]])
    let columns = try cat.columns(of: parse(query: sql), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "column 2", type: .integer),
    ])
  }

  @Test func `NULLs sort first ascending over the combined union`() throws {
    // The `()` grand-total arm NULLs Region; ascending, the NULL sorts FIRST
    // over the whole union — the setop-output scope orders identically to a
    // plain derived union. (DESC counterpart is covered above.)
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY Region
        """, yields: [[nil, 45], ["East", 35], ["West", 10]])
  }

  @Test func `a grouping-sets CTE body with an ORDER BY runs and types`()
      throws {
    // A GROUPING SETS body carrying a query-level ORDER BY, used as a CTE: the
    // run and the schema derive agree (`run ≡ columns(of:)`). The CTE reports
    // its declared columns; the body orders the union by the aggregate.
    let cat = try sales()
    let sql = """
        WITH t (Region, Total) AS (
          SELECT Region, SUM(Qty)
            FROM Sales
           GROUP BY GROUPING SETS ((Region), ())
           ORDER BY SUM(Qty)
        )
        SELECT * FROM t
        """
    let rows = try cat.run(Statement(parsing: sql))
    #expect(rows == [
      [.text("West"), .integer(10)],
      [.text("East"), .integer(35)],
      [.null, .integer(45)],
    ])
    let columns = try cat.columns(of: Statement(parsing: sql), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "Total", type: .integer),
    ])
  }

  @Test func `a derived table in a grouping-sets arm runs under ORDER BY`()
      throws {
    // The GROUPING SETS expansion is a `UNION ALL` of per-set grouped arms,
    // each over the SAME `FROM (SELECT …) AS s` — so every arm names the
    // derived alias `s`. Under the query-level ORDER BY carrier, the union must
    // run PER ARM (each materialising `s` in its own scope); before, the
    // single-context carrier execution never bound `s` and faulted
    // `.relation`. Per-Region sums (East 15, West 7) and the grand total (22),
    // ordered by SUM.
    let cat = try Catalog {
      Relation("Base", ["Region": .text, "Qty": .integer]) {
        Row("East", 10)
        Row("East", 5)
        Row("West", 7)
      }
    }
    try cat.expect("""
        SELECT SUM(Qty) FROM (SELECT Region, Qty FROM Base) AS s
         GROUP BY GROUPING SETS ((Region), ())
         ORDER BY 1
        """, yields: [[7], [15], [22]])
  }

  // MARK: - Subqueries in an omitted grouping set

  @Test func `a subquery in an omitted set is collected for the () arm`()
      throws {
    // A scalar subquery in a set's key must be pre-registered for EVERY arm,
    // not only the arms whose set includes it: an `.arm` lowers the SUPERSET
    // (to NULL an absent key), so the `()` grand-total arm lowers `(SELECT 1)`
    // and needs it collected. The present arm groups on the constant subquery
    // value (one group) and projects it (1); the `()` arm NULLs the absent key.
    let cat = try sales()
    try cat.expect("""
        SELECT (SELECT 1)
          FROM Sales
         GROUP BY GROUPING SETS (((SELECT 1)), ())
        """, yields: [[1], [nil]])
    // run ≡ columns(of:): the schema derive resolves the same, not a fault.
    let columns = try cat.columns(of: parse(query: """
        SELECT (SELECT 1)
          FROM Sales
         GROUP BY GROUPING SETS (((SELECT 1)), ())
        """), validate: true)
    #expect(columns == [OutputColumn(name: "column 1", type: .integer)])
  }

  // MARK: - Empty set list

  @Test func `an empty GROUPING SETS set list is a syntax fault, not a crash`()
      throws {
    // `Grouping.sets` is a public AST case, so a caller may build an EMPTY set
    // list (the parser never emits it). The expansion must reject it with a
    // typed `SQLError` before the `UNION ALL` reduce seed (`arms[0]`) traps the
    // process on the empty arm list.
    let cat = try sales()
    let empty = Select(projection: .expressions([
      Projected(expression: .literal(.integer(1)))
    ]), from: Relation(name: "Sales"), grouping: .sets([]))
    let fault = SQLError.state("42601",
                               "GROUPING SETS requires at least one set")
    let raised: SQLError?
    do {
      _ = try cat.run(.select(empty))
      raised = nil
    } catch let error {
      raised = error
    }
    #expect(raised == fault)
    // `columns(of:)` faults the same, not a crash or a schema.
    let columns: SQLError?
    do {
      _ = try cat.columns(of: .select(empty), validate: true)
      columns = nil
    } catch let error {
      columns = error
    }
    #expect(columns == fault)
  }
}

// MARK: - Context tokens

/// A `T` relation whose columns are literally named `grouping` and `sets` — the
/// two context identifiers — to prove they stay usable as column names.
private func context() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["grouping": .text, "sets": .integer]) {
      Row("x", 1)
      Row("y", 2)
    }
  }
}

// MARK: - Carrier resolves by structure, not text/AST

struct GroupingSetsCarrierStructureTests {
  @Test func `a DISTINCT qualified-aggregate sort key matches the projected one`()
      throws {
    // `ORDER BY SUM(s.Qty)` is the SAME projected value as `SUM(Qty)` — it
    // differs only by qualification — so the carrier matches it to that
    // projected output by RESOLVED identity (through the arm's grouped space),
    // never a spurious hidden sort column that DISTINCT would then reject. It
    // must run IDENTICALLY to the plain grouped form, the oracle.
    try sales().expect("""
        SELECT DISTINCT SUM(Qty) FROM Sales AS s
         GROUP BY GROUPING SETS ((Region)) ORDER BY SUM(s.Qty)
        """, equals: """
        SELECT DISTINCT SUM(Qty) FROM Sales AS s
         GROUP BY Region ORDER BY SUM(s.Qty)
        """)
  }

  @Test func `a genuinely unprojected aggregate under DISTINCT faults as plain`()
      throws {
    // A sort key the SELECT DISTINCT list does not project is rejected — the
    // same `.distinct` fault the plain grouped form raises, not accepted as if
    // its hidden materialised slot were a select-list value.
    try sales().expect("""
        SELECT DISTINCT Region FROM Sales AS s
         GROUP BY GROUPING SETS ((Region)) ORDER BY MAX(Qty)
        """, fails: .distinct("an expression"))
    try sales().expect("""
        SELECT DISTINCT Region FROM Sales AS s
         GROUP BY Region ORDER BY MAX(Qty)
        """, fails: .distinct("an expression"))
  }

  @Test func `a bare-vs-qualified column sort key still matches (regression)`()
      throws {
    // The pre-existing qualifier-equivalent COLUMN case keeps working under the
    // resolved-identity match: `ORDER BY s.Region` ≡ the projected `Region`.
    try sales().expect("""
        SELECT Region, SUM(Qty) FROM Sales AS s
         GROUP BY GROUPING SETS ((Region)) ORDER BY s.Region
        """, equals: """
        SELECT Region, SUM(Qty) FROM Sales AS s
         GROUP BY Region ORDER BY s.Region
        """)
  }

  @Test func `a delimited *gs0 alias is a real output, not a generated column`()
      throws {
    // The generated hidden-column count is STRUCTURAL (carried out of `expand`),
    // so a user's DELIMITED alias `AS "*gs0"` — which by NAME looks like a
    // generated `*gsN` sort column — is NOT trimmed: it is the real, only output
    // (this is a PLAIN union, no grouping, so no column is ever generated).
    try pair().expect("""
        SELECT a AS "*gs0" FROM L UNION ALL SELECT b FROM R ORDER BY 1
        """, yields: [[1], [2], [3], [4], [5]])
    let cat = try pair()
    let columns = try cat.columns(of: parse(query: """
        SELECT a AS "*gs0" FROM L UNION ALL SELECT b FROM R ORDER BY 1
        """), validate: true)
    #expect(columns == [OutputColumn(name: "*gs0", type: .integer)])
  }

  @Test func `a real GROUPING SETS unprojected sort key trims its generated column`()
      throws {
    // A genuinely-unprojected aggregate sort key IS materialised as a generated
    // hidden column so it survives the UNION ALL; the carrier trims it so the
    // result is exactly the projected columns, ordered by the hidden slot. The
    // schema (run ≡ columns) drops the generated column too.
    let cat = try sales()
    try cat.expect("""
        SELECT Region FROM Sales AS s
         GROUP BY GROUPING SETS ((Region)) ORDER BY MAX(Qty)
        """, yields: [["West"], ["East"]])
    let columns = try cat.columns(of: parse(query: """
        SELECT Region FROM Sales AS s
         GROUP BY GROUPING SETS ((Region)) ORDER BY MAX(Qty)
        """), validate: true)
    #expect(columns == [OutputColumn(name: "Region", type: .text)])
  }

  @Test func `an out-of-range ordinal after a materialised key faults like plain`()
      throws {
    // An unprojected `MAX(Qty)` sort key materialises a hidden `*gsN` column, so
    // the inner union's width becomes 2 — but the ONLY real output is `Region`.
    // A trailing ORDINAL must bind the REAL output arity (`0 ..< real`), NOT the
    // grown width, so `ORDER BY MAX(Qty), 2` faults `.column("2")` exactly as
    // the plain grouped `GROUP BY Region ORDER BY MAX(Qty), 2` does — never
    // binding the hidden `MAX(Qty)` slot as if it were a select-list output.
    try sales().expect("""
        SELECT Region FROM Sales GROUP BY GROUPING SETS ((Region))
         ORDER BY MAX(Qty), 2
        """, fails: .column("2"))
    try sales().expect("""
        SELECT Region FROM Sales GROUP BY Region ORDER BY MAX(Qty), 2
        """, fails: .column("2"))
  }

  @Test func `an out-of-range ordinal before a materialised key faults like plain`()
      throws {
    // The bound is ORDER-INDEPENDENT: whether the materialising `MAX(Qty)` key
    // comes before or after the ordinal, `ORDER BY 2, MAX(Qty)` still faults
    // `.column("2")` over the single real output, matching the plain form.
    try sales().expect("""
        SELECT Region FROM Sales GROUP BY GROUPING SETS ((Region))
         ORDER BY 2, MAX(Qty)
        """, fails: .column("2"))
    try sales().expect("""
        SELECT Region FROM Sales GROUP BY Region ORDER BY 2, MAX(Qty)
        """, fails: .column("2"))
  }

  @Test func `an in-range ordinal after a materialised key binds the real output`()
      throws {
    // An IN-RANGE ordinal still binds the real output even when an earlier key
    // materialised a hidden column: `ORDER BY MAX(Qty), 1` orders by `Region`
    // (ordinal 1, the sole real output), agreeing with the plain grouped form.
    try sales().expect("""
        SELECT Region FROM Sales GROUP BY GROUPING SETS ((Region))
         ORDER BY MAX(Qty), 1
        """, equals: """
        SELECT Region FROM Sales GROUP BY Region ORDER BY MAX(Qty), 1
        """)
  }

  @Test func `a pure ordinal ORDER BY over a GROUPING SETS query still binds`()
      throws {
    // A GROUPING SETS query with NO materialised hidden column (no unprojected
    // sort key) still resolves a positional `ORDER BY 1` over its real output —
    // the ordinal bound is the real arity, unchanged when nothing is
    // materialised. The grand-total NULL and the two per-Region rows, by Region
    // ascending (NULL sorts first).
    try sales().expect("""
        SELECT Region FROM Sales GROUP BY GROUPING SETS ((Region), ())
         ORDER BY 1
        """, yields: [[nil], ["East"], ["West"]])
  }

  @Test func `a real ordinal past the first output binds a multi-output GS query`()
      throws {
    // When ordinal 2 IS a real output, the bound admits it: a two-output
    // GROUPING SETS query with an unprojected-aggregate sort key materialises a
    // hidden THIRD column, but `ORDER BY SUM(Qty), 2` binds the real second
    // output (`SUM(Qty)`), matching the plain grouped form.
    try sales().expect("""
        SELECT Region, SUM(Qty) FROM Sales GROUP BY GROUPING SETS ((Region))
         ORDER BY MAX(Qty), 2
        """, equals: """
        SELECT Region, SUM(Qty) FROM Sales GROUP BY Region ORDER BY MAX(Qty), 2
        """)
  }

  @Test func `an explicit "column 1" alias is bindable, not a synthesized header`()
      throws {
    // A synthesized display header `column N` is non-bindable by name, but the
    // carrier distinguishes it from an EXPLICIT delimited `AS "column 1"` by the
    // STRUCTURAL synthesized flag, not by comparing the name text — so ordering
    // by the explicit alias works.
    try pair().expect("""
        SELECT a AS "column 1" FROM L UNION ALL SELECT b FROM R
         ORDER BY "column 1"
        """, yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a genuinely unnamed set-op output stays ordinal-only`() throws {
    // A computed output with no alias is a synthesized `column N` header — not
    // bindable by that name — so it is reachable only by ordinal, exactly as a
    // plain derived union.
    try pair().expect("""
        SELECT a + 0 FROM L UNION ALL SELECT b FROM R ORDER BY 1
        """, yields: [[1], [2], [3], [4], [5]])
    let cat = try pair()
    cat.expect("""
        SELECT a + 0 FROM L UNION ALL SELECT b FROM R ORDER BY "column 1"
        """, fails: .column("column 1"))
  }
}

// `pair` mirrors the OrderedSetOperation fixture — two single-column relations
// `L`(a) and `R`(b) — for the carrier's plain-union structural cases above.
private func pair() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["a": .integer]) { Row(3); Row(1); Row(2) }
    Relation("R", ["b": .integer]) { Row(5); Row(4) }
  }
}

struct GroupingSetsContextTokenTests {
  @Test func `grouping and sets remain usable as column names`() throws {
    // `GROUPING`/`SETS` are context identifiers, not lexer keywords, so a
    // column named either — projected, and a `GROUP BY` key — parses as a plain
    // reference. `grouping` here is NOT followed by `SETS`, so it stays a key.
    try context().expect("""
        SELECT grouping, sets FROM T GROUP BY grouping, sets
        """, yields: [["x", 1], ["y", 2]])
  }

  @Test func `grouping is a plain group key when not followed by sets`() throws {
    // A lone `GROUP BY grouping` (the context identifier not opening the
    // construct) groups on the column, unchanged from before the construct
    // existed.
    try context().expect("SELECT grouping FROM T GROUP BY grouping",
                         yields: [["x"], ["y"]])
  }
}
