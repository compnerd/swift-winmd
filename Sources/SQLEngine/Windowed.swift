// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Window function

extension WindowFunction {
  /// The result type of a ranking window function — `ROW_NUMBER`, `RANK`,
  /// `DENSE_RANK` each yield a 1-based integer position, so each types as
  /// `.integer`, the type the schema advertises for a projected window column.
  ///
  /// An aggregate window's type depends on its argument (an integer `SUM` over
  /// integers, a double over doubles), so it is derived with a scope in
  /// `Scope.derive`/`validate`, which branch on the aggregate case before
  /// reaching this scope-free property.
  internal var type: ValueType {
    switch self {
    case .rowNumber, .rank, .denseRank, .ntile:
      .integer
    case .percentRank, .cumeDist:
      .double
    case .aggregate:
      preconditionFailure(
          "an aggregate window types from its argument through a scope")
    case .lead, .lag, .firstValue, .lastValue, .nthValue:
      preconditionFailure(
          "a positional window types from its value through a scope")
    }
  }

  /// Whether the executor computes this window function yet — every ranking
  /// function and every aggregate window now does. A future window function
  /// lands here `false` until its executor does, rejected with the feature
  /// diagnostic on both the run and validate paths until then.
  internal var supported: Bool {
    switch self {
    case .rowNumber, .rank, .denseRank, .aggregate, .lead, .lag,
         .firstValue, .lastValue, .nthValue,
         .ntile, .percentRank, .cumeDist:
      true
    }
  }

  /// The ISO keyword spelling of this window function, for a diagnostic — the
  /// ranking name, or the aggregate's own keyword for an aggregate window.
  internal var keyword: String {
    switch self {
    case .rowNumber: "ROW_NUMBER"
    case .rank: "RANK"
    case .denseRank: "DENSE_RANK"
    case let .aggregate(function, _, _, _): function.keyword
    case .lead: "LEAD"
    case .lag: "LAG"
    case .firstValue: "FIRST_VALUE"
    case .lastValue: "LAST_VALUE"
    case .nthValue: "NTH_VALUE"
    case .ntile: "NTILE"
    case .percentRank: "PERCENT_RANK"
    case .cumeDist: "CUME_DIST"
    }
  }

  /// This ranking window function's result `type`, or the feature diagnostic
  /// when its executor has not yet landed — the type the schema advertises for
  /// a supported window, faulting an unsupported one in parity with the run. An
  /// aggregate window is typed through a scope, never this property.
  internal var result: ValueType {
    get throws(SQLError) {
      guard supported else {
        throw .state("0A000", "\(keyword) is not yet supported")
      }
      return type
    }
  }
}

extension Frame.Bound {
  /// This bound with a zero offset collapsed to `CURRENT ROW` — `0 PRECEDING`
  /// and `0 FOLLOWING` both name the current row. So a `RANGE` frame bounded by
  /// one covers the current peer group (the bound the executor handles), not an
  /// unsupported numeric offset, and it orders with `CURRENT ROW`.
  internal var normalized: Frame.Bound {
    switch self {
    case .preceding(0), .following(0): .currentRow
    default: self
    }
  }
}

extension WindowFunction {
  /// Faults when this window function requires a window `ORDER BY` that `spec`
  /// lacks — an offset function (`LEAD`/`LAG`) reads the row a fixed distance
  /// along the window order, so an unordered window has no neighbour to read.
  /// Called on both the compile (run) and validate paths so the two stay in
  /// lockstep (the run ≡ validate tripwire).
  internal func require(order spec: WindowSpec) throws(SQLError) {
    switch self {
    case .rowNumber, .rank, .denseRank, .aggregate,
         .firstValue, .lastValue, .nthValue,
         .ntile, .percentRank, .cumeDist:
      break
    case .lead, .lag:
      guard spec.order != nil else {
        throw .state("0A000", "\(keyword) requires an ORDER BY")
      }
    }
  }
}

extension Frame {
  /// Whether a bound is an `n PRECEDING`/`n FOLLOWING` numeric offset — a zero
  /// offset is the current row, not a numeric offset, so it is normalized away
  /// first.
  private var offset: Bool {
    switch (start.normalized, end.normalized) {
    case (.preceding, _), (.following, _), (_, .preceding), (_, .following):
      true
    default:
      false
    }
  }

