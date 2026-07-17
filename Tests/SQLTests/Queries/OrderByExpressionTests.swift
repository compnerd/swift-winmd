// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// MARK: - Fixtures

/// A `People` relation whose columns support every sort-key form: `Name` for a
/// bare-column and `UPPER(Name)` key, `A`/`B` for an `A + B` arithmetic key,
/// and deliberate ties so a secondary key is observable.
private func people() throws -> FixtureCatalog {
  try Catalog {
    Relation("People",
             ["Id": .integer, "Name": .text, "A": .integer, "B": .integer]) {
      Row(1, "carol", 3, 1)
      Row(2, "alice", 1, 4)
      Row(3, "bob", 2, 2)
      Row(4, "dave", 5, 5)
    }
  }
}

/// A `Sales` relation of `Dept`/`Amount` rows with departments of differing
/// counts (Books 3, Games 3, Toys 1) so a grouped `ORDER BY COUNT(*)` has a
/// meaningful order, and distinct sums (Books 60, Games 90, Toys 30) for an
/// aggregate that is both projected and sorted-on.
private func sales() throws -> FixtureCatalog {
  try Catalog {
    Relation("Sales", ["Dept": .text, "Amount": .integer]) {
      Row("Books", 10)
      Row("Books", 20)
      Row("Books", 30)
      Row("Games", 40)
      Row("Games", 50)
      Row("Games", nil)
      Row("Toys", 30)
    }
  }
}

/// Two relations that BOTH carry a `Name` column, joined on their `Id`s, so a
/// bare unqualified `ORDER BY Name` is an ambiguous INPUT reference — the
/// surface for the representation-independence check.
private func joined() throws -> FixtureCatalog {
  try Catalog {
    Relation("a", ["Id": .integer, "Name": .text]) {
      Row(1, "carol")
      Row(2, "alice")
      Row(3, "bob")
    }
    Relation("b", ["Id": .integer, "Name": .text]) {
      Row(1, "x")
      Row(2, "y")
      Row(3, "z")
    }
  }
}

// MARK: - Tests

/// The generalized ISO `<sort key>`: an output ORDINAL, an arbitrary value
/// EXPRESSION over the input columns, and an output ALIAS — the three forms an
/// `ORDER BY` key now admits beyond a bare column.
struct OrderByExpressionTests {
  @Test func `ORDER BY an ordinal orders on that output column`() throws {
    // `2` names the second projected column (Name), ascending.
    try people().expect("SELECT Id, Name FROM People ORDER BY 2",
                        yields: [[2, "alice"], [3, "bob"], [1, "carol"],
                                 [4, "dave"]])
  }

  @Test func `ORDER BY an ordinal DESC reverses that output column`() throws {
    // `2 DESC` orders on Name descending: dave, carol, bob, alice.
    try people().expect("SELECT Id, Name FROM People ORDER BY 2 DESC",
                        yields: [[4, "dave"], [1, "carol"], [3, "bob"],
                                 [2, "alice"]])
  }

  @Test func `an ordinal names the output column, not the integer constant`() throws {
    // A bare integer sort key is the ISO ORDINAL, never the constant `1`;
    // ordering on `1` therefore orders on the FIRST output column (Id), the
    // rows already in Id order, rather than treating every row as equal.
    let catalog = try people()
    try catalog.expect("SELECT Id, Name FROM People ORDER BY 1",
                       equals: "SELECT Id, Name FROM People ORDER BY Id")
  }

  @Test func `an out-of-range ordinal is diagnosed`() throws {
    // `3` names a third output column the two-column select list has not — an
    // ordinal outside `1 ... width` faults as an unknown column would.
    try people().expect("SELECT Id, Name FROM People ORDER BY 3",
                        fails: SQLError.column("3"))
  }

  @Test func `ORDER BY an arithmetic expression orders on its value`() throws {
    // `A + B`: carol 4, alice 5, bob 4, dave 10 — ascending, ties (carol, bob
    // both 4) kept in scan order (a stable sort).
    try people().expect("SELECT Name FROM People ORDER BY A + B",
                        yields: [["carol"], ["bob"], ["alice"], ["dave"]])
  }

  @Test func `ORDER BY a scalar call orders on the computed value`() throws {
    // `UPPER(Name)` upper-cases before comparing; the names are already
    // lower-case and distinct, so the order is the plain alphabetical one.
    try people().expect("SELECT Id FROM People ORDER BY UPPER(Name)",
                        yields: [[2], [3], [1], [4]])
  }

  @Test func `ORDER BY an output alias orders on the aliased value`() throws {
    // `Total` aliases `A + B`; the ORDER BY names the output alias, ordering on
    // the same computed value (carol 4, bob 4, alice 5, dave 10).
    try people().expect("""
        SELECT Name, A + B AS Total FROM People ORDER BY Total
        """, yields: [["carol", 4], ["bob", 4], ["alice", 5], ["dave", 10]])
  }

  @Test func `an output alias wins over an input column of the same name`() throws {
    // `Name` aliases `UPPER(Name)` here, so the bare `ORDER BY Name` binds the
    // OUTPUT alias (the ISO precedence) rather than the input `Name` column —
    // both order the rows the same alphabetically here, but the alias's value
    // (the upper-cased name) is what the output row carries.
    try people().expect("""
        SELECT Id, UPPER(Name) AS Name FROM People ORDER BY Name
        """, yields: [[2, "ALICE"], [3, "BOB"], [1, "CAROL"], [4, "DAVE"]])
  }

  @Test func `a mixed multi-key ORDER BY combines an ordinal and an expression`() throws {
    // Primary `A + B` ascending leaves carol and bob tied at 4; the secondary
    // ordinal `1` (the Id output column) DESC breaks that tie — carol (Id 1)
    // before bob (Id 3) — proving the two key forms compose and each carries
    // its own direction.
    try people().expect("""
        SELECT Id FROM People ORDER BY A + B, 1 DESC
        """, yields: [[3], [1], [2], [4]])
  }

  @Test func `ORDER BY an input column absent from the select list`() throws {
    // A plain (non-DISTINCT) query may order on any INPUT column — `A` here —
    // even one the projection drops; the sort runs on the source rows before
    // the projection. A ascending: alice 1, bob 2, carol 3, dave 5.
    try people().expect("SELECT Name FROM People ORDER BY A",
                        yields: [["alice"], ["bob"], ["carol"], ["dave"]])
  }

  // MARK: - Output-name binding is representation-independent

  // Only an explicit `AS` alias introduces an ORDER-BY-visible output name. A
  // bare projected column contributes none, so `ORDER BY <bareName>` resolves
  // as an INPUT column — identically whether an unrelated select-list item
  // forced the projection into a `columns` or an `expressions` list.

