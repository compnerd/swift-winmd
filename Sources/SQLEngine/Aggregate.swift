// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Aggregation — grouping a relation and folding aggregate functions over each
/// group.
///
/// An aggregate query groups its filtered rows by the `GROUP BY` columns (or
/// treats the whole result as one group when there is none) and folds a
/// `COUNT`/`SUM`/`MIN`/`MAX`/`AVG` accumulator over every row of a group. Unlike
/// a scalar function — evaluated per row through the `Routines` — an aggregate
/// accumulates over a group, so it is a separate mechanism the engine
/// recognises by name at parse time and lowers to an `Aggregation` here, never
/// routed through `Function.swift`.
///
/// The `Aggregate` node yields one grouped `Record` per group whose slots are
/// the group-key values (slots `0 ..< keys.count`, in key order) followed by the
/// aggregate results (slot `keys.count + j` is aggregate `j`), the slot space
/// the projection, the `HAVING`, and the `ORDER BY` are lowered against.

/// A lowered aggregate — the ordinal-addressed form of an AST `Expression`'s
/// `.aggregate`, ready for the executor to fold over a group.
///
/// The `function` is the standard aggregate; `argument` is the term evaluated
/// per source record whose non-NULL values the aggregate folds, or `nil` for
/// `COUNT(*)`, which counts rows without reading any value. The argument is in
/// the SOURCE's slot space (the WHERE/join chain below the aggregate), evaluated
/// against each source record before the fold; the result lands in the grouped
/// record.
///
/// Two aggregations are EQUAL when they fold the same function over the same
/// resolved argument term — the RESOLVED form column qualification has already
/// normalized to a slot, so `SUM(Amount)` and `SUM(Sales.Amount)` in a
/// single-relation scope are one aggregation. Equality (not `Hashable`, since
/// `Term` is only `Equatable`) is how the grouped path DEDUPS the aggregates
/// collected from the projection, the `HAVING`, and the `ORDER BY` into one
/// grouped slot each, so a qualification-equivalent aggregate written in two
/// clauses computes once and both clauses order/read the same slot.
internal struct Aggregation: Equatable {
  /// The aggregate function to fold over the group.
  internal let function: Aggregate

  /// The term evaluated per source record and folded, or `nil` for `COUNT(*)`
  /// (which counts every row without reading a value).
  internal let argument: Term?

  /// Whether the aggregate folds each DISTINCT non-NULL value once (`COUNT`/
  /// `SUM`/`AVG(DISTINCT x)`) rather than every value — the ISO `DISTINCT` set
  /// quantifier. It has no effect on `MIN`/`MAX` (the extreme is the same with
  /// duplicates), which honour it as a no-op.
  internal let distinct: Bool

  /// The lowered per-row gate of an aggregate's `FILTER (WHERE …)`, or `nil`
  /// when none is written. A source record folds into the aggregate only when
  /// this filter evaluates TRUE (a FALSE or UNKNOWN row is skipped), applied
  /// BEFORE the `distinct` dedup.
  internal let filter: Filter?

  internal init(function: Aggregate, argument: Term?, distinct: Bool = false,
                filter: Filter? = nil) {
    self.function = function
    self.argument = argument
    self.distinct = distinct
    self.filter = filter
  }
}

extension Aggregation {
  /// This aggregation with its argument's and filter's slots remapped through
  /// `slot`.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Aggregation {
    Aggregation(function: function,
                argument: argument.map { $0.remapped(through: slot) },
                distinct: distinct,
                filter: filter.map { $0.remapped(through: slot) })
  }

  /// The source slots this aggregation reads, accumulated into `slots` — its
  /// argument's and its `FILTER` predicate's, or none for a `COUNT(*)` with no
  /// filter.
  internal func references(into slots: inout Set<Int>) {
    argument?.references(into: &slots)
    filter?.references(into: &slots)
  }
}

// MARK: - Accumulation

