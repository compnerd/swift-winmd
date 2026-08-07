// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Interpreter

/// Interprets `plan` against `catalog`, producing its result records.
///
/// Each operator transforms the records its sub-plan yields: `scan` re-resolves
/// the relation by name, opens its cursor, and materialises its referenced
/// ordinals over the seek range into dense slots; `select` keeps the admitted
/// records; `project` rebuilds each from the projected slots; `sort` orders
/// them by its typed keys major to minor, stably and each in its own direction;
/// `product` pairs every outer record with every inner one; `join` re-resolves
/// the inner relation, seeks it per outer record, and concatenates the matches;
/// `setop` runs its two sides — each with its own set-operation semantics — and
/// combines their rows by its `kind` (`UNION`/`INTERSECT`/`EXCEPT`),
/// deduplicating unless `all`; `distinct` deduplicates its source's whole rows
/// (`SELECT DISTINCT`); `limit` skips the first `offset` of its source's rows
/// then takes at most `count`. The catalog is borrowed throughout — a
/// `~Escapable` source is never copied or stored.
extension Catalog where Self: ~Escapable {
  internal borrowing func execute(_ plan: Plan, _ context: Context)
      throws(SQLError) -> Array<Record> {
    switch plan {
    case .single:
      // The FROM-less single row: one record with no cells, the source a scalar
      // projection evaluates its constant/call expressions against.
      return [Record([])]
    case let .values(rows, types):
      // The ISO table value constructor: one record per row, each the row's
      // lowered terms evaluated against the single empty record (as `single`'s
      // row is) then coerced to the unified column `types` — so `VALUES (1),
      // (2.5)` yields a `double` column. An explicit loop keeps the borrowed
      // `~Escapable` self a row's scalar subquery materialises against out of a
      // closure capture.
      var records = Array<Record>()
      records.reserveCapacity(rows.count)
      for row in rows {
        var cells = Array<Value>()
        cells.reserveCapacity(row.count)
        for term in row {
          try cells.append(evaluate(Record([]), term, context))
        }
        records.append(Record(cells).coerced(to: types))
      }
      return records
    case .empty:
      // The known-empty relation yields no records — the optimiser proved its
      // constant-false guard admits none — so nothing above it (a project, an
      // aggregate, a join) ever sees a row, and its skipped subtree stays
      // unrun.
      return []
    case let .scan(name, ordinals, seek):
      return try materialise(name, ordinals, seek, context.relations)
    case let .derived(name, source, ordinals, seek):
      return try derive(name, source, ordinals, seek, context)
    case let .select(filter, .product(outer, inner)):
      // Fuse a residual product with its filter: stream each pair through the
      // predicate rather than materialising the whole cross product first.
      return try sift(execute(outer, context), execute(inner, context),
                      filter, context)
    case let .select(filter, source):
      return try admitted(execute(source, context), filter, context)
    case let .project(terms, source):
      // An explicit loop, not a `.map` closure: the borrowed `~Escapable` self
      // a projected scalar subquery materialises against cannot be captured by
      // a closure, so each record projects in a direct re-borrow.
      let source = try execute(source, context)
      var projected = Array<Record>()
      projected.reserveCapacity(source.count)
      for record in source {
        try projected.append(project(terms, record, context))
      }
      return projected
    case let .sort(keys, source):
      return try sorted(execute(source, context), keys, context)
    case let .product(outer, inner):
      return try product(execute(outer, context), execute(inner, context))
    case let .join(outer, name, ordinals, base, column, keys, filter):
      return try join(execute(outer, context), name, ordinals, base, column,
                      keys, filter, context)
    case let .outer(left, right, on, kind):
      // The side widths come from the sub-plans (known for a compiled plan),
      // so an unmatched row NULL-extends to the right width even when a side
      // yields no rows to read a width off.
      return try outer(execute(left, context), execute(right, context),
                       widths: (left: left.slots ?? 0, right: right.slots ?? 0),
                       on, kind, context)
    case let .semijoin(left, right, on, anti):
      // The side widths come from the sub-plans (known for a compiled plan), so
      // the hash fast-path can map a straddling equi key's right slot into the
      // right side's own standalone space.
      return try semijoin(execute(left, context), execute(right, context),
                          widths: (left: left.slots ?? 0,
                                   right: right.slots ?? 0),
                          on, anti: anti, context)
    case let .apply(left, key, correlation, ordinals, on, kind):
      return try applied(execute(left, context), key, correlation, ordinals,
                         on, kind, context)
    case let .setop(kind, left, right, all, types, _):
      return try setop(kind, left, right, all, types, context)
    case let .distinct(source):
      return deduplicated(try execute(source, context))
    case let .aggregate(keys, aggregates, source):
      return try grouped(execute(source, context), keys, aggregates, context)
    case let .window(windowings, source):
      return try windowed(execute(source, context), windowings, context)
    case let .limit(count, offset, source):
      return limited(try execute(source, context), count, offset)
    case let .top(keys, offset, count, source):
      return try topmost(execute(source, context), keys, offset, count, context)
    }
  }

  /// Executes the query-level `ordered` set-operation carrier `plan` over the
  /// inner set operation `union`, routing the setop leaf through the same
  /// per-arm augmentation the direct `run(.setop)` and the correlated-subquery
  /// `arms` use — so a derived table an arm names is materialised in that arm's
  /// own scope before its `.scan` reads it.
  ///
  /// The carrier plan `ordered` builds is a stack of single-source row
  /// operators (`sort`/`distinct`/`limit`/`project`, and the `project`/`sort`
  /// pair a `materialised` output key emits) OVER the compiled `union` setop.
  /// The plain `execute(_:_:)` would run the setop under the one carrier
  /// context (`execute(.setop)` shares it across both arms), which never binds
  /// an arm's arm-local derived alias — arms are SELECT-scoped, so the query-
  /// level augment misses them. This descends the wrapper stack unchanged,
  /// applying each operator through the same helper `execute(_:_:)` uses, and
  /// at the setop leaf runs `arms(_:_:_:)` — per-arm augment, per arm
  /// `execute`, shared `combine` — so the carrier's sort/dedup/limit see the
  /// fully materialised combined rows in the union's output slot space. A
  /// `union` with only base-relation arms materialises nothing extra, so it
  /// runs identically.
  internal borrowing func execute(_ plan: Plan, carrying union: Query,
                                  _ context: Context)
      throws(SQLError) -> Array<Record> {
    switch plan {
    case .setop:
      return try arms(plan, union, context)
    case let .project(terms, source):
      let source = try execute(source, carrying: union, context)
      var projected = Array<Record>()
      projected.reserveCapacity(source.count)
      for record in source {
        try projected.append(project(terms, record, context))
      }
      return projected
    case let .sort(keys, source):
      return try sorted(execute(source, carrying: union, context), keys,
                        context)
    case let .distinct(source):
      return deduplicated(try execute(source, carrying: union, context))
    case let .limit(count, offset, source):
      return limited(try execute(source, carrying: union, context), count,
                     offset)
    case let .select(filter, source):
      return try admitted(execute(source, carrying: union, context), filter,
                          context)
    default:
      // The carrier stack holds only the single-source row operators above; any
      // other node is not one the carrier builds, so execute it as-is (it does
      // not enclose the setop leaf).
      return try execute(plan, context)
    }
  }

  /// Sorts `rows` by the ordered `keys` — the executor's `.sort` node body,
  /// shared with the query-level `ordered` set-operation carrier so the two
  /// sort a combined result identically.
  ///
  /// Each key's `Term` is evaluated against every record up front — a bare slot
  /// read, but any lowered expression (`a + b`, `UPPER(Name)`, an ordinal's or
  /// alias's select-list item) — so the comparator sorts on precomputed values.
  /// Evaluation may throw (a scalar call, a division), which a `sorted(by:)`
  /// comparator cannot, so it happens here rather than inside the sort; it also
  /// evaluates each key once per row rather than once per comparison. An
  /// explicit loop keeps the borrowed `self` a scalar sort key materialises
  /// against out of a closure capture.
  internal borrowing func sorted(_ rows: Array<Record>,
                                 _ keys: Array<(term: Term, ascending: Bool)>,
                                 _ context: Context)
      throws(SQLError) -> Array<Record> {
    var sortable = Array<Array<Value>>()
    sortable.reserveCapacity(rows.count)
    for record in rows {
      var cells = Array<Value>()
      cells.reserveCapacity(keys.count)
      for key in keys {
        try cells.append(evaluate(record, key.term, context))
      }
      sortable.append(cells)
    }
    return sortable.indices
      .sorted { lhs, rhs in
        // Compare the keys major to minor: the first key on which the rows
        // differ decides the order; a key they are equal on falls through to
        // the next. A key's direction governs that key alone.
        for index in keys.indices {
          let ordered = less(sortable[lhs][index], sortable[rhs][index])
          let reverse = less(sortable[rhs][index], sortable[lhs][index])
          if ordered == reverse { continue }
          return keys[index].ascending ? ordered : reverse
        }
        // Equal on every key: keep the source order (a stable sort) by
        // tie-breaking on the original index.
        return lhs < rhs
      }
      .map { rows[$0] }
  }

