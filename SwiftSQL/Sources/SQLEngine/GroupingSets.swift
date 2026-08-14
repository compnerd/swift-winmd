// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - GROUPING SETS

extension Query {
  /// Whether this query is a windowed `GROUP BY GROUPING SETS` select — a
  /// window function over a grouping-sets query. `expanded` does not desugar
  /// such a select to its `UNION ALL` (the window must ride above the arm
  /// union, not inside each arm), so it keeps a `.select` body while its result
  /// is the arm union; the compile lowers it directly (`windowed(sets:)`) and
  /// the run routes it through the carrier-aware executor over that union.
  ///
  /// The predicate matches the compile gate (`compile(_ select:)`), so the two
  /// recognise the same shape. A multi-set spelling's FROM/JOIN derived tables
  /// are arm-scoped, not query-scoped: `augment` binds their schema but not
  /// their rows (a stateful source must not fire once at the query level and be
  /// reused by both arms), the arms materialising the rows per arm — as a
  /// `.setop` body's arms already do. A single-set spelling has no such arm
  /// union (see `unioned`), so it is not arm-scoped: it materialises and
  /// runs through the ordinary per-query path.
  internal var windowing: Bool {
    guard case let .select(select) = body, select.windows,
        case .sets = select.grouping else { return false }
    return true
  }

  /// Whether a `windowing` select's arm union is a genuine set operation —
  /// two or more grouping sets, so `expand` (which `decompose` drives) reduces
  /// it to a `.setop`. A single set — a non-empty `((x))` or the grand total
  /// `(())` — reduces to one plain grouped `.select`, not a `.setop`: there is
  /// no union, one arm.
  ///
  /// The per-arm carrier path assumes that setop — its `.window` descent
  /// carries the union to the setop leaf and per-arm augments each arm's
  /// derived layer, which the schema-only `augment` deferred. A single arm has
  /// nothing to carry and no per-arm augment, so it runs the ordinary per-query
  /// path: `augment` materialises its derived rows once (one arm, so per-arm
  /// and per-query coincide) and the ordinary executor reads them. Both the
  /// `augment` schema-only bind and the `run` carrier routing fork on this one
  /// predicate, so the single-arm shape is decided at the same point as the
  /// multi-arm and a future routing change cannot silently miss it. The
  /// predicate agrees with the decomposed union's body: `sets.count > 1` iff
  /// `decompose(windowed:sets:).union` is a `.setop` (both driven by `expand`).
  internal var unioned: Bool {
    guard windowing, case let .select(select) = body,
        case let .sets(sets) = select.grouping else { return false }
    return sets.count > 1
  }

  /// The hidden arm union a windowed `GROUP BY GROUPING SETS` select must
  /// execute carrier-aware over — the `.setop` `decompose` splits off the
  /// `.select` body — or `nil` when this query carries no such union and runs
  /// through the ordinary per-query executor. A `unioned` select keeps a
  /// `.select` body while its result is the arm union, so a `.setop`-only union
  /// check misses it; every executor entry point (`run`, the view `derive`, the
  /// correlated `executed`) instead consults this one decision, routing a
  /// non-`nil` result through `execute(_:carrying:)` over a `revealed()`
  /// context — the schema-only `augment` deferred each arm's derived layer, and
  /// `revealed` drops that layer so each arm re-materialises it. Sharing the
  /// decision keeps a future entry point from open-coding a `.setop`-only
  /// recognition that silently scans the schema-only source once.
  internal func union(windowed routines: Routines) throws(SQLError) -> Query? {
    guard unioned, case let .select(select) = body,
        case let .sets(sets) = select.grouping else { return nil }
    return try decompose(windowed: select, sets: sets, routines).union
  }

  /// This query with each top-level `GROUP BY GROUPING SETS` select replaced by
  /// its `UNION ALL` expansion — applied once at every pipeline entry (`run`,
  /// `compile`, `columns(of:)`), so the whole downstream (materialise, augment,
  /// executor) sees the expanded AST and a run and a `columns(of:)` derive
  /// cannot diverge.
  ///
  /// It rewrites the query's own selects (a bare select and each set-operation
  /// arm), NOT the derived tables or subqueries nested within — those re-enter
  /// these same entries (`materialise`/`resolved` run and derive an inner body,
  /// `cell` runs a scalar subquery), where they are expanded in turn — so one
  /// shallow pass at each entry covers arbitrary nesting.
  internal var expanded: Query {
    get throws(SQLError) {
      // A carrier is transparent to the expansion — its row operators add no
      // grouping — so expand the body and carry the stack through unchanged. A
      // grouping-sets body is produced afresh by `expand` (whose own carrier,
      // if any, sits innermost, beneath this query's carriers); a `setop` body
      // recurses into its arms.
      switch body {
      case let .select(select):
        // Inline every `OVER w` named-window reference to its `WINDOW` clause
        // definition first — the resolution prelude, run before any structural
        // walk — so a named window and the equivalent inline `OVER (…)` resolve
        // identically on the run and validate paths (both enter `expanded`).
        let select = try select.inlined
        if case let .sets(sets) = select.grouping {
          // A window over a `GROUPING SETS` query sees the whole result set —
          // the union of every set's rows (ISO 9075) — not one arm's grouped
          // rows, so the window layer rides above the union rather than inside
          // an arm. A windowed grouping-sets select is not desugared here: it
          // is lowered directly at compile — the window node placed above the
          // arm union's `setop` plan, over the union-output scope (`compile(_
          // select:)`) — so no derived-table boundary drops its context. The
          // inlined select rides through unchanged for that direct lowering
          // (and the schema-derive/typecheck twins), while a non-windowed one
          // desugars to its `UNION ALL` here as before.
          if select.windows {
            return Query(body: .select(select), carriers: carriers)
          }
          let expanded = try expand(select, sets: sets)
          return Query(body: expanded.body,
                       carriers: expanded.carriers + carriers)
        }
        return Query(body: .select(select), carriers: carriers)
      case let .setop(kind, left, right, all):
        return Query(body: .setop(kind, try left.expanded,
                                  try right.expanded, all: all),
                     carriers: carriers)
      case .values:
        // A `VALUES` body carries no grouping to expand.
        return self
      }
    }
  }
}

