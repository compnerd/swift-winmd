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
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return applies(left) || applies(right)
  case .single, .empty, .scan, .join:
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
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return joins(left) || joins(right)
  case .single, .empty, .scan, .apply:
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
  case let .product(left, right), let .semijoin(left, right, _, _),
       let .setop(_, left, right, _, _, _):
    return outers(left) || outers(right)
  case .single, .empty, .scan, .join, .apply:
    return false
  }
}

/// Whether `plan` (or a descendant) carries a `.semijoin` node — the witness a
/// correlated `EXISTS`/`NOT EXISTS` conjunct decorrelated. `anti` distinguishes
/// the two senses: a plain `EXISTS` yields `anti == false`, a `NOT EXISTS`
/// `anti == true`.
private func semijoins(_ plan: Plan) -> Bool {
  switch plan {
  case .semijoin:
    return true
  case let .derived(_, source, _, _):
    return semijoins(source)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return semijoins(source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .setop(_, left, right, _, _, _):
    return semijoins(left) || semijoins(right)
  case .single, .empty, .scan, .join, .apply:
    return false
  }
}

/// Whether `plan` (or any descendant) carries a `.semijoin` node of the given
/// `anti` sense — a SEMIJOIN (`anti == false`) or ANTI-join (`anti == true`).
private func semijoins(_ plan: Plan, anti wanted: Bool) -> Bool {
  switch plan {
  case let .semijoin(_, _, _, anti):
    return anti == wanted
  case let .derived(_, source, _, _):
    return semijoins(source, anti: wanted)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return semijoins(source, anti: wanted)
  case let .product(left, right), let .outer(left, right, _, _),
       let .setop(_, left, right, _, _, _):
    return semijoins(left, anti: wanted) || semijoins(right, anti: wanted)
  case .single, .empty, .scan, .join, .apply:
    return false
  }
}

/// The number of `.semijoin` nodes `plan` (and its descendants) carries — the
/// count of EXISTS conjuncts lifted into the stack. Two decorrelatable EXISTS
/// of one WHERE lift into TWO stacked semijoins, so this returns 2.
private func semijoinCount(_ plan: Plan) -> Int {
  switch plan {
  case let .semijoin(left, right, _, _):
    return 1 + semijoinCount(left) + semijoinCount(right)
  case let .derived(_, source, _, _):
    return semijoinCount(source)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return semijoinCount(source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .setop(_, left, right, _, _, _):
    return semijoinCount(left) + semijoinCount(right)
  case .single, .empty, .scan, .join, .apply:
    return 0
  }
}

/// The number of `.semijoin` nodes of the given `anti` sense `plan` (and its
/// descendants) carries. Unlike `semijoins(_:anti:)`, which inspects only the
/// FIRST semijoin it reaches, this descends THROUGH a semijoin's own left, so a
/// stacked SEMI-over-ANTI reports one of each.
private func semijoinCount(_ plan: Plan, anti wanted: Bool) -> Int {
  switch plan {
  case let .semijoin(left, right, _, anti):
    return (anti == wanted ? 1 : 0)
        + semijoinCount(left, anti: wanted)
        + semijoinCount(right, anti: wanted)
  case let .derived(_, source, _, _):
    return semijoinCount(source, anti: wanted)
  case let .select(_, source), let .project(_, source), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return semijoinCount(source, anti: wanted)
  case let .product(left, right), let .outer(left, right, _, _),
       let .setop(_, left, right, _, _, _):
    return semijoinCount(left, anti: wanted)
        + semijoinCount(right, anti: wanted)
  case .single, .empty, .scan, .join, .apply:
    return 0
  }
}

/// Whether `plan` (or any descendant) carries a residual correlated `.exists`
/// conjunct in a `.select`'s filter — the witness an EXISTS was NOT rewritten
/// (it stayed correlated). Scans every conjunct of each `.select` filter, so an
/// EXISTS surviving beside other conjuncts (or nested in an `.or`) is caught.
private func exists(in plan: Plan) -> Bool {
  switch plan {
  case let .select(filter, source):
    return filter.conjuncts.contains { existential($0) } || exists(in: source)
  case let .derived(_, source, _, _), let .project(_, source),
       let .sort(_, source), let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return exists(in: source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return exists(in: left) || exists(in: right)
  case .single, .empty, .scan, .join, .apply:
    return false
  }
}

/// Whether `filter` is (or, through `and`/`or`/`not`, reaches) an `.exists`
/// conjunct — a correlated `EXISTS`/`NOT EXISTS` still lowered as a predicate.
private func existential(_ filter: Filter) -> Bool {
  switch filter {
  case .exists:
    return true
  case let .and(lhs, rhs), let .or(lhs, rhs):
    return existential(lhs) || existential(rhs)
  case let .not(operand):
    return existential(operand)
  default:
    return false
  }
}

/// Whether `plan` (or any descendant) carries a residual `.within` conjunct in
/// a `.select`'s filter — the witness an `IN (Q)` was NOT rewritten (it stayed
/// correlated), the `IN` analogue of `exists(in:)`. Scans every conjunct of
/// each `.select` filter, so an `IN` surviving beside other conjuncts (or
/// nested in an `.or`) is caught.
private func within(in plan: Plan) -> Bool {
  switch plan {
  case let .select(filter, source):
    return filter.conjuncts.contains { membership($0) } || within(in: source)
  case let .derived(_, source, _, _), let .project(_, source),
       let .sort(_, source), let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return within(in: source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return within(in: left) || within(in: right)
  case .single, .empty, .scan, .join, .apply:
    return false
  }
}

/// Whether `filter` is (or, through `and`/`or`/`not`, reaches) a `.within`
/// conjunct — a correlated `IN (Q)`/`NOT IN (Q)` still lowered as a predicate.
private func membership(_ filter: Filter) -> Bool {
  switch filter {
  case .within:
    return true
  case let .and(lhs, rhs), let .or(lhs, rhs):
    return membership(lhs) || membership(rhs)
  case let .not(operand):
    return membership(operand)
  default:
    return false
  }
}

/// Whether `plan` (or any descendant) carries a scalar `.subquery` TERM — the
/// witness a correlated (or uncorrelated) scalar subquery was NOT decorrelated
/// into a LEFT join, the scalar analogue of `exists(in:)`/`within(in:)`. Scans
/// the projection terms of each `.project` and the operand terms every
/// `.select` filter reaches, so a residual scalar surviving in either clause is
/// caught.
private func subquery(in plan: Plan) -> Bool {
  switch plan {
  case let .project(terms, source):
    return terms.contains { subquery($0) } || subquery(in: source)
  case let .select(filter, source):
    return subquery(filter) || subquery(in: source)
  case let .derived(_, source, _, _), let .sort(_, source),
       let .distinct(source), let .limit(_, _, source),
       let .aggregate(_, _, source):
    return subquery(in: source)
  case let .product(left, right), let .outer(left, right, _, _),
       let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
    return subquery(in: left) || subquery(in: right)
  case .single, .empty, .scan, .join, .apply:
    return false
  }
}

/// Whether `term` is (or, through any nested term, reaches) a scalar
/// `.subquery` — a correlated scalar subquery still lowered as a projection or
/// operand term rather than replaced by a joined-column read.
private func subquery(_ term: Term) -> Bool {
  switch term {
  case .subquery:
    return true
  case let .apply(_, arguments):
    return arguments.contains { subquery($0) }
  case let .binary(_, lhs, rhs), let .nullif(lhs, rhs):
    return subquery(lhs) || subquery(rhs)
  case let .coalesce(elements, _):
    return elements.contains { subquery($0) }
  case let .cast(operand, _):
    return subquery(operand)
  case let .case(branches, otherwise, _):
    return branches.contains { subquery($0.0) || subquery($0.1) }
        || otherwise.map { subquery($0) } ?? false
  case .slot, .parameter, .constant:
    return false
  }
}

/// Whether `filter` reaches a scalar `.subquery` in any operand `Term` —
/// through the boolean connectives and the comparison/predicate operands a
/// `.select` filter is built from. Used to detect a scalar subquery left
/// correlated in a WHERE clause (the v1 non-projection cut).
private func subquery(_ filter: Filter) -> Bool {
  switch filter {
  case let .compare(lhs, _, rhs):
    return subquery(lhs) || subquery(rhs)
  case let .bound(operand, _, _):
    return subquery(operand)
  case let .null(operand, _):
    return subquery(operand)
  case let .membership(operand, elements, _):
    return subquery(operand) || elements.contains { subquery($0) }
  case let .and(lhs, rhs), let .or(lhs, rhs):
    return subquery(lhs) || subquery(rhs)
  case let .not(operand):
    return subquery(operand)
  default:
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

// MARK: - Decorrelatable EXISTS → semijoin: result-equivalence + plan shape

/// Behaviour-preserving oracles for the correlated `EXISTS` → SEMIJOIN and
/// `NOT EXISTS` → ANTI-join decorrelation. A semijoin is a per-row EXISTENCE
/// test: a left row survives AT MOST ONCE regardless of how many inner rows it
/// matches (unlike a join, which multiplies). Every case compares the run
/// against the KNOWN-CORRECT multiset the correlated `exists` evaluator
/// produces and pins the plan shape: a decorrelatable EXISTS becomes a
/// `.semijoin` with NO residual `.exists`, an excluded one stays an `.exists`.
struct DecorrelateExistsTests {
  /// AT-MOST-ONCE (G1): Id 1's body matches TWO inner rows, yet the left row
  /// appears EXACTLY ONCE — a semijoin tests existence, it does NOT multiply.
  /// Id 1 and Id 2 have children (kept), Id 3 has none (dropped).
  @Test func `a left row matching many inner rows appears exactly once`()
      throws {
    try fixture().expect(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) ORDER BY T.Id",
        yields: [[1], [2]])
  }

  /// PLAN SHAPE: the decorrelatable EXISTS optimises to a `.semijoin` (the SEMI
  /// sense) with NO surviving `.exists` conjunct — the pass fired.
  @Test func `a decorrelatable EXISTS optimises to a semijoin`() throws {
    let plan = try fixture().optimised(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)")
    #expect(semijoins(plan, anti: false))
    #expect(!exists(in: plan))
  }

  /// NOT EXISTS → ANTI-join: the complement of the SEMI case — a left row
  /// survives iff NO inner row matches. Only Id 3 (no child) survives.
  @Test func `a NOT EXISTS yields the anti-join complement`() throws {
    try fixture().expect(
        "SELECT T.Id FROM T " +
        "WHERE NOT EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) ORDER BY T.Id",
        yields: [[3]])
  }

  /// PLAN SHAPE: a `NOT EXISTS` optimises to a `.semijoin` of the ANTI sense
  /// (`anti == true`), NO `.exists` surviving.
  @Test func `a decorrelatable NOT EXISTS optimises to an anti-join`() throws {
    let plan = try fixture().optimised(
        "SELECT T.Id FROM T " +
        "WHERE NOT EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)")
    #expect(semijoins(plan, anti: true))
    #expect(!exists(in: plan))
  }

  /// NULL KEY (SEMI): a left row with a NULL correlation key matches nothing
  /// (NULL ≠ NULL), so EXISTS is FALSE and the SEMI drops it. Id 1 survives,
  /// NULL-Id row does not. The inner NULL-keyed `(NULL, 999)` never matches.
  @Test func `a NULL key makes EXISTS false and the semijoin drops the row`()
      throws {
    try nullFixture().expect(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) ORDER BY T.Id",
        yields: [[1]])
  }

  /// NULL KEY (ANTI): a NULL correlation key makes NOT EXISTS TRUE,
  /// so the ANTI-join KEEPS the NULL-Id row. Id 1 (has a child) is dropped, the
  /// NULL-Id row survives.
  @Test func `a NULL key makes NOT EXISTS true and the anti-join keeps it`()
      throws {
    try nullFixture().expect(
        "SELECT T.Id FROM T " +
        "WHERE NOT EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)",
        yields: [[nil]])
  }

  /// EMPTY INNER (SEMI): no inner row matches ANY left row, so EXISTS is FALSE
  /// for all — the SEMI emits nothing.
  @Test func `an empty matching inner drops every SEMI left row`() throws {
    try fixture().empty(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id AND S.x > 10000)")
  }

  /// EMPTY INNER (ANTI): no inner row matches, so NOT EXISTS is TRUE for every
  /// left row — the ANTI-join keeps them all.
  @Test func `an empty matching inner keeps every ANTI left row`() throws {
    try fixture().expect(
        "SELECT T.Id FROM T " +
        "WHERE NOT EXISTS (SELECT 1 FROM S WHERE S.k = T.Id AND S.x > 10000) " +
        "ORDER BY T.Id",
        yields: [[1], [2], [3]])
  }

  /// DUPLICATE LEFT ROWS (SEMI): a left relation with duplicate keys preserves
  /// every duplicate that passes the existence test — the semijoin filters, it
  /// does not dedup. Both copies of Id 1 survive; Id 3 (no child) drops.
  @Test func `duplicate left rows are preserved by the semijoin`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(1)            // a duplicate left key
        Row(3)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
        Row(1, 101)       // Id 1 matches many; each left copy appears once
      }
    }
    try catalog.expect(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)",
        yields: [[1], [1]])
  }

  /// DUPLICATE LEFT ROWS (ANTI): the mirror — every duplicate that FAILS the
  /// existence test is preserved. Both copies of Id 3 survive, Id 1 drops.
  @Test func `duplicate left rows are preserved by the anti-join`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(3)
        Row(3)            // a duplicate left key with no child
        Row(1)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
      }
    }
    try catalog.expect(
        "SELECT T.Id FROM T " +
        "WHERE NOT EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)",
        yields: [[3], [3]])
  }

  /// BODY RESIDUAL `p_R`: a safe local conjunct in the EXISTS WHERE (`S.x <
  /// 200`) rides the semijoin `on` alongside the correlation key. Id 1 keeps a
  /// matching child (100 or 101 < 200), Id 2's only child (200) fails it ⇒ Id 2
  /// drops, Id 3 has none. Only Id 1 survives.
  @Test func `a safe body residual filters the semijoin`() throws {
    try fixture().expect(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id AND S.x < 200) " +
        "ORDER BY T.Id",
        yields: [[1]])
  }

  /// A NULL body residual makes the match UNKNOWN — "not a match". A child with
  /// a NULL `flag` and the body `S.flag = 1` yields UNKNOWN for that row, so it
  /// does not satisfy EXISTS. Id 1's only child has a NULL flag ⇒ EXISTS false
  /// ⇒ dropped; Id 2's child (flag 1) satisfies it ⇒ kept.
  @Test func `a NULL body residual is not a match`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
      }
      Relation("S", ["k": .integer, "flag": .integer]) {
        Row(1, nil)       // flag NULL ⇒ S.flag = 1 UNKNOWN ⇒ not a match
        Row(2, 1)         // flag 1 ⇒ a match
      }
    }
    try catalog.expect(
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id AND S.flag = 1)",
        yields: [[2]])
  }

  /// A SAFE SIBLING beside the EXISTS still decorrelates: `T.Id < 3 AND
  /// EXISTS(...)`. Id 1 (child, < 3) survives, Id 2 (child, < 3) survives, Id 3
  /// fails the sibling. The semijoin fires (a safe sibling permits it) and the
  /// sibling stays in a `.select` above.
  @Test func `a safe sibling conjunct still decorrelates`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.Id < 3 AND EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)"
    let plan = try fixture().optimised(sql)
    #expect(semijoins(plan, anti: false))
    #expect(!exists(in: plan))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }
}