  /// Faults the feature diagnostic when the executor cannot compute this frame
  /// over `function` yet — called on both the compile (run) and validate paths
  /// so the two stay in lockstep (the run ≡ validate tripwire): a frame the
  /// schema types is one the run executes.
  ///
  /// The executor honours a frame only for a frame-sensitive function (an
  /// aggregate window folds over it, a `FIRST_VALUE`/`LAST_VALUE`/`NTH_VALUE`
  /// reads a row of it — a ranking or offset function takes none); a `ROWS`
  /// frame of any bounds; a `RANGE` frame whose bounds are the partition edges
  /// or the current peer group (a `RANGE` numeric offset — measured against
  /// the order-key value — is not yet computed); `GROUPS` is not yet computed.
  /// Faults a structurally invalid frame — one the parser can spell or a public
  /// AST can construct but no execution can honor. A frame may not start at
  /// `UNBOUNDED FOLLOWING` or end at `UNBOUNDED PRECEDING` — the start would
  /// follow, or the end precede, every row, so the frame is empty everywhere but
  /// the partition edge (a misleading total rather than a diagnostic). The
  /// single-bound form (`ROWS UNBOUNDED FOLLOWING`) reaches the same invalid
  /// start. And an `n PRECEDING`/`n FOLLOWING` size must be nonnegative — a
  /// negative one (a directly built `.preceding(-1)`, which the parser cannot
  /// spell) runs the bound the opposite way, as the `LEAD`/`LAG` offset check
  /// guards there. Reached from `reject(for:)` for a referenced window, and
  /// directly when validating an unused named window's specification, so an
  /// unused definition's frame is checked as a referenced one's is.
  internal func check() throws(SQLError) {
    if case .unboundedFollowing = start {
      throw .state("42601",
                   "a window frame cannot start at UNBOUNDED FOLLOWING")
    }
    if case .unboundedPreceding = end {
      throw .state("42601", "a window frame cannot end at UNBOUNDED PRECEDING")
    }
    for bound in [start, end] {
      switch bound {
      case let .preceding(size), let .following(size):
        guard size >= 0 else {
          throw .state("22023", "a window frame offset must be nonnegative")
        }
      default:
        break
      }
    }
    // The five bound categories order UNBOUNDED PRECEDING < n PRECEDING <
    // CURRENT ROW < n FOLLOWING < UNBOUNDED FOLLOWING; a start from a later
    // category than the end (CURRENT ROW AND 1 PRECEDING, or 1 FOLLOWING AND
    // CURRENT ROW) begins the frame after it ends, so it frames nothing for
    // every row rather than raising the required error.
    guard category(of: start) <= category(of: end) else {
      throw .state("42601", "a window frame start follows its end")
    }
    // Within one category, the offsets still order the bounds: an `n PRECEDING`
    // is earlier the larger its offset, an `n FOLLOWING` earlier the smaller. So
    // `2 PRECEDING AND 5 PRECEDING` and `5 FOLLOWING AND 2 FOLLOWING` each begin
    // after they end — an empty frame, not the required error — unless the
    // offsets are compared too.
    switch (start.normalized, end.normalized) {
    case let (.preceding(from), .preceding(to)):
      guard from >= to else {
        throw .state("42601", "a window frame start follows its end")
      }
    case let (.following(from), .following(to)):
      guard from <= to else {
        throw .state("42601", "a window frame start follows its end")
      }
    default:
      break
    }
  }

  /// A bound's position in the frame ordering, earliest to latest. A zero
  /// offset is the current row — `0 PRECEDING` and `0 FOLLOWING` both name it —
  /// so each ranks with `CURRENT ROW`, making `CURRENT ROW AND 0 PRECEDING` and
  /// `0 FOLLOWING AND CURRENT ROW` the valid single-row frames they are rather
  /// than a rejected inversion.
  private func category(of bound: Bound) -> Int {
    switch bound.normalized {
    case .unboundedPreceding: 0
    case .preceding: 1
    case .currentRow: 2
    case .following: 3
    case .unboundedFollowing: 4
    }
  }

  internal func reject(for function: WindowFunction) throws(SQLError) {
    try check()
    guard function.frameable else {
      throw .state("0A000",
                   "a window frame is not supported for \(function.keyword)")
    }
    switch unit {
    case .rows:
      break
    case .range:
      if offset {
        throw .state("0A000",
                     "a RANGE numeric offset frame is not yet supported")
      }
    case .groups:
      throw .state("0A000", "a GROUPS window frame is not yet supported")
    }
  }
}

extension Select {
  /// Whether the select projects (or orders by) a window function — the query
  /// compiles through the window path, appending each window's result to the
  /// source rows before the projection reads it. A window is allowed only in
  /// the SELECT list and `ORDER BY` (ISO 9075); one elsewhere is rejected.
  internal var windows: Bool {
    let projected = switch projection {
    case .all, .columns:
      false
    case let .expressions(items):
      items.contains { $0.expression.windowed }
    }
    return projected || orderKeys.contains { $0.windowed }
  }
}

// MARK: - Windowing (lowered)

/// A lowered window function — the ordinal-addressed form of an AST
/// `Expression.window`, ready for the executor to compute over a partition.
///
/// The `partition` terms and `order` sort keys are in the source's slot space
/// (the WHERE/join chain below the window node), evaluated per source record:
/// the partition terms split the records into independent partitions, and the
/// order keys fix the row order the ranking reads within a partition. The
/// `function` is the ranking (or, later, aggregate) folded over that ordered
/// partition, its value appended to each record as a fresh slot.
///
/// Two windowings are equal when they compute the same function over the same
/// resolved partition and order — the resolved form column qualification has
/// already normalized to a slot — so a window written twice
/// (`ROW_NUMBER() OVER w … ROW_NUMBER() OVER w`) is one windowing, one appended
/// slot. Equality is how the window path dedups the windows collected from the
/// projection and the `ORDER BY`.
internal struct Windowing: Equatable {
  /// A lowered window computation over an ordered partition.
  ///
  /// A ranking function carries nothing to lower — it reads only each row's
  /// position (and its peers) in the ordered partition. An aggregate window
  /// carries its lowered `Aggregation` (the argument `Term` and `FILTER`
  /// `Filter` already resolved to the source slot space), folded over the row's
  /// frame.
  internal enum Function: Equatable {
    /// `ROW_NUMBER` — the 1-based position of the row in the window order.
    case rowNumber
    /// `RANK` — the peer-aware rank, skipping after a tie.
    case rank
    /// `DENSE_RANK` — the peer-aware rank, dense (no gap after a tie).
    case denseRank
    /// An aggregate folded over the row's frame — the lowered `Aggregation` the
    /// executor accumulates, mirroring the collapsing grouping path's fold but
    /// cardinality-preserving.
    case aggregate(Aggregation)
    /// `LEAD` — the lowered `value` term read `offset` rows after the current
    /// row in the window order, else the lowered `default` term (or NULL) at a
    /// partition edge.
    case lead(Term, offset: Int, default: Term?)
    /// `LAG` — the mirror of `lead`, reading `offset` rows before the current
    /// row.
    case lag(Term, offset: Int, default: Term?)
    /// `FIRST_VALUE` — the lowered `value` term read at the first row of the
    /// frame.
    case firstValue(Term)
    /// `LAST_VALUE` — the `value` term read at the last row of the frame.
    case lastValue(Term)
    /// `NTH_VALUE` — the `value` term read at the 1-based `n`-th row of the
    /// frame, else NULL when the frame holds fewer than `n` rows.
    case nthValue(Term, Int)
    /// `NTILE` — the 1-based bucket number when the partition is split into `n`
    /// equal buckets.
    case ntile(Int)
    /// `PERCENT_RANK` — the relative rank in `[0, 1]`.
    case percentRank
    /// `CUME_DIST` — the cumulative distribution in `(0, 1]`.
    case cumeDist
  }

