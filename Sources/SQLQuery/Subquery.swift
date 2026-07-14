// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The subquery layer: the operators that nest a built `Query` inside another —
// `IN (SELECT …)`, `EXISTS (…)`, a quantified `op {ANY|ALL} (…)`, and a scalar
// subquery in expression position. The engine grew these nodes (a subquery
// `Expression`/`Predicate`), so a builder lowers each to its real AST node
// exactly as `Statement(parsing:)` would for the equivalent SQL text.
//
// A nested query is UNCORRELATED when it names no column of the enclosing query
// — the engine runs it ONCE and memoises it — or CORRELATED when its inner
// `WHERE`/`ON` names an enclosing column, which the engine (PR243) re-executes
// PER OUTER ROW: it resolves an inner column reference OUTWARD when the
// subquery's own `FROM` does not bind it, binds the outer cell as a synthetic
// `:__correlated_…` parameter, and re-runs the inner plan against each outer
// row. Both shapes lower through the SAME operators below — correlation turns
// only on the inner query referencing an outer column. `outer(_:_:)` names that
// reference unambiguously (see its note on the qualifier-shadow rule), and
// `grouping`/`correlating` build the correlated inner query a LINQ group-join
// reduces per outer row.

// MARK: - Queryable

/// A built query that nests inside another as a subquery — the `Query` a
/// membership, `EXISTS`, quantified, or scalar-subquery operator wraps. Both a
/// `QueryBuilder` (one `SELECT`) and a `SetQuery` (a set operation) vend the
/// nested `Query`, so a subquery operator takes `some Queryable` and either
/// composes uniformly.
public protocol Queryable {
  /// The engine `Query` this lowers to, the node a subquery operator nests.
  var query: Query { get }
}

extension QueryBuilder: Queryable {}
extension SetQuery: Queryable {}

// MARK: - Membership

extension Term {
  /// `self IN (subquery)` — whether the term equals any value the `subquery`
  /// yields; the `subquery` must project exactly one column. It lowers to the
  /// engine's `within` predicate, the subquery form of the value-list `in`.
  /// Pass `negated: true` for `NOT IN`, mirroring the engine node's flag.
  public func `in`(_ subquery: some Queryable,
                   negated: Bool = false) -> Filter {
    Filter(.within(expression, subquery.query, negated: negated))
  }
}

// MARK: - EXISTS

/// `EXISTS (subquery)` — whether the `subquery` yields at least one row, a
/// two-valued test of cardinality alone. It lowers to the engine's `exists`
/// predicate. Pass `negated: true` for `NOT EXISTS`, mirroring the engine
/// node's flag.
public func exists(_ subquery: some Queryable,
                   negated: Bool = false) -> Filter {
  Filter(.exists(subquery.query, negated: negated))
}

// MARK: - Quantified comparison

/// A quantified subquery operand — the `{ANY | SOME | ALL} (subquery)` right
/// side of a quantified comparison. It pairs a quantifier with the nested
/// query; a comparison operator against a `Term` lowers the pair to the
/// engine's `quantified` predicate. `any(_:)` and `all(_:)` build one.
public struct Quantification: Sendable {
  fileprivate let quantifier: Quantifier
  fileprivate let query: Query

  fileprivate init(_ quantifier: Quantifier, _ query: Query) {
    self.quantifier = quantifier
    self.query = query
  }
}

/// `ANY (subquery)` — the quantifier a comparison holds against when it is TRUE
/// for at least one value the `subquery` yields (`SOME` is a synonym). The
/// `subquery` must project exactly one column.
public func any(_ subquery: some Queryable) -> Quantification {
  Quantification(.any, subquery.query)
}

/// `ALL (subquery)` — the quantifier a comparison holds against when it is TRUE
/// for every value the `subquery` yields. The `subquery` must project exactly
/// one column.
public func all(_ subquery: some Queryable) -> Quantification {
  Quantification(.all, subquery.query)
}

extension Term {
  /// `self <op> quantified` as a quantified-comparison `Filter`, lowering to
  /// the engine's `quantified` predicate — the shared spine the comparison
  /// operators against a `Quantification` return through.
  private func compare(_ op: Comparison,
                       _ quantified: Quantification) -> Filter {
    Filter(.quantified(expression, op, quantified.quantifier,
                       quantified.query))
  }