// MARK: - EXISTS that STAYS correlated, run correctly (and adversarial throws)

/// The excluded shapes: a body that is not a plain filter+project over a base
/// scan, a non-equi correlation, an unsafe body term, an unsafe SIBLING, and an
/// EXISTS nested in an `.or`. Each MUST stay a residual `.exists` (no
/// `.semijoin`) and run correctly — and the two throw-visibility cases must
/// throw exactly as the correlated plan does.
struct DecorrelateExistsExclusionTests {
  /// ADVERSARIAL SIBLING THROW-VISIBILITY (the step-4 guard, load-bearing): a
  /// sibling `(1 / T.v) = 0` divides by zero for a T row whose `v = 0`,
  /// AND that SAME row's EXISTS is FALSE. The correlated select evaluates the
  /// whole `AND` for the row and THROWS `.divide`. A wrongly-decorrelated plan
  /// would let the SEMIJOIN DROP that exists-false row and HIDE the throw. So
  /// the recogniser MUST leave it correlated (unsafe sibling) — and the run
  /// MUST throw.
  @Test func `an unsafe sibling stays correlated and throws`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "v": .integer]) {
        Row(9, 0)         // v = 0 ⇒ 1 / v faults; Id 9 has NO child ⇒ EXISTS
                          // false, so a semijoin drops it and hides the fault
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)       // keyed to Id 1, never to Id 9
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE (1 / T.v) = 0 AND EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)"
    let plan = try catalog.optimised(sql)
    #expect(!semijoins(plan))                   // NOT decorrelated
    #expect(exists(in: plan))                   // still a residual EXISTS
    catalog.expect(sql, fails: .divide)         // and it MUST throw
  }

  /// ADVERSARIAL BODY THROW-VISIBILITY (G4): an EXISTS body carries an UNSAFE
  /// term `1 / (S.x - 100) > 0` that divides by zero for the child `(1, 100)`,
  /// which is keyed to the ABSENT Id 1. The per-row correlated run never binds
  /// `:outer = 1`, so it never reaches that inner row and never throws. A
  /// set-based semijoin over the whole `S` WOULD evaluate the divide. The
  /// recogniser leaves it correlated (unsafe body), so the run is throw-free.
  @Test func `an unreachable throwing body row stays correlated`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(2)
        Row(3)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)      // x - 100 = 0 ⇒ divide by zero, keyed to absent Id 1
        Row(2, 200)      // safe for Id 2
      }
    }
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS " +
        "(SELECT 1 FROM S WHERE S.k = T.Id AND 1 / (S.x - 100) > 0)"
    #expect(!semijoins(try catalog.optimised(sql)))
    #expect(exists(in: try catalog.optimised(sql)))
    // Id 2: child (2, 200) ⇒ 1 / 100 = 0 ⇒ `> 0` false ⇒ EXISTS false; Id 3:
    // none. The Id-1 divide is never reached, so no rows and NO throw.
    let rows = try catalog.run(parse(query: sql), .standard)
    #expect(rows.isEmpty)
  }

  /// NON-EQUI correlation `S.k > T.Id`: no equi key to hash on, so the EXISTS
  /// stays correlated and runs correctly. Id 1 has a child with k > 1 (k = 2),
  /// Id 2 has none (only k ≤ 2), Id 3 none. Only Id 1 survives.
  @Test func `a non-equi correlation stays an exists and runs correctly`()
      throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k > T.Id)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// AGGREGATE body: a `COUNT(*)` body is not a plain filter+project,
  /// so the EXISTS stays correlated. The body is always non-empty (COUNT of an
  /// empty group yields a row), so EXISTS is TRUE for every left row — kept.
  @Test func `an aggregate body stays an exists and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS " +
        "(SELECT COUNT(*) FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2], [3]])
  }

  /// LIMIT body: a `FETCH FIRST` body is not the canonical filter+project,
  /// so the EXISTS stays correlated — and runs correctly (a body limited to one
  /// row still exists iff a matching child exists). Id 1, Id 2 kept, Id 3 not.
  @Test func `a limit body stays an exists and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS (SELECT x FROM S " +
        "WHERE S.k = T.Id ORDER BY S.x FETCH FIRST 1 ROW ONLY)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }

  /// DISTINCT body: a `SELECT DISTINCT` body is not the canonical shape, so the
  /// EXISTS stays correlated — and runs correctly (dedup does not change
  /// existence). Id 1, Id 2 kept, Id 3 not.
  @Test func `a distinct body stays an exists and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS " +
        "(SELECT DISTINCT x FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }

  /// SETOP body: a `UNION` body is not the canonical single-scan shape, so the
  /// EXISTS stays correlated — and runs correctly. Id 1, Id 2 have a matching
  /// arm; Id 3 has none.
  @Test func `a setop body stays an exists and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS " +
        "(SELECT x FROM S WHERE S.k = T.Id " +
        "UNION SELECT x FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }

  /// NESTED SUBQUERY in the body: the EXISTS body itself nests an `IN (Q)`, so
  /// its plan is not the canonical filter+project over a single scan — it stays
  /// correlated and runs correctly. Id 1, Id 2 have a child whose x is in the
  /// inner set; Id 3 has none.
  @Test func `a nested subquery body stays an exists and runs correctly`()
      throws {
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS (SELECT 1 FROM S " +
        "WHERE S.k = T.Id AND S.x IN (SELECT x FROM S))"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }

  /// BODY-LOCAL DERIVED table: the EXISTS body reads its OWN derived `e` (over
  /// `S`), a per-execution alias the set-based rewrite cannot relay. It stays
  /// correlated — and the derived `e` reads `S`, so Id 1, Id 2 are kept.
  @Test func `a body-local derived table stays an exists`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE EXISTS " +
        "(SELECT 1 FROM (SELECT k FROM S) AS e WHERE e.k = T.Id)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }

  /// EXISTS INSIDE AN `.or`: an EXISTS that is NOT a top-level `AND` conjunct
  /// (it sits under an `OR`) is left correlated — the recogniser lifts only a
  /// top-level conjunct. `T.Id = 3 OR EXISTS(...)`: Id 3 (the OR's left) and
  /// Ids 1, 2 (the EXISTS arm) survive.
  @Test func `an EXISTS under an OR stays correlated and runs correctly`()
      throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.Id = 3 OR EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try fixture().optimised(sql)))
    #expect(exists(in: try fixture().optimised(sql)))
    try fixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2], [3]])
  }
}

