// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - WITH (non-recursive) tests

/// Parses `text` to a statement and runs it against `catalog`.
private func statement<C: Catalog & ~Escapable>(_ text: String,
                                                _ catalog: borrowing C)
    throws -> Array<Array<Value>> {
  try catalog.run(Statement(parsing: text))
}

struct EngineWithTests {
  @Test func `a non-recursive CTE materialises as an inline view`() throws {
    // The CTE `adults` is materialised once and the trailing query reads it
    // like a table — the inline-view shape of a non-recursive WITH.
    let rows = try statement("""
        WITH adults (Key, Label) AS (SELECT Id, Name FROM Parent WHERE Id >= 2)
          SELECT Label FROM adults
        """, engineFamily())
    #expect(rows == [[.text("Bee")], [.text("Cid")]])
  }

  @Test func `a JOIN matches an integer key to an equal double key`() throws {
    // The optimized join paths (hash bucket, seek/final check, CTE nested loop)
    // must use the same mixed-numeric equality a predicate does: `1` and `1.0`
    // are equal, so the row joins rather than being dropped by a raw-`Value`
    // key comparison.
    let rows = try statement("""
        WITH a (x) AS (SELECT 1), b (x) AS (SELECT 1.0)
          SELECT * FROM a JOIN b ON a.x = b.x
        """, engineFamily())
    #expect(rows == [[.integer(1), .double(1.0)]])
  }

