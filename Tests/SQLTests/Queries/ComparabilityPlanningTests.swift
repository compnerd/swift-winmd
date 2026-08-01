// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixtures

/// A relation sorted on `Id` (so a range on it seeks a physical run) beside an
/// integer `N`, a text `S`, and a second integer `J` — enough to write a
/// cross-kind residual `N = S` next to a seekable `Id` range, and a comparable
/// residual `N = J` for the no-regression check.
private func seekable() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "N": .integer, "S": .text, "J": .integer],
             sorted: "Id") {
      Row(1, 10, "x", 10)
      Row(2, 20, "y", 20)
    }
  }
}

/// A left relation `A` joined to a right relation `B` sorted on `Bid`, `B`
/// carrying an integer `Bn` and a text `Bs` for a cross-kind residual pushed to
/// the inner side, and a comparable `Ak = Bk` equi key.
private func joinable() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["Ak": .integer, "Ax": .integer]) {
      Row(1, 100)
      Row(2, 200)
    }
    Relation("B", ["Bid": .integer, "Bk": .integer, "Bn": .integer,
                   "Bs": .text],
             sorted: "Bid") {
      Row(1, 1, 10, "x")
      Row(2, 2, 20, "y")
    }
  }
}

/// The incomparable-type fault a `integer = character varying` pair raises on
/// both the run and the `validate: true` schema path.
private let intVsText =
    SQLError.state("42804", "cannot compare integer with character varying")

// MARK: - Seek must not drop a cross-kind residual

/// Since a cross-kind comparison faults `42804`, the physical seek must not
/// treat it as a safe residual and drop it over an emptied range — the exact
/// optimiser bypass the carried comparability classification closes. Both the
/// run and the validate path fault, in lockstep.
struct SeekComparabilityTests {
  @Test func `an emptied seek keeps the cross-kind residual and faults`()
      throws {
    // `N = S` is the cross-kind conjunct and `Id < 0` the emptied seekable
    // range beside it. The un-seeked scan evaluates the leading `N = S` on the
    // first row and faults; the buggy optimiser would seek the empty `Id < 0`
    // run and keep `N = S` as a residual over the sought (empty) rows, never
    // evaluating it. The carried classification marks `N = S` unsafe so the
    // seek is declined and the fault surfaces on both run and validate.
    let query = try parse(query: "SELECT Id FROM T WHERE N = S AND Id < 0")
    #expect(throws: intVsText) { try seekable().columns(of: query) }
    try seekable().expect("SELECT Id FROM T WHERE N = S AND Id < 0",
                          fails: intVsText)
  }

  @Test func `the emptied-seek plan does not seek past the cross-kind conjunct`()
      throws {
    // The carried classification marks `N = S` unsafe, so `seek` declines the
    // one-conjunct seek (an unsafe residual over the sought run) and leaves the
    // full scan under the whole filter — no seeked `.scan` in the plan.
    let catalog = try seekable()
    let compiled = try catalog.compile(parse("SELECT Id FROM T "
                                              + "WHERE N = S AND Id < 0"))
    let plan = try catalog.optimise(compiled, [:])
    #expect(!sought(plan))
  }

  @Test func `a standalone cross-kind comparison over a sorted table faults`()
      throws {
    // No seekable conjunct at all: the whole filter is the cross-kind residual,
    // which must scan and fault rather than be folded away.
    let query = try parse(query: "SELECT Id FROM T WHERE N = S")
    #expect(throws: intVsText) { try seekable().columns(of: query) }
    try seekable().expect("SELECT Id FROM T WHERE N = S", fails: intVsText)
  }
}

// MARK: - Pushdown must not push a cross-kind predicate past a row-dropper

