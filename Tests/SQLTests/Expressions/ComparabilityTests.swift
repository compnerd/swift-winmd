// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation carrying one column of each comparable kind — an integer `N`, a
/// text `S`, a boolean `B`, and a double `D` — beside a text relation `U` a
/// subquery reads, so a comparison mixing any two kinds is expressible.
private func mixed() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "N": .integer, "S": .text,
                   "B": .boolean, "D": .double]) {
      Row(1, 10, "x", true, 1.0)
      Row(2, 20, "y", false, 2.5)
    }
    Relation("U", ["Label": .text]) {
      Row("a")
      Row("b")
    }
  }
}

/// The incomparable-type faults this fixture's cross-kind pairs raise.
private let intVsText =
    SQLError.state("42804", "cannot compare integer with character varying")
private let textVsInt =
    SQLError.state("42804", "cannot compare character varying with integer")
private let intVsBoolean =
    SQLError.state("42804", "cannot compare integer with boolean")

// MARK: - Scalar comparison

/// A cross-kind scalar comparison is a data-type mismatch, faulting on both the
/// run and the `validate: true` schema path with the same SQLSTATE — the
/// run ≡ validate parity the ISO comparability rule demands.
struct ScalarComparabilityTests {
  @Test func `a cross-kind equality faults run and validate`() throws {
    let query = try parse(query: "SELECT Id FROM T WHERE N = S")
    #expect(throws: intVsText) { try mixed().columns(of: query) }
    try mixed().expect("SELECT Id FROM T WHERE N = S", fails: intVsText)
  }

  @Test func `a cross-kind inequality faults run and validate`() throws {
    let query = try parse(query: "SELECT Id FROM T WHERE N <> S")
    #expect(throws: intVsText) { try mixed().columns(of: query) }
    try mixed().expect("SELECT Id FROM T WHERE N <> S", fails: intVsText)
  }

  @Test func `a cross-kind ordering faults run and validate`() throws {
    let query = try parse(query: "SELECT Id FROM T WHERE N < S")
    #expect(throws: intVsText) { try mixed().columns(of: query) }
    try mixed().expect("SELECT Id FROM T WHERE N < S", fails: intVsText)
  }

  @Test func `a boolean against a number faults`() throws {
    let query = try parse(query: "SELECT Id FROM T WHERE N = B")
    #expect(throws: intVsBoolean) { try mixed().columns(of: query) }
    try mixed().expect("SELECT Id FROM T WHERE N = B", fails: intVsBoolean)
  }
}

// MARK: - Row comparison

/// A row comparison folds componentwise, so an incomparable component pair
/// faults — the same fault on run and validate.
struct RowComparabilityTests {
  @Test func `a cross-kind component faults run and validate`() throws {
    let query = try parse(query: "SELECT Id FROM T WHERE (N, S) = (S, N)")
    #expect(throws: intVsText) { try mixed().columns(of: query) }
    try mixed().expect("SELECT Id FROM T WHERE (N, S) = (S, N)",
                       fails: intVsText)
  }

  @Test func `a like-kind row comparison still compares`() throws {
    // Every component pair is comparable, so the row comparison runs.
    try mixed().expect("SELECT Id FROM T WHERE (N, S) = (10, 'x')",
                       yields: [[1]])
  }

  @Test func `a short-circuited incomparable component faults`() throws {
    // `(N, S) = (999, N)`: the integer first component decides FALSE (no `N` is
    // 999), which used to short-circuit the fold before the incomparable
    // `S`/`N` second was reached — a silent FALSE at run where `Scope.check`
    // already rejected it. The run now preflights every component's
    // comparability, so it faults the same reachable pair validate does.
    let sql = "SELECT Id FROM T WHERE (N, S) = (999, N)"
    let query = try parse(query: sql)
    #expect(throws: textVsInt) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: textVsInt)
  }

