// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - NULL tests

private struct Selection: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let text: String
  internal let expected: Array<Array<Value>>

  internal var testDescription: String { name }
}

private let kNullable: Array<Selection> = [
  Selection(name: "IS NULL", text: "SELECT Id FROM Maybe WHERE Note IS NULL",
            expected: [[.integer(2)], [.integer(4)]]),
  Selection(name: "IS NOT NULL",
            text: "SELECT Id FROM Maybe WHERE Note IS NOT NULL",
            expected: [[.integer(1)], [.integer(3)]]),
  Selection(name: "comparison against NULL",
            text: "SELECT Id FROM Maybe WHERE Note = 'alpha'",
            expected: [[.integer(1)]]),
  Selection(name: "NOT of a NULL comparison",
            text: "SELECT Id FROM Maybe WHERE NOT Note = 'alpha'",
            expected: [[.integer(3)]]),
  Selection(name: "NULL projection",
            text: "SELECT Note FROM Maybe WHERE Id = 2", expected: [[.null]]),
  Selection(name: "ascending NULL order",
            text: "SELECT Id FROM Maybe ORDER BY Note ASC",
            expected: [[.integer(2)], [.integer(4)], [.integer(1)],
                       [.integer(3)]]),
  Selection(name: "descending NULL order",
            text: "SELECT Id FROM Maybe ORDER BY Note DESC",
            expected: [[.integer(3)], [.integer(1)], [.integer(2)],
                       [.integer(4)]]),
]

struct EngineNullTests {
  @Test(arguments: kNullable)
  fileprivate func runs(_ test: Selection) throws {
    #expect(try sparse(test.text) == test.expected)
  }

  @Test func `a NULL outer join key matches no inner row`() throws {
    // The child with a NULL foreign key is the outer row; a NULL key equi-joins
    // to nothing, so it contributes no pair — `Parent` is sorted, so the inner
    // is seeked and the NULL key is skipped before probing.
    let rows = try orphans().run(parse("""
        SELECT Child.Name, Parent.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid
        """))
    #expect(rows == [
      [.text("Ann"), .text("Ada")],
      [.text("Bob"), .text("Bee")],
    ])
  }
}

// MARK: - Bound-parameter / correlated-subquery tests

/// Runs `text` against the `family` catalog with the given parameter bindings.
private func boundRun(_ text: String, _ bindings: Bindings)
    throws -> Array<Array<Value>> {
  try family().run(parse(text), Routines(), bindings: bindings)
}

private struct Binding: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let text: String
  internal let bindings: Bindings
  internal let expected: Array<Array<Value>>

  internal var testDescription: String { name }
}

private let kBindings: Array<Binding> = [
  Binding(name: "bound integer",
          text: "SELECT Name FROM Child WHERE Pid = :pid",
          bindings: ["pid": .integer(1)],
          expected: [[.text("Ann")], [.text("Amy")]]),
  Binding(name: "bound text", text: "SELECT Id FROM Parent WHERE Name = :who",
          bindings: ["who": .text("Bee")], expected: [[.integer(2)]]),
  Binding(name: "unbound", text: "SELECT Name FROM Child WHERE Pid = :pid",
          bindings: [:], expected: []),
  Binding(name: "bound conjunction",
          text: "SELECT Name FROM Child WHERE Pid = :pid AND Name = 'Amy'",
          bindings: ["pid": .integer(1)], expected: [[.text("Amy")]]),
  Binding(name: "unbound under NOT",
          text: "SELECT Name FROM Child WHERE NOT Pid = :pid", bindings: [:],
          expected: []),
  Binding(name: "bound under NOT",
          text: "SELECT Name FROM Child WHERE NOT Pid = :pid",
          bindings: ["pid": .integer(1)],
          expected: [[.text("Bob")], [.text("Orphan")]]),
]

struct EngineBoundTests {
  @Test(arguments: kBindings)
  fileprivate func runs(_ test: Binding) throws {
    #expect(try boundRun(test.text, test.bindings) == test.expected)
  }

  @Test func `a correlated section runs a child query per outer row`() throws {
    // The relational shape of a template's nested section: the outer query
    // yields the parents; for each, the child query is re-run with the parent's
    // key bound, producing that parent's children — exactly an interface →
    // methods expansion.
    let catalog = try family()
    let parents = try catalog.run(parse("SELECT Id, Name FROM Parent"))
    let query = try parse("SELECT Name FROM Child WHERE Pid = :pid")

    var sections = Array<(parent: String, children: Array<String>)>()
    for parent in parents {
      let key = parent[0]
      let children = try catalog.run(query, Routines(), bindings: ["pid": key])
      guard case let .text(name) = parent[1] else { continue }
      sections.append((name, children.map { row in
        guard case let .text(child) = row[0] else { return "" }
        return child
      }))
    }

    #expect(sections.count == 3)
    #expect(sections[0].parent == "Ada")
    #expect(sections[0].children == ["Ann", "Amy"])
    #expect(sections[1].parent == "Bee")
    #expect(sections[1].children == ["Bob"])
    #expect(sections[2].parent == "Cid")
    #expect(sections[2].children.isEmpty)
  }

  @Test func `a bound key plans a seek when its value is known`() throws {
    // Parent is sorted on Id; with `:id` bound the planner resolves it and
    // seeks the run rather than scanning and filtering the whole relation.
    let select = try parse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = try family()
    let plan = try catalog.optimise(catalog.compile(select),
                                    ["id": .integer(2)])
    #expect(sought(plan))
    #expect(!filters(plan))
  }

  @Test func `an unbound key cannot seek and scans under the filter`() throws {
    let select = try parse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = try family()
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled, [:])
    #expect(!sought(plan))
    #expect(filters(plan))
  }

  @Test func `a bound key inside a view seeks when its parameter is supplied`() throws {
    // A parameterized view (`… WHERE Id = :id` over sorted Parent): the bound
    // key seeks inside the view's sub-plan rather than scanning it once :id is
    // supplied, so a reusable view is as fast as the inlined query.
    let select = try parse("SELECT Key, Label FROM Picked")
    let catalog = try gallery()
    let plan = try catalog.optimise(catalog.compile(select),
                                    ["id": .integer(2)])
    let sub = try #require(derived(plan))
    #expect(sought(sub))
    #expect(!filters(sub))
  }
}

// MARK: - UNION tests

/// A three-relation catalog for `UNION`: `Lhs` and `Rhs` each hold a single
/// `Tag` text column, sharing the value `shared` so a union across them proves
/// cross-relation dedup; the values are otherwise distinct. `Extra` repeats the
/// `a` already in `Lhs`, so a trailing `UNION ALL Extra` keeps it a second
/// time — proving an inner `UNION`'s dedup survives an outer `UNION ALL`.
///
/// The relations are `Lhs`/`Rhs` rather than `Left`/`Right`, now that the
/// latter are reserved outer-join keywords.
func tags() -> EngineMemory {
  let fields = [EngineField(name: "Tag", type: .text)]
  let left = [
    [.text("a")],
    [.text("shared")],
  ] as Array<Array<Value>>
  let right = [
    [.text("shared")],
    [.text("b")],
  ] as Array<Array<Value>>
  let extra = [
    [.text("a")],
  ] as Array<Array<Value>>
  return EngineMemory([
    "Lhs": FixtureRelation(fields, left),
    "Rhs": FixtureRelation(fields, right),
    "Extra": FixtureRelation(fields, extra),
  ])
}

struct EngineUnionTests {
  @Test func `UNION removes whole-row duplicates, keeping the first occurrence`() throws {
    // People's Age repeats (30 for Alice and Carol, 25 for Bob and Eve); a
    // UNION of the relation with itself collapses every duplicate row.
    let rows = try roster().run(parse("""
        SELECT Age FROM People UNION SELECT Age FROM People
        """))
    #expect(rows == [[.integer(30)], [.integer(25)], [.integer(40)]])
  }

  @Test func `UNION ALL keeps every row of every arm in source order`() throws {
    let rows = try roster().run(parse("""
        SELECT Age FROM People UNION ALL SELECT Age FROM People
        """))
    let ages = [30, 25, 30, 40, 25].map { Value.integer($0) }
    #expect(rows == (ages + ages).map { [$0] })
  }

