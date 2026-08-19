// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Optimisation

extension Catalog where Self: ~Escapable {
  /// Rewrites the logical `plan` into a physical one, re-resolving relations by
  /// name through this catalog for their seekability and a bound key through
  /// `bindings` so it seeks like a literal.
  ///
  /// Two pattern rewrites fire, the rest of the tree recursing unchanged:
  ///
  /// (a) **Seek.** A `Select` over a full `Scan` whose predicate (or a
  ///     conjunct of it) is a sort-key equality or range on a seekable column
  ///     becomes a seeked `Scan`, the remaining predicate kept as a residual
  ///     `Select`.
  ///
  /// (b) **Index-nested-loop join.** A `Select` over a `Product` whose
  ///     predicate carries a `match` conjunct relating an outer-side ordinal to
  ///     an inner-side ordinal — the inner side a bare `Scan` — becomes a
  ///     `Join` that seeks the inner per outer record, the remaining conjuncts
  ///     kept as a residual `Select`. If the inner side is not a bare `Scan`,
  ///     the product stays (a plain nested loop).
  internal borrowing func optimise(_ plan: Plan, _ bindings: Bindings)
      throws(SQLError) -> Plan {
    try optimise(plan, Context(bindings: bindings))
  }

  /// Rewrites `plan` into a physical one under `context` — the in-scope overlay
  /// (consulted before the base catalog for seekability) and the bindings a
  /// bound key seeks like a literal.
  internal borrowing func optimise(_ plan: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    switch plan {
    case .single:
      plan
    case .values:
      // A values leaf is already physical — no seek, join, or source below it —
      // so it optimises to itself.
      plan
    case .empty:
      // The known-empty relation is already physical — no seek, join, or source
      // to rewrite below it — so it optimises to itself (and re-optimising a
      // folded plan is idempotent).
      plan
    case .scan:
      plan
    case let .derived(name, plan, ordinals, seek):
      // Optimise the view's sub-plan with the bindings so a bound predicate
      // inside the view seeks; the derived leaf itself carries no sort key, so
      // the outer query still scans its result as is. The sub-plan resolves
      // outside the statement's CTE scope — never a caller's `WITH` — so a view
      // means what it was registered to mean; its scope is the
      // `definition_schema.` overlay its own query names (the same one it
      // compiled under), so a view body's store scan re-resolves.
      //
      // A SET-operation view body's arm scans an arm-local derived alias the
      // whole-view overlay does not bind (arms are SELECT-scoped), so `seek`
      // would fault `.relation` resolving it. Optimise each arm under that
      // arm's own augmented overlay — the same per-arm scope `derive`/`setop`
      // execute it under — so the arm's `d` resolves for the seek rewrite.
      try .derived(name: name,
                   plan: optimise(view: name, plan, context),
                   ordinals: ordinals, seek: seek)
    case let .select(filter, source) where filter.constant == true:
      // A provably-always-true filter admits every row, so the select is a
      // no-op: drop it and optimise the source alone — identical result, one
      // fewer per-row predicate. This composes with the seek and nest cases
      // below: a constant-true filter over a `.scan` or `.product` never
      // reaches them, becoming just the optimised source (a plain scan or
      // product), not a seek over a true residual or a nest with a true gate.
      try optimise(source, context)
    case let .select(filter, source) where filter.constant == false:
      // A provably-always-false filter admits no row, so the whole selection is
      // the known-empty relation of the source's width — WHEN discarding the
      // source suppresses no observable throw. `emptied(filter:over:)`
      // optimises the source, then folds to `.empty` only when that source is
      // throw-free (`Plan.safe`) and its width is known, else leaves the select
      // filtering.
      try emptied(filter, over: source, context)
    case let .select(filter, .scan(name, ordinals, nil)):
      try seek(filter, name, ordinals, context)
    case let .select(filter, .product(left, right)):
      try nest(filter, left, right, context)
    case let .select(filter, source):
      try .select(filter, optimise(source, context))
    case let .project(ordinals, source):
      try .project(ordinals, optimise(source, context))
    case let .sort(keys, source):
      try elided(keys, over: source, context)
    case let .product(left, right):
      try .product(optimise(left, context), optimise(right, context))
    case .join:
      plan
    case let .outer(left, right, on, kind):
      // Optimise each side (a nested inner join or a seekable scan inside a
      // side still rewrites), but keep the outer node and its `on` intact — the
      // `on` governs matching and must not fold into a product or push onto a
      // leaf, or an unmatched preserved row would be dropped rather than
      // NULL-extended.
      try .outer(optimise(left, context), optimise(right, context), on: on,
                 kind: kind)
    case let .semijoin(left, right, on, anti):
      // Optimise each side (a nested join or seekable scan inside a side still
      // rewrites), but keep the semijoin node and its `on` intact — the `on`
      // governs the existence test and must not fold into a product or onto
      // a leaf, or a surviving/excluded left row would change. The executor's
      // hash fast-path keys on the straddling equi `.match` this `on` holds.
      try .semijoin(optimise(left, context), optimise(right, context), on: on,
                    anti: anti)
    case let .apply(left, key, correlation, ordinals, on, kind):
      // Optimise the left side (a seekable scan or a nested join inside it
      // still rewrites), but keep the apply node, its `on`, and its recorded
      // body plan intact — the body re-executes per outer row and was already
      // compiled and pushed down under its own scope, so the outer optimise
      // never reshapes it.
      try .apply(optimise(left, context), key: key, correlation: correlation,
                 ordinals: ordinals, on: on, kind: kind)
    case let .setop(kind, left, right, all, types, widened):
      // Optimise each side with the same bindings so a bound predicate inside
      // an arm seeks; the set operation itself merely combines its sides,
      // preserving this node's own `kind`, `all`, unified column `types`, and
      // `widened` mask.
      try .setop(kind, optimise(left, context), optimise(right, context),
                 all: all, types: types, widened: widened)
    case let .distinct(source):
      // A `distinct` dedups its source without a seek or join of its own;
      // optimise the source below it, then DROP the dedup when that optimised
      // source provably yields distinct full rows already (`Plan.unique`) —
      // DISTINCT-of-DISTINCT, DISTINCT over a set operation's deduped result,
      // or over a grouped aggregate — else rewrap and keep deduplicating.
      try deduplicated(source, context)
    case let .aggregate(keys, aggregates, source):
      // An aggregate reshapes its source and has no seek or join of its own;
      // optimise its source (the WHERE/join chain below it seeks and nests as
      // usual) and rewrap. The `HAVING`/projection sit above it as `select`s
      // the recursion reaches through here, but their grouped-space slots never
      // seek a base relation.
      try .aggregate(keys: keys, aggregates: aggregates,
                     optimise(source, context))
    case let .window(windowings, source):
      // A window node reshapes its source's rows (appending the window results)
      // and has no seek or join of its own; optimise its source (the WHERE/join
      // chain below it seeks and nests as usual) and rewrap. The projection sits
      // above it as a `project` the recursion reaches through here.
      try .window(windowings, optimise(source, context))
    case let .limit(count?, offset, .sort(keys, source)):
      // Fuse a bounded `limit` directly over a `sort` into a single bounded
      // selection: the executor keeps only the `offset + count` head rows in
      // sorted order (an `O(n log(offset + count))` partial sort) rather than
      // sorting the whole input and slicing. The guard requires `count != nil`
      // — an `OFFSET` with no `FETCH` is unbounded, nothing to bound, so it
      // falls through to the plain `limit` recurse below and keeps the full
      // sort. The keys are unchanged (a sort key is evaluated per row, never
      // seeked); only the source optimises.
      try .top(keys: keys, offset: offset, count: count,
                optimise(source, context))
    case let .limit(count, offset, source):
      // A `limit` is a transparent wrapper — optimise its source and re-cap;
      // the cap itself has no seek or join to rewrite. An unbounded `limit`
      // (`count == nil`) over a sort reaches here, keeping the full sort.
      try .limit(count: count, offset: offset, optimise(source, context))
    case let .top(keys, offset, count, source):
      // A `top` is already the fused physical shape; optimise its source and
      // rewrap so re-optimising a folded plan is idempotent (the cap and the
      // ordering have no seek or join of their own to rewrite).
      try .top(keys: keys, offset: offset, count: count,
                optimise(source, context))
    }
  }

