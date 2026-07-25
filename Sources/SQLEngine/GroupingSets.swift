// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - GROUPING SETS

extension Query {
  /// This query with each TOP-LEVEL `GROUP BY GROUPING SETS` select replaced by
  /// its `UNION ALL` expansion — applied ONCE at every pipeline entry (`run`,
  /// `compile`, `columns(of:)`), so the whole downstream (materialise, augment,
  /// executor) sees the expanded AST and a run and a `columns(of:)` derive
  /// cannot diverge.
  ///
  /// It rewrites the query's OWN selects (a bare select and each set-operation
  /// arm), NOT the derived tables or subqueries nested within — those RE-ENTER
  /// these same entries (`materialise`/`resolved` run and derive an inner body,
  /// `cell` runs a scalar subquery), where they are expanded in turn — so ONE
  /// shallow pass at each entry covers arbitrary nesting.
  internal var expanded: Query {
    get throws(SQLError) {
      switch self {
      case let .select(select):
        if case let .sets(sets) = select.grouping {
          return try expand(select, sets: sets)
        }
        return self
      case let .setop(kind, left, right, all):
        return .setop(kind, try left.expanded, try right.expanded, all: all)
      case let .ordered(inner, distinct, order, limit, generated):
        // An `ordered` carrier is produced by `expand` over an already-
        // expanded union, so its inner is idempotent under a re-expansion;
        // recurse for uniformity (a nested `.sets` inside is impossible —
        // `expand` only ever wraps a `setop` of `.arm` selects). The generated
        // trailing count rides through unchanged.
        return .ordered(try inner.expanded, distinct: distinct, order: order,
                        limit: limit, generated: generated)
      }
    }
  }
}