  @Test func `an incomparable ordering component faults past a decisive one`()
      throws {
    // The lexicographic cascade `(N, S) < (999, N)`: the integer first
    // component (`N < 999`) is decisive, yet the incomparable `S`/`N` second
    // still makes the whole row comparison ill-typed — it faults on both the
    // run and validate, the same reachable pair.
    let sql = "SELECT Id FROM T WHERE (N, S) < (999, N)"
    let query = try parse(query: sql)
    #expect(throws: textVsInt) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: textVsInt)
  }

  @Test func `a comparable short-circuit still yields the right rows`() throws {
    // The preflight leaves a fully-comparable row byte-for-byte: `(N, S) =
    // (999, 'x')` short-circuits FALSE at the first component (no `N` is 999)
    // and selects nothing, without a fault — the short-circuit is intact.
    try mixed().empty("SELECT Id FROM T WHERE (N, S) = (999, 'x')")
  }
}

// MARK: - Row membership

/// The value-list row `IN` and the row-subquery `IN` paths fold the same
/// componentwise `relate`, so they inherit the preflight: an incomparable
/// component faults even when an earlier one would short-circuit the equality.
struct RowMembershipComparabilityTests {
  @Test func `a cross-kind row IN-list component faults run and validate`()
      throws {
    // `(N, S) IN ((999, N))`: the integer first component decides no-match, but
    // the incomparable `S`/`N` second faults — on the run through `relate` and
    // on validate, which types each element pair (`.among`).
    let sql = "SELECT Id FROM T WHERE (N, S) IN ((999, N))"
    let query = try parse(query: sql)
    #expect(throws: textVsInt) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: textVsInt)
  }

  @Test func `a cross-kind row IN subquery component faults at run`() throws {
    // `(N, S) IN (SELECT 999, Id FROM T)`: the integer first component is FALSE
    // for every subquery row (no `N` is 999), short-circuiting the equality
    // before the incomparable `S`/`Id` second — yet the row subquery folds the
    // same `relate`, so the preflight faults it at run. The static check defers
    // a subquery operand to the run, so it admits it.
    let sql = "SELECT Id FROM T WHERE (N, S) IN (SELECT 999, Id FROM T)"
    try mixed().expect(sql, fails: textVsInt)
    let query = try parse(query: sql)
    _ = try mixed().columns(of: query)
  }
}

// MARK: - Reflexive membership

/// A relation with a nullable integer `N`, to exercise the reflexive
/// short-circuit's NULL-operand exemption on the run.
private func nullable() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer, "N": .integer, "S": .text]) {
      Row(1, 10, "x")
      Row(2, nil, "y")
      Row(3, 30, "z")
    }
  }
}

/// A stateful counter backing a non-deterministic `tick()` routine, so a
/// reflexive `tick()` operand reads a different value at each call.
private final class Counter: @unchecked Sendable {
  private var count = 0

  /// Returns the sequence `1, 2, 3, …` across successive calls — two calls
  /// never agree, so a `tick() = tick()` comparison is FALSE.
  func next() -> Int {
    count += 1
    return count
  }
}

/// A scalar `IN`-list whose reached prefix ends at a reflexive element — the
/// operand itself (`K IN (K, …)`) — never faults the comparability check on a
/// later element, because the run's membership Kleene-OR never faults one: a
/// non-null operand makes `operand = operand` TRUE and short-circuits before a
/// later element is evaluated, and a NULL operand makes every element (this one
/// and each later one) a NULL comparison, UNKNOWN and exempt. So the validate
/// walk stops at the reflexive element, matching the run — while respecting
/// element order, so a cross-kind element reached first still faults.
struct ReflexiveMembershipComparabilityTests {
  @Test func `a reflexive element short-circuits a later cross-kind element`()
      throws {
    // `N IN (N, 'x')`: a non-null `N` matches the reflexive `N` and never
    // reaches the cross-kind `'x'`; a NULL `N` reaches it but compares UNKNOWN
    // (`NULL = 'x'`), never a 42804. So `'x'` is only ever compared to a
    // possibly-NULL `N` — no fault on run or validate, whether or not `N` is
    // provably non-NULL. Every non-null row matches `N = N`, so the run selects
    // them all.
    let sql = "SELECT Id FROM T WHERE N IN (N, 'x')"
    let query = try parse(query: sql)
    _ = try mixed().columns(of: query)
    try mixed().expect(sql, yields: [[1], [2]])
  }

