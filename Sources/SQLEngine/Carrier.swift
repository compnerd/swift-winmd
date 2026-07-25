// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Ordered set operation

/// A grouped-arm resolver a carrier caller injects: the RESOLVED grouped-space
/// `Term` of each projected item, and a closure lowering an arbitrary
/// expression to that same space — the identity surface a query-level `ORDER
/// BY` key matches against by resolved identity. A plain set-operation carrier
/// injects none (`nil`).
internal typealias Resolver =
    (terms: Array<Term>, resolve: (Expression) throws(SQLError) -> Term)

extension Catalog where Self: ~Escapable {
  /// Compiles an `ORDER BY` / `SELECT DISTINCT` / `OFFSET`·`FETCH` carried over
  /// the set-operation `union` — the `Query.ordered` carrier — into the row
  /// operators STACKED over the union's compiled plan, resolved through the
  /// setop's OUTPUT scope.
  ///
  /// A `setop` node has no order/distinct/limit slot, so the query-level row
  /// operators ride this outer carrier rather than a text `SELECT * FROM
  /// (union) AS g ORDER BY …` wrapper. They resolve against a scope over the
  /// union's OUTPUT columns — the arm-0-named, type-unified result columns —
  /// the SAME canonical resolution any `SELECT … FROM <derived> ORDER BY
  /// <alias/ordinal/expr>` uses, so:
  ///
  ///   - an ordinal `ORDER BY n`, an output alias, or a bare projected column
  ///     orders on that output column (its slot in the union output);
  ///   - a generated `column N` display header is NOT among the scope's
  ///     bindable output names, so `ORDER BY "column N"` faults `.column` — as
  ///     it does over any derived union — rather than being wrongly accepted;
  ///   - a bare name matching TWO output columns faults `SQLError.ambiguous`,
  ///     as a plain grouped query's `ORDER BY` does;
  ///   - under `DISTINCT` a key must name an output (`distinct(_:_:_:)` over
  ///     the identity projection), matching the plain-grouped rule.
  ///
  /// The row operators do NOT project — the result schema is the union's — so
  /// the carrier's projection is the IDENTITY over the real output slots
  /// (`0 ..< real`), which also trims any hidden materialised column.
  internal borrowing func ordered(_ union: Query, distinct: Bool,
                                  order: Order?, limit: Limit?,
                                  generated: Int,
                                  _ context: Context) throws(SQLError) -> Plan {
    // Compile the inner union and derive its OUTPUT columns — the arm-0-named,
    // type-unified result columns the carrier orders/dedups over. The plan's
    // output sits at slots `0 ..< width` (a `setop`'s output is its arm-0
    // projection), so the carrier resolves and stacks in that identity space.
    // The shared `carried(over:)` resolver then does the whole ORDER BY /
    // DISTINCT resolution against the setop-output scope and stacks the row
    // operators.
    let plan = try compile(union, context)
    let cols = try columns(unifying: union, context)
    // A GROUPING SETS expansion's arm-0 is a GROUPED `.arm` select; a plain
    // set-operation chain's is not. For a GROUPING SETS carrier, inject a
    // resolver that lowers the arm's projection — and any ORDER BY key — to the
    // arm's grouped-space `Term`s, so a query-level `ORDER BY` matches a
    // projected aggregate by RESOLVED identity (`SUM(s.Qty)` ≡ projected
    // `SUM(Qty)`), the plain grouped `ORDER BY` path's rule. A plain arm has no
    // grouped aggregate space and injects none.
    let resolver: Resolver? =
        if case .arm = union.first.grouping {
          try projected(arm: union.first, context)
        } else {
          nil
        }
    return try carried(over: plan, output: cols, arm: union.first,
                       distinct: distinct, order: order, limit: limit,
                       generated: generated, resolver: resolver, context)
  }

  /// The REAL output count of an `ordered` carrier over a `width`-column set
  /// operation — the trim width `width − generated`, the leading real outputs
  /// with the trailing `generated` hidden materialised sort columns dropped.
  ///
  /// `Query.ordered` is a PUBLIC AST case a caller may build with a `generated`
  /// count out of step with the inner union's width (the parser only ever emits
  /// `0`, and `expand` an in-range count). A count PAST the width, or NEGATIVE,
  /// would make the trim width negative — the carrier's `0 ..< real` range and
  /// per-column subscripts, and the schema path's `Array.prefix`, would TRAP
  /// the process. Rejecting the malformed count with ONE typed internal-error
  /// fault, read by BOTH the compile carrier (`carried`) and the schema path
  /// (`columns(unifying:)`), keeps `run ≡ columns(of:)` on a malformed carrier.
  internal func real(trimming generated: Int, of width: Int)
      throws(SQLError) -> Int {
    guard generated >= 0, generated <= width else {
      throw .state("XX000",
                   "ordered set-operation generated count out of range")
    }
    return width - generated
  }