  @Test func `a bare ORDER BY name over a join is an ambiguous input column`() throws {
    // Both `a` and `b` carry `Name`, so the bare `ORDER BY Name` is an
    // ambiguous INPUT reference — no explicit alias claims the name.
    try joined().expect("""
        SELECT a.Name, a.Id FROM a JOIN b ON a.Id = b.Id ORDER BY Name
        """, fails: SQLError.ambiguous("Name"))
  }

  @Test func `an unrelated AS does not flip a bare ORDER BY name to an output`() throws {
    // Aliasing ONLY the SECOND item (`a.Id AS id`) forces the projection into
    // an `expressions` list, but the first item is still a BARE `a.Name` with
    // no explicit alias — so `ORDER BY Name` remains the same ambiguous INPUT
    // reference as the `columns`-list form above, not a bind to the first
    // output. Semantics track the SQL, not the AST representation.
    try joined().expect("""
        SELECT a.Name, a.Id AS id FROM a JOIN b ON a.Id = b.Id ORDER BY Name
        """, fails: SQLError.ambiguous("Name"))
  }

  @Test func `ORDER BY an explicit alias still binds the projected output`() throws {
    // An explicit `AS u` DOES introduce an output name, so `ORDER BY u` binds
    // the projected expression (the upper-cased name), not an input column.
    try people().expect("""
        SELECT UPPER(Name) AS u FROM People ORDER BY u
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
  }

  @Test func `a single-table bare ORDER BY name binds the input column`() throws {
    // One relation, one `Name`: the bare projected column introduces no output
    // alias, so `ORDER BY Name` binds the unambiguous INPUT column.
    try people().expect("SELECT Name FROM People ORDER BY Name",
                        yields: [["alice"], ["bob"], ["carol"], ["dave"]])
  }

  // MARK: - Duplicate output aliases are ambiguous

  @Test func `ORDER BY a duplicated output alias is ambiguous`() throws {
    // `A AS k` and `B AS k` both name `k`; the two aliases compute different
    // values, so a bare `ORDER BY k` has no single term to order on — it is
    // ambiguous rather than a select-list-order-dependent first-match on `A`.
    try people().expect("""
        SELECT A AS k, B AS k FROM People ORDER BY k
        """, fails: SQLError.ambiguous("k"))
  }

  @Test func `ORDER BY a non-duplicated output alias still binds`() throws {
    // Distinct aliases `k`/`j` leave `k` unambiguous, so `ORDER BY k` binds the
    // `A` output ascending: alice 1, bob 2, carol 3, dave 5.
    try people().expect("""
        SELECT A AS k, B AS j FROM People ORDER BY k
        """, yields: [[1, 4], [2, 2], [3, 1], [5, 5]])
  }

  @Test func `SELECT DISTINCT admits an ordinal ORDER BY key`() throws {
    // Under DISTINCT every ORDER BY key must be a select-list value; the
    // ordinal `1` names the sole output column, so it is admitted. The distinct
    // A+B totals are 4, 5, 10 (carol and bob share 4), ordered ascending.
    try people().expect("""
        SELECT DISTINCT A + B AS Total FROM People ORDER BY 1
        """, yields: [[4], [5], [10]])
  }

  @Test func `SELECT DISTINCT rejects an expression ORDER BY key it drops`() throws {
    // `A` is not a select-list value, so ordering on it under DISTINCT is
    // ill-defined — one output row stands for many source rows with differing
    // `A` — and faults.
    try people().expect("SELECT DISTINCT Name FROM People ORDER BY A",
                        fails: SQLError.distinct("A"))
  }

  @Test func `SELECT DISTINCT admits an ORDER BY repeating a projected expression`() throws {
    // The ORDER BY REPEATS the projected `A + B` expression rather than naming
    // its alias or ordinal. That sort key IS the projected distinct value, so
    // ordering on it is well-defined and admitted — the same result as the
    // alias `ORDER BY Total` and the ordinal `ORDER BY 1` naming that output.
    // The distinct A+B totals are 4, 5, 10 (carol and bob share 4), ascending.
    try people().expect("""
        SELECT DISTINCT A + B AS Total FROM People ORDER BY A + B
        """, yields: [[4], [5], [10]])
  }

  @Test func `the alias and ordinal name the same DISTINCT output`() throws {
    // `ORDER BY Total` (alias) and `ORDER BY 1` (ordinal) produce the SAME order
    // as the repeated `ORDER BY A + B` above — all three name the one projected
    // distinct value.
    try people().expect("""
        SELECT DISTINCT A + B AS Total FROM People ORDER BY Total
        """, yields: [[4], [5], [10]])
    try people().expect("""
        SELECT DISTINCT A + B AS Total FROM People ORDER BY 1
        """, yields: [[4], [5], [10]])
  }

  @Test func `SELECT DISTINCT rejects an expression over a non-projected column`() throws {
    // Only `A` is projected, so the repeated-expression admission must not
    // over-accept: `A + B` reads `B`, which the projection drops, so ordering
    // on it under DISTINCT stays ill-defined and faults.
    try people().expect("SELECT DISTINCT A FROM People ORDER BY A + B",
                        fails: SQLError.distinct("an expression"))
  }

  @Test func `SELECT DISTINCT admits an ORDER BY on a bare projected column`() throws {
    // A bare projected `A` lowers to a slot the ORDER BY key reads, so the
    // bare-slot admission (not the expression one) accepts `ORDER BY A`. The
    // distinct `A` values are 1, 2, 3, 5, ascending.
    try people().expect("SELECT DISTINCT A FROM People ORDER BY A",
                        yields: [[1], [2], [3], [5]])
  }

  @Test func `SELECT DISTINCT admits an ORDER BY differing only in qualification`() throws {
    // The ORDER BY repeats the projected `A + 1`, but QUALIFIES the column
    // (`People.A + 1`) where the projection did not (`A + 1`). The two are
    // different AST expressions, yet both LOWER to the same `Term` — the
    // column resolves to the same slot — so the sort key IS the projected
    // distinct value and is admitted, exactly as the unqualified `A + 1`, the
    // alias `v`, and the ordinal `1` naming that output are. The distinct
    // A+1 values are 2, 3, 4, 6, ascending.
    try people().expect("""
        SELECT DISTINCT A + 1 AS v FROM People ORDER BY People.A + 1
        """, yields: [[2], [3], [4], [6]])
  }

  @Test func `the qualified, unqualified, alias, and ordinal DISTINCT keys agree`() throws {
    // The qualified `People.A + 1` produces the SAME order as the unqualified
    // `A + 1`, the alias `v`, and the ordinal `1` — all four name the one
    // projected distinct value (2, 3, 4, 6, ascending).
    let catalog = try people()
    try catalog.expect("""
        SELECT DISTINCT A + 1 AS v FROM People ORDER BY A + 1
        """, yields: [[2], [3], [4], [6]])
    try catalog.expect("""
        SELECT DISTINCT A + 1 AS v FROM People ORDER BY v
        """, yields: [[2], [3], [4], [6]])
    try catalog.expect("""
        SELECT DISTINCT A + 1 AS v FROM People ORDER BY 1
        """, yields: [[2], [3], [4], [6]])
  }

  @Test func `SELECT DISTINCT admits a qualified ORDER BY on a bare projected column`() throws {
    // The projected bare `A` lowers to a slot, and the QUALIFIED `People.A`
    // key lowers to the SAME slot, so it matches the projected term and is
    // admitted. The distinct `A` values are 1, 2, 3, 5, ascending.
    try people().expect("SELECT DISTINCT A FROM People ORDER BY People.A",
                        yields: [[1], [2], [3], [5]])
  }

  @Test func `SELECT DISTINCT rejects a qualified key over a non-projected column`() throws {
    // A resolved-term match must not over-accept: `People.B` lowers to a slot
    // the projected `A` does not, so ordering on it under DISTINCT stays
    // ill-defined and faults — the qualification does not make it projected.
    try people().expect("SELECT DISTINCT A FROM People ORDER BY People.B",
                        fails: SQLError.distinct("B"))
  }

  @Test func `SELECT DISTINCT admits a mixed-case ORDER BY repeating a projected call`() throws {
    // The ORDER BY repeats the projected `UPPER(Name)` call, but spells the
    // routine in a DIFFERENT case (`upper` vs `UPPER`). A routine resolves by
    // the case-insensitive SQL identifier rule, so both name the same routine
    // and the two calls lower to an IDENTICAL term — the sort key IS the
    // projected distinct value and is admitted, exactly as the same-case
    // `ORDER BY UPPER(Name)`, the alias `u`, and the ordinal `1` are. The
    // distinct upper-cased names are ALICE, BOB, CAROL, DAVE, ascending.
    try people().expect("""
        SELECT DISTINCT UPPER(Name) AS u FROM People ORDER BY upper(Name)
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
  }

  @Test func `the same-case, mixed-case, alias, and ordinal DISTINCT call keys agree`() throws {
    // The mixed-case `upper(Name)` produces the SAME order as the same-case
    // `UPPER(Name)`, the alias `u`, and the ordinal `1` — all four name the one
    // projected distinct value (ALICE, BOB, CAROL, DAVE, ascending).
    let catalog = try people()
    try catalog.expect("""
        SELECT DISTINCT UPPER(Name) AS u FROM People ORDER BY UPPER(Name)
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
    try catalog.expect("""
        SELECT DISTINCT UPPER(Name) AS u FROM People ORDER BY u
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
    try catalog.expect("""
        SELECT DISTINCT UPPER(Name) AS u FROM People ORDER BY 1
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
  }

  @Test func `SELECT DISTINCT admits a mixed-case ORDER BY the other way round`() throws {
    // The case folding is symmetric: a lower-case `upper(Name)` PROJECTED and
    // an upper-case `UPPER(Name)` in the ORDER BY lower to the same term too,
    // so this spelling is admitted as well (ALICE, BOB, CAROL, DAVE).
    try people().expect("""
        SELECT DISTINCT upper(Name) AS u FROM People ORDER BY UPPER(Name)
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
  }

  @Test func `SELECT DISTINCT rejects a case-folded key that names a different routine`() throws {
    // Case folding equates only calls of the SAME routine: `LOWER(Name)` is a
    // DIFFERENT routine from the projected `UPPER(Name)`, so its term differs
    // and ordering on it under DISTINCT stays ill-defined and faults.
    try people().expect("""
        SELECT DISTINCT UPPER(Name) AS u FROM People ORDER BY LOWER(Name)
        """, fails: SQLError.distinct("an expression"))
  }

  @Test func `a non-DISTINCT call resolves and runs regardless of its spelling`() throws {
    // Name folding is purely about term IDENTITY — dispatch already folds on
    // lookup, so a plain (non-DISTINCT) query calling `upper` in either case
    // still resolves the routine and runs. The names are already lower-case and
    // distinct, so the upper-cased order is the plain alphabetical one.
    let catalog = try people()
    try catalog.expect("SELECT Id FROM People ORDER BY upper(Name)",
                       yields: [[2], [3], [1], [4]])
    try catalog.expect("SELECT Id FROM People ORDER BY UPPER(Name)",
                       yields: [[2], [3], [1], [4]])
  }

  @Test func `a grouped ORDER BY sorts on an aggregate it does not project`() throws {
    // `COUNT(*)` is neither projected nor in a HAVING, so the group plan must
    // collect it from the ORDER BY to have a grouped slot to sort on: Toys 1,
    // then Books and Games tied at 3 (stable, first-appearance order).
    try sales().expect("""
        SELECT Dept FROM Sales GROUP BY Dept ORDER BY COUNT(*)
        """, yields: [["Toys"], ["Books"], ["Games"]])
  }

  @Test func `a grouped ORDER BY aggregate DESC reverses the group order`() throws {
    // The reported motivating case — sort groups by their count descending:
    // Books and Games (3) before Toys (1), the tie kept in first-appearance
    // order by the stable sort.
    try sales().expect("""
        SELECT Dept FROM Sales GROUP BY Dept ORDER BY COUNT(*) DESC
        """, yields: [["Books"], ["Games"], ["Toys"]])
  }

  @Test func `a grouped ORDER BY may sort on an unprojected SUM`() throws {
    // `SUM(Amount)` is only in the ORDER BY (Books 60, Games 90, Toys 30) —
    // ascending yields Toys, Books, Games.
    try sales().expect("""
        SELECT Dept FROM Sales GROUP BY Dept ORDER BY SUM(Amount)
        """, yields: [["Toys"], ["Books"], ["Games"]])
  }

  @Test func `an aggregate both projected and sorted-on computes once`() throws {
    // `COUNT(*)` is projected AND sorted on — `collect` dedups, so it lands in
    // one grouped slot and the projection and the sort read the same value
    // (no duplicate-slot regression): counts descending, projected alongside.
    try sales().expect("""
        SELECT Dept, COUNT(*) FROM Sales GROUP BY Dept ORDER BY COUNT(*) DESC
        """, yields: [["Books", 3], ["Games", 3], ["Toys", 1]])
  }

  // MARK: - Aggregate collection normalizes column qualification

  // Aggregate collection dedups by the RESOLVED aggregation (function plus
  // resolved argument term), not by AST spelling, so an aggregate written two
  // ways that differ ONLY in column qualification — `SUM(Amount)` projected,
  // `SUM(Sales.Amount)` in the ORDER BY — is ONE grouped slot: the aggregate
  // computes once and both clauses read/order the same value.

  @Test func `SELECT DISTINCT admits an ORDER BY aggregate differing only in qualification`() throws {
    // The projected `SUM(Amount)` and the ORDER BY `SUM(Sales.Amount)` differ
    // only in qualification; deduped by resolved form they share ONE grouped
    // slot, so the sort key IS the projected distinct value and DISTINCT admits
    // it. Distinct department sums are 60, 90, 30, ordered ascending.
    try sales().expect("""
        SELECT DISTINCT SUM(Amount) FROM Sales GROUP BY Dept \
        ORDER BY SUM(Sales.Amount)
        """, yields: [[30], [60], [90]])
  }

  @Test func `a DISTINCT qualified ORDER BY aggregate matches the unqualified form`() throws {
    // The qualified `SUM(Sales.Amount)` sort key produces the SAME result as the
    // unqualified `SUM(Amount)` and the ordinal `1` — all three name the one
    // projected distinct aggregate value.
    let catalog = try sales()
    try catalog.expect("""
        SELECT DISTINCT SUM(Amount) FROM Sales GROUP BY Dept \
        ORDER BY SUM(Sales.Amount)
        """, yields: [[30], [60], [90]])
    try catalog.expect("""
        SELECT DISTINCT SUM(Amount) FROM Sales GROUP BY Dept \
        ORDER BY SUM(Amount)
        """, yields: [[30], [60], [90]])
    try catalog.expect("""
        SELECT DISTINCT SUM(Amount) FROM Sales GROUP BY Dept ORDER BY 1
        """, yields: [[30], [60], [90]])
  }

  @Test func `a grouped ORDER BY qualified aggregate reuses the projected slot`() throws {
    // Non-DISTINCT: the projected `SUM(Amount)` (aliased) and the ORDER BY
    // `SUM(Sales.Amount)` are the SAME resolved aggregation, so SUM computes
    // ONCE into one grouped slot and the sort orders by it — the qualified and
    // unqualified sort keys agree (60, 90, 30 by department, descending).
    let catalog = try sales()
    try catalog.expect("""
        SELECT Dept, SUM(Amount) AS s FROM Sales GROUP BY Dept \
        ORDER BY SUM(Sales.Amount) DESC
        """, yields: [["Games", 90], ["Books", 60], ["Toys", 30]])
    try catalog.expect("""
        SELECT Dept, SUM(Amount) AS s FROM Sales GROUP BY Dept \
        ORDER BY SUM(Amount) DESC
        """, yields: [["Games", 90], ["Books", 60], ["Toys", 30]])
  }

  @Test func `a whole-result qualified ORDER BY aggregate reuses the projected slot`() throws {
    // The whole-result aggregate form (no GROUP BY): the projected `SUM(Amount)`
    // and the qualified `SUM(Sales.Amount)` sort key are one aggregation, so the
    // single group's SUM (180, the sole non-NULL total) computes once and the
    // sort orders by that shared slot.
    try sales().expect("""
        SELECT SUM(Amount) FROM Sales ORDER BY SUM(Sales.Amount)
        """, yields: [[180]])
  }

  @Test func `a DISTINCT ORDER BY on a different aggregate still faults`() throws {
    // Soundness: `SUM(Dept)` in the ORDER BY is a DIFFERENT aggregate from the
    // projected `COUNT(*)` — a different function over a different operand — so
    // it is a separate, non-projected grouped slot and ordering on it under
    // DISTINCT stays ill-defined and faults. (Its own fold over the TEXT `Dept`
    // never runs; the DISTINCT check rejects it first.)
    try sales().expect("""
        SELECT DISTINCT COUNT(*) FROM Sales GROUP BY Dept ORDER BY SUM(Dept)
        """, fails: SQLError.distinct("an expression"))
  }

  @Test func `genuinely different aggregates keep separate grouped slots`() throws {
    // Two different aggregations over the same operand — `SUM(Amount)` and
    // `MAX(Amount)` — must NOT dedup into one slot: they compute independently.
    // Books sums 60 / maxes 30, Games 90 / 50, Toys 30 / 30; ordered by SUM.
    try sales().expect("""
        SELECT SUM(Amount), MAX(Amount) FROM Sales GROUP BY Dept \
        ORDER BY SUM(Amount)
        """, yields: [[30, 30], [60, 30], [90, 50]])
  }

  // MARK: - Type-checking the sort keys

  /// The result columns `sql` advertises, resolved WITHOUT running it — the
  /// static shape check `columns(of:)`/`.schema`/`information_schema` drive,
  /// against the standard prelude so a call like `UPPER` resolves.
  private func columns(_ catalog: borrowing FixtureCatalog, _ sql: String)
      throws -> Array<OutputColumn> {
    guard case let .select(query) = try Statement(parsing: sql) else {
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return try catalog.columns(of: query)
  }

  @Test func `columns(of:) rejects an ORDER BY call to an unknown routine`() throws {
    // `NOPE` is no registered routine, so the sort would fault at run — the
    // static shape check must reject it too, not advertise the query as valid.
    #expect(throws: SQLError.self) {
      _ = try columns(try people(),
                      "SELECT Name FROM People ORDER BY NOPE(Name)")
    }
  }

  @Test func `columns(of:) rejects a wrong-arity ORDER BY call`() throws {
    // `UPPER` takes one argument; the two-argument call would fault its arity
    // at run, so the static shape check rejects it before advertising it.
    #expect(throws: SQLError.self) {
      _ = try columns(try people(),
                      "SELECT Name FROM People ORDER BY UPPER(Name, 2)")
    }
  }

  @Test func `columns(of:) accepts a valid ORDER BY call and expression`() throws {
    // A registered one-argument `UPPER` and an arithmetic key type-check, so
    // the shape check advertises the query — and it runs.
    let catalog = try people()
    let upper =
        try columns(catalog, "SELECT Name FROM People ORDER BY UPPER(Name)")
    #expect(upper.count == 1)
    try catalog.expect("SELECT Id FROM People ORDER BY UPPER(Name)",
                       yields: [[2], [3], [1], [4]])
    let sum =
        try columns(catalog, "SELECT Name FROM People ORDER BY 1 + A")
    #expect(sum.count == 1)
  }

  @Test func `columns(of:) rejects a grouped ORDER BY over a bad aggregate operand`() throws {
    // A grouped `ORDER BY SUM(Bogus)`/`NOPE(Amount)` collects into the group
    // plan and folds before the sort — an unknown operand column or an unknown
    // routine would fault at run, so the static shape check rejects both.
    let catalog = try sales()
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, """
          SELECT Dept FROM Sales GROUP BY Dept ORDER BY SUM(Bogus)
          """)
    }
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, """
          SELECT Dept FROM Sales GROUP BY Dept ORDER BY NOPE(Amount)
          """)
    }
  }

  @Test func `columns(of:) accepts a grouped ORDER BY COUNT(*)`() throws {
    // A valid grouped aggregate sort key type-checks and runs.
    let catalog = try sales()
    let advertised = try columns(catalog, """
        SELECT Dept FROM Sales GROUP BY Dept ORDER BY COUNT(*)
        """)
    #expect(advertised.count == 1)
    try catalog.expect("""
        SELECT Dept FROM Sales GROUP BY Dept ORDER BY COUNT(*)
        """, yields: [["Toys"], ["Books"], ["Games"]])
  }

  @Test func `columns(of:) surfaces a bad ORDER BY call in a view body`() throws {
    // A view whose body's ORDER BY calls an unknown routine advertises no valid
    // schema — the shape check reaches into the body's sort keys, so a
    // `.schema`/`columns(of:)` over the view faults where a run would.
    let catalog = try Catalog {
      Relation("People", ["Name": .text]) {
        Row("carol")
      }
      try View("Bad", "SELECT Name FROM People ORDER BY NOPE(Name)",
               as: ["Name"])
    }
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, "SELECT * FROM Bad")
    }
  }

  @Test func `columns(of:) accepts an ORDER BY output alias absent as input`() throws {
    // `u` names the `UPPER(Name)` output alias, not an input column; the sort
    // key resolves to the already-validated projection item, so the shape check
    // must NOT re-validate it as an input column (which would fault, there
    // being no `u` column) — it advertises the query, and it runs.
    let catalog = try people()
    let advertised = try columns(catalog, """
        SELECT UPPER(Name) AS u FROM People ORDER BY u
        """)
    #expect(advertised.count == 1)
    try catalog.expect("""
        SELECT UPPER(Name) AS u FROM People ORDER BY u
        """, yields: [["ALICE"], ["BOB"], ["CAROL"], ["DAVE"]])
  }

  // MARK: - A grouped ORDER BY output name type-checks like the run

  // The grouped order lowering (`Grouping.terms`/`Grouping.order`) binds a bare
  // `ORDER BY <name>` to a grouped OUTPUT name — a projected item's
  // `Projected.name` (an alias, else an unaliased group column's own name) —
  // before an input column. The schema/type-check path must resolve the SAME
  // output-name set, so `columns(of:)`/`.schema` accept exactly the grouped
  // `ORDER BY` queries that compile and run.

  @Test func `columns(of:) accepts a grouped ORDER BY an unaliased group column`() throws {
    // The reported case: `a.Name` and `COUNT(*)` force an `expressions`
    // projection, and `a.Name` is a group column with NO explicit alias. The
    // grouped lowering binds `ORDER BY Name` to that group-column OUTPUT (its
    // `Projected.name`), so the run ACCEPTS. Before the fix the schema path
    // treated `Name` as an INPUT column and — both `a` and `b` carrying `Name`
    // — faulted `SQLError.ambiguous`, rejecting a query that runs. It now binds
    // the grouped output too, so `columns(of:)` accepts and the query runs.
    let catalog = try joined()
    let advertised = try columns(catalog, """
        SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
        GROUP BY a.Name ORDER BY Name
        """)
    #expect(advertised.count == 2)
    try catalog.expect("""
        SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
        GROUP BY a.Name ORDER BY Name
        """, yields: [["alice", 1], ["bob", 1], ["carol", 1]])
  }

  @Test func `a view over a grouped ORDER BY group-column body validates`() throws {
    // The same shape as a VIEW body: the schema path reaches into the body's
    // grouped `ORDER BY Name`, binds it to the group-column output as the run
    // does, and advertises a valid schema — no spurious ambiguity fault.
    let catalog = try Catalog {
      Relation("a", ["Id": .integer, "Name": .text]) {
        Row(1, "carol")
        Row(2, "alice")
      }
      Relation("b", ["Id": .integer, "Name": .text]) {
        Row(1, "x")
        Row(2, "y")
      }
      try View("Grouped", """
          SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
          GROUP BY a.Name ORDER BY Name
          """, as: ["Name", "n"])
    }
    let advertised = try columns(catalog, "SELECT * FROM Grouped")
    #expect(advertised.count == 2)
  }

  @Test func `a grouped ORDER BY over an unresolvable name faults in both paths`() throws {
    // Soundness: `Bogus` is neither a grouped output nor a resolvable input
    // column, so it faults consistently — the run rejects it, and the schema
    // path must too (no over-acceptance from the new output-name lookup).
    let catalog = try joined()
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, """
          SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
          GROUP BY a.Name ORDER BY Bogus
          """)
    }
    catalog.expect("""
        SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
        GROUP BY a.Name ORDER BY Bogus
        """, fails: SQLError.column("Bogus"))
  }

  @Test func `a grouped ORDER BY over an ambiguous non-group input still faults`() throws {
    // Soundness: `Id` is a group-column-absent INPUT column both `a` and `b`
    // carry, and no projected output claims the name — so the grouped lowering
    // resolves it as an ambiguous input and faults, and the schema path agrees.
    let catalog = try joined()
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, """
          SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
          GROUP BY a.Name ORDER BY Id
          """)
    }
    catalog.expect("""
        SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
        GROUP BY a.Name ORDER BY Id
        """, fails: SQLError.ambiguous("Id"))
  }

  // MARK: - The sort validates below a row-dropping limit

  // The compiled shape is `Project(Limit(Sort(input)))`: the sort evaluates
  // each ORDER BY key over the input rows BEFORE the cap pages them, so a limit
  // that drops every output row still runs the sort. The static shape check
  // must therefore validate the sort keys — and the projection expressions an
  // ordinal or an output-name key reaches — INDEPENDENT of whether the
  // projection is reachable under the limit.

  @Test func `a zero-row FETCH does not spare a bad ORDER BY expression`() throws {
    // The projection (`Name`) is unreachable under a zero FETCH, but the sort
    // below the limit still evaluates `NOPE(Name)` — an unknown routine — so
    // the shape check must reject the query rather than advertise it then
    // fault at run.
    #expect(throws: SQLError.self) {
      _ = try columns(try people(), """
          SELECT Name FROM People ORDER BY NOPE(Name) FETCH FIRST 0 ROWS ONLY
          """)
    }
  }

  @Test func `a zero-row FETCH does not spare an ORDER BY ordinal's projection term`() throws {
    // The projection block is skipped under a zero FETCH, but `ORDER BY 1`
    // makes the sort recompute the first projection term — `NOPE(Name)`, an
    // unknown routine — below the limit, so the shape check must reject it.
    #expect(throws: SQLError.self) {
      _ = try columns(try people(), """
          SELECT NOPE(Name) FROM People ORDER BY 1 FETCH FIRST 0 ROWS ONLY
          """)
    }
  }

  @Test func `a zero-row FETCH does not spare an ORDER BY alias's projection term`() throws {
    // `n` names the bad `NOPE(Name)` output; the sort recomputes that term
    // below the zero FETCH, so the shape check must reject it even though the
    // projection block is skipped.
    #expect(throws: SQLError.self) {
      _ = try columns(try people(), """
          SELECT NOPE(Name) AS n FROM People ORDER BY n FETCH FIRST 0 ROWS ONLY
          """)
    }
  }

  @Test func `an OFFSET past the sole aggregate row does not spare a bad ORDER BY`() throws {
    // A whole-result aggregate emits ONE row, which a positive OFFSET drops, so
    // the projection is unreachable — but the sort below the limit still
    // evaluates `NOPE(Dept)`, so the shape check must reject the query.
    #expect(throws: SQLError.self) {
      _ = try columns(try sales(), """
          SELECT COUNT(*) FROM Sales ORDER BY NOPE(Dept) OFFSET 1 ROWS
          """)
    }
  }

  @Test func `a zero-row FETCH still spares an unreferenced projection expression`() throws {
    // No ORDER BY, so the sort runs nothing; the projection (`NOPE(Name)`) is
    // unreachable under a zero FETCH and never evaluated — so the shape check
    // must NOT reject it. Fixing the sort-key gap introduces no false positive
    // for a projection term the sort does not reach.
    let advertised = try columns(try people(), """
        SELECT NOPE(Name) FROM People FETCH FIRST 0 ROWS ONLY
        """)
    #expect(advertised.count == 1)
  }

  @Test func `a valid ORDER BY under a zero-row FETCH validates and runs empty`() throws {
    // A valid sort key under a zero FETCH type-checks (the sort runs) and the
    // query runs to its empty page — no false positive, no fault.
    let catalog = try people()
    let advertised = try columns(catalog, """
        SELECT Name FROM People ORDER BY UPPER(Name) FETCH FIRST 0 ROWS ONLY
        """)
    #expect(advertised.count == 1)
    try catalog.expect("""
        SELECT Name FROM People ORDER BY UPPER(Name) FETCH FIRST 0 ROWS ONLY
        """, yields: [])
  }

  @Test func `columns(of:) surfaces a bad ORDER BY under a limit in a view body`() throws {
    // A view whose body drops every row with a zero FETCH but sorts on an
    // unknown routine advertises no valid schema — the shape check reaches
    // the body's sort keys regardless of the limit, faulting where a run would.
    let catalog = try Catalog {
      Relation("People", ["Name": .text]) {
        Row("carol")
      }
      try View("Bad", """
          SELECT Name FROM People ORDER BY NOPE(Name) FETCH FIRST 0 ROWS ONLY
          """, as: ["Name"])
    }
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, "SELECT * FROM Bad")
    }
  }

  // MARK: - The schema path rejects an out-of-range ORDER BY ordinal

  // An `ORDER BY` ordinal names a 1-based SELECT-list position; one outside
  // `1 ... width` names no output column and faults `SQLError.column` (spelled
  // as the ordinal) at run. The static shape check must raise the SAME fault
  // rather than drop the key and advertise a shape for a query that cannot run.

  @Test func `columns(of:) rejects an out-of-range ORDER BY ordinal`() throws {
    // `2` is past the one-column select list; the run faults `SQLError.column`,
    // so the schema path must reject it too — the two paths agree.
    let catalog = try people()
    #expect(throws: SQLError.column("2")) {
      _ = try columns(catalog, "SELECT Name FROM People ORDER BY 2")
    }
    catalog.expect("SELECT Name FROM People ORDER BY 2",
                   fails: SQLError.column("2"))
  }

  @Test func `columns(of:) accepts an in-range ORDER BY ordinal`() throws {
    // `1` names the sole output column, in range; the shape check advertises it
    // and it runs.
    let catalog = try people()
    let advertised = try columns(catalog, "SELECT Name FROM People ORDER BY 1")
    #expect(advertised.count == 1)
    try catalog.expect("SELECT Name FROM People ORDER BY 1",
                       yields: [["alice"], ["bob"], ["carol"], ["dave"]])
  }

  @Test func `columns(of:) rejects a zero or negative ORDER BY ordinal`() throws {
    // `0` (and a parser-forbidden negative, tested via the AST) is below the
    // 1-based range, faulting consistently in both paths as the run does.
    let catalog = try people()
    #expect(throws: SQLError.column("0")) {
      _ = try columns(catalog, "SELECT Name FROM People ORDER BY 0")
    }
    catalog.expect("SELECT Name FROM People ORDER BY 0",
                   fails: SQLError.column("0"))
  }

  @Test func `columns(of:) surfaces an out-of-range ORDER BY ordinal in a view body`() throws {
    // A view whose body's `ORDER BY 2` names a missing output column advertises
    // no valid schema — the shape check reaches the body's sort keys, faulting
    // where a run would.
    let catalog = try Catalog {
      Relation("People", ["Name": .text]) {
        Row("carol")
      }
      try View("Bad", "SELECT Name FROM People ORDER BY 2", as: ["Name"])
    }
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, "SELECT * FROM Bad")
    }
  }

  // MARK: - The schema path enforces GROUP BY rules on ORDER BY expressions

  // A grouped `ORDER BY` sorts in the grouped slot space, so a sort EXPRESSION
  // referencing a resolvable-but-non-grouped column faults `SQLError.grouping`
  // at run (`Grouping.term`). The static shape check validates each grouped
  // sort key through the SAME grouped lowering, so it rejects exactly the keys
  // the run does and admits exactly the ones it does.

  @Test func `columns(of:) rejects a grouped ORDER BY over a non-grouped column`() throws {
    // `b.Id` is a resolvable INPUT column, but neither a `GROUP BY` key nor
    // inside an aggregate, so `ORDER BY b.Id + 1` faults `SQLError.grouping` at
    // run — the schema path validates it through the grouped lowering and agrees.
    let catalog = try joined()
    #expect(throws: SQLError.grouping("Id")) {
      _ = try columns(catalog, """
          SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
          GROUP BY a.Name ORDER BY b.Id + 1
          """)
    }
    catalog.expect("""
        SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
        GROUP BY a.Name ORDER BY b.Id + 1
        """, fails: SQLError.grouping("Id"))
  }

  @Test func `columns(of:) accepts a grouped ORDER BY over a group key or aggregate`() throws {
    // The valid grouped sort keys still validate and run: a group key
    // (`a.Name`), a bare aggregate (`COUNT(*)`), and an expression over an
    // aggregate (`COUNT(*) + 1`) — each admitted by the grouped lowering.
    let catalog = try joined()
    for key in ["a.Name", "COUNT(*)", "COUNT(*) + 1"] {
      let sql = """
          SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
          GROUP BY a.Name ORDER BY \(key)
          """
      let advertised = try columns(catalog, sql)
      #expect(advertised.count == 2)
    }
    try catalog.expect("""
        SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
        GROUP BY a.Name ORDER BY a.Name
        """, yields: [["alice", 1], ["bob", 1], ["carol", 1]])
  }

  @Test func `columns(of:) surfaces a bad grouped ORDER BY expression in a view body`() throws {
    // A view whose grouped body sorts on a non-grouped column advertises no
    // valid schema — the shape check reaches the body's grouped sort keys and
    // faults `SQLError.grouping` where a run would.
    let catalog = try Catalog {
      Relation("a", ["Id": .integer, "Name": .text]) {
        Row(1, "carol")
      }
      Relation("b", ["Id": .integer]) {
        Row(1)
      }
      try View("Bad", """
          SELECT a.Name, COUNT(*) FROM a JOIN b ON a.Id = b.Id \
          GROUP BY a.Name ORDER BY b.Id + 1
          """, as: ["Name", "n"])
    }
    #expect(throws: SQLError.self) {
      _ = try columns(catalog, "SELECT * FROM Bad")
    }
  }
}

