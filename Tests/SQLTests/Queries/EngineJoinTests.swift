// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Join tests

struct EngineJoinTests {
  @Test func `a join on a foreign key pairs each child with its parent`() throws {
    let rows = try join("""
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
    try family().expect("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """,
        yields: [["Ada", "Ann"], ["Ada", "Amy"], ["Bee", "Bob"]])
  }

  @Test func `a join keys off the inner relation's virtual Id`() throws {
    // `Ordered` has no stored key; its identity is its 1-based `Id`. The
    // child's `Pid` joins to that virtual column.
    let rows = try join("""
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
    let rows = try join("""
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
    try family().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          WHERE Parent.Name = 'Ada' AND Child.Name = 'Amy'
        """,
        yields: [["Amy"]])
  }

  @Test func `ORDER BY orders across the join`() throws {
    try family().expect("""
        SELECT Child.Name FROM Parent JOIN Child ON Child.Pid = Parent.Id
          ORDER BY Child.Name ASC
        """,
        yields: [["Amy"], ["Ann"], ["Bob"]])
  }

  @Test func `an unqualified name in both relations is ambiguous`() throws {
    #expect(throws: SQLError.ambiguous("Name")) {
      try join("SELECT Name FROM Parent JOIN Child ON Child.Pid = Parent.Id")
    }
  }

  @Test func `a self-join's shared table name makes a qualified name ambiguous`() throws {
    #expect(throws: SQLError.ambiguous("Id")) {
      try join("""
          SELECT Parent.Name FROM Parent JOIN Parent ON Parent.Id = Parent.Id
          """)
    }
  }

  @Test func `a duplicated alias makes a shared qualified column ambiguous`() throws {
    // `x.Pid` resolves by column (the Child side only); `x.Name` is on both,
    // so the shared alias is ambiguous rather than binding silently to outer.
    #expect(throws: SQLError.ambiguous("Name")) {
      try join("""
          SELECT x.Name FROM Parent AS x JOIN Child AS x ON x.Pid = x.Pid
          """)
    }
  }

  @Test func `a parent with no matching child contributes no rows`() throws {
    let rows = try join("""
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
    let seek = try join("""
        SELECT Parent.Name, Child.Name FROM Child
          JOIN Parent ON Parent.Id = Child.Pid ORDER BY Child.Name ASC
        """)
    let scan = try join("""
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
    let rows = try join("""
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
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Parent.Id < Child.Pid
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!joined(plan))
    #expect(residue(plan))
  }

  @Test func `a mixed ON hashes the equi conjunct and filters the residual`() throws {
    // `ON Child.Pid = Parent.Id AND Child.Name < 'B'`: the equality hash-joins
    // each child to its parent; the residual inequality beside the key then
    // keeps only pairs whose child name sorts before 'B' — dropping Bob, the
    // sole B-name.
    let rows = try join("""
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
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id AND Parent.Name < Child.Name
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))
  }

  @Test func `an expression equality ON is a residual, not a hash key`() throws {
    // `ON Child.Pid = Parent.Id + 1` equates a column with an EXPRESSION, so
    // it is not a bare `column = column` key: it lowers to a residual over the
    // product (nested loop), not a hash join.
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id + 1
        """)
    // Parent 1 (Ada) → Pid 2: Bob. Parent 2 (Bee) → Pid 3: none.
    // Parent 3 (Cid) → Pid 4: none.
    #expect(rows == [[.text("Ada"), .text("Bob")]])
  }

  @Test func `an expression equality ON plans a residual product`() throws {
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id + 1
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!joined(plan))
    #expect(residue(plan))
  }

