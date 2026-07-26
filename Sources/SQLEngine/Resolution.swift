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

/// The resolution context a subquery occurrence materialises under — the seam
/// that keeps two AST-identical subqueries resolving under different overlays
/// separate cache entries, so neither overwrites the other.
///
/// An uncorrelated subquery's result depends only on the overlay it resolves
/// against, and in this slice a subquery resolves under exactly one of two
/// contexts: the top-level caller's overlay (its `WITH` CTEs), or a specific
/// VIEW body's overlay (that view's own base relations, never the caller's
/// `WITH`). A view `VN` whose body has `EXISTS (SELECT V FROM S)` over an empty
/// base `S`, run under a caller that binds `WITH S AS (SELECT 1)`, must read
/// the view's own (empty) `S` — not the caller's CTE — even though both spell
/// the same AST. Keying the cache by the `Query` value alone collapses the
/// two; a `Subscope` composed into the key keeps them disjoint. The `caller`
/// case is distinguished from every `view` case, and two distinct view names
/// never collide (case-folded), so the caller and view spaces cannot overlap.
///
/// It is reproducible at both the compile site (lowering embeds it in the
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

/// The role a subquery occurrence materialises in — its shape in the cache.
///
/// The same inner SQL can occur in three roles at once, each needing a
/// different materialisation, so the role discriminates the cache entry: a
/// `scalar` occurrence (`Expression.subquery`) collapses to one cell
/// (`cell(of:)`), a `valued` occurrence (`IN (SELECT …)`, `Predicate.within`)
/// keeps the materialised rows for its value set, and an `existential`
/// occurrence (`EXISTS (SELECT …)`) is a cardinality probe that never runs
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
  /// A `LATERAL (SELECT …)` FROM/JOIN occurrence — a correlated apply's right
  /// side, materialised in full per outer row. Distinct from the predicate
  /// roles so a lateral body's pre-compiled plan keys disjointly from any
  /// scalar/`IN`/`EXISTS` occurrence of the same inner SQL.
  case lateral
}

/// The cache identity of one collected subquery occurrence — its resolution
/// `context` composed with its `query` AST and its `role`.
///
/// A subquery is keyed neither by its `Query` value alone (which collapses two
/// AST-identical subqueries under different overlays — see `Subscope`)
/// nor by a raw counter (which two independent id spaces could not keep
/// disjoint), but by the triple: within one `Subscope`, an identical `Query`
/// resolves to an identical result, so value-discrimination is correct there;
/// across scopes the `Subscope` keeps them separate. A caller-space key
/// (`.caller`) and a view-space key (`.view(name)`) are unequal even for the
/// same AST, so the two id spaces cannot collide.
///
/// The `role` keeps the three materialisation shapes of one `(scope, query)`
/// disjoint (see `Role`): a `scalar` read can never hit a `valued` or an
/// `existential` entry and vice versa, so identical inner SQL used in more than
/// one role no longer cross-reads the wrong entry.
internal struct Subkey: Hashable, Sendable {
  /// The resolution context this occurrence materialises under.
  internal let scope: Subscope

  /// The subquery's AST.
  internal let query: Query

  /// The role this occurrence materialises in — its cache shape.
  internal let role: Role

  internal init(_ scope: Subscope, _ query: Query, _ role: Role) {
    self.scope = scope
    self.query = query
    self.role = role
  }
}

/// The cache identity of one correlated subquery occurrence's pre-compiled plan
/// — its occurrence `Subkey` composed with the SET of synthetic parameter names
/// its correlation binds.
///
/// The `Subkey` alone (scope + query + role) does NOT separate two occurrences
/// of identical inner SQL that compile under different outer layouts — the two
/// arms of a set operation, `SELECT (SELECT m FROM Src WHERE m = k) FROM Outer1
/// UNION ALL SELECT (SELECT m FROM Src WHERE m = k) FROM Outer2` where
/// `Outer1.k` sits at ordinal 0 and `Outer2.k` at ordinal 1. Both arms carry
/// the same `Subkey` (same `.caller` scope, same AST, same role), so keying the
/// plan memo by `Subkey` alone lets the right arm read the LEFT arm's plan —
/// which binds `:__correlated_0_0` while the right arm's outer row binds
/// `:__correlated_0_1`, yielding NULL/wrong results. The correlation's
/// parameter names (`:__correlated_<depth>_<ordinal>`) encode each occurrence's
/// own outer layout and are stable across the ordinal remap `optimise` applies
/// (it rewrites the `Source` values, never the keys), so they match at the
/// record site (the pre-pass compile) and the lookup site (the lowered node)
/// while differing between the two arms. Adding them to the key gives each arm
/// its own plan yet preserves legitimate sharing: an identical occurrence under
/// an identical outer layout binds the same names and reuses the one plan.
internal struct PlanKey: Hashable, Sendable {
  /// The occurrence's `Subkey` — scope, query, and role.
  private let key: Subkey

  /// The synthetic parameter names this occurrence's correlation binds — its
  /// outer-layout identity, remap-stable.
  private let names: Set<String>

  internal init(_ key: Subkey, _ correlation: Correlation) {
    self.key = key
    self.names = Set(correlation.keys)
  }
}

/// Where a correlated synthetic parameter's per-outer-row value comes from — a
/// cell of the immediate enclosing row (`slot`), or an already-bound parameter
/// the containing subquery threads through (`bound`).
///
/// A correlation to the subquery's immediate enclosing query reads that outer
/// row directly: `slot` is the outer combined ordinal the re-execution binds
/// from the current outer row. A correlation to a scope two OR more levels up
/// (a nested subquery naming a grandparent column) is bound by the containing
/// subquery — which the bubble-up marks correlated to that same grandparent, so
/// it re-executes and binds the parameter — and the inner occurrence only reads
/// it back through `bindings`, so its source is `bound`: the eval leaves the
/// threaded binding intact rather than overwriting it from the inner's own row.
internal enum Source: Hashable, Sendable {
  /// The value is the current outer row's cell at this combined ordinal.
  case slot(Int)
  /// The value is the `COALESCE` (first non-NULL) of the current outer row's
  /// cells at these combined ordinals, coerced to the unified `type` — a
  /// `NATURAL`/`USING` merged column of an enclosing join scope (ISO 9075
  /// 7.10), whose value belongs to neither physical side but to their coalesce,
  /// correlated into a LATERAL body (or any nested subquery) as its one merged
  /// column. It reads the outer row rather than a threaded binding, exactly as
  /// `slot`, over more than one cell, matching the merged column's own
  /// `COALESCE(left, right)` value the local scope lowers.
  case coalesce(Array<Int>, ValueType)
  /// The value is already in `bindings` — threaded down by the containing
  /// subquery — so the eval passes it through unchanged.
  case bound
}

/// The correlation of a subquery occurrence — the synthetic bound parameters
/// its inner query names, each mapped to the `Source` its per-outer-row value
/// comes from (an immediate-enclosing-row cell, or a threaded binding).
///
/// A correlated subquery references a column of an enclosing query (`SELECT V
/// FROM S WHERE S.k = T.k`, the inner `T.k` outer). This slice ships the
/// minimal (b) cut: an outer column is allowed ONLY in the inner query's
/// `WHERE`/`ON` (a comparison operand or a `WHERE`-position term), where it
/// lowers to a synthetic `Term.parameter(name)` — reusing the run's `bindings`
/// with no new evaluator beyond that leaf. This map records, per synthetic
/// name, the `Source` the per-outer-row re-execution binds it from. An empty
/// map is an uncorrelated occurrence, materialised once and memoised; a
/// non-empty one re-runs the inner plan per outer row against a `bindings`
/// extended with each named cell, bypassing the materialise cache.
///
/// An outer column in the inner projection / `GROUP BY` / `HAVING` is out of
/// this cut — it needs the general (a)-style outer-row evaluator, not a bound
/// param — so it is diagnosed as unsupported rather than mis-resolved (see
/// `Outer.parameter`). A column binding neither locally nor in any enclosing
/// scope stays the ordinary unknown-column fault.
internal typealias Correlation = Dictionary<String, Source>

