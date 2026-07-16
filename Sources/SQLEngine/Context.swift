// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The escapable execution context threaded beside the borrowed base catalog
/// through every resolution and execution phase — the three owned maps a run
/// carries, bundled into one value.
///
/// A query runs against a `~Escapable` `Catalog` (borrowed, never copied) plus
/// this `Context` (fully owned value data):
///
/// - `relations` — the in-scope relation overlay: the materialised common table
/// expressions a `WITH` binds and any `definition_schema.` store relation the
/// query names, keyed case-folded. The resolver consults it BEFORE the base
/// catalog, so a name it binds shadows a base table or view. - `routines` — the
/// scalar functions (UDFs) a call resolves through, keyed case-folded; the
/// engine prelude (`BITAND`) merged under the caller's. - `bindings` — the
/// query parameters, each `:name` mapped to its bound value, read by a `bound`
/// filter and the seek planner.
///
/// It is plain escapable data, so it needs none of the lifetime machinery the
/// borrowed catalog does: extending the `relations` overlay for a CTE's scope,
/// or rebinding it for a recursive step, is an ordinary value copy — the
/// `deriving`/`scoping` helpers below. The borrowed catalog stays a SEPARATE
/// parameter; a `Context` never holds it (a stored `~Escapable` member cannot
/// yield a `~Escapable` table).
internal struct Context {
  /// The in-scope relation overlay — materialised CTEs and store relations,
  /// consulted before the base catalog.
  internal let relations: ScopedRelations

  /// The scalar routines (UDFs) a call resolves through.
  internal let routines: Routines

  /// The query parameter bindings.
  internal let bindings: Bindings

  /// The RUN-time results of the UNCORRELATED subqueries the executing plan
  /// nests — each `EXISTS`/`IN (Q)` subquery run ONCE and memoised by its
  /// `Query`, read by the row evaluator. Empty during compilation and every
  /// schema-only path (which never opens a cursor); the `run` path populates it
  /// (see `Catalog.subqueries(of:)`) just before executing the plan.
  internal let subqueries: Subqueries

  /// The cyclic-view guard — the view names currently under resolution, so a
  /// view body that materialises itself (directly or through a derived table)
  /// faults `SQLError.recursion` rather than resolving without end.
  internal let visited: Set<String>

  /// Whether a derived table's body is EAGER type-checked at resolution. A RUN
  /// preflight, or a schema-only path after a run has proved the statement
  /// runnable, passes `false` so a data-dependent-empty body expression an
  /// execution never evaluates is not rejected; a strict schema check keeps it
  /// `true`.
  internal let validate: Bool

  /// The resolution overlay a nested subquery lowers its cache key under —
  /// `.caller` for a top-level compile, `.view(name)` for a view body's — so a
  /// view-body occurrence and a top-level one over the same AST stay distinct
  /// cache entries (see `Subscope`).
  internal let subscope: Subscope

  /// The enclosing correlation stack a nested subquery correlates against — the
  /// `Outer` scopes an inner `WHERE` column that binds none of ITS relations
  /// resolves outward through, lowering to a synthetic `Term.parameter` and
  /// recording the correlation. `nil` at the top level (no enclosing query).
  internal let outer: Outer?

  /// Whether the query being resolved is a LATERAL derived table's BODY — set
  /// only by `lateral(_:against:_:)` as it derives/compiles the body. Per ISO
  /// 9075 a `LATERAL` body's preceding-FROM references are in scope throughout
  /// its query expression, INCLUDING the select list, so the body admits a
  /// correlated column EVERYWHERE (not only its `WHERE`/`ON`). This flag
  /// threads into the `Resolution`/`SubqueryCheck` the body's lowering and
  /// validation build (`everywhere`), lifting the projection-correlation bar
  /// for the lateral body ALONE — an ordinary subquery's projection stays
  /// barred (`false`).
  internal let lateral: Bool

