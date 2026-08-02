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
      assign(windowing.function, over: ordered, keyed, into: &values)
    }
    return values
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
  private borrowing func assign(_ function: WindowFunction,
                                over ordered: Array<Int>,
                                _ keyed: Dictionary<Int, Array<Value>>,
                                into values: inout Array<Value>) {
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
