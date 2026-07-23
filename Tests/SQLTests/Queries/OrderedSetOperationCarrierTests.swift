// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLTestSupport

// A `Query.ordered` carrier wraps a set operation with the query-level row
// operators (`ORDER BY`/`DISTINCT`/`OFFSET`·`FETCH`); it compiles to a
// `.shaped` project/sort/distinct/limit stack over the `.setop`, NOT a bare
// `.setop`. Several correlated-subquery and view seams matched `if case .setop
// = <query>`/`if case .setop = <plan>` DIRECTLY, silently swallowing the
// carrier — a correlated ordered set-op subquery (its plan a `.shaped` stack)
// never reached the per-arm augment, so an arm-local derived alias went
// unmaterialised (`.relation`), and a reached irreconcilable pair skipped its
// strict re-fold (run/validate diverged). These seams now route through the
// carrier-transparent core (`Query.core`) and the shared carrier descender
// (`execute(_:carrying:)` / the view `setop` and `optimise` per-arm helpers),
// so carrier transparency is a construction guarantee. Each test pairs the
// ORDERED shape with its BARE (non-carrier) baseline to show the two agree.

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
/// carrier, one bare — each arm naming its OWN arm-local derived table `d`, so
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

// MARK: - Tests

struct OrderedSetOperationCarrierTests {
  @Test func `a correlated IN over an ordered set op materialises each arm's derived table`()
      throws {
    // GAP-A2: the correlated `IN (…)` subquery is a set operation UNDER an ORDER
    // BY carrier, so its plan is a `.shaped` stack — `if case .setop = plan` was
    // false, so it fell to the whole-query augment, which binds NO arm-local
    // derived alias (a setop collects none), and arm-0's `.scan("x")` faulted
    // `.relation('x')`. It now routes through `execute(_:carrying:)`, per-arm
    // augmenting `x` before the arm scan. Alice (Age 30) matches the arm value.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT V FROM (SELECT 30 AS V) AS x WHERE x.V = p.Age
           UNION SELECT 99 ORDER BY 1)
        """, yields: [[1]])
  }

  @Test func `a bare correlated IN set op materialises each arm's derived table`()
      throws {
    // The non-ordered baseline (a bare `.setop` plan) already worked — the
    // ordered form now matches it EXACTLY.
    try people().expect("""
        SELECT Id FROM People p WHERE p.Age IN
          (SELECT V FROM (SELECT 30 AS V) AS x WHERE x.V = p.Age
           UNION SELECT 99)
        """, yields: [[1]])
  }

  @Test func `an ordered set-op view materialises each arm's derived table`()
      throws {
    // GAP-A3/A4: a view body that is a set operation UNDER an ORDER BY carrier
    // compiles to a `.shaped` plan, so BOTH the view execute (`derive`) and the
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
    // yields the same MULTISET as the ordered form, but UNSORTED — the two arms
    // in source order: the derived `d` arm ({7, 8}) then the `S` arm ({7, 8}).
    try views().expect("SELECT * FROM bare", yields: [[7], [8], [7], [8]])
  }

  @Test func `a reached correlated scalar ordered set op faults on irreconcilable arms`()
      throws {
    // GAP-A1: a REACHED correlated scalar subquery over an ordered set operation
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
    try people().expect("SELECT Id FROM People WHERE Age = (SELECT 'a' UNION SELECT 1 ORDER BY 1)",
                        fails: .operand("UNION arms have irreconcilable types"))
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
}
