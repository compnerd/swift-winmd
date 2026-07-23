// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// MARK: - Fixtures

/// Two single-column relations to combine: `L` of `a` (3, 1, 2) and `R` of `b`
/// (5, 4) — a `UNION ALL` yields five rows a query-level `ORDER BY` sorts, a
/// `UNION` dedups first.
private func pair() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["a": .integer]) {
      Row(3)
      Row(1)
      Row(2)
    }
    Relation("R", ["b": .integer]) {
      Row(5)
      Row(4)
    }
  }
}

// A query-level `ORDER BY` / `OFFSET`·`FETCH` after a set operation applies to
// the WHOLE combined result — the ISO rule — carried on `Query.ordered` and
// resolved through the setop's OUTPUT scope, not bound to the trailing arm.
// These exercise the general capability the GROUPING SETS expansion also uses,
// over PLAIN unions.
struct OrderedSetOperationTests {
  @Test func `a query-level ORDER BY sorts the whole UNION ALL result`()
      throws {
    // Without the carrier the trailing `ORDER BY a` bound the RIGHT arm — which
    // projects `b` from `R` — and faulted `no such column 'a'`. It now orders
    // the union's output (named off the first arm, `a`): 1..5 ascending.
    try pair().expect("""
        SELECT a FROM L UNION ALL SELECT b FROM R ORDER BY a
        """, yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a positional ORDER BY orders the combined result descending`()
      throws {
    // `ORDER BY 1 DESC` names the first output column of the union over the
    // combined rows: 5..1 descending.
    try pair().expect("""
        SELECT a FROM L UNION ALL SELECT b FROM R ORDER BY 1 DESC
        """, yields: [[5], [4], [3], [2], [1]])
  }

  @Test func `OFFSET and FETCH page the ordered UNION ALL result`() throws {
    // The row limit rides the carrier over the union: ordered 1..5, OFFSET 1
    // skips 1 and FETCH NEXT 2 takes 2 and 3.
    try pair().expect("""
        SELECT a FROM L UNION ALL SELECT b FROM R
         ORDER BY 1 OFFSET 1 ROW FETCH NEXT 2 ROWS ONLY
        """, yields: [[2], [3]])
  }

  @Test func `a bare UNION dedups before the query-level ORDER BY`() throws {
    // A bare `UNION` (no ALL) removes whole-row duplicates BEFORE the carrier's
    // ORDER BY sorts — `L UNION L` is the distinct rows of `L`, ordered 1, 2, 3.
    try pair().expect("""
        SELECT a FROM L UNION SELECT a FROM L ORDER BY a
        """, yields: [[1], [2], [3]])
  }

  @Test func `an ORDER BY over a UNION types across the arms`() throws {
    // The result column TYPES unify across the arms (ISO), so the sort runs over
    // the coerced values — a mixed integer arm and a double arm widen to double
    // and order numerically.
    let cat = try Catalog {
      Relation("I", ["n": .integer]) {
        Row(1)
        Row(3)
      }
      Relation("D", ["d": .double]) {
        Row(2.5)
      }
    }
    try cat.expect("""
        SELECT n FROM I UNION ALL SELECT d FROM D ORDER BY 1
        """, yields: [[1.0], [2.5], [3.0]])
  }

  @Test func `an ORDER BY over an INTERSECT orders the common rows`() throws {
    // The carrier rides any set operation, not only UNION: `L INTERSECT` a
    // relation sharing 1 and 2 keeps the common rows, then orders them.
    let cat = try Catalog {
      Relation("L", ["a": .integer]) {
        Row(3)
        Row(1)
        Row(2)
      }
      Relation("M", ["a": .integer]) {
        Row(2)
        Row(1)
        Row(9)
      }
    }
    try cat.expect("""
        SELECT a FROM L INTERSECT SELECT a FROM M ORDER BY a
        """, yields: [[1], [2]])
  }

  @Test func `a trailing ORDER BY lifts onto a pure INTERSECT chain`() throws {
    // A top-level chain of ONLY `INTERSECT` is built inside `intersection()`
    // and never runs the `UNION`/`EXCEPT` loop, so the trailing lift must gate
    // on the query being a set operation, NOT on that loop. With DISTINCT names
    // (`x` on the left, `y` on the right) the defect is unmasked: before, the
    // ORDER BY stayed on the RIGHT arm and resolved `x` against `R` — faulting
    // `no such column 'x'`. It now lifts onto the carrier and orders the
    // combined intersect output by the FIRST-arm name `x`.
    let cat = try Catalog {
      Relation("L", ["a": .integer]) {
        Row(3)
        Row(1)
        Row(2)
      }
      Relation("R", ["b": .integer]) {
        Row(2)
        Row(1)
        Row(9)
      }
    }
    try cat.expect("""
        SELECT a AS x FROM L INTERSECT SELECT b AS y FROM R ORDER BY x
        """, yields: [[1], [2]])
    // The parenthesised-then-ordered ORACLE: order the intersect result the
    // same way (by the first-arm name over the combined output).
    try cat.expect("""
        SELECT a AS x FROM L INTERSECT SELECT b AS y FROM R ORDER BY x
        """, equals: """
        SELECT * FROM (
          SELECT a AS x FROM L INTERSECT SELECT b AS y FROM R
        ) AS g ORDER BY x
        """)
  }

  @Test func `a trailing ORDER BY lifts onto a pure EXCEPT chain`() throws {
    // A top-level chain of only `EXCEPT` runs the outer loop, so its trailing
    // ORDER BY already lifted — the parity guard for the outer set-op path.
    // `L EXCEPT R` keeps the left rows absent from the right (3), then orders.
    let cat = try Catalog {
      Relation("L", ["a": .integer]) {
        Row(3)
        Row(1)
        Row(2)
      }
      Relation("R", ["b": .integer]) {
        Row(2)
        Row(1)
      }
    }
    try cat.expect("""
        SELECT a AS x FROM L EXCEPT SELECT b AS y FROM R ORDER BY x
        """, yields: [[3]])
  }

  @Test func `OFFSET and FETCH page a pure INTERSECT chain`() throws {
    // The lift carries the row limit too: `L INTERSECT M` shares 1, 2, 3;
    // ordered ascending, OFFSET 1 skips 1 and FETCH NEXT 1 takes 2.
    let cat = try Catalog {
      Relation("L", ["a": .integer]) {
        Row(3)
        Row(1)
        Row(2)
      }
      Relation("M", ["b": .integer]) {
        Row(2)
        Row(1)
        Row(3)
      }
    }
    try cat.expect("""
        SELECT a AS x FROM L INTERSECT SELECT b AS y FROM M
         ORDER BY x OFFSET 1 ROW FETCH NEXT 1 ROWS ONLY
        """, yields: [[2]])
  }

  @Test func `a trailing ORDER BY lifts onto a mixed UNION INTERSECT chain`()
      throws {
    // `INTERSECT` binds tighter than `UNION`, so `L UNION M INTERSECT N` parses
    // as `L UNION (M INTERSECT N)`: `M INTERSECT N` shares 4 and 5, unioned
    // with L's 1, 2, 3 gives 1..5. The trailing ORDER BY lifts onto the chain,
    // ordering the combined output by the first-arm name `x`, descending.
    let cat = try Catalog {
      Relation("L", ["a": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
      Relation("M", ["b": .integer]) {
        Row(4)
        Row(5)
        Row(6)
      }
      Relation("N", ["c": .integer]) {
        Row(4)
        Row(5)
        Row(7)
      }
    }
    try cat.expect("""
        SELECT a AS x FROM L
         UNION SELECT b AS y FROM M
         INTERSECT SELECT c AS z FROM N
         ORDER BY x DESC
        """, yields: [[5], [4], [3], [2], [1]])
  }

  @Test func `a query-level ORDER BY over a TABLE-arm set operation sorts`()
      throws {
    // A `TABLE t` first arm projects `.all` — the arm-0 AST projection is
    // EMPTY — so deriving the carrier's output NAMES from those AST items
    // (rather than the RESOLVED columns) TRAPPED on an out-of-range index. And
    // a `TABLE`/`VALUES` LAST arm carries no primary-level order, so a trailing
    // query-level ORDER BY was left UNCONSUMED (`unexpected trailing input`).
    // Both are fixed: the output names come from the resolved columns, and the
    // tail is parsed at the query level. Ordered over the combined output:
    // 1..5.
    try pair().expect("""
        TABLE L UNION ALL TABLE R ORDER BY 1
        """, yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a SELECT star first arm set operation orders by a resolved name`()
      throws {
    // The `SELECT *` first arm resolves its output columns (`a`) from the base
    // relation; the carrier orders by the RESOLVED name `a` over the combined
    // union output — the same name a plain derived union would bind.
    try pair().expect("""
        SELECT * FROM L UNION ALL SELECT b FROM R ORDER BY a
        """, yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `a query-level ORDER BY over a VALUES-arm set operation sorts`()
      throws {
    // A `VALUES` last arm carries no primary-level order either, so the
    // trailing query-level ORDER BY parses at the query level. `L`'s 1, 2, 3
    // unioned with the constants 4, 5, ordered ascending.
    try pair().expect("""
        SELECT a FROM L UNION ALL VALUES (4), (5) ORDER BY 1
        """, yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `an out-of-range ordinal over a plain UNION faults`() throws {
    // A plain ordered set-operation carries no hidden materialised columns
    // (`generated == 0`), so an ORDINAL past the single output faults `.column`
    // over the union's real arity — the non-GROUPING-SETS path is unchanged by
    // the GROUPING SETS ordinal bound fix (the ordinal is bounded by the REAL
    // output width, which here IS the full width).
    try pair().expect("""
        SELECT a FROM L UNION ALL SELECT b FROM R ORDER BY 2
        """, fails: .column("2"))
  }

  @Test func `a set operation of derived-table arms orders the whole result`()
      throws {
    // Each arm names its OWN derived alias (`d` on the left, `e` on the right).
    // Arms are SELECT-scoped, so the query-level augment the carrier runs under
    // never binds them — before, the carrier compiled ONE `setop` plan run
    // under the single carrier context, so an arm's `.scan d` faulted
    // `.relation`. The carrier now runs the union PER ARM (the same machinery
    // the direct `setop` and a correlated-subquery setop use), materialising
    // each arm's derived table in its own scope: 1 then 2.
    try pair().expect("""
        SELECT v FROM (SELECT 1 AS v) AS d
         UNION ALL SELECT v FROM (SELECT 2 AS v) AS e ORDER BY 1
        """, yields: [[1], [2]])
  }

  @Test func `an INTERSECT of derived-table arms orders the common rows`()
      throws {
    // The per-arm materialisation rides any set operation: an `INTERSECT` of
    // two derived arms sharing the row 1 keeps it.
    try pair().expect("""
        SELECT v FROM (SELECT 1 AS v) AS d
         INTERSECT SELECT v FROM (SELECT 1 AS v) AS e ORDER BY 1
        """, yields: [[1]])
  }

  @Test func `an EXCEPT of derived-table arms orders the left-only rows`()
      throws {
    // `EXCEPT` of derived arms keeps the left row absent from the right.
    try pair().expect("""
        SELECT v FROM (SELECT 1 AS v) AS d
         EXCEPT SELECT v FROM (SELECT 2 AS v) AS e ORDER BY 1
        """, yields: [[1]])
  }

  @Test func `a negative OFFSET over a UNION faults`() throws {
    // A direct `Limit` with a negative offset (the parser yields none, but a
    // built AST can) faults — the carrier rejects it as the `Select` path does.
    let cat = try pair()
    let query = Query.ordered(
        .setop(.union,
               .select(Select(projection: .columns([Column(name: "a")]),
                              from: Relation(name: "L"))),
               .select(Select(projection: .columns([Column(name: "b")]),
                              from: Relation(name: "R"))),
               all: true),
        distinct: false, order: nil, limit: Limit(count: 1, offset: -1),
        generated: 0)
    #expect(throws: SQLError.state("2201X",
                                   "OFFSET row count must be non-negative")) {
      _ = try cat.run(query)
    }
  }

  @Test func `an out-of-range generated count over a union faults`() throws {
    // `Query.ordered` is a PUBLIC AST case; a caller may build a `generated`
    // count out of step with the inner union's width (the parser and `expand`
    // never do). A count PAST the width, or NEGATIVE, makes `real = width −
    // generated` negative — the carrier's `0 ..< real` range and per-column
    // subscripts would TRAP the process. The carrier now rejects a malformed
    // count with a typed internal-error fault rather than trapping. Build the
    // malformed AST directly: a ONE-column union with `generated: 2`, then a
    // negative `generated`.
    let cat = try pair()
    let union = Query.setop(
        .union,
        .select(Select(projection: .columns([Column(name: "a")]),
                       from: Relation(name: "L"))),
        .select(Select(projection: .columns([Column(name: "b")]),
                       from: Relation(name: "R"))),
        all: true)
    let over = Query.ordered(union, distinct: false, order: nil, limit: nil,
                             generated: 2)
    let fault = SQLError.state("XX000",
                               "ordered set-operation generated count out " +
                               "of range")
    #expect(throws: fault) { _ = try cat.run(over) }
    let under = Query.ordered(union, distinct: false, order: nil, limit: nil,
                              generated: -1)
    #expect(throws: fault) { _ = try cat.run(under) }
    // An IN-RANGE `generated` (0 — no hidden columns) still compiles and runs
    // the union unchanged: 1..5 over the two arms.
    let valid = Query.ordered(union, distinct: false,
                              order: Order(keys: [
                                Order.Key(sort: .ordinal(1), ascending: true),
                              ]), limit: nil, generated: 0)
    #expect(try cat.run(valid) == [[1], [2], [3], [4], [5]].map { $0.map {
      Value.integer($0)
    } })
  }
}