// MARK: - Multiple decorrelatable EXISTS → STACKED semijoins

/// Oracles for lifting MORE THAN ONE decorrelatable EXISTS conjunct of a single
/// WHERE. Each such conjunct becomes its OWN semijoin stacked over the source,
/// so the AND of independent existence tests is an AND of stacked semijoins —
/// order-independent, at-most-once per left row. Each case pins BOTH the count
/// of stacked semijoins (no residual `.exists`) AND the known-correct multiset
/// the correlated `exists` evaluator produces.
struct DecorrelateMultiExistsTests {
  /// A parent `T` and TWO children `S`, `U` keyed on `T.Id`. Id 1 has a match
  /// in BOTH, Id 2 only in `S`, Id 3 in NEITHER — the AND survives Id 1 alone,
  /// so lifting both semijoins must drop Ids 2 and 3.
  private func twoChildFixture() throws -> FixtureCatalog {
    try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
        Row(2)
        Row(3)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
        Row(2, 200)       // Id 2 matches S only
      }
      Relation("U", ["k": .integer, "y": .integer]) {
        Row(1, 900)       // Id 1 matches U (and S); Id 2, 3 do not
      }
    }
  }

  /// BOTH LIFT: two decorrelatable EXISTS of one WHERE become TWO stacked
  /// semijoins (no residual `.exists`), the result the rows matching BOTH: Id 1
  /// alone (Id 2 matches only `S`, dropped; Id 3 matches neither, dropped).
  @Test func `two decorrelatable EXISTS lift into two stacked semijoins`()
      throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) " +
        "AND EXISTS (SELECT 1 FROM U WHERE U.k = T.Id)"
    let plan = try twoChildFixture().optimised(sql)
    #expect(semijoinCount(plan) == 2)           // BOTH lifted
    #expect(!exists(in: plan))                   // no residual EXISTS
    try twoChildFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// AT-MOST-ONCE ACROSS THE STACK: an outer row whose BOTH bodies match MANY
  /// inner rows appears EXACTLY ONCE — a semijoin tests existence, it does not
  /// multiply, and stacking two preserves at-most-once. Id 1 matches two `S`
  /// rows and two `U` rows (four combinations a join would emit), yet the SEMI
  /// stack yields it once.
  @Test func `an outer row matching many in both bodies appears once`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer]) {
        Row(1)
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)
        Row(1, 101)       // Id 1 matches S twice
      }
      Relation("U", ["k": .integer, "y": .integer]) {
        Row(1, 900)
        Row(1, 901)       // Id 1 matches U twice
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) " +
        "AND EXISTS (SELECT 1 FROM U WHERE U.k = T.Id)"
    #expect(semijoinCount(try catalog.optimised(sql)) == 2)
    // A join would emit Id 1 four times (2 × 2); the SEMI stack emits it ONCE.
    try catalog.expect(sql, yields: [[1]])
  }

  /// MIXED SENSE: `EXISTS(...) AND NOT EXISTS(...)` lifts a SEMI over `S` and
  /// an ANTI over `U` — the complement rows. Id 1 has a child in BOTH (SEMI
  /// keeps, ANTI drops), Id 2 in `S` only (SEMI keeps, ANTI keeps), Id 3 in
  /// neither (SEMI drops). Only Id 2 survives both.
  @Test func `a SEMI and an ANTI in one WHERE both lift`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) " +
        "AND NOT EXISTS (SELECT 1 FROM U WHERE U.k = T.Id)"
    let plan = try twoChildFixture().optimised(sql)
    #expect(semijoinCount(plan) == 2)
    #expect(semijoinCount(plan, anti: false) == 1)   // the EXISTS over S
    #expect(semijoinCount(plan, anti: true) == 1)    // the NOT EXISTS over U
    #expect(!exists(in: plan))
    try twoChildFixture().expect(sql + " ORDER BY T.Id", yields: [[2]])
  }

  /// A DECORRELATABLE EXISTS beside a NON-decorrelatable one (an aggregate
  /// body): the whole select STAYS correlated. The non-decorrelatable exists is
  /// an UNSAFE non-lifted sibling, so it blocks all lifting (no semijoin). The
  /// run is still correct: Id 1's `S` child exists AND its aggregate body
  /// always yields a row (COUNT of an empty group is 0), so Ids 1, 2 (S
  /// children) survive, Id 3 does not.
  @Test func `a decorrelatable plus a non-decorrelatable EXISTS stay bound`()
      throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) " +
        "AND EXISTS (SELECT COUNT(*) FROM U WHERE U.k = T.Id)"
    let plan = try twoChildFixture().optimised(sql)
    #expect(semijoinCount(plan) == 0)            // nothing lifted
    #expect(exists(in: plan))                    // still residual EXISTS
    try twoChildFixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }

  /// ADVERSARIAL SIBLING THROW-VISIBILITY across TWO liftable EXISTS: an unsafe
  /// non-exists sibling `(1 / T.v) = 0` shares the WHERE with two
  /// decorrelatable EXISTS. A `v = 0` row whose EXISTS conjuncts do NOT all
  /// hold makes the correlated select evaluate the whole AND and THROW
  /// `.divide` (the sibling is first, so it is reached before the false
  /// EXISTS). A stack that dropped that row via a semijoin would HIDE the
  /// throw, so the guard leaves the WHOLE select correlated (no semijoin) — and
  /// the run MUST throw.
  @Test func `an unsafe sibling blocks all lifting and throws`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "v": .integer]) {
        Row(9, 0)         // v = 0 ⇒ 1 / v faults; Id 9 has NO S/U child, so its
                          // EXISTS conjuncts are false ⇒ a stack would drop it
      }
      Relation("S", ["k": .integer, "x": .integer]) {
        Row(1, 100)       // keyed to Id 1, never to Id 9
      }
      Relation("U", ["k": .integer, "y": .integer]) {
        Row(1, 900)       // keyed to Id 1, never to Id 9
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE (1 / T.v) = 0 " +
        "AND EXISTS (SELECT 1 FROM S WHERE S.k = T.Id) " +
        "AND EXISTS (SELECT 1 FROM U WHERE U.k = T.Id)"
    let plan = try catalog.optimised(sql)
    #expect(semijoinCount(plan) == 0)            // nothing lifted (unsafe kin)
    #expect(exists(in: plan))                    // still residual EXISTS
    catalog.expect(sql, fails: .divide)          // and it MUST throw
  }

  /// REGRESSION: a SINGLE decorrelatable EXISTS beside a SAFE non-exists kin
  /// still lifts EXACTLY as before — one semijoin, the sibling kept in a
  /// `.select` above. `T.Id < 3 AND EXISTS(over S)`: Id 1, Id 2 (S child, < 3)
  /// survive; Id 3 fails the sibling. The multi-lift path is a strict superset.
  @Test func `a single EXISTS beside a safe sibling still lifts once`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.Id < 3 AND EXISTS (SELECT 1 FROM S WHERE S.k = T.Id)"
    let plan = try twoChildFixture().optimised(sql)
    #expect(semijoinCount(plan) == 1)           // exactly one lift
    #expect(semijoins(plan, anti: false))
    #expect(!exists(in: plan))
    try twoChildFixture().expect(sql + " ORDER BY T.Id", yields: [[1], [2]])
  }
}