  @Test func `a cross-kind element before the reflexive one still faults`()
      throws {
    // `N IN ('x', N)`: the cross-kind `'x'` is reached first — a non-null `N`
    // faults `N = 'x'` before the reflexive `N`, so it faults 42804 on both
    // the run and validate. The reflexive recognition respects element order.
    let sql = "SELECT Id FROM T WHERE N IN ('x', N)"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: intVsText)
  }

  @Test func `a comparable non-match before a cross-kind element still faults`()
      throws {
    // `N IN (1, 'x')`: `1` is comparable to `N` but not a definite match (no
    // `N` is 1), so the walk reaches the cross-kind `'x'` and faults — the
    // reflexive fix must not over-admit a merely-comparable earlier element.
    let sql = "SELECT Id FROM T WHERE N IN (1, 'x')"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: intVsText)
  }

  @Test func `a NULL operand exempts a later cross-kind element on the run`()
      throws {
    // The soundness crux: a NULL operand makes `NULL IN (NULL, 'x')` UNKNOWN
    // (never a fault), so `N IN (N, 'x')` runs cleanly even over a NULL-`N` row
    // — the row is simply not selected. Only the non-null rows match `N = N`,
    // confirming the reflexive short-circuit never hides a run fault.
    try nullable().expect("SELECT Id FROM T WHERE N IN (N, 'x')",
                          yields: [[1], [3]])
  }

  @Test func `a non-deterministic operand no longer short-circuits, faulting`()
      throws {
    // `tick() IN (tick(), 'x')`: the operand is a non-deterministic routine, so
    // the run evaluates the two `tick()` calls independently — here they
    // disagree (1 then 2), so the reflexive `tick() = tick()` is FALSE and the
    // run reaches the cross-kind `tick() = 'x'` and faults 42804. The stability
    // gate withholds the reflexive short-circuit (a non-deterministic operand
    // is not stable), so the validate walk reaches the same `'x'` and faults
    // too — the run ≡ validate parity the earlier structural-equality shortcut
    // broke by pruning `'x'` while the run faulted on it.
    let counter = Counter()
    let routines = try Routines.standard
        .registering("tick", returns: .integer, deterministic: false) { _ in
          .integer(counter.next())
        }
    let sql = "SELECT Id FROM T WHERE tick() IN (tick(), 'x')"
    let query = try parse(query: sql)
    #expect(throws: intVsText) {
      try mixed().columns(of: query, routines: routines)
    }
    try mixed().expect(sql, fails: intVsText, routines: routines)
  }

  @Test func `a deterministic non-column operand still short-circuits`()
      throws {
    // `N + 1 IN (N + 1, 'x')`: the operand is deterministic though not a bare
    // column, so its two evaluations always agree and the reflexive `N + 1`
    // matches per row — the comparability walk stops there, so the cross-kind
    // `'x'` is only ever compared to a possibly-NULL `N + 1` (UNKNOWN, never
    // 42804) and it type-checks on both paths, every row matching `N + 1 = N +
    // 1`. The gate is stability, not column-only: a column-only gate would
    // wrongly reach and fault `'x'`.
    let sql = "SELECT Id FROM T WHERE N + 1 IN (N + 1, 'x')"
    let query = try parse(query: sql)
    _ = try mixed().columns(of: query)
    try mixed().expect(sql, yields: [[1], [2]])
  }

  @Test func `a nullable reflexive operand no longer prunes a later element`()
      throws {
    // `N IN (N, 1 / 0)` over a nullable `N`: a non-null row short-circuits at
    // the reflexive `N` and never evaluates `1 / 0`, but a NULL row runs past
    // the UNKNOWN `N = N` and evaluates `1 / 0`, which faults. The reflexive
    // short-circuit is only a comparability stop for a not-provably-non-NULL
    // operand, so validate keeps validating the later element and faults the
    // `1 / 0` too — matching the run, which faults on the NULL-`N` row 2. This
    // is the nullable-operand guard: the prune suppressed the divide the
    // run raises.
    let sql = "SELECT Id FROM T WHERE N IN (N, 1 / 0)"
    let query = try parse(query: sql)
    #expect(throws: SQLError.divide) { try nullable().columns(of: query) }
    try nullable().expect(sql, fails: .divide)
  }

  @Test func `a provably non-null reflexive operand still prunes fully`()
      throws {
    // `COALESCE(N, 0) IN (COALESCE(N, 0), 1 / 0)`: the operand is provably
    // non-NULL — `COALESCE(N, 0)` never yields NULL — so `operand = operand` is
    // TRUE on every row and the run short-circuits at the reflexive element,
    // never evaluating `1 / 0`. The `defined` gate recognises this, so validate
    // prunes the whole tail (the `1 / 0` is not validated) and type-checks,
    // matching the run — the optimisation is preserved for a non-NULL operand.
    // Every row matches, so the run selects them all.
    let sql =
        "SELECT Id FROM T WHERE COALESCE(N, 0) IN (COALESCE(N, 0), 1 / 0)"
    let query = try parse(query: sql)
    _ = try nullable().columns(of: query)
    try nullable().expect(sql, yields: [[1], [2], [3]])
  }

  @Test func `a provably non-null reflexive operand prunes a cross-kind tail`()
      throws {
    // `COALESCE(N, 0) IN (COALESCE(N, 0), 'x')`: the provably non-NULL operand
    // short-circuits the reflexive match, so the `'x'` is unreachable
    // — no fault on run or validate, every row matching.
    let sql = "SELECT Id FROM T WHERE COALESCE(N, 0) IN (COALESCE(N, 0), 'x')"
    let query = try parse(query: sql)
    _ = try nullable().columns(of: query)
    try nullable().expect(sql, yields: [[1], [2], [3]])
  }
}

