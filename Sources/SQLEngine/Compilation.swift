// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Compilation

extension Projection {
  /// Compiles this scalar (FROM-less) `SELECT <expr-list>` projection into
  /// `Project(single)` — the projection evaluated against the one empty row the
  /// `single` leaf yields — ordered and paged by any `order`/`limit` tail.
  ///
  /// The projection resolves against an empty schema (no columns), so only
  /// literals, scalar calls, and arithmetic over them lower; a `SELECT *` has
  /// no relation to expand and a bare-column reference no column to bind, each
  /// faulting (`SQLError.column` for a column, `SQLError.unsupported` for `*`).
  /// The terms hold no slots, so the `single` row's empty record carries every
  /// value the projection needs.
  ///
  /// `subquery` carries the compile-time width map of the uncorrelated
  /// subqueries the projection nests, so an `EXISTS`/`IN (Q)` inside a scalar
  /// term lowers exactly as it does on the FROM'd path — the FROM-less scalar
  /// select is otherwise the one path that would hit the default unsupported
  /// map and reject a subquery a run materialises. The `Resolution` is
  /// threaded, not run, here (see `subquery(of:)`).
  ///
  /// A projection is a barred clause position, so a correlated column of this
  /// query has no evaluator here. `Schema.terms` bars the seam intrinsically,
  /// so this FROM-less projection cannot admit correlation even when handed the
  /// admitting `plans.rest` — the same cut `columns(of:)` applies on the schema
  /// path, keeping run and derive in lockstep.
  ///
  /// A trailing `ORDER BY`/`OFFSET`·`FETCH` (`order`/`limit`) orders and pages
  /// that single row through the shared `shaped` plan shape, so a FROM-less
  /// query expression's tail runs (`VALUES (1) ORDER BY 1`) rather than
  /// faulting. An empty schema binds only an ordinal or an output-alias key —
  /// the sole ISO keys over a FROM-less select, which has no source column to
  /// order on — so an ordinary column key faults (`SQLError.column`) as it does
  /// on the projection.
  internal func scalar(_ routines: Routines = [:],
                       subquery: Resolution = .unsupported,
                       distinct: Bool = false,
                       order: Order? = nil, limit: Limit? = nil)
      throws(SQLError) -> Plan {
    guard case .all = self else {
      let schema = Schema(width: 0, extent: 0, names: [], types: [],
                          virtuals: [])
      let relation = Relation(name: "")
      let terms = try schema.terms(self, in: relation, routines,
                                   subquery: subquery)
      var keys = Array<SortKey>()
      if let order {
        let names = self.outputs(count: terms.count)
        keys = try schema.order(order, in: relation, terms, names, routines,
                                subquery: subquery)
        // Every FROM-less ORDER BY key is a select-list output already, so the
        // DISTINCT rule (a key must be a projected value) rebinds none; the
        // call still enforces it against a direct `Select`.
        if distinct { keys = try SQLEngine.distinct(order.keys, keys, terms) }
      }
      return Plan.single.shaped(distinct: distinct, projection: terms,
                                filter: nil, order: keys, limit: limit)
    }
    // `SELECT *` names every column of the relations in scope; a FROM-less
    // query has none, so there is nothing to expand.
    throw .unsupported("SELECT * requires a FROM clause")
  }
}

/// A relation resolved for compilation: its name-resolution `schema` and a
/// `leaf` factory that, given the ordinals the query references on its side,
/// builds the leaf `Plan` — a `scan` for a base table, a `derived` over the
/// view's compiled sub-plan for a view.
internal struct Resolved {
  let schema: Schema
  let leaf: (Array<Int>) -> Plan
}

/// The sorted, deduplicated ordinals a query references: the union of the
/// ordinals its `projection` terms read, the columns its `filter` reads, and
/// every column its `order` keys read. The projection terms hold ordinals at
/// this stage; a scalar call's arguments contribute their read ordinals too.
private func referenced(_ projection: Array<Term>, _ filter: Filter?,
                        _ order: Array<SortKey>)
    -> Array<Int> {
  var ordinals = Set<Int>()
  for term in projection {
    term.references(into: &ordinals)
  }
  filter?.references(into: &ordinals)
  for key in order { key.term.references(into: &ordinals) }
  return ordinals.sorted()
}

/// The inverse map `ordinal → slot` of a referenced-ordinal list: slot `i` is
/// `ordinals[i]`, so the map sends `ordinals[i]` back to `i`.
private func invert(_ ordinals: Array<Int>) -> Dictionary<Int, Int> {
  var slot = Dictionary<Int, Int>(minimumCapacity: ordinals.count)
  for index in ordinals.indices {
    slot[ordinals[index]] = index
  }
  return slot
}

/// Rejects an `ORDER BY` key ordering on a value outside the `DISTINCT` output.
///
/// `SELECT DISTINCT` sorts the pre-projection rows then dedups the projected
/// ones, so ordering on a value the projection drops is ill-defined — after
/// dedup one output row stands for many source rows, whose differing sort-key
/// values leave no single order. The standard therefore requires every
/// `ORDER BY` key under `DISTINCT` to be a value of the select list, as the
/// grouped path requires for `GROUP BY`. An ordinal or an output-alias key
/// references a select-list output by construction (`SortKey.output`), so it
/// satisfies the rule whatever its term computes — its value is constant across
/// a dedup group. An ordinary input expression key satisfies it when either it
/// reads a projected column — its resolved `Term` is a bare `.slot` (a plain
/// column read) that a projected bare-slot term also reads — or it repeats a
/// projected select-list expression: its AST `Expression` is structurally equal
/// to a projected one (`SELECT DISTINCT A + B AS total … ORDER BY A + B`), so
/// the key orders on a projected distinct value and is well-defined, exactly as
/// the alias `ORDER BY total` and the ordinal `ORDER BY 1` naming that same
/// output are. A key ordering on any other value faults `SQLError.distinct`.
///
/// The satisfying comparison is over the resolved `Term`s, not the AST: a key
/// whose lowered `term` equals a projected item's lowered `term` orders on a
/// projected value. Lowering normalizes column qualification to a slot, so a
/// key that differs from its projected twin ONLY in qualification — `SELECT
/// DISTINCT A + 1 AS v … ORDER BY People.A + 1` against a projected `A + 1`,
/// where the two `.column`s resolve to the same slot — matches, as its
/// unqualified spelling and its alias/ordinal already do. The one comparison
/// runs in whatever slot space the caller resolved into (base ordinals on the
/// non-aggregate paths, grouped slots on the grouped path); `order` and
/// `projection` share it, so it serves every compile path, and it subsumes the
/// bare-projected-column case (`ORDER BY <projectedColumn>` lowers to the same
/// `.slot` the projection reads). `keys` supplies the AST key's spelling for
/// the fault message; each resolved order key pairs index-for-index with it.
///
/// A matching input key is rebound to the projected column it matched: this
/// returns the order keys with each satisfying input key's `column` set to the
/// index of the projection item whose term it equals, so the DISTINCT
/// materialisation sorts on that already-materialised projected slot rather
/// than appending and re-evaluating `term` — a re-evaluation that would
/// misorder a non-deterministic or stateful key (`ORDER BY tick()` against a
/// projected `tick()`). An ordinal/alias key already names its column and
/// passes through.
internal func distinct(_ keys: Array<Order.Key>, _ order: Array<SortKey>,
                       _ projection: Array<Term>)
    throws(SQLError) -> Array<SortKey> {
  var bound = order
  for index in order.indices where !order[index].output {
    guard let column = projection.firstIndex(of: order[index].term) else {
      throw .distinct(keys[index].name)
    }
    bound[index] = SortKey(term: order[index].term,
                           ascending: order[index].ascending, column: column)
  }
  return bound
}

extension Plan {
  /// This source plan wrapped in the projection/limit/sort/select operators,
  /// omitting each layer when its clause is absent. The `projection`, `filter`,
  /// and `order` keys are in slot space; an empty `order` omits the sort.
  ///
  /// Without `distinct` and with no `ORDER BY` key naming a select-list output
  /// (an ordinal or an output alias), the shape is `Project(Limit(Sort(_)))`:
  /// the row `limit` sits below the projection — after `WHERE` and `ORDER BY`
  /// but before the select list runs. A row outside the requested page is
  /// dropped by the limit before its projection runs, so a projection that
  /// could throw (`SELECT 1 / 0 … FETCH FIRST 0 ROWS ONLY`) never evaluates for
  /// a discarded row and the query returns the documented empty page.
  ///
  /// When an `ORDER BY` key names a select-list output over a computed
  /// expression (`SELECT next() AS n … ORDER BY n`), reusing the projection
  /// term as the pre-projection sort key would evaluate that expression twice
  /// — once to order, once to project — so a non-deterministic or stateful
  /// routine sorts on one set of values and returns a second, misordering the
  /// result. `materialised` instead computes the sort-referenced outputs once
  /// below the sort and orders an output key by that column, then a
  /// final projection reads those same values it sorted on (and computes the
  /// remaining, unreferenced outputs above the cap). `shaped` takes that shape
  /// exactly when a key names an output; a pure input-key `ORDER BY` keeps the
  /// simpler `Project(Sort(_))` (its keys need input columns the materialised
  /// row has projected away).
  ///
  /// With `distinct` (`SELECT DISTINCT`) the dedup runs on the projected rows —
  /// after `ORDER BY`, before `OFFSET`/`FETCH` (the ISO order) — so the shape
  /// is `Limit(Distinct(Project(Sort(_))))`: the projection loses its cap
  /// (every candidate row must be projected to dedup it), the `distinct` dedups
  /// the projected rows, and the `limit` pages the deduplicated result. Its
  /// `ORDER BY` keys are all output values (the `distinct` rule), so the sort
  /// runs over the materialised projection here too.
  internal func shaped(distinct: Bool = false, projection: Array<Term>,
                       filter: Filter?, order: Array<SortKey>,
                       limit: Limit?) -> Plan {
    var plan = self
    if let filter {
      plan = .select(filter, plan)
    }

    // An output key names a materialised projection column; sorting on the
    // recomputed projection term instead would double-evaluate it (wrong for a
    // non-deterministic routine). Materialise the sort-referenced outputs once
    // below the sort, so the order reflects the returned values whenever a key
    // does — over the filtered `plan`, so a HAVING/WHERE above governs.
    if order.contains(where: { $0.output }) {
      return plan.materialised(distinct: distinct, projection: projection,
                               order: order, limit: limit)
    }

    if !order.isEmpty {
      let keys = order.map { (term: $0.term, ascending: $0.ascending) }
      plan = .sort(keys: keys, plan)
    }
    guard distinct else {
      return .project(projection, plan.capped(limit: limit))
    }
    return Plan.distinct(.project(projection, plan)).capped(limit: limit)
  }

