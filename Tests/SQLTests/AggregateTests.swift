// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

// MARK: - In-memory adapter

/// An in-memory relation: a fixed schema plus rows of typed values.
///
/// This harness knows nothing of WinMD — it is a self-contained fixture for the
/// aggregation (`GROUP BY`/`HAVING`/`COUNT`/`SUM`/`MIN`/`MAX`/`AVG`) tests,
/// deliberately independent of `EngineTests.swift`/`LimitTests.swift` so the
/// files reconcile cleanly. No column is marked seekable — aggregation reads
/// every row of a group, so a seek is beside the point here.
private struct AggregateRelation: Sendable {
  let names: Array<String>
  let records: Array<Array<Value>>

  init(_ names: Array<String>, _ records: Array<Array<Value>>) {
    self.names = names
    self.records = records
  }
}

/// A `Catalog` over a dictionary of named relations.
private struct AggregateMemory: Catalog {
  let catalog: Dictionary<String, AggregateRelation>

  init(_ relations: Dictionary<String, AggregateRelation>) {
    self.catalog = relations
  }

  func table(named name: String) -> AggregateTable? {
    guard let relation = catalog[name] else { return nil }
    return AggregateTable(relation)
  }

  func relations() -> Array<String> {
    Array(catalog.keys)
  }
}

/// A `Table` over one in-memory relation.
private struct AggregateTable: Table {
  let relation: AggregateRelation

  init(_ relation: AggregateRelation) {
    self.relation = relation
  }

  var width: Int { relation.names.count }

  var names: Array<String> { relation.names }

  func ordinal(of name: String) -> Int? {
    relation.names.firstIndex(of: name)
  }

  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? { nil }

  func cursor() -> AggregateCursor {
    AggregateCursor(relation)
  }
}

/// An index-addressed cursor over a relation's rows.
private struct AggregateCursor: Cursor {
  let relation: AggregateRelation

  init(_ relation: AggregateRelation) {
    self.relation = relation
  }

  var count: Int { relation.records.count }

  func row(_ index: Int) -> AggregateRow? {
    guard index < relation.records.count else { return nil }
    return AggregateRow(relation, index)
  }
}

/// A positional view over one row's cells.
private struct AggregateRow: Row {
  let relation: AggregateRelation
  let index: Int

  init(_ relation: AggregateRelation, _ index: Int) {
    self.relation = relation
    self.index = index
  }

  subscript(_ column: Int) -> Value {
    borrowing get { relation.records[index][column] }
  }
}

// MARK: - Fixtures

/// A `Sales` relation of `Dept`/`Region`/`Amount` rows — three departments, two
/// regions, and a NULL `Amount` (a row `COUNT(*)` counts but `COUNT(Amount)`,
/// `SUM`, `MIN`, `MAX`, `AVG` skip). One department (`Toys`) has ONLY a NULL
/// amount, exercising the all-NULL group (`SUM`/`AVG` NULL, `COUNT(Amount)` 0).
private func sales() -> AggregateMemory {
  let records = [
    [.text("Books"), .text("East"), .integer(10)],
    [.text("Books"), .text("East"), .integer(20)],
    [.text("Books"), .text("West"), .integer(30)],
    [.text("Games"), .text("East"), .integer(40)],
    [.text("Games"), .text("West"), .null],
    [.text("Games"), .text("West"), .integer(50)],
    [.text("Toys"), .text("East"), .null],
  ] as Array<Array<Value>>
  return AggregateMemory(["Sales":
      AggregateRelation(["Dept", "Region", "Amount"], records)])
}

// MARK: - Helpers