  /// The fold of a provably constant-false `select(filter, source)` into the
  /// known-empty relation, or the select left intact when the fold would change
  /// more than the (already-zero) row count.
  ///
  /// A constant-false `filter` admits no row, so the selection's result is
  /// empty — but executing `select(false, source)` today still runs `source`,
  /// which may raise, before it filters every row out. Rewriting to `.empty`
  /// skips `source` entirely, so it is sound ONLY when `source` raises on no
  /// input (`Plan.safe`) — else the fold would suppress a throw, a correctness
  /// bug
  /// rather than an optimisation. The source is optimised first so its safety
  /// and width reflect the physical shape the executor would actually run (and
  /// so its own nested folds still apply on the fall-through). `.empty` carries
  /// the source's slot width so a downstream consumer mis-shapes nothing; a
  /// source of unknown width (`slots` nil) is left filtering. On either doubt
  /// the select stays — a constant-false filter neither seeks nor supplies a
  /// join key (`1 = 0` reads no slot), so no seek or nest rewrite is forgone.
  private borrowing func emptied(_ filter: Filter, over source: Plan,
                                 _ context: Context)
      throws(SQLError) -> Plan {
    let source = try optimise(source, context)
    guard source.safe, let slots = source.slots else {
      return .select(filter, source)
    }
    return .empty(slots: slots)
  }

