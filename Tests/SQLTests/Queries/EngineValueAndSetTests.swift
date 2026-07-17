// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - NULL tests

struct EngineNullTests {
  @Test func `IS NULL admits only the NULL rows`() throws {
    try engineNullable().expect("SELECT Id FROM Maybe WHERE Note IS NULL",
                          yields: [[2], [4]])
  }

  @Test func `IS NOT NULL admits only the non-NULL rows`() throws {
    let rows = try engineNullable("SELECT Id FROM Maybe WHERE Note IS NOT NULL")
    #expect(rows == [[.integer(1)], [.integer(3)]])
  }

  @Test func `a comparison against a NULL cell is UNKNOWN and rejects`() throws {
    // For the NULL rows (2, 4) `Note = 'alpha'` is UNKNOWN, not false, so they
    // are not admitted; only the row whose Note equals 'alpha' survives.
    try engineNullable().expect("SELECT Id FROM Maybe WHERE Note = 'alpha'",
                          yields: [[1]])
  }

  @Test func `NOT of a NULL comparison stays UNKNOWN and rejects`() throws {
    // The NULL rows are UNKNOWN; NOT UNKNOWN is UNKNOWN, so they still reject —
    // only the non-null, non-'alpha' row survives.
    let rows = try engineNullable("SELECT Id FROM Maybe WHERE NOT Note = 'alpha'")
    #expect(rows == [[.integer(3)]])
  }

  @Test func `a NULL cell projects as a NULL value`() throws {
    try engineNullable().expect("SELECT Note FROM Maybe WHERE Id = 2",
                          yields: [[nil]])
  }

  @Test func `ORDER BY ascending sorts NULL keys first, then by value`() throws {
    // NULL holds a stable position — first in ascending order — so the non-null
    // notes still sort among themselves ('alpha' before 'gamma') rather than
    // tying with the nulls and leaving the order undefined.
    try engineNullable().expect("SELECT Id FROM Maybe ORDER BY Note ASC",
                          yields: [[2], [4], [1], [3]])
  }

  @Test func `ORDER BY descending sorts NULL keys last`() throws {
    try engineNullable().expect("SELECT Id FROM Maybe ORDER BY Note DESC",
                          yields: [[3], [1], [2], [4]])
  }