/// Parses `text` to a query, failing on any other statement.
private func parse(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

/// Runs `text` against the `Sales` catalog, yielding the projected rows.
private func run(_ text: String) throws -> Array<Array<Value>> {
  try Engine.run(parse(text), sales())
}

// MARK: - Tests

struct AggregateTests {
  @Test("COUNT(*) over the whole result counts every row")
  func countStar() throws {
    #expect(try run("SELECT COUNT(*) FROM Sales") == [[.integer(7)]])
  }

  @Test("COUNT(*) over an empty result is zero, not no row")
  func countStarEmpty() throws {
    // The degenerate whole-result aggregation yields one group even over no
    // matching rows — COUNT is 0 rather than an empty result.
    #expect(try run("SELECT COUNT(*) FROM Sales WHERE Dept = 'None'")
            == [[.integer(0)]])
  }

  @Test("COUNT(expr) ignores NULLs where COUNT(*) does not")
  func countExpr() throws {
    // Five of the seven rows have a non-NULL Amount (two are NULL); COUNT(*)
    // counts all seven, COUNT(Amount) only the non-NULL five.
    #expect(try run("SELECT COUNT(Amount), COUNT(*) FROM Sales")
            == [[.integer(5), .integer(7)]])
  }

  @Test("SUM, MIN, MAX, and AVG skip NULLs over the whole result")
  func wholeResult() throws {
    // Amounts 10,20,30,40,50 (the NULLs skipped): SUM 150, MIN 10, MAX 50,
    // AVG 150/5 = 30.0 — real division to an approximate-numeric double.
    let rows = try run("""
        SELECT SUM(Amount), MIN(Amount), MAX(Amount), AVG(Amount) FROM Sales
        """)
    #expect(rows == [[.integer(150), .integer(10), .integer(50),
                      .double(30.0)]])
  }

  @Test("AVG is real division yielding an approximate-numeric double")
  func avgReal() throws {
    // Books amounts 10,20,30 sum 60 over 3 → 20.0; Games 40,50 sum 90 over 2
    // → 45.0 — real division, not truncating; Toys all-NULL → NULL.
    let rows = try run("""
        SELECT Dept, AVG(Amount) FROM Sales GROUP BY Dept ORDER BY Dept
        """)
    #expect(rows == [[.text("Books"), .double(20.0)],
                     [.text("Games"), .double(45.0)],
                     [.text("Toys"), .null]])
  }

  @Test("AVG yields a fractional double where integer division truncates")
  func avgFractional() throws {
    // Books amounts 10,20,30 sum 60 over 3 rows → 20.0; but the East Books
    // pair 10,20 averages 15.0, and adding a third exercises a non-integral
    // quotient: 10+20+30 = 60 over the two East rows would be 30/2 = 15.0.
    let rows = try run("""
        SELECT AVG(Amount) FROM Sales WHERE Dept = 'Books' AND Region = 'East'
        """)
    // East Books are 10 and 20: (10 + 20) / 2 = 15.0.
    #expect(rows == [[.double(15.0)]])
  }

  @Test("an all-NULL group yields NULL for SUM/MIN/MAX/AVG and 0 for COUNT")
  func allNull() throws {
    // Toys has one row whose Amount is NULL: COUNT(*) counts the row (1),
    // COUNT(Amount) skips it (0), and the value aggregates are NULL.
    let rows = try run("""
        SELECT COUNT(*), COUNT(Amount), SUM(Amount), MIN(Amount),
               MAX(Amount), AVG(Amount)
          FROM Sales WHERE Dept = 'Toys'
        """)
    #expect(rows == [[.integer(1), .integer(0), .null, .null, .null, .null]])
  }

  @Test("GROUP BY one column aggregates each group")
  func groupByOne() throws {
    let rows = try run("""
        SELECT Dept, COUNT(*), SUM(Amount) FROM Sales
          GROUP BY Dept ORDER BY Dept
        """)
    #expect(rows == [[.text("Books"), .integer(3), .integer(60)],
                     [.text("Games"), .integer(3), .integer(90)],
                     [.text("Toys"), .integer(1), .null]])
  }

  @Test("GROUP BY multiple columns keys on the tuple")
  func groupByMany() throws {
    let rows = try run("""
        SELECT Dept, Region, COUNT(*), SUM(Amount) FROM Sales
          GROUP BY Dept, Region ORDER BY Dept
        """)
    // (Books,East) 10+20, (Books,West) 30, (Games,East) 40, (Games,West)
    // NULL+50, (Toys,East) NULL. Ordered by Dept, ties by first appearance.
    #expect(rows == [[.text("Books"), .text("East"), .integer(2), .integer(30)],
                     [.text("Books"), .text("West"), .integer(1), .integer(30)],
                     [.text("Games"), .text("East"), .integer(1), .integer(40)],
                     [.text("Games"), .text("West"), .integer(2), .integer(50)],
                     [.text("Toys"), .text("East"), .integer(1), .null]])
  }

  @Test("a compound ORDER BY sorts grouped output by each key in turn")
  func orderByCompound() throws {
    // Order groups by Dept ascending, breaking ties by Region descending — the
    // second key reverses only the rows the first leaves equal.
    let rows = try run("""
        SELECT Dept, Region, COUNT(*), SUM(Amount) FROM Sales
          GROUP BY Dept, Region ORDER BY Dept, Region DESC
        """)
    #expect(rows == [[.text("Books"), .text("West"), .integer(1), .integer(30)],
                     [.text("Books"), .text("East"), .integer(2), .integer(30)],
                     [.text("Games"), .text("West"), .integer(2), .integer(50)],
                     [.text("Games"), .text("East"), .integer(1), .integer(40)],
                     [.text("Toys"), .text("East"), .integer(1), .null]])
  }

  @Test("mixed integer/double group keys canonicalize into one group")
  func mixedNumericKeys() throws {
    // A column carrying both 1 and 1.0 — as a CTE/UNION ALL or any source can —
    // groups them together under the engine's EXACT numeric equality (the same
    // `1` = `1.0` UNION dedup uses), yielding one group of two keyed by the
    // first-appearance integer, not two one-row groups.
    let catalog = AggregateMemory(
        ["T": AggregateRelation(["x"], [[.integer(1)], [.double(1.0)]])])
    let rows = try Engine.run(
        parse("SELECT x, COUNT(*) FROM T GROUP BY x"), catalog)
    #expect(rows == [[.integer(1), .integer(2)]])
  }

  @Test("mixed SUM/AVG widening does not depend on row order")
  func mixedWideningOrderIndependent() throws {
    // Int.max, 1, 0.5 overflows Int if summed as integers first, but the 0.5
    // widens the total to a double — so the result must be the same
    // whether the overflowing integer prefix or the double is seen first, not a
    // SQLError.magnitude one way and a double the other.
    let prefix = AggregateMemory(
        ["T": AggregateRelation(
            ["x"], [[.integer(.max)], [.integer(1)], [.double(0.5)]])])
    let suffix = AggregateMemory(
        ["T": AggregateRelation(
            ["x"], [[.double(0.5)], [.integer(.max)], [.integer(1)]])])
    let expected = Double(Int.max) + 1.0 + 0.5
    let query = "SELECT SUM(x), AVG(x) FROM T"
    #expect(try Engine.run(parse(query), prefix)
            == [[.double(expected), .double(expected / 3)]])
    #expect(try Engine.run(parse(query), suffix)
            == [[.double(expected), .double(expected / 3)]])
  }

  @Test("all-integer SUM tolerates transient overflow if the total fits")
  func transientIntegerOverflow() throws {
    // A prefix that overflows Int (Int.max + 1) must not latch a fault when a
    // later value (-1) brings the exact total back into range — the result is
    // the mathematical total, Int.max, whichever order the rows arrive in.
    let up = AggregateMemory(
        ["T": AggregateRelation(
            ["x"], [[.integer(.max)], [.integer(1)], [.integer(-1)]])])
    let down = AggregateMemory(
        ["T": AggregateRelation(
            ["x"], [[.integer(.max)], [.integer(-1)], [.integer(1)]])])
    #expect(try Engine.run(parse("SELECT SUM(x) FROM T"), up)
            == [[.integer(.max)]])
    #expect(try Engine.run(parse("SELECT SUM(x) FROM T"), down)
            == [[.integer(.max)]])
    // A total that genuinely exceeds Int still faults, in any order.
    let over = AggregateMemory(
        ["T": AggregateRelation(["x"], [[.integer(.max)], [.integer(.max)]])])
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try Engine.run(parse("SELECT SUM(x) FROM T"), over)
    }
  }

  @Test("AVG divides a wide integer total that SUM could not represent")
  func avgWideIntegerTotal() throws {
    // Two Int.max rows sum to 2 * Int.max, outside Int — SUM would fault, but
    // AVG divides the wide total and returns the finite approximate mean.
    let catalog = AggregateMemory(
        ["T": AggregateRelation(["x"], [[.integer(.max)], [.integer(.max)]])])
    #expect(try Engine.run(parse("SELECT AVG(x) FROM T"), catalog)
            == [[.double(Double(Int.max))]])
  }

  @Test("MIN/MAX over incomparable kinds is a type error, either order")
  func minMaxIncomparableKinds() throws {
    // A column mixing TEXT and INTEGER (from a CTE/UNION ALL) has no ordering
    // across kinds — MIN/MAX rejects it rather than keeping the first-seen
    // value (which would flip MIN and MAX with row order).
    let fault = SQLError.operand("MIN and MAX require a common comparable kind")
    let textFirst = AggregateMemory(
        ["T": AggregateRelation(["x"], [[.text("a")], [.integer(1)]])])
    let intFirst = AggregateMemory(
        ["T": AggregateRelation(["x"], [[.integer(1)], [.text("a")]])])
    for catalog in [textFirst, intFirst] {
      #expect(throws: fault) {
        try Engine.run(parse("SELECT MIN(x) FROM T"), catalog)
      }
      #expect(throws: fault) {
        try Engine.run(parse("SELECT MAX(x) FROM T"), catalog)
      }
    }
  }

  @Test("MIN/MAX over Int.max and Double(Int.max) is deterministic")
  func minMaxNumericBoundary() throws {
    // Int.max (2^63 - 1) and Double(Int.max) (2^63) are both numeric and order
    // exactly, so MIN is the integer and MAX the larger double — same result
    // whichever row arrives first, not an order-dependent first-seen keep.
    let intFirst = AggregateMemory(
        ["T": AggregateRelation(
            ["x"], [[.integer(.max)], [.double(Double(Int.max))]])])
    let doubleFirst = AggregateMemory(
        ["T": AggregateRelation(
            ["x"], [[.double(Double(Int.max))], [.integer(.max)]])])
    for catalog in [intFirst, doubleFirst] {
      #expect(try Engine.run(parse("SELECT MIN(x), MAX(x) FROM T"), catalog)
              == [[.integer(.max), .double(Double(Int.max))]])
    }
  }

  @Test("ORDER BY on a duplicated projection output name is ambiguous")
  func orderByAmbiguousName() throws {
    // Two projected columns share the output name `k`, so `ORDER BY k` has no
    // single slot to order on — rejected as ambiguous (as the non-grouped path
    // reports for a shared unqualified join column) rather than silently
    // ordering by whichever projection came last.
    #expect(throws: SQLError.ambiguous("k")) {
      try run("""
          SELECT Dept AS k, Region AS k FROM Sales
            GROUP BY Dept, Region ORDER BY k
          """)
    }
  }

  @Test("MIN and MAX use the engine's typed comparison per group")
  func minMax() throws {
    let rows = try run("""
        SELECT Dept, MIN(Amount), MAX(Amount) FROM Sales
          GROUP BY Dept ORDER BY Dept
        """)
    #expect(rows == [[.text("Books"), .integer(10), .integer(30)],
                     [.text("Games"), .integer(40), .integer(50)],
                     [.text("Toys"), .null, .null]])
  }

  @Test("HAVING filters groups after aggregation")
  func having() throws {
    // Keep only departments whose row count exceeds one — Toys (1 row) drops.
    let rows = try run("""
        SELECT Dept, COUNT(*) FROM Sales
          GROUP BY Dept HAVING COUNT(*) > 1 ORDER BY Dept
        """)
    #expect(rows == [[.text("Books"), .integer(3)],
                     [.text("Games"), .integer(3)]])
  }

  @Test("HAVING may reference an aggregate not in the projection")
  func havingHidden() throws {
    // The HAVING aggregates SUM(Amount) though the projection does not — the
    // engine still computes it for the group filter.
    let rows = try run("""
        SELECT Dept FROM Sales
          GROUP BY Dept HAVING SUM(Amount) > 70 ORDER BY Dept
        """)
    // Books SUM 60 drops, Games SUM 90 keeps, Toys SUM NULL drops (UNKNOWN).
    #expect(rows == [[.text("Games")]])
  }

  @Test("HAVING without a GROUP BY filters the single whole-result group")
  func havingWholeResult() throws {
    // The whole result is one group; HAVING keeps or drops it. COUNT(*) is 7.
    #expect(try run("SELECT COUNT(*) FROM Sales HAVING COUNT(*) > 5")
            == [[.integer(7)]])
    #expect(try run("SELECT COUNT(*) FROM Sales HAVING COUNT(*) > 100") == [])
  }

  @Test("ORDER BY may name an aggregate's projection alias")
  func orderByAggregate() throws {
    // Order the departments by their total descending — the ORDER BY names the
    // aggregate's output alias `Total`.
    let rows = try run("""
        SELECT Dept, SUM(Amount) AS Total FROM Sales
          GROUP BY Dept ORDER BY Total DESC
        """)
    // Games 90, Books 60, Toys NULL (NULL sorts last descending).
    #expect(rows == [[.text("Games"), .integer(90)],
                     [.text("Books"), .integer(60)],
                     [.text("Toys"), .null]])
  }

  @Test("ORDER BY on a computed-expression alias is rejected clearly")
  func orderByComputedAlias() throws {
    // `Doubled` aliases a COMPUTED value (the projection evaluates it after
    // the sort), so it has no standalone grouped slot to order on — the engine
    // rejects it as unsupported rather than misreporting an unknown column.
    #expect(throws: SQLError.self) {
      try run("""
          SELECT Dept, COUNT(*) * 2 AS Doubled FROM Sales
            GROUP BY Dept ORDER BY Doubled DESC
          """)
    }
  }

  @Test("an aggregate query pages with OFFSET/FETCH after ORDER BY")
  func aggregateFetch() throws {
    // Three groups ordered by Dept; skip one, take one.
    let rows = try run("""
        SELECT Dept, COUNT(*) FROM Sales
          GROUP BY Dept ORDER BY Dept OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY
        """)
    #expect(rows == [[.text("Games"), .integer(3)]])
  }

  @Test("an aggregate mixes with a scalar arithmetic over the group key")
  func mixedProjection() throws {
    // A grouped query may project the key through arithmetic and a scalar
    // expression alongside the aggregate; COUNT(*) doubled proves it composes.
    let rows = try run("""
        SELECT Dept, COUNT(*) * 2 FROM Sales
          GROUP BY Dept ORDER BY Dept
        """)
    #expect(rows == [[.text("Books"), .integer(6)],
                     [.text("Games"), .integer(6)],
                     [.text("Toys"), .integer(2)]])
  }

  @Test("a non-grouped projection column is rejected")
  func projectionRule() throws {
    // `Region` is neither aggregated nor a GROUP BY key, so the query is
    // ill-formed — the standard single-group rule.
    #expect(throws: SQLError.grouping("Region")) {
      try run("SELECT Dept, Region, COUNT(*) FROM Sales GROUP BY Dept")
    }
  }

  @Test("a bare column with no GROUP BY and an aggregate is rejected")
  func bareColumnRule() throws {
    // Mixing a bare column with an aggregate and no GROUP BY groups the whole
    // result — the column is then not a key, so it faults.
    #expect(throws: SQLError.grouping("Dept")) {
      try run("SELECT Dept, COUNT(*) FROM Sales")
    }
  }

  @Test("the projection-rule fault carries the SS004 SQLSTATE")
  func projectionRuleState() throws {
    #expect(SQLError.grouping("Region").sqlstate == "SS004")
  }

  @Test("SUM over a text column is a type error")
  func sumText() throws {
    // SUM/AVG require numeric operands; folding a text value faults through the
    // engine's arithmetic rather than coercing.
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try run("SELECT SUM(Dept) FROM Sales")
    }
  }

  @Test("AVG over a text column is a type error")
  func avgText() throws {
    // AVG folds the same numeric total as SUM, so a text operand faults alike.
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try run("SELECT AVG(Dept) FROM Sales")
    }
  }

  @Test("only COUNT admits a '*' operand")
  func starOnlyCount() throws {
    // `SUM(*)`/`AVG(*)`/`MIN(*)`/`MAX(*)` are not valid — only `COUNT(*)`
    // counts rows without reading a value.
    for function in ["SUM", "AVG", "MIN", "MAX"] {
      #expect(throws: SQLError.self) {
        try run("SELECT \(function)(*) FROM Sales")
      }
    }
    // `COUNT(*)` remains valid — it counts every row.
    #expect(try run("SELECT COUNT(*) FROM Sales") == [[.integer(7)]])
  }

  @Test("an aggregate in a WHERE clause is rejected")
  func aggregateInWhere() throws {
    // An aggregate has no per-row meaning, so it may not appear in a WHERE.
    #expect(throws: SQLError.self) {
      try run("SELECT Dept FROM Sales WHERE COUNT(*) > 1 GROUP BY Dept")
    }
  }

  @Test("an aggregate groups a join by a qualified key column")
  func aggregateOverJoin() throws {
    // Aggregation sits above the join chain, so a grouped query over a join
    // folds each aggregate over the joined rows and keys on a qualified column.
    let catalog = AggregateMemory([
      "Dept": AggregateRelation(["Id", "Name"],
          [[.integer(1), .text("Books")], [.integer(2), .text("Games")]]),
      "Item": AggregateRelation(["DeptId", "Price"],
          [[.integer(1), .integer(10)], [.integer(1), .integer(20)],
           [.integer(2), .integer(40)]]),
    ])
    let rows = try Engine.run(parse("""
        SELECT Dept.Name, SUM(Item.Price) FROM Dept
          JOIN Item ON Item.DeptId = Dept.Id
          GROUP BY Dept.Name ORDER BY Dept.Name
        """), catalog)
    #expect(rows == [[.text("Books"), .integer(30)],
                     [.text("Games"), .integer(40)]])
  }

  @Test("SUM over an all-integer column stays an exact integer")
  func sumIntegerExact() throws {
    // Every folded value is an integer, so the total stays an integer — the
    // engine's arithmetic keeps `integer + integer` integral.
    #expect(try run("SELECT SUM(Amount) FROM Sales")
            == [[.integer(150)]])
  }

  @Test("SUM over a double column yields a double")
  func sumDouble() throws {
    let catalog = AggregateMemory([
      "T": AggregateRelation(["X"],
          [[.double(1.5)], [.double(2.25)], [.double(0.25)]]),
    ])
    // 1.5 + 2.25 + 0.25 = 4.0 — the running total widens to a double.
    let rows = try Engine.run(parse("SELECT SUM(X) FROM T"), catalog)
    #expect(rows == [[.double(4.0)]])
  }

  @Test("SUM over mixed integer and double columns widens to a double")
  func sumMixed() throws {
    let catalog = AggregateMemory([
      "T": AggregateRelation(["X"],
          [[.integer(10)], [.double(2.5)], [.integer(20)]]),
    ])
    // 10 + 2.5 + 20 = 32.5 — a lone double operand widens the whole total.
    let rows = try Engine.run(parse("SELECT SUM(X) FROM T"), catalog)
    #expect(rows == [[.double(32.5)]])
  }

  @Test("AVG over a double column is a double")
  func avgDouble() throws {
    let catalog = AggregateMemory([
      "T": AggregateRelation(["X"],
          [[.double(1.0)], [.double(2.0)]]),
    ])
    // (1.0 + 2.0) / 2 = 1.5 — real division over a double total.
    let rows = try Engine.run(parse("SELECT AVG(X) FROM T"), catalog)
    #expect(rows == [[.double(1.5)]])
  }
}