  @Test func `a UNION across two relations of matching arity merges and dedups`() throws {
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
        """))
    // `shared` appears in both arms but survives once, first occurrence kept.
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a UNION ALL across two relations keeps the shared row twice`() throws {
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs UNION ALL SELECT Tag FROM Rhs
        """))
    #expect(rows == [
      [.text("a")],
      [.text("shared")],
      [.text("shared")],
      [.text("b")],
    ])
  }

  @Test func `an inner UNION dedups before a trailing UNION ALL appends its arm`() throws {
    // (Lhs UNION Rhs) UNION ALL Extra. The inner UNION dedups `shared`
    // across Lhs and Rhs to one row — `a, shared, b` — and the outer UNION
    // ALL then appends Extra's `a` WITHOUT deduplicating, so `a` recurs. A
    // chain flattened to the trailing `all` would instead keep both copies of
    // `shared`; honouring each node's own flag keeps exactly one.
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
          UNION ALL SELECT Tag FROM Extra
        """))
    #expect(rows == [
      [.text("a")],
      [.text("shared")],
      [.text("b")],
      [.text("a")],
    ])
  }

  @Test func `a UNION of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(1, 2)) {
      try roster().run(parse("""
          SELECT Id FROM People UNION SELECT Id, Name FROM People
          """))
    }
  }

  @Test func `a view defined as a UNION resolves and queries`() throws {
    let both = try View(query: select("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
        """), columns: ["Tag"])
    let catalog = EngineMemory(tags().catalog, views: ["Both": both])
    let rows = try catalog.run(parse("SELECT Tag FROM Both"))
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `an all-NULL view column unifies with a later text arm`() throws {
    // The reviewer's VIEW all-NULL case. The view `v`'s column `x` is a constant
    // NULL in BOTH arms, so its resolved schema marks the column UNCONSTRAINED:
    // an enclosing `SELECT x FROM v UNION SELECT 'c'` must unify the view column
    // with the text `'c'` arm and RUN — yielding the NULL and the text — rather
    // than fault integer against text. The view's schema resolution builds its
    // Schema from the body carrier through `Schema(from:)`, so the `Scope`
    // reader reports the column unconstrained and the outer fold skips its type,
    // exactly as it skips a fresh constant-NULL arm.
    let view = try View(query: select("""
        SELECT NULLIF(1, 1) AS x UNION SELECT NULLIF('b', 'b')
        """), columns: ["x"])
    let catalog = EngineMemory(tags().catalog, views: ["V": view])
    let rows = try catalog.run(parse("SELECT x FROM V UNION SELECT 'c'"))
    #expect(rows == [[.null], [.text("c")]])
  }

  @Test func `a predicate over a widened UNION view column tests the coerced type`() throws {
    // The reviewer's precision oracle. The view `V(x)` is `SELECT x FROM A
    // UNION ALL SELECT x FROM B`, where `A.x` is the integer 9007199254740993
    // and `B.x` is the double 9007199254740992.0. The set operation WIDENS `x`
    // to `double` (an integer arm beside a double arm), so `combine` coerces
    // the integer arm's row to double — and 9007199254740993 is NOT
    // representable as a double, rounding to 9007199254740992.0. An outer
    // `SELECT x FROM V WHERE x = 9007199254740992` must test the COERCED value:
    // the integer arm's row becomes 9007199254740992.0, which `== 9007..92`, so
    // BOTH rows survive. Were the predicate pushed PER ARM below the widening
    // set operation, the integer arm would test 9007199254740993 == ..92
    // exactly (the pre-coercion value) and DROP its row, yielding one — the
    // unsound behaviour the `widened` gate now prevents by keeping the
    // predicate above the arms, on the coerced output.
    let integers = [EngineField(name: "x", type: .integer)]
    let doubles = [EngineField(name: "x", type: .double)]
    let a = [[Value.integer(9007199254740993)]]
    let b = [[Value.double(9007199254740992.0)]]
    let base = EngineMemory([
      "A": FixtureRelation(integers, a),
      "B": FixtureRelation(doubles, b),
    ])
    let view = try View(query: select("""
        SELECT x FROM A UNION ALL SELECT x FROM B
        """), columns: ["x"])
    let memory = EngineMemory(base.catalog, views: ["V": view])
    let rows = try memory.run(parse("""
        SELECT x FROM V WHERE x = 9007199254740992
        """))
    #expect(rows == [[.double(9007199254740992.0)],
                     [.double(9007199254740992.0)]])
  }

  @Test func `a bound parameter threads into every arm of a UNION`() throws {
    // Both arms key on the same `:pid`; the binding reaches each alike, so the
    // union is the parent's children drawn from two queries over the relation.
    let rows = try family().run(parse("""
        SELECT Name FROM Child WHERE Pid = :pid
          UNION ALL SELECT Name FROM Child WHERE Pid = :pid
        """), Routines(), bindings: ["pid": .integer(1)])
    #expect(rows == [
      [.text("Ann")],
      [.text("Amy")],
      [.text("Ann")],
      [.text("Amy")],
    ])
  }
}

// MARK: - INTERSECT / EXCEPT tests

/// A two-relation catalog for `INTERSECT`/`EXCEPT` multiplicity: `A` and `B`
/// each hold a single integer `N`, with duplicates chosen so the operators'
/// `ALL` counts differ from their distinct forms. `A` holds `1` twice, `2`
/// thrice, `3` once and `4` once; `B` holds `2` twice, `3` once, `5` once. Thus
/// `2` and `3` are common (with differing multiplicities), `1`/`4` are A-only,
/// and `5` is B-only — enough to exercise `min` (INTERSECT ALL) and the floored
/// difference (EXCEPT ALL).
private func multiset() -> EngineMemory {
  let fields = [EngineField(name: "N", type: .integer)]
  let a = [1, 1, 2, 2, 2, 3, 4].map { [Value.integer($0)] }
  let b = [2, 2, 3, 5].map { [Value.integer($0)] }
  return EngineMemory([
    "A": FixtureRelation(fields, a),
    "B": FixtureRelation(fields, b),
  ])
}