  /// Selects the `offset + count` head rows of `rows` in the order the fused
  /// `sort` would impose, then drops the first `offset` and takes at most
  /// `count` — the executor's `top` node body, byte-identical to
  /// `sorted(rows, keys)` then `limited(_, count, offset)` but bounded: it
  /// keeps only the head prefix in a max-heap rather than sorting the input, an
  /// `O(n log(offset + count))` partial sort in place of `sort`'s `O(n log n)`.
  ///
  /// Each key term is evaluated once per row up front — exactly as `sorted`
  /// does — so a throwing key (`ORDER BY 1 / x`) faults over the same rows,
  /// before any row is selected or dropped: the fusion changes which rows are
  /// KEPT, never which rows a key is evaluated on. The comparator is `sorted`'s
  /// own — major-to-minor `less` with each key's direction flip and the
  /// original-index ascending tie-break — so among rows equal on every key the
  /// lowest input index wins, the stable sort's choice; the retained prefix is
  /// therefore the head of the full stable sort.
  internal borrowing func topmost(
      _ rows: Array<Record>,
      _ keys: Array<(term: Term, ascending: Bool)>,
      _ offset: Int, _ count: Int, _ context: Context)
      throws(SQLError) -> Array<Record> {
    // Evaluate each key once per row, exactly as `sorted` does — so a throwing
    // key raises over the same rows before any row is selected or dropped.
    var sortable = Array<Array<Value>>()
    sortable.reserveCapacity(rows.count)
    for record in rows {
      var cells = Array<Value>()
      cells.reserveCapacity(keys.count)
      for key in keys {
        try cells.append(evaluate(record, key.term, context))
      }
      sortable.append(cells)
    }

    // The total order `sorted` sorts by — major-to-minor `less` with each key's
    // direction, tie-broken by the ascending original index. The index
    // tie-break makes it a strict total order, so the head selection is
    // unambiguous and matches the stable sort exactly.
    let before = { (lhs: Int, rhs: Int) -> Bool in
      for index in keys.indices {
        let ordered = less(sortable[lhs][index], sortable[rhs][index])
        let reverse = less(sortable[rhs][index], sortable[lhs][index])
        if ordered == reverse { continue }
        return keys[index].ascending ? ordered : reverse
      }
      return lhs < rhs
    }

    // The bound is `offset + count`, saturated to `Int.max` on overflow so an
    // `Int.max` FETCH never traps — it then simply exceeds the row count and
    // the heap keeps every row (degrading to a full sort, never a fault).
    let sum = offset.addingReportingOverflow(count)
    let bound = sum.overflow ? Int.max : sum.partialValue

    // Keep only the `bound` smallest indices under `before` in a bounded
    // max-heap, then sort them into order, drop the first `offset`, and take at
    // most `count` — byte-identical to `limited` over the full `sorted`.
    var heap = Heap(capacity: bound, before: before)
    for index in sortable.indices { heap.offer(index) }
    let selected = heap.sorted()
    guard offset < selected.count else { return [] }
    return selected[offset...].prefix(count).map { rows[$0] }
  }

  /// Evaluates each projected `term` against `record` through `routines` to the
  /// output row, in order — slot `i` of the result is `terms[i]`. This catalog
  /// and `relations` thread through so a projected scalar subquery materialises
  /// lazily on first reach (see the evaluator's `.subquery` case).
  private borrowing func project(_ terms: Array<Term>, _ record: Record,
                                 _ context: Context)
      throws(SQLError) -> Record {
    var cells = Array<Value>()
    cells.reserveCapacity(terms.count)
    for term in terms {
      try cells.append(evaluate(record, term, context))
    }
    return Record(cells)
  }

  /// Keeps the `records` the `filter` admits — those it evaluates to `true`
  /// under three-valued logic (UNKNOWN and `false` both reject), resolving
  /// scalar calls through `routines` and parameters from `bindings`. This
  /// catalog and `relations` thread through for a scalar subquery in `filter`.
  private borrowing func admitted(_ records: Array<Record>, _ filter: Filter,
                                  _ context: Context)
      throws(SQLError) -> Array<Record> {
    var kept = Array<Record>()
    for record in records {
      if try evaluate(record, filter, context) == true {
        kept.append(record)
      }
    }
    return kept
  }

  /// The Cartesian product of `outer` and `inner` filtered row by row by
  /// `filter` — the fused product-under-select, streamed.
  ///
  /// A residual (non-equi) `product` under a `select` would otherwise
  /// materialise the whole `outer.count * inner.count` cross product and only
  /// then filter it, a memory blowup quadratic in the inputs. Here each pair is
  /// merged, tested, and kept or dropped in turn, so only the surviving rows —
  /// not the full product — are ever held. The order is identical to filtering
  /// the eager product: outer-major, each admitted inner in its own order. A
  /// pair the `filter` evaluates to `true` under three-valued logic is kept;
  /// UNKNOWN and `false` both drop, exactly as `admitted`.
  private borrowing func sift(_ outer: Array<Record>,
                              _ inner: Array<Record>, _ filter: Filter,
                              _ context: Context)
      throws(SQLError) -> Array<Record> {
    var records = Array<Record>()
    for left in outer {
      for right in inner {
        let record = left.merged(with: right)
        if try evaluate(record, filter, context) == true {
          records.append(record)
        }
      }
    }
    return records
  }