// MARK: - Decorrelatable correlated IN → semijoin: result + plan shape

/// A parent `T` (with an `x` value to test membership against) and a child `S`
/// keyed on `T.Id` — Id 1's `x = 100` matches a child value, Id 2's `x = 999`
/// does not (its key matches but no value equals), Id 3 has no child at all.
/// The three shapes a correlated `IN (Q)` semijoin keeps, drops on value, and
/// drops on key.
private func inFixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "x": .integer]) {
      Row(1, 100)         // key AND value match ⇒ kept
      Row(2, 999)         // key matches, value does not ⇒ dropped
      Row(3, 300)         // no child at all ⇒ dropped
    }
    Relation("S", ["k": .integer, "v": .integer]) {
      Row(1, 100)
      Row(1, 101)
      Row(2, 200)
    }
  }
}

/// Behaviour-preserving oracles for the POSITIVE correlated `IN (Q)` → SEMIJOIN
/// decorrelation. `operand IN (SELECT col FROM S WHERE S.k = :outer …)` is a
/// per-row membership test — TRUE iff some correlated inner row's `col` equals
/// `operand` — so it lifts to a semijoin whose `on` conjoins the correlation
/// key with the membership equality. Like EXISTS it is AT-MOST-ONCE. Each pins
/// BOTH the plan shape (a `.semijoin`, no residual `.within`) and the
/// known-correct multiset the correlated `within` evaluator produces.
struct DecorrelateInTests {
  /// The canonical lift: `T.x IN (SELECT S.v FROM S WHERE S.k = T.Id)`. Id 1
  /// (key 1, x = 100 = child 100) survives, Id 2 (key 2, x = 999 ≠ child 200)
  /// drops on value, Id 3 (no child) drops on key.
  @Test func `a correlated IN lifts to a semijoin with the correct rows`()
      throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    let plan = try inFixture().optimised(sql)
    #expect(semijoinCount(plan) == 1)
    #expect(semijoins(plan, anti: false))
    #expect(!within(in: plan))                   // no residual IN
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// AT-MOST-ONCE: an outer row whose operand matches MANY inner rows appears
  /// EXACTLY ONCE — a semijoin tests membership, it does not multiply. Id 1's
  /// `x = 100` equals two inner values (100 appears once, but 7 keyed to Id 1
  /// twice below), yet Id 1 surfaces once.
  @Test func `an outer row matching many inner rows appears once`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "x": .integer]) {
        Row(1, 7)
      }
      Relation("S", ["k": .integer, "v": .integer]) {
        Row(1, 7)
        Row(1, 7)          // Id 1's operand equals TWO inner rows
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    #expect(semijoinCount(try catalog.optimised(sql)) == 1)
    // A join would emit Id 1 twice; the SEMI emits it ONCE.
    try catalog.expect(sql, yields: [[1]])
  }

  /// NULL OPERAND: `x IN (Q)` with a NULL operand is UNKNOWN (never TRUE), so
  /// the SEMI drops the row. A NULL inner element does not falsely match a
  /// non-null operand either. Id 1 (x NULL) drops; Id 2 (x = 100, child 100
  /// beside a NULL child) survives — the NULL element is simply not a match.
  @Test func `a NULL operand drops and a NULL element never falsely matches`()
      throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "x": .integer]) {
        Row(1, nil)        // NULL operand ⇒ IN UNKNOWN ⇒ dropped
        Row(2, 100)        // matches the non-null child 100
      }
      Relation("S", ["k": .integer, "v": .integer]) {
        Row(1, 100)        // keyed to Id 1, but Id 1's operand is NULL
        Row(2, nil)        // a NULL element — never a definite match
        Row(2, 100)        // Id 2's real match
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    #expect(semijoinCount(try catalog.optimised(sql)) == 1)
    try catalog.expect(sql, yields: [[2]])
  }

  /// BODY RESIDUAL `p_R`: a safe local conjunct in the IN subquery WHERE
  /// (`S.v < 200`) rides the semijoin `on` alongside the correlation key and
  /// membership. Only children with `v < 200` are candidates. Id 1's x = 100
  /// equals child 100 (< 200) ⇒ kept; if the residual excluded 100 it would
  /// drop.
  @Test func `a safe body residual filters the semijoin`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "x": .integer]) {
        Row(1, 100)        // 100 < 200 ⇒ candidate ⇒ kept
        Row(2, 200)        // 200 not < 200 ⇒ excluded by residual ⇒ dropped
      }
      Relation("S", ["k": .integer, "v": .integer]) {
        Row(1, 100)
        Row(2, 200)
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT S.v FROM S WHERE S.k = T.Id AND S.v < 200)"
    let plan = try catalog.optimised(sql)
    #expect(semijoinCount(plan) == 1)
    #expect(!within(in: plan))
    try catalog.expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// A DECORRELATED IN beside a SAFE sibling: `T.Id < 3 AND T.x IN (…)`. The IN
  /// lifts into a semijoin and the safe sibling stays in a `.select` above. Id
  /// 1 (< 3, x = 100 matches) survives; Id 2 (< 3, x = 999 no match) drops on
  /// value; Id 3 fails the sibling.
  @Test func `a correlated IN beside a safe sibling lifts`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.Id < 3 AND T.x IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    let plan = try inFixture().optimised(sql)
    #expect(semijoinCount(plan) == 1)
    #expect(semijoins(plan, anti: false))
    #expect(!within(in: plan))
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }
}