  @Test func `a NULL outer join key matches no inner row`() throws {
    // The child with a NULL foreign key is the outer row; a NULL key equi-joins
    // to nothing, so it contributes no pair — `Parent` is sorted, so the inner
    // is seeked and the NULL key is skipped before probing.
    let rows = try engineNullableKeys().run(engineParse("""
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
  try engineFamily().run(engineParse(text), Routines(), bindings: bindings)
}

struct EngineBoundTests {
  @Test func `a bound parameter filters rows by an outer value`() throws {
    // The child relation keyed on a bound parent id — the section primitive: a
    // template renders an interface's methods by binding the interface key and
    // running the child query.
    let rows = try boundRun("SELECT Name FROM Child WHERE Pid = :pid",
                            ["pid": .integer(1)])
    #expect(rows == [[.text("Ann")], [.text("Amy")]])
  }

  @Test func `a bound text parameter compares against a text column`() throws {
    let rows = try boundRun("SELECT Id FROM Parent WHERE Name = :who",
                            ["who": .text("Bee")])
    #expect(rows == [[.integer(2)]])
  }

  @Test func `an unbound parameter admits no row`() throws {
    let rows = try boundRun("SELECT Name FROM Child WHERE Pid = :pid", [:])
    #expect(rows.isEmpty)
  }

  @Test func `a bound parameter conjoined with another predicate`() throws {
    let rows = try boundRun("""
        SELECT Name FROM Child WHERE Pid = :pid AND Name = 'Amy'
        """, ["pid": .integer(1)])
    #expect(rows == [[.text("Amy")]])
  }

  @Test func `a correlated section runs a child query per outer row`() throws {
    // The relational shape of a template's nested section: the outer query
    // yields the parents; for each, the child query is re-run with the parent's
    // key bound, producing that parent's children — exactly an interface →
    // methods expansion.
    let catalog = try engineFamily()
    let parents = try catalog.run(engineParse("SELECT Id, Name FROM Parent"))
    let query = try engineParse("SELECT Name FROM Child WHERE Pid = :pid")

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

  @Test func `an unbound parameter under NOT still admits no rows`() throws {
    // A missing binding is UNKNOWN, not false; NOT preserves UNKNOWN rather
    // than inverting it into a match, so the predicate admits nothing.
    let rows = try boundRun("SELECT Name FROM Child WHERE NOT Pid = :pid", [:])
    #expect(rows.isEmpty)
  }

  @Test func `a bound parameter under NOT inverts the match`() throws {
    let rows = try boundRun("SELECT Name FROM Child WHERE NOT Pid = :pid",
                            ["pid": .integer(1)])
    #expect(rows == [[.text("Bob")], [.text("Orphan")]])
  }

  @Test func `a bound key plans a seek when its value is known`() throws {
    // Parent is sorted on Id; with `:id` bound the planner resolves it and
    // seeks the run rather than scanning and filtering the whole relation.
    let select = try engineParse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = try engineFamily()
    let plan = try catalog.optimise(catalog.compile(select),
                                    ["id": .integer(2)])
    #expect(engineSeeks(plan))
    #expect(!engineFilters(plan))
  }

  @Test func `an unbound key cannot seek and scans under the filter`() throws {
    let select = try engineParse("SELECT Name FROM Parent WHERE Id = :id")
    let catalog = try engineFamily()
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled, [:])
    #expect(!engineSeeks(plan))
    #expect(engineFilters(plan))
  }

  @Test func `a bound key inside a view seeks when its parameter is supplied`() throws {
    // A parameterized view (`… WHERE Id = :id` over sorted Parent): the bound
    // key seeks inside the view's sub-plan rather than scanning it once :id is
    // supplied, so a reusable view is as fast as the inlined query.
    let select = try engineParse("SELECT Key, Label FROM Picked")
    let catalog = try engineViews()
    let plan = try catalog.optimise(catalog.compile(select),
                                    ["id": .integer(2)])
    let sub = try #require(engineDerived(plan))
    #expect(engineSeeks(sub))
    #expect(!engineFilters(sub))
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
func engineTags() -> EngineMemory {
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
    let rows = try enginePeople().run(engineParse("""
        SELECT Age FROM People UNION SELECT Age FROM People
        """))
    #expect(rows == [[.integer(30)], [.integer(25)], [.integer(40)]])
  }

  @Test func `UNION ALL keeps every row of every arm in source order`() throws {
    let rows = try enginePeople().run(engineParse("""
        SELECT Age FROM People UNION ALL SELECT Age FROM People
        """))
    let ages = [30, 25, 30, 40, 25].map { Value.integer($0) }
    #expect(rows == (ages + ages).map { [$0] })
  }

  @Test func `a UNION across two relations of matching arity merges and dedups`() throws {
    let rows = try engineTags().run(engineParse("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
        """))
    // `shared` appears in both arms but survives once, first occurrence kept.
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a UNION ALL across two relations keeps the shared row twice`() throws {
    let rows = try engineTags().run(engineParse("""
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
    let rows = try engineTags().run(engineParse("""
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
      try enginePeople().run(engineParse("""
          SELECT Id FROM People UNION SELECT Id, Name FROM People
          """))
    }
  }

  @Test func `a view defined as a UNION resolves and queries`() throws {
    let both = try View(query: engineSelect("""
        SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs
        """), columns: ["Tag"])
    let catalog = EngineMemory(engineTags().catalog, views: ["Both": both])
    let rows = try catalog.run(engineParse("SELECT Tag FROM Both"))
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a bound parameter threads into every arm of a UNION`() throws {
    // Both arms key on the same `:pid`; the binding reaches each alike, so the
    // union is the parent's children drawn from two queries over the relation.
    let rows = try engineFamily().run(engineParse("""
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
    let rows = try multiset().run(engineParse("""
        SELECT N FROM A INTERSECT SELECT N FROM B
        """))
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `INTERSECT ALL keeps each common row to the lesser multiplicity`() throws {
    // A holds `2` thrice and B twice, so INTERSECT ALL keeps `min(3, 2)` = two;
    // `3` is once in each, so one — every occurrence in A's order.
    let rows = try multiset().run(engineParse("""
        SELECT N FROM A INTERSECT ALL SELECT N FROM B
        """))
    #expect(rows == [[.integer(2)], [.integer(2)], [.integer(3)]])
  }

  @Test func `EXCEPT keeps the distinct left rows absent from the right`() throws {
    // A's distinct rows not in B are `1` and `4`; `2`/`3` are removed (present
    // in B), first occurrence order preserved.
    let rows = try multiset().run(engineParse("""
        SELECT N FROM A EXCEPT SELECT N FROM B
        """))
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }

  @Test func `EXCEPT ALL removes one left row per matching right row`() throws {
    // A: 1,1,2,2,2,3,4. B removes one `2` per its two copies (leaving one `2`)
    // and its one `3` (leaving none); `1` (twice) and `4` are untouched — every
    // survivor in A's order.
    let rows = try multiset().run(engineParse("""
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
    // Here the reused `engineTags()` relations give `B INTERSECT C` = `Rhs INTERSECT
    // Extra`: Rhs is {shared, b}, Extra is {a}, so the intersection is empty
    // and the whole result is just Lhs's distinct rows.
    let rows = try engineTags().run(engineParse("""
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
    let rows = try engineTags().run(engineParse("""
        SELECT Tag FROM Lhs
          UNION SELECT Tag FROM Rhs
          EXCEPT SELECT Tag FROM Extra
        """))
    #expect(rows == [[.text("shared")], [.text("b")]])
  }

  @Test func `INTERSECT of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(1, 2)) {
      try enginePeople().run(engineParse("""
          SELECT Id FROM People INTERSECT SELECT Id, Name FROM People
          """))
    }
  }

  @Test func `EXCEPT of arms projecting differing column counts is rejected`() throws {
    #expect(throws: SQLError.arity(2, 1)) {
      try enginePeople().run(engineParse("""
          SELECT Id, Name FROM People EXCEPT SELECT Id FROM People
          """))
    }
  }

  @Test func `a view defined as an EXCEPT resolves and queries`() throws {
    let diff = try View(query: engineSelect("""
        SELECT N FROM A EXCEPT SELECT N FROM B
        """), columns: ["N"])
    let catalog = EngineMemory(multiset().catalog, views: ["Diff": diff])
    let rows = try catalog.run(engineParse("SELECT N FROM Diff"))
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }
}

// MARK: - DISTINCT tests

struct EngineDistinctTests {
  @Test func `DISTINCT removes duplicate rows, keeping the first occurrence`() throws {
    // People's Age repeats (30 for Alice and Carol, 25 for Bob and Eve);
    // DISTINCT collapses each duplicate to its first appearance, in row order.
    try enginePeople().expect("SELECT DISTINCT Age FROM People",
                        yields: [[30], [25], [40]])
  }

  @Test func `a plain SELECT keeps every duplicate row`() throws {
    try enginePeople().expect("SELECT Age FROM People",
                        yields: [[30], [25], [30], [40], [25]])
  }

  @Test func `SELECT ALL is the plain, non-deduplicating select`() throws {
    try enginePeople().expect("SELECT ALL Age FROM People",
                        yields: [[30], [25], [30], [40], [25]])
  }

  @Test func `DISTINCT dedups on the whole projected row, not one column`() throws {
    // Grade's (Class, Score) pairs repeat — (A, 80) three times, (B, 90)
    // twice — while a single column would over-collapse. DISTINCT keeps one of
    // each distinct pair, first occurrence in row order.
    try engineGrades().expect("SELECT DISTINCT Class, Score FROM Grade",
                        yields: [["B", 90], ["A", 80], ["A", 70]])
  }

  @Test func `DISTINCT dedups rows a projection maps together`() throws {
    // Bob (25) and Eve (25), Alice (30) and Carol (30) share an Age; projecting
    // Age alone collapses each pair even though their other columns differ.
    try enginePeople().expect("SELECT DISTINCT Age FROM People WHERE Age < 40",
                        yields: [[30], [25]])
  }

  @Test func `DISTINCT binds to its own arm within a UNION ALL`() throws {
    // DISTINCT is a per-SELECT quantifier: it dedups the LEFT arm alone (its
    // repeated Ages collapse to 30, 25, 40), then the UNION ALL appends the
    // right arm's rows without deduplicating across the arms.
    try enginePeople().expect("""
        SELECT DISTINCT Age FROM People
          UNION ALL SELECT Age FROM People WHERE Id = 1
        """, yields: [[30], [25], [40], [30]])
  }

  @Test func `DISTINCT combines with ORDER BY, ordering the deduplicated rows`() throws {
    // The distinct Ages, then ascending: dedup keeps 30, 25, 40; ORDER BY sorts
    // them 25, 30, 40.
    try enginePeople().expect("SELECT DISTINCT Age FROM People ORDER BY Age",
                        yields: [[25], [30], [40]])
  }

  @Test func `DISTINCT dedups before OFFSET/FETCH pages the result`() throws {
    // Three distinct Ages ordered 25, 30, 40; FETCH FIRST 2 pages the
    // deduplicated, ordered rows — proving the cap sits above the dedup.
    try enginePeople().expect("""
        SELECT DISTINCT Age FROM People ORDER BY Age FETCH FIRST 2 ROWS ONLY
        """, yields: [[25], [30]])
  }

  @Test func `DISTINCT over an aggregate dedups the grouped rows`() throws {
    // Grouping People by Age yields one row per distinct Age (25, 30, 40), each
    // with its COUNT; projecting only the COUNT leaves 2, 2, 1 — DISTINCT then
    // collapses the two 2s to one.
    try enginePeople().expect("""
        SELECT DISTINCT COUNT(*) FROM People GROUP BY Age
        """, yields: [[2], [1]])
  }

  @Test func `a view defined with DISTINCT deduplicates when queried`() throws {
    let ages = try View(query: engineSelect("SELECT DISTINCT Age FROM People"),
                        columns: ["Age"])
    let catalog = EngineMemory(try enginePeople().catalog, views: ["Ages": ages])
    try catalog.expect("SELECT Age FROM Ages", yields: [[30], [25], [40]])
  }

  @Test func `DISTINCT ordering on a non-projected column faults`() throws {
    // Name is not in the DISTINCT output, so after dedup each Age stands for
    // several Names — the order is ill-defined; the standard rejects it.
    try enginePeople().expect("SELECT DISTINCT Age FROM People ORDER BY Name",
                        fails: .distinct("Name"))
  }

  @Test func `DISTINCT ordering on a projected column pages correctly`() throws {
    // Age is a select-list column, so ordering (and paging) on it is well
    // defined: the deduplicated Ages sort 25, 30, 40, and OFFSET 1 drops the
    // first.
    try enginePeople().expect("""
        SELECT DISTINCT Age FROM People ORDER BY Age
          OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY
        """, yields: [[30], [40]])
  }

  @Test func `DISTINCT over a join rejects a hidden ORDER BY key`() throws {
    // Child.Name is not projected, so ordering the deduplicated Parent.Name
    // rows on it is ill-defined across the two joined relations.
    try engineFamily().expect("""
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
    try enginePeople().expect("""
        SELECT DISTINCT COUNT(*) FROM People GROUP BY Age ORDER BY Age
        """, fails: .distinct("Age"))
  }

  @Test func `grouped DISTINCT orders on a projected aggregate alias`() throws {
    // The counts per Age are 2, 2, 1; DISTINCT collapses the two 2s, leaving
    // {1, 2}. Ordering on the projected alias `c` is well defined — ascending
    // yields 1, 2.
    try enginePeople().expect("""
        SELECT DISTINCT COUNT(*) AS c FROM People GROUP BY Age ORDER BY c
        """, yields: [[1], [2]])
  }
}

// MARK: - Arithmetic tests

struct EngineArithmeticTests {
  @Test func `literal arithmetic evaluates over a row`() throws {
    // One row of `People` drives the projection; the value is the same for each,
    // and `Id = 1` selects exactly one.
    try enginePeople().expect("SELECT 2 + 3 FROM People WHERE Id = 1", yields: [[5]])
  }

  @Test func `multiplication binds tighter than addition`() throws {
    try enginePeople().expect("SELECT 2 + 3 * 4 FROM People WHERE Id = 1",
                        yields: [[14]])
  }

  @Test func `parentheses override precedence`() throws {
    try enginePeople().expect("SELECT (2 + 3) * 4 FROM People WHERE Id = 1",
                        yields: [[20]])
  }

  @Test func `subtraction and division are left-associative`() throws {
    // (20 - 5) - 3 = 12, not 20 - (5 - 3) = 18; (100 / 5) / 2 = 10.
    let difference = try engineRun("SELECT 20 - 5 - 3 FROM People WHERE Id = 1")
    #expect(difference == [[.integer(12)]])
    let quotient = try engineRun("SELECT 100 / 5 / 2 FROM People WHERE Id = 1")
    #expect(quotient == [[.integer(10)]])
  }

  @Test func `integer division truncates`() throws {
    try enginePeople().expect("SELECT 7 / 2 FROM People WHERE Id = 1", yields: [[3]])
  }

  @Test func `arithmetic over a column computes per row`() throws {
    let rows = try engineRun("SELECT Age + 1 FROM People WHERE Id = 2")
    // Bob's Age is 25; 25 + 1 = 26.
    #expect(rows == [[.integer(26)]])
  }

  @Test func `arithmetic mixes columns and a function call`() throws {
    let rows = try engineFunctionRun("SELECT add(Id, 1) * 10 FROM People WHERE Id = 3")
    // Carol: (3 + 1) * 10 = 40.
    #expect(rows == [[.integer(40)]])
  }

  @Test func `a NULL operand propagates to a NULL result`() throws {
    // `Note` is NULL for row 2; `Id + Note` mixes a present integer with a NULL,
    // so the whole expression is NULL rather than a fault.
    try engineNullable().expect("SELECT Id + Note FROM Maybe WHERE Id = 2",
                          yields: [[nil]])
  }

  @Test func `division by zero faults`() throws {
    #expect(throws: SQLError.divide) {
      try engineRun("SELECT Id / 0 FROM People WHERE Id = 1")
    }
  }

  @Test func `arithmetic overflow faults instead of trapping`() throws {
    // `Int.max + 1` and a multiply past the boundary report overflow as a
    // `SQLError` rather than trapping (and aborting) the process.
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try engineRun("SELECT 9223372036854775807 + 1 FROM People WHERE Id = 1")
    }
    #expect(throws: SQLError.magnitude("integer overflow")) {
      try engineRun("SELECT 9223372036854775807 * 2 FROM People WHERE Id = 1")
    }
  }

  @Test func `a parenthesised expression opens a predicate`() throws {
    // `(Age + 1)` is the grouped left operand of the comparison, not a predicate
    // group; it matches Dave (40 + 1 = 41). A leading `(` no longer forces a
    // predicate-group parse.
    let matched = try engineRun("SELECT Id FROM People WHERE (Age + 1) = 41")
    #expect(matched == [[.integer(4)]])
    // A grouped expression works before `IS NULL` too; `Id + 1` is never NULL.
    let none = try engineRun("SELECT Id FROM People WHERE (Id + 1) IS NULL")
    #expect(none.isEmpty)
  }

  @Test func `a text operand faults as a type error`() throws {
    #expect(throws: SQLError.operand("operands must be numeric")) {
      try engineRun("SELECT Name + 1 FROM People WHERE Id = 1")
    }
  }

  @Test func `arithmetic in a predicate filters rows`() throws {
    // `Age + 1 = 26` holds for everyone aged 25 (Bob and Eve); the arithmetic
    // is evaluated per row on the WHERE side too.
    try enginePeople().expect("SELECT Name FROM People WHERE Age + 1 = 26",
                        yields: [["Bob"], ["Eve"]])
  }
}

// MARK: - Scalar (FROM-less) SELECT tests

struct EngineScalarSelectTests {
  @Test func `a FROM-less literal yields exactly one row`() throws {
    // No relation, so the projection runs against a single empty row; the
    // catalog is never consulted for a table.
    try enginePeople().expect("SELECT 42", yields: [[42]])
  }