extension Dictionary where Key == String, Value == Source {
  /// This correlation with every `slot` outer ordinal remapped to its packed
  /// slot through `slot`, so a per-outer-row re-execution reads the outer
  /// record's cell; a `bound` source is unchanged — it reads a threaded
  /// binding, not the outer record.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Correlation {
    mapValues { source in
      switch source {
      case let .slot(ordinal):
        .slot(slot[ordinal]!)
      case let .coalesce(ordinals, type):
        .coalesce(ordinals.map { slot[$0]! }, type)
      case .bound:
        .bound
      }
    }
  }

  /// The outer ordinals this correlation reads from the immediate enclosing row
  /// — every `slot` source's ordinal and every `coalesce` source's constituent
  /// ordinals, excluding the `bound` (threaded-binding) sources — the cells
  /// that must be materialised for a per-outer-row re-execution.
  internal var slots: Set<Int> {
    var slots = Set<Int>()
    for source in values {
      switch source {
      case let .slot(ordinal):
        slots.insert(ordinal)
      case let .coalesce(ordinals, _):
        slots.formUnion(ordinals)
      case .bound:
        break
      }
    }
    return slots
  }
}

/// The enclosing resolution scope a subquery lowers against for its correlated
/// columns — the scope stack the minimal (b) correlation cut consults when an
/// inner column binds against none of the subquery's own in-scope relations.
///
/// A subquery resolves its columns against its own relations FIRST; a name none
/// of them binds is a candidate correlated reference to an enclosing query.
/// This carries the enclosing `Scope`s, innermost last, and — as lowering
/// reaches each such candidate — resolves it against them (nearest first),
/// mints a synthetic `:parameter` name for the outer combined ordinal, and
/// records the (name → ordinal) pair into the shared `correlation` accumulator
/// so the per-outer-row re-execution can bind that cell. It is a class so the
/// accumulator survives the seam being copied by value down the lowering, and
/// so the same occurrence lowered on the run and the schema paths accretes into
/// one map.
///
/// A name no enclosing scope binds either stays the ordinary unknown-column
/// fault (the local surface already raised `SQLError.column`); this only
/// intercepts a name the OUTER scope binds. Correlation is admitted ONLY where
/// a synthetic bound param is a valid lowering — a `WHERE`/`ON` term — so a
/// scope with no admitted position (a projection / `GROUP BY` / `HAVING`
/// surface) carries no `Outer` and the outer column stays unresolved, diagnosed
/// as unsupported rather than mis-bound.
internal final class Outer {
  /// The enclosing scopes, outermost first — a column resolves against the
  /// nearest enclosing (last) that binds it, matching lexical scoping. The last
  /// scope is this subquery's immediate parent; any earlier one is a
  /// grandparent (or further) whose correlation bubbles up to the containing
  /// subquery.
  private let scopes: Array<Scope>

  /// The enclosing subquery's `Outer` — the one holding `scopes` minus the last
  /// — up which a correlation to a non-immediate scope propagates, so the
  /// containing subquery is marked correlated to that grandparent column too.
  /// `nil` at the outermost level (a top-level select's `Outer`).
  private let parent: Outer?

  /// The correlated references discovered so far — each synthetic `:parameter`
  /// name mapped to the `Source` its per-outer-row value comes from (this
  /// subquery's immediate-enclosing-row cell, or a threaded binding).
  private(set) var correlation: Correlation = [:]

  internal init(_ scopes: Array<Scope> = [], parent: Outer? = nil) {
    self.scopes = scopes
    self.parent = parent
  }

  /// This outer scope extended with `scope` as the nearest enclosing one — the
  /// stack a nested subquery lowers against, seeing its immediate parent last,
  /// with `self` as the parent so a correlation to a grandparent scope bubbles
  /// up. The accumulator starts fresh: correlation is recorded per occurrence,
  /// not shared across sibling subqueries.
  internal func nested(under scope: Scope) -> Outer {
    Outer(scopes + [scope], parent: self)
  }

  /// The synthetic `:parameter` name a correlated reference to enclosing
  /// combined `ordinal` at scope `depth` lowers to — deterministic in both, so
  /// the run and schema lowerings of the same occurrence mint identical names
  /// and the re-execution binds them from the outer row. The `depth` (the
  /// scope-stack index the reference resolves at) disambiguates two references
  /// from different enclosing scopes that share an ordinal — a `T.id`
  /// (grandparent) and a `U.u` (parent) both at combined ordinal 0 — so each
  /// gets its own synthetic param and correlation entry rather than colliding
  /// on `:__correlated_0`. The depth is a scope-stack index, stable across the
  /// bubble-up (a parent sees the shared prefix scope at the same index), so
  /// the binding level and the threading levels agree on the name.
  private func name(for ordinal: Int, at depth: Int) -> String {
    ":__correlated_\(depth)_\(ordinal)"
  }

  /// The synthetic `:parameter` name a correlated reference to a
  /// `NATURAL`/`USING` merged column of enclosing scope `depth` lowers to —
  /// keyed by the merged column's LEFT constituent ordinal but in a DISTINCT
  /// namespace from `name(for:at:)`, so it cannot collide with the physical
  /// parameter of ANY constituent slot. A LATERAL body that references both the
  /// bare merged column (this key) AND a physical constituent `A.k` (the
  /// physical `name(for:at:)` key) thus gets two correlation entries, one per
  /// reference, so the merged coalesce and the qualified slot each bind their
  /// own value regardless of lowering order (a shared key let one overwrite the
  /// other). The left constituent ordinal uniquely identifies the merged column
  /// within a scope — each merged column stands over its own physical slots —
  /// so it is a stable, deterministic identity across the run and schema
  /// lowerings, as `name(for:at:)` is.
  private func parameter(merging ordinal: Int, at depth: Int) -> String {
    ":__merged_\(depth)_\(ordinal)"
  }

  /// The synthetic bound-parameter name `column` correlates to, or `nil` when
  /// no enclosing scope binds it (the ordinary unknown-column fault stands).
  ///
  /// The enclosing scopes are consulted nearest first (the innermost enclosing
  /// query shadows an outer one, as lexical scoping requires). On a match it
  /// records the correlation (see `record(_:matching:)`) and returns the name,
  /// so the caller lowers the column to a `Term.parameter`. A nearer scope that
  /// binds the name ambiguously (in more than one of its relations) shadows the
  /// farther ones: `correlated` faults `SQLError.ambiguous`, which propagates
  /// rather than falling through to rebind the name to a farther relation. Only
  /// a NOT-found (`nil`) keeps the walk moving outward.
  internal func parameter(for column: Column) throws(SQLError) -> String? {
    for depth in scopes.indices.reversed() {
      // A bare (unqualified) name a `NATURAL`/`USING` join of this enclosing
      // scope merged (ISO 9075 7.10) correlates to its one coalesce value — the
      // merged entry shadows its two physical constituents, so a LATERAL body's
      // bare `k` binds the merged column rather than faulting `.ambiguous`
      // between the two sides. Its source is the `COALESCE` of its constituent
      // outer cells, coerced to its unified type, matching the merged column's
      // own `value` the local scope lowers. A qualified `A.k`/`B.k` never
      // matches a merged column and falls through to the physical probe.
      if column.qualifier == nil,
          let merged = try scopes[depth].merged(binding: column.name) {
        let name = parameter(merging: merged.constituents[0], at: depth)
        record(name, .coalesce(merged.constituents, merged.type),
               matching: depth)
        return name
      }
      guard let ordinal = try scopes[depth].correlated(column) else { continue }
      let name = name(for: ordinal, at: depth)
      record(name, .slot(ordinal), matching: depth)
      return name
    }
    return nil
  }

