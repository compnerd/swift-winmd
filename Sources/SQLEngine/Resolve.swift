// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Resolution and lowering — the bridge from the name-addressed AST to the
/// engine's ordinal-addressed forms.
///
/// The AST names columns by string; the engine addresses them by ordinal.
/// Resolution reads only a relation's schema — its `width`, its `extent`, and
/// its name → ordinal map — never its live cursor, so it runs over an escapable
/// `Schema` (lifted off a base `Table` or a compiled `View`) rather than the
/// `~Escapable` source. A single relation resolves a name against one `Schema`.
/// A join lays its two relations end to end in one combined ordinal space and
/// resolves a possibly qualified name against the pair through a `Scope`. Both
/// lower a `Projection` to ordinals (`*` → the real width, never a virtual
/// column), an `Order` to an `(ordinal, ascending)` pair, and the AST
/// `Predicate` to the engine's `Filter`. A column name resolves to a real
/// ordinal (`< width`) or a virtual one (`>= width`). A name no relation
/// resolves is `SQLError.column`; an unqualified name both relations of a join
/// resolve is `SQLError.ambiguous`.

/// The RESOLUTION CONTEXT a subquery occurrence materialises under — the seam
/// that keeps two AST-identical subqueries resolving under DIFFERENT overlays
/// SEPARATE cache entries, so neither overwrites the other.
///
/// An uncorrelated subquery's result depends only on the overlay it resolves
/// against, and in this slice a subquery resolves under exactly one of two
/// contexts: the top-level CALLER's overlay (its `WITH` CTEs), or a specific
/// VIEW body's overlay (that view's own base relations, never the caller's
/// `WITH`). A view `VN` whose body has `EXISTS (SELECT V FROM S)` over an empty
/// base `S`, run under a caller that binds `WITH S AS (SELECT 1)`, must read
/// the view's own (empty) `S` — not the caller's CTE — even though both spell
/// the same AST. Keying the cache by the `Query` VALUE alone collapses the
/// two; a `Subscope` composed into the key keeps them disjoint. The `caller`
/// case is distinguished from every `view` case, and two distinct view names
/// never collide (case-folded), so the caller and view spaces cannot overlap.
///
/// It is reproducible at BOTH the compile site (lowering embeds it in the
/// lowered `Filter`) and the matching materialise site (`run` materialises the
/// top-level query's subqueries under `.caller`; `derive(name:)` materialises a
/// view body's under `.view(name)`), so the key a lowered predicate reads is
/// the key the materialiser wrote.
internal enum Subscope: Hashable, Sendable {
  /// The top-level caller's overlay — a subquery textually in the outer query
  /// (its `WHERE`, projection, …), and an outer conjunct pushed into a view.
  case caller
  /// A view body's own overlay, named by the view (case-folded) — a subquery
  /// textually in that view's registered query.
  case view(String)
}

/// The ROLE a subquery occurrence materialises in — its SHAPE in the cache.
///
/// The SAME inner SQL can occur in three roles at once, each needing a
/// DIFFERENT materialisation, so the role discriminates the cache entry: a
/// `scalar` occurrence (`Expression.subquery`) collapses to one cell
/// (`cell(of:)`), a `valued` occurrence (`IN (SELECT …)`, `Predicate.within`)
/// keeps the materialised rows for its value set, and an `existential`
/// occurrence (`EXISTS (SELECT …)`) is a cardinality PROBE that never runs
/// the select list. Keying the cache without the role collapses the three onto
/// one entry, so an `IN` reading a scalar entry faults (no rows) and an
/// `EXISTS` reading a scalar entry mis-reads `present` — the role keeps them
/// disjoint.
internal enum Role: Hashable, Sendable {
  /// A scalar-subquery occurrence — collapsed to a single cell.
  case scalar
  /// An `IN (SELECT …)` occurrence — materialised in full for its value
  /// set.
  case valued
  /// An `EXISTS (SELECT …)` occurrence — a cardinality probe.
  case existential
}

/// The cache identity of one collected subquery OCCURRENCE — its resolution
/// `context` composed with its `query` AST and its `role`.
///
/// A subquery is keyed neither by its `Query` value alone (which collapses two
/// AST-identical subqueries under different overlays — see `Subscope`)
/// nor by a raw counter (which two independent id spaces could not keep
/// disjoint), but by the TRIPLE: within one `Subscope`, an identical `Query`
/// resolves to an identical result, so value-discrimination is correct there;
/// across scopes the `Subscope` keeps them separate. A caller-space key
/// (`.caller`) and a view-space key (`.view(name)`) are unequal even for the
/// same AST, so the two id spaces cannot collide.
///
/// The `role` keeps the three materialisation SHAPES of one `(scope, query)`
/// disjoint (see `Role`): a `scalar` read can never hit a `valued` or an
/// `existential` entry and vice versa, so identical inner SQL used in more than
/// one role no longer cross-reads the wrong entry.
internal struct Subkey: Hashable, Sendable {
  /// The resolution context this occurrence materialises under.
  internal let scope: Subscope

  /// The subquery's AST.
  internal let query: Query

  /// The role this occurrence materialises in — its cache SHAPE.
  internal let role: Role

  internal init(_ scope: Subscope, _ query: Query, _ role: Role) {
    self.scope = scope
    self.query = query
    self.role = role
  }
}

/// One UNCORRELATED subquery already RUN ONCE at execution — the value a
/// run-time `Subqueries` cache memoises so the row evaluator reads an
/// `EXISTS`/`IN (Q)` predicate without re-running the inner query or itself
/// holding the borrowing catalog.
///
/// An `IN (Q)` occurrence needs the subquery's single COLUMN of values, so it
/// is materialised in FULL (`rows`). An occurrence used only by `EXISTS` needs
/// nothing but CARDINALITY — whether the row source yields ANY row — so it is
/// materialised as a `present` PROBE that never evaluates the select list or
/// sort keys and stops at the first row (`EXISTS (SELECT 1 / 0 FROM S)` over a
/// non-empty `S` is TRUE with no `.divide`, no full scan). A probe carries no
/// `rows`, so `values` faults if an `IN` ever reads it — but a query needing
/// its values is materialised full, so it never does.
///
/// A SCALAR subquery occurrence is NOT materialised here — it collapses LAZILY,
/// on the first evaluation of its `Term.subquery`, so a scalar subquery in an
/// unreachable `CASE`/`COALESCE` arm never runs (see `Subqueries.scalar`). The
/// eager entries this holds are therefore only the `IN` full result and the
/// `EXISTS` probe.
internal struct MaterialisedSubquery {
  /// The subquery's result rows for an `IN` occurrence materialised in full, or
  /// `nil` for an `EXISTS`-only probe (which carries no full rows).
  private let rows: Array<Array<Value>>?

  /// Whether the row source yielded a row — the `EXISTS` non-empty test, read
  /// from the full `rows` or the probe.
  internal let present: Bool

  /// A full materialisation of `rows` — an `IN` occurrence, whose select list
  /// IS needed.
  internal init(rows: Array<Array<Value>>) {
    self.rows = rows
    self.present = !rows.isEmpty
  }

  /// A cardinality probe — an `EXISTS`-only occurrence, carrying only whether
  /// the row source yielded a row, never the select-list values.
  internal init(present: Bool) {
    self.rows = nil
    self.present = present
  }

  /// The single column of the result — the `IN (Q)` membership values. Only an
  /// occurrence materialised in FULL (its select list needed) reads this; a
  /// probe-only entry carries none, an internal invariant break if reached.
  internal func values() throws(SQLError) -> Array<Value> {
    guard let rows else {
      throw .named("a subquery materialised as a probe has no values")
    }
    return rows.map { $0[0] }
  }
}

/// The mutable memo a `Subqueries` cache shares by REFERENCE for the scalar
/// subqueries it materialises LAZILY.
///
/// A scalar subquery collapses on the FIRST evaluation of its `Term.subquery`,
/// not eagerly at run start, so an occurrence in an unreachable
/// `CASE`/`COALESCE` arm never runs (never throws `.cardinality` or an inner
/// fault). It is UNCORRELATED, so its collapsed value is row-invariant: the
/// first reached evaluation runs and caches it here, keyed by its `Subkey`, and
/// every later read of the same key returns the cached value WITHOUT
/// re-running. The cache is a class so the memo survives `Subqueries` being
/// copied by value down the evaluate tree — every copy shares the one box.
internal final class ScalarMemo {
  private var cells: Dictionary<Subkey, Value> = [:]

  /// The already-collapsed value for `key`, or `nil` when it has not yet been
  /// evaluated — the evaluator runs and `store`s it on a miss.
  internal func value(_ key: Subkey) -> Value? {
    cells[key]
  }

  /// Records `value` as the collapsed value of the scalar occurrence `key`, so
  /// a later read of the same key returns it without re-running the subquery.
  internal func store(_ value: Value, for key: Subkey) {
    cells[key] = value
  }
}

/// The COMPILE-time seam that lowers an `EXISTS`/`IN (Q)` predicate WITHOUT
/// running its subquery — the fix for the schema-path cursor-contract violation.
///
/// Predicate lowering happens over escapable resolution surfaces (`Schema`,
/// `Scope`, `Grouping`) that carry no catalog, and is shared by SCHEMA-ONLY
/// paths (`columns(of:)`, view resolution, arity checks) documented NOT to open
/// a cursor. So lowering carries the sub-`Query` into the `Filter` as DATA
/// rather than running it: `exists`/`within` build the lowered node holding the
/// query, which executes ONCE, at RUN time (see `Subqueries`). Only the
/// single-column arity of an `IN (Q)` is decided here — from the subquery's
/// COMPILED WIDTH, known without a cursor — so a two-column `IN` subquery faults
/// `SQLError.arity` at compile as before, never having run.
///
/// The `widths` map holds each nested `Query`'s compiled column count, built by
/// the `compile` path (where the catalog is in scope) by COMPILING — never
/// running — every subquery ONCE ahead of lowering. A schema-only surface with
/// no catalog passes `.unsupported`, whose `width` faults, so a subquery
/// reaching such a surface is rejected rather than mis-lowered.
internal struct Subquery {
  /// The resolution context every subquery lowered against this surface
  /// materialises under — `.caller` for a top-level compile, `.view(name)` for
  /// a view body's — composed into each lowered `Filter`'s cache key so a
  /// view-body occurrence and a top-level one over the same AST stay distinct.
  private let scope: Subscope

  /// Each nested `Query` mapped to its COMPILED column count — cursor-free; an
  /// `IN (Q)` and a scalar subquery each require it be 1.
  private let widths: Dictionary<Query, Int>

  /// Each nested `Query` mapped to its single-column output TYPE, derived
  /// cursor-free in the compile pre-pass — the static type a scalar subquery
  /// contributes (the executor coerces its collapsed value to it, as a `CASE`
  /// coerces its arms). Only a width-1 query has one, so an `EXISTS`/`IN (Q)`
  /// occurrence (whose type is irrelevant) may be absent.
  private let types: Dictionary<Query, ValueType>

  internal init(_ scope: Subscope = .caller,
                _ widths: Dictionary<Query, Int> = [:],
                _ types: Dictionary<Query, ValueType> = [:]) {
    self.scope = scope
    self.widths = widths
    self.types = types
  }

  /// A `Subquery` for a lowering surface with no catalog — a schema-only
  /// resolve. It holds no widths, so any subquery lowered against it faults
  /// `SQLError.unsupported` rather than mis-lower.
  internal static var unsupported: Subquery {
    Subquery()
  }

  /// The compiled column count of `query`, or a fault when the surface holds
  /// none — a subquery reaching a catalog-less lowering surface.
  private func width(_ query: Query) throws(SQLError) -> Int {
    guard let width = widths[query] else {
      throw .unsupported("a subquery is not supported in this position")
    }
    return width
  }

  /// The single-column output type `query` contributes as a scalar subquery.
  /// The compile pre-pass records it beside the width for every subquery, so a
  /// scalar occurrence reads it; a surface with no catalog holds none and
  /// faults, rejecting the subquery rather than mis-typing it.
  private func output(_ query: Query) throws(SQLError) -> ValueType {
    guard let type = types[query] else {
      throw .unsupported("a subquery is not supported in this position")
    }
    return type
  }

  /// The static single-column type a scalar subquery `query` contributes to a
  /// SCHEMA derive — its single-column arity enforced first (else
  /// `SQLError.arity`, matching the lowering), so this schema surface and the
  /// run's lowering AGREE on both the arity fault and the type.
  internal func scalar(type query: Query) throws(SQLError) -> ValueType {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return try output(query)
  }

  /// Lowers `[NOT] EXISTS (query)` — the query carried into the `Filter` to run
  /// at execution, `negated` flipping the non-empty test. `EXISTS` ignores the
  /// subquery's arity (its column count is irrelevant to a cardinality test),
  /// but the query must have been compiled in the pre-pass (else a catalog-less
  /// surface, which faults).
  internal func exists(_ query: Query, negated: Bool)
      throws(SQLError) -> Filter {
    _ = try width(query)
    return .exists(Subkey(scope, query, .existential), negated: negated)
  }

  /// Lowers `operand [NOT] IN (query)` — `operand` already lowered to a `Term`
  /// — requiring `query` project EXACTLY ONE column (else `SQLError.arity`,
  /// checked from the COMPILED width, so a two-column subquery faults here
  /// without running), then carrying the query into the `Filter` to run at
  /// execution.
  internal func within(_ operand: Term, _ query: Query, negated: Bool)
      throws(SQLError) -> Filter {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return .within(operand, Subkey(scope, query, .valued), negated: negated)
  }

  /// Lowers `operand op {ANY | ALL} (query)` — `operand` already lowered to a
  /// `Term` — requiring `query` project EXACTLY ONE column (else
  /// `SQLError.arity`, from the COMPILED width, so a two-column subquery faults
  /// here WITHOUT running), then carrying the query into the `Filter` under the
  /// SAME `.valued` role `within` uses — the full column is materialised and
  /// folded per outer row — to run at execution.
  internal func quantified(_ operand: Term, _ op: Comparison,
                           _ quantifier: Quantifier, _ query: Query)
      throws(SQLError) -> Filter {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return .quantified(operand, op, quantifier, Subkey(scope, query, .valued))
  }

  /// Lowers a scalar subquery `(query)` to a `Term.subquery` reading its
  /// collapsed value from the run-time cache, requiring `query` project EXACTLY
  /// ONE column (else `SQLError.arity`, from the COMPILED width, so a wider
  /// subquery faults here WITHOUT running). The term carries the subquery's
  /// occurrence `Subkey` — its resolution scope composed with `query` — and its
  /// single-column TYPE, to which the executor coerces the collapsed value (the
  /// empty → NULL and >1-row → cardinality cases are decided at RUN, in the
  /// materialiser).
  internal func scalar(_ query: Query) throws(SQLError) -> Term {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return try .subquery(Subkey(scope, query, .scalar), type: output(query))
  }
}

/// The RUN-time cache that executes each UNCORRELATED subquery ONCE and
/// memoises its result — the seam that gives the row evaluator a subquery result
/// WITHOUT itself holding the borrowing catalog.
///
/// A subquery is UNCORRELATED in this slice — it names no column of the
/// enclosing query — so its result is the SAME for every outer row and is
/// computed at most once per outer-query execution. The `run` path, where the
/// borrowing catalog IS in scope, populates this map BEFORE executing the plan
/// (see `Catalog.subqueries(of:)`), so the evaluator reads it as plain
/// escapable data. An `EXISTS` reads whether the result is non-empty; an
/// `IN (Q)` folds over its single materialised column.
///
/// An `IN`/`EXISTS` occurrence is materialised EAGERLY here — its full result
/// or its probe run at run start, since a `WHERE`/`ON` predicate referencing it
/// is not short-circuited past. A SCALAR occurrence instead materialises
/// LAZILY, on the first evaluation of its `Term.subquery` (memoised in
/// `scalars`), so an occurrence in an unreachable `CASE`/`COALESCE` arm never
/// runs. Per-arm short-circuit for the `IN`/`EXISTS` roles and the
/// per-outer-row re-execution a CORRELATED subquery needs thread a runner to
/// the predicate site in a follow-up.
internal struct Subqueries {
  private let results: Dictionary<Subkey, MaterialisedSubquery>

  /// The shared memo of the scalar occurrences materialised LAZILY on first
  /// evaluation — a reference so every by-value copy of this cache down the
  /// evaluate tree shares the one box, keeping a scalar materialise-once.
  private let scalars: ScalarMemo

  /// The REVEALED base scope the eager occurrences of this cache ran against,
  /// keyed PER `Subscope` — the enclosing scope with this SELECT's derived
  /// aliases revealed away and its CTEs/store relations intact
  /// (`Context.revealed`), stored under the `Subscope` those occurrences
  /// materialised in. A LAZY scalar occurrence resolves its inner query against
  /// the scope of its OWN `Subkey`, not the augmented overlay threaded down the
  /// evaluate tree: the executor threads only the EXECUTING plan's overlay, so
  /// after a `merged` folds a view-body cache into the caller's it cannot tell
  /// a view-body occurrence's scope from the caller's. Keying PER `Subscope`
  /// keeps a `.view(name)` scalar reading the VIEW's own relations and a
  /// `.caller` scalar the caller's — one shared scope resolved a view-body
  /// scalar against the caller's overlay (the round-15 fault). Empty for a
  /// scope the cache carries no eager occurrence of (a bare `Subqueries()` a
  /// schema path threads), so the lazy scalar falls back to the threaded
  /// overlay — whose derived layer a `cell(of:)` reveal drops to expose a CTE a
  /// same-named derived alias shadows.
  private let scopes: Dictionary<Subscope, ScopedRelations>

  internal init(_ results: Dictionary<Subkey, MaterialisedSubquery> = [:],
                _ scalars: ScalarMemo = ScalarMemo(),
                _ scopes: Dictionary<Subscope, ScopedRelations> = [:]) {
    self.results = results
    self.scalars = scalars
    self.scopes = scopes
  }

  /// The revealed base relations the occurrences of `scope` ran against, or an
  /// empty map when the cache carries none — the scope a LAZY scalar of that
  /// `Subscope` resolves its inner query against, falling back to the threaded
  /// overlay when empty (a schema path's bare cache).
  internal func relations(_ scope: Subscope) -> ScopedRelations {
    scopes[scope] ?? [:]
  }