  @Test func `a FROM-less arithmetic computes a scalar`() throws {
    try enginePeople().expect("SELECT 1 + 1", yields: [[2]])
  }

  @Test func `FROM-less arithmetic honours precedence`() throws {
    try enginePeople().expect("SELECT 2 + 3 * 4", yields: [[14]])
  }

  @Test func `a FROM-less multi-column projection yields one row of each value`() throws {
    try enginePeople().expect("SELECT 1, 2, 3", yields: [[1, 2, 3]])
  }

  @Test func `a FROM-less projection mixes text and integer expressions`() throws {
    try enginePeople().expect("SELECT 'x', 10 / 2", yields: [["x", 5]])
  }

  @Test func `a FROM-less scalar call evaluates against the single row`() throws {
    let rows = try engineFunctionRun("SELECT add(40, 2)")
    #expect(rows == [[.integer(42)]])
  }

  @Test func `a boolean literal lowers to its truth value`() throws {
    try enginePeople().expect("SELECT TRUE, FALSE", yields: [[true, false]])
  }

  @Test func `a hex blob literal lowers to its bytes`() throws {
    // The `x'53514c'` literal lexes, parses, and lowers to the three-byte
    // blob `SQL`, projected as a `Value.blob`.
    try enginePeople().expect("SELECT x'53514c'",
                        yields: [[[0x53, 0x51, 0x4c] as Array<UInt8>]])
  }

