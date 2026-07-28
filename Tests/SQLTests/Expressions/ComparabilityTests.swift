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

// MARK: - Compile-time comparability

/// The run's comparability determination is a static data-type rule, so it
/// faults a reachable cross-kind comparison at compile regardless of table
/// cardinality — including over an empty input the run would otherwise return
/// empty for, and before the optimiser can hash, reorder, or drop a comparison
/// that would else throw. `check` (`validate: true`) already faults each of
/// these, so the run's compile-time walk restores run ≡ validate where the
/// run's per-row `matches` never fired.
private func partitioned() throws -> FixtureCatalog {
  try Catalog {
    // A is non-empty, E is empty — so a cross-kind comparison over E is never
    // reached by the run's per-row evaluation, the silent hole.
    Relation("A", ["num": .integer, "txt": .text]) {
      Row(1, "x")
      Row(2, "y")
    }
    Relation("E", ["num": .integer, "txt": .text]) { }
  }
}

struct EmptyInputComparabilityTests {
  @Test func `a cross-kind WHERE over an empty table faults at compile`()
      throws {
    // The run never evaluates the WHERE over zero rows, so `matches` never
    // faults — the compile-time comparability check must, matching validate.
    let sql = "SELECT num FROM E WHERE E.num = E.txt"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind key pushed below an empty product faults`() throws {
    // `A CROSS JOIN E` with E empty yields no rows, so a WHERE the pushdown
    // sinks below the product (`E.num = E.txt`, single-relation over the empty
    // side) is never evaluated — the compile check faults it regardless.
    let sql = "SELECT A.num FROM A CROSS JOIN E WHERE E.num = E.txt"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind under a constant-false fold faults`() throws {
    // `WHERE 1 = 0` folds the derived source to empty, so its body's cross-kind
    // is never run — the compile-time walk reaches into the derived body and
    // faults it before the fold can drop the faulting source.
    let sql = """
        SELECT * FROM (SELECT * FROM E WHERE E.num = E.txt) t WHERE 1 = 0
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind in a body over an empty table faults`() throws {
    // The derived body materialises over an empty `E` — no row reaches its
    // WHERE at run — so only the compile-time walk over the body faults it.
    let sql = "SELECT * FROM (SELECT * FROM E WHERE E.num = E.txt) t"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `an unreachable cross-kind still does not fault`() throws {
    // `1 = 0 AND …` short-circuits, so its cross-kind leg is not reached —
    // the comparability walk is reachability-aware and defers it, exactly as
    // the run and validate both do (`A` is non-empty, so a reached fault would
    // surface).
    let sql = "SELECT num FROM A WHERE 1 = 0 AND A.num = A.txt"
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }

  @Test func `a reachable comparable query over an empty input still runs`()
      throws {
    // The compile check faults only a cross-kind pair, so a same-kind
    // comparison over the empty `E` still runs to its (empty) result.
    try partitioned().empty("SELECT num FROM E WHERE E.num = 1")
  }
}

// MARK: - Compile-time comparability: reflexive membership

/// The compile-time finder carries the reflexive short-circuit and its
/// nullable-operand guard. Over the empty `E` the run's per-row `member` never
/// fires, so only the finder catches a cross-kind comparison a later `IN`
/// element carries — and a nullable reflexive operand must not prune the
/// finder's recursion into those later elements (a NULL row reaches and
/// evaluates them), while a provably non-NULL operand still prunes the tail.
struct ReflexiveMembershipFinderTests {
  @Test func `a nullable reflexive operand recurses a nested cross-kind`()
      throws {
    // `E.num IN (E.num, CASE WHEN E.num = E.txt THEN 1 END)` over empty `E`:
    // the reflexive `E.num` is nullable (no NOT NULL flag), so the finder
    // recurses the later `CASE` and faults its cross-kind guard `E.num = E.txt`
    // (integer vs text) at compile — the run reaches it on a NULL-`E.num` row,
    // and over the empty `E` only the finder can. The prune stopped at the
    // reflexive element and missed it.
    let sql = """
        SELECT num FROM E \
        WHERE E.num IN (E.num, CASE WHEN E.num = E.txt THEN 1 END)
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a provably non-null reflexive operand still prunes the tail`()
      throws {
    // The operand `COALESCE(E.num, 0)` is provably non-NULL, so `operand =
    // operand` is TRUE on every row and the run short-circuits at the reflexive
    // element, never reaching the `CASE`. The `defined` gate prunes the whole
    // tail, so the nested cross-kind is unreachable — no fault, matching the
    // run (empty over the empty `E`).
    let sql = """
        SELECT num FROM E WHERE COALESCE(E.num, 0) \
        IN (COALESCE(E.num, 0), CASE WHEN E.num = E.txt THEN 1 END)
        """
    let query = try parse(query: sql)
    _ = try partitioned().columns(of: query)
    try partitioned().empty(sql)
  }
}

// MARK: - Compile-time comparability: projection, grouping, sort

/// A cross-kind comparison hidden in a projection, `GROUP BY` key, `ORDER BY`
/// sort key, or aggregate `FILTER` is a surface the run never evaluates over an
/// empty input — the projection is not computed, the fold sees no row — yet
/// `columns(of: validate:)` faults each. The compile-time comparability walk
/// now visits every such surface, restoring run ≡ validate where the per-row
/// `matches` never fired.
struct ProjectionComparabilityTests {
  @Test func `a projection NULLIF cross-kind pair faults at compile`() throws {
    // `NULLIF(v1, v2)` desugars to `v1 = v2`; over an empty `E` the projection
    // is never evaluated, so only the compile walk faults it, like validate.
    let sql = "SELECT NULLIF(E.num, E.txt) FROM E"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a projection CASE guard cross-kind pair faults at compile`()
      throws {
    let sql = "SELECT CASE WHEN E.num = E.txt THEN 1 ELSE 0 END FROM E"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `an aggregate FILTER cross-kind pair faults at compile`() throws {
    // The `FILTER (WHERE …)` gate is validated unconditionally, so a cross-kind
    // gate over the empty group a whole-result aggregate folds faults.
    let sql = "SELECT COUNT(*) FILTER (WHERE E.num = E.txt) FROM E"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a GROUP BY key cross-kind pair faults at compile`() throws {
    let sql = "SELECT COUNT(*) FROM E GROUP BY NULLIF(E.num, E.txt)"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `an ORDER BY key cross-kind pair faults at compile`() throws {
    // The sort key is evaluated below any limit, so its comparison is checked
    // unconditionally; over the empty `E` the sort runs no key at run.
    let sql = "SELECT E.num FROM E ORDER BY NULLIF(E.num, E.txt)"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a same-kind projection NULLIF still runs over an empty input`()
      throws {
    // A comparable NULLIF is not faulted, so the query runs to its empty
    // result.
    let sql = "SELECT NULLIF(E.num, 1) FROM E"
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }

  @Test func `a NULL-guarded projection CASE stays UNKNOWN, never a fault`()
      throws {
    // `E.txt = NULL` is a constant-NULL comparison, exempt, so the CASE guard
    // faults neither the run nor validate.
    let sql = "SELECT CASE WHEN E.txt = NULL THEN 1 ELSE 0 END FROM E"
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }

  @Test func `an unreachable projection under a false WHERE does not fault`()
      throws {
    // A projection under a constant-false WHERE is unreachable, so its
    // cross-kind NULLIF is not checked — the query runs to its empty result
    // even over the non-empty `A`, exactly as validate accepts it.
    let sql = "SELECT NULLIF(A.num, A.txt) FROM A WHERE 1 = 0"
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }
}

// MARK: - Compile-time comparability: HAVING aggregates

/// A `HAVING` aggregate is collected and folded by the group node before the
/// filter predicate runs, so its operand and `FILTER` comparisons are evaluated
/// unconditionally — an enclosing `AND`/`OR` short-circuit that leaves the
/// aggregate's own comparison unreachable does not spare the fold. The strict
/// validate walk checks every `HAVING` aggregate through `aggregates(in:)`
/// regardless of the predicate's reachability, so the run's comparability walk
/// must too (`comparisons(aggregatesIn:)`), ahead of its reachability-aware
/// scalar walk — else a cross-kind `HAVING 1 = 0 AND SUM(NULLIF(int, text))`
/// silently returns empty on the run while validate faults it (`run ≡
/// validate`). The internal reachability of the aggregate's own operand still
/// prunes (a `CASE` arm the guard makes dead is never folded), so the
/// unconditional check must not over-fault an unreachable operand comparison.
struct HavingAggregateComparabilityTests {
  @Test func `a grouped HAVING aggregate behind a false AND faults at compile`()
      throws {
    // `1 = 0 AND SUM(…)`: the reachability walk prunes the `SUM(…) > 0` leg,
    // but the group node folds `SUM(NULLIF(E.num, E.txt))` before the filter —
    // the cross-kind operand faults 42804 on both paths over the empty group.
    let sql = """
        SELECT COUNT(*) FROM E GROUP BY E.num \
        HAVING 1 = 0 AND SUM(NULLIF(E.num, E.txt)) > 0
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a grouped HAVING aggregate behind a true OR faults at compile`()
      throws {
    // `1 = 1 OR SUM(…)`: the reachability walk prunes the OR's right leg, but
    // the aggregate still folds before the filter, so its cross-kind operand
    // faults on both paths.
    let sql = """
        SELECT COUNT(*) FROM E GROUP BY E.num \
        HAVING 1 = 1 OR SUM(NULLIF(E.num, E.txt)) > 0
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a whole-result HAVING aggregate behind a short-circuit faults`()
      throws {
    // No GROUP BY: the whole-result aggregate emits one empty group whose
    // HAVING folds its `SUM` before the filter, so the short-circuited
    // cross-kind operand faults on both paths.
    let sql = """
        SELECT COUNT(*) FROM E \
        HAVING 1 = 0 AND SUM(NULLIF(E.num, E.txt)) > 0
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a HAVING aggregate FILTER behind a short-circuit faults`()
      throws {
    // The `FILTER (WHERE …)` gate is evaluated as the aggregate folds, before
    // the filter predicate, so a cross-kind gate under a short-circuited HAVING
    // leg faults on both paths.
    let sql = """
        SELECT COUNT(*) FROM E GROUP BY E.num \
        HAVING 1 = 0 AND COUNT(*) FILTER (WHERE E.num = E.txt) > 0
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a same-kind HAVING aggregate behind a short-circuit still runs`()
      throws {
    // The control: a comparable `SUM(NULLIF(E.num, 1))` operand is not faulted,
    // so the short-circuited HAVING runs to the empty result on both paths.
    let sql = """
        SELECT COUNT(*) FROM E GROUP BY E.num \
        HAVING 1 = 0 AND SUM(NULLIF(E.num, 1)) > 0
        """
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }

  @Test func `an unreachable HAVING aggregate operand does not over-fault`()
      throws {
    // The aggregate's own operand short-circuits internally: the executor never
    // folds the `CASE`'s dead `NULLIF` arm, so neither the run's `aggregatesIn`
    // walk (which delegates to the reachability-aware `comparisons(in:)` at the
    // aggregate) nor validate's `aggregates(in:)` faults it — the unconditional
    // HAVING-aggregate check must not over-fault an unreachable operand.
    let sql = """
        SELECT COUNT(*) FROM E GROUP BY E.num \
        HAVING SUM(CASE WHEN 1 = 0 THEN NULLIF(E.num, E.txt) ELSE 0 END) > 0
        """
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }
}

// MARK: - Per-site deferred-error suppression

/// The comparability walk swallows a deferred non-comparability fault (an
/// ill-typed arithmetic operand, an unknown routine, a bad arity) per site and
/// continues, so it reaches every later comparison surface regardless of where
/// such a fault sits — a single enclosing catch would let the first deferred
/// fault abort the walk before a later incomparable comparison was checked. The
/// run enforces only the ISO comparability rule (42804); every other operand
/// fault stays deferred to execution, exactly as before. Validate stays
/// stricter — its strict walk reports the first fault it reaches, an arithmetic
/// `.operand` among them — a pre-existing, out-of-scope divergence; the point
/// here is that the run no longer silently returns empty past a deferred fault.
struct DeferredFaultComparabilityTests {
  @Test func `a deferred projection fault does not hide a later comparison`()
      throws {
    // The reviewer's case, arithmetic-first: `E.txt + 1` is an ill-typed
    // arithmetic operand the run defers, so the walk swallows it per site and
    // continues to `NULLIF(E.num, E.txt)` — an integer/text comparison — which
    // faults 42804 at run over the empty `E`, where the old single enclosing
    // catch returned silently. Validate's strict walk faults the arithmetic
    // first (`.operand`), so it rejects the query too, just with the stricter
    // code — an unchanged, out-of-scope divergence.
    let sql = "SELECT E.txt + 1, NULLIF(E.num, E.txt) FROM E"
    try partitioned().expect(sql, fails: intVsText)
    #expect(throws: SQLError.self) {
      try partitioned().columns(of: parse(query: sql))
    }
  }

  @Test func `the comparison-first order faults 42804 on both paths`() throws {
    // With the comparison first, both walks reach it before the arithmetic: the
    // run's comparability walk faults 42804 at the first projection item, and
    // the strict validate walk faults the same 42804 as its first fault.
    let sql = "SELECT NULLIF(E.num, E.txt), E.txt + 1 FROM E"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a WHERE comparison faults past a deferred projection fault`()
      throws {
    // A cross-kind comparison in the WHERE coexists with an ill-typed
    // arithmetic projection: both walks visit the WHERE first, so it faults
    // 42804 on both the run and validate — the deferred projection fault never
    // masks it.
    let sql = "SELECT E.txt + 1 FROM E WHERE E.num = E.txt"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `an ORDER BY comparison faults past a deferred projection fault`()
      throws {
    // The projection is visited before the sort keys, so the ill-typed
    // `E.txt + 1` projection is swallowed per site, so the walk continues to
    // the cross-kind `ORDER BY NULLIF(E.num, E.txt)` sort key — faulting 42804
    // at run over the empty `E`, the definitive cross-clause per-site case.
    let sql = "SELECT E.txt + 1 FROM E ORDER BY NULLIF(E.num, E.txt)"
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a deferred fault with no comparison does not fault the walk`()
      throws {
    // Only a 42804 escapes the comparability walk: an arithmetic operand fault
    // with no incomparable comparison anywhere stays deferred to the run, which
    // returns its (empty) result over `E`. Validate stays stricter and faults
    // the arithmetic — the pre-existing, out-of-scope divergence.
    let sql = "SELECT E.txt + 1 FROM E"
    try partitioned().empty(sql)
    #expect(throws: SQLError.self) {
      try partitioned().columns(of: parse(query: sql))
    }
  }
}

// MARK: - Compile-time comparability: subquery bodies

/// A cross-kind comparison in the body of a reached `EXISTS`/`IN (Q)`/scalar
/// subquery is never faulted at run when its uncorrelated body does not
/// materialise over an empty outer — the per-row `matches` never fires — yet
/// the schema path recursively type-checks the body and faults it. The compile
/// walk now recurses into each reached body the same way, closing that hole,
/// while an unreached body (a short-circuited leg's subquery) still defers.
struct SubqueryBodyComparabilityTests {
  @Test func `a reached EXISTS body cross-kind faults at compile`() throws {
    // `E` is empty, so the EXISTS is never evaluated and its uncorrelated body
    // over `A` never materialises — only the compile walk, recursing into the
    // body, faults it, matching validate.
    let sql =
        "SELECT E.num FROM E WHERE EXISTS (SELECT 1 FROM A WHERE A.num = A.txt)"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a reached IN subquery body cross-kind pair faults at compile`()
      throws {
    let sql = """
        SELECT E.num FROM E \
        WHERE E.num IN (SELECT A.num FROM A WHERE A.num = A.txt)
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a reached scalar subquery body cross-kind pair faults`() throws {
    let sql = """
        SELECT E.num FROM E \
        WHERE E.num = (SELECT A.num FROM A WHERE A.num = A.txt)
        """
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `an unreachable EXISTS body under a false leg does not fault`()
      throws {
    // `1 = 0 AND EXISTS (…)` short-circuits, so the EXISTS body is never
    // reached — the walk records no reach, so its cross-kind body defers,
    // exactly as the run and validate both do (`A` is non-empty, so a reached
    // fault would surface).
    let sql = """
        SELECT A.num FROM A \
        WHERE 1 = 0 AND EXISTS (SELECT 1 FROM E WHERE E.num = E.txt)
        """
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }
}

// MARK: - Compile-time comparability: CTE bodies

/// A cross-kind comparison in a reachable `WITH` body faults at compile on both
/// paths: the run materialises each CTE through the same `run` (hence the same
/// compile-time comparability walk) the trailing query drives, and the schema
/// path (`columns(of:)`) type-checks each CTE body — so a cross-kind body over
/// an empty input, which the CTE's own per-row `matches` never reaches, still
/// faults, keeping run ≡ validate.
struct CTEBodyComparabilityTests {
  @Test func `a cross-kind WITH body faults at run and validate`() throws {
    let sql = """
        WITH c AS (SELECT E.num FROM E WHERE E.num = E.txt) SELECT * FROM c
        """
    let statement = try Statement(parsing: sql)
    #expect(throws: intVsText) { try partitioned().columns(of: statement) }
    #expect(throws: intVsText) { _ = try partitioned().run(statement) }
  }
}

// MARK: - Compile-time comparability: stored-view bodies

/// A stored VIEW registered by name is executed on the run path as an
/// already-compiled plan (`validate: false`), so its body's comparisons were
/// never comparability-checked and the outer query's walk treated the view as
/// an opaque relation. A cross-kind comparison in a view body over an empty
/// input therefore returned no rows on the run while the schema path
/// (`columns(of:)`) faulted the body — the same run ≠ validate hole the
/// derived-table recursion closes. The comparability walk now descends into
/// each reached view's body, transitively, restoring run ≡ validate.
///
/// `V`'s body compares an integer against text over an empty `E`; `Same`'s
/// body is a like-kind comparison over the non-empty `A`; `Nested` names `V`,
/// so a walk that descends must reach `V`'s cross-kind pair through it.
private func viewed() throws -> FixtureCatalog {
  try Catalog {
    Relation("A", ["num": .integer, "txt": .text]) {
      Row(1, "x")
      Row(2, "y")
    }
    Relation("E", ["num": .integer, "txt": .text]) { }
    try View("V", "SELECT num FROM E WHERE num = txt", as: ["num"])
    try View("Same", "SELECT num FROM A WHERE num = 1", as: ["num"])
    try View("Nested", "SELECT num FROM V", as: ["num"])
  }
}

struct ViewBodyComparabilityTests {
  @Test func `a cross-kind stored-view body faults at run and validate`()
      throws {
    // `SELECT * FROM V` executes `V`'s compiled plan over the empty `E`, so its
    // `num = txt` never reaches `matches` — only the walk descending into the
    // body faults it, matching the schema path.
    let sql = "SELECT * FROM V"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try viewed().columns(of: query) }
    try viewed().expect(sql, fails: intVsText)
  }

  @Test func `a cross-kind view body faults transitively through a view`()
      throws {
    // `Nested` names `V`, so the descent must recurse through `Nested`'s body
    // into `V`'s to reach the cross-kind pair.
    let sql = "SELECT * FROM Nested"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try viewed().columns(of: query) }
    try viewed().expect(sql, fails: intVsText)
  }

  @Test func `a view named in a reached subquery body faults at compile`()
      throws {
    // The EXISTS is reached (a bare `WHERE EXISTS`), so its body's `FROM V`
    // is walked and `V`'s cross-kind pair faults, exactly as a cross-kind pair
    // written directly in the subquery body would.
    let sql = "SELECT num FROM A WHERE EXISTS (SELECT 1 FROM V)"
    let query = try parse(query: sql)
    #expect(throws: intVsText) { try viewed().columns(of: query) }
    try viewed().expect(sql, fails: intVsText)
  }

  @Test func `a view under an unreachable branch does not fault`() throws {
    // `1 = 0 AND EXISTS (…)` short-circuits, so the EXISTS body is never
    // reached and its `FROM V` is never walked — the cross-kind body defers,
    // exactly as a directly-written unreachable cross-kind pair does. `A` is
    // non-empty, so a spurious descent would surface `V`'s fault.
    let sql =
        "SELECT num FROM A WHERE 1 = 0 AND EXISTS (SELECT 1 FROM V)"
    _ = try viewed().columns(of: parse(query: sql))
    try viewed().empty(sql)
  }

  @Test func `a same-kind view body still resolves and yields its rows`()
      throws {
    // `Same`'s body is a like-kind comparison, so the descent faults nothing
    // and the view runs — `num = 1` selects `A`'s first row.
    try viewed().expect("SELECT num FROM Same", yields: [[1]])
  }
}

// MARK: - Compile-time comparability: defined-function bodies

/// A `CREATE FUNCTION` scalar body is validated once at registration
/// (`Routine.init` runs the full `Scope.validate` walk, whose `check`/`nullif`
/// apply the comparability rule unconditionally), so a cross-kind comparison in
/// a reachable part of the body faults 42804 eagerly at definition time — it is
/// not a `validate: false`-deferred run-path surface. These lock that in.
private func define(_ definition: String) throws -> Routines {
  guard case let .function(name, function) = try Statement(parsing: definition)
  else {
    throw SQLError.incomplete(expected: "a CREATE FUNCTION statement")
  }
  return try Routines.standard.registering(name, function)
}

struct DefinedFunctionComparabilityTests {
  @Test func `a cross-kind comparison in a function body faults at definition`()
      throws {
    // `a = b` compares the integer parameter against the text one — a data-type
    // mismatch the registration-time body validation faults, before any call.
    #expect(throws: intVsText) {
      _ = try define("CREATE FUNCTION cmp(a INTEGER, b VARCHAR) RETURNS "
                         + "INTEGER AS CASE WHEN a = b THEN 1 ELSE 0 END")
    }
  }

  @Test func `a same-kind comparison in a function body defines and runs`()
      throws {
    // A like-kind guard defines cleanly; `cmp(N, N)` is TRUE for every row, so
    // the projection yields `1` for both of `T`'s rows.
    let routines =
        try define("CREATE FUNCTION cmp(a INTEGER, b INTEGER) "
                       + "RETURNS INTEGER AS CASE WHEN a = b THEN 1 ELSE 0 END")
    try mixed().expect("SELECT cmp(N, N) FROM T", yields: [[1], [1]],
                       routines: routines)
  }
}

// MARK: - Decorrelation comparability

/// A correlated subquery whose key equates a cross-kind pair (`R.name =
/// L.age`, text against integer) must fault 42804 at run, not decorrelate into
/// a hash/semijoin that buckets the two sides apart and silently drops every
/// row. The decorrelation producer gates the `.match` hoist on the same
/// `ValueType.unified` notion the run's `matches` and validate's `comparable`
/// use: a cross-kind key bails the rewrite, leaving the correlated select to
/// fault through `matches`; a comparable one still decorrelates.
private func correlated() throws -> FixtureCatalog {
  try Catalog {
    Relation("L", ["Id": .integer, "age": .integer]) {
      Row(1, 10)
      Row(2, 20)
    }
    Relation("R", ["Id": .integer, "name": .text, "m": .integer]) {
      Row(1, "10", 10)
      Row(2, "z", 99)
    }
  }
}

struct DecorrelationComparabilityTests {
  @Test func `a cross-kind correlated EXISTS faults at run and validate`()
      throws {
    let sql =
        "SELECT L.Id FROM L WHERE EXISTS (SELECT 1 FROM R WHERE R.name = L.age)"
    let query = try parse(query: sql)
    #expect(throws: textVsInt) { try correlated().columns(of: query) }
    try correlated().expect(sql, fails: textVsInt)
  }

  @Test func `a cross-kind correlated IN faults at run`() throws {
    // `L.age IN (SELECT R.name …)` lifts to a semijoin whose key would bucket
    // integer against text apart; the gate leaves it to fault through
    // `matches`.
    try correlated().expect(
        "SELECT L.Id FROM L WHERE L.age IN (SELECT R.name FROM R)",
        fails: intVsText)
  }

  @Test func `a cross-kind correlated scalar subquery faults at run`() throws {
    let sql = """
        SELECT L.Id FROM L \
        WHERE L.age = (SELECT R.name FROM R WHERE R.m = L.age)
        """
    try correlated().expect(sql, fails: intVsText)
  }

  @Test func `a same-kind correlated EXISTS still decorrelates and matches`()
      throws {
    // `R.m = L.age` is an integer pair, so the semijoin key still hoists: `L`
    // age 10 finds `R.m` 10, age 20 finds none — returning the matched row.
    try correlated().expect(
        "SELECT L.Id FROM L WHERE EXISTS (SELECT 1 FROM R WHERE R.m = L.age)",
        yields: [[1]])
  }

  @Test func `a same-kind correlated IN still decorrelates and matches`()
      throws {
    // `L.age IN (SELECT R.m …)` is an integer membership: age 10 is in {10,
    // 99}, age 20 is not, so it still lifts to a semijoin and returns the row.
    try correlated().expect(
        "SELECT L.Id FROM L WHERE L.age IN (SELECT R.m FROM R)",
        yields: [[1]])
  }
}

// MARK: - Nested subexpressions, set-operation carriers, parameter LIKE

/// The incomparable-type fault a non-character `LIKE` operand or pattern raises
/// — the same message on the compile character check and the run's `like`.
private let likeChar =
    SQLError.state("42804", "LIKE requires character operands")

/// A comparison nested inside a `COALESCE`/`CASE` argument, past an earlier
/// argument whose own resolution defers (an arithmetic type error), is still
/// found: the comparison-finder recurses each argument independently and defers
/// each one's own fault locally, so no earlier argument can hide a later
/// argument's incomparable comparison. (The retired walk-reuse deferred the
/// whole expression at once, silently swallowing the nested comparison.)
struct NestedSubexpressionComparabilityTests {
  @Test func `a COALESCE nested NULLIF faults past a deferred arithmetic arg`()
      throws {
    // `E.txt + 1` is a deferred arithmetic error; the finder recurses on to the
    // second argument's `NULLIF(E.num, E.txt)` — an integer/text comparison —
    // faulting 42804 at run over the empty `E`, where the old single enclosing
    // catch returned silently. Validate stays stricter, faulting the arithmetic
    // first (the pre-existing divergence).
    let sql = "SELECT COALESCE(E.txt + 1, NULLIF(E.num, E.txt)) FROM E"
    try partitioned().expect(sql, fails: intVsText)
    #expect(throws: SQLError.self) {
      try partitioned().columns(of: parse(query: sql))
    }
  }

  @Test func
      `a COALESCE nested CASE guard faults past a deferred arithmetic arg`()
      throws {
    let sql = """
        SELECT COALESCE(E.txt + 1, \
        CASE WHEN E.num = E.txt THEN 1 ELSE 0 END) FROM E
        """
    try partitioned().expect(sql, fails: intVsText)
  }

  @Test func `a same-kind COALESCE past a deferred arithmetic arg still runs`()
      throws {
    // No incomparable comparison anywhere, so the deferred arithmetic stays the
    // run's to raise — over the empty `E` it never evaluates, so the run yields
    // its empty result.
    let sql = "SELECT COALESCE(E.txt + 1, NULLIF(E.num, 1)) FROM E"
    try partitioned().empty(sql)
  }
}

/// A query-level `ORDER BY` carried over a set operation is a comparison
/// surface the finder visits: a cross-kind sort key faults 42804 in the
/// carrier, while a key that holds no comparison (an arithmetic one) does not —
/// the finder checks comparisons alone and never re-validates the carrier's
/// operands, so a run does not reject `ORDER BY txt + 1`.
struct CarrierComparabilityTests {
  @Test func `a cross-kind set-operation ORDER BY key faults at run`() throws {
    // The union's output column `txt` is text; `NULLIF(txt, 1)` compares it to
    // an integer — 42804 — in the carrier, over the empty `E`.
    let sql = """
        SELECT txt FROM E UNION ALL SELECT txt FROM E \
        ORDER BY NULLIF(txt, 1)
        """
    try partitioned().expect(sql, fails: textVsInt)
    #expect(throws: textVsInt) {
      try partitioned().columns(of: parse(query: sql))
    }
  }

  @Test func `an arithmetic set-operation ORDER BY key does not fault the run`()
      throws {
    // `txt + 1` is an arithmetic operand error, not a comparison, so the finder
    // leaves it to the run — which never evaluates it over empty `E`, so the
    // query yields its empty result. (Validate stays stricter, faulting the
    // arithmetic — the pre-existing divergence.)
    let sql = """
        SELECT txt FROM E UNION ALL SELECT txt FROM E \
        ORDER BY txt + 1
        """
    try partitioned().empty(sql)
  }
}

/// A recursive CTE's query-level `ORDER BY` carrier is peeled by the fixpoint
/// and run through `apply` under a normal context, so — unlike the non-
/// recursive set-operation carrier the top-level walk re-runs through
/// `ordered` — its sort keys never reached the compile-time comparability
/// walk: a cross-kind key over an empty-anchor fixpoint sorted no rows and
/// returned empty rather than faulting, while `columns(of: validate: true)`
/// faulted it through the CTE's carrier validation. `apply` now preflights the
/// carrier through the same `carried` resolver in `comparing()` mode, so a
/// cross-kind key faults 42804 on the run as it does on the validate path —
/// while an arithmetic key still defers to the run.
struct RecursiveCarrierComparabilityTests {
  @Test func `a cross-kind recursive-CTE ORDER BY key faults run and validate`()
      throws {
    // `r`'s anchor `SELECT num AS n FROM E` is empty, so the fixpoint sorts no
    // rows; the carrier `NULLIF(n, 'x')` compares the integer output `n`
    // against text — the cross-kind key the preflight faults 42804 before the
    // (empty) sort, matching the validate path's carrier validation.
    let sql = """
        WITH RECURSIVE r (n) AS (\
        SELECT num AS n FROM E \
        UNION ALL SELECT n + 1 FROM r WHERE n < 0 \
        ORDER BY NULLIF(n, 'x')) SELECT n FROM r
        """
    let statement = try Statement(parsing: sql)
    #expect(throws: intVsText) {
      try partitioned().columns(of: statement, validate: true)
    }
    #expect(throws: intVsText) { _ = try partitioned().run(statement) }
  }

  @Test func `a same-kind recursive-CTE ORDER BY key runs to its empty result`()
      throws {
    // `NULLIF(n, 1)` compares the integer output against an integer —
    // comparable — so neither path faults; the empty-anchor fixpoint is empty.
    let sql = """
        WITH RECURSIVE r (n) AS (\
        SELECT num AS n FROM E \
        UNION ALL SELECT n + 1 FROM r WHERE n < 0 \
        ORDER BY NULLIF(n, 1)) SELECT n FROM r
        """
    let statement = try Statement(parsing: sql)
    _ = try partitioned().columns(of: statement, validate: true)
    let rows = try partitioned().run(statement)
    #expect(rows.isEmpty)
  }

  @Test func `an arithmetic recursive-CTE ORDER BY key does not fault the run`()
      throws {
    // `n + 1` is an arithmetic operand, not a comparison, so the comparability
    // preflight leaves it to the run — which never evaluates it over the empty
    // fixpoint, so the query yields its empty result. The comparability-only
    // preflight must not over-fault a non-comparison key (it is not full
    // validation).
    let sql = """
        WITH RECURSIVE r (n) AS (\
        SELECT num AS n FROM E \
        UNION ALL SELECT n + 1 FROM r WHERE n < 0 \
        ORDER BY n + 1) SELECT n FROM r
        """
    let statement = try Statement(parsing: sql)
    let rows = try partitioned().run(statement)
    #expect(rows.isEmpty)
  }
}

/// A `LIKE` whose pattern (or escape) is a `:parameter` defers its character
/// rule to the run — the binding decides whether it faults — while a constant
/// non-character pattern faults at compile as the run does. This holds on both
/// the run and the validate path, so run ≡ validate.
struct ParameterLikeComparabilityTests {
  @Test func `an integer LIKE an unbound parameter does not fault`() throws {
    // `A.num LIKE :p` with `:p` unbound reads the pattern as NULL — UNKNOWN,
    // never the character fault — so it faults neither at compile nor at run,
    // over the non-empty `A`.
    let sql = "SELECT num FROM A WHERE A.num LIKE :p"
    _ = try partitioned().columns(of: parse(query: sql))
    try partitioned().empty(sql)
  }

  @Test func `an integer LIKE a NULL-bound parameter does not fault`() throws {
    try partitioned().empty("SELECT num FROM A WHERE A.num LIKE :p",
                            bindings: ["p": .null])
  }

  @Test func `an integer LIKE a non-character-bound parameter faults at run`()
      throws {
    // `:p` bound to a non-null integer is a non-character pattern, so the run's
    // `like` faults 42804 — the dynamic residual the compile defer leaves it.
    try partitioned().expect("SELECT num FROM A WHERE A.num LIKE :p",
                             fails: likeChar, bindings: ["p": .integer(5)])
  }

  @Test func `an integer LIKE a constant pattern still faults at compile`()
      throws {
    // A constant non-null pattern is not deferred, so the finder faults the
    // non-character operand `E.num` 42804 at compile, even over the empty `E`.
    let sql = "SELECT num FROM E WHERE E.num LIKE 'x'"
    let query = try parse(query: sql)
    #expect(throws: likeChar) { try partitioned().columns(of: query) }
    try partitioned().expect(sql, fails: likeChar)
  }
}
