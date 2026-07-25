// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLStandard
import SQLTestSupport

// MARK: - Fixtures

/// A `Sales` relation of `Region`/`Product`/`Qty` rows. Per-(Region, Product):
/// East/A 10, East/B 20, West/A 7, West/B 3. Per-Region: East 30, West 10.
/// Per-Product: A 17, B 23. Grand total 40. Each level's SUM is distinct, so a
/// row's grouping set is legible from its values.
private func sales() throws -> FixtureCatalog {
  try Catalog {
    Relation("Sales", ["Region": .text, "Product": .text, "Qty": .integer]) {
      Row("East", "A", 10)
      Row("East", "B", 20)
      Row("West", "A", 7)
      Row("West", "B", 3)
    }
  }
}

/// The `SQLError` running `sql` against `catalog` raises, or `nil` — the RUN
/// path (`Catalog.run`), for the run ≡ schema fault agreement.
private func running(_ sql: String,
                     _ catalog: borrowing FixtureCatalog) -> SQLError? {
  do {
    _ = try catalog.run(parse(query: sql))
    return nil
  } catch let fault {
    return fault
  }
}

/// The `SQLError` type-checking `sql`'s schema raises, or `nil` — the SCHEMA
/// path (`columns(of:validate:true)`), for the run ≡ schema fault agreement.
private func checking(_ sql: String,
                      _ catalog: borrowing FixtureCatalog) -> SQLError? {
  do {
    _ = try catalog.columns(of: parse(query: sql), validate: true)
    return nil
  } catch let fault {
    return fault
  }
}

// MARK: - GROUPING()

struct GroupingFunctionTests {
  @Test func `a plain GROUP BY key is never rolled up, so GROUPING is 0`()
      throws {
    // A plain `GROUP BY Region` is one grouping set whose sole member is
    // `Region`, so `Region` is present in every result row and NEVER rolled up:
    // `GROUPING(Region)` is 0 for every row. Rows in first-appearance order.
    try sales().expect("""
        SELECT Region, GROUPING(Region), SUM(Qty)
          FROM Sales
         GROUP BY Region
        """, yields: [
          ["East", 0, 30],
          ["West", 0, 10],
        ])
  }

  @Test func `GROUPING SETS ((a), ()) reports 0 for the key arm, 1 for the total`()
      throws {
    // `GROUPING SETS ((Region), ())` is two arms. The `(Region)` arm groups on
    // `Region` (present → `GROUPING(Region)` = 0); the `()` grand-total arm
    // rolls `Region` up (it is in the superset but not this set → the projected
    // `Region` is a super-aggregate NULL, `GROUPING(Region)` = 1). Arm order:
    // the `(Region)` rows first, then the total.
    try sales().expect("""
        SELECT Region, GROUPING(Region), SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((Region), ())
        """, yields: [
          ["East", 0, 30],
          ["West", 0, 10],
          [nil, 1, 40],
        ])
  }

  @Test func `ROLLUP(a, b) reports per-level bits and a first-arg-MSB vector`()
      throws {
    // `ROLLUP(Region, Product)` is `[[Region, Product], [Region], []]`. Per
    // level, the scalar `GROUPING(Region)`/`GROUPING(Product)` and the two-arg
    // VECTOR `GROUPING(Region, Product)` (Region the MOST-significant bit):
    //   full arm  — both present: (0, 0), vector 0b00 = 0.
    //   (Region)  — Product rolled up: (0, 1), vector 0b01 = 1.
    //   ()        — both rolled up: (1, 1), vector 0b11 = 3.
    // So the vector takes 0, 1, 3 — never 2 (Region cannot be rolled up while
    // Product is kept in a ROLLUP prefix).
    try sales().expect("""
        SELECT Region, Product,
               GROUPING(Region), GROUPING(Product),
               GROUPING(Region, Product), SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region, Product)
        """, yields: [
          ["East", "A", 0, 0, 0, 10],
          ["East", "B", 0, 0, 0, 20],
          ["West", "A", 0, 0, 0, 7],
          ["West", "B", 0, 0, 0, 3],
          ["East", nil, 0, 1, 1, 30],
          ["West", nil, 0, 1, 1, 10],
          [nil, nil, 1, 1, 3, 40],
        ])
  }