  /// Records the correlation of `name` — the `source` its per-outer-row value
  /// comes from — matched at enclosing-scope `depth`.
  ///
  /// A match at the last scope (this subquery's immediate parent) reads that
  /// outer row directly, so the source is the parent-row `source` as given (a
  /// `slot` cell or a merged column's `coalesce`). A match at an earlier scope
  /// is a correlation of the containing subquery too: it is recorded `bound`
  /// here — the eval threads the value through `bindings` rather than reading
  /// this subquery's own row — and the same `source` propagated up to `parent`
  /// (whose last scope is one level nearer), so the containing occurrence is
  /// itself marked correlated and re-executes per its enclosing row. Since a
  /// `Scope` lays relations at cumulative offsets from 0, the source's ordinals
  /// are the same in every level that shares the matched scope, so the ancestor
  /// that owns it as its immediate parent reads the right cells.
  private func record(_ name: String, _ source: Source, matching depth: Int) {
    let immediate = depth == scopes.count - 1
    correlation[name] = immediate ? source : .bound
    if !immediate { parent?.record(name, source, matching: depth) }
  }

  /// The value type of the enclosing column `column` names, or `nil` when no
  /// enclosing scope binds it — the static type a correlated reference
  /// contributes to the type-check surface (`validate`), so a correlated column
  /// types as its outer column rather than a placeholder. It records no
  /// correlation (a pure type probe); the lowering's `parameter(for:)` records
  /// the binding. Like `parameter(for:)`, a nearer scope binding the name
  /// ambiguously shadows the farther ones — `correlated` faults
  /// `SQLError.ambiguous`, which propagates rather than falling through — so
  /// the schema-derive and the run's lowering agree on the ambiguity.
  internal func type(for column: Column) throws(SQLError) -> ValueType? {
    try resolved(for: column).map(\.type)
  }

  /// The resolved enclosing column `column` names — its outer `type` AND
  /// `unconstrained` mask read together from the one ordinal a nearest-first
  /// walk matches — or `nil` when no enclosing scope binds it. It walks
  /// `scopes` nearest-first exactly as the type probe does (a nearer scope
  /// shadows a farther one), records no correlation (a pure probe), and lets an
  /// ambiguous nearer scope's `SQLError.ambiguous` propagate. `type(for:)` and
  /// any mask reader are thin accessors over this, so a correlated column's
  /// type and mask cannot diverge — the fix for a correlated all-NULL column
  /// losing its mask through the LATERAL correlation surface.
  internal func resolved(for column: Column) throws(SQLError)
      -> ResolvedColumn? {
    for scope in scopes.reversed() {
      // A bare name an enclosing `NATURAL`/`USING` join merged types from the
      // merged column's unified coalesce type (ISO 9075 7.10) — the same entry
      // `parameter(for:)` binds — so the schema-derive and the run's lowering
      // agree on a correlated merged reference. It carries the merged column's
      // own `unconstrained` mask (constrained once either constituent did, a
      // placeholder only when both were unconstrained), so an enclosing
      // set-operation fold over the correlated merged reference defers or
      // constrains consistently. A qualified name falls through to the physical
      // probe.
      if column.qualifier == nil,
          let merged = try scope.merged(binding: column.name) {
        return merged.resolved(named: column.name)
      }
      guard let ordinal = try scope.correlated(column) else { continue }
      return scope.resolved(at: ordinal, named: column.name)
    }
    return nil
  }
}

/// The mutable memo a `Subqueries` cache shares by reference for the
/// uncorrelated subqueries it materialises lazily, keyed by occurrence
/// `Subkey`.
///
/// Every subquery role — scalar collapse, `IN` value set, `EXISTS` probe — is
/// materialised lazily, on the FIRST evaluation of its lowered node, so an
/// occurrence in an unreachable `CASE`/`COALESCE` arm or a short-circuited
/// `AND`/`OR` never runs (never throws its inner fault) — the folded-in lazy
/// `IN`/`EXISTS` that the earlier slice left eager. An uncorrelated occurrence
/// is row-invariant, so the first reached evaluation runs it once and caches
/// the result here; every later read of the same key returns it without
/// re-running. A correlated occurrence is NOT memoised (its result depends on
/// the bound outer row), so it never reads or writes this — it re-runs per
/// outer row.
///
/// It is a class so the memo survives `Subqueries` being copied by value down
/// the evaluate tree — every copy shares the one box.
internal final class SubqueryMemo {
  /// The collapsed scalar value memoised per scalar occurrence.
  private var scalars: Dictionary<Subkey, Value> = [:]
  /// The `EXISTS` non-empty result memoised per existential occurrence.
  private var probes: Dictionary<Subkey, Bool> = [:]
  /// The `IN (Q)` single-column value set memoised per valued occurrence.
  private var columns: Dictionary<Subkey, Array<Value>> = [:]

  /// The resolution OVERLAY each `Subscope`'s subqueries run under — the
  /// caller's `WITH`/store overlay under `.caller`, a view body's own overlay
  /// under `.view(name)` — recorded as each scope begins executing, so the lazy
  /// evaluator runs a subquery against the overlay of the scope it was
  /// textually lowered under, NOT the (possibly different) overlay of the
  /// execution site a predicate pushdown moved it to. A caller conjunct pushed
  /// INTO a view thus still resolves its subquery's `FROM S` against the
  /// caller's `S`, not the view's base — the correctness the disjoint
  /// `Subscope` keying and the captured overlay together preserve.
  private var overlays: Dictionary<Subscope, ScopedRelations> = [:]

  internal func scalar(_ key: Subkey) -> Value? { scalars[key] }
  internal func store(scalar value: Value, for key: Subkey) {
    scalars[key] = value
  }

  internal func present(_ key: Subkey) -> Bool? { probes[key] }
  internal func store(present value: Bool, for key: Subkey) {
    probes[key] = value
  }

  internal func values(_ key: Subkey) -> Array<Value>? { columns[key] }
  internal func store(values: Array<Value>, for key: Subkey) {
    columns[key] = values
  }

  /// The compiled inner plan of each correlated occurrence, keyed by its
  /// occurrence `PlanKey` (its `Subkey` composed with the parameter names its
  /// correlation binds) — compiled once (with the enclosing scope as its
  /// `Outer`, so its correlated columns lowered to `Term.parameter`) by the run
  /// path's compile and stashed here, so the evaluator re-executes that plan
  /// per outer row against the correlated bindings rather than re-compiling the
  /// inner query fresh (which, with no outer scope in hand at eval, would fault
  /// on the outer column). Keying by the `PlanKey` keeps two occurrences of the
  /// same inner SQL — under a `.caller` and a `.view(name)` scope, or across
  /// two set-operation arms whose correlated column has a different outer
  /// ordinal — disjoint, so each executes its own plan rather than the first
  /// occurrence's, while an identical occurrence under an identical outer
  /// layout still shares. An uncorrelated occurrence carries none — it re-runs
  /// its `Query` (recompiling resolves without an outer scope) and memoises.
  private var plans: Dictionary<PlanKey, Plan> = [:]

  internal func overlay(_ scope: Subscope) -> ScopedRelations? {
    overlays[scope]
  }
  internal func record(overlay: ScopedRelations, for scope: Subscope) {
    overlays[scope] = overlay
  }

  internal func plan(_ key: PlanKey) -> Plan? { plans[key] }
  internal func record(plan: Plan, for key: PlanKey) {
    if plans[key] == nil { plans[key] = plan }
  }

  /// The occurrence `Subkey`s whose reached correlated set-operation fold has
  /// already been strictly re-validated — a reached scalar/`IN` occurrence
  /// folds once (faulting on an irreconcilable pair the first reached outer
  /// row), then subsequent rows skip the redundant per-row re-fold.
  private var validated: Set<Subkey> = []

  internal func validated(_ key: Subkey) -> Bool { validated.contains(key) }
  internal func validate(_ key: Subkey) { validated.insert(key) }
}