/// Expands a `GROUP BY GROUPING SETS (s1, …, sn)` `select` into a `UNION ALL`
/// of one grouped ARM per set — the single shared expansion the compile path
/// (`compile(_ select:)`) and the schema path (`columns(unifying:)`) both
/// drive, so a run and a `columns(of:)` derive cannot diverge.
///
/// Each arm is the original select grouped on one set's `keys` while carrying
/// the superset (the union of every set's keys) in its `.arm` grouping — so a
/// projected/HAVING reference to a grouping column another set groups on but
/// this arm's set omits lowers to a super-aggregate NULL by resolved identity
/// (`Grouped.term`), never a per-site AST rewrite. The projection stays
/// verbatim per arm: the empty set `()` builds a genuine grand-total aggregate
/// (`group` on `[]` = one row), and the NULL padding types through the existing
/// set-operation `merge` (a NULL arm constrains nothing, deferring to the arm
/// that groups on the column). HAVING is copied into every arm (ISO: it filters
/// each set's own groups); arms combine with `UNION ALL`, so a duplicate set
/// keeps its rows and the grand-total row is never deduplicated. The `WINDOW`
/// clause is copied into every arm too, so the arm compile validates each named
/// definition against the grouped source — an unused definition faulting a
/// context-free error (an undefined ORDER BY column) on both paths, as the
/// ordinary aggregate form does, rather than being dropped unvalidated.
///
/// The query-level `ORDER BY` / `OFFSET`/`FETCH` / `DISTINCT` ride the outer
/// `Query.ordered` carrier over the union — a `setop` node carries no
/// order/distinct/limit slot. The carrier resolves those row operators through
/// the setop's output scope (`compile`/`run`), so an ORDER BY key that names an
/// output — an alias, a bare projected column, or an ordinal — orders on that
/// output the same way any `(SELECT … UNION SELECT …) ORDER BY <alias/ordinal>`
/// does, and a duplicate output name faults `SQLError.ambiguous` there, exactly
/// as a plain grouped query does. A generated `column N` display header is NOT
/// a bindable output name (the scope's names are the projected aliases-or-bare
/// columns), so `ORDER BY "column N"` faults `.column` as it does over any
/// derived union.
///
/// Only an ORDER BY key that re-expresses a value the setop-output scope cannot
/// recompute — a genuinely unprojected non-column expression, the canonical
/// example an aggregate (`ORDER BY MAX(x)`) the select list does not project —
/// is materialised here as a hidden trailing column in every arm (so the `UNION
/// ALL` arity stays equal). A COLUMN key is never materialised: it resolves at
/// the setop-output scope (a bare/aliased projected column to its output slot,
/// a qualified `n.A` ≡ the projected `A` by lowered identity) or faults there,
/// so the qualifier-presence defect that materialised `n.A` as a hidden column
/// is gone. The compiled carrier orders on the materialised ordinal and trims
/// it through the identity projection; the carrier binds the hidden slot by
/// POSITION, never by the generated `*gsN` name a user output could spell.
internal func expand(_ select: Select,
                     sets: Array<Array<Expression>>) throws(SQLError) -> Query {
  // `GROUPING SETS ()` — an empty set list — has no arm to combine, so the
  // `UNION ALL` reduce below has no seed. The parser never emits it (the
  // grammar requires at least one set), but `Grouping.sets` is a public AST
  // case a caller may build directly, so reject the empty list here with a
  // syntax fault rather than letting the `arms[0]` seed trap.
  guard !sets.isEmpty else {
    throw .state("42601", "GROUPING SETS requires at least one set")
  }
  // The superset — every set's keys, flattened — threaded into each arm so an
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

  // The query-level ORDER BY keys materialised as hidden trailing columns — a
  // sort key the setop-output scope cannot recompute over the combined union.
  // A non-column key (an aggregate `MAX(x)`, a computed key) the select list
  // does not project is materialised; a projected non-column expression
  // (`ORDER BY SUM(Qty)` where `SUM(Qty)` is a select-list item) resolves to
  // its output slot instead.
  //
  // A COLUMN key is materialised only when the setop-output scope cannot
  // resolve it — its bare name is not a projected output. An unqualified
  // column whose bare name IS a projected output (`SELECT Region … ORDER BY
  // Region`) binds that output by ISO output-alias precedence (a bare name →
  // a select-list alias), so it is NOT materialised. A qualified column,
  // though, references its input column by identity, NOT a select alias: its
  // bare name colliding with a different output's alias (`SELECT Product AS
  // Region … ORDER BY s.Region`) must NOT be treated as that projected output
  // — the qualified key rides the carrier's `Grouped` resolver, which either
  // resolves it to the output it genuinely IS (rebinding to the real slot, no
  // effect) or, when it is a grouped-but-unprojected column, orders on this
  // hidden slot. An unprojected grouped column (`SELECT SUM(Qty) … GROUP BY
  // GROUPING SETS ((Region)) ORDER BY Region`) has no output slot but IS
  // orderable — the plain grouped path accepts it — so it materialises through
  // each arm's grouped projection: an arm grouped on the column carries its
  // value, and an arm that does NOT group on it is rejected by the arm's
  // grouped resolver with the same grouping fault the plain form raises (a
  // non-grouped column faults identically). This is the aggregate case's
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
  // each arm appends them (aliased to synthetic names) so they survive the
  // union at an equal arity across arms; without a carrier the projection is
  // verbatim.
  let names = hidden.indices.map { "*gs\($0)" }
  let arms = sets.map { set -> Query in
    let projection: Projection
    if case .all = select.projection {
      // A grouped `SELECT *` is ill-formed; keep the `.all` verbatim in every
      // arm (never the carrier) so the arm's grouped resolver throws the same
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
                          having: select.having, window: select.window))
  }
  // `sets` is non-empty (the parser requires at least one set), so `union` is
  // set; combine with `UNION ALL` so no arm's rows are deduplicated.
  let union = arms.dropFirst().reduce(arms[0]) {
    .setop(.union, $0, $1, all: true)
  }
  // A grouped `SELECT *` is ill-formed: return the bare union of the `.all`
  // arms (never the carrier, whose hidden trimming assumes real output items
  // the `.all` arms do not enumerate) so the arm's grouped resolver throws the
  // same `SELECT *` fault the unwrapped form does, carried or not.
  if case .all = select.projection { return union }
  // A single grouping set is an ordinary `GROUP BY` — there is no `UNION` for
  // an unprojected sort key to survive, so materialise no hidden column and
  // add no `ordered` carrier. Wrapping the lone `.select` arm in `.ordered`
  // would hide a FROM-clause derived table from the query-level derived-table
  // collection and per-arm execution, faulting `.relation` at run. Re-attach
  // the query-level clauses to the single grouped arm and return it plain, so
  // the ordinary `SELECT` path materialises its derived tables. The `WINDOW`
  // clause rides onto the arm as it does for the multi-set union, so the arm
  // compile validates every named definition against the grouped source — an
  // unused `WINDOW bad AS (ORDER BY nonesuch)` still faults its undefined
  // column, as the multi-set and ordinary grouped forms do, rather than being
  // dropped unvalidated on a single-set query.
  if sets.count == 1 {
    return .select(Select(distinct: select.distinct,
                          projection: select.projection, from: select.from,
                          joins: select.joins, predicate: select.predicate,
                          grouping: .arm(keys: sets[0], superset: superset),
                          having: select.having, window: select.window,
                          order: select.order, limit: select.limit))
  }
  guard carried else { return union }
  // The query-level row operators ride the `ordered` carrier over the union.
  // `compile`/`run` resolve them through the setop-output scope; the hidden
  // materialised columns (if any) trail every arm at equal arity and the
  // carrier trims them through its identity projection. `generated` carries
  // their structural count out of here — the carrier recovers the real width
  // as `width − generated`, never by scanning output names for a `*gs` prefix.
  return .ordered(union, distinct: select.distinct, order: select.order,
                  limit: select.limit, generated: hidden.count)
}