/// A running aggregate over the rows of a group — the fold's state.
///
/// One accumulator per aggregate per group folds each source record's argument
/// value in, then `value` reads off the result. `COUNT` counts rows (or non-NULL
/// values); `SUM`/`AVG` total the non-NULL numeric values — an all-integer
/// total stays an exact integer, any double operand widens the total to an
/// approximate double, and the widen/overflow choice is deferred to the end so
/// the result does not depend on row order — `AVG` then dividing by the non-NULL
/// count as real division to an approximate-numeric double; `MIN`/`MAX` keep
/// the least/greatest non-NULL value by the engine's typed `less`. Every
/// aggregate but `COUNT` IGNORES NULLs — a NULL argument does not fold — and an
/// empty or all-NULL group yields `COUNT` `0` and the others NULL.
private struct Accumulator {
  private let function: Aggregate
  // Whether to fold each DISTINCT non-NULL value once — the ISO `DISTINCT` set
  // quantifier — tracking the values already folded in `seen`. `MIN`/`MAX`
  // honour it as a no-op (an extreme is unchanged by duplicates), so the flag
  // is normalised OFF for them in `init`: the dedup — and the `seen` set it
  // grows — runs only for `COUNT`/`SUM`/`AVG`, where duplicate multiplicity
  // matters. This keeps a `MIN`/`MAX(DISTINCT x)` an O(1) STREAMING fold rather
  // than one whose memory grows with the group's distinct values for no
  // semantic gain (its result is the same as `MIN`/`MAX(x)` either way).
  private let distinct: Bool
  private var seen = Set<Value>()
  private var count = 0
  // SUM/AVG numeric state, kept independent of row order: an exact WIDE integer
  // total (`Int128`, range-checked once at the end) for the all-integer case,
  // and a parallel double total used once any operand is a double. A wide total
  // means a transient prefix overflow cannot latch a fault a later value undoes,
  // and the widen decision is deferred so a double anywhere widens the group.
  private var integer: Int128 = 0
  private var total = 0.0
  private var widened = false
  private var extreme: Value? = nil

  internal init(_ function: Aggregate, distinct: Bool = false) {
    self.function = function
    // `DISTINCT` is a no-op for `MIN`/`MAX` (an extreme is unchanged by
    // duplicates), so normalise it OFF for them: the fold never builds `seen`,
    // staying O(1) streaming rather than O(distinct-values) memory.
    self.distinct = distinct && function != .min && function != .max
  }

  /// Folds one source `value` into the running aggregate — for `COUNT(*)` the
  /// value is a sentinel `.integer` (a row is always counted); every other
  /// aggregate ignores a NULL.
  ///
  /// - Throws: `SQLError.operand` if `SUM`/`AVG` meets a non-numeric value, or
  ///   if `MIN`/`MAX` meets a value whose kind has no ordering against the one
  ///   already seen (a TEXT after an INTEGER). An integer overflow or a
  ///   non-finite double total is not raised here — the widen/overflow decision
  ///   is deferred to `value` so it is order-independent.
  internal mutating func fold(_ value: Value) throws(SQLError) {
    // Every aggregate but a row-count ignores NULL — a NULL argument does not
    // fold, so an all-NULL group aggregates as an empty one.
    if case .null = value { return }
    // A double operand widens the SUM/AVG total to an approximate double, and
    // the widen decision is order-independent: flag it from the CELL'S KIND
    // before the DISTINCT dedup, so a double anywhere in the group widens even
    // when it is a duplicate the dedup skips for summation. `1` and `1.0`
    // canonicalise equal, so a group mixing them dedups to one value whose kind
    // is whichever appeared first — but the double must still widen the sum
    // regardless of that order, else an integer-first group faults on an
    // integer total a double-first group widens to a finite double.
    if case .double = value, function == .sum || function == .avg {
      widened = true
    }
    // Under `DISTINCT` a value already folded does not fold again — deduped on
    // its CANONICAL form (the same normalisation a `GROUP BY` key and the
    // equality UNION use, so `1` and `1.0` count as one distinct value) — so a
    // repeated value counts, sums, and averages once. `MIN`/`MAX` normalise
    // `distinct` OFF (an extreme is unchanged by duplicates), so this never
    // builds `seen` for them. `COUNT(*)`'s row sentinel never reaches here (a
    // `COUNT(*)` carries no `distinct`), so every counted row still counts.
    if distinct, !seen.insert(canonical(value)).inserted { return }
    count += 1
    switch function {
    case .count, .min, .max:
      if function != .count {
        // Keep the least (`MIN`) or greatest (`MAX`) value by the engine's typed
        // comparison; the first non-NULL value seeds it, and a later value of an
        // unorderable kind is a type error, not an order-dependent keep.
        extreme = if let current = extreme {
          try keep(value, over: current)
        } else {
          value
        }
      }
    case .sum, .avg:
      // Total every value into a double running sum, while keeping an exact
      // wide (`Int128`) integer total for the all-integer case; `widened` was
      // already set above from the cell's kind. Deferring the widen decision —
      // and range-checking the wide total only at the end — keeps the result
      // independent of row order: neither a later double nor a transient prefix
      // overflow that a later value undoes can change the outcome.
      switch value {
      case let .integer(number):
        total += Double(number)
        integer += Int128(number)
      case let .double(number):
        total += number
      default:
        throw .operand("operands must be numeric")
      }
    }
  }