  /// The fold of a `distinct(source)` into its optimised `source` alone when
  /// that source provably yields distinct full rows already, or the `distinct`
  /// left wrapping it otherwise.
  ///
  /// `SELECT DISTINCT` compiles to a `distinct` over the projected rows, but
  /// the dedup is redundant when the source yields no duplicate full row — a
  /// DISTINCT over another DISTINCT, over a set operation's already-deduped
  /// result, or over a grouped aggregate (one row per distinct group key). The
  /// source is optimised first so its `unique` reflects the physical shape the
  /// executor runs (and so its own nested folds still apply). Dropping the
  /// `distinct` is sound ONLY when `source.unique` is provably true — a
  /// conservative test resolving every doubt to `false` (keep the dedup), so a
  /// mis-fold never leaks a duplicate; a missed fold costs one extra dedup.
  private borrowing func deduplicated(_ source: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    let source = try optimise(source, context)
    return source.unique ? source : .distinct(source)
  }

  /// The fold of a `sort(keys, source)` into its optimised `source` alone when
  /// that source's guaranteed order already satisfies `keys`, or the `sort`
  /// left wrapping it otherwise.
  ///
  /// A stable sort of an input already in the requested order is the identity,
  /// so dropping the sort yields byte-identical rows. The source is optimised
  /// first so its promised order reflects the physical shape the executor runs
  /// — a seeked scan is still ordered on its key (a seek is a contiguous slice
  /// of the sorted scan), so `WHERE Id > 1 ORDER BY Id` drops the sort over the
  /// seek. Dropping is sound only when `satisfies` is provably true — a
  /// conservative test resolving every doubt (a `DESC` key, an expression key,
  /// a source with no promised order) to keeping the sort, so a mis-fold never
  /// reorders rows; a missed fold costs one full sort. A bare-slot sort key
  /// cannot throw, so dropping it suppresses no fault.
  private borrowing func elided(_ keys: Array<(term: Term, ascending: Bool)>,
                                over source: Plan, _ context: Context)
      throws(SQLError) -> Plan {
    let source = try optimise(source, context)
    return satisfies(keys, source, context) ? source : .sort(keys: keys, source)
  }

  /// Optimises a VIEW body's sub-`plan` for the view named `name`, resolving
  /// its scans under the view's own overlay rather than a caller's scope.
  ///
  /// A single-arm body optimises under the whole-view overlay
  /// (`overlay(name:)`) — the same scope it compiled under. A SET-operation
  /// body optimises each ARM under that arm's own augmented overlay: an arm
  /// scans its arm-local derived alias, which the whole-view overlay does not
  /// bind (arms are SELECT-scoped), so `seek` would fault `.relation` resolving
  /// it. The `plan` tree mirrors the `query` tree, so this descends the two in
  /// lockstep — a `.setop` node recurses into both arms, a leaf arm augments
  /// the arm's aliases schema-ONLY (`rows: false`, so `seek` treats them as
  /// unseekable materialised relations by name/schema without executing a
  /// derived body) and optimises the arm sub-plan under that arm-local scope —
  /// matching the per-arm scope `derive`/`setop` execute it under.
  private borrowing func optimise(view name: String, _ plan: Plan,
                                  _ context: Context)
      throws(SQLError) -> Plan {
    let overlay = try overlay(name, context)
    guard let view = resolve(view: name) else {
      return try optimise(plan, overlay)
    }
    // A bare set-operation body (`view.query` itself a `.setop`) optimises its
    // `.setop` plan per arm, exactly as before — but any other plan shape (a
    // pushed `.select` over the setop, a `.derived`, a leaf) stays on the plain
    // optimiser, whose pushdown/seek pass rebases a caller `WHERE` into each
    // arm. Preserved verbatim so a non-ordered union view's seek injection is
    // unchanged.
    if view.query.carriers.isEmpty, case .setop = view.query.body,
        case .setop = plan {
      return try optimise(plan, view.query, overlay)
    }
    // A set operation under an `ordered` carrier compiles to a `.shaped` stack
    // (project/sort/distinct/limit) over the `.setop` — NOT a bare setop — so
    // its per-arm derived aliases went un-optimised (both `case .setop` guards
    // failed). Descend the carrier wrapper to the setop leaf, optimising each
    // arm under its own overlay, exactly as the execute path's carrier-aware
    // `setop`/`execute(_:carrying:)` do. gated on the body actually wearing a
    // carrier (`view.query` an `.ordered`), so a bare union view keeps the
    // plain path above and this never rewrites its pushed `.select`/seek shape.
    if !view.query.carriers.isEmpty, case .setop = view.query.body {
      return try optimise(plan, view.query.core, overlay)
    }
    return try optimise(plan, overlay)
  }