// MARK: - IN that STAYS correlated, run correctly

/// The excluded IN shapes: a deferred `NOT IN`, an UNCORRELATED IN, a non-equi
/// correlation, a non-canonical body (aggregate/limit/distinct), a body-local
/// derived table, and an IN whose subquery projects an EXPRESSION. Each MUST
/// stay a residual `.within` (no `.semijoin`) and run correctly.
struct DecorrelateInExclusionTests {
  /// DEFERRED `NOT IN`: the NULL trap makes it not a plain anti-join, so it is
  /// left correlated. Over the base fixture Id 1 (x = 100 IN {100, 101}) is
  /// excluded by NOT IN; Id 2 (x = 999 NOT IN {200}) survives; Id 3 has no
  /// child so `NOT IN ()` is TRUE — kept.
  @Test func `a NOT IN stays correlated and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x NOT IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[2], [3]])
  }

  /// UNCORRELATED IN: `x IN (SELECT v FROM S)` has an empty correlation (v1
  /// lifts CORRELATED IN only), so it stays a residual `.within`. The inner set
  /// is {100, 101, 200}; Id 1 (x = 100) and Id 2? x = 999 not in ⇒ drop; Id 3 x
  /// = 300 not in ⇒ drop. Only Id 1 survives.
  @Test func `an uncorrelated IN stays correlated and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE T.x IN (SELECT S.v FROM S)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// NON-EQUI correlation `S.k > T.Id`: no equi key to hash on, so the IN stays
  /// correlated. Id 1: children with k > 1 → k = 2 → v = 200; x = 100 ∉ {200} ⇒
  /// drop. Id 2: k > 2 → none ⇒ drop. Id 3: none ⇒ drop. No rows.
  @Test func `a non-equi correlation stays correlated and runs correctly`()
      throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT S.v FROM S WHERE S.k > T.Id)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().empty(sql)
  }

  /// AGGREGATE body: a `SUM(S.v)` body is not a plain filter+project, so the IN
  /// stays correlated. Id 1's children sum to 201, x = 100 ≠ 201 ⇒ drop; Id 2's
  /// sum is 200, x = 999 ≠ 200 ⇒ drop; Id 3's group is empty (SUM ⇒ NULL), IN
  /// UNKNOWN ⇒ drop. No rows.
  @Test func `an aggregate body stays correlated and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT SUM(S.v) FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().empty(sql)
  }

  /// LIMIT body: a `FETCH FIRST` body is not the canonical filter+project, so
  /// the IN stays correlated — and runs correctly. Id 1's first-by-v child is
  /// 100, x = 100 ⇒ kept; Id 2's is 200, x = 999 ⇒ drop; Id 3 none ⇒ drop.
  @Test func `a limit body stays correlated and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE T.x IN " +
        "(SELECT S.v FROM S WHERE S.k = T.Id ORDER BY S.v FETCH FIRST 1 ROW " +
        "ONLY)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// DISTINCT body: a `SELECT DISTINCT` body is not the canonical shape, so the
  /// IN stays correlated — dedup does not change membership. Id 1 (x = 100 ∈
  /// {100, 101}) kept; Id 2, Id 3 drop.
  @Test func `a distinct body stays correlated and runs correctly`() throws {
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT DISTINCT S.v FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// BODY-LOCAL DERIVED table: the IN body reads its OWN derived `e` (over
  /// `S`), a per-execution alias the set-based rewrite cannot relay. It stays
  /// correlated — the derived `e` reads `S`, so Id 1 (x = 100 ∈ {100, 101})
  /// survives; Id 2, Id 3 drop.
  @Test func `a body-local derived table stays correlated`() throws {
    let sql =
        "SELECT T.Id FROM T WHERE T.x IN " +
        "(SELECT e.v FROM (SELECT k, v FROM S) AS e WHERE e.k = T.Id)"
    #expect(!semijoins(try inFixture().optimised(sql)))
    #expect(within(in: try inFixture().optimised(sql)))
    try inFixture().expect(sql + " ORDER BY T.Id", yields: [[1]])
  }

  /// EXPRESSION projection: the IN subquery projects `S.v + 1`, not a bare
  /// column, so there is no single membership slot and the IN stays correlated.
  /// Id 1's candidate values are {101, 102}; x = 100 ∉ ⇒ drop. Add an Id whose
  /// x equals a shifted value to prove it still runs: Id 4 x = 401 = 400 + 1.
  @Test func `an expression projection stays correlated and runs correctly`()
      throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "x": .integer]) {
        Row(1, 100)        // 100 ∉ {101, 102} ⇒ drop
        Row(4, 401)        // 401 = 400 + 1 ⇒ kept
      }
      Relation("S", ["k": .integer, "v": .integer]) {
        Row(1, 100)
        Row(1, 101)
        Row(4, 400)
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE T.x IN (SELECT S.v + 1 FROM S WHERE S.k = T.Id)"
    #expect(!semijoins(try catalog.optimised(sql)))
    #expect(within(in: try catalog.optimised(sql)))
    try catalog.expect(sql + " ORDER BY T.Id", yields: [[4]])
  }
}

// MARK: - IN adversarial throw-visibility (operand + sibling)