  /// The OUTER join of `left` and `right` on the `on` predicate — a nested loop
  /// tracking matches so an unmatched preserved row is emitted with the other
  /// side NULL-extended.
  ///
  /// `left`/`right` are the two materialised sides and `widths` each side's
  /// slot count (needed to NULL-extend even when a side is empty).
  /// Each candidate pair is merged (left slots then right slots) and tested
  /// against `on` under three-valued logic — TRUE matches, UNKNOWN and FALSE do
  /// not, exactly as a `WHERE` admits; `on` governs matching alone, so an
  /// unmatched preserved row is still emitted.
  ///
  ///   - `left`: every left row, in left-major order — each matched pair, then
  ///     a right-NULL row for a left row that matched nothing.
  ///   - `right`: the mirror — every right row, in right-major order, its
  ///     unmatched ones left-NULL.
  ///   - `full`: the left-major pass (matched pairs and right-NULL
  ///     unmatched-left rows) followed by a left-NULL row for every right row
  ///     no left row ever matched, so both sides' unmatched rows survive.
  ///
  /// A `.inner` kind never reaches here — `compile` lowers an inner join
  /// through the product/join path.
  ///
  /// fast path: when `on` carries an equi `.match` conjunct straddling the two
  /// sides (a left slot `< widths.left` equal to a right slot `>= widths.left`
  /// — the shape a decorrelated OUTER APPLY emits), a `.left`/`.full` join
  /// hashes the right side by that key once and probes per left row
  /// (`bucketed`), turning the O(left × right) nested loop into O(left +
  /// right). The probe re-checks the whole `on` on each bucket candidate — the
  /// bucket over-groups (two large integers can share a `Double` bucket) and
  /// `on` may carry residual conjuncts beyond the key — so the surviving pairs,
  /// the NULL-extension of unmatched left rows, and (for `.full`) the left-NULL
  /// of never-matched right rows are byte-identical to the nested-loop below. A
  /// NULL key buckets/probes nothing, so it stays unmatched exactly as the
  /// nested loop's UNKNOWN `.match` leaves it. A non-equi `on` (no straddling
  /// `.match`) takes the nested loop.
  ///
  /// The fast path fires ONLY when the whole `on` is `safe` (cannot throw): it
  /// evaluates `on` for the bucket candidates alone, so it skips a non-matching
  /// or NULL-key right row entirely — never evaluating `on` for it — whereas
  /// the nested loop evaluates the whole `on` for every pair. (This is NOT
  /// about AND short-circuiting: the evaluator IS Kleene and does short-circuit
  /// an `AND` on a FALSE left, but only on a FALSE one — an UNKNOWN or TRUE
  /// left still evaluates the right, and either side of the `on` may throw.) An
  /// unsafe `on` — a straddling `.match` AND a throwing conjunct like
  /// `(1 / B.x) = 0` — could therefore suppress a throw the nested loop raises
  /// on a skipped pair, so it falls to the nested loop below, which evaluates
  /// every pair and throws identically.
  /// A `safe` `on` throws on no pair, so skipping the non-bucket/NULL rows
  /// suppresses nothing. A decorrelated OUTER APPLY's `on` is safe by
  /// construction (the recogniser gates the residual and apply predicate
  /// `safe`), so it keeps the fast path.
  ///
  /// In practice every `.match`-carrying `on` that reaches here is already
  /// safe: the `on()` recogniser (`Resolve.swift`) forms no `.match` unless the
  /// whole ON is `allSatisfy(\.safe)`, and the OUTER APPLY decorrelation only
  /// folds a `.match` when its body residual and apply `on` are `safe`. This
  /// `on.safe` guard is defence-in-depth — it keeps the executor locally sound
  /// without relying on that distant invariant, so a future `.match` producer
  /// cannot silently suppress a throw here.
  private borrowing func outer(_ left: Array<Record>,
                               _ right: Array<Record>,
                               widths: (left: Int, right: Int),
                               _ on: Filter, _ kind: Join.Kind,
                               _ context: Context)
      throws(SQLError) -> Array<Record> {
    let nulls =
        (left: Record(Array(repeating: .null, count: widths.left)),
         right: Record(Array(repeating: .null, count: widths.right)))

    // The hash fast-path applies to the left-preserving kinds (`.left`/`.full`)
    // whose loop is left-major; a straddling equi `.match` conjunct gives the
    // probe key. `.right` keeps its own right-major nested loop above.
    if (kind == .left || kind == .full),
        let key = equikey(on, widths.left), on.safe {
      // `key.right` is in the combined `left ++ right` space; the right side is
      // materialised standalone, so its own slot is `key.right - widths.left`.
      return try bucketed(left, right,
                          key: (key.left, key.right - widths.left),
                          on, kind, nulls, context)
    }

    // A `right` join preserves the right side, so it drives the loop
    // right-major and NULL-extends the left. The `on` filter stays in the same
    // combined slot space (left slots then right slots), so each candidate is
    // still merged left-first — only the iteration order and the preserved side
    // differ.
    if kind == .right {
      var records = Array<Record>()
      for inner in right {
        var paired = false
        for lhs in left {
          let record = lhs.merged(with: inner)
          if try evaluate(record, on, context) == true {
            records.append(record)
            paired = true
          }
        }
        if !paired { records.append(nulls.left.merged(with: inner)) }
      }
      return records
    }

    var records = Array<Record>()
    // Track which right rows matched some left row — a `full` join emits the
    // never-matched ones NULL-extended after the left-major pass.
    var matched = Array(repeating: false, count: right.count)

    for lhs in left {
      var paired = false
      for index in right.indices {
        let record = lhs.merged(with: right[index])
        if try evaluate(record, on, context) == true {
          records.append(record)
          matched[index] = true
          paired = true
        }
      }
      // An unmatched left row is preserved (right NULL) for a `left` or `full`
      // join — the left side is preserved in both.
      if !paired {
        records.append(lhs.merged(with: nulls.right))
      }
    }

    // A `full` join also preserves every right row no left row matched (left
    // NULL).
    if kind == .full {
      for index in right.indices where !matched[index] {
        records.append(nulls.left.merged(with: right[index]))
      }
    }
    return records
  }

  /// The hash fast-path of a `.left`/`.full` OUTER join: the right side hashed
  /// once by `key.right` into buckets, then each left row probed by `key.left`
  /// in O(1). Behaviour-identical to the nested loop `outer` above — same
  /// surviving pairs, same NULL-extension, same order.
  ///
  /// The right side is bucketed by its key's promoted `bucket` (a NULL key
  /// buckets nothing — it can never equi-match, exactly as the nested loop's
  /// UNKNOWN `.match` leaves it unmatched). Each left row probes its own key's
  /// bucket, and every candidate is confirmed against the whole `on` — the
  /// bucket over-groups and `on` may carry residual conjuncts beyond the key —
  /// so a bucket collision or a failing residual drops the pair exactly as the
  /// nested loop's per-pair `on` test does. A left row with no confirmed pair
  /// is NULL-extended (right NULL), preserving it. For `.full`, a right row no
  /// left row confirmed is emitted left-NULL after the left-major pass,
  /// mirroring the nested loop's `matched` tracking.
  ///
  /// The iteration is left-major and, within a left row, walks the bucket in
  /// the order rows were inserted (right-cursor order), so the emitted order
  /// matches the nested loop's left-major/right-order pass. A left row whose
  /// key is NULL probes nothing and is NULL-extended.
  ///
  /// `key.left` is a combined-space slot (the left side is the record's
  /// prefix), while `key.right` is the right side's own standalone slot — the
  /// caller maps the combined right slot down by `widths.left` before the call.
  private borrowing func bucketed(_ left: Array<Record>,
                                  _ right: Array<Record>,
                                  key: (left: Int, right: Int),
                                  _ on: Filter, _ kind: Join.Kind,
                                  _ nulls: (left: Record, right: Record),
                                  _ context: Context)
      throws(SQLError) -> Array<Record> {
    // Bucket the right side by its key, remembering each row's index so a
    // `.full` join can emit the never-matched right rows left-NULL afterwards.
    var buckets = Dictionary<Value, Array<Int>>()
    for index in right.indices {
      let value = right[index][key.right]
      if case .null = value { continue }
      buckets[bucket(value), default: Array<Int>()].append(index)
    }

    var records = Array<Record>()
    var matched = Array(repeating: false, count: right.count)
    for lhs in left {
      let value = lhs[key.left]
      var paired = false
      // A NULL left key equi-matches nothing, so it probes no bucket and stays
      // unmatched — the `guard` skips straight to the NULL-extension below.
      if case .null = value {} else {
        for index in buckets[bucket(value)] ?? [] {
          let record = lhs.merged(with: right[index])
          // Confirm the whole `on` — the bucket over-groups and `on` may carry
          // residual conjuncts beyond the equi key, so a collision or a failing
          // residual drops the pair, exactly as the nested loop's `on` test.
          if try evaluate(record, on, context) == true {
            records.append(record)
            matched[index] = true
            paired = true
          }
        }
      }
      if !paired { records.append(lhs.merged(with: nulls.right)) }
    }

    // A `.full` join also preserves every right row no left row confirmed.
    if kind == .full {
      for index in right.indices where !matched[index] {
        records.append(nulls.left.merged(with: right[index]))
      }
    }
    return records
  }