  /// Optimises a view body's SET-operation `plan` arm by arm, each arm sub-plan
  /// under `overlay` augmented with that arm's own derived aliases, descending
  /// the `plan` and `query` trees in lockstep (they mirror each other). A body
  /// riding an `ordered` carrier descends the `.shaped` wrapper stack first,
  /// reconstructing each row operator over its optimised source, down to the
  /// `.setop` leaf.
  internal borrowing func optimise(_ plan: Plan, _ query: Query,
                                   _ overlay: Context)
      throws(SQLError) -> Plan {
    // See through an `ordered` carrier over a set operation nested as an arm,
    // as the execute-side `setop`/`arms` do: a suffix-bearing parenthesised
    // set operation reaches this recursion as an `.ordered(.setop(…))` arm
    // whose plan is a `.shaped` carrier stack. Peel to the carrier-transparent
    // `core` so the wrapper descent below fires and each inner arm optimises
    // under its own augment — otherwise a filtered `.scan("d")` arm would
    // seek-optimise against an unbound `d` and fault `.relation`. `core` leaves
    // a bare setop or a leaf select unchanged.
    let query = query.core
    if case let .setop(kind, left, right, all, types, widened) = plan,
        case let .setop(_, leftQuery, rightQuery, _) = query.body {
      return try .setop(kind, optimise(left, leftQuery, overlay),
                        optimise(right, rightQuery, overlay), all: all,
                        types: types, widened: widened)
    }
    // Descend the `ordered` carrier's single-source row operators, rebuilding
    // each over its optimised source while the setop `query` core rides through
    // unchanged until the `.setop` node above splits it. The carrier wrapper
    // sits above the setop, so `query` is still the `.setop` core here — gate
    // on that: once the setop has split into an arm (`query` a `.select`), the
    // plan is that ARM's own sub-plan, whose `.project`/`.select`/… must reach
    // the plain arm optimiser below (its seek/pushdown rewrite), NOT be walked
    // through as a carrier wrapper. So these cases fire ONLY above the setop.
    if case .setop = query.body {
      switch plan {
      case let .project(terms, source):
        return try .project(terms, optimise(source, query, overlay))
      case let .sort(keys, source):
        return try .sort(keys: keys, optimise(source, query, overlay))
      case let .distinct(source):
        return try .distinct(optimise(source, query, overlay))
      case let .limit(count, offset, source):
        return try .limit(count: count, offset: offset,
                          optimise(source, query, overlay))
      case let .select(filter, source):
        return try .select(filter, optimise(source, query, overlay))
      default:
        break
      }
    }
    // Schema-only (`rows: false`): the optimiser needs the arm's derived alias
    // bound by name/schema so `seek` treats it as an unseekable materialised
    // relation — NOT its rows. Materialising here would execute the arm's
    // derived body during optimisation (a stateful routine would run once here
    // and again at `derive`), so bind schema-only and let the single execution
    // happen at run.
    //
    // `validate: false` — this is the run path's optimiser, matching the
    // `overlay(name:)` above: `resolve`/`compile` already validated the view
    // body under the caller's `validate`, so an arm's data-dependent-empty
    // derived body must not be re-type-checked here and fault a run that its
    // filtered-out rows never reach.
    return try optimise(plan, augment(overlay.validating(false), for: query,
                                      rows: false))
  }