  /// Stacks the query-level row operators — a carried `ORDER BY` / `DISTINCT` /
  /// `OFFSET`·`FETCH` — over an already-compiled set-operation `plan`, resolved
  /// through the setop's OUTPUT scope. `plan`'s output sits at slots
  /// `0 ..< output.count`, the arm-0-named, type-unified result columns
  /// (`output`); `arm` is the union's FIRST arm — its projection is the surface
  /// a projected-expression / aliased / qualified ORDER BY key matches against
  /// by AST (a plain set-op arm).
  ///
  /// `resolver`, when INJECTED, lowers the arm's projected items to a grouped
  /// slot space and lowers an arbitrary expression to the same space — a
  /// resolved-identity surface a caller over a grouped arm supplies so a
  /// query-level `ORDER BY` key matches a projected aggregate by resolved
  /// identity. A plain set-operation arm has no grouped aggregate space and
  /// passes `nil`, so the carrier keeps the ordinary AST/output-name
  /// resolution; `generated` is then `0` and no hidden slot is materialised or
  /// trimmed.
  ///
  /// A `setop` node has no order/distinct/limit slot, so the query-level row
  /// operators ride this outer carrier rather than a text `SELECT * FROM
  /// (union) AS g ORDER BY …` wrapper. They resolve against a scope over the
  /// setop's OUTPUT columns — the arm-0-named, type-unified result columns —
  /// the SAME canonical resolution any `SELECT … FROM <derived> ORDER BY
  /// <alias/ordinal/expr>` uses.
  ///
  /// The row operators do NOT project — the result schema is the union's — so
  /// the carrier's projection is the IDENTITY over the real output slots
  /// (`0 ..< real`), which also trims any hidden materialised column.
  internal borrowing func carried(over plan: Plan,
                                  output cols: Array<ResolvedColumn>,
                                  arm: Select, distinct: Bool, order: Order?,
                                  limit: Limit?, generated: Int,
                                  resolver: Resolver? = nil,
                                  _ context: Context)
      throws(SQLError) -> Plan {
    if let limit {
      // A direct `Limit(count:offset:)` may carry negatives the executor's
      // skip and take would trap on (the parser yields only non-negatives).
      // Reject them as a query error, as the `Select` compile path does.
      guard limit.offset >= 0 else {
        throw .state("2201X", "OFFSET row count must be non-negative")
      }
      guard (limit.count ?? 0) >= 0 else {
        throw .state("2201W", "FETCH row count must be non-negative")
      }
    }
    let width = cols.count
    // The union's arm-0 projection carries the real output items followed by
    // any hidden materialised sort columns (a producer aliases them `*gsN`).
    // The REAL output count `real` is the carrier's trim width — the STRUCTURAL
    // `generated` count carried on the node (never a scan of the arm-0 names
    // for a `*gs` prefix, which would trim a user's delimited `AS "*gs0"`), so
    // slots `0 ..< real` are the real outputs and `real ..< width` the hidden
    // ones. The hidden expressions map to their `*gsN` output slots for a
    // materialised ORDER BY key.
    let items: Array<Projected> = switch arm.projection {
    case let .expressions(list):
      list
    case let .columns(columns):
      columns.map { Projected(expression: .column($0)) }
    case .all:
      []
    }
    // Range-check the `generated` count against the width and derive the trim
    // width `real` through the shared guard (see `real(trimming:of:)`), which
    // faults a malformed public-AST count rather than letting the `0 ..< real`
    // range below or a per-column subscript TRAP. The SAME guard backs the
    // schema path (`columns(unifying:)`), so `run ≡ columns(of:)`.
    let real = try real(trimming: generated, of: width)
    // A `generated` tail must correspond to genuine HIDDEN aliased columns — a
    // producer's `*gsN` items, each carrying a non-nil alias. A caller may,
    // though, build `.ordered(<2-col union>, generated: 1)` over an ORDINARY
    // union whose trailing item is a normal projected column with NO alias, OR
    // `.ordered(<SELECT * union>, generated: N>0)` whose arm-0 projection is
    // `.all` so `items` is EMPTY though `width > 0`: the hidden-name mapping's
    // `items[real + k].alias!` below would TRAP (an unaliased item, or an
    // absent one when `items` is short). Prove each generated tail slot HAS a
    // corresponding aliased projected item before force-unwrapping, faulting
    // the same typed internal-error the range guard raises rather than
    // crashing. (Not a `where` skip: an absent slot must fault, not pass.)
    for k in 0 ..< generated {
      guard real + k < items.count, items[real + k].alias != nil else {
        throw .state("XX000",
                     "ordered set-operation generated tail is not aliased")
      }
    }
    // The output NAME of each REAL column — an alias, else a bare column. An
    // unnamed output (a computed column with no `AS`) has NO bindable name: it
    // is reachable only by ordinal, so it takes a non-spellable synthetic name
    // (`*colN`, which a normal or delimited identifier cannot spell) rather
    // than the positional `column N` DISPLAY header — else `ORDER BY "column
    // N"` would wrongly bind it, where a plain derived union faults `.column`.
    //
    // Whether an output is unnamed is the RESOLVED column's STRUCTURAL
    // `synthesized` flag — set where the projection had no inferable name
    // (`Projected.name == nil`) and a positional `column N` was substituted —
    // NOT a comparison of the resolved name text to `column N`, which would
    // mistake a user's EXPLICIT delimited `AS "column 1"` for a synthesized
    // header and strip it. A named output keeps its name; a synthesized one is
    // `nil` here (not bindable). (A `SELECT *`/`TABLE` first arm names every
    // output through `cols`, never synthesized, and carries no hidden column,
    // so `real == width`.)
    let outputs: Array<String?> = (0 ..< real).map {
      cols[$0].synthesized ? nil : cols[$0].name
    }
    // The scope over the union's output. The schema names EVERY column so
    // `term` can resolve a materialised key's synthetic column: a named real
    // output by its name, an UNNAMED real output by a non-spellable `*colN`,
    // and each hidden materialised column by its `*gsN` alias.
    let schema = Schema(from: cols,
                        names: (0 ..< width).map {
                          $0 < real ? (outputs[$0] ?? "*col\($0)")
                                    : items[$0].alias!
                        },
                        extent: width, virtuals: [])
    // The derived relation is a scope entry keyed by the empty alias, so bare
    // ORDER BY / DISTINCT names resolve unqualified over the `schema`; its
    // inner query is inspected nowhere here, so the arm-0 `SELECT` stands in
    // for it uniformly.
    let scope = Scope([(Relation(derived: .select(arm), as: ""), schema)])
    // COLLECT and RESOLVE the carrier ORDER BY's OWN nested subqueries — the
    // SAME machinery a plain `SELECT … ORDER BY CASE WHEN EXISTS (…) …` uses
    // (`subquery(_:_:_:within:)` builds a `Resolution` recording each nested
    // query's width/type/plan against the setop-output `scope`, AND records a
    // CORRELATED one's runtime plan into `context.subqueries` per the ROLE it
    // occupies). A carried `ORDER BY` over a set operation is otherwise lowered
    // with the DEFAULT `.unsupported` resolution, so `scope.order` REJECTS an
    // `EXISTS`/`IN`/scalar sort-key subquery a plain `SELECT`'s ORDER BY
    // accepts. Threading this resolution in makes a set operation's ORDER BY
    // resolve a subquery sort key identically to a plain select's; an ORDER BY
    // position bars a NEW correlation (`.barred` inside `scope.order`), so a
    // genuinely-unsupported case still faults exactly as it does on a SELECT.
    //
    // `roles(of:)` classifies a subquery by the CLAUSE it occurs in, so the
    // recording pass must inspect a select whose ORDER BY IS the carrier's —
    // NOT the bare `arm`, whose own ORDER BY does not carry the carrier's sort-
    // key subqueries. Reusing `arm` there records NO runtime plan (empty
    // roles), so a CORRELATED carrier sort-key subquery lowers to a
    // `Term.subquery`/`.parameter` yet faults "a correlated subquery plan was
    // not compiled" at execution — where the SAME ORDER BY on a plain SELECT
    // records and re-executes it per row. Overlay the carrier's `order` on the
    // arm (keeping the arm's projection surface a projected-expression key
    // resolves against) so the recording sees the carrier's sort-key subqueries
    // in their ORDER BY role. The projected-key resolution itself still runs
    // over `arm` in `scope.order` below; `subquery(_:_:_:within:)` reads the
    // passed select ONLY for `roles(of:)`.
    var subqueries = Array<Query>()
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &subqueries)
      }
    }
    let classifier = Select(distinct: arm.distinct, projection: arm.projection,
                            from: arm.from, joins: arm.joins,
                            predicate: arm.predicate, grouping: arm.grouping,
                            having: arm.having, order: order, limit: arm.limit)
    let resolution = try subquery(subqueries, classifier, context,
                                  within: scope)
    // The identity projection over the REAL output slots, and the REAL output
    // names a bare ORDER BY name or a DISTINCT key binds against — alias-or-
    // bare, `nil` for an unnamed output. `scope.order` bounds an ORDINAL key by
    // this projection's COUNT, so it must be the REAL arity (`real`), NOT the
    // grown `width`.
    let projection = (0 ..< real).map(Term.slot)
    let names: Array<String?> = (0 ..< real).map { outputs[$0] }
    // Resolve the ORDER BY through the setop-output scope. Rewrite only a key
    // the scope cannot resolve for itself over the union's output.
    var keys = Array<SortKey>()
    if let order {
      // The REAL projected items an `ORDER BY <expr>` key may match to its
      // ordinal — the arm-0 projection minus its trailing hidden `*gsN`
      // columns. EMPTY for a `SELECT *`/`TABLE` first arm (no enumerated
      // projection to match), so such a key falls to the scope's ordinary
      // resolution over the `*`-expanded output columns.
      let reals = Array(items.prefix(real))
      let folded = Set(outputs.compactMap { $0?.lowercased() })
      // A key resolving to a HIDDEN materialised slot (`real ..< width`) is
      // bound STRUCTURALLY, by KEY INDEX → that slot, NOT by rewriting to the
      // generated `*gsN` NAME. The hidden alias is a SPELLABLE delimited
      // identifier a user's own output could carry (`SELECT Region AS "*gs0" …
      // ORDER BY MAX(Qty)`), so a name rewrite would let `scope.order`'s
      // output-alias precedence CAPTURE the hidden key onto the real `*gs0`
      // output. Recording the slot and OVERWRITING the resolved key's `term`
      // below binds it by position, immune to a colliding alias.
      var materialised = Dictionary<Int, Int>()
      let rewritten = Order(keys: try order.keys.enumerated().map {
        (offset, key) throws(SQLError) -> Order.Key in
        guard case let .expression(expression) = key.sort else { return key }
        // A BARE unqualified column NAMING A REAL OUTPUT is left to the
        // setop-output scope's ordinary resolution, whichever carrier: it binds
        // an output alias or a bare projected column BY NAME and faults
        // `.ambiguous` on a name TWO outputs share — the ISO precedence
        // `scope.order` applies before a term match, which a resolved-identity
        // rewrite to an ordinal would wrongly bypass. A bare column that is NOT
        // a real output rides the resolver (when injected) to its hidden slot.
        let bare = if case let .column(column) = expression {
          column.qualifier == nil && folded.contains(column.name.lowercased())
        } else {
          false
        }
        // A grouped-arm caller's injected resolver: match a QUALIFIED column or
        // a NON-column expression against the arm's projected terms by RESOLVED
        // identity. A key that lowers cleanly and equals a projected term
        // orders on that slot's ORDINAL — a REAL slot directly, a HIDDEN slot
        // bound structurally below (never through its spellable `*gsN` name). A
        // key `resolve` faults on is left for the setop-output scope to bind or
        // fault, as before.
        if let resolver, !bare {
          let term = try? resolver.resolve(expression)
          if let term, let slot = resolver.terms.firstIndex(of: term) {
            if slot < real {
              return Order.Key(sort: .ordinal(slot + 1),
                               ascending: key.ascending)
            }
            // The hidden slot: record it against this key's index and stand a
            // resolvable ORDINAL placeholder (`1`, the first real output) in
            // its place so `scope.order` yields an aligned SortKey WITHOUT
            // trying to recompute the unprojected aggregate over the
            // output-only scope; its `term` is overwritten to `.slot(slot)`
            // afterward, binding the hidden column by POSITION.
            materialised[offset] = slot
            return Order.Key(sort: .ordinal(1), ascending: key.ascending)
          }
          return key
        }
        if resolver != nil { return key }
        // Plain set-operation carrier: a materialised key (a hidden `*gsN`
        // item, matched by AST) is bound structurally to that hidden slot,
        // through the same ORDINAL-placeholder-then-overwrite the resolver path
        // uses, so a colliding `*gsN` alias cannot capture it.
        if let slot = (real ..< width).first(where: {
          items[$0].expression == expression
        }) {
          materialised[offset] = slot
          return Order.Key(sort: .ordinal(1), ascending: key.ascending)
        }
        if case .column = expression {
          // A column key — bare or qualified — rides through to `scope.order`.
          // A bare name binds an output by ISO alias precedence (or faults
          // `.ambiguous` on a name two outputs share). A QUALIFIED key faults
          // there: the set-operation output carries NO range, so `R.a` /
          // `NoSuch.a` fails resolution exactly as the derived-union
          // equivalent does — it is NOT silently sorted by a bare output `a`
          // after dropping an invalid qualifier.
          return key
        }
        if let index = reals.firstIndex(where: {
          $0.expression == expression
        }) {
          return Order.Key(sort: .ordinal(index + 1),
                           ascending: key.ascending)
        }
        return key
      })
      keys = try scope.order(rewritten, projection, names, context.routines,
                             subquery: resolution)
      // Bind each materialised key to its HIDDEN slot by POSITION, overwriting
      // the ordinal placeholder's resolved key: `.slot(slot)` orders on the
      // hidden `*gsN` column directly, `column` cleared so it is an ordinary
      // input key (NOT a select-list output — DISTINCT then rejects it, and it
      // is trimmed by the identity projection). This never spells the hidden
      // `*gsN` NAME, so a user output aliased identically cannot capture it.
      for (offset, slot) in materialised {
        keys[offset] = SortKey(term: .slot(slot),
                               ascending: keys[offset].ascending, column: nil)
      }
      // The carrier's ORDER BY is a NEW expression surface: `scope.order`
      // RESOLVES each key (binds a column, arity), but — like the grouped
      // path's structural resolve — does NOT type-check a key's operands or its
      // calls, so an unknown routine (`ORDER BY missing(a)`) or an ill-typed
      // operand (`ORDER BY a + 'x'`) a run raises on slipped past validate.
      // Under `validate`, type-check each key EXPRESSION against the SAME
      // setop-output scope it resolved over — its calls and operands as a
      // projected expression's — so validate faults IDENTICALLY to a run. An
      // ordinal/output-name key carries no `.expression` to re-check. The run
      // path compiles LENIENTLY (`validate: false`), so this never double-
      // faults there — the run surfaces the fault at execution as it did
      // before.
      if context.validate {
        // A carrier ORDER BY key may nest an `EXISTS`/`IN`/scalar subquery
        // (`ORDER BY CASE WHEN EXISTS (…) …`), which the `scope.validate`
        // type-check below rejects under the DEFAULT `.unsupported`
        // `SubqueryCheck`. Record each nested subquery's width and type — the
        // SAME cursor-free pre-pass `subqueryCheck(of:)` runs for a plain
        // SELECT's ORDER BY subqueries — so the type-check validates a subquery
        // sort key rather than faulting `.unsupported`, keeping the schema path
        // in step with the run (which resolves the same key through
        // `resolution` above).
        //
        // Derive each subquery's width/type against the SAME setop-output
        // `scope` the run resolves it through (`subquery(_:_:_:within: scope)`
        // above): a carrier ORDER BY subquery may reference a set-operation
        // OUTPUT column — an aliased output living ONLY in this scope, unseen
        // by `context.outer` — so nesting `scope` under the outer, enclosing-
        // scope shape `subquery(_:_:_:within:)` builds, resolves it at validate
        // EXACTLY as it does at run. Threading bare `context.outer` faulted
        // `.column` on a set-op output column a run resolves, rejecting a query
        // that executes. A genuinely-unresolvable column (not a set-op output,
        // absent from the outer) still faults here as it does at run.
        let nested = (context.outer ?? Outer()).nested(under: scope)
        var widths = Dictionary<Query, Int>()
        var types = Dictionary<Query, ValueType>()
        for query in subqueries {
          try self.width(query, [], context, nested, &widths, &types)
        }
        let check = SubqueryCheck(widths, types).barred
        for key in rewritten.keys {
          guard case let .expression(expression) = key.sort else { continue }
          try scope.aggregates(in: expression, context.routines,
                               subquery: check)
          _ = try scope.validate(expression, context.routines, subquery: check)
        }
      }
    }
    // Under DISTINCT every ORDER BY key must be a select-list value (see
    // `distinct`); the keys and identity projection are in the union's output
    // slot space, aligned with the AST keys index-for-index. The DISTINCT check
    // sees ONLY the REAL outputs (`0 ..< real`), NOT the hidden materialised
    // sort columns: a hidden `*gsN` slot is not a select-list value.
    if distinct, let order {
      keys = try SQLEngine.distinct(order.keys, keys,
                                    (0 ..< real).map(Term.slot))
    }
    // Stack the row operators over the union plan, trimming to the REAL output
    // columns with the identity projection `0 ..< real` (dropping any hidden
    // materialised sort column).
    return plan.shaped(distinct: distinct,
                       projection: (0 ..< real).map(Term.slot),
                       filter: nil, order: keys, limit: limit)
  }
}
