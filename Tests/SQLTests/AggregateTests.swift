// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQL
import SQLTestSupport

// MARK: - Fixtures

/// A `Sales` relation of `Dept`/`Region`/`Amount` rows — three departments, two
/// regions, and a NULL `Amount` (a row `COUNT(*)` counts but `COUNT(Amount)`,
/// `SUM`, `MIN`, `MAX`, `AVG` skip). One department (`Toys`) has ONLY a NULL
/// amount, exercising the all-NULL group (`SUM`/`AVG` NULL, `COUNT(Amount)` 0).
private func sales() throws -> FixtureCatalog {
  try Catalog {
    Relation("Sales",
             ["Dept": .text, "Region": .text, "Amount": .integer]) {
      Row("Books", "East", 10)
      Row("Books", "East", 20)
      Row("Books", "West", 30)
      Row("Games", "East", 40)
      Row("Games", "West", nil)
      Row("Games", "West", 50)
      Row("Toys", "East", nil)
    }
  }
}

// MARK: - Tests

struct AggregateTests {
  @Test func `COUNT(*) over the whole result counts every row`() throws {
    try sales().expect("SELECT COUNT(*) FROM Sales", yields: [[7]])
  }

  @Test func `COUNT(*) over an empty result is zero, not no row`() throws {
    // The degenerate whole-result aggregation yields one group even over no
    // matching rows — COUNT is 0 rather than an empty result.
    try sales().expect("SELECT COUNT(*) FROM Sales WHERE Dept = 'None'",
                       yields: [[0]])
  }

  @Test func `COUNT(expr) ignores NULLs where COUNT(*) does not`() throws {
    // Five of the seven rows have a non-NULL Amount (two are NULL); COUNT(*)
    // counts all seven, COUNT(Amount) only the non-NULL five.
    try sales().expect("SELECT COUNT(Amount), COUNT(*) FROM Sales",
                       yields: [[5, 7]])
  }

  @Test func `SUM, MIN, MAX, and AVG skip NULLs over the whole result`() throws {
    // Amounts 10,20,30,40,50 (the NULLs skipped): SUM 150, MIN 10, MAX 50,
    // AVG 150/5 = 30.0 — real division to an approximate-numeric double.
    try sales().expect("""
        SELECT SUM(Amount), MIN(Amount), MAX(Amount), AVG(Amount) FROM Sales
        """, yields: [[150, 10, 50, 30.0]])
  }

  @Test func `AVG is real division yielding an approximate-numeric double`() throws {
    // Books amounts 10,20,30 sum 60 over 3 → 20.0; Games 40,50 sum 90 over 2
    // → 45.0 — real division, not truncating; Toys all-NULL → NULL.
    try sales().expect("""
        SELECT Dept, AVG(Amount) FROM Sales GROUP BY Dept ORDER BY Dept
        """, yields: [["Books", 20.0], ["Games", 45.0], ["Toys", nil]])
  }

  @Test func `AVG yields a fractional double where integer division truncates`() throws {
    // East Books are 10 and 20: (10 + 20) / 2 = 15.0.
    try sales().expect("""
        SELECT AVG(Amount) FROM Sales WHERE Dept = 'Books' AND Region = 'East'
        """, yields: [[15.0]])
  }

  @Test func `an all-NULL group yields NULL for SUM/MIN/MAX/AVG and 0 for COUNT`() throws {
    // Toys has one row whose Amount is NULL: COUNT(*) counts the row (1),
    // COUNT(Amount) skips it (0), and the value aggregates are NULL.
    try sales().expect("""
        SELECT COUNT(*), COUNT(Amount), SUM(Amount), MIN(Amount),
               MAX(Amount), AVG(Amount)
          FROM Sales WHERE Dept = 'Toys'
        """, yields: [[1, 0, nil, nil, nil, nil]])
  }