// MARK: - Window over GROUPING SETS

/// The decomposition of a windowed `GROUP BY GROUPING SETS` `select` into the
/// two halves the direct lowering composes — the window-free arm `union` and
/// the outer window layer's `projection` and `order` over it. It is not an AST
/// rewrite to a derived table: the compile seam (`compile(_ select:)`) compiles
/// the `union` to a `setop` plan, builds the union-output `Scope`, and drives
/// the shared window machinery over it, placing a `window` node above the arm
/// union with no derived-table boundary to drop context; the schema-derive and
/// type-check twins reuse the same decomposition, so a run and a `columns(of:)`
/// derive cannot diverge.
internal struct WindowedSets {
  /// The original projected items (verbatim), from which the direct lowering's
  /// schema twin names each output — an alias, else a bare column's name, else
  /// the positional `column N` synthesized header — and marks an unnamed one
  /// synthesized, preserving its provenance across the boundary-free lowering.
  internal let items: Array<Projected>

  /// The outer window layer's projection — each original item with every
  /// group-dependent subexpression lifted to a synthetic `*gwN` reference of
  /// the union output, each group-independent scalar (`tick()`, `1 / 0`) kept
  /// outer, a window kept with its operands lifted. Each item carries the
  /// original item's inferable output name as its alias (`nil` for an unnamed
  /// one), so a query `ORDER BY` names a window alias while an unnamed output
  /// stays a synthesized header, never the internal `*gwN` name.
  internal let projection: Array<Projected>

  /// The outer window layer's query-level `ORDER BY`, each key lifted to read
  /// the union output — an ordinal or a bare name of a projected output left
  /// verbatim (it orders on that output), any other key's expression lifted.
  internal let order: Order?

  /// The inner window-free `UNION ALL` of arms — the `expand` of a synthetic
  /// grouping-sets select projecting the lifted `*gwN` operands, the rest of
  /// the query verbatim. It carries the original `WINDOW` clause onto its arms,
  /// so each arm validates every named definition against the grouped source.
  internal let union: Query
}

