// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The escapable execution context threaded beside the borrowed base catalog
/// through every resolution and execution phase — the three owned maps a run
/// carries, bundled into one value.
///
/// A query runs against a `~Escapable` `Catalog` (borrowed, never copied) plus
/// this `Context` (fully owned value data):
///
///   - `relations` — the in-scope relation overlay: the materialised common
///     table expressions a `WITH` binds and any `definition_schema.` store
///     relation the query names, keyed case-folded. The resolver consults it
///     BEFORE the base catalog, so a name it binds shadows a base table or view.
///   - `routines` — the scalar functions (UDFs) a call resolves through, keyed
///     case-folded; the engine prelude (`BITAND`) merged under the caller's.
///   - `bindings` — the query parameters, each `:name` mapped to its bound
///     value, read by a `bound` filter and the seek planner.
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

  /// A context over the three maps — an empty overlay and no bindings by
  /// default, the shape a bare query with no `WITH` and no parameters runs
  /// under. It carries no subquery results until `run` resolves them.
  internal init(relations: ScopedRelations = [:], routines: Routines = [:],
                bindings: Bindings = [:],
                subqueries: Subqueries = Subqueries()) {
    self.relations = relations
    self.routines = routines
    self.bindings = bindings
    self.subqueries = subqueries
  }

  /// A copy of this context with `relations` REPLACING the overlay, the same
  /// routines, bindings, and subquery results — the scope a phase reads after
  /// `augment` extends the overlay with the store relations a query names, or a
  /// recursive step rebinds a CTE's self.
  internal func scoping(_ relations: ScopedRelations) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries)
  }

  /// A copy of this context whose overlay binds `materialised` to `name` (folded
  /// to lower case), the binding shadowing any existing one — the recursive
  /// step's rebinding of a CTE's self to the previous iteration's rows.
  internal func binding(_ name: String, to materialised: RelationInstance)
      -> Context {
    var relations = relations
    relations[name.lowercased()] = materialised
    return scoping(relations)
  }

  /// A copy of this context carrying `subqueries` as the executing plan's
  /// materialised subquery results — the run path's extension just before it
  /// executes a compiled plan, so the row evaluator reads each subquery result
  /// off the SAME context that threads everywhere `execute` descends.
  internal func resolving(_ subqueries: Subqueries) -> Context {
    Context(relations: relations, routines: routines, bindings: bindings,
            subqueries: subqueries)
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
}
