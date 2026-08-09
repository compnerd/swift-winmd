// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// MARK: - Fixtures

/// A `Sales` relation of `Region`/`Product`/`Qty` rows — the same groupable
/// shape the GROUPING SETS suite uses. Per-(Region, Product) sums: East/A 15
/// (10 + 5), East/B 20, West/A 7, West/B 3. Per-Region sums: East 35, West 10.
/// Per-Product sums: A 22 (10 + 5 + 7), B 23 (20 + 3). Grand total 45.
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
/// `SUM` — for the duplicate-overlap and general-key cases. Per-A sums: 1 is
/// 150 (100 + 50), 2 is 30.
private func nums() throws -> FixtureCatalog {
  try Catalog {
    Relation("N", ["A": .integer, "V": .integer]) {
      Row(1, 100)
      Row(1, 50)
      Row(2, 30)
    }
  }
}

/// A three-dimensional `G` relation — `A`/`B`/`C` grouping columns and a `V` to
/// `SUM` — for the composite-unit case `ROLLUP((A, B), C)`, where `(A, B)` is
/// one indivisible level. Rows are chosen so each level's sums are distinct.
private func grid() throws -> FixtureCatalog {
  try Catalog {
    Relation("G", ["A": .integer, "B": .integer, "C": .integer,
                   "V": .integer]) {
      Row(1, 1, 1, 10)
      Row(1, 1, 2, 20)
      Row(1, 2, 1, 30)
      Row(2, 1, 1, 40)
    }
  }
}

// MARK: - ROLLUP / CUBE