  @Test func `a JOIN matches a large integer to its rounded double past 2^53`() throws {
    // Above 2^53 an integer is not exactly representable as `Double`; the
    // predicate treats `9007199254740993` and `9007199254740993.0` as equal by
    // promoting the integer to `Double` (both round to 2^53), so the optimized
    // join must too — a fold-double-to-Int key would drop the row.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740993),
             b (x) AS (SELECT 9007199254740993.0)
          SELECT a.x FROM a JOIN b ON a.x = b.x
        """, engineFamily())
    #expect(rows == [[.integer(9007199254740993)]])
  }

  @Test func `a JOIN keeps distinct large integer keys unequal (exact integers)`() throws {
    // Two integers that round to the SAME Double past 2^53 are still unequal as
    // integers, so an integer/integer join must NOT pair them — the hash bucket
    // may collide, but the residual `matches` check keeps integer equality
    // exact.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740992),
             b (x) AS (SELECT 9007199254740993)
          SELECT a.x FROM a JOIN b ON a.x = b.x
        """, engineFamily())
    #expect(rows.isEmpty)
  }

  @Test func `UNION deduplicates numerically-equal rows across kinds`() throws {
    // `1` and `1.0` are the same numeric value, so UNION keeps one — the first
    // arm's — not both; the dedup uses the numeric equality, not raw `Value`.
    #expect(try statement("SELECT 1 UNION SELECT 1.0", engineFamily())
            == [[.integer(1)]])
    // UNION ALL keeps every row.
    #expect(try statement("SELECT 1 UNION ALL SELECT 1.0", engineFamily())
            == [[.integer(1)], [.double(1.0)]])
  }

  @Test func `UNION dedup keeps distinct integers a rounded double sits between`() throws {
    // Dedup is EXACT: `2^53.0` equals the integer `2^53` (folds to it), but NOT
    // the integer `2^53 + 1`. So an earlier approximate row must not absorb
    // both distinct integers — the `2^53 + 1` row survives regardless of order.
    let rows = try statement("""
        SELECT 9007199254740992.0
          UNION SELECT 9007199254740992
          UNION SELECT 9007199254740993
        """, engineFamily())
    #expect(rows == [[.double(9007199254740992.0)],
                     [.integer(9007199254740993)]])
  }

  @Test func `ORDER BY orders mixed integer/double keys by magnitude`() throws {
    let rows = try statement("""
        WITH a (x) AS (SELECT 3 UNION ALL SELECT 1.5) SELECT x FROM a ORDER BY x
        """, engineFamily())
    #expect(rows == [[.double(1.5)], [.integer(3)]])
  }

  @Test func `ORDER BY over mixed keys past 2^53 stays a total order`() throws {
    // A double ties two distinct integers under promotion; the comparator must
    // stay a strict weak ordering (transitive), keeping the larger integer last
    // rather than misordering it ahead of the smaller via the stable tie-break.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740993
                       UNION ALL SELECT 9007199254740993.0
                       UNION ALL SELECT 9007199254740992)
          SELECT x FROM a ORDER BY x
        """, engineFamily())
    #expect(rows.count == 3)
    #expect(rows.last == [.integer(9007199254740993)])
  }

  @Test func `a CTE infers its columns and filters on them`() throws {
    let rows = try statement("""
        WITH grown AS (SELECT Id, Name FROM Parent)
          SELECT Name FROM grown WHERE Id = 3
        """, engineFamily())
    #expect(rows == [[.text("Cid")]])
  }

  @Test func `a later CTE reads an earlier one (chained CTEs)`() throws {
    // `b` resolves `a` — the resolver consults the CTEs materialised so far, so
    // a later member sees an earlier one.
    let rows = try statement("""
        WITH a (Id, Name) AS (SELECT Id, Name FROM Parent WHERE Id >= 2),
             b (Who) AS (SELECT Name FROM a WHERE Id = 3)
          SELECT Who FROM b
        """, engineFamily())
    #expect(rows == [[.text("Cid")]])
  }

  @Test func `a CTE shadows a base relation of the same name`() throws {
    // `Parent` is a base relation; the CTE of the same name shadows it, so the
    // trailing query reads the CTE's rows, not the base table's.
    let rows = try statement("""
        WITH Parent (Id, Name) AS (SELECT Id, Name FROM Parent WHERE Id = 1)
          SELECT Name FROM Parent
        """, engineFamily())
    #expect(rows == [[.text("Ada")]])
  }

  @Test func `the trailing query joins a CTE against a base relation`() throws {
    // The CTE `kids` joins to the base `Parent` on the foreign key — proving a
    // materialised relation and a base one combine in one query.
    let rows = try statement("""
        WITH kids (Pid, Kid) AS (SELECT Pid, Name FROM Child)
          SELECT Parent.Name, kids.Kid FROM Parent
            JOIN kids ON kids.Pid = Parent.Id
        """, engineFamily())
    #expect(rows == [
      [.text("Ada"), .text("Ann")],
      [.text("Ada"), .text("Amy")],
      [.text("Bee"), .text("Bob")],
    ])
  }

  @Test func `a CTE's Id virtual column resolves`() throws {
    let rows = try statement("""
        WITH a (Tag) AS (SELECT Name FROM Parent)
          SELECT Id, Tag FROM a WHERE Id = 2
        """, engineFamily())
    #expect(rows == [[.integer(2), .text("Bee")]])
  }

  @Test func `a CTE column list of the wrong arity is rejected at parse`() throws {
    #expect(throws: SQLError.columns(expected: 2, got: 1)) {
      try statement("""
          WITH a (x) AS (SELECT Id, Name FROM Parent) SELECT x FROM a
          """, engineFamily())
    }
  }

  @Test func `an unknown column of a CTE is reported`() throws {
    #expect(throws: SQLError.column("Missing")) {
      try statement("""
          WITH a (Id) AS (SELECT Id FROM Parent) SELECT Missing FROM a
          """, engineFamily())
    }
  }

  @Test func `a CTE whose body is a UNION materialises both arms`() throws {
    let rows = try statement("""
        WITH both (Tag) AS (SELECT Tag FROM Lhs UNION SELECT Tag FROM Rhs)
          SELECT Tag FROM both
        """, engineTags())
    #expect(rows == [[.text("a")], [.text("shared")], [.text("b")]])
  }

  @Test func `a CTE column list wider than its SELECT * body is rejected, not trapped`() throws {
    // `Parent` is a two-column relation, but the column list declares three
    // names; the `SELECT *` body's width is known only after it compiles, so
    // the declared arity is checked against the body's compiled width, faulting
    // with `SQLError.columns` rather than trapping when a later read indexes a
    // cell the row does not have.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try statement("""
          WITH a (x, y, z) AS (SELECT * FROM Parent) SELECT x FROM a
          """, engineFamily())
    }
  }

  @Test func `a zero-row SELECT * CTE body of the wrong arity is rejected`() throws {
    // `Parent` is a two-column relation, but the column list declares three
    // names. The body `WHERE Id < 0` yields no rows, so a per-row check would
    // pass it through vacuously and register `a` with a three-column schema
    // over a two-column body; the trailing `SELECT z` then reads an ordinal the
    // body never projects. The body's compiled width is checked against the
    // declared arity BEFORE materialising, regardless of the row count, so the
    // mismatch faults with `SQLError.columns` rather than silently returning
    // data.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try statement("""
          WITH a (x, y, z) AS (SELECT * FROM Parent WHERE Id < 0)
            SELECT z FROM a
            UNION SELECT 99 AS z FROM Parent WHERE Id = 1
          """, engineFamily())
    }
  }

  @Test func `a WITH list rejects a case-insensitively duplicate query name`() throws {
    // Two CTEs share a name (`a` and `A`), so the second would silently
    // overwrite the first in the materialised scope — a typo in a multi-CTE
    // query changing the result. The duplicate is rejected before materialising.
    #expect(throws: SQLError.redefinition("A")) {
      try statement("""
          WITH a (x) AS (SELECT Id FROM Parent),
               A (x) AS (SELECT Id FROM Parent)
            SELECT x FROM a
          """, engineFamily())
    }
  }

  @Test func `a WHERE pushed onto a joined-in CTE filters its rows before the join`() throws {
    // `kids` is joined to `Parent` on the foreign key, and a single-relation
    // `WHERE kids.Kid = 'Amy'` is pushed onto the CTE inner; only the matching
    // CTE row may join, so a CTE row with any other `Kid` is excluded rather than
    // paired.
    let rows = try statement("""
        WITH kids (Pid, Kid) AS (SELECT Pid, Name FROM Child)
          SELECT Parent.Name, kids.Kid FROM Parent
            JOIN kids ON kids.Pid = Parent.Id
            WHERE kids.Kid = 'Amy'
        """, engineFamily())
    #expect(rows == [[.text("Ada"), .text("Amy")]])
  }

  @Test func `a statement CTE does not leak into a registered view's body`() throws {
    // `Adults` is a view over the base `Parent`; a statement-local
    // `WITH Parent (Id) AS …` must NOT reach into the view's stored body, so
    // `SELECT Id FROM Adults` still reads the base `Parent`'s ids — a view means
    // what it was registered to mean regardless of the caller's WITH. Were the
    // caller's CTEs threaded into the view body, `Adults`'s `FROM Parent` would
    // bind to the CTE and the query would return `99`.
    let adults =
        try View(query: engineSelect("SELECT Id FROM Parent"), columns: ["Id"])
    let catalog = EngineMemory(try engineFamily().catalog, views: ["Adults": adults])
    let rows = try statement("""
        WITH Parent (Id) AS (SELECT 99 AS Id FROM Parent WHERE Id = 1)
          SELECT Id FROM Adults
        """, catalog)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `a top-level FROM a CTE still resolves to the CTE, not the base relation`() throws {
    // The complement of `viewScoping`: at the STATEMENT level a CTE that names a
    // base relation still shadows it, so a trailing `FROM Parent` reads the CTE
    // — the scoping fix narrows only a view's body, never the statement query.
    let adults =
        try View(query: engineSelect("SELECT Id FROM Parent"), columns: ["Id"])
    let catalog = EngineMemory(try engineFamily().catalog, views: ["Adults": adults])
    let rows = try statement("""
        WITH Parent (Id) AS (SELECT 99 AS Id FROM Parent WHERE Id = 1)
          SELECT Id FROM Parent
        """, catalog)
    #expect(rows == [[.integer(99)]])
  }

  @Test func `a WITH RECURSIVE arm that never names the CTE runs once, not to a cap`() throws {
    // Every member of a `WITH RECURSIVE` list is syntactically marked recursive,
    // but neither arm of this UNION ALL reads `a`, so it is not recursive in
    // truth: it runs once, yielding exactly its two rows, rather than re-running
    // an arm that adds nothing new until the recursion cap fires.
    let rows = try statement("""
        WITH RECURSIVE a (n) AS (
          SELECT 1 AS n FROM Extra UNION ALL SELECT 2 AS n FROM Extra
        )
        SELECT n FROM a
        """, engineTags())
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }

  @Test func `a WITH RECURSIVE whose anchor reads a same-named base is not recursive`() throws {
    // The CTE `Parent` shares a base relation's name; only the ANCHOR reads that
    // base (the CTE is not in scope there), while the recursive arm reads
    // `Extra` and never names the CTE. Self-reference is detected in the arm
    // alone, so this is NOT routed through the fixpoint: the two arms materialise
    // once (UNION ALL) instead of the arm re-running to the recursion cap.
    let catalog = EngineMemory([
      "Parent": FixtureRelation([EngineField(name: "Id", type: .integer)],
                         [[.integer(1)], [.integer(2)]] as Array<Array<Value>>),
      "Extra": FixtureRelation([EngineField(name: "Id", type: .integer)],
                        [[.integer(3)]] as Array<Array<Value>>),
    ])
    let rows = try statement("""
        WITH RECURSIVE Parent (Id) AS (
          SELECT Id FROM Parent UNION ALL SELECT Id FROM Extra
        )
        SELECT Id FROM Parent
        """, catalog)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }
}

// MARK: - WITH RECURSIVE tests

/// A one-row seed catalog: a `Seed` relation of a single row, the FROM-less
/// `SELECT 1` the dialect lacks expressed as `SELECT 1 FROM Seed`. It also
/// carries an `Edge(Src, Dst)` relation for a transitive-closure test.
private func seed() -> EngineMemory {
  let one = [EngineField(name: "One", type: .integer)]
  let seedRows = [[.integer(1)]] as Array<Array<Value>>

  let edge = [
    EngineField(name: "Src", type: .integer),
    EngineField(name: "Dst", type: .integer),
  ]
  // 1 -> 2 -> 3 -> 4, a simple chain whose closure is every reachable pair.
  let edges = [
    [.integer(1), .integer(2)],
    [.integer(2), .integer(3)],
    [.integer(3), .integer(4)],
  ] as Array<Array<Value>>

  return EngineMemory([
    "Seed": FixtureRelation(one, seedRows),
    "Edge": FixtureRelation(edge, edges),
  ])
}

/// Routines with an `inc` scalar — `inc(n) = n + 1` — standing in for the `+`
/// the dialect lacks, so a recursive counter can advance.
private func counting() -> Routines {
  try! Routines().registering("inc", parameters: [.integer]) {
    arguments throws(SQLError) in
    guard case let .integer(n) = arguments.first else {
      throw .argument("inc expects one integer argument")
    }
    return .integer(n + 1)
  }
}

struct EngineRecursiveTests {
  @Test func `a recursive counter enumerates 1..5`() throws {
    // The canonical recursive CTE: seed with 1, then inc(n) while n < 5. The
    // anchor reads the one-row Seed; the recursive arm names the CTE `c`.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c WHERE n < 5
        )
        SELECT n FROM c
        """)
    let rows = try seed().run(query, counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test func `a recursive counter runs through Catalog.run(_:statement:)`() throws {
    let rows = try seed().run(Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c WHERE n < 3
        )
        SELECT n FROM c
        """), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `a non-UNION recursive CTE validates its compiled width`() throws {
    // A `WITH RECURSIVE` member whose body is not a UNION runs once, but must
    // still match its declared arity. Here the body resolves `Parent` against
    // the base relation of the same name (two columns) under a three-column
    // list; the non-UNION path validates the compiled width and faults rather
    // than binding narrow rows that trap when the trailing `SELECT z` reads the
    // absent ordinal.
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      _ = try engineFamily().run(Statement(parsing: """
          WITH RECURSIVE Parent (x, y, z) AS (SELECT * FROM Parent)
            SELECT z FROM Parent
          """))
    }
  }

  @Test func `a recursive CTE with more than one recursive arm is rejected`() throws {
    // The body has TWO self-referential arms; the engine models one anchor plus
    // one recursive arm, so the earlier recursive arm would land in the anchor
    // (compiled with the CTE not in scope). Reject it with a clear `unsupported`
    // diagnostic rather than failing obscurely as an unresolved relation.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL SELECT inc(n) AS n FROM c WHERE n < 3
          UNION ALL SELECT inc(n) AS n FROM c WHERE n < 5
        )
        SELECT n FROM c
        """)
    #expect(throws: SQLError.state("0A000",
        "recursive WITH references the CTE outside its final UNION arm")) {
      _ = try seed().run(query, counting())
    }
  }

  @Test func `a recursive reference before the final UNION arm is rejected`() throws {
    // The self-reference (`FROM Parent`) is a MIDDLE arm and the final arm is
    // non-recursive, so the recursive-arm check (which inspects the final arm)
    // sees no recursion and the CTE would take the run-once path — compiling the
    // middle `FROM Parent` against a same-named base (silently wrong) or, with
    // none, an unresolved relation. With no same-named base/view it is rejected
    // as an unsupported recursive shape.
    let query = try Statement(parsing: """
        WITH RECURSIVE Parent (Id) AS (
          SELECT 1 AS Id FROM Seed
          UNION ALL SELECT inc(Id) AS Id FROM Parent WHERE Id < 3
          UNION ALL SELECT 99 AS Id FROM Seed
        )
        SELECT Id FROM Parent
        """)
    #expect(throws: SQLError.state("0A000",
        "recursive WITH references the CTE outside its final UNION arm")) {
      _ = try seed().run(query, counting())
    }
  }

  @Test func `a recursive CTE whose anchor reads a same-named base still evaluates`() throws {
    // `Parent` intentionally shadows a base relation of the same name: the anchor
    // `SELECT Id FROM Parent` reads the BASE (the CTE is not in scope for the
    // base case), seeding the recursion, while the right arm's `FROM Parent` is
    // the true self-reference. The multiple-recursive-arm guard must NOT reject
    // this — the anchor's reference resolves to an existing base relation, so it
    // is a valid seed, not a misplaced recursive arm.
    let catalog = EngineMemory([
      "Parent": FixtureRelation([EngineField(name: "Id", type: .integer)],
                         [[.integer(1)]] as Array<Array<Value>>),
    ])
    let rows = try catalog.run(Statement(parsing: """
        WITH RECURSIVE Parent (Id) AS (
          SELECT Id FROM Parent
          UNION ALL SELECT inc(Id) AS Id FROM Parent WHERE Id < 5
        )
        SELECT Id FROM Parent
        """), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test func `a recursive CTE whose anchor reads a same-named view still evaluates`() throws {
    // Like `anchorShadowsBase`, but the same-named seed is a registered VIEW,
    // not a base table: the anchor `SELECT id FROM v` resolves to the view (the
    // CTE is not in scope for the base case), and the right arm is the true
    // self-reference. The guard must accept a view seed as well as a table.
    let view = try View(query: engineSelect("SELECT Id FROM Parent"), columns: ["id"])
    let catalog = EngineMemory([
      "Parent": FixtureRelation([EngineField(name: "Id", type: .integer)],
                         [[.integer(1)]] as Array<Array<Value>>),
    ], views: ["v": view])
    let rows = try catalog.run(Statement(parsing: """
        WITH RECURSIVE v (id) AS (
          SELECT id FROM v
          UNION ALL SELECT inc(id) AS id FROM v WHERE id < 5
        )
        SELECT id FROM v
        """), counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)], [.integer(5)]])
  }

  @Test func `UNION dedups rows a UNION ALL recursion would repeat`() throws {
    // The recursive arm re-derives n from 1 without a guard's monotonic bound,
    // but a bare UNION dedups whole rows, so the fixpoint is the distinct set
    // 1..4 reached and nothing new thereafter — it terminates where UNION ALL
    // would loop. inc advances; the WHERE caps the run, and UNION drops dupes.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION
          SELECT inc(n) AS n FROM c WHERE n < 4
        )
        SELECT n FROM c
        """)
    let rows = try seed().run(query, counting())
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)]])
  }

  @Test func `a bare UNION dedups duplicate anchor seed rows`() throws {
    // The anchor is itself a UNION ALL that yields `1` twice, so the seed
    // carries a duplicate; the recursive arm (`n < 1`) adds nothing new. A bare
    // outer UNION dedups the seed exactly as it dedups an iteration step, so the
    // duplicate anchor rows collapse to the single distinct row `1` rather than
    // leaking both into the result.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT 1 AS n FROM Seed
          UNION
          SELECT inc(n) AS n FROM c WHERE n < 1
        )
        SELECT n FROM c
        """)
    let rows = try seed().run(query, counting())
    #expect(rows == [[.integer(1)]])
  }

  @Test func `a transitive-closure self-join reaches every descendant`() throws {
    // The closure of the edge chain 1->2->3->4: seed with the direct edges,
    // then extend each known reach (Src, Dst) by an edge out of Dst. The
    // recursive arm joins the CTE to the base Edge relation.
    let query = try Statement(parsing: """
        WITH RECURSIVE reach (Src, Dst) AS (
          SELECT Src, Dst FROM Edge
          UNION ALL
          SELECT reach.Src, Edge.Dst FROM reach
            JOIN Edge ON Edge.Src = reach.Dst
        )
        SELECT Src, Dst FROM reach ORDER BY Src ASC
        """)
    let rows = try seed().run(query)
    // Direct: (1,2)(2,3)(3,4); extended: (1,3)(2,4); further: (1,4).
    let pairs = rows.map { row -> (Int, Int) in
      guard case let .integer(a) = row[0], case let .integer(b) = row[1]
      else { return (0, 0) }
      return (a, b)
    }
    #expect(Set(pairs.map { "\($0.0)-\($0.1)" }) == [
      "1-2", "2-3", "3-4", "1-3", "2-4", "1-4",
    ])
  }

  @Test func `a recursive arm of the wrong width faults, not traps, before rebinding`() throws {
    // `Edge` is a two-column relation, but the column list declares three
    // names; the anchor's `SELECT *` compiles to a two-wide plan the fixpoint
    // would bind under the three-column schema, so the recursive arm's read of
    // the absent third ordinal would trap in `RelationInstance.record`. The
    // anchor's compiled width is checked against the declared arity BEFORE it
    // seeds the working set, so the fault surfaces as `SQLError.columns` rather
    // than a trap.
    let query = try Statement(parsing: """
        WITH RECURSIVE t (a, b, c) AS (
          SELECT * FROM Edge
          UNION ALL
          SELECT a, b, c FROM t WHERE a < 0
        )
        SELECT a FROM t
        """)
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try seed().run(query)
    }
  }

  @Test func `a zero-row SELECT * anchor of the wrong width faults, not passes`() throws {
    // `Edge` is a two-column relation, but the column list declares three
    // names. The anchor `WHERE Src < 0` yields no rows, so a per-row check
    // would seed nothing to validate and bind the CTE under a three-column
    // schema; the recursive arm's read of the absent third ordinal would then
    // trap. The anchor's compiled width is checked against the declared arity
    // BEFORE it seeds the working set, regardless of how many rows it produces,
    // so the fault surfaces as `SQLError.columns`.
    let query = try Statement(parsing: """
        WITH RECURSIVE t (a, b, c) AS (
          SELECT * FROM Edge WHERE Src < 0
          UNION ALL
          SELECT a, b, c FROM t WHERE a < 0
        )
        SELECT a FROM t
        """)
    #expect(throws: SQLError.columns(expected: 3, got: 2)) {
      try seed().run(query)
    }
  }

  @Test func `a runaway recursion is capped with SQLError.recursion`() throws {
    // inc(n) with no terminating WHERE produces an unbounded sequence of new
    // rows; UNION ALL keeps every one, so the fixpoint is never reached and the
    // cap fires.
    let query = try Statement(parsing: """
        WITH RECURSIVE c (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT inc(n) AS n FROM c
        )
        SELECT n FROM c
        """)
    #expect(throws: SQLError.recursion("c")) {
      try seed().run(query, counting())
    }
  }
}
