// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The predicate layer: a `Filter` — a proxy over a `Predicate` — and the
// operator overloads that build one. `column("x") == 3` yields a `Filter`, and
// `&&`/`||`/`!` combine filters into the engine's `and`/`or`/`not` nodes; the
// `WHERE`, `ON`, and `HAVING` clauses each take a `Filter` and lower its
// `predicate`.

/// A predicate proxy — a wrapper over the engine's `Predicate` the comparison
/// and logical operators build, so a fluent `.where(column("x") == 3 && …)`
/// reads as the condition it lowers to.
public struct Filter: Hashable, Sendable {
  /// The engine predicate this filter lowers to.
  public let predicate: Predicate

  public init(_ predicate: Predicate) {
    self.predicate = predicate
  }
}

// MARK: - Comparisons

extension Term {
  /// `self <op> other` as a comparison `Filter`, lifting a bare literal operand
  /// through `TermConvertible` so `column("x") == 3` needs no `.literal` rite.
  private func compare(_ op: Comparison,
                       _ other: some TermConvertible) -> Filter {
    Filter(.comparison(left: expression, op: op,
                       right: other.term.expression))
  }

  public static func == (lhs: Term, rhs: some TermConvertible) -> Filter {
    lhs.compare(.equal, rhs)
  }

  public static func != (lhs: Term, rhs: some TermConvertible) -> Filter {
    lhs.compare(.unequal, rhs)
  }

  public static func < (lhs: Term, rhs: some TermConvertible) -> Filter {
    lhs.compare(.lt, rhs)
  }

  public static func > (lhs: Term, rhs: some TermConvertible) -> Filter {
    lhs.compare(.gt, rhs)
  }

  public static func <= (lhs: Term, rhs: some TermConvertible) -> Filter {
    lhs.compare(.leq, rhs)
  }

  public static func >= (lhs: Term, rhs: some TermConvertible) -> Filter {
    lhs.compare(.geq, rhs)
  }
}

// MARK: - Null / membership / like / between

extension Term {
  /// `self IS NULL` — a definite test of whether the term evaluates to NULL.
  public var isNull: Filter {
    Filter(.null(expression, negated: false))
  }

  /// `self IS NOT NULL`.
  public var isNotNull: Filter {
    Filter(.null(expression, negated: true))
  }

  /// `self IN (values)` — whether the term equals any of the listed values,
  /// each lifted through `TermConvertible`. The engine requires a non-empty
  /// list. Pass `negated: true` for `NOT IN`, mirroring the engine node's flag.
  public func `in`(_ values: any TermConvertible...,
                   negated: Bool = false) -> Filter {
    Filter(.membership(expression, values.map(\.term.expression),
                       negated: negated))
  }

  /// `self LIKE pattern [ESCAPE escape]` — whether the term's text matches the
  /// pattern (`%` any run, `_` one character). Pass `negated: true` for
  /// `NOT LIKE`, mirroring the engine node's flag.
  public func like(_ pattern: String, escape: String? = nil,
                   negated: Bool = false) -> Filter {
    Filter(.like(expression,
                 pattern: .expression(.literal(.string(pattern))),
                 escape: escape.map { .expression(.literal(.string($0))) },
                 negated: negated))
  }

  /// `self BETWEEN lower AND upper` — whether the term is within the inclusive
  /// range, each bound lifted through `TermConvertible`. Pass `negated: true`
  /// for `NOT BETWEEN`, mirroring the engine node's flag.
  public func between(_ lower: some TermConvertible,
                      and upper: some TermConvertible,
                      negated: Bool = false) -> Filter {
    Filter(.between(expression, .expression(lower.term.expression),
                    .expression(upper.term.expression), negated: negated))
  }
}

// MARK: - Logical combinators

/// `lhs AND rhs`.
public func && (lhs: Filter, rhs: Filter) -> Filter {
  Filter(.and(lhs.predicate, rhs.predicate))
}

/// `lhs OR rhs`.
public func || (lhs: Filter, rhs: Filter) -> Filter {
  Filter(.or(lhs.predicate, rhs.predicate))
}

/// `NOT operand`.
public prefix func ! (operand: Filter) -> Filter {
  Filter(.not(operand.predicate))
}
