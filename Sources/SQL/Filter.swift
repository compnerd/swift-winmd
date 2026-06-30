// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A query's parameter bindings: each `:name` parameter mapped to the value
/// bound for this run — the operand a `bound` filter resolves, and the key the
/// seek planner reads.
public typealias Bindings = Dictionary<String, Value>

/// The engine's ordinal-addressed row filter.
///
/// `Filter` is the lowered form of the AST's name-addressed `Predicate`: a tree
/// of comparisons composed with `AND`, `OR`, and `NOT`, with every column
/// resolved to a slot once. Each comparison operand is a `Term` — a slot, a
/// constant, or a scalar call — so the executor can still seek a sorted column
/// off a bare slot before running it. The filter is fully
/// escapable; the `~Escapable` row it reads materialises only transiently at
/// evaluation.
internal indirect enum Filter {
  /// `left <op> right`, both operands lowered to ordinal-addressed terms (a
  /// slot, a constant, or a scalar-function call).
  case compare(Term, Comparison, Term)
  /// `left <op> :parameter`, the left a term and the operand resolved at run
  /// time from the engine's bindings — the lowered form of a correlated
  /// subquery's parent-keyed predicate.
  case bound(Term, Comparison, String)
  /// `left = right`, both columns addressed by ordinal — a join's `ON`
  /// equality, lowered as a conjunct of the product's `Select` predicate.
  case match(Int, Int)
  /// `term IS NULL`, or `IS NOT NULL` when `negated` — the lowered form of the
  /// AST's `null`, a definite two-valued test (never UNKNOWN).
  case null(Term, negated: Bool)
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

extension Term {
  /// This term with every ordinal it reads remapped to a slot through `slot`: a
  /// `.slot` holding an ordinal becomes the same slot, a constant is unchanged,
  /// a call recurses into its arguments.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Term {
    switch self {
    case let .slot(ordinal):
      .slot(slot[ordinal]!)
    case .constant:
      self
    case let .apply(name, arguments):
      .apply(name: name,
             arguments: arguments.map { $0.remapped(through: slot) })
    }
  }
}

extension Filter {
  /// This filter with every ordinal it addresses remapped to a slot through
  /// `slot`.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Filter {
    switch self {
    case let .compare(lhs, op, rhs):
      .compare(lhs.remapped(through: slot), op, rhs.remapped(through: slot))
    case let .bound(term, op, parameter):
      .bound(term.remapped(through: slot), op, parameter)
    case let .match(left, right):
      .match(slot[left]!, slot[right]!)
    case let .null(term, negated):
      .null(term.remapped(through: slot), negated: negated)
    case let .and(lhs, rhs):
      .and(lhs.remapped(through: slot), rhs.remapped(through: slot))
    case let .or(lhs, rhs):
      .or(lhs.remapped(through: slot), rhs.remapped(through: slot))
    case let .not(operand):
      .not(operand.remapped(through: slot))
    }
  }

  /// The flat list of `AND`-conjuncts of this filter (a non-`and` is a
  /// singleton).
  internal var conjuncts: Array<Filter> {
    guard case let .and(lhs, rhs) = self else { return [self] }
    return lhs.conjuncts + rhs.conjuncts
  }
}

extension Array where Element == Filter {
  /// The right-leaning `AND` of these conjuncts, or `nil` for an empty list.
  internal var conjunction: Filter? {
    guard let last else { return nil }
    return dropLast().reversed().reduce(last) { .and($1, $0) }
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

/// Matches two typed values under operator `op`, under three-valued logic.
///
/// A `NULL` on either side is UNKNOWN (`nil`): `NULL` is unordered and unequal
/// to everything, itself included, so no comparison against it is ever true or
/// false. A like-typed non-null pair compares — two integers or two strings; a
/// cross-typed pair (an integer against a string, or the reverse) never matches.
private func matches(_ lhs: Value, _ op: Comparison, _ rhs: Value) -> Bool? {
  switch (lhs, rhs) {
  case (.null, _), (_, .null): nil
  case let (.integer(lhs), .integer(rhs)): op.apply(lhs, rhs)
  case let (.text(lhs), .text(rhs)): op.apply(lhs, rhs)
  default: false
  }
}

/// Evaluates `filter` against `row` under three-valued logic, resolving scalar
/// calls through `routines` and any bound parameter from `bindings`.
///
/// The result is `true`, `false`, or `nil` — SQL's UNKNOWN. A `compare`
/// evaluates both operand terms and matches them — a `NULL` operand making the
/// comparison UNKNOWN; a `bound` matches the left term against the parameter's
/// bound value, but an unbound or absent parameter is UNKNOWN (`nil`), not
/// `false` — a missing binding cannot be inverted into a match by `NOT`. A
/// `match` tests both cells equal under the same three-valued rule, so a `NULL`
/// join key matches nothing; a `null` is a definite test of whether its term
/// is `NULL` (`true`/`false`, never UNKNOWN), negated for `IS NOT NULL`. `AND`
/// and `OR` follow Kleene logic (`false` dominates `AND`, `true` dominates `OR`,
/// UNKNOWN otherwise) and `NOT` maps UNKNOWN to itself. The executor admits a
/// row only when the whole predicate is `true` (its `== true` gate), so UNKNOWN
/// and `false` both reject. The `borrowing` row is non-escaping; it threads
/// into the recursion freely and is never stored.
internal func evaluate<R: Row & ~Escapable>(_ filter: Filter,
                                            _ row: borrowing R,
                                            _ routines: Routines,
                                            _ bindings: Bindings)
    throws(SQLError) -> Bool? {
  switch filter {
  case let .compare(lhs, op, rhs):
    try matches(evaluate(lhs, row, routines), op, evaluate(rhs, row, routines))
  case let .bound(term, op, parameter):
    if let operand = bindings[parameter] {
      try matches(evaluate(term, row, routines), op, operand)
    } else {
      nil
    }
  case let .match(left, right):
    matches(row[left], .equal, row[right])
  case let .null(term, negated):
    try (evaluate(term, row, routines) == .null) != negated
  case let .and(lhs, rhs):
    // `&&`/`||` take an `@autoclosure` right operand, which would capture the
    // borrowed `~Escapable` row; spell each connective explicitly so a branch
    // re-borrows the row rather than capturing it. Kleene `AND`: `false`
    // dominates, an UNKNOWN left yields `false` only against a `false` right.
    switch try evaluate(lhs, row, routines, bindings) {
    case false?: false
    case true?: try evaluate(rhs, row, routines, bindings)
    case nil: try evaluate(rhs, row, routines, bindings) == false ? false : nil
    }
  case let .or(lhs, rhs):
    // Kleene `OR`: `true` dominates, an UNKNOWN left yields `true` only against
    // a `true` right.
    switch try evaluate(lhs, row, routines, bindings) {
    case true?: true
    case false?: try evaluate(rhs, row, routines, bindings)
    case nil: try evaluate(rhs, row, routines, bindings) == true ? true : nil
    }
  case let .not(operand):
    try evaluate(operand, row, routines, bindings).map { !$0 }
  }
}
