// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A parsed SQL statement.
///
/// The dialect supports a single statement shape, with zero or more joins:
///
/// ```sql
/// SELECT <* | column (, column)*>
///   FROM <table> [AS alias]
///   ([INNER | (LEFT | RIGHT | FULL) [OUTER]] JOIN <table> [AS alias]
///     ON <predicate>)*
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
  /// A `CREATE FUNCTION name(param TYPE, …) RETURNS TYPE AS expression`: the
  /// scalar function's `name` and the `Function` it binds — the declared
  /// parameters, result type, and the SQL body expression. A consumer registers
  /// the `Function` under `name` into its `Routines` (as it registers a `View`
  /// into a catalog) so a later call `name(…)` in a projection or predicate
  /// resolves to it.
  case function(name: String, function: Function)
}

/// A user-defined scalar function — a named SQL expression over named
/// parameters, registered as a routine.
///
/// A defined function is the SQL counterpart of a native `Routine` closure: its
/// `body` is a scalar `Expression` over the `parameters` (each a name and a
/// declared type), yielding the declared `returns` type. It is fully escapable
/// data — no borrowed storage — so a consumer threads it into the `Routines`
/// map beside the borrowing catalog, exactly as a `View` sits in a catalog. A
/// call binds its evaluated arguments to the parameter names and evaluates the
/// body (see `Routine`'s defined initializer).
public struct Function: Hashable, Sendable {
  /// One declared parameter — its name and value type.
  public struct Parameter: Hashable, Sendable {
    /// The parameter's name — the identifier the body references it by.
    public let name: String

    /// The parameter's declared value type.
    public let type: ValueType

    public init(name: String, type: ValueType) {
      self.name = name
      self.type = type
    }
  }

  /// The declared parameters, in order — their count the function's arity.
  public let parameters: Array<Parameter>

  /// The declared result type.
  public let returns: ValueType

  /// The scalar expression the function computes over its parameters.
  public let body: Expression

