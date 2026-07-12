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
///   [WHERE <predicate>]
///   [ORDER BY <integer | expression> [ASC|DESC] (, …)*]
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

  /// Whether the EXISTS cardinality `probe` preserves this select's existence —
  /// so an EXISTS-only occurrence may run the probe rather than a full run.
  ///
  /// It holds for a non-set-operation `SELECT` WITHOUT a `HAVING` that is
  /// EITHER non-`DISTINCT` (its cardinality is the source's, independent of the
  /// projected values) OR `DISTINCT` WITHOUT an `OFFSET`. `DISTINCT` collapses
  /// a non-empty source to at least one distinct row, so `SELECT DISTINCT 1
  /// FROM S` is non-empty iff `S` is — existence is preserved by the constant
  /// projection. An `OFFSET` breaks that: it skips DISTINCT rows, so emptiness
  /// depends on the REAL distinct count (`SELECT DISTINCT x FROM S OFFSET 5` is
  /// empty iff there are `≤ 5` distinct `x`), which the constant projection —
  /// one distinct row — would wrongly collapse; such a select is not
  /// probe-eligible.
  ///
  /// An aggregate/grouped select without a `HAVING` is probe-eligible: its
  /// cardinality is a source-only fact the probe preserves WITHOUT the original
  /// target (see `probe`). A whole-result aggregate (no `GROUP BY`) yields
  /// EXACTLY ONE row regardless of the source — so EXISTS is true modulo the
  /// limit — and a grouped one yields ONE ROW PER GROUP, so existence is the
  /// source's non-emptiness after `WHERE`. A `HAVING` is NOT eligible: group
  /// survival depends on the aggregate VALUES (which `HAVING` may reference),
  /// so cardinality is not a source-only fact and the target must run.
  internal var probable: Bool {
    guard having == nil else { return false }
    return !distinct || limit?.offset ?? 0 == 0
  }

  /// The EXISTS cardinality-probe rewrite of this select — the same
  /// FROM/`WHERE`/joins, the same `DISTINCT` quantifier, the same `GROUP BY`,
  /// and the SAME original `OFFSET`/`FETCH`, but its projection replaced with a
  /// cardinality-preserving target and its `ORDER BY` dropped — so a probe run
  /// tests whether the row source yields ANY row WITHOUT evaluating the
  /// original select list or sort keys.
  ///
  /// It preserves the row source (FROM, joins, `WHERE`) and the original row
  /// limit EXACTLY, so its cardinality matches this select's — enough for an
  /// existence test that honours the original limiting: a `FETCH FIRST 0 ROWS`
  /// probes zero rows (EXISTS false) and an `OFFSET` past the end probes none
  /// (false), neither overridden by a synthetic cap. `ORDER BY` is dropped
  /// because existence is order-independent (the row count after `OFFSET`/
  /// `FETCH` does not depend on order). A FROM-less `SELECT <exprs>` always
  /// yields exactly one row and cannot carry a limit, so its probe is just
  /// `SELECT <constant>` with NO limit — it compiles and yields one row
  /// (EXISTS true). `DISTINCT` is retained (the caller applies the probe to a
  /// `DISTINCT` select only when it has no `OFFSET`, so `SELECT DISTINCT 1 FROM
  /// S` yields exactly one distinct row iff `S` is non-empty).
  ///
  /// The probe target is chosen to preserve cardinality without the original:
  /// a NON-aggregate select projects the constant `1`, one row per source row;
  /// an aggregate/grouped one projects `COUNT(*)` (with the `GROUP BY` kept), a
  /// trivial always-computable aggregate whose grouping is the original's — a
  /// whole-result `COUNT(*)` yields exactly one row (even over an empty source)
  /// and a grouped one yields one row per group — so the probe's cardinality is
  /// the original's and the original target (e.g. `SUM(1 / 0)`) never runs. It
  /// is meaningful only where `probable` holds; the caller applies it only
  /// there.
  internal var probe: Select {
    let target: Expression = aggregates
        ? .aggregate(.count, of: .star)
        : .literal(.integer(1))
    let item = Projected(expression: target)
    return Select(distinct: distinct, projection: .expressions([item]),
                  from: from, joins: joins, predicate: predicate,
                  grouping: grouping, having: nil, order: nil, limit: limit)
  }

  /// Every expression the ORDER BY sort EVALUATES over its input rows — the
  /// direct sort-key expressions AND the projection expressions its OUTPUT
  /// shorthands reach — the ones a reachable type-check pass must validate as
  /// it does a projected expression.
  ///
  /// The compiled shape is `Project(Limit(Sort(input)))`: the sort is BELOW the
  /// limit and evaluates each key over the input rows BEFORE the cap pages
  /// them, so what the sort forces to evaluate is independent of whether the
  /// projection is reachable. Each ORDER BY key resolves to the expression the
  /// sort runs, mirroring the resolver's lowering:
  ///
  ///   - a direct `.expression(e)` key over the input columns yields `e`;
  ///   - a bare unqualified column matching a projected explicit-`AS` OUTPUT
  ///     ALIAS resolves to that projection item's OWN expression (the ISO alias
  ///     precedence a `ORDER BY x` follows) — the term the sort recomputes
  ///     below the limit, NOT a fresh input reference;
  ///   - an `ordinal(n)` resolves to the `n`-th projection item's expression
  ///     (1-based, in range), the term the sort recomputes below the limit.
  ///
  /// A `*` or bare-column projection carries no expression a shorthand could
  /// reach (each output is a plain column slot compilation already resolves),
  /// so an ordinal or bare-name key against one contributes nothing to check.
  ///
  /// A bare unqualified name binds to a projection OUTPUT name by the SAME rule
  /// the resolver's `ORDER BY` lowering uses, so the type-check and the run
  /// agree on which keys are outputs and which are input columns:
  ///
  ///   - a NON-grouped query resolves an output name from an EXPLICIT `AS`
  ///     ALIAS only (`Projected.alias`) — the representation-independent ISO
  ///     precedence a `ORDER BY x` follows, so a bare projected column (no
  ///     `AS`) introduces no output and `ORDER BY <bareName>` stays an input
  ///     reference whether the parser emitted the select list as `columns` or,
  ///     forced by a sibling `AS`, as `expressions` (mirrors non-grouped
  ///     `Scope.order`);
  ///   - a GROUPED query resolves an output name from `Projected.name` (an
  ///     alias, else a bare column's name) — the SAME output-name set
  ///     `Grouping.terms`/`Grouping.order` record and bind, so a grouped
  ///     `ORDER BY <groupcol>` naming an unaliased projected group column
  ///     resolves to that output here exactly as it does in the run, rather
  ///     than being (mis)validated as an ambiguous input column.
  internal var orderKeys: Array<Expression> {
    // A grouped query's output-name surface includes an unaliased projected
    // group column (its `Projected.name`), matching the grouped lowering; a
    // non-grouped query's is an explicit `AS` alias only.
    orderKeys(named: aggregates ? \.name : \.alias)
  }

  /// The ORDER BY sort keys resolved to the expression the sort evaluates,
  /// matching a bare output name against `output` — the projection accessor a
  /// caller picks to mirror the resolver's lowering (see `orderKeys`).
  private func orderKeys(named output: KeyPath<Projected, String?>)
      -> Array<Expression> {
    guard let order else { return [] }
    // Only an `expressions` list carries a projection expression an ordinal or
    // an output-name key could reach; a `*` or bare-column projection names
    // plain column slots compilation already resolves.
    let items: Array<Projected>
    if case let .expressions(projected) = projection {
      items = projected
    } else {
      items = []
    }
    var expressions = Array<Expression>()
    for key in order.keys {
      switch key.sort {
      case let .ordinal(position):
        // An ordinal names the `position`-th projected output (1-based); the
        // sort recomputes that item's expression below the limit. An
        // out-of-range ordinal is `compile`'s fault to raise, so skip it here.
        if position >= 1, position <= items.count {
          expressions.append(items[position - 1].expression)
        }
      case let .expression(expression):
        // A bare unqualified name binds a matching projection OUTPUT name
        // before an input column (the ISO precedence), resolving to that
        // item's expression — the output surface (`output`) mirrors the
        // resolver's lowering for this query shape.
        if case let .column(column) = expression, column.qualifier == nil,
            let item = items.first(where: {
              $0[keyPath: output]?.lowercased() == column.name.lowercased()
            }) {
          expressions.append(item.expression)
        } else {
          expressions.append(expression)
        }
      }
    }
    return expressions
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
  /// The per-item explicit-`AS` OUTPUT ALIASES of a projection of `count`
  /// columns, aligned index-for-index with the lowered projection terms — an
  /// `expressions` item's `alias` (the explicit `AS`, else `nil`); a `*` or a
  /// bare-column list names none (`nil` throughout).
  ///
  /// It is the alias surface an `ORDER BY` output name resolves against, and it
  /// is REPRESENTATION-INDEPENDENT: only an explicit `AS` introduces an
  /// output name an `ORDER BY` may bind, so a bare projected column (`SELECT
  /// a.Name …`) contributes `nil` here whether the parser emitted it as a
  /// `columns` list or, forced by a sibling `AS`, as an `expressions` list —
  /// `ORDER BY Name` then resolves identically (an input column) in both. A
  /// bare `ORDER BY x` prefers a projected item whose explicit alias is `x`
  /// (the ISO precedence) to an input column of the same name. `count` is the
  /// lowered projection's width — the `expansion` of a `*`, which this itself
  /// cannot know — so the returned array always matches the projection terms
  /// in length.
  internal func outputs(count: Int) -> Array<String?> {
    switch self {
    case .all, .columns:
      return Array(repeating: nil, count: count)
    case let .expressions(items):
      return items.map(\.alias)
    }
  }

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
  ///
  /// `distinct` is the ISO `<set quantifier>` written inside the parentheses:
  /// `DISTINCT` folds each DISTINCT input value once (`COUNT(DISTINCT x)`,
  /// `SUM(DISTINCT x)`), `ALL` (the default, `distinct` `false`) folds every
  /// value. It is a no-op for `MIN`/`MAX` — the least/greatest value is the
  /// same with or without duplicates — but the standard admits it there, so it
  /// is accepted and ignored. `COUNT(*)` admits no quantifier (the parser
  /// diagnoses `COUNT(DISTINCT *)`).
  ///
  /// `filter`, when present, is the ISO `FILTER (WHERE <search condition>)` —
  /// the aggregate folds only the rows of the group whose predicate is TRUE (a
  /// FALSE or UNKNOWN row is skipped), applied as a per-row gate BEFORE the
  /// value reaches the fold — and before the `DISTINCT` dedup, so the two
  /// compose as "filter, then dedup". It gates even `COUNT(*)`, which counts
  /// only the admitted rows.
  case aggregate(Aggregate, of: Aggregand, distinct: Bool = false,
                 filter: Predicate? = nil)
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
  /// A `CAST(operand AS type)` — the ISO explicit conversion of the `operand`
  /// expression to the target `ValueType`. Unlike the widening `CASE` unifies
  /// its arms with, a cast is a NOMINAL conversion whose static type is the
  /// target, so the engine advertises `type` for the column and CONVERTS the
  /// evaluated value to it per row (see `Value.cast(to:)`). A `NULL` operand
  /// casts to `NULL` for any target; an unconvertible value (an unparseable
  /// text-to-number, an out-of-range double-to-integer, a cross-kind pair with
  /// no conversion) faults rather than yielding a wrong value.
  case cast(Expression, ValueType)
  /// `COALESCE(v1, v2, …)` — the first argument whose value is non-NULL, else
  /// NULL. The ISO definition is the searched `CASE WHEN v1 IS NOT NULL THEN v1
  /// … END`, but it is a FIRST-CLASS node rather than that expansion so each
  /// argument is evaluated EXACTLY ONCE: the desugar re-referenced each `vi` in
  /// both its `IS NOT NULL` guard and its `THEN`, evaluating a stateful
  /// argument twice — testing one call's value for NULL and returning a
  /// different one. The result type is the `ValueType.unified` reduction over
  /// the arguments (the same unification a `CASE`'s results take), to which the
  /// selected value is coerced. At least two arguments (the parser enforces
  /// it).
  case coalesce(Array<Expression>)
  /// `NULLIF(v1, v2)` — NULL when `v1` equals `v2`, else `v1`. The ISO
  /// definition is `CASE WHEN v1 = v2 THEN NULL ELSE v1 END`, but it is a
  /// FIRST-CLASS node rather than that expansion so `v1` is evaluated EXACTLY
  /// ONCE: the desugar embedded `v1` in both the equality and the `ELSE`,
  /// evaluating a stateful `v1` twice — comparing one call's value to `v2` and
  /// returning a different one. The result type is `v1`'s.
  case nullif(Expression, Expression)
  /// A scalar subquery `(SELECT …)` — a nested `Query` in expression position,
  /// yielding ONE value: its lone cell when it returns exactly one row, NULL
  /// when it returns none, and `SQLError.cardinality` when it returns more. The
  /// inner query must project EXACTLY ONE column (checked at compile, cursor-
  /// free, from its compiled width); the value's type is that column's. `Query`
  /// is `indirect`, so nesting it here composes the synthesized `Hashable`.
  ///
  /// In this slice the subquery is UNCORRELATED — it names no column of the
  /// enclosing query — so it runs ONCE per outer-query execution (memoised in
  /// the same `Subqueries` cache an `EXISTS`/`IN (Q)` predicate uses) and its
  /// value is the same for every outer row. A reference to an outer column
  /// resolves (or faults) as any other column would; correlation is a later
  /// slice.
  case subquery(Query)
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

/// A binary operator over two scalar operands.
///
/// The four standard arithmetic operators over numbers, and the ISO `||`
/// string concatenation. `*` `/` bind tighter than `+` `-` `||`, and every
/// operator is left-associative — the precedence the parser's climbing grammar
/// encodes and parentheses override. The four arithmetic operators require
/// numeric operands; `||` requires text operands. All propagate NULL.
public enum Arithmetic: Hashable, Sendable {
  /// `+`
  case add
  /// `-`
  case subtract
  /// `*`
  case multiply
  /// `/` — integer division.
  case divide
  /// `||` — text concatenation. It joins two text operands into one text value
  /// and propagates NULL (a NULL operand yields NULL); a non-text operand is a
  /// `SQLError.operand` type error, as arithmetic faults on a non-numeric one.
  case concatenate
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
  /// `x [NOT] BETWEEN a AND b` — whether `x` is within the inclusive range
  /// `[a, b]`, or outside it when `negated`. The ISO definition is `x >= a AND
  /// x <= b` (and `x < a OR x > b` negated), but it is a FIRST-CLASS node
  /// rather than that expansion so the test expression `x` is evaluated EXACTLY
  /// ONCE: the desugar duplicated `x` across both bound comparisons, testing a
  /// stateful `x`'s lower bound with one call and its upper with another. It
  /// keeps the ISO three-valued semantics — a NULL `x`, `a`, or `b` makes a
  /// bound UNKNOWN, excluding the row. Each bound `a` and `b` is an `Operand` —
  /// an ordinary scalar expression or a run-time `:parameter` resolved from the
  /// bindings (`x BETWEEN :lo AND :hi`) — the same binding the comparison and
  /// `LIKE` arms accept, so a caller can bind a range rather than interpolate
  /// it.
  case between(Expression, Operand, Operand, negated: Bool)
  /// `a IS [NOT] DISTINCT FROM b` — the ISO null-safe comparison of `a` and
  /// `b`, `negated` marking the `IS NOT DISTINCT FROM` (null-safe equality)
  /// spelling. It is TWO-VALUED — never UNKNOWN — treating NULL as a comparable
  /// value: `a IS DISTINCT FROM b` is FALSE iff both are NULL, or both are
  /// non-NULL and equal, and TRUE otherwise (exactly one NULL, or both non-NULL
  /// and unequal). `IS NOT DISTINCT FROM` is its negation. A cross-kind pair is
  /// DISTINCT — the two differ — matching the engine's cross-kind FALSE
  /// equality. Unlike `=`, a NULL operand never makes the row UNKNOWN.
  case distinct(Expression, Expression, negated: Bool)
  /// `[NOT] EXISTS (Q)` — whether the subquery `Q` yields at least one row,
  /// `negated` marking `NOT EXISTS`. It is DEFINITELY two-valued — never
  /// UNKNOWN — even when `Q` produces NULL-valued rows: the presence of a row
  /// is TRUE regardless of its values, so `EXISTS` tests cardinality alone. In
  /// this first slice `Q` is UNCORRELATED — it names no column of the enclosing
  /// query — so the engine materialises it ONCE (as a common table expression's
  /// body is materialised) and the whole predicate is the definite non-empty
  /// test of that result; `negated` flips it. `Predicate` is `indirect`, so it
  /// nests the whole `Query` without boxing.
  case exists(Query, negated: Bool)
  /// `x [NOT] IN (Q)` — whether the operand `x` equals any value the subquery
  /// `Q` yields, `negated` marking `NOT IN`. `Q` must project exactly ONE
  /// column (else `SQLError.arity`); the predicate is the three-valued
  /// membership of `x` in that column, exactly as the value-list `membership`
  /// is — a NULL `x` or a NULL element makes an otherwise-unmatched test
  /// UNKNOWN rather than FALSE, and `NOT IN` its negation (never TRUE when a
  /// NULL element is present), while an EMPTY result is FALSE (TRUE negated).
  /// In this first slice `Q` is UNCORRELATED (it names no enclosing column), so
  /// the engine materialises it ONCE and folds `x = v` over the materialised
  /// column under Kleene `OR`, the SAME three-valued core the value-list `IN`
  /// uses.
  case within(Expression, Query, negated: Bool)
  /// `p IS [NOT] <truth value>` — the ISO `<boolean test>`, whether the inner
  /// boolean `Predicate` `p`'s THREE-VALUED result equals the `value`
  /// (`TRUE`/`FALSE`/`UNKNOWN`), or does not when `negated`. Unlike the other
  /// predicates the result is DEFINITE two-valued — never itself UNKNOWN — so
  /// `p IS TRUE` is FALSE (not UNKNOWN) for an UNKNOWN `p`, and `p IS UNKNOWN`
  /// TESTS for that UNKNOWN. The operand is a `Predicate` rather than an
  /// `Expression`: a boolean is a predicate to this engine — a bare boolean
  /// operand `x` bridges as the comparison `x = TRUE`, whose three-valued
  /// truth IS `x`'s boolean value (`NULL` yielding UNKNOWN) — so a boolean
  /// column (`flag IS TRUE`) and a parenthesised comparison (`(a > b) IS TRUE`)
  /// share the one inner-predicate form and reuse the whole comparison
  /// machinery to evaluate it.
  case truth(Predicate, value: Truth, negated: Bool)
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

/// A truth value a `<boolean test>` (`Predicate.truth`) tests against — the
/// three SQL truth values, `UNKNOWN` being the spelling the test uses for a
/// NULL boolean (SQL spells UNKNOWN as `NULL` in a value position, but names it
/// `UNKNOWN` in this test). `p IS TRUE`/`FALSE`/`UNKNOWN` yields a DEFINITE
/// two-valued result, never itself UNKNOWN.
public enum Truth: Hashable, Sendable {
  /// The truth value `TRUE`.
  case `true`
  /// The truth value `FALSE`.
  case `false`
  /// The truth value `UNKNOWN` — a NULL boolean.
  case unknown
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

/// An `ORDER BY` clause: an ordered list of sort keys, each a sort value and
/// its own direction.
///
/// The keys are applied major to minor — `ORDER BY a, b DESC, c` sorts by `a`
/// ascending, breaks ties by `b` descending, then breaks the rest by `c`
/// ascending — so `keys[0]` is the primary key and each later key orders only
/// the rows the earlier keys leave equal. A per-key `ASC`/`DESC` governs that
/// key alone (default `ASC`); `keys` is never empty.
public struct Order: Hashable, Sendable {
  /// One sort key: the value to order on and its direction.
  public struct Key: Hashable, Sendable {
    /// An ISO `<sort key>` — the value a key orders on.
    ///
    /// The standard makes a sort key an arbitrary value expression over the
    /// query's columns; SQL practice adds two shorthands that name an OUTPUT
    /// column of the select list rather than an input value: a 1-based
    /// `ordinal` and an output `alias`. The three cases:
    ///
    /// - `ordinal(n)` — `ORDER BY 1` names the query's first projected output
    ///   column (1-based). An integer-literal sort key is ALWAYS this ordinal
    ///   (the ISO rule), never the integer constant `1`; ordering rows by a
    ///   constant is meaningless, so the standard reads a bare integer here as
    ///   a select-list position. An out-of-range `n` faults.
    /// - `expression(e)` — `ORDER BY a + b`, `ORDER BY UPPER(Name)`, or a bare
    ///   column `ORDER BY Name` (the common case) — any value expression over
    ///   the INPUT columns, evaluated per row.
    ///
    /// An unqualified name is EITHER an output alias (`SELECT x AS y … ORDER BY
    /// y`) or an input column; it lowers as an `expression(.column(name))` and
    /// the resolver prefers a matching OUTPUT alias to an input column of the
    /// same name (the ISO precedence for a bare `ORDER BY` name), falling back
    /// to the input column when no alias claims it.
    public enum Sort: Hashable, Sendable {
      /// `ORDER BY n` — the query's `n`-th projected output column, 1-based.
      case ordinal(Int)
      /// `ORDER BY expression` — a value expression over the input columns (a
      /// bare column, arithmetic, or a call), or a bare name a resolver may
      /// bind to an output alias first.
      case expression(Expression)
    }

    /// The value this key orders on.
    public let sort: Sort

    /// Whether this key is ascending (`ASC`, the default) rather than
    /// descending (`DESC`).
    public let ascending: Bool

    public init(sort: Sort, ascending: Bool = true) {
      self.sort = sort
      self.ascending = ascending
    }

    /// A key ordering on a bare (possibly-qualified) column — the common shape,
    /// lowered to the value expression `expression(.column(column))`. Retained
    /// so the many single-column constructors keep compiling.
    public init(column: Column, ascending: Bool = true) {
      self.init(sort: .expression(.column(column)), ascending: ascending)
    }

    /// A short spelling of this key for a diagnostic — a bare column's name, an
    /// ordinal's decimal, else a generic `"an expression"`. It names the
    /// offending key in a `SELECT DISTINCT` ordering fault
    /// (`SQLError.distinct`) without reconstructing the whole expression.
    internal var name: String {
      switch sort {
      case let .ordinal(position): "\(position)"
      case let .expression(.column(column)): column.name
      case .expression: "an expression"
      }
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
