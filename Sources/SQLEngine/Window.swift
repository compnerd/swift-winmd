// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Window-function execution — computing each window function over its ordered
/// partition and appending the result to every source record.
///
/// Unlike an aggregate — which folds a group to one row — a window function is
/// cardinality-preserving: the `window` node passes every source record through
/// and widens it by one slot per windowing (slot `source width + j` holds
/// windowing `j`'s value). Each windowing partitions the records by its own
/// `PARTITION BY` terms, orders each partition by its own `ORDER BY` keys, and
/// assigns the ranking value for each row's position in that order.

extension Catalog where Self: ~Escapable {
  /// Computes each `windowings` window function over `records` and appends its
  /// result as a fresh slot, preserving the records and their order.
  ///
  /// Each windowing yields one value per record (by its original position); the
  /// values are appended in windowing order, so the output record's slots are
  /// the source's own slots followed by `windowings[0]`, `windowings[1]`, … The
  /// several windowings of one query (each with its own `OVER`) are computed
  /// independently over the shared source.
  internal borrowing func windowed(_ records: Array<Record>,
                                   _ windowings: Array<Windowing>,
                                   _ context: Context)
      throws(SQLError) -> Array<Record> {
    // Each windowing's per-record value, indexed by the record's original
    // position — computed up front so the output row appends them in order.
    var columns = Array<Array<Value>>()
    columns.reserveCapacity(windowings.count)
    for windowing in windowings {
      try columns.append(computed(records, windowing, context))
    }

    var output = Array<Record>()
    output.reserveCapacity(records.count)
    for index in records.indices {
      var cells = records[index].values
      for column in columns { cells.append(column[index]) }
      output.append(Record(cells))
    }
    return output
  }

  /// One windowing's value for every record, indexed by the record's original
  /// position: partition the records by the partition terms (canonical, so `1`
  /// and `1.0` fall in one partition), order each partition by the window
  /// `ORDER BY`, and assign the ranking value.
  private borrowing func computed(_ records: Array<Record>,
                                  _ windowing: Windowing,
                                  _ context: Context)
      throws(SQLError) -> Array<Value> {
    // Group the record indices into partitions keyed on the canonical partition
    // values. With no `PARTITION BY` the whole input is one partition.
    var partitions = Array<Array<Int>>()
    var index = Dictionary<Record, Int>()
    for position in records.indices {
      var cells = Array<Value>()
      cells.reserveCapacity(windowing.partition.count)
      for key in windowing.partition {
        try cells.append(evaluate(records[position], key, context))
      }
      let identity = Record(cells.map(canonical))
      if let slot = index[identity] {
        partitions[slot].append(position)
      } else {
        index[identity] = partitions.count
        partitions.append([position])
      }
    }

    var values = Array(repeating: Value.null, count: records.count)
    for partition in partitions {
      // The window `ORDER BY` key values for every record of the partition —
      // computed once, used both to order the partition and (for the peer-aware
      // ranks) to detect ties.
      var keyed = Dictionary<Int, Array<Value>>(minimumCapacity: partition.count)
      for position in partition {
        var cells = Array<Value>()
        cells.reserveCapacity(windowing.order.count)
        for key in windowing.order {
          try cells.append(evaluate(records[position], key.term, context))
        }
        keyed[position] = cells
      }
      // Order the partition by the key values, major to minor, stably — with no
      // `ORDER BY` every row is a peer and the original order is kept.
      let ordered = partition.sorted { lhs, rhs in
        let left = keyed[lhs]!
        let right = keyed[rhs]!
        for index in windowing.order.indices {
          let ordered = less(left[index], right[index])
          let reverse = less(right[index], left[index])
          if ordered == reverse { continue }
          return windowing.order[index].ascending ? ordered : reverse
        }
        return lhs < rhs
      }
      switch windowing.function {
      case .rowNumber, .rank, .denseRank:
        assign(windowing.function, over: ordered, keyed, into: &values)
      case let .aggregate(aggregation):
        if let frame = windowing.frame {
          try framed(aggregation, over: ordered, keyed, in: records, context,
                     frame: frame, into: &values)
        } else {
          try accumulate(aggregation, over: ordered, keyed, in: records,
                         context, into: &values)
        }
      case let .lead(value, offset, fallback):
        try position(value, by: offset, default: fallback, over: ordered,
                     in: records, context, into: &values)
      case let .lag(value, offset, fallback):
        try position(value, by: -offset, default: fallback, over: ordered,
                     in: records, context, into: &values)
      }
    }
    return values
  }

