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
  /// A `LATERAL (SELECT …)` FROM/JOIN occurrence — a correlated apply's right
  /// side, materialised in full per outer row. Distinct from the predicate
  /// roles so a lateral body's pre-compiled plan keys disjointly from any
  /// scalar/`IN`/`EXISTS` occurrence of the same inner SQL.
  case lateral
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

/// The cache identity of one CORRELATED subquery occurrence's pre-compiled plan
/// — its occurrence `Subkey` composed with the SET OF SYNTHETIC PARAMETER NAMES
/// its correlation binds.
///
/// The `Subkey` alone (scope + query + role) does NOT separate two occurrences
/// of IDENTICAL inner SQL that compile under DIFFERENT outer layouts — the two
/// arms of a set operation, `SELECT (SELECT m FROM Src WHERE m = k) FROM Outer1
/// UNION ALL SELECT (SELECT m FROM Src WHERE m = k) FROM Outer2` where
/// `Outer1.k` sits at ordinal 0 and `Outer2.k` at ordinal 1. Both arms carry
/// the SAME `Subkey` (same `.caller` scope, same AST, same role), so keying the
/// plan memo by `Subkey` alone lets the right arm READ the LEFT arm's plan —
/// which binds `:__correlated_0_0` while the right arm's outer row binds
/// `:__correlated_0_1`, yielding NULL/wrong results. The correlation's
/// PARAMETER NAMES (`:__correlated_<depth>_<ordinal>`) encode each occurrence's
/// own outer layout and are STABLE across the ordinal remap `optimise` applies
/// (it rewrites the `Source` values, never the keys), so they match at the
/// RECORD site (the pre-pass compile) and the LOOKUP site (the lowered node)
/// while DIFFERING between the two arms. Adding them to the key gives each arm
/// its OWN plan yet preserves legitimate SHARING: an identical occurrence under
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
/// cell of the IMMEDIATE enclosing row (`slot`), or an ALREADY-bound parameter
/// the containing subquery threads through (`bound`).
///
/// A correlation to the subquery's IMMEDIATE enclosing query reads that outer
/// row directly: `slot` is the outer combined ordinal the re-execution binds
/// from the current outer row. A correlation to a scope TWO OR MORE levels up
/// (a NESTED subquery naming a grandparent column) is bound by the CONTAINING
/// subquery — which the bubble-up marks correlated to that same grandparent, so
/// it re-executes and binds the parameter — and the inner occurrence only reads
/// it back through `bindings`, so its source is `bound`: the eval leaves the
/// threaded binding intact rather than overwriting it from the inner's own row.
internal enum Source: Hashable, Sendable {
  /// The value is the current outer row's cell at this combined ordinal.
  case slot(Int)
  /// The value is the `COALESCE` (first non-NULL) of the current outer row's
  /// cells at these combined ordinals, COERCED to the unified `type` — a
  /// `NATURAL`/`USING` MERGED column of an enclosing join scope (ISO 9075
  /// 7.10), whose value belongs to NEITHER physical side but to their coalesce,
  /// correlated into a LATERAL body (or any nested subquery) as its ONE merged
  /// column. It reads the outer row rather than a threaded binding, exactly as
  /// `slot`, over MORE than one cell, matching the merged column's own
  /// `COALESCE(left, right)` value the local scope lowers.
  case coalesce(Array<Int>, ValueType)
  /// The value is already in `bindings` — threaded down by the containing
  /// subquery — so the eval passes it through unchanged.
  case bound
}

/// The CORRELATION of a subquery occurrence — the synthetic bound parameters
/// its inner query names, each mapped to the `Source` its per-outer-row value
/// comes from (an immediate-enclosing-row cell, or a threaded binding).
///
/// A CORRELATED subquery references a column of an enclosing query (`SELECT V
/// FROM S WHERE S.k = T.k`, the inner `T.k` outer). This slice ships the
/// MINIMAL (b) cut: an outer column is allowed ONLY in the inner query's
/// `WHERE`/`ON` (a comparison operand or a `WHERE`-position term), where it
/// lowers to a synthetic `Term.parameter(name)` — reusing the run's `bindings`
/// with NO new evaluator beyond that leaf. This map records, per synthetic
/// name, the `Source` the per-outer-row re-execution binds it from. An EMPTY
/// map is an UNCORRELATED occurrence, materialised once and memoised; a
/// NON-empty one re-runs the inner plan per outer row against a `bindings`
/// extended with each named cell, bypassing the materialise cache.
///
/// An outer column in the inner PROJECTION / `GROUP BY` / `HAVING` is OUT of
/// this cut — it needs the general (a)-style outer-row evaluator, not a bound
/// param — so it is DIAGNOSED as unsupported rather than mis-resolved (see
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

/// The ENCLOSING resolution scope a subquery lowers against for its CORRELATED
/// columns — the scope STACK the minimal (b) correlation cut consults when an
/// inner column binds against none of the subquery's OWN in-scope relations.
///
/// A subquery resolves its columns against its own relations FIRST; a name none
/// of them binds is a candidate CORRELATED reference to an enclosing query.
/// This carries the enclosing `Scope`s, innermost last, and — as lowering
/// reaches each such candidate — resolves it against them (nearest first),
/// MINTS a synthetic `:parameter` name for the outer combined ordinal, and
/// RECORDS the (name → ordinal) pair into the shared `correlation` accumulator
/// so the per-outer-row re-execution can bind that cell. It is a class so the
/// accumulator survives the seam being copied by value down the lowering, and
/// so the SAME occurrence lowered on the run and the schema paths accretes into
/// one map.
///
/// A name no enclosing scope binds either stays the ordinary unknown-column
/// fault (the local surface already raised `SQLError.column`); this only
/// intercepts a name the OUTER scope binds. Correlation is admitted ONLY where
/// a synthetic bound param is a valid lowering — a `WHERE`/`ON` term — so a
/// scope with no admitted position (a projection / `GROUP BY` / `HAVING`
/// surface) carries no `Outer` and the outer column stays unresolved, DIAGNOSED
/// as unsupported rather than mis-bound.
internal final class Outer {
  /// The enclosing scopes, OUTERMOST first — a column resolves against the
  /// nearest enclosing (last) that binds it, matching lexical scoping. The LAST
  /// scope is this subquery's IMMEDIATE parent; any earlier one is a
  /// grandparent (or further) whose correlation BUBBLES UP to the containing
  /// subquery.
  private let scopes: Array<Scope>

  /// The enclosing subquery's `Outer` — the one holding `scopes` MINUS the last
  /// — up which a correlation to a non-immediate scope propagates, so the
  /// CONTAINING subquery is marked correlated to that grandparent column too.
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

  /// This outer scope extended with `scope` as the NEAREST enclosing one — the
  /// stack a nested subquery lowers against, seeing its immediate parent last,
  /// with `self` as the parent so a correlation to a grandparent scope bubbles
  /// up. The accumulator starts fresh: correlation is recorded PER occurrence,
  /// not shared across sibling subqueries.
  internal func nested(under scope: Scope) -> Outer {
    Outer(scopes + [scope], parent: self)
  }

  /// The synthetic `:parameter` name a correlated reference to enclosing
  /// combined `ordinal` at scope `depth` lowers to — deterministic in BOTH, so
  /// the run and schema lowerings of the SAME occurrence mint identical names
  /// and the re-execution binds them from the outer row. The `depth` (the
  /// scope-stack index the reference resolves at) disambiguates two references
  /// from DIFFERENT enclosing scopes that share an ordinal — a `T.id`
  /// (grandparent) and a `U.u` (parent) both at combined ordinal 0 — so each
  /// gets its OWN synthetic param and correlation entry rather than colliding
  /// on `:__correlated_0`. The depth is a scope-stack index, stable across the
  /// bubble-up (a parent sees the shared prefix scope at the SAME index), so
  /// the binding level and the threading levels agree on the name.
  private func name(for ordinal: Int, at depth: Int) -> String {
    ":__correlated_\(depth)_\(ordinal)"
  }