  /// The value MIN/MAX keeps between a `candidate` and the running `extreme` —
  /// the lesser for `MIN`, the greater for `MAX`, by the engine's typed `less`.
  ///
  /// - Throws: `SQLError.operand` if the two kinds have no ordering (a TEXT and
  ///   an INTEGER, say). `less` orders neither way for such a pair, so keeping
  ///   the first-seen value would make MIN/MAX depend on row order; a type error
  ///   is deterministic instead.
  private func keep(_ candidate: Value, over extreme: Value)
      throws(SQLError) -> Value {
    guard comparable(candidate, extreme) else {
      throw .operand("MIN and MAX require a common comparable kind")
    }
    return (function == .min ? less(candidate, extreme)
                             : less(extreme, candidate)) ? candidate : extreme
  }

  /// The aggregate's result once every row is folded.
  ///
  /// `COUNT` is the row/value count (`0` for an empty group); `SUM` the numeric
  /// total — an exact integer when every value folded was an integer, a double
  /// once any widened it (`NULL` when no value folded, an empty or all-NULL
  /// group); `AVG` the real quotient of the total over the non-NULL count as an
  /// approximate-numeric double (`NULL` when none); `MIN`/`MAX` the extreme
  /// value (`NULL` when none).
  ///
  /// - Throws: `SQLError.magnitude` if an all-integer `SUM` total does not fit
  ///   `Int` — the exact wide total is range-checked once, so only a truly
  ///   out-of-range total faults, never a transient prefix overflow a later
  ///   value undoes — or a `SUM`/`AVG` double result is not finite. `AVG`
  ///   divides the wide total, so an integer sum outside `Int` still averages.
  internal var value: Value {
    get throws(SQLError) {
      switch function {
      case .count:
        return .integer(count)
      case .sum:
        guard count != 0 else { return .null }
        if widened {
          guard total.isFinite else {
            throw .magnitude("double result is not finite")
          }
          return .double(total)
        }
        guard let sum = Int(exactly: integer) else {
          throw .magnitude("integer overflow")
        }
        return .integer(sum)
      case .avg:
        // AVG is real division of the numeric total over the non-NULL count,
        // yielding an approximate-numeric double — not truncating like the
        // engine's integer `/`. An empty or all-NULL group has no value, so AVG
        // is NULL. It divides the WIDE total (the exact Int128, or the double
        // total when a double widened it), so an all-integer sum outside Int
        // still averages rather than faulting like SUM's Int-bounded result.
        guard count != 0 else { return .null }
        let sum: Double = widened ? total : Double(integer)
        let average = sum / Double(count)
        guard average.isFinite else {
          throw .magnitude("double result is not finite")
        }
        return .double(average)
      case .min, .max:
        return extreme ?? .null
      }
    }
  }
}

/// Whether MIN/MAX can order two non-NULL values: the same kind, or both
/// numeric (integer/double, which `less` orders by magnitude). A cross-kind
/// non-numeric pair — TEXT vs INTEGER, BLOB vs BOOLEAN — has no ordering, so a
/// MIN/MAX over a column mixing them is a type error rather than a first-seen,
/// order-dependent result.
private func comparable(_ a: Value, _ b: Value) -> Bool {
  switch (a, b) {
  case (.integer, .integer), (.double, .double),
       (.integer, .double), (.double, .integer),
       (.text, .text), (.boolean, .boolean), (.blob, .blob):
    true
  default:
    false
  }
}

// MARK: - Execution

