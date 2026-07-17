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

/// Whether `plan` (or any descendant) carries an `.outer` node — the witness an
/// OUTER APPLY (`.left`) decorrelated to a LEFT `.outer` join.
private func outers(_ plan: Plan) -> Bool {
  switch plan {
  case .outer:
    return true
  case let .derived(_, source, _, _):
    return outers(source)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return outers(source)
  case let .product(left, right), let .setop(_, left, right, _):
    return outers(left) || outers(right)
  case .single, .scan, .join, .apply:
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
    let parsed = try parse(query: sql)
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
    let rows = try fixture().run(parse(query:
        "SELECT T.Id FROM T " +
        "JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id"), .standard)
    // Id 1 twice (two children), Id 2 once — NO dedup, NO Id 3.
    #expect(rows == [[.integer(1)], [.integer(1)], [.integer(2)]])
  }

  /// NO MATCH: Id 3 has no child, so the INNER join DROPS it — never NULL-
  /// extended, exactly as CROSS APPLY drops an unmatched left row.
  @Test func `a left row with no match is dropped`() throws {
    let rows = try fixture().run(parse(query:
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
    let rows = try catalog.run(parse(query: sql), .standard)
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

// MARK: - Decorrelatable OUTER APPLY (`.left`): result-equivalence + plan shape

/// Behaviour-preserving oracles for the OUTER APPLY (`LEFT JOIN LATERAL`) →
/// LEFT `.outer` join decorrelation. An OUTER APPLY NULL-extends an unmatched
/// left row (ONCE) and multiplies a matched one by its match count — the SAME
/// multiset the correlated `applied` (`.left`) executor produces. Each case
/// compares the run against that known-correct multiset and pins the plan
/// shape: a decorrelatable OUTER APPLY becomes an `.outer` with NO `.apply`
/// node.
struct DecorrelateOuterApplyTests {
  /// NULL-EXTENSION: Id 3 has no child, so the OUTER apply PRESERVES it
  /// NULL-extended — Id 1 → {100, 101}, Id 2 → {200}, Id 3 → (3, NULL) — the
  /// exact multiset the correlated `.left` `applied` yields, unlike the CROSS
  /// APPLY that would drop Id 3.
  @Test func `an OUTER APPLY NULL-extends an unmatched left row`() throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, 200], [3, nil]])
  }

  /// MULTIPLICITY: Id 1 matches two inner rows and appears TWICE (matched, NOT
  /// NULL-extended); it is not deduped — the LEFT join multiplies a matched
  /// left row by its match count exactly as the per-row run does.
  @Test func `a matched OUTER APPLY left row is multiplied not deduped`()
      throws {
    let rows = try fixture().run(parse(query:
        "SELECT T.Id FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id"), .standard)
    // Id 1 twice (two children, matched — no NULL row), Id 2 once, Id 3 once
    // (NULL-extended). The left row is preserved, matched rows not deduped.
    #expect(rows == [[.integer(1)], [.integer(1)], [.integer(2)],
                     [.integer(3)]])
  }

  /// NULL CORRELATION KEY: a NULL outer `Id` matches nothing (NULL ≠ NULL), so
  /// the OUTER apply NULL-extends it — Id 1 → 100, the NULL-Id row → NULL. The
  /// inner NULL-keyed `(NULL, 999)` never pairs. Identical to the per-row
  /// `WHERE S.k = :outer` NULL-drop then NULL-extension.
  @Test func `a NULL correlation key NULL-extends the left row`() throws {
    try nullFixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY d.x",
        yields: [[nil, nil], [1, 100]])
  }

  /// The apply's `ON` (safe) still governs matching: `ON d.x > 100` rejects Id
  /// 1's child 100 and Id 2's child 200 stays (`200 > 100`), so Id 1 keeps only
  /// 101, Id 2 keeps 200, and Id 3 (no child) NULL-extends — every left row
  /// preserved, exactly as the correlated OUTER apply's per-pair `ON`.
  @Test func `a safe apply ON governs the decorrelated match`() throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d " +
        "ON d.x > 100 ORDER BY T.Id, d.x",
        yields: [[1, 101], [2, 200], [3, nil]])
  }

  /// The apply `ON` rejects EVERY pair: `ON d.x > 1000` matches no child, so
  /// EACH left row — even Ids 1 and 2 with children — is NULL-extended, just as
  /// Id 3 is. The correlated OUTER apply preserves every left row; the
  /// decorrelated LEFT join must too.
  @Test func `an ON rejecting every pair NULL-extends every left row`()
      throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d " +
        "ON d.x > 1000 ORDER BY T.Id",
        yields: [[1, nil], [2, nil], [3, nil]])
  }

  /// A safe local body predicate `p_R` (`S.x < 200`) folds into the LEFT join's
  /// `on`: Id 1 keeps both children, Id 2 loses its only child (200) and
  /// NULL-extends, Id 3 NULL-extends — the multiset the per-row run produces.
  @Test func `a safe local body predicate folds into the outer join`() throws {
    try fixture().expect(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.x < 200) " +
        "AS d ON 1 = 1 ORDER BY T.Id, d.x",
        yields: [[1, 100], [1, 101], [2, nil], [3, nil]])
  }

  /// PLAN SHAPE: the decorrelatable OUTER APPLY optimises to an `.outer` join
  /// with NO surviving `.apply` node — the pass fired.
  @Test func `a decorrelatable OUTER APPLY optimises to an outer join`()
      throws {
    let plan = try fixture().optimised(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1")
    #expect(!applies(plan))
    #expect(outers(plan))
  }

  /// PLAN SHAPE: a safe residual `ON` and a local body predicate still
  /// decorrelate — no `.apply` node survives, an `.outer` node appears.
  @Test func `an OUTER APPLY with safe ON and body predicate decorrelates`()
      throws {
    let plan = try fixture().optimised(
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id AND S.x < 200) " +
        "AS d ON d.x > 50")
    #expect(!applies(plan))
    #expect(outers(plan))
  }
}