  /// The synthetic `:parameter` name a correlated reference to a
  /// `NATURAL`/`USING` MERGED column of enclosing scope `depth` lowers to —
  /// keyed by the merged column's LEFT constituent ordinal but in a DISTINCT
  /// namespace from `name(for:at:)`, so it cannot collide with the physical
  /// parameter of ANY constituent slot. A LATERAL body that references BOTH the
  /// bare merged column (this key) AND a physical constituent `A.k` (the
  /// physical `name(for:at:)` key) thus gets TWO correlation entries, one per
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
  /// The enclosing scopes are consulted NEAREST first (the innermost enclosing
  /// query shadows an outer one, as lexical scoping requires). On a match it
  /// records the correlation (see `record(_:matching:)`) and returns the name,
  /// so the caller lowers the column to a `Term.parameter`. A nearer scope that
  /// binds the name AMBIGUOUSLY (in more than one of its relations) SHADOWS the
  /// farther ones: `correlated` faults `SQLError.ambiguous`, which propagates
  /// rather than falling through to rebind the name to a farther relation. Only
  /// a NOT-FOUND (`nil`) keeps the walk moving outward.
  internal func parameter(for column: Column) throws(SQLError) -> String? {
    for depth in scopes.indices.reversed() {
      // A bare (unqualified) name a `NATURAL`/`USING` join of this enclosing
      // scope MERGED (ISO 9075 7.10) correlates to its ONE coalesce value — the
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
  /// A match at the LAST scope (this subquery's immediate parent) reads that
  /// outer row directly, so the source is the parent-row `source` as given (a
  /// `slot` cell or a merged column's `coalesce`). A match at an EARLIER scope
  /// is a correlation of the CONTAINING subquery too: it is recorded `bound`
  /// here — the eval threads the value through `bindings` rather than reading
  /// this subquery's own row — and the SAME `source` propagated up to `parent`
  /// (whose last scope is one level nearer), so the containing occurrence is
  /// itself marked correlated and re-executes per its enclosing row. Since a
  /// `Scope` lays relations at cumulative offsets from 0, the source's ordinals
  /// are the same in every level that shares the matched scope, so the ancestor
  /// that owns it as its IMMEDIATE parent reads the right cells.
  private func record(_ name: String, _ source: Source, matching depth: Int) {
    let immediate = depth == scopes.count - 1
    correlation[name] = immediate ? source : .bound
    if !immediate { parent?.record(name, source, matching: depth) }
  }

  /// The value type of the enclosing column `column` names, or `nil` when no
  /// enclosing scope binds it — the static type a correlated reference
  /// contributes to the type-check surface (`validate`), so a correlated column
  /// types as its outer column rather than a placeholder. It records NO
  /// correlation (a pure type probe); the lowering's `parameter(for:)` records
  /// the binding. Like `parameter(for:)`, a nearer scope binding the name
  /// AMBIGUOUSLY SHADOWS the farther ones — `correlated` faults
  /// `SQLError.ambiguous`, which propagates rather than falling through — so
  /// the schema-derive and the run's lowering AGREE on the ambiguity.
  internal func type(for column: Column) throws(SQLError) -> ValueType? {
    try resolved(for: column).map(\.type)
  }

  /// The resolved enclosing column `column` names — its outer `type` AND
  /// `unconstrained` mask read TOGETHER from the one ordinal a nearest-first
  /// walk matches — or `nil` when no enclosing scope binds it. It walks
  /// `scopes` NEAREST-first exactly as the type probe does (a nearer scope
  /// shadows a farther one), records NO correlation (a pure probe), and lets an
  /// ambiguous nearer scope's `SQLError.ambiguous` propagate. `type(for:)` and
  /// any mask reader are THIN accessors over this, so a correlated column's
  /// type and mask cannot diverge — the fix for a correlated all-NULL column
  /// losing its mask through the LATERAL correlation surface.
  internal func resolved(for column: Column) throws(SQLError)
      -> ResolvedColumn? {
    for scope in scopes.reversed() {
      // A bare name an enclosing `NATURAL`/`USING` join MERGED types from the
      // merged column's unified coalesce type (ISO 9075 7.10) — the SAME entry
      // `parameter(for:)` binds — so the schema-derive and the run's lowering
      // agree on a correlated merged reference. It carries the merged column's
      // OWN `unconstrained` mask (constrained once either constituent did, a
      // placeholder only when BOTH were unconstrained), so an enclosing
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

/// The mutable memo a `Subqueries` cache shares by REFERENCE for the
/// UNCORRELATED subqueries it materialises LAZILY, keyed by occurrence
/// `Subkey`.
///
/// Every subquery ROLE — scalar collapse, `IN` value set, `EXISTS` probe — is
/// materialised LAZILY, on the FIRST evaluation of its lowered node, so an
/// occurrence in an unreachable `CASE`/`COALESCE` arm or a short-circuited
/// `AND`/`OR` never runs (never throws its inner fault) — the folded-in lazy
/// `IN`/`EXISTS` that the earlier slice left eager. An UNCORRELATED occurrence
/// is row-invariant, so the first reached evaluation runs it ONCE and caches
/// the result here; every later read of the same key returns it WITHOUT
/// re-running. A CORRELATED occurrence is NOT memoised (its result depends on
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

  /// The RESOLUTION OVERLAY each `Subscope`'s subqueries run under — the
  /// caller's `WITH`/store overlay under `.caller`, a view body's own overlay
  /// under `.view(name)` — recorded as each scope BEGINS executing, so the lazy
  /// evaluator runs a subquery against the overlay of the scope it was
  /// TEXTUALLY lowered under, NOT the (possibly different) overlay of the
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

  /// The COMPILED inner plan of each CORRELATED occurrence, keyed by its
  /// occurrence `PlanKey` (its `Subkey` composed with the parameter names its
  /// correlation binds) — compiled ONCE (with the enclosing scope as its
  /// `Outer`, so its correlated columns lowered to `Term.parameter`) by the run
  /// path's compile and stashed here, so the evaluator RE-EXECUTES that plan
  /// per outer row against the correlated bindings rather than RE-COMPILING the
  /// inner query fresh (which, with no outer scope in hand at eval, would fault
  /// on the outer column). Keying by the `PlanKey` keeps two occurrences of the
  /// SAME inner SQL — under a `.caller` and a `.view(name)` scope, or across
  /// two set-operation arms whose correlated column has a DIFFERENT outer
  /// ordinal — DISJOINT, so each executes its OWN plan rather than the first
  /// occurrence's, while an identical occurrence under an identical outer
  /// layout still SHARES. An UNCORRELATED occurrence carries none — it re-runs
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
  /// folds ONCE (faulting on an irreconcilable pair the first reached outer
  /// row), then subsequent rows skip the redundant per-row re-fold.
  private var validated: Set<Subkey> = []

  internal func validated(_ key: Subkey) -> Bool { validated.contains(key) }
  internal func validate(_ key: Subkey) { validated.insert(key) }
}

/// The COMPILE-time seam that lowers an `EXISTS`/`IN (Q)` predicate WITHOUT
/// running its subquery — the fix for the schema-path cursor-contract
/// violation.
///
/// Predicate lowering happens over escapable resolution surfaces (`Schema`,
/// `Scope`, `Grouping`) that carry no catalog, and is shared by SCHEMA-ONLY
/// paths (`columns(of:)`, view resolution, arity checks) documented NOT to open
/// a cursor. So lowering carries the sub-`Query` into the `Filter` as DATA
/// rather than running it: `exists`/`within` build the lowered node holding the
/// query, which executes ONCE, at RUN time (see `Subqueries`). Only the
/// single-column arity of an `IN (Q)` is decided here — from the subquery's
/// COMPILED WIDTH, known without a cursor — so a two-column `IN` subquery
/// faults `SQLError.arity` at compile as before, never having run.
///
/// The `widths` map holds each nested `Query`'s compiled column count, built by
/// the `compile` path (where the catalog is in scope) by COMPILING — never
/// running — every subquery ONCE ahead of lowering. A schema-only surface with
/// no catalog passes `.unsupported`, whose `width` faults, so a subquery
/// reaching such a surface is rejected rather than mis-lowered.
internal struct Resolution {
  /// The resolution context every subquery lowered against this surface
  /// materialises under — `.caller` for a top-level compile, `.view(name)` for
  /// a view body's — composed into each lowered `Filter`'s cache key so a
  /// view-body occurrence and a top-level one over the same AST stay distinct.
  private let scope: Subscope

  /// Each nested `Query` mapped to its COMPILED column count — cursor-free; an
  /// `IN (Q)` and a scalar subquery each require it be 1.
  private let widths: Dictionary<Query, Int>

  /// Each nested `Query` mapped to its single-column output COLUMN, derived
  /// cursor-free in the compile pre-pass — the resolved column a scalar
  /// subquery contributes, its TYPE (the executor coerces its collapsed value
  /// to it, as a `CASE` coerces its arms) AND its `unconstrained` mask
  /// TOGETHER, so a bare scalar-subquery projection over a constant-NULL body
  /// carries that mask into an outer set-operation fold rather than dropping
  /// it. Only a width-1 query has one, so an `EXISTS`/`IN (Q)` occurrence
  /// (whose type is irrelevant) may be absent.
  private let types: Dictionary<Query, ResolvedColumn>

  /// Each nested `Query` mapped to its CORRELATION — the synthetic bound params
  /// its inner `WHERE`/`ON` names of an enclosing column, discovered by the
  /// pre-pass compiling the nested query under this select's scope as its
  /// `Outer`. An UNCORRELATED nested query maps to the empty correlation (or is
  /// absent), so its lowered node bypasses nothing; a correlated one carries
  /// its map into the lowered `Filter`/`Term` so the per-outer-row re-execution
  /// binds the named cells.
  private let correlations: Dictionary<Query, Correlation>

  /// The ENCLOSING scope THIS select's OWN columns correlate against — set when
  /// this select is itself a subquery, so a column its relations do not bind
  /// resolves against the outer query and lowers to a `Term.parameter`. `nil`
  /// for a top-level select (no enclosing scope), leaving an unbound column the
  /// ordinary fault.
  private let outer: Outer?

  /// Whether this lowering surface ADMITS a correlated column — TRUE for the
  /// inner `WHERE`/`ON` (a synthetic bound param is a valid lowering there),
  /// FALSE for the projection / `GROUP BY` / `HAVING` (the minimal (b) cut has
  /// no evaluator for an outer column there). A barred surface DIAGNOSES a
  /// correlated column as unsupported rather than mis-resolving it.
  private let admits: Bool

  /// Whether the surface admits a correlated column EVERYWHERE — in the barred
  /// clause positions (the projection / `GROUP BY` / `HAVING`) as well as the
  /// `WHERE`/`ON` — set ONLY when lowering a LATERAL derived table's body. Per
  /// ISO 9075 a `LATERAL` body's preceding-FROM references are in scope
  /// throughout its query expression, INCLUDING the select list, so a lateral
  /// body correlates everywhere while an ordinary subquery's projection stays
  /// barred. When `true`, `barred` is a NO-OP — it keeps `admits`, so a
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

  /// This seam with correlation BARRED — the surface a projection / `GROUP BY`
  /// / `HAVING` lowers under, where an outer column is out of the minimal (b)
  /// cut. It keeps the widths/types/correlations (nested subqueries there still
  /// lower and carry their OWN inner correlation) but rejects a correlated
  /// column of THIS query as unsupported.
  ///
  /// A LATERAL body's surface (`everywhere`) is the exception: ISO puts the
  /// preceding-FROM references in scope throughout the body INCLUDING the
  /// select list, so `barred` is a NO-OP there — the projection keeps admitting
  /// a correlated column, which lowers to a `Term.parameter` the apply binds
  /// per outer row.
  internal var barred: Resolution {
    if everywhere { return self }
    return Resolution(scope, widths, types, correlations, outer: outer,
                      admits: false, everywhere: everywhere)
  }

  /// The synthetic bound-parameter name a CORRELATED reference to `column`
  /// lowers to, or `nil` when no enclosing scope binds it (the ordinary
  /// unknown-column fault stands). A `.column` lowering consults this ONLY
  /// after its own relations fail to bind the name.
  ///
  /// On a barred surface (a projection / `GROUP BY` / `HAVING`) an outer column
  /// IS out of the minimal (b) cut, so a name the enclosing scope binds is
  /// DIAGNOSED `SQLError.unsupported` rather than mis-resolved — the same fault
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
  /// to a SCHEMA derive — its `type` AND `unconstrained` mask TOGETHER — or
  /// `nil` when no enclosing scope binds it. Every type/mask reader is a THIN
  /// accessor over this ONE resolver, so a correlated column's type and mask
  /// cannot diverge (the fix for a correlated all-NULL column losing its mask
  /// through the LATERAL surface).
  ///
  /// A BARRED surface (a projection / `GROUP BY` / `HAVING` of an ORDINARY
  /// subquery) still DIAGNOSES a bound name `SQLError.unsupported` — the SAME
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
  /// discovered by the pre-pass, or the empty map for an UNCORRELATED one.
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
  /// SCHEMA derive — its single-column arity enforced first (else
  /// `SQLError.arity`, matching the lowering), so this schema surface and the
  /// run's lowering AGREE on both the arity fault and the type. This is the
  /// bare-`ValueType` path the run's `Term.subquery` lowering reads; the outer
  /// set-operation fold reads the whole column through `scalar(resolved:)`.
  internal func scalar(type query: Query) throws(SQLError) -> ValueType {
    let width = try width(query)
    guard width == 1 else { throw .arity(1, width) }
    return try output(query).type
  }

  /// The single-column resolved COLUMN a scalar subquery `query` contributes to
  /// a SCHEMA derive — its type AND `unconstrained` mask together, the arity
  /// guard first (else `SQLError.arity`, exactly as `scalar(type:)`). A bare
  /// scalar-subquery PROJECTION reads this so a constant-NULL body's mask
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
  /// — requiring `query` project EXACTLY ONE column (else `SQLError.arity`,
  /// checked from the COMPILED width, so a two-column subquery faults here
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
  /// `Term` — requiring `query` project EXACTLY ONE column (else
  /// `SQLError.arity`, from the COMPILED width, so a two-column subquery faults
  /// here WITHOUT running), then carrying the query into the `Filter` under the
  /// SAME `.valued` role `within` uses — the full column is materialised and
  /// folded per outer row — with the discovered `correlation` threaded exactly
  /// as `within` threads it, so a CORRELATED quantified re-runs its inner plan
  /// per outer row (an UNCORRELATED one carries an empty correlation and
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
    return try .subquery(Subkey(scope, query, .scalar),
                         correlation: correlation(of: query),
                         type: output(query).type)
  }
}

/// The PER-SITE lowering seams a select's pre-pass discovers — ONE `Resolution`
/// per join `ON` (resolved against that join's PREFIX scope) and one for the
/// REST (the WHERE, `HAVING`, projection, and `ORDER BY`, resolved against the
/// full join scope).
///
/// The same inner SQL in both an `ON` and the WHERE is resolved TWICE, each
/// against its OWN site's scope, so a name the `ON`'s narrow prefix binds
/// UNAMBIGUOUSLY yet the WHERE's full scope binds in MORE than one relation is
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

/// The RUN-time cache that runs each UNCORRELATED subquery ONCE, LAZILY on the
/// first reach of its lowered node, and memoises the result — the seam that
/// gives the row evaluator a subquery result WITHOUT itself holding the
/// borrowing catalog stored.
///
/// The evaluator (a `Catalog` method, the catalog IN scope) runs a subquery
/// itself: it reads this cache first and, on a miss, runs the inner plan and
/// `store`s the result. An UNCORRELATED occurrence names no enclosing column,
/// so its result is the SAME for every outer row and is memoised under its
/// occurrence `Subkey`; a later reach returns it WITHOUT re-running. A
/// CORRELATED occurrence's result depends on the bound outer row, so it
/// BYPASSES this cache entirely — the evaluator re-runs its inner plan per
/// outer row against a `bindings` extended with the correlated cells (this
/// slice does NOT memoise across distinct binding tuples — a flagged future
/// optimisation). Every role (scalar / `IN` / `EXISTS`) is lazy, so a subquery
/// an unreachable `CASE` arm or a short-circuited `AND`/`OR` never reaches
/// never runs.
internal struct Subqueries {
  /// The shared memo of the UNCORRELATED occurrences materialised LAZILY on
  /// first reach — a reference so every by-value copy of this cache down the
  /// evaluate tree shares the one box, keeping each materialise-once.
  private let memo: SubqueryMemo

  internal init(_ memo: SubqueryMemo = SubqueryMemo()) {
    self.memo = memo
  }

  /// The memoised `EXISTS` non-empty result for the UNCORRELATED occurrence
  /// `key`, or `nil` when it has not yet run — the evaluator probes on a miss
  /// and `store`s it.
  internal func present(cached key: Subkey) -> Bool? {
    memo.present(key)
  }

  /// Records the `EXISTS` non-empty result of the UNCORRELATED occurrence
  /// `key`.
  internal func store(present value: Bool, for key: Subkey) {
    memo.store(present: value, for: key)
  }

  /// The memoised `IN (Q)` single column for the UNCORRELATED occurrence `key`,
  /// or `nil` when it has not yet run — the evaluator materialises on a miss
  /// and `store`s it.
  internal func values(cached key: Subkey) -> Array<Value>? {
    memo.values(key)
  }

  /// Records the `IN (Q)` single-column value set of the UNCORRELATED
  /// occurrence `key`.
  internal func store(values: Array<Value>, for key: Subkey) {
    memo.store(values: values, for: key)
  }

  /// The already-collapsed value memoised for the scalar UNCORRELATED
  /// occurrence `key`, or `nil` when it has not yet been evaluated.
  internal func scalar(cached key: Subkey) -> Value? {
    memo.scalar(key)
  }

  /// Records `value` as the collapsed value of the scalar UNCORRELATED
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
  /// ITS overlay even when a pushdown moved its predicate to another site.
  internal func record(overlay: ScopedRelations, for scope: Subscope) {
    memo.record(overlay: overlay, for: scope)
  }

  /// The pre-compiled inner plan of the CORRELATED occurrence `key` under
  /// `correlation` — compiled once with its enclosing scope so its correlated
  /// columns are `Term.parameter` — or `nil` for an UNCORRELATED one (which
  /// recompiles fresh per run). Keyed by the occurrence's `PlanKey` (its
  /// `Subkey` plus the correlation's parameter names), so two occurrences of
  /// the SAME inner SQL under DIFFERENT outer layouts — two set-operation arms
  /// whose correlated column sits at different ordinals — each find their OWN
  /// plan.
  internal func plan(_ key: Subkey, _ correlation: Correlation) -> Plan? {
    memo.plan(PlanKey(key, correlation))
  }

  /// Stashes `plan` as the pre-compiled inner plan of the CORRELATED occurrence
  /// `key` under `correlation`, for the evaluator to re-execute per outer row.
  internal func record(plan: Plan, for key: Subkey,
                       _ correlation: Correlation) {
    memo.record(plan: plan, for: PlanKey(key, correlation))
  }

  /// Whether the reached correlated set-operation fold of occurrence `key` has
  /// already been strictly re-validated — so a per-row execution folds ONCE and
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

/// One subquery OCCURRENCE the type-check walk reached — its inner `query`
/// and the `role` it materialises in AT THAT occurrence.
///
/// The role is recorded PER OCCURRENCE (not derived from the union of every
/// role the query occupies in the select) so the deferred type-check picks the
/// occurrence's OWN run shape: an `existential` reach validates the EXISTS
/// PROBE (no projection), a `scalar`/`valued` reach the original. So the SAME
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

/// The mutable set of subquery OCCURRENCES the type-check walk REACHED, shared
/// by a `SubqueryCheck` by REFERENCE.
///
/// A subquery's inner-query OPERAND validation is DEFERRED to the reachability
/// walk (`Scope.validate`), mirroring the lazy executor: an occurrence in an
/// unreachable `CASE`/`COALESCE` arm or a short-circuited `AND`/`OR` leg never
/// validates, exactly as it never runs. The walk cannot itself hold the
/// borrowing catalog a recursive type-check needs, so as it REACHES each
/// occurrence it records the inner query AND its role here; the catalog-bearing
/// `typecheck` phase reads this set AFTER the walk and type-checks only the
/// reached occurrences, each in its OWN role's shape. The box is a class so the
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

  /// Each nested `Query` mapped to its single-column output COLUMN, derived by
  /// the `typecheck` pre-pass — the type AND `unconstrained` mask a scalar
  /// subquery reports to the result schema (`validate`/`derive`), matching the
  /// lowering's `Resolution`. The mask lets a bare scalar-subquery projection
  /// over a constant-NULL body stay unconstrained in an outer set-operation
  /// fold.
  private let types: Dictionary<Query, ValueType>

  /// The scalar inner queries whose OPERAND validation is DEFERRED through the
  /// `.subquery` case of the walk — a scalar-ONLY occurrence, recorded reached
  /// by `type`. An `IN`/`EXISTS`/quantified occurrence defers through
  /// `validate` instead (its arity/type derivation stays total), so the two
  /// record paths stay distinct.
  private let deferred: Set<Query>

  /// The shared box the walk records each reached scalar occurrence into, read
  /// by the catalog-bearing `typecheck` phase after the walk to validate the
  /// reached inner queries.
  private let reached: ReachedScalars

  /// The ENCLOSING scope this select's OWN columns correlate against — the
  /// validation-side analog of `Resolution.outer`, so a correlated column
  /// resolves against the outer query exactly as the run's lowering does,
  /// keeping typecheck↔run parity. `nil` for a top-level select.
  private let outer: Outer?

  /// Whether this surface ADMITS a correlated column — the inner `WHERE`/`ON`
  /// (TRUE) versus a projection / `GROUP BY` / `HAVING` (FALSE, diagnosed) —
  /// the analog of `Resolution.admits`, so validation faults the unsupported
  /// correlated-projection case exactly where the run does.
  private let admits: Bool

  /// Whether the surface admits a correlated column EVERYWHERE — a LATERAL
  /// body's validation surface, the analog of `Resolution.everywhere` — so
  /// `barred` is a NO-OP and the projection/`HAVING` walk of a lateral body
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

  /// This checker with correlation BARRED — the surface a projection / `GROUP
  /// BY` / `HAVING` type-checks under, where an outer column is out of the (b)
  /// cut and is diagnosed rather than resolved. Mirrors `Resolution.barred` —
  /// including the LATERAL-body exception (`everywhere`), where it is a NO-OP
  /// so the projection/`HAVING` walk keeps admitting the correlated preceding
  /// column the run's lowering binds.
  internal var barred: SubqueryCheck {
    if everywhere { return self }
    return SubqueryCheck(widths, types, deferred: deferred, reached: reached,
                         outer: outer, admits: false, everywhere: everywhere)
  }

  /// This checker over a FRESH `reached` box, carrying `outer` — the surface a
  /// join `ON` type-checks under. The `ON` shares this select's width/type
  /// derivation and its enclosing `outer` (a correlated `ON` column resolves
  /// against the containing query as the WHERE's does), but the caller runs its
  /// reachability walk against the join's PREFIX scope (its LOCAL relations),
  /// so a reference to a later-joined relation faults per the prefix. The fresh
  /// box keeps its reached occurrences separate for the caller to validate
  /// against that prefix.
  internal func scoped(_ outer: Outer?) -> SubqueryCheck {
    SubqueryCheck(widths, types, deferred: deferred,
                  reached: ReachedScalars(), outer: outer)
  }

  /// The outer type `column` correlates to, or `nil` when no enclosing scope
  /// binds it — the validation-side `Resolution.correlate`: it resolves against
  /// `outer`, faulting `.unsupported` on a BARRED surface (a projection /
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
  /// reached a catalog-less surface and is rejected — and RECORDS it reached in
  /// `role`, so the `typecheck` phase validates its OPERANDS after the walk in
  /// that role's shape. This is the WALK-reach point for an
  /// `IN`/`EXISTS`/quantified occurrence: `check` calls it only when the
  /// reachability walk arrives at the `.within`/`.exists`/`.quantified` node,
  /// so an occurrence in a skipped `CASE`/`COALESCE` arm or a short-circuited
  /// `AND`/`OR` leg is never recorded — its body is not type-checked, exactly
  /// as the lazy executor never materialises it. A REACHED one is validated in
  /// its OWN role's shape (an `EXISTS` reach → the probe), so a reached bad
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
  /// `SQLError.arity`, matching the run's lowering). This is the WALK-reached
  /// path, so a scalar occurrence whose operand validation was deferred is
  /// recorded REACHED here, for the `typecheck` phase to validate its inner
  /// query. The cursor-free arity/type derivation stays SEPARATE and total: the
  /// arity of an unreachable scalar was already enforced eagerly in the
  /// pre-pass (`subqueryCheck`), so a two-column subquery in a skipped arm
  /// still faults.
  internal func type(_ query: Query) throws(SQLError) -> ValueType {
    // A DEFERRED scalar occurrence is REACHED here in the `scalar` role: record
    // it for the `typecheck` phase to validate its inner query's OPERANDS,
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
  /// with the ROLE it reached in. The `typecheck` phase validates only these
  /// after the walk, mirroring the lazy executor's evaluation of only a reached
  /// subquery, picking each one's RUN shape from ITS OWN reached role (an
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
private func lower(_ predicate: Predicate,
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
  case let .rows(lhs, op, rhs):
    // `(l…) <op> (r…)` lowers to a first-class `Filter.comparison` — the two
    // rows of EQUAL arity (`SQLError.arity` otherwise), each component lowered
    // ONCE through `term`. The runtime evaluates every component exactly once
    // per row and folds the values with the SAME `matches`/Kleene primitives a
    // scalar comparison uses (a componentwise Kleene `AND` for `=`, its
    // negation for `<>`, the lexicographic cascade for the ordering operators),
    // so a stateful component is read once and the ISO three-valued truth is
    // preserved. A desugar to a conjunction/cascade of scalar comparisons
    // duplicated a component across its places, re-evaluating it.
    try rows(lhs, op, rhs, term: term)
  case let .among(lhs, rows, negated):
    // `(l…) [NOT] IN ((r…), …)` lowers to a first-class `Filter.memberships` —
    // the left row and a non-empty list of element rows, all of EQUAL arity
    // (`SQLError.arity` otherwise, an empty list rejected), each component
    // lowered ONCE through `term`. The runtime evaluates the left row once per
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
    // evaluates the test `x` ONCE per row (an `AND`/`OR` of two comparisons
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
    // evaluates TWO-VALUED, treating NULL as a comparable value. No
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
/// The two rows must be of EQUAL arity (`SQLError.arity` otherwise) — a
/// row-value comparison of unequal rows is undefined. Each component is lowered
/// ONCE rather than duplicated into a desugared conjunction/cascade of scalar
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
/// The element list must be non-empty and every element row of the SAME arity
/// as the left row (`SQLError.arity` otherwise) — as with the scalar value-list
/// `IN`, the parser rejects `IN ()`, but `Predicate.among` is public, so a
/// caller can bypass the grammar and this lowering rejects it. The left row's
/// components are lowered ONCE and held rather than copied into an OR-chain of
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

  /// The ordinal `column` resolves to in `relation`, or `nil` when it is a
  /// candidate CORRELATED reference to an enclosing scope — this relation does
  /// not name it — the not-found probe the single-relation `.column` lowering
  /// consults before correlating outward.
  ///
  /// The two not-found situations `ordinal(of:in:)` conflates as `.column` are
  /// DISTINGUISHED here. A qualifier this relation does NOT answer (its alias,
  /// else its name), or an unqualified name it does not carry, is a genuine
  /// not-found → `nil`, so the walk correlates to the outer query. But a
  /// qualifier this relation DOES answer, naming a column it LACKS, is a hard
  /// `SQLError.column` that PROPAGATES: the local alias SHADOWS a same-named
  /// outer relation, so the miss faults against the inner relation rather than
  /// falling through to bind the outer one. This is the single-relation analog
  /// of `Scope.find`.
  internal func find(_ column: Column, in relation: Relation)
      throws(SQLError) -> Int? {
    if let qualifier = column.qualifier,
        (relation.alias ?? relation.name) != qualifier {
      return nil
    }
    guard let ordinal = ordinal(of: column.name) else {
      guard column.qualifier == nil else { throw .column(column.name) }
      return nil
    }
    return ordinal
  }

  /// The projected terms of `projection`, addressed by ordinal: a `*` or a
  /// bare-column list yields one `.slot(ordinal)` per column; an expression
  /// list lowers each expression to a term. The terms hold ordinals, which the
  /// engine remaps to slots after gathering the referenced ones.
  internal func terms(_ projection: Projection, in relation: Relation,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<Term> {
    // A projection is a BARRED clause position: a correlated column of THIS
    // query has no evaluator here (only WHERE/ON/HAVING admit one). The cut is
    // intrinsic to the entry, so a caller CANNOT pass an admitting seam into a
    // projection — the FROM-less scalar path included — keeping the run's
    // lowering and the schema `columns(of:)` derive in lockstep.
    let subquery = subquery.barred
    switch projection {
    case .all:
      return (0 ..< width).map { .slot($0) }
    case let .columns(columns):
      // Lower each bare column through `term`, so a name this relation does not
      // bind consults the `subquery` surface: a correlated reference on the
      // BARRED projection surface is diagnosed unsupported (parity with the
      // schema path) rather than faulting `SQLError.column`.
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(term(.column(column), in: relation, routines,
                              subquery: subquery))
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
                     subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      // Resolve against this relation first; a name it does not bind is a
      // candidate CORRELATED reference to the enclosing scope, lowered to a
      // synthetic `Term.parameter` when the outer scope binds it, else the
      // ordinary unknown-column fault. A QUALIFIED miss on THIS relation (its
      // alias names it, but the column is absent) is a HARD `.column` `find`
      // propagates — never a fall-through to correlate a same-qualifier outer
      // relation, which the local alias SHADOWS.
      if let ordinal = try find(column, in: relation) { return .slot(ordinal) }
      if let name = try subquery.correlate(column) { return .parameter(name) }
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
      throw .state("42803", "an aggregate is not allowed here")
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
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // An ORDER BY is BARRED, as the projection is: a correlated column of THIS
    // query is out of the cut here, so the entry bars the seam by construction.
    let subquery = subquery.barred
    return try SQLEngine.order(order, projection, names) {
      expression throws(SQLError) in
      try term(expression, in: relation, routines, subquery: subquery)
    }
  }

  internal func lower(_ predicate: Predicate, in relation: Relation,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
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
/// `extent` — its real `width` plus the virtual columns it exposes — rather
/// than its `width` keeps a relation's virtual columns (an `Id`, an owner
/// foreign key) on its own side rather than colliding with the next relation's
/// space. A `Scope` resolves a possibly qualified `SQLEngine.Column` into that
/// combined space so the engine's `Filter`, projection, and order all address
/// cells uniformly across the chain. A qualifier names a relation by its alias,
/// else its table name; an unqualified name resolves against every relation and
/// is ambiguous if more than one resolves it — as is a qualified name two
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

  /// A `NATURAL`/`USING` MERGED column (ISO 9075 7.10) — the ONE common column
  /// a named-column join exposes, belonging to NEITHER side. It has NO physical
  /// slot of its own: its `value` is the `COALESCE(left, right)` over the two
  /// PHYSICAL combined ordinals it merges (each still addressable QUALIFIED),
  /// and its `type` the unified coalesce type. A bare (unqualified) reference
  /// to its `name` resolves to `value` — the merged entry SHADOWS its physical
  /// constituents for bare lookup — while a qualified `A.c`/`B.c` never matches
  /// it and reaches its own slot.
  internal struct Merged: Sendable {
    let name: String
    let value: Term
    let type: ValueType
    /// The two PHYSICAL combined ordinals this merged column coalesces — the
    /// left constituent and the right one — kept so a `SELECT *` drops them
    /// (each is exposed ONCE, via the merged `value`, not twice as itself).
    let constituents: Array<Int>
    /// Whether the merged column places NO type constraint — TRUE only when
    /// BOTH constituents were unconstrained (each an all-NULL/placeholder
    /// column), so a `USING` merge of two constant-NULL sides stays a
    /// placeholder that a further enclosing set-operation fold unifies with any
    /// typed arm; FALSE when EITHER side constrained the merged type. The
    /// `unconstrained` bit the set-operation `merge(_:_:)` computes, carried so
    /// a downstream `output(of:)`/correlated read reports it rather than
    /// hard-coding the merged column constrained.
    let unconstrained: Bool

    /// This merged column as an output `ResolvedColumn` — its `type` AND its
    /// `unconstrained` mask carried TOGETHER, named `name` (the reference's
    /// spelling for a bare `output(of:)`, else the merged column's own `name`
    /// for a `SELECT *`). The SINGLE construction both the `SELECT *`
    /// (`outputs`) and the explicit bare `output(of:)` merged-output paths
    /// route through, so neither can drop the mask the other carries.
    internal func resolved(named name: String) -> ResolvedColumn {
      ResolvedColumn(OutputColumn(name: name, type: type),
                     unconstrained: unconstrained)
    }
  }

  private let members: Array<Member>

  /// The `NATURAL`/`USING` merged columns of the join chain, in ISO 7.10 order
  /// — a bare reference to one resolves to its coalesce `value`, and a
  /// `SELECT *` prepends them ahead of the members' remaining physical columns.
  /// Empty for a chain with no named-column join, so an ordinary scope is
  /// unchanged.
  private let merged: Array<Merged>

  /// The physical combined ordinals a merged column subsumes — the union of
  /// every `Merged.constituents` — so a `SELECT *` skips them (each is exposed
  /// ONCE via its merged `value`).
  private let subsumed: Set<Int>

  /// Builds a scope over `relations` — the `FROM` relation first, then each
  /// joined relation in source order — laying each past the previous one's
  /// `extent`, carrying the `NATURAL`/`USING` `merged` columns (empty for a
  /// chain with none).
  internal init(_ relations: Array<(Relation, Schema)>,
                merged: Array<Merged> = []) {
    var members = Array<Member>()
    members.reserveCapacity(relations.count)
    var offset = 0
    for (relation, schema) in relations {
      members.append(Member(relation: relation, schema: schema, offset: offset))
      offset += schema.extent
    }
    self.members = members
    self.merged = merged
    self.subsumed = Set(merged.flatMap(\.constituents))
  }

  /// The merged column named `name` (case-insensitively), or `nil` when none —
  /// the entry a bare reference SHADOWS its two physical constituents with.
  private func merged(_ name: String) -> Merged? {
    let folded = name.lowercased()
    return merged.first { $0.name.lowercased() == folded }
  }

  /// The `NATURAL`/`USING` merged column a BARE `name` resolves to (ISO 9075
  /// 7.10), or `nil` when none is merged under that name — the binding
  /// `term`/`derive`/`output(of:)` shadow the two physical sides with.
  ///
  /// The merged column shadows its OWN constituents, but an addressable column
  /// of the same name a LATER PLAIN join contributed (`… USING (k) JOIN C …`, C
  /// carrying its own `k`) is NOT a constituent — a bare `k` now names both
  /// the merged column and that other one, so it faults `SQLError.ambiguous`
  /// rather than silently taking the merged value. A qualified `A.k`/`C.k`
  /// never reaches here and stays unambiguous.
  ///
  /// The conflict scan is the FULL addressable surface (`addressable` —
  /// physical AND virtual, the same surface `ordinal(of:)` resolves against),
  /// EXCLUDING the merged column's own physical constituents. So a merged `Id`
  /// (a virtual join column) coexisting with a later plain join's own VIRTUAL
  /// `Id` faults `.ambiguous` just as a real conflict does — the two axes stay
  /// consistent because neither the merged bare lookup nor the ordinary one
  /// scans a partial surface.
  internal func merged(binding name: String) throws(SQLError) -> Merged? {
    guard let merged = merged(name) else { return nil }
    for ordinal in addressable(Column(name: name))
        where !subsumed.contains(ordinal) {
      throw .ambiguous(name)
    }
    return merged
  }

  /// Whether the real column at `member`'s local `ordinal` is a PHYSICAL
  /// constituent a merged column subsumes — one a `SELECT *` drops, since the
  /// merged `value` already exposes it ONCE.
  private func subsumed(_ member: Member, _ ordinal: Int) -> Bool {
    subsumed.contains(member.offset + ordinal)
  }

  /// The `NATURAL`/`USING` merged columns, in ISO 7.10 order — the surface the
  /// schema-path `SELECT *`/bare-column resolution (`outputs`/`output(of:)`)
  /// reads to name and type a merged output column, matching the run's `terms`.
  internal var merges: Array<Merged> { merged }

  /// The merged column named `name` (case-insensitively), or `nil` when none —
  /// the probe `Grouping` uses to route a bare merged key to term-matching
  /// rather than the ordinal `keys` map its `find` cannot fill.
  internal func merges(_ name: String) -> Merged? { merged(name) }

  /// Whether the real column at combined `ordinal` is a PHYSICAL constituent a
  /// merged column subsumes — the schema-path `SELECT *` (`outputs`) drops it.
  internal func subsumes(_ ordinal: Int) -> Bool { subsumed.contains(ordinal) }

  /// The combined ordinals of the REAL columns a `SELECT *` emits AFTER the
  /// merged block — every relation's real column at its combined ordinal, in
  /// chain order, skipping a physical constituent a merged column subsumes
  /// (each exposed ONCE via its merged `value`). Never a virtual ordinal.
  ///
  /// This is the ONE walk the `SELECT *` surfaces share, so its length and its
  /// membership cannot drift between them: `terms(.all)` maps each to a
  /// `.slot`, `outputs`/`names` read each column's name and type, and
  /// `width(of: .all)` is `merged.count` plus this count — the width DERIVED
  /// from the same enumeration that emits the columns, not a parallel formula.
  internal var expansion: Array<Int> {
    var ordinals = Array<Int>()
    for member in members {
      for ordinal in 0 ..< member.schema.width
          where !subsumed(member, ordinal) {
        ordinals.append(member.offset + ordinal)
      }
    }
    return ordinals
  }

  /// The visible (unqualified) column NAMES this scope resolves, in chain order
  /// — the `NATURAL`/`USING` merged columns first, then each member's real
  /// column names skipping a physical constituent a merged column subsumes.
  /// This is the LEFT side's output-name list a `NATURAL` join intersects with
  /// the joined-in relation to find its common columns. It reads the ONE
  /// `expansion` enumeration the `SELECT *` surfaces share, resolving each
  /// combined ordinal back to its owning relation's spelling (`name(at:)`).
  internal var names: Array<String> {
    merged.map(\.name) + expansion.map { name(at: $0) }
  }

  /// The (unqualified) name of the real column at combined `ordinal` — the
  /// reverse of the chain layout, resolving `ordinal` to its owning relation
  /// and that relation's spelling. A combined `ordinal` from `expansion` always
  /// names a real column (`local < width`); the fallback empty string never
  /// arises for an `expansion` ordinal. Shared by `names` and the schema-path
  /// `SELECT *` (`outputs`), so both name the columns `expansion` emits.
  internal func name(at ordinal: Int) -> String {
    for member in members {
      let local = ordinal - member.offset
      if local >= 0, local < member.schema.width {
        return member.schema.names[local]
      }
    }
    return ""
  }

  /// The LEFT-side resolution of a bare join column `name` when building a
  /// `NATURAL`/`USING` merged column: its value `Term`, its `type`, its
  /// `unconstrained` mask, and the PHYSICAL combined ordinals it stands over.
  ///
  /// The `unconstrained` mask is the CONSTITUENT'S — an earlier-merged column's
  /// own accumulated bit, else the physical column's `unconstrained(at:)` — so
  /// the `NATURAL`/`USING` type merge honors an all-NULL/placeholder left the
  /// SAME way the set-operation fold does (a constant-NULL left constrains
  /// nothing, deferring the merged type to the right).
  ///
  /// A name an earlier join already MERGED resolves to that merged column — its
  /// coalesce `value`, unified `type`, and constituent ordinals — so a chained
  /// `… USING (k)` keys on the merged value (a `RIGHT`/`FULL` join's left-NULL
  /// row still joins), THROUGH the FULL ambiguity-aware bare lookup
  /// (`merged(binding:)`): a merged entry that now COEXISTS with a physical
  /// column of the same name a LATER PLAIN join re-introduced (`… USING (k) …
  /// JOIN C ON … JOIN … USING (k)`, C carrying its own `k`) is AMBIGUOUS, so
  /// keying a later `USING` on it faults `SQLError.ambiguous` here rather than
  /// silently taking the merged value and leaving two output columns named `k`.
  /// A name NOT yet merged must resolve to EXACTLY ONE left physical column
  /// (`ordinal(of:)`); an accumulated-left name bound TWICE (a plain `ON` join
  /// left two columns of that name) faults `SQLError.ambiguous` here, the
  /// finding-1 trap now a first-class fault at construction rather than a
  /// downstream crash.
  internal func left(_ name: String) throws(SQLError)
      -> (value: Term, type: ValueType, unconstrained: Bool,
          constituents: Array<Int>) {
    if let merged = try merged(binding: name) {
      return (merged.value, merged.type, merged.unconstrained,
              merged.constituents)
    }
    let ordinal = try ordinal(of: Column(name: name))
    return (.slot(ordinal), type(at: ordinal), unconstrained(at: ordinal),
            [ordinal])
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
  /// 1-based `ORDER BY` ordinal must fall in. A `*` counts the merged columns
  /// plus the real columns the shared `expansion` enumeration emits (never a
  /// virtual column); a bare-column or an expression list is its item count.
  internal func width(of projection: Projection) -> Int {
    switch projection {
    case .all:
      // DERIVED from the ONE `expansion` walk `terms(.all)`/`outputs` emit —
      // the merged columns plus the real columns it yields — so the width
      // cannot drift from the emitted count. A parallel `schemas.reduce(width)
      // − subsumed.count` arithmetic UNDERCOUNTED when a merged column's
      // constituent was VIRTUAL (a fixture/adapter `Id`): the virtual ordinal
      // is in `subsumed` but was never in the real-width sum, so subtracting it
      // dropped a real column that IS emitted.
      return merged.count + expansion.count
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

  /// Whether the real column at combined `ordinal` is UNCONSTRAINED — an
  /// all-arms-NULL CTE column that places no type constraint, so a bare
  /// reference to it in a set-operation arm unifies with any typed arm order-
  /// independently (`RelationInstance.unconstrained`). A virtual ordinal
  /// (`Id`, a foreign key) or an out-of-range one carries a genuine type and is
  /// constrained, so it reports `false` — mirroring `type(at:)`'s dispatch.
  internal func unconstrained(at ordinal: Int) -> Bool {
    for member in members {
      let local = ordinal - member.offset
      guard local >= 0, local < member.schema.extent else { continue }
      return local < member.schema.width
          && member.schema.unconstrained[local]
    }
    return false
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
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    return switch expression {
    case let .column(column):
      // A BARE name matching a `NATURAL`/`USING` merged column types from the
      // unified coalesce `type` — the merged column has NO physical ordinal, so
      // it is typed here rather than via `type(at:)` (a same-named physical
      // column a later plain join added faults `.ambiguous`).
      if column.qualifier == nil,
          let merged = try merged(binding: column.name) {
        merged.type
      } else if let ordinal = try find(column) {
        // A column this scope does not bind may be a CORRELATED reference to an
        // enclosing query (in an inner `WHERE`); type it as the outer column,
        // else the ordinary column fault. A LOCALLY AMBIGUOUS name is a HARD
        // error `find` propagates, never a fall-through to outer correlation.
        type(at: ordinal)
      } else if let resolved = try subquery.correlated(column) {
        resolved.type
      } else {
        try type(at: ordinal(of: column))
      }
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
      // The result type is the unification of every REACHABLE branch result
      // (and the `ELSE`) — the executor's short-circuit means an unreachable
      // branch (a constant-false guard, or any branch after a constant-true
      // one) never yields a value, so it cannot shape the column's type. The
      // reachable result types must UNIFY; a definitively-irreconcilable clash
      // (text beside an integer) faults `SQLError.operand` here too, so this
      // lowering surface and the faulting `validate` AGREE. A `CASE` always has
      // at least one `WHEN`; when none is reachable (every guard
      // constant-false, no reachable `ELSE`) the run yields NULL, for which
      // `.integer` is the schema default.
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
                      subquery: Resolution = .unsupported)
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
                             subquery: Resolution = .unsupported)
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
                      subquery: Resolution = .unsupported)
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
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try derive(argument, routines, subquery: subquery)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is derived (for its errors) but skipped: it can never
        // be returned, so its type must not shape the column.
        continue
      }
      if selects(argument, routines) {
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
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    let results = reachable(whens, otherwise, routines)
    if results.isEmpty { return .integer }
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
      // A BARE name matching a `NATURAL`/`USING` merged column (ISO 9075 7.10)
      // types from the unified coalesce `type` — the SAME merged-aware bare
      // lookup `term`/`derive` shadow the two physical sides with, so the
      // type-check accepts exactly the bare merged reference the run lowers (a
      // same-named physical column a later plain join added faults `.ambiguous`
      // in `merged(binding:)`). A column this scope does not bind may be a
      // CORRELATED reference to an enclosing query (validated as the run
      // resolves it — a `WHERE` one types as its outer column, a
      // projection/`HAVING` one faults unsupported); else the ordinary column
      // fault. A LOCALLY AMBIGUOUS name is a HARD error `find` propagates — not
      // a fall-through to outer correlation.
      if column.qualifier == nil,
          let merged = try merged(binding: column.name) {
        merged.type
      } else if let ordinal = try find(column) {
        type(at: ordinal)
      } else if let type = try subquery.correlated(column) {
        type
      } else {
        try type(at: ordinal(of: column))
      }
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
      if selects(argument, routines) {
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
  /// `WHEN` guard is a boolean predicate whose operands are validated
  /// (`check`); only a REACHABLE result expression is validated; and the
  /// reachable result types must UNIFY to one type (`ValueType.unified`) — a
  /// definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, as a query cannot yield a column of two kinds.
  /// A mixed integer/double `CASE` widens to `double`.
  ///
  /// The executor takes the first TRUE guard's result and never evaluates a
  /// later branch, so a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result — its operands are NOT validated (`CASE WHEN 1 = 0 THEN
  /// Name + 1 ELSE 0 END` type-checks). A constant-TRUE guard is itself
  /// reachable and KEEPS every earlier reachable branch — a row an earlier
  /// row-dependent guard matches takes that branch, never reaching the
  /// constant-TRUE one — so those earlier results are still validated (`CASE
  /// WHEN Id = 1 THEN Name + 1 WHEN 1 = 1 THEN 0 END` faults on the reachable
  /// `Id = 1` branch's `Name + 1`); it makes only every STRICTLY-LATER guard,
  /// result, and the `ELSE` unreachable. A REACHABLE bad operand (`WHEN Id = 1
  /// THEN Name + 1`) still faults. When no branch is reachable the run yields
  /// NULL, typed `.integer` (the schema default), with no result to validate.
  private func conditional(_ whens: Array<When>, _ otherwise: Expression?,
                           _ routines: Routines,
                           subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    var results = Array<Expression>()
    var decided = false
    for branch in whens {
      // The guard up to (and including) the decisive one is evaluated, so
      // validate its operands; a constant-FALSE guard's result is unreachable
      // (skip it), a constant-TRUE one is reachable but makes every LATER
      // branch unreachable — so keep the earlier results and this one, then
      // stop.
      try check(branch.when, routines, subquery: subquery)
      switch constant(branch.when, routines) {
      case false: continue
      case true: results.append(branch.then); decided = true
      case nil: results.append(branch.then)
      }
      if decided { break }
    }
    if !decided, let otherwise { results.append(otherwise) }
    if results.isEmpty { return .integer }
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
      if filter.aggregated {
        throw .state("42803", "an aggregate is not allowed in a FILTER")
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
      // Reached in the `existential` role, so the deferred phase validates its
      // cardinality PROBE (no select list), never the original projection.
      try subquery.validate(query, as: .existential)
    case let .within(operand, query, _):
      // Validate the operand AND the inner query, and enforce the single-column
      // arity the lowering does (`SQLError.arity`), so schema validation
      // matches execution — the recurring lesson that the two must not diverge.
      // Reached in the `valued` role — its value set is read, so the deferred
      // phase validates the ORIGINAL query.
      _ = try validate(operand, routines, subquery: subquery)
      try subquery.validate(query, as: .valued)
      let width = try subquery.width(query)
      guard width == 1 else { throw .arity(1, width) }
    case let .quantified(operand, _, _, query):
      // As `within`: validate the operand and the inner query, and enforce the
      // single-column arity the lowering does (`SQLError.arity`), so schema
      // validation matches execution. Reached `valued` (its values are read),
      // so the deferred phase validates the ORIGINAL query.
      _ = try validate(operand, routines, subquery: subquery)
      try subquery.validate(query, as: .valued)
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
      if values.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      _ = try validate(operand, routines, subquery: subquery)
      _ = try membership(of: values, each: { value throws(SQLError) in
        _ = try validate(value, routines, subquery: subquery)
      }, equality: { value throws(SQLError) in
        matched(operand, value, routines)
      })
    case let .rows(lhs, _, rhs):
      // `(l…) <op> (r…)` lowers to a componentwise comparison, so type each
      // component of both rows for real errors (unknown column, bad arity, …),
      // and enforce the EQUAL-arity rule the lowering does (`SQLError.arity`)
      // so schema validation matches execution. A cross-kind component is NOT
      // rejected — the run's `matches` yields FALSE across kinds without
      // faulting, as an `IN` element does — so the schema accepts what the run
      // accepts.
      guard lhs.count == rhs.count else {
        throw .arity(lhs.count, rhs.count)
      }
      for expression in lhs {
        _ = try validate(expression, routines, subquery: subquery)
      }
      for expression in rhs {
        _ = try validate(expression, routines, subquery: subquery)
      }
    case let .among(lhs, rows, _):
      // `(l…) [NOT] IN ((r…), …)` lowers to a disjunction of row equalities, so
      // type the left row and each element row for real errors, and enforce the
      // non-empty list and per-row EQUAL-arity rules the lowering does. A
      // cross-kind component is NOT rejected, as an `IN` element is not.
      //
      // The OR-chain short-circuits exactly as the scalar `.membership` does: a
      // DEFINITE constant match (both the left row and an element row fold to
      // ROW-INDEPENDENT constants whose tuple-equality `relate` yields TRUE)
      // makes the whole `IN` TRUE and leaves every later element unreachable,
      // so validation stops there — `(1, 2) IN ((1, 2), (Name + 1, 3))`
      // type-checks (the constant `(1, 2)` matches the first element before
      // `Name + 1` is reached), while `(1, 2) IN ((3, 4), (Name + 1, 5))` (no
      // definite match) still validates `Name + 1` and faults. A row-dependent
      // side leaves the element undecided (`nil`), so no false short-circuit
      // prunes a reachable element.
      if rows.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      for expression in lhs {
        _ = try validate(expression, routines, subquery: subquery)
      }
      let l = constants(lhs, routines)
      _ = try membership(of: rows, each: { element throws(SQLError) in
        guard element.count == lhs.count else {
          throw .arity(lhs.count, element.count)
        }
        for expression in element {
          _ = try validate(expression, routines, subquery: subquery)
        }
      }, equality: { element throws(SQLError) in
        guard let l, let r = constants(element, routines) else { return nil }
        return relate(l, .equal, r)
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

  /// Whether `expression` folds to a CONSTANT NULL for EVERY row — a projected
  /// column that places NO type constraint on a set-operation's unified column,
  /// so the fold skips its (literal-fix) type exactly as `COALESCE` skips a
  /// constant-NULL argument. The projection walk (`output(_ item:)`) reads this
  /// beside its type derive, so a column's type and its `unconstrained` mask
  /// come from ONE resolution over the SAME expression and cannot diverge.
  internal func null(_ expression: Expression, _ routines: Routines) -> Bool {
    if case .some(.null) = constant(expression, routines) { return true }
    return false
  }

  /// Whether evaluating `expression` would dispatch an INVALID routine call —
  /// the tree contains, at ANY depth, a `.call(name, _)` that is UNREGISTERED
  /// (`routines[name] == nil`) or INVALID for its routine (bad arity or a
  /// definitively-wrong argument type). Such a call has no genuine return type
  /// (`derive` fabricates the declared `returns`, or the `.integer` default for
  /// a missing name), yet the run faults on it (`SQLError.function` for the
  /// missing name, `SQLError.argument` for the bad arity/type), so a projection
  /// over it places NO type constraint on a set-operation's unified column:
  /// mark it UNCONSTRAINED and let the fold defer to the other arm rather than
  /// fault on the fabricated type. This is SOUND either way — if the arm is
  /// REACHED the run dispatches it and faults, and if it is NOT reached (a
  /// zero-row limit, a filtered-out arm) the expression is never evaluated, so
  /// its fabricated type is irrelevant. Only an invalid call trips it, so a
  /// VALID call (correct arity and argument types) stays constrained — its
  /// declared `returns` still shapes the fold — and a genuine type mismatch
  /// still faults `SQLError.operand` (42804).
  ///
  /// It MIRRORS `derive`'s expression arms exactly so no form escapes: a bare
  /// call is the depth-0 case of the `.call` arm, and every composite arm
  /// recurses the same sub-expressions `derive` traverses.
  internal func unresolved(_ expression: Expression,
                           _ routines: Routines) -> Bool {
    switch expression {
    // `.column`/`.literal`: no call, so never unresolved — mirroring
    // `derive`'s leaf arms, which fabricate no routine type.
    case .column, .literal:
      return false
    // `.call`: the depth-0 case (an unregistered name), OR an unregistered
    // call nested in an argument — subsuming the former bare-call special case
    // in `output(_ item:)`. An INVALID call to an EXISTING routine (bad arity
    // or a definitively-wrong argument type) is treated like a MISSING one:
    // `derive` fabricates the declared `returns` for it, but the run faults
    // (`SQLError.argument`), so its type must not constrain the fold. This
    // mirrors the strict validator `call(_:over:_:)`'s arity/type guards as a
    // NON-throwing probe.
    case let .call(name, arguments):
      guard let routine = routines[name] else { return true }
      guard (routine.minimum ... routine.parameters.count)
          .contains(arguments.count) else { return true }
      if arguments.contains(where: { unresolved($0, routines) }) { return true }
      for (argument, expected) in zip(arguments, routine.parameters) {
        guard let type = try? derive(argument, routines) else { return true }
        if type != expected { return true }
      }
      return false
    // `.binary` (arithmetic AND `||`): both derive arms derive both operands.
    case let .binary(_, lhs, rhs):
      return unresolved(lhs, routines) || unresolved(rhs, routines)
    // `.aggregate`: `derive` recurses only the operand (a `.star` counts
    // rows, deriving nothing); the `filter` is a `Predicate`, not shaping the
    // derived type.
    case let .aggregate(_, operand, _, _):
      switch operand {
      case .star: return false
      case let .expression(argument): return unresolved(argument, routines)
      }
    // `.case`: `derive` unifies only the REACHABLE result expressions
    // (`reachable`), so mirror that reach — an unregistered call in an
    // unreachable branch never runs and never shapes the type.
    case let .case(whens, otherwise):
      return reachable(whens, otherwise, routines)
          .contains { unresolved($0, routines) }
    // `.cast`: `derive` recurses the operand for its resolution.
    case let .cast(operand, _):
      return unresolved(operand, routines)
    // `.coalesce`: `derive` (`unified`) scans only the REACHABLE prefix — it
    // STOPS at the first argument a constant non-NULL value `selects`, so a
    // later argument never runs nor shapes the type. Mirror that reach, else
    // `COALESCE(1, missing())` wrongly defers instead of constraining `1`.
    case let .coalesce(arguments):
      for argument in arguments {
        if unresolved(argument, routines) { return true }
        if selects(argument, routines) { break }
      }
      return false
    // `.nullif`: `derive` (`nullif`) derives both operands.
    case let .nullif(lhs, rhs):
      return unresolved(lhs, routines) || unresolved(rhs, routines)
    // `.subquery`: a nested scalar subquery resolves its OWN columns through
    // the memo (`scalar(resolved:)`), which already carries the unconstrained
    // mask for any unregistered call inside it — do NOT double-handle it here.
    case .subquery:
      return false
    }
  }

  /// The constant `Value`s a ROW `row` folds to when EVERY component is
  /// row-independent — else `nil` (any component a row/group/run decides). A
  /// row comparison and a row `IN` element fold through this so a single row-
  /// dependent component leaves the whole row undecided, matching the runtime's
  /// whole-row evaluation.
  private func constants(_ row: Array<Expression>, _ routines: Routines)
      -> Array<Value>? {
    var values = Array<Value>()
    values.reserveCapacity(row.count)
    for expression in row {
      guard let value = constant(expression, routines) else { return nil }
      values.append(value)
    }
    return values
  }

  /// Folds an `IN` value list as its OR-chain of `operand = element`
  /// equalities, honouring the executor's SHORT-CIRCUIT: the elements are
  /// visited in order, each mapped to its three-valued equality truth by
  /// `equality`, and the truths are OR-folded — but a definite `true` stops the
  /// walk, since the OR-chain matches there and every LATER element is
  /// unreachable (`Row.matches` returns on the first true arm). This is the ONE
  /// short-circuit the `IN` type-check (`check`), constant fold (`constant`),
  /// and empty-group evaluator (`empty`) all share: each supplies the
  /// per-element `equality` its surface computes with, and every surface stops
  /// at the same element the run does.
  ///
  /// `visit` runs on each element BEFORE its truth is taken, so a surface with
  /// a per-element side effect (validation) applies it to exactly the reachable
  /// prefix. The fold seeds FALSE (an empty match is FALSE), so the returned
  /// truth is the disjunction over the visited prefix.
  ///
  /// The element is GENERIC — a scalar value list supplies an `Expression` per
  /// element, a row `IN` a whole `Array<Expression>` row — so the same
  /// short-circuit drives the scalar `.membership` and the row `.among` folds,
  /// the tuple-equality via `relate` standing in for the scalar equality.
  private func membership<Element, E: Error>(
      of elements: Array<Element>,
      each visit: (Element) throws(E) -> Void = { (_: Element) in },
      equality: (Element) throws(E) -> Bool?)
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
    case let .rows(lhs, op, rhs):
      // Fold `(l…) <op> (r…)` exactly as the scalar `.comparison` folds — each
      // component of BOTH rows folds through `constant(_ expression:)`, then
      // the folded values combine through the SHARED `relate` primitive the run
      // (`Filter.comparison`) and the empty-group pre-fold drive, so the fold
      // matches the run. A single row-dependent component (`nil`) leaves the
      // whole comparison per row (`nil`), so both `AND` arms stay reachable; an
      // all-constant pair settles it, so a constant-false row guard prunes its
      // right arm as `1 = 0 AND …` does.
      guard let l = constants(lhs, routines),
          let r = constants(rhs, routines) else {
        return nil
      }
      return relate(l, op, r)
    case let .among(lhs, rows, negated):
      // Fold `(l…) [NOT] IN ((r…), …)` exactly as the scalar `.membership`
      // folds — the left row folds through `constant(_ expression:)`, then the
      // element rows OR-fold under the `membership` short-circuit: an element
      // whose components ALL fold constant contributes its tuple-equality
      // (`relate(l, =, r)`, the same shared primitive), and once one folds
      // definitely TRUE the walk stops, so a later row-dependent element is
      // unreachable and does not spoil it — `(1, 2) IN ((1, 2), (Name + 1, 3))`
      // folds `true`. Absent a decisive match, a row-dependent element makes it
      // per row (`nil`); a row-dependent LEFT row leaves the whole `IN` per
      // row. `NOT IN` negates the folded truth (UNKNOWN maps to itself).
      guard let l = constants(lhs, routines) else { return nil }
      let truth = membership(of: rows) { element in
        guard let r = constants(element, routines) else { return nil }
        return relate(l, .equal, r)
      }
      return negated ? truth.map { !$0 } : truth
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
    case let .rows(lhs, _, rhs):
      // A row comparison is settled when EVERY component of BOTH rows folds to
      // a ROW-INDEPENDENT constant — the row analog of `.comparison`, so a
      // constant-UNKNOWN row comparison (a NULL component) folds a `truth` test
      // definitely rather than deferring it.
      lhs.allSatisfy { constant($0, routines) != nil }
          && rhs.allSatisfy { constant($0, routines) != nil }
    case let .among(lhs, rows, _):
      // A row `IN` is settled when the LEFT row and EVERY element row fold to
      // ROW-INDEPENDENT constants — the row analog of `.membership`.
      lhs.allSatisfy { constant($0, routines) != nil }
          && rows.allSatisfy { element in
            element.allSatisfy { constant($0, routines) != nil }
          }
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
    // A row-value comparison and row `IN` are three-valued over NULLs — a NULL
    // component makes a componentwise test UNKNOWN — exactly as the scalar
    // `.comparison`/`.membership` are, so neither is definite.
    case .comparison, .membership, .rows, .among, .like, .between, .bound:
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
    case let .rows(lhs, _, rhs):
      for expression in lhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
      for expression in rhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
    case let .among(lhs, rows, _):
      for expression in lhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
      for element in rows {
        for expression in element {
          try aggregates(in: expression, routines, subquery: subquery)
        }
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
      // three-valued `OR`, honouring the OR-chain's short-circuit
      // (`membership`): the run stops at the first TRUE comparison and never
      // evaluates a later element, so `1 IN (1, 1 / 0)` folds `true` here
      // without folding `1 / 0` to a `.divide` fault. Negated for `NOT IN`.
      //
      // Reject an empty list, as `check` and `lower` do — a whole-result
      // aggregate `HAVING` over the empty group reaches this fold WITHOUT a
      // prior `check` (`OutputColumn.typecheck`), so an empty list would
      // otherwise fold `false` (`true` under `NOT IN`) here while both compile
      // (`lower`) and schema (`check`) reject it. The parser rejects `IN ()`,
      // but a caller can build `.membership(_, [], …)` directly.
      if values.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      let lhs = try empty(operand, routines)
      let truth = try membership(of: values) { value throws(SQLError) in
        matches(lhs, .equal, try empty(value, routines))
      }
      return negated ? truth.map { !$0 } : truth
    case let .rows(lhs, op, rhs):
      // Fold `(l…) <op> (r…)` over the empty group as `Filter.comparison`
      // evaluates it: each component folds through `empty(_ expression:)`, then
      // the values combine with the SAME `matches`/Kleene primitives — the
      // componentwise Kleene `AND` for `=` (its negation for `<>`), the
      // lexicographic cascade for the ordering operators. Reject an unequal
      // arity as `lower`/`check` do.
      guard lhs.count == rhs.count else {
        throw .arity(lhs.count, rhs.count)
      }
      var l = Array<Value>()
      l.reserveCapacity(lhs.count)
      for expression in lhs { try l.append(empty(expression, routines)) }
      var r = Array<Value>()
      r.reserveCapacity(rhs.count)
      for expression in rhs { try r.append(empty(expression, routines)) }
      return relate(l, op, r)
    case let .among(lhs, rows, negated):
      // Fold `(l…) [NOT] IN ((r…), …)` over the empty group as
      // `Filter.memberships` evaluates it: the left row folds once, then
      // `(l…) = (r…)` folds over the element rows under Kleene `OR`, each
      // element equality the componentwise Kleene `AND`. Reject an empty list
      // or unequal arity as `lower`/`check` do.
      if rows.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      var l = Array<Value>()
      l.reserveCapacity(lhs.count)
      for expression in lhs { try l.append(empty(expression, routines)) }
      var truth: Bool? = false
      for element in rows {
        guard element.count == lhs.count else {
          throw .arity(lhs.count, element.count)
        }
        var r = Array<Value>()
        r.reserveCapacity(element.count)
        for expression in element { try r.append(empty(expression, routines)) }
        truth = or(truth, relate(l, .equal, r))
        if truth == true { break }
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

  /// Whether `column` is a QUALIFIED reference whose qualifier a relation of
  /// this scope answers — a qualified name a present alias (else a table name)
  /// names. An UNqualified name is FALSE (it names no one local relation to
  /// shadow an outer one), as is a qualified name no local relation answers.
  ///
  /// A qualified name a local relation answers but none of this scope binds is
  /// a QUALIFIED MISS on that relation — the local alias SHADOWS a same-named
  /// enclosing relation, so `find` faults it hard rather than correlating
  /// outward; an unadmitted qualifier is genuinely not local and correlates.
  private func shadows(_ column: Column) -> Bool {
    if column.qualifier == nil { return false }
    return members.contains { admits($0, column) }
  }

  /// Every combined ordinal `column` addresses — the FULL addressable surface
  /// (each admitted relation's PHYSICAL columns AND its VIRTUAL ones, through
  /// `Schema.ordinal(of:)`), in chain order. This is the ONE bare-name scan
  /// every ambiguity/presence determination routes through, so no site can scan
  /// a PARTIAL surface (real-only) and drift: a name matching more than one
  /// entry here is ambiguous, one present, none absent — measured over the same
  /// physical∪virtual surface `ordinal(of:)` resolves against. An unqualified
  /// `column` admits every relation; a qualified one only a relation its
  /// qualifier names.
  private func addressable(_ column: Column) -> Array<Int> {
    var ordinals = Array<Int>()
    for member in members where admits(member, column) {
      guard let local = member.schema.ordinal(of: column.name) else { continue }
      ordinals.append(member.offset + local)
    }
    return ordinals
  }

  /// The combined ordinal `column` resolves to.
  ///
  /// The name resolves against every admitted relation: present in exactly one
  /// it yields that relation's `offset` plus the local ordinal; present in more
  /// than one — an unqualified name in several relations, or a qualified name
  /// two relations share a name for — it is `SQLError.ambiguous`; in none it is
  /// `SQLError.column`. Resolution reads the ONE full-addressable scan
  /// (`addressable`), so it and every ambiguity/presence check measure the same
  /// physical∪virtual surface.
  internal func ordinal(of column: Column) throws(SQLError) -> Int {
    let ordinals = addressable(column)
    if ordinals.count > 1 { throw .ambiguous(column.name) }
    guard let resolved = ordinals.first else { throw .column(column.name) }
    return resolved
  }

  /// The combined ordinal `column` resolves to as an ENCLOSING reference, or
  /// `nil` when this scope binds it in NONE of its relations — the probe a
  /// nested subquery's `Outer` consults for a candidate correlated column. The
  /// three outcomes are DISTINCT: a name bound by exactly one relation yields
  /// its ordinal, a name bound by NONE reports `nil` (the `Outer` walk keeps
  /// looking outward), and a name bound by MORE than one relation of this scope
  /// is `SQLError.ambiguous` and PROPAGATES — a nearer ambiguous scope SHADOWS
  /// farther ones rather than falling through to rebind the name to an outer
  /// column. Only the not-found `SQLError.column` becomes `nil`; every other
  /// fault (an ambiguity or a qualifier fault) propagates. This is the
  /// enclosing analog of `find`, which the LOCAL lowering consults for the same
  /// reason.
  internal func correlated(_ column: Column) throws(SQLError) -> Int? {
    try find(column)
  }

  /// The combined ordinal `column` resolves to, or `nil` when it is a candidate
  /// CORRELATED reference to an enclosing scope — the not-found probe a
  /// `.column` lowering consults before correlating outward. FOUR outcomes stay
  /// DISTINCT.
  ///
  /// A name bound by exactly one relation yields its ordinal (found → bind). A
  /// name bound by MORE than one relation is `SQLError.ambiguous`, PROPAGATED
  /// (never `nil`): a local ambiguity is a hard error, not a fall-through, so
  /// `try?`-swallowing it would silently rebind an ambiguous local name to an
  /// outer column. The remaining `SQLError.column` — no relation binds the name
  /// — splits on whether some local relation ADMITTED the qualifier: an
  /// UNADMITTED qualifier (or an absent unqualified name) is a genuine
  /// not-found → `nil`, so the walk correlates outward; a qualifier a local
  /// relation DOES admit, naming a column it LACKS, is a QUALIFIED MISS that
  /// PROPAGATES as a hard `.column` — the local alias SHADOWS a same-qualifier
  /// enclosing relation, so it faults against the inner relation rather than
  /// falling through to bind the outer one.
  internal func find(_ column: Column) throws(SQLError) -> Int? {
    do {
      return try ordinal(of: column)
    } catch let error {
      guard case .column = error else { throw error }
      if shadows(column) { throw error }
      return nil
    }
  }

  /// The resolved column a bare `column` LOCALLY names — carrying its output
  /// name, its `type(at:)` type, and its `unconstrained(at:)` mask TOGETHER
  /// from ONE `find` — or `nil` when this scope binds it in none of its
  /// relations (the reference is a candidate correlated one).
  ///
  /// INVARIANT: a column reference's type and mask (and any future per-column
  /// attribute) are obtained from ONE resolution that traverses the SAME paths
  /// — local (here), correlation (`Outer.resolved(for:)`), schema — so the two
  /// attributes cannot diverge. The mask reader once consulted a DIFFERENT
  /// (local-only) path than the type reader, so a correlated all-NULL column
  /// lost its mask; folding both through the single ordinal closes that gap.
  internal func resolved(_ column: Column) throws(SQLError) -> ResolvedColumn? {
    guard let ordinal = try find(column) else { return nil }
    return ResolvedColumn(name: column.name, type: type(at: ordinal),
                          unconstrained: unconstrained(at: ordinal))
  }

  /// The resolved column at combined `ordinal`, named `name` — its `type(at:)`
  /// type and `unconstrained(at:)` mask read TOGETHER, so an enclosing
  /// correlation walk (`Outer.resolved(for:)`) carries both up from the one
  /// ordinal it matched.
  internal func resolved(at ordinal: Int, named name: String)
      -> ResolvedColumn {
    ResolvedColumn(name: name, type: type(at: ordinal),
                   unconstrained: unconstrained(at: ordinal))
  }

  /// The combined-ordinal projected terms: every real column of every relation
  /// for `*` (in chain order, never a virtual column) as `.slot` terms, a
  /// bare-column list as `.slot` terms at their combined ordinals, an
  /// expression list as lowered terms — in source order.
  internal func terms(_ projection: Projection,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported) throws(SQLError)
      -> Array<Term> {
    // A projection is a BARRED clause position (see `Schema.terms`): the entry
    // bars the seam, so no join-scope projection can admit a correlated column
    // of THIS query.
    let subquery = subquery.barred
    switch projection {
    case .all:
      // The `NATURAL`/`USING` merged columns FIRST (ISO 9075 7.10), each as its
      // coalesce `value`, then every real column the shared `expansion`
      // enumeration yields as a `.slot` at its combined ordinal — in chain
      // order, never a virtual column, and never a physical constituent a
      // merged column subsumes. `width(of: .all)` counts this SAME
      // enumeration, so the emitted arity and the width cannot diverge.
      return merged.map(\.value) + expansion.map { .slot($0) }
    case let .columns(columns):
      // Lower each bare column through `term`, so a name none of this scope's
      // relations bind consults the `subquery` surface: a correlated reference
      // on the BARRED projection surface is diagnosed unsupported (parity with
      // the schema path) rather than faulting `SQLError.column`.
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(term(.column(column), routines, subquery: subquery))
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
                     subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      // A BARE (unqualified) name matching a `NATURAL`/`USING` merged column
      // (ISO 9075 7.10) resolves to its ONE coalesced `value` — the merged
      // entry SHADOWS its two physical constituents, so the name is not
      // ambiguous between the two sides. A QUALIFIED `A.c`/`B.c` never matches
      // a (unqualified) merged column and reaches its own side below. A
      // physical column of the same name a later PLAIN join contributed faults
      // `.ambiguous` (`merged(binding:)`).
      if column.qualifier == nil,
          let merged = try merged(binding: column.name) {
        return merged.value
      }
      // Resolve the column against this scope's own relations first; a name
      // none binds is a candidate CORRELATED reference — consult the enclosing
      // scope, lowering to a synthetic `Term.parameter` bound from the outer
      // row when it resolves there, else the ordinary unknown-column fault. A
      // LOCALLY AMBIGUOUS name (bound by more than one relation) is a HARD
      // error `find` propagates — never a fall-through to outer correlation
      // that would rebind it to an outer column.
      if let ordinal = try find(column) { return .slot(ordinal) }
      if let name = try subquery.correlate(column) { return .parameter(name) }
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
      throw .state("42803", "an aggregate is not allowed here")
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
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // An ORDER BY is BARRED, as the projection is (see `Schema.order`).
    let subquery = subquery.barred
    return try SQLEngine.order(order, projection, names) {
      expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }
  }

  /// Lowers a join's `ON predicate` to the engine's `Filter` across the chain,
  /// emitting a `match` for each pure `column = column` equality — the
  /// hash-join key `nest` folds into a physical `Join` — ONLY WHEN the WHOLE
  /// `ON` is safe, and otherwise lowering the entire conjunction as one
  /// residual.
  ///
  /// The key is READ OFF the ALREADY-LOWERED conjunct, not by re-resolving the
  /// AST: a conjunct whose lowered form is a `compare(.slot, .equal, .slot)` —
  /// both operands columns of the join prefix — IS the hash-join key `nest`
  /// folds into a physical `Join`, so it is rewritten to the `match(left,
  /// right)` node `nest` recognises. A conjunct that lowered to a `.parameter`
  /// operand is a CORRELATED outer reference (`ON V.x = T.id` under an EXISTS,
  /// lowering to `compare(.slot, .equal, .parameter)`), NOT a column = column
  /// key, so it stays the residual `ON` filter — re-resolving its AST would
  /// consult only the prefix and fault `SQLError.column` on the outer column
  /// that already lowered correctly. Every other leaf (an inequality, an
  /// expression equality such as `a.x = b.y + 1`, an `IS NULL`, a membership,
  /// an `OR`/`NOT`) lowers through `lower`, becoming a residual the join runs
  /// as a filter over the product — nested-loop semantics, correct if O(n·m).
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
                   subquery: Resolution = .unsupported)
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
    // Read the equi-join key off the ALREADY-LOWERED term rather than
    // re-resolving the AST: a key is a `compare(.slot, .equal, .slot)` whose
    // BOTH operands are columns of the join prefix. A conjunct that lowered to
    // a `.parameter` operand is a CORRELATED outer reference (`V.x = :outer`),
    // NOT a column = column key, so it stays the residual `ON` filter — a
    // re-resolution of its AST would consult only the prefix and fault
    // `SQLError.column` on the outer column already lowered correctly.
    let filters = lowered.map { residual -> Filter in
      if case let .compare(.slot(left), .equal, .slot(right)) = residual {
        return Filter(match: left, right)
      }
      return residual
    }
    return filters.conjunction!
  }

  /// Lowers the name-addressed AST `predicate` to the engine's `Filter`, each
  /// column reference resolved to a combined ordinal across the chain.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
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
/// An `aggregate` node yields grouped records whose slots are the `GROUP BY`
/// key values (slots `0 ..< keys.count`, in key order) followed by the
/// aggregate results (slot `keys.count + j` is aggregate `j`). A `Grouping`
/// lowers a name-addressed AST expression into that space: an aggregate call
/// maps to its result slot; a bare column maps to its key slot ONLY when it is
/// a `GROUP BY` key — the standard rule that a non-aggregated column must
/// appear in the `GROUP BY` (else `SQLError.grouping`). It also records each
/// projected item's output name so an `ORDER BY` may name a projection alias,
/// the standard way to order on an aggregate (`ORDER BY <count-alias>`).
///
/// The keys and aggregates resolve against the underlying `Scope`, so the same
/// combined-ordinal resolution the source uses decides which projection columns
/// are keys.
internal struct Grouping {
  private let scope: Scope

  /// Each BARE-column `GROUP BY` key's combined base ordinal mapped to its
  /// grouped slot — key `i` sits at grouped slot `i`. A general (non-column)
  /// key holds no ordinal entry; it matches by expression through
  /// `expressions` instead.
  private let keys: Dictionary<Int, Int>

  /// Each `GROUP BY` key's source AST expression, in key order — key `i` sits
  /// at grouped slot `i`. A projection/`HAVING`/`ORDER BY` expression EQUAL to
  /// a general (non-column) key resolves to that key's slot. A bare column
  /// still resolves through the ordinal `keys` map, so a qualification-
  /// equivalent reference (`Amount` vs `Sales.Amount`) matches.
  private let expressions: Array<Expression>

  /// Each `GROUP BY` key's LOWERED base-ordinal term, in key order — key `i`
  /// sits at grouped slot `i`. A projection/`HAVING`/`ORDER BY` expression that
  /// lowers to a term EQUAL to a key's is that key, so a bare `NATURAL`/`USING`
  /// merged column — which lowers to a `COALESCE(left, right)` term with NO
  /// single ordinal, the group key AND every bare reference to it — groups and
  /// projects as ONE value, matched by the lowered TERM rather than the AST
  /// expression or an ordinal a merged column lacks.
  private let terms: Array<Term>

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

  /// Builds a grouping over `scope` for the `GROUP BY` `columns` (with their
  /// already-LOWERED base-ordinal `terms`, so a merged column's coalesce term
  /// is matched by term) and the query's distinct `aggregates` (in
  /// first-appearance order — aggregate `j` at grouped slot `columns.count +
  /// j`). The `aggregates` are already deduped by RESOLVED `Aggregation` (see
  /// `group`), so a qualification-equivalent pair is one entry, one slot.
  internal init(_ scope: Scope, _ grouping: Array<Expression>,
                _ terms: Array<Term>,
                _ aggregates: Array<Aggregation>,
                subquery: Resolution = .unsupported) throws(SQLError) {
    self.scope = scope
    var keys = Dictionary<Int, Int>(minimumCapacity: grouping.count)
    for index in grouping.indices {
      // A BARE-column grouping key a local relation binds maps its combined
      // ordinal to its grouped slot. A bare `NATURAL`/`USING` MERGED column
      // binds no single ordinal (`find` faults `.ambiguous` over its two
      // physical sides) — its lowered `terms[index]` is a `COALESCE` matched by
      // term, so it takes NO ordinal entry, as a general key does. A key NONE
      // binds is a candidate CORRELATED reference (a LATERAL body grouping
      // on a preceding column): the correlation surface's non-recording
      // `correlated` probe distinguishes it from a genuine unknown column, and
      // it occupies grouped slot `index` as a `.parameter` key (in `group`'s
      // keys array) with NO ordinal→slot entry — the projection reads it via
      // the same correlation, never through this key dict. A genuinely unknown
      // column re-throws the `.column` fault; a barred surface diagnoses a
      // bound outer column `.unsupported`. `correlated` records nothing, so it
      // stays idempotent against `group`'s own correlation. A general
      // (non-column) key takes no ordinal entry; it matches by term in `term`.
      guard case let .column(column) = grouping[index],
          column.qualifier == nil ? scope.merges(column.name) == nil : true
      else { continue }
      if let ordinal = try scope.find(column) {
        keys[ordinal] = index
      } else if try subquery.correlated(column) == nil {
        _ = try scope.ordinal(of: column)
      }
    }
    self.keys = keys
    self.expressions = grouping
    self.terms = terms
    self.offset = grouping.count
    self.aggregates = aggregates
  }

  /// The grouped slot an aggregate `expression` resolves to (an aggregate the
  /// query collected), or `nil` if it is not one. The expression is RESOLVED to
  /// an `Aggregation` — column qualification normalized to a slot — and matched
  /// against the collected aggregations, so `SUM(Amount)` and
  /// `SUM(Sales.Amount)` find the same slot in a single-relation scope.
  private func slot(of expression: Expression, _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
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
  /// slot only when it is a `GROUP BY` key, else it is `SQLError.grouping` —
  /// the standard rule.
  private func term(_ expression: Expression,
                    _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    if case .aggregate = expression,
       let slot = try slot(of: expression, routines, subquery: subquery) {
      return .slot(slot)
    }
    // A bare `NATURAL`/`USING` MERGED column lowers to its `COALESCE(left,
    // right)` value — the SAME term the `GROUP BY` key lowered to — so it
    // matches a key by TERM (it binds no single ordinal), grouping and
    // projecting as ONE value. A right-only row of a `RIGHT`/`FULL` join groups
    // by its coalesced value, not a NULL left column.
    if case let .column(column) = expression, column.qualifier == nil,
        scope.merges(column.name) != nil {
      let lowered = try scope.term(expression, routines, subquery: subquery)
      guard let index = terms.firstIndex(of: lowered) else {
        throw .grouping(column.name)
      }
      return .slot(index)
    }
    // A general (non-column) key matches by expression: a projection/`HAVING`/
    // `ORDER BY` expression EQUAL to a `GROUP BY` key resolves to that key's
    // grouped slot. A bare column is skipped here and falls through to the
    // ordinal path below, which matches a qualification-equivalent reference.
    if case .column = expression {
    } else if let index = expressions.firstIndex(of: expression) {
      return .slot(index)
    }
    switch expression {
    case let .column(column):
      // Resolve the column against this scope's own relations first, mirroring
      // `Scope.term`'s `.column`: a name a local relation binds must be a
      // `GROUP BY` key (the standard grouping rule), else `SQLError.grouping`.
      // A name NONE binds is a candidate CORRELATED reference — consult the
      // surface, which admits it (a `Term.parameter` the apply binds per outer
      // row) only for a LATERAL body's `everywhere` seam and diagnoses it
      // `.unsupported` on an ordinary barred grouped surface. The final
      // `ordinal(of:)` re-throws the genuine unknown-column `.column` fault,
      // exactly as `Scope.term` does.
      if let ordinal = try scope.find(column) {
        guard let slot = keys[ordinal] else { throw .grouping(column.name) }
        return .slot(slot)
      }
      if let name = try subquery.correlate(column) { return .parameter(name) }
      return try .slot(scope.ordinal(of: column))
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
      // key, an aggregate its result slot, as elsewhere in a grouped
      // expression.
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
      // inconsistency, since the query gathers every projection/HAVING
      // aggregate.
      throw .state("XX000", "uncollected aggregate")
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

  /// The grouped-space projected terms, recording each item's output name for
  /// an `ORDER BY` to name.
  ///
  /// A `columns` projection (`SELECT Dept … GROUP BY Dept`) lowers each column
  /// as a grouped term — a `GROUP BY` key, else `SQLError.grouping`. An
  /// `expressions` projection lowers each item's expression and records its
  /// output name (an alias, else a bare column's name) so an `ORDER BY` may
  /// name it — the standard alias ordering on an aggregate. A `SELECT *` has no
  /// well-defined meaning over groups (which columns?), so it faults.
  internal mutating func terms(_ projection: Projection,
                               _ routines: Routines = [:],
                               subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<Term> {
    // A grouped projection is a BARRED clause position (see `Schema.terms`):
    // the entry bars the seam so it cannot admit a correlated column of THIS
    // query.
    let subquery = subquery.barred
    switch projection {
    case .all:
      throw .state("0A000",
                   "SELECT * is not allowed with GROUP BY or aggregates")
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
                      subquery: Resolution = .unsupported)
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
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // A grouped ORDER BY is BARRED, as the projection is (see `Schema.order`).
    let subquery = subquery.barred
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
    case let .comparison(lhs, _, rhs):
      for term in lhs { term.references(into: &ordinals) }
      for term in rhs { term.references(into: &ordinals) }
    case let .memberships(lhs, rows, _):
      for term in lhs { term.references(into: &ordinals) }
      for element in rows {
        for term in element { term.references(into: &ordinals) }
      }
    case let .exists(_, correlation, _):
      // A CORRELATED EXISTS reads the enclosing row's cells its inner `WHERE`
      // names — the correlation's `slot` outer ordinals — so those must be
      // materialised for the per-row re-execution (a `bound` source reads a
      // threaded binding, not the outer record). An UNCORRELATED one names
      // none.
      ordinals.formUnion(correlation.slots)
    case let .within(operand, _, correlation, _):
      // The outer operand term reads ordinals; a CORRELATED subquery ALSO reads
      // the outer `slot` cells its inner `WHERE` names.
      operand.references(into: &ordinals)
      ordinals.formUnion(correlation.slots)
    case let .quantified(operand, _, _, _, correlation):
      // As `within`: the outer operand term reads ordinals; a CORRELATED
      // subquery ALSO reads the outer `slot` cells its inner `WHERE` names.
      operand.references(into: &ordinals)
      ordinals.formUnion(correlation.slots)
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
