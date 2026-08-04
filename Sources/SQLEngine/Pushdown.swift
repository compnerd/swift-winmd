// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Selection pushdown

extension Plan {
  /// Pushes each `WHERE` conjunct that references a single relation's slots
  /// down to just above that relation's leaf, before the join/product chain
  /// folds it in — so a relation is filtered as it is read rather than after
  /// the whole product is formed.
  ///
  /// `compile` leaves the `WHERE` as one `select` atop the left-deep chain, so
  /// a join runs on unfiltered inputs. This pass descends the chain: a conjunct
  /// whose slots all fall in one relation's contiguous slot run rides down to
  /// that relation's leaf as a `select` over its `scan`/`derived`, where the
  /// seek and nest rewrites can then act on it; a conjunct spanning two
  /// relations (a residual, an `OR` across sides) stays at the level whose two
  /// children it straddles. A conjunct over a `derived` view's output columns
  /// is pushed INTO the view's sub-plan — its outer slot mapped back through
  /// the view's projection to the sub-plan slot the column reads — recursing
  /// below the view's own joins. A `union` pushes into every arm. The pass is a
  /// pure logical rewrite; `optimise` runs after it and still sees the
  /// `select`s the seek and nest rewrites match.
  internal func pushdown() throws(SQLError) -> Plan {
    switch self {
    // Pushdown runs before optimise, the only producer of `.empty`, so a plan
    // reaching here never carries one; the arm keeps the switch exhaustive. A
    // `values` leaf is FROM-less — no `WHERE` conjunct rides into it.
    case .single, .empty, .values, .scan, .join:
      self
    case let .derived(name, sub, ordinals, seek):
      try .derived(name: name, plan: sub.pushdown(), ordinals: ordinals,
                   seek: seek)
    case let .select(filter, source):
      try source.pushdown().distribute(filter.conjuncts)
    case let .project(terms, source):
      try .project(terms, source.pushdown())
    case let .sort(keys, source):
      try .sort(keys: keys, source.pushdown())
    case let .product(left, right):
      try .product(left.pushdown(), right.pushdown())
    case let .outer(left, right, on, kind):
      // Push down within each side (its own joins/filters rewrite), but the
      // outer node is a pushdown barrier: a `WHERE` conjunct above it never
      // rides into a side. Filtering a preserved side's rows before the outer
      // join is equivalent, but filtering the NULL-extended side's rows before
      // it would change which rows match, so — preferring correctness — the
      // whole `WHERE` stays above (`distribute`'s default keeps it a `select`
      // over this node).
      try .outer(left.pushdown(), right.pushdown(), on: on, kind: kind)
    case let .semijoin(left, right, on, anti):
      // Push down within each side (its own joins/filters rewrite), but the
      // semijoin node is a pushdown barrier: a `WHERE` conjunct above it never
      // rides into a side. The semijoin drops left rows by the existence test,
      // so filtering a side's rows before it could change which left rows
      // survive — preferring correctness, the whole `WHERE` stays above
      // (`distribute`'s default keeps it a `select` over this node). Pushdown
      // runs before decorrelate, so this arm handles only a semijoin a nested
      // pass produced; a top-level plan never carries one at this point.
      try .semijoin(left.pushdown(), right.pushdown(), on: on, anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // Push down within the left side (its own joins/filters rewrite), but the
      // apply is a pushdown barrier: its right side is not a static sub-plan
      // but a per-outer-row re-execution, so a `WHERE` conjunct above it never
      // rides into it (mirroring the `.outer` gate — `distribute`'s default
      // keeps the conjunct a `select` over this node). The recorded body plan
      // was already pushed down at its compile.
      try .apply(left.pushdown(), key: key, correlation: correlation,
                 ordinals: ordinals, on: on, kind: kind)
    case let .setop(kind, left, right, all, types, widened):
      try .setop(kind, left.pushdown(), right.pushdown(), all: all,
                 types: types, widened: widened)
    case let .distinct(source):
      // A `distinct` sits above the projection, so no `WHERE` conjunct reaches
      // it to push down; it recurses transparently. A filter must never cross a
      // dedup — filtering before or after it yields different rows — and none
      // can, since it sits above the projection like the cap.
      try .distinct(source.pushdown())
    case let .aggregate(keys, aggregates, source):
      // An aggregate reshapes rows into a fresh grouped slot space, so it is a
      // pushdown barrier: a `HAVING`/projection filter above it is in grouped
      // space and stays there (`distribute`'s default keeps it as a `select`
      // over the aggregate), while the WHERE below it — already placed under
      // the aggregate at compile — pushes down within the source as usual.
      try .aggregate(keys: keys, aggregates: aggregates, source.pushdown())
    case let .window(windowings, source):
      // A window node appends the window results to a fresh output slot space,
      // so it is a pushdown barrier: a projection filter above it is in that
      // widened space and stays there (`distribute`'s default keeps it a
      // `select` over the window), while the WHERE below it — already placed
      // under the window at compile — pushes down within the source as usual.
      try .window(windowings, source.pushdown())
    case let .limit(count, offset, source):
      // A `limit` is the outermost operator, so no `WHERE` conjunct ever
      // reaches it to push down; it recurses transparently, its source pushed
      // as usual. A filter must never cross it — capping before or after a
      // filter yields different rows — and none can, since the cap sits above
      // the projection.
      try .limit(count: count, offset: offset, source.pushdown())
    case let .topN(keys, offset, count, source):
      // `topN` is produced by `optimise`, which runs after pushdown, so a plan
      // reaching here never carries one; the arm recurses transparently to keep
      // the switch exhaustive, mirroring the `limit`/`sort` it fuses.
      try .topN(keys: keys, offset: offset, count: count, source.pushdown())
    }
  }

  /// Places each of `conjuncts` as deep in the already-pushed `self` as the
  /// slots it reads allow, wrapping the level whose children a conjunct
  /// straddles in a residual `select`.
  ///
  /// At a `product`, `left.slots` is the boundary: a conjunct entirely below it
  /// belongs to the left child and rides down; one entirely at or above it
  /// belongs to the right child, rebased into that child's own slot space; one
  /// straddling the boundary — or reading no slots, or able to throw when
  /// evaluated (a division or scalar call) — stays here. A `select` is a join's
  /// `ON` gate, whose two sides straddle every boundary, and is a barrier for
  /// an unsafe `WHERE` conjunct: `nest` folds only one `match` into the hash
  /// `Join`'s key, leaving every other `ON` conjunct (a match beyond that key,
  /// or a non-equi residual) as the gate's residual under the join, and the
  /// gate drops a pair its leftover conjuncts evaluate UNKNOWN or `false`
  /// before the `WHERE` runs. So fusing a throwing `WHERE` conjunct into the
  /// gate — the `AND` not short-circuiting, still evaluating it for a pair the
  /// gate already dropped — would raise an error the separate gate suppresses,
  /// whether the leftover is a non-equi residual (`A JOIN B ON A.k < B.k WHERE
  /// (1 / A.x) = 0`, `A.k` NULL) or a second equi key (`… ON A.k1 = B.k1 AND
  /// A.k2 = B.k2 WHERE (1 / A.x) = 0`, `A.k2` NULL). Every UNSAFE `WHERE`
  /// conjunct stays a separate `select` above the gate, preserving the
  /// `ON`-drops-before-`WHERE` ordering; a safe `WHERE` conjunct (which never
  /// raises) still descends below the gate — as the product loop's ordering
  /// allows — so a safe single-relation conjunct reaches its base scan. The
  /// match keys fold down so `nest` can join under the gate. At a `derived`
  /// leaf the conjuncts push into the view; at a base `scan` they land right
  /// above it. A conjunct that cannot descend is re-conjoined here.
  private func distribute(_ conjuncts: Array<Filter>)
      throws(SQLError) -> Plan {
    switch self {
    case let .product(left, right):
      guard let base = left.slots else {
        return residual(conjuncts)
      }
      var here = Array<Filter>()
      var down = Array<Filter>()
      var over = Array<Filter>()
      var barrier = false
      for (index, conjunct) in conjuncts.enumerated() {
        let slots = conjunct.slots
        // A conjunct stays here — at the product level, run per pair, in the
        // order the `AND` chain wrote — when a preceding conjunct was unsafe
        // (`barrier`), when it reads no slots (e.g. `(1 / 0) = 0`, where
        // `allSatisfy` is vacuously true), when evaluating it can throw (a
        // division or scalar call, e.g. `(1 / A.x) = 0`), or when it is
        // nullable (reads a slot, so a NULL there makes it UNKNOWN) and a later
        // conjunct is unsafe. Riding a throwing conjunct down would raise while
        // scanning a child even when the join's other side is empty; riding a
        // safe conjunct past an earlier unsafe one would filter its rows before
        // the unsafe one runs, suppressing a throw the left-to-right `AND` owes
        // (`(1 / A.x) = 0 AND A.x <> 0`, `A.x = 0`, on a matching pair).
        // Because the evaluator's `AND` does not short-circuit, riding a
        // nullable conjunct below a later unsafe one likewise suppresses a
        // throw: the un-pushed `AND` runs the later conjunct even for the
        // UNKNOWN row, but the pushed conjunct drops that row first (`A.x = 1
        // AND (1 / B.y) = 0`, `A.x` NULL and `B.y = 0`). Only a safe
        // single-relation conjunct with no unsafe predecessor — and, if
        // nullable, no unsafe successor — rides down.
        let hazard =
            conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
        if barrier || slots.isEmpty || !conjunct.safe || hazard {
          here.append(conjunct)
        } else if slots.allSatisfy({ $0 < base }) {
          down.append(conjunct)
        } else if slots.allSatisfy({ $0 >= base }) {
          over.append(conjunct)
        } else {
          here.append(conjunct)
        }
        // An unsafe conjunct bars every later conjunct from riding past it.
        if !conjunct.safe { barrier = true }
      }
      let product =
          Plan.product(try left.distribute(down),
                       try right.distribute(over.map { $0.shifted(by: base) }))
      return product.residual(here)
    case let .select(gate, source):
      // A join's `ON` gate straddles both sides, so it never captures a
      // single-relation conjunct. Its equi `column = column` conjuncts are the
      // `match` keys `nest` folds into a hash `Join`; any other conjunct is a
      // residual (non-equi) `ON` predicate the join runs over its product.
      var matches = Array<Filter>()
      var residual = Array<Filter>()
      for conjunct in gate.conjuncts {
        if case .match = conjunct {
          matches.append(conjunct)
        } else {
          residual.append(conjunct)
        }
      }
      // The `ON` gate is ALWAYS a distribution barrier for an unsafe outer
      // `WHERE` conjunct, whether the gate is mixed (a non-equi residual) or
      // pure-equi (only matches). `nest` folds only one `match` into the hash
      // `Join`'s key and leaves every other `ON` conjunct — a match beyond that
      // key, plus any non-equi residual — as the gate's own residual `select`
      // under the join, which drops a pair it evaluates UNKNOWN or `false`
      // before the `WHERE` runs. Because the evaluator's `AND` does not
      // short-circuit, fusing a throwing `WHERE` conjunct into that gate
      // residual would evaluate it for a pair the gate has already dropped.
      // This bites a pure-equi `ON` too: `A JOIN B ON A.k1 = B.k1 AND A.k2 =
      // B.k2 WHERE (1 / A.x) = 0`, `A.k1` matching, `A.k2` NULL, `A.x` = 0 —
      // `nest` keys on `A.k1 = B.k1`, so the surviving pair reaches the
      // leftover `A.k2 = B.k2` (UNKNOWN), which should drop it; a fused `A.k2 =
      // B.k2 AND (1 / A.x) = 0` would instead divide by zero. So every unsafe
      // `WHERE` conjunct stays a separate `select` above the gate — never fused
      // with a leftover `ON` conjunct — keeping the `ON`-drops-before-`WHERE`
      // order.
      //
      // A safe `WHERE` conjunct, by contrast, never raises, so pushing it below
      // the gate can only drop rows, not suppress a throw; it still descends
      // (`matches + residual + safe`) so a safe single-relation conjunct
      // reaches its base scan as before. `distribute`'s product loop keeps it
      // after the `ON` residual, and its own barrier bars it from riding past
      // an unsafe `ON` conjunct — a safe `WHERE` pushed to a base scan below
      // the product does not co-locate with, nor reorder around, the gate's
      // leftover conjuncts. A safe conjunct stays above when the loop would
      // keep it at the product level anyway — mirroring that loop's ordering
      // rules so descending it never suppresses a throw the `WHERE`'s
      // non-short-circuiting `AND` owes: after ANY earlier unsafe conjunct
      // (a `barrier`), or when it is nullable and a later conjunct is unsafe
      // (a `hazard`). The match keys still fold down beside the residual so
      // `nest` can form the join under the gate; a single-equality pure-equi
      // `ON` folds its one key and carries no leftover conjunct, so a safe
      // `WHERE` descends and an unsafe one sits directly above the join.
      var safe = Array<Filter>()
      var above = Array<Filter>()
      var barrier = false
      for (index, conjunct) in conjuncts.enumerated() {
        let hazard =
            conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
        if conjunct.safe && !barrier && !hazard {
          safe.append(conjunct)
        } else {
          above.append(conjunct)
        }
        if !conjunct.safe { barrier = true }
      }
      let gated = try source.distribute(matches + residual + safe)
      return gated.residual(above)
    case .derived:
      return try into(conjuncts)
    default:
      return residual(conjuncts)
    }
  }

  /// Pushes `conjuncts` INTO this `derived` view's sub-plan, below its own
  /// projection and joins, mapping each conjunct's outer slot (a slot into the
  /// leaf's `ordinals`, i.e. a view output column) back to the sub-plan slot
  /// the column reads.
  ///
  /// A view's sub-plan is `Project(terms, body)` (or a `union` of such), so an
  /// output column `ordinals[slot]` is `terms[ordinals[slot]]`. A conjunct
  /// pushes in only when every slot it reads maps to a bare `.slot` term — a
  /// plain column of the body; a conjunct over a computed column (a call or
  /// arithmetic) cannot rebase and stays as a `select` on the derived leaf. A
  /// `union` sub-plan admits a conjunct only when every arm's projection admits
  /// it — the arms are combined, so a conjunct that cannot push into one arm
  /// must stay outside them all. The admitted conjuncts, still in the view's
  /// output slot space, push in through `inject`, which rebases each against
  /// the projection it lands under — per ARM for a union, since the arms map
  /// the same output column to different body slots; the rest wrap the leaf.
  ///
  /// The partition carries the same ordering barrier `distribute`'s product
  /// loop has: a conjunct stays `outer` — on the derived leaf, run in the `AND`
  /// chain's order — when a preceding conjunct was unsafe (`barrier`), when it
  /// is itself unsafe (a division or scalar call), when it is nullable and a
  /// later conjunct is unsafe, or when the view's projection cannot admit it;
  /// only a safe conjunct with no unsafe predecessor — and, if nullable, no
  /// unsafe successor — pushes in. An unsafe conjunct bars every later one from
  /// riding into the view: pushing a later conjunct past it would let the view
  /// seek and drop the row before the unsafe outer conjunct runs, suppressing a
  /// throw the left-to-right `AND` owes (`(1 / x) = 0 AND x = 1` over a view
  /// whose `x` is sorted, the `x = 1` seek dropping the `x = 0` row before the
  /// outer division raises). Symmetrically a nullable conjunct pushed below a
  /// later unsafe one suppresses a throw: the non-short-circuiting `AND` runs
  /// the later conjunct even for the UNKNOWN row, but the injected conjunct
  /// drops that row first (`x = 1 AND (1 / y) = 0`, `x` NULL and `y = 0`).
  private func into(_ conjuncts: Array<Filter>) throws(SQLError) -> Plan {
    guard case let .derived(name, plan, ordinals, seek) = self else {
      return residual(conjuncts)
    }
    var inner = Array<Filter>()
    var outer = Array<Filter>()
    var barrier = false
    for (index, conjunct) in conjuncts.enumerated() {
      // A nullable conjunct (reads a slot, so a NULL there makes it UNKNOWN)
      // must also stay outer when a later conjunct is unsafe: the evaluator's
      // `AND` does not short-circuit, so the un-pushed query runs the later
      // conjunct even for the UNKNOWN row, but injecting this one into the view
      // would seek or filter that row away first — suppressing a throw the
      // left-to-right `AND` owes (`x = 1 AND (1 / y) = 0` over a view exposing
      // `x`/`y`, `x` NULL and `y = 0`).
      let hazard =
          conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
      if barrier || !conjunct.safe || hazard
          || !plan.pushable(conjunct, ordinals) {
        outer.append(conjunct)
      } else {
        inner.append(conjunct)
      }
      // An unsafe conjunct bars every later conjunct from riding past it.
      if !conjunct.safe { barrier = true }
    }
    let sub = inner.isEmpty ? plan : try plan.inject(inner, ordinals)
    let leaf = Plan.derived(name: name, plan: sub, ordinals: ordinals,
                            seek: seek)
    return leaf.residual(outer)
  }

  /// Whether `conjunct` (in this view's output slot space, its slots indices
  /// into `ordinals`) can push below this sub-plan's projection.
  ///
  /// A `project` admits it when every slot it reads maps to a bare `.slot` term
  /// of the body — the `rebase` helper produces a mapping; a computed column
  /// (call or arithmetic) has none. A `union` admits it only when every arm
  /// does — the arms are combined, so a conjunct pushable into one but not
  /// another cannot descend into any and must stay outside — AND the conjunct
  /// references no column the set operation widens: an arm coerces its cells to
  /// the unified column type only after it runs (in `combine`), so a predicate
  /// pushed into the arm tests the pre-coercion value, and over a widened
  /// column that is the wrong type. Such a conjunct stays above the derived
  /// leaf as a `select` on the coerced output, where it tests the unified type
  /// — the observable result then matches an un-pushed query. A same-typed
  /// column (an empty `widened`) still pushes. Anything else does not admit it.
  private func pushable(_ conjunct: Filter, _ ordinals: Array<Int>) -> Bool {
    switch self {
    case let .project(terms, _):
      // A conjunct pushes below the projection only when every projected term
      // is safe: pushing it filters rows before the projection runs, so a
      // throwing term — a division or scalar call, even one the conjunct does
      // not read — would be skipped for the filtered rows, suppressing a raise
      // `derive` owes by evaluating every column of every view row.
      terms.allSatisfy(\.safe) && rebase(conjunct, ordinals) != nil
    case let .setop(_, left, right, _, _, widened):
      // A conjunct over a column the set operation widens must NOT push into
      // the arms: an arm evaluates it on the un-coerced value, but `combine`
      // coerces the arm's rows to the unified type only after the arm runs, so
      // the pushed predicate tests the wrong type. A slot the conjunct reads is
      // a view-output slot, `ordinals[slot]` its output column — the same index
      // `widened` records — so keep the conjunct outer when any is widened.
      !conjunct.slots.contains { widened.contains(ordinals[$0]) }
          && left.pushable(conjunct, ordinals)
          && right.pushable(conjunct, ordinals)
    default:
      false
    }
  }

  /// This view sub-plan with `conjuncts` (in the view's output slot space)
  /// pushed below its projection, each rebased into the body slots the
  /// projection it lands under reads.
  ///
  /// For a `union` each arm rebases the conjuncts against its own projection —
  /// the same output column sits at different body slots across arms, so a
  /// single pre-rebased filter cannot serve them all; the rebase must happen
  /// per arm. `pushable` has already vetted every conjunct against every arm,
  /// so the per-arm `rebase` is guaranteed non-nil.
  private func inject(_ conjuncts: Array<Filter>, _ ordinals: Array<Int>)
      throws(SQLError) -> Plan {
    switch self {
    case let .project(terms, body):
      try .project(terms,
                   body.distribute(conjuncts.map { rebase($0, ordinals)! }))
    case let .setop(kind, left, right, all, types, widened):
      try .setop(kind, left.inject(conjuncts, ordinals),
                 right.inject(conjuncts, ordinals), all: all, types: types,
                 widened: widened)
    default:
      // A view sub-plan is always a `project` (or a `union` of them); anything
      // else keeps the conjuncts as an outer `select` rather than dropping
      // them.
      residual(conjuncts)
    }
  }

  /// `conjunct` rebased from a `derived` leaf's output slot space into this
  /// projection sub-plan's body slot space, or `nil` if any slot it reads is a
  /// computed view column (not a bare `.slot` projection term) and so cannot be
  /// pushed in.
  ///
  /// Slot `s` of the leaf reads view column `ordinals[s]`, whose value is the
  /// projection term `terms[ordinals[s]]`; the conjunct pushes in only when
  /// that term is a bare `.slot(body)`, in which case `s` maps to `body`.
  /// Shared by `pushable` (the non-nil check) and `inject` (the rebased value).
  private func rebase(_ conjunct: Filter, _ ordinals: Array<Int>) -> Filter? {
    guard case let .project(terms, _) = self else { return nil }
    var map = Dictionary<Int, Int>(minimumCapacity: conjunct.slots.count)
    for slot in conjunct.slots {
      guard case let .slot(body) = terms[ordinals[slot]] else { return nil }
      map[slot] = body
    }
    return conjunct.remapped(through: map)
  }

  /// This plan wrapped in a `select` of `conjuncts`, or unchanged for an empty
  /// list — the residual placement of conjuncts that descend no further.
  private func residual(_ conjuncts: Array<Filter>) -> Plan {
    guard let filter = conjuncts.conjunction else { return self }
    return .select(filter, self)
  }
}