/// The compile-time seam that lowers an `EXISTS`/`IN (Q)` predicate without
/// running its subquery — the fix for the schema-path cursor-contract
/// violation.
///
/// Predicate lowering happens over escapable resolution surfaces (`Schema`,
/// `Scope`, `Grouped`) that carry no catalog, and is shared by schema-ONLY
/// paths (`columns(of:)`, view resolution, arity checks) documented NOT to open
/// a cursor. So lowering carries the sub-`Query` into the `Filter` as data
/// rather than running it: `exists`/`within` build the lowered node holding the
/// query, which executes once, at run time (see `Subqueries`). Only the
/// single-column arity of an `IN (Q)` is decided here — from the subquery's
/// compiled width, known without a cursor — so a two-column `IN` subquery
/// faults `SQLError.arity` at compile as before, never having run.
///
/// The `widths` map holds each nested `Query`'s compiled column count, built by
/// the `compile` path (where the catalog is in scope) by compiling — never
/// running — every subquery once ahead of lowering. A schema-only surface with
/// no catalog passes `.unsupported`, whose `width` faults, so a subquery
/// reaching such a surface is rejected rather than mis-lowered.
internal struct Resolution {
  /// The resolution context every subquery lowered against this surface
  /// materialises under — `.caller` for a top-level compile, `.view(name)` for
  /// a view body's — composed into each lowered `Filter`'s cache key so a
  /// view-body occurrence and a top-level one over the same AST stay distinct.
  private let scope: Subscope

  /// Each nested `Query` mapped to its compiled column count — cursor-free; an
  /// `IN (Q)` and a scalar subquery each require it be 1.
  private let widths: Dictionary<Query, Int>

  /// Each nested `Query` mapped to its single-column output COLUMN, derived
  /// cursor-free in the compile pre-pass — the resolved column a scalar
  /// subquery contributes, its type (the executor coerces its collapsed value
  /// to it, as a `CASE` coerces its arms) AND its `unconstrained` mask
  /// together, so a bare scalar-subquery projection over a constant-NULL body
  /// carries that mask into an outer set-operation fold rather than dropping
  /// it. Only a width-1 query has one, so an `EXISTS`/`IN (Q)` occurrence
  /// (whose type is irrelevant) may be absent.
  private let types: Dictionary<Query, ResolvedColumn>

  /// Each nested `Query` mapped to its correlation — the synthetic bound params
  /// its inner `WHERE`/`ON` names of an enclosing column, discovered by the
  /// pre-pass compiling the nested query under this select's scope as its
  /// `Outer`. An uncorrelated nested query maps to the empty correlation (or is
  /// absent), so its lowered node bypasses nothing; a correlated one carries
  /// its map into the lowered `Filter`/`Term` so the per-outer-row re-execution
  /// binds the named cells.
  private let correlations: Dictionary<Query, Correlation>

  /// The enclosing scope this select's own columns correlate against — set when
  /// this select is itself a subquery, so a column its relations do not bind
  /// resolves against the outer query and lowers to a `Term.parameter`. `nil`
  /// for a top-level select (no enclosing scope), leaving an unbound column the
  /// ordinary fault.
  private let outer: Outer?

  /// Whether this lowering surface admits a correlated column — TRUE for the
  /// inner `WHERE`/`ON` (a synthetic bound param is a valid lowering there),
  /// FALSE for the projection / `GROUP BY` / `HAVING` (the minimal (b) cut has
  /// no evaluator for an outer column there). A barred surface diagnoses a
  /// correlated column as unsupported rather than mis-resolving it.
  private let admits: Bool

  /// Whether the surface admits a correlated column everywhere — in the barred
  /// clause positions (the projection / `GROUP BY` / `HAVING`) as well as the
  /// `WHERE`/`ON` — set ONLY when lowering a LATERAL derived table's body. Per
  /// ISO 9075 a `LATERAL` body's preceding-FROM references are in scope
  /// throughout its query expression, including the select list, so a lateral
  /// body correlates everywhere while an ordinary subquery's projection stays
  /// barred. When `true`, `barred` is a no-OP — it keeps `admits`, so a
  /// projected preceding column still lowers to a `Term.parameter` — and the
  /// per-outer-row apply binds it exactly as a `WHERE`-correlated one.
  private let everywhere: Bool

  internal init(_ scope: Subscope = .caller,
                _ widths: Dictionary<Query, Int> = [:],
                _ types: Dictionary<Query, ResolvedColumn> = [:],
                _ correlations: Dictionary<Query, Correlation> = [:],
                outer: Outer? = nil, admits: Bool = true,
                everywhere: Bool = false) {
    self.scope = scope
    self.widths = widths
    self.types = types
    self.correlations = correlations
    self.outer = outer
    self.admits = admits
    self.everywhere = everywhere
  }

  /// A `Resolution` for a lowering surface with no catalog — a schema-only
  /// resolve. It holds no widths, so any subquery lowered against it faults
  /// `SQLError.unsupported` rather than mis-lower.
  internal static var unsupported: Resolution {
    Resolution()
  }

  /// This seam with correlation barred — the surface a projection / `GROUP BY`
  /// / `HAVING` lowers under, where an outer column is out of the minimal (b)
  /// cut. It keeps the widths/types/correlations (nested subqueries there still
  /// lower and carry their own inner correlation) but rejects a correlated
  /// column of this query as unsupported.
  ///
  /// A LATERAL body's surface (`everywhere`) is the exception: ISO puts the
  /// preceding-FROM references in scope throughout the body including the
  /// select list, so `barred` is a no-OP there — the projection keeps admitting
  /// a correlated column, which lowers to a `Term.parameter` the apply binds
  /// per outer row.
  internal var barred: Resolution {
    if everywhere { return self }
    return Resolution(scope, widths, types, correlations, outer: outer,
                      admits: false, everywhere: everywhere)
  }

  /// The synthetic bound-parameter name a correlated reference to `column`
  /// lowers to, or `nil` when no enclosing scope binds it (the ordinary
  /// unknown-column fault stands). A `.column` lowering consults this ONLY
  /// after its own relations fail to bind the name.
  ///
  /// On a barred surface (a projection / `GROUP BY` / `HAVING`) an outer column
  /// IS out of the minimal (b) cut, so a name the enclosing scope binds is
  /// diagnosed `SQLError.unsupported` rather than mis-resolved — the same fault
  /// on the run and the schema paths, keeping typecheck↔run parity.
  internal func correlate(_ column: Column) throws(SQLError) -> String? {
    guard let name = try outer?.parameter(for: column) else { return nil }
    guard admits else {
      throw .state("0A000",
                   "a correlated column is only supported in a subquery's " +
                   "WHERE")
    }
    return name
  }

  /// The resolved outer column a correlated reference to `column` contributes
  /// to a schema derive — its `type` AND `unconstrained` mask together — or
  /// `nil` when no enclosing scope binds it. Every type/mask reader is a thin
  /// accessor over this one resolver, so a correlated column's type and mask
  /// cannot diverge (the fix for a correlated all-NULL column losing its mask
  /// through the LATERAL surface).
  ///
  /// A barred surface (a projection / `GROUP BY` / `HAVING` of an ordinary
  /// subquery) still diagnoses a bound name `SQLError.unsupported` — the same
  /// fault the run's lowering raises, keeping typecheck↔run parity — so this
  /// widens nothing: a lateral body's projection (`everywhere`) admits it,
  /// while an ordinary subquery's projection faults exactly as before.
  internal func correlated(_ column: Column) throws(SQLError)
      -> ResolvedColumn? {
    guard let resolved = try outer?.resolved(for: column) else { return nil }
    guard admits else {
      throw .state("0A000",
                   "a correlated column is only supported in a subquery's " +
                   "WHERE")
    }
    return resolved
  }

  /// The correlation of the nested `query` — its synthetic outer bindings —
  /// discovered by the pre-pass, or the empty map for an uncorrelated one.
  private func correlation(of query: Query) -> Correlation {
    correlations[query] ?? [:]
  }

  /// The compiled column count of `query`, or a fault when the surface holds
  /// none — a subquery reaching a catalog-less lowering surface.
  private func width(_ query: Query) throws(SQLError) -> Int {
    guard let width = widths[query] else {
      throw .state("0A000", "a subquery is not supported in this position")
    }
    return width
  }