// MARK: - Single evaluation of a computed output sort key

/// A shared call counter a stateful routine increments — a tiny
/// `@unchecked Sendable` box over a mutable count, so the non-deterministic
/// `tick()` routine registered against it both yields successive values and
/// records how many times the run invoked it. (`NEXT` is a reserved word —
/// its `FETCH … NEXT` spelling — so the routine is spelled `tick`.) The engine
/// evaluates a query on one thread, so the box needs no lock.
private final class Counter: @unchecked Sendable {
  /// The number of times `next()` has been called.
  private(set) var count = 0

  /// Increments the count and returns the NEXT value — the sequence `1, 2, 3,
  /// …` across successive calls, so a row's yielded value doubles as the
  /// call's order of evaluation.
  func next() -> Int {
    count += 1
    return count
  }
}

/// An `ORDER BY` key naming a COMPUTED select-list output must sort on the SAME
/// value the row returns — the projected expression evaluated ONCE per row.
/// Reusing the projection term as the pre-projection sort key evaluated it
/// twice (once to order, once to project), so a non-deterministic routine
/// sorted on one set of values and returned a second, misordering the result.
struct OrderBySingleEvaluationTests {
  /// A four-row table — enough rows that a per-row `tick()` yields four
  /// distinct values whose order is observable.
  private func table() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
        Row(4)
      }
    }
  }

  @Test func `an ordinal over a stateful output sorts on the returned value`() throws {
    // `tick()` yields 1, 2, 3, 4 across the four rows — computed ONCE per row
    // when the output is materialised below the sort. `ORDER BY 1 DESC` then
    // sorts on those materialised values and returns them in that order:
    // 4, 3, 2, 1. Double-evaluation would sort on the first set (1…4) yet
    // return an independently generated SECOND set (5…8), whose values would
    // NOT be in descending order.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try table().expect("SELECT tick() AS n FROM T ORDER BY 1 DESC",
                       yields: [[4], [3], [2], [1]], routines: routines)
    // Exactly one call per row: the sort no longer recomputes the output.
    #expect(counter.count == 4)
  }

  @Test func `an alias over a stateful output sorts on the returned value`() throws {
    // The alias form of the same query: `ORDER BY n` names the output, which is
    // materialised once, so the returned `n`s are in descending order and the
    // routine is invoked exactly once per row.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try table().expect("SELECT tick() AS n FROM T ORDER BY n DESC",
                       yields: [[4], [3], [2], [1]], routines: routines)
    #expect(counter.count == 4)
  }

  @Test func `a deterministic computed output still orders correctly`() throws {
    // A deterministic computed output (`Id * 10`) orders on exactly the
    // returned value whether or not it is recomputed — the ordinal and alias
    // sort on it descending: 40, 30, 20, 10.
    try table().expect("SELECT Id * 10 AS n FROM T ORDER BY 1 DESC",
                       yields: [[40], [30], [20], [10]])
    try table().expect("SELECT Id * 10 AS n FROM T ORDER BY n DESC",
                       yields: [[40], [30], [20], [10]])
  }

  @Test func `a stateful output under a secondary input key is computed once`() throws {
    // A multi-key sort mixing a materialised output ordinal (primary) and an
    // ordinary INPUT key (`Id`, secondary): the output is still computed once,
    // so the primary key sorts on the returned values (4, 3, 2, 1) and the
    // routine is invoked exactly once per row even though an input key rides
    // alongside it in the materialised sort row.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try table().expect("SELECT tick() AS n FROM T ORDER BY 1 DESC, Id ASC",
                       yields: [[4], [3], [2], [1]], routines: routines)
    #expect(counter.count == 4)
  }

  @Test func `a grouped computed output sorts on the returned aggregate`() throws {
    // The grouped path also materialises a computed output once: order on the
    // aliased `COUNT(*) * 2` output, an ordinal over it — the sort reads the
    // materialised aggregate rather than recomputing the projection term.
    let catalog = try Catalog {
      Relation("G", ["Dept": .text]) {
        Row("a")
        Row("a")
        Row("a")
        Row("b")
        Row("c")
        Row("c")
      }
    }
    // a 3→6, c 2→4, b 1→2, descending on the doubled count.
    try catalog.expect("""
        SELECT Dept, COUNT(*) * 2 AS n FROM G GROUP BY Dept ORDER BY 2 DESC
        """, yields: [["a", 6], ["c", 4], ["b", 2]])
    try catalog.expect("""
        SELECT Dept, COUNT(*) * 2 AS n FROM G GROUP BY Dept ORDER BY n DESC
        """, yields: [["a", 6], ["c", 4], ["b", 2]])
  }
}

