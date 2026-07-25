// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The result schema of a query — the columns it would yield, named and typed,
/// WITHOUT running it.
///
/// A `SELECT`'s result has a name and a type per column: `SELECT *` takes them
/// from the relations in scope, a bare-column list from the column names, and
/// an expression list from each item's alias (else a derived name, else a
/// positional `column N`). `Catalog.columns(of:)` computes this by RESOLVING
/// the query — the same name → schema resolution compilation runs — but never
/// opening a cursor, so it is safe over an empty or costly source. It is the
/// one capability behind the `INFORMATION_SCHEMA` overlay's own headers, a
/// future `SELECT *` empty-result header, and a `.schema` metacommand.

// MARK: - Output column

/// One column of a query's result: its output name and its value type.
public struct OutputColumn: Hashable, Sendable {
  /// The column's output name — an alias, a source column's name, or a
  /// positional `column N` for an unnamed expression.
  public let name: String

  /// The column's value type.
  public let type: ValueType

  public init(name: String, type: ValueType) {
    self.name = name
    self.type = type
  }
}

// MARK: - Resolved column

/// One column of a relation body's RESOLVED output — the authoritative
/// per-column descriptor a binding is built FROM as a whole, rather than
/// re-listed field by field at each site.
///
/// It wraps the body's `OutputColumn` (name + type) and carries the per-column
/// `unconstrained` mask a set-operation type unification threads: whether every
/// arm folded into this column projects a CONSTANT NULL, so it places NO type
/// constraint on a unified column (a NULL unifies with any typed arm, exactly
/// as `COALESCE` skips a constant-NULL argument). It is the ONE per-column
/// carrier: both `resolved(query:in:)`/`columns(unifying:)` and `merge` operate
/// on and return it, and every binding is built from it via the single
/// `init(from:)` constructor — no site re-lists the fields, so none can drop
/// the mask.
internal struct ResolvedColumn: Hashable, Sendable {
  /// The column's output name and value type.
  internal let column: OutputColumn

  /// Whether every arm folded into this column so far projects a constant NULL,
  /// so it places NO type constraint on the set-operation's unified column.
  internal let unconstrained: Bool

  /// Whether this column's NAME is a SYNTHESIZED positional `column N` header
  /// rather than an inferable output name — the projection had no alias and no
  /// bare-column name (`Projected.name == nil`), so a display header stood in.
  /// It is the STRUCTURAL bare/unnamed fact (set where the name is fabricated),
  /// carried so a consumer distinguishes a synthesized header from a user's
  /// EXPLICIT delimited `AS "column 1"` — the two are indistinguishable by NAME
  /// text but not by provenance. The left arm's flag wins a set-operation fold,
  /// mirroring the ISO first-arm NAME rule.
  internal let synthesized: Bool

  internal init(_ column: OutputColumn, unconstrained: Bool = false,
                synthesized: Bool = false) {
    self.column = column
    self.unconstrained = unconstrained
    self.synthesized = synthesized
  }

  /// A resolved column carrying `name` and `type` directly — the declared
  /// carrier a common table expression's self binding is built from, its name
  /// the declared column and its type the `.integer` placeholder a materialised
  /// relation reports.
  internal init(name: String, type: ValueType, unconstrained: Bool = false,
                synthesized: Bool = false) {
    self.column = OutputColumn(name: name, type: type)
    self.unconstrained = unconstrained
    self.synthesized = synthesized
  }

  /// The column's output name.
  internal var name: String { column.name }

  /// The column's value type.
  internal var type: ValueType { column.type }
}

// MARK: - Merge