  /// The single-column output COLUMN `query` contributes as a scalar subquery —
  /// its type AND `unconstrained` mask together. The compile pre-pass records
  /// it beside the width for every subquery, so a scalar occurrence reads it; a
  /// surface with no catalog holds none and faults, rejecting the subquery
  /// rather than mis-typing it.
  private func output(_ query: Query) throws(SQLError) -> ResolvedColumn {
    guard let resolved = types[query] else {
      throw .state("0A000", "a subquery is not supported in this position")
    }
    return resolved
  }

  /// The static single-column type a scalar subquery `query` contributes to a
  /// schema derive — its single-column arity enforced first (else
  /// `SQLError.arity`, matching the lowering), so this schema surface and the
  /// run's lowering agree on both the arity fault and the type. This is the
  /// bare-`ValueType` path the run's `Term.subquery` lowering reads; the outer
  /// set-operation fold reads the whole column through `scalar(resolved:)`.
  internal func scalar(type query: Query) throws(SQLError) -> ValueType {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return try output(query).type
  }

  /// The single-column resolved COLUMN a scalar subquery `query` contributes to
  /// a schema derive — its type AND `unconstrained` mask together, the arity
  /// guard first (else `SQLError.arity`, exactly as `scalar(type:)`). A bare
  /// scalar-subquery projection reads this so a constant-NULL body's mask
  /// travels into an outer set-operation fold rather than being dropped by the
  /// bare-type path.
  internal func scalar(resolved query: Query)
      throws(SQLError) -> ResolvedColumn {
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
    return .exists(Subkey(scope, query, .existential),
                   correlation: correlation(of: query), negated: negated)
  }

  /// Lowers `operand [NOT] IN (query)` — `operand` already lowered to a `Term`
  /// — requiring `query` project exactly one column (else `SQLError.arity`,
  /// checked from the compiled width, so a two-column subquery faults here
  /// without running), then carrying the query into the `Filter` to run at
  /// execution.
  internal func within(_ operand: Term, _ query: Query, negated: Bool)
      throws(SQLError) -> Filter {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return .within(operand, Subkey(scope, query, .valued),
                   correlation: correlation(of: query), negated: negated)
  }

  /// Lowers `operand op {ANY | ALL} (query)` — `operand` already lowered to a
  /// `Term` — requiring `query` project exactly one column (else
  /// `SQLError.arity`, from the compiled width, so a two-column subquery faults
  /// here without running), then carrying the query into the `Filter` under the
  /// same `.valued` role `within` uses — the full column is materialised and
  /// folded per outer row — with the discovered `correlation` threaded exactly
  /// as `within` threads it, so a correlated quantified re-runs its inner plan
  /// per outer row (an uncorrelated one carries an empty correlation and
  /// memoises once), to run at execution.
  internal func quantified(_ operand: Term, _ op: Comparison,
                           _ quantifier: Quantifier, _ query: Query)
      throws(SQLError) -> Filter {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return .quantified(operand, op, quantifier, Subkey(scope, query, .valued),
                       correlation: correlation(of: query))
  }

  /// Lowers a scalar subquery `(query)` to a `Term.subquery` reading its
  /// collapsed value from the run-time cache, requiring `query` project exactly
  /// one column (else `SQLError.arity`, from the compiled width, so a wider
  /// subquery faults here without running). The term carries the subquery's
  /// occurrence `Subkey` — its resolution scope composed with `query` — and its
  /// single-column type, to which the executor coerces the collapsed value (the
  /// empty → NULL and >1-row → cardinality cases are decided at run, in the
  /// materialiser).
  internal func scalar(_ query: Query) throws(SQLError) -> Term {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return try .subquery(Subkey(scope, query, .scalar),
                         correlation: correlation(of: query),
                         type: output(query).type)
  }
}

/// The per-site lowering seams a select's pre-pass discovers — one `Resolution`
/// per join `ON` (resolved against that join's prefix scope) and one for the
/// rest (the WHERE, `HAVING`, projection, and `ORDER BY`, resolved against the
/// full join scope).
///
/// The same inner SQL in both an `ON` and the WHERE is resolved twice, each
/// against its own site's scope, so a name the `ON`'s narrow prefix binds
/// unambiguously yet the WHERE's full scope binds in more than one relation is
/// a prefix correlation in the `ON` and a genuine ambiguity in the WHERE — each
/// per its own site, not the first occurrence's prefix (see `subquery(of:)`).
internal struct Plans {
  /// The lowering seam of each join `ON`, in join order — `on(i)` reads the
  /// `i`-th, resolved against `prefixes[i]`.
  private let ons: Array<Resolution>

  /// The lowering seam the WHERE, `HAVING`, projection, and `ORDER BY` share,
  /// resolved against the full join scope.
  internal let rest: Resolution

  internal init(_ ons: Array<Resolution>, _ rest: Resolution) {
    self.ons = ons
    self.rest = rest
  }

  /// The lowering seam of join `index`'s `ON`.
  internal func on(_ index: Int) -> Resolution {
    ons[index]
  }
}

/// The run-time cache that runs each uncorrelated subquery once, lazily on the
/// first reach of its lowered node, and memoises the result — the seam that
/// gives the row evaluator a subquery result without itself holding the
/// borrowing catalog stored.
///
/// The evaluator (a `Catalog` method, the catalog IN scope) runs a subquery
/// itself: it reads this cache first and, on a miss, runs the inner plan and
/// `store`s the result. An uncorrelated occurrence names no enclosing column,
/// so its result is the same for every outer row and is memoised under its
/// occurrence `Subkey`; a later reach returns it without re-running. A
/// correlated occurrence's result depends on the bound outer row, so it
/// bypasses this cache entirely — the evaluator re-runs its inner plan per
/// outer row against a `bindings` extended with the correlated cells (this
/// slice does NOT memoise across distinct binding tuples — a flagged future
/// optimisation). Every role (scalar / `IN` / `EXISTS`) is lazy, so a subquery
/// an unreachable `CASE` arm or a short-circuited `AND`/`OR` never reaches
/// never runs.
internal struct Subqueries {
  /// The shared memo of the uncorrelated occurrences materialised lazily on
  /// first reach — a reference so every by-value copy of this cache down the
  /// evaluate tree shares the one box, keeping each materialise-once.
  private let memo: SubqueryMemo

  internal init(_ memo: SubqueryMemo = SubqueryMemo()) {
    self.memo = memo
  }

  /// The memoised `EXISTS` non-empty result for the uncorrelated occurrence
  /// `key`, or `nil` when it has not yet run — the evaluator probes on a miss
  /// and `store`s it.
  internal func present(cached key: Subkey) -> Bool? {
    memo.present(key)
  }

  /// Records the `EXISTS` non-empty result of the uncorrelated occurrence
  /// `key`.
  internal func store(present value: Bool, for key: Subkey) {
    memo.store(present: value, for: key)
  }

  /// The memoised `IN (Q)` single column for the uncorrelated occurrence `key`,
  /// or `nil` when it has not yet run — the evaluator materialises on a miss
  /// and `store`s it.
  internal func values(cached key: Subkey) -> Array<Value>? {
    memo.values(key)
  }

  /// Records the `IN (Q)` single-column value set of the uncorrelated
  /// occurrence `key`.
  internal func store(values: Array<Value>, for key: Subkey) {
    memo.store(values: values, for: key)
  }

  /// The already-collapsed value memoised for the scalar uncorrelated
  /// occurrence `key`, or `nil` when it has not yet been evaluated.
  internal func scalar(cached key: Subkey) -> Value? {
    memo.scalar(key)
  }

  /// Records `value` as the collapsed value of the scalar uncorrelated
  /// occurrence `key`.
  internal func store(scalar value: Value, for key: Subkey) {
    memo.store(scalar: value, for: key)
  }

  /// The resolution overlay `scope`'s subqueries run under — the overlay
  /// recorded as `scope` began executing (see `SubqueryMemo.overlays`), or
  /// `nil` when none was recorded (a top-level run always records `.caller`).
  internal func overlay(_ scope: Subscope) -> ScopedRelations? {
    memo.overlay(scope)
  }

