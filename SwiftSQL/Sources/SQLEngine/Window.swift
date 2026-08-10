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
      case .number, .rank, .dense:
        assign(windowing.function, over: ordered, keyed, into: &values)
      case .ntile, .percent, .cumulative:
        distribute(windowing.function, over: ordered, keyed, into: &values)
      case let .aggregate(aggregation):
        if let frame = windowing.frame {
          try framed(aggregation, over: ordered, keyed, windowing.order,
                     in: records, context, frame: frame, into: &values)
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
      case let .first(value):
        try extremum(value, at: .first, over: ordered, keyed, windowing.order,
                     frame: windowing.frame, in: records, context,
                     into: &values)
      case let .last(value):
        try extremum(value, at: .last, over: ordered, keyed, windowing.order,
                     frame: windowing.frame, in: records, context,
                     into: &values)
      case let .nth(value, position):
        try extremum(value, at: .nth(position), over: ordered, keyed,
                     windowing.order, frame: windowing.frame, in: records,
                     context, into: &values)
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
                                _ order: Array<SortKey>,
                                in records: Array<Record>,
                                _ context: Context,
                                frame: Frame,
                                into values: inout Array<Value>)
      throws(SQLError) {
    let count = ordered.count
    let framing = framing(over: ordered, keyed, order, frame: frame)
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
    if case .head = frame.start {
      var accumulator = Accumulator(aggregation.function,
                                    distinct: aggregation.distinct)
      var folded = 0
      for index in 0 ..< count {
        let high = bound(frame.end, at: index, frame.unit, start: false,
                         framing)
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
    if case .tail = frame.end {
      var accumulator = Accumulator(aggregation.function,
                                    distinct: aggregation.distinct)
      var folded = count
      for index in (0 ..< count).reversed() {
        let low = bound(frame.start, at: index, frame.unit, start: true,
                        framing)
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
      let low = bound(frame.start, at: index, frame.unit, start: true, framing)
      let high = bound(frame.end, at: index, frame.unit, start: false, framing)
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

  /// Reads a frame-sensitive positional function's `value` at a chosen row of
  /// each row's frame, writing into `values` at the record's original position.
  /// `ordered` is the partition in window order, `keyed` each record's window
  /// `ORDER BY` values (so a `RANGE`/default frame finds a row's peer group).
  ///
  /// `FIRST_VALUE` reads the frame's first row, `LAST_VALUE` its last, and
  /// `NTH_VALUE` its 1-based `n`-th row (`NULL` when the frame holds fewer than
  /// `n` rows). The frame is the explicit `frame`, or — when none is written —
  /// the window default (`RANGE UNBOUNDED PRECEDING` through the current peer
  /// group), so a default-framed `LAST_VALUE` reads the current peer group's
  /// end (the current row with distinct order keys), the classic gotcha.
  private borrowing func extremum(_ value: Term, at position: Position,
                                  over ordered: Array<Int>,
                                  _ keyed: Dictionary<Int, Array<Value>>,
                                  _ order: Array<SortKey>,
                                  frame: Frame?,
                                  in records: Array<Record>,
                                  _ context: Context,
                                  into values: inout Array<Value>)
      throws(SQLError) {
    let count = ordered.count
    // The default frame is `RANGE UNBOUNDED PRECEDING AND CURRENT ROW` — the
    // partition start through the current peer group — the frame the value
    // functions read over when none is written. Resolve it before building the
    // framing so the geometry is built for the frame actually read.
    let frame = frame ?? Frame(unit: .range, start: .head,
                               end: .current)
    let framing = framing(over: ordered, keyed, order, frame: frame)
    // Evaluate each source row's value once, before selecting frame positions.
    // Several output rows may select the same target — `FIRST_VALUE` returns the
    // partition's first value throughout — so reading a materialised value keeps
    // a stateful or non-deterministic value (`FIRST_VALUE(tick())`) evaluated
    // one time per input row rather than once per output that reads it.
    var evaluated = Array<Value>()
    evaluated.reserveCapacity(count)
    for slot in 0 ..< count {
      try evaluated.append(evaluate(records[ordered[slot]], value, context))
    }
    for index in 0 ..< count {
      let low = bound(frame.start, at: index, frame.unit, start: true, framing)
      let high = bound(frame.end, at: index, frame.unit, start: false, framing)
      let lo = max(0, low)
      let hi = min(count - 1, high)
      // The chosen row's index into `ordered`, or `nil` when the frame is empty
      // or holds fewer than `n` rows (`NTH_VALUE`).
      let target: Int? = if lo > hi {
        nil
      } else {
        switch position {
        case .first: lo
        case .last: hi
        // Compare the 1-based offset against the frame width rather than adding
        // it to `lo`, so a large parsed position (`NTH_VALUE(x,
        // 9223372036854775807)`) decides it is past the frame (NULL) without
        // `lo + n - 1` overflowing. Both sides here are small, and `lo + n - 1`
        // is formed only once it is known to land within `[lo, hi]`.
        case let .nth(n): n - 1 > hi - lo ? nil : lo + n - 1
        }
      }
      values[ordered[index]] = target.map { evaluated[$0] } ?? .null
    }
  }

  /// Assigns a distribution function's value to each record of an
  /// already-ordered partition, writing into `values` at the record's original
  /// position. `keyed` holds each record's window `ORDER BY` values, so the
  /// peer groups (`PERCENT_RANK`, `CUME_DIST`) are found by tie.
  ///
  /// - `NTILE(n)` — the ordered partition is split into `n` contiguous buckets
  ///   as equally as possible: with `rows = q * n + r`, the first `r` buckets
  ///   hold `q + 1` rows and the rest `q`, and each row takes its 1-based
  ///   bucket number (more buckets than rows leaves the trailing ones empty).
  /// - `PERCENT_RANK` — `(rank - 1) / (rows - 1)`, where `rank` is the peer
  ///   group's 1-based start position; a single-row partition is `0`.
  /// - `CUME_DIST` — `rows through the current peer group / rows`, so peers
  ///   share the value and the last peer group is `1`.
  private borrowing func distribute(_ function: Windowing.Function,
                                    over ordered: Array<Int>,
                                    _ keyed: Dictionary<Int, Array<Value>>,
                                    into values: inout Array<Value>) {
    let count = ordered.count
    switch function {
    case let .ntile(buckets):
      // `q` rows per bucket, the first `r` buckets one larger; the large
      // buckets fill the first `r * (q + 1)` positions, the rest follow.
      let quotient = count / buckets
      let remainder = count % buckets
      let large = remainder * (quotient + 1)
      for position in 0 ..< count {
        let bucket = position < large
            ? position / (quotient + 1) + 1
            : remainder + (position - large) / quotient + 1
        values[ordered[position]] = .integer(bucket)
      }
    case .percent:
      let (peerLo, _) = peering(ordered, keyed)
      for position in 0 ..< count {
        values[ordered[position]] = count <= 1
            ? .double(0)
            : .double(Double(peerLo[position]) / Double(count - 1))
      }
    case .cumulative:
      let (_, peerHi) = peering(ordered, keyed)
      for position in 0 ..< count {
        values[ordered[position]] =
            .double(Double(peerHi[position] + 1) / Double(count))
      }
    default:
      // A ranking, aggregate, or positional window is computed elsewhere and
      // never dispatched here.
      preconditionFailure("a non-distribution window is not distributed")
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
    case .aggregate, .lead, .lag, .first, .last, .nth,
         .ntile, .percent, .cumulative:
      preconditionFailure("a non-ranking window is computed, not ranked")
    case .number, .rank, .dense:
      break
    }
    if case .number = function {
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
/// upper (it governs which peer-group/band edge and which group row a bound
/// takes); `framing` holds the partition's peer-group and (for a numeric-offset
/// `RANGE` frame) order-key value geometry.
///
/// A returned index may fall outside `0 ..< count` (an offset running off the
/// partition, or a partition-edge bound) — the caller clamps it and treats a
/// crossed pair as an empty frame. A `ROWS` `preceding`/`following` bound is a
/// physical offset from `index`; a `GROUPS` one counts peer groups; a `RANGE`
/// one bands the order-key value.
private func bound(_ bound: Frame.Bound, at index: Int, _ unit: Frame.Unit,
                   start: Bool, _ framing: Framing) -> Int {
  // A zero offset is the current row, so it reads the peer group under `RANGE`/
  // `GROUPS` (the current row under `ROWS`) rather than an offset of `index`.
  switch bound.normalized {
  case .head:
    return 0
  case .tail:
    return framing.count - 1
  case .current:
    switch unit {
    case .rows:
      return index
    case .range, .groups:
      // A RANGE/GROUPS current row frames the whole current peer group.
      return framing.peer(index, start: start)
    }
  case let .preceding(offset):
    switch unit {
    case .rows:
      // A large parsed offset (`n PRECEDING` near `Int.max`) must place the
      // bound before the partition, not overflow `index - offset`; on overflow
      // saturate past the edge the offset runs toward, which the caller clamps.
      let (low, overflow) = index.subtractingReportingOverflow(offset)
      return overflow ? (offset < 0 ? Int.max : Int.min) : low
    case .groups:
      return framing.group(index, by: offset, following: false, start: start)
    case .range:
      return framing.value(index, by: offset, following: false, start: start)
    }
  case let .following(offset):
    switch unit {
    case .rows:
      // As `preceding`: a large `n FOLLOWING` offset saturates past the end
      // rather than trapping on `index + offset`.
      let (high, overflow) = index.addingReportingOverflow(offset)
      return overflow ? (offset < 0 ? Int.min : Int.max) : high
    case .groups:
      return framing.group(index, by: offset, following: true, start: start)
    case .range:
      return framing.value(index, by: offset, following: true, start: start)
    }
  }
}

/// The peer-group and order-key geometry of an ordered partition, resolving a
/// `GROUPS` or numeric-offset `RANGE` frame's bounds to row indices.
///
/// `low`/`high` bound each position's peer group (the rows tied on the window
/// `ORDER BY`); `group` numbers each position's 0-based peer group and
/// `starts`/`ends` bound each group by number, so a `GROUPS` bound steps a
/// whole number of groups in `O(1)`. `keys` holds each position's single
/// order-key value in window order (populated only for a lone order key — the
/// shape a numeric-offset `RANGE` frame requires), and `ascending` its
/// direction, so a `RANGE` bound bands the value in the key's own order.
/// `present` is the contiguous index span of `keys`' non-`NULL` values —
/// precomputed once so a `RANGE` bound binary-searches the band edge in
/// `O(log n)` rather than scanning the whole partition per row.
///
/// Each geometry is filled by `framing` only when the frame's unit and bounds
/// consult it — `low`/`high` for a non-`ROWS` frame, `group`/`starts`/`ends`
/// for a `GROUPS` frame, `keys`/`present` for a numeric-offset `RANGE` frame
/// over a lone order key — and is left empty otherwise. `bound` reaches each
/// accessor (`peer`, `group`, `value`) only under its own unit's case, so an
/// empty array is never indexed. `count` and `ascending` are always set.
private struct Framing {
  let count: Int
  let low: Array<Int>
  let high: Array<Int>
  let group: Array<Int>
  let starts: Array<Int>
  let ends: Array<Int>
  let keys: Array<Value>
  let present: Range<Int>
  let ascending: Bool

  /// The current peer group's edge for the row at `index` — its group start (a
  /// lower bound) or end (an upper bound). A `RANGE`/`GROUPS` `CURRENT ROW`
  /// frames the whole current peer group.
  func peer(_ index: Int, start: Bool) -> Int {
    start ? low[index] : high[index]
  }

  /// The ordered index bounding a `GROUPS` frame `offset` peer groups before
  /// (`following == false`) or after the row at `index`'s group. A `start`
  /// bound takes the target group's first row, an end bound its last. A target
  /// past the partition runs the bound off that edge: a preceding start /
  /// following end clamps to the partition, and a following start / preceding
  /// end returns past the far edge so the caller reads an empty frame.
  func group(_ index: Int, by offset: Int, following: Bool, start: Bool)
      -> Int {
    let (target, overflow) =
        group[index].addingReportingOverflow(following ? offset : -offset)
    let last = starts.count - 1
    if start {
      if overflow { return following ? count : 0 }
      if target < 0 { return 0 }
      if target > last { return count }
      return starts[target]
    }
    if overflow { return following ? count - 1 : -1 }
    if target < 0 { return -1 }
    if target > last { return count - 1 }
    return ends[target]
  }

  /// The ordered index bounding a numeric-offset `RANGE` frame for the row at
  /// `index`: the band edge `offset` value units before (`following == false`)
  /// or after the current order-key value, found in the key's sort order. A
  /// `start` bound is the first row at or after the lower edge, an end bound
  /// the last at or before the upper edge. An edge off the present span
  /// resolves to that span's boundary, not the partition's: a `NULL` run sits
  /// at one physical end of window order — the low indices adjacent to the
  /// partition start (`UNBOUNDED PRECEDING`), the high indices adjacent to its
  /// end (`UNBOUNDED FOLLOWING`) — and returning the present boundary keeps a
  /// `NULL` run lying on an unbounded edge in the frame. The frame's
  /// intersection with the other bound then self-gates those `NULL`s: a
  /// value-bounded other edge excludes them, an unbounded one includes them, so
  /// `value` need not know the other bound. A `NULL` order key is a peer of
  /// every other `NULL` and comparable to no value, so its own frame is exactly
  /// its peer group.
  ///
  /// The present keys fill `present` non-decreasing under `precedes`, so each
  /// edge is a monotonic threshold binary-searched in `O(log n)` — restoring
  /// the linear cumulative frame rather than rescanning the partition per row.
  func value(_ index: Int, by offset: Int, following: Bool, start: Bool)
      -> Int {
    let current = keys[index]
    if case .null = current { return peer(index, start: start) }
    // Preceding steps toward the partition start — a smaller value under `ASC`,
    // a larger one under `DESC` — and following the reverse, so the sort
    // direction and the bound direction fold into whether the edge adds the
    // offset.
    let add = following == ascending
    let (target, overflow) = shift(current, by: offset, add: add)
    var lo = present.lowerBound
    var hi = present.upperBound
    if overflow {
      // The shifted edge ran past `Int`'s range, so it lies numerically beyond
      // every integer key — above all on an add-overflow, below all on a
      // subtract-overflow. It is the extreme of the band scan, so resolve it to
      // the present boundary the scan would reach for a target infinitely far
      // on that side. `late` is whether the target sits past the high-index
      // (late) end of window order, which an add-overflow reaches only under
      // `ASC` and a subtract under `DESC`; the shared return then keeps a
      // `NULL` run adjacent to that unbounded edge in the frame.
      let late = add == ascending
      lo = late ? present.upperBound : present.lowerBound
    } else if start {
      // The first present key at or after the lower edge. `precedes(key,
      // target)` falls true→false across `present`, so lower-bound the first
      // key that no longer precedes `target` — the first of a tie run on it.
      // None banding at or after the edge lands on `present.upperBound`, the
      // first high `NULL` index (or `count`), keeping a trailing `NULL` run.
      while lo < hi {
        let mid = lo + (hi - lo) / 2
        if precedes(keys[mid], target) { lo = mid + 1 } else { hi = mid }
      }
    } else {
      // The last present key at or before the upper edge. `precedes(target,
      // key)` rises false→true across `present`, so find the first key
      // `target` precedes and step back — the last of a tie run on `target`.
      // None banding at or before the edge lands on `present.lowerBound`, whose
      // `lo - 1` is the last low `NULL` index (or `-1`), keeping a leading
      // `NULL` run.
      while lo < hi {
        let mid = lo + (hi - lo) / 2
        if precedes(target, keys[mid]) { hi = mid } else { lo = mid + 1 }
      }
    }
    // One shared edge: a `start` bound is `lo` itself, an end bound the row
    // before it. Off-present edges resolved to a present boundary above, so a
    // `NULL` run on an unbounded side is retained; the other bound's
    // intersection self-gates whether those `NULL`s fall in the frame.
    return start ? lo : lo - 1
  }

  /// Whether `left` sorts before `right` in the single order key's direction —
  /// the comparison the partition is ordered by, so its keys are non-decreasing
  /// under it and a `NULL` sorts to one end.
  private func precedes(_ left: Value, _ right: Value) -> Bool {
    ascending ? less(left, right) : less(right, left)
  }
}

/// Whether `value` is a non-`NULL` order key — one a numeric band compares
/// against (a `NULL` bands with no value).
private func present(_ value: Value) -> Bool {
  if case .null = value { false } else { true }
}

/// The contiguous index span of `keys`' present (non-`NULL`) values — the range
/// a numeric-offset `RANGE` bound binary-searches. A single order key sorts the
/// `NULL`s to one end, so the present keys fill one span: the first present
/// index up to one past the last. Empty when every key is `NULL` or `keys` is.
private func span(_ keys: Array<Value>) -> Range<Int> {
  var first = keys.startIndex
  while first < keys.endIndex, !present(keys[first]) { first += 1 }
  var last = keys.endIndex - 1
  while last >= first, !present(keys[last]) { last -= 1 }
  return first ..< (last + 1)
}

/// `value` moved `offset` numeric units up (`add`) or down — the band edge of a
/// numeric-offset `RANGE` frame — paired with whether the shift overflowed. The
/// reject gate proved the order key numeric, so an integer key shifts in `Int`
/// and a double key in `Double`. An integer shift past `Int`'s range reports
/// the overflow so `value` resolves the edge off the partition rather than
/// banding against the saturated key, which would draw that extreme key's peer
/// group into the frame; a double shift cannot overflow.
private func shift(_ value: Value, by offset: Int, add: Bool)
    -> (Value, Bool) {
  switch value {
  case let .integer(magnitude):
    let (moved, overflow) = add ? magnitude.addingReportingOverflow(offset)
                                : magnitude.subtractingReportingOverflow(offset)
    return (.integer(overflow ? (add ? .max : .min) : moved), overflow)
  case let .double(magnitude):
    return (.double(add ? magnitude + Double(offset)
                        : magnitude - Double(offset)), false)
  default:
    return (value, false)
  }
}

/// The `Framing` of `ordered` under `order` for `frame` — built to only the
/// geometry `frame`'s unit and bounds resolve against, so a plain `ROWS` frame
/// allocates none of it. A non-`ROWS` frame's `CURRENT ROW` peer bounds
/// (`low`/`high`) come from a single peer scan (`peering`); a `GROUPS` frame's
/// group-number navigation (`group`/`starts`/`ends`) folds from those peer
/// bounds; a numeric-offset `RANGE` frame over a lone order key materialises
/// each position's key value in window order with its direction and the
/// contiguous non-`NULL` span (`span`) a band binary-searches. Every geometry
/// a `frame`'s unit does not consult is left empty — `bound` reaches each
/// `Framing` accessor only under its own unit, so an empty array is never read.
private func framing(over ordered: Array<Int>,
                     _ keyed: Dictionary<Int, Array<Value>>,
                     _ order: Array<SortKey>, frame: Frame) -> Framing {
  let count = ordered.count
  // A `RANGE`/`GROUPS` `CURRENT ROW` bound frames the whole current peer group,
  // so only a non-`ROWS` frame needs the peer bounds; a `ROWS` frame is a
  // physical offset and `bound` reads neither `low` nor `high` for it.
  var low = Array<Int>()
  var high = Array<Int>()
  if frame.unit != .rows {
    (low, high) = peering(ordered, keyed)
  }
  // A GROUPS frame steps whole peer groups, so — only then — number the
  // positions and record each group's `[start, end]` span from the peer bounds;
  // a new peer group opens where a position is its own group's low.
  var group = Array<Int>()
  var starts = Array<Int>()
  var ends = Array<Int>()
  if frame.unit == .groups {
    group = Array(repeating: 0, count: count)
    var number = -1
    for index in 0 ..< count {
      if low[index] == index {
        number += 1
        starts.append(index)
        ends.append(high[index])
      }
      group[index] = number
    }
  }
  // A numeric-offset RANGE frame over a single order key bands that key's
  // value; materialise its per-position value only then (a GROUPS frame reads
  // the peer groups instead, a ROWS or unmeasured RANGE frame reads neither),
  // and bound its non-NULL span once so `value` binary-searches the band edge.
  var keys = Array<Value>()
  if frame.unit == .range, frame.measured, order.count == 1 {
    keys.reserveCapacity(count)
    for position in ordered { keys.append(keyed[position]![0]) }
  }
  return Framing(count: count, low: low, high: high, group: group,
                 starts: starts, ends: ends, keys: keys, present: span(keys),
                 ascending: order.first?.ascending ?? true)
}

/// Which row of the frame a positional value function reads.
private enum Position {
  /// `FIRST_VALUE` — the frame's first row.
  case first
  /// `LAST_VALUE` — the frame's last row.
  case last
  /// `NTH_VALUE` — the frame's 1-based `n`-th row.
  case nth(Int)
}

/// Each ordered position's peer-group bounds — for the row at position `p`, the
/// `[low[p], high[p]]` index range of the maximal contiguous run of rows tied
/// on the window `ORDER BY` (with no order keys the whole partition). The
/// partition is already sorted, so a peer group is contiguous and a single
/// forward scan bounds every position — used for the `RANGE`/default frame's
/// `CURRENT ROW` bound.
private func peering(_ ordered: Array<Int>,
                     _ keyed: Dictionary<Int, Array<Value>>)
    -> (low: Array<Int>, high: Array<Int>) {
  let count = ordered.count
  var low = Array(repeating: 0, count: count)
  var high = Array(repeating: 0, count: count)
  var group = 0
  while group < count {
    var end = group + 1
    while end < count, peers(keyed[ordered[end - 1]]!, keyed[ordered[end]]!) {
      end += 1
    }
    for index in group ..< end {
      low[index] = group
      high[index] = end - 1
    }
    group = end
  }
  return (low, high)
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