/// Decomposes a `GROUP BY GROUPING SETS` `select` that also projects (or orders
/// by) a window function into the window-free arm union and the outer window
/// layer over it — the two halves the direct lowering composes, without any
/// derived-table boundary.
///
/// A window over a grouping-sets query must see the whole result set: the union
/// of every set's rows, the per-set grouped rows and the NULL-extended
/// super-aggregate rows alike (ISO 9075). The ordinary `expand` would push a
/// window into each arm, so it would see only that arm's grouped rows. The
/// decomposition instead separates:
///
///   - the inner window-free `expand` union of arms, whose projection is
///     exactly the operands the windows and the surviving projection reference
///     — each maximal window-free subexpression (a group key, an aggregate, a
///     `GROUPING(…)`, or a scalar over them) lifted to a synthetic `*gwN`
///     column, so every arm computes those values in its own grouped scope and
///     the union carries one row per group across every set. The original
///     `WINDOW` clause rides onto the union arms so the arm compile validates
///     every named definition against the grouped source before dropping it —
///     an unused `WINDOW bad AS (ORDER BY nonesuch)` still faults its undefined
///     column, as the ordinary and non-windowed aggregate forms do;
///
///   - the outer window layer: the original projection and `ORDER BY` with
///     every group-dependent subexpression rewritten to its `*gwN` reference of
///     the union output and every group-independent scalar (`tick()`, `1 / 0`)
///     kept outer. Each window's `PARTITION BY`/`ORDER BY`/argument now reads a
///     computed column of the union — a `SUM(x)` a window orders by is already
///     materialised, the window reads it and does not re-aggregate — so the
///     window computes over the full result set. A projection-only group-
///     independent scalar stays above the window and the query-level cap,
///     evaluated after the window as the ordinary grouped-window path evaluates
///     its projection, so the single-set spelling observes the same values the
///     ordinary `GROUP BY` form does (#137).
///
/// The lifted `*gwN` references are unqualified: the compile seam builds the
/// union-output `Scope` keyed by the empty alias (as the `ordered` set-op
/// carrier does), so a bare `*gwN` resolves against that scope's columns rather
/// than a derived-table qualifier. The compile seam compiles the union in the
/// enclosing context, so a correlated arm reference (an enclosing LATERAL
/// `T.Id`) resolves natively — no `VALUES (1)` unit or LATERAL apply is needed.
///
/// The rewrite is one uniform substitution walk (`Lift.substitute`): each
/// maximal grounded atom the union scope cannot compute — a bare `.aggregate`,
/// a `.grouping(…)`, or a group column — lifts to a `*gwN` arm column, while
/// every other node (a literal, a group-independent scalar, an arithmetic/
/// `CAST`/`COALESCE`/`NULLIF`, a `CASE`'s structure, a window function's
/// operands) stays outer with its operands recursed. The residual then flows to
/// the same `Windowed`/`materialise`/`shaped` machinery the plain window path
/// drives, so its placement is inherited, not re-implemented: a projection-only
/// scalar and a grounded `CASE`'s structure sit above the query-level cap
/// (`Project(Limit(Sort))`), so a dropped page never evaluates them (#137); a
/// `LEAD`/`LAG` default stays a lazily evaluated operand; and a window reads
/// its `*gwN` arm slots as the plain path reads its materialised source cells.
/// A lifted atom is shared to one `*gwN` column only when deterministic under
/// `routines` (a group key, an aggregate over steady parts), so a `SUM(x)` a
/// window orders by and the projection also yields is one column; a non-
/// deterministic one (`SUM(tick())`) takes a fresh column per occurrence. The
/// exception is a projected output a window ordinal links to (`ORDER BY 1`):
/// the ordinal ties the key to that output, so the output lifts to the arm
/// whole, shared with the key — one evaluation, the window ordering by the
/// reported column.
///
/// A scalar subquery uncorrelated to this query is hosted in the outer layer
/// through the union-scope `Resolution` (kept verbatim so a `LEAD` default or a
/// `CASE` branch nesting it stays lazy), while one correlated to a group key
/// stays arm-lifted, where the arm's grouped scope binds the correlation.
///
/// A window `FILTER` and a windowed `CASE` are the two operand shapes not
/// lowered here — each carries a `Predicate` a `*gwN` column cannot stand in
/// for — so each faults the feature diagnostic on both paths, in parity,
/// rather than resolving a base column the union scope cannot see.
internal func decompose(windowed select: Select,
                        sets: Array<Array<Expression>>,
                        _ routines: Routines) throws(SQLError) -> WindowedSets {
  // `GROUPING SETS ()` has no arm to union — rejected here as in `expand`, so a
  // directly built empty set list faults a syntax error rather than trapping.
  guard !sets.isEmpty else {
    throw .state("42601", "GROUPING SETS requires at least one set")
  }
  // A grouped `SELECT *` is ill-formed (the window then lives in `ORDER BY`);
  // reject it with the same fault the grouped projection resolver raises, so a
  // windowed `SELECT * … GROUP BY GROUPING SETS` faults identically to the
  // unwrapped grouped form, on both paths.
  if case .all = select.projection {
    throw .state("0A000",
                 "SELECT * is not allowed with GROUP BY or aggregates")
  }

  // The real projected items, as an explicit list — an `expressions` list
  // verbatim, a bare-column `columns` list lifted into `Projected`s.
  let items: Array<Projected> = switch select.projection {
  case let .expressions(list):
    list
  case let .columns(columns):
    columns.map { Projected(expression: .column($0)) }
  case .all:
    []
  }

  // The projected outputs a window `ORDER BY` ordinal links to (`Order.Key
  // .output`, stamped by the prelude's `resolving(ordinals:)`). Such an output
  // and every window key naming it must read one `*gwN` leaf — the operand
  // evaluated once, the window ordering by the reported value — even when it is
  // non-deterministic, mirroring how `materialise` shares an ordinal value
  // on the ordinary path. A window `ORDER BY` names only a window-free output
  // (`resolving(ordinals:)` rejects a window output), so a linked output lifts
  // to a single leaf the key can share.
  let targets = ordinals(of: items, select.order)
  // The bare names of the group-key columns — the columns a correlated subquery
  // may reference (ISO restricts a grouped correlation to a grouping column).
  // The lifter reads them to route a subquery: one naming a group key is
  // correlated to this query and stays arm-lifted, resolved in the arm's
  // grouped scope; one naming none is uncorrelated and hosted in the outer
  // layer through the union-scope `Resolution`.
  var keys = Set<String>()
  for set in sets {
    for key in set { key.collect(columns: &keys) }
  }
  // Lift the projection and the query-level ORDER BY over the union output,
  // gathering the operands each references into `lift.leaves`. Each outer item
  // carries the original item's inferable output name as its alias (`nil` for
  // an unnamed one) — a bare group column stays named, an aliased value keeps
  // its alias — so a query `ORDER BY` may name a window alias, while an unnamed
  // output takes no `*gwN` name and stays a synthesized `column N` header (the
  // schema twin names it from `items`).
  var lift = Lift(routines, keys: keys)
  var projection = Array<Projected>()
  projection.reserveCapacity(items.count)
  for index in items.indices {
    // An output a window `ORDER BY` ordinal links to lifts through the ordinal
    // channel keyed by its index, so the window key naming it (earlier or
    // later in the list) shares the same leaf — one evaluation, the window
    // ordering by the reported value; that output is a window operand via the
    // link, so it lifts to the arm whole even when group-independent. Every
    // other output takes the uniform substitution walk (`substitute`): each
    // grounded atom it references lifts to a `*gwN` arm column, its literals
    // and group-independent scalars kept outer, evaluated after the window.
    let lifted: Expression
    if targets.contains(index) {
      lifted = lift.lift(items[index].expression, output: index)
    } else {
      lifted = try lift.substitute(items[index].expression)
    }
    projection.append(Projected(expression: lifted, alias: items[index].name))
  }
  // The projected output names — a bare unqualified ORDER BY key naming one
  // orders on that output (ISO output-alias precedence), so it is left to
  // resolve against the outer projection rather than lifted to a `*gwN`
  // reference.
  let outputs = Set(items.compactMap { $0.name?.lowercased() })
  let order: Order? = if let clause = select.order {
    try Order(keys: clause.keys.map { key throws(SQLError) in
      switch key.sort {
      case .ordinal:
        // A query-level ordinal names an outer projected column by position —
        // preserved verbatim, resolved against the outer select's projection.
        return key
      case let .expression(expression):
        if case let .column(column) = expression, column.qualifier == nil,
            outputs.contains(column.name.lowercased()) {
          return key
        }
        var lifted =
            try Order.Key(sort: .expression(lift.substitute(expression)),
                          ascending: key.ascending)
        lifted.output = key.output
        return lifted
      }
    })
  } else {
    nil
  }

  // Build the inner union of window-free arms — the `expand` of a synthetic
  // grouping-sets select projecting the lifted operands (aliased `*gwN`), the
  // rest of the query verbatim. With no query-level operators the union carries
  // no `ordered` wrapper, so the union is a bare `UNION ALL` (or the lone
  // grouped select of a single set). When nothing is lifted (a bare
  // `ROW_NUMBER() OVER ()`), a constant seeds one column so each arm still
  // yields one row per group.
  //
  // The original `WINDOW` clause rides onto the inner select so `expand`
  // threads it into each arm, where the arm's `front` validates every
  // definition against the original grouped scope before dropping it — the used
  // windows the prelude already inlined and lifted to the outer, so a carried
  // definition is unused and validated only. Without it a context-free error in
  // an unused definition (`WINDOW bad AS (ORDER BY nonesuch)`) would be quietly
  // accepted here, unlike the ordinary and non-windowed aggregate forms.
  let leaves = lift.leaves
  let names = (0..<max(1, leaves.count)).map { "*gw\($0)" }
  let projected: Array<Projected> = leaves.isEmpty
      ? [Projected(expression: .literal(.integer(1)), alias: names[0])]
      : leaves.indices.map {
          Projected(expression: leaves[$0], alias: names[$0])
        }
  let inner = Select(projection: .expressions(projected), from: select.from,
                     joins: select.joins, predicate: select.predicate,
                     grouping: .sets(sets), having: select.having,
                     window: select.window)
  let union = try expand(inner, sets: sets)

  return WindowedSets(items: items, projection: projection, order: order,
                      union: union)
}

