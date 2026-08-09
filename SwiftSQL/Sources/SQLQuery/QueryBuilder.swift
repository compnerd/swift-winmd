// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The fluent query builder — a value type that accumulates a `Select` and,
// through the terminals, lowers to the engine's `Query`/`Statement` AST. Each
// combinator (`where`/`select`/`join`/`order(by:)`/`group(by:)`/`having`/
// `limit`/`offset`/`distinct`) sets one `Select` field and returns a refined
// builder; the set operators (`union`/`intersect`/`except`) wrap two builders
// into a `Query.setop`. The lowering is AST-direct — no SQL text is emitted —
// so a build carries no lexer/parser round-trip, and the built AST equals the
// one `Statement(parsing:)` would produce for the equivalent SQL (the test
// oracle, since the AST is `Hashable`).

/// A fluent, chainable builder over one `SELECT`. `from(_:)` roots it at a
/// relation, the combinators refine it, and `query`/`statement` lower it to the
/// engine AST — or `run(against:)` hands it straight to a catalog.
public struct QueryBuilder: Hashable, Sendable {
  // The `Select` fields, accumulated one combinator at a time. The engine's
  // `Select` stores each as a `let`, so the builder holds the fields itself and
  // constructs the immutable `Select` only at the `query` terminal; every
  // combinator returns a copy with one field replaced.
  private var unique: Bool
  private var projection: SQLEngine.Projection
  private var from: Relation
  private var joins: Array<Join>
  private var predicate: Predicate?
  private var grouping: Array<Column>
  private var having: Predicate?
  private var order: Order?
  private var limit: Limit?

  private init(from: Relation) {
    self.unique = false
    self.projection = .all
    self.from = from
    self.joins = []
    self.predicate = nil
    self.grouping = []
    self.having = nil
    self.order = nil
    self.limit = nil
  }

  /// A copy of this builder with one field replaced — the shared spine every
  /// combinator returns through, keeping the builder a pure value.
  private func with(_ transform: (inout QueryBuilder) -> Void)
      -> QueryBuilder {
    var copy = self
    transform(&copy)
    return copy
  }

  /// The `Select` the accumulated fields lower to. The builder holds the
  /// `GROUP BY` columns as a plain list; it lowers here to the engine's
  /// ordinary `Grouping.keys` over the column expressions.
  private var select: Select {
    let keys = Grouping.keys(grouping.map { .column($0) })
    return Select(distinct: unique, projection: projection, from: from,
                  joins: joins, predicate: predicate, grouping: keys,
                  having: having, order: order, limit: limit)
  }
}

// MARK: - Roots

/// A query over the relation `name` (optionally aliased) — the root of a
/// chain. The relation is named dynamically, matching how winmd vends its
/// metadata tables; the catalog resolves it at run time.
public func from(_ name: String, as alias: String? = nil) -> QueryBuilder {
  QueryBuilder.rooted(at: Relation(name: name, alias: alias))
}

extension QueryBuilder {
  fileprivate static func rooted(at relation: Relation) -> QueryBuilder {
    QueryBuilder(from: relation)
  }
}

// MARK: - Projection

extension QueryBuilder {
  /// Projects the named columns, in order — `SELECT c1, c2, …`. An empty list
  /// leaves the projection `SELECT *`.
  public func select(_ columns: String...) -> QueryBuilder {
    columns.isEmpty
        ? with { $0.projection = .all }
        : with { $0.projection = .columns(columns.map { Column($0) }) }
  }

  /// Projects the given terms and aliased items — `SELECT f(a), b AS x, …`. An
  /// item is a bare `Term` (`count()`, `column("t.x")`, `sum(a).over(…)`) or a
  /// `term.as("x")` alias, both `ProjectionConvertible`, so a term need not be
  /// wrapped or aliased to be projected. It lowers to the simpler
  /// `Projection.columns` when every item is an unaliased bare column (the
  /// parser's own choice), else to the richer `Projection.expressions`.
  public func select(_ items: any ProjectionConvertible...) -> QueryBuilder {
    let projections = items.map(\.projection)
    let columns = projections.compactMap(\.column)
    if columns.count == projections.count {
      return with { $0.projection = .columns(columns) }
    }
    return with { $0.projection = .expressions(projections.map(\.projected)) }
  }