// MARK: - OUTER APPLY excluded bodies: STAY correlated, run correctly

/// The `.left`-specific exclusions plus the shared G3 ones. The load-bearing
/// one is the UNSAFE apply `ON`: a LEFT join cannot split its `on`, so folding
/// an unsafe `on` beside a nullable body residual would throw for a pair the
/// correlated body WHERE dropped — so an unsafe `on` LEAVES the apply
/// correlated (the safe-gate), running identically to the base.
struct DecorrelateOuterApplyExclusionTests {
  /// UNSAFE APPLY `ON` (the safe-gate, `.left`-specific): a body residual
  /// `S.k = T.Id` can be UNKNOWN for a non-matching inner row, and the apply
  /// `ON (1 /
  /// d.x) = 0` divides by a child's `x`. `S` has a child `(2, 0)`, so `1 / d.x`
  /// divides by zero for Id 2's matched child. The correlated OUTER apply
  /// evaluates the body WHERE FIRST and reaches the `ON` only for a surviving
  /// pair, so it DOES throw for Id 2's matched (2, 0). Folding into one LEFT-
  /// join `on` would ALSO throw — but the recogniser cannot prove throw-
  /// equivalence
  /// for an unsafe `on`, so it LEAVES the apply correlated and the run throws
  /// `.divide` exactly as the base.
  @Test func `an unsafe apply ON stays correlated and throws identically`()
      throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
        Row(2, 0)          // 1 / 0 → divide by zero for Id 2's matched child
      }
    }
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d " +
        "ON (1 / d.x) = 0"
    #expect(applies(try catalog.optimised(sql)))   // NOT decorrelated
    catalog.expect(sql, fails: .divide)
  }

  /// NON-EQUI correlation: `S.k > T.Id` has no equi-key to hash on, so the
  /// OUTER apply stays correlated — and runs correctly with NULL-extension. Id
  /// 1 → k > 1 → child (2, 200) → 200; Id 2 → k > 2 → none → NULL; Id 3 → none
  /// → NULL.
  @Test func `a non-equi correlation stays an apply and NULL-extends`()
      throws {
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k > T.Id) AS d ON 1 = 1"
    #expect(applies(try fixture().optimised(sql)))   // NOT decorrelated
    try fixture().expect(sql + " ORDER BY T.Id, d.x",
                         yields: [[1, 200], [2, nil], [3, nil]])
  }

  /// BODY-LOCAL DERIVED table: the body reads its OWN derived `e` (over `S`), a
  /// per-execution materialised alias the set-based rewrite cannot relay. The
  /// OUTER apply stays correlated and NULL-extends Id 3 — the derived `e` reads
  /// `S` (100, 101, 200), never a same-named base relation.
  @Test func `a body-local derived table stays an apply and NULL-extends`()
      throws {
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM (SELECT k, x FROM S) AS e " +
        "WHERE e.k = T.Id) AS d ON 1 = 1"
    #expect(applies(try fixture().optimised(sql)))   // NOT decorrelated
    try fixture().expect(sql + " ORDER BY T.Id, d.x",
                         yields: [[1, 100], [1, 101], [2, 200], [3, nil]])
  }

  /// AGGREGATE body: a `COUNT(*)` body is not a plain filter+project, so the
  /// OUTER apply stays correlated — and runs correctly. Every left row is
  /// preserved (a LEFT apply), each with its child count: Id 1 → 2, Id 2 → 1,
  /// Id 3 → 0 (the aggregate over an empty group yields 0, not NULL).
  @Test func `an aggregate body stays an apply and runs correctly`() throws {
    let sql =
        "SELECT T.Id, d.n FROM T LEFT JOIN LATERAL " +
        "(SELECT COUNT(*) AS n FROM S WHERE S.k = T.Id) AS d ON 1 = 1"
    #expect(applies(try fixture().optimised(sql)))   // NOT decorrelated
    try fixture().expect(sql + " ORDER BY T.Id",
                         yields: [[1, 2], [2, 1], [3, 0]])
  }
}