struct RollupCubeTests {
  @Test func `ROLLUP(a, b) yields the full, per-prefix, and grand-total levels`()
      throws {
    // `ROLLUP(Region, Product)` desugars to the descending prefixes of its two
    // units — `[[Region, Product], [Region], []]` — so three arms: the full
    // grouping, the per-Region grouping (Product a super-aggregate NULL), and
    // the grand total (both NULL). Arm order, then row order within each arm
    // (first-appearance). Per-(Region, Product): East/A 15, East/B 20, West/A
    // 7, West/B 3; per-Region: East 35, West 10; grand total 45.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region, Product)
        """, yields: [
          ["East", "A", 15], ["East", "B", 20],
          ["West", "A", 7], ["West", "B", 3],
          ["East", nil, 35], ["West", nil, 10],
          [nil, nil, 45],
        ])
    // The desugar's oracle: the same query written as the equivalent explicit
    // GROUPING SETS (Stage 1) yields identical rows — pinning both the set
    // content and the arm ORDER of `ROLLUP`.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region, Product)
        """, equals: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product), (Region), ())
        """)
    // The clause desugars to `.sets`, not the plain `.keys` path.
    let select = try parse(select: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region, Product)
        """)
    let union: Bool
    if case .sets = select.grouping { union = true } else { union = false }
    #expect(union)
  }

  @Test func `CUBE(a, b) yields all four subset levels, full set first`() throws {
    // `CUBE(Region, Product)` desugars to every subset of its two units,
    // enumerated FULL-SET-FIRST by descending mask:
    // `[[Region, Product], [Product], [Region], []]`. Four arms: the full
    // grouping, the per-Product grouping (Region NULL), the per-Region grouping
    // (Product NULL), and the grand total. Per-Product: A 22, B 23.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY CUBE(Region, Product)
        """, yields: [
          ["East", "A", 15], ["East", "B", 20],
          ["West", "A", 7], ["West", "B", 3],
          [nil, "A", 22], [nil, "B", 23],
          ["East", nil, 35], ["West", nil, 10],
          [nil, nil, 45],
        ])
    // The oracle pins the subset-enumeration ORDER: the hand-written GROUPING
    // SETS lists the four subsets in exactly the descending-mask order `CUBE`
    // produces (full, {Product}, {Region}, {}).
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY CUBE(Region, Product)
        """, equals: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product), (Product), (Region), ())
        """)
  }

  @Test func `GROUP BY a, ROLLUP(b) cross-products the elements`() throws {
    // The whole clause is the CROSS product of its elements: the ordinary
    // `Region` (`[[Region]]`) crossed with `ROLLUP(Product)`
    // (`[[Product], []]`) gives `[[Region, Product], [Region]]` — the full
    // grouping and the per-Region subtotal, with no grand total (Region is
    // present in every set). Per-(Region, Product) then per-Region.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY Region, ROLLUP(Product)
        """, yields: [
          ["East", "A", 15], ["East", "B", 20],
          ["West", "A", 7], ["West", "B", 3],
          ["East", nil, 35], ["West", nil, 10],
        ])
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY Region, ROLLUP(Product)
        """, equals: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region, Product), (Region))
        """)
  }

  @Test func `GROUPING SETS nests a ROLLUP and an ordinary set`() throws {
    // A `GROUPING SETS` element may itself be a construct: `(ROLLUP(Region),
    // (Product))` CONCATENATES `ROLLUP(Region)`'s `[[Region], []]` with the
    // ordinary set `[[Product]]`, giving `[[Region], [], [Product]]` — per
    // Region, grand total, then per Product.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS (ROLLUP(Region), (Product))
        """, yields: [
          ["East", nil, 35], ["West", nil, 10],
          [nil, nil, 45],
          [nil, "A", 22], [nil, "B", 23],
        ])
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS (ROLLUP(Region), (Product))
        """, equals: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), (), (Product))
        """)
  }

  @Test func `ROLLUP((a, b), c) treats the composite unit as one level`() throws {
    // A parenthesised unit `(A, B)` groups its members as one indivisible
    // level. `ROLLUP((A, B), C)` desugars to `[[A, B, C], [A, B], []]` — no
    // `[A]` level, unlike `ROLLUP(A, B, C)`. Per-(A, B, C): 4 rows; per-(A, B):
    // (1,1) 30, (1,2) 30, (2,1) 40; grand total 100.
    try grid().expect("""
        SELECT A, B, C, SUM(V)
          FROM G
         GROUP BY ROLLUP((A, B), C)
        """, equals: """
        SELECT A, B, C, SUM(V)
          FROM G
         GROUP BY GROUPING SETS ((A, B, C), (A, B), ())
        """)
    try grid().expect("""
        SELECT A, B, C, SUM(V)
          FROM G
         GROUP BY ROLLUP((A, B), C)
        """, yields: [
          [1, 1, 1, 10], [1, 1, 2, 20], [1, 2, 1, 30], [2, 1, 1, 40],
          [1, 1, nil, 30], [1, 2, nil, 30], [2, 1, nil, 40],
          [nil, nil, nil, 100],
        ])
  }

  @Test func `an ordinary GROUP BY a, b stays the plain keys path`() throws {
    // A clause with no construct is unchanged — it desugars to `.keys`, the
    // plain grouped path, so `GROUP BY Region, Product` is one group set (the
    // four per-(Region, Product) rows), NOT a set list with super-aggregate
    // arms.
    let select = try parse(select: """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY Region, Product
        """)
    let plain: Bool
    if case .keys = select.grouping { plain = true } else { plain = false }
    #expect(plain)
    try sales().expect("""
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY Region, Product
        """, yields: [
          ["East", "A", 15], ["East", "B", 20],
          ["West", "A", 7], ["West", "B", 3],
        ])
  }

  @Test func `a function-call and an arithmetic key do not misfire the construct`()
      throws {
    // An ordinary key is a general scalar `expression`, so a function call
    // `UPPER(Product)` and an arithmetic `A + 1` group normally — the
    // ROLLUP/CUBE lookahead fires ONLY on a bare `ROLLUP`/`CUBE` immediately
    // before `(`, never on another call. `UPPER(Product)` leaves the
    // already-upper A/B unchanged, so it matches `GROUP BY Product`; `A + 1`
    // groups 1 → 2, 2 → 3.
    try sales().expect("""
        SELECT UPPER(Product), SUM(Qty)
          FROM Sales
         GROUP BY UPPER(Product)
        """, equals: """
        SELECT Product, SUM(Qty) FROM Sales GROUP BY Product
        """)
    try nums().expect("""
        SELECT A + 1, SUM(V) FROM N GROUP BY A + 1
        """, yields: [[2, 150], [3, 30]])
    // Both stay the plain `.keys` path — no construct token appeared.
    let select = try parse(select: "SELECT A + 1 FROM N GROUP BY A + 1")
    let plain: Bool
    if case .keys = select.grouping { plain = true } else { plain = false }
    #expect(plain)
  }

  @Test func `a column named rollup stays a grouping key, delimited or bare`()
      throws {
    // `ROLLUP`/`CUBE` are context identifiers: a delimited `"rollup"` (a quoted
    // identifier, never the construct) and a bare `rollup` NOT followed by `(`
    // both stay ordinary keys. The construct fires only on a bare `rollup(`.
    let cat = try Catalog {
      Relation("T", ["rollup": .text, "cube": .integer]) {
        Row("x", 1)
        Row("y", 2)
      }
    }
    // A bare `rollup`/`cube` not followed by `(` — plain grouping keys.
    try cat.expect("""
        SELECT rollup, cube FROM T GROUP BY rollup, cube
        """, yields: [["x", 1], ["y", 2]])
    // The delimited spellings group identically.
    try cat.expect("""
        SELECT "rollup", "cube" FROM T GROUP BY "rollup", "cube"
        """, yields: [["x", 1], ["y", 2]])
    // A lone bare `rollup` key stays the plain `.keys` path.
    let select = try parse(select: "SELECT rollup FROM T GROUP BY rollup")
    let plain: Bool
    if case .keys = select.grouping { plain = true } else { plain = false }
    #expect(plain)
  }

  @Test func `run agrees with columns(of:validate:) for a ROLLUP query`() throws {
    // run ≡ schema: the type derive over the union `.sets` matches the run.
    // A NULL-padded column takes its sibling arm's type through the
    // set-operation merge, so Region/Product stay `.text` and the SUM
    // `.integer`.
    let cat = try sales()
    let sql = """
        SELECT Region, Product, SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region, Product)
        """
    try cat.expect(sql, yields: [
      ["East", "A", 15], ["East", "B", 20],
      ["West", "A", 7], ["West", "B", 3],
      ["East", nil, 35], ["West", nil, 10],
      [nil, nil, 45],
    ])
    let columns = try cat.columns(of: parse(query: sql), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "Product", type: .text),
      OutputColumn(name: "column 3", type: .integer),
    ])
  }

  @Test func `ROLLUP rides the carrier for an unprojected-aggregate ORDER BY`()
      throws {
    // A ROLLUP query with a query-level ORDER BY over an unprojected aggregate
    // (`MAX(Qty)`, not in the select list) rides the `ordered` carrier over the
    // union — `expand` materialises the aggregate as a hidden column in every
    // arm, orders on it, and trims it. `ROLLUP(Region)` is `((Region), ())`;
    // per-Region MAX(Qty) East 20 / West 7, the grand-total MAX 20. Ascending
    // MAX: West (7) → 10, then East (20) → 35 and the total (20) → 45 in arm
    // order.
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales
         GROUP BY ROLLUP(Region) ORDER BY MAX(Qty)
        """, yields: [[10], [35], [45]])
    // The carrier trims the hidden aggregate: exactly the one projected column.
    let cat = try sales()
    let columns = try cat.columns(of: parse(query: """
        SELECT SUM(Qty) FROM Sales
         GROUP BY ROLLUP(Region) ORDER BY MAX(Qty)
        """), validate: true)
    #expect(columns == [OutputColumn(name: "column 1", type: .integer)])
  }

  @Test func `an empty ROLLUP() and CUBE() collapse to one grand-total set`()
      throws {
    // Zero units is admitted: the empty product is the single empty grand-total
    // set (`.sets([[]])`), so `ROLLUP()` and `CUBE()` each yield exactly one
    // grand-total row — the SUM over the whole relation, 45.
    try sales().expect("SELECT SUM(Qty) FROM Sales GROUP BY ROLLUP()",
                       yields: [[45]])
    try sales().expect("SELECT SUM(Qty) FROM Sales GROUP BY CUBE()",
                       yields: [[45]])
    // The oracle: `GROUPING SETS (())` — a lone grand-total set — is identical.
    try sales().expect("SELECT SUM(Qty) FROM Sales GROUP BY ROLLUP()",
                       equals: """
        SELECT SUM(Qty) FROM Sales GROUP BY GROUPING SETS (())
        """)
    // Still the `.sets` path (a construct token appeared), not plain `.keys`.
    let select = try parse(select: "SELECT SUM(Qty) FROM Sales GROUP BY CUBE()")
    let union: Bool
    if case .sets = select.grouping { union = true } else { union = false }
    #expect(union)
  }

  @Test func `a duplicate grouping set keeps its rows, not deduplicated`() throws {
    // ISO combines the sets with UNION ALL, so an overlapping clause keeps
    // duplicate rows. `GROUP BY ROLLUP(A), A` crosses `[[A], []]` with `[[A]]`
    // into `[[A, A], [A]]` — both sets group by `A` (a repeated key is
    // harmless), so each per-A group appears twice.
    try nums().expect("""
        SELECT A, SUM(V) FROM N GROUP BY ROLLUP(A), A
        """, yields: [[1, 150], [2, 30], [1, 150], [2, 30]])
    try nums().expect("""
        SELECT A, SUM(V) FROM N GROUP BY ROLLUP(A), A
        """, equals: """
        SELECT A, SUM(V) FROM N GROUP BY GROUPING SETS ((A), (A))
        """)
  }

  @Test func `a scalar-subquery unit keeps its own parenthesis`() throws {
    // A `ROLLUP`/`CUBE` unit, or a `GROUPING SETS` member, that IS a scalar
    // subquery `(VALUES …)` must route through `expression` — the leading `(`
    // is the subquery's, not a composite-set delimiter, so it is not stolen
    // (which produced `expected an identifier but found 'VALUES'`). A scalar
    // subquery is a valid ordinary grouping key, so it is valid as a unit too.
    // `(VALUES (1))` is a constant, so grouping on it forms one group.
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales GROUP BY ROLLUP((VALUES (1)))
        """, equals: """
        SELECT SUM(Qty) FROM Sales
          GROUP BY GROUPING SETS (((VALUES (1))), ())
        """)
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales GROUP BY CUBE((VALUES (1)))
        """, equals: """
        SELECT SUM(Qty) FROM Sales
          GROUP BY GROUPING SETS (((VALUES (1))), ())
        """)
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales GROUP BY GROUPING SETS ((VALUES (1)))
        """, equals: "SELECT SUM(Qty) FROM Sales GROUP BY (VALUES (1))")
    // A subquery beside an ordinary key in a composite unit still parses — the
    // composite `(` is the delimiter, the inner `(VALUES …)` its own key.
    try sales().expect("""
        SELECT Region, SUM(Qty) FROM Sales
          GROUP BY ROLLUP(((VALUES (1)), Region))
        """, equals: """
        SELECT Region, SUM(Qty) FROM Sales
          GROUP BY GROUPING SETS (((VALUES (1)), Region), ())
        """)
    // guard: a plain composite unit `(a, b)` is unaffected — no subquery, the
    // `(` stays a set delimiter.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty) FROM Sales
          GROUP BY ROLLUP((Region, Product))
        """, equals: """
        SELECT Region, Product, SUM(Qty) FROM Sales
          GROUP BY GROUPING SETS ((Region, Product), ())
        """)
  }

  @Test func `a top-level parenthesised ordinary set groups its keys`() throws {
    // The generalised grammar admits a top-level parenthesised composite set
    // `(a, b)` and the grand-total `()` — which the flat `expression` path
    // could not consume (a comma list / empty parens faulted). They group
    // exactly as the bare forms.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty) FROM Sales GROUP BY (Region, Product)
        """, equals: """
        SELECT Region, Product, SUM(Qty) FROM Sales GROUP BY Region, Product
        """)
    // `GROUP BY ()` is the grand total — equivalent to no `GROUP BY`.
    try sales().expect("SELECT SUM(Qty) FROM Sales GROUP BY ()",
                       equals: "SELECT SUM(Qty) FROM Sales")
    // A composite set beside a bare key.
    try sales().expect("""
        SELECT Region, Product, SUM(Qty) FROM Sales GROUP BY (Region), Product
        """, equals: """
        SELECT Region, Product, SUM(Qty) FROM Sales GROUP BY Region, Product
        """)
    // guard (no regression): a top-level `(` that begins a larger scalar key
    // — a parenthesised expression `(A + 1)`, or a paren that merely starts an
    // expression `(A) + 1` — is read as one key, NOT truncated at the `)`. The
    // row backtracking rewinds a single `(…)` with no top-level comma.
    try nums().expect("SELECT A + 1, SUM(V) FROM N GROUP BY (A + 1)",
                      equals: "SELECT A + 1, SUM(V) FROM N GROUP BY A + 1")
    try nums().expect("SELECT A + 1, SUM(V) FROM N GROUP BY (A) + 1",
                      equals: "SELECT A + 1, SUM(V) FROM N GROUP BY A + 1")
    // A top-level scalar subquery key still parses (the `(` is the subquery's).
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales GROUP BY (VALUES (1))
        """, equals: "SELECT SUM(Qty) FROM Sales GROUP BY (VALUES (1))")
  }

  @Test func `GROUP BY () is the grand total, not absent grouping`() throws {
    // `GROUP BY ()` is a single grand-total group — NOT the `.keys([])` shape
    // an absent `GROUP BY` carries, which is no grouping (one row per input
    // row). It yields one row whatever the input cardinality, matching the
    // GROUPING SETS `(())` form.
    try sales().expect("SELECT 1 FROM Sales GROUP BY ()", yields: [[1]])
    try sales().expect("""
        SELECT SUM(Qty) FROM Sales GROUP BY ()
        """, equals: """
        SELECT SUM(Qty) FROM Sales GROUP BY GROUPING SETS (())
        """)
    // Over an empty input the grand-total group still yields its one row.
    let empty = try Catalog { Relation("E", ["x": .integer]) { } }
    try empty.expect("SELECT 1 FROM E GROUP BY ()", yields: [[1]])
    try empty.expect("SELECT COUNT(*) FROM E GROUP BY ()", yields: [[0]])
  }

  @Test func `an over-large CUBE or cross product faults, not overflows`()
      throws {
    // A CUBE of 63/64 units once overflowed `1 << n` to a negative/zero mask,
    // yielding no sets and the misleading "requires at least one set". It now
    // faults a program-limit error before the shift, and the whole clause's
    // cross product is capped the same way.
    let cube = SQLError.state("54001",
                              "GROUP BY CUBE supports at most 12 grouping " +
                              "elements")
    func columns(_ range: Range<Int>) -> String {
      range.map { "c\($0)" }.joined(separator: ", ")
    }
    try sales().expect("SELECT 1 FROM Sales GROUP BY CUBE(\(columns(0..<63)))",
                       fails: cube)
    try sales().expect("SELECT 1 FROM Sales GROUP BY CUBE(\(columns(0..<64)))",
                       fails: cube)
    try sales().expect("SELECT 1 FROM Sales GROUP BY CUBE(\(columns(0..<13)))",
                       fails: cube)
    // Within the cap a CUBE still expands (Region/Product = 4 sets).
    try sales().expect("""
        SELECT Region, Product, SUM(Qty) FROM Sales
          GROUP BY CUBE(Region, Product)
        """, equals: """
        SELECT Region, Product, SUM(Qty) FROM Sales
          GROUP BY GROUPING SETS ((Region, Product), (Product), (Region), ())
        """)
    // Two maximal cubes multiply past 4096 — caught by the cross-product cap.
    try sales().expect("""
        SELECT 1 FROM Sales
          GROUP BY CUBE(\(columns(0..<12))), CUBE(\(columns(12..<24)))
        """, fails: SQLError.state("54001", "GROUP BY produces too many " +
                                   "grouping sets (max 4096)"))
    // A ROLLUP of n units expands to n + 1 prefixes summing to O(n²)
    // expression references; its arity is validated before the prefixes are
    // built, so an oversized (here 4096-unit) ROLLUP faults immediately rather
    // than materialising the quadratic structure first.
    try sales().expect(
        "SELECT 1 FROM Sales GROUP BY ROLLUP(\(columns(0..<4096)))",
        fails: SQLError.state("54001", "GROUP BY ROLLUP supports at most " +
                              "4095 grouping elements"))
  }

  @Test func `a parenthesised unit keeps its arithmetic tail as one key`()
      throws {
    // `ROLLUP((A) + 1)` — the unit is the scalar key `(A) + 1`, NOT a composite
    // set `(A)` with a stray `+ 1` (which once left `+ 1` where the construct's
    // `)` was expected and faulted). The unit disambiguation rewinds a single
    // `(A)`, so parens are transparent and it parses identically to the bare
    // `A + 1` unit — at ROLLUP/CUBE units and GROUPING SETS members alike.
    try nums().expect("SELECT SUM(V) FROM N GROUP BY ROLLUP((A) + 1)",
                      equals: "SELECT SUM(V) FROM N GROUP BY ROLLUP(A + 1)")
    try nums().expect("SELECT SUM(V) FROM N GROUP BY CUBE((A) + 1)",
                      equals: "SELECT SUM(V) FROM N GROUP BY CUBE(A + 1)")
    try nums().expect("SELECT SUM(V) FROM N GROUP BY GROUPING SETS ((A) + 1)",
                      equals: "SELECT SUM(V) FROM N GROUP BY (A) + 1")
    // guard: a genuine composite unit `(A, V)` is still a set, not truncated.
    try nums().expect("""
        SELECT SUM(V) FROM N GROUP BY ROLLUP((A, V))
        """, equals: """
        SELECT SUM(V) FROM N GROUP BY GROUPING SETS ((A, V), ())
        """)
  }

  @Test func `a long ordinary clause and repeated keys parse and group`()
      throws {
    // Ordinary keys accumulate by append (linear), not O(n²) cross. The result
    // is unaffected — a repeated key groups as one, key order within the set
    // does not matter, and a repeated literal collapses to one group.
    try nums().expect("SELECT A, SUM(V) FROM N GROUP BY A, A, A",
                      equals: "SELECT A, SUM(V) FROM N GROUP BY A")
    try nums().expect("SELECT SUM(V) FROM N GROUP BY 1, 1, 1",
                      equals: "SELECT SUM(V) FROM N GROUP BY 1")
  }

  @Test func `a wide composite unit is bounded before expansion`() throws {
    // units.count is capped, but a composite unit holds arbitrarily many
    // expressions, and CUBE copies each unit across 2ⁿ⁻¹ subsets — so a compact
    // 12-unit CUBE whose first unit is a wide composite would materialise
    // hundreds of millions of references. The projected expansion (references,
    // not just unit count) is bounded before the subsets are built.
    func cols(_ range: Range<Int>) -> String {
      range.map { "c\($0)" }.joined(separator: ", ")
    }
    let refs = SQLError.state("54001",
                              "GROUP BY expands too many grouping expressions")
    // 12 units, first a 600-column composite → 2¹¹ × ~611 references ≫ 2²⁰.
    try sales().expect("""
        SELECT 1 FROM Sales
          GROUP BY CUBE((\(cols(0..<600))), \(cols(600..<611)))
        """, fails: refs)
    // The cross / append path is bounded too: a 12-column CUBE (4096 sets)
    // followed by a wide composite ordinary set multiplies past the budget.
    try sales().expect("""
        SELECT 1 FROM Sales
          GROUP BY CUBE(\(cols(0..<12))), (\(cols(12..<525)))
        """, fails: refs)
  }
}