/// A cross-kind conjunct pushed onto a join's inner side, beside a seekable
/// emptying range on that side, must not be dropped when the executor seeks the
/// inner by the range — the pushdown/inner-seek analog of the plain seek
/// bypass. Both paths fault at commit 1.
struct PushdownComparabilityTests {
  @Test func `a cross-kind inner conjunct beside an emptied range faults`()
      throws {
    // The cross-kind `B.Bn = B.Bs` leads the emptied seekable `B.Bid < 0` on
    // the inner side, so selection pushdown lands both on `B`'s scan. The
    // executor materialises `B` under the leading `B.Bn = B.Bs` and faults; the
    // carried classification keeps it from being seeked past the empty
    // `B.Bid < 0` run (which would drop it and yield no inner rows).
    let sql = "SELECT A.Ax FROM A JOIN B ON A.Ak = B.Bk "
            + "WHERE B.Bn = B.Bs AND B.Bid < 0"
    #expect(throws: intVsText) { try joinable().columns(of: parse(query: sql)) }
    try joinable().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind ON conjunct bars the key hoist and faults`() throws {
    // A cross-kind `ON` conjunct beside a comparable equi key forbids hoisting
    // the key (which would hash the sides into disjoint buckets and silently
    // drop every pair), so the whole `ON` stays a nested-loop residual that
    // faults the cross-kind pair — run and validate agree.
    let sql = "SELECT A.Ax FROM A JOIN B ON A.Ak = B.Bk AND A.Ax = B.Bs"
    #expect(throws: intVsText) { try joinable().columns(of: parse(query: sql)) }
    try joinable().expect(sql, fails: intVsText)
  }
}

// MARK: - No regression: comparable filters still seek and hash

/// Over-classifying a comparable filter as unsafe would force a scan or a
/// nested loop where a seek or hash join is available — a real cost. A
/// like-kind seek and a like-kind equi join must keep their fast plans.
struct ComparablePlanRegressionTests {
  @Test func `a like-kind residual still seeks the range`() throws {
    // `Id < 5` seeks the sorted key and the comparable `N = J` rides below as a
    // safe residual — the optimised plan still reaches a seeked `.scan`.
    let catalog = try seekable()
    let compiled = try catalog.compile(parse("SELECT Id FROM T "
                                              + "WHERE Id < 5 AND N = J"))
    let plan = try catalog.optimise(compiled, [:])
    #expect(sought(plan))
    try catalog.expect("SELECT Id FROM T WHERE Id < 5 AND N = J",
                       yields: [[1], [2]])
  }

  @Test func `a like-kind equi join still hashes`() throws {
    // `A.Ak = B.Bk` is a comparable key, so the join hoists it and reaches the
    // hash/index `.join` node rather than a residual product.
    let catalog = try joinable()
    let compiled =
        try catalog.compile(parse("SELECT A.Ax FROM A JOIN B ON A.Ak = B.Bk"))
    let plan = try catalog.optimise(compiled, [:])
    #expect(joined(plan))
  }
}

// MARK: - An unreachable BETWEEN upper must not bar the hoist

/// `stamped`'s `.between` reconciled both bounds unconditionally, so a
/// cross-kind upper barred a sibling equi key's hash join even when the lower's
/// static FALSE makes the upper unreachable — the run's `ranged` short-circuits
/// on `test >= lower` before ever reaching the upper, so it cannot fault. The
/// `settled` gate now mirrors that short-circuit, leaving such a BETWEEN safe
/// so the comparable equi key still hoists. A reachable cross-kind upper (the
/// lower does not settle) stays unsafe and faults, so soundness is unchanged.
struct BetweenShortCircuitPlanningTests {
  @Test func `an unreachable cross-kind BETWEEN upper keeps the hash join`()
      throws {
    // `0 BETWEEN 1 AND 'x'`: `0 >= 1` is statically FALSE, so `ranged` never
    // reaches the `'x'` upper and it cannot fault. The BETWEEN is safe, so
    // `Scope.on` hoists the comparable `A.Ak = B.Bk` into a hash `.join` rather
    // than degrading to a Cartesian nested loop.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B "
            + "ON 0 BETWEEN 1 AND 'x' AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(joined(plan))
  }

  @Test func `the unreachable-upper BETWEEN join runs, no fault`() throws {
    // The BETWEEN is FALSE for every pair (the `'x'` upper never reached), so
    // the inner join yields nothing — and crucially never faults 42804, on
    // either the validate or the run path.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B "
            + "ON 0 BETWEEN 1 AND 'x' AND A.Ak = B.Bk"
    _ = try catalog.columns(of: parse(query: sql))
    try joinable().empty(sql)
  }

  @Test func `a reachable cross-kind BETWEEN upper still bars the hoist`()
      throws {
    // `5 BETWEEN 1 AND 'x'`: `5 >= 1` is TRUE, so the lower does not settle the
    // truth and `ranged` reaches the `'x'` upper — a reachable cross-kind pair
    // that faults. The BETWEEN stays unsafe, no key is hoisted, and both paths
    // fault 42804.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B "
            + "ON 5 BETWEEN 1 AND 'x' AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(!joined(plan))
    #expect(throws: intVsText) { try catalog.columns(of: parse(query: sql)) }
    try joinable().expect(sql, fails: intVsText)
  }
}

// MARK: - A NULL-determined LIKE must not bar the hoist

/// `stamped`'s `.like` required the subject to be character (and ignored the
/// escape), so a NULL-determined LIKE — a NULL pattern, escape, or subject the
/// run reads as UNKNOWN before any character check, never faulting — barred a
/// sibling equi key's hash join. The NULL-first gate (`vanishes` and the
/// constant-NULL subject skip) now leaves such a LIKE safe so the equi key
/// still hoists, while a reachable non-character LIKE stays unsafe and faults.
struct LikeNullDeterminedPlanningTests {
  private let notText =
      SQLError.state("42804", "LIKE requires character operands")

  @Test func `a NULL pattern over an integer subject keeps the hash join`()
      throws {
    // `B.Bn LIKE NULL` (integer `Bn`): the NULL pattern makes the whole LIKE
    // UNKNOWN before the subject's non-character type is read, so it cannot
    // fault. Safe, so the comparable `A.Ak = B.Bk` hoists to a `.join`.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B ON B.Bn LIKE NULL AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(joined(plan))
    _ = try catalog.columns(of: parse(query: sql))
    try joinable().empty(sql)
  }

  @Test func `a NULL escape over an integer subject keeps the hash join`()
      throws {
    // `B.Bn LIKE 'x' ESCAPE NULL`: the NULL escape likewise vanishes the LIKE
    // to UNKNOWN. The escape was previously ignored by `stamped`, so the
    // non-text subject wrongly barred the hoist; the gate now reads the escape.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B "
            + "ON B.Bn LIKE 'x' ESCAPE NULL AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(joined(plan))
    _ = try catalog.columns(of: parse(query: sql))
    try joinable().empty(sql)
  }

  @Test func `a NULL subject over a non-character pattern keeps the hash join`()
      throws {
    // `NULL LIKE 1`: the constant-NULL subject short-circuits `like` to UNKNOWN
    // from its `(.null, _, _)` arm before the pattern's type is read, so it
    // cannot fault. Safe, so the equi key hoists.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B ON NULL LIKE 1 AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(joined(plan))
    _ = try catalog.columns(of: parse(query: sql))
    try joinable().empty(sql)
  }

  @Test func `a reachable non-character LIKE still bars the hoist`() throws {
    // `B.Bn LIKE 'x'` (integer `Bn`, non-NULL pattern): a reachable
    // non-character subject the run faults. The LIKE stays unsafe, no key is
    // hoisted, and both paths fault 42804.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B ON B.Bn LIKE 'x' AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(!joined(plan))
    #expect(throws: notText) { try catalog.columns(of: parse(query: sql)) }
    try joinable().expect(sql, fails: notText)
  }

  @Test func `a parameter LIKE pattern beside an equi key bars the hoist`()
      throws {
    // A `:parameter` pattern is not NULL-determined — it may bind a
    // non-character value the run faults on — so `stamped` keeps it unsafe
    // (unlike `check`, which defers it to the run). No key is hoisted, so a
    // cross-kind binding faults at run rather than hashing rows away first.
    let catalog = try joinable()
    let sql = "SELECT A.Ax FROM A JOIN B ON B.Bn LIKE :p AND A.Ak = B.Bk"
    let plan = try catalog.optimise(try catalog.compile(parse(sql)), [:])
    #expect(!joined(plan))
    try joinable().expect(sql, fails: notText, bindings: ["p": .integer(1)])
  }
}

// MARK: - A carrier sort-key subquery is comparability-checked on both paths

/// A nonempty relation with an integer `num` beside a text `txt`, enough to
/// write a cross-kind `num = txt` comparison inside a query-level carrier sort
/// key's subquery whose uncorrelated body a run over an empty carrier never
/// evaluates.
private func crossable() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["num": .integer, "txt": .text]) {
      Row(1, "x")
      Row(2, "y")
    }
  }
}

/// A `Query.ordered` carrier's `ORDER BY` may nest an `EXISTS`/`IN`/scalar
/// subquery. Its uncorrelated body a run never materialises over an empty
/// carrier — the sort evaluates no key — so a cross-kind comparison inside that
/// body escaped the comparison-finder (the run returned empty) and the carrier
/// validate branch (which type-checked the keys but not the subquery bodies):
/// both accepted a query the equivalent plain `SELECT … ORDER BY` faults 42804.
/// The finder and the validator now recurse each reached carrier sort-key
/// subquery body — over the set-operation carrier and the recursive-CTE
/// fixpoint's peeled `ORDER BY` alike — so the fault surfaces on both paths, in
/// lockstep with the plain-select form, while an unreached or comparable body
/// still does not fault.
struct CarrierSubqueryComparabilityTests {
  @Test func `a cross-kind set-op carrier sort-key subquery faults on both paths`()
      throws {
    // The `EXISTS` body's `a.num = a.txt` is cross-kind. Over the empty carrier
    // the run evaluated no key, so it returned rows without faulting while the
    // carrier validate branch never checked the body — both lenient where the
    // plain `SELECT num FROM A ORDER BY CASE WHEN EXISTS (…) …` faults. The
    // recursion closes it: run and validate now fault 42804.
    let sql = """
        SELECT num FROM A UNION ALL SELECT num FROM A
          ORDER BY CASE WHEN EXISTS (SELECT 1 FROM A a WHERE a.num = a.txt)
                        THEN 1 ELSE 0 END
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try crossable().columns(of: query) }
    try crossable().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind scalar carrier sort-key subquery faults on both paths`()
      throws {
    // A scalar (not `EXISTS`) sort-key subquery reaches the finder through the
    // `.subquery` case, recorded only because `deferred` is seeded with the
    // sort keys' scalar subqueries. Its body's `a.num = a.txt` faults 42804 on
    // both paths too.
    let sql = """
        SELECT num FROM A UNION ALL SELECT num FROM A
          ORDER BY (SELECT COUNT(*) FROM A a WHERE a.num = a.txt)
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try crossable().columns(of: query) }
    try crossable().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind recursive-CTE carrier sort-key subquery faults on both paths`()
      throws {
    // The recursive-CTE fixpoint peels its trailing `ORDER BY` and applies it
    // through the same `carried` resolver, preflighting the keys in comparing
    // mode (`Engine.apply`) and validating them (`Engine.validate(carrier:)`).
    // A cross-kind `EXISTS` body inside that carrier ORDER BY faults 42804 on
    // both — the run no longer sorts the materialised rows past it.
    let catalog = try crossable()
    let sql = """
        WITH RECURSIVE t(n) AS (
          VALUES (1)
          UNION ALL
          SELECT n + 1 FROM t WHERE n < 3
          ORDER BY CASE WHEN EXISTS (SELECT 1 FROM A a WHERE a.num = a.txt)
                        THEN 0 ELSE 1 END
        ) SELECT n FROM t
        """
    let statement = try Statement(parsing: sql)
    let raised: SQLError?
    do {
      _ = try catalog.run(statement)
      raised = nil
    } catch let fault {
      raised = fault
    }
    #expect(raised == intVsText)
    #expect(throws: intVsText) {
      _ = try catalog.columns(of: try Statement(parsing: sql), validate: true)
    }
  }

  @Test func `a comparable carrier sort-key subquery does not fault`() throws {
    // No over-reach: the `EXISTS` body's `a.num = a.num` is like-kind, so
    // neither path faults and the run yields all four rows.
    let sql = """
        SELECT num FROM A UNION ALL SELECT num FROM A
          ORDER BY CASE WHEN EXISTS (SELECT 1 FROM A a WHERE a.num = a.num)
                        THEN 1 ELSE 0 END
        """
    _ = try crossable().columns(of: parse(query: sql))
    try crossable().expect(sql, yields: [[1], [2], [1], [2]])
  }

  @Test func `an unreached carrier sort-key subquery does not fault`() throws {
    // No over-reach: a constant-FALSE `AND` short-circuits before the
    // cross-kind `EXISTS`, so the subquery is never recorded and never
    // recursed — matching the run, which never materialises it. Neither path
    // faults.
    let sql = """
        SELECT num FROM A UNION ALL SELECT num FROM A
          ORDER BY CASE WHEN 1 = 0
                            AND EXISTS (SELECT 1 FROM A a WHERE a.num = a.txt)
                        THEN 1 ELSE 0 END
        """
    _ = try crossable().columns(of: parse(query: sql))
    try crossable().expect(sql, yields: [[1], [2], [1], [2]])
  }

  @Test func `a bare arithmetic carrier key does not fault the finder`() throws {
    // No over-reach: a carrier key that is a bare arithmetic expression carries
    // no comparison and no subquery, so the finder faults nothing and the run
    // orders the rows.
    let sql = """
        SELECT num FROM A UNION ALL SELECT num FROM A ORDER BY num + 1
        """
    _ = try crossable().columns(of: parse(query: sql))
    try crossable().expect(sql, yields: [[1], [1], [2], [2]])
  }
}
