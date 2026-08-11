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
  internal func union(windowed routines: Routines,
                      schemas: Dictionary<String, Exposure>)
      throws(SQLError) -> Query? {
    guard unioned, case let .select(select) = body,
        case let .sets(sets) = select.grouping else { return nil }
    return try decompose(windowed: select, sets: sets, routines, schemas).union
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

/// The columns a relation exposes to the windowed grouping-sets membership
/// test, split by the two surfaces the `Lift` reads them through — the
/// physical∪virtual surface a bare name binds against directly, and the real-
/// only surface a `SELECT *` over the relation projects.
internal struct Exposure {
  /// Every column a bare name may bind against in a subquery whose FROM names
  /// this relation directly — its real columns AND its virtual ones (`Id`, a
  /// foreign key), the physical∪virtual surface the engine's `Schema
  /// .ordinal(of:)` resolves an unqualified name against. A subquery `FROM U
  /// WHERE Id = …` binds `Id` to U's virtual, so the direct-membership test
  /// must see it, or a bare `Id` over a relation bearing a virtual `Id` would
  /// mis-rewrite to the outer key rather than binding its own adapter column.
  internal let bindable: Set<String>

  /// The real columns alone — the surface a `SELECT *` exposes. The engine's
  /// `*` expansion (`Scope.terms(.all)`) enumerates each source's real columns
  /// in chain order and never a virtual column, so a derived `(SELECT * FROM U)
  /// e` exposes U's real columns, not its virtual `Id`. Deriving a `SELECT *`
  /// output from `bindable` would expose a virtual the engine omits, mis-
  /// binding a bare `Id` group-key reference to the derived table rather than
  /// the outer key (the unsound direction — a false local).
  internal let real: Set<String>
}

extension Catalog where Self: ~Escapable {
  /// The `Exposure` — the bindable (real∪virtual) and the real-only column
  /// surfaces, case-folded — of every relation in scope, keyed by its name: the
  /// base tables and views this catalog vends and the common table expressions
  /// and store relations the `overlay` binds. It is the schema map the windowed
  /// grouping-sets `Lift` decides an unqualified group-key-colliding subquery
  /// reference against: a name a local relation exposes binds locally, one
  /// absent from every local is the outer group-key correlation. A subquery's
  /// own FROM relation reads the `bindable` surface (a bare `Id` binds a
  /// virtual), while a `SELECT *` derived table's output takes the `real`
  /// surface of its own sources (`*` omits virtuals).
  ///
  /// It mirrors the engine's full schema derivation across every relation kind,
  /// not a subset:
  ///
  ///   - a base table's real columns (`real`) plus its virtual columns
  ///     (`bindable` only) — the engine's `Schema.ordinal(of:)` resolves an
  ///     adapter `Id` for a bare name, so the direct-membership test must too,
  ///     while `*` omits the virtual, so the star surface must not;
  ///   - a view's declared column names in projection order (`View.columns`,
  ///     the ISO first-arm naming), with no virtual column (`View.schema`) on
  ///     either surface, shadowing a base table of the same name — the
  ///     precedence a `view(named:)` lookup applies;
  ///   - a CTE's or store relation's declared columns (both surfaces) plus the
  ///     universal virtual `Id` a `RelationInstance` vends (`bindable` only,
  ///     as `*` omits it), shadowing a base table or view — the innermost
  ///     overlay precedence the resolver applies. Only the overlay's base layer
  ///     is read: a CTE is statement-scoped, while a nested subquery's FROM
  ///     never sees an enclosing SELECT's derived aliases, so the derived
  ///     layers name no relation a hosted subquery can reference.
  ///
  /// A relation still absent from the map — the residual — cannot be derived
  /// pre-compile: only a `SELECT *` over a source the map does not name (an
  /// unresolved or not-yet-bound CTE), whose columns the union scope cannot
  /// expand here, leaving `expose` to record it opaque (the reference
  /// conservatively blocked, arm-lifted).
  ///
  /// Every seam that lowers a windowed grouping-sets query — the compile, the
  /// schema derive and typecheck twins, and each runtime `union(windowed:)`
  /// entry — builds this map from the one catalog `self` and the same `overlay`
  /// base layer (established once at statement entry and threaded unchanged),
  /// so all decide local membership identically and run stays in step with
  /// validate.
  internal borrowing func schemas(_ overlay: ScopedRelations = [:])
      -> Dictionary<String, Exposure> {
    var schemas = Dictionary<String, Exposure>()
    for name in relations() {
      guard let table = table(named: name) else { continue }
      var real = Set<String>()
      for column in table.names { real.insert(column.lowercased()) }
      var bindable = real
      for virtual in table.virtuals { bindable.insert(virtual.lowercased()) }
      schemas[name.lowercased()] = Exposure(bindable: bindable, real: real)
    }
    for name in views() {
      guard let view = view(named: name) else { continue }
      let columns = Set(view.columns.map { $0.lowercased() })
      schemas[name.lowercased()] = Exposure(bindable: columns, real: columns)
    }
    for (name, instance) in overlay.bindings {
      let real = Set(instance.columns.map { $0.lowercased() })
      schemas[name.lowercased()] =
          Exposure(bindable: real.union(["id"]), real: real)
    }
    return schemas
  }
}

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

extension WindowedSets {
  /// The role (`scalar`/`valued`/`existential`) each subquery the outer window
  /// layer hosts occupies — classified over the rewritten `projection` and
  /// `order`, NOT the original select. The lifter rewrites a correlated
  /// subquery's free group-key references to `*gwN` before hosting it, so the
  /// `Query` the union-scope `Resolution` compiles differs from the select's
  /// original spelling; classifying against the rewritten expressions keeps a
  /// hosted subquery's role matched to the very query the `Resolution` lowers.
  /// An uncorrelated subquery rides through the rewrite verbatim, so it agrees
  /// with the select's own classification for it.
  internal func roles(of query: Query) -> Array<Role> {
    var roles = Array<Role>()
    if scalar.contains(query) { roles.append(.scalar) }
    if valued.contains(query) { roles.append(.valued) }
    if existential.contains(query) { roles.append(.existential) }
    return roles
  }

  /// The scalar-position subqueries the rewritten outer layer hosts.
  internal var scalar: Set<Query> {
    gather { $0.collect(scalar: &$1) }
  }

  /// The `IN (Q)`-position subqueries the rewritten outer layer hosts.
  internal var valued: Set<Query> {
    gather { $0.collect(valued: &$1) }
  }

  /// The `EXISTS (Q)`-position subqueries the rewritten outer layer hosts.
  internal var existential: Set<Query> {
    gather { $0.collect(existential: &$1) }
  }

  /// The queries `collect` gathers across the rewritten outer `projection` and
  /// `order` — the two surfaces the seams host a subquery from.
  private func gather(_ collect: (Expression, inout Set<Query>) -> Void)
      -> Set<Query> {
    var queries = Set<Query>()
    for item in projection { collect(item.expression, &queries) }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        collect(expression, &queries)
      }
    }
    return queries
  }
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
/// A subquery uncorrelated to this query — or one whose group-key correlations
/// are all qualified-free references — is hosted in the outer layer through the
/// union-scope `Resolution`, its qualified-free references rewritten to their
/// `*gwN` union column so the union scope resolves them as correlated outer
/// parameters (kept verbatim so a `LEAD` default or a `CASE` branch nesting it
/// stays lazy). A subquery whose only correlation is an unqualified group-key-
/// colliding reference is undecidable pre-schema, so it stays arm-lifted (a
/// scalar one; a predicate one hosts verbatim), the arm's grouped scope binding
/// the correlation.
///
/// A window `FILTER` and a windowed `CASE` are the two operand shapes not
/// lowered here — each carries a `Predicate` a `*gwN` column cannot stand in
/// for — so each faults the feature diagnostic on both paths, in parity,
/// rather than resolving a base column the union scope cannot see.
internal func decompose(windowed select: Select,
                        sets: Array<Array<Expression>>,
                        _ routines: Routines,
                        _ schemas: Dictionary<String, Exposure>)
    throws(SQLError) -> WindowedSets {
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
  // The lifter reads them to route a subquery by its free variables (`host`): a
  // qualified-free reference to a group key is rewritten to its `*gwN` union
  // column and the subquery hosted outer; a subquery whose only correlation is
  // an unqualified group-key-colliding reference is undecidable pre-schema, a
  // scalar one falls back to arm-lift (a predicate one hosts verbatim); one
  // whose every group-key reference is bound within its own scope is
  // uncorrelated and hosted outer verbatim.
  var keys = Set<String>()
  for set in sets {
    for key in set { key.collect(free: &keys, bound: []) }
  }
  // The grouping-key member expressions themselves — every set's keys, by the
  // resolved identity grouped lowering matches a key by, approximated pre-scope
  // as each key's `canonical` (qualifier-stripped, case-folded). The lifter
  // matches a whole outer subexpression's `canonical` against these to lift a
  // complete grouping key to one `*gwN` arm column before descending into its
  // operands, so the arm projects the exact key it groups on — not a bare
  // operand (`A` under `A + 1`) the grouped arm would reject. Matching by
  // canonical (not raw `Expression` equality) collapses a qualification- or
  // case-variant spelling (`A + 1` ≡ `T.A + 1` ≡ `a + 1`) as the arm's real
  // `Grouped.term` will, so a projection spelled differently than the key still
  // lifts whole. This is the projection key-lift lookup, kept distinct from
  // `keys` (the bare names the correlation classifier routes a subquery
  // against).
  var members = Set<Expression>()
  for set in sets {
    for key in set { members.insert(key.canonical) }
  }
  // Lift the projection and the query-level ORDER BY over the union output,
  // gathering the operands each references into `lift.leaves`. Each outer item
  // carries the original item's inferable output name as its alias (`nil` for
  // an unnamed one) — a bare group column stays named, an aliased value keeps
  // its alias — so a query `ORDER BY` may name a window alias, while an unnamed
  // output takes no `*gwN` name and stays a synthesized `column N` header (the
  // schema twin names it from `items`).
  var lift = Lift(routines, keys: keys, members: members, schemas: schemas)
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
/// ordinary machinery resolves against the union scope directly. A `.subquery`
/// is hosted outer — the outer layer resolves it via the union-scope
/// `Resolution` `windowed(sets:)` passes — with its free qualified group-key
/// references rewritten to their `*gwN` union column (`host`), so a correlated
/// subquery correlates against the union scope; a scalar subquery whose only
/// correlation is unqualified-ambiguous falls back to an arm-lift instead.
///
/// A window `FILTER` and a windowed `CASE` are the two shapes not lowered here
/// — each carries a `Predicate` a `*gwN` column cannot stand in for — so each
/// faults the feature diagnostic on both paths, in parity (#136).
private struct Lift {
  /// The routines a lifted operand's determinism is judged against, deciding
  /// whether two occurrences share one `*gwN` column.
  private let routines: Routines

  /// The bare names of the group-key columns — the columns a correlated
  /// subquery may reference as a free variable. A subquery correlated to one by
  /// a qualified-free reference has it rewritten to its `*gwN` union
  /// column and is hosted outer (`host`); one whose only correlation is an
  /// unqualified group-key-colliding reference absent from its local relations
  /// is likewise the outer key, rewritten and hosted; one whose every group-key
  /// reference binds within its own scope is uncorrelated and hosted verbatim.
  private let keys: Set<String>

  /// The grouping-key member expressions — every grouping set's keys by the
  /// resolved identity grouped lowering matches a key by, approximated pre-
  /// scope as each key's `canonical` (qualifier-stripped, case-folded). A whole
  /// outer subexpression whose `canonical` equals one of these is a complete
  /// grouping key, lifted to one `*gwN` arm column (`substitute`) before its
  /// operands are recursed, so a computed key (`A + 1`) is projected whole by
  /// the arm — not its bare operand (`A`), which the arm's grouped scope would
  /// reject as a non-key. Matching by canonical rather than raw `Expression`
  /// equality collapses a qualification- or case-variant spelling (`A + 1` ≡
  /// `T.A + 1` ≡ `a + 1`) exactly as the arm's `Grouped.term` will once it has
  /// a scope, so a projection spelled differently than the key still lifts
  /// whole rather than descending to a bare operand the arm rejects. It is the
  /// projection key-lift lookup, kept distinct from `keys` (the bare names the
  /// subquery-correlation classifier routes against): a correlation to a bare
  /// column when the key is an expression is illegal ISO anyway, so the two
  /// serve separate decisions and need not agree.
  private let members: Set<Expression>

  /// The `Exposure` — case-folded — of each relation in scope, keyed by the
  /// relation's name: the catalog's base tables and views, and the overlay's
  /// common table expressions and store relations. It backs the local-
  /// membership test an unqualified group-key-colliding reference decides
  /// against (`expose`): a subquery's FROM relation naming one of these binds
  /// an unqualified name in its `bindable` set locally, so the name is its own
  /// column, not the outer correlation. Virtual columns count on that surface
  /// — the engine's `Schema.ordinal(of:)` resolves an adapter `Id` for
  /// a bare name, so a subquery over a `U` bearing a virtual `Id` binds a bare
  /// `Id` to that `Id`, never the outer key — while a `SELECT *` over `U` reads
  /// the `real` surface instead (`*` omits the virtual). The map mirrors the
  /// engine's full schema derivation across every relation kind
  /// (`Catalog.schemas`); a relation absent from it — only a `SELECT *` over a
  /// source the map does not name — is indeterminate, leaving the reference
  /// conservatively blocked.
  private let schemas: Dictionary<String, Exposure>

  /// The local scope a rewrite walk accumulates as it descends — the enriched
  /// `bound` the transforming twin threads in place of a bare alias set. It
  /// carries the in-scope FROM/JOIN `aliases` (for the qualified-local check),
  /// the exposed unqualified column `names` of every determinate local relation
  /// (for the unqualified-local check), and `opaque` — set when an in-scope
  /// relation's columns could not be derived (only a `SELECT *` over a source
  /// the schema map does not name remains, now that a base table, view, CTE,
  /// VALUES, and a `SELECT *` over any of those all derive through `schemas`),
  /// so an unqualified name might still bind there and the reference stays
  /// blocked rather than rewritten.
  private struct Locals {
    var aliases: Set<String>
    var names: Set<String>
    var opaque: Bool

    /// The empty scope a `host` walk starts from — no local relation yet in
    /// scope, so an unqualified group-key reference is the outer correlation
    /// until a descended relation exposes it.
    static var empty: Locals { Locals(aliases: [], names: [], opaque: false) }
  }

  /// Whether the in-flight `host` walk met an unqualified free reference whose
  /// bare name is a group key that no determinate in-scope local relation
  /// exposes yet an opaque local might — undecidable pre-schema, so it is not
  /// safely rewritten and hosted. Set by the leaf rewrite, read by `host`
  /// (which then rolls back any `*gwN` columns the aborted walk allocated and
  /// reports the subquery unhostable), and reset at each `host` entry. A name a
  /// determinate local exposes is left verbatim without blocking (a local
  /// bind); one absent from every determinate local with no opaque local in
  /// scope is rewritten to `*gwN` without blocking (the outer key).
  private var blocked = false

  /// Whether the in-flight rewrite rides a query-level carrier's row operators
  /// (a set operation's `ORDER BY`), where an unqualified name binds the set-op
  /// output by ISO output-alias/ordinal precedence — a local output reference,
  /// not a correlation — so it is left verbatim and never blocks, unlike an
  /// unqualified body reference (undecidable, so conservatively blocked). Set
  /// while a carrier's `ORDER BY` is rewritten, reset false when the walk
  /// crosses into a nested subquery body (via `rewrite(_ query:)`), whose own
  /// unqualified references follow the ordinary rule.
  private var riding = false

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

  fileprivate init(_ routines: Routines, keys: Set<String>,
                   members: Set<Expression>,
                   schemas: Dictionary<String, Exposure>) {
    self.routines = routines
    self.keys = keys
    self.members = members
    self.schemas = schemas
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
  /// with no derived-table qualifier to match. It is `synthetic`, a `Column`
  /// identity no user identifier can mint, so a quoted alias spelled `"*gwN"`
  /// stays distinct and a query-level `ORDER BY` binds this reference to its
  /// union column structurally rather than by output-alias precedence
  /// (`Windowed.order`).
  private mutating func reference(_ expression: Expression) -> Expression {
    .column(Column(name: "*gw\(allocate(expression))", synthetic: true))
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
      return .column(Column(name: "*gw\(existing)", synthetic: true))
    }
    let position = allocate(expression)
    linked[output] = position
    return .column(Column(name: "*gw\(position)", synthetic: true))
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
  /// compute (a whole grouping-key member expression, an aggregate, a
  /// `GROUPING(…)`, a group column, or a scalar subquery the outer layer hosts
  /// through the union-scope `Resolution`) replaced by its `*gwN` reference,
  /// every other node kept in the outer with its operands recursed.
  ///
  /// A whole grouping-key member expression is recognised before any composite
  /// recursion: a computed key (`A + 1`) is a `.binary` whose bare operand `A`
  /// is not itself a grouping key, so recursing into it would lift `A` and the
  /// grouped arm would reject the arm's projected `A`; matching the whole
  /// `A + 1` against `members` lifts it to one `*gwN` column the arm projects
  /// as its exact grouping key. This subsumes the bare-column key (`dept` is a
  /// `.column` member matched whole), while a bare `A` operand reached only by
  /// descending an expression key is never reached, and a projected non-key
  /// column (`SELECT A … GROUP BY (A + 1)`) still lifts as a `.column` atom so
  /// the arm rejects it with the `.grouping` fault the ordinary form gives.
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
    // A whole grouping-key member expression lifts to one `*gwN` arm column
    // before descending into any composite operands, so the arm projects the
    // exact key it groups on. Matched by `canonical` (qualifier-stripped, case-
    // folded), so a projection spelled differently than the key (`A + 1` for a
    // `T.A + 1` key) still lifts whole rather than descending to a bare operand
    // the arm rejects, mirroring the arm's `Grouped.term` match. A bare literal
    // key needs no column (a constant reads the same everywhere) and stays
    // inline, mirroring the ordinal-linked `lift`. The `reference` shares
    // a leaf with an equal projected or ordinal-linked key through the
    // `steady`/`index` dedup.
    if members.contains(expression.canonical) {
      if case .literal = expression { return expression }
      return reference(expression)
    }
    switch expression {
    case .aggregate, .grouping, .column:
      // A grounded atom the union scope cannot compute — an aggregate, a
      // GROUPING bit-vector, or a group column — becomes its deduplicated
      // `*gwN` reference, computed in the arm's grouped scope.
      return reference(expression)
    case let .subquery(query):
      // A subquery uncorrelated to this query — or one whose every group-key
      // correlation is a qualified-free reference — hosted in the outer layer
      // through the union-scope `Resolution`, its qualified-free references
      // rewritten to their `*gwN` union column (`host`), so a `LEAD` default or
      // a `CASE` branch nesting it stays lazy, evaluated only when reached; the
      // union scope exposes the `*gwN` column the hosted subquery reads as a
      // correlated outer parameter. A subquery whose only correlation is an
      // unqualified group-key-colliding reference is undecidable pre-schema (it
      // might be a local base column, so rewriting to `*gwN` could be wrong),
      // so `host` returns `nil` and it falls back to arm-lift (a `*gwN`
      // reference), where the arm's grouped scope binds the reference — always
      // value-correct, only forgoing the lazy outer host.
      if let hosted = host(query) { return .subquery(hosted) }
      return reference(expression)
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

  /// This subquery prepared to be hosted in the outer window layer — its free
  /// qualified group-key references rewritten to their `*gwN` union column, so
  /// the union-scope `Resolution` resolves them as correlated parameters —
  /// or `nil` when it cannot be safely hosted and must be arm-lifted instead.
  ///
  /// The rewrite descends the whole subquery body (`rewrite`), threading each
  /// nested select's own FROM/JOIN aliases as `bound` (the same alias-tracking
  /// `collect(free:bound:)` uses), and at each column decides by qualifier:
  ///
  ///   - a reference qualified by a non-local alias whose bare name is a group
  ///     key is a free correlation to that key — rewritten to its deduplicated
  ///     `*gwN` union column (the arm projects the key, the union carries it);
  ///   - a reference qualified by one of the subquery's own aliases is local —
  ///     left untouched (`e.dept` over its own `FROM Emp AS e`);
  ///   - a reference qualified by a non-local alias whose name is NOT a group
  ///     key is a correlation to some other outer column — left untouched;
  ///   - an unqualified reference to a group key is undecidable pre-schema
  ///     (it might be a local base column) so it is never rewritten; a query
  ///     bearing one is not safely hosted, so the walk marks it `blocked` and
  ///     `host` reports it unhostable (`nil`), the caller arm-lifting instead.
  ///
  /// An uncorrelated subquery meets no free group-key reference, so it rides
  /// through unchanged (no column allocated), reproducing the verbatim host.
  private mutating func host(_ query: Query) -> Query? {
    let leaves = self.leaves
    let index = self.index
    let linked = self.linked
    blocked = false
    let hosted = rewrite(query, bound: .empty)
    guard !blocked else {
      // The walk met an unqualified key-colliding reference: discard the `*gwN`
      // columns it allocated for the qualified-free references beside it and
      // report the subquery unhostable, so the caller arm-lifts the original.
      self.leaves = leaves
      self.index = index
      self.linked = linked
      return nil
    }
    return hosted
  }

  /// This query with its free qualified group-key references rewritten to their
  /// `*gwN` column — a `.select` extending `bound` with its own aliases, a
  /// `.setop` recursing both arms, a `.values` its rows, and each carrier's
  /// query-level `ORDER BY` — the transforming twin of
  /// `Query.collect(free:bound:)`.
  ///
  /// The body's own references follow the ordinary rule (an unqualified key-
  /// colliding name is undecidable, so it blocks); a carrier's `ORDER BY` rides
  /// above the body's output, where an unqualified name binds a local output.
  /// `riding` is saved and reset false for the body, so a nested subquery
  /// reached from an enclosing carrier order returns to the body rule, and the
  /// enclosing carrier context is restored after — the carriers rewritten under
  /// `riding` by `rewrite(_ carrier:)`.
  private mutating func rewrite(_ query: Query, bound: Locals) -> Query {
    let saved = riding
    riding = false
    let body: Query.Body
    switch query.body {
    case let .select(select):
      body = .select(rewrite(select, bound: bound))
    case let .setop(kind, left, right, all):
      body = .setop(kind, rewrite(left, bound: bound),
                    rewrite(right, bound: bound), all: all)
    case let .values(rows):
      body = .values(rows.map { rewrite($0, bound: bound) })
    }
    let carriers = query.carriers.map { rewrite($0, bound: bound) }
    riding = saved
    return Query(body: body, carriers: carriers)
  }

  /// This carrier's query-level `ORDER BY` keys rewritten over the set-op
  /// output — the row operators riding above the body. An unqualified key binds
  /// a local output (output-alias/ordinal precedence), so the walk rewrites it
  /// under `riding`: an unqualified name is left verbatim and never blocks, a
  /// reference qualified by a non-local alias whose bare name is a group key is
  /// the correlation, rewritten to its `*gwN` union column, and an ordinal is
  /// carried through. `DISTINCT`/`OFFSET`·`FETCH`/`generated` hold no column
  /// reference, so they ride through unchanged. A subquery nested in an order
  /// key resets `riding` (via `rewrite(_ query:)`), so its own body follows the
  /// ordinary rule.
  private mutating func rewrite(_ carrier: Query.Carrier, bound: Locals)
      -> Query.Carrier {
    let saved = riding
    riding = true
    let order = rewrite(carrier.order, bound: bound)
    riding = saved
    return Query.Carrier(distinct: carrier.distinct, order: order,
                         limit: carrier.limit, generated: carrier.generated)
  }

  /// This select's free group-key references rewritten, each clause resolved
  /// against the same scope compilation lowers it against — a progressively
  /// extended join prefix, not one all-relations-at-once scope. The
  /// transforming twin of `Select.collect(free:bound:)`, descending its
  /// FROM/JOIN bodies and `ON`s, predicate, projection, grouping, HAVING, ORDER
  /// BY, and named-window specifications.
  ///
  /// Compilation resolves a join `ON` against a prefix scope — the FROM
  /// relation and joins `0…index`, the joined-in relation included, never a
  /// relation joined later (`Compilation.subqueries(_:enclosing:prefixes:)`,
  /// whose `prefixes[index]` is `relations[0 … index + 1]`) — while the
  /// predicate, projection, grouping, HAVING, and ORDER BY see the full join
  /// scope, and a derived join relation's body (a LATERAL arm) sees only the
  /// PRECEDING relations (the FROM and joins before it, itself excluded). The
  /// prefix accumulates here in that exact order so join[i]'s `ON` is rewritten
  /// under FROM…join[i] rather than the full scope: without it, a later join
  /// exposing a group-key-colliding column (`dept`) makes an earlier `ON`'s
  /// outer-key reference look local, so the reference is left verbatim while
  /// prefix-scoped resolution — which cannot see that later relation — faults
  /// `.column` over the `*gwN`-only union scope instead of binding the outer
  /// key.
  private mutating func rewrite(_ select: Select, bound: Locals)
      -> Select {
    // FROM is the first relation, resolved with no preceding — its derived body
    // sees only the enclosing scope.
    let from = rewrite(select.from, bound: bound)
    // Accumulate the join prefix in source order. Each join's relation body
    // resolves against the PRECEDING scope (a LATERAL arm may name a preceding
    // column, itself excluded); its `ON` against the prefix extended with its
    // own relation (`A JOIN B ON A.x = B.y` sees `B`). Only after the whole
    // chain is `prefix` the full scope the remaining clauses resolve against.
    var prefix = bound
    extend(&prefix, with: select.from)
    var joins = Array<Join>()
    joins.reserveCapacity(select.joins.count)
    for join in select.joins {
      let relation = rewrite(join.relation, bound: prefix)
      extend(&prefix, with: join.relation)
      joins.append(Join(relation: relation, kind: join.kind,
                        on: rewrite(join.on, bound: prefix), using: join.using))
    }
    let locals = prefix
    let window = select.window.map {
      NamedWindow(name: $0.name, spec: rewrite($0.spec, bound: locals))
    }
    return Select(distinct: select.distinct,
                  projection: rewrite(select.projection, bound: locals),
                  from: from, joins: joins,
                  predicate: select.predicate.map {
                    rewrite($0, bound: locals)
                  },
                  grouping: rewrite(select.grouping, bound: locals),
                  having: select.having.map { rewrite($0, bound: locals) },
                  window: window, order: rewrite(select.order, bound: locals),
                  limit: select.limit)
  }

  /// A relation's free qualified group-key references rewritten — a `.derived`
  /// one recursing into its inner query (which extends `bound` with its own
  /// aliases), a `.named` one carried through (it references no column).
  private mutating func rewrite(_ relation: Relation, bound: Locals)
      -> Relation {
    guard case let .derived(query) = relation.source else { return relation }
    return Relation(derived: rewrite(query, bound: bound),
                    as: relation.alias ?? "", columns: relation.columns,
                    lateral: relation.lateral)
  }

  /// Folds `relation` into the accumulating local scope — its binding alias
  /// into `aliases`, and either its exposed column `names` or, when those
  /// cannot be derived, `opaque`. It mirrors the alias threading
  /// `collect(free:bound:)` uses, erring toward "local": an over-admitted name
  /// is left verbatim (at worst forgoing a lazy host), never mis-rewritten to a
  /// wrong outer correlation.
  private func extend(_ locals: inout Locals, with relation: Relation) {
    locals.aliases.insert((relation.alias ?? relation.name).lowercased())
    guard let names = expose(relation) else {
      locals.opaque = true
      return
    }
    locals.names.formUnion(names)
  }

  /// The exposed unqualified column names of `relation` — the surface a bare
  /// name in a subquery whose FROM names it binds against — or `nil` when they
  /// cannot be derived pre-compile (an indeterminate local the caller records
  /// `opaque`). An explicit `AS t(c, …)` list names the columns directly; a
  /// `.named` relation resolves through the derived `schemas` on its `bindable`
  /// surface (a base table's real and virtual columns, a view's declared
  /// columns, a CTE's or store relation's columns and virtual `Id`); and a
  /// `.derived` table takes its inner query's output names, indeterminate only
  /// for a `SELECT *` over a source the map does not name.
  private func expose(_ relation: Relation) -> Set<String>? {
    if !relation.columns.isEmpty {
      return Set(relation.columns.map { $0.lowercased() })
    }
    switch relation.source {
    case let .named(name):
      return schemas[name.lowercased()]?.bindable
    case let .derived(query):
      return outputs(of: query)
    }
  }

  /// The unqualified output names a derived table's `query` exposes, or `nil`
  /// when they cannot be derived — a `SELECT *` over a source the map does not
  /// name. An explicit projection contributes each named item (an alias, else a
  /// bare column); an unnamed computed item exposes no bindable name and adds
  /// none. A `SELECT *` derives through `starred` — the real columns of its own
  /// FROM/JOIN sources, the engine's `*` expansion (`Scope.terms(.all)`), so a
  /// `(SELECT * FROM Emp) e` exposes `Emp`'s real columns and an unqualified
  /// group-key-colliding name binds there rather than arm-lifting. A set
  /// operation takes the left arm's names (ISO 9075 output naming); a `VALUES`
  /// body exposes the default column names the engine's `VALUES` schema
  /// derivation assigns — `column1 … columnN` for an N-column row
  /// (`Query.names`) — so an unqualified `column1` over a `(VALUES …)` derived
  /// table binds locally rather than being mis-rewritten to an outer group key.
  private func outputs(of query: Query) -> Set<String>? {
    switch query.body {
    case let .select(select):
      switch select.projection {
      case .all:
        return starred(select)
      case let .columns(columns):
        return Set(columns.map { $0.name.lowercased() })
      case let .expressions(items):
        return Set(items.compactMap { $0.name?.lowercased() })
      }
    case let .setop(_, left, _, _):
      return outputs(of: left)
    case let .values(rows):
      return Set((0 ..< (rows.first?.count ?? 0)).map { "column\($0 + 1)" })
    }
  }

  /// The real columns a `SELECT *` over `select`'s FROM/JOIN sources exposes —
  /// the engine's `*` expansion (`Scope.terms(.all)`), which enumerates each
  /// source relation's real columns in chain order (never a virtual column and
  /// never a merged constituent, both of which name no column the union
  /// enumeration omits), unioned as a set since membership tests names alone.
  /// `nil` when any source's columns cannot be derived (a nested `SELECT *`
  /// over a source the map does not name), so the whole `*` output is opaque.
  private func starred(_ select: Select) -> Set<String>? {
    guard var columns = reals(of: select.from) else { return nil }
    for join in select.joins {
      guard let names = reals(of: join.relation) else { return nil }
      columns.formUnion(names)
    }
    return columns
  }

  /// The real columns `relation` contributes to a `SELECT *` expansion — an
  /// explicit `AS t(c, …)` list, a base table's/view's/CTE's real columns (the
  /// `real` surface, never a virtual `Id`, which `*` omits), or a derived
  /// table's own output names (recursing `outputs`). `nil` when a `.named`
  /// source is absent from the map or a nested derived `SELECT *` is opaque.
  private func reals(of relation: Relation) -> Set<String>? {
    if !relation.columns.isEmpty {
      return Set(relation.columns.map { $0.lowercased() })
    }
    switch relation.source {
    case let .named(name):
      return schemas[name.lowercased()]?.real
    case let .derived(query):
      return outputs(of: query)
    }
  }

  /// A projection's free qualified group-key references rewritten. A `.columns`
  /// list keeps its `.columns` shape (a rewrite maps a bare column to a bare
  /// column — verbatim, or its `*gwN` union reference), but the rewritten
  /// list rides through only when every column's identity is unchanged. A
  /// rewrite that remapped a group-key column to its synthetic `*gwN`
  /// reference changed an identity (`synthetic` participates in `Column`
  /// equality), so the rewritten columns are retained — returning the
  /// original there would discard the reference and leave the group key
  /// unbindable in the outer union scope.
  private mutating func rewrite(_ projection: Projection, bound: Locals)
      -> Projection {
    switch projection {
    case .all:
      return .all
    case let .expressions(items):
      return .expressions(items.map {
        Projected(expression: rewrite($0.expression, bound: bound),
                  alias: $0.alias)
      })
    case let .columns(columns):
      let rewritten = columns.map { rewrite(.column($0), bound: bound) }
      let lifted = rewritten.compactMap { expression -> Column? in
        if case let .column(column) = expression { column } else { nil }
      }
      if lifted == columns { return projection }
      if lifted.count == rewritten.count { return .columns(lifted) }
      return .expressions(rewritten.map { Projected(expression: $0) })
    }
  }

  /// A grouping's keys' free qualified group-key references rewritten
  /// — a `.keys` its list, a `.sets` each set, an `.arm` its keys and superset.
  private mutating func rewrite(_ grouping: Grouping, bound: Locals)
      -> Grouping {
    switch grouping {
    case let .keys(keys):
      return .keys(rewrite(keys, bound: bound))
    case let .sets(sets):
      return .sets(sets.map { rewrite($0, bound: bound) })
    case let .arm(keys, superset):
      return .arm(keys: rewrite(keys, bound: bound),
                  superset: rewrite(superset, bound: bound))
    }
  }

  /// An ORDER BY's sort-key expressions rewritten — an ordinal key carried
  /// through, a value key's expression rewritten (its `output` kept).
  private mutating func rewrite(_ order: Order?, bound: Locals) -> Order? {
    guard let order else { return nil }
    return Order(keys: order.keys.map { key in
      guard case let .expression(expression) = key.sort else { return key }
      var rewritten = Order.Key(sort: .expression(rewrite(expression,
                                                          bound: bound)),
                                ascending: key.ascending)
      rewritten.output = key.output
      return rewritten
    })
  }

  /// A window specification's `PARTITION BY` keys and `ORDER BY` values
  /// rewritten, the base/parenthesized flags and frame carried through — the
  /// frame's bounds hold no column reference `collect(free:bound:)` descends.
  private mutating func rewrite(_ spec: WindowSpec, bound: Locals)
      -> WindowSpec {
    WindowSpec(base: spec.base, parenthesized: spec.parenthesized,
               partition: rewrite(spec.partition, bound: bound),
               order: rewrite(spec.order, bound: bound), frame: spec.frame)
  }

  /// This expression's free group-key references rewritten — the transforming
  /// twin of `Expression.collect(free:bound:)`. A `.column` leaf decides by
  /// qualifier and local membership (rewrite a non-local group-key reference,
  /// leave a locally-bound one, block an undecidable one); every other node
  /// keeps its structure and recurses its operands, descending a scalar
  /// `.subquery`'s body and a window's operands so a correlation nested at any
  /// depth is rewritten.
  private mutating func rewrite(_ expression: Expression, bound: Locals)
      -> Expression {
    switch expression {
    case let .column(column):
      let name = column.name.lowercased()
      guard let qualifier = column.qualifier else {
        // A carrier `ORDER BY` reference (`riding`) binds the set-op output by
        // ISO output-alias/ordinal precedence, and a non-key name is no
        // correlation — both left verbatim. Otherwise decide by inner-scope
        // precedence against the local relations: a name a determinate local
        // exposes (real or virtual) binds there, left verbatim; a name absent
        // from every determinate local with no opaque local in scope is the
        // outer group key, rewritten to its `*gwN` union column; a name absent
        // from the determinate locals but possibly hiding in an opaque local
        // (a `SELECT *` over a source the schema map does not name) is
        // undecidable, so it blocks and the subquery arm-lifts.
        guard !riding, keys.contains(name) else { return expression }
        if bound.names.contains(name) { return expression }
        guard !bound.opaque else {
          blocked = true
          return expression
        }
        return reference(.column(column))
      }
      guard !bound.aliases.contains(qualifier.lowercased()),
          keys.contains(name) else { return expression }
      return reference(.column(column))
    case .literal:
      return expression
    case let .call(name, arguments):
      return .call(name: name, arguments: rewrite(arguments, bound: bound))
    case let .binary(operation, lhs, rhs):
      return .binary(operation, rewrite(lhs, bound: bound),
                     rewrite(rhs, bound: bound))
    case let .cast(operand, type):
      return .cast(rewrite(operand, bound: bound), type)
    case let .coalesce(arguments):
      return .coalesce(rewrite(arguments, bound: bound))
    case let .nullif(lhs, rhs):
      return .nullif(rewrite(lhs, bound: bound), rewrite(rhs, bound: bound))
    case let .aggregate(aggregate, operand, distinct, filter):
      let lifted: Aggregand = switch operand {
      case .star:
        .star
      case let .expression(argument):
        .expression(rewrite(argument, bound: bound))
      }
      return .aggregate(aggregate, of: lifted, distinct: distinct,
                        filter: filter.map { rewrite($0, bound: bound) })
    case let .grouping(arguments):
      return .grouping(rewrite(arguments, bound: bound))
    case let .case(whens, otherwise):
      let branches = whens.map {
        When(when: rewrite($0.when, bound: bound),
             then: rewrite($0.then, bound: bound))
      }
      return .case(branches, else: otherwise.map { rewrite($0, bound: bound) })
    case let .subquery(query):
      return .subquery(rewrite(query, bound: bound))
    case let .window(function, spec):
      return .window(function: rewrite(function, bound: bound),
                     spec: rewrite(spec, bound: bound))
    }
  }

  /// This window function's operands' free qualified group-key references
  /// rewritten — transforming twin of `WindowFunction.collect(free:bound:)`.
  private mutating func rewrite(_ function: WindowFunction, bound: Locals)
      -> WindowFunction {
    switch function {
    case .number, .rank, .dense, .ntile, .percent, .cumulative:
      return function
    case let .aggregate(aggregate, operand, distinct, filter):
      let lifted: Aggregand = switch operand {
      case .star:
        .star
      case let .expression(argument):
        .expression(rewrite(argument, bound: bound))
      }
      return .aggregate(aggregate, of: lifted, distinct: distinct,
                        filter: filter.map { rewrite($0, bound: bound) })
    case let .lead(value, offset, fallback):
      return .lead(rewrite(value, bound: bound), offset: offset,
                   default: fallback.map { rewrite($0, bound: bound) })
    case let .lag(value, offset, fallback):
      return .lag(rewrite(value, bound: bound), offset: offset,
                  default: fallback.map { rewrite($0, bound: bound) })
    case let .first(value):
      return .first(rewrite(value, bound: bound))
    case let .last(value):
      return .last(rewrite(value, bound: bound))
    case let .nth(value, position):
      return .nth(rewrite(value, bound: bound), position)
    }
  }

  /// This predicate's free qualified group-key references rewritten — the
  /// transforming twin of `Predicate.collect(free:bound:)`, descending its
  /// operand expressions, nested predicates, and every `EXISTS`/`IN`/quantified
  /// subquery body (which extends `bound` with its own aliases).
  private mutating func rewrite(_ predicate: Predicate, bound: Locals)
      -> Predicate {
    switch predicate {
    case let .exists(query, negated):
      return .exists(rewrite(query, bound: bound), negated: negated)
    case let .within(lhs, query, negated):
      return .within(rewrite(lhs, bound: bound), rewrite(query, bound: bound),
                     negated: negated)
    case let .quantified(lhs, op, quantifier, query):
      return .quantified(rewrite(lhs, bound: bound), op, quantifier,
                         rewrite(query, bound: bound))
    case let .comparison(left, op, right):
      return .comparison(left: rewrite(left, bound: bound), op: op,
                         right: rewrite(right, bound: bound))
    case let .bound(left, op, parameter):
      return .bound(left: rewrite(left, bound: bound), op: op,
                    parameter: parameter)
    case let .null(operand, negated):
      return .null(rewrite(operand, bound: bound), negated: negated)
    case let .membership(operand, values, negated):
      return .membership(rewrite(operand, bound: bound),
                         rewrite(values, bound: bound), negated: negated)
    case let .rows(lhs, op, rhs):
      return .rows(rewrite(lhs, bound: bound), op, rewrite(rhs, bound: bound))
    case let .among(lhs, rows, negated):
      return .among(rewrite(lhs, bound: bound),
                    rows.map { rewrite($0, bound: bound) }, negated: negated)
    case let .like(operand, pattern, escape, negated):
      return .like(rewrite(operand, bound: bound),
                   pattern: rewrite(pattern, bound: bound),
                   escape: escape.map { rewrite($0, bound: bound) },
                   negated: negated)
    case let .between(operand, lower, upper, negated):
      return .between(rewrite(operand, bound: bound),
                      rewrite(lower, bound: bound),
                      rewrite(upper, bound: bound), negated: negated)
    case let .distinct(lhs, rhs, negated):
      return .distinct(rewrite(lhs, bound: bound), rewrite(rhs, bound: bound),
                       negated: negated)
    case let .truth(inner, value, negated):
      return .truth(rewrite(inner, bound: bound), value: value,
                    negated: negated)
    case let .and(lhs, rhs):
      return .and(rewrite(lhs, bound: bound), rewrite(rhs, bound: bound))
    case let .or(lhs, rhs):
      return .or(rewrite(lhs, bound: bound), rewrite(rhs, bound: bound))
    case let .not(inner):
      return .not(rewrite(inner, bound: bound))
    }
  }

  /// A `LIKE`/`BETWEEN` operand's free references rewritten — an expression
  /// recursed, a `:parameter` carried through.
  private mutating func rewrite(_ operand: Predicate.Operand,
                                bound: Locals) -> Predicate.Operand {
    guard case let .expression(expression) = operand else { return operand }
    return .expression(rewrite(expression, bound: bound))
  }

  /// Each expression of `expressions` rewritten, in order.
  private mutating func rewrite(_ expressions: Array<Expression>,
                                bound: Locals) -> Array<Expression> {
    expressions.map { rewrite($0, bound: bound) }
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
  /// A subquery-bearing form (`exists`/`within`/`quantified`) keeps its
  /// subquery hosted whole — the union-scope `Resolution` the outer layer
  /// resolves against hosts it in place — but still substitutes the operands
  /// beside the subquery: the left row of `(l…) IN (subquery)` or a quantified
  /// `(l…) op {ANY|ALL} (subquery)`, so a grounded left (`dept IN (…)` → `*gw0
  /// IN (…)`) the `*gwN`-only outer scope cannot resolve becomes an arm column,
  /// as it does in a scalar position. `EXISTS` carries no operand beside its
  /// subquery, so it rebuilds unchanged.
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
    case let .exists(query, negated):
      // `[NOT] EXISTS (subquery)` carries only the subquery, hosted by the
      // outer layer's union-scope `Resolution`. A subquery correlated to a
      // key by a qualified-free reference has that reference rewritten to its
      // `*gwN` column (`host`), so it resolves against the union scope as a
      // correlated parameter; an uncorrelated one rides through unchanged.
      // A `*gwN` column cannot stand in for a whole predicate subquery, so
      // there is no arm-lift here: an unqualified-ambiguous correlation (`host`
      // returns `nil`) hosts verbatim, the residual behaviour unchanged.
      return .exists(host(query) ?? query, negated: negated)
    case let .within(left, query, negated):
      // `(l…) [NOT] IN (subquery)` — the subquery is hosted (its qualified-
      // free correlations rewritten by `host`), and the left row still
      // holds grounded operands the `*gwN`-only outer scope cannot resolve, so
      // substitute them (`dept IN (…)` → `*gw0 IN (…)`).
      return try .within(substitute(left), host(query) ?? query,
                         negated: negated)
    case let .quantified(left, op, quantifier, query):
      // `(l…) op {ANY|ALL} (subquery)` — as `within`: host the subquery whole
      // (rewriting its qualified-free correlations) and substitute the row.
      return try .quantified(substitute(left), op, quantifier,
                             host(query) ?? query)
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

  /// This expression canonicalised for the grouping-key membership test — the
  /// pre-scope approximation of the resolved identity grouped lowering matches
  /// a key by. `Grouped.term` equates a projection/`HAVING`/`ORDER BY`
  /// expression with a `GROUP BY` key when the two lower to the same `Term`
  /// under `scope.term`, which resolves a column's qualifier to its ordinal (so
  /// `T.A` and `A` collapse) and case-folds every identifier (so `A` and `a`
  /// collapse, and a scalar-call name lowercases), then compares structurally.
  /// With no scope here to resolve an ordinal, this mirrors those two
  /// normalisations syntactically: each column drops its qualifier and
  /// lowercases its name, each scalar-call name lowercases, and the rest of the
  /// tree recurses structurally — so a computed grouping key spelled `T.A + 1`,
  /// `A + 1`, or `a + 1` canonicalises to one form the member set matches,
  /// exactly as the arm's real `Grouped.term` equates them once it has a scope.
  ///
  /// Dropping the qualifier can over-collapse two distinct relations' same-
  /// named columns (`R.A` vs `S.A`) the resolved term keeps apart, but that
  /// only lifts a whole non-key expression the arm's grouped resolver then
  /// rejects with the same `.grouping` fault, never a wrong success. A `CASE`
  /// guard `Predicate` canonicalises through `Predicate.canonical` — the same
  /// two normalisations over its operand expressions — so a computed `CASE` key
  /// matches a qualification- or case-variant projection of it (`CASE WHEN
  /// T.A = 1 …` ≡ `CASE WHEN a = 1 …`), as the arm's `Grouped.term` equates the
  /// whole `CASE` once it has a scope. A scalar `subquery` body and a `window`
  /// specification recurse no further (neither is a legal grouping-key operand
  /// the arm would accept), so a qualifier or case variance buried in one is a
  /// residual matched only verbatim — a conservative under-match that forgoes
  /// the whole-key lift and descends, as before.
  fileprivate var canonical: Expression {
    switch self {
    case let .column(column):
      return .column(Column(name: column.name.lowercased()))
    case .literal:
      return self
    case let .call(name, arguments):
      return .call(name: name.lowercased(),
                   arguments: arguments.map { $0.canonical })
    case let .binary(operation, lhs, rhs):
      return .binary(operation, lhs.canonical, rhs.canonical)
    case let .cast(operand, type):
      return .cast(operand.canonical, type)
    case let .coalesce(arguments):
      return .coalesce(arguments.map { $0.canonical })
    case let .nullif(lhs, rhs):
      return .nullif(lhs.canonical, rhs.canonical)
    case let .aggregate(aggregate, operand, distinct, filter):
      let canonical: Aggregand = switch operand {
      case .star:
        .star
      case let .expression(expression):
        .expression(expression.canonical)
      }
      return .aggregate(aggregate, of: canonical, distinct: distinct,
                        filter: filter)
    case let .grouping(arguments):
      return .grouping(arguments.map { $0.canonical })
    case let .case(whens, otherwise):
      let branches = whens.map {
        When(when: $0.when.canonical, then: $0.then.canonical)
      }
      return .case(branches, else: otherwise?.canonical)
    case .subquery, .window:
      return self
    }
  }
}

extension Predicate {
  /// This predicate canonicalised for the grouping-key membership test — the
  /// pre-scope approximation of the resolved identity grouped lowering a `CASE`
  /// key's guard matches by. It mirrors `Expression.canonical`'s two
  /// normalisations over every operand expression the predicate carries — a
  /// column drops its qualifier and lowercases its name, a scalar-call name
  /// lowercases — and recurses each nested predicate, so a guard spelled
  /// `T.A = 1` and one spelled `a = 1` canonicalise to one form, exactly as the
  /// whole `CASE`'s `Grouped.term` equates the two keys once it has a scope.
  ///
  /// A nested `EXISTS`/`IN`/quantified subquery body stays structural — as
  /// `Expression.canonical` leaves a `.subquery` body — so a qualifier or case
  /// variance buried in one is matched only verbatim, a conservative under-
  /// match. The operand expressions beside the subquery (the left row of an
  /// `IN`/quantified) still canonicalise, as they do in a scalar position.
  fileprivate var canonical: Predicate {
    switch self {
    case let .comparison(left, op, right):
      return .comparison(left: left.canonical, op: op, right: right.canonical)
    case let .bound(left, op, parameter):
      return .bound(left: left.canonical, op: op, parameter: parameter)
    case let .null(operand, negated):
      return .null(operand.canonical, negated: negated)
    case let .membership(operand, values, negated):
      return .membership(operand.canonical, values.map { $0.canonical },
                         negated: negated)
    case let .rows(lhs, op, rhs):
      return .rows(lhs.map { $0.canonical }, op, rhs.map { $0.canonical })
    case let .among(lhs, rows, negated):
      return .among(lhs.map { $0.canonical },
                    rows.map { $0.map { $0.canonical } }, negated: negated)
    case let .like(operand, pattern, escape, negated):
      return .like(operand.canonical, pattern: pattern.canonical,
                   escape: escape?.canonical, negated: negated)
    case let .between(operand, lower, upper, negated):
      return .between(operand.canonical, lower.canonical, upper.canonical,
                      negated: negated)
    case let .distinct(lhs, rhs, negated):
      return .distinct(lhs.canonical, rhs.canonical, negated: negated)
    case let .truth(inner, value, negated):
      return .truth(inner.canonical, value: value, negated: negated)
    case let .and(lhs, rhs):
      return .and(lhs.canonical, rhs.canonical)
    case let .or(lhs, rhs):
      return .or(lhs.canonical, rhs.canonical)
    case let .not(inner):
      return .not(inner.canonical)
    case let .within(lhs, query, negated):
      return .within(lhs.map { $0.canonical }, query, negated: negated)
    case let .quantified(lhs, op, quantifier, query):
      return .quantified(lhs.map { $0.canonical }, op, quantifier, query)
    case .exists:
      return self
    }
  }
}

extension Predicate.Operand {
  /// This `LIKE`/`BETWEEN` operand canonicalised — an ordinary expression
  /// through `Expression.canonical`, a `:parameter` left verbatim (it names no
  /// column a qualifier or case variance could reach).
  fileprivate var canonical: Predicate.Operand {
    guard case let .expression(expression) = self else { return self }
    return .expression(expression.canonical)
  }
}

extension Query {
  /// The bare (case-folded) names of every column this query references
  /// freely — not qualified by a FROM/JOIN alias in `bound`, the local aliases
  /// accumulated from the enclosing subquery scopes down to here. It descends
  /// into its FROM/JOIN derived bodies, predicates, projection, grouping,
  /// HAVING, ORDER BY, window specifications, every nested subquery, and each
  /// carrier's query-level `ORDER BY`, each `.select` extending `bound` with
  /// its own aliases so a nested subquery binds its own references in turn.
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    switch body {
    case let .select(select):
      select.collect(free: &names, bound: bound)
    case let .setop(_, left, right, _):
      left.collect(free: &names, bound: bound)
      right.collect(free: &names, bound: bound)
    case let .values(rows):
      for row in rows {
        for expression in row { expression.collect(free: &names, bound: bound) }
      }
    }
    // Parity with the rewrite twin: a carrier's `ORDER BY` rides above the body
    // and may hold a correlation the rewrite lifts (a set-op `ORDER BY T.Id`),
    // so descend its keys too. This gathers group-key names, not the host
    // decision (which runs through `rewrite`/`blocked`), so it stays in sync
    // with `rewrite(_ carrier:)` and no future free-reference consumer misses a
    // carrier correlation.
    for carrier in carriers {
      for key in carrier.order?.keys ?? [] {
        if case let .expression(expression) = key.sort {
          expression.collect(free: &names, bound: bound)
        }
      }
    }
  }
}

extension Select {
  /// The bare names of every column this select references freely, given the
  /// `bound` aliases of the enclosing subquery scopes. It extends `bound` with
  /// its own FROM/JOIN aliases — the qualifier each relation's columns bind
  /// under, `alias ?? name`, matching `Scope.admits` — so a reference qualified
  /// by a local alias is local, not free; a reference qualified by a non-local
  /// alias, or unqualified (undecidable pre-schema, so conservatively free), is
  /// collected. It descends into its FROM/JOIN derived bodies and `ON`s,
  /// predicate, projection, grouping keys, HAVING, ORDER BY, and named-window
  /// specifications.
  ///
  /// It builds the join prefix in source order, mirroring `rewrite(_ select:)`
  /// and compilation: a join's derived body sees the PRECEDING aliases (itself
  /// excluded), its `ON` the prefix extended with its own alias, and the
  /// remaining clauses the full scope — so a reference qualified by a
  /// later-joined alias is free in an earlier `ON`, exactly as prefix-scoped
  /// resolution binds it.
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    from.collect(free: &names, bound: bound)
    var prefix = bound
    prefix.insert((from.alias ?? from.name).lowercased())
    for join in joins {
      join.relation.collect(free: &names, bound: prefix)
      prefix.insert((join.relation.alias ?? join.relation.name).lowercased())
      join.on.collect(free: &names, bound: prefix)
    }
    let locals = prefix
    predicate?.collect(free: &names, bound: locals)
    switch projection {
    case .all:
      break
    case let .columns(columns):
      for column in columns { column.collect(free: &names, bound: locals) }
    case let .expressions(items):
      for item in items {
        item.expression.collect(free: &names, bound: locals)
      }
    }
    for key in grouping.collected { key.collect(free: &names, bound: locals) }
    having?.collect(free: &names, bound: locals)
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(free: &names, bound: locals)
      }
    }
    for definition in window {
      for expression in definition.spec.expressions {
        expression.collect(free: &names, bound: locals)
      }
    }
  }
}

