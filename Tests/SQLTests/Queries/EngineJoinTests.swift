// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Join tests

struct EngineJoinTests {
  @Test func `a join on a foreign key pairs each child with its parent`() throws {
    let rows = try engineJoin("""
        SELECT * FROM Parent JOIN Child ON Child.Pid = Parent.Id
        """)
    // The orphan child (Pid 9) and the childless parent (Cid) drop out.
    #expect(rows == [
      [.integer(1), .text("Ada"), .integer(1), .text("Ann")],
      [.integer(1), .text("Ada"), .integer(1), .text("Amy")],
      [.integer(2), .text("Bee"), .integer(2), .text("Bob")],
    ])
  }

  @Test func `a qualified projection selects across both relations`() throws {
    try engineFamily().expect("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """,
        yields: [["Ada", "Ann"], ["Ada", "Amy"], ["Bee", "Bob"]])
  }

  @Test func `a join keys off the inner relation's virtual Id`() throws {
    // `Ordered` has no stored key; its identity is its 1-based `Id`. The
    // child's `Pid` joins to that virtual column.
    let rows = try engineJoin("""
        SELECT Ordered.Label, Child.Name FROM Child
          JOIN Ordered ON Ordered.Id = Child.Pid
        """)
    // Pid 1 → "first" (Ann, Amy), Pid 2 → "second" (Bob); Pid 9 has no row.
    #expect(rows == [
      [.text("first"), .text("Ann")],
      [.text("first"), .text("Amy")],
      [.text("second"), .text("Bob")],
    ])
  }

  @Test func `a join keyed off the OUTER relation's virtual Id does not collide`() throws {
    // The combined ordinal space lays the inner relation past the outer's
    // `extent` — its real width plus the virtual columns it exposes — so an
    // outer virtual column never shares an ordinal with an inner real one. Here
    // `Ordered` is the OUTER relation, and the join keys off its virtual `Id`
    // at ordinal `width`; the inner `Child.Pid` is a real column at ordinal 0.
    // Were the inner laid at the outer's `width` (or at a base collapsed to 0
    // by a `1 << 32` reserve on a 32-bit host), `Child.Pid` would land on the
    // outer `Id`'s ordinal and the join's cells would corrupt one another.
    let rows = try engineJoin("""
        SELECT Ordered.Id, Child.Name FROM Ordered
          JOIN Child ON Child.Pid = Ordered.Id
        """)
    // Id 1 → Ann, Amy; Id 2 → Bob; Id 3 has no child; Pid 9 no parent.
    #expect(rows == [
      [.integer(1), .text("Ann")],
      [.integer(1), .text("Amy")],
      [.integer(2), .text("Bob")],
    ])
  }

  @Test func `a WHERE spans both relations`() throws {
    try engineFamily().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada' AND Child.Name = 'Amy'
        """,
        yields: [["Amy"]])
  }

  @Test func `ORDER BY orders across the join`() throws {
    try engineFamily().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          ORDER BY Child.Name ASC
        """,
        yields: [["Amy"], ["Ann"], ["Bob"]])
  }

  @Test func `an unqualified name in both relations is ambiguous`() throws {
    #expect(throws: SQLError.ambiguous("Name")) {
      try engineJoin("SELECT Name FROM Parent JOIN Child ON Child.Pid = Parent.Id")
    }
  }

  @Test func `a self-join's shared table name makes a qualified name ambiguous`() throws {
    #expect(throws: SQLError.ambiguous("Id")) {
      try engineJoin("""
          SELECT Parent.Name FROM Parent JOIN Parent ON Parent.Id = Parent.Id
          """)
    }
  }

  @Test func `a duplicated alias makes a shared qualified column ambiguous`() throws {
    // `x.Pid` resolves by column (the Child side only); `x.Name` is on both,
    // so the shared alias is ambiguous rather than binding silently to outer.
    #expect(throws: SQLError.ambiguous("Name")) {
      try engineJoin("""
          SELECT x.Name FROM Parent AS x JOIN Child AS x ON x.Pid = x.Pid
          """)
    }
  }

  @Test func `a parent with no matching child contributes no rows`() throws {
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Cid'
        """)
    #expect(rows.isEmpty)
  }

  @Test func `the seek probe and the scan probe return identical results`() throws {
    // The join seeks `Child.Pid = Parent.Id` when the inner relation is
    // seekable on the key, and scans it otherwise. Both inner orderings — the
    // sorted `Parent` and its unsorted twin used as the inner — must agree.
    let seek = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid ORDER BY Child.Name ASC
        """)
    let scan = try engineJoin("""
        SELECT P.Name, Child.Name FROM Child
          JOIN ParentUnsorted AS P ON P.Id = Child.Pid ORDER BY Child.Name ASC
        """)
    #expect(seek == scan)
    #expect(seek == [
      [.text("Ada"), .text("Amy")],
      [.text("Ada"), .text("Ann")],
      [.text("Bee"), .text("Bob")],
    ])
  }
}