struct EngineIntersectExceptTests {
  @Test func `INTERSECT keeps the distinct rows present in both arms`() throws {
    // `2` and `3` occur in both A and B; the distinct INTERSECT keeps each
    // once, in A's (left) order, and drops A-only `1`/`4` and B-only `5`.
    let rows = try multiset().run(parse("""
        SELECT N FROM A INTERSECT SELECT N FROM B
        """))
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `INTERSECT ALL keeps each common row to the lesser multiplicity`() throws {
    // A holds `2` thrice and B twice, so INTERSECT ALL keeps `min(3, 2)` = two;
    // `3` is once in each, so one — every occurrence in A's order.
    let rows = try multiset().run(parse("""
        SELECT N FROM A INTERSECT ALL SELECT N FROM B
        """))
    #expect(rows == [[.integer(2)], [.integer(2)], [.integer(3)]])
  }

  @Test func `EXCEPT keeps the distinct left rows absent from the right`() throws {
    // A's distinct rows not in B are `1` and `4`; `2`/`3` are removed (present
    // in B), first occurrence order preserved.
    let rows = try multiset().run(parse("""
        SELECT N FROM A EXCEPT SELECT N FROM B
        """))
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }

  @Test func `EXCEPT ALL removes one left row per matching right row`() throws {
    // A: 1,1,2,2,2,3,4. B removes one `2` per its two copies (leaving one `2`)
    // and its one `3` (leaving none); `1` (twice) and `4` are untouched — every
    // survivor in A's order.
    let rows = try multiset().run(parse("""
        SELECT N FROM A EXCEPT ALL SELECT N FROM B
        """))
    #expect(rows == [
      [.integer(1)],
      [.integer(1)],
      [.integer(2)],
      [.integer(4)],
    ])
  }

  @Test func `INTERSECT binds tighter than UNION`() throws {
    // `A UNION B INTERSECT C` is `A UNION (B INTERSECT C)` per ISO precedence.
    // Here the reused `tags()` relations give `B INTERSECT C` = `Rhs INTERSECT
    // Extra`: Rhs is {shared, b}, Extra is {a}, so the intersection is empty
    // and the whole result is just Lhs's distinct rows.
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs
          UNION SELECT Tag FROM Rhs
          INTERSECT SELECT Tag FROM Extra
        """))
    #expect(rows == [[.text("a")], [.text("shared")]])
  }

  @Test func `UNION and EXCEPT are same precedence, left-associative`() throws {
    // `A UNION B EXCEPT C` binds as `(A UNION B) EXCEPT C`. Lhs UNION Rhs is
    // {a, shared, b}; EXCEPT Extra ({a}) removes `a`, leaving {shared, b}. A
    // right-associative reading — `A UNION (B EXCEPT C)` — would instead keep
    // `a` (from Lhs), so the result proves the left grouping.
    let rows = try tags().run(parse("""
        SELECT Tag FROM Lhs
          UNION SELECT Tag FROM Rhs
          EXCEPT SELECT Tag FROM Extra
        """))
    #expect(rows == [[.text("shared")], [.text("b")]])
  }

  @Test func `INTERSECT of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(1, 2)) {
      try roster().run(parse("""
          SELECT Id FROM People INTERSECT SELECT Id, Name FROM People
          """))
    }
  }

  @Test func `EXCEPT of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(2, 1)) {
      try roster().run(parse("""
          SELECT Id, Name FROM People EXCEPT SELECT Id FROM People
          """))
    }
  }

  @Test func `a view defined as an EXCEPT resolves and queries`() throws {
    let diff = try View(query: select("""
        SELECT N FROM A EXCEPT SELECT N FROM B
        """), columns: ["N"])
    let catalog = EngineMemory(multiset().catalog, views: ["Diff": diff])
    let rows = try catalog.run(parse("SELECT N FROM Diff"))
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }
}

// MARK: - DISTINCT tests

struct EngineDistinctTests {
  @Test func `DISTINCT removes duplicate rows, keeping the first occurrence`() throws {
    // People's Age repeats (30 for Alice and Carol, 25 for Bob and Eve);
    // DISTINCT collapses each duplicate to its first appearance, in row order.
    try roster().expect("SELECT DISTINCT Age FROM People",
                        yields: [[30], [25], [40]])
  }

  @Test func `a plain SELECT keeps every duplicate row`() throws {
    try roster().expect("SELECT Age FROM People",
                        yields: [[30], [25], [30], [40], [25]])
  }

  @Test func `SELECT ALL is the plain, non-deduplicating select`() throws {
    try roster().expect("SELECT ALL Age FROM People",
                        yields: [[30], [25], [30], [40], [25]])
  }

  @Test func `DISTINCT dedups on the whole projected row, not one column`() throws {
    // Grade's (Class, Score) pairs repeat — (A, 80) three times, (B, 90)
    // twice — while a single column would over-collapse. DISTINCT keeps one of
    // each distinct pair, first occurrence in row order.
    try grades().expect("SELECT DISTINCT Class, Score FROM Grade",
                        yields: [["B", 90], ["A", 80], ["A", 70]])
  }

  @Test func `DISTINCT dedups rows a projection maps together`() throws {
    // Bob (25) and Eve (25), Alice (30) and Carol (30) share an Age; projecting
    // Age alone collapses each pair even though their other columns differ.
    try roster().expect("SELECT DISTINCT Age FROM People WHERE Age < 40",
                        yields: [[30], [25]])
  }

  @Test func `DISTINCT binds to its own arm within a UNION ALL`() throws {
    // DISTINCT is a per-SELECT quantifier: it dedups the LEFT arm alone (its
    // repeated Ages collapse to 30, 25, 40), then the UNION ALL appends the
    // right arm's rows without deduplicating across the arms.
    try roster().expect("""
        SELECT DISTINCT Age FROM People
          UNION ALL SELECT Age FROM People WHERE Id = 1
        """, yields: [[30], [25], [40], [30]])
  }

  @Test func `DISTINCT combines with ORDER BY, ordering the deduplicated rows`() throws {
    // The distinct Ages, then ascending: dedup keeps 30, 25, 40; ORDER BY sorts
    // them 25, 30, 40.
    try roster().expect("SELECT DISTINCT Age FROM People ORDER BY Age",
                        yields: [[25], [30], [40]])
  }

  @Test func `DISTINCT dedups before OFFSET/FETCH pages the result`() throws {
    // Three distinct Ages ordered 25, 30, 40; FETCH FIRST 2 pages the
    // deduplicated, ordered rows — proving the cap sits above the dedup.
    try roster().expect("""
        SELECT DISTINCT Age FROM People ORDER BY Age FETCH FIRST 2 ROWS ONLY
        """, yields: [[25], [30]])
  }

  @Test func `DISTINCT over an aggregate dedups the grouped rows`() throws {
    // Grouping People by Age yields one row per distinct Age (25, 30, 40), each
    // with its COUNT; projecting only the COUNT leaves 2, 2, 1 — DISTINCT then
    // collapses the two 2s to one.
    try roster().expect("""
        SELECT DISTINCT COUNT(*) FROM People GROUP BY Age
        """, yields: [[2], [1]])
  }

  @Test func `a view defined with DISTINCT deduplicates when queried`() throws {
    let ages = try View(query: select("SELECT DISTINCT Age FROM People"),
                        columns: ["Age"])
    let catalog = EngineMemory(try roster().catalog, views: ["Ages": ages])
    try catalog.expect("SELECT Age FROM Ages", yields: [[30], [25], [40]])
  }

  @Test func `DISTINCT ordering on a non-projected column faults`() throws {
    // Name is not in the DISTINCT output, so after dedup each Age stands for
    // several Names — the order is ill-defined; the standard rejects it.
    try roster().expect("SELECT DISTINCT Age FROM People ORDER BY Name",
                        fails: .distinct("Name"))
  }

  @Test func `DISTINCT ordering on a projected column pages correctly`() throws {
    // Age is a select-list column, so ordering (and paging) on it is well
    // defined: the deduplicated Ages sort 25, 30, 40, and OFFSET 1 drops the
    // first.
    try roster().expect("""
        SELECT DISTINCT Age FROM People ORDER BY Age
          OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY
        """, yields: [[30], [40]])
  }

  @Test func `DISTINCT over a join rejects a hidden ORDER BY key`() throws {
    // Child.Name is not projected, so ordering the deduplicated Parent.Name
    // rows on it is ill-defined across the two joined relations.
    try family().expect("""
        SELECT DISTINCT Parent.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id ORDER BY Child.Name
        """, fails: .distinct("Name"))
  }

  @Test func `SS005 is the DISTINCT ORDER BY SQLSTATE`() {
    #expect(SQLError.distinct("Name").sqlstate == "SS005")
  }

  @Test func `grouped DISTINCT rejects ordering on a non-output GROUP BY key`() throws {
    // The output is only COUNT(*); Age is the grouping key but not projected,
    // so ordering (and paging) on it after dedup is ill-defined — the same rule
    // the non-aggregate path enforces, in grouped-slot space.
    try roster().expect("""
        SELECT DISTINCT COUNT(*) FROM People GROUP BY Age ORDER BY Age
        """, fails: .distinct("Age"))
  }

  @Test func `grouped DISTINCT orders on a projected aggregate alias`() throws {
    // The counts per Age are 2, 2, 1; DISTINCT collapses the two 2s, leaving
    // {1, 2}. Ordering on the projected alias `c` is well defined — ascending
    // yields 1, 2.
    try roster().expect("""
        SELECT DISTINCT COUNT(*) AS c FROM People GROUP BY Age ORDER BY c
        """, yields: [[1], [2]])
  }
}

// MARK: - Arithmetic tests

struct EngineArithmeticTests {
  @Test func `literal arithmetic evaluates over a row`() throws {
    // One row of `People` drives the projection; the value is the same for each,
    // and `Id = 1` selects exactly one.
    try roster().expect("SELECT 2 + 3 FROM People WHERE Id = 1", yields: [[5]])
  }

  @Test func `multiplication binds tighter than addition`() throws {
    try roster().expect("SELECT 2 + 3 * 4 FROM People WHERE Id = 1",
                        yields: [[14]])
  }

  @Test func `parentheses override precedence`() throws {
    try roster().expect("SELECT (2 + 3) * 4 FROM People WHERE Id = 1",
                        yields: [[20]])
  }

  @Test func `subtraction and division are left-associative`() throws {
    // (20 - 5) - 3 = 12, not 20 - (5 - 3) = 18; (100 / 5) / 2 = 10.
    let difference = try answer("SELECT 20 - 5 - 3 FROM People WHERE Id = 1")
    #expect(difference == [[.integer(12)]])
    let quotient = try answer("SELECT 100 / 5 / 2 FROM People WHERE Id = 1")
    #expect(quotient == [[.integer(10)]])
  }

  @Test func `integer division truncates`() throws {
    try roster().expect("SELECT 7 / 2 FROM People WHERE Id = 1", yields: [[3]])
  }

  @Test func `arithmetic over a column computes per row`() throws {
    let rows = try answer("SELECT Age + 1 FROM People WHERE Id = 2")
    // Bob's Age is 25; 25 + 1 = 26.
    #expect(rows == [[.integer(26)]])
  }

  @Test func `arithmetic mixes columns and a function call`() throws {
    let rows = try functions("SELECT add(Id, 1) * 10 FROM People WHERE Id = 3")
    // Carol: (3 + 1) * 10 = 40.
    #expect(rows == [[.integer(40)]])
  }

  @Test func `a NULL operand propagates to a NULL result`() throws {
    // `Note` is NULL for row 2; `Id + Note` mixes a present integer with a NULL,
    // so the whole expression is NULL rather than a fault.
    try sparse().expect("SELECT Id + Note FROM Maybe WHERE Id = 2",
                          yields: [[nil]])
  }

  @Test func `division by zero faults`() throws {
    #expect(throws: SQLError.divide) {
      try answer("SELECT Id / 0 FROM People WHERE Id = 1")
    }
  }

  @Test func `arithmetic overflow faults instead of trapping`() throws {
    // `Int.max + 1` and a multiply past the boundary report overflow as a
    // `SQLError` rather than trapping (and aborting) the process.
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try answer("SELECT 9223372036854775807 + 1 FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try answer("SELECT 9223372036854775807 * 2 FROM People WHERE Id = 1")
    }
  }

  @Test func `a parenthesised expression opens a predicate`() throws {
    // `(Age + 1)` is the grouped left operand of the comparison, not a predicate
    // group; it matches Dave (40 + 1 = 41). A leading `(` no longer forces a
    // predicate-group parse.
    let matched = try answer("SELECT Id FROM People WHERE (Age + 1) = 41")
    #expect(matched == [[.integer(4)]])
    // A grouped expression works before `IS NULL` too; `Id + 1` is never NULL.
    let none = try answer("SELECT Id FROM People WHERE (Id + 1) IS NULL")
    #expect(none.isEmpty)
  }

  @Test func `a text operand faults as a type error`() throws {
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try answer("SELECT Name + 1 FROM People WHERE Id = 1")
    }
  }

  @Test func `arithmetic in a predicate filters rows`() throws {
    // `Age + 1 = 26` holds for everyone aged 25 (Bob and Eve); the arithmetic
    // is evaluated per row on the WHERE side too.
    try roster().expect("SELECT Name FROM People WHERE Age + 1 = 26",
                        yields: [["Bob"], ["Eve"]])
  }
}

// MARK: - Scalar (FROM-less) SELECT tests

struct EngineScalarSelectTests {
  @Test func `a FROM-less literal yields exactly one row`() throws {
    // No relation, so the projection runs against a single empty row; the
    // catalog is never consulted for a table.
    try roster().expect("SELECT 42", yields: [[42]])
  }

  @Test func `a FROM-less arithmetic computes a scalar`() throws {
    try roster().expect("SELECT 1 + 1", yields: [[2]])
  }

  @Test func `FROM-less arithmetic honours precedence`() throws {
    try roster().expect("SELECT 2 + 3 * 4", yields: [[14]])
  }

  @Test func `a FROM-less multi-column projection yields one row of each value`() throws {
    try roster().expect("SELECT 1, 2, 3", yields: [[1, 2, 3]])
  }

  @Test func `a FROM-less projection mixes text and integer expressions`() throws {
    try roster().expect("SELECT 'x', 10 / 2", yields: [["x", 5]])
  }

  @Test func `a FROM-less scalar call evaluates against the single row`() throws {
    let rows = try functions("SELECT add(40, 2)")
    #expect(rows == [[.integer(42)]])
  }

  @Test func `a boolean literal lowers to its truth value`() throws {
    try roster().expect("SELECT TRUE, FALSE", yields: [[true, false]])
  }

  @Test func `a hex blob literal lowers to its bytes`() throws {
    // The `x'53514c'` literal lexes, parses, and lowers to the three-byte
    // blob `SQL`, projected as a `Value.blob`.
    try roster().expect("SELECT x'53514c'",
                        yields: [[[0x53, 0x51, 0x4c] as Array<UInt8>]])
  }

  @Test func `a boolean operand faults as a non-numeric type error`() throws {
    // Neither boolean nor blob is numeric, so arithmetic over either faults
    // exactly as text does — the type-checker rejects any non-numeric operand.
    try roster().expect("SELECT TRUE + 1",
                        fails: .operand("operands must be numeric"))
  }

  @Test func `a blob operand faults as a non-numeric type error`() throws {
    try roster().expect("SELECT x'00' + 1",
                        fails: .operand("operands must be numeric"))
  }

  @Test func `a NULL-yielding FROM-less expression projects NULL`() throws {
    // The bare literal NULL is not in the grammar, but a NULL arises from a
    // function returning it; `nothing` yields NULL for the single row.
    let routines: Routines =
        ["nothing": Routine(parameters: []) { _ in .null }]
    let rows = try roster().run(parse("SELECT nothing()"), routines)
    #expect(rows == [[.null]])
  }

  @Test func `a FROM-less SELECT * is rejected — no relation to expand`() throws {
    #expect(throws: SQLError.unsupported("SELECT * requires a FROM clause")) {
      try answer("SELECT *")
    }
  }

  @Test func `a FROM-less bare column is rejected — no column to bind`() throws {
    try roster().expect("SELECT Name", fails: .column("Name"))
  }

  @Test func `a directly-built FROM-less select with clauses is rejected`() throws {
    // The parser never builds a FROM-less select carrying a WHERE, GROUP BY,
    // HAVING, ORDER BY, OFFSET/FETCH, or JOIN, but a direct `Select(from: nil,
    // …)` can. The engine rejects it rather than silently drop the clause — a
    // false predicate or HAVING would otherwise still return the scalar row.
    let fault =
        SQLError.unsupported(
            "a WHERE, GROUP BY, HAVING, ORDER BY, OFFSET/FETCH, or JOIN " +
            "requires a FROM clause")
    let filtered = try EngineScalarSelectTests.select(
        "SELECT 1 FROM People WHERE Id = 99")
    #expect(throws: fault) {
      try roster().run(.select(Select(projection: filtered.projection,
                                    from: nil,
                                    predicate: filtered.predicate)))
    }
    let grouped = try EngineScalarSelectTests.select(
        "SELECT Id FROM People GROUP BY Id")
    #expect(throws: fault) {
      try roster().run(.select(Select(projection: grouped.projection, from: nil,
                                    grouping: grouped.grouping)))
    }
    let filteredGroup = try EngineScalarSelectTests.select(
        "SELECT Id FROM People GROUP BY Id HAVING COUNT(*) > 0")
    #expect(throws: fault) {
      try roster().run(.select(Select(projection: filteredGroup.projection,
                                    from: nil,
                                    having: filteredGroup.having)))
    }
    let ordered =
        try EngineScalarSelectTests.select("SELECT Id FROM People ORDER BY Id")
    #expect(throws: fault) {
      try roster().run(.select(Select(projection: ordered.projection, from: nil,
                                    order: ordered.order)))
    }
    let limited = try EngineScalarSelectTests.select(
        "SELECT Id FROM People FETCH FIRST 1 ROW ONLY")
    #expect(throws: fault) {
      try roster().run(.select(Select(projection: limited.projection, from: nil,
                                    limit: limited.limit)))
    }
    let joined = try EngineScalarSelectTests.select(
        "SELECT Id FROM People JOIN Pets ON Pets.Owner = People.Id")
    #expect(throws: fault) {
      try roster().run(.select(Select(projection: joined.projection, from: nil,
                                    joins: joined.joins)))
    }
  }

  /// The `Select` of a parsed single-`SELECT` query — for building the FROM-less
  /// shapes the parser will not, by re-homing a clause onto a `from: nil` select.
  private static func select(_ text: String) throws -> Select {
    guard case let .select(select) = try parse(text) else {
      throw SQLError.incomplete(expected: "a SELECT")
    }
    return select
  }

  @Test func `a FROM-less arm of a UNION combines with a FROM arm`() throws {
    // Both arms project one integer column; the FROM-less arm contributes its
    // single computed row, deduplicating against the People ages.
    let rows = try roster().run(parse("""
        SELECT 100 UNION ALL SELECT Age FROM People WHERE Id = 1
        """))
    #expect(rows == [[.integer(100)], [.integer(30)]])
  }

  @Test func `an existing SELECT … FROM … query is unaffected`() throws {
    // The FROM-optional grammar leaves a normal query parsing and running
    // exactly as before.
    try roster().expect("SELECT Name FROM People WHERE Id = 1",
                        yields: [["Alice"]])
  }
}

// MARK: - ISO set-operation type unification and value coercion tests

/// Parses `text` to a statement and runs it against `catalog` — for the `WITH`
/// shapes the query-only `run` overload will not take.
private func statement<C: Catalog & ~Escapable>(_ text: String,
                                                _ catalog: borrowing C)
    throws -> Array<Array<Value>> {
  try catalog.run(Statement(parsing: text))
}

/// The ISO rule that a set operation's result column TYPE is the common type
/// across ALL arms — not the first arm's — and each arm's values are COERCED to
/// it: a mixed `integer`/`double` column widens to `double` and its integer
/// values promote, an irreconcilable pair faults, and a constant-NULL arm
/// constrains nothing. Homogeneous set operations are unchanged
/// (byte-identical).
struct EngineSetOperationCoercionTests {
  @Test func `UNION widens a mixed integer/double column and coerces its values`() throws {
    // The unified column type is `double`, so the `integer` arm's `1` coerces
    // to `1.0` and the result column is `double` throughout.
    try roster().expect("SELECT 1 UNION SELECT 2.5",
                              yields: [[1.0], [2.5]])
    try roster().expect("SELECT 1 UNION ALL SELECT 2.5",
                              yields: [[1.0], [2.5]])
  }

  @Test func `UNION dedups numerically-equal rows to the coerced double`() throws {
    // `1` coerces to `1.0`, equal to the double arm's `1.0`, so the bare UNION
    // keeps one — the emitted `double`.
    try roster().expect("SELECT 1 UNION SELECT 1.0", yields: [[1.0]])
  }

  @Test func `INTERSECT and EXCEPT emit the coerced double`() throws {
    // Equality already canonicalises `1` and `1.0`, so both match/subtract; the
    // coercion makes the EMITTED cell carry the unified `double` type.
    try roster().expect("SELECT 1 INTERSECT SELECT 1.0", yields: [[1.0]])
    try roster().expect("SELECT 2 EXCEPT SELECT 1.0", yields: [[2.0]])
  }

  @Test func `a UNION of irreconcilable column types faults`() throws {
    // A text arm beside a number, or a boolean beside a number, has no common
    // type — the fold faults `SQLError.operand` (SQLSTATE 42804).
    try roster().expect(
        "SELECT 1 UNION SELECT 'x'",
        fails: .operand("UNION arms have irreconcilable types"))
    try roster().expect(
        "SELECT TRUE UNION SELECT 1",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a nested-arm UNION arity mismatch faults not traps`() throws {
    // The outer widths match (both 2), so the outer check passes; the fold
    // then descends into the left child `SELECT 1, 2 UNION SELECT 3` whose
    // arms differ (2 vs 1) — the fold's own guard faults `.arity` rather than
    // trapping on an out-of-bounds column index.
    try roster().expect("SELECT 1, 2 UNION SELECT 3 UNION SELECT 4, 5",
                              fails: .arity(2, 1))
  }

  @Test func `a chained 3-arm UNION widens across every arm`() throws {
    // The left-associative chain folds pairwise, so the trailing `double`
    // widens the whole column and every value coerces.
    try roster().expect("SELECT 1 UNION SELECT 2 UNION SELECT 3.5",
                              yields: [[1.0], [2.0], [3.5]])
  }

  @Test func `a chained UNION with an incompatible tail faults`() throws {
    try roster().expect(
        "SELECT 1 UNION SELECT 2 UNION SELECT 'x'",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a UNION nested in a subquery carries its coerced types`() throws {
    // The derived table runs through the `.setop` Plan node, whose carried
    // `types` (computed at compile) coerce each arm's rows — the outer
    // `SELECT *` reads the widened `double` column.
    try roster().expect("SELECT * FROM (SELECT 1 UNION SELECT 2.5) AS d",
                              yields: [[1.0], [2.5]])
  }

  @Test func `a column list over a UNION body renames the widened column`()
      throws {
    // The crossover of the two ISO features: the `.setop` Plan node's carried
    // `types` coerce the mixed integer/double arms to a `double` column (set-op
    // unification), and the `AS d(a)` list renames that column `a` (the
    // explicit output column list). Selecting `d.a` reads the widened, coerced
    // values under the list's name — the two features COMPOSE.
    try roster().expect(
        "SELECT d.a FROM (SELECT 1 UNION SELECT 2.5) AS d(a) ORDER BY d.a",
        yields: [[1.0], [2.5]])
  }

  @Test func `a constant-NULL arm does not veto the widening`() throws {
    // A `NULLIF(2, 2)` arm folds to constant NULL, so it constrains nothing (a
    // NULL unifies with any typed arm): the OTHER arm's `double` types the
    // column, its NULL row stays NULL and the double row coerces.
    try roster().expect("SELECT NULLIF(2, 2) UNION SELECT 2.5",
                              yields: [[nil], [2.5]])
    // A typed integer arm beside a constant-NULL arm keeps the `integer`
    // column.
    try roster().expect("SELECT 1 UNION SELECT NULLIF(2, 2)",
                              yields: [[1], [nil]])
  }

  @Test func `a recursive CTE widens an integer anchor to a double arm`() throws {
    // The anchor is `integer` and the recursive arm `double`; the unified
    // column is `double`, so the anchor's `1` coerces to `1.0` and every
    // iteration's value carries the widened type (v1b — the fixpoint coerces
    // its rows).
    let rows = try statement("""
        WITH RECURSIVE t (n) AS (
          SELECT 1 UNION ALL SELECT n + 0.5 FROM t WHERE n < 3
        ) SELECT n FROM t
        """, roster())
    #expect(rows == [[.double(1.0)], [.double(1.5)], [.double(2.0)],
                     [.double(2.5)], [.double(3.0)]])
  }

  @Test func `a homogeneous UNION is byte-identical (no coercion)`() throws {
    // Every arm the same type — the coercion is a no-op, so the result is
    // exactly what the pre-unification engine produced.
    try roster().expect(
        "SELECT Age FROM People UNION SELECT Age FROM People",
        yields: [[30], [25], [40]])
  }

  @Test func `a homogeneous INTERSECT/EXCEPT is byte-identical`() throws {
    try roster().expect(
        "SELECT Age FROM People INTERSECT SELECT Age FROM People",
        yields: [[30], [25], [40]])
    try roster().empty(
        "SELECT Age FROM People EXCEPT SELECT Age FROM People")
  }
}

// MARK: - Correlated / lateral all-NULL column mask unification

/// A column reference resolves its TYPE and its `unconstrained` mask from ONE
/// resolution over the SAME paths — local, correlation, schema — so a
/// correlated all-NULL column (referenced through a LATERAL body) keeps its
/// mask and unifies with a typed set-operation arm, rather than losing the mask
/// through the correlation surface and folding as a concrete type. The mask
/// reader once walked a LOCAL-only path while the type reader was
/// correlation-aware, so a correlated all-NULL column dropped its mask; the
/// read-side unification closes that gap. A GENUINELY-typed correlated column
/// stays concrete (no over-marking), and a barred ORDINARY subquery projection
/// still faults, so the unification widens nothing.
struct EngineCorrelatedNullUnificationTests {
  @Test func `a correlated all-NULL column unifies through a LATERAL set-op arm`()
      throws {
    // The reviewer's case. `t`'s column `x` is a constant NULL in BOTH arms, so
    // it is UNCONSTRAINED. The lateral body `SELECT x UNION SELECT 'c'`
    // references the correlated `x`, whose mask must survive the correlation
    // surface so the arm is unconstrained and unifies with the text `'c'` — the
    // body yields the NULL row and the `'c'` row. Before the read-side
    // unification the mask was read LOCAL-only, so the correlated `x` folded as
    // a concrete integer and the arm faulted int-vs-text.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('a', 'a'))
          SELECT y FROM t
          JOIN LATERAL (SELECT x UNION SELECT 'c') AS d (y) ON 1 = 1
        """, family())
    #expect(rows == [[.null], [.text("c")]])
  }

  @Test func `a grandparent all-NULL column unifies through a nested LATERAL arm`()
      throws {
    // The correlation crosses TWO lateral levels: `x` (from `t`) is read in the
    // INNERMOST lateral body's set-op arm, which correlates to a scope two
    // enclosing levels up. The nearest-first `Outer` walk must carry `x`'s
    // unconstrained mask up from that grandparent scope, so the innermost arm
    // still unifies the NULL with the text `'c'`.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('a', 'a'))
          SELECT z FROM t
          JOIN LATERAL (
            SELECT y FROM (SELECT 1 AS one) AS u
            JOIN LATERAL (SELECT x UNION SELECT 'c') AS d (y) ON 1 = 1
          ) AS e (z) ON 1 = 1
        """, family())
    #expect(rows == [[.null], [.text("c")]])
  }

  @Test func `a genuinely-typed correlated column in a LATERAL arm stays concrete`()
      throws {
    // The over-marking guard: `t`'s column `x` is a CONCRETE integer (a plain
    // `SELECT 1`), so the correlated reference must NOT be marked
    // unconstrained — the lateral arm `SELECT x UNION SELECT 'c'` then folds a
    // genuine integer against text and faults `.operand` (SQLSTATE 42804),
    // exactly as an irreconcilable local pair does. This proves the mask is
    // not spuriously set for every correlated column.
    #expect(throws: SQLError.operand("UNION arms have irreconcilable types")) {
      _ = try statement("""
          WITH t (x) AS (SELECT 1)
            SELECT y FROM t
            JOIN LATERAL (SELECT x UNION SELECT 'c') AS d (y) ON 1 = 1
          """, family())
    }
  }

  @Test func `a local all-NULL column still unifies with a text arm`() throws {
    // The local (non-correlated) all-NULL regression: `x` resolves through the
    // LOCAL path, whose resolved lookup carries the same mask, so a bare
    // reference in a set-op arm unifies with the text arm and runs.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('a', 'a'))
          SELECT x FROM t UNION SELECT 'c'
        """, family())
    #expect(rows == [[.null], [.text("c")]])
  }

  @Test func `a homogeneous UNION still runs unchanged`() throws {
    // The unification is a no-op for a genuinely-typed homogeneous set
    // operation — the result is exactly what the pre-unification engine
    // produced.
    try roster().expect(
        "SELECT Age FROM People UNION SELECT Age FROM People",
        yields: [[30], [25], [40]])
  }

  @Test func `a barred ordinary subquery projection still faults 0A000`() throws {
    // The parity guard: the read-side resolution keeps the `admits` bar, so an
    // ORDINARY (non-lateral) correlated subquery in a projection is still
    // DIAGNOSED `.unsupported` — the unification does not widen acceptance. The
    // barred surface faults the same on the run and schema paths.
    let people = try roster()
    #expect(throws: SQLError.state("0A000",
        "a correlated column is only supported in a subquery's WHERE")) {
      _ = try people.run(parse("SELECT (SELECT P.Age) FROM People AS P"))
    }
  }
}