  /// The window function computed over each ordered partition.
  internal let function: Function

  /// The `PARTITION BY` keys splitting the records into partitions — empty when
  /// no `PARTITION BY` is written (the whole input is one partition).
  internal let partition: Array<Term>

  /// The window's `ORDER BY` keys fixing the row order within a partition —
  /// empty when none is written (every row a peer).
  internal let order: Array<SortKey>

  /// The explicit window frame the executor folds an aggregate window over, or
  /// `nil` for the default frame (the whole partition with no `order`, the
  /// running `RANGE UNBOUNDED PRECEDING` through the current peer group with
  /// one). The frame bounds are literal offsets, so nothing lowers here.
  internal let frame: Frame?

  internal init(function: Function, partition: Array<Term>,
                order: Array<SortKey>, frame: Frame? = nil) {
    self.function = function
    self.partition = partition
    self.order = order
    self.frame = frame
  }
}

extension Windowing.Function {
  /// This function with the slots of any aggregate window's argument and
  /// `FILTER` remapped through `slot` — a ranking function has none to remap.
  internal func remapped(through slot: Dictionary<Int, Int>)
      -> Windowing.Function {
    switch self {
    case .rowNumber, .rank, .denseRank, .ntile, .percentRank, .cumeDist:
      self
    case let .aggregate(aggregation):
      .aggregate(aggregation.remapped(through: slot))
    case let .lead(value, offset, fallback):
      .lead(value.remapped(through: slot), offset: offset,
            default: fallback.map { $0.remapped(through: slot) })
    case let .lag(value, offset, fallback):
      .lag(value.remapped(through: slot), offset: offset,
           default: fallback.map { $0.remapped(through: slot) })
    case let .firstValue(value):
      .firstValue(value.remapped(through: slot))
    case let .lastValue(value):
      .lastValue(value.remapped(through: slot))
    case let .nthValue(value, position):
      .nthValue(value.remapped(through: slot), position)
    }
  }

  /// The source slots this function reads, accumulated into `slots` — an
  /// aggregate window's argument and `FILTER` slots, an offset function's value
  /// and default slots, none for a ranking function.
  internal func references(into slots: inout Set<Int>) {
    switch self {
    case .rowNumber, .rank, .denseRank, .ntile, .percentRank, .cumeDist:
      break
    case let .aggregate(aggregation):
      aggregation.references(into: &slots)
    case let .lead(value, _, fallback), let .lag(value, _, fallback):
      value.references(into: &slots)
      fallback?.references(into: &slots)
    case let .firstValue(value), let .lastValue(value),
         let .nthValue(value, _):
      value.references(into: &slots)
    }
  }
}

extension Windowing {
  /// This windowing with its partition and order terms' slots remapped through
  /// `slot` — the base-ordinal → source-slot map the window node's source is
  /// packed under.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Windowing {
    Windowing(function: function.remapped(through: slot),
              partition: partition.map { $0.remapped(through: slot) },
              order: order.map { $0.remapped(through: slot) }, frame: frame)
  }

  /// The source slots this windowing reads, accumulated into `slots` — its
  /// partition and order terms', plus an aggregate window's argument and
  /// `FILTER`, so the source scan materialises exactly the cells the window
  /// partitions, orders, and folds on.
  internal func references(into slots: inout Set<Int>) {
    function.references(into: &slots)
    for term in partition { term.references(into: &slots) }
    for key in order { key.term.references(into: &slots) }
  }

  /// Whether every value this windowing evaluates per row — its partition and
  /// order keys and the function's own argument, value, offset default — is
  /// deterministic, so two structurally equal occurrences yield the same result
  /// and may share one appended slot (one evaluation). A stateful or
  /// non-deterministic input makes two occurrences diverge, so each keeps its
  /// own slot. An aggregate window carrying a `FILTER` is conservatively not
  /// shareable — the filter may hide a non-deterministic call this does not
  /// descend, and forgoing the share is always safe.
  internal func deterministic(_ routines: Routines) -> Bool {
    guard partition.allSatisfy({ $0.deterministic(routines) }),
          order.allSatisfy({ $0.term.deterministic(routines) }) else {
      return false
    }
    switch function {
    case .rowNumber, .rank, .denseRank, .ntile, .percentRank, .cumeDist:
      return true
    case let .aggregate(aggregation):
      return aggregation.filter == nil
          && (aggregation.argument?.deterministic(routines) ?? true)
    case let .lead(value, _, fallback), let .lag(value, _, fallback):
      return value.deterministic(routines)
          && (fallback?.deterministic(routines) ?? true)
    case let .firstValue(value), let .lastValue(value),
         let .nthValue(value, _):
      return value.deterministic(routines)
    }
  }
}

// MARK: - Window discovery