// MARK: - Non-equi join tests

struct EngineNonEquiJoinTests {
  @Test func `an inequality ON pairs every row the predicate admits`() throws {
    // `ON Parent.Id < Child.Pid` is a pure inequality — no equi conjunct —
    // so it is a nested loop: for each parent, every child whose Pid exceeds
    // its Id, in outer-major order.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """)
    #expect(rows == [
      [.text("Ada"), .text("Bob")],
      [.text("Ada"), .text("Orphan")],
      [.text("Bee"), .text("Orphan")],
      [.text("Cid"), .text("Orphan")],
    ])
  }

  @Test func `a pure inequality ON plans a residual product, not a hash join`() throws {
    // No `column = column` conjunct, so `nest` cannot form a `.join`; the level
    // stays a `.select` over a `.product` — the nested-loop shape.
    let catalog = try engineFamily()
    let select = try engineParse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!engineJoins(plan))
    #expect(engineResidual(plan))
  }

  @Test func `a mixed ON hashes the equi conjunct and filters the residual`() throws {
    // `ON Child.Pid = Parent.Id AND Child.Name < 'B'`: the equality hash-joins
    // each child to its parent; the residual inequality beside the key then
    // keeps only pairs whose child name sorts before 'B' — dropping Bob, the
    // sole B-name.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id AND Child.Name < 'B'
        """)
    // Equi pairs (Ada,Ann),(Ada,Amy),(Bee,Bob); the residual drops (Bee,Bob).
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
    ])
  }

  @Test func `a mixed ON still plans a hash join for its equi conjunct`() throws {
    // The `column = column` conjunct becomes a `.join`; the inequality
    // survives as a residual `.select` over it — the equi fast-path still
    // triggers.
    let catalog = try engineFamily()
    let select = try engineParse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id AND Parent.Name < Child.Name
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineJoins(plan))
  }

  @Test func `an expression equality ON is a residual, not a hash key`() throws {
    // `ON Child.Pid = Parent.Id + 1` equates a column with an EXPRESSION, so
    // it is not a bare `column = column` key: it lowers to a residual over the
    // product (nested loop), not a hash join.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id + 1
        """)
    // Parent 1 (Ada) → Pid 2: Bob. Parent 2 (Bee) → Pid 3: none.
    // Parent 3 (Cid) → Pid 4: none.
    #expect(rows == [[.text("Ada"), .text("Bob")]])
  }

  @Test func `an expression equality ON plans a residual product`() throws {
    let catalog = try engineFamily()
    let select = try engineParse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id + 1
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!engineJoins(plan))
    #expect(engineResidual(plan))
  }

  @Test func `a non-equi ON equals the eager product filtered`() throws {
    // The nested-loop join over an inequality must yield exactly the eager
    // cross product filtered by the same predicate, in outer-major order.
    let catalog = try engineFamily()
    let parents = try catalog.run(engineParse("SELECT Name, Id FROM Parent"))
    let children = try catalog.run(engineParse("SELECT Name, Pid FROM Child"))
    var expected = Array<Array<Value>>()
    for parent in parents {
      for child in children where less(parent[1], child[1]) {
        expected.append([parent[0], child[0]])
      }
    }
    let rows = try catalog.run(engineParse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """))
    #expect(rows == expected)
  }

  @Test func `an unsafe ON conjunct before an equi key is preserved`() throws {
    // `ON (1 / A.x) = 0 AND A.k = B.k` over a product pair where `A.x = 0` and
    // `A.k <> B.k`. The hash join evaluates its key equality BEFORE any
    // residual, so hoisting `A.k = B.k` to a key would drop the non-matching
    // pair and skip the division the earlier unsafe conjunct owes. The unsafe
    // leading conjunct bars extraction, so the WHOLE ON stays a residual over
    // the product and the division raises `SQLError.divide` rather than the
    // query returning no rows.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(engineParse("""
          SELECT A.k FROM A JOIN B ON (1 / A.x) = 0 AND A.k = B.k
          """))
    }
  }

  @Test func `an unsafe-prefixed ON extracts no equi key, planning a residual`() throws {
    // The same `ON (1 / A.x) = 0 AND A.k = B.k`: the unsafe leading conjunct
    // bars the equi from becoming a `match`, so `nest` forms no `.join` — the
    // level is a residual `.select` over a `.product`, the whole ON per pair.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    let select = try engineParse("""
        SELECT A.k FROM A JOIN B ON (1 / A.x) = 0 AND A.k = B.k
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!engineJoins(plan))
    #expect(engineResidual(plan))
  }

  @Test func `an equi key before an unsafe residual extracts no key, planning a residual`() throws {
    // `ON A.k = B.k AND (1 / A.x) = 0` (equi FIRST) has an unsafe conjunct, so
    // NO key is extracted and the WHOLE ON lowers to a residual over the
    // product. A hash key would skip a NULL-key pair before the unsafe RHS ran,
    // suppressing the divide the left-to-right Kleene AND owes — so the equi
    // must NOT hoist while an unsafe conjunct FOLLOWS it.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    let compiled = try catalog.compile(engineParse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!engineJoins(plan))
    #expect(engineResidual(plan))
  }

  @Test func `a nullable ON key before an unsafe residual raises`() throws {
    // `ON A.k = B.k AND (1 / A.x) = 0` with `A.k` NULL and `A.x = 0`. The
    // equality is UNKNOWN (a NULL operand), so the Kleene AND must still
    // evaluate the unsafe RHS `(1 / A.x) = 0` and raise `SQLError.divide`.
    // Extracting `A.k = B.k` to a hash key would skip the NULL key and DROP the
    // pair before the RHS ran, returning no rows — so no key is hoisted and the
    // WHOLE ON stays a residual over the product that raises.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.integer(0), .null]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                    [[.integer(2)]] as Array<Array<Value>>),
    ])
    let compiled = try catalog.compile(engineParse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!engineJoins(plan))
    #expect(engineResidual(plan))
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(engineParse("""
          SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
          """))
    }
  }

  @Test func `a definite-false ON key before an unsafe residual short-circuits without raising`() throws {
    // `ON A.k = B.k AND (1 / A.x) = 0` with `A.k = 5`, `B.k = 3` (non-NULL,
    // definitely UNEQUAL) and `A.x = 0`. The equality is definite FALSE, so the
    // Kleene AND short-circuits (`false` dominates) and never evaluates the
    // unsafe RHS — no rows, no raise. Both the product+select and the residual
    // agree, distinguishing a definite-FALSE key from the UNKNOWN NULL one.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                     EngineField(name: "k", type: .integer)],
                    [[.integer(0), .integer(5)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                    [[.integer(3)]] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(engineParse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """))
    #expect(rows.isEmpty)
  }

  @Test func `a safe non-equi before an equi still extracts the equi key`() throws {
    // SAFE-prefix — `ON A.p < B.q AND A.k = B.k`. The leading `<` is safe
    // (comparing two cells never raises), so it does not bar extraction: the
    // equi `A.k = B.k` still becomes a hash key beside the residual inequality.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "k", type: .integer),
                     EngineField(name: "p", type: .integer)],
                    [[.integer(1), .integer(5)],
                     [.integer(2), .integer(10)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer),
                     EngineField(name: "q", type: .integer)],
                    [[.integer(1), .integer(8)],
                     [.integer(2), .integer(3)]] as Array<Array<Value>>),
    ])
    let text = """
        SELECT A.k, B.q FROM A JOIN B ON A.p < B.q AND A.k = B.k
        """
    // Key pairs (1,1) with 5 < 8 kept; (2,2) with 10 < 3 dropped.
    let rows = try catalog.run(engineParse(text))
    #expect(rows == [[.integer(1), .integer(8)]])
    let compiled = try catalog.compile(engineParse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineJoins(plan))
  }

  @Test func `a pure equi ON still plans a hash join`() throws {
    // The equi fast-path is unchanged: an all-`column = column` ON extracts
    // its key and folds into a `.join`.
    let catalog = try engineFamily()
    let select = try engineParse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineJoins(plan))
  }

  @Test func `a nullable ON gate drops a pair before an unsafe WHERE`() throws {
    // `A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0`, `A.k` NULL and `A.x` = 0.
    // The residual `ON` gate `A.k < B.k` is UNKNOWN (a NULL operand), so the
    // pair is DROPPED at the gate and the `WHERE` never runs on it — no rows,
    // no raise. The gate is a distribution BARRIER: the `WHERE` stays a
    // SEPARATE `select` above the residual `ON` gate rather than fused into one
    // throwing `A.k < B.k AND (1 / A.x) = 0` over the product.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                            EngineField(name: "k", type: .integer)],
                           [[.integer(0), .null]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                           [[.integer(2)]] as Array<Array<Value>>),
    ])
    let text = "SELECT A.k FROM A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0"
    let compiled = try catalog.compile(engineParse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineSeparated(plan))
    #expect(engineResidual(plan))
    #expect(try catalog.run(engineParse(text)).isEmpty)
  }

  @Test func `a surviving ON pair still runs the unsafe WHERE`() throws {
    // CONTROL — the same `A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0`, but now
    // `A.k` = 1 and `B.k` = 2, so the `ON` gate is TRUE and the pair PASSES it.
    // The `WHERE` then runs on the surviving pair and `(1 / A.x) = 0` with
    // `A.x` = 0 raises `SQLError.divide` — the `WHERE` still applies after the
    // gate.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                            EngineField(name: "k", type: .integer)],
                           [[.integer(0), .integer(1)]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                           [[.integer(2)]] as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(engineParse("""
          SELECT A.k FROM A JOIN B ON A.k < B.k WHERE (1 / A.x) = 0
          """))
    }
  }

  @Test func `a safe WHERE over a non-equi ON join returns correct rows`()
      throws {
    // A SAFE `WHERE` over a non-equi `ON` join yields the same rows the eager
    // product filtered by both `ON` and `WHERE` would — whether or not the safe
    // `WHERE` fuses with the gate. `ON Parent.Id < Child.Pid WHERE Child.Name
    // <> 'Orphan'` pairs each parent with a later-keyed child, then drops the
    // Orphan child.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid WHERE Child.Name <> 'Orphan'
        """)
    #expect(rows == [[.text("Ada"), .text("Bob")]])
  }

  @Test func `a leftover ON match gates a pair before an unsafe WHERE`() throws {
    // `A JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE (1 / A.x) = 0`, with
    // `A.k1` matching, `A.k2` NULL, and `A.x` = 0. `nest` folds ONE equi key
    // (`A.k1 = B.k1`) into the hash `.join`, leaving `A.k2 = B.k2` as the
    // gate's own residual under the join. The surviving `k1` pair reaches that
    // leftover match, which is UNKNOWN (a NULL `A.k2`), so the pair is DROPPED
    // at the gate BEFORE the `WHERE` runs — no rows, no raise. The `ON` gate is
    // a BARRIER even though it is PURE-equi: the `WHERE` stays a SEPARATE
    // `select` above the leftover-match gate rather than fused into a throwing
    // `A.k2 = B.k2 AND (1 / A.x) = 0` that would divide by zero on the pair.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                            EngineField(name: "k1", type: .integer),
                            EngineField(name: "k2", type: .integer)],
                           [[.integer(0), .integer(1), .null]]
                             as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k1", type: .integer),
                            EngineField(name: "k2", type: .integer)],
                           [[.integer(1), .integer(5)]]
                             as Array<Array<Value>>),
    ])
    let text = """
        SELECT A.k1 FROM A
          JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE (1 / A.x) = 0
        """
    let compiled = try catalog.compile(engineParse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    // The equi key still hash-joins; the leftover match gates above it, and the
    // `WHERE` is a SEPARATE `select` above that gate, not fused with the match.
    #expect(engineJoins(plan))
    #expect(engineStacked(plan))
    #expect(try catalog.run(engineParse(text)).isEmpty)
  }

  @Test func `both ON matches passing lets the unsafe WHERE raise`() throws {
    // CONTROL — the same two-key `ON` and unsafe `WHERE`, but now BOTH keys
    // match (`A.k2` = 5 = `B.k2`), so the pair passes the whole `ON` gate. The
    // `WHERE` then runs on the surviving pair and `(1 / A.x) = 0` with `A.x`
    // = 0 raises `SQLError.divide` — the `WHERE` still applies after the gate.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                            EngineField(name: "k1", type: .integer),
                            EngineField(name: "k2", type: .integer)],
                           [[.integer(0), .integer(1), .integer(5)]]
                             as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k1", type: .integer),
                            EngineField(name: "k2", type: .integer)],
                           [[.integer(1), .integer(5)]]
                             as Array<Array<Value>>),
    ])
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(engineParse("""
          SELECT A.k1 FROM A
            JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE (1 / A.x) = 0
          """))
    }
  }

  @Test func `a two-equality pure-equi ON with a safe WHERE joins correctly`()
      throws {
    // The equi fast-path is intact under the always-barrier rule: a two-key
    // pure-equi `ON` still hash-joins (one key folded, the other gating over
    // the join) and a SAFE `WHERE` above returns the expected rows. `A.k1` and
    // `A.k2` pick out exactly the `B` row whose BOTH keys match; the `WHERE`
    // then keeps only the tagged pair.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "k1", type: .integer),
                            EngineField(name: "k2", type: .integer),
                            EngineField(name: "tag", type: .text)],
                           [[.integer(1), .integer(5), .text("keep")],
                            [.integer(1), .integer(9), .text("drop")]]
                             as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k1", type: .integer),
                            EngineField(name: "k2", type: .integer),
                            EngineField(name: "note", type: .text)],
                           [[.integer(1), .integer(5), .text("bee")],
                            [.integer(1), .integer(9), .text("cee")]]
                             as Array<Array<Value>>),
    ])
    let text = """
        SELECT A.tag, B.note FROM A
          JOIN B ON A.k1 = B.k1 AND A.k2 = B.k2 WHERE A.tag = 'keep'
        """
    let compiled = try catalog.compile(engineParse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineJoins(plan))
    #expect(try catalog.run(engineParse(text)) == [[.text("keep"), .text("bee")]])
  }

  @Test func `a single-equality ON still plans a hash join and behaves`() throws {
    // A single-equality pure-equi `ON A.k = B.k` folds its ONE key into the
    // hash `.join` and carries no leftover conjunct, so the `WHERE` sits
    // above the join. A matching pair runs the `WHERE`; a NULL key drops the
    // pair at the join, so the `WHERE` never runs on it. `A` holds a matching
    // row (`k` = 1, `x` = 1) and a NULL-key row (`k` NULL, `x` = 0): the match
    // returns the pair `WHERE A.x = 1` admits, and the NULL-key row is dropped
    // before the unsafe `(1 / A.x)` would ever divide.
    let catalog = EngineMemory([
      "A": FixtureRelation([EngineField(name: "x", type: .integer),
                            EngineField(name: "k", type: .integer)],
                           [[.integer(1), .integer(1)],
                            [.integer(0), .null]] as Array<Array<Value>>),
      "B": FixtureRelation([EngineField(name: "k", type: .integer)],
                           [[.integer(1)]] as Array<Array<Value>>),
    ])
    let text = "SELECT A.k FROM A JOIN B ON A.k = B.k WHERE (1 / A.x) = 1"
    let compiled = try catalog.compile(engineParse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(engineJoins(plan))
    #expect(try catalog.run(engineParse(text)) == [[.integer(1)]])
  }
}