  /// Folds an aggregate window's `aggregation` over each row's frame, writing
  /// the result into `values` at each record's original position. `ordered` is
  /// the partition in window order, `keyed` each record's window `ORDER BY`
  /// values, so the peer-aware running frame detects ties.
  ///
  /// The default frame is `RANGE UNBOUNDED PRECEDING`: a row's frame is every
  /// partition row up to and including its peer group — the rows tied with it
  /// on the window `ORDER BY`. So the fold runs cumulatively over the ordered
  /// partition one peer group at a time, and every peer of a group takes the
  /// same running value (the total through the last peer), never a row-by-row
  /// step within a tie. With no window `ORDER BY` every row is a peer, so the
  /// one peer group is the whole partition and every row takes the grand total
  /// — the whole-partition frame.
  ///
  /// The fold is the collapsing grouping path's own `Accumulator`, carried
  /// across the peer groups, so an aggregate window equals the running
  /// aggregate a cumulative `GROUP BY` would compute, spread over the rows
  /// rather than collapsed.
  private borrowing func accumulate(_ aggregation: Aggregation,
                                    over ordered: Array<Int>,
                                    _ keyed: Dictionary<Int, Array<Value>>,
                                    in records: Array<Record>,
                                    _ context: Context,
                                    into values: inout Array<Value>)
      throws(SQLError) {
    var accumulator = Accumulator(aggregation.function,
                                  distinct: aggregation.distinct)
    var start = 0
    while start < ordered.count {
      // The peer group [start, end) — the rows tied with `ordered[start]` on
      // every window `ORDER BY` key. With no order keys every row is a peer, so
      // this spans the whole partition.
      var end = start + 1
      while end < ordered.count,
            peers(keyed[ordered[end - 1]]!, keyed[ordered[end]]!) {
        end += 1
      }
      // Fold every row of the peer group into the running accumulator, then
      // assign its cumulative value to each — RANGE, so peers share the frame
      // end.
      for index in start ..< end {
        let position = ordered[index]
        // The aggregate's `FILTER (WHERE …)` gates the row before the fold (and
        // so before the DISTINCT dedup): only a definite TRUE admits it, a
        // FALSE or UNKNOWN row skipped, exactly as the grouping path gates.
        if let filter = aggregation.filter {
          guard try evaluate(records[position], filter, context) == true else {
            continue
          }
        }
        // `COUNT(*)` folds a non-NULL sentinel (a row is always counted); every
        // other aggregate folds its evaluated argument value.
        let value: Value = if let argument = aggregation.argument {
          try evaluate(records[position], argument, context)
        } else {
          .integer(0)
        }
        try accumulator.fold(value)
      }
      let running = try accumulator.value
      for index in start ..< end { values[ordered[index]] = running }
      start = end
    }
  }