  /// Marks the projection `SELECT DISTINCT` — the result rows deduplicated.
  public func distinct() -> QueryBuilder {
    with { $0.unique = true }
  }
}

// MARK: - Filter / join

extension QueryBuilder {
  /// Filters the scanned rows by `filter` — `WHERE`. A second `where(_:)`
  /// replaces the predicate rather than conjoining; combine with `&&` to add a
  /// conjunct.
  public func `where`(_ filter: Filter) -> QueryBuilder {
    with { $0.predicate = filter.predicate }
  }

  /// This builder with `filter` conjoined into its `WHERE` — the existing
  /// predicate `AND` `filter`, or `filter` alone when there is none. Unlike
  /// `where(_:)`, which replaces, this narrows the row filter, so a terminal
  /// (`all`) can add a condition without discarding one the chain already set.
  internal func filtering(by filter: Filter) -> QueryBuilder {
    with {
      if let existing = $0.predicate {
        $0.predicate = .and(existing, filter.predicate)
      } else {
        $0.predicate = filter.predicate
      }
    }
  }

  /// Whether the predicate a terminal (`all`) adds must be tested against this
  /// query's output rows rather than conjoined into its `WHERE`. It is so when
  /// the output scope diverges from the pre-projection source scope: a rich
  /// (`.expressions`) projection introduces an output column absent from the
  /// source — an aggregate, a window value, a computed expression, or an
  /// aliased column — which the predicate may name; the query aggregates (a
  /// `GROUP BY`/`HAVING`, reusing the engine's own `Select.aggregates` so this
  /// cannot drift from its grouped-compile routing); or a `LIMIT`/`OFFSET`
  /// pages the rows. `all` wraps such a query as a derived table so its
  /// predicate resolves against — and applies after — the shaped output. A bare
  /// `SELECT *` or a plain-column projection is a passthrough whose output
  /// resolves in the source scope, so `all` filters it in place, keeping the
  /// query's own relation aliases and joined columns resolvable. A DISTINCT, or
  /// a window in the ORDER BY alone, preserves the membership a universal test
  /// depends on, and a plain ORDER BY only reorders, so neither shapes here.
  internal var shaped: Bool {
    if case .expressions = projection { return true }
    return select.aggregates || limit != nil
  }

  /// Joins `relation` (optionally aliased) on `filter` — an `INNER JOIN` by
  /// default; pass `kind` for a `LEFT`/`RIGHT`/`FULL` outer join. The `on`
  /// filter is an arbitrary predicate (equi, non-equi, or composite).
  public func join(_ relation: String, as alias: String? = nil,
                   kind: Join.Kind = .inner,
                   on filter: Filter) -> QueryBuilder {
    with {
      $0.joins.append(Join(relation: Relation(name: relation, alias: alias),
                           kind: kind, on: filter.predicate))
    }
  }
}

// MARK: - Flatten

extension QueryBuilder {
  /// The qualifier the root `FROM` relation binds — its alias when present,
  /// else its name — the name a correlated inner query qualifies an outer
  /// column by, and the key an `OuterRow` proxy stamps onto its references.
  fileprivate var qualifier: String {
    from.alias ?? from.name
  }

  /// A predicate that always holds — the `1 = 1` an `APPLY` carries as its
  /// vacuous `ON`, since a `LATERAL` body correlates through its own `WHERE`
  /// rather than a join key. It equals the tree the parser builds for `1 = 1`,
  /// so the lowering oracle matches.
  fileprivate static var always: Predicate {
    .comparison(left: .literal(.integer(1)), op: .equal,
                right: .literal(.integer(1)))
  }

  /// Flattens a correlated inner sequence into the outer row set — the LINQ
  /// `SelectMany`, lowered to a `LATERAL` derived table (an `APPLY`). `body`
  /// receives an `OuterRow` proxy over the root `FROM` relation, so its inner
  /// query correlates to a preceding-FROM column exactly as `outer(_:_:)` names
  /// one — `flatten { t in from("S").where(column("S.k") == t["Id"]) }` lowers
  /// to `FROM T JOIN LATERAL (SELECT * FROM S WHERE S.k = T.Id) AS d ON 1 = 1`.
  ///
  /// `kind` is the apply variety: `.inner` (a CROSS APPLY, the default) drops
  /// an outer row whose body yields nothing, while `.left` (an OUTER APPLY)
  /// preserves it NULL-extended. The body binds under `alias`, the name a later
  /// clause qualifies its columns by.
  public func flatten(as alias: String = "d", kind: Join.Kind = .inner,
                      _ body: (OuterRow) -> QueryBuilder) -> QueryBuilder {
    let inner = body(OuterRow(qualifier: qualifier))
    let derived = Relation(derived: inner.query, as: alias, lateral: true)
    return with {
      $0.joins.append(Join(relation: derived, kind: kind,
                           on: QueryBuilder.always))
    }
  }
}

