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
      let ordered = try ordered(partition, records, windowing.order, context)
      try assign(windowing.function, over: ordered, into: &values)
    }
    return values
  }

  /// The `indices` of one partition ordered by the window `ORDER BY` keys, major
  /// to minor, stably (ties keep their original order) — the row order the
  /// ranking reads. With no `ORDER BY` every row is a peer and the partition's
  /// original order is kept.
  ///
  /// Each key's `Term` is evaluated against every record up front, so the
  /// comparator sorts on precomputed values (a scalar term may throw, which a
  /// `sorted(by:)` comparator cannot) — mirroring the query-level `sorted`.
  private borrowing func ordered(_ indices: Array<Int>,
                                 _ records: Array<Record>,
                                 _ keys: Array<SortKey>,
                                 _ context: Context)
      throws(SQLError) -> Array<Int> {
    var sortable = Dictionary<Int, Array<Value>>(minimumCapacity: indices.count)
    for position in indices {
      var cells = Array<Value>()
      cells.reserveCapacity(keys.count)
      for key in keys {
        try cells.append(evaluate(records[position], key.term, context))
      }
      sortable[position] = cells
    }
    return indices.sorted { lhs, rhs in
      let left = sortable[lhs]!
      let right = sortable[rhs]!
      for index in keys.indices {
        let ordered = less(left[index], right[index])
        let reverse = less(right[index], left[index])
        if ordered == reverse { continue }
        return keys[index].ascending ? ordered : reverse
      }
      // Equal on every key: keep the source order (a stable order) by
      // tie-breaking on the original index.
      return lhs < rhs
    }
  }

  /// Assigns `function`'s value to each record of an already-ordered partition,
  /// writing into `values` at the record's original position.
  ///
  /// `ROW_NUMBER` is the 1-based sequential position — distinct for every row,
  /// even where the order keys tie.
  private borrowing func assign(_ function: WindowFunction,
                                over ordered: Array<Int>,
                                into values: inout Array<Value>)
      throws(SQLError) {
    switch function {
    case .rowNumber:
      for position in ordered.indices {
        values[ordered[position]] = .integer(position + 1)
      }
    case .rank, .denseRank:
      // The peer-aware ranking functions are gated unsupported at compile until
      // their executor lands, so a plan reaching here is an internal
      // inconsistency.
      throw .state("XX000", "\(function.keyword) is not yet executable")
    }
  }
}
