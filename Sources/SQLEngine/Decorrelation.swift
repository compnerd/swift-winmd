// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Catalog where Self: ~Escapable {
  // MARK: - Decorrelation

  /// Rewrites a decorrelatable correlated CROSS APPLY into a set-based inner
  /// join — a behaviour-preserving logical pass run after `pushdown` (so each
  /// `.apply` body is already in `project`/`select`/`scan` canonical form) and
  /// before `optimise`/`nest` (so the emitted `.select`-over-`.product` folds
  /// to a `.join` for free). It recurses the tree structurally, leaving every
  /// node but a decorrelatable `.apply` untouched, so a plan with none is
  /// returned unchanged.
  ///
  /// At each `.apply(left, key, correlation, ordinals, on, kind: .inner)` it
  /// consults the pre-compiled body plan (`context.subqueries.plan(key,
  /// correlation)`, the SAME lookup `executed` uses) and, when the body is a
  /// simple filter+project over a single base-relation scan with a purely equi
  /// correlation, rewrites the apply to `project(over left ++ taken,
  /// select(on'', product(left, scan(R))))` — the exact output geometry the
  /// correlated `applied` produces (each left row multiplied by its match
  /// count, an unmatched left row dropped), which the subsequent `nest` folds
  /// to a hash equi-join. On ANY doubt (a non-`.inner` kind, a
  /// non-decorrelatable body, a non-equi/expression correlation, an unsafe body
  /// term, or a taken-ordinals geometry it cannot map soundly) it leaves the
  /// `.apply` verbatim, so execution is unchanged — a missed decorrelation is a
  /// perf loss, a wrong one is silent data corruption.
  internal borrowing func decorrelate(_ plan: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    switch plan {
    // `.empty` is produced only by `optimise`, which runs after decorrelation,
    // so a plan reaching here never carries one; the arm is a structural
    // no-op keeping the switch exhaustive.
    case .single, .empty, .scan, .join:
      return plan
    case let .derived(name, plan, ordinals, seek):
      // A view body is compiled and re-executed under its own scope; its
      // correlated applies (if any) decorrelate when it is derived/optimised,
      // not here. Recurse structurally only.
      return try .derived(name: name, plan: decorrelate(plan, context),
                          ordinals: ordinals, seek: seek)
    case let .select(filter, source):
      // Decorrelate the source first (a nested apply/exists/IN inside it still
      // rewrites), then attempt to lift a top-level correlated `EXISTS`/`NOT
      // EXISTS` or correlated `IN (Q)` conjunct of this select's filter into a
      // semijoin. On any doubt the whole `.select` is left correlated
      // (`decorrelated(semijoins:)` returns `nil`), so execution is unchanged.
      let source = try decorrelate(source, context)
      return decorrelated(semijoins: filter, source, context)
          ?? .select(filter, source)
    case let .project(terms, source):
      // Decorrelate the source first (a nested apply/exists/IN inside it still
      // rewrites), then attempt to lift each top-level correlated scalar
      // `.subquery` term of this projection into its own LEFT join. On any
      // doubt the whole `.project` is left correlated (`decorrelated(scalars:)`
      // returns `nil`), so execution is unchanged.
      let source = try decorrelate(source, context)
      return decorrelated(scalars: terms, source, context)
          ?? .project(terms, source)
    case let .sort(keys, source):
      return try .sort(keys: keys, decorrelate(source, context))
    case let .product(left, right):
      return try .product(decorrelate(left, context),
                          decorrelate(right, context))
    case let .outer(left, right, on, kind):
      return try .outer(decorrelate(left, context), decorrelate(right, context),
                        on: on, kind: kind)
    case let .semijoin(left, right, on, anti):
      // A semijoin this pass itself produced (from a decorrelated `EXISTS`);
      // recurse structurally into both sides so a nested correlated apply
      // inside either still rewrites, preserving the node.
      return try .semijoin(decorrelate(left, context),
                           decorrelate(right, context), on: on, anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // Decorrelate the LEFT first (a nested apply inside it still rewrites),
      // then attempt this apply. `.inner` (CROSS APPLY) folds to an inner hash
      // join; `.left` (OUTER APPLY) folds to a LEFT `.outer` join. A `.right`/
      // `.full` apply does not exist (rejected at compile), so any other kind
      // is left verbatim.
      let left = try decorrelate(left, context)
      guard kind == .inner || kind == .left,
          let body = context.subqueries.plan(key, correlation),
          let rewritten = decorrelated(apply: left, body, key, correlation,
                                       ordinals, on, kind, context) else {
        return .apply(left, key: key, correlation: correlation,
                      ordinals: ordinals, on: on, kind: kind)
      }
      return rewritten
    case let .setop(kind, left, right, all, types, widened):
      return try .setop(kind, decorrelate(left, context),
                        decorrelate(right, context), all: all, types: types,
                        widened: widened)
    case let .distinct(source):
      return try .distinct(decorrelate(source, context))
    case let .aggregate(keys, aggregates, source):
      return try .aggregate(keys: keys, aggregates: aggregates,
                            decorrelate(source, context))
    case let .limit(count, offset, source):
      return try .limit(count: count, offset: offset,
                        decorrelate(source, context))
    }
  }

  /// The join rewrite of a CROSS APPLY (`.inner`) or OUTER APPLY (`.left`)
  /// whose `left` is already decorrelated, or `nil` when the apply's `body` is
  /// not decorrelatable — in which case the caller leaves the `.apply`
  /// unchanged (conservative default). An `.inner` apply becomes an inner hash
  /// join; a `.left` apply becomes a LEFT `.outer` join.
  ///
  /// The body must be `project(projection, select(where, scan(R, _, nil)))`
  /// with every projection term a bare slot (G3: a filter+project over a single
  /// base relation, no aggregate/limit/distinct/setop/nested apply — none of
  /// which wear this exact shape), the correlation must be all `.slot` sources
  /// (no `.bound` grandparent), and the `where` conjuncts must be exactly one
  /// equi correlation `correlate.inner = :param` (or the reversed order) plus
  /// safe, non-parameterised, single-relation local predicates `p_R` (G4: an
  /// unsafe or parameterised residual — a non-equi/expression correlation —
  /// bails).
  /// The scan's `seek` must be absent (a seeked body is not the canonical
  /// shape).
  ///
  /// **`.inner` (CROSS APPLY).** The rewrite lays the body scan's referenced
  /// ordinals after the left (a `.product`), then stacks two selects: an INNER
  /// select carrying the whole body WHERE (the correlation equality
  /// `.match(correlate.outer, base + correlate.inner)` AND the local residual
  /// `p_R`) and an OUTER select carrying the apply's `on` — the apply's `on`
  /// mapped from its `left ++ taken` space into this `left ++ scan` space. The
  /// `on` is kept
  /// separate (not folded into the body residual's conjunction) so it is
  /// evaluated ONLY on rows the body WHERE admitted: nested selects run
  /// bottom-up, restoring the correlated order (body WHERE → drop an UNKNOWN
  /// row → `on`), so an `on` that would throw on a row the body WHERE drops
  /// never fires — matching the correlated `applied` (which never reaches the
  /// `on` for a dropped row). It then projects the result back to the apply's
  /// `left ++ taken` geometry. The equi `.match` lets `nest`/`optimise` fold
  /// the product into a hash equi-join whose NULL-key drops and match-count
  /// multiplicity mirror the per-row re-execution.
  ///
  /// **`.left` (OUTER APPLY).** The rewrite is a LEFT `.outer` join
  /// `outer(left, scan(R), on: match(correlate.outer, base + correlate.inner)
  /// AND residual' AND on', kind: .left)`, projected back to the apply's
  /// `left ++ taken` geometry. The `.outer` node's `on` governs matching and
  /// NULL-extends an unmatched left row across the taken width — exactly OUTER
  /// APPLY. unlike the inner case the `on` cannot be split into a select above
  /// the join: the LEFT join's match/NULL-extension condition IS the whole
  /// `on`, so the correlation equality, the body residual, and the apply `on`
  /// must fold into one predicate evaluated together per (L, R) pair. This
  /// engine evaluates an `AND`'s RHS even for an UNKNOWN LHS, so folding an
  /// unsafe apply `on` beside a nullable body residual would raise a throw for
  /// a pair the correlated body WHERE dropped. therefore `.left` decorrelates
  /// ONLY when the mapped apply `on` is `safe` (non-throwing) or provably
  /// constant-true (the common `ON 1 = 1`): evaluating a `safe` `on` for an
  /// UNKNOWN-residual pair cannot throw, so the fold is result- AND throw-
  /// equivalent. An unsafe apply `on` leaves the `.apply` correlated. The equi
  /// `match` conjunct lets the `.outer` executor's hash fast-path probe by the
  /// key, mirroring the inner join's NULL-key drop and multiplicity.
  private borrowing func decorrelated(apply left: Plan, _ body: Plan,
                                      _ key: Subkey,
                                      _ correlation: Correlation,
                                      _ ordinals: Array<Int>, _ on: Filter,
                                      _ kind: Join.Kind,
                                      _ context: Context) -> Plan? {
    guard case let .project(projection, .select(filter, leaf)) = body,
        case let .scan(name, scanOrdinals, nil) = leaf,
        let base = left.slots else { return nil }
    // The scanned `name` must be a genuine base relation, not a body-local
    // derived alias. When the lateral body declares its own derived table(s) —
    // `SELECT x FROM (SELECT k, x FROM S) AS e WHERE …` — the compiled body
    // plan scans that alias (`e`), which the correlated `applied` executor
    // materialises per execution under the body's revealed overlay. The
    // caller-level checks below (a CTE/store overlay entry, a view) do not see
    // `e`, so it would pass as a base relation and the rewrite would relay a
    // caller-level `scan("e")` that faults `.relation("e")` or, worse, binds a
    // same-named OUTER base table and returns wrong rows. Bail whenever the
    // body query declares any derived tables of its own — the same
    // `collect(derived:)` the augment path uses over the body select — and
    // leave the apply correlated.
    var derivations = Array<(String, Query, Array<String>)>()
    key.query.collect(derived: &derivations)
    guard derivations.isEmpty else { return nil }
    // The scan must also name a genuine base relation, not a CTE/store overlay
    // entry or a view. A CTE `.scan` binds under the body's own revealed
    // overlay (a caller derived alias of the same name shadowed) that the
    // `applied` executor restores per run; relaid into a caller-level join it
    // would re-resolve the name against the OUTER overlay and bind the wrong
    // relation. A view `.scan` (a `.derived` after resolution) is likewise out
    // of the single-base-relation cut. Leave either correlated.
    guard context.relations[name.lowercased()] == nil,
        resolve(view: name) == nil else { return nil }
    // Every projection term must be a bare slot: a projected expression (a
    // LATERAL-only shape over a preceding column, or any computed column) has a
    // slot geometry the scan-relaid rewrite cannot reproduce, so bail.
    var projected = Array<Int>()
    for term in projection {
      guard case let .slot(slot) = term else { return nil }
      projected.append(slot)
    }
    // A taken ordinal at or beyond the projection's width is the body's virtual
    // `Id` — a LATERAL-only per-left-row row number the `applied` executor
    // derives from this left row's output through a `RelationInstance`, which a
    // set-based join (numbering over the whole relation) cannot reproduce.
    // Leave it correlated.
    guard ordinals.allSatisfy({ projection.indices.contains($0) }) else {
      return nil
    }
    // The correlation must be a single `.slot` source (no `.bound` grandparent
    // this v1 decorrelates). The outer key is that source's ordinal, already in
    // the left's combined slot space.
    guard correlation.count == 1,
        case let (name: parameter, source: .slot(outer))? =
            correlation.first.map({ (name: $0.key, source: $0.value) })
        else { return nil }

    // Split the body WHERE into the one equi correlation conjunct
    // (`correlate.inner = :parameter`) and the local residual `p_R`. Any other
    // parameterised conjunct is a non-equi/expression correlation — bail. Every
    // residual must be safe (G4: a throwing body term could fire for an inner
    // row no left row reaches under set-based execution).
    var inner: Int? = nil
    var residual = Array<Filter>()
    for conjunct in filter.conjuncts {
      if inner == nil, let slot = equated(conjunct, to: parameter) {
        inner = slot
        continue
      }
      guard conjunct.safe, !conjunct.parameterised else { return nil }
      residual.append(conjunct)
    }
    guard let inner else { return nil }
    // The correlation key pair: `outer` the source's ordinal (in the left's
    // combined slot space), `inner` the equi conjunct's body slot.
    let correlate = (outer: outer, inner: inner)

    // The correlation equality is hoisted to a straddling `.match` — the hash
    // key the physical join buckets each side by — so decorrelate only when its
    // two columns' declared types unify; a cross-kind pair would hash into
    // disjoint buckets and silently match nothing. Bail otherwise, leaving the
    // apply correlated so the equality routes through `matches` and faults.
    guard comparable(correlating: correlate.outer, in: left,
                     to: correlate.inner, scanning: name, scanOrdinals,
                     context) else { return nil }
    // The scan is relaid after the left, so the body's 0-based scan slots shift
    // by `base` into the combined space. The correlation equality becomes a
    // `.match` (folded to the join key), and the residual `p_R` shifts
    // alongside into this `left ++ scan` space.
    let scan = Plan.scan(name: name, ordinals: scanOrdinals, seek: nil)
    let matched = Filter(match: correlate.outer, base + correlate.inner)
    let shifted = residual.map { $0.shifted(by: -base) }
    // The apply's `on` addresses the `left ++ taken` space; map it into this
    // `left ++ scan` space (taken column `base + j` becomes the scan slot `base
    // + projected[ordinals[j]]` its projection read).
    let mapped =
        on.remapped(through: remap(taken: ordinals, over: base, projected))
    // Project back to the apply's exact `left ++ taken` geometry: the left's
    // slots unchanged, then each taken column at its combined scan slot.
    var terms = (0 ..< base).map { Term.slot($0) }
    terms.append(contentsOf: ordinals.map { Term.slot(base + projected[$0]) })

    switch kind {
    case .inner:
      // The inner gate carries the whole body WHERE (match key + residual) and
      // nothing else — the apply's `on` is kept in a separate select above the
      // body-filtered join rather than folded into the residual conjunction.
      // The correlated `applied` evaluates the body WHERE FIRST (dropping an
      // UNKNOWN row — a NULL-flag child) and only THEN the `on`, so an `on`
      // that would throw on a dropped row never fires. This engine evaluates an
      // `AND`'s RHS even for an UNKNOWN LHS, so folding `on` into the residual
      // conjunction would evaluate it for a dropped row and raise a fault the
      // original APPLY never hits. Nested selects evaluate bottom-up, so an
      // OUTER `on` sees only the rows the body WHERE admitted — restoring the
      // correlated order (body WHERE → drop → on). The `.match` lets
      // `nest`/`optimise` fold the product into a hash equi-join.
      let product = Plan.product(left, scan)
      let gate = ([matched] + shifted).conjunction
      let filtered = gate.map { Plan.select($0, product) } ?? product
      let gated = mapped.constant == true ? filtered : .select(mapped, filtered)
      return .project(terms, gated)
    case .left:
      // OUTER APPLY: a LEFT `.outer` join whose `on` governs matching and
      // NULL-extends an unmatched left row. unlike the inner case the `on`
      // cannot be split into a select above the join — the LEFT join's match/
      // NULL-extension condition IS the whole `on`, so correlation + residual +
      // apply `on` must be one predicate evaluated together per (L, R) pair.
      //
      // safe-`on` gate (throw-equivalence): this engine evaluates an `AND`'s
      // RHS even for an UNKNOWN LHS, so if the body residual can be UNKNOWN and
      // the apply `on` is unsafe, folding them raises a throw for a pair the
      // correlated body WHERE dropped at its own filter — a spurious throw the
      // OUTER APPLY never hits. Only decorrelate `.left` when the mapped `on`
      // is `safe` (non-throwing) or provably constant-true (`ON 1 = 1`): a
      // `safe` `on` for an UNKNOWN-residual pair cannot throw, so the fold is
      // result- AND throw-equivalent. An unsafe apply `on` bails — the caller
      // leaves the `.apply` correlated.
      guard mapped.safe || mapped.constant == true else { return nil }
      let condition =
          mapped.constant == true ? [matched] + shifted
                                  : [matched] + shifted + [mapped]
      // `condition` always holds the `match` conjunct, so it is never empty.
      let clause = condition.conjunction ?? matched
      let outer = Plan.outer(left, scan, on: clause, kind: .left)
      return .project(terms, outer)
    default:
      // `.right`/`.full` do not exist as apply kinds (rejected at compile); the
      // caller already gates on `.inner`/`.left`, so this is unreachable.
      return nil
    }
  }

  /// The semijoin rewrite of a `.select` whose `filter` carries one or more
  /// top-level correlated `EXISTS`/`NOT EXISTS` or correlated `IN (Q)`
  /// conjuncts over an already-decorrelated `source`, or `nil` when no conjunct
  /// is decorrelatable — in which case the caller leaves the `.select`
  /// correlated (conservative default). every decorrelatable `EXISTS` becomes
  /// its own semijoin (a `NOT EXISTS` an anti-join), and every decorrelatable
  /// correlated `IN (Q)` a semijoin whose `on` also carries the membership
  /// equality; the semijoins are stacked over the source, and the conjuncts NOT
  /// lifted are kept in a `.select` above the stack.
  ///
  /// An `EXISTS` is a two-valued existence test — TRUE iff the body yields a
  /// row, never UNKNOWN — so a semijoin is result-equivalent to the per-row
  /// re-execution the `exists` evaluator does, without the NOT-IN NULL trap (a
  /// NULL correlation key is simply "no match", dropping a semi left row and
  /// keeping an anti one). A positive correlated `IN (Q)` is likewise a
  /// per-row test — `operand IN (Q)` is TRUE iff some inner row's projected
  /// column equals `operand` — so a semijoin whose `on` conjoins the
  /// correlation key with the membership equality `operand = projected` is
  /// result-equivalent (a NULL `operand` or projected element yields no
  /// definite equality, so the row simply does not match — correct for positive
  /// IN, where the UNKNOWN-vs-FALSE distinction only bites NOT IN). `NOT IN`
  /// (`negated`) is deferred — it carries that NULL trap — and stays
  /// correlated. The body must be the same simple filter+project over a single
  /// base-relation scan the CROSS APPLY recogniser requires; for EXISTS the
  /// projection content is irrelevant (existence only), while for `IN (Q)` the
  /// projection must be exactly one bare-slot term (the IN column). The
  /// correlation must be a single `.slot` source and the body WHERE must split
  /// into exactly one equi correlation conjunct plus safe, non-parameterised
  /// residual conjuncts `p_R` (an unsafe or parameterised residual — a non-equi
  /// correlation — bails, G3/G4).
  ///
  /// **sibling throw-visibility (load-bearing).** A semijoin drops left rows
  /// (semi drops non-matching rows, anti drops matching rows), so a sibling
  /// conjunct of the enclosing `AND` that is unsafe could be skipped for a row
  /// the semijoin drops — suppressing a throw the correlated `.select` raises
  /// (it evaluates every conjunct of the `AND` for the row before the row is
  /// dropped). This is the throw-visibility class the OUTER APPLY safe gate
  /// guards. therefore lifting proceeds ONLY when every conjunct NOT lifted
  /// into a semijoin is `safe`; a decorrelatable exists/IN body is itself safe
  /// (a filter+project over one base scan with safe residuals, and an IN
  /// operand gated `safe` before lifting), so the lifted conjuncts add no
  /// throw, but a non-decorrelatable exists/IN left in the residual is unsafe
  /// and blocks all lifting. If any non-lifted conjunct is unsafe the whole
  /// `.select` stays correlated. Conservative is correct — a missed
  /// decorrelation is a perf loss, a wrong one is silent data corruption.
  ///
  /// The decorrelatable exists/IN conjuncts are ALL lifted, each into its own
  /// semijoin stacked over the source; the rest (a non-decorrelatable
  /// exists/IN, a `NOT IN`, or another predicate) are the siblings the
  /// throw-visibility guard tests, kept in the `.select` above the stack. Each
  /// semijoin's output width is the source's, so every stacked semijoin sees
  /// the same source slots — the correlation-key ordinals stay valid through
  /// the stack — and the residual select and everything above still address
  /// those slots.
  private borrowing func decorrelated(semijoins filter: Filter, _ source: Plan,
                                      _ context: Context) -> Plan? {
    // Lift every decorrelatable exists/IN conjunct into its own semijoin
    // stacked over `source`; a conjunct that is not one is kept in `remaining`
    // (both the siblings the throw-visibility guard tests and the residual
    // select above the stack).
    var node = source
    var remaining = Array<Filter>()
    var lifted = false
    for conjunct in filter.conjuncts {
      if case let .exists(key, correlation, negated) = conjunct,
          let body = context.subqueries.plan(key, correlation),
          let next = semijoin(node, body, key, correlation, negated,
                              membership: nil, context) {
        node = next
        lifted = true
        continue
      }
      // A positive correlated scalar `IN (Q)`: the operand rides the semijoin
      // `on` as the membership equality. `NOT IN` (`negated`) is deferred (its
      // NULL trap is not a plain anti-join) and an uncorrelated IN (an empty
      // correlation) stays as is — both fall through to `remaining`. The
      // operand must be `safe`: a per-outer-row `operand` throw fires even when
      // inner is empty, but a semijoin never evaluates `on` for a left row with
      // no right rows, so an unsafe operand would be suppressed — leave it
      // correlated. Only the one-arity (scalar) row decorrelates through the
      // single membership equality; a wider row `(a, b) IN (Q)` is left
      // correlated in this slice.
      if case let .within(operands, key, correlation, false) = conjunct,
          operands.count == 1, let operand = operands.first,
          !correlation.isEmpty, operand.safe,
          let body = context.subqueries.plan(key, correlation),
          let next = semijoin(node, body, key, correlation, false,
                              membership: operand, context) {
        node = next
        lifted = true
        continue
      }
      remaining.append(conjunct)
    }
    guard lifted else { return nil }
    // sibling throw-visibility: every conjunct NOT lifted into a semijoin must
    // be safe — a row a semijoin drops could otherwise suppress a throw the
    // correlated select raises for it. A non-decorrelatable exists/IN (or a
    // deferred `NOT IN`) is itself unsafe, so it (conservatively) blocks all
    // lifting here.
    guard remaining.allSatisfy(\.safe) else { return nil }
    // Keep the remaining conjuncts in a `.select` above the stack. Each
    // semijoin's width == the source's, so they and everything above still
    // address the same slots.
    return remaining.conjunction.map { .select($0, node) } ?? node
  }

  /// The `.semijoin` node for a correlated `EXISTS`/`NOT EXISTS` body — or a
  /// positive correlated `IN (Q)` body when `membership` is the IN operand —
  /// over `left`, or `nil` when the `body` is not decorrelatable — the same
  /// guards the CROSS APPLY recogniser applies. `negated` selects the anti
  /// sense (only ever `false` for the IN path, `NOT IN` being deferred).
  ///
  /// The body must be `project(projection, select(where, scan(R, _, nil)))`
  /// with no body-local derived table (the body-local hazard), `R` a genuine
  /// base relation (not a CTE/store overlay entry or a view), a single `.slot`
  /// correlation source, and a `where` splitting into exactly one equi
  /// correlation conjunct plus safe, non-parameterised residual conjuncts. The
  /// correlation equality becomes a straddling `.match` (the executor's hash
  /// key), the residual shifts into combined `left ++ scan` space alongside.
  ///
  /// For EXISTS (`membership == nil`) the projection content is irrelevant (a
  /// semijoin tests existence, taking no body column), so `on` is the
  /// correlation match AND the residual. For `IN (Q)` (`membership` the
  /// operand) the projection must be exactly one bare `.slot` term — the IN
  /// column — else the shape is not decorrelatable and this bails. The
  /// membership equality `operand = .slot(base + projected)` conjoins into `on`
  /// after the correlation match (so `equikey` still picks the correlation as
  /// the hash key and the membership rides the whole-`on` confirm): a left row
  /// survives iff some inner row equi-matches the key AND its projected column
  /// equals the operand AND the residual holds. The `operand` addresses the
  /// source's slots `0 ..< base`, unchanged in combined space, so used AS-IS.
  private borrowing func semijoin(_ left: Plan, _ body: Plan, _ key: Subkey,
                                  _ correlation: Correlation, _ negated: Bool,
                                  membership operand: Term?,
                                  _ context: Context) -> Plan? {
    guard case let .project(projection, .select(filter, leaf)) = body,
        case let .scan(name, scanOrdinals, nil) = leaf,
        let base = left.slots else { return nil }
    // No body-local derived table: its per-execution alias cannot be relaid as
    // a caller-level scan — the same hazard the CROSS APPLY recogniser guards.
    var derivations = Array<(String, Query, Array<String>)>()
    key.query.collect(derived: &derivations)
    guard derivations.isEmpty else { return nil }
    // The scan must name a genuine base relation, not a CTE/store overlay entry
    // or a view — a CTE/view `.scan` re-resolves against the wrong overlay when
    // relaid at the caller level. Leave either correlated.
    guard context.relations[name.lowercased()] == nil,
        resolve(view: name) == nil else { return nil }
    // For the IN path the projection must be exactly one bare `.slot` — the IN
    // column whose value the membership equality tests against the operand. A
    // multi-term or expression projection has no single membership slot, so it
    // is not decorrelatable; bail. The EXISTS path takes no body column, so its
    // projection content is irrelevant and this is skipped.
    var projected: Int? = nil
    if operand != nil {
      guard projection.count == 1,
          case let .slot(slot) = projection[0] else { return nil }
      projected = slot
    }
    // The correlation must be a single `.slot` source (no `.bound` parent):
    // the outer key is that source's ordinal, already in the left's slot space.
    guard correlation.count == 1,
        case let (name: parameter, source: .slot(outer))? =
            correlation.first.map({ (name: $0.key, source: $0.value) })
        else { return nil }

    // Split the body WHERE into the one equi correlation conjunct
    // (`correlate.inner = :parameter`) and the local residual `p_R`. Any other
    // parameterised conjunct is a non-equi/expression correlation — bail. Every
    // residual must be safe (a throwing body term could fire for an inner
    // left row reaches under set-based execution).
    var inner: Int? = nil
    var residual = Array<Filter>()
    for conjunct in filter.conjuncts {
      if inner == nil, let slot = equated(conjunct, to: parameter) {
        inner = slot
        continue
      }
      guard conjunct.safe, !conjunct.parameterised else { return nil }
      residual.append(conjunct)
    }
    guard let inner else { return nil }

    // The correlation equality becomes the semijoin's straddling `.match` hash
    // key, so decorrelate only when its two columns' declared types unify; a
    // cross-kind pair would hash into disjoint buckets and match nothing,
    // dropping every left row silently. Bail otherwise, leaving the correlated
    // `EXISTS`/`IN` select so its equality routes through `matches` and faults.
    guard comparable(correlating: outer, in: left, to: inner, scanning: name,
                     scanOrdinals, context) else { return nil }
    // The scan is relaid after the left, so the body's 0-based scan slots shift
    // by `base` into the combined space. The correlation equality becomes a
    // straddling `.match` (the executor's hash key), and the residual `p_R`
    // shifts alongside into this `left ++ scan` space.
    let scan = Plan.scan(name: name, ordinals: scanOrdinals, seek: nil)
    let matched = Filter(match: outer, base + inner)
    let shifted = residual.map { $0.shifted(by: -base) }
    // The IN membership equality `operand = projected` rides `on` after the
    // correlation match (so `equikey` still hashes on the correlation) and
    // before the residual. The `operand` reads the source's slots `0 ..< base`,
    // unchanged in combined space, so it is used AS-IS; the projected body slot
    // shifts by `base`. For EXISTS there is no membership, so `on` is the match
    // plus the residual exactly as before (a `nil` operand ⇒ byte-identical).
    var conjuncts = [matched]
    if let operand, let projected {
      conjuncts.append(Filter(compare: operand, .equal,
                              .slot(base + projected)))
    }
    conjuncts.append(contentsOf: shifted)
    let on = conjuncts.conjunction ?? matched
    return .semijoin(left, scan, on: on, anti: negated)
  }

  /// Lift every decorrelatable correlated scalar `.subquery` term of a
  /// projection into its own LEFT `.outer` join stacked under the projection,
  /// replacing the term with a coercion-preserving read of the joined column,
  /// or `nil` when no term is liftable — in which case the caller leaves the
  /// `.project` correlated (conservative default). A correlated scalar subquery
  /// `(SELECT v FROM R WHERE R.Id = T.fk [AND p_R])` today re-executes per
  /// outer row; over the unique virtual `Id` key each left row matches at most
  /// one `R` row (a residual `p_R` can only drop the single candidate), so it
  /// becomes a plain LEFT join reading `v` from the joined column.
  ///
  /// **uniqueness (load-bearing).** `join(scalar:)` decorrelates ONLY when the
  /// equi correlation's inner key is the relation's virtual `Id`, at ordinal
  /// exactly `== width` (a 1-based unique row index). A non-`Id` key (an owner
  /// foreign key or a coded-index key at an ordinal `> width`, or a real column
  /// `< width`) is NOT unique — many rows share it — so admitting it would
  /// silently collapse many matches to one. The at-most-one match makes the
  /// `>1` cardinality throw impossible, so the LEFT join reproduces it without
  /// a MIN aggregate (which would materialise-and-group all of `R` and could
  /// throw for a group no left row reaches).
  ///
  /// **no sibling throw hazard.** Unlike the semijoin/anti-join lifts (which
  /// DROP left rows), a LEFT join drops nothing — every left row is emitted
  /// exactly once — so a throwing sibling projection term is evaluated on
  /// exactly the same rows it was correlated; nothing is suppressed. The body
  /// residual is gated `safe` and the unique key makes the cardinality throw
  /// impossible, so the join reads `R` once introducing no new throw. Hence no
  /// safe-gate over the siblings is needed.
  ///
  /// Each `.outer` appends `R`'s ordinals after the running node, never
  /// shifting slots `0 ..< base`, so an unreplaced projection term keeps its
  /// original source slot verbatim and the j-th lifted scalar reads its joined
  /// `v` at `base_j + vSlot_j` (the running slot count before that join plus
  /// `v`'s combined-space slot). The final `.project` sits atop the whole stack
  /// and re-selects, discarding the extra right columns, so the output geometry
  /// stays `terms.count`.
  private borrowing func decorrelated(scalars terms: Array<Term>,
                                      _ source: Plan, _ context: Context)
      -> Plan? {
    guard var base = source.slots else { return nil }
    var node = source
    var projected = terms
    var lifted = false
    for (position, term) in terms.enumerated() {
      guard case let .subquery(key, correlation, type) = term,
          !correlation.isEmpty,       // uncorrelated: leave (already memoised)
          let body = context.subqueries.plan(key, correlation),
          let (outer, slot) = join(scalar: body, node, key, correlation, base,
                                   context)
        else { continue }
      node = outer
      // coercion-preserving: `.coalesce([.slot(slot)], type)` applies exactly
      // `Value.coerced(to: type)` to a non-NULL cell and passes NULL through —
      // byte-identical to `scalar()`'s `(value ?? .null).coerced(to: type)`. A
      // raw `.slot` would DROP the coercion (a `.double`-typed scalar over an
      // `.integer` cell); a `.cast` is wrong (it faults/truncates rather than
      // widens). Use `.coalesce`.
      projected[position] = .coalesce([.slot(slot)], type: type)
      base = node.slots ?? base       // width grew by R's ordinals
      lifted = true
    }
    guard lifted else { return nil }
    return .project(projected, node)
  }

  /// The LEFT `.outer` join and the combined-space slot of the joined value `v`
  /// for a correlated scalar `.subquery` body over `left`, or `nil` when the
  /// `body` is not decorrelatable — the same guards the semijoin recogniser
  /// applies plus the unique-`Id`-key guard.
  ///
  /// The body must be `project(projection, select(where, scan(R, _, nil)))`
  /// with the projection exactly one bare `.slot(v)` (the scalar's column), no
  /// body-local derived table, `R` a genuine base relation, a single `.slot`
  /// correlation source, and a `where` splitting into exactly one equi
  /// correlation conjunct plus safe, non-parameterised residual conjuncts
  /// `p_R`. The equi conjunct's inner scan slot must map (through the scan's
  /// referenced ordinals) to the relation ordinal `== width` AND that
  /// width-ordinal virtual (`virtuals.first`) must be the unique `Id`, and ONLY
  /// it — a non-`Id` first virtual, which the `Table.virtuals` contract
  /// permits, is not unique and must stay correlated. The correlation match
  /// becomes a straddling
  /// `.match` (the executor hash key), the residual shifts into combined `left
  /// ++ scan` space, and the two conjoin into the LEFT join's `on`.
  private borrowing func join(scalar body: Plan, _ left: Plan, _ key: Subkey,
                              _ correlation: Correlation, _ base: Int,
                              _ context: Context) -> (Plan, Int)? {
    guard case let .project(projection, .select(filter, leaf)) = body,
        case let .scan(name, scanOrdinals, nil) = leaf,
        left.slots == base else { return nil }
    // No body-local derived table: its per-execution alias cannot be relaid as
    // a caller-level scan — the same hazard the semijoin recogniser guards.
    var derivations = Array<(String, Query, Array<String>)>()
    key.query.collect(derived: &derivations)
    guard derivations.isEmpty else { return nil }
    // The scan must name a genuine base relation, not a CTE/store overlay entry
    // or a view — a CTE/view `.scan` re-resolves against the wrong overlay when
    // relaid at the caller level. Leave either correlated.
    guard context.relations[name.lowercased()] == nil,
        resolve(view: name) == nil else { return nil }
    // The projection must be exactly one bare `.slot(v)` — the scalar's column,
    // whose joined value replaces the term. A multi-term or expression
    // projection has no single value slot, so it is not decorrelatable.
    guard projection.count == 1,
        case let .slot(vSlot) = projection[0] else { return nil }
    // The correlation must be a single `.slot` source (no `.bound` parent):
    // the outer key is that source's ordinal, already in the left's slot space.
    guard correlation.count == 1,
        case let (name: parameter, source: .slot(outer))? =
            correlation.first.map({ (name: $0.key, source: $0.value) })
        else { return nil }

    // Split the body WHERE into the one equi correlation conjunct
    // (`correlate.inner = :parameter`) and the local residual `p_R`. Any other
    // parameterised conjunct is a non-equi/expression correlation — bail. Every
    // residual must be safe (a throwing body term could fire for an inner row
    // no left row reaches under set-based execution).
    var inner: Int? = nil
    var residual = Array<Filter>()
    for conjunct in filter.conjuncts {
      if inner == nil, let slot = equated(conjunct, to: parameter) {
        inner = slot
        continue
      }
      guard conjunct.safe, !conjunct.parameterised else { return nil }
      residual.append(conjunct)
    }
    guard let inner else { return nil }
    // uniqueness guard: the equi conjunct's inner scan slot must map to the
    // relation ordinal `== width` AND that width-ordinal virtual must be the
    // unique `Id` — a 1-based unique row index, and ONLY it. An ordinal `>
    // width` is another (non-unique) virtual; an ordinal `< width` is a real
    // column: neither is a unique key. The width-ordinal virtual is
    // `virtuals.first`, and the `Table.virtuals` contract permits a conformer
    // whose first virtual is NOT `Id` (a non-unique `Owner`, say) — such a key
    // matches many rows, so decorrelating over it would silently collapse them
    // and drop the correlated scalar's `.cardinality`; it must stay correlated.
    // `table(named:)` resolves the base relation (the caller-level checks above
    // already ensured `name` is not a CTE/view), and `scanOrdinals[inner]` maps
    // the equi conjunct's 0-based scan slot to its relation ordinal.
    guard let table = table(named: name),
        scanOrdinals[inner] == table.width,
        table.virtuals.first?.lowercased() == "id" else { return nil }

    // The correlation equality becomes the join's straddling `.match` hash key
    // (its inner side the unique `Id`, an integer row index), so decorrelate
    // only when the outer column's declared type unifies with the inner's; a
    // cross-kind pair would hash into disjoint buckets and match nothing. Bail
    // otherwise, leaving the correlated scalar so its equality routes through
    // `matches` and faults.
    guard comparable(correlating: outer, in: left, to: inner, scanning: name,
                     scanOrdinals, context) else { return nil }
    // The scan is relaid after the left, so the body's 0-based scan slots shift
    // by `base` into the combined space. The correlation equality becomes a
    // straddling `.match` (the executor's hash key), and the residual `p_R`
    // shifts alongside into this `left ++ scan` space.
    let scan = Plan.scan(name: name, ordinals: scanOrdinals, seek: nil)
    let matched = Filter(match: outer, base + inner)
    let shifted = residual.map { $0.shifted(by: -base) }
    let on = ([matched] + shifted).conjunction ?? matched
    // A unique-`Id` key matches at most one R row, so a plain LEFT join reads
    // `v` from the joined column: an unmatched left row NULL-extends (the empty
    // → NULL of the correlated scalar), a matched one reads its lone cell. `v`
    // lands at `base + vSlot` in the combined `left ++ scan` space.
    return (.outer(left, scan, on: on, kind: .left), base + vSlot)
  }

  /// Whether the correlation key `outer = inner` is a comparable pair — the
  /// straddling `.match` this pass hoists is the physical join key `nest`, the
  /// bucketed outer join, and the semijoin fast path all hash on, so a
  /// cross-kind pair (an integer outer against a text inner) hashes the two
  /// sides into disjoint buckets, compares no candidate row, and would silently
  /// return no matches — the same silent non-match `Scope.on` guards for a
  /// `column = column` join key. The inner-body lowering cannot fault it (the
  /// outer column is an untyped `:parameter` in the body scope), so gate the
  /// hoist here: decorrelate only when the outer slot's declared type unifies
  /// with the inner column's (`ValueType.unified`, the notion `Scope.on`, the
  /// run's `matches`, and `check`'s `comparable` all share). When it does not
  /// unify — or either type cannot be resolved from the plans — bail: the
  /// correlated `.apply`/`.select` is left in place, routing the equality
  /// through the nested-loop `matches`, which faults 42804 on the cross-kind
  /// pair. A missed decorrelation is a perf loss; a wrong one is data
  /// corruption, so an unresolved type bails.
  ///
  /// `outer` addresses `left`'s combined slot space; `inner` is the body scan's
  /// slot, reading the base relation `name`'s column `scanOrdinals[inner]`.
  private borrowing func comparable(correlating outer: Int, in left: Plan,
                                    to inner: Int, scanning name: String,
                                    _ scanOrdinals: Array<Int>,
                                    _ context: Context) -> Bool {
    guard let l = type(of: left, at: outer, context),
        let r = type(of: .scan(name: name, ordinals: scanOrdinals,
                                     seek: nil), at: inner, context),
        l.unified(with: r) != nil else { return false }
    return true
  }

  /// The declared type of the base-relation column the combined `slot` of
  /// `plan` reads, or `nil` when it traces to none — a computed column, a
  /// grouped/set-operation/apply slot, or a shape this resolver does not walk.
  /// It mirrors `Plan.slots`' combined-space arithmetic to descend to the leaf
  /// scan the slot belongs to, then reads that column's type exactly as
  /// `Scope.type(at:)` does: a real column's `types` entry (a CTE/store
  /// overlay binding's, else the base table's), and a virtual ordinal (`Id`,
  /// an owner foreign key) or an out-of-range one `.integer`, the index type.
  /// A `nil` result bails the decorrelation gate above (conservatively, never a
  /// wrong rewrite).
  private borrowing func type(of plan: Plan, at slot: Int,
                                    _ context: Context) -> ValueType? {
    switch plan {
    case let .scan(name, ordinals, _):
      guard slot >= 0, slot < ordinals.count else { return nil }
      return type(of: name, at: ordinals[slot], context)
    case let .select(_, source):
      return type(of: source, at: slot, context)
    case let .distinct(source):
      return type(of: source, at: slot, context)
    case let .limit(_, _, source):
      return type(of: source, at: slot, context)
    case let .sort(_, source):
      return type(of: source, at: slot, context)
    case let .semijoin(left, _, _, _):
      return type(of: left, at: slot, context)
    case let .project(terms, source):
      guard slot >= 0, slot < terms.count,
          case let .slot(inner) = terms[slot] else { return nil }
      return type(of: source, at: inner, context)
    case let .product(left, right):
      guard let boundary = left.slots else { return nil }
      return slot < boundary
          ? type(of: left, at: slot, context)
          : type(of: right, at: slot - boundary, context)
    case let .outer(left, right, _, _):
      guard let boundary = left.slots else { return nil }
      return slot < boundary
          ? type(of: left, at: slot, context)
          : type(of: right, at: slot - boundary, context)
    case let .join(outer, name, ordinals, base, _, _, _):
      if slot < base { return type(of: outer, at: slot, context) }
      let inner = slot - base
      guard inner >= 0, inner < ordinals.count else { return nil }
      return type(of: name, at: ordinals[inner], context)
    default:
      // A `.derived` view leaf, a `.apply`, an `.aggregate`, a `.setop`, or a
      // `.single`/`.empty` slot has no single base column this resolver reads —
      // bail (the gate leaves the apply correlated, a perf loss, never wrong).
      return nil
    }
  }

  /// The declared type of relation `name`'s column at `ordinal` — the CTE/store
  /// overlay binding's `types` entry when the name binds one, else the base
  /// table's — mirroring `Scope.type(at:)`: a real column carries its type, a
  /// virtual (`Id`, owner) or out-of-range ordinal is `.integer`. `nil` only
  /// when the name resolves to no base relation at all (the caller then bails).
  private borrowing func type(of name: String, at ordinal: Int,
                                    _ context: Context) -> ValueType? {
    if let instance = context.relations[name.lowercased()] {
      return ordinal < instance.types.count ? instance.types[ordinal]
                                            : .integer
    }
    guard let table = table(named: name) else { return nil }
    return ordinal < table.types.count ? table.types[ordinal] : .integer
  }
}