// MARK: - Outer join tests

struct EngineOuterJoinTests {
  @Test func `a LEFT JOIN preserves an unmatched left row, right NULL`() throws {
    // Every parent survives; Cid, with no child, emits once with the child
    // columns NULL — the NULL-extension. Matched parents emit each pair.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
      [.text("Cid"), .null],
    ])
  }

  @Test func `LEFT OUTER JOIN is the same as LEFT JOIN`() throws {
    // The `OUTER` noise word is optional and changes nothing.
    let terse = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    let verbose = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT OUTER JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(terse == verbose)
  }

  @Test func `a RIGHT JOIN preserves an unmatched right row, left NULL`() throws {
    // Every child survives, right-major; the Orphan (Pid 9) has no parent and
    // emits once with the parent columns NULL.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          RIGHT JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
      [.null, .text("Orphan")],
    ])
  }

  @Test func `a FULL JOIN preserves the unmatched rows of both sides`() throws {
    // The left-major pairs and the childless Cid (right NULL), then the
    // parentless Orphan (left NULL) — both sides' unmatched rows survive.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          FULL JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
      [.text("Cid"), .null],
      [.null, .text("Orphan")],
    ])
  }

  @Test func `an ON conjunct keeps an unmatched left row a WHERE would drop`() throws {
    // ON vs WHERE. Restricting the MATCH with `AND Child.Name = 'Amy'` keeps
    // every parent — the ON governs matching alone, so a parent that now
    // matches no child is still emitted NULL-extended. Only Ada matches Amy.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id AND Child.Name = 'Amy'
        """)
    #expect(rows == [
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .null],
      [.text("Cid"), .null],
    ])
  }

  @Test func `the same predicate in WHERE drops the unmatched rows`() throws {
    // Moving the predicate to a post-join WHERE filters AFTER the outer join,
    // so the NULL-extended rows (whose Child.Name is NULL) fail `= 'Amy'` and
    // drop — turning the LEFT join back to inner-like. This is the ON-vs-WHERE
    // distinction the outer join preserves.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id WHERE Child.Name = 'Amy'
        """)
    #expect(rows == [[.text("Ada"), .text("Amy")]])
  }

  @Test func `a WHERE IS NULL over a LEFT join finds the unmatched rows`() throws {
    // The anti-join idiom: a LEFT join then `WHERE Child.Name IS NULL` keeps
    // only the parents with no child — Cid.
    let rows = try engineJoin("""
        SELECT Parent.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id WHERE Child.Name IS NULL
        """)
    #expect(rows == [[.text("Cid")]])
  }

  @Test func `a LEFT JOIN with a non-equi ON preserves unmatched rows`() throws {
    // Outer joins compose with Part 1's non-equi ON: `ON Parent.Id > Child.Pid`
    // pairs each parent with the children below it, and NULL-extends a parent
    // that dominates none. Child Pids are 1,1,2,9. Ada(1) > none; Bee(2) >
    // Pid 1 (Ann, Amy); Cid(3) > Pids 1,1,2 (Ann, Amy, Bob).
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Parent.Id > Child.Pid
        """)
    #expect(rows == [
      [.text("Ada"), .null],
      [.text("Bee"), .text("Ann")],
      [.text("Bee"), .text("Amy")],
      [.text("Cid"), .text("Ann")],
      [.text("Cid"), .text("Amy")],
      [.text("Cid"), .text("Bob")],
    ])
  }

  @Test func `a LEFT JOIN plans an outer node, not a distributed product`() throws {
    // The ON must stay on the outer node — never distributed into a product or
    // nested into a hash join — or an unmatched row would be dropped. So the
    // plan reaches an `.outer` node and NOT a `.join`.
    let catalog = try engineFamily()
    let select = try engineParse("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(outers(plan))
    #expect(!engineJoins(plan))
  }

  @Test func `an inner join then a LEFT join preserves the middle unmatched`() throws {
    // A mixed chain: House JOIN Room (inner) then LEFT JOIN Item. The empty
    // Attic (no item) survives the LEFT join NULL-extended, while the inner
    // House-Room pairs are formed first.
    let rows = try engineLineage("""
        SELECT House.House, Room.Room, Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          LEFT JOIN Item ON Item.Rid = Room.Id
        """)
    #expect(rows == [
      [.text("Burrow"), .text("Kitchen"), .text("Kettle")],
      [.text("Burrow"), .text("Kitchen"), .text("Pot")],
      [.text("Burrow"), .text("Attic"), .null],
      [.text("Manor"), .text("Hall"), .text("Banner")],
    ])
  }

  @Test func `an empty right side NULL-extends every left row`() throws {
    // With no child matching, a LEFT join still emits every parent, right
    // NULL — the width comes from the plan, not from a right row.
    let rows = try engineJoin("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = 999
        """)
    #expect(rows == [
      [.text("Ada"), .null],
      [.text("Bee"), .null],
      [.text("Cid"), .null],
    ])
  }
}