  /// The materialised result for `key` — every occurrence a runnable plan
  /// references is populated at run start, so a miss is an internal invariant
  /// break, reported rather than silently treated as empty.
  private func result(_ key: Subkey) throws(SQLError) -> MaterialisedSubquery {
    guard let result = results[key] else {
      throw .named("a subquery result was not materialised")
    }
    return result
  }

  /// Whether the occurrence `key` yielded a row — the `EXISTS` non-empty test.
  internal func present(_ key: Subkey) throws(SQLError) -> Bool {
    try result(key).present
  }

  /// The single column of the occurrence `key`'s result — the `IN (Q)`
  /// membership values. The plan compiled the query's width to 1, so the first
  /// cell of each row is its lone value; an `IN` occurrence is always
  /// materialised in FULL, so its values are present.
  internal func values(_ key: Subkey) throws(SQLError) -> Array<Value> {
    try result(key).values()
  }

  /// The already-collapsed value memoised for the scalar occurrence `key`, or
  /// `nil` when it has not yet been evaluated. The evaluator reads this first;
  /// on a miss it runs the subquery (where the catalog is in scope) and
  /// `store`s the collapsed value, so a scalar in an unreachable arm never runs
  /// and a reached one runs at most once.
  internal func scalar(cached key: Subkey) -> Value? {
    scalars.value(key)
  }

  /// Records `value` as the collapsed value of the scalar occurrence `key` —
  /// the evaluator's memoisation after the first reached evaluation runs the
  /// subquery, so a later read of the same key returns it without re-running.
  internal func store(scalar value: Value, for key: Subkey) {
    scalars.store(value, for: key)
  }

  /// The DISJOINT union of this cache and `other`'s — every entry of both,
  /// which never collide because their keys carry distinct `Subscope`s: `self`
  /// holds one resolution context's occurrences (the caller's, keyed
  /// `.caller`), `other` another's (a view body's, keyed `.view(name)`). A
  /// subquery AST-identical in both is TWO occurrences under TWO scopes, so it
  /// occupies TWO keys — neither overwrites the other, and the pushed caller
  /// filter reads its `.caller` result while the view-body filter reads its
  /// `.view` one. A collision would be an id-space bug (two contexts sharing a
  /// scope); it cannot happen, so the merge keeps the existing entry. The
  /// merged cache keeps `self`'s scalar memo and UNIONS the per-`Subscope`
  /// base scopes of both — a caller cache and a view-body cache resolve
  /// DISJOINT scalar keys, so one shared memo serves both spaces, and each
  /// `Subscope` keeps its OWN base relations (the `.caller` map and the
  /// `.view(name)` map ride through side by side), so a view-body lazy scalar
  /// resolves against the VIEW's relations and a caller scalar the caller's —
  /// keeping only `self`'s left-hand scope would resolve a view-body scalar
  /// against the caller overlay. Two contexts sharing a `Subscope` would be an
  /// id-space bug, so a scope collision keeps `self`'s.
  internal func merged(_ other: Subqueries) -> Subqueries {
    Subqueries(results.merging(other.results) { existing, _ in existing },
               scalars,
               scopes.merging(other.scopes) { existing, _ in existing })
  }
}

/// The mutable set of SCALAR-subquery inner queries the type-check walk
/// REACHED, shared by a `SubqueryCheck` by REFERENCE.
///
/// A scalar subquery's inner-query OPERAND validation is DEFERRED to the
/// reachability walk (`Scope.validate`), mirroring the lazy executor: an
/// occurrence in an unreachable `CASE`/`COALESCE` arm never validates, exactly
/// as it never runs. The walk cannot itself hold the borrowing catalog a
/// recursive type-check needs, so as it REACHES each scalar `.subquery` it
/// records the inner query here; the catalog-bearing `typecheck` phase reads
/// this set AFTER the walk and type-checks only the reached inner queries. The
/// box is a class so the reached set survives `SubqueryCheck` being copied by
/// value down the walk — every copy shares the one box, the same way
/// `ScalarMemo` shares the run's lazy collapse.
internal final class ReachedScalars {
  private var queries: Set<Query> = []

  /// Records `query` as a scalar occurrence the walk reached, so the deferred
  /// type-check phase validates its inner query.
  internal func reach(_ query: Query) {
    queries.insert(query)
  }

  /// The scalar inner queries the walk reached — the ones the deferred phase
  /// type-checks.
  internal var reached: Set<Query> {
    queries
  }
}

/// The validation-side analog of `Subquery` — the seam that lets the dry-run
/// type-check (`check`) validate the UNCORRELATED inner query an `EXISTS`/`IN
/// (Q)` nests without itself holding the borrowing catalog.
///
/// `check` runs over escapable resolution surfaces carrying no catalog, yet a
/// subquery's inner names and routines must be validated against one for schema
/// validation to match execution — the recurring lesson that the two must not
/// diverge. The `typecheck` path, where the borrowing catalog and `Context`
/// ARE in scope, builds this from the maps it fills by validating and compiling
/// every subquery ahead of the `check` walk; a surface with no catalog passes
/// `.unsupported`, which faults so a subquery reaching such a surface is
/// rejected rather than passed unvalidated.
///
/// An `EXISTS`/`IN (Q)` inner query is type-checked EAGERLY in that pre-pass
/// (its predicate is not short-circuited past, so it always runs), as is every
/// scalar subquery's cursor-free ARITY and TYPE derivation (TOTAL — a CASE's
/// static column type unifies all arms regardless of runtime reachability, and
/// deriving the type of `1 / 0` yields the integer type WITHOUT dividing). A
/// scalar subquery's inner-query OPERAND validation is instead DEFERRED: the
/// `.subquery` case of the reachability walk records the reached query into the
/// shared `reached` box, and the `typecheck` phase validates only those after
/// the walk — so an unreachable arm's scalar subquery is not validated, exactly
/// as the executor does not evaluate it.
internal struct SubqueryCheck {
  /// Each nested `Query` mapped to its compiled column count — the map the
  /// `typecheck` path builds by compiling every subquery ONCE, ahead of the
  /// `check` walk. `check` reads its width to enforce a `IN (Q)`'s or a scalar
  /// subquery's single-column arity.
  private let widths: Dictionary<Query, Int>

  /// Each nested `Query` mapped to its single-column output TYPE, derived by
  /// the `typecheck` pre-pass — the type a scalar subquery reports to the
  /// result schema (`validate`/`derive`), matching the lowering's `Subquery`.
  private let types: Dictionary<Query, ValueType>

  /// The scalar inner queries whose OPERAND validation is DEFERRED to the walk
  /// — the ones NOT eagerly type-checked in the pre-pass (a scalar-ONLY
  /// occurrence). The `.subquery` case records a reached one into `reached`.
  private let deferred: Set<Query>

  /// The shared box the walk records each reached scalar occurrence into, read
  /// by the catalog-bearing `typecheck` phase after the walk to validate the
  /// reached inner queries.
  private let reached: ReachedScalars

  internal init(_ widths: Dictionary<Query, Int> = [:],
                _ types: Dictionary<Query, ValueType> = [:],
                deferred: Set<Query> = [],
                reached: ReachedScalars = ReachedScalars()) {
    self.widths = widths
    self.types = types
    self.deferred = deferred
    self.reached = reached
  }

  /// A checker for a surface with no catalog — validating a subquery needs one,
  /// so it holds no widths and faults `SQLError.unsupported` rather than pass a
  /// subquery unvalidated.
  internal static var unsupported: SubqueryCheck {
    SubqueryCheck()
  }

  /// Asserts the inner `query` was validated in the pre-pass — a query the
  /// surface's map holds has been type-checked and compiled; one it does not
  /// reached a catalog-less surface and is rejected.
  internal func validate(_ query: Query) throws(SQLError) {
    guard widths[query] != nil else {
      throw .unsupported("a subquery is not supported in this position")
    }
  }

  /// The column count `query` projects — from the pre-pass compile.
  internal func width(_ query: Query) throws(SQLError) -> Int {
    guard let width = widths[query] else {
      throw .unsupported("a subquery is not supported in this position")
    }
    return width
  }

  /// The single-column output type `query` contributes as a scalar subquery —
  /// from the pre-pass derive — validating its single-column arity first (else
  /// `SQLError.arity`, matching the run's lowering). This is the WALK-reached
  /// path, so a scalar occurrence whose operand validation was deferred is
  /// recorded REACHED here, for the `typecheck` phase to validate its inner
  /// query. The cursor-free arity/type derivation stays SEPARATE and total: the
  /// arity of an unreachable scalar was already enforced eagerly in the
  /// pre-pass (`subqueryCheck`), so a two-column subquery in a skipped arm still
  /// faults.
  internal func type(_ query: Query) throws(SQLError) -> ValueType {
    // A DEFERRED scalar occurrence is REACHED here: record it for the
    // `typecheck` phase to validate its inner query's OPERANDS, mirroring the
    // lazy executor materialising only a reached scalar. Its arity and single-
    // column type were derived eagerly in `subqueryCheck` (cursor-free, total),
    // so this reads them exactly as an eagerly-checked occurrence does — only
    // the operand fault (`.divide`) it might raise defers to the reached walk.
    if deferred.contains(query) { reached.reach(query) }
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    guard let type = types[query] else {
      throw .unsupported("a subquery is not supported in this position")
    }
    return type
  }

  /// The scalar inner queries the walk reached — the ones the `typecheck` phase
  /// validates after the walk, mirroring the lazy executor's evaluation of only
  /// a reached scalar subquery.
  internal var visited: Set<Query> {
    reached.reached
  }
}

/// Lowers the name-addressed AST `predicate` to the engine's `Filter`, lowering
/// each leaf's operand expressions through `term` and passing a `bound`
/// comparison's `:parameter` through unchanged.
///
/// Every predicate lowering — a single relation, a join scope, a grouped scope —
/// shares this shape, differing only in how a leaf term resolves its columns
/// (against one schema, a combined join space, or a grouped slot space); each
/// caller supplies that resolution as `term`.
private func lower(_ predicate: Predicate,
                   term: (Expression) throws(SQLError) -> Term,
                   subquery: Subquery)
    throws(SQLError) -> Filter {
  switch predicate {
  case let .comparison(left, op, right):
    try .compare(term(left), op, term(right))
  case let .bound(left, op, parameter):
    try .bound(term(left), op, parameter)
  case let .null(expression, negated):
    try .null(term(expression), negated: negated)
  case let .exists(query, negated):
    // `[NOT] EXISTS (Q)`. In this first slice `Q` is UNCORRELATED, so the
    // materialiser runs it ONCE (as a CTE body materialises) and the whole
    // predicate is the definite non-empty test of that result — never UNKNOWN,
    // `negated` flipping it. A missing materialiser (a lowering surface with no
    // catalog in scope) rejects the subquery rather than mis-lower it.
    try subquery.exists(query, negated: negated)
  case let .within(expression, query, negated):
    // `x [NOT] IN (Q)`. `Q` is UNCORRELATED here, so the materialiser runs it
    // ONCE, checks it projects exactly ONE column (else `SQLError.arity`), and
    // lowers to a `Filter.within` folding `x = v` over that column under the
    // value-list `IN`'s three-valued Kleene `OR`.
    try subquery.within(term(expression), query, negated: negated)
  case let .quantified(expression, op, quantifier, query):
    // `x op {ANY | ALL} (Q)`. `Q` is UNCORRELATED here, so the materialiser
    // runs it ONCE, checks it projects exactly ONE column (else
    // `SQLError.arity`), and lowers to a `Filter.quantified` folding `x op v`
    // over that column with the SAME `matches`/Kleene primitives `within` uses
    // — Kleene `OR` for `any`, Kleene `AND` for `all`.
    try subquery.quantified(term(expression), op, quantifier, query)
  case let .membership(expression, values, negated):
    // `x IN (a, b, …)` is the disjunction `x = a OR x = b OR …` and `NOT IN`
    // its negation, lowered to a first-class `Filter.membership` that evaluates
    // the operand ONCE per row (an OR-chain would re-evaluate a side-effecting
    // operand once per element) and folds the element equalities under Kleene
    // `OR`. That yields the ISO three-valued result: an unmatched test with a
    // NULL operand or a NULL element is UNKNOWN — Kleene `OR` of a FALSE and an
    // UNKNOWN is UNKNOWN — not FALSE, and `NOT` maps that UNKNOWN to itself, so
    // `NOT IN` a list holding NULL is never TRUE.
    try membership(term(expression), values, negated: negated, term: term)
  case let .like(operand, pattern, escape, negated):
    // Lower each operand to a first-class `Filter.like`; the optional escape
    // lowers only when present. The matcher and three-valued handling live in
    // the runtime, so lowering just resolves the operand terms.
    try like(operand, pattern, escape, negated: negated, term: term)
  case let .between(test, low, high, negated):
    // `x [NOT] BETWEEN a AND b` lowers to a first-class `Filter.between` that
    // evaluates the test `x` ONCE per row (an `AND`/`OR` of two comparisons
    // would re-evaluate a non-idempotent `x`, once per bound) and folds the two
    // bounds against that same value under Kleene logic — a NULL `x`, `a`, or
    // `b` making a bound UNKNOWN and excluding the row, the ISO range test.
    // Each bound lowers through the same `Operand` form a `LIKE` pattern does,
    // a `.term` or a `:parameter` name resolved from the bindings at eval.
    try .between(term(test), lower(low, term: term), lower(high, term: term),
                 negated: negated)
  case let .distinct(lhs, rhs, negated):
    // `a IS [NOT] DISTINCT FROM b` lowers to a first-class `Filter.distinct`
    // over the two lowered terms — the null-safe comparison the runtime
    // evaluates TWO-VALUED, treating NULL as a comparable value. No
    // `:parameter` form is defined, so both sides lower straight through
    // `term`.
    try .distinct(term(lhs), term(rhs), negated: negated)
  case let .truth(inner, value, negated):
    // `p IS [NOT] <truth value>` lowers to a first-class `Filter.truth` over
    // the lowered inner boolean filter; the three-valued-to-definite mapping
    // lives in the runtime (`tested`), so lowering just lowers the operand.
    try .truth(lower(inner, term: term, subquery: subquery), value,
               negated: negated)
  case let .and(lhs, rhs):
    try .and(lower(lhs, term: term, subquery: subquery),
             lower(rhs, term: term, subquery: subquery))
  case let .or(lhs, rhs):
    try .or(lower(lhs, term: term, subquery: subquery),
            lower(rhs, term: term, subquery: subquery))
  case let .not(operand):
    try .not(lower(operand, term: term, subquery: subquery))
  }
}

/// Lowers `x [NOT] IN (v, …)` — the operand already lowered to `left` — to a
/// first-class `Filter.membership(left, [v0, v1, …], negated:)`, each value
/// lowered through `term`.
///
/// The operand is held ONCE rather than copied into an OR-chain of `left = vi`
/// comparisons: that chain re-evaluated `left` per element, so a non-idempotent
/// operand (a side-effecting scalar call) yielded a different value each
/// element compared against. The `Filter.membership` runtime evaluates `left`
/// exactly once per row, then folds `left = vi` over the elements IN ORDER
/// under Kleene `OR` — the same left-to-right short-circuit and
/// NULL/three-valued semantics the OR-chain had — and `negated` applies the
/// `NOT IN` negation.
///
/// The value list must be non-empty: the parser rejects `IN ()`, but
/// `Predicate.membership` is public, so a caller can hand this lowering an
/// empty list directly, bypassing the grammar. An empty list has no element to
/// compare against — the membership is undefined — so reject it as an
/// unsupported shape rather than folding it.
private func membership(_ left: Term, _ values: Array<Expression>,
                        negated: Bool,
                        term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  guard !values.isEmpty else {
    throw .unsupported("IN requires a non-empty value list")
  }
  var elements = Array<Term>()
  elements.reserveCapacity(values.count)
  for value in values {
    try elements.append(term(value))
  }
  return .membership(left, elements, negated: negated)
}

/// Lowers `operand [NOT] LIKE pattern [ESCAPE escape]` to a first-class
/// `Filter.like`, the operand lowered through `term`, the pattern and optional
/// escape through `operand(_:)` — an expression lowers to a term, a
/// `:parameter` passes through as a bound name resolved at eval.
///
/// Lowering is a plain term resolution — the `%`/`_` matcher and the
/// three-valued/cross-kind handling are the runtime's — so this mirrors the
/// membership lowering, differing only in carrying the pattern and escape
/// operands rather than a value list.
private func like(_ operand: Expression, _ pattern: Predicate.Operand,
                  _ escape: Predicate.Operand?, negated: Bool,
                  term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  let escape: Filter.Operand? =
      if let escape { try lower(escape, term: term) } else { nil }
  return try .like(term(operand), pattern: lower(pattern, term: term),
                   escape: escape, negated: negated)
}

