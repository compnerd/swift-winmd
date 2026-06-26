// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A parsed SQL statement.
///
/// The dialect supports a single statement shape, now with an optional join:
///
/// ```sql
/// SELECT <* | column (, column)*>
///   FROM <table> [AS alias]
///   [JOIN <table> [AS alias] ON <column> = <column>]
///   [WHERE <predicate>] [ORDER BY <column> [ASC|DESC]]
/// ```
///
/// The AST is a tree of fully escapable values — names, operators, and literal
/// operands — that any consumer may interpret. It carries no knowledge of the
/// relations it names; resolving the table, alias, and column identifiers is
/// the consumer's responsibility.
public enum Statement: Hashable, Sendable {
  case select(Select)
}

/// A `SELECT` query: a projection over one relation or a join of two, with an
/// optional predicate and ordering.
public struct Select: Hashable, Sendable {
  /// The columns the query yields.
  public let projection: Projection

  /// The primary relation the query scans.
  public let from: Relation

  /// The join applied to `from`, if any.
  public let join: Join?

  /// The row filter, if any.
  public let predicate: Predicate?

  /// The ordering applied to the result, if any.
  public let order: Order?

  public init(projection: Projection, from: Relation, join: Join? = nil,
              predicate: Predicate? = nil, order: Order? = nil) {
    self.projection = projection
    self.from = from
    self.join = join
    self.predicate = predicate
    self.order = order
  }

  /// The name of the primary relation.
  ///
  /// Retained for single-relation consumers that only ever name one table; it
  /// reads the `from` relation's name.
  public var table: String {
    from.name
  }
}

/// A named relation in a `FROM` or `JOIN`, with an optional alias.
///
/// `name` is the relation's spelling; `alias`, when present, is the short name
/// a qualified column reference may use in its place (`FROM TypeDef AS t`).
public struct Relation: Hashable, Sendable {
  /// The relation's name.
  public let name: String

  /// The alias bound to the relation, if any.
  public let alias: String?

  public init(name: String, alias: String? = nil) {
    self.name = name
    self.alias = alias
  }
}

/// A `JOIN` clause: a second relation and the equality that relates it to the
/// rows already in scope.
///
/// The `ON` equality is held as its two column references in source order —
/// `left = right` — for the consumer to classify. The binding interprets the
/// pseudo-columns `rowid` (every table's 1-based row index) and `parent` (a
/// list-child's owning row) within those references.
public struct Join: Hashable, Sendable {
  /// The relation joined in.
  public let relation: Relation

  /// The left side of the `ON` equality.
  public let left: Column

  /// The right side of the `ON` equality.
  public let right: Column

  public init(relation: Relation, left: Column, right: Column) {
    self.relation = relation
    self.left = left
    self.right = right
  }
}

/// A possibly-qualified column reference: an optional relation qualifier and a
/// column name (`t.Name`, or a bare `Name`).
///
/// A qualifier names a relation by its alias or its table name; an unqualified
/// reference leaves the relation for the consumer to infer. The name may be a
/// real column or one of the binding's pseudo-columns (`rowid`, `parent`); the
/// AST does not distinguish them.
///
/// `Column` is `ExpressibleByStringLiteral`, splitting a literal on its first
/// dot into qualifier and name, so a consumer may write a reference as a plain
/// string (`"t.Name"`, `"Flags"`).
public struct Column: Hashable, Sendable, ExpressibleByStringLiteral {
  /// The relation qualifier, if any.
  public let qualifier: String?

  /// The column name.
  public let name: String

  public init(qualifier: String? = nil, name: String) {
    self.qualifier = qualifier
    self.name = name
  }

  /// Parses a reference from its dotted spelling: the text before the first dot
  /// is the qualifier and the rest is the name; an undotted spelling is an
  /// unqualified name.
  public init(_ spelling: String) {
    if let dot = spelling.firstIndex(of: ".") {
      self.qualifier = String(spelling[..<dot])
      self.name = String(spelling[spelling.index(after: dot)...])
    } else {
      self.qualifier = nil
      self.name = spelling
    }
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }
}

/// The columns a query yields.
public enum Projection: Hashable, Sendable {
  /// `SELECT *` — every column of the relation(s) in scope.
  case all
  /// `SELECT a, b, c` — the named columns, in order.
  case columns(Array<Column>)
  /// `SELECT f(a), b` — projected expressions, in order, each an optional
  /// alias over a scalar `Expression` (a bare column, a literal, or a call to a
  /// registered scalar function). The parser emits this only when a projection
  /// carries a function call or an alias; a list of bare columns stays the
  /// simpler `columns` case.
  case expressions(Array<Projected>)
}

/// One projected expression with an optional output alias.
///
/// A bare column projects as `Expression.column`; `f(a) AS x` carries the call
/// and the alias `x`. The alias names the output column for a downstream
/// consumer (a view's column, a template field); the engine yields positional
/// rows and does not itself use the alias.
public struct Projected: Hashable, Sendable {
  /// The expression the column yields.
  public let expression: Expression

  /// The output alias, if any.
  public let alias: String?

  public init(expression: Expression, alias: String? = nil) {
    self.expression = expression
    self.alias = alias
  }
}

/// A scalar expression — a value computed per row.
///
/// An expression is a bare column reference, a literal constant, or a call to a
/// registered scalar function over argument expressions. The engine resolves a
/// `column` to an ordinal, evaluates a `call` through the routines, and
/// yields a typed `Value`. This is the layer the per-dialect decode functions
/// (`guid`, `ret_type`, …) plug into: each is a registered scalar function the
/// projection calls.
public indirect enum Expression: Hashable, Sendable {
  /// A bare column reference, resolved to an ordinal.
  case column(Column)
  /// A literal constant.
  case literal(Literal)
  /// A call to the named scalar function over its arguments, in order.
  case call(name: String, arguments: Array<Expression>)
}

/// A row filter — a tree of comparisons composed with `AND`, `OR`, and `NOT`.
///
/// The tree is `data`, not an opaque closure, so a consumer may inspect it (for
/// example to lower an equality test on a sorted column to a binary search).
public indirect enum Predicate: Hashable, Sendable {
  /// `left <op> right` — each operand a scalar `Expression` (a column, a
  /// literal, or a call to a registered scalar function).
  case comparison(left: Expression, op: Comparison, right: Expression)
  /// `lhs AND rhs`.
  case and(Predicate, Predicate)
  /// `lhs OR rhs`.
  case or(Predicate, Predicate)
  /// `NOT operand`.
  case not(Predicate)
}

/// A comparison operator.
public enum Comparison: Hashable, Sendable {
  /// `=`
  case equal
  /// `<>`
  case unequal
  /// `<`
  case lt
  /// `>`
  case gt
  /// `<=`
  case leq
  /// `>=`
  case geq
}

/// A literal operand of a comparison.
public enum Literal: Hashable, Sendable {
  /// A single-quoted string literal, with its escapes resolved.
  case string(String)
  /// An integer literal.
  case integer(Int)
}

/// An `ORDER BY` clause: a column and its direction.
public struct Order: Hashable, Sendable {
  /// The column the result is ordered on.
  public let column: Column

  /// Whether the order is ascending (`ASC`, the default) rather than
  /// descending (`DESC`).
  public let ascending: Bool

  public init(column: Column, ascending: Bool = true) {
    self.column = column
    self.ascending = ascending
  }
}
