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
  /// `left <op> right`, both operands lowered to ordinal-addressed terms (a
  /// slot, a constant, or a scalar-function call).
  case compare(Term, Comparison, Term)
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

// MARK: - Terms

/// The engine's ordinal-addressed scalar expression.
///
/// `Term` is the lowered form of the AST's name-addressed `Expression`: a slot
/// reference (a column resolved to its slot in a record), a constant, or a call
/// to a registered scalar function over argument terms. A projection lowers each
/// projected expression to a `Term` the executor evaluates per record against
/// the routines; a bare-column projection lowers to a `.slot`, so the simple
/// path stays a plain slot read.
internal indirect enum Term {
  /// The cell at `slot` of the record.
  case slot(Int)
  /// A constant value.
  case constant(Value)
  /// A call to the named scalar function over its argument terms, in order.
  case apply(name: String, arguments: Array<Term>)
}

extension Term {
  /// The slots this term reads, accumulated into `slots`.
  ///
  /// A `slot` reads itself; a `constant` reads none; an `apply` reads the union
  /// of its arguments. A projection unions these with the filter and order so a
  /// scan materialises exactly the cells the projection's functions consume.
  internal func references(into slots: inout Set<Int>) {
    switch self {
    case let .slot(slot):
      slots.insert(slot)
    case .constant:
      break
    case let .apply(_, arguments):
      for argument in arguments {
        argument.references(into: &slots)
      }
    }
  }
}

/// The literal `literal` as a typed `Value`.
internal func value(of literal: Literal) -> Value {
  switch literal {
  case let .integer(integer): .integer(integer)
  case let .string(string): .text(string)
  }
}

/// Evaluates `term` against `row` through `routines`, yielding a typed value.
///
/// A `slot` reads the row's cell; a `constant` is itself; an `apply` looks the
/// function up in the routines (`SQLError.function` on a miss), evaluates its
/// arguments, and applies it. The `borrowing` row is non-escaping — a term runs
/// over a materialised projection record or a predicate's borrowed cursor row.
internal func evaluate<R: Row & ~Escapable>(_ term: Term, _ row: borrowing R,
                                            _ routines: Routines)
    throws(SQLError) -> Value {
  switch term {
  case let .slot(slot):
    row[slot]
  case let .constant(value):
    value
  case let .apply(name, arguments):
    try apply(name, arguments, row, routines)
  }
}

/// Resolves `name` in `routines` and applies it to its evaluated `arguments`.
private func apply<R: Row & ~Escapable>(_ name: String,
                                        _ arguments: Array<Term>,
                                        _ row: borrowing R,
                                        _ routines: Routines)
    throws(SQLError) -> Value {
  guard let function = routines.function(named: name) else {
    throw .function(name)
  }
  var values = Array<Value>()
  values.reserveCapacity(arguments.count)
  for argument in arguments {
    try values.append(evaluate(argument, row, routines))
  }
  return try function(values)
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

/// Matches two typed values under operator `op`.
///
/// A like-typed pair compares — two integers or two strings; a cross-typed pair
/// (an integer against a string, or the reverse) never matches.
private func matches(_ lhs: Value, _ op: Comparison, _ rhs: Value) -> Bool {
  switch (lhs, rhs) {
  case let (.integer(lhs), .integer(rhs)): op.apply(lhs, rhs)
  case let (.text(lhs), .text(rhs)): op.apply(lhs, rhs)
  default: false
  }
}

/// Evaluates `filter` against `row`, resolving scalar calls through `routines`.
///
/// A `compare` evaluates both operand terms and matches them; a `match` reads
/// both cells and tests them equal; the boolean connectives recurse. The
/// `borrowing` row is non-escaping; it threads into the recursion freely and is
/// never stored.
internal func evaluate<R: Row & ~Escapable>(_ filter: Filter,
                                            _ row: borrowing R,
                                            _ routines: Routines)
    throws(SQLError) -> Bool {
  switch filter {
  case let .compare(lhs, op, rhs):
    try matches(evaluate(lhs, row, routines), op, evaluate(rhs, row, routines))
  case let .match(left, right):
    row[left] == row[right]
  case let .and(lhs, rhs):
    // `&&`/`||` take an `@autoclosure` right operand, which would capture the
    // borrowed `~Escapable` row; spell the short-circuit explicitly so each
    // branch re-borrows the row rather than capturing it.
    if try evaluate(lhs, row, routines) { try evaluate(rhs, row, routines) }
    else { false }
  case let .or(lhs, rhs):
    if try evaluate(lhs, row, routines) { true }
    else { try evaluate(rhs, row, routines) }
  case let .not(operand):
    try !evaluate(operand, row, routines)
  }
}