/// Lowers a `LIKE` pattern or escape `operand` to its filter form: an
/// expression lowers to a `.term` through `term`; a `:parameter` passes through
/// as a bound `.parameter` name resolved from the bindings at eval, the same
/// mechanism a `Predicate.bound` comparison uses.
private func lower(_ operand: Predicate.Operand,
                   term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter.Operand {
  switch operand {
  case let .expression(expression): try .term(term(expression))
  case let .parameter(name): .parameter(name)
  }
}

/// One resolved sort key — a lowered `Term`, its direction, and the
/// SELECT-list output column it names (when it names one).
///
/// `term` is the value the sort evaluates per record, `ascending` its own
/// direction. `column` records the 0-based projection column an ORDINAL or an
/// output ALIAS names — the two forms that reference the select list by
/// construction — and is `nil` for an ordinary INPUT expression. `shaped`
/// materialises each projected output ONCE below the sort and orders an output
/// key by that materialised column (`slot(column)`), so a computed output is
/// sorted on exactly the value it returns rather than recomputed by the sort.
/// A non-deterministic or stateful routine would otherwise sort on one set of
/// values and return a second, misordering the result. The `SELECT DISTINCT`
/// ordering check reads `output`, since an output key is well-defined over the
/// deduplicated rows (its value is constant across a dedup group) whether its
/// term is a bare column or not.
internal struct SortKey {
  /// The value this key orders on.
  let term: Term

  /// Whether this key is ascending (`ASC`) rather than descending (`DESC`).
  let ascending: Bool

  /// The 0-based projection column this key names (an ordinal or an output
  /// alias), or `nil` for an ordinary input expression.
  let column: Int?

  /// Whether this key references a SELECT-list output (an ordinal or an output
  /// alias) rather than an ordinary input expression.
  var output: Bool { column != nil }

  /// This key with its `term` ordinals remapped to slots through `slot`. The
  /// `column` is a projection-list index, not an ordinal, so it is unchanged.
  internal func remapped(through slot: Dictionary<Int, Int>) -> SortKey {
    SortKey(term: term.remapped(through: slot), ascending: ascending,
            column: column)
  }
}

/// The resolved sort keys `order` lowers to, in major-to-minor order — each
/// key's ISO `<sort key>` lowered to a `Term` and its direction preserved.
///
/// A single relation and a join scope share this shape, differing only in how a
/// key's `expression` lowers to an ordinal-addressed `Term` (against one
/// schema, or a combined join space); each caller supplies that lowering as
/// `term`. The grouped scope orders in a different (grouped-slot) space, so it
/// does not share this.
///
/// The three sort-key forms resolve as:
///
/// - `ordinal(n)` names the query's `n`-th projected OUTPUT column (1-based).
///   It resolves to that projection item's already-lowered `Term`
///   (`projection[n - 1]`) — the SAME expression the select list computes,
///   re-used over the source rows the sort runs on — so a bare-column ordinal
///   reads its slot and a computed one (`SELECT a + b … ORDER BY 1`) recomputes
///   the expression. An `n` outside `1 ... projection.count` faults
///   `SQLError.column` (spelled as the ordinal), as an unknown column would.
/// - `expression(.column(name))` with an unqualified `name` is EITHER an output
///   alias or an input column. A matching output alias wins (the ISO precedence
///   for a bare `ORDER BY` name), resolving to that projection item's lowered
///   `Term`; absent an alias, the name lowers as an ordinary input column
///   through `term`. A qualified column (`t.x`) is always an input reference.
/// - Any other `expression(e)` lowers directly over the input columns through
///   `term`.
///
/// `names` are the projection's per-item explicit-`AS` output aliases (else
/// `nil`), aligned index-for-index with `projection`. Only an explicit `AS`
/// introduces an alias a bare `ORDER BY` name may bind, so the surface is
/// REPRESENTATION-INDEPENDENT — a bare projected column contributes no output
/// name and `ORDER BY` resolves it as an input column whether the projection is
/// a `columns` or an `expressions` list. An alias two items share has no single
/// term to order on — the two aliases may compute different values, so the
/// result must not depend on select-list order — and a bare `ORDER BY` name
/// matching it is `SQLError.ambiguous`, as the grouped `Grouping.order` does.
private func order(_ order: Order, _ projection: Array<Term>,
                   _ names: Array<String?>,
                   term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Array<SortKey> {
  // Output aliases two or more projected items share, lowercased. A bare
  // `ORDER BY` name matching one is ambiguous rather than a silent first-match.
  var seen = Set<String>()
  var ambiguous = Set<String>()
  for name in names.compactMap({ $0?.lowercased() }) {
    if !seen.insert(name).inserted { ambiguous.insert(name) }
  }
  var keys = Array<SortKey>()
  keys.reserveCapacity(order.keys.count)
  for key in order.keys {
    let resolved: Term
    let column: Int?
    switch key.sort {
    case let .ordinal(position):
      guard position >= 1, position <= projection.count else {
        throw .column("\(position)")
      }
      resolved = projection[position - 1]
      column = position - 1
    case let .expression(expression):
      if case let .column(name) = expression, name.qualifier == nil,
          let index = names.firstIndex(where: {
            $0?.lowercased() == name.name.lowercased()
          }) {
        if ambiguous.contains(name.name.lowercased()) {
          throw .ambiguous(name.name)
        }
        resolved = projection[index]
        column = index
      } else {
        resolved = try term(expression)
        column = nil
      }
    }
    keys.append(SortKey(term: resolved, ascending: key.ascending,
                        column: column))
  }
  return keys
}

extension Schema {
  /// The ordinal of the column `column` names, validating its qualifier against
  /// `relation`.
  ///
  /// A single-relation query has one relation, so a qualifier — `relation`'s
  /// alias, else its table name — must name it; any other qualifier is
  /// `SQLError.column`, as a join rejects a qualifier naming neither side.
  internal func ordinal(of column: Column, in relation: Relation)
      throws(SQLError) -> Int {
    if let qualifier = column.qualifier,
        (relation.alias ?? relation.name) != qualifier {
      throw .column(column.name)
    }
    guard let ordinal = ordinal(of: column.name) else {
      throw .column(column.name)
    }
    return ordinal
  }

  /// The projected terms of `projection`, addressed by ordinal: a `*` or a
  /// bare-column list yields one `.slot(ordinal)` per column; an expression list
  /// lowers each expression to a term. The terms hold ordinals, which the
  /// engine remaps to slots after gathering the referenced ones.
  internal func terms(_ projection: Projection, in relation: Relation,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Array<Term> {
    switch projection {
    case .all:
      return (0 ..< width).map { .slot($0) }
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(.slot(ordinal(of: column, in: relation)))
      }
      return terms
    case let .expressions(projected):
      var terms = Array<Term>()
      terms.reserveCapacity(projected.count)
      for item in projected {
        try terms.append(term(item.expression, in: relation, routines,
                              subquery: subquery))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to an ordinal-addressed `Term`: a column to a
  /// `.slot(ordinal)`, a literal to a `.constant`, a call to an `.apply` over
  /// its lowered arguments.
  internal func term(_ expression: Expression, in relation: Relation,
                     _ routines: Routines = [:],
                     subquery: Subquery = .unsupported)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      return try .slot(ordinal(of: column, in: relation))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, in: relation, routines,
                                subquery: subquery))
      }
      // Case-fold the routine name to the SQL identifier rule the `Routines`
      // lookup uses (lowercase), so two calls that spell the same routine with
      // different case — `UPPER(x)` and `upper(x)` — lower to an IDENTICAL
      // `.apply` term. Term identity then agrees with dispatch (which folds on
      // lookup), so the DISTINCT ORDER BY guard's projected-term match, the
      // aggregate dedup, and every other term comparison stay consistent.
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, in: relation, routines,
                                  subquery: subquery),
                         term(rhs, in: relation, routines, subquery: subquery))
    case let .case(whens, otherwise):
      // Lower each branch's guard predicate to a `Filter` and its result to a
      // `Term`, and the `ELSE` to a `Term`, over this relation's resolution.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        let gate = try lower(branch.when, in: relation, routines,
                             subquery: subquery)
        try branches.append((gate, term(branch.then, in: relation, routines,
                                        subquery: subquery)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, in: relation, routines, subquery: subquery)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — so the executor COERCES the selected
      // branch's value to the type the schema advertises. Derive it against a
      // one-relation scope, this Schema's own resolution surface.
      let scope = Scope([(relation, self)])
      let type = try scope.derive(whens, otherwise, routines,
                                  subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand and attach the target type; the executor converts the
      // evaluated value to it (`Value.cast(to:)`).
      return try .cast(term(operand, in: relation, routines,
                            subquery: subquery), type)
    case let .coalesce(arguments):
      // Lower each argument to a `Term` over this relation and hold them in a
      // first-class `Term.coalesce` so each is evaluated ONCE. `type` is the
      // unified argument type the selected value coerces to, derived against a
      // one-relation scope.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, in: relation, routines,
                                 subquery: subquery))
      }
      let scope = Scope([(relation, self)])
      let type = try scope.derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      // Lower both operands to `Term`s over this relation and hold them in a
      // first-class `Term.nullif` so each is evaluated ONCE.
      return try .nullif(term(lhs, in: relation, routines, subquery: subquery),
                         term(rhs, in: relation, routines, subquery: subquery))
    case let .subquery(query):
      // A scalar subquery lowers to a `Term.subquery` reading its collapsed
      // value from the run-time cache, carrying its occurrence `Subkey` and
      // single-column type, the single-column arity enforced from the compiled
      // width (no cursor). The query is UNCORRELATED — it reads no cell here.
      return try subquery.scalar(query)
    case .aggregate:
      // An aggregate has no per-row meaning — it folds over a group — so it may
      // not appear in a `WHERE`, a join `ON`, or a non-aggregate projection.
      throw .unsupported("an aggregate is not allowed here")
    }
  }

  /// The resolved sort keys an `ORDER BY` lowers to, in major-to-minor order —
  /// each key's ISO `<sort key>` a `Term` over this relation's ordinals, its
  /// direction preserved.
  ///
  /// `projection` are the query's already-lowered projection terms and `names`
  /// their output names, so an ordinal or an output-alias key resolves to the
  /// matching select-list item's `Term` and an ordinary expression key lowers
  /// fresh over this relation (see the free `order`).
  internal func order(_ order: Order, in relation: Relation,
                      _ projection: Array<Term>, _ names: Array<String?>,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    try SQLEngine.order(order, projection, names) {
      expression throws(SQLError) in
      try term(expression, in: relation, routines, subquery: subquery)
    }
  }

  internal func lower(_ predicate: Predicate, in relation: Relation,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Filter {
    try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
      try term(expression, in: relation, routines, subquery: subquery)
    }, subquery: subquery)
  }
}

// MARK: - Join scope

/// The relations of a join chain, addressed in one combined ordinal space.
///
/// A join chain lays its relations end to end: relation `i` occupies the
/// combined ordinals `[offset_i, offset_i + extent_i)`, where `offset_i` is the
/// sum of the `extent`s of the relations before it. Using each relation's
/// `extent` — its real `width` plus the virtual columns it exposes — rather than
/// its `width` keeps a relation's virtual columns (an `Id`, an owner foreign
/// key) on its own side rather than colliding with the next relation's space. A
/// `Scope` resolves a possibly qualified `SQLEngine.Column` into that combined
/// space so the engine's `Filter`, projection, and order all address cells
/// uniformly across the chain. A qualifier names a relation by its alias, else
/// its table name; an unqualified name resolves against every relation and is
/// ambiguous if more than one resolves it — as is a qualified name two
/// relations share an alias or table name for (a self-join or a duplicated
/// alias). Resolution reads only schemas, so the scope is escapable data over
/// the relations' `Schema`s.
internal struct Scope {
  /// One relation of the chain: its reference (for qualifier matching), its
  /// name-resolution schema, and its base offset in the combined space.
  private struct Member {
    let relation: Relation
    let schema: Schema
    let offset: Int
  }

  private let members: Array<Member>

  /// Builds a scope over `relations` — the `FROM` relation first, then each
  /// joined relation in source order — laying each past the previous one's
  /// `extent`.
  internal init(_ relations: Array<(Relation, Schema)>) {
    var members = Array<Member>()
    members.reserveCapacity(relations.count)
    var offset = 0
    for (relation, schema) in relations {
      members.append(Member(relation: relation, schema: schema, offset: offset))
      offset += schema.extent
    }
    self.members = members
  }

  /// The combined-space base offset and extent of each relation, in chain order
  /// — the layout the engine packs referenced ordinals against.
  internal var layout: Array<(offset: Int, extent: Int)> {
    members.map { ($0.offset, $0.schema.extent) }
  }

  /// The relations' name-resolution schemas, in chain order — the surface the
  /// result-schema walk reads each relation's `names`/`types` off for a
  /// `SELECT *`.
  internal var schemas: Array<Schema> {
    members.map(\.schema)
  }

  /// The number of output columns `projection` yields over this scope — the
  /// count the lowered `terms(projection)` array carries, and the range a
  /// 1-based `ORDER BY` ordinal must fall in. A `*` expands to every relation's
  /// real `width` in chain order (never a virtual column); a bare-column or an
  /// expression list is its item count. It reads only schemas, matching the
  /// compile path's `projection.count` without lowering a term.
  internal func width(of projection: Projection) -> Int {
    switch projection {
    case .all:
      return schemas.reduce(0) { $0 + $1.width }
    case let .columns(columns):
      return columns.count
    case let .expressions(items):
      return items.count
    }
  }

  /// The value type of the real column at combined `ordinal` — the type the
  /// owning relation's schema types it, for the result-schema walk.
  ///
  /// A combined `ordinal` falls in exactly one relation's `[offset, offset +
  /// extent)` span; a real one (its local index `< width`) reads that schema's
  /// `types`. A virtual ordinal (`Id`, an owner foreign key) is not an ISO
  /// column and carries no schema type, so it reports `.integer` — the identity
  /// and foreign-key columns are integral.
  internal func type(at ordinal: Int) -> ValueType {
    for member in members {
      let local = ordinal - member.offset
      guard local >= 0, local < member.schema.extent else { continue }
      return local < member.schema.width ? member.schema.types[local]
                                         : .integer
    }
    return .integer
  }

  /// The value type of a `literal` operand — the domain of the value it stands
  /// for. Shared by both the schema and type-check surfaces.
  private func type(of literal: Literal) -> ValueType {
    switch literal {
    case .string: .text
    case .integer: .integer
    case .double: .double
    case .boolean: .boolean
    case .blob: .blob
    }
  }

  /// DERIVES the nominal value type a scalar `expression` yields WITHOUT
  /// faulting on an operand: a bare column its source type, a literal its own,
  /// a standard aggregate its result domain (`COUNT`/`SUM`/`AVG` numeric,
  /// `MIN`/`MAX` the operand's type), a scalar call its routine's declared
  /// return type (`returns`, else the `.integer` default for an unregistered
  /// name), a binary arithmetic expression a numeric result (a double when
  /// either operand is a double, else an integer). It resolves the column
  /// ordinal (so an unknown or ambiguous reference faults as a projection
  /// would) but reads no cursor and never faults on an operand's kind, so a
  /// schema resolves even for an expression a zero-row limit or a short-circuit
  /// makes unreachable (a run never evaluates it, so it cannot fault).
  ///
  /// This is the SCHEMA surface. `validate(_:_:)` is the type-check surface: it
  /// faults exactly as a run would on a bad operand or an unknown/misused call.
  internal func derive(_ expression: Expression, _ routines: Routines = [:],
                       subquery: Subquery = .unsupported)
      throws(SQLError) -> ValueType {
    return switch expression {
    case let .column(column):
      try type(at: ordinal(of: column))
    case let .literal(literal):
      type(of: literal)
    case let .call(name, _):
      routines[name]?.returns ?? .integer
    case let .aggregate(function, operand, _, _):
      switch function {
      // `COUNT` always counts rows to an integer; `AVG` folds to a double;
      // `SUM`/`MIN`/`MAX` take the operand's own type (an integer for `.star`).
      case .count: .integer
      case .avg: .double
      case .sum, .min, .max:
        switch operand {
        case .star: .integer
        case let .expression(argument):
          try derive(argument, routines, subquery: subquery)
        }
      }
    case let .binary(.concatenate, lhs, rhs):
      // `||` yields text; the operands' own types do not shape it, but derive
      // both for resolution — an unresolved column faults `SQLError.column`
      // (`Missing || 'x'`) — exactly as the arithmetic `.binary` branch does.
      try concatenation(lhs, rhs, routines, subquery: subquery)
    case let .binary(_, lhs, rhs):
      try [derive(lhs, routines, subquery: subquery),
           derive(rhs, routines, subquery: subquery)].contains(.double)
          ? .double : .integer
    case let .case(whens, otherwise):
      // The result type is the unification of every REACHABLE branch result (and
      // the `ELSE`) — the executor's short-circuit means an unreachable branch
      // (a constant-false guard, or any branch after a constant-true one) never
      // yields a value, so it cannot shape the column's type. The reachable
      // result types must UNIFY; a definitively-irreconcilable clash (text
      // beside an integer) faults `SQLError.operand` here too, so this lowering
      // surface and the faulting `validate` AGREE. A `CASE` always has at least
      // one `WHEN`; when none is reachable (every guard constant-false, no
      // reachable `ELSE`) the run yields NULL, for which `.integer` is the
      // schema default.
      try derive(whens, otherwise, routines, subquery: subquery)
    case let .cast(operand, type):
      // A cast's static type is the target type; the conversion is nominal, so
      // the operand's own type does not shape it. Derive the operand anyway for
      // its ordinal resolution — an unknown/ambiguous column faults as a
      // projection would.
      try derive(cast: operand, to: type, routines, subquery: subquery)
    case let .coalesce(arguments):
      // The result type is the unification of the arguments (the same
      // `ValueType.unified` reduction a `CASE`'s results take), the type the
      // selected value coerces to.
      try unified(arguments, routines, subquery: subquery)
    case let .nullif(lhs, rhs):
      // NULLIF yields either `v1` or NULL, so the column takes `v1`'s type —
      // but derive BOTH operands for resolution, returning the LHS type: an
      // unresolved column faults `SQLError.column` (`NULLIF(1, Missing)`) on
      // this derive-only surface too, mirroring the `||`/arithmetic derive
      // branch rather than leaving the RHS unresolved.
      try nullif(lhs, rhs, routines, subquery: subquery)
    case let .subquery(query):
      // A scalar subquery's static type is its single-column output type — the
      // compile pre-pass recorded it beside the width for every subquery, so
      // `derive` reads it (enforcing the single-column arity). A surface with
      // no catalog holds none and faults, rejecting the subquery rather than
      // mis-typing it, so this derive and the run's lowering AGREE.
      try subquery.scalar(type: query)
    }
  }

