// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - GROUPING SETS

extension Query {
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
          // an arm. A windowed grouping-sets select is NOT desugared here: it
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
  // the ordinary `SELECT` path materialises its derived tables.
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
/// the outer window layer's `projection` and `order` over it. It is NOT an AST
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
  /// window-free subexpression lifted to a synthetic `*gwN` reference of the
  /// union output, a window kept with its operands lifted. Each item carries
  /// the original item's inferable output name as its alias (`nil` for an
  /// unnamed one), so a query `ORDER BY` names a window alias while an unnamed
  /// output stays a synthesized header, never the internal `*gwN` name.
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
///     every lifted subexpression rewritten to its `*gwN` reference of the
///     union output. Each window's `PARTITION BY`/`ORDER BY`/argument now reads
///     a computed column of the union — a `SUM(x)` a window orders by is
///     already materialised, the window reads it and does not re-aggregate — so
///     the window computes over the full result set.
///
/// The lifted `*gwN` references are unqualified: the compile seam builds the
/// union-output `Scope` keyed by the empty alias (as the `ordered` set-op
/// carrier does), so a bare `*gwN` resolves against that scope's columns rather
/// than a derived-table qualifier. The compile seam compiles the union in the
/// enclosing context, so a correlated arm reference (an enclosing LATERAL
/// `T.Id`) resolves natively — no `VALUES (1)` unit or LATERAL apply is needed.
///
/// A window-free subexpression is lifted to one shared `*gwN` column only when
/// it is deterministic under `routines` (a group key, an aggregate, a scalar
/// over such, a deterministic call) — so a `SUM(x)` a window orders by and the
/// projection also yields is one column, read never re-aggregated. A non-
/// deterministic one (a `tick()` in the projection and the window `ORDER BY`
/// alike) takes a fresh column per occurrence, so each site evaluates it
/// independently, matching the plain grouped-window path rather than collapsing
/// the two sites onto one union column.
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