/// A proxy over the OUTER row a `flatten` body correlates to — a reference to a
/// column of the enclosing query's root `FROM` relation. `outer["Id"]` builds
/// the qualified `outer(_:_:)` reference the engine resolves outward and
/// re-binds per outer row, so a `flatten` body reads its correlated key without
/// naming the outer relation's qualifier by hand.
public struct OuterRow: Sendable {
  /// The outer relation's qualifier — its alias or name — the reference is
  /// stamped with.
  fileprivate let qualifier: String

  /// The outer column `name`, qualified by the enclosing relation — the term a
  /// `flatten` body compares its inner key against.
  public subscript(_ name: String) -> Term {
    column(qualifier, name)
  }
}

// MARK: - Order / group / having

extension QueryBuilder {
  /// Orders the result by the given keys, major to minor — `ORDER BY`. Each key
  /// is a column name and a direction; `asc(_:)`/`desc(_:)` build one, and a
  /// bare string defaults to ascending.
  public func order(by keys: Order.Key...) -> QueryBuilder {
    with { $0.order = Order(keys: keys) }
  }

  /// Appends `key` as the next minor sort key — the LINQ `ThenBy`, so
  /// `order(by: "a").then(by: desc("b"))` orders by `a` then `b DESC`, the same
  /// `ORDER BY a, b DESC` a single `order(by:)` of both keys builds. It extends
  /// the ORDER BY the chain has so far; on a chain with no ordering yet it
  /// starts one, so a lone `then(by:)` reads as `order(by:)` of that key.
  public func then(by key: Order.Key) -> QueryBuilder {
    with { $0.order = Order(keys: ($0.order?.keys ?? []) + [key]) }
  }

  /// Groups the rows by the named columns — `GROUP BY` — so the aggregates
  /// (`count()`, `sum(_:)`, …) fold over each group.
  public func group(by columns: String...) -> QueryBuilder {
    with { $0.grouping = columns.map { Column($0) } }
  }

  /// Filters the grouped rows by `filter` — `HAVING`, applied after
  /// aggregation, so it may reference the aggregates and the grouping columns.
  public func having(_ filter: Filter) -> QueryBuilder {
    with { $0.having = filter.predicate }
  }
}

/// An ascending sort key on `column` — the default direction.
public func asc(_ column: String) -> Order.Key {
  Order.Key(column: Column(column), ascending: true)
}

/// A descending sort key on `column`.
public func desc(_ column: String) -> Order.Key {
  Order.Key(column: Column(column), ascending: false)
}

/// An ascending sort key on the expression `term` — a computed or aggregate
/// value, as a window `ORDER BY SUM(x)` needs, where a bare column name will
/// not do.
public func asc(_ term: Term) -> Order.Key {
  Order.Key(sort: .expression(term.expression), ascending: true)
}

/// A descending sort key on the expression `term`.
public func desc(_ term: Term) -> Order.Key {
  Order.Key(sort: .expression(term.expression), ascending: false)
}

extension Order.Key: ExpressibleByStringLiteral {
  /// A bare column name is an ascending key — `order(by: "Name", desc("Id"))`.
  public init(stringLiteral value: String) {
    self.init(column: Column(value), ascending: true)
  }
}

// MARK: - Limit / offset

extension QueryBuilder {
  /// Caps the result at `count` rows — the ISO `FETCH FIRST count ROWS ONLY`,
  /// preserving any `offset` already set.
  public func limit(_ count: Int) -> QueryBuilder {
    with { $0.limit = Limit(count: count, offset: $0.limit?.offset ?? 0) }
  }