  @Test func `a non-equi ON equals the eager product filtered`() throws {
    // The nested-loop join over an inequality must yield exactly the eager
    // cross product filtered by the same predicate, in outer-major order.
    let catalog = try family()
    let parents = try catalog.run(parse("SELECT Name, Id FROM Parent"))
    let children = try catalog.run(parse("SELECT Name, Pid FROM Child"))
    var expected = Array<Array<Value>>()
    for parent in parents {
      for child in children where less(parent[1], child[1]) {
        expected.append([parent[0], child[0]])
      }
    }
    let rows = try catalog.run(parse("""
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
      _ = try catalog.run(parse("""
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
    let select = try parse("""
        SELECT A.k FROM A JOIN B ON (1 / A.x) = 0 AND A.k = B.k
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!joined(plan))
    #expect(residue(plan))
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
    let compiled = try catalog.compile(parse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!joined(plan))
    #expect(residue(plan))
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
    let compiled = try catalog.compile(parse("""
        SELECT A.k FROM A JOIN B ON A.k = B.k AND (1 / A.x) = 0
        """))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(!joined(plan))
    #expect(residue(plan))
    #expect(throws: SQLError.divide) {
      _ = try catalog.run(parse("""
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
    let rows = try catalog.run(parse("""
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
    let rows = try catalog.run(parse(text))
    #expect(rows == [[.integer(1), .integer(8)]])
    let compiled = try catalog.compile(parse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))
  }

  @Test func `a pure equi ON still plans a hash join`() throws {
    // The equi fast-path is unchanged: an all-`column = column` ON extracts
    // its key and folds into a `.join`.
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          JOIN Child ON Child.Pid = Parent.Id
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))
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
    let compiled = try catalog.compile(parse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(separated(plan))
    #expect(residue(plan))
    #expect(try catalog.run(parse(text)).isEmpty)
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
      _ = try catalog.run(parse("""
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
    let rows = try join("""
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
    let compiled = try catalog.compile(parse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    // The equi key still hash-joins; the leftover match gates above it, and the
    // `WHERE` is a SEPARATE `select` above that gate, not fused with the match.
    #expect(joined(plan))
    #expect(stacked(plan))
    #expect(try catalog.run(parse(text)).isEmpty)
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
      _ = try catalog.run(parse("""
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
    let compiled = try catalog.compile(parse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))
    #expect(try catalog.run(parse(text)) == [[.text("keep"), .text("bee")]])
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
    let compiled = try catalog.compile(parse(text))
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(joined(plan))
    #expect(try catalog.run(parse(text)) == [[.integer(1)]])
  }
}

// MARK: - Outer join tests

struct EngineOuterJoinTests {
  @Test func `a LEFT JOIN preserves an unmatched left row, right NULL`() throws {
    // Every parent survives; Cid, with no child, emits once with the child
    // columns NULL — the NULL-extension. Matched parents emit each pair.
    let rows = try join("""
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
    let terse = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    let verbose = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT OUTER JOIN Child ON Child.Pid = Parent.Id
        """)
    #expect(terse == verbose)
  }

  @Test func `a RIGHT JOIN preserves an unmatched right row, left NULL`() throws {
    // Every child survives, right-major; the Orphan (Pid 9) has no parent and
    // emits once with the parent columns NULL.
    let rows = try join("""
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
    let rows = try join("""
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
    let rows = try join("""
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
    let rows = try join("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id WHERE Child.Name = 'Amy'
        """)
    #expect(rows == [[.text("Ada"), .text("Amy")]])
  }

  @Test func `a WHERE IS NULL over a LEFT join finds the unmatched rows`() throws {
    // The anti-join idiom: a LEFT join then `WHERE Child.Name IS NULL` keeps
    // only the parents with no child — Cid.
    let rows = try join("""
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
    let rows = try join("""
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
    let catalog = try family()
    let select = try parse("""
        SELECT Parent.Name, Child.Name FROM Parent
          LEFT JOIN Child ON Child.Pid = Parent.Id
        """)
    let compiled = try catalog.compile(select)
    let plan = try catalog.optimise(compiled.pushdown(), [:])
    #expect(outers(plan))
    #expect(!joined(plan))
  }

  @Test func `an inner join then a LEFT join preserves the middle unmatched`() throws {
    // A mixed chain: House JOIN Room (inner) then LEFT JOIN Item. The empty
    // Attic (no item) survives the LEFT join NULL-extended, while the inner
    // House-Room pairs are formed first.
    let rows = try lineage("""
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
    let rows = try join("""
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
    let rows = try lineage("""
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
    let rows = try lineage("""
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
    try lineage().expect("""
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
      try lineage("""
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
      try lineage("""
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
    let rows = try lineage("""
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
    try shared().expect("""
        SELECT Author.Aid, Book.Bid, Sale.Code FROM Author
          JOIN Book ON Code = Book.Aid
          JOIN Sale ON Sale.Sid = Book.Bid
        """,
        yields: [[1, 100, 900], [2, 101, 901]])
  }
}

// MARK: - NATURAL and USING join tests

/// A catalog of relations sharing column NAMES, so a `NATURAL`/`USING` join has
/// common columns to key on. `Emp(Dept, Name)` and `Team(Dept, Lead)` share
/// `Dept`; `Lhs(K, G, A)` and `Rhs(K, G, B)` share `K` and `G`; `Solo(x)`
/// and `Other(y)` share nothing (a `NATURAL` join over them degenerates to a
/// product). `Team` has a `Dept` (30) no `Emp` names, and `Emp` a `Dept` (10)
/// no `Team` names, so an outer join has an unmatched row on each side.
/// `Bonus(Dept, Amt)` names every `Dept` (10, 20, 30), so a THIRD `USING
/// (Dept)` join after an outer `Emp`/`Team` one keys each surviving row —
/// including an unmatched left/right one — on the merged `Dept`.
private func named() throws -> FixtureCatalog {
  try Catalog {
    Relation("Emp", ["Dept": .integer, "Name": .text]) {
      Row(10, "Ann")
      Row(20, "Bob")
      Row(20, "Cid")
    }
    Relation("Team", ["Dept": .integer, "Lead": .text]) {
      Row(20, "Deb")
      Row(30, "Eve")
    }
    Relation("Lhs", ["K": .integer, "G": .text, "A": .text]) {
      Row(1, "x", "a1")
      Row(2, "y", "a2")
    }
    Relation("Rhs", ["K": .integer, "G": .text, "B": .text]) {
      Row(1, "x", "b1")
      Row(2, "z", "b2")
    }
    Relation("Solo", ["x": .integer]) {
      Row(1)
      Row(2)
    }
    Relation("Other", ["y": .text]) {
      Row("p")
      Row("q")
    }
    Relation("Bonus", ["Dept": .integer, "Amt": .integer]) {
      Row(10, 50)
      Row(20, 100)
      Row(30, 200)
    }
  }
}

struct EngineNaturalUsingTests {
  @Test func `INNER USING (c) merges the column once, first, then rests`() throws {
    // Output column list (ISO 7.10): the USING column `Dept` ONCE and FIRST,
    // then the left's other columns (`Name`), then the right's (`Lead`). Rows
    // join on `Dept` equality — only Dept 20 matches on both sides.
    try named().expect("SELECT * FROM Emp JOIN Team USING (Dept)",
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `USING (c1, c2) keys on both columns`() throws {
    // The join columns `K, G` come first in order, then `Lhs`'s `A`, then
    // `Rhs`'s `B`. Only the (1, x) row agrees on BOTH columns.
    try named().expect("""
        SELECT * FROM Lhs JOIN Rhs USING (K, G)
        """,
        yields: [[1, "x", "a1", "b1"]])
  }

  @Test func `NATURAL INNER joins on the one shared column`() throws {
    // `Emp` and `Team` share only `Dept`, so `NATURAL JOIN` is `USING (Dept)`:
    // the merged `Dept` first, then `Name`, then `Lead`.
    try named().expect("SELECT * FROM Emp NATURAL JOIN Team",
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `NATURAL with two common columns keys on both`() throws {
    // `Lhs` and `Rhs` share `K` and `G` (in `Lhs`'s order), so the merged
    // `K, G` come first, then `A`, then `B` — the same as `USING (K, G)`.
    try named().expect("SELECT * FROM Lhs NATURAL JOIN Rhs",
        yields: [[1, "x", "a1", "b1"]])
  }

  @Test func `NATURAL with no common column is a CROSS product`() throws {
    // `Solo(x)` and `Other(y)` share nothing, so `NATURAL JOIN` degenerates
    // to a Cartesian product (ISO), NOT a fault: every left row paired with
    // every right row, the output being every column of both.
    try named().expect("SELECT * FROM Solo NATURAL JOIN Other",
        yields: [
          [1, "p"],
          [1, "q"],
          [2, "p"],
          [2, "q"],
        ])
  }

  @Test func `LEFT OUTER USING shows the left value in the merged column`() throws {
    // `Emp` Dept 10 has no `Team` match; a LEFT join keeps it, and the merged
    // `Dept` = COALESCE(Emp.Dept, Team.Dept) shows the left's 10 while `Lead`
    // NULL-extends.
    try named().expect("""
        SELECT * FROM Emp LEFT JOIN Team USING (Dept)
        """,
        yields: [
          [10, "Ann", nil],
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `RIGHT OUTER USING shows the right value in the merged column`() throws {
    // `Team` Dept 30 has no `Emp` match; a RIGHT join keeps it, and the merged
    // `Dept` = COALESCE(Emp.Dept, Team.Dept) shows the right's 30 even though
    // the left `Emp.Dept` is NULL there. `Name` NULL-extends.
    try named().expect("""
        SELECT * FROM Emp RIGHT JOIN Team USING (Dept)
        """,
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
          [30, nil, "Eve"],
        ])
  }

  @Test func `FULL OUTER NATURAL merges each side's unmatched value`() throws {
    // Both unmatched rows survive: `Emp` Dept 10 (left-only, merged `Dept` =
    // 10, `Lead` NULL) and `Team` Dept 30 (right-only, merged `Dept` = 30 via
    // COALESCE though `Emp.Dept` is NULL, `Name` NULL).
    try named().expect("SELECT * FROM Emp NATURAL FULL OUTER JOIN Team",
        yields: [
          [10, "Ann", nil],
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
          [30, nil, "Eve"],
        ])
  }

  @Test func `USING a column absent from one side faults`() throws {
    // `Name` is on `Emp` but not `Team`, so `USING (Name)` names a column the
    // right side does not resolve — a column fault.
    try named().expect("SELECT * FROM Emp JOIN Team USING (Name)",
        fails: .column("Name"))
  }

  @Test func `USING is case-insensitive in the column name`() throws {
    // The join column matches case-insensitively, as the engine's identifier
    // resolution does, so `USING (dept)` keys on `Dept`.
    try named().expect("SELECT * FROM Emp JOIN Team USING (dept)",
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `a qualified reference still reaches each side's own column`() throws {
    // An explicit projection resolves columns by the ordinary rules over the
    // synthesized `ON` join, so a qualified `Emp.Dept`/`Team.Dept` still names
    // each side's own column (both equal on a matched row).
    try named().expect("""
        SELECT Emp.Dept, Team.Dept, Name FROM Emp JOIN Team USING (Dept)
        """,
        yields: [
          [20, 20, "Bob"],
          [20, 20, "Cid"],
        ])
  }

  @Test func `a bare reference to a merged column resolves to the coalesced value`() throws {
    // ISO 9075 7.10: the USING/NATURAL common column is an exposed name of the
    // join result belonging to NEITHER side, so a BARE `Dept` resolves to the
    // ONE coalesced column — UNAMBIGUOUSLY — not to `Emp.Dept` or `Team.Dept`.
    try named().expect("SELECT Dept FROM Emp JOIN Team USING (Dept)",
        yields: [[20], [20]])
  }

  @Test func `a bare merged reference resolves in WHERE`() throws {
    // The exposed name resolves in a `WHERE` too — `Dept = 20` filters on the
    // coalesced value, keeping only the matched rows.
    try named().expect("""
        SELECT Name FROM Emp JOIN Team USING (Dept) WHERE Dept = 20
        """,
        yields: [["Bob"], ["Cid"]])
  }

  @Test func `a bare merged reference resolves in ORDER BY`() throws {
    // The exposed name resolves in an `ORDER BY` — a FULL join's rows sort by
    // the coalesced `Dept`, the left-only (10) and right-only (30) unmatched
    // rows ordered alongside the matched (20) ones.
    try named().expect("""
        SELECT Name FROM Emp NATURAL FULL OUTER JOIN Team ORDER BY Dept
        """,
        yields: [["Ann"], ["Bob"], ["Cid"], [nil]])
  }

  @Test func `a bare merged reference resolves in GROUP BY`() throws {
    // The exposed name resolves as a `GROUP BY` key — the matched Dept 20 rows
    // form one group of two.
    try named().expect("""
        SELECT Dept, COUNT(*) FROM Emp JOIN Team USING (Dept) GROUP BY Dept
        """,
        yields: [[20, 2]])
  }

  @Test func `a bare merged reference in a LEFT join yields the coalesced value`() throws {
    // A LEFT join keeps the left-only Dept 10; the exposed bare `Dept` shows
    // the coalesced value (the left's 10), matching the `SELECT *` merged
    // column.
    try named().expect("""
        SELECT Dept FROM Emp LEFT JOIN Team USING (Dept)
        """,
        yields: [[10], [20], [20]])
  }

  @Test func `a bare merged reference in a RIGHT join yields the coalesced value`() throws {
    // A RIGHT join keeps the right-only Dept 30; the exposed bare `Dept` shows
    // the coalesced value (the right's 30) even where the left `Emp.Dept` is
    // NULL.
    try named().expect("""
        SELECT Dept FROM Emp RIGHT JOIN Team USING (Dept)
        """,
        yields: [[20], [20], [30]])
  }

  @Test func `a bare merged reference in a FULL join yields each side's value`() throws {
    // A FULL join keeps both unmatched rows; the exposed bare `Dept` shows the
    // coalesced value on each — the left's 10 (right NULL) and the right's 30
    // (left NULL).
    try named().expect("""
        SELECT Dept FROM Emp NATURAL FULL OUTER JOIN Team
        """,
        yields: [[10], [20], [20], [30]])
  }

  @Test func `a bare reference to each of two merged columns resolves`() throws {
    // A NATURAL join over two common columns exposes BOTH `K` and `G`; a bare
    // reference to each resolves to its coalesced value (equal on the one
    // matched row).
    try named().expect("""
        SELECT K, G FROM Lhs NATURAL JOIN Rhs
        """,
        yields: [[1, "x"]])
  }

  @Test func `a bare reference to a shared but non-join column stays ambiguous`() throws {
    // The scoping guard (ISO 9075 7.10): ONLY the join columns are exposed.
    // `Lhs` and `Rhs` share `K` and `G`, but `USING (K)` joins on `K` alone —
    // so bare `G`, shared yet NOT a join column, stays AMBIGUOUS between the
    // two sides rather than collapsing to a merged value.
    try named().expect("""
        SELECT G FROM Lhs JOIN Rhs USING (K)
        """,
        fails: .ambiguous("G"))
  }

  @Test func `a qualified reference is not merged when its name is a join column`() throws {
    // The exposed name is UNqualified; a qualified `Lhs.G`/`Rhs.G` still names
    // its own side even when the sibling `K` is a join column — merging is
    // scoped to the bare join-column name alone.
    try named().expect("""
        SELECT Lhs.G, Rhs.G FROM Lhs JOIN Rhs USING (K)
        """,
        yields: [["x", "x"], ["y", "z"]])
  }

  // MARK: - Aliased ranges (finding 1)

  @Test func `an aliased FROM side resolves a USING join`() throws {
    // The synthesized `ON` and coalesced `SELECT *` qualify by the RANGE name
    // (the alias `e`), the only name the scope admits, so `Emp AS e JOIN Team
    // USING (Dept)` resolves rather than faulting on an unqualifiable
    // `Emp.Dept`.
    try named().expect("""
        SELECT * FROM Emp AS e JOIN Team USING (Dept)
        """,
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `an aliased JOINED side resolves a USING join`() throws {
    // The joined side's references qualify by its range name (`t`) too, so
    // `Emp JOIN Team AS t USING (Dept)` resolves.
    try named().expect("""
        SELECT * FROM Emp JOIN Team AS t USING (Dept)
        """,
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `a projection qualified by an alias resolves over a USING join`() throws {
    // Both sides aliased: a qualified `e.Name` resolves to its side and a bare
    // merged `Dept` to the coalesced value, all over the aliased ranges.
    try named().expect("""
        SELECT e.Name, Dept FROM Emp AS e JOIN Team AS t USING (Dept)
        """,
        yields: [
          ["Bob", 20],
          ["Cid", 20],
        ])
  }

  // MARK: - Set-operation arity over the merged width (finding 2)

  @Test func `a UNION over a USING join measures the merged width`() throws {
    // The `SELECT *` arm's width is the MERGED count (3 — `Dept` once), so a
    // 3-column second arm aligns and the UNION succeeds. Before the desugar ran
    // ahead of the arity check, the `*` measured both physical `Dept`s (4) and
    // wrongly rejected the valid set operation.
    try named().expect("""
        SELECT * FROM Emp JOIN Team USING (Dept)
        UNION SELECT Dept, Name, Lead FROM Emp JOIN Team USING (Dept)
        """,
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `a UNION whose arms differ post-merge still faults arity`() throws {
    // A genuinely mismatched set operation — a 3-wide merged `*` against a
    // 2-column arm — still faults, measured at the merged width.
    try named().expect("""
        SELECT * FROM Emp JOIN Team USING (Dept)
        UNION SELECT Dept, Name FROM Emp JOIN Team USING (Dept)
        """,
        fails: .arity(3, 2))
  }

  // MARK: - Exposed IN and quantified outer operand (finding 3)

  @Test func `a bare merged reference resolves as an IN operand`() throws {
    // The outer operand of `IN (subquery)` resolves in THIS query's scope, so
    // a bare merged `Dept` is exposed to the coalesced value — not left
    // ambiguous between the two physical sides.
    try named().expect("""
        SELECT Name FROM Emp JOIN Team USING (Dept)
        WHERE Dept IN (SELECT Dept FROM Team)
        """,
        yields: [["Bob"], ["Cid"]])
  }

  @Test func `a bare merged reference resolves as a quantified operand`() throws {
    // As `IN`, the `= ANY (subquery)` outer operand is exposed to the merged
    // value.
    try named().expect("""
        SELECT Name FROM Emp JOIN Team USING (Dept)
        WHERE Dept = ANY (SELECT Dept FROM Team)
        """,
        yields: [["Bob"], ["Cid"]])
  }

  // MARK: - Coalesced key carried into a later join (finding 4)

  @Test func `a chained USING join keys a RIGHT-only row on the merged value`() throws {
    // `Emp RIGHT JOIN Team USING (Dept)` keeps the right-only Dept 30 (left
    // `Emp.Dept` NULL); the next `JOIN Bonus USING (Dept)` keys on the MERGED
    // `Dept`, so that row still joins `Bonus` (Amt 200) rather than being
    // dropped on a NULL left key.
    try named().expect("""
        SELECT * FROM Emp RIGHT JOIN Team USING (Dept) JOIN Bonus USING (Dept)
        """,
        yields: [
          [20, "Bob", "Deb", 100],
          [20, "Cid", "Deb", 100],
          [30, nil, "Eve", 200],
        ])
  }

  @Test func `a chained USING join keys a FULL join's unmatched rows on the merged value`() throws {
    // A FULL first join keeps BOTH unmatched rows — Dept 10 (left-only) and 30
    // (right-only); the chained `Bonus` join keys each on the merged `Dept`, so
    // both still join (Amt 50 and 200).
    try named().expect("""
        SELECT * FROM Emp FULL JOIN Team USING (Dept) JOIN Bonus USING (Dept)
        """,
        yields: [
          [10, "Ann", nil, 50],
          [20, "Bob", "Deb", 100],
          [20, "Cid", "Deb", 100],
          [30, nil, "Eve", 200],
        ])
  }

  // MARK: - Duplicate USING names (finding 5)

  @Test func `a repeated USING column faults rather than crashing`() throws {
    // `USING (Dept, Dept)` names one merged column twice; the duplicate is
    // caught BEFORE the output dictionary the merged names key would trap on,
    // faulting `.duplicate` rather than aborting the process.
    try named().expect("""
        SELECT * FROM Emp JOIN Team USING (Dept, Dept)
        """,
        fails: .duplicate("Dept"))
  }

  @Test func `a NATURAL join after a plain join with two like-named columns faults`() throws {
    // `Emp JOIN Team ON …` leaves the left side carrying TWO columns named
    // `Dept`; a following `NATURAL JOIN Bonus` would merge `Dept` twice — the
    // duplicate is caught and faults `.duplicate` rather than trapping.
    try named().expect("""
        SELECT * FROM Emp JOIN Team ON Emp.Dept = Team.Dept
        NATURAL JOIN Bonus
        """,
        fails: .duplicate("Dept"))
  }

  // MARK: - Grouping a RIGHT/FULL merged column by the merged value (finding 6)

  @Test func `a RIGHT join groups a bare merged column by the coalesced value`() throws {
    // The right-only Dept 30 (left `Emp.Dept` NULL) groups and projects by the
    // MERGED value 30, not NULL — the `GROUP BY` key is the coalesced value the
    // projection emits.
    try named().expect("""
        SELECT Dept, COUNT(*) FROM Emp RIGHT JOIN Team USING (Dept)
        GROUP BY Dept
        """,
        yields: [
          [20, 2],
          [30, 1],
        ])
  }

  @Test func `a FULL join groups a bare merged column by the coalesced value`() throws {
    // Both unmatched rows group by their merged value — the left-only 10 and
    // the right-only 30 — each its own group, not collapsed to NULL.
    try named().expect("""
        SELECT Dept, COUNT(*) FROM Emp FULL JOIN Team USING (Dept)
        GROUP BY Dept
        """,
        yields: [
          [10, 1],
          [20, 2],
          [30, 1],
        ])
  }

  // MARK: - Accumulated-left ambiguity (finding 1)

  @Test func `a USING column a plain join bound twice on the left faults`() throws {
    // A plain `ON` join leaves the accumulated left carrying TWO columns named
    // `Dept` (`Emp.Dept` and `Team.Dept`); a following `JOIN Bonus USING
    // (Dept)` keys `Dept` on that left — which binds it TWICE — so it faults
    // `.ambiguous` at construction rather than trapping a downstream build.
    try named().expect("""
        SELECT * FROM Emp JOIN Team ON Emp.Dept = Team.Dept
        JOIN Bonus USING (Dept)
        """,
        fails: .ambiguous("Dept"))
  }

  // MARK: - A merged name a later plain join re-collides with (finding 2)

  @Test func `a qualified name a later plain join adds over a merged one resolves`() throws {
    // A `USING (Dept)` merges `Dept`; a later plain `JOIN Bonus AS C ON …`
    // brings its OWN physical `C.Dept`. A QUALIFIED `C.Dept` names that side
    // unambiguously and resolves — never a crash — even though a bare `Dept`
    // would now be ambiguous between the merged column and `C.Dept`.
    try named().expect("""
        SELECT C.Dept FROM Emp JOIN Team USING (Dept)
        JOIN Bonus AS C ON C.Dept = Emp.Dept
        """,
        yields: [[20], [20]])
  }

  @Test func `a bare name a later plain join re-collides with a merged one faults`() throws {
    // The bare counterpart: with the merged `Dept` AND the later plain join's
    // physical `C.Dept` both in scope, a bare `Dept` names two columns and
    // faults `.ambiguous` — surfacing at lookup, NEVER a crash.
    try named().expect("""
        SELECT Dept FROM Emp JOIN Team USING (Dept)
        JOIN Bonus AS C ON C.Dept = Emp.Dept
        """,
        fails: .ambiguous("Dept"))
  }

  // MARK: - ORDER BY alias precedence over a merged key (finding 3)

  @Test func `ORDER BY binds a projection alias before the merged key`() throws {
    // `SELECT Name AS Dept … ORDER BY Dept` sorts by the PROJECTED alias
    // `Name`, not the coalesced merged `Dept` key — the bare `ORDER BY` key
    // reaches the resolver's alias-first binding before the scope's merged
    // column, since there is no pre-rewrite substituting the key for the
    // coalesce. The names sort opposite to the departments, so the two orders
    // are distinguishable: alphabetical `Ann, Bob, Cid` (by alias), not `Bob
    // (10), Cid (20), Ann (30)` (by the merged Dept).
    let catalog = try Catalog {
      Relation("Emp", ["Dept": .integer, "Name": .text]) {
        Row(30, "Ann")
        Row(10, "Bob")
        Row(20, "Cid")
      }
      Relation("Team", ["Dept": .integer, "Lead": .text]) {
        Row(10, "L1")
        Row(20, "L2")
        Row(30, "L3")
      }
    }
    try catalog.expect("""
        SELECT Name AS Dept FROM Emp JOIN Team USING (Dept) ORDER BY Dept
        """,
        yields: [["Ann"], ["Bob"], ["Cid"]])
  }

  // MARK: - Merged columns under schema VALIDATION (finding A)

  @Test func `a bare merged reference type-checks under validation`() throws {
    // The run lowers a bare merged `Dept` in the `WHERE` through `Scope.term`
    // to the coalesced value; `columns(of:validate:true)` — whose type-check
    // walk validates the `WHERE` through the SAME merged-aware bare-name
    // lookup — must resolve it too, not fault `.ambiguous`. The schema names
    // the projected `Name` (text) and does not throw.
    let text = """
        SELECT Name FROM Emp JOIN Team USING (Dept) WHERE Dept = 20
        """
    let columns = try named()
        .columns(of: Statement(parsing: text), validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "Name")
    #expect(columns[0].type == .text)
  }

  @Test func `a bare merged reference in the projection type-checks`() throws {
    // The merged `Dept` PROJECTED and type-checked: the schema resolves it to
    // the unified coalesce type (`integer`) rather than faulting `.ambiguous`.
    let text = "SELECT Dept FROM Emp JOIN Team USING (Dept) WHERE Dept = 20"
    let columns = try named()
        .columns(of: Statement(parsing: text), validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].name == "Dept")
    #expect(columns[0].type == .integer)
  }

  @Test func `a validated merged query agrees with the run`() throws {
    // run ≡ columns(of:validate:true): the query the validation path accepts
    // is the query the run executes, producing the two matched rows.
    try named().expect("""
        SELECT Name FROM Emp JOIN Team USING (Dept) WHERE Dept = 20
        """,
        yields: [["Bob"], ["Cid"]])
  }

  @Test func `a genuinely ambiguous bare name still faults under validation`()
      throws {
    // The scoping guard holds under validation too: bare `G`, shared by `Lhs`
    // and `Rhs` yet NOT the `USING (K)` join column, stays `.ambiguous` — the
    // merged-aware lookup narrows nothing that a plain shared column widens.
    let text = "SELECT G FROM Lhs JOIN Rhs USING (K)"
    #expect(throws: SQLError.ambiguous("G")) {
      _ = try named()
          .columns(of: Statement(parsing: text), validate: true)
    }
  }

  // MARK: - A later USING over a re-collided merged name (finding B)

  @Test func `a later USING on a name a plain join re-collided with faults`()
      throws {
    // `Emp JOIN Team USING (Dept)` merges `Dept`; the plain `JOIN Bonus AS C
    // ON …` re-introduces a physical `C.Dept`, so the prefix now binds `Dept`
    // BOTH as the merged column and as `C.Dept`. A later `JOIN X USING (Dept)`
    // resolves its common `Dept` against that prefix — ambiguous — so it
    // faults `.ambiguous` rather than silently keying on the merged value and
    // leaving two output columns named `Dept`.
    let catalog = try Catalog {
      Relation("Emp", ["Dept": .integer, "Name": .text]) {
        Row(20, "Bob")
      }
      Relation("Team", ["Dept": .integer, "Lead": .text]) {
        Row(20, "Deb")
      }
      Relation("Bonus", ["Dept": .integer, "Amt": .integer]) {
        Row(20, 100)
      }
      Relation("X", ["Dept": .integer, "Note": .text]) {
        Row(20, "n")
      }
    }
    catalog.expect("""
        SELECT * FROM Emp JOIN Team USING (Dept)
        JOIN Bonus AS C ON C.Dept = Emp.Dept
        JOIN X USING (Dept)
        """,
        fails: .ambiguous("Dept"))
  }

  // MARK: - Incompatible USING column types (finding C)

  @Test func `a USING join over int and double sides unifies to double`()
      throws {
    // `A.k integer`, `B.k double`: the merged `k` type UNIFIES to `double`,
    // and the coalesce coerces each side to it, so the schema advertises
    // `double` and the rows carry doubles — not a silent left `integer`.
    let catalog = try Catalog {
      Relation("A", ["k": .integer, "a": .text]) {
        Row(1, "x")
      }
      Relation("B", ["k": .double, "b": .text]) {
        Row(1.0, "y")
      }
    }
    let text = "SELECT k FROM A JOIN B USING (k)"
    let columns = try catalog.columns(of: Statement(parsing: text),
                                      validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .double)
    try catalog.expect(text, yields: [[1.0]])
  }

  @Test func `a RIGHT USING join coerces a right-only row to the unified type`()
      throws {
    // `A.k integer`, `B.k double`, RIGHT join: the right-only row's `k` (from
    // `B`, the left `A.k` NULL) shows as a `double`, coerced to the unified
    // merged type — not the raw right value under a schema claiming integer.
    let catalog = try Catalog {
      Relation("A", ["k": .integer, "a": .text]) {
        Row(1, "x")
      }
      Relation("B", ["k": .double, "b": .text]) {
        Row(1.0, "y")
        Row(2.0, "z")
      }
    }
    try catalog.expect("SELECT k FROM A RIGHT JOIN B USING (k) ORDER BY k",
                       yields: [[1.0], [2.0]])
  }

  @Test func `a USING join over irreconcilable int and text sides faults`()
      throws {
    // `A.k integer`, `B.k text`: no common type, so the merged column is
    // rejected at resolve with `.operand`/42804 — the same fault a set-op fold
    // raises — rather than publishing an `integer` schema the coalesced text
    // value would violate.
    let catalog = try Catalog {
      Relation("A", ["k": .integer, "a": .text]) {
        Row(1, "x")
      }
      Relation("B", ["k": .text, "b": .text]) {
        Row("1", "y")
      }
    }
    catalog.expect("SELECT k FROM A JOIN B USING (k)",
                   fails: .operand("USING columns have irreconcilable types"))
  }

  @Test func `a RIGHT USING join over irreconcilable sides faults too`()
      throws {
    // The RIGHT variant faults at resolve exactly as the plain one — the
    // unified-type rejection precedes any row, so no schema-violating row is
    // produced.
    let catalog = try Catalog {
      Relation("A", ["k": .integer, "a": .text]) {
        Row(1, "x")
      }
      Relation("B", ["k": .text, "b": .text]) {
        Row("2", "y")
      }
    }
    catalog.expect("SELECT k FROM A RIGHT JOIN B USING (k)",
                   fails: .operand("USING columns have irreconcilable types"))
  }

  // MARK: - USING type unification honors the unconstrained mask

  @Test func `a USING join defers to the right when the left is unconstrained`()
      throws {
    // `(SELECT NULLIF(1, 1) AS k) AS a` — the left `k` is constant NULL, so
    // UNCONSTRAINED (a placeholder `integer` that places no type constraint) —
    // RIGHT JOIN `B_text` whose `k` is `text`. The merged `k` types off the
    // CONSTRAINED right (`text`) through the same mask-aware unification the
    // set-op fold takes, rather than faulting the placeholder `integer` beside
    // `text`. A right row's merged `k` is `B_text.k` (the always-NULL left
    // coalesces away). Run ≡ columns(of:).
    let catalog = try Catalog {
      Relation("B_text", ["k": .text, "b": .text]) {
        Row("p", "b1")
        Row("q", "b2")
      }
    }
    let text = """
        SELECT k FROM (SELECT NULLIF(1, 1) AS k) AS a
          RIGHT JOIN B_text USING (k) ORDER BY k
        """
    let columns = try catalog.columns(of: Statement(parsing: text),
                                      validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .text)
    try catalog.expect(text, yields: [["p"], ["q"]])
  }

  @Test func `a USING join defers to the left when the right is unconstrained`()
      throws {
    // The SYMMETRIC case: the CONSTRAINED left `A_text.k` (`text`) beside an
    // UNCONSTRAINED right `(SELECT NULLIF(1, 1) AS k)` — the merged `k` types
    // off the left (`text`), and a LEFT join keeps every left row, its merged
    // `k` the left value (the always-NULL right coalesces away).
    let catalog = try Catalog {
      Relation("A_text", ["k": .text, "a": .text]) {
        Row("p", "a1")
        Row("q", "a2")
      }
    }
    let text = """
        SELECT k FROM A_text
          LEFT JOIN (SELECT NULLIF(1, 1) AS k) AS b USING (k) ORDER BY k
        """
    let columns = try catalog.columns(of: Statement(parsing: text),
                                      validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .text)
    try catalog.expect(text, yields: [["p"], ["q"]])
  }

  @Test func `a USING join of two unconstrained sides stays unconstrained`()
      throws {
    // BOTH constituents constant NULL (unconstrained): the merged `k` stays a
    // placeholder that places no constraint, so a further `UNION SELECT 1` over
    // it UNIFIES to `integer` rather than faulting the placeholder beside the
    // typed arm — the merged column carries its own `unconstrained` bit into
    // the enclosing set-operation fold, exactly as a bare unconstrained column
    // would.
    let catalog = try Catalog {
      Relation("Unit", ["only": .integer]) {
        Row(1)
      }
    }
    let text = """
        SELECT k FROM (SELECT NULLIF(1, 1) AS k FROM Unit) AS a
          JOIN (SELECT NULLIF(1, 1) AS k FROM Unit) AS b USING (k)
        UNION SELECT 1
        """
    let columns = try catalog.columns(of: Statement(parsing: text),
                                      validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .integer)
    // The merged `k` is NULL (both sides NULL, and a NULL key never matches),
    // so the join yields no row; the UNION's second arm contributes `1`.
    try catalog.expect(text, yields: [[1]])
  }

  // MARK: - ISO 7.10 output order over chained USING/NATURAL joins (hole 2)

  @Test func `a chained USING on two different columns orders the outer merge first`()
      throws {
    // ISO 9075 7.10: each join's common columns lead, then the rest of the LEFT
    // output, then the right. `(P JOIN Q USING (k)) JOIN R USING (a)` therefore
    // exposes `[a, k, p, q, r]` — the OUTER `a` first, then the inner `k` (it
    // sits within "the rest of the left"), not the flat fold order `[k, a, …]`.
    let text = "SELECT * FROM P JOIN Q USING (k) JOIN R USING (a)"
    try chained().expect(text, yields: [[7, 1, "p1", "q1", "r1"]])
    let columns = try chained()
        .columns(of: Statement(parsing: text), validate: true)
    #expect(columns.map(\.name) == ["a", "k", "p", "q", "r"])
  }

  @Test func `a chained NATURAL join orders the outer common columns first`()
      throws {
    // The NATURAL variant discovers the same common columns (`k` inner, `a`
    // outer) and lays them in the same ISO order `[a, k, …]` in both the run
    // and the schema.
    let text = "SELECT * FROM P NATURAL JOIN Q NATURAL JOIN R"
    try chained().expect(text, yields: [[7, 1, "p1", "q1", "r1"]])
    let columns = try chained()
        .columns(of: Statement(parsing: text), validate: true)
    #expect(columns.map(\.name) == ["a", "k", "p", "q", "r"])
  }

  @Test func `a chained USING on the SAME column keeps it once at the outer position`()
      throws {
    // A chained `… USING (Dept)` over an already-merged `Dept` DROPS the inner
    // entry and keeps the ONE merged `Dept` at the outer join's position — so
    // `SELECT *` still exposes `Dept` once, then the three sides' rests. Run
    // and schema agree.
    let text =
        "SELECT * FROM Emp JOIN Team USING (Dept) JOIN Bonus USING (Dept)"
    try named().expect(text,
        yields: [
          [20, "Bob", "Deb", 100],
          [20, "Cid", "Deb", 100],
        ])
    let columns = try named()
        .columns(of: Statement(parsing: text), validate: true)
    #expect(columns.map(\.name) == ["Dept", "Name", "Lead", "Amt"])
  }

  // MARK: - Merged columns threaded into a LATERAL body (hole 1)

  @Test func `a LATERAL body resolves a bare USING-merged column`() throws {
    // ISO 9075 7.10: the `USING (Dept)` merged column is an output column of
    // the join, so a LATERAL body's PRECEDING scope carries it and a bare
    // `Dept` in the body binds the ONE coalesced column rather than faulting
    // `.ambiguous` between the two physical `Dept`s. Run and schema agree.
    let text = """
        SELECT d.n FROM Emp JOIN Team USING (Dept)
          JOIN LATERAL (SELECT Dept AS n) AS d ON 1 = 1
        """
    try named().expect(text, yields: [[20], [20]])
    let columns = try named()
        .columns(of: Statement(parsing: text), validate: true)
    #expect(columns.map(\.name) == ["n"])
  }

  @Test func `a LATERAL body resolves a bare NATURAL-merged column`() throws {
    // The NATURAL variant threads the merged column into the LATERAL body the
    // same way `USING` does.
    let text = """
        SELECT d.n FROM Emp NATURAL JOIN Team
          JOIN LATERAL (SELECT Dept AS n) AS d ON 1 = 1
        """
    try named().expect(text, yields: [[20], [20]])
  }

  @Test func `a LATERAL body coalesces a merged column of a RIGHT join`() throws {
    // A RIGHT join's merged `Dept` is `COALESCE(Emp.Dept, Team.Dept)`; the
    // right-only Dept 30 (left NULL) correlates into the body as the coalesced
    // value 30 — a physical-left binding would have shown NULL. This exercises
    // the `.coalesce` correlation source over the outer row's two cells.
    let text = """
        SELECT d.n FROM Emp RIGHT JOIN Team USING (Dept)
          JOIN LATERAL (SELECT Dept AS n) AS d ON 1 = 1
        """
    try named().expect(text, yields: [[20], [20], [30]])
  }

  @Test func `a LATERAL body still resolves a qualified constituent column`()
      throws {
    // A QUALIFIED `Emp.Dept` in the body never matches the merged column and
    // reaches its own physical side, correlating as an ordinary outer slot.
    let text = """
        SELECT d.n FROM Emp JOIN Team USING (Dept)
          JOIN LATERAL (SELECT Emp.Dept AS n) AS d ON 1 = 1
        """
    try named().expect(text, yields: [[20], [20]])
  }

  @Test func `a LATERAL body faults an ambiguous non-merged name`() throws {
    // A plain `JOIN Bonus ON …` re-introduces a physical `Dept` beside the
    // merged one, so a bare `Dept` in the LATERAL body now names BOTH and stays
    // `.ambiguous` — the merged axis does not mask a genuine ambiguity.
    let text = """
        SELECT d.n FROM Emp JOIN Team USING (Dept)
          JOIN Bonus ON Bonus.Dept = Emp.Dept
          JOIN LATERAL (SELECT Dept AS n) AS d ON 1 = 1
        """
    try named().expect(text, fails: .ambiguous("Dept"))
  }

  @Test func `a merged column and its constituent correlate independently`()
      throws {
    // A LATERAL body of `Emp RIGHT JOIN Team USING (Dept)` projects BOTH the
    // bare merged `Dept` (COALESCE) and the physical `Emp.Dept` constituent. On
    // the right-only Dept 30 row the merged `Dept` coalesces to 30 while
    // `Emp.Dept` is NULL — each correlates through its OWN parameter identity,
    // so neither read overwrites the other regardless of projection order.
    let forward = """
        SELECT m, e FROM Emp RIGHT JOIN Team USING (Dept)
          JOIN LATERAL (SELECT Dept AS m, Emp.Dept AS e) AS d ON 1 = 1
          ORDER BY m
        """
    try named().expect(forward, yields: [
      [20, 20],
      [20, 20],
      [30, nil],
    ])
    // The REVERSE projection order yields the same values — the merged and the
    // constituent correlation keys do not collide, so lowering order is
    // irrelevant.
    let reverse = """
        SELECT m, e FROM Emp RIGHT JOIN Team USING (Dept)
          JOIN LATERAL (SELECT Emp.Dept AS e, Dept AS m) AS d ON 1 = 1
          ORDER BY m
        """
    try named().expect(reverse, yields: [
      [20, 20],
      [20, 20],
      [30, nil],
    ])
  }

  @Test func `a SELECT star merged column carries its unconstrained mask`()
      throws {
    // Both `USING (k)` constituents are constant-NULL (`NULLIF(1, 1)`), so the
    // merged `k` is UNCONSTRAINED — it places no type constraint. A `SELECT *`
    // must carry that mask (exactly as an explicit `SELECT k` does), so the
    // enclosing UNION unifies the merged `k` with the text arm rather than
    // faulting the first arm's integer against the text (42804).
    let star = """
        SELECT * FROM (SELECT NULLIF(1, 1) AS k FROM Solo) AS a
          JOIN (SELECT NULLIF(1, 1) AS k FROM Solo) AS b USING (k)
          UNION SELECT 'x'
        """
    let starred = try named()
        .columns(of: Statement(parsing: star), validate: true)
    #expect(starred.map(\.type) == [.text])
    // The explicit `SELECT k` variant already resolved through `output(of:)`;
    // it stays resolvable and agrees.
    let explicit = """
        SELECT k FROM (SELECT NULLIF(1, 1) AS k FROM Solo) AS a
          JOIN (SELECT NULLIF(1, 1) AS k FROM Solo) AS b USING (k)
          UNION SELECT 'x'
        """
    let named = try named()
        .columns(of: Statement(parsing: explicit), validate: true)
    #expect(named.map(\.type) == [.text])
  }

  @Test func `a genuinely constrained USING merge still faults an irreconcilable UNION`()
      throws {
    // Both constituents are CONSTRAINED (a bare integer `Dept` and a text
    // `Lead`… no — both integer here), so the merged `Dept` is a constrained
    // integer and the text UNION arm is irreconcilable: 42804 still faults,
    // proving the mask is carried, not hard-coded unconstrained.
    let text = """
        SELECT * FROM Emp JOIN Team USING (Dept) UNION SELECT 'x', 'y', 'z'
        """
    try named().expect(text,
        fails: .operand("UNION arms have irreconcilable types"))
  }

  // MARK: - USING/NATURAL over a VIRTUAL column (the fixture `Id`)

  @Test func `USING a virtual Id present on both sides resolves and merges it`()
      throws {
    // `Id` is a VIRTUAL column (the fixture's 1-based row index) on BOTH `Emp`
    // and `Team`, not a real one in `names`. `USING (Id)` must resolve it
    // through the SAME virtual-aware `ordinal(of:)` the predicate path
    // `Emp.Id = Team.Id` uses, keying on the row index: Emp Ids 1..3, Team
    // Ids 1..2, so Ids 1 and 2 match. ISO 7.10 order exposes the merged `Id`
    // once and first, then `Emp`'s real columns, then `Team`'s.
    try named().expect("SELECT * FROM Emp JOIN Team USING (Id)",
        yields: [
          [1, 10, "Ann", 20, "Deb"],
          [2, 20, "Bob", 30, "Eve"],
        ])
  }

  @Test func `a bare virtual-Id USING column types integral under columns(of:)`()
      throws {
    // The merged virtual `Id`'s result type is derived on the schema path the
    // run agrees with — a fixture virtual `Id` types integral.
    let text = "SELECT Id FROM Emp JOIN Team USING (Id)"
    let columns = try named()
        .columns(of: Statement(parsing: text), validate: true)
    let pairs = columns.map { ($0.name, $0.type) }
    #expect(pairs.elementsEqual([("Id", .integer)], by: ==))
  }

  @Test func `NATURAL does not key on a shared virtual Id, only real columns`()
      throws {
    // The NATURAL DECISION: the common set is the LEFT scope's `names` — the
    // real, `SELECT *`-visible columns, NO virtual — so a virtual `Id` shared
    // by both sides is NOT a NATURAL common column even though both sides can
    // ADDRESS it. This is consistent with ISO, where NATURAL and `SELECT *`
    // draw on the SAME column-name list (which the engine excludes virtuals
    // from), while an EXPLICIT `USING (Id)` (like an explicit `A.Id = B.Id`)
    // resolves the virtual through `ordinal(of:)`. So `Emp NATURAL JOIN Team`
    // keys on the shared REAL `Dept` alone (Dept 20 matches), NOT on the
    // virtual `Id` — the round-1 behavior is unchanged.
    try named().expect("SELECT * FROM Emp NATURAL JOIN Team",
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
  }

  @Test func `USING mixes a REAL left Id with a VIRTUAL joined Id`() throws {
    // `Coded` carries a REAL `Id` column (shadowing its own virtual); `Emp`
    // exposes only a VIRTUAL `Id`. `USING (Id)` must resolve the LEFT through
    // the real column and the RIGHT through the virtual one, keying REAL 1..3
    // against the row index 1..3.
    try virtual().expect("SELECT * FROM Coded JOIN Emp USING (Id)",
        yields: [
          [1, "c1", 10, "Ann"],
          [2, "c2", 20, "Bob"],
          [3, "c3", 20, "Cid"],
        ])
  }

  @Test func `USING mixes a VIRTUAL left Id with a REAL joined Id`() throws {
    // The reverse: `Emp` (virtual `Id`) as the FROM side, `Coded` (real `Id`)
    // joined — the LEFT resolves the virtual, the RIGHT the real. The output
    // exposes the merged `Id`, then `Emp`'s real columns, then `Coded`'s real
    // ones (its real `Id` is the merged constituent, dropped from the rest).
    try virtual().expect("SELECT * FROM Emp JOIN Coded USING (Id)",
        yields: [
          [1, 10, "Ann", "c1"],
          [2, 20, "Bob", "c2"],
          [3, 20, "Cid", "c3"],
        ])
  }

  @Test func `NATURAL excludes a JOINED-side virtual Id from the common set`()
      throws {
    // `Coded` has a REAL `Id` (in `names`); `Emp` exposes `Id` ONLY as a
    // VIRTUAL column (the fixture row index), and the two share NO real column
    // (`Id`/`Tag` vs `Dept`/`Name`). The `NATURAL` common set is the REAL-name
    // intersection on BOTH sides, so the joined-side VIRTUAL `Id` must NOT
    // match `Coded`'s real `Id` — the join degenerates to a CROSS product (its
    // synthesized `on` empty), keeping ALL FOUR real columns unmerged and every
    // 3x3 pairing. An EXPLICIT `USING (Id)` (the control below) still resolves
    // the virtual; NATURAL, like `SELECT *`, draws only on real names.
    try virtual().expect("SELECT * FROM Coded NATURAL JOIN Emp",
        yields: [
          [1, "c1", 10, "Ann"],
          [1, "c1", 20, "Bob"],
          [1, "c1", 20, "Cid"],
          [2, "c2", 10, "Ann"],
          [2, "c2", 20, "Bob"],
          [2, "c2", 20, "Cid"],
          [3, "c3", 10, "Ann"],
          [3, "c3", 20, "Bob"],
          [3, "c3", 20, "Cid"],
        ])
    let text = "SELECT * FROM Coded NATURAL JOIN Emp"
    let columns = try virtual().columns(of: parse(query: text))
    #expect(columns.map(\.name) == ["Id", "Tag", "Dept", "Name"])
  }

  @Test func `NATURAL excludes a LEFT-side virtual Id from the common set`()
      throws {
    // The symmetric case: `Emp` (virtual `Id`) is the LEFT/FROM side, `Coded`
    // (real `Id`) the joined one. The left is already real-only
    // (`prefix.names` never lists a virtual), so a LEFT virtual `Id` is not
    // even a candidate — the common set stays the empty real intersection and
    // the join is a CROSS product over all four real columns.
    try virtual().expect("SELECT * FROM Emp NATURAL JOIN Coded",
        yields: [
          [10, "Ann", 1, "c1"],
          [10, "Ann", 2, "c2"],
          [10, "Ann", 3, "c3"],
          [20, "Bob", 1, "c1"],
          [20, "Bob", 2, "c2"],
          [20, "Bob", 3, "c3"],
          [20, "Cid", 1, "c1"],
          [20, "Cid", 2, "c2"],
          [20, "Cid", 3, "c3"],
        ])
    let text = "SELECT * FROM Emp NATURAL JOIN Coded"
    let columns = try virtual().columns(of: parse(query: text))
    #expect(columns.map(\.name) == ["Dept", "Name", "Id", "Tag"])
  }

  @Test func `explicit USING over the real-and-virtual Id still merges (round 7)`()
      throws {
    // CONTROL: the round-7 behavior is UNCHANGED. `Coded JOIN Emp USING (Id)`
    // still resolves `Coded`'s REAL `Id` and `Emp`'s VIRTUAL `Id` through the
    // virtual-aware probe and MERGES them (keys real 1..3 against the row
    // index 1..3), a single merged `Id` first, then the remaining real columns.
    // Only NATURAL's common-set derivation changed; the explicit-USING path is
    // untouched.
    try virtual().expect("SELECT * FROM Coded JOIN Emp USING (Id)",
        yields: [
          [1, "c1", 10, "Ann"],
          [2, "c2", 20, "Bob"],
          [3, "c3", 20, "Cid"],
        ])
    let text = "SELECT * FROM Coded JOIN Emp USING (Id)"
    let columns = try virtual().columns(of: parse(query: text))
    #expect(columns.map(\.name) == ["Id", "Tag", "Dept", "Name"])
  }

  @Test func `a RIGHT USING over a virtual Id coalesces the right-only value`()
      throws {
    // `Few` has ONE row (Id 1); `Many` has three (Ids 1..3). A RIGHT join keeps
    // every `Many` row: Id 1 matches, and Ids 2 and 3 are right-only with a
    // NULL-extended left `Id`. The merged `Id` = COALESCE(Few.Id, Many.Id) must
    // show the JOINED (right) virtual value on those right-only rows, so the
    // merged column is 1, 2, 3 — not NULL — proving the run coalesces the
    // virtual slot, not just resolves it.
    try virtual().expect("""
        SELECT Id FROM Few RIGHT JOIN Many USING (Id) ORDER BY Id
        """,
        yields: [[1], [2], [3]])
  }

  // MARK: - A merged name a later plain join re-collides with on the VIRTUAL
  // axis (round 8)

  @Test func `a bare merged Id a later plain join's virtual Id re-collides with faults`()
      throws {
    // `Few JOIN Many USING (Id)` merges the VIRTUAL `Id` of both sides; a later
    // plain `JOIN Emp ON 1 = 1` brings `Emp`'s OWN addressable virtual `Id`. A
    // bare `Id` now names BOTH the merged column and `Emp.Id`, so it faults
    // `.ambiguous` — the merged bare lookup scans the FULL addressable surface
    // (physical AND virtual, `Scope.ordinal(of:)`'s), not a real-only one that
    // would MISS the virtual `Emp.Id` and wrongly take the merged value. run
    // and `columns(of:)` agree.
    let text = "SELECT Id FROM Few JOIN Many USING (Id) JOIN Emp ON 1 = 1"
    try virtual().expect(text, fails: .ambiguous("Id"))
    #expect(throws: SQLError.ambiguous("Id")) {
      _ = try virtual().columns(of: parse(query: text))
    }
  }

  @Test func `a bare merged Id ambiguous with a virtual one faults in the WHERE`()
      throws {
    // The same conflict feeds a `WHERE` predicate: with the merged `Id` AND the
    // plain-joined `Emp.Id` (virtual) both addressable, a bare `Id` in the
    // `WHERE` faults `.ambiguous` rather than silently keying on the merged
    // value.
    let text = """
        SELECT v FROM Few JOIN Many USING (Id) JOIN Emp ON 1 = 1 WHERE Id = 1
        """
    try virtual().expect(text, fails: .ambiguous("Id"))
    #expect(throws: SQLError.ambiguous("Id")) {
      _ = try virtual().columns(of: parse(query: text))
    }
  }

  @Test func `a later USING over a virtual Id a plain join re-collided with faults`()
      throws {
    // The conflict feeds a later `USING` key too: `… USING (Id) JOIN Emp ON 1 =
    // 1 JOIN Coded USING (Id)` accumulates a left carrying BOTH the merged `Id`
    // and the plain-joined `Emp.Id` (virtual), so keying the final `USING (Id)`
    // on that left is ambiguous — the left resolution (`Scope.left`) routes
    // through the SAME full-surface merged bare lookup and faults.
    try virtual().expect("""
        SELECT v FROM Few JOIN Many USING (Id) JOIN Emp ON 1 = 1
        JOIN Coded USING (Id)
        """,
        fails: .ambiguous("Id"))
  }

  @Test func `qualified sides of a virtual-Id merge still resolve past a re-collision`()
      throws {
    // With bare `Id` ambiguous, each QUALIFIED reference still reaches its own
    // side unambiguously: `Few.Id`/`Many.Id` the merge constituents (both the
    // matched row index 1), `Emp.Id` the later plain join's virtual `Id` (the
    // three `Emp` rows' indices 1..3) — never a fault.
    try virtual().expect("""
        SELECT Few.Id, Many.Id, Emp.Id FROM Few JOIN Many USING (Id)
        JOIN Emp ON 1 = 1
        """,
        yields: [[1, 1, 1], [1, 1, 2], [1, 1, 3]])
  }

  @Test func `a bare merged name a later plain join lacks stays unambiguous`()
      throws {
    // The control: when the later plain join's relation does NOT expose the
    // merged name, the full-surface scan finds NO non-constituent match and the
    // bare name resolves to the merged column — no false ambiguity. `Emp JOIN
    // Team USING (Dept)` merges `Dept`; `Other(y)` carries no `Dept`, so a bare
    // `Dept` still coalesces (only Dept 20 matches on both sides). run and
    // `columns(of:)` agree.
    let catalog = try Catalog {
      Relation("Emp", ["Dept": .integer, "Name": .text]) {
        Row(10, "Ann")
        Row(20, "Bob")
        Row(20, "Cid")
      }
      Relation("Team", ["Dept": .integer, "Lead": .text]) {
        Row(20, "Deb")
        Row(30, "Eve")
      }
      Relation("Other", ["y": .text]) {
        Row("p")
      }
    }
    let text = "SELECT Dept FROM Emp JOIN Team USING (Dept) JOIN Other ON 1 = 1"
    try catalog.expect(text, yields: [[20], [20]])
    let columns = try catalog.columns(of: parse(query: text))
    #expect(columns.map(\.name) == ["Dept"])
  }

  // MARK: - `SELECT *` arity derives from the emitted enumeration (round 9)

  @Test func `a virtual-Id USING SELECT * width equals its emitted arity`()
      throws {
    // `SELECT * FROM Emp JOIN Team USING (Id)` merges the VIRTUAL `Id` of both
    // sides. No REAL column is subsumed (both `Id`s are virtual), so the arm
    // emits FIVE values (the merged `Id`, then `Emp`'s two real columns, then
    // `Team`'s two) — and the computed `SELECT *` width must equal that count,
    // not undercount by subtracting the virtual constituents from a real-only
    // sum. The width now DERIVES from the same enumeration `columns(of:)`
    // walks, so the two agree by construction.
    let catalog = try named()
    try catalog.expect("SELECT * FROM Emp JOIN Team USING (Id)",
        yields: [
          [1, 10, "Ann", 20, "Deb"],
          [2, 20, "Bob", 30, "Eve"],
        ])
    let text = "SELECT * FROM Emp JOIN Team USING (Id)"
    let columns = try catalog.columns(of: parse(query: text))
    #expect(columns.count == 5)
  }

  @Test func `a set operation over a virtual-Id SELECT * matches arity 5`()
      throws {
    // The undercounted width fed the set-operation arity check, so a genuinely
    // matching UNION was WRONGLY rejected. The left arm's `SELECT *` is arity 5
    // (merged virtual `Id` + four real columns); a right arm of five columns
    // now unifies rather than faulting.
    try named().expect("""
        SELECT * FROM Emp JOIN Team USING (Id)
        UNION ALL SELECT 9, 99, 'z', 88, 'w'
        """,
        yields: [
          [1, 10, "Ann", 20, "Deb"],
          [2, 20, "Bob", 30, "Eve"],
          [9, 99, "z", 88, "w"],
        ])
  }

  @Test func `a virtual-Id SELECT * set operation still faults a real arity mismatch`()
      throws {
    // The floor: a right arm of the WRONG arity (three columns against the
    // arm's five) still faults `.arity`, so deriving width from the enumeration
    // did not disable the check.
    try named().expect("""
        SELECT * FROM Emp JOIN Team USING (Id) UNION ALL SELECT 1, 2, 3
        """,
        fails: .arity(5, 3))
  }

  @Test func `an ORDER BY ordinal past the merged width resolves`() throws {
    // The undercounted width (3) made the `ORDER BY` ordinal bound in the
    // type-check path (`columns(of:validate:true)`) REJECT a valid ordinal (4
    // or 5) that names a real output column — the width there feeds the bound.
    // The width is now 5, so ordinal 5 (`Team`'s `Lead`) type-checks, and the
    // run resolves and sorts by it.
    let catalog = try named()
    let text = "SELECT * FROM Emp JOIN Team USING (Id) ORDER BY 5"
    _ = try catalog.columns(of: parse(query: text))
    try catalog.expect(text,
        yields: [
          [1, 10, "Ann", 20, "Deb"],
          [2, 20, "Bob", 30, "Eve"],
        ])
  }

  @Test func `a real-column USING SELECT * width is unchanged`() throws {
    // The control: when the USING column is a REAL column (`Dept`), one real
    // constituent per side IS subsumed, so the emitted arity is 3 (merged
    // `Dept` + `Emp.Name` + `Team.Lead`) — unchanged by deriving width from the
    // enumeration. `columns(of:)` reports 3 and an `ORDER BY 3` resolves while
    // an `ORDER BY 4` faults.
    let catalog = try named()
    let text = "SELECT * FROM Emp JOIN Team USING (Dept)"
    let columns = try catalog.columns(of: parse(query: text))
    #expect(columns.count == 3)
    try catalog.expect("\(text) ORDER BY 3",
        yields: [
          [20, "Bob", "Deb"],
          [20, "Cid", "Deb"],
        ])
    catalog.expect("\(text) ORDER BY 4", fails: .column("4"))
  }
}

/// Fixtures for the VIRTUAL-`Id` named-column join cases. `Coded` carries a
/// REAL `Id` column (which shadows its own virtual `Id`), so a `USING (Id)`
/// against `Emp`'s VIRTUAL `Id` mixes a real and a virtual constituent. `Few`
/// (one row) RIGHT-joined to `Many` (three rows) `USING (Id)` produces two
/// right-only rows whose merged `Id` must coalesce to `Many`'s row index.
private func virtual() throws -> FixtureCatalog {
  try Catalog {
    Relation("Emp", ["Dept": .integer, "Name": .text]) {
      Row(10, "Ann")
      Row(20, "Bob")
      Row(20, "Cid")
    }
    Relation("Coded", ["Id": .integer, "Tag": .text]) {
      Row(1, "c1")
      Row(2, "c2")
      Row(3, "c3")
    }
    Relation("Few", ["v": .text]) {
      Row("f1")
    }
    Relation("Many", ["w": .text]) {
      Row("m1")
      Row("m2")
      Row("m3")
    }
  }
}

/// Three relations for a chained named-column join over TWO DISTINCT columns:
/// `P(k, p)` and `Q(k, a, q)` share `k`, and `Q` and `R(a, r)` share `a`, so
/// `(P JOIN Q USING (k)) JOIN R USING (a)` merges `k` at the INNER join and `a`
/// at the OUTER one — the ISO 7.10 output order is `[a, k, p, q, r]`. `P
/// NATURAL JOIN Q NATURAL JOIN R` discovers the same common columns.
private func chained() throws -> FixtureCatalog {
  try Catalog {
    Relation("P", ["k": .integer, "p": .text]) {
      Row(1, "p1")
    }
    Relation("Q", ["k": .integer, "a": .integer, "q": .text]) {
      Row(1, 7, "q1")
    }
    Relation("R", ["a": .integer, "r": .text]) {
      Row(7, "r1")
    }
  }
}