  /// Records `overlay` as the resolution overlay `scope`'s subqueries run
  /// under — the caller's before executing the top-level plan, a view body's
  /// before deriving it — so a subquery lowered under `scope` re-runs against
  /// its overlay even when a pushdown moved its predicate to another site.
  internal func record(overlay: ScopedRelations, for scope: Subscope) {
    memo.record(overlay: overlay, for: scope)
  }

  /// The pre-compiled inner plan of the correlated occurrence `key` under
  /// `correlation` — compiled once with its enclosing scope so its correlated
  /// columns are `Term.parameter` — or `nil` for an uncorrelated one (which
  /// recompiles fresh per run). Keyed by the occurrence's `PlanKey` (its
  /// `Subkey` plus the correlation's parameter names), so two occurrences of
  /// the same inner SQL under different outer layouts — two set-operation arms
  /// whose correlated column sits at different ordinals — each find their own
  /// plan.
  internal func plan(_ key: Subkey, _ correlation: Correlation) -> Plan? {
    memo.plan(PlanKey(key, correlation))
  }

  /// Stashes `plan` as the pre-compiled inner plan of the correlated occurrence
  /// `key` under `correlation`, for the evaluator to re-execute per outer row.
  internal func record(plan: Plan, for key: Subkey,
                       _ correlation: Correlation) {
    memo.record(plan: plan, for: PlanKey(key, correlation))
  }

  /// Whether the reached correlated set-operation fold of occurrence `key` has
  /// already been strictly re-validated — so a per-row execution folds once and
  /// skips the redundant re-fold on subsequent outer rows.
  internal func validated(_ key: Subkey) -> Bool { memo.validated(key) }

  /// Records that occurrence `key`'s reached set-operation fold has been
  /// strictly re-validated.
  internal func validate(_ key: Subkey) { memo.validate(key) }

  /// This cache — the memo is a shared box the whole run accretes into, so a
  /// caller cache and a view-body cache share one box, their disjoint
  /// `Subscope` keys never colliding. The prior eager merge collapses to
  /// identity now that every occurrence is memoised lazily against this one
  /// shared box.
  internal func merged(_ other: Subqueries) -> Subqueries {
    self
  }
}

/// One subquery occurrence the type-check walk reached — its inner `query`
/// and the `role` it materialises in at that occurrence.
///
/// The role is recorded per occurrence (not derived from the union of every
/// role the query occupies in the select) so the deferred type-check picks the
/// occurrence's own run shape: an `existential` reach validates the EXISTS
/// probe (no projection), a `scalar`/`valued` reach the original. So the same
/// inner SQL reached only as an `EXISTS` validates the probe even where an
/// unreached arm has it as a scalar.
internal struct Reach: Hashable, Sendable {
  /// The reached occurrence's inner query.
  internal let query: Query

  /// The role the occurrence materialises in — the shape its deferred
  /// type-check validates.
  internal let role: Role

  internal init(_ query: Query, _ role: Role) {
    self.query = query
    self.role = role
  }
}

/// The mutable set of subquery occurrences the type-check walk reached, shared
/// by a `SubqueryCheck` by reference.
///
/// A subquery's inner-query operand validation is deferred to the reachability
/// walk (`Scope.validate`), mirroring the lazy executor: an occurrence in an
/// unreachable `CASE`/`COALESCE` arm or a short-circuited `AND`/`OR` leg never
/// validates, exactly as it never runs. The walk cannot itself hold the
/// borrowing catalog a recursive type-check needs, so as it reaches each
/// occurrence it records the inner query AND its role here; the catalog-bearing
/// `typecheck` phase reads this set after the walk and type-checks only the
/// reached occurrences, each in its own role's shape. The box is a class so the
/// reached set survives `SubqueryCheck` being copied by value down the walk —
/// every copy shares the one box, the same way `ScalarMemo` shares the run's
/// lazy collapse.
internal final class ReachedScalars {
  private var occurrences: Set<Reach> = []

  /// Records `query` as an occurrence the walk reached in `role`, so the
  /// deferred type-check phase validates its inner query in that role's shape.
  internal func reach(_ query: Query, as role: Role) {
    occurrences.insert(Reach(query, role))
  }

  /// The subquery occurrences the walk reached — the ones the deferred phase
  /// type-checks, each in its own role's shape.
  internal var reached: Set<Reach> {
    occurrences
  }
}

/// The validation-side analog of `Resolution` — the seam that lets the dry-run
/// type-check (`check`) validate the uncorrelated inner query an `EXISTS`/`IN
/// (Q)` nests without itself holding the borrowing catalog.
///
/// `check` runs over escapable resolution surfaces carrying no catalog, yet a
/// subquery's inner names and routines must be validated against one for schema
/// validation to match execution — the recurring lesson that the two must not
/// diverge. The `typecheck` path, where the borrowing catalog and `Context`
/// are in scope, builds this from the maps it fills by validating and compiling
/// every subquery ahead of the `check` walk; a surface with no catalog passes
/// `.unsupported`, which faults so a subquery reaching such a surface is
/// rejected rather than passed unvalidated.
///
/// An `EXISTS`/`IN (Q)` inner query is type-checked eagerly in that pre-pass
/// (its predicate is not short-circuited past, so it always runs), as is every
/// scalar subquery's cursor-free arity and type derivation (total — a CASE's
/// static column type unifies all arms regardless of runtime reachability, and
/// deriving the type of `1 / 0` yields the integer type without dividing). A
/// scalar subquery's inner-query operand validation is instead deferred: the
/// `.subquery` case of the reachability walk records the reached query into the
/// shared `reached` box, and the `typecheck` phase validates only those after
/// the walk — so an unreachable arm's scalar subquery is not validated, exactly
/// as the executor does not evaluate it.
internal struct SubqueryCheck {
  /// Each nested `Query` mapped to its compiled column count — the map the
  /// `typecheck` path builds by compiling every subquery once, ahead of the
  /// `check` walk. `check` reads its width to enforce a `IN (Q)`'s or a scalar
  /// subquery's single-column arity.
  private let widths: Dictionary<Query, Int>

  /// Each nested `Query` mapped to its single-column output COLUMN, derived by
  /// the `typecheck` pre-pass — the type AND `unconstrained` mask a scalar
  /// subquery reports to the result schema (`validate`/`derive`), matching the
  /// lowering's `Resolution`. The mask lets a bare scalar-subquery projection
  /// over a constant-NULL body stay unconstrained in an outer set-operation
  /// fold.
  private let types: Dictionary<Query, ValueType>

  /// The scalar inner queries whose operand validation is deferred through the
  /// `.subquery` case of the walk — a scalar-ONLY occurrence, recorded reached
  /// by `type`. An `IN`/`EXISTS`/quantified occurrence defers through
  /// `validate` instead (its arity/type derivation stays total), so the two
  /// record paths stay distinct.
  private let deferred: Set<Query>

  /// The shared box the walk records each reached scalar occurrence into, read
  /// by the catalog-bearing `typecheck` phase after the walk to validate the
  /// reached inner queries.
  private let reached: ReachedScalars

  /// The enclosing scope this select's own columns correlate against — the
  /// validation-side analog of `Resolution.outer`, so a correlated column
  /// resolves against the outer query exactly as the run's lowering does,
  /// keeping typecheck↔run parity. `nil` for a top-level select.
  private let outer: Outer?

  /// Whether this surface admits a correlated column — the inner `WHERE`/`ON`
  /// (TRUE) versus a projection / `GROUP BY` / `HAVING` (FALSE, diagnosed) —
  /// the analog of `Resolution.admits`, so validation faults the unsupported
  /// correlated-projection case exactly where the run does.
  private let admits: Bool

  /// Whether the surface admits a correlated column everywhere — a LATERAL
  /// body's validation surface, the analog of `Resolution.everywhere` — so
  /// `barred` is a no-OP and the projection/`HAVING` walk of a lateral body
  /// validates a correlated preceding column rather than faulting, matching the
  /// run's lowering (typecheck↔run parity).
  private let everywhere: Bool