  @Test func `GROUP BY one column aggregates each group`() throws {
    try sales().expect("""
        SELECT Dept, COUNT(*), SUM(Amount) FROM Sales
          GROUP BY Dept ORDER BY Dept
        """, yields: [["Books", 3, 60], ["Games", 3, 90], ["Toys", 1, nil]])
  }

  @Test func `GROUP BY multiple columns keys on the tuple`() throws {
    // (Books,East) 10+20, (Books,West) 30, (Games,East) 40, (Games,West)
    // NULL+50, (Toys,East) NULL. Ordered by Dept, ties by first appearance.
    try sales().expect("""
        SELECT Dept, Region, COUNT(*), SUM(Amount) FROM Sales
          GROUP BY Dept, Region ORDER BY Dept
        """, yields: [["Books", "East", 2, 30], ["Books", "West", 1, 30],
                      ["Games", "East", 1, 40], ["Games", "West", 2, 50],
                      ["Toys", "East", 1, nil]])
  }

  @Test func `a compound ORDER BY sorts grouped output by each key in turn`() throws {
    // Order groups by Dept ascending, breaking ties by Region descending — the
    // second key reverses only the rows the first leaves equal.
    try sales().expect("""
        SELECT Dept, Region, COUNT(*), SUM(Amount) FROM Sales
          GROUP BY Dept, Region ORDER BY Dept, Region DESC
        """, yields: [["Books", "West", 1, 30], ["Books", "East", 2, 30],
                      ["Games", "West", 2, 50], ["Games", "East", 1, 40],
                      ["Toys", "East", 1, nil]])
  }