// MARK: - Unconstrained-mask channel seal (per-wrapper regression matrix)

/// The class-level seal: a per-column `unconstrained` mask (an all-arms-NULL
/// column places NO type constraint, so it unifies with any set-operation arm)
/// must travel with a column's type through EVERY channel that stores or passes
/// a RESOLVED column's type. Three channels carry a resolved column's type — the
/// write/bindings carrier, the read/reference lookup, and the SCALAR-SUBQUERY
/// output memo — and each is exercised here by a matched PAIR per wrapper shape:
/// an all-NULL driver UNION'd with a typed arm must RUN (unify → the NULL row
/// and the typed row), while a NON-null counterpart in the SAME shape must still
/// FAULT `.operand` (SQLSTATE 42804), so the seal marks exactly the
/// constant-NULL columns and no others. The scalar-subquery pair is the fix for
/// the last leaking channel: the output memo once stored a bare `ValueType`, so
/// a scalar wrapper dropped the mask — `SELECT (SELECT NULLIF('a','a')) UNION
/// SELECT 1` was wrongly rejected while the unwrapped form ran.
struct EngineUnconstrainedMaskSealTests {
  @Test func `a bare all-NULL arm unifies with a typed arm; a typed one faults`()
      throws {
    // The baseline channel — a bare projected expression folding to constant
    // NULL is unconstrained, so it unifies; a typed literal constrains and
    // faults int-vs-text.
    try roster().expect("SELECT NULLIF('a', 'a') UNION SELECT 1",
                              yields: [[nil], [1]])
    try roster().expect(
        "SELECT 'a' UNION SELECT 1",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a scalar-subquery all-NULL wrapper unifies; a typed one faults`()
      throws {
    // THE FIX. The scalar subquery `(SELECT NULLIF('a','a'))` collapses to a
    // constant NULL, so its resolved output column is UNCONSTRAINED — the memo
    // now carries that mask into the outer fold, which unifies the wrapper with
    // the integer arm and RUNS (NULL row + `1` row). A genuinely-typed wrapper
    // `(SELECT 'a')` stays concrete text and faults int-vs-text.
    try roster().expect(
        "SELECT (SELECT NULLIF('a', 'a')) UNION SELECT 1",
        yields: [[nil], [1]])
    try roster().expect(
        "SELECT (SELECT 'a') UNION SELECT 1",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a scalar subquery over a both-NULL UNION unifies; a typed one faults`()
      throws {
    // The scalar subquery's OWN body is a set operation both of whose arms fold
    // to constant NULL, so the inner unification leaves the column
    // unconstrained — the memo carries THAT mask out, and the outer fold unifies
    // the wrapper with the text `'c'` arm. A typed inner UNION (`SELECT 1 UNION
    // SELECT 2`) stays a concrete integer and faults int-vs-text.
    try roster().expect("""
        SELECT (SELECT NULLIF(1, 1) UNION SELECT NULLIF('a', 'a'))
          UNION SELECT 'c'
        """, yields: [[nil], ["c"]])
    try roster().expect(
        "SELECT (SELECT 1 UNION SELECT 2) UNION SELECT 'c'",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a derived-table all-NULL column unifies; a typed one faults`()
      throws {
    // The derived-table channel: the derived body's column `x` folds to constant
    // NULL, so its resolved schema marks it unconstrained; a bare reference in
    // the outer set-op arm unifies with the integer `1`. A typed derived column
    // (`SELECT 'a' AS x`) stays concrete text and faults int-vs-text.
    try roster().expect("""
        SELECT x FROM (SELECT NULLIF('a', 'a') AS x) AS d UNION SELECT 1
        """, yields: [[nil], [1]])
    try roster().expect(
        "SELECT x FROM (SELECT 'a' AS x) AS d UNION SELECT 1",
        fails: .operand("UNION arms have irreconcilable types"))
  }
}

// MARK: - Placeholder-column unconstrained closure (fold defers, not faults)

/// The invariant that closes two feedback classes with ONE rule: a carrier
/// column whose type is a FABRICATED PLACEHOLDER (not a genuine derivation) is
/// marked UNCONSTRAINED, so the set-operation `merge` fold DEFERS to the other
/// arm rather than faulting on the placeholder — faulting ONLY on two
/// genuinely-known irreconcilable types.
///
/// Two placeholders are closed here. An UNREGISTERED routine call has no
/// genuine return type (the derive fabricates the `.integer` default), so its
/// fold defers — at ANY depth, whether the call is BARE (`missing()`) or
/// NESTED in a composite (`missing() + 0`, `COALESCE(missing(), 1)`, a `CASE`
/// result, an argument of a registered call); the SEPARATE reachable typecheck
/// still raises `SQLError.function` when the arm is REACHED, so a
/// genuinely-missing routine is never hidden — only the FOLD defers. A CTE's
/// declared-name carrier is likewise a placeholder, so a genuine body
/// incompatibility (`SELECT 'b' UNION SELECT 1`) PROPAGATES `.operand`
/// identically at run and at `columns(of:validate:true)`, rather than being
/// swallowed into a phantom `.integer`. A REGISTERED-only expression carries a
/// genuine type and still constrains, and a literal mismatch still faults, so
/// the deferral marks exactly the placeholders and no others.
struct EnginePlaceholderUnconstrainedClosureTests {
  @Test func `a bare unregistered call in a reached arm still faults function`()
      throws {
    // The unregistered `missing()` is REACHED (a FROM-less single-row arm), so
    // the reachable typecheck raises `SQLError.function` — NOT `.operand`. The
    // fold deferring on the placeholder does not hide the missing routine.
    try roster().expect("SELECT missing() UNION SELECT 'x'",
                              fails: .function("missing"))
  }

  @Test func `a bare unregistered call on the right side still faults function`()
      throws {
    // The right-side variant: the fold defers on the placeholder either way,
    // and the reachable typecheck raises `.function` when the arm is reached.
    try roster().expect("SELECT 1 UNION SELECT missing()",
                              fails: .function("missing"))
  }

  @Test func `an unreached unregistered-call arm defers and the union runs`()
      throws {
    // The zero-row arm skips the unregistered `NOPE(Name)` — never reached, so
    // no `.function` fault — while its placeholder type defers in the fold
    // rather than faulting `.operand` against the text `'x'`. The union yields
    // only the reached `'x'` row.
    try roster().expect("""
        SELECT NOPE(Name) FROM People FETCH FIRST 0 ROWS ONLY
          UNION SELECT 'x'
        """, yields: [["x"]])
  }

  @Test func `an unreached nested unregistered call defers and the union runs`()
      throws {
    // The reviewer oracle: `NOPE(Name) + 0` NESTS the unregistered call in a
    // `.binary`, which the former shallow bare-call case did not catch. The
    // zero-row arm never evaluates it, so `unresolved` marks the arm
    // unconstrained and the fold defers to the text `'x'` rather than faulting
    // `.operand` on the fabricated `.integer`. The union yields only `'x'`.
    try roster().expect("""
        SELECT NOPE(Name) + 0 FROM People FETCH FIRST 0 ROWS ONLY
          UNION SELECT 'x'
        """, yields: [["x"]])
  }

  @Test func `a reached nested unregistered call still faults function`()
      throws {
    // The reached counterpart: over the non-empty `People` the arm evaluates
    // `NOPE(Name) + 0`, dispatching the missing routine — so the reachable
    // typecheck raises `SQLError.function` (the name folded to `nope`), NOT
    // `.operand`. Deferring the fold does not hide the missing routine even
    // when it is nested.
    try roster().expect("""
        SELECT NOPE(Name) + 0 FROM People UNION SELECT 'x'
        """, fails: .function("nope"))
  }

  @Test func `an unregistered call inside COALESCE defers`() throws {
    // Nested in a `COALESCE`: the FROM-less arm's `COALESCE(missing(), 1)`
    // contains the unregistered call, so `unresolved` marks it unconstrained
    // and the fold defers to the text `'x'` rather than faulting `.operand`. A
    // FROM-less single-row arm is REACHED, so `missing()` dispatches — hence
    // the run faults `.function`, proving the deferral touches only the fold.
    try roster().expect("SELECT COALESCE(missing(), 1) UNION SELECT 'x'",
                              fails: .function("missing"))
  }

  @Test func `a COALESCE selecting an earlier non-NULL arg constrains the fold`()
      throws {
    // `COALESCE(1, missing())` SELECTS the constant integer `1` and never
    // reaches `missing()` (both `unified` and the executor stop there), so the
    // left arm constrains the set-op as integer — the text `'x'` arm is
    // genuinely irreconcilable and must fault `.operand`, not defer and leave
    // the integer `1` cell uncoerced against text.
    try roster().expect(
        "SELECT COALESCE(1, missing()) UNION ALL SELECT 'x'",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `an unregistered call inside a CASE result defers in the fold`()
      throws {
    // Nested in a reachable `CASE` result: the arm's `CASE WHEN 1 = 1 THEN
    // missing() END` reaches the `missing()` branch, so `unresolved` (via the
    // reachable-branch mirror of `derive`) marks it unconstrained. The arm is
    // reached, so the run dispatches `missing()` and faults `.function`.
    try roster().expect("""
        SELECT CASE WHEN 1 = 1 THEN missing() END UNION SELECT 'x'
        """, fails: .function("missing"))
  }

  @Test func `an unregistered call as a registered call argument defers`()
      throws {
    // Nested as an ARGUMENT of a REGISTERED call: `up(missing())` — `up` is
    // registered, but its argument dispatches the unregistered `missing()`, so
    // `unresolved`'s `.call` arm recurses the arguments and marks the arm
    // unconstrained. The FROM-less arm is reached, so the run dispatches the
    // inner `missing()` and faults `.function`.
    let routines: Routines =
        ["up": Routine(returns: .text, parameters: [.text]) { row in row[0] }]
    try roster().expect("SELECT up(missing()) UNION SELECT 'x'",
                              fails: .function("missing"), routines: routines)
  }

  @Test func `an unreached nested unregistered call under COALESCE runs`()
      throws {
    // The deferral is observable as a clean RUN when the nesting arm is
    // filtered out: a zero-row `COALESCE(missing(), 1)` arm never evaluates the
    // call, so the union folds and yields only the reached text `'x'`.
    try roster().expect("""
        SELECT COALESCE(missing(), 1) FROM People FETCH FIRST 0 ROWS ONLY
          UNION SELECT 'x'
        """, yields: [["x"]])
  }

  @Test func `a registered-only arithmetic mismatch still faults 42804`()
      throws {
    // The nested over-suppression guard: a REGISTERED integer-returning call in
    // an arithmetic expression carries a GENUINE type — `unresolved` finds no
    // unregistered call, so the arm stays constrained and the integer result
    // beside the text `'x'` still faults `.operand`. The recursion suppresses
    // ONLY unregistered calls, never a genuine mismatch.
    let routines: Routines =
        ["one": Routine(returns: .integer, parameters: []) { _ in .integer(1) }]
    try roster().expect("SELECT one() + 0 UNION SELECT 'x'",
                              fails: .operand(
                                  "UNION arms have irreconcilable types"),
                              routines: routines)
  }

  @Test func `pure literal arithmetic still faults 42804 beside text`() throws {
    // The baseline nested guard: `1 + 0` folds to a GENUINE integer with no
    // call at all, so it stays constrained and faults `.operand` against the
    // text `'x'` — the recursion adds no over-suppression to a call-free tree.
    try roster().expect(
        "SELECT 1 + 0 UNION SELECT 'x'",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a scalar subquery with an unregistered call defers via the memo`()
      throws {
    // Subquery composition: `(SELECT NOPE())` resolves its OWN single column
    // through the subquery memo (`scalar(resolved:)`), which already carries
    // the unconstrained mask for the unregistered call inside — so `unresolved`
    // returns false for the outer `.subquery` and does NOT double-handle it.
    // The outer fold defers to the text `'x'`; the FROM-less subquery arm is
    // reached, so the run dispatches `NOPE` (folded to `nope`) and faults
    // `.function`.
    try roster().expect("SELECT (SELECT NOPE()) UNION SELECT 'x'",
                              fails: .function("nope"))
  }

  @Test func `a registered text-returning call still constrains and faults`()
      throws {
    // The over-suppression guard: a REGISTERED routine has a GENUINE return
    // type, so its column is NOT a placeholder and still constrains — a
    // text-returning call beside an integer arm faults `.operand`.
    let routines: Routines = [
      "tag": Routine(returns: .text, parameters: [.text]) { _ in .text("t") }
    ]
    try roster().expect("SELECT tag(Name) FROM People UNION SELECT 1",
                              fails: .operand(
                                  "UNION arms have irreconcilable types"),
                              routines: routines)
  }

  @Test func `a registered call unifying with a matching arm runs`() throws {
    // The counterpart: a registered call whose genuine return type UNIFIES with
    // the other arm folds cleanly and runs.
    let routines: Routines =
        ["tag": Routine(returns: .text, parameters: [.text]) { row in row[0] }]
    try roster().expect("""
        SELECT tag(Name) FROM People WHERE Id = 1 UNION SELECT 'x'
        """, yields: [["Alice"], ["x"]], routines: routines)
  }

  @Test func `a literal type mismatch still faults 42804`() throws {
    // The baseline over-suppression guard: two GENUINE literal types still fold
    // to an irreconcilable pair and fault — the closure widens nothing.
    try roster().expect(
        "SELECT 1 UNION SELECT 'x'",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a genuine CTE body incompatibility faults at run`() throws {
    // The CTE-validate case at RUN: the body `SELECT 'b' UNION SELECT 1` folds
    // two GENUINE types (text vs integer) — irreconcilable — so the run faults
    // `.operand` rather than swallowing it into the declared `.integer`
    // placeholder.
    #expect(throws: SQLError.operand("UNION arms have irreconcilable types")) {
      _ = try statement(
          "WITH a(x) AS (SELECT 'b' UNION SELECT 1) SELECT x FROM a",
          family())
    }
  }

  @Test func `a genuine CTE body incompatibility faults at columns validate`()
      throws {
    // The SAME case at the schema path: `columns(of:validate:true)` must ALSO
    // throw `.operand` — no divergence, no phantom integer column advertised
    // for a query that cannot run.
    let statement = try Statement(parsing:
        "WITH a(x) AS (SELECT 'b' UNION SELECT 1) SELECT x FROM a")
    #expect(throws: SQLError.operand("UNION arms have irreconcilable types")) {
      _ = try family().columns(of: statement, validate: true)
    }
  }
}

// MARK: - Deferred set-op operand fold in the nested-subquery shape pre-pass

/// The reachability-aware deferral of a nested subquery's set-operation
/// operand-compatibility fold. The shape pre-pass (`subquery(of:)`/`width`)
/// records every nested subquery's width and single-column type AHEAD of the
/// walk that decides which subqueries actually run, so it must NOT fault
/// `SQLError.operand` (SQLSTATE 42804) on an incompatible set-operation
/// subquery a short-circuited `AND`/`OR` leg never reaches — a `… WHERE 1 = 0
/// AND EXISTS (SELECT 'x' UNION SELECT 1)` runs and yields no rows. Deferral
/// alone would HIDE a genuine incompatibility in a subquery that DOES run, so
/// a REACHED scalar or `IN`/quantified occurrence is re-folded strictly on the
/// reached path and faults exactly as before; an `EXISTS`/`LATERAL` reach does
/// not constrain column type and never faults on it. The top-level and CTE
/// folds are outside the pre-pass (`shape` is `false`), so they keep faulting.
struct EngineDeferredSetopShapeTests {
  @Test func `a dead-branch EXISTS over an incompatible UNION runs to no rows`()
      throws {
    // The reviewer oracle: the `EXISTS` is short-circuited by `1 = 0 AND …`, so
    // the incompatible `SELECT 'x' UNION SELECT 1` is never reached — the shape
    // pre-pass defers its operand fold rather than faulting 42804, and the
    // query runs to no rows.
    try roster().empty("""
        SELECT 1 FROM People WHERE 1 = 0 AND EXISTS (SELECT 'x' UNION SELECT 1)
        """)
  }

  @Test func `a reached EXISTS over an incompatible UNION runs`() throws {
    // A REACHED `EXISTS` does not read the arms' unified column type — its
    // cardinality probe never evaluates the select list — so it must NOT fault
    // on the incompatible pair (role `.existential`, skipped by the re-fold).
    // People has rows, so the EXISTS is present and every row projects `1`.
    try roster().expect("""
        SELECT 1 FROM People WHERE EXISTS (SELECT 'x' UNION SELECT 1)
        """, yields: Array(repeating: [1], count: 5))
  }

  @Test func `a dead-branch IN over an incompatible UNION runs to no rows`()
      throws {
    // The `IN` is unreachable behind `1 = 0 AND …`, so its incompatible UNION
    // defers in the shape pre-pass and the query runs to no rows.
    try roster().empty("""
        SELECT 1 FROM People WHERE 1 = 0 AND Age IN (SELECT 'a' UNION SELECT 1)
        """)
  }

  @Test func `a reached IN over an incompatible UNION faults 42804`() throws {
    // A REACHED `IN` reads its value set's column type (role `.valued`), so the
    // re-fold on the reached path restores the strict operand check and the
    // incompatible UNION faults 42804 — the deferral does not hide it.
    try roster().expect("""
        SELECT 1 FROM People WHERE Age IN (SELECT 'a' UNION SELECT 1)
        """, fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a reached scalar-subquery incompatible UNION faults 42804`() throws {
    // A REACHED scalar subquery collapses to a single cell (role `.scalar`), so
    // the reached re-fold checks its arms strictly and the incompatible UNION
    // faults 42804 in the comparison.
    try roster().expect("""
        SELECT 1 FROM People WHERE Age = (SELECT 'a' UNION SELECT 1)
        """, fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a dead-branch scalar-subquery incompatible UNION runs to no rows`()
      throws {
    // The SAME scalar subquery behind `1 = 0 AND …` is unreachable, so its
    // operand fold defers in the pre-pass and the query runs to no rows.
    try roster().empty("""
        SELECT 1 FROM People
          WHERE 1 = 0 AND Age = (SELECT 'a' UNION SELECT 1)
        """)
  }

  @Test func `a top-level incompatible UNION still faults 42804`() throws {
    // The top level is not a shape pre-pass (`shape` is `false`), so its
    // operand fold still faults — the deferral is scoped to nested subqueries.
    try roster().expect(
        "SELECT 'x' UNION SELECT 1",
        fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a compatible CTE body under an incompatible-looking outer runs`()
      throws {
    // A compatible CTE body unified against a matching outer arm runs — the
    // deferral changes nothing for a query that folds cleanly. A `WITH` is a
    // statement, so it runs through the statement overload.
    let rows = try statement(
        "WITH a(x) AS (SELECT 'b') SELECT x FROM a UNION SELECT 'c'",
        roster())
    #expect(rows == [[.text("b")], [.text("c")]])
  }
}

// MARK: - Reached-correlated set-op fold and invalid-call suppression

/// The two execution-seam refinements of the deferred set-op fold. A REACHED
/// correlated non-EXISTS subquery re-executes the SHAPED (placeholder-typed)
/// plan the pre-pass recorded under `.shaping()`, so it must strict-fold its
/// arms' column types at the EXECUTION seam (`Filter.executed`) — not from the
/// shaped plan — faulting `.operand` (42804) exactly as the uncorrelated run
/// path does, and ONLY for a REACHED occurrence (an unreachable one never runs
/// `executed`, so its deferral stands); an `EXISTS` reach never reads column
/// type and does not fault. Separately, an INVALID routine call (bad arity or a
/// definitively-wrong argument type) to an EXISTING routine is treated like a
/// MISSING one — its fabricated declared type must NOT constrain the fold — so
/// an invalid call in an UNREACHED arm folds away, while a VALID call's genuine
/// return type still constrains (the over-suppression guard).
struct EngineReachedCorrelatedSetopTests {
  @Test func `a reached correlated IN over an incompatible UNION faults 42804`()
      throws {
    // The correlated `IN` subquery unions a text left arm (correlated `d.k =
    // People.Id`) with an integer right arm. Reached for every outer row, its
    // shaped plan is strict-folded at the execution seam and the irreconcilable
    // pair faults 42804 on the first reached row — the correlated occurrence no
    // longer coerces to the placeholder type and silently passes.
    try roster().expect("""
        SELECT Id FROM People WHERE 1 IN ( \
        SELECT 'x' FROM (SELECT 1 AS k) AS d WHERE d.k = People.Id \
        UNION SELECT 1)
        """, fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a dead-branch correlated IN over an incompatible UNION runs empty`()
      throws {
    // The SAME correlated `IN` behind `1 = 0 AND …` is unreachable, so it never
    // reaches the execution seam — its shape deferral stands and the query runs
    // to no rows.
    try roster().empty("""
        SELECT Id FROM People WHERE 1 = 0 AND 1 IN ( \
        SELECT 'x' FROM (SELECT 1 AS k) AS d WHERE d.k = People.Id \
        UNION SELECT 1)
        """)
  }

  @Test func `a reached correlated EXISTS over an incompatible UNION runs`()
      throws {
    // A reached correlated `EXISTS` (role `.existential`) ignores its arms'
    // column types — the execution seam skips the strict fold — so the
    // incompatible pair does not fault. The right arm always yields a row, so
    // the EXISTS is present for every outer row and each projects its `Id`.
    try roster().expect("""
        SELECT Id FROM People WHERE EXISTS ( \
        SELECT 'x' FROM (SELECT 1 AS k) AS d WHERE d.k = People.Id \
        UNION SELECT 1)
        """, yields: [[1], [2], [3], [4], [5]])
  }

  @Test func `an invalid unreached call does not constrain the fold`() throws {
    // `tag(text) RETURNS text` called with NO argument is invalid (bad arity),
    // so it is treated like a missing call — its declared `text` return does
    // NOT constrain the fold. The invalid arm is unreached (`FETCH FIRST 0 ROWS
    // ONLY`), so the fold defers to the integer right arm and the query yields
    // it alone rather than faulting 42804 in the dead left arm.
    let routines: Routines = [
      "tag": Routine(returns: .text, parameters: [.text]) { _ in .text("t") }
    ]
    try roster().expect("""
        SELECT tag() FROM People FETCH FIRST 0 ROWS ONLY UNION SELECT 1
        """, yields: [[1]], routines: routines)
  }

  @Test func `an invalid reachable call faults on its bad arity, not 42804`()
      throws {
    // The counterpart on a VALIDATING path: `SELECT tag() UNION SELECT 1` calls
    // `tag(text)` with no argument. The invalid call does not constrain the
    // fold (so no spurious 42804), but the strict `validate: true` schema path
    // catches the bad arity and faults `.argument` — NOT the operand fold. (The
    // lenient run path does not validate arity, so it does not fault there.)
    let routines: Routines = [
      "tag": Routine(returns: .text, parameters: [.text]) { _ in .text("t") }
    ]
    let statement = try Statement(parsing: "SELECT tag() UNION SELECT 1")
    #expect(throws: SQLError.argument("tag takes 1 arguments")) {
      _ = try roster().columns(of: statement, routines: routines,
                                     validate: true)
    }
  }

  @Test func `a valid text call still constrains the fold and faults 42804`()
      throws {
    // The over-suppression guard: `tag('a')` is a VALID call (correct arity and
    // argument type), so its declared `text` return still constrains the fold —
    // a text column beside an integer arm faults 42804. The invalid-call
    // suppression must not swallow a valid call's genuine type.
    let routines: Routines = [
      "tag": Routine(returns: .text, parameters: [.text]) { _ in .text("t") }
    ]
    try roster().expect("""
        SELECT tag('a') FROM People UNION SELECT 1
        """, fails: .operand("UNION arms have irreconcilable types"),
        routines: routines)
  }
}