  /// The result type of `NULLIF(v1, v2)` under `derive` — `v1`'s type, deriving
  /// BOTH operands for resolution first: NULLIF yields either `v1` or NULL, so
  /// its own RHS type does not shape the column, but an unresolved column still
  /// faults `SQLError.column`, mirroring the `||`/arithmetic derive branch. So
  /// `NULLIF(1, Missing)` faults `.column` on the derive-only paths
  /// (`columns(of:validate:false)`, an unreachable projection) where `validate`
  /// never runs.
  private func nullif(_ lhs: Expression, _ rhs: Expression,
                      _ routines: Routines,
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> ValueType {
    let type = try derive(lhs, routines, subquery: subquery)
    _ = try derive(rhs, routines, subquery: subquery)
    return type
  }

  /// The `.text` type of `lhs || rhs`, deriving both operands for resolution
  /// first: the result is always text and the operands' own types do not shape
  /// it, but an unresolved column still faults `SQLError.column`, mirroring the
  /// arithmetic `.binary` derive branch.
  private func concatenation(_ lhs: Expression, _ rhs: Expression,
                             _ routines: Routines,
                             subquery: Subquery = .unsupported)
      throws(SQLError) -> ValueType {
    _ = try derive(lhs, routines, subquery: subquery)
    _ = try derive(rhs, routines, subquery: subquery)
    return .text
  }

  /// The target `type` of a `CAST`, deriving `operand` for its ordinal
  /// resolution — a schema-surface non-faulting derive of the operand — and
  /// discarding its type, the conversion being nominal.
  private func derive(cast operand: Expression, to type: ValueType,
                      _ routines: Routines,
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> ValueType {
    _ = try derive(operand, routines, subquery: subquery)
    return type
  }

  /// The unification of the types of `arguments` — the `ValueType.unified`
  /// reduction a `CASE`'s reachable results and a `COALESCE`'s arguments both
  /// take. A definitively-irreconcilable pair (a text beside an integer) faults
  /// `SQLError.operand`; a mixed integer/double pair widens to `double`. The
  /// list is never empty (the parser requires ≥ 2 COALESCE arguments).
  ///
  /// Only a SELECTABLE argument shapes the type. A run skips an argument
  /// whose value is NULL and moves on, so an argument folding to a constant
  /// `.null` (`constant(_ expression:)`) can NEVER be the result — its type is
  /// derived (an unknown column still faults) but is NOT merged, exactly as a
  /// `CASE` omits an unreachable branch's result type. And an argument that is
  /// the definite selection (`selects(_:)` — a constant NON-NULL value, or a
  /// `COUNT` aggregate that is always non-NULL) sets the type and makes every
  /// LATER argument unreachable — mirroring a `CASE`'s reachable-branch
  /// unification and the faulting `validate`'s stop.
  private func unified(_ arguments: Array<Expression>,
                       _ routines: Routines,
                       subquery: Subquery = .unsupported)
      throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try derive(argument, routines, subquery: subquery)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is derived (for its errors) but skipped: it can never
        // be returned, so its type must not shape the column.
        continue
      }
      guard !selects(argument, routines) else {
        // A definite selection: merge its type and stop, as every later
        // argument is unreachable.
        return try merged(type, next)
      }
      type = try merged(type, next)
    }
    return type ?? .integer
  }

  /// Whether `argument` is a COALESCE's definite selection — an argument the
  /// executor's short-circuit is GUARANTEED to return, making every later
  /// argument unreachable (neither validated nor unified). That holds when it
  /// folds to a constant NON-NULL value (`constant(_ expression:)`), or when it
  /// is a `COUNT` aggregate: `COUNT` alone among the aggregates always yields a
  /// row count of 0 or more, never NULL, so it always selects — while `SUM` /
  /// `MIN` / `MAX` / `AVG` are NULL over an empty group and so do NOT stop.
  private func selects(_ argument: Expression, _ routines: Routines) -> Bool {
    return switch argument {
    case .aggregate(.count, _, _, _): true
    default: constant(argument, routines).map { $0 != .null } ?? false
    }
  }

  /// The unification of a COALESCE's running result type with the `next`
  /// selectable argument's type — `next` when there is no running type yet,
  /// else their `ValueType.unified`, faulting `SQLError.operand` on an
  /// irreconcilable pair (a text beside an integer). Shared by the `derive`
  /// (`unified`) and `validate` (`coalesce`) surfaces so both merge only a
  /// selectable argument's type identically.
  private func merged(_ running: ValueType?, _ next: ValueType)
      throws(SQLError) -> ValueType {
    guard let running else { return next }
    guard let unified = running.unified(with: next) else {
      throw .operand("COALESCE arguments have irreconcilable types")
    }
    return unified
  }

  /// The nominal type of a `CASE` under `derive` — the unification of its
  /// REACHABLE result types, and `.integer` when no branch is reachable (the
  /// run yields NULL). The reachable result types must UNIFY (`unified`):
  /// a definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, so this lowering surface AGREES with the
  /// faulting `validate` (`conditional`) — a mixed integer/double `CASE` still
  /// widens to `double`.
  internal func derive(_ whens: Array<When>, _ otherwise: Expression?,
                       _ routines: Routines,
                       subquery: Subquery = .unsupported)
      throws(SQLError) -> ValueType {
    let results = reachable(whens, otherwise, routines)
    guard !results.isEmpty else { return .integer }
    var type = try derive(results[0], routines, subquery: subquery)
    for result in results.dropFirst() {
      let next = try derive(result, routines, subquery: subquery)
      guard let unified = type.unified(with: next) else {
        throw .operand("CASE results have irreconcilable types")
      }
      type = unified
    }
    return type
  }

  /// The result expressions of a `CASE` the executor's short-circuit can REACH,
  /// in branch order: a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result and is dropped; a `WHEN` whose guard is statically
  /// constant-TRUE is itself reachable and keeps every EARLIER reachable branch
  /// (a row an earlier row-dependent guard matches takes that branch, never
  /// reaching this one), but makes every STRICTLY-LATER `WHEN` and the `ELSE`
  /// unreachable; an `ELSE` is reachable only when no guard is constant-TRUE. A
  /// guard that is not statically decidable (`constant` is `nil`) leaves its
  /// result reachable.
  private func reachable(_ whens: Array<When>, _ otherwise: Expression?,
                         _ routines: Routines)
      -> Array<Expression> {
    var results = Array<Expression>()
    for branch in whens {
      switch constant(branch.when, routines) {
      case false: continue
      case true: results.append(branch.then); return results
      case nil: results.append(branch.then)
      }
    }
    if let otherwise { results.append(otherwise) }
    return results
  }

  /// The value type a scalar `expression` yields, VALIDATING each operand and
  /// call exactly as a run would fault: an aggregate or arithmetic over a
  /// non-numeric operand (`SQLError.operand`), a call to an unregistered
  /// routine (`SQLError.function`), a bad arity or argument kind
  /// (`SQLError.argument`), a `/` by a literal zero (`SQLError.divide`), or a
  /// deterministic overflow of two folded literal operands
  /// (`SQLError.magnitude`) faults precisely where a run would raise it. It
  /// resolves column ordinals and reads no cursor, so it type-checks a query
  /// without executing it.
  ///
  /// This is the TYPE-CHECK surface. `derive(_:_:)` is the non-faulting schema
  /// surface, which only DERIVES the nominal output type.
  internal func validate(_ expression: Expression, _ routines: Routines = [:],
                         subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    switch expression {
    case let .column(column):
      try type(at: ordinal(of: column))
    case let .literal(literal):
      type(of: literal)
    case let .call(name, arguments):
      try call(name, over: arguments, routines, subquery: subquery)
    case let .aggregate(function, operand, _, filter):
      try aggregate(function, over: operand, filter: filter, routines,
                    subquery: subquery)
    case let .binary(op, lhs, rhs):
      try arithmetic(op, lhs, rhs, routines, subquery: subquery)
    case let .case(whens, otherwise):
      try conditional(whens, otherwise, routines, subquery: subquery)
    case let .cast(operand, type):
      try validate(cast: operand, to: type, routines, subquery: subquery)
    case let .coalesce(arguments):
      try coalesce(arguments, routines, subquery: subquery)
    case let .nullif(lhs, rhs):
      try nullif(validate: lhs, rhs, routines, subquery: subquery)
    case let .subquery(query):
      // A scalar subquery's static type is its single-column output type — the
      // pre-pass validated and compiled its inner query and derived the type,
      // enforcing the single-column arity (else `SQLError.arity`), so this
      // reads that type exactly as the run's lowering does. A surface with no
      // catalog holds none and faults, rejecting the subquery unvalidated.
      try subquery.type(query)
    }
  }

  /// The result type of `COALESCE(v1, v2, …)`, validating each REACHABLE
  /// argument as a run would fault and unifying only the SELECTABLE ones'
  /// types (`merged`). A definitively-irreconcilable pair (a text argument
  /// beside an integer) faults `SQLError.operand`, as the column cannot be two
  /// kinds; a mixed integer/double pair widens to `double`.
  ///
  /// The executor returns the first NON-NULL argument and never evaluates a
  /// later one, so an argument that is the definite selection (`selects(_:)` —
  /// a constant NON-NULL value, or a `COUNT` aggregate that is always non-NULL)
  /// makes every LATER argument unreachable — those are NOT validated
  /// (`COALESCE(1, missing_udf())` and `COALESCE(COUNT(*), missing_udf())` both
  /// type-check), exactly as a constant-TRUE `CASE` guard makes later branches
  /// unreachable.
  ///
  /// An argument that folds to a constant `.null` is validated (for its own
  /// errors) but its type is NOT merged: a run skips a NULL and moves on, so
  /// that argument can never be returned — merging its declared type would
  /// reject `COALESCE(null_text(), 1)`, a text arm that can only yield the
  /// integer, exactly as a `CASE` omits a skipped branch's result type. An
  /// undecidable argument (`nil`) may be selected, so its type is merged and
  /// the walk continues.
  private func coalesce(_ arguments: Array<Expression>, _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try validate(argument, routines, subquery: subquery)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is validated (for its errors) but skipped: it can
        // never be returned, so its type must not shape the column.
        continue
      }
      guard !selects(argument, routines) else {
        // A definite selection: merge its type and stop, as every later
        // argument is unreachable and unvalidated.
        return try merged(type, next)
      }
      type = try merged(type, next)
    }
    return type ?? .integer
  }

  /// The result type of `NULLIF(v1, v2)`, validating both operands as a run
  /// would fault. The result is either `v1` or NULL, so the column takes `v1`'s
  /// type; `v2` need not unify with it (a run compares them under `matches`,
  /// which yields FALSE across kinds without faulting), so it is validated for
  /// its own errors (an unknown column, a bad call) but does not shape the
  /// type.
  private func nullif(validate lhs: Expression, _ rhs: Expression,
                      _ routines: Routines,
                      subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    let type = try validate(lhs, routines, subquery: subquery)
    _ = try validate(rhs, routines, subquery: subquery)
    return type
  }

  /// The target `type` of a `CAST`, VALIDATING `operand` for real errors
  /// (unknown column, bad call arity, …) as a run would fault, and REJECTING a
  /// cast the runtime could never perform before advertising the target type.
  ///
  /// A cast whose (operand type → target type) PAIR is structurally
  /// unsupported — a boolean to a number, a number to a blob — faults `42846`
  /// for EVERY value of the operand's kind, so `SELECT CAST(TRUE AS INTEGER)`
  /// would otherwise advertise an integer column though executing it
  /// unconditionally throws. `ValueType.castable(to:)` — the same structural
  /// truth the runtime cast consults — rejects that pair here, at validation.
  ///
  /// A castable-but-VALUE-dependent pair still passes: a `text` to a number, or
  /// a `blob` to `text`, is a supported pair whose fault (`22018`/`22003`)
  /// depends on the value, so a reachable good value runs — `CAST('1' AS
  /// INTEGER)` type-checks. The exception is a CONSTANT operand that folds and
  /// ALWAYS fails: `CAST('abc' AS INTEGER)` is unparseable for the one value it
  /// can have, so a trial cast of the folded constant rejects it too.
  ///
  /// The constant fold runs FIRST, before the structural pair rejection: a
  /// constant operand casts to ONE value, so its trial cast decides the cast
  /// outright — it ALLOWS a statically-NULL operand (`CAST(CASE WHEN 1 = 0
  /// THEN 1 END AS BLOB)` folds to `.null`, which casts to ANY target) even
  /// where the operand's DERIVED type would make the pair structurally
  /// unsupported, and it still REJECTS a constant that always fails. Only a
  /// NON-constant operand, whose value is unknown at validation, falls to the
  /// structural pair check.
  private func validate(cast operand: Expression, to type: ValueType,
                        _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    let source = try validate(operand, routines, subquery: subquery)
    // A constant operand casts to one value only, so its trial cast is the
    // whole decision: it ALLOWS a folded NULL to any target and REJECTS a
    // spelling that always faults (`CAST('abc' AS INTEGER)`). A non-constant
    // operand folds to `nil`, so the structural pair check rejects a kind that
    // could never cast (`CAST(<boolean column> AS INTEGER)` → `42846`).
    if let value = constant(operand, routines) {
      _ = try value.cast(to: type)
    } else if !source.castable(to: type) {
      throw .state("42846",
                   "cannot cast \(source.domain) to \(type.domain)")
    }
    return type
  }

  /// The result type of a `CASE`, validating each REACHABLE branch as a run
  /// would fault and honouring the executor's short-circuit: each evaluated
  /// `WHEN` guard is a boolean predicate whose operands are validated (`check`);
  /// only a REACHABLE result expression is validated; and the reachable result
  /// types must UNIFY to one type (`ValueType.unified`) — a
  /// definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, as a query cannot yield a column of two kinds. A
  /// mixed integer/double `CASE` widens to `double`.
  ///
  /// The executor takes the first TRUE guard's result and never evaluates a
  /// later branch, so a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result — its operands are NOT validated (`CASE WHEN 1 = 0 THEN
  /// Name + 1 ELSE 0 END` type-checks). A constant-TRUE guard is itself
  /// reachable and KEEPS every earlier reachable branch — a row an earlier
  /// row-dependent guard matches takes that branch, never reaching the
  /// constant-TRUE one — so those earlier results are still validated (`CASE WHEN
  /// Id = 1 THEN Name + 1 WHEN 1 = 1 THEN 0 END` faults on the reachable `Id = 1`
  /// branch's `Name + 1`); it makes only every STRICTLY-LATER guard, result, and
  /// the `ELSE` unreachable. A REACHABLE bad operand (`WHEN Id = 1 THEN Name +
  /// 1`) still faults. When no branch is reachable the run yields NULL, typed
  /// `.integer` (the schema default), with no result to validate.
  private func conditional(_ whens: Array<When>, _ otherwise: Expression?,
                           _ routines: Routines,
                           subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    var results = Array<Expression>()
    var decided = false
    for branch in whens {
      // The guard up to (and including) the decisive one is evaluated, so
      // validate its operands; a constant-FALSE guard's result is unreachable
      // (skip it), a constant-TRUE one is reachable but makes every LATER branch
      // unreachable — so keep the earlier results and this one, then stop.
      try check(branch.when, routines, subquery: subquery)
      switch constant(branch.when, routines) {
      case false: continue
      case true: results.append(branch.then); decided = true
      case nil: results.append(branch.then)
      }
      if decided { break }
    }
    if !decided, let otherwise { results.append(otherwise) }
    guard !results.isEmpty else { return .integer }
    var type = try validate(results[0], routines, subquery: subquery)
    for result in results.dropFirst() {
      let next = try validate(result, routines, subquery: subquery)
      guard let unified = type.unified(with: next) else {
        throw .operand("CASE results have irreconcilable types")
      }
      type = unified
    }
    return type
  }

  /// The result type of the scalar routine `name` called over `arguments`,
  /// validating its declared signature exactly as a run would fault: an
  /// unregistered name faults `SQLError.function`; the argument count must lie
  /// in the routine's `minimum ... parameters.count` arity (a fixed-arity
  /// routine has `minimum == parameters.count`, so this is exact for it, and an
  /// optional-tail routine like `OVERLAY` admits either count); and each
  /// SUPPLIED argument's static type must equal the declared parameter type. A
  /// nullable column of the DECLARED
  /// type passes — statically it carries its declared type and a run-time NULL
  /// propagates — so only a definitively-wrong type (text where an integer is
  /// required) is rejected, mirroring a routine like `BITAND` throwing
  /// `SQLError.argument` on a non-integer non-NULL value. Each argument is
  /// validated too, so a type error nested in a call — `BITAND(Name + 1, 1)`
  /// over text — faults exactly as a run would, rather than the call reporting
  /// its return type over an un-evaluable argument `compile` resolved but never
  /// type-checked.
  private func call(_ name: String, over arguments: Array<Expression>,
                    _ routines: Routines,
                    subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    guard let routine = routines[name] else { throw .function(name) }
    guard (routine.minimum ... routine.parameters.count)
        .contains(arguments.count) else {
      let arity = routine.minimum == routine.parameters.count
          ? "\(routine.parameters.count)"
          : "\(routine.minimum) to \(routine.parameters.count)"
      throw .argument("\(name) takes \(arity) arguments")
    }
    for (argument, expected) in zip(arguments, routine.parameters) {
      let type = try validate(argument, routines, subquery: subquery)
      guard type == expected else {
        throw .argument("\(name) requires \(expected.domain) arguments")
      }
    }
    return routine.returns
  }

  /// The result type of `function` folded over `operand`, validating the
  /// operand as a run would fault. `COUNT` counts rows (`.integer`);
  /// `MIN`/`MAX` take the operand's own type — they compare, so any comparable
  /// value folds. `SUM`/`AVG` fold NUMERICALLY: `SUM` yields the operand's
  /// numeric type, `AVG` a double, so both REQUIRE a numeric operand — over
  /// text, boolean, or blob `Aggregate.fold` faults `SQLError.operand` on the
  /// first non-NULL value, so typing faults the same way rather than
  /// advertising `AVG(Name)` as a double or `SUM(Name)` as text for a query
  /// that cannot fold its rows.
  private func aggregate(_ function: Aggregate, over operand: Aggregand,
                         filter: Predicate?, _ routines: Routines,
                         subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    // A `FILTER (WHERE …)` is a per-row gate, so it type-checks as an ordinary
    // predicate — its columns resolve and its comparisons are well-typed — and
    // it may not itself contain an aggregate (ISO forbids an aggregate in a
    // filter's search condition, as it has no per-row meaning).
    if let filter {
      guard !filter.aggregated else {
        throw .unsupported("an aggregate is not allowed in a FILTER")
      }
      try check(filter, routines, subquery: subquery)
      // A FILTER that STATICALLY cannot admit a row makes the operand
      // unreachable: the executor gates on a definite TRUE (a FALSE or UNKNOWN
      // row is skipped, and the argument is evaluated only AFTER the gate), so
      // an operand behind a statically non-TRUE filter never folds. `SUM(1 / 0)
      // FILTER (WHERE 1 = 0)` thus runs to the empty result (NULL) — do NOT
      // validate the dead operand, or a fault it could never raise (a divide by
      // zero) would wrongly reject a runnable query. The aggregate is
      // statically empty, so advertise its declared/derived result type without
      // the operand's run-time-fault check (`dead(_:_:)` proves the filter
      // ROW-INDEPENDENTLY never TRUE); a filter that could be TRUE still
      // validates the operand as a bare aggregate does.
      if dead(filter, routines) {
        return try empty(function, over: operand, routines)
      }
    }
    switch function {
    case .count:
      // `COUNT(expr)` evaluates `expr` per row to test it is non-NULL, so
      // validate the operand (`COUNT(*)` has none); the result is always an
      // integer count.
      if case let .expression(argument) = operand {
        _ = try validate(argument, routines, subquery: subquery)
      }
      return .integer
    case .min, .max:
      switch operand {
      case .star: return .integer
      case let .expression(argument):
        return try validate(argument, routines, subquery: subquery)
      }
    case .sum, .avg:
      let type: ValueType = switch operand {
      case .star: .integer
      case let .expression(argument):
        try validate(argument, routines, subquery: subquery)
      }
      if !type.numeric { throw .operand("operands must be numeric") }
      return function == .avg ? .double : type
    }
  }

  /// The result type of `function` folded over `operand` when a statically
  /// non-TRUE `FILTER` makes the fold empty — the operand is UNREACHABLE, so it
  /// is DERIVED for its type (resolving a column) but NOT validated for a
  /// run-time fault it can never raise (a divide by zero, a non-numeric SUM).
  /// The empty fold yields `COUNT` `0` and every other aggregate NULL, so the
  /// type is the set-function's declared/derived one, mirroring `aggregate` but
  /// non-faulting on the dead operand: `COUNT`/`AVG` fixed, `SUM`/`MIN`/`MAX`
  /// the operand's own derived type (`.integer` for `.star`).
  private func empty(_ function: Aggregate, over operand: Aggregand,
                     _ routines: Routines) throws(SQLError) -> ValueType {
    switch function {
    case .count:
      return .integer
    case .avg:
      return .double
    case .sum, .min, .max:
      switch operand {
      case .star: return .integer
      case let .expression(argument): return try derive(argument, routines)
      }
    }
  }

  /// Whether `filter` is ROW-INDEPENDENTLY never TRUE — so a `FILTER`'s gate
  /// (which admits a row only on a definite TRUE) can never admit one and the
  /// aggregate operand behind it is UNREACHABLE. An `AND` is TRUE only when
  /// EVERY conjunct is TRUE, so a single conjunct that is row-independently
  /// non-TRUE kills the whole conjunction regardless of the others: flatten the
  /// top-level `Predicate.and` spine (`a AND (b AND c)` to `a, b, c` — each
  /// non-AND node one conjunct, not descending into `OR`) and prove it dead
  /// when ANY conjunct folds definitely FALSE (`constant(_:)` `false`), or is
  /// `settled` (row-independent) and folds to UNKNOWN (`constant(_:)` `nil`).
  /// This subsumes the whole-filter case (a settled-non-TRUE filter is a lone
  /// conjunct). It stays SOUND — only a PROVABLY non-TRUE conjunct kills the
  /// filter: a row-dependent conjunct (could be TRUE per row) or a settled-TRUE
  /// one does NOT, so those still validate the operand.
  private func dead(_ filter: Predicate, _ routines: Routines) -> Bool {
    var conjuncts: Array<Predicate> = [filter]
    var index = 0
    while index < conjuncts.count {
      if case let .and(lhs, rhs) = conjuncts[index] {
        conjuncts[index] = lhs
        conjuncts.append(rhs)
      } else {
        index += 1
      }
    }
    return conjuncts.contains { conjunct in
      let folded = constant(conjunct, routines)
      return folded == false
          || (folded == nil && settled(conjunct, routines))
    }
  }

  /// The result type of `lhs op rhs` — a double when either arithmetic operand
  /// is a double (`Age + 1.5`), an integer for two integer operands, and text
  /// for `||` — validating each operand's kind as a run would fault: an
  /// arithmetic operator over a text/boolean/blob operand has no arithmetic and
  /// `||` over a non-text operand has no concatenation (`Arithmetic.apply`
  /// faults `SQLError.operand`); a `/` by a literal zero is rejected up front
  /// (`SQLError.divide`); and two literal operands are folded to reject a
  /// deterministic overflow (`SQLError.magnitude`). Typing thus faults as a run
  /// would rather than advertise a header no row can produce.
  private func arithmetic(_ op: Arithmetic, _ lhs: Expression,
                          _ rhs: Expression,
                          _ routines: Routines,
                          subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    let left = try validate(lhs, routines, subquery: subquery)
    let right = try validate(rhs, routines, subquery: subquery)
    if case .concatenate = op {
      // Both operands are validated above for their OWN errors. `||` yields
      // text and needs two text operands — UNLESS one folds to a static NULL,
      // in which case `Arithmetic.apply` returns NULL BEFORE it inspects EITHER
      // kind, so the whole expression yields NULL and runs whatever the other
      // operand's type (as the CAST path admits a folded NULL to any target):
      // `(CASE WHEN 1 = 0 THEN 1 END) || 1` runs. A non-text, non-NULL pairing
      // faults exactly as the run does.
      guard left == .text && right == .text
              || vanishing(lhs, routines) || vanishing(rhs, routines) else {
        throw .operand("|| operands must be text")
      }
      return .text
    }
    guard left.numeric, right.numeric else {
      throw .operand("operands must be numeric")
    }
    // A literal-zero divisor faults `Arithmetic.apply` on the first row it
    // divides, so reject it statically; a non-literal divisor is per row.
    if case .divide = op, zero(rhs) { throw .divide }
    // Two literal operands fold to a constant, so a deterministic magnitude
    // fault (integer overflow, a non-finite double) hits every row the
    // projection reaches — a FROM-less SELECT at once. Fold them so the schema
    // rejects the column rather than advertise a header no row yields.
    if case let .literal(lhs) = lhs, case let .literal(rhs) = rhs {
      _ = try op.apply(value(of: lhs), value(of: rhs))
    }
    return left == .double || right == .double ? .double : .integer
  }

  /// Whether `expression` folds to a static NULL — a row-independent constant
  /// NULL. A `||` with a vanishing operand yields NULL before its
  /// `Arithmetic.apply` inspects EITHER operand's kind, so the whole expression
  /// is valid whatever the other operand's type, mirroring the CAST validation
  /// path that admits a folded NULL to any target — so a no-match `CASE` typed
  /// `.integer` that yields NULL lets `(CASE WHEN 1 = 0 THEN 1 END) || 1` run.
  private func vanishing(_ expression: Expression, _ routines: Routines)
      -> Bool {
    if case .null? = constant(expression, routines) { true } else { false }
  }

  /// Whether `expression` is a literal zero — the statically-known divisor a
  /// `/` would fault on.
  private func zero(_ expression: Expression) -> Bool {
    switch expression {
    case .literal(.integer(0)): true
    case let .literal(.double(value)): value == 0
    default: false
    }
  }

  /// Type-checks every operand expression in `predicate` — a comparison's two
  /// sides, an `IS NULL` operand — recursing through `AND`/`OR`/`NOT`. It types
  /// each for the side effect of validation (an operand or function fault a run
  /// would raise) and discards the result. A `left op :parameter` bound
  /// comparison is NOT checked: with no binding (the schema default) the run
  /// yields UNKNOWN without evaluating the left term.
  ///
  /// It respects the executor's short-circuit: `false AND rhs` and `true OR
  /// rhs` never evaluate `rhs` (`evaluate` returns on the left arm), so a right
  /// arm a STATICALLY-false `AND` (or true `OR`) guards is unreachable and is
  /// not type-checked — `WHERE 1 = 0 AND Name + 1 = 2` runs, so its schema
  /// resolves rather than faulting on the unreachable `Name + 1`.
  func check(_ predicate: Predicate,
             _ routines: Routines = [:],
             subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      _ = try validate(left, routines, subquery: subquery)
      _ = try validate(right, routines, subquery: subquery)
    case let .exists(query, _):
      // Validate the inner UNCORRELATED query as the run's lowering does — it
      // resolves and type-checks against the enclosing catalog, so a bad column
      // or routine inside it faults at validation, matching what a run rejects.
      try subquery.validate(query)
    case let .within(operand, query, _):
      // Validate the operand AND the inner query, and enforce the single-column
      // arity the lowering does (`SQLError.arity`), so schema validation
      // matches execution — the recurring lesson that the two must not diverge.
      _ = try validate(operand, routines, subquery: subquery)
      try subquery.validate(query)
      let width = try subquery.width(query)
      guard width == 1 else { throw .arity(1, width) }
    case let .quantified(operand, _, _, query):
      // As `within`: validate the operand and the inner query, and enforce the
      // single-column arity the lowering does (`SQLError.arity`), so schema
      // validation matches execution.
      _ = try validate(operand, routines, subquery: subquery)
      try subquery.validate(query)
      let width = try subquery.width(query)
      guard width == 1 else { throw .arity(1, width) }
    case .bound:
      // `left op :parameter` with no binding — the schema default `[:]` —
      // yields UNKNOWN without evaluating the left term, so a run just produces
      // no rows; schema validation has no bindings, so it does not evaluate it.
      break
    case let .null(operand, _):
      _ = try validate(operand, routines, subquery: subquery)
    case let .membership(operand, values, _):
      // `x IN (v, …)` lowers to `x = v OR …`, so type it as those comparisons:
      // validate the operand and each value for real errors (unknown column,
      // bad arity, …). A cross-kind element (text in an integer list) is NOT
      // rejected: the lowered `operand = element` comparison yields FALSE at
      // runtime via `Row.matches` without faulting, so a row still runs (and
      // may match a like-kind element), and the schema check must accept what
      // the run accepts — rejecting it here would diverge from the run.
      //
      // The OR-chain short-circuits: a DEFINITE constant match (`x = v` folds
      // TRUE, both row-independent constants) makes the whole `IN` TRUE and
      // leaves every later element unreachable, so validation stops there —
      // `1 IN (1 + 0, Name + 1)` type-checks, the run matching `1 = 1 + 0`
      // before ever reaching `Name + 1`, while `2 IN (1 + 0, Name + 1)` (no
      // definite match) still validates `Name + 1` and faults.
      // `matched(operand, value, routines)` is the fold's own primitive.
      //
      // An empty list has no OR-chain and cannot be lowered (`lower` would have
      // no seed), so reject it here too — the parser rejects `IN ()`, but a
      // caller can build `.membership(_, [], …)` directly, so this validation
      // faults on that shape rather than typing it as an always-false chain.
      guard !values.isEmpty else {
        throw .unsupported("IN requires a non-empty value list")
      }
      _ = try validate(operand, routines, subquery: subquery)
      _ = try membership(of: values, each: { value throws(SQLError) in
        _ = try validate(value, routines, subquery: subquery)
      }, equality: { value throws(SQLError) in
        matched(operand, value, routines)
      })
    case let .like(operand, pattern, escape, _):
      // Validate the operand, pattern, and optional escape for REAL errors
      // (unknown column, bad arity, …); a non-text operand or pattern is NOT
      // rejected — the run yields a definite FALSE via `Row.like` without
      // faulting (the cross-kind rule), and the schema check must accept what
      // the run accepts, as the `IN` cross-kind element does.
      _ = try validate(operand, routines, subquery: subquery)
      try validate(pattern, routines, subquery: subquery)
      if let escape {
        try validate(escape, routines, subquery: subquery)
        try reject(escape, routines)
      }
    case let .between(test, lower, upper, _):
      // `x [NOT] BETWEEN a AND b` compares `x` against both bounds, so validate
      // the three operands for real errors (an unknown column, a bad call). A
      // cross-kind bound is NOT rejected: the run's `matches` yields FALSE
      // across kinds without faulting (as an `IN` element does), so the schema
      // check accepts what the run accepts.
      //
      // It respects the executor's short-circuit — the same one `ranged`
      // evaluates with: a DEFINITELY-FALSE lower comparison (`x >= a`) settles
      // the whole truth (BETWEEN FALSE, NOT BETWEEN TRUE — the latter is the
      // negation of that truth, not the divergent `x < a OR x > b` expansion),
      // leaving `upper` unreachable for BOTH spellings, so `upper` is NOT
      // validated — `0 BETWEEN 1 AND (1 / 0)` type-checks, the lower `0 >= 1`
      // FALSE settling the row before the `1 / 0` upper is reached, exactly as
      // an `AND`'s constant-false left leaves its right unchecked.
      _ = try validate(test, routines, subquery: subquery)
      try validate(lower, routines, subquery: subquery)
      let settled = {
        guard let value = constant(test, routines),
            let low = constant(lower, routines) else {
          return false
        }
        return matches(value, .geq, low) == false
      }()
      if !settled { try validate(upper, routines, subquery: subquery) }
    case let .distinct(lhs, rhs, _):
      // `a IS [NOT] DISTINCT FROM b` compares both operands, so validate the
      // two for real errors (an unknown column, a bad call). BOTH are always
      // validated — the predicate is TWO-VALUED with no short-circuit: neither
      // side settles the truth without the other. A cross-kind pair is NOT
      // rejected: the run's `distinct` treats it as DISTINCT without faulting
      // (as an `IN` element does), so the schema check accepts what the run
      // accepts.
      _ = try validate(lhs, routines, subquery: subquery)
      _ = try validate(rhs, routines, subquery: subquery)
    case let .truth(inner, _, _):
      // `p IS [NOT] <truth value>` validates its inner boolean predicate for
      // real errors; the truth mapping cannot itself fault, so it adds no
      // further check.
      try check(inner, routines, subquery: subquery)
    case let .and(lhs, rhs):
      try check(lhs, routines, subquery: subquery)
      if constant(lhs, routines) != false {
        try check(rhs, routines, subquery: subquery)
      }
    case let .or(lhs, rhs):
      try check(lhs, routines, subquery: subquery)
      if constant(lhs, routines) != true {
        try check(rhs, routines, subquery: subquery)
      }
    case let .not(operand):
      try check(operand, routines, subquery: subquery)
    }
  }

  /// Type-checks a `LIKE` pattern or escape `operand` for the side effect of
  /// validation: an expression is validated (`validate`), a `:parameter` reads
  /// nothing at compile time (its value arrives from the bindings at run time),
  /// so it needs no check, as a `Predicate.bound` parameter needs none.
  private func validate(_ operand: Predicate.Operand, _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    if case let .expression(expression) = operand {
      _ = try validate(expression, routines, subquery: subquery)
    }
  }

  /// Rejects a STATICALLY-invalid `LIKE` `escape` at validation, as `Row.like`
  /// would fault it on EVERY row: a ROW-INDEPENDENT escape expression that
  /// folds (`constant`) to a value that is neither NULL (a valid UNKNOWN) nor a
  /// single-character text (a non-text, or a wrong-length text) makes the query
  /// un-runnable, so reject it here with the same message and condition the run
  /// raises. A `:parameter`, a column, or any other non-constant escape is per
  /// row and cannot be decided statically (`constant` is `nil`) — the run
  /// validates it.
  private func reject(_ escape: Predicate.Operand, _ routines: Routines)
      throws(SQLError) {
    guard case let .expression(expression) = escape,
        let value = constant(expression, routines) else {
      return
    }
    switch value {
    case .null:
      break
    case let .text(text) where text.count == 1:
      break
    default:
      throw .argument("LIKE ESCAPE must be a single character")
    }
  }

  /// The definite truth of the equality `operand = value` when both fold to
  /// ROW-INDEPENDENT CONSTANTS (via `constant`) — the OR-chain equality an `IN`
  /// element folds to — else `nil` (a side reading a row is decided per row).
  /// It folds each side through `constant` — the same `value(of:)`, arithmetic,
  /// and comparison the run evaluates a `left = element` comparison with — so a
  /// `true` here is a definite match that short-circuits the chain.
  private func matched(_ operand: Expression, _ value: Expression,
                       _ routines: Routines) -> Bool? {
    guard let lhs = constant(operand, routines),
        let rhs = constant(value, routines) else {
      return nil
    }
    return matches(lhs, .equal, rhs)
  }

  /// The constant `Value` `expression` folds to when it is ROW-INDEPENDENT —
  /// else `nil` (an operand a row, group, or run context decides). A literal
  /// folds to its value; a binary folds its two operands and applies the SAME
  /// `Arithmetic.apply(Value, Value)` the run's binary evaluation uses, so the
  /// fold matches the run exactly (and a would-be fault — a divide, an overflow
  /// — collapses to `nil` rather than deciding a match). A ROW-INDEPENDENT call
  /// to a DETERMINISTIC routine (every argument folds constant) folds to its
  /// routine's value over those folded arguments — the SAME `Routine` the run
  /// invokes over the same constant arguments, so the fold matches the run; an
  /// unregistered name, a NOT DETERMINISTIC routine, a non-constant argument,
  /// or a throwing routine collapses to `nil`. Only a deterministic routine
  /// folds (ISO): executing a non-deterministic one here could return one value
  /// while this compile-time walk decides reachability and a DIFFERENT one when
  /// the run reaches the same call — pruning an element the run keeps. Every
  /// other expression is not statically foldable: a `column` reads a row and an
  /// `aggregate` folds a group, so each is `nil`. A ROW-INDEPENDENT `case`
  /// folds too — walking the `WHEN`s in order over `constant(_ predicate:)`:
  /// the first constant-TRUE guard yields its folded result, a constant-FALSE
  /// guard is skipped, and a guard the fold cannot decide (`nil`) means the
  /// taken branch is per row, so the whole `case` is `nil`; with no
  /// constant-TRUE guard it folds the `ELSE`, or `.null` when there is none (a
  /// no-match `CASE` yields NULL). This honours the SAME reachability
  /// `reachable(_:_:_:)` validates with. Returning `nil` is SOUND — a caller
  /// that cannot fold an element keeps considering it, never wrongly pruning a
  /// later one.
  private func constant(_ expression: Expression, _ routines: Routines)
      -> Value? {
    switch expression {
    case let .literal(literal):
      return try? SQLEngine.value(of: literal)
    case let .binary(op, lhs, rhs):
      guard let lhs = constant(lhs, routines),
          let rhs = constant(rhs, routines) else {
        return nil
      }
      return try? op.apply(lhs, rhs)
    case let .call(name, arguments):
      guard let routine = routines[name], routine.deterministic else {
        return nil
      }
      var values = Array<Value>()
      values.reserveCapacity(arguments.count)
      for argument in arguments {
        guard let value = constant(argument, routines) else { return nil }
        values.append(value)
      }
      guard let result = try? routine(values) else { return nil }
      // A routine call bypasses `Arithmetic.apply`'s finite check, so a
      // non-finite double is not a definite value the run would accept — it
      // faults there — so do not claim a match: fold to `nil` (parity with
      // `empty(_:_:)`, which rejects the same non-finite result).
      if case let .double(number) = result, !number.isFinite { return nil }
      return result
    case let .case(whens, otherwise):
      for branch in whens {
        switch constant(branch.when, routines) {
        case false: continue
        case true: return constant(branch.then, routines)
        case nil: return nil
        }
      }
      guard let otherwise else { return .null }
      return constant(otherwise, routines)
    case let .cast(operand, type):
      // A ROW-INDEPENDENT operand folds to its converted value — the SAME
      // `Value.cast(to:)` the run applies, so the fold matches. A would-be
      // fault (an unconvertible value) collapses to `nil`, so the cast stays
      // undecided rather than deciding a match, just as a would-be-faulting
      // binary fold does.
      guard let value = constant(operand, routines) else { return nil }
      return try? value.cast(to: type)
    case let .coalesce(arguments):
      // Fold as the run evaluates it — the first argument that folds to a
      // non-NULL value (COERCED to the unified type, as the executor's
      // `Term.coalesce` coerces the selected value), else NULL when every
      // argument folds NULL. An argument the fold cannot decide (`nil`) BEFORE
      // a decisive non-NULL one means the taken value is per row, so the whole
      // `COALESCE` is `nil`. Coercing an `.integer` selected from a COALESCE
      // that unifies to `.double` folds to `.double`, matching the advertised
      // column type — so a `.double`-typed routine over `COALESCE(1, 2.5)`
      // folds against the SAME value the run supplies. The unified type is the
      // one `derive`/`unified` already reduces over the selectable arguments;
      // an irreconcilable pair (which `derive` would fault on) leaves the value
      // uncoerced (`try?` → `nil`), a no-op the executor never reaches.
      let type = try? unified(arguments, routines)
      for argument in arguments {
        guard let value = constant(argument, routines) else { return nil }
        if case .null = value { continue }
        return type.map { value.coerced(to: $0) } ?? value
      }
      return .null
    case let .nullif(lhs, rhs):
      // Fold as the run evaluates it — NULL when `v1 = v2` folds definitely
      // TRUE, else `v1`; a side the fold cannot decide leaves it per row
      // (`nil`).
      guard let va = constant(lhs, routines),
          let vb = constant(rhs, routines) else {
        return nil
      }
      return matches(va, .equal, vb) == true ? .null : va
    case .column, .aggregate, .subquery:
      // A `subquery` is row-independent but is materialised at RUN (this
      // compile-time fold has no cache), so it is not statically foldable —
      // `nil`, like a `column` or `aggregate`.
      return nil
    }
  }

  /// Folds an `IN` value list as its OR-chain of `operand = element` equalities,
  /// honouring the executor's SHORT-CIRCUIT: the elements are visited in order,
  /// each mapped to its three-valued equality truth by `equality`, and the truths
  /// are OR-folded — but a definite `true` stops the walk, since the OR-chain
  /// matches there and every LATER element is unreachable (`Row.matches` returns
  /// on the first true arm). This is the ONE short-circuit the `IN`
  /// type-check (`check`), constant fold (`constant`), and empty-group evaluator
  /// (`empty`) all share: each supplies the per-element `equality` its surface
  /// computes with, and every surface stops at the same element the run does.
  ///
  /// `visit` runs on each element BEFORE its truth is taken, so a surface with a
  /// per-element side effect (validation) applies it to exactly the reachable
  /// prefix. The fold seeds FALSE (an empty match is FALSE), so the returned
  /// truth is the disjunction over the visited prefix.
  private func membership<E: Error>(
      of elements: Array<Expression>,
      each visit: (Expression) throws(E) -> Void = { (_: Expression) in },
      equality: (Expression) throws(E) -> Bool?)
      throws(E) -> Bool? {
    var truth: Bool? = false
    for element in elements {
      try visit(element)
      truth = or(truth, try equality(element))
      // A definite match makes every LATER element unreachable — the OR-chain
      // short-circuits here, exactly as the run does.
      if truth == true { break }
    }
    return truth
  }

  /// The definite constant truth value of `predicate` when it is statically
  /// decidable — a comparison or `IS [NOT] NULL` whose operands fold to
  /// ROW-INDEPENDENT `Value`s (via `constant(_ expression:)`: literals,
  /// arithmetic, deterministic calls, nested `CASE`s), composed through
  /// `AND`/`OR`/`NOT`/`IN` — else `nil` (a predicate reading a column or a
  /// `:parameter` is decided per row). `check(_:_:)` reads it to skip an arm
  /// the executor's short-circuit proves unreachable, matching `matches` and
  /// `value(of:)`, the primitives the run itself evaluates a comparison with.
  /// Folding each operand through `constant(_ expression:)` carries its
  /// determinism gate: a non-deterministic call operand folds to `nil`, so the
  /// comparison stays undecided (`nil`) rather than deciding a match the run
  /// might not make.
  func constant(_ predicate: Predicate, _ routines: Routines) -> Bool? {
    switch predicate {
    case let .comparison(left, op, right):
      guard let lhs = constant(left, routines),
          let rhs = constant(right, routines) else {
        return nil
      }
      return matches(lhs, op, rhs)
    case let .and(lhs, rhs):
      // `constant` is a pure fold with no side effect, so both arms evaluate.
      return and(constant(lhs, routines), constant(rhs, routines))
    case let .or(lhs, rhs):
      return or(constant(lhs, routines), constant(rhs, routines))
    case let .not(operand):
      guard let value = constant(operand, routines) else { return nil }
      return !value
    case let .null(operand, negated):
      // A ROW-INDEPENDENT operand that folds to a concrete value is not NULL;
      // one that folds to `.null` (a NULL literal, or a deterministic routine
      // returning NULL) is NULL — matching the run. An operand the fold cannot
      // decide (`nil`) is per row, so the truth is too. This mirrors
      // `empty(_ predicate:)`'s `.null` arm, which folds via `empty(operand)`.
      guard let value = constant(operand, routines) else { return nil }
      let null = if case .null = value { true } else { false }
      return negated ? !null : null
    case let .membership(operand, values, negated):
      // Fold `x IN (…)` exactly as its OR-chain of equalities folds — the same
      // primitives (`matched`/`constant`, `matches`, `membership`'s
      // short-circuit) — honouring the OR-chain's short-circuit: once a
      // ROW-INDEPENDENT element definitely equals the constant operand the fold
      // is `true`, so a later row-dependent element (which alone would make the
      // fold per-row `nil`) is unreachable and does not spoil it —
      // `1 IN (1 + 0, Name + 1)` folds `true`. Absent a decisive match, any
      // row-dependent element makes it per row (`nil`). `NOT IN` negates the
      // folded truth (UNKNOWN maps to itself).
      let truth = membership(of: values) { value in
        matched(operand, value, routines)
      }
      return negated ? truth.map { !$0 } : truth
    case let .like(operand, pattern, escape, negated):
      // Fold `x LIKE p` when the operand, pattern, and optional escape all fold
      // to ROW-INDEPENDENT constants — the same `constant(_ expression:)` the
      // run's terms evaluate through — running the SAME matcher `Row.like`
      // does; any row-dependent operand leaves it per row (`nil`). `NOT LIKE`
      // negates the folded truth (UNKNOWN maps to itself).
      guard let truth = matched(operand, pattern, escape, routines) else {
        return nil
      }
      return negated ? !truth : truth
    case let .between(test, lower, upper, negated):
      // Fold `x [NOT] BETWEEN a AND b` as `ranged` evaluates it: BETWEEN is the
      // Kleene `x >= a AND x <= b`, and NOT BETWEEN its NEGATION (not the
      // `x < a OR x > b` expansion, which diverges on a cross-kind bound — see
      // `ranged`). The folded `x >= a` short-circuits before the upper: a
      // definitely-FALSE one settles BETWEEN FALSE (and NOT BETWEEN TRUE)
      // without folding the upper — or any fault it carries — so
      // `0 BETWEEN 1 AND (1 / 0)` folds definitely FALSE rather than `nil`. A
      // side the fold cannot decide leaves it per row (`nil`).
      guard let value = constant(test, routines),
          let low = constant(lower, routines) else {
        return nil
      }
      let above = matches(value, .geq, low)
      if above == false { return negated }
      guard let high = constant(upper, routines) else { return nil }
      let within = and(above, matches(value, .leq, high))
      return negated ? within.map { !$0 } : within
    case let .distinct(lhs, rhs, negated):
      // Fold `a IS [NOT] DISTINCT FROM b` as `differs` evaluates it: the
      // null-safe `distinct` of the two folded values, negated for `IS NOT`.
      // It is TWO-VALUED, so when BOTH sides fold to ROW-INDEPENDENT constants
      // the truth is DEFINITE; a row-dependent side leaves it per row (`nil`).
      guard let lhs = constant(lhs, routines),
          let rhs = constant(rhs, routines) else {
        return nil
      }
      let differ = distinct(lhs, rhs)
      return negated ? !differ : differ
    case let .truth(inner, value, negated):
      // Fold `p IS [NOT] <truth value>` whenever the inner boolean is ROW-
      // INDEPENDENT. `constant` gives its definite truth; and a `nil` from it
      // over a `settled` inner (every operand a constant) is a definite UNKNOWN
      // — NOT a per-row deferral — which `tested` maps to a DEFINITE result
      // (`p IS UNKNOWN` TRUE, `p IS TRUE` FALSE), so a constant-UNKNOWN test
      // short-circuits/type-checks as the run does rather than deferring and
      // validating an unreachable conjunct.
      let folded = constant(inner, routines)
      if folded != nil || settled(inner, routines) {
        return tested(folded, value, negated)
      }
      // An `IS [NOT] UNKNOWN` test folds even over a ROW-DEPENDENT inner when
      // the inner is DEFINITE (two-valued — `IS NULL`, `IS DISTINCT FROM`,
      // another truth test, and their `AND`/`OR`/`NOT`, never take UNKNOWN):
      // such an inner is never the third value the test checks for, so
      // `p IS UNKNOWN` is definitely FALSE and `p IS NOT UNKNOWN` definitely
      // TRUE regardless of the rows — `(Flag IS NULL) IS UNKNOWN` folds FALSE.
      // A `TRUE`/`FALSE` test still turns on the inner's per-row value, so it
      // stays per row.
      if value == .unknown, definite(inner) { return negated }
      return nil
    case .bound:
      return nil
    case .exists, .within, .quantified:
      // A subquery predicate is not a ROW-INDEPENDENT constant fold — its truth
      // is decided by the materialised result at lowering time, not by folding
      // operands here — so it never folds statically; treat it as undecided
      // (per-row) so a reachability walk neither prunes nor faults on it.
      return nil
    }
  }

  /// Whether every operand `predicate` reads folds to a ROW-INDEPENDENT
  /// constant — so its three-valued truth is fully determined at compile time.
  /// When it is and `constant(_ predicate:)` is `nil`, that `nil` is a definite
  /// UNKNOWN (a NULL propagated through constant operands), NOT a per-row
  /// deferral: the distinction `constant`'s `Bool?` cannot carry, which the
  /// truth test needs to fold `p IS UNKNOWN`/`p IS TRUE` over a
  /// constant-UNKNOWN `p`. A row or non-deterministic operand is NOT constant
  /// (`constant(_ expression:)` is `nil`), so it is not settled; a `:parameter`
  /// (`.bound`) is per-run, never settled.
  private func settled(_ predicate: Predicate, _ routines: Routines) -> Bool {
    switch predicate {
    case let .comparison(left, _, right):
      constant(left, routines) != nil && constant(right, routines) != nil
    case let .null(operand, _):
      constant(operand, routines) != nil
    case let .membership(operand, values, _):
      constant(operand, routines) != nil
          && values.allSatisfy { constant($0, routines) != nil }
    case let .like(operand, pattern, escape, _):
      constant(operand, routines) != nil
          && constant(pattern, routines) != nil
          && (escape.map { constant($0, routines) != nil } ?? true)
    case let .between(test, lower, upper, _):
      constant(test, routines) != nil && constant(lower, routines) != nil
          && constant(upper, routines) != nil
    case let .distinct(lhs, rhs, _):
      constant(lhs, routines) != nil && constant(rhs, routines) != nil
    case let .truth(inner, _, _):
      settled(inner, routines)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      settled(lhs, routines) && settled(rhs, routines)
    case let .not(operand):
      settled(operand, routines)
    case .bound:
      false
    case .exists, .within, .quantified:
      // A subquery predicate's truth comes from a materialised result, not from
      // folding constant operands, so it is never settled at compile time.
      false
    }
  }

  /// Whether `predicate` is DEFINITE — two-valued, never evaluating to UNKNOWN,
  /// even when it reads row data. `IS [NOT] NULL`, `IS [NOT] DISTINCT FROM`,
  /// and a boolean test all collapse SQL's third value to a definite result by
  /// construction, and `AND`/`OR`/`NOT` of definite predicates stay definite. A
  /// comparison, membership, `LIKE`, `BETWEEN`, or bound parameter can be
  /// UNKNOWN (a NULL operand), so none is definite. This lets an `IS [NOT]
  /// UNKNOWN` test fold — the third value it checks for can never occur — over
  /// a row-dependent inner `settled` cannot reach.
  private func definite(_ predicate: Predicate) -> Bool {
    switch predicate {
    case .null, .distinct, .truth:
      true
    // `EXISTS` is DEFINITELY two-valued — a non-empty test never yields UNKNOWN
    // — so it is definite, while `IN (Q)` is three-valued over NULLs (a NULL
    // element or operand makes an unmatched test UNKNOWN), so it is not.
    case .exists:
      true
    // A quantified comparison is three-valued over NULLs exactly as `IN (Q)` —
    // a NULL element or operand makes an undecided fold UNKNOWN — so it is not
    // definite either.
    case .within, .quantified:
      false
    case let .and(lhs, rhs), let .or(lhs, rhs):
      definite(lhs) && definite(rhs)
    case let .not(operand):
      definite(operand)
    case .comparison, .membership, .like, .between, .bound:
      false
    }
  }

  /// The definite truth of `operand LIKE pattern [ESCAPE escape]` when the
  /// operand, pattern, and optional escape all fold to ROW-INDEPENDENT
  /// constants (via `constant(_ expression:)`), else `nil`. It folds each side
  /// and runs the SAME `matches` the run's `Row.like` does — a NULL side is
  /// UNKNOWN (`nil`), a non-text operand or pattern a definite non-match
  /// (FALSE), a bad escape collapses to `nil` (undecided) rather than faulting
  /// a compile-time reachability walk.
  private func matched(_ operand: Expression, _ pattern: Predicate.Operand,
                       _ escape: Predicate.Operand?, _ routines: Routines)
      -> Bool? {
    guard let operand = constant(operand, routines),
        let pattern = constant(pattern, routines) else {
      return nil
    }
    let character: Character?
    switch escape {
    case .none:
      character = nil
    case let .some(escape):
      switch constant(escape, routines) {
      case let .text(text) where text.count == 1:
        character = text.first
      // A NULL, absent, ill-formed, or `:parameter` escape is not a decidable
      // fold — leave the LIKE per row (`nil`) rather than deciding a match.
      default:
        return nil
      }
    }
    return switch (operand, pattern) {
    case (.null, _), (_, .null):
      nil
    case let (.text(operand), .text(pattern)):
      matches(operand, pattern, escape: character)
    default:
      false
    }
  }

  /// The constant `Value` a `LIKE` pattern or escape `operand` folds to when it
  /// is ROW-INDEPENDENT (`constant(_ expression:)`), else `nil`. A `:parameter`
  /// is per run — its value arrives from the bindings — so it never folds
  /// constant, exactly as a column does.
  private func constant(_ operand: Predicate.Operand, _ routines: Routines)
      -> Value? {
    switch operand {
    case let .expression(expression): constant(expression, routines)
    case .parameter: nil
    }
  }

  /// Validates the aggregate sub-expressions of `expression` — an aggregate's
  /// fold runs over every row (in the aggregate node) BEFORE a `LIMIT`, so it
  /// is reachable even under a zero-row limit — WITHOUT validating the
  /// surrounding per-result expression a run never reaches. It recurses through
  /// a binary's operands and a call's arguments to reach an aggregate, then
  /// validates it (its operand included); a bare column or literal has none.
  func aggregates(in expression: Expression,
                  _ routines: Routines = [:],
                  subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    switch expression {
    case .column, .literal, .subquery:
      // A scalar `subquery` nests no OUTER aggregate — its inner aggregates are
      // validated within the subquery's own type-check — so it contributes none
      // here, like a bare `column`.
      break
    case let .aggregate(function, operand, _, filter):
      _ = try aggregate(function, over: operand, filter: filter, routines,
                        subquery: subquery)
    case let .call(_, arguments):
      for argument in arguments {
        try aggregates(in: argument, routines, subquery: subquery)
      }
    case let .binary(_, lhs, rhs):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .case(whens, otherwise):
      for branch in whens {
        try aggregates(in: branch.when, routines, subquery: subquery)
        try aggregates(in: branch.then, routines, subquery: subquery)
      }
      if let otherwise {
        try aggregates(in: otherwise, routines, subquery: subquery)
      }
    case let .cast(operand, _):
      try aggregates(in: operand, routines, subquery: subquery)
    case let .coalesce(arguments):
      for argument in arguments {
        try aggregates(in: argument, routines, subquery: subquery)
      }
    case let .nullif(lhs, rhs):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    }
  }

  /// Validates the aggregate sub-expressions of a `LIKE` pattern or escape
  /// `operand` — an expression's own, none in a `:parameter`.
  func aggregates(in operand: Predicate.Operand, _ routines: Routines = [:],
                  subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    if case let .expression(expression) = operand {
      try aggregates(in: expression, routines, subquery: subquery)
    }
  }

  /// Validates the aggregate sub-expressions of `predicate` — a `HAVING`'s
  /// aggregates are collected and FOLDED by the group node before the `HAVING`
  /// filter runs, so they are reachable even in an arm the filter's
  /// short-circuit skips. It walks EVERY arm (unlike `check`), reaching an
  /// aggregate through a comparison's operands and `AND`/`OR`/`NOT`.
  func aggregates(in predicate: Predicate,
                  _ routines: Routines = [:],
                  subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      try aggregates(in: left, routines, subquery: subquery)
      try aggregates(in: right, routines, subquery: subquery)
    case let .bound(left, _, _):
      try aggregates(in: left, routines, subquery: subquery)
    case let .null(operand, _):
      try aggregates(in: operand, routines, subquery: subquery)
    case let .membership(operand, values, _):
      try aggregates(in: operand, routines, subquery: subquery)
      for value in values {
        try aggregates(in: value, routines, subquery: subquery)
      }
    case .exists:
      // A subquery is its OWN scope — any aggregate inside it folds over its
      // group, not the enclosing one — so an `EXISTS (Q)` contributes no outer
      // aggregate to collect.
      break
    case let .within(operand, _, _):
      // Only the OUTER operand may hold an enclosing-group aggregate; the
      // subquery is its own scope, so it is not walked here.
      try aggregates(in: operand, routines, subquery: subquery)
    case let .quantified(operand, _, _, _):
      // As `within`: only the OUTER operand may hold an enclosing-group
      // aggregate; the subquery is its own scope.
      try aggregates(in: operand, routines, subquery: subquery)
    case let .like(operand, pattern, escape, _):
      try aggregates(in: operand, routines, subquery: subquery)
      try aggregates(in: pattern, routines, subquery: subquery)
      if let escape {
        try aggregates(in: escape, routines, subquery: subquery)
      }
    case let .between(test, lower, upper, _):
      try aggregates(in: test, routines, subquery: subquery)
      try aggregates(in: lower, routines, subquery: subquery)
      try aggregates(in: upper, routines, subquery: subquery)
    case let .distinct(lhs, rhs, _):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .truth(inner, _, _):
      try aggregates(in: inner, routines, subquery: subquery)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .not(operand):
      try aggregates(in: operand, routines, subquery: subquery)
    }
  }

  /// Validates a whole-result aggregate's PROJECTION or SORT `expression` over
  /// the single empty group a constant-false `WHERE` leaves — the empty-fold's
  /// per-expression check, dispatching on whether the expression nests a
  /// subquery.
  ///
  /// A subquery-FREE expression is precisely EMPTY-FOLDED (`empty`): its value
  /// over the empty group is evaluated exactly as a run does, pruning a
  /// statically-decided `CASE` branch (a constant-false guard's arm never
  /// folds, so it cannot fault) — the precise reachability a false-`WHERE`
  /// whole-result aggregate gives its projection.
  ///
  /// An expression that NESTS a subquery cannot be folded: the empty group
  /// carries no catalog, so a `CASE WHEN EXISTS (Q) …` guard folds UNKNOWN and
  /// its arms would be pruned — but the subquery is row-independent and may be
  /// TRUE at RUN, RUNNING the guarded arm. So VALIDATE it as a run would
  /// (`validate`), which validates BOTH arms of a subquery-guarded `CASE` (a
  /// `nil`-constant guard leaves both reachable), surfacing the fault the run
  /// raises — `SELECT CASE WHEN EXISTS (Q) THEN 1 / 0 … WHERE 1 = 0` faults
  /// `.divide`, matching a run that keeps the empty group and evaluates the
  /// THEN arm. This mirrors the `having.subquery` carve-out, extended to
  /// projection and sort expressions.
  func fold(_ expression: Expression, _ routines: Routines = [:],
            subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    if expression.subquery {
      _ = try validate(expression, routines, subquery: subquery)
    } else {
      _ = try empty(expression, routines)
    }
  }

  /// The value `expression` yields when a whole-result aggregate projects the
  /// single empty group a constant-false `WHERE` leaves — the fold over zero
  /// rows: `COUNT` is 0, every other aggregate NULL, a literal itself, a binary
  /// the operator applied to its folded operands, a call the routine applied to
  /// its folded arguments. It EVALUATES the empty group exactly as a run does,
  /// so it raises precisely the run's fault — an unregistered routine
  /// (`SQLError.function`), a bad arity or kind (`SQLError.argument`), a divide
  /// by zero (`SQLError.divide`), an overflow (`SQLError.magnitude`) —
  /// while a NULL operand propagates without faulting. An aggregate's own
  /// operand is never reached (the fold sees no row), and a bare column cannot
  /// appear (a non-grouped column is a grouping error `compile` already
  /// rejected), so a `SUM(text)` is NULL here rather than a type fault.
  func empty(_ expression: Expression, _ routines: Routines = [:])
      throws(SQLError) -> Value {
    switch expression {
    case let .literal(literal):
      return try value(of: literal)
    case let .aggregate(function, _, _, _):
      return function == .count ? .integer(0) : .null
    case let .binary(op, lhs, rhs):
      return try op.apply(empty(lhs, routines), empty(rhs, routines))
    case let .call(name, arguments):
      guard let routine = routines[name] else { throw .function(name) }
      var values = Array<Value>()
      values.reserveCapacity(arguments.count)
      for argument in arguments {
        try values.append(empty(argument, routines))
      }
      let result = try routine(values)
      // A routine call bypasses `Arithmetic.apply`'s finite check, so enforce
      // it here: a non-finite double faults as a run would (magnitude).
      if case let .double(number) = result, !number.isFinite {
        throw .magnitude("function '\(name)' produced a non-finite double")
      }
      return result
    case let .case(whens, otherwise):
      // Evaluate the `CASE` over the empty group exactly as a run does: the
      // first branch whose guard folds TRUE (`empty(predicate)`) yields its
      // result, else the `ELSE`, else `NULL`. A skipped branch's result never
      // folds, so it cannot fault. The selected value is COERCED to the CASE's
      // unified result type (`derive`), just as the executor's
      // `Row.conditional` widens it — an `.integer` arm of a CASE that unifies
      // to `.double` folds to `.double`, so the empty group matches the
      // advertised column type. NULL (a no-match, no-ELSE fold) passes through.
      let type = try derive(whens, otherwise, routines)
      for branch in whens where try empty(branch.when, routines) == true {
        return try empty(branch.then, routines).coerced(to: type)
      }
      guard let otherwise else { return .null }
      return try empty(otherwise, routines).coerced(to: type)
    case let .cast(operand, type):
      // Convert the operand's empty-group value exactly as a run does — a NULL
      // (the common empty-group operand) casts to NULL, an unconvertible value
      // faults as the run would.
      return try empty(operand, routines).cast(to: type)
    case let .coalesce(arguments):
      // Evaluate the empty group as a run does — the first argument that folds
      // to a non-NULL value (coerced to the unified type, as the executor
      // coerces the selected value), else NULL. A NULL argument propagates
      // without faulting; a later one is not reached once a non-NULL is taken.
      let type = try unified(arguments, routines)
      for argument in arguments {
        let value = try empty(argument, routines)
        if case .null = value { continue }
        return value.coerced(to: type)
      }
      return .null
    case let .nullif(lhs, rhs):
      // Evaluate the empty group as a run does — NULL when `v1 = v2` is TRUE,
      // else the folded `v1`.
      let va = try empty(lhs, routines)
      let vb = try empty(rhs, routines)
      return matches(va, .equal, vb) == true ? .null : va
    case .column, .subquery:
      // A bare column cannot appear over an empty group (a grouping error
      // `compile` rejected). A scalar `subquery` is materialised at RUN (this
      // fold carries no cache), and its value is uncorrelated — group-
      // independent — so this pre-run fold treats it as the undecided `.null`,
      // never faulting on a subquery the run would materialise cleanly.
      return .null
    }
  }

  /// The value a `LIKE` pattern or escape `operand` folds to over the empty
  /// group: an expression folds through `empty(_ expression:)`; a `:parameter`
  /// is UNBOUND here — the empty-group fold carries no bindings — so it is
  /// `.null`, reading UNKNOWN exactly as a `Predicate.bound` parameter does.
  func empty(_ operand: Predicate.Operand, _ routines: Routines = [:])
      throws(SQLError) -> Value {
    switch operand {
    case let .expression(expression): try empty(expression, routines)
    case .parameter: .null
    }
  }

  /// Whether a `HAVING` `predicate` passes over the single empty group a
  /// constant-false `WHERE` leaves — TRUE keeps the group (the projection then
  /// runs), FALSE or UNKNOWN (`nil`) drops it (the projection is unreachable).
  /// It evaluates the predicate as a run does: comparing the folded operand
  /// values (`empty(_:_:)`) with three-valued logic, and short-circuiting
  /// `AND`/`OR` so an unreachable arm's operand never folds — and never faults.
  /// A `left op :parameter` with no binding is UNKNOWN, its left unevaluated.
  func empty(_ predicate: Predicate,
             _ routines: Routines = [:])
      throws(SQLError) -> Bool? {
    switch predicate {
    case let .comparison(left, op, right):
      return matches(try empty(left, routines), op, try empty(right, routines))
    case .bound:
      return nil
    case let .null(operand, negated):
      let value = try empty(operand, routines)
      let null = if case .null = value { true } else { false }
      return negated ? !null : null
    case let .membership(operand, values, negated):
      // Fold `x IN (…)` over the empty group as its OR-chain of equalities does
      // — the folded operand matched against each folded element under
      // three-valued `OR`, honouring the OR-chain's short-circuit (`membership`):
      // the run stops at the first TRUE comparison and never evaluates a later
      // element, so `1 IN (1, 1 / 0)` folds `true` here without folding `1 / 0`
      // to a `.divide` fault. Negated for `NOT IN`.
      //
      // Reject an empty list, as `check` and `lower` do — a whole-result
      // aggregate `HAVING` over the empty group reaches this fold WITHOUT a
      // prior `check` (`OutputColumn.typecheck`), so an empty list would
      // otherwise fold `false` (`true` under `NOT IN`) here while both compile
      // (`lower`) and schema (`check`) reject it. The parser rejects `IN ()`,
      // but a caller can build `.membership(_, [], …)` directly.
      guard !values.isEmpty else {
        throw .unsupported("IN requires a non-empty value list")
      }
      let lhs = try empty(operand, routines)
      let truth = try membership(of: values) { value throws(SQLError) in
        matches(lhs, .equal, try empty(value, routines))
      }
      return negated ? truth.map { !$0 } : truth
    case let .like(operand, pattern, escape, negated):
      // Fold `x LIKE p` over the empty group as `Row.like` evaluates it: the
      // operand, pattern, and optional escape are each folded ONCE, IN ORDER,
      // BEFORE the result is decided (so a faulting reached operand surfaces
      // its throw rather than being swallowed by a NULL escape). Then a NULL
      // operand, pattern, or escape is UNKNOWN, a non-text operand or pattern a
      // definite non-match, else the `%`/`_` matcher decides; a non-NULL escape
      // that is not a single character faults `SQLError.argument`, as the run
      // does. `NOT LIKE` negates.
      let subject = try empty(operand, routines)
      let template = try empty(pattern, routines)
      let separator: Value? =
          if let escape { try empty(escape, routines) } else { nil }
      var character: Character? = nil
      switch separator {
      case .none, .null:
        break
      case let .text(text) where text.count == 1:
        character = text.first
      default:
        throw .argument("LIKE ESCAPE must be a single character")
      }
      let truth: Bool? = switch (subject, template, separator) {
      case (.null, _, _), (_, .null, _), (_, _, .some(.null)):
        nil
      case let (.text(subject), .text(template), _):
        matches(subject, template, escape: character)
      default:
        false
      }
      return negated ? truth.map { !$0 } : truth
    case let .between(test, lower, upper, negated):
      // Fold `x [NOT] BETWEEN a AND b` over the empty group as `ranged` does:
      // BETWEEN is `x >= a AND x <= b`, and NOT BETWEEN its NEGATION (not the
      // `x < a OR x > b` expansion, which diverges on a cross-kind bound — see
      // `ranged`). The folded `x >= a` short-circuits before the upper: a
      // definitely-FALSE one settles BETWEEN FALSE (and NOT BETWEEN TRUE)
      // leaving the upper unfolded — and any fault it would raise unraised — so
      // `HAVING 0 BETWEEN 1 AND (1 / 0)` drops the group without a `.divide`
      // fault, exactly as the run does.
      let value = try empty(test, routines)
      let low = try empty(lower, routines)
      let above = matches(value, .geq, low)
      if above == false { return negated }
      let within = and(above, matches(value, .leq, try empty(upper, routines)))
      return negated ? within.map { !$0 } : within
    case let .distinct(lhs, rhs, negated):
      // Fold `a IS [NOT] DISTINCT FROM b` over the empty group as `differs`
      // does: the null-safe `distinct` of the two folded values, negated for
      // `IS NOT`. It is TWO-VALUED — both operands fold to definite values, so
      // the truth is definite (never UNKNOWN, unlike a `=` over a NULL).
      let differ = distinct(try empty(lhs, routines), try empty(rhs, routines))
      return negated ? !differ : differ
    case let .truth(inner, value, negated):
      // Fold `p IS [NOT] <truth value>` over the empty group as `Filter.truth`
      // evaluates it: `empty` yields the inner's genuine three-valued result
      // (over zero rows every side is constant, so a `nil` here is a real
      // UNKNOWN, not a per-row deferral), which `tested` maps to a DEFINITE
      // result — never itself UNKNOWN.
      return tested(try empty(inner, routines), value, negated)
    case let .and(lhs, rhs):
      // A `false` left proves the `AND` false without folding the right arm,
      // which a run's short-circuit never evaluates and so must not fault.
      let left = try empty(lhs, routines)
      if left == false { return false }
      return and(left, try empty(rhs, routines))
    case let .or(lhs, rhs):
      // A `true` left proves the `OR` true without folding the right arm.
      let left = try empty(lhs, routines)
      if left == true { return true }
      return or(left, try empty(rhs, routines))
    case let .not(operand):
      return try empty(operand, routines).map { !$0 }
    case .exists, .within, .quantified:
      // The whole-result empty-group fold carries no catalog, so it cannot
      // materialise a subquery to decide the predicate — it reads UNKNOWN,
      // dropping the lone empty group, the conservative outcome for the rare
      // `HAVING <subquery predicate>` over a constant-false `WHERE`.
      return nil
    }
  }

  /// Whether `column`'s qualifier admits `member`: an unqualified name admits
  /// every relation, a qualified one only a relation its qualifier (an alias,
  /// else a table name) names.
  private func admits(_ member: Member, _ column: Column) -> Bool {
    guard let qualifier = column.qualifier else { return true }
    return (member.relation.alias ?? member.relation.name) == qualifier
  }

  /// The combined ordinal `column` resolves to.
  ///
  /// The name resolves against every admitted relation: present in exactly one
  /// it yields that relation's `offset` plus the local ordinal; present in more
  /// than one — an unqualified name in several relations, or a qualified name
  /// two relations share a name for — it is `SQLError.ambiguous`; in none it is
  /// `SQLError.column`.
  internal func ordinal(of column: Column) throws(SQLError) -> Int {
    var resolved: Int? = nil
    for member in members where admits(member, column) {
      guard let local = member.schema.ordinal(of: column.name) else { continue }
      if resolved != nil { throw .ambiguous(column.name) }
      resolved = member.offset + local
    }
    guard let resolved else { throw .column(column.name) }
    return resolved
  }

  /// The combined-ordinal projected terms: every real column of every relation
  /// for `*` (in chain order, never a virtual column) as `.slot` terms, a
  /// bare-column list as `.slot` terms at their combined ordinals, an expression
  /// list as lowered terms — in source order.
  internal func terms(_ projection: Projection,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported) throws(SQLError)
      -> Array<Term> {
    switch projection {
    case .all:
      // Every real column of every relation, at its combined ordinal — in chain
      // order, never a virtual column of any relation.
      var terms = Array<Term>()
      for member in members {
        for ordinal in 0 ..< member.schema.width {
          terms.append(.slot(member.offset + ordinal))
        }
      }
      return terms
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(.slot(ordinal(of: column)))
      }
      return terms
    case let .expressions(projected):
      var terms = Array<Term>()
      terms.reserveCapacity(projected.count)
      for item in projected {
        try terms.append(term(item.expression, routines, subquery: subquery))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to a combined-ordinal `Term`.
  internal func term(_ expression: Expression,
                     _ routines: Routines = [:],
                     subquery: Subquery = .unsupported)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      return try .slot(ordinal(of: column))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, routines, subquery: subquery))
      }
      // Case-fold the routine name to the identifier rule the lookup uses, so
      // equivalent-case calls lower to an identical term (see the primary
      // `term(_:in:_:)`).
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .case(whens, otherwise):
      // Lower each branch's guard to a combined-ordinal `Filter` and its result
      // to a `Term`, and the `ELSE` to a `Term`, across the join chain.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        try branches.append((lower(branch.when, routines, subquery: subquery),
                             term(branch.then, routines, subquery: subquery)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, routines, subquery: subquery)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — so the executor COERCES the selected
      // branch's value to the type the schema advertises.
      let type = try derive(whens, otherwise, routines, subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand across the join chain and attach the target type; the
      // executor converts the evaluated value to it (`Value.cast(to:)`).
      return try .cast(term(operand, routines, subquery: subquery), type)
    case let .coalesce(arguments):
      // Lower each argument to a combined-ordinal `Term` and hold them in a
      // first-class `Term.coalesce` so each is evaluated ONCE; `type` is the
      // unified argument type the selected value coerces to.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines, subquery: subquery))
      }
      let type = try derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      // Lower both operands to combined-ordinal `Term`s and hold them in a
      // first-class `Term.nullif` so each is evaluated ONCE.
      return try .nullif(term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .subquery(query):
      // A scalar subquery lowers to a `Term.subquery` reading its collapsed
      // value from the run-time cache, carrying its occurrence `Subkey` and
      // single-column type; the single-column arity is enforced from the
      // compiled width here (no cursor). The query is UNCORRELATED, so it reads
      // no cell of this row.
      return try subquery.scalar(query)
    case .aggregate:
      // An aggregate has no per-row meaning — it folds over a group — so it may
      // not appear in a `WHERE`, a join `ON`, or a non-aggregate projection.
      throw .unsupported("an aggregate is not allowed here")
    }
  }

  /// The resolved sort keys an `ORDER BY` lowers to, in major-to-minor order —
  /// each key's ISO `<sort key>` a `Term` over the chain's combined ordinals,
  /// its direction preserved.
  ///
  /// `projection` are the query's already-lowered projection terms and `names`
  /// their output names, so an ordinal or an output-alias key resolves to the
  /// matching select-list item's `Term` and an ordinary expression key lowers
  /// fresh over the chain (see the free `order`).
  internal func order(_ order: Order, _ projection: Array<Term>,
                      _ names: Array<String?>, _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    try SQLEngine.order(order, projection, names) {
      expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }
  }

  /// Lowers a join's `ON left = right` to a `match` conjunct, each side
  /// resolved to a combined ordinal across the chain.
  internal func match(_ left: Column, _ right: Column) throws(SQLError)
      -> Filter {
    try .match(ordinal(of: left), ordinal(of: right))
  }

  /// Lowers a join's `ON predicate` to the engine's `Filter` across the chain,
  /// emitting a `match` for each pure `column = column` equality — the
  /// hash-join key `nest` folds into a physical `Join` — ONLY WHEN the WHOLE
  /// `ON` is safe, and otherwise lowering the entire conjunction as one
  /// residual.
  ///
  /// A `column = column` conjunct is the hash-join key `nest` folds into a
  /// physical `Join`, so it lowers to a `match(left, right)` — the same node
  /// the equi-only `ON` produced — rather than a `compare(.slot, .equal,
  /// .slot)`, which `nest` would not recognise as a key. Every other leaf (an
  /// inequality, an expression equality such as `a.x = b.y + 1`, an `IS NULL`,
  /// a membership, an `OR`/`NOT`) lowers through `lower`, becoming a residual
  /// the join runs as a filter over the product — nested-loop semantics,
  /// correct if O(n·m).
  ///
  /// A `match` key is extracted ONLY WHEN EVERY lowered conjunct is `safe`; if
  /// ANY conjunct is unsafe, the whole `ON` lowers to a single residual and NO
  /// key is hoisted. The hash join evaluates its key equality BEFORE any
  /// residual conjunct AND skips a NULL key (an equi `match` drops a pair whose
  /// key cell is NULL), so an extracted key changes the `ON`'s left-to-right
  /// Kleene error behaviour on two hazards, both suppressing a throw the
  /// residual `select` over the product would raise (the order the WHERE
  /// pushdown barriers preserve):
  ///   - an UNSAFE conjunct BEFORE the key (`ON (1 / A.x) = 0 AND A.k = B.k`):
  ///     hoisting the key would let its non-match drop a pair before the
  ///     unsafe conjunct runs (`A.x = 0` ⇒ `SQLError.divide`);
  ///   - a NULLABLE key BEFORE an UNSAFE conjunct (`ON A.k = B.k AND (1 / A.x)
  ///     = 0`, `A.k` NULL, `A.x = 0`): the equality is UNKNOWN, so the Kleene
  ///     `AND` must still evaluate the unsafe RHS and raise — but the hash join
  ///     skips the NULL key and drops the pair before the RHS runs.
  /// The engine has no NOT NULL schema (a column surfaces as a `Value` that may
  /// be `.null`), so it cannot prove a key operand non-nullable; EVERY equi key
  /// is treated as nullable, collapsing both hazards to the single whole-`ON`
  /// rule. An equi `column = column` is always `safe` (comparing two cells
  /// never raises), so an all-equi or otherwise all-safe `ON` still hash-joins
  /// byte-for-byte.
  internal func on(_ predicate: Predicate,
                   _ routines: Routines = [:],
                   subquery: Subquery = .unsupported)
      throws(SQLError) -> Filter {
    let conjuncts = predicate.conjuncts
    let lowered = try conjuncts.map { conjunct throws(SQLError) in
      try lower(conjunct, routines, subquery: subquery)
    }
    // An unsafe conjunct anywhere forbids extracting ANY key: a hoisted key
    // both skips a NULL pair before a LATER unsafe conjunct runs and drops a
    // non-match before an EARLIER one does — either suppressing the throw the
    // whole-ON residual owes. Lower the entire conjunction as one residual.
    guard lowered.allSatisfy(\.safe) else { return lowered.conjunction! }
    var filters = Array<Filter>()
    for (conjunct, residual) in zip(conjuncts, lowered) {
      if case let .comparison(.column(left),
                              .equal, .column(right)) = conjunct {
        try filters.append(match(left, right))
      } else {
        filters.append(residual)
      }
    }
    return filters.conjunction!
  }

  /// Lowers the name-addressed AST `predicate` to the engine's `Filter`, each
  /// column reference resolved to a combined ordinal across the chain.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Filter {
    try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }, subquery: subquery)
  }
}