extension Expression {
  /// Whether the expression contains a window function anywhere within it.
  ///
  /// A window is a first-class node (`.window`), so the flag is true for one
  /// directly and for any compound holding one (`ROW_NUMBER() OVER () + 1`, a
  /// `CASE` whose guard or result is a window). It mirrors `aggregated`, which
  /// carves the same descent for a nested aggregate; a window inside a scalar
  /// `subquery` belongs to that subquery, not the enclosing query, and a window
  /// nested in an aggregate's argument is that aggregate's problem — both are
  /// not windows of this query, so each is false here.
  internal var windowed: Bool {
    switch self {
    case .column, .literal, .subquery, .aggregate:
      false
    case .window:
      true
    case let .call(_, arguments):
      arguments.contains { $0.windowed }
    case let .binary(_, lhs, rhs):
      lhs.windowed || rhs.windowed
    case let .case(whens, otherwise):
      whens.contains { $0.when.windowed || $0.then.windowed }
          || (otherwise?.windowed ?? false)
    case let .cast(operand, _):
      operand.windowed
    case let .coalesce(arguments):
      arguments.contains { $0.windowed }
    case let .nullif(lhs, rhs):
      lhs.windowed || rhs.windowed
    case let .grouping(arguments):
      arguments.contains { $0.windowed }
    }
  }

  /// Collects the distinct window expressions within this expression into
  /// `expressions`, in first-appearance order — the same window written twice
  /// computes once. Mirrors the aggregate `collect(into:)`; a window inside a
  /// scalar `subquery` or an aggregate's argument belongs to that inner scope,
  /// so neither is collected here.
  internal func collect(windows expressions: inout Array<Expression>) {
    switch self {
    case .column, .literal, .subquery, .aggregate:
      break
    case .window:
      if !expressions.contains(self) { expressions.append(self) }
    case let .call(_, arguments):
      for argument in arguments { argument.collect(windows: &expressions) }
    case let .binary(_, lhs, rhs):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .case(whens, otherwise):
      for branch in whens {
        branch.when.collect(windows: &expressions)
        branch.then.collect(windows: &expressions)
      }
      otherwise?.collect(windows: &expressions)
    case let .cast(operand, _):
      operand.collect(windows: &expressions)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(windows: &expressions) }
    case let .nullif(lhs, rhs):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .grouping(arguments):
      for argument in arguments { argument.collect(windows: &expressions) }
    }
  }

  /// Lowers this AST `.window` expression to a `Windowing`, its `PARTITION BY`
  /// keys and window `ORDER BY` resolved to combined base-ordinal terms through
  /// `scope`. `self` is always an `.window` — the window collectors gather only
  /// those.
  internal func windowing(_ scope: Scope, _ routines: Routines = [:],
                          subquery: Resolution = .unsupported)
      throws(SQLError) -> Windowing {
    guard case let .window(function, spec) = self else {
      throw .state("XX000", "expected a window function")
    }
    // The `Query.expanded` prelude inlines every named-window reference, so a
    // lowered spec carries its own partition/order/frame — a residual base name
    // reaching here is an internal inconsistency, never a user diagnostic.
    guard spec.base == nil else {
      throw .state("XX000", "an un-inlined window reference")
    }
    let partition = try spec.partition.map { key throws(SQLError) -> Term in
      try scope.term(key, routines, subquery: subquery)
    }
    let order: Array<SortKey> = if let clause = spec.order {
      try scope.window(order: clause, routines, subquery: subquery)
    } else {
      []
    }
    let lowered = try function.lowered(scope, routines, subquery: subquery)
    return Windowing(function: lowered, partition: partition, order: order,
                     frame: spec.frame)
  }
}

extension WindowFunction {
  /// Lowers this AST window function to a `Windowing.Function` over `scope` — a
  /// ranking function maps to its ranking case (nothing to resolve), and an
  /// aggregate window lowers its operand and `FILTER` to the source slot space,
  /// reusing the collapsing aggregate's own `aggregation` lowering so the two
  /// resolve identically (run ≡ validate).
  /// Faults a constant argument the parser's grammar rejects but a directly
  /// built AST could still carry — a nonpositive `NTILE` bucket count or
  /// `NTH_VALUE` position, or a negative `LEAD`/`LAG` offset. `lowered` calls
  /// this, the point compile lowers every window through, so the executor never
  /// divides by a zero bucket count, subscripts a row before the partition
  /// start, or negates `Int.min`, and the run and validate paths fault alike.
  private func check() throws(SQLError) {
    switch self {
    case let .ntile(buckets):
      guard buckets >= 1 else {
        throw .state("22023", "NTILE requires a positive bucket count")
      }
    case let .nthValue(_, position):
      guard position >= 1 else {
        throw .state("22023", "NTH_VALUE requires a positive position")
      }
    case let .lead(_, offset, _), let .lag(_, offset, _):
      guard offset >= 0 else {
        throw .state("22023", "\(keyword) requires a nonnegative offset")
      }
    default:
      break
    }
  }

