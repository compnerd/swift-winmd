// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Ordered set operation

/// A grouped-arm resolver a carrier caller injects: the resolved grouped-space
/// `Term` of each projected item, and a closure lowering an arbitrary
/// expression to that same space — the identity surface a query-level `ORDER
/// BY` key matches against by resolved identity. A plain set-operation carrier
/// injects none (`nil`).
internal typealias Resolver =
    (terms: Array<Term>, resolve: (Expression) throws(SQLError) -> Term)

extension Catalog where Self: ~Escapable {
  /// Compiles an `ORDER BY` / `SELECT DISTINCT` / `OFFSET`·`FETCH` carried over
  /// the set-operation `union` — the `Query.ordered` carrier — into the row
  /// operators stacked over the union's compiled plan, resolved through the
  /// setop's output scope.
  ///
  /// A `setop` node has no order/distinct/limit slot, so the query-level row
  /// operators ride this outer carrier rather than a text `SELECT * FROM
  /// (union) AS g ORDER BY …` wrapper. They resolve against a scope over the
  /// union's output columns — the arm-0-named, type-unified result columns —
  /// the same canonical resolution any `SELECT … FROM <derived> ORDER BY
  /// <alias/ordinal/expr>` uses, so:
  ///
  ///   - an ordinal `ORDER BY n`, an output alias, or a bare projected column
  ///     orders on that output column (its slot in the union output);
  ///   - a generated `column N` display header is NOT among the scope's
  ///     bindable output names, so `ORDER BY "column N"` faults `.column` — as
  ///     it does over any derived union — rather than being wrongly accepted;
  ///   - a bare name matching two output columns faults `SQLError.ambiguous`,
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
    // Compile the inner union and derive its output columns — the arm-0-named,
    // type-unified result columns the carrier orders/dedups over. The plan's
    // output sits at slots `0 ..< width` (a `setop`'s output is its arm-0
    // projection), so the carrier resolves and stacks in that identity space.
    // The shared `carried(over:)` resolver then does the whole ORDER BY /
    // DISTINCT resolution against the setop-output scope and stacks the row
    // operators.
    let plan = try compile(union, context)
    let cols = try columns(unifying: union, context)
    // A GROUPING SETS expansion's arm-0 is a grouped `.arm` select; a plain
    // set-operation chain's is not. For a GROUPING SETS carrier, inject a
    // resolver that lowers the arm's projection — and any ORDER BY key — to the
    // arm's grouped-space `Term`s, so a query-level `ORDER BY` matches a
    // projected aggregate by resolved identity (`SUM(s.Qty)` ≡ projected
    // `SUM(Qty)`), the plain grouped `ORDER BY` path's rule. A plain arm has no
    // grouped aggregate space and injects none.
    let arm = union.arm
    let resolver: Resolver? =
        if case let .select(select) = arm.body, case .arm = select.grouping {
          try projected(arm: select, context)
        } else {
          nil
        }
    return try carried(over: plan, output: cols, arm: arm,
                       distinct: distinct, order: order, limit: limit,
                       generated: generated, resolver: resolver, context)
  }

  /// The REAL output count of an `ordered` carrier over a `width`-column set
  /// operation — the trim width `width − generated`, the leading real outputs
  /// with the trailing `generated` hidden materialised sort columns dropped.
  ///
  /// `Query.ordered` is a public AST case a caller may build with a `generated`
  /// count out of step with the inner union's width (the parser only ever emits
  /// `0`, and `expand` an in-range count). A count past the width, or negative,
  /// would make the trim width negative — the carrier's `0 ..< real` range and
  /// per-column subscripts, and the schema path's `Array.prefix`, would trap
  /// the process. Rejecting the malformed count with one typed internal-error
  /// fault, read by both the compile carrier (`carried`) and the schema path
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
  /// through the setop's output scope. `plan`'s output sits at slots
  /// `0 ..< output.count`, the arm-0-named, type-unified result columns
  /// (`output`); `arm` is the query's leftmost arm (a carrier-free `Query`) —
  /// its `items` projection surface is what a projected-expression / aliased /
  /// qualified ORDER BY key matches against by AST (a plain set-op arm).
  ///
  /// `resolver`, when injected, lowers the arm's projected items to a grouped
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
  /// setop's output columns — the arm-0-named, type-unified result columns —
  /// the same canonical resolution any `SELECT … FROM <derived> ORDER BY
  /// <alias/ordinal/expr>` uses.
  ///
  /// The row operators do NOT project — the result schema is the union's — so
  /// the carrier's projection is the IDENTITY over the real output slots
  /// (`0 ..< real`), which also trims any hidden materialised column.
  internal borrowing func carried(over plan: Plan,
                                  output cols: Array<ResolvedColumn>,
                                  arm: Query, distinct: Bool, order: Order?,
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
    // The REAL output count `real` is the carrier's trim width — the structural
    // `generated` count carried on the node (never a scan of the arm-0 names
    // for a `*gs` prefix, which would trim a user's delimited `AS "*gs0"`), so
    // slots `0 ..< real` are the real outputs and `real ..< width` the hidden
    // ones. The hidden expressions map to their `*gsN` output slots for a
    // materialised ORDER BY key.
    let items = arm.items
    // Range-check the `generated` count against the width and derive the trim
    // width `real` through the shared guard (see `real(trimming:of:)`), which
    // faults a malformed public-AST count rather than letting the `0 ..< real`
    // range below or a per-column subscript trap. The same guard backs the
    // schema path (`columns(unifying:)`), so `run ≡ columns(of:)`.
    let real = try real(trimming: generated, of: width)
    // A `generated` tail must correspond to genuine hidden aliased columns — a
    // producer's `*gsN` items, each carrying a non-nil alias. A caller may,
    // though, build `.ordered(<2-col union>, generated: 1)` over an ordinary
    // union whose trailing item is a normal projected column with no alias, OR
    // `.ordered(<SELECT * union>, generated: N>0)` whose arm-0 projection is
    // `.all` so `items` is empty though `width > 0`: the hidden-name mapping's
    // `items[real + k].alias!` below would trap (an unaliased item, or an
    // absent one when `items` is short). Prove each generated tail slot has a
    // corresponding aliased projected item before force-unwrapping, faulting
    // the same typed internal-error the range guard raises rather than
    // crashing. (Not a `where` skip: an absent slot must fault, not pass.)
    for k in 0 ..< generated {
      guard real + k < items.count, items[real + k].alias != nil else {
        throw .state("XX000",
                     "ordered set-operation generated tail is not aliased")
      }
    }
    // The output name of each REAL column — an alias, else a bare column. An
    // unnamed output (a computed column with no `AS`) has no bindable name: it
    // is reachable only by ordinal, so it takes a non-spellable synthetic name
    // (`*colN`, which a normal or delimited identifier cannot spell) rather
    // than the positional `column N` display header — else `ORDER BY "column
    // N"` would wrongly bind it, where a plain derived union faults `.column`.
    //
    // Whether an output is unnamed is the resolved column's structural
    // `synthesized` flag — set where the projection had no inferable name
    // (`Projected.name == nil`) and a positional `column N` was substituted —
    // NOT a comparison of the resolved name text to `column N`, which would
    // mistake a user's explicit delimited `AS "column 1"` for a synthesized
    // header and strip it. A named output keeps its name; a synthesized one is
    // `nil` here (not bindable). (A `SELECT *`/`TABLE` first arm names every
    // output through `cols`, never synthesized, and carries no hidden column,
    // so `real == width`.)
    let outputs: Array<String?> = (0 ..< real).map {
      cols[$0].synthesized ? nil : cols[$0].name
    }
    // The scope over the union's output. The schema names every column so
    // `term` can resolve a materialised key's synthetic column: a named real
    // output by its name, an unnamed real output by a non-spellable `*colN`,
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
    let scope = Scope([(Relation(derived: arm, as: ""), schema)])
    // collect and resolve the carrier ORDER BY's own nested subqueries — the
    // same machinery a plain `SELECT … ORDER BY CASE WHEN EXISTS (…) …` uses
    // (`subquery(_:_:_:within:)` builds a `Resolution` recording each nested
    // query's width/type/plan against the setop-output `scope`, AND records a
    // correlated one's runtime plan into `context.subqueries` per the role it
    // occupies). A carried `ORDER BY` over a set operation is otherwise lowered
    // with the DEFAULT `.unsupported` resolution, so `scope.order` rejects an
    // `EXISTS`/`IN`/scalar sort-key subquery a plain `SELECT`'s ORDER BY
    // accepts. Threading this resolution in makes a set operation's ORDER BY
    // resolve a subquery sort key identically to a plain select's; an ORDER BY
    // position admits a correlated column (`scope.order` resolves it against
    // the enclosing scope), exactly as it does on a SELECT.
    //
    // `roles(of:order:)` classifies a subquery by the clause it occurs in — the
    // carrier path's `ORDER BY` IS the carrier's, NOT the leftmost arm's own (a
    // bare arm's ORDER BY does not carry the carrier's sort-key subqueries).
    // Classifying over `arm`'s clauses ⊕ the carrier's `order` records a
    // correlated carrier sort-key subquery's runtime plan (else it lowers to a
    // `Term.subquery`/`.parameter` yet faults "a correlated subquery plan was
    // not compiled" at execution), and resolves for any leftmost arm — a
    // `Select` or a `VALUES` — without a synthetic classifier `Select`.
    var subqueries = Array<Query>()
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &subqueries)
      }
    }
    let resolution = try subquery(subqueries,
                                  roles: { arm.roles(of: $0, order: order) },
                                  context, within: scope)
    // The identity projection over the REAL output slots, and the REAL output
    // names a bare ORDER BY name or a DISTINCT key binds against — alias-or-
    // bare, `nil` for an unnamed output. `scope.order` bounds an ordinal key by
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
      // columns. empty for a `SELECT *`/`TABLE` first arm (no enumerated
      // projection to match), so such a key falls to the scope's ordinary
      // resolution over the `*`-expanded output columns.
      let reals = Array(items.prefix(real))
      let folded = Set(outputs.compactMap { $0?.lowercased() })
      // A key resolving to a hidden materialised slot (`real ..< width`) is
      // bound structurally, by KEY index → that slot, NOT by rewriting to the
      // generated `*gsN` name. The hidden alias is a spellable delimited
      // identifier a user's own output could carry (`SELECT Region AS "*gs0" …
      // ORDER BY MAX(Qty)`), so a name rewrite would let `scope.order`'s
      // output-alias precedence capture the hidden key onto the real `*gs0`
      // output. Recording the slot and overwriting the resolved key's `term`
      // below binds it by position, immune to a colliding alias.
      var materialised = Dictionary<Int, Int>()
      let rewritten = Order(keys: try order.keys.enumerated().map {
        (offset, key) throws(SQLError) -> Order.Key in
        guard case let .expression(expression) = key.sort else { return key }
        // A bare unqualified column naming A REAL output is left to the
        // setop-output scope's ordinary resolution, whichever carrier: it binds
        // an output alias or a bare projected column BY name and faults
        // `.ambiguous` on a name two outputs share — the ISO precedence
        // `scope.order` applies before a term match, which a resolved-identity
        // rewrite to an ordinal would wrongly bypass. A bare column that is NOT
        // a real output rides the resolver (when injected) to its hidden slot.
        let bare = if case let .column(column) = expression {
          column.qualifier == nil && folded.contains(column.name.lowercased())
        } else {
          false
        }
        // A grouped-arm caller's injected resolver: match a qualified column or
        // a non-column expression against the arm's projected terms by resolved
        // identity. A key that lowers cleanly and equals a projected term
        // orders on that slot's ordinal — a REAL slot directly, a hidden slot
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
            // resolvable ordinal placeholder (`1`, the first real output) in
            // its place so `scope.order` yields an aligned SortKey without
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
        // through the same ordinal-placeholder-then-overwrite the resolver path
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
          // `.ambiguous` on a name two outputs share). A qualified key faults
          // there: the set-operation output carries no range, so `R.a` /
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
      // Bind each materialised key to its hidden slot by POSITION, overwriting
      // the ordinal placeholder's resolved key: `.slot(slot)` orders on the
      // hidden `*gsN` column directly, `column` cleared so it is an ordinary
      // input key (NOT a select-list output — DISTINCT then rejects it, and it
      // is trimmed by the identity projection). This never spells the hidden
      // `*gsN` name, so a user output aliased identically cannot capture it.
      for (offset, slot) in materialised {
        keys[offset] = SortKey(term: .slot(slot),
                               ascending: keys[offset].ascending, column: nil)
      }
      // The carrier's ORDER BY is a new expression surface: `scope.order`
      // resolves each key (binds a column, arity), but — like the grouped
      // path's structural resolve — does NOT type-check a key's operands or its
      // calls, so an unknown routine (`ORDER BY missing(a)`) or an ill-typed
      // operand (`ORDER BY a + 'x'`) a run raises on slipped past validate.
      // Under `validate`, type-check each key expression against the same
      // setop-output scope it resolved over — its calls and operands as a
      // projected expression's — so validate faults identically to a run. An
      // ordinal/output-name key carries no `.expression` to re-check. The run
      // path compiles leniently (`validate: false`), so this never double-
      // faults there — the run surfaces the fault at execution as it did
      // before.
      // A carrier sort key may nest a predicate or scalar subquery (`ORDER BY
      // CASE WHEN EXISTS (…) …`). Both the validate and the comparability pass
      // reach a scalar one through the `.subquery` case, which records it only
      // when it is a `deferred` (scalar-position) query, so seed `deferred`
      // with the sort keys' scalar subqueries; an `EXISTS`/`IN`/quantified
      // reach records unconditionally. Each nested subquery's width and single-
      // column type derive against the same setop-output `scope` the run
      // resolves it through, nested under the outer (`nested`): a carrier ORDER
      // BY subquery may reference a set-operation output column — an aliased
      // output living solely in this scope, unseen by `context.outer` — so it
      // resolves at validate exactly as it does at run.
      let nested = (context.outer ?? Outer()).nested(under: scope)
      var scalars = Set<Query>()
      for key in order.keys {
        if case let .expression(expression) = key.sort {
          expression.collect(scalar: &scalars)
        }
      }
      if context.validate {
        // Record each nested subquery's width and type — the same cursor-free
        // pre-pass `subqueryCheck(of:)` runs for a plain SELECT's ORDER BY
        // subqueries — so the `scope.validate` type-check validates a subquery
        // sort key rather than faulting `.unsupported`, keeping the schema
        // path in step with the run (which resolves the same key through the
        // `resolution` above). A genuinely-unresolvable column (not a set-op
        // output, absent from the outer) still faults here as it does at run.
        var widths = Dictionary<Query, Int>()
        var types = Dictionary<Query, ValueType>()
        for query in subqueries {
          try self.width(query, [], context, nested, &widths, &types)
        }
        // Carry the enclosing `outer` so a key that directly names an outer
        // column — a correlated `ORDER BY T.Id` over a set operation whose
        // output lacks `Id` — resolves against it here exactly as the run's
        // `resolution` above does, rather than faulting `.column`.
        let check = SubqueryCheck(widths, types, deferred: scalars,
                                  outer: context.outer)
        for key in rewritten.keys {
          guard case let .expression(expression) = key.sort else { continue }
          try scope.aggregates(in: expression, context.routines,
                               subquery: check)
          _ = try scope.validate(expression, context.routines, subquery: check)
        }
        // Type-check each reached subquery body in the carrier's nested
        // validate scope, exactly as the plain-select validate walk does — so
        // a carrier ORDER BY subquery whose uncorrelated body a run never
        // materialises over an empty carrier is still type-checked, and a
        // static incomparable comparison inside it (`EXISTS (… WHERE a.num =
        // a.txt)`) faults 42804 here as on the plain-select equivalent. An
        // unreached body (a short-circuited leg's subquery) was never recorded,
        // so it is not recursed. The set-operation operand-compatibility fold
        // the shape pre-pass deferred is re-folded strictly for a scalar/valued
        // reach.
        let inner = context.revealed().with(outer: nested)
        for reach in check.visited {
          try typecheck(shape(of: reach), inner)
          switch reach.role {
          case .scalar, .valued:
            _ = try columns(unifying: reach.query, inner)
          case .existential, .lateral:
            break
          }
        }
      } else if context.comparability {
        // The run's comparability walk over the carrier's `ORDER BY`: hand each
        // sort-key expression to the finder alone, so a cross-kind comparison
        // in a key (`ORDER BY NULLIF(num, txt)`) faults 42804 while an
        // arithmetic key (`ORDER BY txt + 1`) does not — the run never
        // re-validates the carrier's operands. The subquery widths derive
        // best-effort (a structural fault defers, matching the finder's own
        // discipline) so a subquery sort key resolves rather than faulting
        // `.unsupported`.
        var widths = Dictionary<Query, Int>()
        var types = Dictionary<Query, ValueType>()
        for query in subqueries {
          do {
            try self.width(query, [], context, nested, &widths, &types)
          } catch let error {
            guard case let .state(code, _) = error,
                code == "42804" else { continue }
            throw error
          }
        }
        // Carry the enclosing `outer` for the same reason the validate check
        // does: a correlated column inside a key comparison (`ORDER BY
        // NULLIF(T.Id, k)`) resolves against the outer here as it does at run.
        let check = SubqueryCheck(widths, types, deferred: scalars,
                                  outer: context.outer)
        for key in rewritten.keys {
          guard case let .expression(expression) = key.sort else { continue }
          try scope.comparisons(in: expression, context.routines,
                                subquery: check)
        }
        // Recurse the finder into each reached predicate or scalar subquery
        // body (`comparing()`) — the run counterpart of the validate recursion
        // above, matching `comparability(of select:)`. An uncorrelated body a
        // run never materialises over an empty carrier is still comparability-
        // checked, so a cross-kind comparison inside it faults 42804 on the run
        // as on validate. Recurse under the carrier's nested comparing scope —
        // the sort-key subqueries correlate against the setop-output `scope`
        // beneath the outer, the same `nested` the width pre-pass used —
        // rethrowing only 42804 and deferring any other fault, the finder's own
        // discipline.
        let inner = context.revealed().with(outer: nested).comparing()
        for reach in check.visited {
          do {
            try typecheck(shape(of: reach), inner)
          } catch let error {
            guard case let .state(code, _) = error, code == "42804" else {
              continue
            }
            throw error
          }
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
    // A `VALUES` leaf holds each row's cell expressions in the leaf itself,
    // below the carrier's limit. Stacking a `limit` over it evaluates every
    // row's cells before the slice runs — the `limit` interpreter materialises
    // its whole source, then pages — so a row the page drops still evaluates,
    // faulting `VALUES (1 / 0) FETCH FIRST 0 ROWS` and running a dropped row's
    // side effects. A `SELECT` is spared this by sitting its projection above
    // the limit (`Project(Limit(…))`, see `Plan.shaped`), so a dropped row
    // never runs its select list. Give the constructor the same sparing when it
    // carries neither an ORDER BY nor a DISTINCT — each of which must evaluate
    // every row to sort or dedup it — by applying the positional limit at
    // compile time: slice the leaf's rows, so a discarded row's cells never
    // lower into the plan and so never evaluate. The `Limit` count and offset
    // are constant integers (the AST models no dynamic or parameterised page
    // bound), so the slice is exact and total. An ORDER BY or a DISTINCT keeps
    // the eager `.values` leaf and evaluates every row, as sorting and
    // deduplicating require. The sliced set may be empty (`FETCH FIRST 0 ROWS`,
    // an `OFFSET` past the end); the empty-body guard already passed on the
    // original non-empty rows, so an empty result is a valid `.values([])`
    // leaf, not the malformed empty node that guard rejects. The validate
    // path's value-check pages the same rows through the same `paged`, so a
    // discarded row's cell faults neither the run nor `columns(of: validate:)`
    // — the two agree (see `typecheck(values:)`).
    //
    // The positional slice pages the rows but does not trim their columns, so a
    // carrier with a nonzero `generated` (a hand-built public `Query.Carrier`
    // combining `generated` with a limit over a wider `.values`) still needs
    // its trailing hidden columns dropped: the schema path trims them
    // (`columns(unifying:)`, `cols.prefix(real)`), so the run must too or it
    // returns `width` columns where `columns(of:)` advertises `real`. Trim the
    // sliced leaf with the same identity projection `0 ..< real` the eager path
    // below applies — the page already dropped the discarded rows, so the
    // projection only trims the surviving rows' columns and re-introduces no
    // eager evaluation. When `real == width` (the parser's every carrier, whose
    // `generated` is `0`) the projection is the identity, so return the sliced
    // leaf directly and keep the plan shape the common path had.
    if !distinct, order == nil, let limit,
       case let .values(rows, types) = plan {
      let sliced = Plan.values(rows: paged(rows, by: limit), types: types)
      guard real < width else { return sliced }
      return .project((0 ..< real).map(Term.slot), sliced)
    }
    // Stack the row operators over the union plan, trimming to the REAL output
    // columns with the identity projection `0 ..< real` (dropping any hidden
    // materialised sort column).
    return plan.shaped(distinct: distinct,
                       projection: (0 ..< real).map(Term.slot),
                       filter: nil, order: keys, limit: limit)
  }
}

/// The `VALUES` rows a positional `limit` keeps — the compile-time counterpart
/// of the interpreter's `limited` row slice (see `Interpreter`). Drops the
/// leading `offset` rows, then caps at `count` (no cap when `count` is nil, an
/// `OFFSET` without a `FETCH`). Both bounds are the constant integers the parser
/// and the range guard already vetted non-negative.
///
/// It is generic over the row element so the one slice serves both the run and
/// the validate paths and the two cannot drift: the compile lowers a leaf's
/// `Term` rows through it, so a discarded row's cells never evaluate, and the
/// `columns(of: validate:)` value-check pages the `Expression` rows through it,
/// so it validates only the rows the run evaluates (see `typecheck(values:)`).
internal func paged<Row>(_ rows: Array<Row>, by limit: Limit) -> Array<Row> {
  guard limit.offset < rows.count else { return [] }
  let tail = rows[limit.offset...]
  guard let count = limit.count else { return Array(tail) }
  return Array(tail.prefix(count))
}