// MARK: - OUTER APPLY adversarial throw-visibility (G4, safe-gate)

struct DecorrelateOuterApplyThrowTests {
  /// ADVERSARIAL (soundness): an OUTER APPLY whose body WHERE divides by zero
  /// for an inner row NO left row pairs with. `S`'s divide-by-zero row `(1,
  /// 100)` is keyed to the ABSENT Id 1, and the body WHERE carries the UNSAFE
  /// term `1 / (S.x - 100) > 0`. The per-row correlated run never binds `:outer
  /// = 1`, so it never reaches that inner row — yielding Id 2 (matched (2,
  /// 200): `1 / 100 = 0`, so `> 0` false ⇒ no match ⇒ NULL-extended) and Id 3
  /// (no
  /// child ⇒ NULL), with NO throw. A set-based join over the whole `S` WOULD
  /// evaluate the divide on `(1, 100)` and throw. The recogniser LEAVES it
  /// correlated (the body term is unsafe), so the run NULL-extends both left
  /// rows with no spurious throw — the base behaviour.
  @Test func `an unreachable throwing inner row is not decorrelated`() throws {
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
        "LEFT JOIN LATERAL " +
        "(SELECT x FROM S WHERE S.k = T.Id AND 1 / (S.x - 100) > 0) AS d " +
        "ON 1 = 1"
    #expect(applies(try catalog.optimised(sql)))   // NOT decorrelated
    // Id 2: child (2, 200) → 1 / 100 = 0 → `> 0` false ⇒ no match ⇒ NULL. Id 3:
    // no child ⇒ NULL. The divide on the Id-1 child is never reached ⇒ no
    // throw.
    let rows = try catalog.run(parse(query: sql + " ORDER BY T.Id"), .standard)
    #expect(rows == [[.integer(2), .null], [.integer(3), .null]])
  }
}

// MARK: - Decorrelated OUTER APPLY as an outer join's NULL-extended left side

/// A decorrelated OUTER APPLY tops out in a `.project` (over an `.outer`) that
/// restores the apply's output geometry. As the LEFT of a further RIGHT/FULL
/// join, `Plan.slots` must measure that project's width so an unmatched right
/// row NULL-extends across the FULL left width — the same `Plan.slots`
/// exhaustiveness the CROSS APPLY case relies on.
struct DecorrelateOuterApplyWidthTests {
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

