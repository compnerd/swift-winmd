// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// Window-function builders — `<f> OVER (PARTITION BY … ORDER BY …)`, the
// read-only surface unblocked now the engine has a window node (`Gaps.swift`).
// A ranking, distribution, offset, or value function is a `Window` seed
// completed by `.over(…)`; an aggregate term windows through `Term.over(…)`.
// The frame is the engine default — a running `RANGE UNBOUNDED PRECEDING` for
// an ordered aggregate, the whole partition otherwise — as an explicit frame,
// a named window, and a DISTINCT/FILTER window remain later gaps.
//
// Each builder is a single word mirroring the engine's `WindowFunction` case
// (`number()` for `ROW_NUMBER`, `dense()` for `DENSE_RANK`), per the naming
// convention (CodingStyle §7), not the compound SQL keyword.

/// A window function awaiting its `OVER (…)` specification — a ranking
/// (`number()`, `rank()`, `dense()`), a distribution (`ntile(_:)`,
/// `percent()`, `cumulative()`), an offset (`lead(_:)`/`lag(_:)`), or a value
/// (`first(_:)`, `last(_:)`, `nth(_:_:)`). `.over(…)` completes it to a `Term`
/// a projection or an `order(by:)` can carry.
public struct Window {
  fileprivate let function: WindowFunction

  fileprivate init(_ function: WindowFunction) {
    self.function = function
  }

  /// `<function> OVER (PARTITION BY partition ORDER BY order)`. An empty
  /// `partition` or `order` omits that clause. The engine requires a ranking
  /// or offset function to carry an `order`, and faults it at compile
  /// otherwise, exactly as the equivalent SQL does.
  public func over(partitioning partition: [any TermConvertible] = [],
                   ordering order: [Order.Key] = []) -> Term {
    Term(window: function, partition: partition, order: order)
  }
}

extension Term {
  /// Builds a `.window` term from a function and an `OVER` specification — the
  /// single point `Window.over` and `Term.over` construct the node.
  fileprivate init(window function: WindowFunction,
                   partition: [any TermConvertible], order: [Order.Key]) {
    self.init(.window(function: function,
                      spec: WindowSpec(
                          partition: partition.map(\.term.expression),
                          order: order.isEmpty ? nil : Order(keys: order))))
  }

  /// `<aggregate> OVER (…)` — this aggregate term (`sum(_:)`, `count()`, …)
  /// evaluated as a window aggregate over the specification, rather than folded
  /// by a `GROUP BY`. Only an aggregate term windows this way; `over(…)` on any
  /// other term is a builder misuse (there is no window of a bare scalar).
  public func over(partitioning partition: [any TermConvertible] = [],
                   ordering order: [Order.Key] = []) -> Term {
    guard case let .aggregate(function, operand, distinct, filter) = expression
    else {
      preconditionFailure("over(…) requires an aggregate term")
    }
    return Term(window: .aggregate(function, of: operand, distinct: distinct,
                                   filter: filter),
                partition: partition, order: order)
  }
}

// MARK: - Ranking and distribution

/// `ROW_NUMBER()` — the row's 1-based position in the window order.
public func number() -> Window { Window(.number) }

/// `RANK()` — the position in the window order, with gaps after a tie.
public func rank() -> Window { Window(.rank) }

/// `DENSE_RANK()` — the position in the window order, with no gaps after a tie.
public func dense() -> Window { Window(.dense) }

/// `NTILE(buckets)` — the 1-based bucket the row falls in when the partition is
/// split into `buckets` near-equal contiguous groups.
public func ntile(_ buckets: Int) -> Window { Window(.ntile(buckets)) }

/// `PERCENT_RANK()` — `(rank - 1) / (rows - 1)` over the partition.
public func percent() -> Window { Window(.percent) }

/// `CUME_DIST()` — the cumulative distribution: the fraction of partition rows
/// at or before the current row's peer group.
public func cumulative() -> Window { Window(.cumulative) }

// MARK: - Offset

/// `LEAD(value, offset, default)` — `value` from the row `offset` ahead in the
/// window order, or `default` (NULL when omitted) past the partition end.
public func lead(_ value: some TermConvertible, offset: Int = 1,
                 default fallback: (any TermConvertible)? = nil) -> Window {
  Window(.lead(value.term.expression, offset: offset,
               default: fallback?.term.expression))
}

/// `LAG(value, offset, default)` — `value` from the row `offset` behind in the
/// window order, or `default` (NULL when omitted) before the partition start.
public func lag(_ value: some TermConvertible, offset: Int = 1,
                default fallback: (any TermConvertible)? = nil) -> Window {
  Window(.lag(value.term.expression, offset: offset,
              default: fallback?.term.expression))
}

// MARK: - Value

/// `FIRST_VALUE(value)` — `value` from the first row of the window frame.
public func first(_ value: some TermConvertible) -> Window {
  Window(.first(value.term.expression))
}

/// `LAST_VALUE(value)` — `value` from the last row of the window frame.
public func last(_ value: some TermConvertible) -> Window {
  Window(.last(value.term.expression))
}

/// `NTH_VALUE(value, n)` — `value` from the `n`-th (1-based) row of the frame.
public func nth(_ value: some TermConvertible, _ n: Int) -> Window {
  Window(.nth(value.term.expression, n))
}
