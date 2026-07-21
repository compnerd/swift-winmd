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

  @Test func `a UNION over a text CTE column folds the body type`() throws {
    // The CTE `a` binds its body's DERIVED type (`x` is text), so the set-op
    // fold unifies text against text and runs — a `.integer` declared-name
    // placeholder would wrongly fault the all-text UNION as irreconcilable.
    let text = """
        WITH a (x) AS (SELECT 'b') SELECT x FROM a UNION SELECT 'c'
        """
    // The SCHEMA path folds the CTE column at its BODY-derived type too: it
    // must report `x` as `.text` and NOT fault, the compile-time mirror of the
    // run.
    let columns = try engineFamily().columns(of: Statement(parsing: text))
    #expect(columns.count == 1)
    #expect(columns[0].name == "x")
    #expect(columns[0].type == .text)
    let rows = try statement(text, engineFamily())
    #expect(rows == [[.text("b")], [.text("c")]])
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

  @Test func `UNION widens a mixed integer/double column and dedups the equal rows`() throws {
    // ISO unifies the result column type across the arms — an `integer` arm and
    // a `double` arm widen to `double`, and each arm's values are COERCED to
    // it. `1` and `1.0` then compare equal AND emit as the same coerced
    // `double`, so a bare UNION keeps one `1.0` (not the first arm's raw
    // `integer`).
    #expect(try statement("SELECT 1 UNION SELECT 1.0", engineFamily())
            == [[.double(1.0)]])
    // UNION ALL keeps every row, each coerced to the unified `double`.
    #expect(try statement("SELECT 1 UNION ALL SELECT 1.0", engineFamily())
            == [[.double(1.0)], [.double(1.0)]])
  }

  @Test func `UNION coercion collapses integers a rounded double cannot separate`() throws {
    // The unified column is `double`, so EVERY arm's value coerces to `double`
    // before the dedup: `2^53 + 1` (the integer `9007199254740993`) rounds to
    // `2^53.0` on promotion, becoming EQUAL to the double `2^53.0` — so the
    // three arms collapse to the ONE distinct `double`, the ISO
    // approximate-numeric result of a mixed-type UNION.
    let rows = try statement("""
        SELECT 9007199254740992.0
          UNION SELECT 9007199254740992
          UNION SELECT 9007199254740993
        """, engineFamily())
    #expect(rows == [[.double(9007199254740992.0)]])
  }

  @Test func `ORDER BY orders a widened mixed integer/double column by magnitude`() throws {
    // The CTE column unifies to `double`, so its integer arm coerces — `3`
    // emits as `3.0` — and the ordering runs over the widened values.
    let rows = try statement("""
        WITH a (x) AS (SELECT 3 UNION ALL SELECT 1.5) SELECT x FROM a ORDER BY x
        """, engineFamily())
    #expect(rows == [[.double(1.5)], [.double(3.0)]])
  }

  @Test func `ORDER BY over a widened mixed column past 2^53 stays a total order`() throws {
    // The column unifies to `double`, so every arm coerces — the two distinct
    // integers past 2^53 both round to `2^53.0` under the widening, ordering
    // stays a strict weak ordering, and the greatest value is the coerced
    // `double`.
    let rows = try statement("""
        WITH a (x) AS (SELECT 9007199254740993
                       UNION ALL SELECT 9007199254740993.0
                       UNION ALL SELECT 9007199254740992)
          SELECT x FROM a ORDER BY x
        """, engineFamily())
    #expect(rows.count == 3)
    #expect(rows.last == [.double(9007199254740992.0)])
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
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
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
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
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

  @Test func `a recursive CTE seeds its anchor from a same-named base column`()
      throws {
    // The anchor `SELECT Age FROM Parent` reads the BASE `Parent` — the CTE
    // self, whose sole column is `n`, is not in scope for the base case — while
    // only the recursive arm names the self. The set-op type fold must resolve
    // the anchor under the base scope; folding the whole query under the self
    // binding rejects the base-only `Age` (absent from the CTE's `(n)`), so a
    // valid query would trap or fault before running.
    let catalog = EngineMemory([
      "Parent": FixtureRelation([EngineField(name: "Age", type: .integer)],
                         [[.integer(29)]] as Array<Array<Value>>),
    ])
    let rows = try statement("""
        WITH RECURSIVE Parent (n) AS (
          SELECT Age FROM Parent
          UNION ALL SELECT n + 1 FROM Parent WHERE n < 31
        )
        SELECT n FROM Parent ORDER BY n
        """, catalog)
    #expect(rows == [[.integer(29)], [.integer(30)], [.integer(31)]])
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
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
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
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
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
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
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

  @Test func `a recursive arm that is itself a set-op folds the self at the anchor type`() throws {
    // The recursive arm `SELECT s FROM t INTERSECT SELECT 'b'` is ITSELF a set
    // operation, so `validate`'s recursive-arm typecheck folds its self column
    // (`s`) before `fixpoint` rebinds it. Binding the self under the ANCHOR's
    // derived type (`s` is text, from `SELECT 'b'`) — not a `.integer`
    // placeholder — lets text INTERSECT text unify rather than faulting a text
    // arm against an integer self. The SCHEMA path must report `s` as `.text`
    // without throwing, and the run terminates yielding `b`.
    let text = """
        WITH RECURSIVE t (s) AS (
          SELECT 'b' UNION SELECT s FROM t INTERSECT SELECT 'b'
        )
        SELECT s FROM t
        """
    let columns = try engineFamily().columns(of: Statement(parsing: text))
    #expect(columns.count == 1)
    #expect(columns[0].name == "s")
    #expect(columns[0].type == .text)
    let rows = try statement(text, engineFamily())
    #expect(rows == [[.text("b")]])
  }

  @Test func `a recursive CTE widening past its anchor types the self as unified`() throws {
    // The anchor `SELECT 1` is INTEGER but the recursive arm `n + 0.5` yields
    // a DOUBLE, so the CTE column `n` unifies to `.double` — the type every row
    // is coerced to. `fixpoint` binds the iterated self under those UNIFIED
    // types (not the anchor-only integer), so the recursive arm reads `n` at
    // the type its coerced values carry; the run yields the widened sequence
    // and the SCHEMA path reports `n` as `.double`, the run's own result type.
    let text = """
        WITH RECURSIVE t (n) AS (
          SELECT 1 AS n FROM Seed
          UNION ALL
          SELECT n + 0.5 AS n FROM t WHERE n < 3
        )
        SELECT n FROM t
        """
    let columns = try seed().columns(of: Statement(parsing: text),
                                     routines: [:])
    #expect(columns.count == 1)
    #expect(columns[0].name == "n")
    #expect(columns[0].type == .double)
    let rows = try seed().run(Statement(parsing: text))
    #expect(rows == [[.double(1.0)], [.double(1.5)], [.double(2.0)],
                     [.double(2.5)], [.double(3.0)]])
  }

  @Test func `a widening CTE's schema and run agree on an integer routine self`() throws {
    // The reviewer's parity case. Column `a` has an INTEGER anchor (`1`) but a
    // recursive arm `a + 0.5` that widens it to `.double`; the same arm calls
    // the INTEGER-declared `inc(a)` on that self column. Typing the self at the
    // UNIFIED `.double` (the type the run coerces its rows to) makes SCHEMA
    // validation and EXECUTION agree: both FAULT, because `inc` requires an
    // integer argument and the widened self is a double. Were the self typed at
    // the anchor-only integer, schema validation would call the query "valid"
    // while the run faults — the schema-vs-execution break this fix closes. The
    // fault case differs by path (static `.argument` vs the routine's own
    // `.argument`), so assert each throws an `SQLError`.
    let text = """
        WITH RECURSIVE t (a, b) AS (
          SELECT 1 AS a, 1 AS b FROM Seed
          UNION ALL
          SELECT a + 0.5 AS a, inc(a) AS b FROM t WHERE a < 3
        )
        SELECT a, b FROM t
        """
    #expect(throws: SQLError.self) {
      _ = try seed().columns(of: Statement(parsing: text),
                             routines: counting())
    }
    #expect(throws: SQLError.self) {
      _ = try seed().run(Statement(parsing: text), counting())
    }
  }

  @Test func `an all-NULL CTE column unifies with a later text arm`() throws {
    // The CTE `t`'s column `x` is a constant NULL in BOTH arms, so it places NO
    // type constraint: an enclosing UNION over `SELECT x FROM t` must unify it
    // with the `'c'` arm and run, yielding the NULL and the text. The CTE fold
    // carries the per-column unconstrained marker, so a bare reference to `x`
    // unifies like a fresh constant-NULL arm.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF('b', 'b') UNION SELECT NULLIF(1, 1))
          SELECT x FROM t UNION SELECT 'c'
        """, engineFamily())
    #expect(rows == [[.null], [.text("c")]])
  }

  @Test func `an all-NULL CTE column unifies regardless of arm order`() throws {
    // The order-independence case. The arms are REVERSED from the sibling test
    // — the integer-typed NULLIF leads — so the CTE fold defaults `x`'s
    // concrete type to `.integer` rather than `.text`. Without the
    // unconstrained marker the enclosing UNION would fault `.integer` against
    // the `'c'` text arm (the literal-fix regression); the marker unifies it
    // either way.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('b', 'b'))
          SELECT x FROM t UNION SELECT 'c'
        """, engineFamily())
    #expect(rows == [[.null], [.text("c")]])
  }

  @Test func `a three-arm all-NULL CTE column unifies in either order`() throws {
    // A three-arm all-NULL chain stays unconstrained through every merge, so
    // the enclosing UNION unifies it with the text arm — both the integer-first
    // and the text-first orderings yield the same {NULL, 'c'}.
    let forward = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('a', 'a')
                       UNION SELECT NULLIF('b', 'b'))
          SELECT x FROM t UNION SELECT 'c'
        """, engineFamily())
    #expect(forward == [[.null], [.text("c")]])
    let reversed = try statement("""
        WITH t (x) AS (SELECT NULLIF('b', 'b') UNION SELECT NULLIF('a', 'a')
                       UNION SELECT NULLIF(1, 1))
          SELECT x FROM t UNION SELECT 'c'
        """, engineFamily())
    #expect(reversed == [[.null], [.text("c")]])
  }

  @Test func `an all-NULL CTE column unifies beside a widening pair`() throws {
    // Column `a` is all-NULL (unconstrained) while column `b` genuinely widens
    // an integer arm to a double. The enclosing UNION unifies `a` with the text
    // arm and `b`'s double with the integer arm — `a` yields NULLs, `b` the
    // coerced doubles.
    let rows = try statement("""
        WITH t (a, b) AS (SELECT NULLIF(1, 1), 1
                          UNION SELECT NULLIF('x', 'x'), 2.5)
          SELECT a, b FROM t UNION SELECT 'c', 3
        """, engineFamily())
    #expect(Set(rows) == [[.null, .double(1.0)], [.null, .double(2.5)],
                          [.text("c"), .double(3.0)]])
  }

  @Test func `an all-NULL CTE column with no outer union yields NULL`() throws {
    // The marker changes only UNIFICATION, never the reported concrete type: a
    // top-level select over the all-NULL CTE column runs and yields the NULL,
    // exactly as before.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('b', 'b'))
          SELECT x FROM t
        """, engineFamily())
    #expect(rows == [[.null]])
  }

  @Test func `an all-NULL CTE column filters through IS NULL`() throws {
    // `x` is NULL, so `x IS NULL` is TRUE and keeps the row.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('b', 'b'))
          SELECT x FROM t WHERE x IS NULL
        """, engineFamily())
    #expect(rows == [[.null]])
  }

  @Test func `an all-NULL CTE column compared to a value drops the row`() throws {
    // `NULL = 'c'` is UNKNOWN under three-valued logic, so the row is filtered
    // and the result is empty.
    let rows = try statement("""
        WITH t (x) AS (SELECT NULLIF(1, 1) UNION SELECT NULLIF('b', 'b'))
          SELECT x FROM t WHERE x = 'c'
        """, engineFamily())
    #expect(rows.isEmpty)
  }

  @Test func `a recursive CTE with mismatched arm widths faults cleanly`() throws {
    // The anchor projects two columns (matching the declared list) and the
    // recursive arm one, so the recursive-arm width check FAULTS the column-
    // count mismatch — the arm's one-column degree against the two-name list —
    // rather than trap indexing the shorter arm during the fold. The RUN path
    // and the SCHEMA (`columns(of:)`) path must report the IDENTICAL ISO-
    // ordered fault (`expected: arm degree, got: declared count`): the arm-
    // width guard fires BEFORE the `kinds` derive whose inter-arm fold would
    // otherwise raise the reverse `(expected: anchor, got: arm)` order first
    // on the schema path. Assert the shared value so a future reorder cannot
    // silently re-diverge the two paths.
    let text = """
        WITH RECURSIVE t (a, b) AS (SELECT 1, 2 UNION SELECT Id FROM t)
          SELECT * FROM t
        """
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try statement(text, engineFamily())
    }
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try engineFamily().columns(of: Statement(parsing: text))
    }
  }

  @Test func `a recursive CTE anchor mismatch faults alike on both paths`()
      throws {
    // The declared list names two columns; the ANCHOR projects one (the
    // recursive arm two). The anchor-width guard runs before the arm's, so both
    // the RUN and the SCHEMA path report the anchor's one-column degree against
    // the two-name list in the SAME ISO order — the sibling of the arm-mismatch
    // parity, proving the declared-list guard wins whichever arm diverges.
    let text = """
        WITH RECURSIVE t (a, b) AS (SELECT 1 UNION SELECT Id, Id FROM t)
          SELECT * FROM t
        """
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try statement(text, engineFamily())
    }
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try engineFamily().columns(of: Statement(parsing: text))
    }
  }

  @Test func `a no-list recursive CTE faults its arm alike on both paths`()
      throws {
    // With NO explicit `(a, b)` list the CTE's column names come from the
    // ANCHOR's aliases (degree 2), so `cte.columns` is populated exactly as a
    // declared list would be. The recursive arm's single column therefore hits
    // the SAME arm-width guard, faulting `(expected: 1, got: 2)` on BOTH paths
    // — never reaching the `kinds`/`contributions` inter-arm throw, which is
    // consequently unreachable for a recursive CTE (its width is always checked
    // against the anchor-derived list first).
    let text = """
        WITH RECURSIVE t AS (SELECT 1 AS a, 2 AS b UNION SELECT Id AS a FROM t)
          SELECT * FROM t
        """
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try statement(text, engineFamily())
    }
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try engineFamily().columns(of: Statement(parsing: text))
    }
  }

  @Test func `a CTE whose body is narrower than its declared list faults`() throws {
    // The declared list names two columns and the body projects one, so the CTE
    // faults the declared-arity mismatch cleanly — never binding a narrow body
    // under the wider list to trap a later reader. The width check reports the
    // compiled body width against the declared list count.
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try statement("""
          WITH t (a, b) AS (SELECT 1) SELECT a FROM t
          """, engineFamily())
    }
  }

  @Test func `a recursive CTE with an all-NULL anchor unifies its recursive arm`()
      throws {
    // The reviewer's anchor-NULL case. The anchor `SELECT NULLIF(1, 1)` folds
    // to a CONSTANT NULL, so the CTE column `x` is UNCONSTRAINED: the recursive
    // arm — itself a set operation `SELECT x FROM t INTERSECT SELECT 'c'` — must
    // fold the self column against the text `'c'` WITHOUT faulting integer
    // against text, exactly as a bare constant-NULL arm unifies with any typed
    // arm. Because the schema-only self and the run-iteration self bind through
    // the SAME body-derived carrier, both carry the unconstrained mask and
    // cannot diverge. The recursive arm intersects the NULL row against `'c'`
    // (no match), so the fixpoint terminates at the anchor's single NULL row.
    let rows = try statement("""
        WITH RECURSIVE t (x) AS (
          SELECT NULLIF(1, 1) UNION SELECT x FROM t INTERSECT SELECT 'c'
        ) SELECT x FROM t
        """, engineFamily())
    #expect(rows == [[.null]])
  }

  @Test func `a recursive arm's derived body is not typed at the placeholder self`()
      throws {
    // The recursive arm reads the CTE self through a DERIVED body — `FROM
    // (SELECT s || 'c' AS s FROM t …) AS d` — whose `s || 'c'` is well typed
    // only when `s` is TEXT, its real (anchor-derived) type. The arm-WIDTH
    // probe binds the self under the placeholder-typed `declared` carrier
    // (`.integer`) purely to measure arity, and `augment` materialises that
    // derived body eagerly; were the probe validating, it would type `s || 'c'`
    // against the `.integer` placeholder and spuriously fault a runnable query.
    // The probe is NON-validating, so arity is measured without typing the
    // operands; the genuine arm operand check runs later under the unified
    // text carrier and passes. The SCHEMA path must report `s` as `.text`
    // WITHOUT throwing, agreeing with the run's terminating rows.
    let text = """
        WITH RECURSIVE t (s) AS (
          SELECT 'b'
          UNION ALL
          SELECT s FROM (SELECT s || 'c' AS s FROM t WHERE s = 'b') AS d
        ) SELECT * FROM t
        """
    let columns = try engineFamily().columns(of: Statement(parsing: text))
    #expect(columns.count == 1)
    #expect(columns[0].name == "s")
    #expect(columns[0].type == .text)
    let rows = try statement(text, engineFamily())
    #expect(rows == [[.text("b")], [.text("bc")]])
  }

  @Test func `a genuinely mistyped recursive arm still faults on the schema path`()
      throws {
    // The fix makes the arm-WIDTH probe non-validating, so a genuine operand
    // fault in the recursive arm must STILL be caught — by the later `kinds`-
    // seeded typecheck under the unified carrier, not the width probe. Here the
    // arm applies `||` (text-only) to the self column `n`, whose anchor is an
    // INTEGER: the unified self is integer, so `n || 'c'` is genuine text-
    // arithmetic-on-integer and must fault on BOTH the schema path and the run.
    let text = """
        WITH RECURSIVE t (n) AS (
          SELECT 1
          UNION ALL
          SELECT n || 'c' FROM t WHERE n < 3
        ) SELECT * FROM t
        """
    #expect(throws: SQLError.self) {
      _ = try engineFamily().columns(of: Statement(parsing: text))
    }
    #expect(throws: SQLError.self) {
      _ = try statement(text, engineFamily())
    }
  }
}