// MARK: - Subquery operands

/// A cross-kind `IN (Q)` or quantified comparison faults at run through
/// `relate`. The static schema check defers to the run for a subquery operand
/// (its single-column type may be a nominal-NULL placeholder), so it does not
/// fault `columns(of:)` — a deliberate soundness choice keeping the run the
/// authority there.
struct SubqueryComparabilityTests {
  @Test func `a cross-kind IN subquery faults at run`() throws {
    try mixed().expect("SELECT Id FROM T WHERE N IN (SELECT Label FROM U)",
                       fails: intVsText)
  }

  @Test func `a cross-kind IN subquery is admitted by the schema check`()
      throws {
    // The static comparability check defers to the run for a subquery operand,
    // so `columns(of:)` resolves the shape without faulting (run stays the
    // authority — no false reject of a `SELECT NULL`-typed subquery).
    let query =
        try parse(query: "SELECT Id FROM T WHERE N IN (SELECT Label FROM U)")
    _ = try mixed().columns(of: query)
  }

  @Test func `a cross-kind quantified comparison faults at run`() throws {
    try mixed().expect("SELECT Id FROM T WHERE N = ANY (SELECT Label FROM U)",
                       fails: intVsText)
  }
}

// MARK: - Join keys

/// Two relations sharing a join column of each kind — `L.N`/`R.M` an integer
/// pair, `L.N`/`R.T` an integer against text (an incomparable cross-kind key),
/// and `R.D` a double (numeric-promotable against `L.N`). Neither relation
/// carries a sort key, so a join over it hashes/buckets rather than seeks —
/// exercising the very fast paths a cross-kind key must still fault through.
private func joinable() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["Id": .integer, "N": .integer, "S": .text]) {
      Row(1, 10, "x")
      Row(2, 20, "y")
    }
    Relation("R", ["Id": .integer, "M": .integer, "T": .text, "D": .double]) {
      Row(1, 10, "10", 20.0)
      Row(2, 99, "z", 10.0)
    }
  }
}

