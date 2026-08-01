// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// A `Query.ordered` carrier wraps a set operation with the query-level row
// operators (`ORDER BY`/`DISTINCT`/`OFFSET`·`FETCH`); it compiles to a
// `.shaped` project/sort/distinct/limit stack over the `.setop`, NOT a bare
// `.setop`. Several correlated-subquery and view seams matched `if case .setop
// = <query>`/`if case .setop = <plan>` directly, silently swallowing the
// carrier — a correlated ordered set-op subquery (its plan a `.shaped` stack)
// never reached the per-arm augment, so an arm-local derived alias went
// unmaterialised (`.relation`), and a reached irreconcilable pair skipped its
// strict re-fold (run/validate diverged). These seams now route through the
// carrier-transparent core (`Query.core`) and the shared carrier descender
// (`execute(_:carrying:)` / the view `setop` and `optimise` per-arm helpers),
// so carrier transparency is a construction guarantee. Each test pairs the
// ordered shape with its bare (non-carrier) baseline to show the two agree.

// MARK: - Fixtures

/// A `People` catalog plus a single-column `S` for correlated ordered set-op
/// subqueries: `People` seeds the correlation, `S` an arm source.
private func people() throws -> FixtureCatalog {
  try Catalog {
    Relation("People", ["Id": .integer, "Name": .text, "Age": .integer],
             sorted: "Id") {
      Row(1, "Alice", 30)
      Row(2, "Bob", 25)
    }
    Relation("S", ["V": .integer]) {
      Row(7)
      Row(8)
    }
  }
}

/// A catalog whose view bodies are set operations — one riding an `ORDER BY`
/// carrier, one bare — each arm naming its own arm-local derived table `d`, so
/// the per-arm augmentation must materialise it before the arm's scan reads it.
private func views() throws -> FixtureCatalog {
  try Catalog {
    Relation("S", ["V": .integer]) {
      Row(7)
      Row(8)
    }
    try View("ordered", """
        SELECT * FROM (SELECT V FROM S) AS d
        UNION ALL SELECT V FROM S ORDER BY V
        """, as: ["V"])
    try View("bare", """
        SELECT * FROM (SELECT V FROM S) AS d UNION ALL SELECT V FROM S
        """, as: ["V"])
  }
}

/// A catalog for a suffix-bearing set-operation carrier NESTED as an operand of
/// an OUTER set operation — the reviewer's shape. `A` {1, 2}, `B` {2, 3}, `C`
/// {3, 4}. The nested operand `(d UNION ALL C ORDER BY n FETCH FIRST 1 ROW
/// ONLY)` — `d` being the arm-local derived `SELECT n FROM B` — orders the
/// four-row union {2, 3, 3, 4} and takes the one smallest, 2. The view body
/// unions `A` with that, yielding 1, 2, 2.
private func nested() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["n": .integer]) { Row(1); Row(2) }
    Relation("B", ["n": .integer]) { Row(2); Row(3) }
    Relation("C", ["n": .integer]) { Row(3); Row(4) }
    try View("nested", """
        SELECT n FROM A
         UNION ALL (SELECT n FROM (SELECT n FROM B) AS d
                     UNION ALL SELECT n FROM C ORDER BY n FETCH FIRST 1 ROW ONLY)
        """, as: ["n"])
  }
}

/// Like `nested()`, but the nested carrier's inner derived-table arm carries a
/// WHERE over a sorted source column — a filter the optimiser's per-arm seek
/// pass inspects, so it must resolve `d`'s schema during OPTIMISATION (not only
/// execution). `B` is sorted on `k`; `d.k = 1` selects the row `n = 20`, then
/// `{20} UNION ALL C {9}` ordered and paged to one takes 9, so the view unions
/// `A` {1} with 9.
private func nestedSeek() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["n": .integer]) { Row(1) }
    Relation("B", ["n": .integer, "k": .integer], sorted: "k") {
      Row(20, 1)
      Row(30, 2)
    }
    Relation("C", ["n": .integer]) { Row(9) }
    try View("nestedseek", """
        SELECT n FROM A
         UNION ALL (SELECT n FROM (SELECT n, k FROM B) AS d WHERE d.k = 1
                     UNION ALL SELECT n FROM C ORDER BY n FETCH FIRST 1 ROW ONLY)
        """, as: ["n"])
  }
}