  @Test func `mixed integer/double group keys canonicalize into one group`() throws {
    // A column carrying both 1 and 1.0 — as a CTE/UNION ALL or any source can —
    // groups them together under the engine's EXACT numeric equality (the same
    // `1` = `1.0` UNION dedup uses), yielding one group of two keyed by the
    // first-appearance integer, not two one-row groups.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row(1.0)
      }
    }
    try catalog.expect("SELECT x, COUNT(*) FROM T GROUP BY x",
                       yields: [[1, 2]])
  }

  @Test func `mixed SUM/AVG widening does not depend on row order`() throws {
    // Int.max, 1, 0.5 overflows Int if summed as integers first, but the 0.5
    // widens the total to a double — so the result must be the same
    // whether the overflowing integer prefix or the double is seen first, not a
    // SQLError.magnitude one way and a double the other.
    let prefix = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Int.max)
        Row(1)
        Row(0.5)
      }
    }
    let suffix = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(0.5)
        Row(Int.max)
        Row(1)
      }
    }
    let expected = Double(Int.max) + 1.0 + 0.5
    let query = "SELECT SUM(x), AVG(x) FROM T"
    try prefix.expect(query, yields: [[expected, expected / 3]])
    try suffix.expect(query, yields: [[expected, expected / 3]])
  }

  @Test func `all-integer SUM tolerates transient overflow if the total fits`() throws {
    // A prefix that overflows Int (Int.max + 1) must not latch a fault when a
    // later value (-1) brings the exact total back into range — the result is
    // the mathematical total, Int.max, whichever order the rows arrive in.
    let up = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Int.max)
        Row(1)
        Row(-1)
      }
    }
    let down = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Int.max)
        Row(-1)
        Row(1)
      }
    }
    try up.expect("SELECT SUM(x) FROM T", yields: [[Int.max]])
    try down.expect("SELECT SUM(x) FROM T", yields: [[Int.max]])
    // A total that genuinely exceeds Int still faults, in any order.
    let over = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Int.max)
        Row(Int.max)
      }
    }
    over.expect("SELECT SUM(x) FROM T",
                fails: .magnitude("integer overflow"))
  }

  @Test func `AVG divides a wide integer total that SUM could not represent`() throws {
    // Two Int.max rows sum to 2 * Int.max, outside Int — SUM would fault, but
    // AVG divides the wide total and returns the finite approximate mean.
    let catalog = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Int.max)
        Row(Int.max)
      }
    }
    try catalog.expect("SELECT AVG(x) FROM T", yields: [[Double(Int.max)]])
  }

  @Test func `MIN/MAX over incomparable kinds is a type error, either order`() throws {
    // A column mixing TEXT and INTEGER (from a CTE/UNION ALL) has no ordering
    // across kinds — MIN/MAX rejects it rather than keeping the first-seen
    // value (which would flip MIN and MAX with row order).
    let fault = SQLError.operand("MIN and MAX require a common comparable kind")
    let textFirst = try Catalog {
      Relation("T", ["x": .text]) {
        Row("a")
        Row(1)
      }
    }
    let intFirst = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(1)
        Row("a")
      }
    }
    textFirst.expect("SELECT MIN(x) FROM T", fails: fault)
    textFirst.expect("SELECT MAX(x) FROM T", fails: fault)
    intFirst.expect("SELECT MIN(x) FROM T", fails: fault)
    intFirst.expect("SELECT MAX(x) FROM T", fails: fault)
  }

  @Test func `MIN/MAX over Int.max and Double(Int.max) is deterministic`() throws {
    // Int.max (2^63 - 1) and Double(Int.max) (2^63) are both numeric and order
    // exactly, so MIN is the integer and MAX the larger double — same result
    // whichever row arrives first, not an order-dependent first-seen keep.
    let intFirst = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Int.max)
        Row(Double(Int.max))
      }
    }
    let doubleFirst = try Catalog {
      Relation("T", ["x": .integer]) {
        Row(Double(Int.max))
        Row(Int.max)
      }
    }
    try intFirst.expect("SELECT MIN(x), MAX(x) FROM T",
                        yields: [[Int.max, Double(Int.max)]])
    try doubleFirst.expect("SELECT MIN(x), MAX(x) FROM T",
                           yields: [[Int.max, Double(Int.max)]])
  }

  @Test func `ORDER BY on a duplicated projection output name is ambiguous`() throws {
    // Two projected columns share the output name `k`, so `ORDER BY k` has no
    // single slot to order on — rejected as ambiguous (as the non-grouped path
    // reports for a shared unqualified join column) rather than silently
    // ordering by whichever projection came last.
    try sales().expect("""
        SELECT Dept AS k, Region AS k FROM Sales
          GROUP BY Dept, Region ORDER BY k
        """, fails: .ambiguous("k"))
  }

  @Test func `MIN and MAX use the engine's typed comparison per group`() throws {
    try sales().expect("""
        SELECT Dept, MIN(Amount), MAX(Amount) FROM Sales
          GROUP BY Dept ORDER BY Dept
        """, yields: [["Books", 10, 30], ["Games", 40, 50],
                      ["Toys", nil, nil]])
  }

  @Test func `HAVING filters groups after aggregation`() throws {
    // Keep only departments whose row count exceeds one — Toys (1 row) drops.
    try sales().expect("""
        SELECT Dept, COUNT(*) FROM Sales
          GROUP BY Dept HAVING COUNT(*) > 1 ORDER BY Dept
        """, yields: [["Books", 3], ["Games", 3]])
  }

  @Test func `HAVING may reference an aggregate not in the projection`() throws {
    // The HAVING aggregates SUM(Amount) though the projection does not — the
    // engine still computes it for the group filter.
    // Books SUM 60 drops, Games SUM 90 keeps, Toys SUM NULL drops (UNKNOWN).
    try sales().expect("""
        SELECT Dept FROM Sales
          GROUP BY Dept HAVING SUM(Amount) > 70 ORDER BY Dept
        """, yields: [["Games"]])
  }

  @Test func `HAVING without a GROUP BY filters the single whole-result group`() throws {
    // The whole result is one group; HAVING keeps or drops it. COUNT(*) is 7.
    let catalog = try sales()
    try catalog.expect("SELECT COUNT(*) FROM Sales HAVING COUNT(*) > 5",
                       yields: [[7]])
    try catalog.empty("SELECT COUNT(*) FROM Sales HAVING COUNT(*) > 100")
  }

  @Test func `ORDER BY may name an aggregate's projection alias`() throws {
    // Order the departments by their total descending — the ORDER BY names the
    // aggregate's output alias `Total`.
    // Games 90, Books 60, Toys NULL (NULL sorts last descending).
    try sales().expect("""
        SELECT Dept, SUM(Amount) AS Total FROM Sales
          GROUP BY Dept ORDER BY Total DESC
        """, yields: [["Games", 90], ["Books", 60], ["Toys", nil]])
  }

  @Test func `ORDER BY on a computed-expression alias is rejected clearly`() throws {
    // `Doubled` aliases a COMPUTED value (the projection evaluates it after
    // the sort), so it has no standalone grouped slot to order on — the engine
    // rejects it as unsupported rather than misreporting an unknown column.
    #expect(throws: SQLError.self) {
      try sales().run(Statement(parsing: """
          SELECT Dept, COUNT(*) * 2 AS Doubled FROM Sales
            GROUP BY Dept ORDER BY Doubled DESC
          """))
    }
  }

  @Test func `an aggregate query pages with OFFSET/FETCH after ORDER BY`() throws {
    // Three groups ordered by Dept; skip one, take one.
    try sales().expect("""
        SELECT Dept, COUNT(*) FROM Sales
          GROUP BY Dept ORDER BY Dept OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY
        """, yields: [["Games", 3]])
  }

  @Test func `an aggregate mixes with a scalar arithmetic over the group key`() throws {
    // A grouped query may project the key through arithmetic and a scalar
    // expression alongside the aggregate; COUNT(*) doubled proves it composes.
    try sales().expect("""
        SELECT Dept, COUNT(*) * 2 FROM Sales
          GROUP BY Dept ORDER BY Dept
        """, yields: [["Books", 6], ["Games", 6], ["Toys", 2]])
  }

  @Test func `a non-grouped projection column is rejected`() throws {
    // `Region` is neither aggregated nor a GROUP BY key, so the query is
    // ill-formed — the standard single-group rule.
    try sales().expect(
        "SELECT Dept, Region, COUNT(*) FROM Sales GROUP BY Dept",
        fails: .grouping("Region"))
  }

  @Test func `a bare column with no GROUP BY and an aggregate is rejected`() throws {
    // Mixing a bare column with an aggregate and no GROUP BY groups the whole
    // result — the column is then not a key, so it faults.
    try sales().expect("SELECT Dept, COUNT(*) FROM Sales",
                       fails: .grouping("Dept"))
  }

  @Test func `the projection-rule fault carries the SS004 SQLSTATE`() throws {
    #expect(SQLError.grouping("Region").sqlstate == "SS004")
  }

  @Test func `SUM over a text column is a type error`() throws {
    // SUM/AVG require numeric operands; folding a text value faults through the
    // engine's arithmetic rather than coercing.
    try sales().expect("SELECT SUM(Dept) FROM Sales",
                       fails: .operand("operands must be numeric"))
  }

  @Test func `AVG over a text column is a type error`() throws {
    // AVG folds the same numeric total as SUM, so a text operand faults alike.
    try sales().expect("SELECT AVG(Dept) FROM Sales",
                       fails: .operand("operands must be numeric"))
  }

  @Test func `only COUNT admits a '*' operand`() throws {
    // `SUM(*)`/`AVG(*)`/`MIN(*)`/`MAX(*)` are not valid — only `COUNT(*)`
    // counts rows without reading a value.
    let catalog = try sales()
    for function in ["SUM", "AVG", "MIN", "MAX"] {
      #expect(throws: SQLError.self) {
        try catalog.run(Statement(parsing: "SELECT \(function)(*) FROM Sales"))
      }
    }
    // `COUNT(*)` remains valid — it counts every row.
    try catalog.expect("SELECT COUNT(*) FROM Sales", yields: [[7]])
  }

  @Test func `an aggregate in a WHERE clause is rejected`() throws {
    // An aggregate has no per-row meaning, so it may not appear in a WHERE.
    #expect(throws: SQLError.self) {
      try sales().run(Statement(parsing:
          "SELECT Dept FROM Sales WHERE COUNT(*) > 1 GROUP BY Dept"))
    }
  }

  @Test func `an aggregate groups a join by a qualified key column`() throws {
    // Aggregation sits above the join chain, so a grouped query over a join
    // folds each aggregate over the joined rows and keys on a qualified column.
    let catalog = try Catalog {
      Relation("Dept", ["Id": .integer, "Name": .text]) {
        Row(1, "Books")
        Row(2, "Games")
      }
      Relation("Item", ["DeptId": .integer, "Price": .integer]) {
        Row(1, 10)
        Row(1, 20)
        Row(2, 40)
      }
    }
    try catalog.expect("""
        SELECT Dept.Name, SUM(Item.Price) FROM Dept
          JOIN Item ON Item.DeptId = Dept.Id
          GROUP BY Dept.Name ORDER BY Dept.Name
        """, yields: [["Books", 30], ["Games", 40]])
  }

  @Test func `SUM over an all-integer column stays an exact integer`() throws {
    // Every folded value is an integer, so the total stays an integer — the
    // engine's arithmetic keeps `integer + integer` integral.
    try sales().expect("SELECT SUM(Amount) FROM Sales", yields: [[150]])
  }

  @Test func `SUM over a double column yields a double`() throws {
    let catalog = try Catalog {
      Relation("T", ["X": .double]) {
        Row(1.5)
        Row(2.25)
        Row(0.25)
      }
    }
    // 1.5 + 2.25 + 0.25 = 4.0 — the running total widens to a double.
    try catalog.expect("SELECT SUM(X) FROM T", yields: [[4.0]])
  }

  @Test func `SUM over mixed integer and double columns widens to a double`() throws {
    let catalog = try Catalog {
      Relation("T", ["X": .integer]) {
        Row(10)
        Row(2.5)
        Row(20)
      }
    }
    // 10 + 2.5 + 20 = 32.5 — a lone double operand widens the whole total.
    try catalog.expect("SELECT SUM(X) FROM T", yields: [[32.5]])
  }

  @Test func `AVG over a double column is a double`() throws {
    let catalog = try Catalog {
      Relation("T", ["X": .double]) {
        Row(1.0)
        Row(2.0)
      }
    }
    // (1.0 + 2.0) / 2 = 1.5 — real division over a double total.
    try catalog.expect("SELECT AVG(X) FROM T", yields: [[1.5]])
  }

  @Test func `an aggregate argument resolves a bound parameter`() throws {
    // A `:parameter` reached from inside an aggregate's argument binds to its
    // query value the same way the projection and the WHERE do — the CASE guard
    // sees `:k` as 10, so exactly the one Amount = 10 row folds a 1 into the
    // COUNT rather than reading `:k` as UNBOUND and counting 0.
    try sales().expect("""
        SELECT COUNT(CASE WHEN Amount = :k THEN 1 END) FROM Sales
        """, yields: [[1]], bindings: ["k": .integer(10)])
  }

  @Test func `a SUM argument resolves a bound parameter`() throws {
    // The bound parameter reaches a SUM's argument, not just a COUNT's —
    // proving the fix is the general per-record argument evaluation, one
    // aggregate fold path for every function. With :k = 20 the CASE keeps each
    // Amount that equals 20 and folds 0 otherwise, so SUM is the single 20 —
    // read as UNBOUND the guard never matches and SUM is 0.
    try sales().expect("""
        SELECT SUM(CASE WHEN Amount = :k THEN Amount ELSE 0 END) FROM Sales
        """, yields: [[20]], bindings: ["k": .integer(20)])
  }
}