/// The inner-key slot of an equi correlation conjunct `slot = :parameter` (in
/// either operand order), or `nil` when `conjunct` is not that shape — a
/// comparison of a bare slot to the correlation `parameter` under `=`. A
/// non-`=` comparison (a non-equi correlation), a compound operand, or a
/// different parameter is not an equi correlation key and leaves the conjunct
/// to the residual test (which bails on it as a parameterised non-equi term).
///
/// The equi correlation compares a slot to the opaque-kind `:parameter`, so it
/// is stamped `Filter.incomparable` at lowering; unwrap that stamp to read the
/// underlying equi shape. The stamp keeps the correlation predicate an
/// always-evaluated residual on the un-decorrelated path (the run its authority
/// for the per-run kind); recognising the equi shape here lets the decorrelator
/// hoist it to the straddling `.match`, where its comparability is decided.
private func equated(_ conjunct: Filter, to parameter: String) -> Int? {
  var conjunct = conjunct
  if case let .incomparable(inner) = conjunct { conjunct = inner }
  guard case let .compare(lhs, .equal, rhs) = conjunct else { return nil }
  switch (lhs, rhs) {
  case let (.slot(slot), .parameter(name)) where name == parameter:
    return slot
  case let (.parameter(name), .slot(slot)) where name == parameter:
    return slot
  default:
    return nil
  }
}