  // MARK: - Interesting orders

  /// Whether the sort `keys` are already guaranteed by `source`'s output order,
  /// so the sort is redundant. True only when every key is a bare `.slot` and
  /// the key list (as `(slot, ascending)`) is a prefix of `source`'s promised
  /// `ordering` — same slot, same direction, in order. A `DESC` key never
  /// matches the ascending promised order, an expression key is not a bare
  /// slot, and a key list longer than the promised prefix is not satisfied —
  /// each keeps the sort.
  borrowing func satisfies(_ keys: Array<(term: Term, ascending: Bool)>,
                           _ source: Plan, _ context: Context) -> Bool {
    var required = Array<(slot: Int, ascending: Bool)>()
    for key in keys {
      guard case let .slot(slot) = key.term else { return false }
      required.append((slot: slot, ascending: key.ascending))
    }
    let promised = ordering(of: source, context)
    guard required.count <= promised.count else { return false }
    for index in required.indices
        where required[index].slot != promised[index].slot
            || required[index].ascending != promised[index].ascending {
      return false
    }
    return true
  }

  /// The guaranteed output order of `plan` under `context` — the leading run of
  /// `(slot, ascending)` keys its rows are known to emerge in, or `[]` when no
  /// order is promised.
  ///
  /// Only order-preserving shapes report non-empty: a base scan (through its
  /// relation's declared `order`, seeked or not — a seek is a contiguous slice
  /// of the sorted scan), a selection (drops rows, never reorders), and a
  /// bare-slot projection (remapped through its terms). Every other node — an
  /// aggregate, join, product, set operation, window, a limit over an unordered
  /// source, or another sort — carries no promised order here (conservative:
  /// doubt reports `[]`, so a sort is merely kept).
  borrowing func ordering(of plan: Plan, _ context: Context)
      -> Array<(slot: Int, ascending: Bool)> {
    switch plan {
    case let .scan(name, ordinals, _):
      return promised(order: name, ordinals, context)
    case let .select(_, source):
      return ordering(of: source, context)
    case let .project(terms, source):
      // Remap the source order through this projection: a source slot survives
      // only while it maps to a bare `.slot` output term, and the guaranteed
      // prefix ends at the first source key the projection does not expose.
      var output = Dictionary<Int, Int>()
      for slot in terms.indices {
        if case let .slot(source) = terms[slot], output[source] == nil {
          output[source] = slot
        }
      }
      var result = Array<(slot: Int, ascending: Bool)>()
      for key in ordering(of: source, context) {
        guard let slot = output[key.slot] else { break }
        result.append((slot: slot, ascending: key.ascending))
      }
      return result
    default:
      return []
    }
  }

  /// The promised order of a base scan of `name` reading `ordinals` — its
  /// relation's declared `order` mapped into the scan's slot space, ascending.
  ///
  /// A materialised CTE (a name bound in `context.relations`) stores no order,
  /// so it promises none — and a CTE shadowing a same-named base table must not
  /// borrow the base's order, hence the CTE check precedes the table lookup. A
  /// seek is a contiguous slice of the sorted scan, so a seeked scan keeps the
  /// order. The prefix ends at the first declared-order column the scan does
  /// not reference: the rows are ordered by the whole physical column list, so
  /// an unprojected major column breaks the projected prefix.
  borrowing func promised(order name: String, _ ordinals: Array<Int>,
                          _ context: Context)
      -> Array<(slot: Int, ascending: Bool)> {
    guard context.relations[name.lowercased()] == nil,
        let table = table(named: name) else { return [] }
    var slot = Dictionary<Int, Int>()
    for index in ordinals.indices where slot[ordinals[index]] == nil {
      slot[ordinals[index]] = index
    }
    var result = Array<(slot: Int, ascending: Bool)>()
    for ordinal in table.order {
      guard let index = slot[ordinal] else { break }
      result.append((slot: index, ascending: true))
    }
    return result
  }

  // MARK: - Physical seek