/// Only the SORT-referenced outputs are materialised below the sort; every
/// OTHER output is computed by the final projection ABOVE the cap. The whole
/// select list materialised below the sort regressed the `Project(Limit(_))`
/// page — a faulting output an ORDER BY key does NOT name (`1 / 0`) ran for a
/// row the limit was about to drop, so an empty page faulted instead of empty.
struct OrderByLazyProjectionTests {
  @Test func `an unreferenced output does not run for a dropped row`() throws {
    // `x` is the only sort-referenced output, so `1 / 0` is computed by the
    // final projection ABOVE the cap — never for a row the empty page drops.
    // The whole-select-list shape evaluated it below the cap and faulted.
    try people().empty("""
        SELECT Id AS x, 1 / 0 FROM People ORDER BY x FETCH FIRST 0 ROWS ONLY
        """)
  }

  @Test func `an unreferenced output is computed for a surviving row`() throws {
    // A non-empty page: `y` (unreferenced by the sort) computes correctly for
    // each surviving row, so the lazy split still returns the right values.
    try people().expect("SELECT Id AS x, Id * 2 AS y FROM People ORDER BY x",
                        yields: [[1, 2], [2, 4], [3, 6], [4, 8]])
  }

  @Test func `an unreferenced faulting output still faults for a surviving row`() throws {
    // The laziness is a page skip, not a licence to drop a fault: with rows
    // surviving the cap the unreferenced `1 / 0` must still evaluate and fault.
    try people().expect("""
        SELECT Id AS x, 1 / 0 FROM People ORDER BY x FETCH FIRST 2 ROWS ONLY
        """, fails: .divide)
  }
}