  /// Skips the first `count` rows — the ISO `OFFSET count ROWS`, preserving any
  /// `limit` cap already set.
  public func offset(_ count: Int) -> QueryBuilder {
    with { $0.limit = Limit(count: $0.limit?.count, offset: count) }
  }

  /// This builder with its fetch cap reduced to at most `probe` rows — the
  /// smaller of `probe` and any cap already set, keeping the offset. A row
  /// terminal (`first`/`single`/`any`) probes with a small cap, but must never
  /// widen a stricter existing one: `limit(0).first` must still yield nothing,
  /// so the probe bounds against the existing limit rather than replacing it.
  internal func capped(at probe: Int) -> QueryBuilder {
    with {
      let count = $0.limit?.count.map { Swift.min(probe, $0) } ?? probe
      $0.limit = Limit(count: count, offset: $0.limit?.offset ?? 0)
    }
  }

  /// This query as a derived-table source — `(SELECT …) AS \(alias)` — so a
  /// terminal can test a condition over the shaped result (its ORDER BY /
  /// LIMIT / OFFSET already applied) rather than by narrowing the query's own
  /// `WHERE`, which runs before paging and so would change which rows the
  /// page admits.
  internal func nested(as alias: String) -> QueryBuilder {
    QueryBuilder(from: Relation(derived: query, as: alias))
  }
}

// MARK: - Terminals

extension QueryBuilder {
  /// The `Query` this builder lowers to — a single `SELECT` arm.
  public var query: Query {
    .select(select)
  }

  /// The `Statement` this builder lowers to — a `SELECT` statement wrapping
  /// `query`, the value `Catalog.run(_:_:bindings:)` accepts.
  public var statement: Statement {
    .select(query)
  }
}

// MARK: - Set operations

extension QueryBuilder {
  /// `self UNION [ALL] other` — the rows of either arm, duplicates removed
  /// unless `all`. Set operations lower to a `SetQuery`, not a `QueryBuilder`,
  /// since a set operation is no longer a single refinable `SELECT`.
  public func union(_ other: QueryBuilder, all: Bool = false) -> SetQuery {
    SetQuery(.setop(.union, query, other.query, all: all))
  }

  /// `self INTERSECT [ALL] other` — the rows present in both arms.
  public func intersect(_ other: QueryBuilder,
                        all: Bool = false) -> SetQuery {
    SetQuery(.setop(.intersect, query, other.query, all: all))
  }

  /// `self EXCEPT [ALL] other` — the rows of the left arm not in the right.
  public func except(_ other: QueryBuilder, all: Bool = false) -> SetQuery {
    SetQuery(.setop(.except, query, other.query, all: all))
  }

  /// `self` followed by `other`, keeping every row of both — the LINQ `Concat`.
  /// It is `UNION ALL`: unlike `union`, it preserves duplicates and does not
  /// deduplicate across the arms, so it is the multiset append rather than a
  /// set union.
  public func concat(_ other: QueryBuilder) -> SetQuery {
    SetQuery(.setop(.union, query, other.query, all: true))
  }