  /// RIGHT JOIN forcing left NULL-extension over a decorrelated OUTER APPLY.
  /// The lateral yields the `T ++ d` rows including Id 3's NULL-extended row,
  /// but
  /// `RIGHT JOIN U ON 1 = 0` matches none, so every `U` row survives with the
  /// WHOLE `T ++ d` left width NULL — `U.u` at ordinal 2, `T.Id`/`d.x` NULL.
  @Test func `a decorrelated OUTER APPLY as a RIGHT join left NULL-extends`()
      throws {
    let sql =
        "SELECT T.Id, d.x, U.u FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "RIGHT JOIN U ON 1 = 0"
    let plan = try widthFixture().optimised(sql)
    #expect(!applies(plan))
    #expect(outers(plan))
    try widthFixture().expect(sql + " ORDER BY U.u",
                              yields: [[nil, nil, 700], [nil, nil, 701]])
  }
}

// MARK: - OUTER APPLY hash fast-path equivalence

/// The `.outer` executor's hash fast-path must be behaviour-identical to the
/// nested loop it replaces — same rows, same NULL-extension. A larger-ish
/// OUTER APPLY (enough keys that the hash and nested-loop paths could diverge
/// on bucketing or order) is compared against the KNOWN-CORRECT multiset the
/// correlated OUTER apply produces.
struct DecorrelateOuterApplyHashTests {
  /// A wider parent/child so the right side hashes into several buckets. Ids
  /// 1..5 each key children; Id 4 has none (NULL-extended), Id 5 has two. The
  /// decorrelated LEFT join's hash fast-path must yield the same multiset the
  /// correlated OUTER apply does: each matched left row multiplied, each
  /// unmatched one NULL-extended once.
  @Test func `the hash fast-path yields the correlated OUTER APPLY multiset`()
      throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
        Row(4)
        Row(5)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 10)
        Row(2, 20)
        Row(3, 30)
        Row(5, 50)
        Row(5, 51)          // Id 5 has two children (multiplied)
      }
    }
    let sql =
        "SELECT T.Id, d.x FROM T " +
        "LEFT JOIN LATERAL (SELECT x FROM S WHERE S.k = T.Id) AS d ON 1 = 1 " +
        "ORDER BY T.Id, d.x"
    // The hash path fired (an `.outer`, no `.apply`).
    #expect(!applies(try catalog.optimised(sql)))
    #expect(outers(try catalog.optimised(sql)))
    try catalog.expect(sql, yields: [[1, 10], [2, 20], [3, 30], [4, nil],
                                     [5, 50], [5, 51]])
  }
}

// MARK: - OUTER join throw-visibility (fast-path safe-gate)

/// An UNSAFE outer-join `on` — a straddling equi `A.k = B.k` AND a throwing
/// conjunct like `(1 / B.x) = 0` — must FAULT on a pair the throwing term hits,
/// never silently NULL-extend the left row. The nested-loop `.outer` executor
/// evaluates `on` for EVERY (left, right) pair (this evaluator does NOT
/// short-circuit `AND`: a `false`/UNKNOWN key term still evaluates a throwing
/// residual), so a non-matching or NULL-key pair whose `(1 / B.x)` divides by
/// zero raises `.divide`. The `.outer` hash fast-path would SKIP such a pair
/// (it probes `on` for a left row's matching-key bucket alone) and thus
/// SUPPRESS the throw — so a `.match`-carrying `on` must never reach the fast
/// path unless the WHOLE `on` is `safe`. TWO layers enforce this: (1) the
/// `on()` recogniser (`Resolve.swift`) refuses to form ANY `.match` when the ON
/// is not `allSatisfy(\.safe)` — so an unsafe user `A.k = B.k` stays a plain
/// `.compare`, `equikey` finds no key, and the nested loop runs; (2) the
/// executor's own `on.safe` gate on the fast path (this PR), defence-in-depth
/// against a future `.match` producer that skips the recogniser's invariant.
/// These end-to-end oracles PIN the observable invariant across both layers on
/// a PLAIN LEFT/FULL JOIN (no APPLY).
struct OuterJoinSafeGateTests {
  /// A non-matching right row (`B.k = 2 ≠ 1`, `B.x = 0`) makes the throwing
  /// conjunct `(1 / B.x) = 0` fault under the nested loop, which evaluates it
  /// for that pair. The unsafe `on` never forms a `.match`, so the nested loop
  /// runs and raises `.divide` — never NULL-extending `A`.
  @Test func `an unsafe LEFT JOIN on faults on a non-matching pair`() throws {
    let catalog = try Catalog {
      Relation("A", ["k": .integer]) {
        Row(1)
      }
      Relation("B", ["k": .integer, "x": .integer]) {
        Row(2, 0)           // non-matching key (2 ≠ 1), x = 0 ⇒ 1 / 0 faults
      }
    }
    catalog.expect(
        "SELECT A.k FROM A LEFT JOIN B ON (1 / B.x) = 0 AND A.k = B.k",
        fails: .divide)
  }