  public init(parameters: Array<Parameter>, returns: ValueType,
              body: Expression) {
    self.parameters = parameters
    self.returns = returns
    self.body = body
  }
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

/// One of the ISO set operators combining two query terms.
///
/// Each combines the rows of a left and a right term — its arms — into one
/// result: `union` keeps the rows of either, `intersect` the rows of both, and
/// `except` the rows of the left not in the right. The `Query.setop` node pairs
/// a `kind` with an `all` flag governing duplicate handling (see `setop`).
public enum SetOperation: Hashable, Sendable {
  /// `UNION` — the rows of either arm.
  case union
  /// `INTERSECT` — the rows present in both arms.
  case intersect
  /// `EXCEPT` — the rows of the left arm not present in the right.
  case except
}

/// A query: one `SELECT`, or several combined with a set operator.
///
/// A bare `SELECT` is the `select` case; two query terms combined by a set
/// operator (`UNION`, `INTERSECT`, `EXCEPT`) form a `setop` node. `INTERSECT`
/// binds tighter than `UNION`/`EXCEPT` (the ISO precedence), and
/// same-precedence operators associate left — `a UNION b UNION c` nests left,
/// `setop(.union, setop(.union, select(a), select(b), all:), select(c), all:)`,
/// so the arms read in source order, while `a UNION b INTERSECT c` binds as
/// `a UNION (b INTERSECT c)`. Without `all` a set operation removes duplicate
/// result rows; with `all` (`ALL`) it keeps them per the operator's
/// multiplicity rule. Every arm must project the same number of columns, and
/// the result columns are the FIRST arm's projection (the ISO rule).
public indirect enum Query: Hashable, Sendable {
  /// A single `SELECT`.
  case select(Select)
  /// A set operation of `kind` (`UNION`/`INTERSECT`/`EXCEPT`, `ALL` when `all`)
  /// over a left and a right query term, the right appended so a
  /// same-precedence chain reads left to right.
  case setop(SetOperation, Query, Query, all: Bool)

  /// The first `SELECT` of the query — the leftmost arm, reached by descending
  /// the left arm of each set operation. Its projection names the result
  /// columns (the ISO rule), so a `CREATE VIEW` infers a set operation's
  /// columns from it.
  public var first: Select {
    switch self {
    case let .select(select): select
    case let .setop(_, left, _, _): left.first
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
  /// Whether `SELECT DISTINCT` was written — the result rows are deduplicated,
  /// the first occurrence of each distinct row kept. `false` for the default
  /// `SELECT` (equivalently the explicit `SELECT ALL`), which keeps every row.
  public let distinct: Bool

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

  public init(distinct: Bool = false, projection: Projection,
              from: Relation?, joins: Array<Join> = [],
              predicate: Predicate? = nil, grouping: Array<Column> = [],
              having: Predicate? = nil, order: Order? = nil,
              limit: Limit? = nil) {
    self.distinct = distinct
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

/// A `JOIN` clause: a second relation, its join `kind`, and the `ON` predicate
/// that relates it to the rows already in scope.
///
/// The `ON` predicate is an arbitrary boolean expression over the relation
/// joined in and the ones already in scope — the same predicate grammar a
/// `WHERE` admits — so a join may relate its sides by an equality (`a.x =
/// b.y`), an inequality (`a.x < b.y`), an expression equality (`a.x = b.y +
/// 1`), or any `AND`/`OR`/`NOT` of comparisons. A pure `column = column`
/// equality conjunct still lowers to a hash-join key; the rest becomes a
/// residual filter over the join (nested-loop semantics). The consumer
/// interprets the adapter-computed columns `Id` (every table's 1-based row
/// identity) and a list-child's owner foreign key within the predicate's column
/// references.
///
/// `kind` is the inner/outer variety: `inner` (the default) keeps only matched
/// pairs, while a `left`/`right`/`full` OUTER join additionally preserves the
/// unmatched rows of the left, right, or both sides, NULL-extending the other
/// side's columns. The `ON` predicate governs MATCHING alone — an unmatched
/// outer row is still emitted — which is distinct from a post-join `WHERE`.
public struct Join: Hashable, Sendable {
  /// The inner/outer variety of a join.
  public enum Kind: Hashable, Sendable {
    /// `[INNER] JOIN` — only matched pairs, the default.
    case inner
    /// `LEFT [OUTER] JOIN` — every left row, unmatched ones NULL-extended.
    case left
    /// `RIGHT [OUTER] JOIN` — every right row, unmatched ones NULL-extended.
    case right
    /// `FULL [OUTER] JOIN` — every row of both sides, unmatched NULL-extended.
    case full
  }

  /// The relation joined in.
  public let relation: Relation

  /// The inner/outer variety of this join.
  public let kind: Kind

  /// The `ON` predicate relating the joined-in relation to those in scope.
  public let on: Predicate

  public init(relation: Relation, kind: Kind = .inner, on: Predicate) {
    self.relation = relation
    self.kind = kind
    self.on = on
  }

  /// A `column = column` equi-join over `relation` — the common shape, as the
  /// two column references its `ON` equates.
  public init(relation: Relation, kind: Kind = .inner, left: Column,
              right: Column) {
    self.init(relation: relation, kind: kind,
              on: .comparison(left: .column(left), op: .equal,
                              right: .column(right)))
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
/// `Column` is `ExpressibleByStringLiteral`, splitting a literal on its LAST
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

  /// Parses a reference from its dotted spelling: the text before the LAST dot
  /// is the qualifier and the text after it is the name; an undotted spelling
  /// is an unqualified name.
  ///
  /// Splitting on the last dot keeps every single-dot reference identical
  /// (`t.Name` → qualifier `t`, name `Name`) while letting a two-part relation
  /// name qualify a column — the `INFORMATION_SCHEMA` overlay's dotted
  /// relations (`information_schema.tables.table_name` → qualifier
  /// `information_schema.tables`, name `table_name`). A bare identifier in this
  /// dialect carries more than one dot only for that reserved two-part
  /// namespace; a dotted metadata name reaches the parser delimited, so it
  /// never splits here.
  public init(_ spelling: String) {
    if let dot = spelling.lastIndex(of: ".") {
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

  /// A view's column names inferred from this projection — the ISO rule shared
  /// by `CREATE VIEW` without an explicit column list and the `View(_:)`
  /// convenience initializer.
  ///
  /// A `columns` projection yields each reference's name (the qualifier
  /// dropped); an `expressions` projection yields each item's inferable `name`
  /// (its alias, else a bare column's name); a non-column expression with no
  /// alias, and a `SELECT *`, have no inferable name and fault with
  /// `SQLError.named`.
  internal func names() throws(SQLError) -> Array<String> {
    switch self {
    case .all:
      throw .named("SELECT *")
    case let .columns(columns):
      return columns.map(\.name)
    case let .expressions(items):
      var names = Array<String>()
      for item in items {
        guard let name = item.name else {
          throw .named("an unaliased expression")
        }
        names.append(name)
      }
      return names
    }
  }
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

  /// The output name this item contributes, or `nil` when it has none — its
  /// alias, else a bare column's name; a non-column expression with no alias
  /// has no inferable name. It is the ONE derivation every output-name site
  /// shares: view/CTE column inference (`Projection.names()`, faulting on
  /// `nil`), the result-schema walk (substituting a positional `column N`),
  /// and an aggregate `ORDER BY`'s alias recording (recording only a `name`).
  internal var name: String? {
    if let alias { return alias }
    if case let .column(column) = expression { return column.name }
    return nil
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
  /// A `CASE` conditional expression — the result of its FIRST `when` whose
  /// predicate is TRUE (three-valued: UNKNOWN and FALSE both skip), else the
  /// `else` result, or `NULL` when there is no `ELSE`. The `when`s are held in
  /// source order.
  ///
  /// Both ISO forms reduce to this searched shape: a SEARCHED `CASE WHEN cond
  /// THEN r … END` carries its predicates directly, and a SIMPLE `CASE op WHEN v
  /// THEN r … END` is normalised at parse time to `WHEN op = v THEN r …`, so the
  /// engine models one conditional. The result expressions' types must unify to
  /// one result type (see resolution).
  case `case`(Array<When>, else: Expression?)
}

/// One `WHEN predicate THEN result` branch of a `CASE` expression — the guard
/// and the value it yields when the guard is the first TRUE one.
public struct When: Hashable, Sendable {
  /// The guard predicate — TRUE selects this branch (UNKNOWN and FALSE skip it).
  /// A simple `CASE`'s `WHEN value` is normalised to the equality `operand =
  /// value` here.
  public let when: Predicate

  /// The result expression this branch yields when its guard is the first TRUE.
  public let then: Expression

  public init(when: Predicate, then: Expression) {
    self.when = when
    self.then = then
  }
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
  /// `operand IN (v, …)`, or `NOT IN` when `negated` — whether the operand
  /// equals any value of the non-empty `values` list. It is ISO shorthand for a
  /// disjunction of equalities under three-valued logic: `x IN (a, b)` is `x = a
  /// OR x = b`, so a NULL operand or a NULL element makes an otherwise-unmatched
  /// test UNKNOWN rather than FALSE, and `NOT IN` is the negation of that (never
  /// TRUE when a NULL element is present). The engine lowers it to that
  /// disjunction rather than carrying a dedicated `Filter` case.
  case membership(Expression, Array<Expression>, negated: Bool)
  /// `operand [NOT] LIKE pattern [ESCAPE escape]` — whether the operand's text
  /// matches the pattern, in which `%` matches any sequence of characters
  /// (including the empty one) and `_` matches exactly one character; every
  /// other pattern character matches itself. An optional `ESCAPE escape` names
  /// a one-character escape whose following `%`, `_`, or escape character
  /// matches that literal character. It is three-valued: a NULL operand, a NULL
  /// pattern, or a NULL escape makes the result UNKNOWN, and `negated` (`NOT
  /// LIKE`) negates the three-valued result (UNKNOWN maps to itself). A
  /// non-text operand or pattern does not match — the engine's cross-kind
  /// comparison rule — so a run yields FALSE without faulting. The pattern and
  /// escape are each an `Operand` — an ordinary scalar expression or a run-time
  /// `:parameter` resolved from the engine's bindings — so a caller can bind a
  /// pattern (`Name LIKE :pattern`) rather than interpolate it.
  case like(Expression, pattern: Operand, escape: Operand?, negated: Bool)
  /// `lhs AND rhs`.
  case and(Predicate, Predicate)
  /// `lhs OR rhs`.
  case or(Predicate, Predicate)
  /// `NOT operand`.
  case not(Predicate)

  /// The pattern or escape operand of a `LIKE` predicate: either an ordinary
  /// scalar `Expression` (a literal, a column, or a call, evaluated per row) or
  /// a run-time `:parameter` (a name resolved from the engine's bindings, the
  /// same mechanism `Predicate.bound` uses for a comparison's right operand).
  ///
  /// SQL's grammar admits only an expression here, but a `:parameter` is not an
  /// expression token — it is consumed by the comparison arm — so LIKE carries
  /// its bindable operands through this dedicated form rather than widening
  /// every expression walk with a parameter case. An unbound parameter, or one
  /// bound to `NULL`, makes the LIKE UNKNOWN, as a `NULL` pattern or escape
  /// does.
  public enum Operand: Hashable, Sendable {
    /// An ordinary scalar expression, evaluated per row.
    case expression(Expression)
    /// A `:parameter` placeholder, resolved at run time from the bindings.
    case parameter(String)
  }
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
  /// A truth-valued literal — the keyword `TRUE` or `FALSE`. SQL's third truth
  /// value UNKNOWN is spelled `NULL`, not a literal here.
  case boolean(Bool)
  /// A binary-string literal — a hex `x'…'` run of byte pairs, its bytes taken
  /// verbatim.
  case blob(Array<UInt8>)
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