/// Groups `records` by the `keys` terms and folds each `aggregates` accumulator
/// over every record of a group, yielding one grouped record per group.
///
/// A grouped record's slots are the key values (slots `0 ..< keys.count`, in key
/// order) followed by the aggregate results (slot `keys.count + j` is
/// `aggregates[j]`). Groups are keyed on the EXACT canonical form of the
/// evaluated key values (`canonical` — so `1` and `1.0` fall in one group, the
/// equality UNION and predicates use), and each group emits its FIRST-appearance
/// original key values, in first-appearance order, so a later `ORDER BY`
/// re-sorts deterministically. With no `keys` the whole input
/// is ONE group — the degenerate whole-result aggregation (`SELECT COUNT(*) FROM
/// T`) — which yields a single grouped record even over an empty input (`COUNT`
/// `0`, the others NULL), the standard SQL rule.
///
/// The `bindings` thread through both the key and the argument evaluation — the
/// same bindings the projection and the `WHERE` filter resolve against — so a
/// `:parameter` reached from inside an aggregate's argument (a
/// `COUNT(CASE WHEN K = :k …)`) binds to its query value rather than reading as
/// UNBOUND. The key evaluation threads them for the same reason and to keep the
/// two evaluate sites consistent, though a `GROUP BY` key is a bare column
/// today, so it cannot yet reach one.
internal func grouped<C>(_ records: Array<Record>, _ keys: Array<Term>,
                         _ aggregates: Array<Aggregation>,
                         _ catalog: borrowing C, _ relations: ScopedRelations,
                         _ routines: Routines, _ bindings: Bindings,
                         _ subqueries: Subqueries)
    throws(SQLError) -> Array<Record> where C: Catalog & ~Escapable {
  var order = Array<Record>()
  var accumulators = Dictionary<Record, Array<Accumulator>>()

  for record in records {
    var cells = Array<Value>()
    cells.reserveCapacity(keys.count)
    for key in keys {
      try cells.append(record.evaluate(key, catalog, relations, routines,
                                       bindings, subqueries))
    }
    let group = Record(cells)
    // Key the group on the EXACT canonical form of its cells so `1` and `1.0`
    // fall in one group (the equality UNION and predicates use), while the
    // emitted group keeps the first-appearance ORIGINAL values.
    let identity = Record(cells.map(canonical))

    if accumulators[identity] == nil {
      accumulators[identity] = aggregates.map {
        Accumulator($0.function, distinct: $0.distinct)
      }
      order.append(group)
    }
    for index in aggregates.indices {
      // An aggregate's `FILTER (WHERE …)` gates the row: only a TRUE
      // predicate admits it (a FALSE or UNKNOWN one, and an unbound
      // `:parameter`, skips), applied before the fold — and so before the
      // DISTINCT dedup. A filter-less aggregate folds every row.
      if let filter = aggregates[index].filter {
        guard try record.evaluate(filter, catalog, relations, routines,
                                  bindings, subqueries) == true else {
          continue
        }
      }
      // `COUNT(*)` has no argument — count the row with a non-NULL sentinel;
      // every other aggregate folds its evaluated argument value.
      let value: Value = if let argument = aggregates[index].argument {
        try record.evaluate(argument, catalog, relations, routines, bindings,
                            subqueries)
      } else {
        .integer(0)
      }
      try accumulators[identity]![index].fold(value)
    }
  }

  // A whole-result aggregation with no matching row still yields one group —
  // the empty group — so the degenerate `SELECT COUNT(*) FROM T` over no rows
  // counts `0` rather than yielding no row at all. A grouped query over no
  // rows yields no group (standard SQL).
  if keys.isEmpty && order.isEmpty {
    let empty = aggregates.map {
      Accumulator($0.function, distinct: $0.distinct)
    }
    var cells = Array<Value>()
    cells.reserveCapacity(empty.count)
    for accumulator in empty { try cells.append(accumulator.value) }
    return [Record(cells)]
  }

  var groups = Array<Record>()
  groups.reserveCapacity(order.count)
  for group in order {
    var cells = group.values
    for accumulator in accumulators[Record(cells.map(canonical))]! {
      try cells.append(accumulator.value)
    }
    groups.append(Record(cells))
  }
  return groups
}