/// A cross-kind equi-join key must fault 42804 at run, not silently drop every
/// row. The optimiser hoists a `col = col` ON equality into a hash/bucket key
/// keyed by each side's value, so an incomparable pair (`L.N = R.T`, an integer
/// against text) hashes to disjoint buckets and no candidate is ever compared —
/// the key is therefore hoisted only when the two columns are comparable, and
/// an incomparable one stays a residual the nested loop evaluates through
/// `matches`, which faults 42804. The schema path (`validate: true`) already
/// faults it, so this restores run ≡ validate on the join key too.
struct JoinComparabilityTests {
  @Test func `a cross-kind inner hash-join key faults run and validate`()
      throws {
    let sql = "SELECT L.Id FROM L JOIN R ON L.N = R.T"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try joinable().columns(of: query) }
    try joinable().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind LEFT bucketed join key faults at run`() throws {
    // The `.left`/`.full` outer join buckets the right side by its key, so a
    // cross-kind key would bucket the two sides apart and NULL-extend every
    // left row silently; leaving it a residual routes it through the nested
    // loop's per-pair `matches`, which faults.
    try joinable().expect("SELECT L.Id FROM L LEFT JOIN R ON L.N = R.T",
                          fails: intVsText)
  }

  @Test func `a cross-kind FULL bucketed join key faults at run`() throws {
    try joinable().expect("SELECT L.Id FROM L FULL JOIN R ON L.N = R.T",
                          fails: intVsText)
  }

  @Test func `a cross-kind RIGHT join key faults at run`() throws {
    try joinable().expect("SELECT L.Id FROM L RIGHT JOIN R ON L.N = R.T",
                          fails: intVsText)
  }

  @Test func `a same-kind inner hash join still matches`() throws {
    // A comparable key is still hoisted and hashed — `L.N = R.M` pairs `L.N`
    // 10 with `R.M` 10 (`L.Id` 1) and leaves `L.N` 20 unmatched.
    try joinable().expect("SELECT L.Id FROM L JOIN R ON L.N = R.M",
                          yields: [[1]])
  }

  @Test func `a numeric int-double hash join still matches by magnitude`()
      throws {
    // The hash bucket promotes an integer to its double magnitude, so `L.N =
    // R.D` matches 10 to 10.0 and 20 to 20.0 — both left rows pair.
    try joinable().expect("SELECT L.Id FROM L JOIN R ON L.N = R.D",
                          yields: [[1], [2]])
  }

  @Test func `a same-kind LEFT bucketed join still preserves and matches`()
      throws {
    // The comparable-key bucketed fast path is intact: `L.N` 10 matches, `L.N`
    // 20 has no `R.M` 20 and is NULL-extended — `L.Id` still emitted for both.
    try joinable().expect("SELECT L.Id FROM L LEFT JOIN R ON L.N = R.M",
                          yields: [[1], [2]])
  }
}

// MARK: - Preserved behaviour

/// The change touches only cross-kind non-null comparisons: NULL stays UNKNOWN,
/// numeric integer/double promotion stays comparable, and `IS DISTINCT FROM`
/// (the null-safe comparison) stays total — never a fault.
struct ComparabilityPreservedTests {
  @Test func `a comparison against NULL stays UNKNOWN, never a fault`()
      throws {
    // `S = NULL` is UNKNOWN for every row (a constant-NULL operand is exempt),
    // so it selects no rows and faults neither the run nor the schema check.
    let query = try parse(query: "SELECT Id FROM T WHERE S = NULL")
    _ = try mixed().columns(of: query)
    try mixed().empty("SELECT Id FROM T WHERE S = NULL")
  }