/// The 0-based outputs a window `ORDER BY` ordinal links to across the `items`
/// projection and the query-level `order` — the provenance the prelude
/// (`WindowSpec.resolving(ordinals:)`) stamped on each window sort key it
/// substituted for an output ordinal. A window naming an output pins its rank
/// to that output's value, so the lifter shares one `*gwN` leaf between the
/// output and every key that names it. A window `ORDER BY` names only a window-
/// free output, so a linked output is always a single-leaf value.
private func ordinals(of items: Array<Projected>, _ order: Order?) -> Set<Int> {
  var windows = Array<Expression>()
  for item in items { item.expression.collect(windows: &windows) }
  for key in order?.keys ?? [] {
    if case let .expression(expression) = key.sort {
      expression.collect(windows: &windows)
    }
  }
  var outputs = Set<Int>()
  for expression in windows {
    guard case let .window(_, spec) = expression, let order = spec.order
    else { continue }
    for key in order.keys {
      if let output = key.output { outputs.insert(output) }
    }
  }
  return outputs
}

/// The substitution walk that rewrites a windowed grouping-sets query's outer
/// expressions over the arm union output, gathering the grounded atoms to push
/// into the arms.
///
/// Every outer expression — a projected item, a query-`ORDER BY` key, a window
/// operand — is rewritten by one uniform walk (`substitute`): each maximal
/// grounded atom the union-output scope cannot compute — a bare `.aggregate`, a
/// `.grouping(…)`, or a group column — is replaced by a reference to its
/// synthetic `*gwN` union column (deduplicated by determinism), while every
/// other node is kept in the outer with its operands recursed — a literal, a
/// pure or stateful scalar over literals (`tick()`, `1 / 0`), an arithmetic/
/// `CAST`/`COALESCE`/`NULLIF`, a `CASE`'s guards and branches, and a window
/// function's operands, a `LEAD`/`LAG` default included.
///
/// The residual (structure-preserved, leaf-substituted) expression then flows
/// to the same `Windowed`/`materialise`/`shaped` machinery the plain window
/// path drives, so its placement is inherited rather than re-implemented here:
/// a group-independent scalar and a grounded `CASE`'s structure sit in the
/// outer projection above the query-level cap (`Project(Limit(Sort))`), so a
/// dropped page never evaluates them (#137); a `LEAD`/`LAG` default stays a
/// lazily evaluated operand the executor reaches only for an out-of-range
/// target; and a window reads its `*gwN` arm slots as the plain path reads its
/// materialised source cells.
///
/// `scope.term` faults a bare `.aggregate`/`.grouping` (42803) and cannot
/// resolve a base column against the `*gwN`-only union scope, so those atoms
/// must be pre-projected by the arms and substituted; every other node the
/// ordinary machinery resolves against the union scope directly. A scalar
/// `.subquery` is pushed to an arm too — the outer layer hosts it via the
/// union-scope `Resolution` `windowed(sets:)` passes, so a `.subquery` left
/// outer resolves against it.
///
/// A window `FILTER` and a windowed `CASE` are the two shapes not lowered here
/// — each carries a `Predicate` a `*gwN` column cannot stand in for — so each
/// faults the feature diagnostic on both paths, in parity (#136).
private struct Lift {
  /// The routines a lifted operand's determinism is judged against, deciding
  /// whether two occurrences share one `*gwN` column.
  private let routines: Routines

  /// The bare names of the group-key columns — the columns a correlated
  /// subquery may reference. A subquery naming one is correlated to this query
  /// and arm-lifted; one naming none is uncorrelated and hosted outer.
  private let keys: Set<String>

  /// The grounded atoms pushed into the arms, in first-appearance order — arm
  /// column `*gwN` is `leaves[N]`.
  private(set) var leaves = Array<Expression>()

  /// The `leaves` position each deterministic pushed atom occupies, so an atom
  /// written twice (a `SUM(x)` a window orders by that the projection also
  /// yields) is one column. A non-deterministic atom is never recorded here, so
  /// each occurrence takes a fresh column.
  private var index = Dictionary<Expression, Int>()

  /// The `leaves` position each ordinal-linked projected output occupies, keyed
  /// by its 0-based output. A projected output a window `ORDER BY` ordinal
  /// names and every window key carrying that output's provenance route through
  /// it, so both read one column even when the operand is non-deterministic —
  /// the value evaluated once, the window ordering by the reported column — the
  /// explicit provenance a determinism test cannot supply. Keyed by output, not
  /// expression, so two ordinals naming distinct outputs that hold an equal
  /// stateful value stay independent, exactly as `materialise` keys its hoist.
  private var linked = Dictionary<Int, Int>()

  fileprivate init(_ routines: Routines, keys: Set<String>) {
    self.routines = routines
    self.keys = keys
  }

  /// Registers `expression` as a column and returns its `leaves` position —
  /// a deterministic atom folded onto its first occurrence (one shared column),
  /// a non-deterministic one taking a fresh position each call.
  private mutating func allocate(_ expression: Expression) -> Int {
    let steady = expression.steady(routines)
    if steady, let existing = index[expression] { return existing }
    let position = leaves.count
    if steady { index[expression] = position }
    leaves.append(expression)
    return position
  }

  /// The `*gwN` union reference for `expression`, registering it as an arm
  /// column on first sight. A deterministic atom reuses its position after (one
  /// shared column), while a non-deterministic one (`SUM(tick())`) takes a
  /// fresh column per occurrence, so each site evaluates it independently. The
  /// reference is unqualified — the compile seam builds the union-output scope
  /// keyed by the empty alias, so a bare `*gwN` resolves against it by name,
  /// with no derived-table qualifier to match.
  private mutating func reference(_ expression: Expression) -> Expression {
    .column(Column(name: "*gw\(allocate(expression))"))
  }

  /// The `*gwN` union reference for a projected `output` a window `ORDER BY`
  /// ordinal links to, keyed by the 0-based `output`. The projected output and
  /// every window key carrying that output's provenance route here, so all read
  /// one leaf — the operand evaluated once, the window ordering by the reported
  /// value — even when it is non-deterministic (a `tick()`), matching how
  /// `materialise` shares an ordinal-named value on the ordinary path. A
  /// deterministic operand still folds through the shared `index` memo, so an
  /// unlinked occurrence reuses it too; a directly written key (no `output`)
  /// never routes here and stays an independent evaluation (#135).
  private mutating func reference(_ expression: Expression, output: Int)
      -> Expression {
    if let existing = linked[output] {
      return .column(Column(name: "*gw\(existing)"))
    }
    let position = allocate(expression)
    linked[output] = position
    return .column(Column(name: "*gw\(position)"))
  }