  internal init(_ widths: Dictionary<Query, Int> = [:],
                _ types: Dictionary<Query, ValueType> = [:],
                deferred: Set<Query> = [],
                reached: ReachedScalars = ReachedScalars(),
                outer: Outer? = nil, admits: Bool = true,
                everywhere: Bool = false) {
    self.widths = widths
    self.types = types
    self.deferred = deferred
    self.reached = reached
    self.outer = outer
    self.admits = admits
    self.everywhere = everywhere
  }

  /// A checker for a surface with no catalog — validating a subquery needs one,
  /// so it holds no widths and faults `SQLError.unsupported` rather than pass a
  /// subquery unvalidated.
  internal static var unsupported: SubqueryCheck {
    SubqueryCheck()
  }

  /// This checker with correlation barred — the surface a projection / `GROUP
  /// BY` / `HAVING` type-checks under, where an outer column is out of the (b)
  /// cut and is diagnosed rather than resolved. Mirrors `Resolution.barred` —
  /// including the LATERAL-body exception (`everywhere`), where it is a no-OP
  /// so the projection/`HAVING` walk keeps admitting the correlated preceding
  /// column the run's lowering binds.
  internal var barred: SubqueryCheck {
    if everywhere { return self }
    return SubqueryCheck(widths, types, deferred: deferred, reached: reached,
                         outer: outer, admits: false, everywhere: everywhere)
  }

  /// This checker over a fresh `reached` box, carrying `outer` — the surface a
  /// join `ON` type-checks under. The `ON` shares this select's width/type
  /// derivation and its enclosing `outer` (a correlated `ON` column resolves
  /// against the containing query as the WHERE's does), but the caller runs its
  /// reachability walk against the join's prefix scope (its local relations),
  /// so a reference to a later-joined relation faults per the prefix. The fresh
  /// box keeps its reached occurrences separate for the caller to validate
  /// against that prefix.
  internal func scoped(_ outer: Outer?) -> SubqueryCheck {
    SubqueryCheck(widths, types, deferred: deferred,
                  reached: ReachedScalars(), outer: outer)
  }

  /// The outer type `column` correlates to, or `nil` when no enclosing scope
  /// binds it — the validation-side `Resolution.correlate`: it resolves against
  /// `outer`, faulting `.unsupported` on a barred surface (a projection /
  /// `GROUP BY` / `HAVING`) so validation rejects the unsupported
  /// correlated-projection case exactly as the run's lowering does, and returns
  /// the outer column's type so `validate` types the reference as that column.
  /// Consulted ONLY after the local relations fail to bind the name.
  internal func correlated(_ column: Column) throws(SQLError) -> ValueType? {
    guard let type = try outer?.type(for: column) else { return nil }
    guard admits else {
      throw .state("0A000",
                   "a correlated column is only supported in a subquery's " +
                   "WHERE")
    }
    return type
  }

  /// Asserts the inner `query` was compiled in the pre-pass — a query the
  /// surface's map holds has had its arity/type derived; one it does not
  /// reached a catalog-less surface and is rejected — and records it reached in
  /// `role`, so the `typecheck` phase validates its operands after the walk in
  /// that role's shape. This is the walk-reach point for an
  /// `IN`/`EXISTS`/quantified occurrence: `check` calls it only when the
  /// reachability walk arrives at the `.within`/`.exists`/`.quantified` node,
  /// so an occurrence in a skipped `CASE`/`COALESCE` arm or a short-circuited
  /// `AND`/`OR` leg is never recorded — its body is not type-checked, exactly
  /// as the lazy executor never materialises it. A reached one is validated in
  /// its own role's shape (an `EXISTS` reach → the probe), so a reached bad
  /// body still faults (parity both directions), while an unreached arm's role
  /// never widens a reached occurrence's shape.
  internal func validate(_ query: Query, as role: Role) throws(SQLError) {
    if widths[query] == nil {
      throw .state("0A000", "a subquery is not supported in this position")
    }
    reached.reach(query, as: role)
  }

  /// The column count `query` projects — from the pre-pass compile.
  internal func width(_ query: Query) throws(SQLError) -> Int {
    guard let width = widths[query] else {
      throw .state("0A000", "a subquery is not supported in this position")
    }
    return width
  }

  /// The single-column output type `query` contributes as a scalar subquery —
  /// from the pre-pass derive — validating its single-column arity first (else
  /// `SQLError.arity`, matching the run's lowering). This is the walk-reached
  /// path, so a scalar occurrence whose operand validation was deferred is
  /// recorded reached here, for the `typecheck` phase to validate its inner
  /// query. The cursor-free arity/type derivation stays separate and total: the
  /// arity of an unreachable scalar was already enforced eagerly in the
  /// pre-pass (`subqueryCheck`), so a two-column subquery in a skipped arm
  /// still faults.
  internal func type(_ query: Query) throws(SQLError) -> ValueType {
    // A deferred scalar occurrence is reached here in the `scalar` role: record
    // it for the `typecheck` phase to validate its inner query's operands,
    // mirroring the lazy executor materialising only a reached scalar. Its
    // arity and single-column type were derived eagerly in `subqueryCheck`
    // (cursor-free, total), so this reads them exactly as an eagerly-checked
    // occurrence does — only the operand fault (`.divide`) it might raise
    // defers to the reached walk.
    if deferred.contains(query) { reached.reach(query, as: .scalar) }
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    guard let type = types[query] else {
      throw .state("0A000", "a subquery is not supported in this position")
    }
    return type
  }

  /// The occurrences the walk reached — the scalar ones recorded by `type` and
  /// the `IN`/`EXISTS`/quantified ones recorded by `validate` — each paired
  /// with the role it reached in. The `typecheck` phase validates only these
  /// after the walk, mirroring the lazy executor's evaluation of only a reached
  /// subquery, picking each one's run shape from its own reached role (an
  /// `existential` → the EXISTS probe, a `scalar`/`valued` → the original), not
  /// from the union of every role the query occupies in the select.
  internal var visited: Set<Reach> {
    reached.reached
  }
}