/// Merges two set-operation arms' resolved columns into the fold's running
/// column: the name is the LEFT arm's (the ISO first-arm rule), and the type is
/// the unification of the two — SKIPPING a constant-NULL (unconstrained) arm's
/// type, which constrains nothing. A column that is constant NULL in BOTH arms
/// stays unconstrained (its type the left's, defaulting to the `.integer` a
/// NULL column already carries); a column typed in ONE arm and NULL in the
/// other takes the typed arm's type and becomes constrained; two typed arms
/// merge through `ValueType.unified`, faulting `SQLError.operand` (SQLSTATE
/// 42804) on an irreconcilable pair — a text beside a number, a boolean beside
/// a number — the same fault a `COALESCE`/`CASE` raises on irreconcilable
/// result types.
///
/// `shape` (default `false`) is the nested-subquery pre-pass mode: on an
/// irreconcilable pair it does NOT fault but substitutes the LEFT arm's type as
/// a discardable placeholder, marked `unconstrained` so a further enclosing
/// fold treats it as placing no constraint. The pre-pass records this width-1
/// type for a subquery the reachability walk has not yet decided runs; an
/// UNREACHED occurrence's type is discarded, and a REACHED scalar/`IN` one is
/// re-folded STRICTLY (`shape: false`) on the reached path, so a genuine
/// incompatibility still faults there. Arity/resolution stay eager regardless.
internal func merge(_ left: ResolvedColumn, _ right: ResolvedColumn,
                    shape: Bool = false)
    throws(SQLError) -> ResolvedColumn {
  let name = left.column.name
  // The NAME (and its synthesized-header provenance) is the LEFT arm's — the
  // ISO first-arm rule — so a union whose first arm names a column `column N`
  // by synthesis stays synthesized (not bindable), and one whose first arm
  // names it explicitly stays a real output, regardless of the right arm.
  let synthesized = left.synthesized
  // A constant-NULL arm constrains nothing: carry the OTHER arm's type (and,
  // when both are NULL, the left's), narrowing the running unconstrained-ness
  // to whether BOTH remaining arms are NULL.
  if left.unconstrained {
    return ResolvedColumn(name: name, type: right.column.type,
                          unconstrained: right.unconstrained,
                          synthesized: synthesized)
  }
  if right.unconstrained {
    return ResolvedColumn(name: name, type: left.column.type,
                          synthesized: synthesized)
  }
  guard let unified = left.column.type.unified(with: right.column.type) else {
    // The shape pre-pass defers the operand fault to the reached path: yield a
    // discardable placeholder (the left arm's type, marked unconstrained)
    // rather than faulting while merely recording an unreached subquery.
    if shape {
      return ResolvedColumn(name: name, type: left.column.type,
                            unconstrained: true, synthesized: synthesized)
    }
    throw .operand("UNION arms have irreconcilable types")
  }
  return ResolvedColumn(name: name, type: unified, synthesized: synthesized)
}

// MARK: - Projection outputs