  @Test func `numeric integer and double promotion still compares`() throws {
    // An integer against a double is numeric, not cross-kind, so it compares by
    // magnitude — `N = D` and `N = 1.0` both run and type-check cleanly.
    let query = try parse(query: "SELECT Id FROM T WHERE N = D")
    _ = try mixed().columns(of: query)
    try mixed().expect("SELECT Id FROM T WHERE N = 10.0", yields: [[1]])
  }

  @Test func `IS DISTINCT FROM stays total across kinds`() throws {
    // The null-safe comparison treats a cross-kind pair as DISTINCT without
    // faulting (unlike a bare comparison), so `N IS DISTINCT FROM S` keeps
    // every row and faults neither the run nor the schema check.
    let query = try parse(query: "SELECT Id FROM T WHERE N IS DISTINCT FROM S")
    _ = try mixed().columns(of: query)
    try mixed().expect("SELECT Id FROM T WHERE N IS DISTINCT FROM S",
                       yields: [[1], [2]])
  }

  @Test func `a genuine boolean predicand still filters`() throws {
    // `WHERE B` desugars to `B = TRUE` — a like-kind boolean comparison — so a
    // genuine boolean predicand still works where a non-boolean one faults.
    try mixed().expect("SELECT Id FROM T WHERE B", yields: [[1]])
  }
}

// MARK: - Optimiser safety

/// A two-relation join fixture for the ON-key-hoist hazard. `L.N` and `R.M` are
/// comparable integers that share no value, so a hash key on `L.N = R.M` drops
/// every candidate pair; `R.K` is an integer that matches `L.N` row for row
/// (a comparable key that pairs both rows); and `R.T` is text — so `L.N = R.T`
/// and `L.N LIKE R.T` are cross-kind. `L` and `R` are both non-empty, so the
/// product `L × R` a barred key falls back to is non-empty and its residual is
/// reached.
private func bucketed() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["Id": .integer, "N": .integer]) {
      Row(1, 1)
      Row(2, 2)
    }
    Relation("R", ["M": .integer, "K": .integer, "T": .text]) {
      Row(8, 1, "a")
      Row(9, 2, "b")
    }
  }
}

/// The non-character `LIKE` fault, raised identically by the run's `like` and
/// the validate path's `character`.
private let likeNonText =
    SQLError.state("42804", "LIKE requires character operands")

/// Whether `plan` reaches a `.join` — a hash join formed when an `ON` yields an
/// extractable equi key, the observable sign the safety gate hoisted a key.
private func joins(_ plan: Plan) -> Bool {
  switch plan {
  case .join: true
  case let .select(_, source): joins(source)
  case let .project(_, source): joins(source)
  case let .sort(_, source): joins(source)
  case let .limit(_, _, source): joins(source)
  case let .distinct(source): joins(source)
  case let .aggregate(_, _, source): joins(source)
  case let .derived(_, sub, _, _): joins(sub)
  case let .product(left, right): joins(left) || joins(right)
  case let .outer(left, right, _, _): joins(left) || joins(right)
  case let .semijoin(left, right, _, _): joins(left) || joins(right)
  case let .apply(left, _, _, _, _, _): joins(left)
  case let .setop(_, left, right, _, _, _): joins(left) || joins(right)
  case .single, .empty, .scan: false
  }
}

