// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

/// Behaviour-preserving oracles for the CROSS APPLY → inner-join decorrelation
/// pass. A decorrelation bug is a SILENT wrong-results bug, so every case
/// compares the run result against the KNOWN-CORRECT multiset the correlated
/// `applied` executor produces — same rows, same duplicates, same drops — and
/// pins the plan shape: a decorrelatable CROSS APPLY becomes a `.join` with NO
/// `.apply` node, and an EXCLUDED body stays an `.apply`, run correctly.

/// Parses `text` to a query, failing on any other statement.
private func query(_ text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

/// Whether `plan` (or any descendant) carries a correlated `.apply` node — the
/// witness a shape was NOT decorrelated.
private func applies(_ plan: Plan) -> Bool {
  switch plan {
  case .apply:
    return true
  case let .derived(_, source, _, _):
    return applies(source)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return applies(source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .setop(_, left, right, _):
    return applies(left) || applies(right)
  case .single, .scan, .join:
    return false
  }
}

/// Whether `plan` (or any descendant) carries a `.join` node — the witness the
/// decorrelated product folded to a hash equi-join.
private func joins(_ plan: Plan) -> Bool {
  switch plan {
  case .join:
    return true
  case let .derived(_, source, _, _):
    return joins(source)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return joins(source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .setop(_, left, right, _):
    return joins(left) || joins(right)
  case .single, .scan, .apply:
    return false
  }
}

extension Catalog where Self: ~Escapable {
  /// The optimised plan for `sql`, threading a shared subquery box through the
  /// SAME compile → pushdown → decorrelate → optimise pipeline `run` uses, so a
  /// plan-shape assertion sees the very plan the executor runs. The overlay is
  /// recorded and this query's derived tables are materialised exactly as `run`
  /// does, so a correlated body's plan is compiled into the box the decorrelate
  /// pass reads.
  fileprivate borrowing func optimised(_ sql: String) throws -> Plan {
    let parsed = try query(sql)
    let context = Context().resolving(Subqueries())
    let logical = try compile(parsed, context.validating(false)).pushdown()
    let augmented = try augment(context.validating(false), for: parsed,
                                rows: true)
    augmented.subqueries.record(overlay: augmented.revealed().relations,
                                for: .caller)
    return try optimise(decorrelate(logical, augmented), augmented)
  }
}

/// A parent `T` and a child `S` keyed on `T.Id` — Id 1 has TWO children, Id 2
/// one, Id 3 none — the duplicate-match and no-match shapes a CROSS APPLY
/// multiplies and drops.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    Relation("S", ["k": .integer, "x": .integer]) {
      Row(1, 100)
      Row(1, 101)
      Row(2, 200)
    }
  }
}

/// A `T` with a NULL-keyed child in `S` — a NULL correlation key equi-joins to
/// nothing, exactly as the per-row `WHERE S.k = :outer` (`:outer` NULL ⇒
/// UNKNOWN) admits nothing.
private func nullFixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(nil)            // a NULL outer key
    }
    Relation("S", ["k": .integer, "x": .integer]) {
      Row(1, 100)
      Row(nil, 999)       // a NULL inner key — never equi-matches
    }
  }
}

// MARK: - Decorrelatable CROSS APPLY: result-equivalence + plan shape