extension Scope {
  /// The output columns a `projection` yields over this scope, named and typed
  /// — `routines` type a scalar call from its declared return type.
  internal func columns(of projection: Projection,
                        _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<ResolvedColumn> {
    return switch projection {
    case .all:
      outputs()
    case let .columns(references):
      try references.map { column throws(SQLError) in
        try output(of: column, subquery: subquery)
      }
    case let .expressions(items):
      try items.indices.map { index throws(SQLError) in
        try output(items[index], at: index, routines, subquery: subquery)
      }
    }
  }

  /// The output columns of a `SELECT *` over this scope — the merged columns
  /// first, then the real columns the shared `expansion` enumeration emits, in
  /// chain order, named and typed from each relation's schema (never a virtual
  /// column) and carrying its source column's `unconstrained` mask (an
  /// all-arms-NULL CTE column stays unconstrained through a `*` expansion) —
  /// the terms `terms(.all)` projects.
  internal func outputs() -> Array<ResolvedColumn> {
    // The `NATURAL`/`USING` merged columns FIRST (ISO 9075 7.10) — each named
    // by its merged name and typed by its unified coalesce type — then every
    // real column the shared `expansion` enumeration yields, resolved at its
    // combined ordinal (name/type/mask read TOGETHER, `resolved(at:named:)`),
    // so the schema names the SAME columns the run's `terms(.all)` projects and
    // `width(of: .all)` counts. Each merged output is built through the SAME
    // `resolved(named:)` the explicit `output(of:)` uses, so a `SELECT *`
    // carries the merged column's `unconstrained` mask (two constant-NULL
    // constituents leave the merged `k` unconstrained) exactly as a bare
    // `SELECT k` does.
    merges.map { $0.resolved(named: $0.name) }
        + expansion.map { resolved(at: $0, named: name(at: $0)) }
  }

  /// The resolved output column a bare `column` reference yields — its own name
  /// (its spelling as written), its type, AND its `unconstrained` mask, read
  /// TOGETHER from ONE resolution so the two cannot diverge: from the relation
  /// that LOCALLY resolves it (`resolved(_:)` — one `find`, both fields), or,
  /// for a name no local relation binds, from the CORRELATION `subquery`
  /// surface (`resolved(for:)` — carrying the outer column's mask, so a
  /// correlated all-NULL column stays unconstrained), mirroring the expression
  /// path's `derive`. Under a LATERAL body's admitting (`everywhere`) surface a
  /// preceding-FROM column types as its outer column; under an ordinary barred
  /// surface it faults `.unsupported`. A genuinely unknown name re-throws the
  /// `.column` fault.
  internal func output(of column: Column,
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ResolvedColumn {
    // A BARE name matching a `NATURAL`/`USING` merged column (ISO 9075 7.10)
    // names and types from the merged column — its unified coalesce type — with
    // no physical ordinal, matching the run's `term`; a same-named physical
    // column a later plain join added faults `.ambiguous`. It carries the
    // merged column's OWN `unconstrained` mask, so a `… USING (k) UNION SELECT
    // 1` over two constant-NULL constituents defers the unified type to the
    // typed arm rather than hard-coding the merged column constrained.
    if column.qualifier == nil,
        let merged = try merged(binding: column.name) {
      return merged.resolved(named: column.name)
    }
    if let resolved = try resolved(column) {
      return resolved
    }
    if let resolved = try subquery.correlated(column) {
      return resolved
    }
    let ordinal = try ordinal(of: column)
    return resolved(at: ordinal, named: column.name)
  }

  /// The output column a projected `item` at 0-based `index` yields: its
  /// inferable output name (`Projected.name` — an alias, else a bare column's
  /// name), else a positional `column N` (1-based). A bare column carries its
  /// source type and a literal its own; a scalar call its routine's declared
  /// return type; every other expression `.integer`.
  ///
  /// It also carries the `unconstrained` mask a set-operation fold reads — a
  /// column that places NO type constraint (a NULL unifies with any typed arm,
  /// exactly as `COALESCE` skips a constant-NULL argument). Three sources mark
  /// it so, all read HERE from the same resolution as the type, never a
  /// separate local-only walk: an expression that folds to a CONSTANT NULL for
  /// every row (`null(_:)`); an expression that would dispatch an UNREGISTERED
  /// routine at ANY depth (`unresolved(_:)` — `derive` fabricates the
  /// `.integer` default for such a call, so the fold must defer rather than
  /// fault on the placeholder); and a bare-column reference resolving to an
  /// unconstrained source column (`output(of:)` — LOCAL or CORRELATED, so an
  /// all-NULL column referenced through a LATERAL body keeps its mask).
  internal func output(_ item: Projected, at index: Int,
                       _ routines: Routines = [:],
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ResolvedColumn {
    // The item's inferable output NAME (`Projected.name` — an alias, else a
    // bare column's name), or a SYNTHESIZED positional `column N` header when
    // it has none. `synthesized` is that STRUCTURAL bare/unnamed fact — carried
    // on the resolved column so a consumer (the `ordered` set-op carrier)
    // distinguishes this fabricated header from a user's explicit delimited
    // `AS "column 1"`, which by NAME text is identical but is a real output.
    let synthesized = item.name == nil
    let name = item.name ?? "column \(index + 1)"
    // A projection places NO type constraint on the unified column when it
    // folds to a CONSTANT NULL for every row (`null` — its derived literal-fix
    // type must not shape the fold) OR when it would dispatch an UNREGISTERED
    // routine at ANY depth (`unresolved` — `derive` fabricates the `.integer`
    // default for such a call, and the fold must not fault on that
    // placeholder). Either way mark it UNCONSTRAINED and derive its type only
    // for the column's advertised type, which the fold then ignores. A
    // reachable missing call still faults `SQLError.function` at the run
    // typecheck, so this defers only the FOLD, never hides the call.
    if null(item.expression, routines)
        || unresolved(item.expression, routines) {
      let type = try derive(item.expression, routines, subquery: subquery)
      return ResolvedColumn(OutputColumn(name: name, type: type),
                            unconstrained: true, synthesized: synthesized)
    }
    // A bare-column projection reuses the ONE column resolution — LOCAL or
    // CORRELATED — so its type and `unconstrained` mask agree, renaming only
    // its output name when the item carries an alias.
    if case let .column(column) = item.expression {
      let resolved = try output(of: column, subquery: subquery)
      return ResolvedColumn(OutputColumn(name: name, type: resolved.type),
                            unconstrained: resolved.unconstrained,
                            synthesized: synthesized)
    }
    // A bare scalar-subquery projection reuses the subquery's OWN resolved
    // column — its type AND `unconstrained` mask — so a constant-NULL body
    // (`(SELECT NULLIF('a','a'))`) stays unconstrained in an outer
    // set-operation fold, mirroring the bare-column branch above. Only a bare
    // `.subquery` qualifies: a subquery NESTED inside a larger expression
    // legitimately constrains, so it falls through to the generic (constrained)
    // else below.
    if case let .subquery(query) = item.expression {
      let resolved = try subquery.scalar(resolved: query)
      return ResolvedColumn(OutputColumn(name: name, type: resolved.type),
                            unconstrained: resolved.unconstrained,
                            synthesized: synthesized)
    }
    // DERIVE the nominal output type: the schema reports the type a run would
    // produce and never faults on an operand. Run-time operand and call
    // validation is `typecheck`'s job, reachability-aware, so a schema resolves
    // even for an expression a zero-row limit makes unreachable. A scalar
    // subquery derives its single-column type from the `subquery` map. Any
    // other expression carries a genuine type, so it is constrained.
    return try ResolvedColumn(OutputColumn(name: name,
                                           type: derive(item.expression,
                                                        routines,
                                                        subquery: subquery)),
                              synthesized: synthesized)
  }
}