  /// Folds an aggregate window's `aggregation` over each row's explicit
  /// `frame`, writing the result into `values` at each record's original
  /// position.
  /// `ordered` is the partition in window order, `keyed` each record's window
  /// `ORDER BY` values (so a `RANGE` frame can find a row's peer group).
  ///
  /// Unlike the default running frame — carried cumulatively across peer groups
  /// by `accumulate` — an explicit frame is a fresh slice per row (a moving sum
  /// over `ROWS BETWEEN 1 PRECEDING AND CURRENT ROW`, say), so each row's frame
  /// bounds are resolved to a `[lo, hi]` index range into `ordered` and the
  /// aggregate is folded over that slice anew. A row-offset bound (`ROWS`) is a
  /// physical position; a `CURRENT ROW` bound under `RANGE` is the whole peer
  /// group (the rows tied on the order key). An empty frame (`lo > hi`, from an
  /// offset running off the partition) folds nothing — `SUM`/`MIN`/`MAX`/`AVG`
  /// are then NULL, `COUNT` is `0`, exactly as an empty group aggregates.
  private borrowing func framed(_ aggregation: Aggregation,
                                over ordered: Array<Int>,
                                _ keyed: Dictionary<Int, Array<Value>>,
                                in records: Array<Record>,
                                _ context: Context,
                                frame: Frame,
                                into values: inout Array<Value>)
      throws(SQLError) {
    let count = ordered.count
    // Each ordered position's peer group — the maximal contiguous run of rows
    // tied on the window `ORDER BY` (with no order keys the whole partition) —
    // the `RANGE` `CURRENT ROW` bound. The partition is already sorted, so a
    // peer group is contiguous and a single forward scan bounds every position.
    var peerLo = Array(repeating: 0, count: count)
    var peerHi = Array(repeating: 0, count: count)
    var group = 0
    while group < count {
      var end = group + 1
      while end < count, peers(keyed[ordered[end - 1]]!, keyed[ordered[end]]!) {
        end += 1
      }
      for index in group ..< end {
        peerLo[index] = group
        peerHi[index] = end - 1
      }
      group = end
    }

    // Evaluate each source row's `FILTER` and argument once, up front, before
    // folding the individual frames. Explicit frames overlap between output rows
    // (a running `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` contains the
    // first row in every frame), so re-evaluating a row per frame would call a
    // stateful or non-deterministic argument (`SUM(tick())`) once per frame
    // rather than once per input row. The per-row `FILTER` result and argument
    // are computed here in window order; the frames below fold these values.
    var admitted = Array(repeating: true, count: count)
    var arguments = Array(repeating: Value.integer(0), count: count)
    for slot in 0 ..< count {
      let position = ordered[slot]
      // The `FILTER (WHERE …)` gates the row before the fold (and before the
      // DISTINCT dedup), as the running path gates: only a definite TRUE admits.
      if let filter = aggregation.filter {
        admitted[slot] = try evaluate(records[position], filter, context)
            == true
      }
      // Evaluate the argument only for an admitted row — a rejected row's
      // argument is never folded, so `SUM(1 / 0) FILTER (WHERE 1 = 0)` skips the
      // throwing argument and folds nothing, exactly as the running and grouped
      // paths do. `COUNT(*)` folds a non-NULL sentinel and has no argument.
      if admitted[slot], let argument = aggregation.argument {
        arguments[slot] = try evaluate(records[position], argument, context)
      }
    }
    // A cumulative frame — one starting at UNBOUNDED PRECEDING — has a lower
    // bound fixed at 0 and an upper bound that never decreases as the row
    // advances (`CURRENT ROW`, an `n PRECEDING`/`FOLLOWING` end, or the peer
    // group of a `RANGE CURRENT ROW`), so no row ever leaves the frame. One
    // running accumulator then folds each row a single time as the end advances,
    // linear in the partition — not the quadratic refold a fresh accumulator per
    // row performs (1 + … + n folds). Peers of a `RANGE` end share the value:
    // the end does not advance across a tie, so a peer folds nothing and reads
    // the running total the first of its group already reached.
    if case .unboundedPreceding = frame.start {
      var accumulator = Accumulator(aggregation.function,
                                    distinct: aggregation.distinct)
      var folded = 0
      for index in 0 ..< count {
        let high = bound(frame.end, at: index, frame.unit, start: false,
                         peerLo, peerHi, count)
        let hi = min(count - 1, high)
        while folded <= hi {
          if admitted[folded] { try accumulator.fold(arguments[folded]) }
          folded += 1
        }
        values[ordered[index]] = try accumulator.value
      }
      return
    }
    // A reverse-cumulative frame — one ending at UNBOUNDED FOLLOWING — is the
    // mirror: its upper bound is fixed at the last row and its lower bound never
    // decreases, so no row ever leaves the frame from the right. Fold it with one
    // running accumulator in reverse (last row to first), each row folded once as
    // the lower bound retreats — linear, not the quadratic refold. Peers of a
    // `RANGE` start share the value, as the forward path's end peers do.
    if case .unboundedFollowing = frame.end {
      var accumulator = Accumulator(aggregation.function,
                                    distinct: aggregation.distinct)
      var folded = count
      for index in (0 ..< count).reversed() {
        let low = bound(frame.start, at: index, frame.unit, start: true,
                        peerLo, peerHi, count)
        let lo = max(0, low)
        while folded > lo {
          folded -= 1
          if admitted[folded] { try accumulator.fold(arguments[folded]) }
        }
        values[ordered[index]] = try accumulator.value
      }
      return
    }
    // A sliding frame's lower bound moves, so a row can leave the frame — which
    // a running `SUM` could reverse but `MIN`/`MAX` cannot — so each row folds
    // its own slice afresh.
    for index in 0 ..< count {
      let low = bound(frame.start, at: index, frame.unit, start: true,
                      peerLo, peerHi, count)
      let high = bound(frame.end, at: index, frame.unit, start: false,
                       peerLo, peerHi, count)
      let lo = max(0, low)
      let hi = min(count - 1, high)
      var accumulator = Accumulator(aggregation.function,
                                    distinct: aggregation.distinct)
      if lo <= hi {
        for slot in lo ... hi where admitted[slot] {
          try accumulator.fold(arguments[slot])
        }
      }
      values[ordered[index]] = try accumulator.value
    }
  }