struct DecorrelateCrossApplyTests {
  /// The canonical CROSS APPLY: a left row is multiplied by its match count and
  /// an unmatched left row is dropped — the SAME multiset the correlated
  /// `applied` produces (Id 1 → {100, 101}, Id 2 → {200}, Id 3 → dropped).
  @Test func `a CROSS APPLY equi body yields the correlated multiset`() throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200]])
  }

  /// DUPLICATE MATCHES: Id 1 matches two inner rows and appears TWICE — the
  /// join multiplies the left row by the match count, it is NOT deduped.
  @Test func `a left row matching many inner rows is multiplied not deduped`()
      throws {
    let rows = try fixture().run(query(
        "SELECT T.Id FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id"), .standard)
    // Id 1 twice (two children), Id 2 once — NO dedup, NO Id 3.
    #expect(rows == [[.integer(1)], [.integer(1)], [.integer(2)]])
  }

  /// NO MATCH: Id 3 has no child, so the INNER join DROPS it — never NULL-
  /// extended, exactly as CROSS APPLY drops an unmatched left row.
  @Test func `a left row with no match is dropped`() throws {
    let rows = try fixture().run(query(
        "SELECT T.Id FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1"),
        .standard)
    #expect(!rows.contains([.integer(3)]))
  }

  /// A NULL correlation key matches nothing (NULL ≠ NULL) — the left row with a
  /// NULL `Id` is dropped, and the inner NULL-keyed row `(NULL, 999)` never
  /// pairs — identical to the per-row `WHERE S.k = :outer` NULL-drop.
  @Test func `a NULL correlation key drops the left row`() throws {
    try nullFixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id",
        yields: [[1, 100]])
  }

  /// The apply's `ON` further filters the merged pair — the residual rides the
  /// combined-space `.select` over the join, so only children with `x > 100`
  /// survive (Id 1 keeps 101, Id 2 keeps 200), exactly as `applied`'s per-pair
  /// `ON` admits.
  @Test func `the apply ON filters the decorrelated pair`() throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON d.x > 100 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 101], [2, 200]])
  }

  /// A safe local residual `p_R` in the body WHERE (`S.x < 200`) rides the join
  /// alongside the correlation key — Id 1 keeps both children, Id 2 loses 200.
  @Test func `a safe local body predicate rides the decorrelated join`()
      throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.x < 200) AS d " +
        "ON 1 = 1 ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101]])
  }

  /// PLAN SHAPE: the decorrelatable CROSS APPLY optimises to a `.join` with NO
  /// `.apply` node remaining — the pass fired.
  @Test func `a decorrelatable CROSS APPLY optimises to a join`() throws {
    let plan = try fixture().optimised(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1")
    #expect(!applies(plan))
    #expect(joins(plan))
  }

  /// PLAN SHAPE: a residual `ON` and a local body predicate still decorrelate —
  /// no `.apply` node survives.
  @Test func `a CROSS APPLY with ON and body predicate decorrelates`() throws {
    let plan = try fixture().optimised(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.x < 200) AS d " +
        "ON d.x > 50")
    #expect(!applies(plan))
    #expect(joins(plan))
  }
}

// MARK: - Excluded bodies: STAY correlated, run correctly

struct DecorrelateExclusionTests {
  /// (a) AGGREGATE body: a `COUNT(*)` body is not a plain filter+project, so it
  /// stays an `.apply` — and still runs correctly (Id 1 → 2, Id 2 → 1, Id 3 → 0
  /// dropped by the `ON d.n > 0`).
  @Test func `an aggregate body stays an apply and runs correctly`() throws {
    let sql =
        "SELECT T.Id, d.n FROM T " +
        "JOIN LATERAL (SELECT COUNT(*) AS n FROM S WHERE S.k = T.Id) AS d " +
        "ON d.n > 0"
    let plan = try fixture().optimised(sql)
    #expect(applies(plan))                     // NOT decorrelated
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1, 2], [2, 1]])
  }

  /// (b) NON-EQUI correlation: `S.k > T.Id` has no equi-key to hash on, so it
  /// stays an `.apply` — and runs correctly (Id 1 matches k∈{2}? no; the child
  /// keys are 1,1,2, so `S.k > T.Id` for Id 1 → k=2 → x=200; Id 2 → none).
  @Test func `a non-equi correlation stays an apply and runs correctly`()
      throws {
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k > T.Id) AS d ON 1 = 1"
    let plan = try fixture().optimised(sql)
    #expect(applies(plan))                     // NOT decorrelated
    // Id 1: children with k > 1 → k=2 → x=200. Id 2: k > 2 → none. Id 3: none.
    try fixture().expect(sql + " ORDER BY T.Id, d.x", yields: [[1, 200]])
  }

  /// (c) THROWING body term (G4): a body WHERE conjunct `1 / (S.x - 100) > 0`
  /// divides by zero on the inner row `(1, 100)`. Under the per-row correlated
  /// run the divide fires only for a left row that reaches that inner row; a
  /// set-based join over the whole `S` would evaluate it for every inner row.
  /// The recogniser LEAVES it correlated (the conjunct is unsafe), and the run
  /// still raises `.divide` exactly as the correlated path does.
  @Test func `a throwing body term stays an apply and still throws`() throws {
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL " +
        "(SELECT x FROM S WHERE S.k = T.Id AND 1 / (S.x - 100) > 0) AS d " +
        "ON 1 = 1"
    let plan = try fixture().optimised(sql)
    #expect(applies(plan))                     // NOT decorrelated (unsafe body)
    // The correlated run reaches the divide (Id 1's child x=100) and raises.
    try fixture().expect(sql, fails: .divide)
  }
}

// MARK: - Body-local derived aliases: STAY correlated (item 1)