  /// This plan (already filtered) shaped so an `ORDER BY` key naming an output
  /// sorts on exactly the value that output returns, computing each such output
  /// exactly once — the single-evaluation shape `shaped` picks when a key
  /// references the select list.
  ///
  /// Only the sort-referenced outputs are materialised below the sort. A `map`
  /// projection retains the input columns (slots `0 ..< self.slots`) and
  /// appends one materialised column per output an ORDER BY key names, then one
  /// per ordinary input sort key (an `ORDER BY a + b` over non-projected
  /// columns still needs its input terms). The sort orders by slots into that
  /// row — an output key by its materialised column, an input key by its
  /// appended (or existing input) column — so a computed output key is
  /// evaluated once and its sort value equals the value the row returns.
  ///
  /// The final projection produces each output from that row: a sort-referenced
  /// output reads its materialised slot (never recomputed, preserving the
  /// single evaluation), and any other output computes its expression from the
  /// retained input columns. Without `distinct` this final projection sits
  /// above the cap, so an unreferenced output (`SELECT x, 1 / 0 … ORDER BY x
  /// FETCH FIRST 0 ROWS`) evaluates only for rows the limit keeps — never for a
  /// dropped row, restoring the lazy `Project(Limit(_))` page the all-outputs
  /// shape regressed.
  ///
  /// With `distinct` the dedup runs on the whole projected row, so every output
  /// (not only the sort-referenced ones) is materialised below the distinct —
  /// the lazy split would dedup on a partial row. The `distinct` then dedups
  /// the projected rows and `limit` pages the deduplicated result.
  private func materialised(distinct: Bool, projection: Array<Term>,
                            order: Array<SortKey>, limit: Limit?) -> Plan {
    let width = projection.count

    // Under DISTINCT the dedup needs the full projected row, so materialise
    // every output below the sort (the sort keys are all outputs here) and let
    // the distinct dedup and the limit page the projected rows.
    if distinct {
      var lower = projection
      var keys = Array<(term: Term, ascending: Bool)>()
      keys.reserveCapacity(order.count)
      for key in order {
        if let column = key.column {
          keys.append((term: .slot(column), ascending: key.ascending))
        } else {
          keys.append((term: .slot(lower.count), ascending: key.ascending))
          lower.append(key.term)
        }
      }
      let sorted = Plan.sort(keys: keys, .project(lower, self))
      let outputs = (0 ..< width).map { Term.slot($0) }
      return Plan.distinct(.project(outputs, sorted)).capped(limit: limit)
    }

    // Retain the input columns, then append only the outputs an ORDER BY key
    // names (materialised once) and the input-only sort-key expressions. A
    // non-sort output stays out of this row — it is computed above the limit.
    let inputs = slots ?? 0
    var lower = (0 ..< inputs).map { Term.slot($0) }
    var materialised = Dictionary<Int, Int>()
    var keys = Array<(term: Term, ascending: Bool)>()
    keys.reserveCapacity(order.count)
    for key in order {
      if let column = key.column {
        // Materialise this output once, reusing its slot if an earlier key
        // named it too, and order by that slot.
        let slot: Int
        if let existing = materialised[column] {
          slot = existing
        } else {
          slot = lower.count
          materialised[column] = slot
          lower.append(projection[column])
        }
        keys.append((term: .slot(slot), ascending: key.ascending))
      } else {
        keys.append((term: .slot(lower.count), ascending: key.ascending))
        lower.append(key.term)
      }
    }

    let sorted = Plan.sort(keys: keys, .project(lower, self))
    // Each output reads its materialised slot when a key named it, else
    // computes its expression from the retained inputs (above the cap, lazily).
    let outputs = (0 ..< width).map { column -> Term in
      if let slot = materialised[column] {
        .slot(slot)
      } else {
        projection[column]
      }
    }
    return .project(outputs, sorted.capped(limit: limit))
  }
}

// MARK: - Compilation

extension Catalog where Self: ~Escapable {
  /// Compiles `query` over this catalog into a logical operator tree.
  ///
  /// A single `SELECT` compiles as itself; a set operation compiles recursively
  /// into a BINARY `setop` plan that mirrors the `Query`:
  /// `compile(.setop(kind, left, right, all))` is `.setop(kind, compile(left),
  /// compile(right), all)`. Each node carries its OWN `kind`/`all`, so the
  /// executor honours every operator distinctly — `(A UNION B) UNION ALL C`
  /// dedups `A ∪ B` before appending `C`, rather than treating the whole chain
  /// by the trailing arm's flag. The right arm must project the same column
  /// count as the query's first `SELECT` — the result columns — else
  /// `SQLError.arity`.
  ///
  internal borrowing func compile(_ query: Query,
                                  _ context: Context = Context())
      throws(SQLError) -> Plan {
    // Expand any `GROUP BY GROUPING SETS` select to its `UNION ALL` FIRST — the
    // same normalization `run` applies — so `compile` and a `columns(of:)`
    // derive over the same query cannot diverge. Idempotent for a `.keys`/
    // `.arm` select; a nested body re-enters and expands in turn.
    let query = try query.expanded
    // Bind the derived tables (and store relations) this query names in its own
    // FROM/JOIN before resolving its relations — SELECT-scoped, so a subquery
    // compiled through here binds its own aliases (an outer statement-global
    // pre-collection would leave a sibling subquery's same-named `t` bound to
    // the wrong one). Schema-only (`rows: false`): compilation reads schemas,
    // never a cursor. Idempotent when the caller already augmented (`run`).
    // `visited` carries the cyclic-view guard through, so a derived table in a
    // view body under resolution that names the view faults `.recursion`.
    // A nested subquery's FROM sees base tables and enclosing CTEs, NOT this
    // query's derived aliases — so the augmented `context` threads onward and
    // `subquery(of:)` reveals the base before lowering a subquery (this query's
    // and every enclosing query's derived aliases dropped, the CTEs and store
    // relations kept, a CTE a same-named derived alias here shadows still
    // visible). The layered overlay never overwrote the CTE, so no pre-augment
    // context is threaded. `validate` gates a derived body's eager type-check:
    // a run preflight passes `false` so a data-dependent body expression an
    // execution never evaluates is not rejected here (the outer query still
    // faults, and a reached body operand still faults at run), matching the
    // non-derived path; a schema check passes `true`.
    let context = try augment(context, for: query, rows: false)
    // A query-level `ORDER BY` / `DISTINCT` / `OFFSET`·`FETCH` over a set
    // operation rides the `ordered` carrier: compile the inner union, then
    // stack the row operators over its plan, resolved through the setop's
    // output scope (`ordered`). The row operators do NOT project, so the result
    // columns stay the union's — an identity projection over its output slots.
    if let carrier = query.carriers.last {
      let inner = Query(body: query.body,
                        carriers: Array(query.carriers.dropLast()))
      return try ordered(inner, distinct: carrier.distinct,
                         order: carrier.order, limit: carrier.limit,
                         generated: carrier.generated, context)
    }
    guard case let .setop(kind, left, right, all) = query.body else {
      // A carrier-free non-set-operation body is a single `SELECT` (a `.values`
      // body is intercepted ahead of this dispatch), compiled directly.
      guard case let .select(select) = query.body else {
        preconditionFailure("a carrier-free non-setop body is a SELECT")
      }
      return try compile(select, context)
    }

    // A set operation collects no derived aliases at the query level — arms are
    // scoped, so `collect(derived:)` stops at a `SELECT` — leaving the augment
    // above with no arm-local bindings. But the `SELECT *` arity check resolves
    // each arm's `*` before the recursive per-arm compile augments that arm, so
    // augment each arm's own derived aliases into a per-ARM scope first, as the
    // per-arm `compile`/`run` scope them: `SELECT * FROM (SELECT V FROM S) AS
    // d` resolves `d`'s width. It is per arm so the left arm's `d` never
    // leaks to the right (the arm-scoping fix); the width each check computes
    // matches what the arm actually produces at run.
    // Compare each operand's real output width — its leftmost arm's width less
    // the hidden `generated` sort columns the carriers on the path appended (a
    // parenthesised operand with an unprojected-aggregate ORDER BY carries one,
    // trimmed at its carrier), so a valid one-column union of such an operand
    // is not rejected on the leaked hidden column. `arity(_ query:_:)` descends
    // to the leftmost arm and augments it, so it measures a `SELECT`, a
    // `TABLE`, or a `VALUES` operand alike.
    let width = try real(trimming: query.generated,
                         of: arity(query, context))
    let count = try real(trimming: right.generated,
                         of: arity(right, context))
    guard count == width else { throw .arity(width, count) }
    // Both arms of a set-operation subquery correlate against the same
    // enclosing scope, so each lowers under the shared `context.outer`. The
    // per-column result types are unified across the arms (ISO) and carried on
    // the plan node: the `.setop` executor holds only the sub-plans, not the
    // arm `Query`s, so it cannot fold them at run — compute them here, where
    // the arm queries and scope are in hand, and coerce each arm's rows at run.
    // The arms' own native column types (each arm's own unified columns —
    // `types(unifying:)` folds a nested arm — the very rows `combine` coerces
    // to this node's unified `types`) are derived before the `types` local
    // shadows the deriver.
    //
    // These three derivations are a schema-only probe — they compute types, not
    // the arms' real plans (those are compiled from `context` below, at
    // `compile(left/right, context)`). The type derivation lowers any nested
    // subquery to read its width, which would record a correlated inner plan
    // into the shared runtime memo; that record is first-writer-wins, so a
    // later caller with a same-shaped subquery could reuse this view body's
    // plan (against the view's base) instead of its own CTE. Derive against a
    // context carrying an isolated throwaway memo — every other field (scope,
    // subscope, outer correlation, validate) preserved — so the probe's
    // recordings are discarded and only the real arm compiles below populate
    // the live memo.
    let probe = context.resolving(Subqueries())
    let l = try types(unifying: left, probe)
    let r = try types(unifying: right, probe)
    let types = try types(unifying: query, probe)
    // The columns this node widens — where the unified `types[c]` differs from
    // an arm's own native type — so the pushdown pass (a pure Plan rewrite with
    // no catalog) can keep a predicate over a widened column above the arms
    // rather than pushing it in, where an arm would test the pre-coercion
    // value. A column differing from either arm is coerced for that arm, so
    // record it; a homogeneous set operation matches both arms, leaving the
    // mask empty and the pushdown unchanged.
    let widened = Set(types.indices.filter {
      types[$0] != l[$0] || types[$0] != r[$0]
    })
    return try .setop(kind, compile(left, context), compile(right, context),
                      all: all, types: types, widened: widened)
  }