/// Whether `plan` reaches an `.outer` node — the outer-join operator.
private func outers(_ plan: Plan) -> Bool {
  switch plan {
  case .outer:
    true
  case let .select(_, source):
    outers(source)
  case let .project(_, source):
    outers(source)
  case let .sort(_, source):
    outers(source)
  case let .limit(_, _, source):
    outers(source)
  case let .distinct(source):
    outers(source)
  case let .derived(_, sub, _, _):
    outers(sub)
  case let .product(left, right):
    outers(left) || outers(right)
  case let .join(source, _, _, _, _, _, _):
    outers(source)
  case let .semijoin(left, right, _, _):
    outers(left) || outers(right)
  case let .apply(left, _, _, _, _, _):
    outers(left)
  case let .setop(_, left, right, _, _, _):
    outers(left) || outers(right)
  case let .aggregate(_, _, source):
    outers(source)
  case .single, .empty, .scan:
    false
  }
}

// MARK: - Multi-way join tests

struct EngineMultiJoinTests {
  @Test func `a three-relation chain joins across two foreign keys`() throws {
    let rows = try engineLineage("""
        SELECT House.House, Room.Room, Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
        """)
    // Burrow's Kitchen holds the Kettle and Pot; its Attic is empty. Manor's
    // Hall holds the Banner. The item with no room (Rid 9) drops out.
    #expect(rows == [
      [.text("Burrow"), .text("Kitchen"), .text("Kettle")],
      [.text("Burrow"), .text("Kitchen"), .text("Pot")],
      [.text("Manor"), .text("Hall"), .text("Banner")],
    ])
  }

  @Test func `a chain seeks each inner relation keyed on its sorted column`() throws {
    // Walking the chain the other way: `Item` is the outer scan, and both inner
    // relations are seeked on their sorted `Id` — the multi-way nest rewrite
    // turning every `Select`-over-`Product` level into an index-nested loop.
    let rows = try engineLineage("""
        SELECT Item.Item, Room.Room, House.House FROM Item
          JOIN Room ON Room.Id = Item.Rid
          JOIN House ON House.Id = Room.Hid
        """)
    #expect(rows == [
      [.text("Kettle"), .text("Kitchen"), .text("Burrow")],
      [.text("Pot"), .text("Kitchen"), .text("Burrow")],
      [.text("Banner"), .text("Hall"), .text("Manor")],
    ])
  }

  @Test func `a WHERE filters across a three-relation chain`() throws {
    try engineLineage().expect("""
        SELECT Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
          WHERE House.House = 'Burrow' AND Item.Item = 'Pot'
        """,
        yields: [["Pot"]])
  }

  @Test func `an unqualified name in more than one relation of a chain is ambiguous`() throws {
    // `Id` sits in both `House` and `Room`; across the chain it resolves in more
    // than one relation, so an unqualified reference is ambiguous.
    #expect(throws: SQLError.ambiguous("Id")) {
      try engineLineage("""
          SELECT Id FROM House
            JOIN Room ON Room.Hid = House.Id
            JOIN Item ON Item.Rid = Room.Id
          """)
    }
  }

  @Test func `an early ON referencing a not-yet-joined relation is rejected`() throws {
    // The first join's `ON` qualifies a column with `Item`, a relation joined
    // only LATER. Resolving the match against just the prefix — `House` and
    // `Room` — the qualifier names no relation in scope, so the query is
    // rejected (`SQLError.column`) rather than resolving `Item`'s slot from a
    // product that does not yet contain it and trapping or indexing wrong.
    #expect(throws: SQLError.column("Rid")) {
      try engineLineage("""
          SELECT House.House FROM House
            JOIN Room ON Item.Rid = House.Id
            JOIN Item ON Item.Rid = Room.Id
          """)
    }
  }

  @Test func `a valid early ON whose columns are all in its prefix runs`() throws {
    // Each `ON` references only the prefix it resolves against, so the whole
    // chain compiles and runs — mirroring `chain`, which the prefix-scope fix
    // leaves unchanged.
    let rows = try engineLineage("""
        SELECT House.House, Room.Room, Item.Item FROM House
          JOIN Room ON Room.Hid = House.Id
          JOIN Item ON Item.Rid = Room.Id
        """)
    #expect(rows == [
      [.text("Burrow"), .text("Kitchen"), .text("Kettle")],
      [.text("Burrow"), .text("Kitchen"), .text("Pot")],
      [.text("Manor"), .text("Hall"), .text("Banner")],
    ])
  }

  @Test func `an unqualified early-ON column a later relation shares is not ambiguous`() throws {
    // The first join's `ON` reads unqualified `Code`, unique within its prefix
    // `{Author, Book}` even though `Sale` — joined only later — also carries a
    // `Code`. Resolving the match against the prefix binds it; resolving against
    // the whole chain would see two `Code`s and report `SQLError.ambiguous`.
    try engineShared().expect("""
        SELECT Author.Aid, Book.Bid, Sale.Code FROM Author
          JOIN Book ON Code = Book.Aid
          JOIN Sale ON Sale.Sid = Book.Bid
        """,
        yields: [[1, 100, 900], [2, 101, 901]])
  }
}