struct DecorrelateBodyDerivedTests {
  /// A parent `T` and a child `S`, PLUS a BASE table also named `e` carrying
  /// unrelated rows — so a rewrite that wrongly relaid a caller-level
  /// `scan("e")` would bind THIS base `e` and return its rows rather than the
  /// body's own derived `e`.
  private func shadowFixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
        Row(1, 101)
        Row(2, 200)
      }
      // A BASE relation named `e` whose rows must NEVER surface — the body's
      // own derived `e` shadows it. A decorrelation that relaid `scan("e")` at
      // the caller would bind these instead.
      Relation("e", ["k": .integer, "x": .integer]) {
        Row(1, 900)
        Row(2, 901)
      }
    }
  }

  /// A lateral body reading its OWN derived table `e` must NOT decorrelate: the
  /// compiled body plan scans the body-local alias `e`, which the correlated
  /// `applied` materialises per execution. Relaid as a caller-level `scan("e")`
  /// the rewrite would fault or bind an outer relation. The recogniser leaves
  /// it correlated.
  @Test func `a body-local derived alias stays an apply`() throws {
    let plan = try shadowFixture().optimised(
        "SELECT d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM (SELECT k, x FROM S) AS e " +
        "WHERE e.k = T.Id) AS d ON 1 = 1")
    #expect(applies(plan))                       // NOT decorrelated
  }

  /// The same body run: the derived `e` reads `S` (100, 101, 200), NOT the
  /// BASE `e` (900, 901). Id 1 → {100, 101}, Id 2 → {200}, Id 3 → dropped —
  /// identical to the correlated multiset.
  @Test func `a body-local derived alias runs correctly`() throws {
    try shadowFixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM (SELECT k, x FROM S) AS e " +
        "WHERE e.k = T.Id) AS d ON 1 = 1 ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200]])
  }
}

// MARK: - APPLY ON behind a nullable body filter (item 2)

struct DecorrelateOnOrderTests {
  /// A parent `T` and a child `S` whose `flag` is NULL for one child. The body
  /// `WHERE S.k = T.Id AND S.flag = 1` drops the NULL-flag row (UNKNOWN
  /// rejects) BEFORE any `ON` is evaluated, so an unsafe `ON` over that dropped
  /// row must never fire.
  private func flagFixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("S", ["k": .integer, "x": .integer, "flag": .integer]) {
        Row(1, 0, nil)      // flag NULL — dropped by body WHERE, x = 0 unsafe
        Row(2, 200, 1)      // flag 1 — survives the body WHERE
      }
    }
  }

  /// THROW ORDER: the body WHERE drops the NULL-flag child (x = 0) before the
  /// unsafe `ON (1 / d.x) = 0` is ever reached, so the correlated APPLY does
  /// NOT throw. The decorrelated plan keeps the `ON` in a SEPARATE select ABOVE
  /// the body-filtered join, so `ON` sees only survivors — Id 2's child x = 200
  /// — and likewise does NOT divide by the dropped x = 0 row. The result is Id
  /// 2's child (integer `1 / 200 = 0`, so the ON admits it), NOT a `.divide`.
  @Test func `a nullable body filter drops a row before the unsafe ON`()
      throws {
    // The NULL-flag child (x = 0) is dropped by the body WHERE, so the unsafe
    // ON never divides by it. Id 2's surviving child x = 200 is admitted by the
    // ON (`1 / 200 = 0`), so the result is [[2, 200]] — and, crucially, NO
    // throw, matching the correlated APPLY.
    try flagFixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.flag = 1) AS d " +
        "ON (1 / d.x) = 0 ORDER BY T.Id",
        yields: [[2, 200]])
  }

  /// The ON still applies to a SURVIVING row: with a safe `ON d.x > 100` the
  /// body WHERE keeps Id 2's child (x = 200, flag 1), and the ON admits it —
  /// proving the split select did not drop the ON, only reorder it.
  @Test func `the ON still filters a surviving row after the split`() throws {
    try flagFixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.flag = 1) AS d " +
        "ON d.x > 100 ORDER BY T.Id",
        yields: [[2, 200]])
  }

  /// The ON legitimately DROPS a surviving row: with `ON d.x > 500` Id 2's
  /// surviving child (x = 200) fails the ON, so the result is empty — the ON
  /// filters survivors exactly as the correlated per-pair ON does.
  @Test func `the ON drops a surviving row it rejects`() throws {
    try flagFixture().empty(
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.flag = 1) AS d " +
        "ON d.x > 500")
  }
}

// MARK: - Adversarial throw-visibility (G4)