  internal func lowered(_ scope: Scope, _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Windowing.Function {
    try check()
    switch self {
    case .rowNumber:
      return .rowNumber
    case .rank:
      return .rank
    case .denseRank:
      return .denseRank
    case let .aggregate(function, operand, distinct, filter):
      let aggregation = try Expression
          .aggregate(function, of: operand, distinct: distinct, filter: filter)
          .aggregation(scope, routines, subquery: subquery)
      return .aggregate(aggregation)
    case let .lead(value, offset, fallback):
      return try .lead(scope.term(value, routines, subquery: subquery),
                       offset: offset,
                       default: fallback.map { expression throws(SQLError) in
                         try scope.reconciled(expression, with: value, routines,
                                              subquery: subquery)
                       })
    case let .lag(value, offset, fallback):
      return try .lag(scope.term(value, routines, subquery: subquery),
                      offset: offset,
                      default: fallback.map { expression throws(SQLError) in
                        try scope.reconciled(expression, with: value, routines,
                                             subquery: subquery)
                      })
    case let .firstValue(value):
      return try .firstValue(scope.term(value, routines, subquery: subquery))
    case let .lastValue(value):
      return try .lastValue(scope.term(value, routines, subquery: subquery))
    case let .nthValue(value, position):
      return try .nthValue(scope.term(value, routines, subquery: subquery),
                           position)
    case let .ntile(buckets):
      return .ntile(buckets)
    case .percentRank:
      return .percentRank
    case .cumeDist:
      return .cumeDist
    }
  }
}

extension Predicate {
  /// Whether this predicate compares a window function anywhere within it — a
  /// window in a comparison operand (a `CASE` guard's `ROW_NUMBER() OVER () >
  /// 1`). Mirrors `Predicate.aggregated`; an `EXISTS`/`IN (Q)` subquery is its
  /// own scope, so a window inside it is that query's, not this predicate's.
  internal var windowed: Bool {
    switch self {
    case let .comparison(left, _, right):
      left.windowed || right.windowed
    case let .bound(left, _, _):
      left.windowed
    case let .null(expression, _):
      expression.windowed
    case let .membership(operand, values, _):
      operand.windowed || values.contains { $0.windowed }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.windowed } || rhs.contains { $0.windowed }
    case let .among(lhs, rows, _):
      lhs.contains { $0.windowed }
          || rows.contains { $0.contains { $0.windowed } }
    case .exists:
      false
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      lhs.contains { $0.windowed }
    case let .like(operand, pattern, escape, _):
      operand.windowed || pattern.windowed || (escape?.windowed ?? false)
    case let .between(test, lower, upper, _):
      test.windowed || lower.windowed || upper.windowed
    case let .distinct(lhs, rhs, _):
      lhs.windowed || rhs.windowed
    case let .truth(inner, _, _):
      inner.windowed
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.windowed || rhs.windowed
    case let .not(operand):
      operand.windowed
    }
  }
}

extension Predicate.Operand {
  /// Whether this LIKE pattern/escape operand holds a window — an expression
  /// operand may, a run-time `:parameter` never does.
  fileprivate var windowed: Bool {
    switch self {
    case let .expression(expression): expression.windowed
    case .parameter: false
    }
  }

  /// Collects the distinct windows within this operand — an expression operand
  /// may hold one, a `:parameter` never does.
  fileprivate func collect(windows expressions: inout Array<Expression>) {
    if case let .expression(expression) = self {
      expression.collect(windows: &expressions)
    }
  }
}

extension Predicate {
  /// Collects the distinct window expressions within this predicate into
  /// `expressions` — those in a comparison operand (a `CASE` guard's window).
  /// Mirrors the aggregate `collect(into:)`; an `EXISTS`/`IN (Q)` subquery is
  /// its own scope, so a window inside it is not collected here.
  internal func collect(windows expressions: inout Array<Expression>) {
    switch self {
    case let .comparison(left, _, right):
      left.collect(windows: &expressions)
      right.collect(windows: &expressions)
    case let .bound(left, _, _):
      left.collect(windows: &expressions)
    case let .null(expression, _):
      expression.collect(windows: &expressions)
    case let .membership(operand, values, _):
      operand.collect(windows: &expressions)
      for value in values { value.collect(windows: &expressions) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(windows: &expressions) }
      for expression in rhs { expression.collect(windows: &expressions) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(windows: &expressions) }
      for element in rows {
        for expression in element { expression.collect(windows: &expressions) }
      }
    case .exists:
      break
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      for expression in lhs { expression.collect(windows: &expressions) }
    case let .like(operand, pattern, escape, _):
      operand.collect(windows: &expressions)
      pattern.collect(windows: &expressions)
      escape?.collect(windows: &expressions)
    case let .between(test, lower, upper, _):
      test.collect(windows: &expressions)
      lower.collect(windows: &expressions)
      upper.collect(windows: &expressions)
    case let .distinct(lhs, rhs, _):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .truth(inner, _, _):
      inner.collect(windows: &expressions)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .not(operand):
      operand.collect(windows: &expressions)
    }
  }
}

// MARK: - Named-window inlining

extension WindowSpec {
  /// This specification with a named-window reference (`OVER w`) resolved to
  /// the specification `windows` defines under that name, an inline spec (`OVER
  /// (…)`) returned unchanged. A reference to an undefined window faults
  /// `42704`; a refinement (a base name with added `PARTITION`/`ORDER`/frame
  /// clauses) and a chained reference (a named window that itself references
  /// another) are not yet supported and fault `0A000`. Each fault is on both
  /// the run and validate paths, since the inlining runs at the shared
  /// `Query.expanded` prelude.
  internal func resolved(against windows: Array<NamedWindow>)
      throws(SQLError) -> WindowSpec {
    guard let base else { return self }
    guard partition.isEmpty, order == nil, frame == nil else {
      throw .state("0A000", "refining a named window is not yet supported")
    }
    guard let named = windows.first(where: {
      $0.name.lowercased() == base.lowercased()
    })?.spec else {
      throw .state("42704", "window \"\(base)\" is not defined")
    }
    guard named.base == nil else {
      throw .state("0A000", "a chained window reference is not yet supported")
    }
    return named
  }
}

