// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Outer-join demotion

extension Plan {
  /// Demotes an outer join whose enclosing `WHERE` is null-rejecting on the
  /// preserved-null side into an inner (or a narrower outer) join, so the
  /// ordinary inner-join machinery — pushdown, seek, and index-nested-loop
  /// `nest` — can then act on it.
  ///
  /// A `WHERE` above a LEFT join that is FALSE or UNKNOWN whenever the right
  /// side is NULL (`WHERE Parent.Name = 'Ada'`, `NULL = 'Ada'` UNKNOWN) drops
  /// every NULL-extended (unmatched) row, so the join is observably an inner
  /// join — but `.outer` is a hard barrier to pushdown/seek/nest, so those
  /// optimisations never fire. This pass runs BEFORE `pushdown()`, while the
  /// `WHERE` still sits as one `.select` atop the join (`.outer` being a
  /// barrier keeps it there), and rewrites the qualifying shape into the inner
  /// shape `select(filter, select(on, product(l, r)))` that pushdown then
  /// distributes and `nest` folds.
  ///
  /// It is behaviour-preserving on two independent axes. Cardinality: the
  /// matched rows of a LEFT-then-reject and an inner join are identical, and
  /// the unmatched rows the LEFT would emit are exactly the ones the rejecting
  /// `WHERE` drops — so no row's survival changes. Throw-visibility: demotion
  /// drops the NULL-extended rows without evaluating the `WHERE` on them, so it
  /// could suppress a fault the un-demoted `WHERE` owes there — the pass
  /// therefore demotes only when the whole `filter` is `safe` (cannot throw on
  /// any input), a coarse but airtight gate the common rejecting predicates
  /// (`= 'Ada'`, `> 5`, `IS NOT NULL`, `IN (…)`) all pass. It reads only the
  /// enclosing `WHERE`, never the join's `on` (which governs matching, not
  /// post-filtering), closing the classic demotion bug.
  ///
  /// The pass recurses structurally so a nested `select`-over-`outer` also
  /// demotes; every other node passes its children through unchanged.
  internal func demoted() -> Plan {
    switch self {
    case let .select(filter, .outer(left, right, on, kind)):
      let left = left.demoted()
      let right = right.demoted()
      let outer = Plan.outer(left, right, on: on, kind: kind)
      // Only a throw-free `WHERE` may demote: dropping the NULL-extended rows
      // must not suppress a fault the `WHERE` owes on them. A side of unknown
      // width leaves the boundary between the two slot spaces unknown, so bail.
      guard filter.safe, let boundary = left.slots, let width = right.slots
      else {
        return .select(filter, outer)
      }
      let leftSlots = Set(0 ..< boundary)
      let rightSlots = Set(boundary ..< boundary + width)
      let demoted = demotion(of: kind, under: filter, leftSlots, rightSlots)
      if demoted == kind { return .select(filter, outer) }
      if demoted == .inner {
        return .select(filter, .select(on, .product(left, right)))
      }
      return .select(filter, .outer(left, right, on: on, kind: demoted))
    case let .select(filter, source):
      return .select(filter, source.demoted())
    case let .project(terms, source):
      return .project(terms, source.demoted())
    case let .sort(keys, source):
      return .sort(keys: keys, source.demoted())
    case let .product(left, right):
      return .product(left.demoted(), right.demoted())
    case let .outer(left, right, on, kind):
      // A bare outer join (not under a `WHERE`) cannot demote — there is no
      // enclosing filter to reject its NULLs — so keep it and recurse.
      return .outer(left.demoted(), right.demoted(), on: on, kind: kind)
    case let .semijoin(left, right, on, anti):
      return .semijoin(left.demoted(), right.demoted(), on: on, anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // The apply's right side is a per-row re-execution, not a static
      // sub-plan; recurse only into the left, as pushdown does.
      return .apply(left.demoted(), key: key, correlation: correlation,
                    ordinals: ordinals, on: on, kind: kind)
    case let .setop(kind, left, right, all, types, widened):
      return .setop(kind, left.demoted(), right.demoted(), all: all,
                    types: types, widened: widened)
    case let .derived(name, plan, ordinals, seek):
      // A view body is compiled and demoted under its own compile, not here;
      // recurse structurally only.
      return .derived(name: name, plan: plan.demoted(), ordinals: ordinals,
                      seek: seek)
    case let .distinct(source):
      return .distinct(source.demoted())
    case let .aggregate(keys, aggregates, source):
      return .aggregate(keys: keys, aggregates: aggregates, source.demoted())
    case let .window(windowings, source):
      return .window(windowings, source.demoted())
    case let .limit(count, offset, source):
      return .limit(count: count, offset: offset, source.demoted())
    case let .topN(keys, offset, count, source):
      // `topN` is produced by `optimise`, after this pass, so it never reaches
      // here; recurse structurally to keep the switch exhaustive.
      return .topN(keys: keys, offset: offset, count: count, source.demoted())
    // A join is produced by `optimise` (after this pass), a values/single/empty
    // /scan leaf holds no outer join, and `empty` is likewise post-optimise —
    // none carries an outer to demote.
    case .single, .values, .empty, .scan, .join:
      return self
    }
  }
}

/// The join kind an outer join of `kind` demotes to, given its enclosing
/// `filter` and the combined-space slot sets of its two sides — the demotion
/// direction each preserved-null side is checked independently for.
///
/// A LEFT join demotes to inner when the filter rejects NULL on the right
/// (preserved-null) side; a RIGHT join when it rejects on the left. A FULL join
/// — both sides preserved — demotes to inner when both are rejected, to RIGHT
/// when only the right is (rejecting NULL on the right drops the unmatched-left
/// rows, whose right columns are NULL, leaving the matched and the unmatched-
/// right rows — a RIGHT join that preserves the right side), and to LEFT when
/// only the left is. An `.inner` kind never reaches an outer node. When no side
/// is rejected the kind is returned unchanged.
private func demotion(of kind: Join.Kind, under filter: Filter,
                      _ leftSlots: Set<Int>, _ rightSlots: Set<Int>)
    -> Join.Kind {
  switch kind {
  case .left:
    return filter.strict(on: rightSlots) ? .inner : .left
  case .right:
    return filter.strict(on: leftSlots) ? .inner : .right
  case .full:
    switch (filter.strict(on: leftSlots), filter.strict(on: rightSlots)) {
    case (true, true): return .inner
    case (true, false): return .left
    case (false, true): return .right
    case (false, false): return .full
    }
  case .inner:
    return .inner
  }
}
