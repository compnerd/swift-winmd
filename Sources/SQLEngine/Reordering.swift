// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Inner-join reordering

extension Catalog where Self: ~Escapable {
  /// Reorders a two-relation inner-join run so the smaller relation drives the
  /// index-nested loop, using the free exact base-table counts
  /// (`cursor().count`). A left-deep `product(L, R)` under a single `.select`
  /// makes `R` the probed inner and `L` the driver, so when the user wrote the
  /// larger relation first the join iterates the many-row side and re-seeks the
  /// few-row one — the order written is the order executed. Driving from the
  /// smaller side is never worse (a seek is `outer × log(inner)`, a hash is
  /// `outer + inner`; both favour the smaller outer), so a strict count
  /// asymmetry is a safe, beneficial signal.
  ///
  /// This runs after `decorrelate()` and before `optimise()`, so demotion has
  /// already exposed qualifying outer joins as product runs and pushdown has
  /// parked single-relation filters at the leaves. It matches only a
  /// `select(filter, product(L, R))` whose two children are bare base-table
  /// scans (a pushed single-relation filter is excluded — its selectivity the
  /// static count cannot see, see `arm(of:)`), whose `filter` is entirely
  /// `safe`, and which carries an equi `.match` straddling the two sides — the
  /// decorrelate posture: reorder only a run that is entirely `product`,
  /// entirely `safe`, and equi-connected, and bail to the original order on any
  /// doubt.
  ///
  /// Behaviour is preserved. Throw-visibility: the whole `filter` must be
  /// `safe` (never reorder across a throwing comparison), so no fault moves or
  /// vanishes. Cardinality: an inner join's result is an order-independent
  /// multiset, and the rewrite is a pure permutation of the two sides — no row
  /// is dropped or duplicated. The swapped product lays the sides `R ++ L`, so
  /// a restoring projection maps them back to the original `L ++ R` slot layout
  /// — the output columns (and the slots every parent reads) are identical;
  /// only the row order within the join changes, which an inner join without an
  /// enclosing `ORDER BY` does not fix (and an `ORDER BY` re-establishes).
  /// It never crosses an outer/apply/semijoin boundary — those are not
  /// `.product`, so a run never spans one.
  internal borrowing func reordered(_ plan: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    switch plan {
    case let .select(filter, .product(left, right)):
      let left = try reordered(left, context)
      let right = try reordered(right, context)
      return try reorder(filter, left, right, context)
          ?? .select(filter, .product(left, right))
    case let .select(filter, source):
      return try .select(filter, reordered(source, context))
    case let .project(terms, source):
      return try .project(terms, reordered(source, context))
    case let .sort(keys, source):
      return try .sort(keys: keys, reordered(source, context))
    case let .product(left, right):
      return try .product(reordered(left, context),
                          reordered(right, context))
    case let .outer(left, right, on, kind):
      return try .outer(reordered(left, context), reordered(right, context),
                        on: on, kind: kind)
    case let .semijoin(left, right, on, anti):
      return try .semijoin(reordered(left, context),
                           reordered(right, context), on: on, anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // The apply's right side is a per-row re-execution, not a static run;
      // recurse only into the left, as pushdown/demotion do.
      return try .apply(reordered(left, context), key: key,
                        correlation: correlation, ordinals: ordinals, on: on,
                        kind: kind)
    case let .setop(kind, left, right, all, types, widened):
      return try .setop(kind, reordered(left, context),
                        reordered(right, context), all: all, types: types,
                        widened: widened)
    case let .derived(name, plan, ordinals, seek):
      // A view body is reordered under its own compile, not here; recurse
      // structurally so a run inside the outer query still rewrites.
      return try .derived(name: name, plan: reordered(plan, context),
                          ordinals: ordinals, seek: seek)
    case let .distinct(source):
      return try .distinct(reordered(source, context))
    case let .aggregate(keys, aggregates, source):
      return try .aggregate(keys: keys, aggregates: aggregates,
                            reordered(source, context))
    case let .window(windowings, source):
      return try .window(windowings, reordered(source, context))
    case let .limit(count, offset, source):
      return try .limit(count: count, offset: offset,
                        reordered(source, context))
    case let .top(keys, offset, count, source):
      // `top` is produced by `optimise`, after this pass, so it never reaches
      // here; recurse structurally to keep the switch exhaustive.
      return try .top(keys: keys, offset: offset, count: count,
                       reordered(source, context))
    // A join is produced by `optimise` (after this pass); a leaf holds no run.
    case .single, .values, .empty, .scan, .join:
      return plan
    }
  }

  /// The reordered `select(filter, product(left, right))` — driving from the
  /// smaller relation — or `nil` when the run does not qualify (leaving the
  /// original order untouched).
  ///
  /// It qualifies only when both sides are base-table scans (or a scan under a
  /// pushed single-relation `select`) of known width, the `filter` is entirely
  /// `safe`, an equi `.match` straddles the two sides, and the left (current
  /// driver) has STRICTLY more rows than the right. A CTE, a derived view, a
  /// non-equi or absent connection, an unsafe predicate, an unknown width, or a
  /// non-strict count difference all bail to `nil`.
  private borrowing func reorder(_ filter: Filter, _ left: Plan, _ right: Plan,
                                 _ context: Context)
      throws(SQLError) -> Plan? {
    guard filter.safe,
        let leftName = arm(of: left), let rightName = arm(of: right),
        let lw = left.slots, let rw = right.slots,
        connected(filter, lw),
        // Both sides must be base tables with a known cursor count — a CTE (a
        // name in the overlay) has no seekable index and a missing name cannot
        // be measured, so either bails.
        context.relations[leftName.lowercased()] == nil,
        context.relations[rightName.lowercased()] == nil,
        let leftTable = table(named: leftName),
        let rightTable = table(named: rightName) else {
      return nil
    }
    let leftCount = leftTable.cursor().count
    let rightCount = rightTable.cursor().count
    // Drive from the smaller relation. Only a strict asymmetry reorders — a tie
    // keeps the written order, so the rewrite is a pure function of the counts
    // (deterministic) and never churns an already-balanced join.
    guard leftCount > rightCount else { return nil }

    // Swap `product(L, R)` to `product(R, L)`: an old left slot `s` moves to
    // `rw + s`, an old right slot `s` (at or past `lw`) moves to `s - lw`.
    var remap = Dictionary<Int, Int>(minimumCapacity: lw + rw)
    for slot in 0 ..< lw { remap[slot] = rw + slot }
    for slot in lw ..< (lw + rw) { remap[slot] = slot - lw }
    // A restoring projection maps the swapped `R ++ L` layout back to the
    // original `L ++ R`: output slot `j` reads the swapped slot the original
    // column `j` now sits at, so every parent reads byte-identical slots.
    let restore = (0 ..< (lw + rw)).map { Term.slot(remap[$0]!) }
    return .project(restore,
                    .select(filter.remapped(through: remap),
                            .product(right, left)))
  }
}

/// The relation name of an inner-join arm — a BARE `scan` alone — else `nil`.
///
/// A scan under a pushed single-relation `select` is deliberately excluded: the
/// pushed filter can prune the relation to a fraction of (or none of) its
/// base-table count, so a reorder driven by the static count could pessimise it
/// (drive from a relation a `WHERE` empties) and defeat the executor's
/// empty-outer / all-NULL-outer read-skip guards. Restricting to bare scans
/// keeps the count an honest measure of the arm — the reorder fires on the
/// headline `A JOIN B ON A.k = B.k` shape and bails on anything a filter
/// touches. Whether the name is a base table rather than a CTE is decided by
/// the caller, which holds the catalog and the overlay.
private func arm(of plan: Plan) -> String? {
  guard case let .scan(name, _, _) = plan else { return nil }
  return name
}

/// Whether `filter` carries an equi `.match` conjunct straddling the join
/// boundary `boundary` — one slot on the left side (`< boundary`), the other on
/// the right (`>= boundary`) — so the two relations are equi-connected and
/// reordering cannot introduce a cartesian product. A run with no straddling
/// `.match` is a cross or non-equi join and bails.
private func connected(_ filter: Filter, _ boundary: Int) -> Bool {
  for conjunct in filter.conjuncts {
    guard case let .match(lhs, rhs) = conjunct else { continue }
    if (lhs < boundary) != (rhs < boundary) { return true }
  }
  return false
}