  @Test func `CUBE(a, b) makes the two-arg vector cover all four bit patterns`()
      throws {
    // `CUBE(Region, Product)` is `[[Region, Product], [Product], [Region], []]`,
    // so the VECTOR `GROUPING(Region, Product)` (Region the MSB) takes every
    // value 0..3:
    //   full arm   — both present: 0b00 = 0.
    //   (Product)  — Region rolled up: 0b10 = 2.
    //   (Region)   — Product rolled up: 0b01 = 1.
    //   ()         — both rolled up: 0b11 = 3.
    try sales().expect("""
        SELECT Region, Product, GROUPING(Region, Product), SUM(Qty)
          FROM Sales
         GROUP BY CUBE(Region, Product)
        """, yields: [
          ["East", "A", 0, 10],
          ["East", "B", 0, 20],
          ["West", "A", 0, 7],
          ["West", "B", 0, 3],
          [nil, "A", 2, 17],
          [nil, "B", 2, 23],
          ["East", nil, 1, 30],
          ["West", nil, 1, 10],
          [nil, nil, 3, 40],
        ])
  }

  @Test func `GROUPING filters super-aggregate rows in HAVING`() throws {
    // `HAVING GROUPING(Region) = 1` keeps only the rows where `Region` is rolled
    // up — the grand total of `ROLLUP(Region)` (`[[Region], []]`), NOT the
    // per-Region rows (whose `GROUPING(Region)` is 0). HAVING lowers per arm, so
    // each arm's constant GROUPING decides its group's fate.
    try sales().expect("""
        SELECT Region, SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region)
        HAVING GROUPING(Region) = 1
        """, yields: [
          [nil, 40],
        ])
  }

  @Test func `GROUPING orders the super-aggregate rows in ORDER BY`() throws {
    // A query-level `ORDER BY GROUPING(Region) DESC` over the `ROLLUP(Region)`
    // union sorts the grand total (GROUPING 1) ahead of the per-Region rows
    // (GROUPING 0), a secondary `Region` breaking the per-Region tie. The
    // projected `GROUPING(Region)` (column 2) makes the sort key an OUTPUT the
    // carrier matches by resolved identity.
    try sales().expect("""
        SELECT Region, GROUPING(Region), SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region)
         ORDER BY GROUPING(Region) DESC, Region
        """, yields: [
          [nil, 1, 40],
          ["East", 0, 30],
          ["West", 0, 10],
        ])
  }

  @Test func `GROUPING of a non-grouping column faults on both paths`() throws {
    // `Product` is in NO grouping set of `GROUP BY Region`, so `GROUPING(Product)`
    // is invalid — the grouped lowering faults `SQLError.grouping` exactly as a
    // bare non-grouped `Product` reference would, on BOTH the run and the schema
    // type-check.
    let sql = """
        SELECT Region, GROUPING(Product)
          FROM Sales
         GROUP BY Region
        """
    #expect(running(sql, try sales()) == .grouping("Product"))
    #expect(checking(sql, try sales()) == .grouping("Product"))
  }

  @Test func `GROUPING of a literal NULL faults on both paths`() throws {
    // A literal NULL is not a `GROUP BY` expression. It lowers to a constant
    // NULL — the same value a rolled-up super-aggregate takes — so the roll-up
    // test must decide membership by the argument's superset identity, not the
    // NULL value: NULL is in no set's superset, so it faults `.state("42803")`
    // rather than counting as a rolled-up bit, on the run and the schema paths.
    let sql = "SELECT GROUPING(NULL) FROM Sales GROUP BY ROLLUP(Region)"
    let fault = SQLError.state("42803",
                               "GROUPING argument must be a GROUP BY expression")
    #expect(running(sql, try sales()) == fault)
    #expect(checking(sql, try sales()) == fault)
  }