  public static func == (lhs: Term, rhs: Quantification) -> Filter {
    lhs.compare(.equal, rhs)
  }

  public static func != (lhs: Term, rhs: Quantification) -> Filter {
    lhs.compare(.unequal, rhs)
  }

  public static func < (lhs: Term, rhs: Quantification) -> Filter {
    lhs.compare(.lt, rhs)
  }

  public static func > (lhs: Term, rhs: Quantification) -> Filter {
    lhs.compare(.gt, rhs)
  }

  public static func <= (lhs: Term, rhs: Quantification) -> Filter {
    lhs.compare(.leq, rhs)
  }

  public static func >= (lhs: Term, rhs: Quantification) -> Filter {
    lhs.compare(.geq, rhs)
  }
}

// MARK: - Scalar subquery

/// `(subquery)` as a scalar `Term` — a nested query in expression position,
/// yielding its lone cell (NULL when it returns no row, a cardinality fault
/// when it returns more than one). The `subquery` must project exactly one
/// column. It lowers to the engine's `subquery` expression, so it composes in a
/// projection (`select(scalar(q).as("m"))`) or a comparison (`column("V") ==
/// scalar(q)`).
public func scalar(_ subquery: some Queryable) -> Term {
  Term(.subquery(subquery.query))
}

// MARK: - Correlation

/// A reference from inside a subquery to a column of an ENCLOSING query — the
/// term a correlated subquery names so the engine (PR243) re-executes it PER
/// OUTER ROW, resolving the reference outward and binding the outer cell.
///
/// It is a `column(_:_:)` qualified by the OUTER relation's `relation` name (or
/// alias), which is the unambiguous form the engine's QUALIFIER-SHADOW rule
/// requires: a subquery resolves a name against its OWN `FROM` first; a bare
/// unqualified name the inner `FROM` also carries binds LOCALLY (no
/// correlation), and a qualifier naming a LOCAL relation that LACKS the column
/// is a HARD `.column` fault (the inner alias shadows a same-name outer one).
/// A qualifier naming a relation the inner `FROM` does NOT answer is never
/// local, so it always correlates OUTWARD to the enclosing query — the shape
/// this builds. Correlation is admitted only in the inner `WHERE`/`ON`, so
/// place an `outer(_:_:)` reference there, not in the inner projection.
public func outer(_ relation: String, _ name: String) -> Term {
  column(relation, name)
}

// MARK: - Group join

extension QueryBuilder {
  /// The CORRELATED inner query a LINQ group-join reduces per outer row — this
  /// inner query filtered to the rows whose `inner` key equals the enclosing
  /// row's `outer` key. For each outer row the engine re-executes it against
  /// that row's `outer` cell (see `outer(_:_:)`), yielding the outer row's
  /// GROUP of matching inner rows. It returns a `QueryBuilder` (a `Queryable`),
  /// so a caller reduces the group with the subquery operator its result
  /// selector wants — `exists(outer.grouping(…))` for "has any match",
  /// `scalar(outer.grouping(…).select(count()))` for the group count, or
  /// `column("k").in(outer.grouping(…).select("k"))` for membership.
  public func grouping(on inner: Term, equals outer: Term) -> QueryBuilder {
    self.where(inner == outer)
  }

  /// The CORRELATED inner query a nested LINQ `SelectMany` reduces per outer
  /// row — this inner query filtered by a `predicate` naming an enclosing
  /// column (through `outer(_:_:)`). It is the flattening group-join's inner
  /// sequence: the engine re-executes it per outer row, and a caller reduces it
  /// with a subquery operator (`exists`/`scalar`/`in`). A group-join keyed on a
  /// single equality is `grouping(on:equals:)`; this takes an arbitrary
  /// correlated `predicate` for a non-equi correlation. (A LINQ `SelectMany`
  /// that FLATTENS the correlated inner rows INTO the outer set is `flatten`,
  /// which lowers to a `LATERAL` apply — see `QueryBuilder.swift`.)
  public func correlating(where predicate: Filter) -> QueryBuilder {
    self.where(predicate)
  }
}