// MARK: - Grouped scope

/// The grouped slot space of an aggregate query — the lowering surface for the
/// projection, `HAVING`, and `ORDER BY` that read a grouped record.
///
/// An `aggregate` node yields grouped records whose slots are the `GROUP BY` key
/// values (slots `0 ..< keys.count`, in key order) followed by the aggregate
/// results (slot `keys.count + j` is aggregate `j`). A `Grouping` lowers a
/// name-addressed AST expression into that space: an aggregate call maps to its
/// result slot; a bare column maps to its key slot ONLY when it is a `GROUP BY`
/// key — the standard rule that a non-aggregated column must appear in the
/// `GROUP BY` (else `SQLError.grouping`). It also records each projected item's
/// output name so an `ORDER BY` may name a projection alias, the standard way to
/// order on an aggregate (`ORDER BY <count-alias>`).
///
/// The keys and aggregates resolve against the underlying `Scope`, so the same
/// combined-ordinal resolution the source uses decides which projection columns
/// are keys.
internal struct Grouping {
  private let scope: Scope

  /// Each `GROUP BY` key's combined base ordinal mapped to its grouped slot —
  /// key `i` sits at grouped slot `i`.
  private let keys: Dictionary<Int, Int>

  /// The number of `GROUP BY` keys — aggregate `j` sits at grouped slot
  /// `offset + j`, following the key slots.
  private let offset: Int