  @Test func `GROUPING outside a grouped query faults on both paths`() throws {
    // `SELECT GROUPING(Region) FROM Sales` has no `GROUP BY` and no aggregate,
    // so it is NOT a grouped query — GROUPING has no grouping set to report
    // against and faults `.state("42803")` on BOTH the run and the schema
    // type-check.
    let sql = "SELECT GROUPING(Region) FROM Sales"
    let fault = SQLError.state("42803", "GROUPING requires a GROUP BY")
    #expect(running(sql, try sales()) == fault)
    #expect(checking(sql, try sales()) == fault)
  }

  @Test func `run agrees with columns(of:validate:) typing GROUPING as integer`()
      throws {
    // run ≡ schema: a valid GROUPING query validates and its schema types the
    // GROUPING output as an INTEGER column (an unaliased expression names
    // `column N`). Region takes its `.text` type through the set-operation
    // merge; the SUM and the GROUPING are `.integer`.
    let cat = try sales()
    let sql = """
        SELECT Region, GROUPING(Region), SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region)
        """
    try cat.expect(sql, yields: [
      ["East", 0, 30],
      ["West", 0, 10],
      [nil, 1, 40],
    ])
    let columns = try cat.columns(of: parse(query: sql), validate: true)
    #expect(columns == [
      OutputColumn(name: "Region", type: .text),
      OutputColumn(name: "column 2", type: .integer),
      OutputColumn(name: "column 3", type: .integer),
    ])
  }

  @Test func `GROUPING needs at least one argument`() throws {
    // ISO `GROUPING` takes one or more grouping expressions; a bare `GROUPING()`
    // is a syntax fault the parser raises before any grouped lowering.
    let fault = SQLError.state("42601",
                               "GROUPING requires at least one argument")
    #expect(running("SELECT GROUPING() FROM Sales GROUP BY Region",
                    try sales()) == fault)
  }

  @Test func `a delimited GROUPING is an ordinary column, not the function`()
      throws {
    // `GROUPING` is a CONTEXT identifier: a DELIMITED `"grouping"` is an
    // ordinary column name, never the function, so a relation with a `grouping`
    // column groups and projects it plainly.
    let cat = try Catalog {
      Relation("T", ["grouping": .text, "n": .integer]) {
        Row("x", 1)
        Row("y", 2)
      }
    }
    try cat.expect("""
        SELECT "grouping", SUM(n) FROM T GROUP BY "grouping"
        """, yields: [["x", 1], ["y", 2]])
  }

  @Test func `GROUPING nested in a CASE resolves to its per-arm bit`() throws {
    // The canonical labelling idiom nests GROUPING inside a `CASE` guard rather
    // than projecting it bare: `CASE WHEN GROUPING(Region) = 1 THEN 'Total'`
    // names the grand-total row. The grouped lowering must descend the compound
    // and resolve the nested GROUPING to its per-arm constant — a bare column in
    // the guard once faulted `.state` because the whole `CASE` was matched as a
    // `GROUP BY` key through the non-grouped scope. Over `ROLLUP(Region)` the
    // per-Region arms take the ELSE (their `Region`), the total arm the THEN.
    try sales().expect("""
        SELECT CASE WHEN GROUPING(Region) = 1 THEN 'Total' ELSE Region END,
               SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region)
        """, yields: [
          ["East", 30],
          ["West", 10],
          ["Total", 40],
        ])
  }

  @Test func `a constant-false WHERE keeps the empty group's arm GROUPING bits`()
      throws {
    // A constant-false `WHERE` leaves the `()` grand-total arm its single empty
    // group, whose `GROUPING(Region)` is 1 (nothing is grouped, so Region is
    // rolled up). The run evaluates that group's `CASE`, takes the `THEN`, and
    // faults on the divide; the schema's empty-group fold must yield the same
    // all-ones bit-vector so it too takes the `THEN` and surfaces the divide,
    // rather than a placeholder 0 that would fold to the `ELSE` and accept a
    // query the run rejects. Run and schema must agree on the fault.
    let sql = """
        SELECT CASE WHEN GROUPING(Region) = 1 THEN 1 / 0 ELSE 0 END
          FROM Sales
         WHERE 1 = 0
         GROUP BY GROUPING SETS ((Region), ())
        """
    #expect(running(sql, try sales()) == .divide)
    #expect(checking(sql, try sales()) == .divide)
  }

  @Test func `the empty-group GROUPING fold does not prune a safe branch`()
      throws {
    // The dual of the divide case: a `GROUPING(Region) = 0` guard is false over
    // the grand-total arm (Region is rolled up, so the bit is 1), so the run
    // takes the harmless `ELSE` and never divides. The empty-group fold, folding
    // the same all-ones GROUPING, must likewise select the `ELSE` — it must not
    // conservatively validate both branches and reject the query on the
    // unreachable `THEN`. The `()` arm yields its lone row; the `(Region)` arm
    // forms no group under the false WHERE.
    try sales().expect("""
        SELECT CASE WHEN GROUPING(Region) = 0 THEN 1 / 0 ELSE 0 END
          FROM Sales
         WHERE 1 = 0
         GROUP BY GROUPING SETS ((Region), ())
        """, yields: [
          [0],
        ])
  }

  @Test func `ORDER BY GROUPING binds past a projection sharing its value`()
      throws {
    // A query-level ORDER BY over the grouping-set union resolves its key
    // against the first arm's projected terms by identity. GROUPING lowers to a
    // dedicated term, not a bare constant, so `ORDER BY GROUPING(Region)` binds
    // to the GROUPING column even when an earlier projection (the literal 0)
    // lowers to the same first-arm constant 0 — the grand-total row (GROUPING 1)
    // must sort first. A bare-constant lowering matched the literal instead, so
    // every row sorted on 0 and the total stayed last.
    try sales().expect("""
        SELECT 0, GROUPING(Region), SUM(Qty)
          FROM Sales
         GROUP BY ROLLUP(Region)
         ORDER BY GROUPING(Region) DESC
        """, yields: [
          [0, 1, 40],
          [0, 0, 30],
          [0, 0, 10],
        ])
  }

  @Test func `ORDER BY tells two GROUPINGs apart under a leading empty set`()
      throws {
    // The identity carried is each GROUPING's arguments in the arm-stable base
    // scope, not the grouped-space lowering — which collapses a rolled-up column
    // to the shared super-aggregate NULL. Under `GROUPING SETS ((), …)` the
    // carrier resolves against the leading `()` arm, where both Region and
    // Product are rolled up; only the base-scope identity keeps `GROUPING(Region)`
    // and `GROUPING(Product)` distinct, so `ORDER BY GROUPING(Product) DESC,
    // GROUPING(Region) DESC` sorts on the intended keys: the Product-rolled-up
    // rows (Product bit 1) first, the grand total (both 1) ahead of the
    // Region-only rows within them, then the Region-rolled-up rows.
    try sales().expect("""
        SELECT GROUPING(Region), GROUPING(Product), SUM(Qty)
          FROM Sales
         GROUP BY GROUPING SETS ((), (Region), (Product))
         ORDER BY GROUPING(Product) DESC, GROUPING(Region) DESC
        """, yields: [
          [1, 1, 40],
          [0, 1, 30],
          [0, 1, 10],
          [1, 0, 17],
          [1, 0, 23],
        ])
  }

  @Test func `GROUPING rejects more arguments than the bit-vector holds`()
      throws {
    // GROUPING lowers to a signed-integer bit-vector, one bit per argument, so
    // it admits at most `Int.bitWidth - 1` (63) arguments — 63 fits, 64 would
    // overflow the payload to a negative value, so the parser rejects it with
    // ISO 54023 (too many arguments) before any lowering.
    let width = Int.bitWidth - 1
    let ok = Array(repeating: "Region", count: width).joined(separator: ", ")
    let over = Array(repeating: "Region", count: width + 1)
        .joined(separator: ", ")
    #expect(running("SELECT GROUPING(\(ok)) FROM Sales GROUP BY Region",
                    try sales()) == nil)
    let fault = SQLError.state("54023",
                               "GROUPING supports at most \(width) arguments")
    #expect(running("SELECT GROUPING(\(over)) FROM Sales GROUP BY Region",
                    try sales()) == fault)
  }

  @Test func `the grouped lowering rejects an over-wide GROUPING built by AST`()
      throws {
    // The parser guard does not cover a query built through the public
    // `Expression.grouping` AST case directly — the grouped lowering must reject
    // an over-wide vector too, on every entry point, or the bit-shifts overflow
    // the signed payload to a negative value. Build a 64-argument GROUPING with
    // no parse and confirm the run and schema paths both fault ISO 54023, while
    // the 63-argument boundary resolves (it is a plain key, GROUPING 0).
    let width = Int.bitWidth - 1
    let region = Expression.column(Column(name: "Region"))
    func grouped(_ count: Int) -> Query {
      .select(Select(projection: .expressions([
                       Projected(expression: .grouping(Array(repeating: region,
                                                             count: count)))]),
                     from: Relation(name: "Sales"),
                     grouping: .keys([region])))
    }
    let cat = try sales()
    let over = grouped(width + 1)
    let fault = SQLError.state("54023",
                               "GROUPING supports at most \(width) arguments")
    #expect(throws: fault) { _ = try cat.run(over) }
    #expect(throws: fault) { _ = try cat.columns(of: over, validate: true) }
    // The constant-false grand-total fold shares the same lowering, so it is
    // rejected ahead of the empty-group bit-vector it would otherwise overflow.
    let folded = Query.select(
        Select(projection: .expressions([
                 Projected(expression: .grouping(Array(repeating: region,
                                                       count: width + 1)))]),
               from: Relation(name: "Sales"),
               predicate: .comparison(left: .literal(.integer(1)), op: .equal,
                                      right: .literal(.integer(0))),
               grouping: .sets([[region], []])))
    #expect(throws: fault) { _ = try cat.columns(of: folded, validate: true) }
    #expect(throws: fault) { _ = try cat.run(folded) }
    #expect(throws: Never.self) { _ = try cat.run(grouped(width)) }
  }

  @Test func `GROUPING recognises a correlated key in a LATERAL body`() throws {
    // Inside a LATERAL aggregate body, the grouping key from the preceding FROM
    // (`T.Id`) lowers to a correlated `Term.parameter`, not a local key slot —
    // yet it is this arm's `GROUP BY` key. Present-key membership is matched by
    // lowered term against the arm's keys, so `GROUPING(T.Id)` reports bit 0
    // rather than faulting as a non-grouping argument.
    let cat = try Catalog {
      Relation("T", ["Id": .integer]) { Row(1); Row(2) }
      Relation("S", ["k": .integer]) { Row(1); Row(1); Row(2) }
    }
    try cat.expect("""
        SELECT d.g, d.n
          FROM T
          JOIN LATERAL (SELECT GROUPING(T.Id) AS g, COUNT(*) AS n
                          FROM S WHERE S.k = T.Id GROUP BY T.Id) AS d ON 1 = 1
        """, yields: [
          [0, 2],
          [0, 1],
        ])
  }

  @Test func `GROUPING rolls up an omitted correlated key in a LATERAL body`()
      throws {
    // Under `GROUP BY ROLLUP(T.Id)` in a LATERAL body, the `()` arm rolls the
    // correlated key up. A rolled-up correlated key lowers to `Term.parameter`,
    // not the super-aggregate NULL a local rolled-up key takes, so roll-up
    // membership is decided by the arm's superset identity rather than the
    // lowered value: `GROUPING(T.Id)` reports bit 1 for the `()` arm and 0 for
    // the `(T.Id)` arm.
    let cat = try Catalog {
      Relation("T", ["Id": .integer]) { Row(1); Row(2) }
      Relation("S", ["k": .integer]) { Row(1); Row(1); Row(2) }
    }
    try cat.expect("""
        SELECT d.g, d.n
          FROM T
          JOIN LATERAL (SELECT GROUPING(T.Id) AS g, COUNT(*) AS n
                          FROM S WHERE S.k = T.Id
                         GROUP BY ROLLUP(T.Id)) AS d ON 1 = 1
        """, yields: [
          [0, 2],
          [1, 2],
          [0, 1],
          [1, 1],
        ])
  }
}
