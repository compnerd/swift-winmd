// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A parsed SQL statement.
///
/// The dialect supports a single statement shape, with zero or more joins:
///
/// ```sql
/// SELECT <* | column (, column)*>
///   FROM <table> [AS alias]
///   (JOIN <table> [AS alias] ON <column> = <column>)*
///   [WHERE <predicate>] [ORDER BY <column> [ASC|DESC] (, …)*]
///   [OFFSET <skip> ROWS] [FETCH {FIRST | NEXT} <count> ROWS ONLY]
/// ```
///
/// The AST is a tree of fully escapable values — names, operators, and literal
/// operands — that any consumer may interpret. It carries no knowledge of the
/// relations it names; resolving the table, alias, and column identifiers is
/// the consumer's responsibility.
public enum Statement: Hashable, Sendable {
  /// A `SELECT` query — one `SELECT`, or several combined with `UNION`.
  case select(Query)
  /// A `CREATE VIEW name AS query`: the view's `name` and the `View` it binds
  /// — the stored `query` and the column names (explicit or inferred from the
  /// projection). A consumer registers the `View` under `name` in a catalog so
  /// a later `SELECT … FROM name` resolves it.
  case create(name: String, view: View)
  /// A `WITH [RECURSIVE] cte (, cte)* query`: the common table expressions
  /// `ctes`, in source order, scoping the trailing `query`. Each `CTE` binds a
  /// named relation the `query` — and a later `CTE` — may name; the engine
  /// materialises them in order into an overlay catalog the `query` runs
  /// against.
  case with(ctes: Array<CTE>, query: Query)
}

/// A common table expression — a query bound to a name for the duration of the
/// enclosing statement.
///
/// `name` is the relation name the trailing query (and a later `CTE`) resolves
/// against; `columns` names its columns in projection order — explicit from a
/// `(c, …)` list, else inferred from the query's first arm exactly as a view's
/// are. A `recursive` CTE names itself in its own `query` (which must be a
/// `UNION` of an anchor and a recursive arm); a non-recursive one does not. The
/// CTE is fully escapable data — the engine materialises its `query` into an
/// in-memory relation and resolves the name to it.
public struct CTE: Hashable, Sendable {
  /// The relation name the CTE binds.
  public let name: String

  /// The CTE's column names, in projection order.
  public let columns: Array<String>

  /// The query the CTE stands for.
  public let query: Query

  /// Whether the CTE is recursive — a `WITH RECURSIVE` member that may name
  /// itself in its own `query`.
  public let recursive: Bool

  public init(name: String, columns: Array<String>, query: Query,
              recursive: Bool) {
    self.name = name
    self.columns = columns
    self.query = query
    self.recursive = recursive
  }
}

/// A query: one `SELECT`, or several combined left-associatively with `UNION`.
///
/// A bare `SELECT` is the `select` case; `a UNION b UNION c` nests left —
/// `union(union(select(a), b, all:), c, all:)` — so the arms read in source
/// order. `UNION` removes duplicate result rows; `UNION ALL` (`all` true) keeps
/// them. Every arm must project the same number of columns, and the result
/// columns are the FIRST arm's projection (the ISO rule).
public indirect enum Query: Hashable, Sendable {
  /// A single `SELECT`.
  case select(Select)
  /// A `UNION` (or `UNION ALL` when `all`) of a query and a further `SELECT`,
  /// the new arm appended on the right so the chain reads left to right.
  case union(Query, Select, all: Bool)

  /// The first `SELECT` of the query — the leftmost arm, reached by descending
  /// the left-associative chain. Its projection names the result columns (the
  /// ISO rule), so a `CREATE VIEW` infers a union's columns from it.
  public var first: Select {
    switch self {
    case let .select(select): select
    case let .union(query, _, _): query.first
    }
  }
}

/// A `SELECT` query: a projection over one relation or a chain of joins, with an
/// optional predicate, ordering, and row limit.
///
/// `from` is optional: a FROM-less `SELECT <expr-list>` yields exactly one row
/// whose columns are the evaluated projection expressions, the standard SQL
/// way to compute a scalar (`SELECT 1 + 1`). A FROM-less select carries no
/// joins, and its projection may not be a `SELECT *` — there is no relation to
/// expand — nor a bare-column reference; only literals, calls, and arithmetic
/// over them resolve against the empty row.
public struct Select: Hashable, Sendable {
  /// The columns the query yields.
  public let projection: Projection

  /// The primary relation the query scans, or `nil` for a FROM-less `SELECT`
  /// that projects over a single empty row.
  public let from: Relation?

  /// The joins applied to `from`, in source order — `from JOIN joins[0] JOIN
  /// joins[1] …`, a left-deep chain. Empty for a single-relation query and for
  /// a FROM-less one.
  public let joins: Array<Join>

  /// The row filter, if any.
  public let predicate: Predicate?