  /// The semijoin of `left` against `right` on `on` — an existence
  /// test emitting each surviving LEFT record unchanged, never merged with a
  /// right one and never NULL-extended.
  ///
  /// `left`/`right` are the two materialised sides, `widths` each side's slot
  /// count (the fast path maps the equi key's combined-space right slot down by
  /// `widths.left` into the right side's own space). A candidate pair is merged
  /// (left slots then right slots) ONLY to evaluate `on` in the combined space;
  /// the LEFT record alone is what a survivor emits.
  ///
  ///   - semi (`anti == false`): a left row is kept iff SOME right row makes
  ///     merged `on` evaluate TRUE under three-valued logic (UNKNOWN and FALSE
  ///     do not match, exactly as a `WHERE` admits). The scan short-circuits on
  ///     the first match, so a left row appears at most once regardless of how
  ///     many right rows it matches — `EXISTS` is a decided per-row test, never
  ///     a multiplication.
  ///   - anti (`anti == true`): a left row is kept iff no right row makes `on`
  ///     TRUE — the complement, a decorrelated `NOT EXISTS`.
  ///
  /// A NULL correlation key makes the equi `.match` UNKNOWN, so no right row
  /// matches: semi drops such a left row, anti keeps it — `EXISTS` two-valued,
  /// never UNKNOWN. An empty right side matches nothing, so semi emits nothing
  /// and anti emits every left row.
  ///
  /// fast path: when `on` carries a straddling equi `.match` conjunct (shape
  /// a decorrelated `EXISTS` emits, found by `equikey`) AND the whole `on` is
  /// `safe`, the right side is bucketed by its key once and each left probes
  /// its own bucket, confirming the whole `on` per candidate (the bucket over-
  /// groups and `on` may carry residual conjuncts beyond the key) and short-
  /// circuiting on the first confirmed match — turning the O(left × right)
  /// nested loop into O(left + right). A NULL left key probes no bucket and so
  /// never matches, exactly as the nested loop's UNKNOWN `.match` leaves it.
  ///
  /// The fast path fires ONLY when `on` is `safe`, for the same reason the
  /// `.outer` executor gates its own hash path: it evaluates `on` for a left
  /// row's matching-key bucket candidates alone, skipping every non-bucket and
  /// NULL-key right row, whereas the nested loop evaluates `on` for every pair.
  /// (This is NOT `AND` short-circuiting: the evaluator is Kleene and does
  /// circuit an `AND` on a FALSE left, but an UNKNOWN or TRUE left still
  /// evaluates the right, and either side may throw.) An unsafe `on` could
  /// therefore suppress a throw the nested loop raises on a skipped pair, so it
  /// falls to the nested loop, which evaluates every pair and throws
  /// identically. In practice the decorrelation only ever builds a `safe` `on`
  /// (its correlation `.match` and residual are gated `safe`), so this gate is
  /// defence-in-depth against a future producer.
  private borrowing func semijoin(_ left: Array<Record>,
                                  _ right: Array<Record>,
                                  widths: (left: Int, right: Int),
                                  _ on: Filter, anti: Bool,
                                  _ context: Context)
      throws(SQLError) -> Array<Record> {
    if let key = equikey(on, widths.left), on.safe {
      // `key.right` is in the combined `left ++ right` space; the right side is
      // materialised standalone, so its own slot is `key.right - widths.left`.
      return try bucketed(left, right,
                          key: (key.left, key.right - widths.left),
                          on, anti: anti, context)
    }

    var records = Array<Record>()
    for lhs in left {
      // Short-circuit on the first right row that confirms `on` — a left row
      // survives (semi) or is excluded (anti) by existence alone, so it need
      // never scan past the first match, and is emitted at most once.
      var found = false
      for rhs in right where try evaluate(lhs.merged(with: rhs), on,
                                          context) == true {
        found = true
        break
      }
      // semi keeps a matched left row, anti keeps an unmatched one — and the
      // LEFT record alone is emitted, never the merge.
      if found != anti { records.append(lhs) }
    }
    return records
  }

  /// The hash fast-path of a semijoin: the right hashed once by `key.right`
  /// into buckets, then each left row probed by `key.left` in O(1) and short-
  /// circuited on the first confirmed match. Behaviour-identical to the nested
  /// loop `semijoin` above — same survivors, each emitted at most once.
  ///
  /// The right side is bucketed by its key's promoted `bucket` (a NULL key
  /// buckets nothing — it can never equi-match, exactly as the nested loop's
  /// UNKNOWN `.match` leaves it). Each left row probes its own key's bucket and
  /// every candidate is confirmed against the whole `on` — the bucket over-
  /// groups and `on` may carry residual conjuncts beyond the key — the first
  /// confirmed match deciding existence. A left row whose key is NULL probes
  /// nothing and matches nothing. semi emits a matched left row (unchanged, at
  /// most once); anti emits an unmatched one — the complement.
  ///
  /// `key.left` is a combined-space slot (the left is the record's prefix),
  /// while `key.right` is the right's own standalone slot — the caller maps
  /// the combined right slot down by `widths.left` before the call.
  private borrowing func bucketed(_ left: Array<Record>,
                                  _ right: Array<Record>,
                                  key: (left: Int, right: Int),
                                  _ on: Filter, anti: Bool,
                                  _ context: Context)
      throws(SQLError) -> Array<Record> {
    // Bucket the right side by its key; a NULL-keyed right row equi-matches
    // nothing, so it is never bucketed.
    var buckets = Dictionary<Value, Array<Int>>()
    for index in right.indices {
      let value = right[index][key.right]
      if case .null = value { continue }
      buckets[bucket(value), default: Array<Int>()].append(index)
    }

    var records = Array<Record>()
    for lhs in left {
      let value = lhs[key.left]
      var found = false
      // A NULL left key equi-matches nothing, so it probes no bucket and stays
      // unmatched — semi drops it, anti keeps it.
      if case .null = value {} else {
        for index in buckets[bucket(value)] ?? [] {
          // Confirm the whole `on` — the bucket over-groups and `on` may carry
          // residual conjuncts beyond the equi key, so a collision or a failing
          // residual is not a match, exactly as the nested loop's `on` test.
          // The first confirmed match decides existence, so stop scanning.
          if try evaluate(lhs.merged(with: right[index]), on, context) == true {
            found = true
            break
          }
        }
      }
      if found != anti { records.append(lhs) }
    }
    return records
  }
}

/// The `(left, right)` slot pair of an equi `.match` conjunct in `on` that
/// straddles the join boundary `boundary` — one slot on the left side
/// (`< boundary`), the other on the right (`>= boundary`) — or `nil` when no
/// such conjunct exists (a non-equi `on`, or a `.match` wholly on one side).
/// The first straddling `.match` among the top-level `AND` conjuncts is the
/// hash key; any further conjuncts ride the whole-`on` confirm the probe
/// applies.
private func equikey(_ on: Filter, _ boundary: Int)
    -> (left: Int, right: Int)? {
  for conjunct in on.conjuncts {
    guard case let .match(lhs, rhs) = conjunct else { continue }
    switch (lhs < boundary, rhs < boundary) {
    case (true, false): return (lhs, rhs)
    case (false, true): return (rhs, lhs)
    default: continue
    }
  }
  return nil
}

/// Caps `records` to at most `count` rows after skipping the first `offset`, in
/// their existing (ordered) order.
///
/// A `nil` `count` is no cap — every row after the skip (an `OFFSET` without a
/// `FETCH`). An `offset` at or past the end yields no rows; a `count` reaching
/// past the remaining rows takes all of them. Both are non-negative, so the
/// skip and the take never index before the start. The take is a `prefix` of
/// the skipped slice rather than an `offset + count` bound, so a `count` near
/// `Int.max` caps the slice instead of overflowing.
/// A bounded max-heap of row indices ordered by a `before` total order — the
/// selection buffer `topmost` keeps the head prefix in.
///
/// The root is the index that comes LAST under `before` (the largest kept), so
/// once the heap is full a new index that comes `before` the root evicts it.
/// Selecting the `capacity` smallest indices this way is `O(n log capacity)`,
/// where sorting the whole input would be `O(n log n)`. `capacity` may be
/// `Int.max` (a saturated `offset + count`), so the buffer never pre-reserves
/// it — it grows to at most `min(n, capacity)` elements as indices are offered.
private struct Heap {
  private var elements = Array<Int>()
  private let capacity: Int
  private let before: (Int, Int) -> Bool

  internal init(capacity: Int, before: @escaping (Int, Int) -> Bool) {
    self.capacity = capacity
    self.before = before
  }

  /// Offers `index` to the heap: inserted while the heap is below `capacity`,
  /// else it displaces the root only when it comes `before` it (is smaller than
  /// the largest kept). A `capacity` of zero keeps nothing.
  internal mutating func offer(_ index: Int) {
    if elements.count < capacity {
      elements.append(index)
      rise(from: elements.count - 1)
    } else if capacity > 0, before(index, elements[0]) {
      elements[0] = index
      fall(from: 0)
    }
  }

  /// The kept indices in ascending `before` order — the sorted head prefix.
  internal func sorted() -> Array<Int> {
    elements.sorted(by: before)
  }

  /// Restores the max-heap property upward from `start`: a child greater than
  /// its parent (the parent comes `before` it) rises.
  private mutating func rise(from start: Int) {
    var index = start
    while index > 0 {
      let parent = (index - 1) / 2
      guard before(elements[parent], elements[index]) else { break }
      elements.swapAt(parent, index)
      index = parent
    }
  }

  /// Restores the max-heap property downward from `start`: the parent sinks
  /// past its greater child (the one it comes `before`).
  private mutating func fall(from start: Int) {
    var index = start
    let count = elements.count
    while true {
      let left = 2 * index + 1
      let right = 2 * index + 2
      var largest = index
      if left < count, before(elements[largest], elements[left]) {
        largest = left
      }
      if right < count, before(elements[largest], elements[right]) {
        largest = right
      }
      guard largest != index else { break }
      elements.swapAt(index, largest)
      index = largest
    }
  }
}

private func limited(_ records: Array<Record>, _ count: Int?, _ offset: Int)
    -> Array<Record> {
  guard offset < records.count else { return [] }
  let tail = records[offset...]
  guard let count else { return Array(tail) }
  return Array(tail.prefix(count))
}