extension Column {
  /// This column's bare name inserted into `names` when it is a free
  /// reference — unqualified (undecidable against a base relation's schema
  /// pre-compilation, so conservatively free) or qualified by an alias not in
  /// `bound`, the local FROM/JOIN aliases in scope. A reference qualified by a
  /// local alias is bound, so it contributes nothing.
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    if let qualifier, bound.contains(qualifier.lowercased()) { return }
    names.insert(name.lowercased())
  }
}

extension Relation {
  /// The bare names a relation references freely — a `.derived` one by
  /// recursing into its inner query (which extends `bound` with its own
  /// aliases), a `.named` one none (its columns are named at resolution, not in
  /// the AST).
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    if case let .derived(query) = source {
      query.collect(free: &names, bound: bound)
    }
  }
}

extension Expression {
  /// The bare (case-folded) names of every column this expression references
  /// freely, given the `bound` aliases in scope, descending into a scalar
  /// `subquery`'s body (which extends `bound` with its own aliases) and a
  /// window's operands so a correlation nested at any depth is seen.
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    switch self {
    case let .column(column):
      column.collect(free: &names, bound: bound)
    case .literal:
      break
    case let .call(_, arguments), let .coalesce(arguments),
         let .grouping(arguments):
      for argument in arguments { argument.collect(free: &names, bound: bound) }
    case let .binary(_, lhs, rhs), let .nullif(lhs, rhs):
      lhs.collect(free: &names, bound: bound)
      rhs.collect(free: &names, bound: bound)
    case let .cast(operand, _):
      operand.collect(free: &names, bound: bound)
    case let .aggregate(_, operand, _, filter):
      if case let .expression(argument) = operand {
        argument.collect(free: &names, bound: bound)
      }
      filter?.collect(free: &names, bound: bound)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(free: &names, bound: bound)
        when.then.collect(free: &names, bound: bound)
      }
      otherwise?.collect(free: &names, bound: bound)
    case let .subquery(query):
      query.collect(free: &names, bound: bound)
    case let .window(function, spec):
      for expression in spec.expressions {
        expression.collect(free: &names, bound: bound)
      }
      function.collect(free: &names, bound: bound)
    }
  }
}