// MARK: - Tests

struct OrderedSetOperationCarrierTests {
  @Test func `a correlated IN over an ordered set op materialises each arm's derived table`()
      throws {
    // gap-A2: the correlated `IN (…)` subquery is a set operation under an ORDER
    // BY carrier, so its plan is a `.shaped` stack — `if case .setop = plan` was
    // false, so it fell to the whole-query augment, which binds no arm-local
    // derived alias (a setop collects none), and arm-0's `.scan("x")` faulted
    // `.relation('x')`. It now routes through `execute(_:carrying:)`, per-arm
    // augmenting `x` before the arm scan. Alice (Age 30) matches the arm value.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT V FROM (VALUES (30)) AS x(V) WHERE x.V = p.Age
           UNION VALUES (99) ORDER BY 1)
        """, yields: [[1]])
  }

  @Test func `a bare correlated IN set op materialises each arm's derived table`()
      throws {
    // The non-ordered baseline (a bare `.setop` plan) already worked — the
    // ordered form now matches it exactly.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT V FROM (VALUES (30)) AS x(V) WHERE x.V = p.Age
           UNION VALUES (99))
        """, yields: [[1]])
  }

  @Test func `an ordered set-op view materialises each arm's derived table`()
      throws {
    // gap-A3/A4: a view body that is a set operation under an ORDER BY carrier
    // compiles to a `.shaped` plan, so both the view execute (`derive`) and the
    // view optimiser (`optimise(view:)`) guards (`case .setop = view.query` and
    // `case .setop = plan`) failed and the per-arm augment was skipped —
    // arm-0's `.scan("d")` faulted `.relation('d')`. Both now descend the
    // carrier wrapper to the setop leaf. `S` = {7, 8}, so the UNION ALL of the
    // derived `d` arm and the `S` arm, ordered, is 7, 7, 8, 8.
    try views().expect("SELECT * FROM ordered", yields: [[7], [7], [8], [8]])
  }

  @Test func `a bare set-op view materialises each arm's derived table`()
      throws {
    // The non-ordered baseline (a bare `.setop` view body) already worked; it
    // yields the same multiset as the ordered form, but unsorted — the two arms
    // in source order: the derived `d` arm ({7, 8}) then the `S` arm ({7, 8}).
    try views().expect("SELECT * FROM bare", yields: [[7], [8], [7], [8]])
  }

  @Test func `a carrier set op nested as a union arm materialises its inner derived table (view)`()
      throws {
    // The real suffix-bearing carrier now reaches a NESTED operand position: the
    // outer view body is `.setop(SELECT n FROM A, .ordered(.setop(…)))`. The
    // per-arm recursion (`setop`/`arms`) split the outer union, then hit the
    // right arm `.ordered(.setop(…))` — a `.shaped` carrier, not a bare `.setop`
    // — and, before this fix, whole-query augmented it as one opaque leaf,
    // binding no arm-local `d` so its `.scan("d")` faulted `.relation('d')`. The
    // recursion now peels the carrier `core` and descends to the inner setop
    // leaf, per-arm augmenting `d`. Inner: {2,3}∪{3,4} ordered, FETCH 1 → 2;
    // outer: A {1,2} then that one → 1, 2, 2.
    try nested().expect("SELECT * FROM nested", yields: [[1], [2], [2]])
    let catalog = try nested()
    #expect(throws: Never.self) {
      _ = try catalog.columns(of: parse(query: "SELECT * FROM nested"))
    }
  }

  @Test func `a carrier set op nested as a union arm materialises its inner derived table (correlated)`()
      throws {
    // The correlated form drives the same nested-arm recursion through
    // `Filter.arms`: the correlated `IN (…)` body is `.setop(SELECT V FROM S,
    // .ordered(.setop(…)))`, whose right arm is a carried setop naming its own
    // arm-local `d` (and correlating `p.Age`). For Alice (Age 30) the inner
    // `d.V = p.Age` arm yields {30}, so the paged inner is 30 and the IN set is
    // {7, 8, 30} — 30 ∈ it, Alice matches; for Bob (25) the inner is {99}, the
    // set {7, 8, 99}, 25 ∉ it. Before the fix arm-0's `.scan("d")` faulted.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT V FROM S
            UNION ALL (SELECT V FROM (VALUES (30)) AS d(V) WHERE d.V = p.Age
                        UNION ALL VALUES (99)
                        ORDER BY V FETCH FIRST 1 ROW ONLY))
        """, yields: [[1]])
  }

  @Test func `a nested carrier arm with a seekable filter peels during view optimization`()
      throws {
    // The nested carrier's inner derived arm carries `WHERE d.k = 1` over a
    // sorted source, so the view OPTIMISER's per-arm seek pass inspects it and
    // must resolve `d`'s schema. The optimiser recursion (`optimise(_:_:_:)`)
    // was carrier-transparent only for a direct `.setop`, so the nested
    // `.ordered(.setop)` arm fell to the generic optimiser, which seek-resolved
    // `.scan("d")` against an unbound `d` and faulted `.relation`. It now peels
    // the carrier `core` and optimises each inner arm under its own augment.
    // `d.k = 1` → n = 20; `{20} ∪ C {9}` ordered, FETCH 1 → 9; A {1} then 9.
    try nestedSeek().expect("SELECT * FROM nestedseek", yields: [[1], [9]])
  }

  @Test func `a reached correlated scalar ordered set op faults on irreconcilable arms`()
      throws {
    // gap-A1: a reached correlated scalar subquery over an ordered set operation
    // with irreconcilable arms (text `'x'` beside integer `1`) skipped the
    // strict operand re-fold — `if case .setop = key.query` was false for the
    // `.ordered` carrier — so the run returned rows where the uncorrelated form
    // faults, a run-vs-validate divergence. It now folds on `key.query.core`,
    // faulting `.operand`/42804 as the uncorrelated form does.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age =
          (SELECT 'x' FROM S WHERE S.V = p.Id UNION SELECT 1 FROM S ORDER BY 1)
        """, fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `a reached correlated IN ordered set op faults on irreconcilable arms`()
      throws {
    // The `.valued` (`IN`) reach re-folds too — a reached irreconcilable
    // ordered set-op `IN` faults identically.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT 'x' FROM S WHERE S.V = p.Id UNION SELECT 1 FROM S ORDER BY 1)
        """, fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `an uncorrelated scalar ordered set op faults the same way`()
      throws {
    // The uncorrelated form the correlated one must match: its arms are folded
    // eagerly, faulting `.operand` at run whether ordered or not.
    try people().expect("""
        SELECT Id FROM People
          WHERE Age = (VALUES ('a') UNION VALUES (1) ORDER BY 1)
        """, fails: .operand("UNION arms have irreconcilable types"))
  }

  @Test func `an unreached correlated scalar ordered set op does not fault`()
      throws {
    // The deferral posture is preserved: a subquery guarded by a statically
    // false conjunct (`1 = 0 AND …`) is never reached, so its irreconcilable
    // arms are NOT re-folded — the run yields no rows and does not fault, the
    // dead-subquery posture the shape pre-pass defers.
    try people().empty("""
        SELECT Id FROM People p WHERE 1 = 0 AND p.Age =
          (SELECT 'x' FROM S WHERE S.V = p.Id UNION SELECT 1 FROM S ORDER BY 1)
        """)
  }

  @Test func `columns(of:) faults a reached irreconcilable ordered set op`()
      throws {
    // The static shape check already faulted (the F2 `typecheck` `.ordered`
    // seam re-folds a reached carried union's arms); the run now matches it, so
    // run ≡ columns(of:). Confirm the schema path still faults for both the
    // scalar and IN shapes.
    let catalog = try people()
    guard case let .select(scalar) = try Statement(parsing: """
        SELECT Id FROM People p WHERE p.Age =
          (SELECT 'x' FROM S WHERE S.V = p.Id UNION SELECT 1 FROM S ORDER BY 1)
        """), case let .select(within) = try Statement(parsing: """
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT 'x' FROM S WHERE S.V = p.Id UNION SELECT 1 FROM S ORDER BY 1)
        """) else {
      Issue.record("expected two SELECT statements")
      return
    }
    #expect(throws: SQLError.operand("UNION arms have irreconcilable types")) {
      _ = try catalog.columns(of: scalar)
    }
    #expect(throws: SQLError.operand("UNION arms have irreconcilable types")) {
      _ = try catalog.columns(of: within)
    }
  }

  @Test func `columns(of:) does not fault an unreached irreconcilable ordered set op`()
      throws {
    // The schema-path deferral matches the run's: an unreached carried union is
    // not re-folded, so `columns(of:)` advertises the query without faulting.
    let catalog = try people()
    guard case let .select(dead) = try Statement(parsing: """
        SELECT Id FROM People p WHERE 1 = 0 AND p.Age =
          (SELECT 'x' FROM S WHERE S.V = p.Id UNION SELECT 1 FROM S ORDER BY 1)
        """) else {
      Issue.record("expected a SELECT statement")
      return
    }
    #expect(throws: Never.self) { _ = try catalog.columns(of: dead) }
  }

  // MARK: - Carrier ORDER BY nesting a subquery

  @Test func `a carrier ORDER BY with an uncorrelated EXISTS runs like a plain SELECT`()
      throws {
    // A carrier `ORDER BY` may nest an `EXISTS`/`IN`/scalar subquery. An
    // uncorrelated one records no per-outer-row plan (its probe runs
    // standalone), so it worked already — the set-op carrier matches the same
    // ORDER BY on a plain SELECT over the identical multiset (a derived table
    // wrapping the union). `S` is non-empty, so the `EXISTS` is TRUE for every
    // row and the sort key is a constant `0`; the secondary ordinal orders the
    // rows.
    let catalog = try people()
    try catalog.expect("""
        SELECT Id FROM People UNION ALL SELECT V FROM S
          ORDER BY CASE WHEN EXISTS (SELECT V FROM S) THEN 0 ELSE 1 END, 1
        """, equals: """
        SELECT Id FROM (SELECT Id FROM People
                        UNION ALL SELECT V FROM S) AS T
          ORDER BY CASE WHEN EXISTS (SELECT V FROM S) THEN 0 ELSE 1 END, Id
        """)
  }

  @Test func `a carrier ORDER BY with a correlated scalar subquery runs like a plain SELECT`()
      throws {
    // finding #1: a carrier `ORDER BY` subquery that correlates to the
    // enclosing query (`… WHERE V < p.Id`, a set operation inside an outer
    // `IN`) resolves the correlation but recorded no runtime plan — the
    // recording pass asked `arm.roles(of:)`, and the ARM does not carry the
    // carrier's sort-key subquery, so its correlated `Subkey` lowered yet
    // faulted "a correlated subquery plan was not compiled" at execution. The
    // carrier now records its own ORDER BY subqueries' plans (through a
    // classifier select carrying the carrier's ORDER BY), so a correlated sort
    // key re-executes per outer row exactly as it does on a plain SELECT — the
    // inner set operation replaced by a derived table over the same multiset,
    // whose ORDER BY takes the ordinary supported correlated-subquery path.
    // `S` = {7, 8}: for `p.Id` 1 or 2 the ORDER BY count is 0 (a no-op sort),
    // so the `IN` keeps its members.
    let catalog = try people()
    try catalog.expect("""
        SELECT p.Id FROM People p WHERE p.Id IN
          (SELECT Id FROM People UNION ALL SELECT V FROM S
             ORDER BY (SELECT COUNT(*) FROM S WHERE V < p.Id), 1)
        """, equals: """
        SELECT p.Id FROM People p WHERE p.Id IN
          (SELECT Id FROM (SELECT Id FROM People
                           UNION ALL SELECT V FROM S) AS T
             ORDER BY (SELECT COUNT(*) FROM S WHERE V < p.Id), Id)
        """)
  }

  @Test func `a carrier ORDER BY with a correlated EXISTS runs like a plain SELECT`()
      throws {
    // The `EXISTS` role records too: an outer-correlated `EXISTS` sort key over
    // the set operation re-probes per outer row like the plain-SELECT form, no
    // longer faulting "plan was not compiled". The ORDER BY does not change the
    // `IN` membership, so both forms return the outer Ids whose value the inner
    // multiset contains.
    let catalog = try people()
    try catalog.expect("""
        SELECT p.Id FROM People p WHERE p.Id IN
          (SELECT Id FROM People UNION ALL SELECT V FROM S
             ORDER BY CASE WHEN EXISTS (SELECT V FROM S WHERE V < p.Id)
                          THEN 0 ELSE 1 END, 1)
        """, equals: """
        SELECT p.Id FROM People p WHERE p.Id IN
          (SELECT Id FROM (SELECT Id FROM People
                           UNION ALL SELECT V FROM S) AS T
             ORDER BY CASE WHEN EXISTS (SELECT V FROM S WHERE V < p.Id)
                          THEN 0 ELSE 1 END, Id)
        """)
  }

  @Test func `a carrier ORDER BY with a correlated subquery yields the outer rows`()
      throws {
    // The concrete rows the outer-correlated carrier ORDER BY produces — no
    // fault. The inner set operation's multiset is `People.Id` (1, 2) ∪ `S`
    // (7, 8); the outer `IN` keeps the `People` rows whose `Id` the multiset
    // holds — Ids 1 and 2 — with the correlated ORDER BY subquery re-executing
    // per outer row, the row set the pre-fix run never reached.
    let catalog = try people()
    try catalog.expect("""
        SELECT p.Id FROM People p WHERE p.Id IN
          (SELECT Id FROM People UNION ALL SELECT V FROM S
             ORDER BY (SELECT COUNT(*) FROM S WHERE V < p.Id), 1)
        """, yields: [[1], [2]])
  }

  // MARK: - Carrier ORDER BY subquery scope (run ≡ validate)

  @Test func `a carrier ORDER BY subquery resolves a set-op output column at validate as at run`()
      throws {
    // finding (PR293): the `validate` carrier pre-pass derived each carrier
    // ORDER BY subquery's width/type against `context.outer`, while the run
    // resolved the same subquery against the set-operation output scope. A
    // carrier ORDER BY subquery referencing a set-op output column — an aliased
    // output (`Id AS Key`) living ONLY in that scope, absent from the outer —
    // therefore resolved at run yet faulted `SQLError.column("Key")` at
    // validate: a query that executes was rejected by `columns(of:, validate:
    // true)`. The pre-pass now derives against the same set-op output scope
    // (nested under the outer), so it resolves at validate exactly as at run.
    // `S` = {7, 8} is non-empty, so the `EXISTS` sort key is a constant.
    let catalog = try people()
    let sql = """
        SELECT Id AS Key FROM People UNION ALL SELECT V FROM S
          ORDER BY CASE WHEN EXISTS (SELECT V FROM S WHERE V = Key)
                       THEN 0 ELSE 1 END
        """
    // Runs — the row set the pre-fix validate would have rejected. The `Key`
    // sort key makes the `EXISTS` TRUE only where an `S.V` equals the output
    // `Key`: the `S` arm's values 7 and 8 sort first (key 0), the `People`
    // Ids 1 and 2 after (key 1).
    try catalog.expect(sql, yields: [[7], [8], [1], [2]])
    // And validates: run ≡ columns(of:, validate: true).
    guard case let .select(select) = try Statement(parsing: sql) else {
      Issue.record("expected a SELECT statement")
      return
    }
    #expect(throws: Never.self) {
      _ = try catalog.columns(of: select, validate: true)
    }
  }

  @Test func `the reviewer's EXISTS carrier ORDER BY runs and validates`()
      throws {
    // The reviewer's exact shape — an `EXISTS` sort key correlating to a bare
    // set-op output column (`Id`, shared with a base relation) — already ran
    // and validated (`width` derives the projection only, and `Id` binds via
    // the outer/base), and still does after the scope alignment.
    let catalog = try people()
    let sql = """
        SELECT Id FROM People UNION ALL SELECT V FROM S
          ORDER BY CASE WHEN EXISTS (SELECT V FROM S WHERE V = Id)
                       THEN 0 ELSE 1 END
        """
    try catalog.expect(sql, yields: [[1], [2], [7], [8]])
    guard case let .select(select) = try Statement(parsing: sql) else {
      Issue.record("expected a SELECT statement")
      return
    }
    #expect(throws: Never.self) {
      _ = try catalog.columns(of: select, validate: true)
    }
  }

  @Test func `a carrier ORDER BY subquery naming an unknown column still faults at run and validate`()
      throws {
    // guard: the scope alignment must not OVER-widen. A carrier ORDER BY
    // subquery referencing a genuinely-unresolvable column (`Zzz` — neither a
    // set-op output nor an outer/base column) still faults `SQLError.column` at
    // both run and validate.
    let catalog = try people()
    let sql = """
        SELECT Id AS Key FROM People UNION ALL SELECT V FROM S
          ORDER BY CASE WHEN EXISTS (SELECT V FROM S WHERE V = Zzz)
                       THEN 0 ELSE 1 END
        """
    catalog.expect(sql, fails: .column("Zzz"))
    guard case let .select(select) = try Statement(parsing: sql) else {
      Issue.record("expected a SELECT statement")
      return
    }
    #expect(throws: SQLError.column("Zzz")) {
      _ = try catalog.columns(of: select, validate: true)
    }
  }

  // MARK: - Carrier robustness (per-arm scope, malformed generated counts)

  @Test func `an ordered union over arm-local derived tables runs like the bare union`()
      throws {
    // finding #1: an ORDER BY carrier over a set operation whose arms name
    // their own arm-local derived tables (`d`, `e`) faulted `.relation('d')`
    // though the same union without the ORDER BY ran fine. The top-level
    // `run(.setop)` path runs each arm per ARM — arm-local aliases bind — but
    // the ordered carrier fell to the generic `optimise`, rewriting both arms
    // under the one carrier-level context that binds no arm-owned alias, so its
    // `seek` rewrite faulted `.relation('d')` before the per-arm
    // `execute(…carrying:)` could augment each arm. `run` now routes an
    // ordered-over-setop carrier through the per-arm optimiser (mirroring the
    // view carrier path). The ordered result equals the bare union's rows.
    let cat = try Catalog {
      Relation("Anchor", ["x": .integer]) { Row(0) }
    }
    // The arms select from arm-local derived tables (`d`, `e`), not `Anchor` —
    // `Anchor` only gives the catalog a base relation. Ordered = bare, sorted.
    try cat.expect("""
        SELECT v FROM (VALUES (1)) AS d(v) WHERE v = 1
        UNION ALL SELECT v FROM (VALUES (2)) AS e(v) ORDER BY 1
        """, yields: [[1], [2]])
    try cat.expect("""
        SELECT v FROM (VALUES (1)) AS d(v) WHERE v = 1
        UNION ALL SELECT v FROM (VALUES (2)) AS e(v)
        """, yields: [[1], [2]])
  }

  @Test func `a DISTINCT paged ordered union over arm-local derived tables runs`()
      throws {
    // finding #1 (other carrier operators): the per-arm descent threads through
    // the DISTINCT dedup and OFFSET·FETCH paging too, not only ORDER BY. Each
    // arm carries a `WHERE` over its own arm-local derived table — the filter
    // the generic optimiser's `seek` rewrite would resolve under the wrong
    // (carrier-level) scope, faulting `.relation` pre-fix. A bare `UNION`
    // dedups the two `1` arms with the `2` arm to {1, 2}; ordered, OFFSET 1
    // FETCH 1 takes the single row `2`.
    let cat = try Catalog {
      Relation("Anchor", ["x": .integer]) { Row(0) }
    }
    try cat.expect("""
        SELECT v FROM (VALUES (1)) AS d(v) WHERE v = 1
        UNION SELECT v FROM (VALUES (1)) AS e(v) WHERE v = 1
        UNION SELECT v FROM (VALUES (2)) AS f(v) WHERE v = 2
        ORDER BY 1 OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY
        """, yields: [[2]])
  }

  @Test func `an ordered union arm over a genuinely-missing relation still faults`()
      throws {
    // finding #1 guard (no over-masking): the per-arm route must NOT swallow a
    // real missing-relation fault. An arm referencing a relation that does NOT
    // exist (`NoSuchRel`) still faults `.relation('NoSuchRel')`, both with and
    // without the ORDER BY carrier — the fix only per-arm-scopes arm-local
    // derived aliases; a genuinely absent relation is still unresolvable.
    let cat = try Catalog {
      Relation("Anchor", ["x": .integer]) { Row(0) }
    }
    cat.expect("""
        SELECT v FROM NoSuchRel UNION ALL VALUES (2) ORDER BY 1
        """, fails: .relation("NoSuchRel"))
    cat.expect("""
        SELECT v FROM NoSuchRel UNION ALL VALUES (2)
        """, fails: .relation("NoSuchRel"))
  }

  @Test func `a generated count over a SELECT-star union faults not traps`()
      throws {
    // finding #2: a hostile `Query.ordered(<union of two SELECT * arms>,
    // generated: 1)` — a PUBLIC AST case the parser never emits. A `SELECT *`
    // arm's projection is `.all`, so the carrier's `items` list is empty though
    // the resolved `width` is > 0. The old aliased-tail check `for k in 0 ..<
    // generated WHERE real + k < items.count` skipped every slot (items empty),
    // so the hidden-name mapping's `items[real + k].alias!` force-unwrapped an
    // absent item and trapped the process. (A trap cannot be caught in-process,
    // so this asserts the post-fix typed fault; pre-fix this crashed.) The
    // carrier now requires each generated tail slot to have an aliased
    // projected item, faulting XX000 rather than crashing.
    let cat = try Catalog {
      Relation("P", ["a": .integer, "b": .integer]) { Row(1, 2) }
      Relation("Q", ["c": .integer, "d": .integer]) { Row(3, 4) }
    }
    let union = Query.setop(
        .union,
        .select(Select(projection: .all, from: Relation(name: "P"))),
        .select(Select(projection: .all, from: Relation(name: "Q"))),
        all: true)
    let over = Query.ordered(union, distinct: false, order: nil, limit: nil,
                             generated: 1)
    #expect(throws: SQLError.state("XX000",
                                   "ordered set-operation generated tail " +
                                   "is not aliased")) {
      _ = try cat.run(over)
    }
  }

  @Test func `columns(of:) faults an out-of-range generated count not traps`()
      throws {
    // finding #3: the schema path `columns(unifying:)` trimmed a carrier's
    // hidden tail as `cols.prefix(cols.count - generated)` with no range guard.
    // A public-AST `generated` past the width makes the argument negative and
    // `Array.prefix` precondition-traps; a negative `generated` returns ALL
    // columns untrimmed — silently wrong and diverging from `run`, which faults
    // XX000. The schema path now mirrors the compile-path range guard (the
    // shared `real(trimming:of:)` helper), so both fault the same XX000. A
    // nested ordered carrier (an ordered arm of an outer union) reaches
    // `columns(unifying:)`'s `.ordered` case directly — the whole-query compile
    // pre-check does not guard it — so its malformed count actually trapped the
    // schema path (`Can't take a prefix of negative length`). A trap cannot be
    // caught in-process, so this asserts the post-fix typed fault; pre-fix this
    // crashed the process.
    let cat = try Catalog {
      Relation("P", ["a": .integer]) { Row(1) }
    }
    let fault = SQLError.state("XX000",
                               "ordered set-operation generated count out " +
                               "of range")
    // A nested ordered arm with a count past the width (1) — `cols.count −
    // 999` is negative, the schema-path `prefix` trap.
    let arm = Query.ordered(
        .select(Select(projection: .all, from: Relation(name: "P"))),
        distinct: false, order: nil, limit: nil, generated: 999)
    let nested = Query.setop(
        .union, arm,
        .select(Select(projection: .all, from: Relation(name: "P"))),
        all: true)
    #expect(throws: fault) {
      _ = try cat.columns(of: nested, routines: [:], validate: false)
    }
    // A top-level malformed carrier faults the same XX000 on both paths (the
    // whole-query compile guards it before `columns(unifying:)`, and the run
    // path's carrier guards it) — run ≡ columns(of:). A count past the width
    // and a negative count both fault.
    let union = Query.setop(
        .union,
        .select(Select(projection: .all, from: Relation(name: "P"))),
        .select(Select(projection: .all, from: Relation(name: "P"))),
        all: true)
    let over = Query.ordered(union, distinct: false, order: nil, limit: nil,
                             generated: 999)
    let under = Query.ordered(union, distinct: false, order: nil, limit: nil,
                              generated: -1)
    #expect(throws: fault) {
      _ = try cat.columns(of: over, routines: [:], validate: false)
    }
    #expect(throws: fault) {
      _ = try cat.columns(of: under, routines: [:], validate: false)
    }
    #expect(throws: fault) { _ = try cat.run(over) }
    #expect(throws: fault) { _ = try cat.run(under) }
    // A valid `generated: 0` returns the correct trimmed schema — one column.
    let valid = Query.ordered(union, distinct: false, order: nil, limit: nil,
                              generated: 0)
    #expect(try cat.columns(of: valid, routines: [:],
                            validate: false).count == 1)
  }
}
