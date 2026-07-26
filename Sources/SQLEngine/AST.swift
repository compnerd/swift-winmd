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

  /// The CTE's declared output columns as the `ResolvedColumn` carrier — each
  /// declared name typed `.integer` and marked unconstrained, since the type is
  /// a fabricated placeholder (a materialised relation reports `.integer`; a
  /// CTE's rows carry no static types), NOT a genuine derivation — so a fold
  /// unifying against it defers to the other arm rather than faulting on the
  /// placeholder. It is the fallback a trusted derive falls back to when a
  /// data-dependent body a filter drops faults its type fold; the primary path
  /// binds a CTE from its body-derived carrier (`kinds(of:)`), which unifies
  /// the arms and carries the real `unconstrained` mask.
  internal var declared: Array<ResolvedColumn> {
    columns.map { ResolvedColumn(name: $0, type: .integer,
                                 unconstrained: true) }
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
/// multiplicity rule. Every arm must project the same number of columns; the
/// result column types are unified across the arms (a mixed integer/double
/// column widening to `double`), while their names come from the first arm (the
/// ISO rule).
public indirect enum Query: Hashable, Sendable {
  /// A single `SELECT`.
  case select(Select)
  /// A set operation of `kind` (`UNION`/`INTERSECT`/`EXCEPT`, `ALL` when `all`)
  /// over a left and a right query term, the right appended so a
  /// same-precedence chain reads left to right.
  case setop(SetOperation, Query, Query, all: Bool)

  /// A query-level `ORDER BY` / `SELECT DISTINCT` / `OFFSET`·`FETCH` carried
  /// OVER an inner query (always a `setop` — a `select` carries its own on the
  /// node). A `setop` node has no order/distinct/limit slot, so an ordered,
  /// deduplicated, or paged set operation rides this outer carrier: the row
  /// operators (`DISTINCT`, `ORDER BY`, `OFFSET`/`FETCH`) apply to the union's
  /// combined result, resolved through the setop's output scope, and do NOT
  /// project — the result columns stay the inner setop's arm-0-named, unified
  /// ones. It is transparent to `columns(unifying:)`, which descends to the
  /// inner setop for the result schema; only `run`/`compile` stack the row
  /// operators over the compiled setop plan. Produced by the GROUPING SETS
  /// `expand` and by the parser for a trailing query-level `ORDER BY` /
  /// `OFFSET`·`FETCH` after a set-operation chain.
  ///
  /// `generated` is the number of GENERATED trailing columns the inner union
  /// carries beyond the real output — the hidden sort columns `expand` appends
  /// to each arm (aliased `*gsN`) so a genuinely-unprojected aggregate sort key
  /// survives the `UNION ALL` at equal arity. The carrier's compile trims them
  /// (`real = width − generated`), and `columns(unifying:)` drops them from the
  /// result schema. It is a structural count carried out of `expand`, never
  /// recovered by scanning output names for a synthetic prefix; the parser's
  /// trailing-`ORDER BY` carrier generates none (`0`).
  case ordered(Query, distinct: Bool, order: Order?, limit: Limit?,
               generated: Int)

  /// The first `SELECT` of the query — the leftmost arm, reached by descending
  /// the left arm of each set operation. Its projection names the result
  /// columns (the ISO rule — their types unify across every arm), so a `CREATE
  /// VIEW` infers a set operation's column names from it. An `ordered` carrier
  /// is transparent — its first is its inner query's.
  public var first: Select {
    switch self {
    case let .select(select): select
    case let .setop(_, left, _, _): left.first
    case let .ordered(inner, _, _, _, _): inner.first
    }
  }

  /// The count of hidden `generated` sort columns the `ordered` carriers on the
  /// path to `first` appended to that arm's projection — the amount by which
  /// `first`'s raw projection width overstates the query's real output width. A
  /// query-level `ORDER BY` over an unprojected aggregate materialises such a
  /// column on each arm and trims it back at the carrier; a set-operation
  /// arity check comparing `first` widths must subtract this so a carrier
  /// operand's hidden column is not miscounted (`(SELECT n … GROUP BY GROUPING
  /// SETS (…) ORDER BY SUM(m)) UNION SELECT n` is a valid one-column union).
  internal var generated: Int {
    switch self {
    case .select: 0
    case let .setop(_, left, _, _): left.generated
    case let .ordered(inner, _, _, _, count): count + inner.generated
    }
  }

  /// The query-level row operators an `ordered` carrier applies OVER its inner
  /// query, peeled off it — the `DISTINCT`/`ORDER BY`/`OFFSET`·`FETCH` and the
  /// generated hidden-column count. A `select`/`setop` carries no carrier.
  public struct Carrier: Hashable, Sendable {
    public let distinct: Bool
    public let order: Order?
    public let limit: Limit?
    public let generated: Int
  }


  /// This query's carrier-transparent core — its innermost `setop`/`select`,
  /// with every `ordered` carrier peeled off. Two carriers stack when an outer
  /// query-expression tail rides a parenthesised primary that already has its
  /// own tail (`(SELECT … ORDER BY … FETCH n) ORDER BY …`), so the peel loops
  /// to the base rather than stopping at one level. For the `if case .setop =
  /// query.core` seams that recognise a set operation whether or not it rides
  /// carriers, so a carried (or twice-carried) union is not silently swallowed
  /// by a bare `.setop` match.
  public var core: Query {
    var query = self
    while case let .ordered(inner, _, _, _, _) = query { query = inner }
    return query
  }

  /// This query's carrier-transparent core paired with every `ordered` carrier
  /// on the path to it, innermost first — the full peel a stacked-carrier seam
  /// uses to reach the base `setop`/`select` and re-apply each carrier in order
  /// (`(setop ORDER BY 1) ORDER BY 1` yields the setop and `[inner, outer]`). A
  /// single carrier yields a one-element list; a bare body an empty one.
  public var peeled: (core: Query, carriers: Array<Carrier>) {
    guard case let .ordered(inner, distinct, order, limit, generated) = self
    else { return (self, []) }
    let (core, carriers) = inner.peeled
    return (core, carriers + [Carrier(distinct: distinct, order: order,
                                      limit: limit, generated: generated)])
  }

  /// Whether the query applies a set-level dedup that collapses distinct rows —
  /// a `DISTINCT` on any `ordered` carrier in its stack, or on its base
  /// `select`. Carrier-transparent (it peels the whole stack), so a seam that
  /// must not rewrite a projection whose distinct cardinality feeds an OFFSET
  /// sees the `DISTINCT` through any number of nested carriers. A set-operation
  /// core is not counted: the probe never rewrites a setop, so its `UNION`
  /// dedup cannot be collapsed by the rewrite.
  public var dedups: Bool {
    let (core, carriers) = peeled
    if carriers.contains(where: \.distinct) { return true }
    if case let .select(select) = core { return select.distinct }
    return false
  }
}

/// A `GROUP BY` grouping: the ordinary key list, an explicit `GROUPING SETS`
/// set list, or one expanded arm of such a set list.
///
/// The parser produces `.keys` for an ordinary `GROUP BY e, …` (empty for no
/// grouping) and `.sets` for `GROUP BY GROUPING SETS (s, …)`. The compile and
/// schema paths expand a `.sets` into a `UNION ALL` of per-arm groupings, each
/// arm a `.arm` grouping on one set's `keys` while carrying the `superset` (the
/// union of ALL sets' keys) so an arm's lowering NULLs a projected/HAVING
/// grouping column absent from this arm's set — the super-aggregate NULL —
/// matched by resolved identity, not raw AST.
public enum Grouping: Hashable, Sendable {
  /// `GROUP BY e, …` — the ordinary `<ordinary grouping set>` keys, in source
  /// order (empty for no explicit grouping).
  case keys(Array<Expression>)

  /// `GROUP BY GROUPING SETS (s, …)` — one key list per set, in source order;
  /// an empty inner list is the grand-total set `()`.
  case sets(Array<Array<Expression>>)

  /// one expanded arm of a `.sets` grouping — grouped on `keys` (this set's
  /// members) while `superset` is the union of every set's keys. A grouping
  /// column IN `superset` but absent from `keys` lowers to a super-aggregate
  /// NULL, matched by lowered-`Term` identity in `Grouped.term`. Produced by
  /// the shared `expand`, never by the parser.
  case arm(keys: Array<Expression>, superset: Array<Expression>)

  /// The `GROUP BY` keys this grouping evaluates over the input rows — a
  /// `.keys` its list, a `.sets` the concatenation of all sets' keys, a `.arm`
  /// its own set's keys. The reachability derive reads `isEmpty` here to
  /// recognise a whole-result aggregate (an empty `GROUP BY`, the `()` arm), so
  /// this stays the arm's own keys, NOT its superset.
  public var expressions: Array<Expression> {
    switch self {
    case let .keys(keys):
      keys
    case let .sets(sets):
      sets.reduce(into: Array<Expression>()) { $0 += $1 }
    case let .arm(keys, _):
      keys
    }
  }

  /// The `GROUP BY` key expressions the subquery/aggregate collectors descend
  /// to pre-register each nested subquery — like `expressions`, but a `.arm`
  /// yields its `superset` (the union of every set's keys). An arm lowers the
  /// superset (an absent key NULLs by resolved identity), not merely its own
  /// set, so a subquery in an omitted set's key must be collected here exactly
  /// as a present set's is; the superset subsumes the arm's own keys.
  internal var collected: Array<Expression> {
    switch self {
    case .keys, .sets:
      expressions
    case let .arm(_, superset):
      superset
    }
  }
}

/// A `SELECT` query: a projection over one relation or a chain of joins, with
/// an optional predicate, ordering, and row limit.
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

  /// The `GROUP BY` grouping — the ordinary `<ordinary grouping set>` key list
  /// (`.keys`, empty for a query with no explicit grouping), or a `GROUPING
  /// SETS (…)` set list (`.sets`) the compile and schema paths expand into a
  /// `UNION ALL` of per-arm groupings. A query that aggregates without a `GROUP
  /// BY` (`SELECT COUNT(*) FROM T`) carries `.keys([])` and aggregates the
  /// whole result as a single group. Each key is a bare `Expression.column` or
  /// a general key expression, so a bare `NATURAL`/`USING` merged column lowers
  /// through the join scope to its `COALESCE(left, right)` value (with no
  /// physical ordinal), the executor grouping each key per row.
  public let grouping: Grouping

  /// The `HAVING` filter over the grouped rows, if any — a predicate the engine
  /// applies after aggregation, so it may reference the aggregates and the
  /// grouping columns. A `HAVING` without a `GROUP BY` filters the single
  /// whole-result group.
  public let having: Predicate?

  /// The ordering applied to the result, if any.
  public let order: Order?

  /// The row limit applied to the (ordered) result, if any.
  public let limit: Limit?

  public init(distinct: Bool = false, projection: Projection,
              from: Relation?, joins: Array<Join> = [],
              predicate: Predicate? = nil, grouping: Grouping = .keys([]),
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
  /// It holds for a non-set-operation `SELECT` without a `HAVING` that is
  /// either non-`DISTINCT` (its cardinality is the source's, independent of the
  /// projected values) OR `DISTINCT` without an `OFFSET`. `DISTINCT` collapses
  /// a non-empty source to at least one distinct row, so `SELECT DISTINCT 1
  /// FROM S` is non-empty iff `S` is — existence is preserved by the constant
  /// projection. An `OFFSET` breaks that: it skips DISTINCT rows, so emptiness
  /// depends on the REAL distinct count (`SELECT DISTINCT x FROM S OFFSET 5` is
  /// empty iff there are `≤ 5` distinct `x`), which the constant projection —
  /// one distinct row — would wrongly collapse; such a select is not
  /// probe-eligible.
  ///
  /// An aggregate/grouped select without a `HAVING` is probe-eligible: its
  /// cardinality is a source-only fact the probe preserves without the original
  /// target (see `probe`). A whole-result aggregate (no `GROUP BY`) yields
  /// exactly one row regardless of the source — so EXISTS is true modulo the
  /// limit — and a grouped one yields one ROW per GROUP, so existence is the
  /// source's non-emptiness after `WHERE`. A `HAVING` is NOT eligible: group
  /// survival depends on the aggregate VALUES (which `HAVING` may reference),
  /// so cardinality is not a source-only fact and the target must run.
  internal var probable: Bool {
    guard having == nil else { return false }
    return !distinct || limit?.offset ?? 0 == 0
  }

  /// The EXISTS cardinality-probe rewrite of this select — the same
  /// FROM/`WHERE`/joins, the same `DISTINCT` quantifier, the same `GROUP BY`,
  /// and the same original `OFFSET`/`FETCH`, but its projection replaced with a
  /// cardinality-preserving target and its `ORDER BY` dropped — so a probe run
  /// tests whether the row source yields ANY row without evaluating the
  /// original select list or sort keys.
  ///
  /// It preserves the row source (FROM, joins, `WHERE`) and the original row
  /// limit exactly, so its cardinality matches this select's — enough for an
  /// existence test that honours the original limiting: a `FETCH FIRST 0 ROWS`
  /// probes zero rows (EXISTS false) and an `OFFSET` past the end probes none
  /// (false), neither overridden by a synthetic cap. `ORDER BY` is dropped
  /// because existence is order-independent (the row count after `OFFSET`/
  /// `FETCH` does not depend on order). A FROM-less `SELECT <exprs>` always
  /// yields exactly one row and cannot carry a limit, so its probe is just
  /// `SELECT <constant>` with no limit — it compiles and yields one row
  /// (EXISTS true). `DISTINCT` is retained (the caller applies the probe to a
  /// `DISTINCT` select only when it has no `OFFSET`, so `SELECT DISTINCT 1 FROM
  /// S` yields exactly one distinct row iff `S` is non-empty).
  ///
  /// The probe target is chosen to preserve cardinality without the original:
  /// a non-aggregate select projects the constant `1`, one row per source row;
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

  /// Every expression the ORDER BY sort evaluates over its input rows — the
  /// direct sort-key expressions AND the projection expressions its output
  /// shorthands reach — the ones a reachable type-check pass must validate as
  /// it does a projected expression.
  ///
  /// The compiled shape is `Project(Limit(Sort(input)))`: the sort is below the
  /// limit and evaluates each key over the input rows before the cap pages
  /// them, so what the sort forces to evaluate is independent of whether the
  /// projection is reachable. Each ORDER BY key resolves to the expression the
  /// sort runs, mirroring the resolver's lowering:
  ///
  ///   - a direct `.expression(e)` key over the input columns yields `e`;
  ///   - a bare unqualified column matching a projected explicit-`AS` output
  ///     alias resolves to that projection item's own expression (the ISO alias
  ///     precedence a `ORDER BY x` follows) — the term the sort recomputes
  ///     below the limit, NOT a fresh input reference;
  ///   - an `ordinal(n)` resolves to the `n`-th projection item's expression
  ///     (1-based, in range), the term the sort recomputes below the limit.
  ///
  /// A `*` or bare-column projection carries no expression a shorthand could
  /// reach (each output is a plain column slot compilation already resolves),
  /// so an ordinal or bare-name key against one contributes nothing to check.
  ///
  /// A bare unqualified name binds to a projection output name by the same rule
  /// the resolver's `ORDER BY` lowering uses, so the type-check and the run
  /// agree on which keys are outputs and which are input columns:
  ///
  ///   - a non-grouped query resolves an output name from an explicit `AS`
  ///     alias only (`Projected.alias`) — the representation-independent ISO
  ///     precedence a `ORDER BY x` follows, so a bare projected column (no
  ///     `AS`) introduces no output and `ORDER BY <bareName>` stays an input
  ///     reference whether the parser emitted the select list as `columns` or,
  ///     forced by a sibling `AS`, as `expressions` (mirrors non-grouped
  ///     `Scope.order`);
  ///   - a grouped query resolves an output name from `Projected.name` (an
  ///     alias, else a bare column's name) — the same output-name set
  ///     `Grouped.terms`/`Grouped.order` record and bind, so a grouped
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
        // A bare unqualified name binds a matching projection output name
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

/// A relation in a `FROM` or `JOIN`: a base relation named by an identifier, or
/// a derived TABLE — a parenthesised subquery `(SELECT …)` — each with an
/// alias.
///
/// A `named` relation's `name` is its spelling; its `alias`, when present, is
/// the short name a qualified column reference may use in its place (`FROM
/// TypeDef AS t`). A `derived` relation wraps a `Query`, materialised once
/// and resolved under a mandatory alias — ISO requires a derived table be named
/// (`FROM (SELECT …) AS t`) — so `alias` is always present and `name` is that
/// alias, the key the resolution scope binds its materialised rows under.
public struct Relation: Hashable, Sendable {
  /// Where a relation's rows come from: a named base relation/view/CTE, or a
  /// derived table's inner query.
  public enum Source: Hashable, Sendable {
    /// A relation named by an identifier — a base table, a view, or a CTE.
    case named(String)
    /// A derived table — the inner `Query` a `FROM (SELECT …) AS t` runs.
    case derived(Query)
  }

  /// The relation's source — a named relation or a derived table's query.
  public let source: Source

  /// The alias bound to the relation. Optional for a `named` relation, always
  /// present for a `derived` one (ISO requires a derived table be aliased).
  public let alias: String?

  /// The relation's explicit output column names — the ISO `AS t(c, …)` list —
  /// in ordinal order, or empty when the relation carries no list. A supplied
  /// list positionally renames the relation's real output columns (the same
  /// mechanism a CTE's `columns` list applies), so `FROM T AS t(c, d)` and
  /// `(SELECT x, y FROM T) AS d(a, b)` address the relation's columns by the
  /// new names. ISO admits the list on both a named relation and a derived
  /// table, so it rides on the shared `Relation` node. Empty matches the CTE
  /// field's shape (an absent list, columns inferred from the source).
  public let columns: Array<String>

  /// Whether a `LATERAL` derived table — its body may reference the preceding
  /// FROM items, so it re-evaluates per their rows (a correlated apply), rather
  /// than materialising once. Always `false` for a `named` relation and for a
  /// plain (non-`LATERAL`) derived table, which resolves independently of its
  /// call site.
  public let lateral: Bool

  /// A named base relation, view, or CTE with an optional alias and an optional
  /// explicit output column list (`FROM T AS t(c, d)`).
  public init(name: String, alias: String? = nil,
              columns: Array<String> = []) {
    self.source = .named(name)
    self.alias = alias
    self.columns = columns
    self.lateral = false
  }

  /// A derived table over `query`, resolved under the mandatory `alias`, with
  /// an optional explicit output column list (`(SELECT …) AS d(a, b)`). A
  /// `lateral` one resolves against the preceding FROM items and re-evaluates
  /// per their rows; a plain one materialises once, independent of the caller.
  public init(derived query: Query, as alias: String,
              columns: Array<String> = [], lateral: Bool = false) {
    self.source = .derived(query)
    self.alias = alias
    self.columns = columns
    self.lateral = lateral
  }

  /// The name the resolution scope keys this relation under: the identifier for
  /// a `named` relation, the alias for a `derived` one (a derived table's rows
  /// are bound under its alias, the only name a column may qualify it by).
  public var name: String {
    switch source {
    case let .named(name):
      name
    case .derived:
      alias ?? ""
    }
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
/// side's columns. The `ON` predicate governs matching alone — an unmatched
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

  /// The ISO named-column join criterion of a `NATURAL` or `JOIN … USING`
  /// clause — a shorthand whose join columns are resolved by name rather than
  /// spelled as an `ON` predicate, and whose common columns COALESCE into one
  /// unqualified output column (ISO 9075 7.10).
  ///
  /// It is mutually exclusive with an `ON` predicate (the parser rejects a
  /// `NATURAL … ON` / `USING … ON`), and its concrete column set is known only
  /// after schema resolution — the two sides' column names — so the engine
  /// carries the criterion here and resolves it into the equality `on`
  /// predicate and the coalesced `SELECT *` output during compilation, rather
  /// than at parse time. A join with no criterion (`nil`) is a plain `ON`/
  /// `CROSS` join.
  public enum Using: Hashable, Sendable {
    /// `NATURAL` — the join columns are every column name the two sides share
    /// (their case-insensitive intersection, in the left side's column order),
    /// computed at resolution. No common column degenerates to a `CROSS` join.
    case natural
    /// `USING (c, …)` — the join columns are the named ones, each of which must
    /// name a column present in both sides (else a column fault).
    case columns(Array<String>)
  }

  /// The relation joined in.
  public let relation: Relation

  /// The inner/outer variety of this join.
  public let kind: Kind

  /// The `ON` predicate relating the joined-in relation to those in scope. A
  /// `NATURAL`/`USING` join (`using != nil`) carries a placeholder always-true
  /// predicate here until compilation resolves its named columns into the real
  /// equality `on`.
  public let on: Predicate

  /// The ISO named-column criterion (`NATURAL` or `USING`), or `nil` for a
  /// plain `ON`/`CROSS` join.
  public let using: Using?

  public init(relation: Relation, kind: Kind = .inner, on: Predicate,
              using: Using? = nil) {
    self.relation = relation
    self.kind = kind
    self.on = on
    self.using = using
  }

  /// A `column = column` equi-join over `relation` — the common shape, as the
  /// two column references its `ON` equates.
  public init(relation: Relation, kind: Kind = .inner, left: Column,
              right: Column) {
    self.init(relation: relation, kind: kind,
              on: .comparison(left: .column(left), op: .equal,
                              right: .column(right)))
  }

  /// A `NATURAL`/`USING` join over `relation` — the named-column criterion its
  /// `on` predicate stands unresolved until compilation. Its `on` is a
  /// placeholder always-true predicate the resolution replaces.
  public init(relation: Relation, kind: Kind = .inner, using: Using) {
    self.init(relation: relation, kind: kind,
              on: .comparison(left: .literal(.integer(1)), op: .equal,
                              right: .literal(.integer(1))),
              using: using)
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
/// `Column` is `ExpressibleByStringLiteral`, splitting a literal on its last
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

  /// Parses a reference from its dotted spelling: the text before the last dot
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
  /// The per-item explicit-`AS` output aliases of a projection of `count`
  /// columns, aligned index-for-index with the lowered projection terms — an
  /// `expressions` item's `alias` (the explicit `AS`, else `nil`); a `*` or a
  /// bare-column list names none (`nil` throughout).
  ///
  /// It is the alias surface an `ORDER BY` output name resolves against, and it
  /// is representation-independent: only an explicit `AS` introduces an
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
  /// has no inferable name. It is the one derivation every output-name site
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
  /// per row), an aggregate accumulates over every row of a group and yields
  /// one value, so the engine recognises the fixed set of aggregate names at
  /// parse time and lowers them through a dedicated mechanism rather than the
  /// routines.
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
  /// FALSE or UNKNOWN row is skipped), applied as a per-row gate before the
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
  /// Both ISO forms reduce to this searched shape: a searched `CASE WHEN cond
  /// THEN r … END` carries its predicates directly, and a SIMPLE `CASE op WHEN
  /// v THEN r … END` is normalised at parse time to `WHEN op = v THEN r …`, so
  /// the engine models one conditional. The result expressions' types must
  /// unify to one result type (see resolution).
  case `case`(Array<When>, else: Expression?)
  /// A `CAST(operand AS type)` — the ISO explicit conversion of the `operand`
  /// expression to the target `ValueType`. Unlike the widening `CASE` unifies
  /// its arms with, a cast is a nominal conversion whose static type is the
  /// target, so the engine advertises `type` for the column and converts the
  /// evaluated value to it per row (see `Value.cast(to:)`). A `NULL` operand
  /// casts to `NULL` for any target; an unconvertible value (an unparseable
  /// text-to-number, an out-of-range double-to-integer, a cross-kind pair with
  /// no conversion) faults rather than yielding a wrong value.
  case cast(Expression, ValueType)
  /// `COALESCE(v1, v2, …)` — the first argument whose value is non-NULL, else
  /// NULL. The ISO definition is the searched `CASE WHEN v1 IS NOT NULL THEN v1
  /// … END`, but it is a FIRST-class node rather than that expansion so each
  /// argument is evaluated exactly once: the desugar re-referenced each `vi` in
  /// both its `IS NOT NULL` guard and its `THEN`, evaluating a stateful
  /// argument twice — testing one call's value for NULL and returning a
  /// different one. The result type is the `ValueType.unified` reduction over
  /// the arguments (the same unification a `CASE`'s results take), to which the
  /// selected value is coerced. At least two arguments (the parser enforces
  /// it).
  case coalesce(Array<Expression>)
  /// `NULLIF(v1, v2)` — NULL when `v1` equals `v2`, else `v1`. The ISO
  /// definition is `CASE WHEN v1 = v2 THEN NULL ELSE v1 END`, but it is a
  /// FIRST-class node rather than that expansion so `v1` is evaluated exactly
  /// once: the desugar embedded `v1` in both the equality and the `ELSE`,
  /// evaluating a stateful `v1` twice — comparing one call's value to `v2` and
  /// returning a different one. The result type is `v1`'s.
  case nullif(Expression, Expression)
  /// A scalar subquery `(SELECT …)` — a nested `Query` in expression position,
  /// yielding one value: its lone cell when it returns exactly one row, NULL
  /// when it returns none, and `SQLError.cardinality` when it returns more. The
  /// inner query must project exactly one column (checked at compile, cursor-
  /// free, from its compiled width); the value's type is that column's. `Query`
  /// is `indirect`, so nesting it here composes the synthesized `Hashable`.
  ///
  /// In this slice the subquery is uncorrelated — it names no column of the
  /// enclosing query — so it runs once per outer-query execution (memoised in
  /// the same `Subqueries` cache an `EXISTS`/`IN (Q)` predicate uses) and its
  /// value is the same for every outer row. A reference to an outer column
  /// resolves (or faults) as any other column would; correlation is a later
  /// slice.
  case subquery(Query)
  /// `GROUPING(a, …)` — the ISO grouping-sets function, an integer bit-vector
  /// reporting per argument whether that expression was rolled up (omitted from
  /// the current result row's grouping set — bit `1`) or is a grouping key of
  /// this set (bit `0`). The FIRST argument is the most-significant bit, so over
  /// the `()` arm of `GROUPING SETS ((a, b), ())` `GROUPING(a, b)` is `0b11`
  /// (`3`), and over the `(a)` arm it is `0b01` (`1`). Each argument must be a
  /// `GROUP BY` expression of some grouping set (else an error), and GROUPING is
  /// valid only in a grouped query (a `GROUP BY`, or a whole-result aggregate).
  ///
  /// It is a FIRST-class node — NOT a scalar `call(name: "GROUPING", …)`, which
  /// would fault `SQLError.function` as an unregistered routine — because it
  /// resolves against the grouped scope's key membership rather than through
  /// the routines: after GROUPING SETS expansion each arm knows its own
  /// keys and the superset, so GROUPING is a compile-TIME per-arm integer
  /// constant (`Grouped.term`) and no executor path ever evaluates a `grouping`
  /// node — it lowers to a `Term.constant(.integer(bits))`.
  case grouping(Array<Expression>)
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
    /// query's columns; SQL practice adds two shorthands that name an output
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
    ///   the input columns, evaluated per row.
    ///
    /// An unqualified name is either an output alias (`SELECT x AS y … ORDER BY
    /// y`) or an input column; it lowers as an `expression(.column(name))` and
    /// the resolver prefers a matching output alias to an input column of the
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
/// `offset` rows, then take at most `count`. The two ISO clauses are
/// independent — an `OFFSET` written without a `FETCH` leaves `count` `nil` (no
/// cap, every row after the skip), and a `FETCH` without an `OFFSET` caps from
/// the start (`offset` `0`). Both counts are non-negative; a `count` of `0`
/// yields no rows and an `offset` past the end yields none.
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
