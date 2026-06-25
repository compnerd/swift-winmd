// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The engine's ordinal-addressed row filter.
///
/// `Filter` is the lowered form of the AST's name-addressed `Predicate`: a tree
/// of comparisons composed with `AND`, `OR`, and `NOT`, with every column
/// resolved to an ordinal once. It reuses the AST's `Comparison` and `Literal`
/// — those are general — and addresses columns by `Int` so the executor can
/// inspect it (to seek a sorted column) before running it. The filter is fully
/// escapable; the `~Escapable` row it reads materialises only transiently at
/// evaluation.
internal indirect enum Filter {
  /// `column <op> value`, the column addressed by ordinal.
  case compare(Int, Comparison, Literal)
  /// `left = right`, both columns addressed by ordinal — a join's `ON`
  /// equality, lowered as a conjunct of the product's `Select` predicate.
  case match(Int, Int)
  /// `lhs AND rhs`.
  case and(Filter, Filter)
  /// `lhs OR rhs`.
  case or(Filter, Filter)
  /// `NOT operand`.
  case not(Filter)
}

// MARK: - Evaluation

extension Comparison {
  /// Applies the operator to two comparable operands.
  internal func apply<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool {
    switch self {
    case .equal: lhs == rhs
    case .unequal: lhs != rhs
    case .lt: lhs < rhs
    case .gt: lhs > rhs
    case .leq: lhs <= rhs
    case .geq: lhs >= rhs
    }
  }
}

/// Matches a typed cell `value` against a `literal` under operator `op`.
///
/// A like-typed pair compares — an integral cell against an `integer` literal, a
/// textual cell against a `string` literal; a cross-typed pair (a textual cell
/// against an integer literal, or the reverse) never matches.
private func matches(_ value: Value, _ op: Comparison, _ literal: Literal)
    -> Bool {
  switch (value, literal) {
  case let (.integer(lhs), .integer(rhs)): op.apply(lhs, rhs)
  case let (.text(lhs), .string(rhs)): op.apply(lhs, rhs)
  default: false
  }
}

/// Evaluates `filter` against `row`.
///
/// A `compare` reads the addressed cell as a typed `Value` and matches it
/// against the literal; a `match` reads both cells and tests them equal; the
/// boolean connectives recurse. The `borrowing` row is non-escaping; it threads
/// into the recursion freely and is never stored.
internal func evaluate<R: Row & ~Escapable>(_ filter: Filter,
                                            _ row: borrowing R) -> Bool {
  switch filter {
  case let .compare(column, op, value):
    matches(row[column], op, value)
  case let .match(left, right):
    row[left] == row[right]
  case let .and(lhs, rhs):
    // `&&`/`||` take an `@autoclosure` right operand, which would capture the
    // borrowed `~Escapable` row; spell the short-circuit explicitly so each
    // branch re-borrows the row rather than capturing it.
    if evaluate(lhs, row) { evaluate(rhs, row) } else { false }
  case let .or(lhs, rhs):
    if evaluate(lhs, row) { true } else { evaluate(rhs, row) }
  case let .not(operand):
    !evaluate(operand, row)
  }
}