/// Lowers the name-addressed AST `predicate` to the engine's `Filter`, lowering
/// each leaf's operand expressions through `term` and passing a `bound`
/// comparison's `:parameter` through unchanged.
///
/// Every predicate lowering — a single relation, a join scope, a grouped scope
/// — shares this shape, differing only in how a leaf term resolves its columns
/// (against one schema, a combined join space, or a grouped slot space); each
/// caller supplies that resolution as `term`.
internal func lower(_ predicate: Predicate,
                    term: (Expression) throws(SQLError) -> Term,
                    subquery: Resolution)
    throws(SQLError) -> Filter {
  switch predicate {
  case let .comparison(left, op, right):
    try Filter(compare: term(left), op, term(right))
  case let .bound(left, op, parameter):
    try .bound(term(left), op, parameter)
  case let .null(expression, negated):
    try Filter(null: term(expression), negated: negated)
  case let .exists(query, negated):
    // `[NOT] EXISTS (Q)`. In this first slice `Q` is uncorrelated, so the
    // materialiser runs it once (as a CTE body materialises) and the whole
    // predicate is the definite non-empty test of that result — never UNKNOWN,
    // `negated` flipping it. A missing materialiser (a lowering surface with no
    // catalog in scope) rejects the subquery rather than mis-lower it.
    try subquery.exists(query, negated: negated)
  case let .within(expression, query, negated):
    // `x [NOT] IN (Q)`. `Q` is uncorrelated here, so the materialiser runs it
    // once, checks it projects exactly one column (else `SQLError.arity`), and
    // lowers to a `Filter.within` folding `x = v` over that column under the
    // value-list `IN`'s three-valued Kleene `OR`.
    try subquery.within(term(expression), query, negated: negated)
  case let .quantified(expression, op, quantifier, query):
    // `x op {ANY | ALL} (Q)`. `Q` is uncorrelated here, so the materialiser
    // runs it once, checks it projects exactly one column (else
    // `SQLError.arity`), and lowers to a `Filter.quantified` folding `x op v`
    // over that column with the same `matches`/Kleene primitives `within` uses
    // — Kleene `OR` for `any`, Kleene `AND` for `all`.
    try subquery.quantified(term(expression), op, quantifier, query)
  case let .membership(expression, values, negated):
    // `x IN (a, b, …)` is the disjunction `x = a OR x = b OR …` and `NOT IN`
    // its negation, lowered to a first-class `Filter.membership` that evaluates
    // the operand once per row (an OR-chain would re-evaluate a side-effecting
    // operand once per element) and folds the element equalities under Kleene
    // `OR`. That yields the ISO three-valued result: an unmatched test with a
    // NULL operand or a NULL element is UNKNOWN — Kleene `OR` of a FALSE and an
    // UNKNOWN is UNKNOWN — not FALSE, and `NOT` maps that UNKNOWN to itself, so
    // `NOT IN` a list holding NULL is never TRUE.
    try membership(term(expression), values, negated: negated, term: term)
  case let .rows(lhs, op, rhs):
    // `(l…) <op> (r…)` lowers to a first-class `Filter.comparison` — the two
    // rows of equal arity (`SQLError.arity` otherwise), each component lowered
    // once through `term`. The runtime evaluates every component exactly once
    // per row and folds the values with the same `matches`/Kleene primitives a
    // scalar comparison uses (a componentwise Kleene `AND` for `=`, its
    // negation for `<>`, the lexicographic cascade for the ordering operators),
    // so a stateful component is read once and the ISO three-valued truth is
    // preserved. A desugar to a conjunction/cascade of scalar comparisons
    // duplicated a component across its places, re-evaluating it.
    try rows(lhs, op, rhs, term: term)
  case let .among(lhs, rows, negated):
    // `(l…) [NOT] IN ((r…), …)` lowers to a first-class `Filter.memberships` —
    // the left row and a non-empty list of element rows, all of equal arity
    // (`SQLError.arity` otherwise, an empty list rejected), each component
    // lowered once through `term`. The runtime evaluates the left row once per
    // row and folds `(l…) = (r…)` over the element rows under Kleene `OR`, so
    // the left components are read once rather than once per element (an
    // OR-chain of row equalities would re-read them), keeping the value-list
    // `IN`'s three-valued semantics.
    try among(lhs, rows, negated: negated, term: term)
  case let .like(operand, pattern, escape, negated):
    // Lower each operand to a first-class `Filter.like`; the optional escape
    // lowers only when present. The matcher and three-valued handling live in
    // the runtime, so lowering just resolves the operand terms.
    try like(operand, pattern, escape, negated: negated, term: term)
  case let .between(test, low, high, negated):
    // `x [NOT] BETWEEN a AND b` lowers to a first-class `Filter.between` that
    // evaluates the test `x` once per row (an `AND`/`OR` of two comparisons
    // would re-evaluate a non-idempotent `x`, once per bound) and folds the two
    // bounds against that same value under Kleene logic — a NULL `x`, `a`, or
    // `b` making a bound UNKNOWN and excluding the row, the ISO range test.
    // Each bound lowers through the same `Operand` form a `LIKE` pattern does,
    // a `.term` or a `:parameter` name resolved from the bindings at eval.
    try Filter(between: term(test), lower(low, term: term),
               lower(high, term: term), negated: negated)
  case let .distinct(lhs, rhs, negated):
    // `a IS [NOT] DISTINCT FROM b` lowers to a first-class `Filter.distinct`
    // over the two lowered terms — the null-safe comparison the runtime
    // evaluates two-valued, treating NULL as a comparable value. No
    // `:parameter` form is defined, so both sides lower straight through
    // `term`.
    try Filter(distinct: term(lhs), term(rhs), negated: negated)
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
/// The operand is held once rather than copied into an OR-chain of `left = vi`
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
  if values.isEmpty {
    throw .state("42601", "IN requires a non-empty value list")
  }
  var elements = Array<Term>()
  elements.reserveCapacity(values.count)
  for value in values {
    try elements.append(term(value))
  }
  return Filter(membership: left, elements, negated: negated)
}

/// Lowers `(l…) <op> (r…)` to a first-class `Filter.comparison(l, op, r)`, the
/// two rows lowered componentwise through `term`.
///
/// The two rows must be of equal arity (`SQLError.arity` otherwise) — a
/// row-value comparison of unequal rows is undefined. Each component is lowered
/// once rather than duplicated into a desugared conjunction/cascade of scalar
/// comparisons: that desugar named a component in several places (the `<`
/// cascade uses each earlier component in both a strict step and an equality
/// tie-guard), so a non-idempotent component was evaluated more than once. The
/// `Filter.comparison` runtime evaluates every component exactly once per row,
/// then folds the values with the same `matches`/Kleene primitives — preserving
/// the ISO three-valued truth while reading each component a single time.
private func rows(_ lhs: Array<Expression>, _ op: Comparison,
                  _ rhs: Array<Expression>,
                  term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  guard lhs.count == rhs.count else {
    throw .arity(lhs.count, rhs.count)
  }
  var l = Array<Term>()
  l.reserveCapacity(lhs.count)
  for expression in lhs { try l.append(term(expression)) }
  var r = Array<Term>()
  r.reserveCapacity(rhs.count)
  for expression in rhs { try r.append(term(expression)) }
  return Filter(comparison: l, op, r)
}

/// Lowers `(l…) [NOT] IN ((r…), …)` to a first-class
/// `Filter.memberships(l, [[r…], …], negated:)`, the left row and each element
/// row lowered componentwise through `term`.
///
/// The element list must be non-empty and every element row of the same arity
/// as the left row (`SQLError.arity` otherwise) — as with the scalar value-list
/// `IN`, the parser rejects `IN ()`, but `Predicate.among` is public, so a
/// caller can bypass the grammar and this lowering rejects it. The left row's
/// components are lowered once and held rather than copied into an OR-chain of
/// scalar row equalities: that chain re-evaluated the left components once per
/// element row, so a non-idempotent component yielded a different value each
/// element compared against. The `Filter.memberships` runtime evaluates the
/// left row once per row, then folds `(l…) = (r…)` over the elements under
/// Kleene `OR` — the same three-valued membership the value-list `IN` uses.
private func among(_ lhs: Array<Expression>, _ rows: Array<Array<Expression>>,
                   negated: Bool,
                   term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  if rows.isEmpty {
    throw .state("42601", "IN requires a non-empty value list")
  }
  var l = Array<Term>()
  l.reserveCapacity(lhs.count)
  for expression in lhs { try l.append(term(expression)) }
  var elements = Array<Array<Term>>()
  elements.reserveCapacity(rows.count)
  for element in rows {
    guard element.count == lhs.count else {
      throw .arity(lhs.count, element.count)
    }
    var row = Array<Term>()
    row.reserveCapacity(element.count)
    for expression in element { try row.append(term(expression)) }
    elements.append(row)
  }
  return Filter(memberships: l, elements, negated: negated)
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
  return try Filter(like: term(operand), pattern: lower(pattern, term: term),
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
/// direction. `column` records the 0-based projection column an ordinal or an
/// output alias names — the two forms that reference the select list by
/// construction — and is `nil` for an ordinary input expression. `shaped`
/// materialises each projected output once below the sort and orders an output
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
/// - `ordinal(n)` names the query's `n`-th projected output column (1-based).
///   It resolves to that projection item's already-lowered `Term`
///   (`projection[n - 1]`) — the same expression the select list computes,
///   re-used over the source rows the sort runs on — so a bare-column ordinal
///   reads its slot and a computed one (`SELECT a + b … ORDER BY 1`) recomputes
///   the expression. An `n` outside `1 ... projection.count` faults
///   `SQLError.column` (spelled as the ordinal), as an unknown column would.
/// - `expression(.column(name))` with an unqualified `name` is either an output
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
/// representation-independent — a bare projected column contributes no output
/// name and `ORDER BY` resolves it as an input column whether the projection is
/// a `columns` or an `expressions` list. An alias two items share has no single
/// term to order on — the two aliases may compute different values, so the
/// result must not depend on select-list order — and a bare `ORDER BY` name
/// matching it is `SQLError.ambiguous`, as the grouped `Grouped.order` does.
internal func order(_ order: Order, _ projection: Array<Term>,
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