  // Lift the projection and the query-level ORDER BY over the union output,
  // gathering the window-free operands each references into `lift.leaves`. Each
  // outer item carries the original item's inferable output name as its alias
  // (`nil` for an unnamed one) — a bare group column stays named, an aliased
  // value keeps its alias — so a query `ORDER BY` may name a window alias,
  // while an unnamed output takes no `*gwN` name and stays a synthesized
  // `column N` header (the schema twin names it from `items`).
  var lift = Lift(routines)
  var projection = Array<Projected>()
  projection.reserveCapacity(items.count)
  for index in items.indices {
    projection.append(
        Projected(expression: try lift.lift(items[index].expression),
                  alias: items[index].name))
  }
  // The projected output names — a bare unqualified ORDER BY key naming one
  // orders on that output (ISO output-alias precedence), so it is left to
  // resolve against the outer projection rather than lifted to a `*gwN`
  // reference.
  let outputs = Set(items.compactMap { $0.name?.lowercased() })
  let order: Order? = if let clause = select.order {
    Order(keys: try clause.keys.map { key throws(SQLError) in
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
        var lifted = Order.Key(sort: .expression(try lift.lift(expression)),
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

/// The lifter that rewrites a windowed grouping-sets query's outer expressions
/// over the arm union output, gathering the window-free operands to push into
/// the arms.
///
/// Each maximal window-free subexpression (anything but a bare literal) is a
/// value the grouped arms compute — a group key, an aggregate, a `GROUPING(…)`,
/// a scalar over them, a whole window-free `CASE` — so it is pushed to `leaves`
/// once (deduplicated by structural identity) and replaced with a reference to
/// its synthetic `*gwN` union column. A bare literal needs no arm column and
/// stays in the outer projection. A window function is kept in the outer, its
/// `PARTITION BY`/`ORDER BY`/argument operands lifted so they read the union
/// columns.
private struct Lift {
  /// The routines a lifted operand's determinism is judged against, deciding
  /// whether two occurrences share one `*gwN` column.
  private let routines: Routines

  /// The window-free operands pushed into the arms, in first-appearance order —
  /// arm column `*gwN` is `leaves[N]`.
  private(set) var leaves = Array<Expression>()

  /// The `leaves` position each DETERMINISTIC pushed operand occupies, so an
  /// operand written twice (a `SUM(x)` a window orders by that the projection
  /// also yields) is one column. A non-deterministic operand is never recorded
  /// here, so each occurrence takes a fresh column.
  private var index = Dictionary<Expression, Int>()

  fileprivate init(_ routines: Routines) {
    self.routines = routines
  }

  /// The `*gwN` union reference for `expression`, registering it as an arm
  /// column on first sight. A DETERMINISTIC operand reuses its position after
  /// (one shared column), while a non-deterministic one (`tick()`) takes a
  /// fresh column per occurrence, so each site evaluates it independently. The
  /// reference is unqualified — the compile seam builds the union-output scope
  /// keyed by the empty alias, so a bare `*gwN` resolves against it by name,
  /// with no derived-table qualifier to match.
  private mutating func reference(_ expression: Expression) -> Expression {
    let steady = expression.steady(routines)
    if steady, let existing = index[expression] {
      return .column(Column(name: "*gw\(existing)"))
    }
    let position = leaves.count
    if steady { index[expression] = position }
    leaves.append(expression)
    return .column(Column(name: "*gw\(position)"))
  }

  /// This expression rewritten over the arm union — a window-free
  /// subexpression pushed to an arm column, a window kept with its operands
  /// lifted, a bare literal left as is.
  fileprivate mutating func lift(_ expression: Expression) throws(SQLError)
      -> Expression {
    guard expression.windowed else {
      // A bare literal needs no arm column and stays in the outer projection.
      // Every other window-free subexpression — a group key, an aggregate, a
      // `GROUPING(…)`, a scalar over them — is lifted to a `*gwN` arm column,
      // computed in the arm's grouped scope and validated there (its reachable
      // operands type-checked as the arm compiles), so a lifted operand faults
      // on the run and validate paths alike. A non-deterministic operand takes
      // a fresh column per occurrence (`reference`), so a `tick()` in the
      // projection and the window `ORDER BY` are two evaluations, not one
      // collapsed onto a shared arm column.
      if case .literal = expression { return expression }
      return reference(expression)
    }
    switch expression {
    case let .window(function, spec):
      return .window(function: try lift(function), spec: try lift(spec))
    case let .call(name, arguments):
      return .call(name: name, arguments: try lift(arguments))
    case let .binary(operation, lhs, rhs):
      return .binary(operation, try lift(lhs), try lift(rhs))
    case let .cast(operand, type):
      return .cast(try lift(operand), type)
    case let .coalesce(arguments):
      return .coalesce(try lift(arguments))
    case let .nullif(lhs, rhs):
      return .nullif(try lift(lhs), try lift(rhs))
    case .case:
      // A windowed `CASE`'s `WHEN` is a `Predicate` no derived column stands in
      // for; defer it rather than leave a base column unresolved in the outer.
      throw .state("0A000",
                   "a window in a CASE with GROUPING SETS is not yet supported")
    case .column, .literal, .aggregate, .subquery, .grouping:
      // Window-free (the guard pushed or kept it) — unreachable here.
      return expression
    }
  }

  /// Each expression of `expressions` lifted, in order.
  private mutating func lift(_ expressions: Array<Expression>)
      throws(SQLError) -> Array<Expression> {
    var lifted = Array<Expression>()
    lifted.reserveCapacity(expressions.count)
    for expression in expressions { lifted.append(try lift(expression)) }
    return lifted
  }

  /// This window function with its operands lifted over the arm union — a
  /// ranking function is unchanged, an aggregate window lifts its argument, and
  /// a positional function lifts its value and default.
  private mutating func lift(_ function: WindowFunction)
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
        .expression(try lift(expression))
      }
      return .aggregate(aggregate, of: lifted, distinct: distinct)
    case let .lead(value, offset, fallback):
      return .lead(try lift(value), offset: offset,
                   default: try lift(fallback))
    case let .lag(value, offset, fallback):
      return .lag(try lift(value), offset: offset,
                  default: try lift(fallback))
    case let .first(value):
      return .first(try lift(value))
    case let .last(value):
      return .last(try lift(value))
    case let .nth(value, position):
      return .nth(try lift(value), position)
    }
  }

  /// An optional operand lifted — `nil` stays `nil` (a positional window's
  /// absent default).
  private mutating func lift(_ expression: Expression?)
      throws(SQLError) -> Expression? {
    guard let expression else { return nil }
    return try lift(expression)
  }

  /// This window specification with its `PARTITION BY` keys and `ORDER BY`
  /// values lifted over the arm union — an ordinal key (a `SELECT *` window
  /// order the prelude left unbound) is preserved, a value key's expression
  /// lifted, the frame carried through.
  private mutating func lift(_ spec: WindowSpec)
      throws(SQLError) -> WindowSpec {
    let partition = try lift(spec.partition)
    let order: Order? = if let clause = spec.order {
      Order(keys: try clause.keys.map { key throws(SQLError) in
        switch key.sort {
        case .ordinal:
          return key
        case let .expression(expression):
          var lifted = Order.Key(sort: .expression(try lift(expression)),
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