/// The two throw-visibility guards specific to the IN lift: an UNSAFE operand
/// (evaluated per outer row by the correlated `within`, even when the inner is
/// empty, so a semijoin that never evaluates `on` for a no-match row would
/// SUPPRESS its throw) and an UNSAFE non-IN sibling (the shared sibling guard).
/// Both MUST stay correlated (no semijoin) and throw exactly as the correlated
/// plan does.
struct DecorrelateInThrowVisibilityTests {
  /// UNSAFE OPERAND (load-bearing): `(1 / T.v) IN (SELECT S.v FROM S WHERE
  /// S.k = T.Id)` with a `v = 0` row whose key has NO child. The correlated
  /// `within` evaluates the operand `1 / 0` for that row EVEN THOUGH the inner
  /// is empty, so it THROWS `.divide`. A semijoin never evaluates `on` for a
  /// left row with no right rows, so it would SUPPRESS the throw — the
  /// recogniser must leave it correlated (unsafe operand), and the run MUST
  /// throw.
  @Test func `an unsafe operand stays correlated and throws`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "v": .integer]) {
        Row(9, 0)          // v = 0 ⇒ 1 / v faults; Id 9 has NO child ⇒ inner
                           // empty, so a semijoin never confirms `on` and hides
                           // the fault
      }
      Relation("S", ["k": .integer, "v": .integer]) {
        Row(1, 100)        // keyed to Id 1, never to Id 9
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE (1 / T.v) IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    let plan = try catalog.optimised(sql)
    #expect(!semijoins(plan))                    // NOT decorrelated
    #expect(within(in: plan))                    // still a residual IN
    catalog.expect(sql, fails: .divide)          // and it MUST throw
  }

  /// UNSAFE SIBLING (the shared sibling guard, on the IN-lift path): a
  /// non-IN sibling `(1 / T.v) = 0` divides by zero for a `v = 0` row whose IN
  /// is FALSE. The correlated select evaluates the whole `AND` (the sibling
  /// first) and THROWS `.divide`. A plan that lifted the IN into a semijoin and
  /// dropped the IN-false row would HIDE the throw, so the guard leaves the
  /// WHOLE select correlated — and the run MUST throw.
  @Test func `an unsafe sibling stays correlated and throws`() throws {
    let catalog = try Catalog {
      Relation("T", ["Id": .integer, "x": .integer, "v": .integer]) {
        Row(9, 100, 0)     // v = 0 ⇒ 1 / v faults; Id 9 has NO child ⇒ IN
                           // false, so a semijoin would drop it, hide the fault
      }
      Relation("S", ["k": .integer, "v": .integer]) {
        Row(1, 100)        // keyed to Id 1, never to Id 9
      }
    }
    let sql =
        "SELECT T.Id FROM T " +
        "WHERE (1 / T.v) = 0 " +
        "AND T.x IN (SELECT S.v FROM S WHERE S.k = T.Id)"
    let plan = try catalog.optimised(sql)
    #expect(!semijoins(plan))                    // nothing lifted (unsafe kin)
    #expect(within(in: plan))                    // still a residual IN
    catalog.expect(sql, fails: .divide)          // and it MUST throw
  }
}

// MARK: - Decorrelatable scalar subquery → LEFT join: result + plan shape

/// A parent `T` whose `fk` column points at a child `R` row by its 1-based
/// virtual `Id` — `fk` 1 → R's row 1, `fk` 3 → R's row 3, `fk` 5 → NO R row
/// (past the end), `fk` NULL → nothing. `R.Id` is the UNIQUE virtual key the
/// scalar `(SELECT R.v FROM R WHERE R.Id = T.fk)` decorrelates over.
private func scalarFixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["fk": .integer]) {
      Row(1)              // → R row 1 (v = 100)
      Row(3)              // → R row 3 (v = 300)
      Row(5)              // → no R row ⇒ scalar NULL
      Row(nil)            // NULL key ⇒ scalar NULL
    }
    Relation("R", ["v": .integer]) {
      Row(100)            // Id 1
      Row(200)            // Id 2
      Row(300)            // Id 3
    }
  }
}

/// Behaviour-preserving oracles for the correlated scalar `.subquery` → LEFT
/// join decorrelation. A scalar subquery over the UNIQUE virtual `Id` key
/// matches AT MOST ONE inner row, so it becomes a plain LEFT join reading the
/// value from a joined column (an unmatched left row NULL-extends, the empty →
/// NULL of the correlated scalar). Each case compares the run against the
/// KNOWN-CORRECT multiset the correlated `scalar` evaluator produces and pins
/// the plan shape: a decorrelatable scalar becomes an `.outer` (LEFT) join with
/// NO residual `.subquery` term, an excluded one stays a `.subquery`.
struct DecorrelateScalarTests {
  /// (1) 0 MATCHES → NULL: `fk` 5 and the NULL key reach no `R.Id`, so the LEFT
  /// join NULL-extends and the coalesce passes the NULL through — exactly the
  /// empty → NULL the correlated scalar yields.
  @Test func `an unmatched scalar key yields NULL`() throws {
    try scalarFixture().expect(
        "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk) AS v FROM T " +
        "ORDER BY v",
        yields: [[nil], [nil], [100], [300]])
  }

  /// (2) 1 MATCH → THE VALUE, and the plan is a LEFT `.outer` join with NO
  /// residual `.subquery` term — the pass fired.
  @Test func `a matched scalar key reads the joined value`() throws {
    let sql = "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk) AS v FROM T"
    let plan = try scalarFixture().optimised(sql)
    #expect(outers(plan))
    #expect(!subquery(in: plan))
    try scalarFixture().expect(sql + " ORDER BY v",
                               yields: [[nil], [nil], [100], [300]])
  }

  /// (3) TYPE COERCION (pins the coalesce, not a raw slot): the scalar's column
  /// is `.double` but its cells are stored as integers, so the coalesce must
  /// widen a matched `.integer` cell to `.double` (`100` → `100.0`) and pass a
  /// NULL (an unmatched key) through unchanged — byte-identical to the scalar
  /// evaluator's `(value ?? .null).coerced(to: .double)`. A raw slot would drop
  /// the widening.
  @Test func `a double-typed scalar widens the integer cell`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(1)            // → R row 1 (d = 100 stored as integer)
        Row(5)            // → no R row ⇒ NULL under .double
      }
      Relation("R", ["d": .double]) {
        Row(100)          // an integer cell in a .double column
      }
    }
    let sql = "SELECT (SELECT R.d FROM R WHERE R.Id = T.fk) AS d FROM T"
    #expect(outers(try catalog.optimised(sql)))
    // The matched cell widens to .double(100.0); the unmatched key stays NULL.
    try catalog.expect(sql + " ORDER BY d",
                       yields: [[Value.null], [Value.double(100.0)]])
  }

  /// (4) DUPLICATE LEFT ROWS read the scalar N times: a LEFT join emits each
  /// left row once (a unique key never multiplies), so three copies of `fk` 1
  /// each read `R.Id` 1's value — the same value three times, not deduped.
  @Test func `duplicate left rows each read the scalar`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(1)
        Row(1)
        Row(1)
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
      }
    }
    let sql = "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk) AS v FROM T"
    #expect(outers(try catalog.optimised(sql)))
    try catalog.expect(sql, yields: [[100], [100], [100]])
  }

  /// (5) SCALAR BESIDE A THROWING SIBLING TERM: a LEFT join drops NO row, so
  /// the sibling `1 / T.z` is evaluated on exactly the rows it was correlated.
  /// The `z = 0` row makes it divide by zero, and the decorrelated plan MUST
  /// throw identically to the correlated one — nothing is suppressed.
  @Test func `a throwing sibling term throws after decorrelation`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer, "z": .integer]) {
        Row(1, 2)         // scalar 100, 1 / 2 = 0
        Row(3, 0)         // 1 / 0 ⇒ divide by zero
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
        Row(200)          // Id 2
        Row(300)          // Id 3
      }
    }
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk), 1 / T.z FROM T"
    // The scalar decorrelates (a LEFT join, no residual scalar term) yet the
    // sibling still faults — the LEFT join drops no row.
    #expect(outers(try catalog.optimised(sql)))
    #expect(!subquery(in: try catalog.optimised(sql)))
    catalog.expect(sql, fails: .divide)
  }

  /// (6) NON-UNIQUE KEY STAYS CORRELATED: the body keys on a REAL column
  /// (`R.owner`, ordinal `< width`) rather than the unique virtual `Id`, so the
  /// uniqueness guard bails and the scalar stays a `.subquery`. The correlated
  /// run is correct; a key matching TWO rows still throws `.cardinality`
  /// per-row.
  @Test func `a non-unique real key stays correlated`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(7)            // matches R's single owner-7 row
        Row(9)            // matches no owner ⇒ NULL
      }
      Relation("R", ["owner": .integer, "v": .integer]) {
        Row(7, 100)       // owner 7 — one row
      }
    }
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.owner = T.fk) AS v FROM T"
    let plan = try catalog.optimised(sql)
    #expect(!outers(plan))                       // NOT decorrelated
    #expect(subquery(in: plan))                  // still a residual scalar
    try catalog.expect(sql + " ORDER BY v", yields: [[nil], [100]])
  }

  /// (6b) A non-unique key that matches MANY rows still throws `.cardinality`
  /// per-row under the correlated path — the scalar was correctly left
  /// correlated, preserving the >1-row fault a LEFT join could not reproduce.
  @Test func `a non-unique key matching many rows still faults`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(7)            // matches TWO owner-7 rows ⇒ cardinality
      }
      Relation("R", ["owner": .integer, "v": .integer]) {
        Row(7, 100)
        Row(7, 200)       // a second owner-7 row
      }
    }
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.owner = T.fk) AS v FROM T"
    #expect(subquery(in: try catalog.optimised(sql)))   // NOT decorrelated
    catalog.expect(sql, fails: .cardinality)
  }

  /// (8) MULTIPLE SCALAR SUBQUERIES → two stacked LEFT joins: each replaced
  /// term reads its OWN joined column, an unreplaced term keeps its original
  /// slot, and both values are correct. `fk1` → R.v, `fk2` → R.w over one R.
  @Test func `two scalar subqueries stack into two LEFT joins`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk1": .integer, "fk2": .integer]) {
        Row(1, 2)         // R.v of Id 1 = 100, R.w of Id 2 = 21
        Row(3, 5)         // R.v of Id 3 = 300, Id 5 absent ⇒ NULL
      }
      Relation("R", ["v": .integer, "w": .integer]) {
        Row(100, 11)      // Id 1
        Row(200, 21)      // Id 2
        Row(300, 31)      // Id 3
      }
    }
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk1), " +
        "(SELECT R.w FROM R WHERE R.Id = T.fk2) FROM T"
    let plan = try catalog.optimised(sql)
    #expect(!subquery(in: plan))                 // BOTH decorrelated
    #expect(outers(plan))
    try catalog.expect(sql + " ORDER BY 1",
                       yields: [[100, 21], [300, nil]])
  }

  /// (8b) An unreplaced projection term keeps its ORIGINAL source slot as the
  /// scalar joins stack after it: `T.fk1` (source slot 0) still reads correctly
  /// beside the two decorrelated scalars whose joins append columns after it.
  @Test func `an unreplaced term keeps its slot under stacked joins`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk1": .integer, "fk2": .integer]) {
        Row(1, 3)         // fk1 = 1, R.v of Id 1 = 100, R.v of Id 3 = 300
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
        Row(200)          // Id 2
        Row(300)          // Id 3
      }
    }
    let sql =
        "SELECT T.fk1, (SELECT R.v FROM R WHERE R.Id = T.fk1), " +
        "(SELECT R.v FROM R WHERE R.Id = T.fk2) FROM T"
    #expect(!subquery(in: try catalog.optimised(sql)))
    try catalog.expect(sql, yields: [[1, 100, 300]])
  }

  /// (9) SCALAR IN WHERE stays correlated (the v1 non-projection cut) and runs
  /// correctly: only `fk` 1 has `R.Id = 1` with `v = 100`, so the predicate
  /// `(SELECT …) = 100` admits it alone.
  @Test func `a scalar subquery in WHERE stays correlated`() throws {
    let sql =
        "SELECT T.fk FROM T " +
        "WHERE (SELECT R.v FROM R WHERE R.Id = T.fk) = 100"
    #expect(subquery(in: try scalarFixture().optimised(sql)))   // v1 cut
    try scalarFixture().expect(sql, yields: [[1]])
  }
}