/// A grouped `ORDER BY` alias must sort on the projection column the alias
/// NAMES — the column's INDEX — not `firstIndex(of:)` of its term. Two
/// projected items may share one term under distinct aliases (two calls to a
/// `deterministic: false` routine), so a term search collapses to the first
/// column and `ORDER BY <second alias>` misorders on the wrong output.
struct OrderByDuplicateAliasTests {
  /// A three-row table grouping to three singleton groups, so a per-group
  /// `tick()` yields a distinct value the alias order is observable over.
  private func table() throws -> FixtureCatalog {
    try Catalog {
      Relation("G", ["Dept": .text]) {
        Row("a")
        Row("b")
        Row("c")
      }
    }
  }

  @Test func `a grouped ORDER BY the second of two shared-term aliases sorts on it`() throws {
    // Two projections share the term `tick()` under distinct aliases `p`
    // (column 1) and `q` (column 2). `ORDER BY q DESC` must sort on COLUMN 2:
    // the sort-referenced `q` is materialised once per group (1, 2, 3 over the
    // three groups) and ordered DESC, so the returned `q` column descends
    // 3, 2, 1 — the observable proof the sort ran on `q`, not `p`. The
    // `firstIndex(of:)` bug resolved `q` to `p`'s column 1 and would sort/
    // materialise `p` instead, leaving the `q` column NOT descending.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try table().expect("""
        SELECT Dept, tick() AS p, tick() AS q FROM G GROUP BY Dept ORDER BY q DESC
        """, yields: [["c", 4, 3], ["b", 5, 2], ["a", 6, 1]], routines: routines)
  }

  @Test func `a grouped ORDER BY the first of two shared-term aliases sorts on it`() throws {
    // The companion: `ORDER BY p DESC` sorts on COLUMN 1, so the `p` column
    // descends 3, 2, 1 while `q` is computed above. That the DESCENDING column
    // moves with the named alias (2 here, 1 above) is what distinguishes the
    // two — a term search would sort both by column 1, making them identical.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try table().expect("""
        SELECT Dept, tick() AS p, tick() AS q FROM G GROUP BY Dept ORDER BY p DESC
        """, yields: [["c", 3, 4], ["b", 2, 5], ["a", 1, 6]], routines: routines)
  }

  @Test func `a non-grouped ORDER BY the second of two shared-term aliases sorts on it`() throws {
    // The non-grouped path already tracks the matched alias index; confirm it
    // over the same shared-term shape. `ORDER BY q DESC` sorts on column 1 (the
    // second output): `q` is materialised once per row (1, 2, 3, 4 in scan
    // order) and ordered DESC, so the returned `q` column descends 4, 3, 2, 1.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try people().expect("""
        SELECT tick() AS p, tick() AS q FROM People ORDER BY q DESC
        """, yields: [[5, 4], [6, 3], [7, 2], [8, 1]], routines: routines)
  }
}

/// A `SELECT DISTINCT` `ORDER BY` key accepted because its resolved term
/// REPEATS a projected expression (not an alias or ordinal) must sort on that
/// ALREADY-MATERIALISED projected slot — the same value the dedup and the
/// output use — rather than re-evaluating the term. Under DISTINCT the whole
/// projection materialises once below the sort; leaving the key's `column`
/// `nil` appended a fresh hidden column and sorted on a SECOND evaluation, so a
/// stateful key ordered on values the returned column did not carry.
struct OrderByDistinctExpressionTests {
  /// A four-row table whose rows are all distinct, so a per-row `tick()` under
  /// DISTINCT survives the dedup as four rows and its order is observable.
  private func table() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
        Row(4)
      }
    }
  }

  @Test func `a DISTINCT repeated stateful expression sorts on the returned value`() throws {
    // `tick()` is projected AND repeated in the ORDER BY. It is not an alias or
    // an ordinal, so it is admitted by the resolved-term match — and must sort
    // on the projected slot the dedup/output use, materialised ONCE per row (1,
    // 2, 3, 4). `ORDER BY tick() DESC` then returns them descending: 4, 3, 2,
    // 1. Re-evaluating the appended term would sort on an independently
    // generated second set (5…8) while returning the first, misordering the
    // `n` column and doubling the call count.
    let counter = Counter()
    let routines = try Routines()
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    try table().expect("""
        SELECT DISTINCT tick() AS n FROM T ORDER BY tick() DESC
        """, yields: [[4], [3], [2], [1]], routines: routines)
    // Exactly one call per row: the sort reuses the materialised slot rather
    // than re-evaluating the appended term (which would count eight).
    #expect(counter.count == 4)
  }

  @Test func `the alias and ordinal forms agree with the repeated expression`() throws {
    // `ORDER BY n` (alias) and `ORDER BY 1` (ordinal) name the SAME projected
    // slot as the repeated `ORDER BY tick()`, so all three return the stateful
    // values descending and invoke the routine exactly once per row.
    for key in ["tick()", "n", "1"] {
      let counter = Counter()
      let routines = try Routines()
          .registering("tick", returns: .integer, deterministic: false) { _ in
            .integer(counter.next())
          }
      try table().expect("""
          SELECT DISTINCT tick() AS n FROM T ORDER BY \(key) DESC
          """, yields: [[4], [3], [2], [1]], routines: routines)
      #expect(counter.count == 4)
    }
  }

  @Test func `a DISTINCT repeated deterministic expression still orders correctly`() throws {
    // A deterministic repeated expression (`Id * 10`) reuses the projected slot
    // too; the distinct values 10, 20, 30, 40 sort descending regardless of
    // re-evaluation, so the reuse changes the value, not the order.
    try table().expect("""
        SELECT DISTINCT Id * 10 AS n FROM T ORDER BY Id * 10 DESC
        """, yields: [[40], [30], [20], [10]])
  }

  @Test func `a DISTINCT key matching no projected expression still faults`() throws {
    // Soundness: `Id` is not a projected value, so ordering on it under DISTINCT
    // is ill-defined and faults — the resolved-term reuse admits exactly the
    // keys the guard already accepted, no more.
    try table().expect("SELECT DISTINCT Id * 10 FROM T ORDER BY Id",
                       fails: SQLError.distinct("Id"))
  }
}