/// Combines the rows of `left` and `right` by the set operation `kind`,
/// deduplicating the whole row unless `all`.
///
/// Each side runs through the same `catalog`, `routines`, and `bindings`, so a
/// bound parameter threads into every arm alike. A side may itself be a
/// `setop`, and it executes with its own semantics first — a nested operation
/// resolves before the outer node combines its result. A `Record` is `Hashable`
/// and keys on its `canonical` values (so `1` and `1.0` are one row), the same
/// whole-row equality `UNION`'s dedup uses.
///
///   - `.union`: the rows of either side, `left` followed by `right`. Without
///     `all` the whole-row duplicates are removed (first occurrence kept);
///     with `all` (`UNION ALL`) every row is kept.
///   - `.intersect`: the rows present in both sides, in left order. Without
///     `all` each common row appears once; with `all` (`INTERSECT ALL`) it
///     appears the lesser of its two multiplicities.
///   - `.except`: the rows of `left` NOT balanced by `right`, in left order.
///     Without `all` each left row absent from `right` appears once; with
///     `all` (`EXCEPT ALL`) each left row appears its left count less its right
///     count, floored at zero.
extension Catalog where Self: ~Escapable {
  fileprivate borrowing func setop(_ kind: SetOperation, _ left: Plan,
                                   _ right: Plan, _ all: Bool,
                                   _ types: Array<ValueType>,
                                   _ context: Context)
      throws(SQLError) -> Array<Record> {
    // `types` is the compile-time unified per-column type — this node carries
    // no arm `Query`, so it cannot fold them here; `combine` coerces each arm's
    // rows to them before applying the operator.
    try combine(kind, execute(left, context), execute(right, context), all,
                types: types)
  }
}

/// Combines two set-operation arms' records under `kind` and `all` — `union`
/// keeps the rows of either, `intersect` those of both, `except` the left's not
/// balanced by the right — the executor's `setop` node and the per-arm run path
/// share this one combiner so the two agree on duplicate handling.
///
/// Each arm's cells are first coerced to the unified column `types` (`Value
/// .coerced` — the widening ISO type unification requires, so `SELECT 1 UNION
/// SELECT 2.5` emits a `double` column), the ONE numeric widening `coerced`
/// performs; a homogeneous set operation's `types` matches each arm's own
/// types, so the coercion is a no-op and the result is byte-identical.
/// `INTERSECT`/`EXCEPT` equality already canonicalises (`1` equals `1.0`), so
/// coercion there changes only the emitted cells' type, never which rows match.
internal func combine(_ kind: SetOperation, _ left: Array<Record>,
                      _ right: Array<Record>, _ all: Bool,
                      types: Array<ValueType>) -> Array<Record> {
  let left = left.map { $0.coerced(to: types) }
  let right = right.map { $0.coerced(to: types) }
  switch kind {
  case .union:
    let combined = left + right
    return all ? combined : deduplicated(combined)
  case .intersect:
    return intersected(left, right, all)
  case .except:
    return subtracted(left, right, all)
  }
}

/// A multiset of records keyed on their `canonical` cell values — the same
/// exact, transitive whole-row equality `UNION`'s dedup uses (so `1` and `1.0`
/// are one key), counting each distinct row's occurrences.
///
/// It backs the `INTERSECT`/`EXCEPT` multiplicity rules: `right`'s rows are
/// tallied into one, and a left row is admitted while its remaining count in
/// the map governs it. `Value` is `Hashable`, so the canonical cell array keys
/// directly.
private struct Multiset {
  private var counts = Dictionary<Array<Value>, Int>()

  /// Tallies each of `records` under its canonical key.
  internal init(_ records: Array<Record>) {
    for record in records {
      counts[record.values.map(canonical), default: 0] += 1
    }
  }

  /// Whether the multiset still holds an occurrence of `record`'s row.
  internal func contains(_ record: Record) -> Bool {
    (counts[record.values.map(canonical)] ?? 0) > 0
  }

  /// Removes one occurrence of `record`'s row, reporting whether one was
  /// present to remove — the `EXCEPT ALL` "cancel a left row against a right"
  /// step.
  internal mutating func remove(_ record: Record) -> Bool {
    let key = record.values.map(canonical)
    guard let count = counts[key], count > 0 else { return false }
    counts[key] = count - 1
    return true
  }
}

/// The rows present in both `left` and `right` — `INTERSECT`.
///
/// Without `all` each row common to both sides appears once, in left order
/// (the first occurrence kept); with `all` it appears the lesser of its left
/// and right multiplicities. `right` is tallied into a `Multiset`; a left row
/// is emitted while an occurrence remains to balance it, so the `all` count is
/// naturally capped at the right side's — and, absent `all`, an emitted row is
/// recorded in a `Seen` set so later duplicates in `left` are dropped.
private func intersected(_ left: Array<Record>, _ right: Array<Record>,
                         _ all: Bool) -> Array<Record> {
  var remaining = Multiset(right)
  var rows = Array<Record>()
  var seen = Seen()
  for record in left {
    if all {
      if remaining.remove(record) { rows.append(record) }
    } else if remaining.contains(record) && seen.insert(record.values) {
      rows.append(record)
    }
  }
  return rows
}

/// The rows of `left` not balanced by `right` — `EXCEPT`.
///
/// Without `all` each `left` row with no match in `right` appears once, in
/// left order (the first occurrence kept); with `all` each `left` row appears
/// its left count less its right count, floored at zero. `right` is tallied
/// into a `Multiset`: for `all` each left row cancels one right occurrence and
/// is emitted only once the right's copies are exhausted; absent `all` a left
/// row is emitted when `right` holds none of it, deduplicated through a `Seen`
/// set.
private func subtracted(_ left: Array<Record>, _ right: Array<Record>,
                        _ all: Bool) -> Array<Record> {
  var remaining = Multiset(right)
  var rows = Array<Record>()
  var seen = Seen()
  for record in left {
    if all {
      if !remaining.remove(record) { rows.append(record) }
    } else if !remaining.contains(record) && seen.insert(record.values) {
      rows.append(record)
    }
  }
  return rows
}

/// The rows of `records` with whole-row duplicates removed — the first
/// occurrence of each distinct row kept and their order preserved.
///
/// A `Record` is `Hashable`, so the dedup keys on the materialised row's values
/// through the `Seen` set — the same whole-row equality `UNION` uses. It backs
/// both a bare `UNION` and `SELECT DISTINCT`.
private func deduplicated(_ records: Array<Record>) -> Array<Record> {
  var rows = Array<Record>()
  var seen = Seen()
  for record in records where seen.insert(record.values) {
    rows.append(record)
  }
  return rows
}

/// Materialises the referenced `ordinals` of the relation `name` over the
/// seek's row range (the whole relation when `nil`) into dense slot `Record`s.
///
/// A common table expression `name` (in `ctes`, consulted first — a CTE shadows
/// a base relation) materialises its records directly from the in-engine
/// `RelationInstance` rows; else the base relation re-resolves through this
/// catalog, its cursor opened.
///
/// - Throws: `SQLError.relation` if the name resolves to neither.
extension Catalog where Self: ~Escapable {
  fileprivate borrowing func materialise(_ name: String,
                                         _ ordinals: Array<Int>,
                                         _ seek: Range<Int>?,
                                         _ ctes: ScopedRelations)
      throws(SQLError) -> Array<Record> {
    if let cte = ctes[name.lowercased()] {
      return (seek ?? 0 ..< cte.rows.count).map { cte.record($0, ordinals) }
    }
    guard let table = table(named: name) else { throw .relation(name) }
    let cursor = table.cursor()
    var records = Array<Record>()
    for index in seek ?? 0 ..< cursor.count {
      guard let row = cursor.row(index) else { continue }
      records.append(Record(row, ordinals))
    }
    return records
  }
}