  /// This query's rows, or a single row of `values` when it yields none — the
  /// LINQ `DefaultIfEmpty`. It lowers to `WITH source(c1, …) AS (self) SELECT
  /// c1 AS <name>, … FROM source UNION ALL (SELECT <values> FROM (VALUES (0))
  /// AS defaults WHERE NOT EXISTS (SELECT * FROM source))`: the source is
  /// materialized once as the `source` CTE and read by both the emitted arm and
  /// the emptiness guard, so a non-deterministic source — a routine that varies
  /// per call — cannot make the two disagree, emitting a row while the guard
  /// still adds the default, or the reverse. The CTE's columns are unique
  /// positional names (`c1`, `c2`, …) that the emitted arm re-projects to the
  /// source's own output names, so a source with duplicate output names
  /// (`SELECT K, K`) still forms a valid CTE column list — which the engine's
  /// case-insensitive uniqueness check would reject on the real names — while
  /// the result keeps those names. (The ISO `VALUES (0)` one-row `<table value
  /// constructor>` gives the guard arm a `FROM` to hang its `WHERE` on, since a
  /// FROM-less `SELECT` is neither ISO nor admitted.) `values` must match this
  /// query's projection in width and order — a `UNION ALL` pairs the arms'
  /// columns positionally. The source's columns must be nameable, so a `SELECT
  /// *` source faults `SQLError.named` (there are no names to re-project).
  public func `default`(_ values: any TermConvertible...)
      throws(SQLError) -> Defaulted {
    let names = try query.names
    let defaults = values.map {
      Projected(expression: $0.term.expression, alias: nil)
    }
    // Materialize the source once as `source` under unique positional names, so
    // the emitted arm and the emptiness guard below read the same rows (the
    // once-materialized CTE) and a duplicate output name cannot fault the CTE
    // column list. The emitted arm re-projects those positions to the source's
    // real output names, so the result's schema is unchanged.
    let internals = names.indices.map { "c\($0 + 1)" }
    let cte = CTE(name: "source", columns: internals, query: query,
                  recursive: false)
    let projected = zip(internals, names).map { column, name in
      Projected(expression: .column(Column(name: column)), alias: name)
    }
    let scan = Select(distinct: false, projection: .expressions(projected),
                      from: Relation(name: "source", alias: nil), joins: [],
                      predicate: nil, grouping: .keys([]), having: nil,
                      order: nil, limit: nil)
    let probe = Query(body: .select(
        Select(distinct: false, projection: .all,
               from: Relation(name: "source", alias: nil), joins: [],
               predicate: nil, grouping: .keys([]), having: nil, order: nil,
               limit: nil)))
    // `VALUES (0)` — the ISO `<table value constructor>` as a first-class query
    // body, a one-row derived table giving the guard arm a `FROM` to hang its
    // `WHERE` on (a FROM-less `SELECT` is neither ISO nor admitted).
    let constructor = Query(body: .values([[.literal(.integer(0))]]))
    let arm = Select(distinct: false, projection: .expressions(defaults),
                     from: Relation(derived: constructor, as: "defaults"),
                     joins: [], predicate: .exists(probe, negated: true),
                     grouping: .keys([]), having: nil, order: nil, limit: nil)
    let union = Query(body: .setop(.union, .select(scan), .select(arm),
                                   all: true))
    return Defaulted(.with(ctes: [cte], query: union))
  }
}

/// A set operation over two query terms — the terminal a `union`/`intersect`/
/// `except` yields. It exposes the same `query`/`statement` terminals a
/// `QueryBuilder` does but no further `SELECT`-level refinement, since a set
/// operation is not a single `SELECT`; chain another set operator to extend it.
public struct SetQuery: Hashable, Sendable {
  /// The `Query` this set operation lowers to.
  public let query: Query

  fileprivate init(_ query: Query) {
    self.query = query
  }

  /// The `Statement` this set operation lowers to.
  public var statement: Statement {
    .select(query)
  }

  /// `self UNION [ALL] other` — extends the chain, associating left.
  public func union(_ other: QueryBuilder, all: Bool = false) -> SetQuery {
    SetQuery(.setop(.union, query, other.query, all: all))
  }

  /// `self INTERSECT [ALL] other`.
  public func intersect(_ other: QueryBuilder,
                        all: Bool = false) -> SetQuery {
    SetQuery(.setop(.intersect, query, other.query, all: all))
  }

  /// `self EXCEPT [ALL] other`.
  public func except(_ other: QueryBuilder, all: Bool = false) -> SetQuery {
    SetQuery(.setop(.except, query, other.query, all: all))
  }

  /// `self` followed by `other`, keeping every row of both — the LINQ `Concat`
  /// (`UNION ALL`), extending the chain and associating left.
  public func concat(_ other: QueryBuilder) -> SetQuery {
    SetQuery(.setop(.union, query, other.query, all: true))
  }
}

/// The LINQ `DefaultIfEmpty` terminal a `default(_:)` yields — this query's
/// rows, or a single default row when it yields none. It lowers to a `WITH`
/// that materializes the source once (see `QueryBuilder.default(_:)`), so it
/// carries a whole `Statement` rather than a `Query`: it offers the
/// `statement`/`run`/`columns` terminals but no further refinement or nesting,
/// since a `WITH` is not a subquery-able query term.
public struct Defaulted: Hashable, Sendable {
  /// The `WITH source AS (…) SELECT … UNION ALL …` statement this lowers to.
  public let statement: Statement

  fileprivate init(_ statement: Statement) {
    self.statement = statement
  }
}