  /// A NULL-key right row (`B.k` NULL, `B.x = 0`) would be skipped by the fast
  /// path (a NULL key buckets/probes nothing), but the nested loop the unsafe
  /// `on` takes evaluates its throwing conjunct. It must raise `.divide`, not
  /// NULL-extend `A`.
  @Test func `an unsafe LEFT JOIN on faults on a NULL-key pair`() throws {
    let catalog = try Catalog {
      Relation("A", ["k": .integer]) {
        Row(1)
      }
      Relation("B", ["k": .integer, "x": .integer]) {
        Row(nil, 0)         // NULL key a fast path would skip; x = 0 ⇒ 1 / 0
      }
    }
    catalog.expect(
        "SELECT A.k FROM A LEFT JOIN B ON (1 / B.x) = 0 AND A.k = B.k",
        fails: .divide)
  }

  /// A FULL join shares the same left-major fast path, so its unsafe `on` must
  /// fault identically — the recogniser forms no `.match`, the nested loop
  /// evaluates the non-matching pair, and it raises `.divide`.
  @Test func `an unsafe FULL JOIN on faults on a non-matching pair`() throws {
    let catalog = try Catalog {
      Relation("A", ["k": .integer]) {
        Row(1)
      }
      Relation("B", ["k": .integer, "x": .integer]) {
        Row(2, 0)           // non-matching key, x = 0 ⇒ 1 / 0 faults
      }
    }
    catalog.expect(
        "SELECT A.k FROM A FULL JOIN B ON (1 / B.x) = 0 AND A.k = B.k",
        fails: .divide)
  }

  /// CONTROL: a SAFE equi LEFT JOIN still takes the fast path and returns the
  /// correct rows — a matched left row (multiplied by its match count), an
  /// unmatched one NULL-extended, and a NULL-key left row NULL-extended. An
  /// added SAFE residual (`B.flag = 1`) keeps `on` safe and still filters.
  @Test func `a safe equi LEFT JOIN with a residual returns correct rows`()
      throws {
    let catalog = try Catalog {
      Relation("A", ["k": .integer]) {
        Row(1)              // matches two B rows, one of which fails B.flag = 1
        Row(2)              // matches no live B row ⇒ NULL-extended
        Row(nil)            // NULL key ⇒ NULL-extended
      }
      Relation("B", ["k": .integer, "flag": .integer]) {
        Row(1, 1)           // A.k = 1 kept (flag = 1)
        Row(1, 0)           // A.k = 1 dropped (flag ≠ 1)
        Row(2, 0)           // A.k = 2 dropped (flag ≠ 1) ⇒ 2 NULL-extends
      }
    }
    try catalog.expect(
        "SELECT A.k, B.flag FROM A " +
        "LEFT JOIN B ON A.k = B.k AND B.flag = 1 " +
        "ORDER BY A.k",
        yields: [[nil, nil], [1, 1], [2, nil]])
  }
}