extension Expression {
  /// This expression with every window reference (`OVER w`) inlined to the
  /// window `windows` defines — the resolution prelude run before any structural
  /// walk descends a window specification, so a named window's `PARTITION BY`/
  /// `ORDER BY` expressions are visible to the subquery, aggregate, and
  /// comparison walks exactly as an inline `OVER (…)` spec's are, keeping the
  /// run and validate paths in lockstep by construction. It mirrors the descent
  /// of `collect(windows:)`: a nested scalar `subquery` or an aggregate's
  /// argument is its own scope (its own `WINDOW` clause resolved when it
  /// re-enters `expanded`), so neither is descended here.
  internal func resolving(_ windows: Array<NamedWindow>)
      throws(SQLError) -> Expression {
    switch self {
    case .column, .literal, .subquery, .aggregate:
      self
    case let .window(function, spec):
      .window(function: function, spec: try spec.resolved(against: windows))
    case let .call(name, arguments):
      .call(name: name, arguments: try arguments.map { argument throws(SQLError)
        in try argument.resolving(windows)
      })
    case let .binary(op, lhs, rhs):
      .binary(op, try lhs.resolving(windows), try rhs.resolving(windows))
    case let .case(whens, otherwise):
      .case(try whens.map { branch throws(SQLError) in
        When(when: try branch.when.resolving(windows),
             then: try branch.then.resolving(windows))
      }, else: try otherwise?.resolving(windows))
    case let .cast(operand, type):
      .cast(try operand.resolving(windows), type)
    case let .coalesce(arguments):
      .coalesce(try arguments.map { argument throws(SQLError) in
        try argument.resolving(windows)
      })
    case let .nullif(lhs, rhs):
      .nullif(try lhs.resolving(windows), try rhs.resolving(windows))
    case let .grouping(arguments):
      .grouping(try arguments.map { argument throws(SQLError) in
        try argument.resolving(windows)
      })
    }
  }
}

extension Predicate.Operand {
  /// This LIKE pattern/escape operand with any window reference in an
  /// expression operand inlined — a `:parameter` carries none.
  fileprivate func resolving(_ windows: Array<NamedWindow>)
      throws(SQLError) -> Predicate.Operand {
    switch self {
    case let .expression(expression):
      .expression(try expression.resolving(windows))
    case .parameter:
      self
    }
  }
}

extension Predicate {
  /// This predicate with every window reference (`OVER w`) inlined — the
  /// `Expression.resolving` companion for a `CASE` guard's predicate. It
  /// mirrors the descent of `collect(windows:)`; an `EXISTS`/`IN (Q)` subquery
  /// is its own scope, so a window inside it is not descended here.
  internal func resolving(_ windows: Array<NamedWindow>)
      throws(SQLError) -> Predicate {
    switch self {
    case let .comparison(left, op, right):
      .comparison(left: try left.resolving(windows), op: op,
                  right: try right.resolving(windows))
    case let .bound(left, op, parameter):
      .bound(left: try left.resolving(windows), op: op, parameter: parameter)
    case let .null(expression, negated):
      .null(try expression.resolving(windows), negated: negated)
    case let .membership(operand, values, negated):
      .membership(try operand.resolving(windows),
                  try values.map { value throws(SQLError) in
                    try value.resolving(windows)
                  }, negated: negated)
    case let .rows(lhs, op, rhs):
      .rows(try lhs.map { l throws(SQLError) in try l.resolving(windows) }, op,
            try rhs.map { r throws(SQLError) in try r.resolving(windows) })
    case let .among(lhs, rows, negated):
      .among(try lhs.map { l throws(SQLError) in try l.resolving(windows) },
             try rows.map { row throws(SQLError) in
               try row.map { r throws(SQLError) in try r.resolving(windows) }
             }, negated: negated)
    case let .like(operand, pattern, escape, negated):
      .like(try operand.resolving(windows),
            pattern: try pattern.resolving(windows),
            escape: try escape?.resolving(windows), negated: negated)
    case let .between(test, lower, upper, negated):
      .between(try test.resolving(windows), try lower.resolving(windows),
               try upper.resolving(windows), negated: negated)
    case let .distinct(lhs, rhs, negated):
      .distinct(try lhs.resolving(windows), try rhs.resolving(windows),
                negated: negated)
    case .exists:
      self
    case let .within(lhs, query, negated):
      .within(try lhs.map { l throws(SQLError) in try l.resolving(windows) },
              query, negated: negated)
    case let .quantified(lhs, op, quantifier, query):
      .quantified(try lhs.map { l throws(SQLError) in
        try l.resolving(windows)
      }, op, quantifier, query)
    case let .truth(inner, value, negated):
      .truth(try inner.resolving(windows), value: value, negated: negated)
    case let .and(lhs, rhs):
      .and(try lhs.resolving(windows), try rhs.resolving(windows))
    case let .or(lhs, rhs):
      .or(try lhs.resolving(windows), try rhs.resolving(windows))
    case let .not(operand):
      .not(try operand.resolving(windows))
    }
  }
}

