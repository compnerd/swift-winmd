// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The scalar layer of the query builder: a `Term` — a proxy for a value the
// engine computes per row — and the operator overloads that combine terms into
// the `Expression` and `Predicate` nodes the engine executes.
//
// Swift cannot reflect a closure body into an expression tree the way C#'s
// `Expression<Func<…>>` does, so a predicate is not captured from a plain
// `{ $0.x > 3 }`; it is BUILT from operator-overloaded proxies.
// `column("x") == 3` evaluates the `==` overload on a `Term` (the column) and a
// lifted literal, yielding a `Predicate.comparison` — the operators construct
// the tree the way the parser would for the equivalent SQL text, because the
// operands are these proxy types, not raw values.

// MARK: - ValueConvertible

/// A Swift value that lifts into a SQL scalar `Term`, so a predicate or a
/// projection is written with bare literals — `column("Flags") == 32` rather
/// than `column("Flags") == .literal(.integer(32))`.
///
/// The conformances mirror `Value`'s cases: `Int` lifts to an integer literal,
/// `String` to text, `Bool` to a boolean, `Double` to an approximate numeric,
/// and `Array<UInt8>` to a blob. A `Term` is itself convertible (the identity),
/// so an overload taking `some Term` accepts both a raw literal and a column
/// reference uniformly.
public protocol TermConvertible {
  /// The scalar term this lifts to.
  var term: Term { get }
}

extension Int: TermConvertible {
  public var term: Term { Term(.literal(.integer(self))) }
}

extension String: TermConvertible {
  public var term: Term { Term(.literal(.string(self))) }
}

extension Bool: TermConvertible {
  public var term: Term { Term(.literal(.boolean(self))) }
}

extension Double: TermConvertible {
  public var term: Term { Term(.literal(.double(self))) }
}

extension Array: TermConvertible where Element == UInt8 {
  public var term: Term { Term(.literal(.blob(self))) }
}

// MARK: - Term

/// A scalar term — a proxy over an `Expression` the engine evaluates per row.
///
/// A term wraps a column reference, a literal, a scalar-function call, an
/// arithmetic combination, or an aggregate. The operator overloads (`==`, `<`,
/// `+`, `||`, …) and the predicate helpers (`isNull`, `like`, `between`, `in`)
/// combine terms into the engine's `Expression`/`Predicate` nodes; `expression`
/// exposes the built `Expression` for a projection.
public struct Term: TermConvertible, Hashable, Sendable {
  /// The engine expression this term lowers to.
  public let expression: Expression

  public init(_ expression: Expression) {
    self.expression = expression
  }

  public var term: Term { self }
}

/// A column reference by name, the untyped root of the scalar layer — the
/// dynamic form the memo recommends for winmd relations, which have no
/// hand-authored Swift entity type. The `spelling` follows `Column`'s
/// last-dot rule (`"t.Name"` qualifies, `"Flags"` does not).
public func column(_ spelling: String) -> Term {
  Term(.column(Column(spelling)))
}

/// A column reference by an explicit qualifier and name — the form a caller
/// reaches for when a column name itself contains a dot the last-dot split
/// would misread.
public func column(_ qualifier: String, _ name: String) -> Term {
  Term(.column(Column(qualifier: qualifier, name: name)))
}

// MARK: - Arithmetic

extension Term {
  /// `self <op> other` as a `binary` arithmetic term, lifting a bare literal
  /// operand through `TermConvertible`.
  private func binary(_ op: Arithmetic,
                      _ other: some TermConvertible) -> Term {
    Term(.binary(op, expression, other.term.expression))
  }

  public static func + (lhs: Term, rhs: some TermConvertible) -> Term {
    lhs.binary(.add, rhs)
  }

  public static func - (lhs: Term, rhs: some TermConvertible) -> Term {
    lhs.binary(.subtract, rhs)
  }

  public static func * (lhs: Term, rhs: some TermConvertible) -> Term {
    lhs.binary(.multiply, rhs)
  }

  public static func / (lhs: Term, rhs: some TermConvertible) -> Term {
    lhs.binary(.divide, rhs)
  }

  /// `self || other` — ISO text concatenation.
  public func concatenating(_ other: some TermConvertible) -> Term {
    binary(.concatenate, other)
  }
}