  /// This expression lifted as the projected output a window `ORDER BY` ordinal
  /// links to — a window-free subexpression pushed to the `*gwN` arm column
  /// keyed by `output`, shared with every window key naming the same output. A
  /// bare literal needs no column (a constant reads the same twice) and stays
  /// inline. The output is window-free by construction — the prelude rejects a
  /// window as an ordinal's target — so this never meets a window operand.
  fileprivate mutating func lift(_ expression: Expression, output: Int)
      -> Expression {
    if case .literal = expression { return expression }
    return reference(expression, output: output)
  }

  /// This outer expression rewritten over the arm union by the uniform
  /// substitution walk — each maximal grounded atom the union scope cannot
  /// compute (an aggregate, a `GROUPING(…)`, a group column, or a scalar
  /// subquery the outer layer hosts through the union-scope `Resolution`)
  /// replaced by its `*gwN` reference, every other node kept in the outer with
  /// its operands recursed.
  ///
  /// A literal and a group-independent scalar (`tick()`, `1 / 0`) stay outer
  /// verbatim (their operands hold no grounded atom); an arithmetic, `CAST`,
  /// `COALESCE`, `NULLIF`, or `CASE` keeps its structure and recurses its
  /// operands and guards; a window keeps its function and specification with
  /// their operands recursed. The residual flows to the ordinary `Windowed`
  /// machinery, which places it exactly as the plain window path places its
  /// own — the outer projection above the cap, a `LEAD`/`LAG` default lazily.
  fileprivate mutating func substitute(_ expression: Expression)
      throws(SQLError) -> Expression {
    switch expression {
    case .aggregate, .grouping, .column:
      // A grounded atom the union scope cannot compute — an aggregate, a
      // GROUPING bit-vector, or a group column — becomes its deduplicated
      // `*gwN` reference, computed in the arm's grouped scope.
      return reference(expression)
    case let .subquery(query):
      // A subquery uncorrelated to this query is hosted in the outer layer
      // through the union-scope `Resolution` — kept verbatim so a `LEAD`
      // default or a `CASE` branch nesting it stays lazy, evaluated only when
      // reached — while one correlated to a group key stays arm-lifted (a
      // `*gwN` reference) where the arm's grouped scope binds the correlation.
      // Arm-lifting is always value-correct, so over-approximating the
      // correlation only forgoes the lazy outer host, never mis-hosts a
      // correlated subquery.
      var referenced = Set<String>()
      query.collect(columns: &referenced)
      return referenced.isDisjoint(with: keys)
          ? expression : reference(expression)
    case .literal:
      return expression
    case let .call(name, arguments):
      return try .call(name: name, arguments: substitute(arguments))
    case let .binary(operation, lhs, rhs):
      return try .binary(operation, substitute(lhs), substitute(rhs))
    case let .cast(operand, type):
      return try .cast(substitute(operand), type)
    case let .coalesce(arguments):
      return try .coalesce(substitute(arguments))
    case let .nullif(lhs, rhs):
      return try .nullif(substitute(lhs), substitute(rhs))
    case let .case(whens, otherwise):
      // A CASE nesting a window carries a per-row Predicate/window shape no
      // `*gwN` column stands in for (#136), so defer it; a window-free CASE
      // keeps its structure outer, its guards and branches recursed so only
      // their grounded atoms lift to arm columns.
      let windowed = whens.contains { $0.when.windowed || $0.then.windowed }
          || (otherwise?.windowed ?? false)
      if windowed {
        throw .state("0A000", "a window in a CASE with GROUPING SETS is not " +
                              "yet supported")
      }
      var branches = Array<When>()
      branches.reserveCapacity(whens.count)
      for when in whens {
        branches.append(try When(when: substitute(when.when),
                                 then: substitute(when.then)))
      }
      let fallback: Expression?
      if let otherwise {
        fallback = try substitute(otherwise)
      } else {
        fallback = nil
      }
      return .case(branches, else: fallback)
    case let .window(function, spec):
      return try .window(function: substitute(function), spec: substitute(spec))
    }
  }

  /// Each expression of `expressions` substituted, in order — a manual loop
  /// rather than `map`, so the typed `SQLError` throw propagates without
  /// widening to `any Error`.
  private mutating func substitute(_ expressions: Array<Expression>)
      throws(SQLError) -> Array<Expression> {
    var lifted = Array<Expression>()
    lifted.reserveCapacity(expressions.count)
    for expression in expressions { lifted.append(try substitute(expression)) }
    return lifted
  }

  /// An optional operand substituted — `nil` stays `nil` (a `LEAD`/`LAG` with
  /// no default, a positional window's absent default). A default stays in the
  /// outer window function with only its grounded atoms lifted, so the executor
  /// evaluates it at its natural point (an out-of-range target only), not
  /// eagerly per row.
  private mutating func substitute(_ expression: Expression?)
      throws(SQLError) -> Expression? {
    guard let expression else { return nil }
    return try substitute(expression)
  }

  /// This `CASE` guard predicate substituted over the arm union — each operand
  /// expression recursed through `substitute`, the predicate's structure kept
  /// in the outer projection. A grounded value (a `dept` column, an aggregate,
  /// a `GROUPING(…)`) becomes a `*gwN` arm reference while the predicate shape
  /// stays outer (`dept = 1` → `*gw0 = 1`); a group-independent operand (a
  /// literal, a `:parameter`) stays verbatim. This does not split the predicate
  /// across arms — only its grouped value operands become arm columns — over
  /// comparison, bound, IS NULL, IN, row comparison and membership, LIKE,
  /// BETWEEN, IS DISTINCT FROM, the boolean test, and AND/OR/NOT.
  ///
  /// A subquery-bearing form (`exists`/`within`/`quantified`) rebuilds
  /// unchanged: the union-scope `Resolution` the outer layer resolves against
  /// hosts the guard's subquery in place, so its enclosing predicate needs no
  /// per-arm rewrite.
  fileprivate mutating func substitute(_ predicate: Predicate)
      throws(SQLError) -> Predicate {
    switch predicate {
    case let .comparison(left, op, right):
      return try .comparison(left: substitute(left), op: op,
                             right: substitute(right))
    case let .bound(left, op, parameter):
      return try .bound(left: substitute(left), op: op, parameter: parameter)
    case let .null(operand, negated):
      return try .null(substitute(operand), negated: negated)
    case let .membership(operand, values, negated):
      return try .membership(substitute(operand), substitute(values),
                             negated: negated)
    case let .rows(left, op, right):
      return try .rows(substitute(left), op, substitute(right))
    case let .among(left, rows, negated):
      var lifted = Array<Array<Expression>>()
      lifted.reserveCapacity(rows.count)
      for row in rows { lifted.append(try substitute(row)) }
      return try .among(substitute(left), lifted, negated: negated)
    case let .like(operand, pattern, escape, negated):
      return try .like(substitute(operand), pattern: substitute(pattern),
                       escape: substitute(escape), negated: negated)
    case let .between(operand, lower, upper, negated):
      return try .between(substitute(operand), substitute(lower),
                          substitute(upper), negated: negated)
    case let .distinct(left, right, negated):
      return try .distinct(substitute(left), substitute(right),
                           negated: negated)
    case let .truth(inner, value, negated):
      return try .truth(substitute(inner), value: value, negated: negated)
    case let .and(left, right):
      return try .and(substitute(left), substitute(right))
    case let .or(left, right):
      return try .or(substitute(left), substitute(right))
    case let .not(inner):
      return try .not(substitute(inner))
    case .exists, .within, .quantified:
      // A subquery-bearing guard is hosted whole by the outer layer's union-
      // scope `Resolution`, so rebuild it unchanged.
      return predicate
    }
  }