  /// The `GROUP BY` columns, in source order — empty for a query with no
  /// explicit grouping. A query that aggregates without a `GROUP BY` (`SELECT
  /// COUNT(*) FROM T`) leaves this empty and aggregates the whole result as a
  /// single group.
  public let grouping: Array<Column>

  /// The `HAVING` filter over the grouped rows, if any — a predicate the engine
  /// applies AFTER aggregation, so it may reference the aggregates and the
  /// grouping columns. A `HAVING` without a `GROUP BY` filters the single
  /// whole-result group.
  public let having: Predicate?

  /// The ordering applied to the result, if any.
  public let order: Order?

  /// The row limit applied to the (ordered) result, if any.
  public let limit: Limit?

  public init(projection: Projection, from: Relation?,
              joins: Array<Join> = [], predicate: Predicate? = nil,
              grouping: Array<Column> = [], having: Predicate? = nil,
              order: Order? = nil, limit: Limit? = nil) {
    self.projection = projection
    self.from = from
    self.joins = joins
    self.predicate = predicate
    self.grouping = grouping
    self.having = having
    self.order = order
    self.limit = limit
  }

  /// The name of the primary relation, or the empty string for a FROM-less
  /// `SELECT`.
  ///
  /// Retained for single-relation consumers that only ever name one table; it
  /// reads the `from` relation's name.
  public var table: String {
    from?.name ?? ""
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
/// adapter-computed columns `Id` (every table's 1-based row identity) and a
/// list-child's owner foreign key within those references.
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
/// real column or one of the binding's adapter-computed columns (`Id`, an owner
/// foreign key); the AST does not distinguish them.
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
  /// `lhs <op> rhs` — a binary arithmetic expression over two sub-expressions,
  /// the engine evaluating it per row to a typed `Value`.
  case binary(Arithmetic, Expression, Expression)
  /// An aggregate function over a group of rows — `COUNT(*)`, `COUNT(x)`,
  /// `SUM(x)`, `MIN(x)`, `MAX(x)`, `AVG(x)`. Unlike a scalar `call` (evaluated
  /// per row), an aggregate accumulates over every row of a group and yields one
  /// value, so the engine recognises the fixed set of aggregate names at parse
  /// time and lowers them through a dedicated mechanism rather than the routines.
  case aggregate(Aggregate, of: Aggregand)
}

/// A standard SQL aggregate function.
///
/// The engine recognises this fixed set by name (case-insensitively) at parse
/// time, distinct from a scalar-function `call`. `COUNT` counts rows (or
/// non-NULL values); `SUM`/`AVG` total and average the non-NULL integers;
/// `MIN`/`MAX` take the least/greatest non-NULL value by the engine's typed
/// comparison.
public enum Aggregate: Hashable, Sendable {
  /// `COUNT` — the number of rows (`*`) or of non-NULL values.
  case count
  /// `SUM` — the total of the non-NULL integer values.
  case sum
  /// `MIN` — the least non-NULL value.
  case min
  /// `MAX` — the greatest non-NULL value.
  case max
  /// `AVG` — the average of the non-NULL integer values.
  case avg
}

/// An aggregate's operand: `*` (rows), valid only for `COUNT`, or a scalar
/// expression evaluated per row and aggregated over the group.
public enum Aggregand: Hashable, Sendable {
  /// `*` — the whole row, the operand of `COUNT(*)`. It counts every row of the
  /// group, NULLs included, so it is admitted only for `COUNT`.
  case star
  /// An expression evaluated per row; the aggregate folds its non-NULL values
  /// over the group.
  case expression(Expression)
}

/// A binary arithmetic operator.
///
/// The four standard operators over integers; `*` `/` bind tighter than `+`
/// `-`, and all four are left-associative — the precedence the parser's
/// climbing grammar encodes and parentheses override.
public enum Arithmetic: Hashable, Sendable {
  /// `+`
  case add
  /// `-`
  case subtract
  /// `*`
  case multiply
  /// `/` — integer division.
  case divide
}

/// A row filter — a tree of comparisons composed with `AND`, `OR`, and `NOT`.
///
/// The tree is `data`, not an opaque closure, so a consumer may inspect it (for
/// example to lower an equality test on a sorted column to a binary search).
public indirect enum Predicate: Hashable, Sendable {
  /// `left <op> right` — each operand a scalar `Expression` (a column, a
  /// literal, or a call to a registered scalar function).
  case comparison(left: Expression, op: Comparison, right: Expression)
  /// `left <op> :parameter` — the left a scalar `Expression`, the operand
  /// resolved at run time from the engine's bindings (the correlated-subquery
  /// primitive a child view keys on the parent's value).
  case bound(left: Expression, op: Comparison, parameter: String)
  /// `operand IS NULL`, or `IS NOT NULL` when `negated` — a definite test of
  /// whether the operand evaluates to `NULL` (never itself UNKNOWN), the way a
  /// nullable column — an absent decoded attribute — is filtered (`WHERE iid IS
  /// NOT NULL`).
  case null(Expression, negated: Bool)
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
  /// An integer literal — a bare run of digits, exact numeric.
  case integer(Int)
  /// An approximate-numeric literal — a decimal with a `.` fraction and/or an
  /// exponent (`3.14`, `1.0`, `1e3`, `2.5e-1`), a binary64 `Double`.
  case double(Double)
}

/// An `ORDER BY` clause: an ordered list of sort keys, each a column and its
/// own direction.
///
/// The keys are applied major to minor — `ORDER BY a, b DESC, c` sorts by `a`
/// ascending, breaks ties by `b` descending, then breaks the rest by `c`
/// ascending — so `keys[0]` is the primary key and each later key orders only
/// the rows the earlier keys leave equal. A per-key `ASC`/`DESC` governs that
/// key alone (default `ASC`); `keys` is never empty.
public struct Order: Hashable, Sendable {
  /// One sort key: the column to order on and its direction.
  public struct Key: Hashable, Sendable {
    /// The column this key orders on.
    public let column: Column