extension Select {
  /// This select with every `OVER w` reference in its projection and `ORDER BY`
  /// inlined to the `WINDOW` clause's definition, and the clause dropped — the
  /// resolution prelude the `Query.expanded` entry runs before any structural
  /// walk, so a named window and the equivalent inline `OVER (…)` compile and
  /// validate identically (a named window's specification is seen by the same
  /// subquery/aggregate/comparison walks). A projection or `ORDER BY` are the
  /// only clauses a window is allowed in (ISO 9075); a reference elsewhere is
  /// rejected there, spec-independently, on both paths.
  ///
  /// A duplicate `WINDOW` name faults `42601`, and an `OVER w` naming an
  /// undefined window faults `42704` — each on both paths, since the prelude is
  /// shared. A select with no window clause and no window function is returned
  /// unchanged.
  internal var inlined: Select {
    get throws(SQLError) {
      // A duplicate named-window definition is a semantic error regardless of
      // whether the query uses any window function.
      var seen = Set<String>()
      for definition in window {
        guard seen.insert(definition.name.lowercased()).inserted else {
          throw .state("42601",
                       "window \"\(definition.name)\" is already defined")
        }
      }
      // Nothing to inline unless the projection or `ORDER BY` bears a window.
      // The clause is kept either way — compile validates every named
      // definition against the source scope, whether or not it is referenced,
      // rather than silently discarding an unused one.
      guard windows else { return self }
      let projection: Projection = switch projection {
      case .all, .columns:
        projection
      case let .expressions(items):
        .expressions(try items.map { item throws(SQLError) in
          Projected(expression: try item.expression.resolving(window),
                    alias: item.alias)
        })
      }
      let order: Order? = if let order {
        Order(keys: try order.keys.map { key throws(SQLError) in
          switch key.sort {
          case .ordinal:
            key
          case let .expression(expression):
            Order.Key(sort: .expression(try expression.resolving(window)),
                      ascending: key.ascending)
          }
        })
      } else {
        nil
      }
      return Select(distinct: distinct, projection: projection, from: from,
                    joins: joins, predicate: predicate, grouping: grouping,
                    having: having, window: window, order: order, limit: limit)
    }
  }
}

// MARK: - Window ORDER BY

extension Scope {
  /// Lowers a window's `ORDER BY` to sort keys over the source scope, major to
  /// minor — each key an ISO `<sort key>` value expression lowered to a `Term`,
  /// its direction preserved.
  ///
  /// A window `ORDER BY` fixes the input row order the ranking reads, so each
  /// key is a value expression over the source columns — never an output
  /// ordinal or alias (there is no projected output to name at this point). An
  /// integer-literal sort key parses as an `ordinal`, which names an output
  /// column, so it is meaningless here and faults the feature diagnostic on
  /// both the run and validate paths (kept in parity through the shared
  /// resolver).
  internal func window(order: Order, _ routines: Routines = [:],
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    var keys = Array<SortKey>()
    keys.reserveCapacity(order.keys.count)
    for key in order.keys {
      switch key.sort {
      case .ordinal:
        throw .state("0A000",
                     "a window ORDER BY output ordinal is not supported")
      case let .expression(expression):
        try keys.append(SortKey(term: term(expression, routines,
                                            subquery: subquery),
                                ascending: key.ascending, column: nil))
      }
    }
    return keys
  }
}

// MARK: - Windowed scope

/// The output slot space of a window query — the lowering surface for the
/// projection and `ORDER BY` that read a window node's records.
///
/// A `window` node passes its source's records through unchanged (slots `0 ..<
/// width`) and appends one slot per windowing (slot `width + j` is
/// `windowings[j]`'s value). A `Windowed` lowers a name-addressed AST
/// expression into that space: a window function maps to its appended slot; any
/// other reference lowers over the source scope and remaps into the packed
/// source slots. Unlike the grouped scope — where a bare non-key column faults
/// — a window is cardinality-preserving, so a bare source column is an ordinary
/// pass-through reference to its own slot.
///
/// It also records each projected item's output name so an `ORDER BY` may name
/// a projection alias, exactly as the grouped surface does.
internal struct Windowed {
  private let scope: Scope

  /// The base-ordinal → packed source-slot map the window node's source is
  /// materialised under — the same map the source chain's terms are remapped
  /// through, so a window-free reference lowers over the source scope and lands
  /// in the source's slot space.
  private let slot: Dictionary<Int, Int>

  /// The source slot count — the boundary the appended window results begin at
  /// (windowing `j` at slot `width + j`).
  private let width: Int

  /// The windowings the query computes, appended one slot each (windowing `j` at
  /// slot `width + j`), built as `slot(of:)` first meets each window during
  /// lowering — a deterministic window shared by its resolved `Windowing`, a
  /// stateful or non-deterministic one kept distinct per occurrence. It is a
  /// reference so the non-mutating lowering accumulates into it; the two lowering
  /// passes each walk the same projection and `ORDER BY`, so each builds an
  /// identical list (one over the identity space, one over the packed source).
  private final class Registry {
    var windowings = Array<Windowing>()
  }
  private let registry = Registry()

  /// The windowings collected so far — after a full projection/`ORDER BY`
  /// lowering, the query's complete list, windowing `j` at appended slot `width
  /// + j`.
  internal var windowings: Array<Windowing> { registry.windowings }

  /// Each projected item's output name (an alias, else a bare column's name),
  /// lowercased, mapped to its output term and its 0-based projection column —
  /// the surface an `ORDER BY` names a projection alias against.
  private var aliases: Dictionary<String, (term: Term, column: Int)> = [:]

  /// Output names two or more projected items share, lowercased. An `ORDER BY`
  /// naming one has no single slot to order on — the ambiguity the ordinary
  /// `order` reports for a shared unqualified column.
  private var ambiguous: Set<String> = []

  /// Builds a windowed surface over `scope`, the packed source-slot map `slot`,
  /// and the source `width` (the boundary appended window results begin at). The
  /// windowings are gathered during lowering, so `windowings` is empty until the
  /// projection and `ORDER BY` have been lowered.
  internal init(_ scope: Scope, _ slot: Dictionary<Int, Int>, width: Int) {
    self.scope = scope
    self.slot = slot
    self.width = width
  }