  /// The query's distinct aggregations, in first-appearance order — aggregate
  /// `j` sits at grouped slot `offset + j`. Deduped by RESOLVED `Aggregation`
  /// (function + resolved argument term), so an aggregate expression's grouped
  /// slot is found by resolving it and matching here — a
  /// qualification-equivalent aggregate (`SUM(Amount)` vs `SUM(Sales.Amount)`)
  /// maps to the SAME slot.
  private let aggregates: Array<Aggregation>

  /// Each projected item's output name (an alias, else a bare column's name),
  /// lowercased, mapped to its grouped term and its 0-based projection column
  /// — the surface an `ORDER BY` names a projection alias against. The `column`
  /// is the position the name occupies in the select list, so an `ORDER BY`
  /// alias sorts on exactly the output that name introduces even when two items
  /// share one term (two calls to a `deterministic: false` routine) under
  /// distinct aliases — a term-only lookup would collapse to the first column.
  private var aliases: Dictionary<String, (term: Term, column: Int)> = [:]

  /// Output names two or more projected items share, lowercased. An `ORDER BY`
  /// that names one has no single slot to order on — the same ambiguity the
  /// non-grouped `Scope.order` reports for a shared unqualified join column
  /// (`SQLError.ambiguous`) rather than silently picking the last projection.
  private var ambiguous: Set<String> = []