  /// A `LIKE`/`BETWEEN` operand substituted over the arm union — an expression
  /// recursed through `substitute`, a `:parameter` (one value for the whole
  /// execution, identical across every group, so group-independent) left
  /// verbatim.
  fileprivate mutating func substitute(_ operand: Predicate.Operand)
      throws(SQLError) -> Predicate.Operand {
    switch operand {
    case let .expression(expression):
      return try .expression(substitute(expression))
    case .parameter:
      return operand
    }
  }

  /// An optional `LIKE` escape operand substituted — `nil` stays `nil`.
  fileprivate mutating func substitute(_ operand: Predicate.Operand?)
      throws(SQLError) -> Predicate.Operand? {
    guard let operand else { return nil }
    return try substitute(operand)
  }

  /// This window function with its operands substituted over the arm union — a
  /// ranking function is unchanged, an aggregate window substitutes its
  /// argument, a positional function substitutes its read-at-a-row value, and a
  /// `LEAD`/`LAG` default substitutes too but stays in the outer function.
  ///
  /// A window reads most operands at a row — the aggregate argument, the
  /// positional value, the `PARTITION BY`/`ORDER BY` keys — so the executor
  /// materialises each once per source row (`Window.position`/`extremum`); the
  /// grounded atoms substitute to `*gwN` arm slots the window reads, the rest
  /// (a scalar, an offset arithmetic) kept in the operand. A `LEAD`/`LAG`
  /// default is the conditional one: `Window.position` evaluates it only for an
  /// out-of-range target, so it stays in the outer function with only its
  /// grounded atoms lifted, the executor evaluating it at its natural point —
  /// exactly as the ordinary grouped-window path's `reconciled` default does.
  private mutating func substitute(_ function: WindowFunction)
      throws(SQLError) -> WindowFunction {
    switch function {
    case .number, .rank, .dense, .ntile, .percent, .cumulative:
      return function
    case let .aggregate(aggregate, operand, distinct, filter):
      // A `FILTER` search condition is a `Predicate` no derived column stands
      // in for; defer it rather than leave a base column unresolved.
      guard filter == nil else {
        throw .state("0A000",
                     "a window FILTER with GROUPING SETS is not yet supported")
      }
      let lifted: Aggregand = switch operand {
      case .star:
        .star
      case let .expression(expression):
        try .expression(substitute(expression))
      }
      return .aggregate(aggregate, of: lifted, distinct: distinct)
    case let .lead(value, offset, fallback):
      return try .lead(substitute(value), offset: offset,
                       default: substitute(fallback))
    case let .lag(value, offset, fallback):
      return try .lag(substitute(value), offset: offset,
                      default: substitute(fallback))
    case let .first(value):
      return try .first(substitute(value))
    case let .last(value):
      return try .last(substitute(value))
    case let .nth(value, position):
      return try .nth(substitute(value), position)
    }
  }

  /// This window specification with its `PARTITION BY` keys and `ORDER BY`
  /// values substituted over the arm union — an ordinal key (a `SELECT *`
  /// window order the prelude left unbound) is preserved, a value key's
  /// expression substituted, the frame carried through.
  private mutating func substitute(_ spec: WindowSpec)
      throws(SQLError) -> WindowSpec {
    let partition = try substitute(spec.partition)
    let order: Order? = if let clause = spec.order {
      try Order(keys: clause.keys.map { key throws(SQLError) in
        switch key.sort {
        case .ordinal:
          return key
        case let .expression(expression):
          // A key the prelude substituted for an output ordinal (`key.output`)
          // shares that output's `*gwN` leaf, so a non-deterministic operand is
          // evaluated once and the window orders by the reported value; a
          // directly written key substitutes to an independent leaf (#135).
          let value: Expression
          if let output = key.output {
            value = lift(expression, output: output)
          } else {
            value = try substitute(expression)
          }
          var lifted = Order.Key(sort: .expression(value),
                                 ascending: key.ascending)
          lifted.output = key.output
          return lifted
        }
      })
    } else {
      nil
    }
    return WindowSpec(base: spec.base, parenthesized: spec.parenthesized,
                      partition: partition, order: order, frame: spec.frame)
  }
}

extension Expression {
  /// Whether this window-free expression yields the same value at every
  /// occurrence, so the lifter may compute it once and share the `*gwN` column
  /// across the sites that reference it — a bare column, literal, or GROUPING
  /// bit-vector (a per-arm compile-time constant), an aggregate over a steady
  /// operand with no FILTER, or an arithmetic/CAST/COALESCE/NULLIF over steady
  /// parts, and a scalar call only when its routine is deterministic and every
  /// argument is. A non-deterministic call (`tick()`) is not shared — each site
  /// computes it independently, matching the plain grouped-window path — and a
  /// `CASE`, a scalar `subquery`, or a filtered aggregate is conservatively not
  /// shared. Mirrors `Term.deterministic`: treating an uncertain expression as
  /// non-steady never wrongly shares two sites that must evaluate on their own,
  /// only forgoes sharing two that could.
  fileprivate func steady(_ routines: Routines) -> Bool {
    switch self {
    case .column, .literal, .grouping:
      true
    case let .call(name, arguments):
      routines[name]?.deterministic == true
          && arguments.allSatisfy { $0.steady(routines) }
    case let .binary(_, lhs, rhs), let .nullif(lhs, rhs):
      lhs.steady(routines) && rhs.steady(routines)
    case let .cast(operand, _):
      operand.steady(routines)
    case let .coalesce(arguments):
      arguments.allSatisfy { $0.steady(routines) }
    case let .aggregate(_, operand, _, filter):
      switch operand {
      case .star:
        filter == nil
      case let .expression(expression):
        filter == nil && expression.steady(routines)
      }
    case .case, .subquery, .window:
      false
    }
  }
}