  /// Reads an offset function's `value` at the row `offset` positions along the
  /// window order from each row (`LEAD` a positive `offset`, `LAG` a negative
  /// one), writing into `values` at the record's original position. `ordered`
  /// is the partition in window order.
  ///
  /// When the offset row falls outside the partition — off the end for `LEAD`,
  /// before the start for `LAG` — the `default` term evaluated at the current
  /// row is written, or `NULL` when no default is given. The `value` (and the
  /// default) is a source-space `Term`, so it is evaluated against the target
  /// (or current) record exactly as a projection term is.
  private borrowing func position(_ value: Term, by offset: Int,
                                  default fallback: Term?,
                                  over ordered: Array<Int>,
                                  in records: Array<Record>,
                                  _ context: Context,
                                  into values: inout Array<Value>)
      throws(SQLError) {
    let count = ordered.count
    // Materialise each source row's value once, in window order, before shifting
    // by the offset — so a stateful or non-deterministic value (`LEAD(tick())`)
    // is evaluated one time per input row (as the other positional windows now
    // do), not once per row that some output shifts onto. `LEAD`/`LAG` then read
    // the target row's materialised value.
    var evaluated = Array<Value>()
    evaluated.reserveCapacity(count)
    for slot in 0 ..< count {
      try evaluated.append(evaluate(records[ordered[slot]], value, context))
    }
    for index in 0 ..< count {
      // A large parsed offset (`LEAD(x, 9223372036854775807)`) would overflow
      // `index + offset`; the sum overflowing means the target is off the end
      // of the partition, so treat it as out of bounds and fall to the default.
      let (target, overflow) = index.addingReportingOverflow(offset)
      if !overflow, target >= 0, target < count {
        values[ordered[index]] = evaluated[target]
      } else if let fallback {
        values[ordered[index]] =
            try evaluate(records[ordered[index]], fallback, context)
      } else {
        values[ordered[index]] = .null
      }
    }
  }