extension WindowFunction {
  /// The bare names of every column this window function's operands reference
  /// freely — an aggregate's argument and FILTER, a positional value and
  /// default, a FIRST/LAST/NTH value.
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    switch self {
    case .number, .rank, .dense, .ntile, .percent, .cumulative:
      break
    case let .aggregate(_, operand, _, filter):
      if case let .expression(argument) = operand {
        argument.collect(free: &names, bound: bound)
      }
      filter?.collect(free: &names, bound: bound)
    case let .lead(value, _, fallback), let .lag(value, _, fallback):
      value.collect(free: &names, bound: bound)
      fallback?.collect(free: &names, bound: bound)
    case let .first(value), let .last(value), let .nth(value, _):
      value.collect(free: &names, bound: bound)
    }
  }
}

extension Predicate {
  /// The bare names of every column this predicate references freely — its
  /// operand expressions, nested predicates, and the body of any `EXISTS`/`IN`/
  /// quantified subquery (which extends `bound` with its own aliases).
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    switch self {
    case let .exists(query, _):
      query.collect(free: &names, bound: bound)
    case let .within(lhs, query, _):
      for expression in lhs { expression.collect(free: &names, bound: bound) }
      query.collect(free: &names, bound: bound)
    case let .quantified(lhs, _, _, query):
      for expression in lhs { expression.collect(free: &names, bound: bound) }
      query.collect(free: &names, bound: bound)
    case let .comparison(left, _, right):
      left.collect(free: &names, bound: bound)
      right.collect(free: &names, bound: bound)
    case let .bound(left, _, _):
      left.collect(free: &names, bound: bound)
    case let .null(operand, _):
      operand.collect(free: &names, bound: bound)
    case let .membership(operand, values, _):
      operand.collect(free: &names, bound: bound)
      for value in values { value.collect(free: &names, bound: bound) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(free: &names, bound: bound) }
      for expression in rhs { expression.collect(free: &names, bound: bound) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(free: &names, bound: bound) }
      for row in rows {
        for expression in row { expression.collect(free: &names, bound: bound) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(free: &names, bound: bound)
      pattern.collect(free: &names, bound: bound)
      escape?.collect(free: &names, bound: bound)
    case let .between(operand, lower, upper, _):
      operand.collect(free: &names, bound: bound)
      lower.collect(free: &names, bound: bound)
      upper.collect(free: &names, bound: bound)
    case let .distinct(lhs, rhs, _):
      lhs.collect(free: &names, bound: bound)
      rhs.collect(free: &names, bound: bound)
    case let .truth(inner, _, _):
      inner.collect(free: &names, bound: bound)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(free: &names, bound: bound)
      rhs.collect(free: &names, bound: bound)
    case let .not(operand):
      operand.collect(free: &names, bound: bound)
    }
  }
}

extension Predicate.Operand {
  /// The bare names a `LIKE`/`BETWEEN` operand references freely — an
  /// expression's columns, a `:parameter` none.
  fileprivate func collect(free names: inout Set<String>, bound: Set<String>) {
    if case let .expression(expression) = self {
      expression.collect(free: &names, bound: bound)
    }
  }
}