  @Test func `a boolean operand faults as a non-numeric type error`() throws {
    // Neither boolean nor blob is numeric, so arithmetic over either faults
    // exactly as text does — the type-checker rejects any non-numeric operand.
    try enginePeople().expect("SELECT TRUE + 1",
                        fails: .operand("operands must be numeric"))
  }

  @Test func `a blob operand faults as a non-numeric type error`() throws {
    try enginePeople().expect("SELECT x'00' + 1",
                        fails: .operand("operands must be numeric"))
  }

  @Test func `a NULL-yielding FROM-less expression projects NULL`() throws {
    // The bare literal NULL is not in the grammar, but a NULL arises from a
    // function returning it; `nothing` yields NULL for the single row.
    let routines: Routines =
        ["nothing": Routine(parameters: []) { _ in .null }]
    let rows = try enginePeople().run(engineParse("SELECT nothing()"), routines)
    #expect(rows == [[.null]])
  }

  @Test func `a FROM-less SELECT * is rejected — no relation to expand`() throws {
    #expect(throws: SQLError.unsupported("SELECT * requires a FROM clause")) {
      try engineRun("SELECT *")
    }
  }

  @Test func `a FROM-less bare column is rejected — no column to bind`() throws {
    try enginePeople().expect("SELECT Name", fails: .column("Name"))
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
      try enginePeople().run(.select(Select(projection: filtered.projection,
                                    from: nil,
                                    predicate: filtered.predicate)))
    }
    let grouped = try EngineScalarSelectTests.select(
        "SELECT Id FROM People GROUP BY Id")
    #expect(throws: fault) {
      try enginePeople().run(.select(Select(projection: grouped.projection, from: nil,
                                    grouping: grouped.grouping)))
    }
    let filteredGroup = try EngineScalarSelectTests.select(
        "SELECT Id FROM People GROUP BY Id HAVING COUNT(*) > 0")
    #expect(throws: fault) {
      try enginePeople().run(.select(Select(projection: filteredGroup.projection,
                                    from: nil,
                                    having: filteredGroup.having)))
    }
    let ordered =
        try EngineScalarSelectTests.select("SELECT Id FROM People ORDER BY Id")
    #expect(throws: fault) {
      try enginePeople().run(.select(Select(projection: ordered.projection, from: nil,
                                    order: ordered.order)))
    }
    let limited = try EngineScalarSelectTests.select(
        "SELECT Id FROM People FETCH FIRST 1 ROW ONLY")
    #expect(throws: fault) {
      try enginePeople().run(.select(Select(projection: limited.projection, from: nil,
                                    limit: limited.limit)))
    }
    let joined = try EngineScalarSelectTests.select(
        "SELECT Id FROM People JOIN Pets ON Pets.Owner = People.Id")
    #expect(throws: fault) {
      try enginePeople().run(.select(Select(projection: joined.projection, from: nil,
                                    joins: joined.joins)))
    }
  }

  /// The `Select` of a parsed single-`SELECT` query — for building the FROM-less
  /// shapes the parser will not, by re-homing a clause onto a `from: nil` select.
  private static func select(_ text: String) throws -> Select {
    guard case let .select(select) = try engineParse(text) else {
      throw SQLError.incomplete(expected: "a SELECT")
    }
    return select
  }

  @Test func `a FROM-less arm of a UNION combines with a FROM arm`() throws {
    // Both arms project one integer column; the FROM-less arm contributes its
    // single computed row, deduplicating against the People ages.
    let rows = try enginePeople().run(engineParse("""
        SELECT 100 UNION ALL SELECT Age FROM People WHERE Id = 1
        """))
    #expect(rows == [[.integer(100)], [.integer(30)]])
  }

  @Test func `an existing SELECT … FROM … query is unaffected`() throws {
    // The FROM-optional grammar leaves a normal query parsing and running
    // exactly as before.
    try enginePeople().expect("SELECT Name FROM People WHERE Id = 1",
                        yields: [["Alice"]])
  }
}