  /// Rewrites `Select(filter, Scan(name, ordinals, nil))` into a seeked scan
  /// when a sort-key conjunct qualifies, else leaves the full scan under the
  /// filter. The relation re-resolves through this catalog for its boundaries.
  ///
  /// A standalone qualifying comparison seeks its run and admits all of it (no
  /// residual). An `AND` with one qualifying conjunct seeks that run and keeps
  /// the other as the residual `Select` — but ONLY when that residual is safe,
  /// since seeking narrows the scan and a throwing residual would then raise
  /// over just the sought run, suppressing a throw the un-seeked scan owes on a
  /// skipped row. Everything else scans under the whole filter. The `filter` is
  /// in slot space, so a comparison's slot maps back to its table ordinal
  /// through the scan's `ordinals` before reading a boundary.
  private borrowing func seek(_ filter: Filter, _ name: String,
                              _ ordinals: Array<Int>, _ context: Context)
      throws(SQLError) -> Plan {
    // A materialised CTE relation stores no sort key, so it is never seekable —
    // leave the scan under the whole filter.
    guard context.relations[name.lowercased()] == nil else {
      return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
    }
    guard let table = table(named: name) else { throw .relation(name) }
    let count = table.cursor().count

    let bindings = context.bindings
    if let range = table.boundaries(filter, ordinals, count, bindings) {
      return .scan(name: name, ordinals: ordinals, seek: range)
    }

    // Seek by one conjunct only when the other — the residual, then run over
    // just the sought run — is safe. Seeking narrows the scan, so a residual
    // that can throw would raise only on the rows the seek kept, suppressing a
    // throw the un-seeked scan owes on a skipped row: `(1 / x) = 0 AND id < 0`
    // over an id-sorted table (an empty id < 0 run) must still raise the
    // division rather than seek past it, as must a grouped `… AND (… AND id <
    // 0)` the left fold rebuilds so a seekable `id < 0` is the top-level RHS.
    if case let .and(lhs, rhs) = filter {
      if rhs.safe,
          let range = table.boundaries(lhs, ordinals, count, bindings) {
        return .select(rhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
      if lhs.safe,
          let range = table.boundaries(rhs, ordinals, count, bindings) {
        return .select(lhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
    }

    return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
  }
}

/// The seekable `(slot, op, integer)` of `filter`: a `compare` against an
/// integer literal, or a `bound` whose parameter resolves to an integer in
/// `bindings`. A string operand, an unbound or non-integer parameter, or a
/// non-comparison does not qualify, and the relation scans.
private func comparison(_ filter: Filter, _ bindings: Bindings)
    -> (Int, Comparison, Int)? {
  // A `slot op :parameter` (`bound`) is stamped `Filter.incomparable` at
  // lowering — its parameter side is opaque — so unwrap that stamp to read the
  // seekable shape. The seek stays comparability-safe on its own: a parameter
  // seeks only when it resolves to an integer against the sort key here, so a
  // cross-kind binding never seeks (it scans, and the residual — carrying the
  // stamp — faults `42804` at run), while the stamp still bars a sibling from
  // seeking past this conjunct through `Filter.safe`.
  var filter = filter
  if case let .incomparable(inner, _) = filter { filter = inner }
  switch filter {
  case let .compare(.slot(slot), op, .constant(.integer(value))):
    return (slot, op, value)
  case let .bound(.slot(slot), op, parameter):
    if case let .integer(value)? = bindings[parameter] {
      return (slot, op, value)
    } else {
      return nil
    }
  default:
    return nil
  }
}

/// The seekable `(slot, lower, upper)` of a non-negated `x BETWEEN lower AND
/// upper` whose test `x` is a `slot` and whose bounds each resolve to an
/// integer — a `.term` integer literal, or a `:parameter` bound to an integer
/// in `bindings`, the same resolution `comparison` applies to a `.bound` — a
/// two-sided run the seek reads directly off the sorted key, exactly the range
/// `x >= lower AND x <= upper` would seek, so a fully-bound parameterised range
/// seeks rather than regressing to a scan. A `NOT BETWEEN` (the complement is
/// two disjoint runs, not one contiguous seek), a non-slot test, or a bound
/// that does not resolve to an integer (a non-constant term, a string, or an
/// unbound or non-integer parameter) does not qualify, and the relation scans
/// under the residual `between`.
private func range(_ filter: Filter, _ bindings: Bindings) -> (Int, Int, Int)? {
  // A parameterised `x BETWEEN :lo AND :hi` is stamped `Filter.incomparable` at
  // lowering (an opaque `:parameter` bound); unwrap to read the seekable range.
  // The seek is binding-guarded — a bound seeks only when it resolves to an
  // integer against the sort key — so a cross-kind binding scans and the
  // stamped residual faults `42804`, as `comparison` does for a `bound`.
  var filter = filter
  if case let .incomparable(inner, _) = filter { filter = inner }
  guard case let .between(.slot(slot), lower, upper, negated: false) = filter,
      let low = integer(lower, bindings),
      let high = integer(upper, bindings) else {
    return nil
  }
  return (slot, low, high)
}

/// The integer a BETWEEN bound seeks on: a `.term` integer literal, or a
/// `:parameter` bound to an integer in `bindings` — the same resolution
/// `comparison` gives a `.bound`'s parameter. Any other operand — a
/// non-constant term, a non-integer constant, or an unbound or non-integer
/// parameter — does not seek (`nil`), and the residual `between` runs instead.
private func integer(_ operand: Filter.Operand, _ bindings: Bindings) -> Int? {
  switch operand {
  case let .term(.constant(.integer(value))):
    value
  case let .parameter(name):
    if case let .integer(value)? = bindings[name] { value } else { nil }
  case .term:
    nil
  }
}

extension Table where Self: ~Escapable {
  /// The boundaries `[lower, upper)` to seek for a sort-key comparison, or
  /// `nil` if `filter` does not qualify for the seek path.
  ///
  /// It qualifies when `filter` is a sort-key equality or range whose operand
  /// is an integer — a literal, or a bound parameter resolved from `bindings`
  /// so a correlated child seeks on its parent key — and `bound` reports the
  /// column seekable (a non-`nil` boundary). A range additionally requires the
  /// column `ordered`: a `bound` boundary partitions a range correctly only
  /// when the seeked column is monotonic, so a range on a seekable, unordered
  /// column (a decoded coded-index key) does not qualify and scans, while its
  /// equality still seeks. The comparison's slot maps back to its table ordinal
  /// through `ordinals` (slot `i` is `ordinals[i]`) for the `bound` query. A
  /// `string` operand or an unseekable column never qualifies, and the executor
  /// scans.
  ///
  /// A first-class `x BETWEEN lower AND upper` (non-negated) whose test `x` is
  /// the sort-key slot and whose bounds each resolve to an integer — a literal,
  /// or a `:parameter` bound in `bindings` (so `x BETWEEN :lo AND :hi` seeks
  /// rather than scans) — seeks a two-sided run: the intersection of the
  /// `x >= lower` and `x <= upper` partitions, exactly the run the desugar
  /// would seek, as an ordered-only range. A `NOT BETWEEN` (a two-run
  /// complement, not one contiguous seek), a non-slot test, or a bound that
  /// does not resolve to an integer does not qualify; the residual `between`
  /// still runs over the sought rows either way.
  ///
  /// The hash-join executor reuses this over a pushed inner filter's conjuncts
  /// to seek the inner by a seekable conjunct before bucketing, so a
  /// seekable/contradictory inner filter reads few or no inner rows.
  internal borrowing func boundaries(_ filter: Filter, _ ordinals: Array<Int>,
                                     _ count: Int, _ bindings: Bindings)
      -> Range<Int>? {
    // A first-class `x BETWEEN lower AND upper` seeks a two-sided run directly:
    // the lower boundary is the `x >= lower` partition (inclusive, `strict`
    // false) and the upper is the `x <= upper` partition (inclusive, `strict`
    // true), so their intersection `lower ..< upper` is exactly the range the
    // desugar `x >= lower AND x <= upper` would seek. As a range it seeks ONLY
    // an ordered key — an unordered seekable column brackets an equality, not
    // a range — and the residual `between` still runs over the sought rows.
    if let (slot, low, high) = range(filter, bindings) {
      guard ordered(ordinals[slot]),
          let lower = bound(ordinals[slot], low, strict: false),
          let upper = bound(ordinals[slot], high, strict: true) else {
        return nil
      }
      // An inverted `BETWEEN lower AND upper` (lower > upper) is a valid empty
      // range: the `x >= lower` partition starts after the `x <= upper` one
      // ends, so `lower > upper` here and `lower ..< upper` would trap Swift's
      // `Range(lowerBound <= upperBound)` precondition. Seek an empty run.
      guard lower <= upper else { return lower ..< lower }
      return lower ..< upper
    }

    guard let (slot, op, value) = comparison(filter, bindings),
        let lower = bound(ordinals[slot], value, strict: false),
        let upper = bound(ordinals[slot], value, strict: true) else {
      return nil
    }

    // A range takes the rows on one side of the boundary, which is correct only
    // when the column is ordered — every row on that side compares that way. An
    // equality takes only the boundary's own run, which `bound` brackets
    // exactly even for an unordered seek (a decoded coded-index key: the sorted
    // raw run brackets one tag's value, and the join re-tests the decoded key
    // per row), so equality always seeks; a range on an unordered column
    // returns `nil` and the engine scans and filters.
    let ordered = ordered(ordinals[slot])
    return switch op {
    case .equal: lower ..< upper
    case .lt: ordered ? 0 ..< lower : nil
    case .leq: ordered ? 0 ..< upper : nil
    case .gt: ordered ? upper ..< count : nil
    case .geq: ordered ? lower ..< count : nil
    case .unequal: nil   // a split run is two scans; let the scan handle it
    }
  }
}

// MARK: - Physical join

extension Catalog where Self: ~Escapable {
  /// Rewrites `Select(filter, Product(left, Scan(inner, _, nil)))` into an
  /// index-nested-loop `Join` when a `match` conjunct relates the two sides,
  /// else leaves the product (a plain nested loop) under the filter.
  ///
  /// The inner side is a bare `Scan(inner, _, nil)`, or that scan under a
  /// pushed single-relation filter — `Select(inner-filter, Scan(inner, _,
  /// nil))`, the shape selection pushdown leaves when a `WHERE` conjunct
  /// references only the joined-in relation. Either way the join folds in the
  /// scan; the pushed filter is preserved so the joined-in relation's non-key
  /// predicate still rides the `Join` path rather than degrading to a residual
  /// product.
  ///
  /// The left side's slot count is the boundary `base` in the combined slot
  /// space: a slot below it is an outer-side key, a slot at or above it an
  /// inner-side key (still in combined space). The inner key's slot maps to its
  /// table ordinal (`column`) through the inner scan's `ordinals` for the
  /// seek's `bound`. The matching conjunct is consumed; any remaining conjuncts
  /// stay as a residual `Select`. The pushed inner filter rides on the `Join`
  /// node itself — in the inner's own 0-based standalone slot space, the space
  /// it already lives in on the inner scan — so the executor applies it while
  /// materialising inner rows (before bucketing / as part of the inner scan),
  /// rather than lifting it into the residual to run after the join. Applying
  /// it during materialisation means a pair forms only when the filter holds,
  /// so it still gates a later unsafe residual conjunct (the pushdown barrier
  /// having kept the safe inner filter ahead of any unsafe conjunct). When the
  /// inner side is neither shape, the product is preserved.
  private borrowing func nest(_ filter: Filter, _ left: Plan, _ right: Plan,
                              _ context: Context)
      throws(SQLError) -> Plan {
    let inner: (name: String, ordinals: Array<Int>, filter: Filter?)?
    switch right {
    case let .scan(name, ordinals, nil):
      inner = (name, ordinals, nil)
    case let .select(pushed, .scan(name, ordinals, nil)):
      inner = (name, ordinals, pushed)
    default:
      inner = nil
    }

    guard let inner, let base = left.slots else {
      return try filter.gated(over: .product(optimise(left, context),
                                             optimise(right, context)))
    }

    let conjuncts = filter.conjuncts
    for index in conjuncts.indices {
      guard case let .match(lhs, rhs) = conjuncts[index],
          let key = keys(lhs, rhs, base) else {
        continue
      }

      var residual = conjuncts
      residual.remove(at: index)
      // The pushed inner filter stays in the inner's 0-based standalone slot
      // space and rides on the `Join` node, applied while the executor
      // materialises the inner (before bucketing / as part of the inner scan) —
      // NOT lifted into the residual to run after the join. It is always safe
      // and the pushdown barrier kept it ahead of any unsafe conjunct, so
      // applying it during materialisation still gates a later unsafe residual
      // (a pair forms only when the filter holds), without letting that
      // conjunct throw first (`Parent.Name = 'nope' AND (1 / Child.x) = 0`, the
      // false name excluding the row before the division runs).
      let join = try Plan.join(optimise(left, context),
                               name: inner.name, ordinals: inner.ordinals,
                               base: base,
                               column: inner.ordinals[key.inner - base],
                               keys: (left: key.outer, right: key.inner),
                               filter: inner.filter)
      guard let predicate = residual.conjunction else { return join }
      return .select(predicate, join)
    }

    return try filter.gated(over: .product(optimise(left, context),
                                           optimise(right, context)))
  }
}