/// The slot remap from a CROSS APPLY's `left ++ taken` output space into the
/// decorrelated `left ++ scan` space: a left slot (`< base`) is unchanged, and
/// the `j`-th taken column (slot `base + j`, reading body-output column
/// `ordinals[j]`) maps to the scan slot `base + projected[ordinals[j]]` its
/// projection read. `on` is remapped through this so it addresses the relaid
/// scan's slots rather than the apply's taken columns.
private func remap(taken ordinals: Array<Int>, over base: Int,
                   _ projected: Array<Int>) -> Dictionary<Int, Int> {
  var map = Dictionary<Int, Int>(minimumCapacity: base + ordinals.count)
  for slot in 0 ..< base { map[slot] = slot }
  for taken in ordinals.indices {
    map[base + taken] = base + projected[ordinals[taken]]
  }
  return map
}

/// The `(outer, inner)` key pair an equality between slots `lhs` and `rhs`
/// relates across the boundary `base`, or `nil` if both fall on one side.
///
/// Exactly one slot must be below `base` (the outer key) and the other at or
/// above it (the inner key, still in combined space); the order the equality
/// was written in does not matter.
internal func keys(_ lhs: Int, _ rhs: Int, _ base: Int)
    -> (outer: Int, inner: Int)? {
  switch (lhs < base, rhs < base) {
  case (true, false): (lhs, rhs)
  case (false, true): (rhs, lhs)
  default: nil
  }
}