  /// The appended slot a window `expression` resolves to, or `nil` if it is not
  /// a window. The expression is resolved to a source-space `Windowing`; a
  /// deterministic one matches those already collected — so a
  /// qualification-equivalent window (`OVER (ORDER BY x)` vs `OVER (ORDER BY
  /// T.x)`) shares one slot — while an unmatched or non-deterministic one is
  /// appended to take a fresh slot.
  private func slot(of expression: Expression, _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Int? {
    guard case .window = expression else { return nil }
    let windowing = try expression.windowing(scope, routines,
                                             subquery: subquery)
        .remapped(through: slot)
    // Share an appended slot only with an already-collected deterministic
    // window; a stateful or non-deterministic window takes a fresh slot per
    // occurrence, so two occurrences of it (`FIRST_VALUE(tick())` written twice)
    // each evaluate independently rather than reading one shared computation.
    if windowing.deterministic(routines),
        let index = registry.windowings.firstIndex(of: windowing) {
      return width + index
    }
    let index = registry.windowings.count
    registry.windowings.append(windowing)
    return width + index
  }

  /// Lowers an `expression` to its output-space `Term` — the module-visible
  /// entry to the private `term`.
  internal func resolve(_ expression: Expression,
                        _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    try term(expression, routines, subquery: subquery)
  }

  /// Lowers a scalar `expression` to an output-space `Term`.
  ///
  /// A window function maps to its appended slot; a window-free expression
  /// lowers wholesale over the source scope and remaps into the packed source
  /// slots; a compound nesting a window (`ROW_NUMBER() OVER () + 1`) recurses,
  /// lowering the window leaves to their appended slots and the ordinary leaves
  /// over the source.
  private func term(_ expression: Expression,
                    _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    if case .window = expression {
      if let slot = try slot(of: expression, routines, subquery: subquery) {
        return .slot(slot)
      }
      // A window reaches here only when it was not collected — an internal
      // inconsistency, since the query gathers every projection/ORDER BY window.
      throw .state("XX000", "uncollected window")
    }
    // A window-free expression carries no appended slot, so it lowers as an
    // ordinary source reference — over the source scope, then remapped into the
    // packed source slots. A bare source column reads its own slot (a window is
    // cardinality-preserving, so no grouping rule bars it).
    if !expression.windowed {
      return try scope.term(expression, routines, subquery: subquery)
          .remapped(through: slot)
    }
    // A compound nesting a window: recurse so each window leaf maps to its
    // appended slot and each ordinary leaf lowers over the source.
    switch expression {
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, routines, subquery: subquery))
      }
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .case(whens, otherwise):
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        try branches.append((lower(branch.when, routines, subquery: subquery),
                             term(branch.then, routines, subquery: subquery)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, routines, subquery: subquery)
      } else {
        nil
      }
      let type = try scope.derive(whens, otherwise, routines,
                                  subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      return try .cast(term(operand, routines, subquery: subquery), type)
    case let .coalesce(arguments):
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines, subquery: subquery))
      }
      let type = try scope.derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      return try .nullif(term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    default:
      // Every other shape is either not window-bearing (handled above) or a
      // leaf a window cannot nest through, so it never reaches here.
      throw .state("XX000", "unlowered window expression")
    }
  }

  /// Lowers a predicate (a `CASE` guard) to an output-space `Filter`, its
  /// operand expressions lowered through `term` so a window in a comparison
  /// maps to its appended slot.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Filter {
    try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }, subquery: subquery)
  }

  /// Records a projected item's output `name` at projection `column` → its
  /// output `term`, flagging the name ambiguous if another item already claimed
  /// it.
  private mutating func record(_ name: String, _ column: Int, _ term: Term) {
    let key = name.lowercased()
    let entry = (term: term, column: column)
    if aliases.updateValue(entry, forKey: key) != nil { ambiguous.insert(key) }
  }

  /// The output-space projected terms, recording each item's output name for an
  /// `ORDER BY` to name. A `SELECT *` over a window query has no well-defined
  /// meaning (which windows?), so it faults.
  internal mutating func terms(_ projection: Projection,
                               _ routines: Routines = [:],
                               subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<Term> {
    // A window-query projection admits a correlated column of this query, as
    // every clause does: an unbound name resolves against the enclosing `outer`
    // that `subquery` carries.
    switch projection {
    case .all:
      throw .state("0A000",
                   "SELECT * is not allowed with a window function")
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for index in columns.indices {
        let term = try term(.column(columns[index]), routines,
                            subquery: subquery)
        terms.append(term)
        record(columns[index].name, index, term)
      }
      return terms
    case let .expressions(items):
      var terms = Array<Term>()
      terms.reserveCapacity(items.count)
      for index in items.indices {
        let term = try term(items[index].expression, routines,
                            subquery: subquery)
        terms.append(term)
        if let name = items[index].name { record(name, index, term) }
      }
      return terms
    }
  }

  /// The resolved sort keys a query `ORDER BY` lowers to in output space, major
  /// to minor — an ordinal names the query's `n`-th projected column, an
  /// unqualified name a projection alias first (else a source column), and any
  /// other expression lowers over the output through `term`.
  internal func order(_ order: Order, _ projection: Array<Term>,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // A query ORDER BY admits a correlated column, as the projection does.
    var resolved = Array<SortKey>()
    resolved.reserveCapacity(order.keys.count)
    for key in order.keys {
      switch key.sort {
      case let .ordinal(position):
        guard position >= 1, position <= projection.count else {
          throw .column("\(position)")
        }
        resolved.append(SortKey(term: projection[position - 1],
                                ascending: key.ascending,
                                column: position - 1))
      case let .expression(expression):
        if case let .column(reference) = expression,
            reference.qualifier == nil {
          let name = reference.name.lowercased()
          if ambiguous.contains(name) { throw .ambiguous(reference.name) }
          if let alias = aliases[name] {
            resolved.append(SortKey(term: alias.term, ascending: key.ascending,
                                    column: alias.column))
            continue
          }
        }
        try resolved.append(SortKey(term: term(expression, routines,
                                                subquery: subquery),
                                    ascending: key.ascending, column: nil))
      }
    }
    return resolved
  }
}