struct DecorrelateThrowVisibilityTests {
  /// ADVERSARIAL (soundness): a CROSS APPLY whose body WHERE divides by zero
  /// for an inner row NO surviving left row pairs with. The child `(1, 100)`
  /// makes
  /// `1 / (S.x - 100)` divide by zero, but NO left row has `Id = 1` — so the
  /// per-row correlated run never binds `:outer = 1` and never reaches that
  /// inner row, yielding NO rows and NO throw. A naive decorrelation to a join
  /// over the whole `S` WOULD evaluate the divide on `(1, 100)` and throw
  /// spuriously. The recogniser must LEAVE it correlated (the conjunct is
  /// unsafe), so the result stays empty with no throw — identical to the base
  /// correlated behaviour.
  @Test func `an unreachable throwing inner row is not decorrelated`() throws {
    // T has only Id 2 and 3; S's only divide-by-zero row is keyed to Id 1.
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(2)
        Row(3)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)      // x - 100 = 0 → divide by zero, keyed to absent Id 1
        Row(2, 200)      // safe for Id 2
      }
    }
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "JOIN LATERAL " +
        "(SELECT x FROM S WHERE S.k = T.Id AND 1 / (S.x - 100) > 0) AS d " +
        "ON 1 = 1"
    // The body carries an unsafe term, so it is NOT decorrelated.
    #expect(applies(try catalog.optimised(sql)))
    // Id 2 matches child (2, 200): 1 / (200 - 100) = 0, so `> 0` is false ⇒ no
    // row; Id 3 matches nothing. The divide on the Id-1 child is never reached,
    // so the run yields nothing and does NOT throw — the base behaviour.
    let rows = try catalog.run(query(sql), .standard)
    #expect(rows.isEmpty)
  }
}

// MARK: - Decorrelated APPLY as an outer join's NULL-extended left side

/// A decorrelated CROSS APPLY tops out in a `.project` that restores the
/// apply's output geometry. When that project is the LEFT side of a RIGHT or
/// FULL join, the outer-join executor sizes the left with `Plan.slots` to
/// NULL-extend an unmatched right row across the FULL left width. A `.project`
/// whose width `Plan.slots` swallowed (returning `nil` → the executor's `0`
/// fallback) would NULL-extend with too few left slots, landing the right
/// columns at the wrong ordinals or trapping. These oracles force exactly that
/// NULL-extension and read the T/d slots after the outer join to prove the
/// ordinals are not shifted.
struct DecorrelateOuterJoinWidthTests {
  /// A parent `T`, a child `S` keyed on `T.Id`, and an unrelated `U` — the
  /// third relation an outer join over the decorrelated apply NULL-extends.
  private func widthFixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
        Row(1, 101)
        Row(2, 200)
      }
      Relation("U", ["u": .integer]) {
        Row(700)
        Row(701)
      }
    }
  }

  /// RIGHT JOIN forcing left NULL-extension. The lateral yields the `T ++ d`
  /// rows ([1, 100], [1, 101], [2, 200]), but `RIGHT JOIN U ON 1 = 0` matches
  /// none of them, so every `U` row survives with the WHOLE `T ++ d` left width
  /// NULL. `Plan.slots` must report the project's width (2) so `U.u` lands at
  /// ordinal 2 and `T.Id`/`d.x` are NULL — not shifted into the U slot or
  /// trapped.
  @Test func `a decorrelated apply as a RIGHT join's left NULL-extends fully`()
      throws {
    // The plan decorrelates (a `.join`, no surviving `.apply`) and its project
    // is the RIGHT join's left side — the very shape whose width `Plan.slots`
    // must measure.
    let plan = try widthFixture().optimised(
        "SELECT T.Id, d.x, U.u FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "RIGHT JOIN U ON 1 = 0")
    #expect(!applies(plan))
    #expect(joins(plan))
    // Every U row is NULL-extended across the full T ++ d left width: U.u at
    // ordinal 2, T.Id and d.x NULL. The known-correct multiset a correlated run
    // would produce — the RIGHT join drops the unmatched lateral rows and keeps
    // each U row once, left NULL.
    try widthFixture().expect(
        "SELECT T.Id, d.x, U.u FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "RIGHT JOIN U ON 1 = 0 ORDER BY U.u",
        yields: [[nil, nil, 700], [nil, nil, 701]])
  }

  /// FULL JOIN forcing BOTH sides' unmatched rows through. `ON 1 = 0` matches
  /// nothing, so the FULL join emits every lateral `T ++ d` row right-NULL then
  /// every `U` row left-NULL — the left-NULL rows again needing the full T ++ d
  /// width so `U.u` lands at ordinal 2. Reads T.Id/d.x/U.u to pin the ordinals.
  @Test func `a decorrelated apply as a FULL join's left NULL-extends fully`()
      throws {
    let plan = try widthFixture().optimised(
        "SELECT T.Id, d.x, U.u FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "FULL JOIN U ON 1 = 0")
    #expect(!applies(plan))
    #expect(joins(plan))
    // Left-major: the three lateral rows (U.u NULL), then the two U rows (T.Id,
    // d.x NULL). The U columns land at ordinal 2 throughout — no shift.
    try widthFixture().expect(
        "SELECT T.Id, d.x, U.u FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "FULL JOIN U ON 1 = 0 ORDER BY T.Id, d.x, U.u",
        yields: [[nil, nil, 700], [nil, nil, 701],
                 [1, 100, nil], [1, 101, nil], [2, 200, nil]])
  }
}