  /// Builds a grouping over `scope` for the `GROUP BY` `columns` and the
  /// query's distinct `aggregates` (in first-appearance order — aggregate `j` at
  /// grouped slot `columns.count + j`). The `aggregates` are already deduped by
  /// RESOLVED `Aggregation` (see `group`), so a qualification-equivalent pair
  /// is one entry sharing one slot.
  internal init(_ scope: Scope, _ columns: Array<Column>,
                _ aggregates: Array<Aggregation>) throws(SQLError) {
    self.scope = scope
    var keys = Dictionary<Int, Int>(minimumCapacity: columns.count)
    for index in columns.indices {
      try keys[scope.ordinal(of: columns[index])] = index
    }
    self.keys = keys
    self.offset = columns.count
    self.aggregates = aggregates
  }

  /// The grouped slot an aggregate `expression` resolves to (an aggregate the
  /// query collected), or `nil` if it is not one. The expression is RESOLVED to
  /// an `Aggregation` — column qualification normalized to a slot — and matched
  /// against the collected aggregations, so `SUM(Amount)` and
  /// `SUM(Sales.Amount)` find the same slot in a single-relation scope.
  private func slot(of expression: Expression, _ routines: Routines = [:],
                    subquery: Subquery = .unsupported)
      throws(SQLError) -> Int? {
    guard case .aggregate = expression else { return nil }
    let aggregation = try expression.aggregation(scope, routines,
                                                 subquery: subquery)
    return aggregates.firstIndex(of: aggregation).map { offset + $0 }
  }