/// Expands a `GROUP BY GROUPING SETS (s1, …, sn)` `select` into a `UNION ALL`
/// of one grouped ARM per set — the SINGLE shared expansion the compile path
/// (`compile(_ select:)`) and the schema path (`columns(unifying:)`) BOTH
/// drive, so a run and a `columns(of:)` derive cannot diverge.
///
/// Each arm is the original select grouped on ONE set's `keys` while carrying
/// the SUPERSET (the union of every set's keys) in its `.arm` grouping — so a
/// projected/HAVING reference to a grouping column ANOTHER set groups on but
/// THIS arm's set omits lowers to a super-aggregate NULL by RESOLVED identity
/// (`Grouped.term`), never a per-site AST rewrite. The projection stays
/// VERBATIM per arm: the empty set `()` builds a genuine grand-total aggregate
/// (`group` on `[]` = ONE row), and the NULL padding types through the existing
/// set-operation `merge` (a NULL arm constrains nothing, deferring to the arm
/// that groups on the column). HAVING is copied into every arm (ISO: it filters
/// each set's own groups); arms combine with `UNION ALL`, so a duplicate set
/// keeps its rows and the grand-total row is never deduplicated.
///
/// The query-level `ORDER BY` / `OFFSET`/`FETCH` / `DISTINCT` ride the outer
/// `Query.ordered` carrier over the union — a `setop` node carries no
/// order/distinct/limit slot. The carrier resolves those row operators through
/// the setop's OUTPUT SCOPE (`compile`/`run`), so an ORDER BY key that names an
/// output — an alias, a bare projected column, or an ordinal — orders on that
/// output the SAME way any `(SELECT … UNION SELECT …) ORDER BY <alias/ordinal>`
/// does, and a duplicate output name faults `SQLError.ambiguous` there, exactly
/// as a plain grouped query does. A generated `column N` display header is NOT
/// a bindable output name (the scope's names are the projected aliases-or-bare
/// columns), so `ORDER BY "column N"` faults `.column` as it does over any
/// derived union.
///
/// Only an ORDER BY key that re-expresses a value the setop-output scope cannot
/// recompute — a genuinely unprojected non-column EXPRESSION, the canonical
/// example an aggregate (`ORDER BY MAX(x)`) the select list does not project —
/// is MATERIALISED here as a HIDDEN trailing column in EVERY arm (so the `UNION
/// ALL` arity stays equal). A COLUMN key is NEVER materialised: it resolves at
/// the setop-output scope (a bare/aliased projected column to its output slot,
/// a qualified `n.A` ≡ the projected `A` by lowered identity) or faults there,
/// so the qualifier-presence defect that materialised `n.A` as a hidden column
/// is gone. The compiled carrier orders on the materialised ordinal and TRIMS
/// it through the identity projection; the carrier binds the hidden slot by
/// POSITION, never by the generated `*gsN` name a user output could spell.
internal func expand(_ select: Select,
                     sets: Array<Array<Expression>>) throws(SQLError) -> Query {
  // `GROUPING SETS ()` — an empty set LIST — has no arm to combine, so the
  // `UNION ALL` reduce below has no seed. The parser never emits it (the
  // grammar requires at least one set), but `Grouping.sets` is a public AST
  // case a caller may build directly, so reject the empty list here with a
  // syntax fault rather than letting the `arms[0]` seed trap.
  guard !sets.isEmpty else {
    throw .state("42601", "GROUPING SETS requires at least one set")
  }
  // The SUPERSET — every set's keys, flattened — threaded into each arm so an
  // absent key NULLs by resolved identity. Compared by lowered term in
  // `Grouped`, so a duplicate spelling here is harmless.
  let superset = sets.reduce(into: Array<Expression>()) { $0 += $1 }

  // The real projected items, as an explicit list. Both spellings the parser
  // emits for an enumerated projection reproject: an `expressions` list
  // verbatim, and a bare-column `columns` list lifted into `Projected`s (a
  // grouped `SELECT Region` is well-formed — Region is a grouping key). Only a
  // `*` (`all`) carries no explicit items and is left for the arm resolver to
  // diagnose (a grouped `SELECT *` is ill-formed).
  let items: Array<Projected> = switch select.projection {
  case let .expressions(list):
    list
  case let .columns(columns):
    columns.map { Projected(expression: .column($0)) }
  case .all:
    []
  }

  // The query-level ORDER BY keys MATERIALISED as hidden trailing columns — a
  // sort key the setop-output scope cannot recompute over the combined union.
  // A NON-column key (an aggregate `MAX(x)`, a computed key) the select list
  // does not project is materialised; a projected non-column expression
  // (`ORDER BY SUM(Qty)` where `SUM(Qty)` is a select-list item) resolves to
  // its output slot instead.
  //
  // A COLUMN key is materialised only when the setop-output scope cannot
  // resolve it — its BARE name is not a projected output. An UNQUALIFIED
  // column whose bare name IS a projected output (`SELECT Region … ORDER BY
  // Region`) binds that output by ISO output-alias precedence (a bare name →
  // a select-list alias), so it is NOT materialised. A QUALIFIED column,
  // though, references its INPUT column by identity, NOT a select alias: its
  // bare name colliding with a DIFFERENT output's alias (`SELECT Product AS
  // Region … ORDER BY s.Region`) must NOT be treated as that projected output
  // — the qualified key rides the carrier's `Grouped` resolver, which either
  // resolves it to the output it genuinely IS (rebinding to the real slot, no
  // effect) or, when it is a grouped-but-unprojected column, orders on this
  // hidden slot. An UNPROJECTED grouped column (`SELECT SUM(Qty) … GROUP BY
  // GROUPING SETS ((Region)) ORDER BY Region`) has no output slot but IS
  // orderable — the plain grouped path accepts it — so it materialises through
  // each arm's grouped projection: an arm grouped on the column carries its
  // value, and an arm that does NOT group on it is REJECTED by the arm's
  // grouped resolver with the SAME grouping fault the plain form raises (a
  // NON-grouped column faults identically). This is the aggregate case's
  // machinery extended to columns, not a fork — the arm's `Grouped` decides
  // grouped/non-grouped.
  let outputs = Set(items.compactMap { $0.name?.lowercased() })
  let hidden: Array<Expression> = (select.order?.keys ?? []).compactMap {
    key in
    guard case let .expression(expression) = key.sort else { return nil }
    guard !items.contains(where: { $0.expression == expression }) else {
      return nil
    }
    if case let .column(column) = expression, column.qualifier == nil,
        outputs.contains(column.name.lowercased()) {
      return nil
    }
    return expression
  }

  // Whether a carrier is needed at all: a query-level DISTINCT, ORDER BY, or
  // row limit has no slot on the `setop` node, so it rides the outer carrier.
  let carried =
      select.distinct || select.order != nil || select.limit != nil

  // Build one arm per set. When the carrier materialises hidden sort columns,
  // each arm APPENDS them (aliased to synthetic names) so they survive the
  // union at an equal arity across arms; without a carrier the projection is
  // verbatim.
  let names = hidden.indices.map { "*gs\($0)" }
  let arms = sets.map { set -> Query in
    let projection: Projection
    if case .all = select.projection {
      // A grouped `SELECT *` is ill-formed; keep the `.all` VERBATIM in every
      // arm (never the carrier) so the arm's grouped resolver throws the SAME
      // `SELECT *` fault the unwrapped form does.
      projection = select.projection
    } else if carried, !hidden.isEmpty {
      let extra = hidden.indices.map {
        Projected(expression: hidden[$0], alias: names[$0])
      }
      projection = .expressions(items + extra)
    } else {
      projection = select.projection
    }
    return .select(Select(projection: projection, from: select.from,
                          joins: select.joins, predicate: select.predicate,
                          grouping: .arm(keys: set, superset: superset),
                          having: select.having))
  }
  // `sets` is non-empty (the parser requires at least one set), so `union` is
  // set; combine with `UNION ALL` so no arm's rows are deduplicated.
  let union = arms.dropFirst().reduce(arms[0]) {
    .setop(.union, $0, $1, all: true)
  }
  // A grouped `SELECT *` is ill-formed: return the bare union of the `.all`
  // arms (never the carrier, whose hidden trimming assumes real output items
  // the `.all` arms do not enumerate) so the arm's grouped resolver throws the
  // SAME `SELECT *` fault the unwrapped form does, carried or not.
  if case .all = select.projection { return union }
  // A SINGLE grouping set is an ordinary `GROUP BY` — there is no `UNION` for
  // an unprojected sort key to survive, so materialise NO hidden column and
  // add NO `ordered` carrier. Wrapping the lone `.select` arm in `.ordered`
  // would hide a FROM-clause derived table from the query-level derived-table
  // collection and per-arm execution, faulting `.relation` at run. Re-attach
  // the query-level clauses to the single grouped arm and return it plain, so
  // the ordinary `SELECT` path materialises its derived tables.
  if sets.count == 1 {
    return .select(Select(distinct: select.distinct,
                          projection: select.projection, from: select.from,
                          joins: select.joins, predicate: select.predicate,
                          grouping: .arm(keys: sets[0], superset: superset),
                          having: select.having, order: select.order,
                          limit: select.limit))
  }
  guard carried else { return union }
  // The query-level row operators ride the `ordered` carrier over the union.
  // `compile`/`run` resolve them through the setop-output scope; the hidden
  // materialised columns (if any) trail every arm at equal arity and the
  // carrier trims them through its identity projection. `generated` carries
  // their STRUCTURAL count out of here — the carrier recovers the real width
  // as `width − generated`, never by scanning output names for a `*gs` prefix.
  return .ordered(union, distinct: select.distinct, order: select.order,
                  limit: select.limit, generated: hidden.count)
}