  /// The distinct uncorrelated subqueries `select` nests, each compiled once
  /// against this catalog and `context` for its column count — never run — into
  /// a `Resolution` map the predicate/projection lowering reads for arity, the
  /// seam that carries each sub-`Query` into its lowered `Filter` as data.
  ///
  /// This is cursor-free: it drives `compile`, which resolves schemas and reads
  /// the subquery's `Plan.width` without a cursor, so a schema-only path
  /// (`columns(of:)`, view resolution) that shares this lowering opens none and
  /// surfaces no data-dependent error. Every subquery in the `WHERE`, join
  /// `ON`s, `HAVING`, projection, `ORDER BY` expressions, and aggregate
  /// arguments and FILTERs is found by a syntactic walk and keyed by its own
  /// `Query` (which is `Hashable`), so lowering resolves each `EXISTS`/`IN (Q)`
  /// against the map by identity. A subquery compiles once even if it appears
  /// twice; it runs at execution (see `subqueries(of:)`), uncorrelated so once.
  ///
  /// `context.subscope` is the resolution context these subqueries lower under
  /// — `.caller` for a top-level compile, `.view(name)` for a view body's —
  /// carried into each lowered `Filter`'s cache key so a view-body occurrence
  /// and a top-level one over the same AST stay distinct entries (see
  /// `Subscope`).
  ///
  /// `enclosing` is the select's own resolution scope — the one its nested
  /// subqueries correlate against: each nested query compiles under a fresh
  /// `Outer` extending `context.outer` (this select's own enclosing scope, when
  /// it is itself a subquery) with `enclosing` the nearest scope, so a nested
  /// query's inner `WHERE` column binding none of its relations resolves
  /// against the enclosing select (and outward), lowering to a synthetic
  /// `Term.parameter` and recording the correlation the lowered node carries.
  /// The returned `Resolution` also carries `context.outer` so this select's
  /// own columns correlate outward when it is a subquery.
  ///
  /// `prefixes`, when supplied, gives the prefix scope each join `ON` lowers
  /// against — the FROM relation and joins `0…index`, never a relation joined
  /// later — so a subquery in join `i`'s `ON` correlates against `prefixes[i]`
  /// (the relations available at that join point) rather than the full join
  /// `enclosing`. A correlated reference to a later-joined relation then binds
  /// against none of the prefix's relations and faults `SQLError.column`,
  /// matching the direct `ON` resolver, which already uses the prefix scope. A
  /// non-join surface (WHERE/projection/HAVING/ORDER) correlates against
  /// `enclosing` as before.
  internal borrowing func subquery(of select: Select, _ context: Context,
                                   enclosing: Scope? = nil,
                                   prefixes: Array<Scope> = [])
      throws(SQLError) -> Plans {
    // Resolve each site'S subqueries against that site's own scope, keyed per
    // occurrence: a join `i`'s `ON` against its prefix scope `prefixes[i]` (the
    // relations available at that join point), the
    // WHERE/HAVING/projection/ORDER against the full join `enclosing`. The same
    // inner SQL in both an `ON` and the WHERE is resolved twice — each against
    // its own site's scope — so the WHERE occurrence sees the full scope and
    // reports a genuine ambiguity rather than reusing the first `ON`
    // occurrence's narrower prefix correlation.
    var lowerings = Array<Resolution>()
    lowerings.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      var queries = Array<Query>()
      select.joins[index].on.collect(subqueries: &queries)
      let within = index < prefixes.count ? prefixes[index] : enclosing
      try lowerings.append(subquery(queries, select, context, within: within))
    }
    var rest = Array<Query>()
    select.predicate?.collect(subqueries: &rest)
    select.having?.collect(subqueries: &rest)
    if case let .expressions(items) = select.projection {
      for item in items { item.expression.collect(subqueries: &rest) }
    }
    for key in select.grouping.collected { key.collect(subqueries: &rest) }
    for key in select.order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &rest)
      }
    }
    let remainder = try subquery(rest, select, context, within: enclosing)
    return Plans(lowerings, remainder)
  }

  /// Builds one lowering `Resolution` over the directly-nested `queries` of a
  /// single site, resolving each against `within` — the scope that site's
  /// subqueries correlate against (a join `ON`'s prefix, or the full
  /// `enclosing` for the WHERE/HAVING/projection/ORDER). Each distinct `Query`
  /// is compiled once here; the same inner SQL at a different site is resolved
  /// by that site's own call, against its own scope.
  internal borrowing func subquery(_ queries: Array<Query>, _ select: Select,
                                   _ context: Context, within: Scope?)
      throws(SQLError) -> Resolution {
    // The select classifies each collected subquery's role (`scalar`/`valued`/
    // `existential`); the carrier path supplies its own body-agnostic
    // classifier through the roles overload below.
    try subquery(queries, roles: { select.roles(of: $0) }, context,
                 within: within)
  }

  /// `subquery(_:_:_:within:)` with the subquery-role classification supplied
  /// as a closure rather than read off a `Select` — the seam the carrier uses
  /// to classify a query-level `ORDER BY`'s subqueries over a leftmost arm that
  /// need not be a `Select` (a `VALUES` body). Every other caller passes a
  /// `Select`'s own `roles(of:)`.
  internal borrowing func subquery(_ queries: Array<Query>,
                                   roles: (Query) -> Array<Role>,
                                   _ context: Context, within: Scope?)
      throws(SQLError) -> Resolution {
    // A nested subquery's FROM resolves against base tables and enclosing CTEs,
    // NOT the enclosing SELECT's derived-table aliases (SELECT-scoped, unseen
    // by a subquery's FROM as a base-table alias would be) — so strip them, the
    // CTEs/store relations kept, before compiling each subquery. Applied for
    // scalar, `IN`, and `EXISTS` alike (`select.subqueries` covers all three).
    let context = context.revealed()
    let scope = context.subscope
    var widths = Dictionary<Query, Int>()
    var types = Dictionary<Query, ResolvedColumn>()
    var correlations = Dictionary<Query, Correlation>()
    for query in queries where widths[query] == nil {
      // A fresh `Outer` per nested query — its enclosing scope is this select
      // (nearest, `within`), stacked past this select's own enclosing scope
      // `outer`. A FROM-less select adds no relations, but it is still a scope
      // frame: it pushes an empty `Scope` so correlation depth counts this
      // level. Its own plan runs over a `single` empty record, so a deeper
      // reference to the true outer must NOT bind as this frame's `.slot` (an
      // empty record has no such cell) — the empty frame makes that reference
      // a grandparent one, resolved `.bound` and threaded through `bindings`,
      // while a genuinely-immediate correlation to a REAL enclosing FROM (a
      // non-nil `within`) stays `.slot` as before.
      let nested = (context.outer ?? Outer()).nested(under: within ?? Scope([]))
      // The context each nested compile/derive threads: the revealed base with
      // this frame's `nested` as the enclosing correlation stack and the
      // shape-only lenience below. `unlateralized()` clears the LATERAL-body
      // flag so a nested ordinary subquery within a lateral body builds its own
      // Resolution with `everywhere: false` — the lateral everywhere-admission
      // covers ONLY the lateral body's own projection, NOT a subquery inside
      // it, so an ordinary correlated scalar-subquery projection is barred
      // exactly as it is outside a lateral body.
      // `shaping()` defers the set-operation operand-compatibility fold out of
      // this pre-pass: it records every nested subquery's width, arity, and
      // single-column type ahead of the reachability walk, so a `SELECT 'x'
      // UNION SELECT 1` behind a short-circuited `1 = 0 AND …` is not faulted
      // while merely recording shape. A reached scalar/`IN` occurrence is re-
      // folded strictly on the walk's reached path; arity/resolution eager.
      let inner = context.with(outer: nested).validating(false)
          .unlateralized().shaping()
      // A nested subquery's body derivation is shape ONLY, so ALWAYS lenient
      // (`validate: false`) — this pass exists to record the subquery's width,
      // arity, and correlation, never to validate its body. Validation of a
      // subquery's body (and the derived tables nested within it, at any depth)
      // is the reachability walk's job: `typecheck(_ select:)` re-derives each
      // reached occurrence's body strictly over `subquery.visited`. Compiling a
      // derived body this subquery nests with `validate: true` here would
      // eager-type-check it before the walk decides the subquery is reached —
      // faulting `WHERE 1 = 0 AND 1 IN (SELECT x FROM (SELECT 1 / 0 …) AS d)`,
      // whose `IN` a run short-circuits away. Structural faults (a bad inner
      // relation/column, a UNION arity) still surface — they resolve regardless
      // of `validate`. The type derivation below is already lenient.
      let plan = try compile(query, inner)
      widths[query] = plan.width
      // A scalar subquery contributes its single-column output COLUMN — its
      // type AND `unconstrained` mask together, unified across its
      // set-operation arms (a `(SELECT 1 UNION SELECT 2.5)` typing `double`, a
      // `(SELECT NULLIF('a','a'))` staying unconstrained), not read off the
      // first arm alone; a wider or an `EXISTS`/`IN (Q)` subquery still records
      // the FIRST column (harmless — only a width-1 scalar occurrence reads it,
      // and the lowering rejects a wider one). It derives cursor-free against
      // the same context the width compile uses, so it matches what the run
      // advertises.
      types[query] =
          try columns(unifying: query, inner).first
      // The correlation the nested compile discovered — the outer columns its
      // inner `WHERE`/`ON` named — carried into the lowered subquery node so
      // the per-outer-row re-execution binds them. Empty for an uncorrelated
      // one.
      correlations[query] = nested.correlation
      // A correlated occurrence's inner plan was just compiled with this site's
      // enclosing scope, so its correlated columns are `Term.parameter`s bound
      // from the outer row. Stash it into the run path's `context.subqueries`
      // memo (which survives into execution) so the evaluator re-executes this
      // plan per outer row rather than recompiling the inner query fresh —
      // which, with no outer scope in hand at eval, would fault on the outer
      // column. Record it under the occurrence's `PlanKey` — its `Subkey` for
      // each role this query occupies (scalar / `IN` / `EXISTS`) composed with
      // the correlation's parameter names — the same identity the lowered node
      // looks up. The names distinguish two occurrences of identical inner SQL
      // under different outer layouts (two set-operation arms whose correlated
      // column sits at different ordinals), so each arm's node finds its own
      // plan rather than the first arm's. The `existential` role records the
      // probed shape
      // (`probed`: the cardinality-only rewrite when `probable`, else the full
      // query) so the per-outer-row EXISTS re-execution tests non-emptiness
      // without evaluating the select list — a `1 / 0` projection never runs —
      // exactly as the uncorrelated EXISTS probes. A schema-only path threads a
      // throwaway memo, harmless there.
      if !nested.correlation.isEmpty {
        for role in roles(query) {
          // Recompile the EXISTS probe leniently (`validate: false`), the same
          // way the `plan` above compiled: this builds the run-time plan a
          // correlated re-execution reuses, so it must not eager-type-check a
          // filtered-out projection the per-outer-row probe never evaluates.
          // The reachability walk validates a reached occurrence's probe shape
          // itself (`typecheck(shape(of: reach), …)`), so validation stays the
          // walk's, never this shape-deriving pass'.
          let recorded = try role == .existential
              ? compile(probed(query), inner)
              : plan
          // Push selection down into the inner plan as the top-level `run` does
          // (line ~134), so a correlated re-execution enjoys the same seeks and
          // join placement. The pushdown's nullability analysis treats a
          // conjunct carrying a correlated `Term.parameter` as nullable, so it
          // never rides ahead of a later unsafe conjunct the inner `AND` still
          // owes.
          context.subqueries.record(plan: try recorded.pushdown(),
                                    for: Subkey(scope, query, role),
                                    nested.correlation)
        }
      }
    }
    // A LATERAL body's `Resolution` admits a correlated preceding-FROM column
    // everywhere (`everywhere`), so its projection lowers such a column to a
    // `Term.parameter` rather than barring it — the ISO scoping a lateral body
    // gets and an ordinary subquery (`context.lateral == false`) does not.
    return Resolution(scope, widths, types, correlations,
                      outer: context.outer, everywhere: context.lateral)
  }

  /// The single value a scalar subquery `query` collapses to against this
  /// catalog and `context`: NULL when it yields no row, its lone cell when it
  /// yields exactly one, and `SQLError.cardinality` when it yields more than
  /// one (the ISO `<scalar subquery>` cardinality rule).
  ///
  /// The compile pre-pass checked `query`'s width to exactly 1
  /// (`SQLError.arity`, cursor-free), so each result row has exactly one cell
  /// and the collapse reads the first. A wider subquery never reaches here — it
  /// faulted at compile.
  ///
  /// The evaluator calls this lazily, on the first reach of a scalar
  /// `Term.subquery`, so an occurrence in an unreachable `CASE`/`COALESCE` arm
  /// never runs it — preserving short-circuit semantics — and memoises the
  /// result for the reached occurrence's later reads.
  internal borrowing func cell(of query: Query, _ context: Context)
      throws(SQLError) -> Value {
    // A scalar subquery is a nested subquery: its FROM resolves against base
    // tables and enclosing CTEs, NOT the enclosing SELECT's derived-table
    // aliases (the evaluator threads the owning plan's overlay, which binds
    // them for the owning scan). strip them (CTEs/store kept), matching the
    // eager `IN`/`EXISTS` strip in `subqueries(of:)`, so a scalar subquery's
    // `FROM d` cannot scan an outer derived alias `d`.
    let context = context.revealed()
    let rows = try run(query, context)
    guard rows.count <= 1 else { throw .cardinality }
    return rows.first?.first ?? .null
  }

  /// Whether `query`'s row source yields ANY row — the `EXISTS` cardinality
  /// probe — without evaluating its select list or sort keys.
  ///
  /// For a `probable` `SELECT` (see `Select.probable`), it runs a probe query
  /// that keeps the FROM/`WHERE`/joins, the `DISTINCT` quantifier, the `GROUP
  /// BY`, and the SAME original `OFFSET`/`FETCH` but replaces the projection
  /// with a cardinality-preserving target and drops the `ORDER BY`, so the
  /// original select-list expressions never evaluate (no `1 / 0` fault) while
  /// the original limiting is honoured: a `FETCH FIRST 0 ROWS` probes zero rows
  /// (EXISTS false) and an `OFFSET` past the end probes none (false). A
  /// FROM-less `SELECT <exprs>` carries no limit, so its probe is a limit-free
  /// `SELECT <constant>` that compiles and yields its one row (EXISTS true). A
  /// `DISTINCT` select without an `OFFSET` is probable too: `SELECT DISTINCT 1
  /// FROM S` yields exactly one distinct row iff `S` is non-empty, so the
  /// constant projection preserves existence. An aggregate/grouped select
  /// without a `HAVING` is probable via a `COUNT(*)` target (see
  /// `Select.probe`): a whole-result aggregate yields exactly one row (EXISTS
  /// true modulo the limit, even over an empty source) and a grouped one yields
  /// one row per group, so the probe preserves its cardinality without running
  /// the original target. A `DISTINCT` select WITH an `OFFSET` (its emptiness
  /// depends on the real distinct count), a `HAVING` one (group survival
  /// depends on the aggregate values, not a source-only fact), or a set
  /// operation is materialised in FULL and tested for emptiness — the rewrite
  /// would not preserve its cardinality — which for those shapes evaluates the
  /// select list as a run would anyway.
  internal borrowing func probe(_ query: Query, _ context: Context)
      throws(SQLError) -> Bool {
    // An `EXISTS` reads ONLY the probe's cardinality, never a cell, so a set-
    // operation probe's column types are irrelevant — `combine` coerces the
    // (discarded) rows, `.isEmpty` reads none. So run the probe under a
    // `shaping()` context, deferring the set-operation operand-compatibility
    // fold: `EXISTS (SELECT 'x' UNION SELECT 1)` probes non-emptiness without
    // faulting `SQLError.operand` on the irreconcilable arm types, matching the
    // invariant that an `EXISTS` does not constrain column type (a bare-select
    // probe folds nothing, so `shaping()` is inert for it).
    return try !run(probed(query), context.shaping()).isEmpty
  }

  /// The cardinality-only shape of `query` an `EXISTS` tests for non-emptiness:
  /// a `probable` `SELECT`'s probe rewrite (`Select.probe` — its select list
  /// and `ORDER BY` replaced by a cardinality-preserving target, so a `1 / 0`
  /// projection never evaluates) and the full `query` otherwise (a `HAVING`
  /// select, a `DISTINCT`-with-`OFFSET` one, or a set operation, whose empty
  /// test is not a source-only fact the rewrite preserves). The `probe(_:)` run
  /// and the correlated `existential` plan both compile/execute this shape, so
  /// a correlated EXISTS probes per outer row as an uncorrelated one does.
  internal borrowing func probed(_ query: Query) -> Query {
    // An `ordered` carrier over a probable primary — a parenthesised
    // `(SELECT …) ORDER BY … FETCH n` in EXISTS position — must probe its inner
    // primary, not evaluate it as a leaf. Existence is order-independent, so
    // the `ORDER BY` drops; the carrier's `DISTINCT`/`OFFSET`·`FETCH` affect
    // cardinality, so they ride the probed inner (`FETCH FIRST 0 ROWS` probes
    // zero, EXISTS false). Peel, probe the inner, re-wrap without the order.
    if let carrier = query.carriers.last {
      let inner = Query(body: query.body,
                        carriers: Array(query.carriers.dropLast()))
      // Rewriting the base projection to a constant collapses distinct rows to
      // one (a `DISTINCT` on any carrier in the stack, or on the base select).
      // A positive OFFSET on this carrier applied afterwards would then wrongly
      // drop that lone row, so keep the whole query unrewritten when the offset
      // depends on distinct cardinality — its select list and sort evaluate,
      // exactly as a direct `SELECT DISTINCT … OFFSET k` (non-probable) does.
      // `query.dedups` is carrier-transparent, so a `DISTINCT` reached only
      // through a stacked carrier (`((SELECT DISTINCT …) ORDER BY …) OFFSET 1`)
      // still suppresses the rewrite. Otherwise probe the inner and drop this
      // ORDER BY (existence is order-independent).
      if query.dedups, (carrier.limit?.offset ?? 0) >= 1 { return query }
      return .ordered(probed(inner), distinct: carrier.distinct, order: nil,
                      limit: carrier.limit, generated: 0)
    }
    guard case let .select(select) = query.body, select.probable else {
      return query
    }
    return .select(select.probe)
  }

  /// Resolves the FROM `relation` and its `joins` into one combined scope, the
  /// single source three call sites share: the aggregate compile path, the
  /// non-aggregate compile path, and the `SELECT *` arity check. The caller
  /// resolves FROM once (it needs the leaf for its own base lowering) and
  /// passes its `schema` here, so FROM is never re-resolved; each join then
  /// resolves into one running, end-to-end ordinal space.
  ///
  /// The returned `joined` holds each join's `Resolved` (its schema and leaf
  /// factory) in source order — the plan lowers each into the combined slot
  /// space from these. The returned `relations` lays the FROM relation first,
  /// then each joined one, each paired with its schema: `Scope(relations)` is
  /// the full-chain scope, `relations[0 ... index + 1]` a join's prefix scope,
  /// and `Scope(…).width(of: .all)` the `SELECT *` width — derived from the
  /// merged-prepend + real-column `expansion` the scope emits, never a separate
  /// sum — every downstream derivation reads out of this one resolution.
  ///
  /// `relations` is built incrementally, each join resolving against the
  /// preceding FROM (`Scope` of the relations before it): a LATERAL arm's
  /// projection may name a preceding column, so its output shape depends on
  /// that scope. A non-lateral join's schema is correlation-independent, so the
  /// preceding scope is harmless — the incremental order is a no-op for it. The
  /// preceding scope threads through here rather than at each call site, so the
  /// arity check gets a LATERAL arm's shape without duplicating the loop.
  internal borrowing func resolve(from relation: Relation, schema: Schema,
                                  joins: Array<Join>, _ context: Context)
      throws(SQLError) -> (joined: Array<Resolved>,
                           relations: Array<(Relation, Schema)>) {
    var joined = Array<Resolved>()
    joined.reserveCapacity(joins.count)
    var relations = [(relation, schema)]
    for index in joins.indices {
      // The preceding scope carries the merged columns the joins before this
      // one expose (`prefix(through:)`), so a LATERAL body resolves a bare
      // merged name to its one coalesced column rather than seeing the two
      // physical join columns and faulting `.ambiguous`. A join before this one
      // is already resolved (its schema is in `relations`), so the merged
      // prefix is computable here.
      let preceding =
          try prefix(through: index, over: relations, joins)
      let resolved =
          try resolve(joins[index].relation, context, preceding: preceding)
      joined.append(resolved)
      relations.append((joins[index].relation, resolved.schema))
    }
    return (joined, relations)
  }

  /// The raw output width of `query`'s leftmost arm — the operand width the
  /// `UNION` arity check compares (before trimming the carriers' hidden
  /// `generated` sort columns). It descends the left arm of each set operation
  /// to the leftmost non-`setop` body and measures it: a `SELECT`'s projected
  /// width (a `*` resolved against its own augmented FROM/JOIN scope), or a
  /// `VALUES` body's row width. Body-agnostic, so a `VALUES` or `TABLE` operand
  /// measures exactly as a `SELECT` one.
  private borrowing func arity(_ query: Query, _ context: Context)
      throws(SQLError) -> Int {
    switch query.body {
    case let .setop(_, left, _, _):
      return try arity(left, context)
    case let .select(select):
      // The leftmost arm resolves its own FROM/JOIN derived aliases (arms are
      // SELECT-scoped), so augment it before measuring a `*`.
      let scope = try augment(context, for: .select(select), rows: false)
      return try arity(select, scope)
    }
  }

  /// The number of result columns `select` projects — the extent of a `*` over
  /// its relations, else the count of its projected items — for the `UNION`
  /// arity check. The relations resolve through this catalog, the overlay
  /// consulted first.
  private borrowing func arity(_ select: Select, _ context: Context)
      throws(SQLError) -> Int {
    switch select.projection {
    case .all:
      // `SELECT *` spans the relations in scope; a FROM-less arm has none.
      guard let relation = select.from else {
        throw .named("SELECT * with no FROM")
      }
      // The FROM resolves once here; each join then resolves through the shared
      // helper, which threads each join's preceding scope into its resolve — so
      // a LATERAL arm's body derives its projected preceding-FROM column
      // against the relations before it rather than against no scope, which
      // would fault the arity check even though the per-arm compile passes the
      // prefix.
      let schema = try resolve(relation, context).schema
      let (_, relations) = try resolve(from: relation, schema: schema,
                                       joins: select.joins, context)
      // A `SELECT *` over a `NATURAL`/`USING` join is measured at its merged
      // width (each join column once) through `Scope.width(of: .all)`, which
      // derives the count from the merged-prepend + real-column `expansion` the
      // arm emits — the width the arm actually produces, not the raw sum of
      // both sides, and not a parallel arithmetic that could drift (a virtual
      // `USING` constituent undercounted the old sum). So `A JOIN B USING (k)
      // UNION SELECT …` compares post-merge widths and a valid set operation is
      // not wrongly rejected. An arm with no named-column join yields an empty
      // merged set, so the width is just the real-column count.
      let merged = try merges(over: relations, select.joins).merged
      return Scope(relations, merged: merged).width(of: .all)
    case let .columns(columns):
      return columns.count
    case let .expressions(items):
      return items.count
    }
  }

  /// Resolves a `Relation` against this catalog and the in-scope `ctes` to its
  /// schema and leaf factory.
  ///
  /// A common table expression shadows a base relation of the same name:
  /// `ctes` is consulted first, a CTE resolving to its materialised schema and
  /// a `scan` leaf (the executor materialises its records from the rows). Else
  /// a view shadows a base table — its `select` compiled to a sub-plan in a
  /// `derived` leaf — and finally a base table scans. A name none resolves is
  /// `SQLError.relation`.
  ///
  /// A view's body compiles outside the statement's CTE scope — never the
  /// caller's `ctes` — so a stored view means exactly what it was registered to
  /// mean regardless of the `WITH` a caller wraps around it. A name that IS a
  /// statement CTE has already resolved above (a CTE shadows a view, as it
  /// shadows a base table), so a name reaching the view branch is genuinely a
  /// view; letting its body see the caller's CTEs would let an unrelated
  /// statement-local `WITH Parent AS …` reach into a view whose own `FROM
  /// Parent` must mean the base relation. The body's scope is instead the
  /// `definition_schema.` overlay built from the view's own query, so a view
  /// defined over a reserved store relation resolves; its `FROM`/`JOIN` names
  /// otherwise resolve against the base catalog (and other views) alone.
  ///
  /// A view's `columns` must name exactly one column per value its query
  /// projects, or the view's schema would let a query index past a sub-plan
  /// row. The parser checks this whenever the projection's arity is statically
  /// known; this is the backstop for a `SELECT *` view, whose width is known
  /// only here, after the sub-plan compiles — a mismatch is `SQLError.columns`.
  ///
  /// `visited` names the views already being resolved down this chain. A view
  /// whose body reaches back to itself — `A` over `B` over `A`, or a view over
  /// itself — would recurse resolve→compile→resolve without end (a stack
  /// overflow, not an `SQLError`); re-encountering a name is a cyclic
  /// definition, reported as `.recursion` rather than hung. The
  /// `definition_schema.` store's `columns` builder, which compiles every view
  /// to advertise it, relies on this: a cyclic view's `try? compile` catches
  /// the fault and skips it. Compiles a LATERAL derived table's `body` against
  /// the preceding FROM `scope`, discovering its correlation and stashing the
  /// pre-compiled plan for the per-outer-row apply to re-execute — the
  /// FROM-clause analog of a correlated subquery's compile pre-pass
  /// (`subquery(_:_:_:within:)`).
  ///
  /// The body compiles under a fresh `Outer` frame nested under `scope` (the
  /// FROM relation and the joins before this one), so a body column naming a
  /// preceding relation binds none of its own relations and resolves outward to
  /// a synthetic `Term.parameter`, minting a `Correlation`. The plan compile is
  /// lenient (`validate: false`), as the correlated-subquery pre-pass is — this
  /// pass discovers the shape, and the run's per-row execution faults a reached
  /// operand. The plan is recorded under the occurrence's `Subkey` (this
  /// select's `subscope`, the body query, the `.lateral` role) composed with
  /// the correlation, the same identity `Plan.apply` looks up through
  /// `executed`. Returns the occurrence `Subkey` and the discovered
  /// correlation.
  ///
  /// A lateral body's schema + validation route through the same derived-body
  /// machinery a non-LATERAL derived body uses (`materialise`, `rows: false`),
  /// differing ONLY in the OUTER treatment: a non-lateral body clears the
  /// correlation stack (`body(_:)`, uncorrelated), while a lateral body threads
  /// the preceding-FROM `nested` outer so its correlated references resolve. So
  /// a lateral body inherits the revealed-base overlay (base + CTEs + store,
  /// its own alias out of scope) — a CTE stays visible in the body — AND the
  /// `validate`-gated operand/function type-check, exactly as a non-lateral
  /// body does. Under `validate: false` (a lenient run/shape pass) the body is
  /// NOT eagerly type-checked, matching the reachability-gated validation the
  /// rest of the engine applies; a reached bad operand still faults at run.
  internal borrowing func lateral(_ body: Query, against scope: Scope,
                                  columns renaming: Array<String>,
                                  _ context: Context)
      throws(SQLError) -> (key: Subkey, correlation: Correlation) {
    let nested = (context.outer ?? Outer()).nested(under: scope)
    // Derive the body's schema and — under `validate` — type-check its operands
    // and functions through the shared derived-body path, over the revealed
    // base (CTEs visible) with the preceding-FROM outer threaded so a
    // correlated reference resolves rather than faulting as unknown. The
    // returned schema is discarded here (`resolve`/`schema(of:)` advertises the
    // columns); this call exists to run the same validation a non-lateral body
    // gets.
    // Mark the body a LATERAL body (`lateralizing`) so its `Resolution`/
    // `SubqueryCheck` admit a correlated preceding-FROM column everywhere,
    // including its projection — per ISO a LATERAL body's preceding references
    // are in scope throughout, unlike an ordinary subquery whose projection
    // stays barred. The flag rides through the shared derived-body machinery to
    // the projection lowering, where a projected preceding column lowers to a
    // `Term.parameter` rather than faulting `.unsupported`.
    // Thread the derived table's explicit `AS d(a, b)` column list into the
    // body's schema derive so this validation checks the same exposed (renamed)
    // names `schema(of:)` advertises — its arity (`SQLError.columns`) and
    // uniqueness (`SQLError.duplicate`) run against the renamed list, so a list
    // hiding a duplicate INNER name (`SELECT T.Id AS x, T.Id AS x) AS d(a, b)`)
    // passes at both seams rather than faulting only here.
    let revealed = context.revealed().with(outer: nested).lateralizing()
    _ = try materialise(body, revealed, rows: false, columns: renaming)
    // Compile the body leniently for the per-outer-row apply plan (the shape
    // pass a correlated subquery's pre-pass runs), recording it under the
    // occurrence's key composed with the discovered correlation. It compiles
    // over the same revealed base the schema/validation pass above used (base +
    // CTEs + store, this select's derived aliases stripped) with the
    // preceding-FROM outer threaded, so a body `FROM d` cannot bind a caller
    // derived alias `d` as a relation — the compile and the schema path resolve
    // the body's FROM identically, faulting an unknown relation consistently
    // rather than the run-only compile scanning a caller alias the schema pass
    // faults.
    let inner = revealed.validating(false)
    let plan = try compile(body, inner)
    let key = Subkey(context.subscope, body, .lateral)
    context.subqueries.record(plan: try plan.pushdown(), for: key,
                              nested.correlation)
    // The per-outer-row apply re-runs this plan under the occurrence scope's
    // recorded revealed overlay (`revealed(under:)`), which the run stores as
    // `revealed().relations` for `key.scope` — the same revealed base compiled
    // here — so execution resolves the body's `FROM` identically and a shadowed
    // CTE cannot diverge between compile and run.
    return (key, nested.correlation)
  }

  internal borrowing func resolve(_ relation: Relation, _ context: Context,
                                  preceding: Scope? = nil)
      throws(SQLError) -> Resolved {
    let name = relation.name
    // A LATERAL derived table is not bound in the overlay — its rows are not a
    // constant relation but a correlated apply's right side, materialised per
    // outer row. Resolve only its schema here; the join loop compiles its body
    // against the preceding FROM and emits a `Plan.apply` rather than calling
    // the `leaf`, so the leaf is never reached for a lateral relation. Its
    // output shape is NOT correlation-independent (per ISO its projection may
    // name a preceding column), so thread the `preceding` scope — the FROM
    // relation and the joins before this one — so a projected preceding column
    // types from that outer column exactly as the run lowers it.
    if relation.lateral {
      let schema = try schema(of: relation, context, preceding: preceding)
      return Resolved(schema: schema) { ordinals in
        .scan(name: name, ordinals: ordinals, seek: nil)
      }
    }
    // The explicit `AS t(c, …)` list positionally renames a named relation's
    // output columns; a derived table's list was applied where it materialised
    // (its overlay binding carries the renamed names), so only a `.named`
    // source renames here — the compile-path mirror of `schema(of:)`'s named
    // rename, kept in parity so compile and the schema-only path resolve the
    // same column names.
    let columns: Array<String> = if case .named = relation.source {
      relation.columns
    } else {
      []
    }
    if let cte = context.relations[name.lowercased()] {
      let schema = try cte.schema().renamed(columns)
      return Resolved(schema: schema) { ordinals in
        .scan(name: name, ordinals: ordinals, seek: nil)
      }
    }

    if let view = resolve(view: name) {
      // A view whose body reaches back to itself — `A` over `B` over `A`, or a
      // view over itself — would recurse resolve→compile→resolve without end (a
      // stack overflow, not an `SQLError`). `visited` names the views already
      // being resolved down this chain; re-encountering one is a cyclic
      // definition, reported as `.recursion` rather than hung.
      if context.visited.contains(name.lowercased()) {
        throw .recursion(name)
      }
      // The view body compiles outside the caller's statement CTEs, but it may
      // still name a reserved `definition_schema.` store relation, so seed its
      // scope with the overlay built from the view's own query — never the
      // caller's `ctes` — so a view defined over a store relation resolves.
      // This covers the built-in `information_schema.` views themselves, whose
      // bodies name `definition_schema.` relations.
      //
      // Compilation resolves only schemas (names → ordinals/types), never rows,
      // so the overlay is built schema-ONLY: a reserved relation types from its
      // header+types, and the row build is never triggered here. A view over
      // `definition_schema.columns` would otherwise re-enter that row builder
      // (which lists views, whose bodies name the relation again) — an
      // unbounded recursion, and the reason the introspection builder can
      // validate a view via `compile`. The rows a view over a reserved
      // relation actually returns are supplied at execute time, where `derive`
      // rebuilds the overlay with rows and runs the sub-plan.
      // This view name enters `visited` before its body's derived tables
      // materialise, so a body naming this view through a derived table
      // (`FROM (SELECT * FROM <self>) AS d`) re-enters `augment`/`materialise`
      // with the view already visited and faults `.recursion` here rather than
      // recursing to a stack overflow.
      // `context.validate` threads into the view body's schema-only augment +
      // compile so a run (`validate: false`) resolving `FROM <view>` does NOT
      // eager-type-check a data-dependent-empty derived body the view nests —
      // as the lenient inline run does; a schema check keeps it strict.
      // `uncorrelated()` clears the caller's correlation stack: a view is
      // defined independently of its call site, so its body must NOT correlate
      // against an enclosing row when the view is queried from inside a
      // correlated subquery. Without it an unbound column in the view
      // definition would bind to the caller's row rather than fault.
      let overlay =
          try augment(context.body([:]).visiting(name),
                      for: view.query, rows: false)
      // The body's subqueries resolve under the VIEW's overlay — never the
      // caller's — so lower them under `.view(name)`, keeping a view-body
      // occurrence and a top-level one over the same AST distinct entries.
      let plan =
          try compile(view.query,
                      overlay.scoped(as: .view(name.lowercased())))
      let projected = plan.width
      guard view.columns.count == projected else {
        throw .columns(expected: projected, got: view.columns.count)
      }
      let schema = try view.schema().renamed(columns)
      return Resolved(schema: schema) { ordinals in
        .derived(name: name, plan: plan, ordinals: ordinals, seek: nil)
      }
    }

    guard let table = table(named: name) else {
      throw .relation(name)
    }
    let schema = try table.schema().renamed(columns)
    return Resolved(schema: schema) { ordinals in
      .scan(name: name, ordinals: ordinals, seek: nil)
    }
  }

  /// The synthesized joins and the `NATURAL`/`USING` merged columns (ISO 9075
  /// 7.10) of `select`'s join chain, resolved against the already-resolved
  /// `relations` (the FROM relation first, then each joined one in source
  /// order). A chain with no named-column join returns the joins verbatim and
  /// an empty merged list, so an ordinary query is untouched.
  ///
  /// Rather than rewrite the AST — an emulation every reference site,
  /// expression form, and pass ordering had to be taught — this models each
  /// merged column once as a scope entry, so the ordinary name→`Term` machinery
  /// (`Scope.term`/`derive`, `Scope.terms(.all)`, `Grouping`) consumes it. The
  /// merged column has no physical slot: its value is `COALESCE(left, right)`
  /// over the two physical combined ordinals (each qualified-addressable),
  /// and a bare reference to its name resolves to that coalesce (the entry
  /// shadows its constituents), while a qualified `A.c`/`B.c` reaches its own
  /// side.
  ///
  /// The fold threads a growing prefix `Scope` — the relations `0…index` plus
  /// the merged columns accumulated so far — so it resolves each join's common
  /// columns through the scope, not by scanning a left array. For a `USING (c,
  /// …)` join each `c` must resolve to exactly one left output column
  /// (`Scope.left` — a name an accumulated plain `ON` join bound twice faults
  /// `SQLError.ambiguous`, the finding-1 trap now a construction fault) and be
  /// present on the right (else `SQLError.column`); a `NATURAL` join's are the
  /// right schema's names the prefix's visible names share, left order (a
  /// twice-bound left name faults `.ambiguous` when keyed). The join's `on`
  /// becomes the conjunction of `left.c = right.c` — the LEFT operand a bare
  /// `.column(c)` the prefix scope lowers to its resolved term (a coalesce when
  /// `c` was already merged, so chained/outer keying is automatic) — empty for
  /// a `NATURAL` join with no shared column, an always-true `CROSS`-equivalent
  /// `on`. A merged column `c` = `COALESCE(leftTerm, right.slot)`, its unified
  /// type; its constituents stay qualified-addressable. `USING (c, c)` (a
  /// repeat in the single `common` list) faults `.duplicate` at construction.
  internal func merges(over relations: Array<(Relation, Schema)>,
                       _ joins: Array<Join>)
      throws(SQLError) -> (ons: Array<Filter?>,
                           merged: Array<Scope.Merged>,
                           prefixes: Array<Array<Scope.Merged>>) {
    guard joins.contains(where: { $0.using != nil }) else {
      let empty = Array(repeating: Array<Scope.Merged>(), count: joins.count)
      return (Array(repeating: nil, count: joins.count), [], empty)
    }
    // The synthesized `on` FILTER of each named-column join (`nil` for a plain
    // `ON`/`CROSS` join, which lowers its own written `on`, or a degenerate
    // `NATURAL` join with no shared column, an always-true `CROSS` product).
    // It is lowered directly here rather than re-lowered from a bare-name AST
    // predicate — a chained merged column has no unambiguous bare spelling
    // against a scope that also holds the joined-in relation's same-named
    // column — carrying the resolved LEFT term (a coalesce when `c` was already
    // merged) `= right.slot`.
    var ons = Array<Filter?>()
    ons.reserveCapacity(joins.count)
    // The merged columns before each join's own relation joins — the surface
    // that join's common-column resolution (and a LATERAL body's preceding
    // scope) reads.
    var prefixes = Array<Array<Scope.Merged>>()
    prefixes.reserveCapacity(joins.count)
    var merged = Array<Scope.Merged>()
    for index in joins.indices {
      prefixes.append(merged)
      let (on, next) = try merging(join: joins[index], at: index,
                                 over: relations, onto: merged)
      ons.append(on)
      merged = next
    }
    return (ons, merged, prefixes)
  }

  /// Folds the one `NATURAL`/`USING` merge step of the join at `index` onto the
  /// merged columns `merged` accumulated by the joins to its left, returning
  /// its synthesized `on` filter (`nil` for a plain `ON`/`CROSS` join or a
  /// shared-column-less `NATURAL` one) and the extended merged set. This is the
  /// single place a join's merged columns are derived — `merges(over:)` folds
  /// it across the whole chain, and the incremental resolve loops
  /// (`merged(through:…)`) fold it join-by-join to build a LATERAL body's
  /// preceding scope — so no site can compute a join's merged columns a second,
  /// divergent way.
  ///
  /// The LEFT scope is the relations `0…index` (the FROM relation and the joins
  /// before this one) with the prior `merged`; the FULL scope adds the
  /// joined-in relation, so its `range.c` right constituent resolves to a
  /// combined ordinal. A `USING (c, …)` join's columns are the named ones (each
  /// present on both sides, else `SQLError.column`; a repeat faults
  /// `.duplicate`); a `NATURAL` join's are the prefix's visible names the right
  /// schema shares, in left order. Each merged column is `COALESCE(leftTerm,
  /// right.slot)` — a
  /// coalesce left when `c` was already merged, so chained/outer keying follows
  /// the merged value — its type the mask-aware unification of the two
  /// constituents through the set-operation `merge(_:_:)` (a constant-NULL/
  /// placeholder side is unconstrained and defers to the other; two constrained
  /// sides unify, an irreconcilable pair faulting `.operand`/42804), and its
  /// `on` conjunct a hash-join `match` key (pure `slot = slot`) or a residual
  /// equi `compare`.
  private func merging(join: Join, at index: Int,
                       over relations: Array<(Relation, Schema)>,
                       onto merged: Array<Scope.Merged>)
      throws(SQLError) -> (on: Filter?, merged: Array<Scope.Merged>) {
    let prefix = Scope(Array(relations[0 ... index]), merged: merged)
    let scope = Scope(Array(relations[0 ... index + 1]), merged: merged)
    let joined = relations[index + 1].1
    let range = join.relation.alias ?? join.relation.name
    guard let using = join.using else {
      return (nil, merged)
    }
    // The joined-in relation's own spelling (its case) of a shared name, or
    // `nil` when it exposes none — probed through the joined schema's FULL
    // addressable surface (`Schema.ordinal(of:)`, virtual-aware), so a virtual
    // column (the fixture/adapter `Id`) a `USING (Id)` join names is found the
    // same way the predicate path `A.Id = B.Id` resolves it, not a real-only
    // `names` membership that would spuriously fault `.column`. This is the
    // explicit `USING (c, …)` probe ONLY — a `USING`-named virtual `Id` still
    // resolves and merges. The spelling is taken from whichever list
    // (`names`/`virtuals`) holds it.
    func right(_ name: String) -> String? {
      let folded = name.lowercased()
      guard joined.ordinal(of: name) != nil else { return nil }
      return (joined.names + joined.virtuals)
          .first { $0.lowercased() == folded }
    }
    // The joined-in relation's own spelling of a shared REAL name, or `nil`
    // when it exposes none as a real column — the `NATURAL` common-set probe. A
    // `NATURAL` join's common set is the intersection of the two sides' REAL
    // (`SELECT *`-visible) column names, virtuals excluded on both sides: the
    // left is already real-only (`prefix.names` reads the `expansion`, never a
    // virtual), and this restricts the joined side to `joined.names` not its
    // full virtual-aware surface. So a fixture/adapter virtual `Id` never
    // becomes a `NATURAL` common column — it participates only when explicitly
    // named by `USING (Id)`, matching how `*`/`NATURAL` expose the same
    // real-column set while an explicit reference resolves a virtual.
    func real(_ name: String) -> String? {
      let folded = name.lowercased()
      return joined.names.first { $0.lowercased() == folded }
    }
    // The join columns in the LEFT side's order — a `NATURAL` join's the
    // prefix's visible names the right schema shares (REAL names only, both
    // sides), a `USING` join's the named ones (each present on both sides,
    // virtual-aware, else `SQLError.column`).
    let common: Array<String>
    switch using {
    case .natural:
      common = prefix.names.filter { real($0) != nil }
    case let .columns(columns):
      for column in columns where right(column) == nil {
        throw .column(column)
      }
      common = columns
    }
    // `USING (k, k)` — a repeat in the single `common` list — faults at
    // construction (the eager behavior), not by trapping a dictionary init.
    var seen = Set<String>()
    for name in common where !seen.insert(name.lowercased()).inserted {
      throw .duplicate(name)
    }
    // Each merged column and its synthesized `on` conjunct: the LEFT the
    // prefix's resolved term for `c` (a coalesce when `c` was already merged,
    // so a chained/outer key follows the merged value), the RIGHT the
    // joined-in slot, the merged value their `COALESCE`, its type unified. A
    // pure `slot = slot` conjunct lowers to the hash-join `match` key `nest`
    // folds; a coalesced left is a residual equi `compare`.
    var conjuncts = Array<Filter>()
    var block = Array<Scope.Merged>()
    for name in common {
      let left = try prefix.left(name)
      let target = Column(qualifier: range, name: right(name)!)
      let slot = try scope.ordinal(of: target)
      if case let .slot(source) = left.value {
        conjuncts.append(Filter(match: source, slot))
      } else {
        conjuncts.append(.compare(left.value, .equal, .slot(slot)))
      }
      // The merged column's type is the mask-aware unification of its two
      // constituents, taken through the same `merge(_:_:)` machinery a
      // set-operation arm fold uses rather than a bare `ValueType.unified` on
      // the raw slot types: a constant-NULL/placeholder side is unconstrained
      // (it places no type constraint), so the merged type defers to the
      // constrained side — `(SELECT NULLIF(1,1) AS k) RIGHT JOIN B USING (k)`
      // types `k` off `B.k` rather than the left's placeholder `integer`.
      // Both constrained unify (`int ⊕ double → double`, an irreconcilable
      // `int ⊕ text` faults `.operand`/42804, the same fault the set-op fold
      // raises); both unconstrained stay a placeholder. The coalesce coerces
      // each side to the resolved type, so a `RIGHT`/`FULL` join's
      // unmatched-side value obeys the advertised type. An irreconcilable pair
      // re-throws under the USING-specific message (the `.operand`/42804 code
      // is what the caller matches), so the fault reads for the join criterion
      // it arose from rather than the set-operation `merge` reports.
      let unified: ResolvedColumn
      do {
        unified =
            try merge(ResolvedColumn(name: name, type: left.type,
                                     unconstrained: left.unconstrained),
                      ResolvedColumn(name: name, type: scope.type(at: slot),
                                     unconstrained:
                                         scope.unconstrained(at: slot)))
      } catch {
        throw .operand("USING columns have irreconcilable types")
      }
      // The merged column's own mask: unconstrained ONLY when both sides were
      // (`merge` narrows to `right.unconstrained` after skipping an
      // unconstrained left), so a downstream set-operation over the merged
      // column defers when neither side ever constrained it, and constrains
      // once either side did.
      block.append(Scope.Merged(name: name,
                                value: .coalesce([left.value, .slot(slot)],
                                                 type: unified.type),
                                type: unified.type,
                                constituents: left.constituents + [slot],
                                unconstrained: unified.unconstrained))
    }
    // ISO 9075 7.10 join output order: this join's common columns lead, then
    // the rest of the LEFT output (recursively), then the right's rest. This
    // join's `block` therefore prepends ahead of the columns accumulated by the
    // joins to its left — so a chained `(A JOIN B USING (k)) JOIN C USING (a)`
    // exposes `[a, k, …]` (the outer `a`, then the inner `k`), not the flat
    // fold order `[k, a, …]`. A chained `… USING (k)` over an already merged
    // `k` drops the earlier entry (this `block`'s coalesce subsumes its
    // constituents plus the new right slot), so `SELECT *` still exposes `k`
    // once and at the OUTER join's position.
    let names = Set(block.map { $0.name.lowercased() })
    let next = block + merged.filter { !names.contains($0.name.lowercased()) }
    return (conjuncts.conjunction, next)
  }

  /// The `NATURAL`/`USING` merged columns accumulated by the joins `0..<count`
  /// — the merged prefix a LATERAL body of the join at `count` sees. Folds the
  /// same per-join `merging` step `merges(over:)` does, over
  /// `relations[0...count]`
  /// (the FROM relation and the joins before `count`), so the incremental
  /// resolve loops build each preceding scope through the one merge path rather
  /// than a second, divergent construction.
  internal func merged(through count: Int,
                       over relations: Array<(Relation, Schema)>,
                       _ joins: Array<Join>)
      throws(SQLError) -> Array<Scope.Merged> {
    var merged = Array<Scope.Merged>()
    for index in 0 ..< count {
      merged = try merging(join: joins[index], at: index, over: relations,
                         onto: merged).merged
    }
    return merged
  }

  /// The preceding scope of the join at `count` — the FROM relation and the
  /// joins before it (`relations[0..<count + 1]`), carrying the merged columns
  /// those joins expose (`merged(through:)`). This is the one constructor of a
  /// join-prefix scope: every incremental resolve loop routes through it, so a
  /// join-prefix scope can never be built without its merged columns (the
  /// finding-1 class — a LATERAL body seeing the two physical join columns
  /// rather than the one merged one).
  internal func prefix(through count: Int,
                       over relations: Array<(Relation, Schema)>,
                       _ joins: Array<Join>)
      throws(SQLError) -> Scope {
    Scope(Array(relations[0 ..< count + 1]),
          merged: try merged(through: count, over: relations, joins))
  }

  /// Compiles `select` over this catalog into a logical operator tree in slot
  /// space.
  ///
  /// The relation(s) resolve through this catalog (`SQLError.relation` on a
  /// miss). A single relation shapes `Project(Sort(Select(Scan)))`; a chain
  /// of joins shapes a left-deep tree, each join level a `Select(match,
  /// Product(chain, Scan))` on that join's `ON` equality, with the `WHERE`
  /// wrapped outside as `Project(Sort(Select(where, chain)))`. The `Select` and
  /// `Sort` layers are present only when a predicate or an `ORDER BY` is. Each
  /// scan carries the set of ordinals the query references on its side
  /// (projection ∪ every match ∪ filter ∪ order, reals and virtuals) so the
  /// executor materialises exactly those, in a fixed order that defines a dense
  /// slot for each — slot `i` is the scan's `i`th referenced ordinal.
  ///
  /// The operators run in slot space: `compile` remaps every ordinal it lowered
  /// (the projection, the `filter`, the order column, and each join's keys)
  /// through `ordinal → slot` so the records the operators address are dense
  /// arrays. The combined slot space lays the relations end to end in chain
  /// order — relation `i`'s referenced ordinals take a contiguous slot run
  /// after every earlier relation's — matching the merged record (each
  /// relation's cells concatenated in order). The tree is logical: every scan
  /// is a full `Scan(_, _, nil)`; the optimiser turns scans into seeks and each
  /// product into a join.
  ///
  internal borrowing func compile(_ select: Select,
                                  _ context: Context = Context())
      throws(SQLError) -> Plan {
    // A `GROUP BY GROUPING SETS (…)` never reaches here: `Query.expanded` (run
    // at every pipeline entry) has already rewritten it to a `UNION ALL` of
    // `.arm` selects, so `compile(_ select:)` sees only `.keys`/`.arm`.
    // Bind this select's own FROM/JOIN derived tables (and store relations)
    // before resolving its relations — SELECT-scoped, so a select reaching
    // this entry directly (a bare `compile(select)`, not through the `Query`
    // wrapper) resolves its own derived aliases rather than faulting
    // `.relation`, the same as its schema siblings `columns(of select:)`/
    // `scope(of select:)`. Schema-only (`rows: false`): compilation reads
    // schemas, never a cursor. Idempotent when the caller already augmented
    // (the `Query` wrapper augments this select before its `compile(query.
    // first, …)`), so the wrapped path does not re-derive — a binding whose
    // derivation matches is kept, so a self-named `(SELECT … FROM T) AS T`
    // still reads the base and a shadowed CTE keeps its binding. `visited`
    // carries the cyclic-view guard, `validate` gates a derived body's eager
    // type-check the same as the wrapper's.
    //
    // The augmented `context` threads onward to `subquery(of:)`/`group`, which
    // reveal the base before lowering a nested subquery — this select's (and
    // every enclosing select's) derived aliases dropped, the CTEs and store
    // relations kept — so a subquery's FROM sees no derived alias while a CTE
    // a same-named derived alias here shadows stays visible. The layered
    // overlay never overwrote the CTE, so no separate pre-augment context runs.
    let context = try augment(context, for: .select(select), rows: false)
    guard let relation = select.from else {
      // A FROM-less select projects expressions over a single row. A `WHERE`,
      // `GROUP BY`, `HAVING`, or `JOIN` has no relation to apply to, so reject
      // it rather than silently ignore the clause — a scalar projection would
      // drop a `GROUP BY`/`HAVING` otherwise. `ORDER BY` and `OFFSET`/`FETCH`
      // do apply: they order and page that single-row result (ISO), so the
      // enclosing query expression's trailing tail on a FROM-less primary —
      // `VALUES (1) ORDER BY 1`, `(SELECT 1 FETCH FIRST 0 ROWS ONLY) UNION …` —
      // runs rather than faulting. The parser never produces a WHERE/GROUP/
      // HAVING/JOIN here, but a direct `Select(from: nil, …)` can.
      let ungrouped = if case .keys([]) = select.grouping { true } else {
        false
      }
      guard select.joins.isEmpty, select.predicate == nil,
          ungrouped, select.having == nil else {
        throw .unsupported(
            "a WHERE, GROUP BY, HAVING, or JOIN requires a FROM clause")
      }
      if let limit = select.limit {
        // As on the FROM'd path, a direct `Limit` may carry negatives the
        // executor would trap on (the parser yields only non-negative counts).
        guard limit.offset >= 0 else {
          throw .state("2201X", "OFFSET row count must be non-negative")
        }
        guard (limit.count ?? 0) >= 0 else {
          throw .state("2201W", "FETCH row count must be non-negative")
        }
      }
      // A scalar projection may still nest an uncorrelated subquery
      // (`SELECT CASE WHEN EXISTS (Q) …`); compile each once for its width and
      // thread the map through so the term lowers as it does on the FROM'd path
      // rather than hit the default unsupported map. The run path builds the
      // matching run-time cache from `query.subqueries` (which descends the
      // projection), so the subquery is materialised there — `compile` runs it
      // never.
      // A FROM-less select adds no relations, so its nested subqueries
      // correlate against this select's own enclosing scope `outer` unchanged;
      // and its own columns (none but a projected outer reference) correlate
      // outward through `outer` too. The seam is `plans.rest`; `scalar` (via
      // `Schema.terms`) bars it — a projection is a barred clause position — so
      // a correlated column of this query is diagnosed, not lowered to a
      // `Term.parameter`, matching `columns(of:)`'s schema-path rejection.
      let plans = try subquery(of: select, context)
      return try select.projection.scalar(context.routines,
                                          subquery: plans.rest,
                                          distinct: select.distinct,
                                          order: select.order,
                                          limit: select.limit)
    }
    // A LATERAL first FROM item has no preceding relation to correlate against,
    // so it is meaningless (and ISO forbids it) — fault rather than resolve a
    // lateral body against nothing.
    if relation.lateral {
      throw .state("42601",
                   "a LATERAL derived table needs a preceding FROM item")
    }
    let from = try resolve(relation, context)

    if let limit = select.limit {
      // The parser yields only non-negative counts (a `-` is its own token),
      // but a direct `Limit(count:offset:)` may carry negatives the executor's
      // skip and take would trap on. Reject them as a query error rather than
      // crash.
      guard limit.offset >= 0 else {
        throw .state("2201X", "OFFSET row count must be non-negative")
      }
      guard (limit.count ?? 0) >= 0 else {
        throw .state("2201W", "FETCH row count must be non-negative")
      }
    }

    // An aggregate query — one with a `GROUP BY`, a `HAVING`, or an aggregate
    // in its projection — compiles through the grouped path, which places an
    // `aggregate` node above the WHERE/join chain and lowers the projection,
    // `HAVING`, and `ORDER BY` against the grouped slot space. A non-aggregate
    // query compiles exactly as before.
    if select.aggregates {
      return try group(select, relation, from, context)
    }

    guard !select.joins.isEmpty else {
      // Compile every nested subquery once for its arity/type, ahead of
      // lowering, into a map the WHERE/projection/ORDER BY lowering reads — and
      // discover each one's correlation against this select's single-relation
      // scope (`enclosing`). This select's own columns correlate outward
      // through `outer`.
      let enclosing = Scope([(relation, from.schema)])
      let plans = try subquery(of: select, context, enclosing: enclosing)
      var filter: Filter? = nil
      if let predicate = select.predicate {
        filter = try from.schema.lower(predicate, in: relation,
                                       context.routines, subquery: plans.rest)
      }
      // The projection and ORDER BY are barred clause positions (only the WHERE
      // admits a correlated column of this query); `terms`/`order` bar the seam
      // intrinsically, so passing `plans.rest` cannot admit one. A nested
      // subquery there still lowers with its own inner correlation.
      let projection =
          try from.schema.terms(select.projection, in: relation,
                                context.routines, subquery: plans.rest)

      // The ORDER BY lowers its keys against the projection: an ordinal or an
      // output-alias key resolves to a select-list item's own term, an ordinary
      // expression key lowers fresh over the source. Its terms and the
      // projection are still in base-ordinal space here.
      var order = Array<SortKey>()
      if let clause = select.order {
        let names = select.projection.outputs(count: projection.count)
        order = try from.schema.order(clause, in: relation, projection, names,
                                      context.routines, subquery: plans.rest)
      }

      // Under DISTINCT every ORDER BY key must be a select-list value — the
      // dedup runs on the projected rows, so ordering on a dropped value is
      // ill-defined (see `distinct`). The order keys and projection are
      // aligned with the AST keys by index. A key matching a projected term is
      // rebound to that projected column so the sort reuses the materialised
      // slot rather than re-evaluating it.
      if select.distinct, let clause = select.order {
        order = try distinct(clause.keys, order, projection)
      }

      // The referenced ordinals, in slot order: slot `i` is `ordinals[i]`.
      let ordinals = referenced(projection, filter, order)
      let slot = invert(ordinals)
      let scan = from.leaf(ordinals)
      return scan.shaped(
          distinct: select.distinct,
          projection: projection.map { $0.remapped(through: slot) },
          filter: filter.map { $0.remapped(through: slot) },
          order: order.map { $0.remapped(through: slot) },
          limit: select.limit)
    }

    // Resolve every joined relation and lay all relations — the FROM relation
    // first, then each joined one in source order — end to end in one combined
    // ordinal space. The helper builds the running `relations` incrementally
    // and threads each join's preceding FROM as its resolve scope, so a LATERAL
    // arm's schema derives against the relations before it.
    let (joined, relations) = try resolve(from: relation, schema: from.schema,
                                          joins: select.joins, context)
    // Model each `NATURAL`/`USING` join's merged columns (ISO 9075 7.10) in the
    // join scope, and synthesize each named-column join's lowered `left.c =
    // right.c` `on` filter — a no-op yielding an empty merged set and all-`nil`
    // `ons` for a chain with none, so an ordinary compile is unchanged. The
    // scope carries the merged columns so the ordinary `terms`/`term`/order/
    // `Grouping` machinery consumes them; a named-column join's `ons[index]`
    // filter replaces its placeholder always-true `on`.
    let (ons, merged, merges) = try merges(over: relations, select.joins)
    let scope = Scope(relations, merged: merged)

    // Each join's ON predicate lowers to a `Filter` at its own chain level,
    // resolved against only the prefix already in scope plus the relation that
    // join introduces — the FROM relation and joins `0…index` — never a
    // relation joined later. Since `Scope` lays relations at cumulative offsets
    // from 0, a prefix scope yields the same global combined ordinals as the
    // full-chain scope, so the ON ordinals remap through `slot` as before;
    // resolving against the prefix rejects a reference to a not-yet-joined
    // relation (`SQLError.column`) and judges ambiguity only within the prefix.
    // A `column = column` conjunct lowers to a `match` hash-join key; any
    // inequality or expression equality lowers to a residual the join filters.
    // The WHERE and ORDER lower against the whole chain, which legitimately
    // sees every relation. Each join's prefix scope — the FROM relation and
    // joins `0…index`, the relations available at that join point, never one
    // joined later — carries the merged columns accumulated before this join
    // (`merges[index]`), so a chained `USING` `on` keys on the merged value and
    // an `ON` subquery's bare merged operand resolves.
    let prefixes = select.joins.indices.map { index in
      Scope(Array(relations[0 ... index + 1]), merged: merges[index])
    }
    // Resolve each LATERAL join's body once against the preceding FROM — the
    // FROM relation and the joins before this one (`relations[0…index]`, one
    // less than the prefix, which includes the join's own relation) — so a body
    // column naming a preceding relation correlates outward and the body's plan
    // is pre-compiled for the per-outer-row apply. A non-lateral join records
    // nothing here (its `nil` slot). The apply is `.inner` (CROSS APPLY, which
    // drops an unmatched outer row) or `.left` (OUTER APPLY, which NULL-extends
    // one); `.right`/`.full` are nonsensical for a correlated body, so fault.
    let empty: (key: Subkey, correlation: Correlation)? = nil
    var laterals = Array(repeating: empty, count: select.joins.count)
    for index in select.joins.indices {
      let join = select.joins[index]
      guard join.relation.lateral,
          case let .derived(body) = join.relation.source else { continue }
      guard join.kind == .inner || join.kind == .left else {
        throw .state("0A000", "a RIGHT/FULL LATERAL join is not supported")
      }
      let preceding = Scope(Array(relations[0 ... index]),
                            merged: merges[index])
      laterals[index] = try lateral(body, against: preceding,
                                    columns: join.relation.columns, context)
    }
    // Compile every nested subquery once for arity/type, ahead of lowering,
    // into a map the join ONs, WHERE, projection, and ORDER BY lowering reads —
    // and discover each one's correlation. A join `ON`'s subquery correlates
    // against its prefix scope; the WHERE/projection/ORDER against the whole
    // join `scope`. This select's own columns correlate outward through
    // `outer`. `validate` gates a nested filtered-out derived body's eager
    // type-check.
    let plans = try subquery(of: select, context, enclosing: scope,
                             prefixes: prefixes)
    var matches = Array<Filter>()
    matches.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      // A `NATURAL`/`USING` join's `on` is the synthesized, already-lowered
      // `left.c = right.c` filter (`ons[index]`, `nil` for a degenerate
      // shared-column-less `NATURAL` join — an always-true `CROSS` product);
      // a plain join lowers its written `ON` against the prefix scope.
      if let on = ons[index] {
        matches.append(on)
      } else {
        try matches.append(prefixes[index].on(select.joins[index].on,
                                              context.routines,
                                              subquery: plans.on(index)))
      }
    }
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause, context.routines,
                                  subquery: plans.rest)
    }
    // The projection and ORDER BY are barred clause positions: a correlated
    // column of this query is out of the minimal (b) cut there (only its
    // WHERE/ON admits one), so `terms`/`order` bar the seam intrinsically and
    // it is diagnosed rather than mis-resolved. A nested subquery in the
    // projection still lowers — its own inner WHERE correlation was discovered
    // in the pre-pass.
    let projection = try scope.terms(select.projection, context.routines,
                                     subquery: plans.rest)

    // The ORDER BY lowers its keys against the projection (as the
    // single-relation path does): an ordinal or an output-alias key resolves to
    // a select-list item's own term, an ordinary expression key lowers fresh
    // over the chain. Its terms and the projection are in combined base-ordinal
    // space here.
    var order = Array<SortKey>()
    if let clause = select.order {
      let names = select.projection.outputs(count: projection.count)
      order = try scope.order(clause, projection, names, context.routines,
                              subquery: plans.rest)
    }

    // Under DISTINCT every ORDER BY key must be a select-list value (see
    // `distinct`); order keys and projection are in combined base-ordinal
    // space here, aligned with the AST keys index-for-index. A key matching a
    // projected term is rebound to that projected column so the sort reuses the
    // materialised slot rather than re-evaluating it.
    if select.distinct, let clause = select.order {
      order = try distinct(clause.keys, order, projection)
    }

    // The combined referenced ordinals — projection ∪ every match ∪ WHERE ∪
    // order — packed per relation in chain order: relation i's referenced
    // ordinals take a contiguous slot run after every earlier relation's,
    // building the combined-ordinal → slot map and each relation's leaf
    // ordinals.
    var references = Set<Int>()
    for term in projection { term.references(into: &references) }
    for match in matches { match.references(into: &references) }
    predicate?.references(into: &references)
    for key in order { key.term.references(into: &references) }
    // A LATERAL apply reads its correlation's outer ordinals from the left
    // chain's record, so those preceding-relation ordinals must be materialised
    // (given a packed slot) even when no clause of this select references them
    // — else the correlation's remap through `slot` finds no slot for the outer
    // column its body names.
    for lateral in laterals {
      references.formUnion(lateral?.correlation.slots ?? [])
    }
    let combined = references.sorted()

    var slot = Dictionary<Int, Int>(minimumCapacity: combined.count)
    var locals = Array<Array<Int>>()
    var packed = 0
    for (offset, extent) in scope.layout {
      let local = combined.compactMap {
        offset <= $0 && $0 < offset + extent ? $0 - offset : nil
      }
      for index in local.indices {
        slot[offset + local[index]] = packed + index
      }
      locals.append(local)
      packed += local.count
    }

    // The left-deep chain: starting from the FROM relation's leaf, each join
    // folds in the next relation's scan. An INNER join is a `Select` on that
    // join's ON over the product — the optimiser turns each `Select`-over-
    // `Product` level into an index-nested-loop join. An OUTER join is an
    // `outer` node holding the ON directly, so the ON governs matching alone
    // and an unmatched preserved row is NULL-extended rather than dropped; its
    // ON is NOT distributed into the product (a `WHERE` still filters after
    // it).
    var chain = from.leaf(locals[0])
    for index in select.joins.indices {
      let on = matches[index].remapped(through: slot)
      // A LATERAL join re-evaluates its pre-compiled body per outer row (a
      // correlated apply): the apply node carries the body occurrence's `key`
      // and its correlation (its `slot` outer ordinals remapped to the left
      // chain's packed slots, so the per-row bind reads the correct cell) plus
      // the referenced body-output `ordinals` this select takes, laid after the
      // left's slots. Its `on` filters the concatenated pair; INNER APPLY drops
      // a left row with no surviving right row.
      if let lateral = laterals[index] {
        chain = .apply(chain, key: lateral.key,
                       correlation: lateral.correlation.remapped(through: slot),
                       ordinals: locals[index + 1], on: on,
                       kind: select.joins[index].kind)
        continue
      }
      let leaf = joined[index].leaf(locals[index + 1])
      switch select.joins[index].kind {
      case .inner:
        chain = .select(on, .product(chain, leaf))
      case .left, .right, .full:
        chain = .outer(chain, leaf, on: on, kind: select.joins[index].kind)
      }
    }

    return chain.shaped(
        distinct: select.distinct,
        projection: projection.map { $0.remapped(through: slot) },
        filter: predicate.map { $0.remapped(through: slot) },
        order: order.map { $0.remapped(through: slot) },
        limit: select.limit)
  }
}
