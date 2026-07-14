// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

// The fluent query builder — a value type that accumulates a `Select` and,
// through the terminals, lowers to the engine's `Query`/`Statement` AST. Each
// combinator (`where`/`select`/`join`/`order(by:)`/`group(by:)`/`having`/
// `limit`/`offset`/`distinct`) sets one `Select` field and returns a refined
// builder; the set operators (`union`/`intersect`/`except`) wrap two builders
// into a `Query.setop`. The lowering is AST-DIRECT — no SQL text is emitted —
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
  private var from: Relation?
  private var joins: Array<Join>
  private var predicate: Predicate?
  private var grouping: Array<Column>
  private var having: Predicate?
  private var order: Order?
  private var limit: Limit?

  private init(from: Relation?) {
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

  /// The `Select` the accumulated fields lower to.
  private var select: Select {
    Select(distinct: unique, projection: projection, from: from,
           joins: joins, predicate: predicate, grouping: grouping,
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

  /// Projects the given terms and aliased items — `SELECT f(a), b AS x, …`. It
  /// lowers to the simpler `Projection.columns` when every item is an
  /// unaliased bare column (the parser's own choice), else to the richer
  /// `Projection.expressions`.
  public func select(_ items: Projection...) -> QueryBuilder {
    let columns = items.compactMap(\.column)
    if columns.count == items.count {
      return with { $0.projection = .columns(columns) }
    }
    return with { $0.projection = .expressions(items.map(\.projected)) }
  }

  /// Marks the projection `SELECT DISTINCT` — the result rows deduplicated.
  public func distinct() -> QueryBuilder {
    with { $0.unique = true }
  }
}

// MARK: - Filter / join

extension QueryBuilder {
  /// Filters the scanned rows by `filter` — `WHERE`. A second `where(_:)`
  /// REPLACES the predicate rather than conjoining; combine with `&&` to add a
  /// conjunct.
  public func `where`(_ filter: Filter) -> QueryBuilder {
    with { $0.predicate = filter.predicate }
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
  fileprivate var qualifier: String? {
    guard let from else { return nil }
    return from.alias ?? from.name
  }

  /// A predicate that always holds — the `1 = 1` an `APPLY` carries as its
  /// vacuous `ON`, since a `LATERAL` body correlates through its own `WHERE`
  /// rather than a join key. It equals the tree the parser builds for `1 = 1`,
  /// so the lowering oracle matches.
  fileprivate static var always: Predicate {
    .comparison(left: .literal(.integer(1)), op: .equal,
                right: .literal(.integer(1)))
  }

  /// Flattens a correlated inner sequence INTO the outer row set — the LINQ
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
/// the qualified `outer(_:_:)` reference the engine resolves OUTWARD and
/// re-binds per outer row, so a `flatten` body reads its correlated key without
/// naming the outer relation's qualifier by hand.
public struct OuterRow: Sendable {
  /// The outer relation's qualifier — its alias or name — the reference is
  /// stamped with.
  fileprivate let qualifier: String?

  /// The outer column `name`, qualified by the enclosing relation — the term a
  /// `flatten` body compares its inner key against.
  public subscript(_ name: String) -> Term {
    guard let qualifier else { return column(name) }
    return column(qualifier, name)
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

  /// Groups the rows by the named columns — `GROUP BY` — so the aggregates
  /// (`count()`, `sum(_:)`, …) fold over each group.
  public func group(by columns: String...) -> QueryBuilder {
    with { $0.grouping = columns.map { Column($0) } }
  }

  /// Filters the grouped rows by `filter` — `HAVING`, applied AFTER
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
}