extension Query {
  /// The bare (unqualified, case-folded) names of every column this query
  /// references anywhere — its FROM/JOIN derived bodies, predicates,
  /// projection, grouping, HAVING, ORDER BY, window specifications, and the
  /// body of every subquery nested within, at any depth. The lifter reads it to
  /// decide whether a candidate subquery correlates to the enclosing grouping-
  /// sets query: one naming a group-key column is correlated (ISO restricts a
  /// grouped correlation to a grouping column) and stays arm-lifted, one naming
  /// none is uncorrelated and hosted outer. Over-approximating (a subquery's
  /// own column shadowing a group-key name) only forgoes the outer host, never
  /// mis-hosts a correlated one, so the routing stays sound.
  fileprivate func collect(columns names: inout Set<String>) {
    switch body {
    case let .select(select):
      select.collect(columns: &names)
    case let .setop(_, left, right, _):
      left.collect(columns: &names)
      right.collect(columns: &names)
    case let .values(rows):
      for row in rows {
        for expression in row { expression.collect(columns: &names) }
      }
    }
  }
}

extension Select {
  /// The bare names of every column this select references — its FROM/JOIN
  /// derived bodies and `ON`s, predicate, projection, grouping keys, HAVING,
  /// ORDER BY, and named-window specifications.
  fileprivate func collect(columns names: inout Set<String>) {
    from.collect(columns: &names)
    for join in joins {
      join.relation.collect(columns: &names)
      join.on.collect(columns: &names)
    }
    predicate?.collect(columns: &names)
    switch projection {
    case .all:
      break
    case let .columns(columns):
      for column in columns { names.insert(column.name.lowercased()) }
    case let .expressions(items):
      for item in items { item.expression.collect(columns: &names) }
    }
    for key in grouping.collected { key.collect(columns: &names) }
    having?.collect(columns: &names)
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(columns: &names)
      }
    }
    for definition in window {
      for expression in definition.spec.expressions {
        expression.collect(columns: &names)
      }
    }
  }
}

extension Relation {
  /// The bare names a relation references — a `.derived` one by recursing into
  /// its inner query, a `.named` one none (its columns are named at resolution,
  /// not in the AST).
  fileprivate func collect(columns names: inout Set<String>) {
    if case let .derived(query) = source { query.collect(columns: &names) }
  }
}

extension Expression {
  /// The bare (case-folded) names of every column this expression references,
  /// descending into a scalar `subquery`'s body and a window's operands so a
  /// correlation nested at any depth is seen.
  fileprivate func collect(columns names: inout Set<String>) {
    switch self {
    case let .column(column):
      names.insert(column.name.lowercased())
    case .literal:
      break
    case let .call(_, arguments), let .coalesce(arguments),
         let .grouping(arguments):
      for argument in arguments { argument.collect(columns: &names) }
    case let .binary(_, lhs, rhs), let .nullif(lhs, rhs):
      lhs.collect(columns: &names)
      rhs.collect(columns: &names)
    case let .cast(operand, _):
      operand.collect(columns: &names)
    case let .aggregate(_, operand, _, filter):
      if case let .expression(argument) = operand {
        argument.collect(columns: &names)
      }
      filter?.collect(columns: &names)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(columns: &names)
        when.then.collect(columns: &names)
      }
      otherwise?.collect(columns: &names)
    case let .subquery(query):
      query.collect(columns: &names)
    case let .window(function, spec):
      for expression in spec.expressions { expression.collect(columns: &names) }
      function.collect(columns: &names)
    }
  }
}

extension WindowFunction {
  /// The bare names of every column this window function's operands reference —
  /// an aggregate's argument and FILTER, a positional value and default, a
  /// FIRST/LAST/NTH value.
  fileprivate func collect(columns names: inout Set<String>) {
    switch self {
    case .number, .rank, .dense, .ntile, .percent, .cumulative:
      break
    case let .aggregate(_, operand, _, filter):
      if case let .expression(argument) = operand {
        argument.collect(columns: &names)
      }
      filter?.collect(columns: &names)
    case let .lead(value, _, fallback), let .lag(value, _, fallback):
      value.collect(columns: &names)
      fallback?.collect(columns: &names)
    case let .first(value), let .last(value), let .nth(value, _):
      value.collect(columns: &names)
    }
  }
}

extension Predicate {
  /// The bare names of every column this predicate references — its operand
  /// expressions, nested predicates, and the body of any `EXISTS`/`IN`/
  /// quantified subquery.
  fileprivate func collect(columns names: inout Set<String>) {
    switch self {
    case let .exists(query, _):
      query.collect(columns: &names)
    case let .within(lhs, query, _):
      for expression in lhs { expression.collect(columns: &names) }
      query.collect(columns: &names)
    case let .quantified(lhs, _, _, query):
      for expression in lhs { expression.collect(columns: &names) }
      query.collect(columns: &names)
    case let .comparison(left, _, right):
      left.collect(columns: &names)
      right.collect(columns: &names)
    case let .bound(left, _, _):
      left.collect(columns: &names)
    case let .null(operand, _):
      operand.collect(columns: &names)
    case let .membership(operand, values, _):
      operand.collect(columns: &names)
      for value in values { value.collect(columns: &names) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(columns: &names) }
      for expression in rhs { expression.collect(columns: &names) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(columns: &names) }
      for row in rows {
        for expression in row { expression.collect(columns: &names) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(columns: &names)
      pattern.collect(columns: &names)
      escape?.collect(columns: &names)
    case let .between(operand, lower, upper, _):
      operand.collect(columns: &names)
      lower.collect(columns: &names)
      upper.collect(columns: &names)
    case let .distinct(lhs, rhs, _):
      lhs.collect(columns: &names)
      rhs.collect(columns: &names)
    case let .truth(inner, _, _):
      inner.collect(columns: &names)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(columns: &names)
      rhs.collect(columns: &names)
    case let .not(operand):
      operand.collect(columns: &names)
    }
  }
}

extension Predicate.Operand {
  /// The bare names a `LIKE`/`BETWEEN` operand references — an expression's
  /// columns, a `:parameter` none.
  fileprivate func collect(columns names: inout Set<String>) {
    if case let .expression(expression) = self {
      expression.collect(columns: &names)
    }
  }
}