extension Catalog where Self: ~Escapable {
  /// Executes a view's sub-`plan` against this catalog and re-lays each
  /// resulting record to the referenced `ordinals` (slots into the view's
  /// columns) over the seek's row range (the whole result when `nil`).
  ///
  /// The sub-plan yields full-width view records — its columns at slots `0 ..<
  /// columns.count`; this projects each to the `ordinals` the outer query
  /// reads, in the slot order the outer scan expects (slot `i` is
  /// `ordinals[i]`).
  ///
  /// The sub-plan runs outside the statement's CTE scope — never the caller's
  /// `WITH` — so a caller's `WITH` never reaches into a stored view's body: a
  /// view's own `FROM`/`JOIN` names resolve to base relations (and other
  /// views), never to a statement-local CTE that happens to share a name. Its
  /// scope is instead the `definition_schema.` overlay the view's own query
  /// names (empty when it names none), so a view defined over a store relation
  /// materialises exactly as the inline query does — the same overlay the body
  /// compiled and optimised under.
  internal borrowing func derive(_ name: String, _ plan: Plan,
                                 _ ordinals: Array<Int>, _ seek: Range<Int>?,
                                 _ context: Context)
      throws(SQLError) -> Array<Record> {
    var overlay = context.body([:])
    if let view = resolve(view: name) {
      // execution-path materialise (`rows: true`): a nested derived body's
      // schema is derived schema-only inside `materialise`, so `validate:
      // false` keeps that lenient — a data-dependent-empty derived body in a
      // view body must not fault at run, matching the top-level run path. Seed
      // the cyclic-view guard with this view's own name, as `resolve(view:)`
      // does, so a body materialising this view through a derived table (`FROM
      // (SELECT * FROM <self>) AS d`) faults `.recursion` in `materialise`
      // rather than re-running the body without end. `body([:])` enters the
      // view-body scope with the caller's correlation stack cleared, so a
      // nested derived body's schema (derived while `augment`/`materialise`
      // resolves it) cannot bind an unbound column outward to an enclosing row.
      let fresh = context.body([:]).visiting(name).validating(false)
      overlay = try augment(fresh, for: view.query, rows: true)
      // Record the view body's own overlay under `.view(name)` so its lazy
      // subqueries re-run against the view's base relations, while a caller
      // conjunct pushed into this body keeps its `.caller` overlay and re-runs
      // against the caller's — each subquery resolving in its own textual scope
      // regardless of the execution site a pushdown lands it at. A view body
      // may nest `EXISTS`/`IN (Q)`/scalar subqueries its own plan carries,
      // lowered under `.view(name)` — a disjoint id space from the `.caller`
      // one (see `Subscope`) — so a view-body `EXISTS (SELECT V FROM S)` over
      // the view's own base and a caller's pushed one over a same-named CTE are
      // separate occurrences. The row evaluator runs each lazily into the same
      // shared memo box `context.subqueries` carries (kept in `overlay` via
      // `scoping`, which preserves the subqueries), so a view-body occurrence
      // memoises beside the caller's without either overwriting the other.
      context.subqueries.record(overlay: overlay.revealed().relations,
                                for: .view(name.lowercased()))
    }
    let rows: Array<Record>
    let view = resolve(view: name)
    if let view, view.query.carriers.isEmpty, case .setop = view.query.body,
        case .setop = plan {
      // A SET-operation view body executes each ARM's sub-plan under an overlay
      // augmented with that arm's own derived aliases. A `setop` collects no
      // derived aliases at the query level (arms are SELECT-scoped), so the
      // overlay built above binds none; a `CREATE VIEW v AS SELECT * FROM
      // (SELECT Id FROM T) AS d UNION ALL …` would else execute an arm `.scan`
      // over an unbound `d`. Executing the arm SUB-plans (not re-running the
      // arm queries) preserves any conjunct the caller pushed into the view's
      // plan — the pushed filter lives in each arm's sub-plan — while the
      // per-arm augment binds the arm-local `d` the whole-body overlay missed.
      //
      // Its subqueries run per ARM inside `setop`, not here over the whole-view
      // overlay: an arm's direct `EXISTS`/`IN (Q)` may name that arm's own arm-
      // local derived alias, so running it demands the arm's own augment in
      // scope — the whole-view overlay binds no arm alias, so a whole-view
      // materialise would fault `.relation("d")` before an arm ever ran.
      // Mirrors the per-arm run and `SELECT *` arity paths.
      rows = try setop(plan, view.query, overlay, name.lowercased())
    } else if let view, !view.query.carriers.isEmpty,
        case .setop = view.query.body {
      // The body is a set operation under an `ordered` carrier (`… UNION …
      // ORDER BY V`), whose plan is a `.shaped` project/sort/distinct stack
      // over the `.setop`, NOT a bare setop, so both guards above failed and
      // the arm-local derived aliases went unmaterialised (`.relation`). Pass
      // the carrier-transparent core to `setop`, which descends the wrapper —
      // applying each row operator through the same executor helpers
      // `execute(_:carrying:)` uses — to the setop leaf where it per-arm
      // augments. gated on the body actually wearing a carrier, so a bare union
      // view keeps the exact plan-shape dispatch above.
      rows = try setop(plan, view.query.core, overlay, name.lowercased())
    } else {
      // A single-arm view body's subqueries run lazily into the shared memo box
      // the `overlay` carries (recorded above under `.view(name)`), so the
      // sub-plan's row evaluator reads each result on first reach.
      rows = try execute(plan, overlay)
    }
    let range = seek ?? 0 ..< rows.count
    return range.map { rows[$0].project(ordinals) }
  }

  /// Executes a view body's SET-operation `plan` arm by arm, each arm sub-plan
  /// under `overlay` augmented with that arm's own derived aliases, combining
  /// the arms under each node's operator.
  ///
  /// The `plan` tree mirrors the `query` tree (compile builds `.setop(kind,
  /// compile(left), compile(right), all)` from `.setop(kind, left, right,
  /// all)`), so this descends the two in lockstep: a `.setop` node recurses
  /// into both arms and `combine`s the results, and a leaf arm — a `.select`
  /// query, its sub-plan any non-`setop` node — augments the arm's derived
  /// aliases into `overlay` (rows, so its `.scan` reads them) and executes the
  /// sub-plan under that arm-local scope. Executing the sub-plan (not
  /// re-running the arm query) keeps any conjunct the caller pushed into the
  /// plan; the per-arm augment binds the arm-local derived alias the whole-body
  /// overlay omitted; and each arm's `d` stays scoped to its arm (two arms may
  /// reuse `d`).
  ///
  /// A leaf arm's direct `EXISTS`/`IN (Q)`/scalar subqueries run lazily into
  /// the shared memo box `overlay.subqueries` carries, lowered under
  /// `.view(name)` — the same scope the arm sub-plan's lowered `Filter`s
  /// compiled under — so an arm subquery resolves against the arm's own
  /// overlay. The arm's revealed overlay is recorded under `.view(name)` before
  /// executing (last arm's binding wins, but arms share the same base relations
  /// a subquery's FROM reveals to; the arm-local derived layer is SELECT-scoped
  /// and invisible to a subquery's FROM, so an arm subquery naming that arm's
  /// arm-local derived alias faults `.relation` as a single arm's does). A
  /// caller conjunct pushed into an arm keeps its `.caller` overlay and re-runs
  /// against the caller's relations.
  private borrowing func setop(_ plan: Plan, _ query: Query, _ overlay: Context,
                               _ name: String)
      throws(SQLError) -> Array<Record> {
    // See through an `ordered` carrier over a set operation nested as an arm: a
    // suffix-bearing parenthesised setop (`… UNION (… UNION … ORDER BY V
    // FETCH n)`) reaches this recursion as an `.ordered(.setop(…))` arm, whose
    // plan is a `.shaped` carrier stack over the setop. Peel to the carrier-
    // transparent `core` so the wrapper descent below fires and reaches the
    // inner setop's arms — where the per-arm augment binds their derived
    // aliases — rather than treating the whole carrier as one opaque leaf
    // (whose whole-query augment binds none, faulting `.relation`). `core`
    // leaves a bare setop or a leaf select unchanged, so a non-carried body is
    // untouched.
    let query = query.core
    if case let .setop(kind, left, right, all, types, _) = plan,
        case let .setop(_, leftQuery, rightQuery, _) = query.body {
      // This node's arm queries are in hand, so the unified column `types` the
      // plan carries (computed at compile) drive the arm coercion `combine`
      // applies — the same types the top-level and Plan-node paths use.
      return try combine(kind, setop(left, leftQuery, overlay, name),
                         setop(right, rightQuery, overlay, name), all,
                         types: types)
    }
    // An `ordered` view body compiles to a `.shaped` stack of single-source row
    // operators (`project`/`sort`/`distinct`/`limit`/`select`) OVER the setop,
    // so descend the wrapper — the same nodes `execute(_:carrying:)` descends —
    // applying each operator through the shared executor helpers, until the
    // `.setop` node recurses above and per-arm augments. The carrier wrapper
    // sits above the setop, so `query` is still the `.setop` core here — gate
    // on that: once the setop splits into an arm (`query` a `.select`), that
    // plan is the ARM's own sub-plan and must execute AS A unit under its own
    // augment below, NOT be walked through as a carrier wrapper (which would
    // apply the arm's projection/filter outside its arm-local scope).
    if case .setop = query.body {
      switch plan {
      case let .project(terms, source):
        let source = try setop(source, query, overlay, name)
        var projected = Array<Record>()
        projected.reserveCapacity(source.count)
        for record in source {
          try projected.append(project(terms, record, overlay))
        }
        return projected
      case let .sort(keys, source):
        return try sorted(setop(source, query, overlay, name), keys, overlay)
      case let .distinct(source):
        return deduplicated(try setop(source, query, overlay, name))
      case let .limit(count, offset, source):
        return limited(try setop(source, query, overlay, name), count, offset)
      case let .select(filter, source):
        return try admitted(setop(source, query, overlay, name), filter,
                            overlay)
      default:
        break
      }
    }
    // A single-arm leaf (a bare `.setop` body's arm, or a carrier wrapper's
    // innermost source once the setop above has split): augment this arm's own
    // derived aliases and execute its sub-plan under the arm-local scope.
    let scope = try augment(overlay.validating(false), for: query, rows: true)
    scope.subqueries.record(overlay: scope.revealed().relations,
                            for: .view(name))
    return try execute(plan, scope)
  }
}