  /// Lowers a scalar `expression` to a grouped-space `Term`.
  ///
  /// An aggregate call maps to its result slot; a literal to a constant; a
  /// `call`/`binary` recurses over its operands; a bare column maps to its key
  /// slot only when it is a `GROUP BY` key, else it is `SQLError.grouping` — the
  /// standard rule.
  private func term(_ expression: Expression,
                    _ routines: Routines = [:],
                    subquery: Subquery = .unsupported)
      throws(SQLError) -> Term {
    if case .aggregate = expression,
       let slot = try slot(of: expression, routines, subquery: subquery) {
      return .slot(slot)
    }
    switch expression {
    case let .column(column):
      let ordinal = try scope.ordinal(of: column)
      guard let slot = keys[ordinal] else { throw .grouping(column.name) }
      return .slot(slot)
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, routines, subquery: subquery))
      }
      // Case-fold the routine name to the identifier rule the lookup uses, so
      // equivalent-case calls lower to an identical term (see the primary
      // `term(_:in:_:)`).
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .case(whens, otherwise):
      // Lower each branch's guard and result, and the `ELSE`, against the
      // grouped slot space — a bare column in any of them must be a `GROUP BY`
      // key, an aggregate its result slot, as elsewhere in a grouped expression.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        try branches.append((lower(branch.when, routines, subquery: subquery),
                             term(branch.then, routines, subquery: subquery)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, routines, subquery: subquery)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — over the grouped scope, so the executor
      // COERCES the selected branch's value to the advertised column type.
      let type = try scope.derive(whens, otherwise, routines,
                                  subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand against the grouped slot space and attach the target
      // type; the executor converts the evaluated value to it.
      return try .cast(term(operand, routines, subquery: subquery), type)
    case let .coalesce(arguments):
      // Lower each argument to a grouped-space `Term` and hold them in a
      // first-class `Term.coalesce` so each is evaluated ONCE; `type` is the
      // unified argument type (over the grouped scope) the value coerces to.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines, subquery: subquery))
      }
      let type = try scope.derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      // Lower both operands to grouped-space `Term`s and hold them in a
      // first-class `Term.nullif` so each is evaluated ONCE.
      return try .nullif(term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .subquery(query):
      // A scalar subquery is UNCORRELATED — row-independent, so it needs no
      // `GROUP BY` key — and lowers to a `Term.subquery` reading its collapsed
      // value from the cache, carrying its `Subkey` and single-column type.
      return try subquery.scalar(query)
    case .aggregate:
      // An aggregate reaches here only when it was not collected — an internal
      // inconsistency, since the query gathers every projection/HAVING aggregate.
      throw .unsupported("uncollected aggregate")
    }
  }

  /// Records a projected item's output `name` at projection `column` → its
  /// grouped `term`, flagging the name ambiguous if another projected item
  /// already claimed it.
  private mutating func record(_ name: String, _ column: Int, _ term: Term) {
    let key = name.lowercased()
    let entry = (term: term, column: column)
    if aliases.updateValue(entry, forKey: key) != nil { ambiguous.insert(key) }
  }

  /// The grouped-space projected terms, recording each item's output name for an
  /// `ORDER BY` to name.
  ///
  /// A `columns` projection (`SELECT Dept … GROUP BY Dept`) lowers each column
  /// as a grouped term — a `GROUP BY` key, else `SQLError.grouping`. An
  /// `expressions` projection lowers each item's expression and records its
  /// output name (an alias, else a bare column's name) so an `ORDER BY` may name
  /// it — the standard alias ordering on an aggregate. A `SELECT *` has no
  /// well-defined meaning over groups (which columns?), so it faults.
  internal mutating func terms(_ projection: Projection,
                               _ routines: Routines = [:],
                               subquery: Subquery = .unsupported)
      throws(SQLError) -> Array<Term> {
    switch projection {
    case .all:
      throw .unsupported("SELECT * is not allowed with GROUP BY or aggregates")
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for index in columns.indices {
        let term = try term(.column(columns[index]), routines,
                            subquery: subquery)
        terms.append(term)
        record(columns[index].name, index, term)
      }
      return terms
    case let .expressions(items):
      var terms = Array<Term>()
      terms.reserveCapacity(items.count)
      for index in items.indices {
        let term = try term(items[index].expression, routines,
                            subquery: subquery)
        terms.append(term)
        // Record the output name (`Projected.name` — an alias, else a bare
        // column's name) so an `ORDER BY` may name it (the standard alias
        // ordering on an aggregate); a computed item names nothing.
        if let name = items[index].name { record(name, index, term) }
      }
      return terms
    }
  }

  /// Lowers a `HAVING`/predicate to a grouped-space `Filter`.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Filter {
    try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }, subquery: subquery)
  }

  /// The resolved sort keys an `ORDER BY` lowers to in grouped space, major to
  /// minor — each key's ISO `<sort key>` a `Term` over the grouped record's
  /// slots, its direction preserved.
  ///
  /// Each sort key resolves as, in order:
  ///
  /// - `ordinal(n)` — the query's `n`-th projected OUTPUT column (1-based),
  ///   resolving to that projection item's own grouped-space `Term`
  ///   (`projection[n - 1]`). An `n` outside `1 ... projection.count` faults
  ///   `SQLError.column`.
  /// - `expression(.column(name))` with an unqualified `name` — a projection
  ///   OUTPUT alias FIRST (the standard alias ordering on an aggregate, `terms`
  ///   recorded these), then a `GROUP BY` key column, both resolving to their
  ///   grouped `Term`. A name two projections share is `SQLError.ambiguous`, as
  ///   the non-grouped `Scope.order` reports for a shared join column.
  /// - Any other `expression(e)` — an arithmetic over aggregates or keys
  ///   (`ORDER BY COUNT(*) * 2`, `ORDER BY SUM(x) DESC`) — lowered through
  ///   `term` into grouped space, so it may name only aggregates and `GROUP BY`
  ///   keys (a bare non-key column faults `SQLError.grouping`).
  ///
  /// Because the `sort` operator now evaluates a `Term` per grouped record
  /// rather than reading one slot, an alias over a COMPUTED expression
  /// (`COUNT(*) * 2 AS Doubled`) orders correctly — its recorded grouped term
  /// recomputes from the group's key and aggregate slots — where the slot-only
  /// sort once rejected it.
  ///
  /// `projection` are the query's already-lowered grouped-space projection
  /// terms — the ordinal surface the positional keys resolve against; the alias
  /// and `GROUP BY` surfaces are the `aliases` and `keys` `terms` recorded.
  internal func order(_ order: Order, _ projection: Array<Term>,
                      _ routines: Routines = [:],
                      subquery: Subquery = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    var resolved = Array<SortKey>()
    resolved.reserveCapacity(order.keys.count)
    for key in order.keys {
      switch key.sort {
      case let .ordinal(position):
        guard position >= 1, position <= projection.count else {
          throw .column("\(position)")
        }
        resolved.append(SortKey(term: projection[position - 1],
                                ascending: key.ascending,
                                column: position - 1))
      case let .expression(expression):
        if case let .column(reference) = expression,
            reference.qualifier == nil {
          let name = reference.name.lowercased()
          // A name two projections share has no single term to order on —
          // reject it as ambiguous rather than pick the last, matching the
          // non-grouped `Scope.order` fault for a shared unqualified column.
          if ambiguous.contains(name) { throw .ambiguous(reference.name) }
          if let alias = aliases[name] {
            // Order on the recorded projection column the alias occupies, not
            // `firstIndex(of:)` — two items may share a term under distinct
            // aliases, so a term search would collapse to the first column.
            resolved.append(SortKey(term: alias.term, ascending: key.ascending,
                                    column: alias.column))
            continue
          }
        }
        try resolved.append(SortKey(term: term(expression, routines,
                                                subquery: subquery),
                                    ascending: key.ascending, column: nil))
      }
    }
    return resolved
  }
}

// MARK: - Referenced ordinals

extension Filter {
  /// The ordinals this filter reads, accumulated into `ordinals`.
  ///
  /// A `compare` reads both operand terms, a `bound` its left term, a `match`
  /// both columns; the connectives recurse. The engine unions these with the
  /// projection, order, and join keys to materialise exactly the columns a
  /// scan's rows are read through.
  internal func references(into ordinals: inout Set<Int>) {
    switch self {
    case let .compare(lhs, _, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .bound(term, _, _):
      term.references(into: &ordinals)
    case let .match(left, right):
      ordinals.insert(left)
      ordinals.insert(right)
    case let .null(term, _):
      term.references(into: &ordinals)
    case let .membership(operand, elements, _):
      operand.references(into: &ordinals)
      for element in elements {
        element.references(into: &ordinals)
      }
    case .exists:
      // An UNCORRELATED EXISTS reads no outer ordinal — its subquery names no
      // enclosing column and runs against its own relations.
      break
    case let .within(operand, _, _):
      // Only the outer operand term reads ordinals; the uncorrelated subquery
      // runs against its own relations.
      operand.references(into: &ordinals)
    case let .quantified(operand, _, _, _):
      // As `within`: only the outer operand reads ordinals; the uncorrelated
      // subquery runs against its own relations.
      operand.references(into: &ordinals)
    case let .like(operand, pattern, escape, _):
      operand.references(into: &ordinals)
      pattern.references(into: &ordinals)
      escape?.references(into: &ordinals)
    case let .between(test, lower, upper, _):
      test.references(into: &ordinals)
      lower.references(into: &ordinals)
      upper.references(into: &ordinals)
    case let .distinct(lhs, rhs, _):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .truth(inner, _, _):
      inner.references(into: &ordinals)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .not(operand):
      operand.references(into: &ordinals)
    }
  }
}