// MARK: - Scalar subquery excluded bodies: STAY correlated, run correctly

/// The G3 exclusions the scalar recogniser shares with the semijoin/apply
/// paths — a body that is not the canonical filter+project over a single base
/// scan — plus the uniqueness cut. Each stays a `.subquery` and runs correctly.
struct DecorrelateScalarExclusionTests {
  /// (7a) AGGREGATE body: a `MAX(R.v)` body is not a bare-`.slot` projection
  /// over a plain scan, so it stays a `.subquery` — and runs correctly (fk 1 →
  /// MAX over the one matching R row).
  @Test func `an aggregate body stays a subquery`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(1)
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
      }
    }
    let sql =
        "SELECT (SELECT MAX(R.v) FROM R WHERE R.Id = T.fk) AS v FROM T"
    #expect(subquery(in: try catalog.optimised(sql)))   // NOT decorrelated
    try catalog.expect(sql, yields: [[100]])
  }

  /// (7b) NON-EQUI correlation (`R.Id > T.fk`): no equi key to hash on, so it
  /// stays a `.subquery`. fk 2 sees R.Id ∈ {3} > 2 — one row (v = 300); a run
  /// is correct.
  @Test func `a non-equi correlation stays a subquery`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(2)            // R.Id > 2 → {3} → v = 300 (one row)
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
        Row(200)          // Id 2
        Row(300)          // Id 3
      }
    }
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Id > T.fk) AS v FROM T"
    #expect(subquery(in: try catalog.optimised(sql)))   // NOT decorrelated
    try catalog.expect(sql, yields: [[300]])
  }

  /// (7c) LIMIT body: a `FETCH FIRST 1 ROW` body wears a `.limit` node, not the
  /// canonical filter+project, so it stays a `.subquery` — and runs correctly.
  @Test func `a limited body stays a subquery`() throws {
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk " +
        "ORDER BY R.v OFFSET 0 ROWS FETCH FIRST 1 ROW ONLY) AS v FROM T"
    #expect(subquery(in: try scalarFixture().optimised(sql)))   // NOT decorr.
    try scalarFixture().expect(sql + " ORDER BY v",
                               yields: [[nil], [nil], [100], [300]])
  }

  /// (7d) DISTINCT body: a `SELECT DISTINCT` body is a `.distinct` node, not
  /// the canonical shape, so it stays a `.subquery` — and runs correctly.
  @Test func `a distinct body stays a subquery`() throws {
    let sql =
        "SELECT (SELECT DISTINCT R.v FROM R WHERE R.Id = T.fk) AS v FROM T"
    #expect(subquery(in: try scalarFixture().optimised(sql)))   // NOT decorr.
    try scalarFixture().expect(sql + " ORDER BY v",
                               yields: [[nil], [nil], [100], [300]])
  }

  /// (7e) SET-OP body: a `UNION` body is a `.setop`, not the canonical shape,
  /// so it stays a `.subquery` — and runs correctly (the union of the matching
  /// row with the empty other arm).
  @Test func `a setop body stays a subquery`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(1)
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
      }
      Relation("Q", ["v": .integer]) {
        Row(999)          // never matched (Id 2 absent)
      }
    }
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk " +
        "UNION SELECT Q.v FROM Q WHERE Q.Id = 2) AS v FROM T"
    #expect(subquery(in: try catalog.optimised(sql)))   // NOT decorrelated
    try catalog.expect(sql, yields: [[100]])
  }

  /// (7f) BODY-LOCAL DERIVED table: the body reads its OWN derived `e` over R,
  /// a per-execution materialised alias the set-based rewrite cannot relay, so
  /// it stays a `.subquery` — and runs correctly.
  @Test func `a body-local derived table stays a subquery`() throws {
    let sql =
        "SELECT (SELECT e.v FROM (SELECT R.Id AS Id, R.v AS v FROM R) AS e " +
        "WHERE e.Id = T.fk) AS v FROM T"
    #expect(subquery(in: try scalarFixture().optimised(sql)))   // NOT decorr.
    try scalarFixture().expect(sql + " ORDER BY v",
                               yields: [[nil], [nil], [100], [300]])
  }

  /// (7g) VIEW body: the body scans a registered VIEW, not a base relation, so
  /// its `.scan` re-resolves against the wrong overlay when relaid — the
  /// recogniser leaves it a `.subquery`. It runs correctly.
  @Test func `a view body stays a subquery`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(1)
        Row(5)            // no matching view row ⇒ NULL
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
      }
      try View("RV", "SELECT R.Id AS Id, R.v AS v FROM R", as: ["Id", "v"])
    }
    let sql =
        "SELECT (SELECT RV.v FROM RV WHERE RV.Id = T.fk) AS v FROM T"
    #expect(subquery(in: try catalog.optimised(sql)))   // NOT decorrelated
    try catalog.expect(sql + " ORDER BY v", yields: [[nil], [100]])
  }

  /// (10) NULL CORRELATION KEY → NULL: a NULL `fk` makes the `.match` UNKNOWN,
  /// so the LEFT join NULL-extends and the coalesce passes NULL through —
  /// identical to the per-row `WHERE R.Id = :outer` (`:outer` NULL) empty →
  /// NULL. Decorrelated (an `.outer`) and correct.
  @Test func `a NULL correlation key NULL-extends to NULL`() throws {
    let catalog = try Catalog {
      Relation("T", ["fk": .integer]) {
        Row(1)            // → v = 100
        Row(nil)          // NULL key ⇒ NULL
      }
      Relation("R", ["v": .integer]) {
        Row(100)          // Id 1
      }
    }
    let sql = "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk) AS v FROM T"
    #expect(outers(try catalog.optimised(sql)))          // decorrelated
    try catalog.expect(sql + " ORDER BY v", yields: [[nil], [100]])
  }
}