/// The Cartesian product of two materialised relations: every concatenation of
/// an `outer` record with an `inner` one, in outer-major order.
private func product(_ outer: Array<Record>, _ inner: Array<Record>)
    -> Array<Record> {
  var records = Array<Record>()
  records.reserveCapacity(outer.count * inner.count)
  for left in outer {
    for right in inner {
      records.append(left.merged(with: right))
    }
  }
  return records
}

/// The equi-join of `outer` against the inner relation `name`, resolved through
/// `ctes` first then `catalog`, seeking or hashing the inner as its shape
/// allows.
///
/// A materialised CTE inner has no sort key, so it is scanned in full and
/// joined by the equality on its `keys.right` slot (`joined`). A base relation
/// that reports `column` (the inner ordinal `keys.right` reads) seekable is
/// sought per outer record — an index-nested loop, cheap because the seek
/// narrows the scan; one that is NOT seekable is scanned once into a hash map
/// keyed by its join value and each outer record probes it in O(1) (`hashed`),
/// rather than reading the whole inner once per outer record. Every strategy
/// materialises a candidate over the referenced `ordinals` into inner slots `0
/// ..< ordinals.count`, admits it only when the pushed inner `filter` (in the
/// inner's standalone slot space) also holds — applied while the inner row is
/// materialised, so a filtered inner row is never paired or bucketed — keys on
/// the inner's `keys.right` slot (`keys.right - base` in the standalone inner
/// record), and concatenates a match (the inner's slots landing at `base` in
/// the combined space). A NULL key joins to nothing, and every path preserves
/// outer-major order, the inner matches in cursor order within each outer.
///
/// The hash-JOIN bucket a key falls in — a grouping key, NOT the equality. A
/// numeric value buckets by its `Double` magnitude (an `.integer` promoted), so
/// every value equal to it under `Filter.matches` shares a bucket: `1` and
/// `1.0`, and an integer and the double it rounds to past 2^53. A non-numeric
/// value (text, boolean, blob, null) buckets as itself. The bucket may over-
/// group — two distinct large integers can share a `Double` bucket — so hash
/// probing pairs it with a residual `matches(_,.equal,_)` check, the same exact
/// equality the predicate uses (integer/integer exact, mixed promoted). The
/// seek and CTE nested-loop paths compare with `matches` directly.
private func bucket(_ value: Value) -> Value {
  if case let .integer(number) = value { return .double(Double(number)) }
  return value
}

/// A value folded to its exact canonical form for duplicate elimination: a
/// whole `double` exactly equal to an `Int` (`Int(exactly:)`) becomes that
/// `.integer`, so `1.0` and `1` are the same value; every other value (a
/// fractional double, text, boolean, blob, null) is itself. Unlike the join's
/// promoted `bucket`, this is exact and transitive, so two integers stay
/// distinct even when they round to the same double — an earlier approximate
/// row cannot absorb two unequal exact integers. Grouping reuses it to key its
/// groups so `1` and `1.0` fall in one group, matching UNION's dedup.
internal func canonical(_ value: Value) -> Value {
  if case let .double(number) = value, let integer = Int(exactly: number) {
    return .integer(integer)
  }
  return value
}

/// Tracks the rows already emitted for UNION / recursive-CTE duplicate
/// elimination under the engine's exact numeric equality. A plain
/// `Set<Array<Value>>` over raw cells keeps `1` and `1.0` (and would keep both)
/// apart; keying each row by its cells' `canonical` form — exact and transitive
/// — dedups `1`/`1.0` while keeping distinct integers separate even when they
/// round to the same double, and (unlike a promoted key) makes the result
/// independent of arm order. Two NULLs stay not distinct (`.null` is its own
/// canonical). No residual check needed: exact equality is an equivalence.
internal struct Seen {
  private var keys = Set<Array<Value>>()

  /// Records `row` and reports whether it was new (not a duplicate of one
  /// already seen) — the `Set.insert(_:).inserted` shape the dedup sites use.
  internal mutating func insert(_ row: Array<Value>) -> Bool {
    keys.insert(row.map(canonical)).inserted
  }
}

/// - Throws: `SQLError.relation` if the inner name resolves to neither.
extension Catalog where Self: ~Escapable {
  fileprivate borrowing func join(_ outer: Array<Record>, _ name: String,
                                  _ ordinals: Array<Int>, _ base: Int,
                                  _ column: Int,
                                  _ keys: (left: Int, right: Int),
                                  _ filter: Filter?, _ context: Context)
      throws(SQLError) -> Array<Record> {
    // A materialised CTE inner has no sort key, so it is scanned in full and
    // the equality on its `keys.right` slot is the join's truth — the same
    // probe a base relation falls back to when its key is unseekable. A pushed
    // inner filter (in the inner's standalone slot space) is applied as each
    // record materialises, before it can pair — mirroring the base seek/hash
    // paths — so a filtered CTE row is never joined.
    if let cte = context.relations[name.lowercased()] {
      var inner = Array<Record>()
      for index in 0 ..< cte.rows.count {
        let right = cte.record(index, ordinals)
        if let filter,
            try evaluate(right, filter, context) != true { continue }
        inner.append(right)
      }
      return try joined(outer, inner, base, keys)
    }
    guard let inner = table(named: name) else { throw .relation(name) }
    guard inner.seekable(column) else {
      return try inner.hashed(outer, ordinals, base, keys, filter, self,
                              context)
    }

    let cursor = inner.cursor()
    let slot = keys.right - base
    var records = Array<Record>()
    for left in outer {
      let value = left[keys.left]
      // A NULL key equi-joins to nothing — NULL is unequal to every value,
      // itself included — so it contributes no pair and need not probe.
      if case .null = value { continue }
      // Seek by the raw value — the sorted key is a single-kind (integer)
      // column, and a promoted double would defeat the seek; the numeric
      // equality below still admits a mixed-kind match (a whole double past the
      // range is caught by the residual check even if the seek scanned wide).
      let range = inner.probe(column, value, cursor.count)
      for index in range {
        guard let row = cursor.row(index) else { continue }
        let right = Record(row, ordinals)
        // A pushed inner filter is applied as each candidate materialises,
        // before it can pair — an inner row it rejects joins to nothing.
        if let filter,
            try evaluate(right, filter, context) != true { continue }
        // Equal by the same rule the predicate uses — integer/integer exact,
        // mixed integer/double promoted — so a seek that scanned wide still
        // pairs exactly.
        if try matches(value, .equal, right[slot]) == true {
          records.append(left.merged(with: right))
        }
      }
    }
    return records
  }
}