    /// Whether this key is ascending (`ASC`, the default) rather than
    /// descending (`DESC`).
    public let ascending: Bool

    public init(column: Column, ascending: Bool = true) {
      self.column = column
      self.ascending = ascending
    }
  }

  /// The sort keys, in major-to-minor order — `keys[0]` is the primary key.
  public let keys: Array<Key>

  public init(keys: Array<Key>) {
    self.keys = keys
  }

  /// A single-key `ORDER BY` — the common case, ordering on one column.
  public init(column: Column, ascending: Bool = true) {
    self.init(keys: [Key(column: column, ascending: ascending)])
  }
}

/// A row-limiting clause — the standard `OFFSET <n> ROWS FETCH { FIRST | NEXT }
/// <n> ROWS ONLY` — pairing an optional leading skip with an optional cap.
///
/// It applies to the ordered result — after `WHERE` and `ORDER BY`, but before
/// the projection, so a row outside the page is never projected: skip the first
/// `offset` rows, then take at most `count`. The two ISO clauses are independent
/// — an `OFFSET` written without a `FETCH` leaves `count` `nil` (no cap, every
/// row after the skip), and a `FETCH` without an `OFFSET` caps from the start
/// (`offset` `0`). Both counts are non-negative; a `count` of `0` yields no rows
/// and an `offset` past the end yields none.
public struct Limit: Hashable, Sendable {
  /// The greatest number of rows the result yields, or `nil` for no cap — an
  /// `OFFSET` written without a `FETCH`.
  public let count: Int?

  /// The number of leading rows skipped before the count applies — `0` when no
  /// `OFFSET` was written.
  public let offset: Int

  public init(count: Int?, offset: Int = 0) {
    self.count = count
    self.offset = offset
  }
}

// MARK: - Scalar-call inventory

extension Query {
  /// The names of every scalar-function `call` anywhere in the query — across
  /// both arms of a `UNION` and every call-bearing clause of each arm.
  ///
  /// The introspection builder checks these against the registered routines
  /// before advertising a view. `compile` resolves a call's ARGUMENTS but
  /// cannot check the routine EXISTS — it holds no routine set and builds no
  /// call term, the name binding only at execute — so a call to an unregistered
  /// function in a `WHERE`/`HAVING` or a later `UNION` arm, invisible to the
  /// first-arm projection type walk, would otherwise be advertised though a run
  /// faults `SQLError.function`.
  internal var calls: Set<String> {
    switch self {
    case let .select(select):
      select.calls
    case let .union(query, select, _):
      query.calls.union(select.calls)
    }
  }
}

extension Select {
  /// The scalar-call names across this arm's call-bearing clauses — the
  /// projection expressions, the `WHERE`, and the `HAVING`. `GROUP BY`, the
  /// join equalities, and `ORDER BY` are column references, never calls.
  internal var calls: Set<String> {
    var names = Set<String>()
    if case let .expressions(items) = projection {
      for item in items { names.formUnion(item.expression.calls) }
    }
    if let predicate { names.formUnion(predicate.calls) }
    if let having { names.formUnion(having.calls) }
    return names
  }
}

extension Predicate {
  /// The scalar-call names within this predicate tree.
  internal var calls: Set<String> {
    switch self {
    case let .comparison(left, _, right):
      left.calls.union(right.calls)
    case let .bound(left, _, _):
      left.calls
    case let .null(operand, _):
      operand.calls
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.calls.union(rhs.calls)
    case let .not(operand):
      operand.calls
    }
  }
}

extension Expression {
  /// The scalar-call names within this expression — the call itself and every
  /// call nested in its arguments, a binary's operands, or an aggregate's
  /// operand. A bare column or literal names none.
  internal var calls: Set<String> {
    switch self {
    case .column, .literal:
      []
    case let .call(name, arguments):
      arguments.reduce(into: Set([name])) { $0.formUnion($1.calls) }
    case let .binary(_, lhs, rhs):
      lhs.calls.union(rhs.calls)
    case let .aggregate(_, operand):
      if case let .expression(expression) = operand {
        expression.calls
      } else {
        []
      }
    }
  }
}