// MARK: - Non-`Id` first virtual: the width-ordinal virtual is NOT unique

/// A minimal `Table` whose FIRST virtual is NOT `Id` — its width-ordinal
/// virtual is a NON-unique `Owner` — beside the standard `Id`-at-`width`
/// fixture the builders always vend.
///
/// The `Table.virtuals` contract permits a conformer whose first virtual is not
/// `Id` (the default is empty, and a source names its own virtuals in any
/// order). Such a virtual still sits at ordinal `== width`, yet — unlike the
/// unique `Id` — it can repeat across rows, so a scalar keyed on it may match
/// many rows and must raise `.cardinality`. The `FixtureCatalog` builders hard
/// wire `Id` at `width`, so this hand-rolled adapter is the only way to model a
/// non-`Id` width-ordinal virtual: it proves the scalar recogniser's uniqueness
/// guard consults the virtual's NAME, not merely its ordinal.
///
/// It carries one real column `v` (`width == 1`) and one virtual column (at
/// ordinal `1`) named `virtual`. When `owners` holds a cell per row that is the
/// virtual value — a value that MAY repeat, the many-match shape a unique `Id`
/// never produces; when `owners` is empty the virtual is the 1-based `Id`.
private struct OwnerRelation: Sendable {
  /// The real `v` cell of each row, in row order.
  let values: Array<Value>

  /// The name of the lone virtual column at ordinal `width` — `Owner` for the
  /// non-unique case, `Id` for the positive control.
  let virtual: String

  /// The virtual cell each row computes, in row order, or empty for the 1-based
  /// `Id`. A stored cell MAY repeat, so a scalar keyed on it can match many.
  let owners: Array<Value>
}

/// A `Catalog` vending a standard `T` (a real `fk`, a virtual `Id`) and an
/// `OwnerRelation` `R` whose lone virtual is named by the relation.
private struct OwnerCatalog: Catalog {
  let parents: Array<Value>
  let child: OwnerRelation

  func table(named name: String) -> OwnerTable? {
    switch name.lowercased() {
    case "t":
      return OwnerTable(names: ["fk"], values: parents.map { [$0] },
                        virtual: "Id")
    case "r":
      return OwnerTable(names: ["v"], values: child.values.map { [$0] },
                        virtual: child.virtual, owners: child.owners)
    default:
      return nil
    }
  }

  func view(named name: String) -> SQLEngine.View? { nil }
  func relations() -> Array<String> { ["T", "R"] }
  func views() -> Array<String> { [] }
}

/// A `Table` with real columns `names` and ONE virtual column `virtual` at
/// ordinal `width`. When `owners` is empty the virtual is the 1-based `Id`;
/// when it holds a cell per row the virtual reads that cell — a value that may
/// repeat.
private struct OwnerTable: Table {
  let names: Array<String>
  let values: Array<Array<Value>>
  let virtual: String
  let owners: Array<Value>

  init(names: Array<String>, values: Array<Array<Value>>, virtual: String,
       owners: Array<Value> = []) {
    self.names = names
    self.values = values
    self.virtual = virtual
    self.owners = owners
  }

  var width: Int { names.count }
  var types: Array<ValueType> { Array(repeating: .integer, count: width) }
  var virtuals: Array<String> { [virtual] }
  var extent: Int { width + 1 }

  func ordinal(of name: String) -> Int? {
    let folded = name.lowercased()
    if let real = names.firstIndex(where: { $0.lowercased() == folded }) {
      return real
    }
    return virtual.lowercased() == folded ? width : nil
  }

  func bound(_ column: Int, _ value: Int, strict: Bool) -> Int? { nil }
  func ordered(_ column: Int) -> Bool { true }

  func cursor() -> OwnerCursor {
    OwnerCursor(values: values, width: width, owners: owners)
  }
}

/// An index-addressed cursor over an `OwnerTable`'s rows.
private struct OwnerCursor: SQLEngine.Cursor {
  let values: Array<Array<Value>>
  let width: Int
  let owners: Array<Value>

  var count: Int { values.count }

  func row(_ index: Int) -> OwnerRow? {
    guard index < values.count else { return nil }
    return OwnerRow(cells: values[index], width: width,
                    owner: owners.isEmpty ? nil : owners[index], index: index)
  }
}

/// A positional view over one row — a real ordinal reads the stored cell, the
/// virtual ordinal `width` reads the row's `owner` cell (a repeatable value)
/// or, absent one, the 1-based `Id`.
private struct OwnerRow: SQLEngine.Row {
  let cells: Array<Value>
  let width: Int
  let owner: Value?
  let index: Int

  subscript(_ column: Int) -> Value {
    borrowing get {
      if column == width { return owner ?? .integer(index + 1) }
      return cells[column]
    }
  }
}

/// The reviewer's scenario: a relation whose FIRST virtual is a NON-unique
/// `Owner` (at ordinal `== width`) must NOT decorrelate a scalar keyed on it —
/// the guard must consult the virtual's NAME, not merely its ordinal. Were it
/// to lift the scalar into a LEFT join, a key matching many rows would emit the
/// values rather than raising `.cardinality`: silent corruption.
struct DecorrelateScalarVirtualTests {
  /// A scalar keyed on the non-`Id` width-ordinal virtual STAYS correlated: the
  /// optimised plan keeps the `.subquery` term and gains NO `.outer` from it.
  @Test func `a non-Id width-ordinal virtual stays correlated`() throws {
    let catalog = OwnerCatalog(
        parents: [.integer(7), .integer(9)],
        child: OwnerRelation(values: [.integer(100)], virtual: "Owner",
                             owners: [.integer(7)]))
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Owner = T.fk) AS v FROM T"
    let plan = try catalog.optimised(sql)
    #expect(subquery(in: plan))                  // still a residual scalar
    #expect(!outers(plan))                        // NOT decorrelated
    try catalog.expect(sql + " ORDER BY v", yields: [[nil], [100]])
  }

  /// When an outer row's `fk` matches MORE THAN ONE R row on the non-unique
  /// `Owner`, the correlated per-row scalar raises `.cardinality` — the fault a
  /// wrongly-lifted LEFT join would silence by emitting both values.
  @Test func `a many-match non-Id virtual raises cardinality`() throws {
    let catalog = OwnerCatalog(
        parents: [.integer(7)],
        child: OwnerRelation(values: [.integer(100), .integer(200)],
                             virtual: "Owner",
                             owners: [.integer(7), .integer(7)]))
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Owner = T.fk) AS v FROM T"
    #expect(subquery(in: try catalog.optimised(sql)))   // NOT decorrelated
    catalog.expect(sql, fails: .cardinality)
  }

  /// POSITIVE CONTROL: the SAME adapter shape keyed on a genuine `Id` virtual
  /// (its first virtual IS `Id`) still DOES decorrelate — the guard did not
  /// over-tighten. The virtual here is the row's 1-based `Id`, so `fk` 1 reads
  /// R's row 1.
  @Test func `an Id width-ordinal virtual still decorrelates`() throws {
    let catalog = OwnerCatalog(
        parents: [.integer(1), .integer(3)],
        child: OwnerRelation(values: [.integer(100), .integer(200),
                                      .integer(300)],
                             virtual: "Id",   // first virtual IS Id
                             owners: []))     // empty ⇒ virtual is the Id
    let sql =
        "SELECT (SELECT R.v FROM R WHERE R.Id = T.fk) AS v FROM T"
    let plan = try catalog.optimised(sql)
    #expect(outers(plan))                         // decorrelated
    #expect(!subquery(in: plan))                  // no residual scalar
    try catalog.expect(sql + " ORDER BY v", yields: [[100], [300]])
  }
}