/// The hash equi-join of `outer` against `inner`: the inner scanned once into a
/// value → records map keyed on its join column, then each outer record probed
/// in O(1).
///
/// The inner is materialised over `ordinals` into standalone slots, its key the
/// slot `keys.right - base`; a NULL-keyed inner record joins to nothing and is
/// never bucketed. Each bucket keeps its rows in cursor order, so probing an
/// outer record in outer order yields the same outer-major, inner-cursor-order
/// result the seek path does. An outer NULL key probes nothing.
///
/// A pushed inner `filter` (in the inner's standalone slot space) is applied
/// during this scan, before a row is bucketed: the inner is seeked by the
/// filter's seekable conjunct — `boundaries` over each conjunct, the same
/// boundary logic the scan seek uses, mapping a slot back to its table column
/// through `ordinals` — so a seekable/contradictory inner filter reads few or
/// no inner rows rather than scanning the whole table; when no conjunct is
/// seekable the whole inner scans. Each read row is then admitted only when the
/// whole `filter` holds, so a filtered inner row is never bucketed or paired.
///
/// An outer with no non-null key has no probe that can match — an empty outer
/// has no probes at all, and a NULL key joins to nothing — so no match can
/// result; return before scanning and bucketing the inner rather than reading
/// every inner row to answer nothing. The nested-loop path this replaces read
/// zero inner rows for such an outer, and a selective or contradictory outer
/// WHERE (`… WHERE key IS NULL`, or one pruning every row) must not force a
/// full scan of a large unseekable inner.
extension Table where Self: ~Escapable {
  fileprivate borrowing func hashed<C>(_ outer: Array<Record>,
                                       _ ordinals: Array<Int>, _ base: Int,
                                       _ keys: (left: Int, right: Int),
                                       _ filter: Filter?,
                                       _ catalog: borrowing C,
                                       _ context: Context)
      throws(SQLError) -> Array<Record> where C: Catalog & ~Escapable {
    guard outer.contains(where: {
      if case .null = $0[keys.left] { false } else { true }
    }) else { return [] }

    let cursor = cursor()
    let slot = keys.right - base
    // Seek the inner by the pushed filter's seekable conjunct, so a
    // seekable/contradictory inner filter reads few or no rows; scan the whole
    // inner when the filter has none (or when there is no filter).
    let range = seek(filter, ordinals, cursor.count, context.bindings)
    var buckets = Dictionary<Value, Array<Record>>()
    for index in range {
      guard let row = cursor.row(index) else { continue }
      let right = Record(row, ordinals)
      // Apply the whole pushed filter before bucketing — a filtered inner row
      // is never a join candidate.
      if let filter,
          try catalog.evaluate(right, filter, context) != true { continue }
      if case .null = right[slot] { continue }
      buckets[bucket(right[slot]), default: Array<Record>()].append(right)
    }

    var records = Array<Record>()
    for left in outer {
      let value = left[keys.left]
      if case .null = value { continue }
      // Probe the bucket, then confirm each candidate with the exact `matches`
      // equality — the bucket over-groups (two distinct large integers can
      // share a `Double` bucket), so the residual check keeps integer/integer
      // exact.
      for right in buckets[bucket(value)] ?? []
          where try matches(value, .equal, right[slot]) == true {
        records.append(left.merged(with: right))
      }
    }
    return records
  }
}

/// The equi-join of `outer` against a fully materialised `inner` record set:
/// for each outer record whose `keys.left` value is non-NULL, every inner row
/// whose `keys.right` slot (`keys.right - base` in the standalone inner record)
/// equals it, the pair concatenated. The plain nested-loop a CTE inner takes.
private func joined(_ outer: Array<Record>, _ inner: Array<Record>,
                    _ base: Int, _ keys: (left: Int, right: Int))
    throws(SQLError) -> Array<Record> {
  let slot = keys.right - base
  var records = Array<Record>()
  for left in outer {
    let value = left[keys.left]
    if case .null = value { continue }
    // The same exact/promoted equality the predicate and the other join paths
    // use — integer/integer exact, mixed integer/double promoted, an
    // incomparable cross-kind key faulting `42804` (the comparability rule).
    for right in inner where try matches(value, .equal, right[slot]) == true {
      records.append(left.merged(with: right))
    }
  }
  return records
}

/// The inner row range the hash join scans and buckets: the `[lower, upper)`
/// seeked by `filter`'s first seekable conjunct — `boundaries` over each,
/// mapping a slot to its table column through `ordinals` — else the whole
/// `0 ..< count` when no conjunct qualifies (or there is no filter).
extension Table where Self: ~Escapable {
  fileprivate borrowing func seek(_ filter: Filter?, _ ordinals: Array<Int>,
                                  _ count: Int, _ bindings: Bindings)
      -> Range<Int> {
    guard let filter else { return 0 ..< count }
    for conjunct in filter.conjuncts {
      if let range = boundaries(conjunct, ordinals, count, bindings) {
        return range
      }
    }
    return 0 ..< count
  }
}

/// Whether the inner `column` of `table` can be seeked — the executor probes it
/// per outer record — as opposed to needing a hash build.
///
/// A seekable column reports a boundary for a valid key; an unseekable one
/// reports `nil`. The probe key must be a valid one: a decoded coded-index join
/// key is 1-based and reports `nil` for the null reference `0`, so probing with
/// `0` would misclassify a seekable coded-index column as unseekable and force
/// a hash build even for a selective join. `1` — the least valid key — answers
/// for every seekable column (`Id`, an owner foreign key, a sorted key, a
/// coded-index key); its value is otherwise irrelevant, since this is only a
/// capability check (the join loop seeks with the real outer key).
extension Table where Self: ~Escapable {
  fileprivate borrowing func seekable(_ column: Int) -> Bool {
    bound(column, 1, strict: false) != nil
  }
}

/// The inner range to probe for `value` on `column` of `table` of `count` rows:
/// the seeked `[lower, upper)` run when `value` is an integer on a seekable
/// column, else the whole `0 ..< count` to scan.
extension Table where Self: ~Escapable {
  fileprivate borrowing func probe(_ column: Int, _ value: Value, _ count: Int)
      -> Range<Int> {
    guard case let .integer(key) = value,
        let lower = bound(column, key, strict: false),
        let upper = bound(column, key, strict: true) else {
      return 0 ..< count
    }
    return lower ..< upper
  }
}

/// Orders two typed sort keys ascending, by their value.
///
/// `NULL` sorts before every non-null value — consistently first in ascending
/// order, last in descending — so a nullable sort key holds a stable, total
/// position rather than tying with every value (which is not a strict ordering
/// and leaves the rest unsorted). Otherwise both keys share a `Value` kind, as
/// they are read from the same slot, and compare by value; a kind mismatch a
/// single-slot key never produces orders as equal.
internal func less(_ lhs: Value, _ rhs: Value) -> Bool {
  switch (lhs, rhs) {
  case (.null, .null): false
  case (.null, _): true
  case (_, .null): false
  case let (.integer(lhs), .integer(rhs)): lhs < rhs
  case let (.double(lhs), .double(rhs)): lhs < rhs
  // A mixed integer/double key is numeric and ordered by magnitude — but
  // exactly, not via a lossy `Double(integer)`. Past 2^53 a promotion ties a
  // double with two distinct integers that themselves order exactly, which
  // would make this comparator non-transitive (not a strict weak ordering);
  // the exact form breaks the tie by the integer the double denotes.
  case let (.integer(lhs), .double(rhs)): less(integer: lhs, double: rhs)
  case let (.double(lhs), .integer(rhs)): less(double: lhs, integer: rhs)
  case let (.text(lhs), .text(rhs)): lhs < rhs
  case let (.boolean(lhs), .boolean(rhs)): !lhs && rhs
  case let (.blob(lhs), .blob(rhs)): lhs.lexicographicallyPrecedes(rhs)
  default: false
  }
}

/// Whether integer `lhs` is strictly less than double `rhs`, compared exactly.
/// `Double(lhs) < rhs` decides it unless the two tie under promotion — then
/// `rhs` is a whole double equal to `Double(lhs)`. If it denotes an exact `Int`
/// the integers compare directly, so a value past 2^53 orders by its true
/// magnitude; if it does not (`Double(Int.max)` rounds to 2^63, past `Int`),
/// `rhs` lies outside `Int` — positive here, so `lhs < rhs` — never a false tie
/// leaving the pair unordered.
private func less(integer lhs: Int, double rhs: Double) -> Bool {
  let promoted = Double(lhs)
  guard promoted == rhs else { return promoted < rhs }
  guard let exact = Int(exactly: rhs) else { return rhs > 0 }
  return lhs < exact
}

/// Whether double `lhs` is strictly less than integer `rhs`, compared exactly —
/// the mirror of `less(integer:double:)`. An out-of-`Int` tie means `lhs` lies
/// outside `Int`, so its sign decides: a positive `lhs` (past `Int.max`) is not
/// less than any `Int`.
private func less(double lhs: Double, integer rhs: Int) -> Bool {
  let promoted = Double(rhs)
  guard lhs == promoted else { return lhs < promoted }
  guard let exact = Int(exactly: lhs) else { return lhs < 0 }
  return exact < rhs
}