  /// Assigns `function`'s value to each record of an already-ordered partition,
  /// writing into `values` at the record's original position. `keyed` holds each
  /// record's window `ORDER BY` values, so the peer-aware ranks detect ties.
  ///
  /// - `ROW_NUMBER` — the 1-based sequential position, distinct for every row
  ///   even where the order keys tie.
  /// - `RANK` — peer rows (equal on every order key) share a rank, and the next
  ///   distinct row takes the rank one past every peer already seen, so ranks
  ///   skip after a tie.
  /// - `DENSE_RANK` — like `RANK`, but the next distinct row after a tie takes
  ///   the immediately following rank, leaving no gap.
  ///
  /// With no `ORDER BY` every row is a peer, so `RANK`/`DENSE_RANK` are `1`
  /// throughout while `ROW_NUMBER` still numbers each row.
  private borrowing func assign(_ function: Windowing.Function,
                                over ordered: Array<Int>,
                                _ keyed: Dictionary<Int, Array<Value>>,
                                into values: inout Array<Value>) {
    // Only a ranking function is ranked here: an aggregate window is folded by
    // `accumulate`/`framed` and an offset function read by `position`, so
    // `computed` dispatches those elsewhere and neither reaches this ranker.
    switch function {
    case .aggregate, .lead, .lag:
      preconditionFailure("a non-ranking window is computed, not ranked")
    case .rowNumber, .rank, .denseRank:
      break
    }
    if case .rowNumber = function {
      for position in ordered.indices {
        values[ordered[position]] = .integer(position + 1)
      }
      return
    }
    // `RANK`/`DENSE_RANK`: walk the ordered rows, opening a new rank only at a
    // non-peer boundary. `count` is the 1-based position (the rank `RANK` takes
    // at a boundary, so it skips over the peers just closed); `rank` is the last
    // assigned rank (incremented by one for `DENSE_RANK`, leaving no gap).
    var rank = 0
    var count = 0
    for position in ordered.indices {
      count += 1
      let row = ordered[position]
      let peer = position > 0
          && peers(keyed[ordered[position - 1]]!, keyed[row]!)
      if !peer {
        rank = function == .rank ? count : rank + 1
      }
      values[row] = .integer(rank)
    }
  }
}

/// Resolves a frame `bound` to an index into the ordered partition, for the row
/// at ordered position `index`. `start` distinguishes the lower bound from the
/// upper (it governs only which peer-group edge a `RANGE` `CURRENT ROW` takes);
/// `peerLo`/`peerHi` hold each position's peer-group bounds and `count` the
/// partition size.
///
/// A returned index may fall outside `0 ..< count` (an offset running off the
/// partition, or a partition-edge bound) — the caller clamps it and treats a
/// crossed pair as an empty frame. `RANGE` reaches here only with a non-offset
/// bound (a numeric `RANGE` offset is rejected at compile), so a `preceding`/
/// `following` bound is always a `ROWS` physical offset.
private func bound(_ bound: Frame.Bound, at index: Int, _ unit: Frame.Unit,
                   start: Bool, _ peerLo: Array<Int>, _ peerHi: Array<Int>,
                   _ count: Int) -> Int {
  // A zero offset is the current row, so it reads the peer group under `RANGE`
  // (the current row under `ROWS`) rather than a physical offset of `index`.
  switch bound.normalized {
  case .unboundedPreceding:
    return 0
  case .unboundedFollowing:
    return count - 1
  case .currentRow:
    if case .range = unit { return start ? peerLo[index] : peerHi[index] }
    return index
  case let .preceding(offset):
    // A large parsed offset (`n PRECEDING` near `Int.max`) must place the bound
    // before the partition, not overflow `index - offset`; on overflow saturate
    // past the edge the offset runs toward, which the caller clamps to `[0,
    // count)`.
    let (low, overflow) = index.subtractingReportingOverflow(offset)
    return overflow ? (offset < 0 ? Int.max : Int.min) : low
  case let .following(offset):
    // As `preceding`: a large `n FOLLOWING` offset saturates past the end
    // rather than trapping on `index + offset`.
    let (high, overflow) = index.addingReportingOverflow(offset)
    return overflow ? (offset < 0 ? Int.min : Int.max) : high
  }
}

/// Whether two records are peers of a window `ORDER BY` — equal on every order
/// key by the engine's typed comparison (neither orders before the other), the
/// same tie the ordering falls through on. Two rows with no order keys (an
/// unordered window) are trivially peers.
private func peers(_ left: Array<Value>, _ right: Array<Value>) -> Bool {
  for index in left.indices {
    if less(left[index], right[index]) || less(right[index], left[index]) {
      return false
    }
  }
  return true
}