  /// A context over the maps and resolution scope — an empty overlay, no
  /// bindings, an empty visited guard, eager validation, the caller scope, and
  /// no enclosing correlation by default: the shape a bare top-level query with
  /// no `WITH` and no parameters resolves and runs under. It carries no
  /// subquery results until `run` resolves them.
  internal init(relations: ScopedRelations = [:], routines: Routines = [:],
                bindings: Bindings = [:],
                subqueries: Subqueries = Subqueries(),
                visited: Set<String> = [], validate: Bool = true,
                subscope: Subscope = .caller, outer: Outer? = nil,
                lateral: Bool = false) {
    self.relations = relations
    self.routines = routines
    self.bindings = bindings
    self.subqueries = subqueries
    self.visited = visited
    self.validate = validate
    self.subscope = subscope
    self.outer = outer
    self.lateral = lateral
  }

  /// A copy of this context with `relations` REPLACING the overlay, the same
  /// routines, bindings, and subquery results — the scope a phase reads after
  /// `augment` extends the overlay with the store relations a query names, or a
  /// recursive step rebinds a CTE's self.
  internal func scoping(_ relations: ScopedRelations) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: lateral)
  }

  /// A copy of this context ENTERING a fresh body scope over `relations` — the
  /// SINGLE derivation every view/derived-table/CTE body-entry seam routes
  /// through, `scoping(relations)` with the enclosing correlation stack CLEARED
  /// (`uncorrelated()`). A body scope — a view definition, a non-LATERAL
  /// derived table, or a CTE — is resolved INDEPENDENTLY of its call site, so
  /// it must NOT correlate against an enclosing query's row: an unbound column
  /// in the body must fault rather than bind outward to the caller. Folding the
  /// reset INTO body-entry makes the clear intrinsic — a future body seam that
  /// routes through `body(_:)` cannot forget to append `uncorrelated()`. A site
  /// that also guards the cyclic-view chain or gates the eager type-check
  /// chains `visiting(_:)`/`validating(_:)` AFTER `body(_:)`.
  internal func body(_ relations: ScopedRelations) -> Context {
    scoping(relations).uncorrelated()
  }

  /// A copy of this context whose overlay binds `materialised` to `name`
  /// (folded to lower case), the binding shadowing any existing one — the
  /// recursive step's rebinding of a CTE's self to the previous iteration's
  /// rows.
  internal func binding(_ name: String, to materialised: RelationInstance)
      -> Context {
    var relations = relations
    relations[name.lowercased()] = materialised
    return scoping(relations)
  }

  /// A copy of this context with `bindings` REPLACING the parameter bindings,
  /// the same overlay, routines, and subquery results — a correlated subquery's
  /// per-outer-row rebinding, which extends the bindings with the enclosing
  /// row's cells before re-executing its inner plan.
  internal func binding(_ bindings: Bindings) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: lateral)
  }

  /// A copy of this context carrying `subqueries` as the executing plan's
  /// materialised subquery results — the run path's extension just before it
  /// executes a compiled plan, so the row evaluator reads each subquery result
  /// off the SAME context that threads everywhere `execute` descends.
  internal func resolving(_ subqueries: Subqueries) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: lateral)
  }

  /// A copy of this context with every enclosing SELECT's derived-table aliases
  /// REVEALED away — the overlay's derived layers dropped, its common table
  /// expressions and `definition_schema.` store relations (the base layer)
  /// KEPT — the scope a NESTED subquery's FROM resolves against.
  ///
  /// A derived-table alias is SELECT-scoped: it names a relation only in its
  /// OWN SELECT's FROM/JOIN and expressions, invisible to a nested subquery's
  /// FROM exactly as a base-table alias in the enclosing FROM is (a subquery
  /// does not see the enclosing query's FROM relations; only base tables and
  /// enclosing CTEs are in its relation scope). A CTE, by contrast, is
  /// statement-scoped — visible inside a nested subquery's FROM — so it stays.
  /// The seam that compiles/materialises a nested subquery (`subquery(of:)`,
  /// `subqueries(of:)`, `cell(of:)`, and the type-check counterparts) reveals
  /// the base so a subquery's `FROM d` cannot scan an outer derived alias `d`,
  /// while a same-named CTE `d` the derived alias SHADOWED is resolved again
  /// — the layered overlay never deleted it. The subquery re-augments its OWN
  /// derived tables into a fresh layer.
  internal func revealed() -> Context {
    scoping(relations.revealed())
  }

  /// A copy of this context with `name` (folded to lower case) ADDED to the
  /// cyclic-view guard — the scope a view body resolves under, so a nested
  /// reference back to the view faults `SQLError.recursion` rather than
  /// resolving without end.
  internal func visiting(_ name: String) -> Context {
    var visited = visited
    visited.insert(name.lowercased())
    return Context(relations: relations, routines: routines,
                   bindings: bindings, subqueries: subqueries,
                   visited: visited, validate: validate, subscope: subscope,
                   outer: outer, lateral: lateral)
  }

  /// A copy of this context with the eager-typecheck gate set to `flag` — a RUN
  /// preflight or a post-run schema-only path passes `false` to keep a
  /// data-dependent body lenient.
  internal func validating(_ flag: Bool) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: flag,
            subscope: subscope, outer: outer, lateral: lateral)
  }

  /// A copy of this context resolving its nested subqueries under `subscope` —
  /// `.view(name)` for a view body, `.caller` for a top-level compile — so an
  /// occurrence's cache key carries the scope it lowered under.
  internal func scoped(as subscope: Subscope) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: lateral)
  }

  /// A copy of this context whose enclosing correlation stack is EXTENDED with
  /// `scope` as the nearest enclosing one (`Outer.nested(under:)`, starting a
  /// fresh stack at the top level) — the scope a nested subquery correlates
  /// against, so an inner column binding none of its own relations resolves
  /// outward and records the correlation.
  internal func nesting(under scope: Scope) -> Context {
    with(outer: (outer ?? Outer()).nested(under: scope))
  }

  /// A copy of this context carrying `outer` as its enclosing correlation stack
  /// — the direct set a caller uses when it already holds the `Outer` a nested
  /// subquery lowers against.
  internal func with(outer: Outer?) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: lateral)
  }

  /// A copy of this context marking the query it resolves as a LATERAL derived
  /// table's BODY (`lateral`) — the SINGLE seam `lateral(_:against:_:)` routes
  /// its body's schema derivation and plan compile through, so the body's
  /// `Resolution`/`SubqueryCheck` admit a correlated preceding-FROM column
  /// EVERYWHERE, including the projection, per ISO. Every OTHER field is
  /// preserved; the flag is scoped to the body's own lowering (a nested
  /// NON-lateral body clears it through `body(_:)`).
  internal func lateralizing() -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: true)
  }

  /// A copy of this context with the enclosing correlation stack CLEARED — the
  /// scope a body that must NOT correlate against the caller's row resolves
  /// under: a view body and a non-LATERAL derived table body. Neither may see
  /// an enclosing query's columns (a view is defined independently of its call
  /// site; a derived table is uncorrelated), so an unbound column in either
  /// must fault rather than bind outward to the caller. Every OTHER field —
  /// the relation overlay, routines, bindings, subquery results, the visited
  /// guard, the validate gate, and the subscope — is preserved; `outer` resets
  /// to `nil` (restoring the top-level default) and the LATERAL-body flag
  /// clears, so a non-lateral body nested inside a lateral one does NOT inherit
  /// the everywhere-correlation admission.
  internal func uncorrelated() -> Context {
    with(outer: nil).unlateralized()
  }

  /// A copy of this context with the LATERAL-body flag CLEARED — the reset
  /// `uncorrelated()`/`body(_:)` fold in, and the seam a nested ordinary
  /// subquery within a lateral body compiles under, so a body that must NOT
  /// correlate against the caller (a view or a non-lateral derived table) does
  /// not carry an enclosing lateral body's everywhere-correlation admission.
  internal func unlateralized() -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries, visited: visited, validate: validate,
            subscope: subscope, outer: outer, lateral: false)
  }
}