/// Whether `plan` reaches a `.select` standing directly over a `.product` — the
/// residual-product a join forms when the safety gate bars key extraction, so
/// the whole `ON` is evaluated per pair.
private func residual(_ plan: Plan) -> Bool {
  switch plan {
  case .select(_, .product): true
  case let .select(_, source): residual(source)
  case let .project(_, source): residual(source)
  case let .sort(_, source): residual(source)
  case let .limit(_, _, source): residual(source)
  case let .distinct(source): residual(source)
  case let .aggregate(_, _, source): residual(source)
  case let .derived(_, sub, _, _): residual(sub)
  case let .product(left, right): residual(left) || residual(right)
  case let .join(outer, _, _, _, _, _, _): residual(outer)
  case let .outer(left, right, _, _): residual(left) || residual(right)
  case let .semijoin(left, right, _, _): residual(left) || residual(right)
  case let .apply(left, _, _, _, _, _): residual(left)
  case let .setop(_, left, right, _, _, _): residual(left) || residual(right)
  case .single, .empty, .scan: false
  }
}

/// A comparison that can fault 42804 must be classified unsafe for the
/// optimiser, so a comparable equi key elsewhere in the same `ON` cannot be
/// hoisted into a hash bucket that drops every candidate pair before the
/// throwing residual is reached — the bypass would silently return no rows
/// where both the nested-loop run and the validate path fault. The gate is
/// type-aware: a provably-comparable `ON` still hash-joins.
struct OptimiserComparabilitySafetyTests {
  @Test
  func `a cross-kind residual faults though a comparable key drops all pairs`()
      throws {
    // `ON L.N = R.T AND L.N = R.M`: `N = M` is a comparable integer key with no
    // matching pair. Hoisting it would bucket every pair away before the
    // cross-kind `N = T` residual ran, returning no rows; instead the whole ON
    // stays a residual and `N = T` faults 42804 on both the run and validate.
    let sql = "SELECT L.Id FROM L JOIN R ON L.N = R.T AND L.N = R.M"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try bucketed().columns(of: query) }
    try bucketed().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind ON conjunct bars key extraction`() throws {
    // The plan-level consequence of the fix: no `.join` is formed and the level
    // is a residual `.select` over the `.product`, so the whole `ON` runs per
    // pair rather than a hash key dropping the pairs first.
    let sql = "SELECT L.Id FROM L JOIN R ON L.N = R.T AND L.N = R.M"
    let compiled = try bucketed().compile(parse(query: sql))
    let plan = try bucketed().optimise(compiled.pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `a cross-kind conjunct bars key extraction regardless of order`()
      throws {
    // The gate rejects the whole ON whichever conjunct comes first: with the
    // comparable key ahead of the cross-kind residual, no `.join` is still
    // formed. (The run's fault is then data-dependent — the definite-false
    // integer `N = M` short-circuits the Kleene `AND` per pair before the
    // cross-kind `N = T` is reached, exactly as the nested loop would, so only
    // the conservative validate path faults here; the optimiser safety this
    // test pins is order-independent.)
    let sql = "SELECT L.Id FROM L JOIN R ON L.N = R.M AND L.N = R.T"
    let compiled = try bucketed().compile(parse(query: sql))
    let plan = try bucketed().optimise(compiled.pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
    #expect(throws: intVsText) { try bucketed().columns(of: parse(query: sql)) }
  }

  @Test
  func `a cross-kind LIKE residual faults though a comparable key drops pairs`()
      throws {
    // `ON L.N LIKE R.T AND L.N = R.M`: the integer-subject LIKE faults 42804,
    // so it too must bar the comparable `N = M` key from bucketing pairs away.
    let sql = "SELECT L.Id FROM L JOIN R ON L.N LIKE R.T AND L.N = R.M"
    let query = try parse(query: sql)
    #expect(throws: likeNonText) { try bucketed().columns(of: query) }
    try bucketed().expect(sql, fails: likeNonText)
  }

  @Test func `a cross-kind LIKE ON conjunct bars key extraction`() throws {
    let sql = "SELECT L.Id FROM L JOIN R ON L.N LIKE R.T AND L.N = R.M"
    let compiled = try bucketed().compile(parse(query: sql))
    let plan = try bucketed().optimise(compiled.pushdown(), [:])
    #expect(!joins(plan))
    #expect(residual(plan))
  }

  @Test func `a comparable equi-join still hash-joins and matches`() throws {
    // Every operand is an integer, so the gate leaves the key hoistable: the
    // plan reaches a `.join`, and `L.N = R.K` pairs each row (1↔1, 2↔2). A
    // perf-defeating over-classification would force a nested-loop residual.
    let sql = "SELECT L.Id FROM L JOIN R ON L.N = R.K"
    let compiled = try bucketed().compile(parse(query: sql))
    let plan = try bucketed().optimise(compiled.pushdown(), [:])
    #expect(joins(plan))
    #expect(!residual(plan))
    try bucketed().expect(sql, yields: [[1], [2]])
  }

  @Test func `a comparable multi-conjunct ON still hoists a key`() throws {
    // Two comparable conjuncts (`L.N = R.K AND L.N = R.M`, all integer): the
    // gate classifies both comparable, so a key is still hoisted — the fix does
    // not fall back to a nested-loop residual when nothing can fault.
    let sql = "SELECT L.Id FROM L JOIN R ON L.N = R.K AND L.N = R.M"
    let compiled = try bucketed().compile(parse(query: sql))
    let plan = try bucketed().optimise(compiled.pushdown(), [:])
    #expect(joins(plan))
  }
}

// MARK: - Row-comparison evaluation order

/// A row comparison and a row `IN` evaluate every component of a side before
/// `relate` compares any pair, so a component's own evaluation fault surfaces
/// ahead of an incomparable pair's 42804. The validate path validates both rows
/// in that same order before its comparability pass, so run ≡ validate on which
/// fault a mixed row raises first.
struct RowOrderComparabilityTests {
  @Test func `a left-row divide preempts the incomparable first pair`() throws {
    // The run builds the whole left row `(1, 1 / 0)` before comparing, dividing
    // by zero before the incomparable `1`/`'x'` pair is reached, so it faults
    // the divide — and validate now matches, validating the left row through
    // its `1 / 0` before the comparability pass rather than faulting 42804 on
    // component 0.
    let sql = "SELECT Id FROM T WHERE (1, 1 / 0) = ('x', 2)"
    let query = try parse(query: sql)
    #expect(throws: SQLError.divide) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: .divide)
  }

  @Test func `a right-row divide preempts an incomparable first pair`() throws {
    // The incomparable pair is at component 0, but the run evaluates the whole
    // right row `(1, 1 / 0)` — dividing — before `relate` compares, faulting
    // the divide. Validate validates all of the left row then all of the right,
    // hitting the `1 / 0` before the comparability pass, matching the run.
    let sql = "SELECT Id FROM T WHERE ('x', 2) = (1, 1 / 0)"
    let query = try parse(query: sql)
    #expect(throws: SQLError.divide) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: .divide)
  }

  @Test func `a row-IN element divide preempts an incomparable pair`() throws {
    // `(N, N) IN (('x', 1 / 0))`: the run builds the whole element row before
    // `relate` compares it, dividing by zero before the incomparable `N`/`'x'`
    // pair is reached. Validate validates every element component before its
    // comparability pass, so it too faults the divide, not 42804.
    let sql = "SELECT Id FROM T WHERE (N, N) IN (('x', 1 / 0))"
    let query = try parse(query: sql)
    #expect(throws: SQLError.divide) { try mixed().columns(of: query) }
    try mixed().expect(sql, fails: .divide)
  }

  @Test func `a comparable mixed row still compares componentwise`() throws {
    // The reorder does not change a comparable row's outcome: `(N, D) = (10,
    // 1.0)` compares integer/integer and double/double, matching row 1.
    try mixed().expect("SELECT Id FROM T WHERE (N, D) = (10, 1.0)",
                       yields: [[1]])
  }
}
