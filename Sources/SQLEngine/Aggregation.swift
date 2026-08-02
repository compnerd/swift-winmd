// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Aggregation

extension Select {
  /// Whether the select aggregates — it has a `GROUP BY`, a `HAVING`, or an
  /// aggregate function anywhere in its projection.
  ///
  /// A query with any of these compiles through the grouped path; one with none
  /// keeps the ordinary `Project(Limit(Sort(Select(_))))` shape unchanged. A
  /// `HAVING` alone (no `GROUP BY`, no aggregate) still aggregates — it filters
  /// the single whole-result group.
  internal var aggregates: Bool {
    let grouped = switch grouping {
    case let .keys(keys): !keys.isEmpty
    // A `GROUPING SETS (…)` (or one expanded arm) always aggregates — even
    // `GROUPING SETS (())` groups the whole result — so it is grouped
    // regardless of whether any set is non-empty.
    case .sets, .arm: true
    }
    if grouped || having != nil { return true }
    switch projection {
    case .all, .columns:
      return false
    case let .expressions(items):
      return items.contains { $0.expression.aggregated }
    }
  }
}

extension Expression {
  /// Whether the expression contains an aggregate call anywhere within it.
  internal var aggregated: Bool {
    switch self {
    case .column, .literal, .subquery:
      // An aggregate inside a scalar subquery belongs to that subquery, not the
      // enclosing query, so a `subquery` is not an aggregated expression here.
      false
    case .aggregate:
      true
    case let .call(_, arguments):
      arguments.contains { $0.aggregated }
    case let .binary(_, lhs, rhs):
      lhs.aggregated || rhs.aggregated
    case let .case(whens, otherwise):
      whens.contains { $0.when.aggregated || $0.then.aggregated }
          || (otherwise?.aggregated ?? false)
    case let .cast(operand, _):
      operand.aggregated
    case let .coalesce(arguments):
      arguments.contains { $0.aggregated }
    case let .nullif(lhs, rhs):
      lhs.aggregated || rhs.aggregated
    case let .grouping(arguments):
      // GROUPING is not itself an aggregate; like a `call`, it is aggregated
      // only if an argument is (a GROUP BY expression never is, so this is
      // false in practice) — mirroring the neighbouring `call` arm.
      arguments.contains { $0.aggregated }
    case let .window(_, spec):
      // A window function is not itself an aggregate — it preserves cardinality
      // rather than folding a group — but a query aggregate nested in its
      // partition or order (`ROW_NUMBER() OVER (ORDER BY SUM(x))`) is one, so
      // descend the specification's expressions as a `call`'s arguments.
      spec.expressions.contains { $0.aggregated }
    }
  }

  /// Whether the expression nests a `GROUPING(…)` operator anywhere within it.
  /// The grouped lowering reads this to route a GROUPING-bearing compound (a
  /// `CASE WHEN GROUPING(x) = 1 …`, an arithmetic over it) through its
  /// per-operand descent rather than the whole-expression key match, which
  /// lowers through `Scope.term` — and `Scope.term` cannot resolve a GROUPING
  /// (it faults `.state`, the operator having meaning only in the grouped
  /// space). Mirrors `aggregated`, which carves the same path out for a nested
  /// aggregate; a GROUPING inside a scalar subquery belongs to that subquery's
  /// own grouped scope, so a `subquery` is not GROUPING-bearing here.
  internal var grouping: Bool {
    switch self {
    case .column, .literal, .aggregate, .subquery:
      false
    case .grouping:
      true
    case let .call(_, arguments):
      arguments.contains { $0.grouping }
    case let .binary(_, lhs, rhs):
      lhs.grouping || rhs.grouping
    case let .case(whens, otherwise):
      whens.contains { $0.when.grouping || $0.then.grouping }
          || (otherwise?.grouping ?? false)
    case let .cast(operand, _):
      operand.grouping
    case let .coalesce(arguments):
      arguments.contains { $0.grouping }
    case let .nullif(lhs, rhs):
      lhs.grouping || rhs.grouping
    case let .window(_, spec):
      // As a `call`: GROUPING-bearing only if the specification's expressions
      // are (a well-formed window carries none).
      spec.expressions.contains { $0.grouping }
    }
  }

  /// Whether the expression references a query binding — a `.bound` predicate —
  /// anywhere within it, reached only through a `CASE` guard (a scalar
  /// expression has no other predicate). A defined-function body is validated
  /// over its parameter schema and evaluated with only its argument record — no
  /// query bindings reach it — so a body naming a `:parameter` is rejected at
  /// registration rather than silently evaluating that reference as unbound.
  internal var bound: Bool {
    switch self {
    case .column, .literal, .aggregate, .subquery:
      // An uncorrelated scalar subquery references no query binding of the
      // enclosing query (correlation is a later slice), so it is not bound.
      false
    case let .call(_, arguments):
      arguments.contains { $0.bound }
    case let .binary(_, lhs, rhs):
      lhs.bound || rhs.bound
    case let .case(whens, otherwise):
      whens.contains { $0.when.bound || $0.then.bound }
          || (otherwise?.bound ?? false)
    case let .cast(operand, _):
      operand.bound
    case let .coalesce(arguments):
      arguments.contains { $0.bound }
    case let .nullif(lhs, rhs):
      lhs.bound || rhs.bound
    case let .grouping(arguments):
      // As a `call`: bound only if an argument references a query binding.
      arguments.contains { $0.bound }
    case let .window(_, spec):
      // As a `call`: bound only if a specification expression references a query
      // binding.
      spec.expressions.contains { $0.bound }
    }
  }
}

extension Predicate.Operand {
  /// Whether this `LIKE` operand contains an aggregate — an expression's own,
  /// never a `:parameter`.
  internal var aggregated: Bool {
    switch self {
    case let .expression(expression): expression.aggregated
    case .parameter: false
    }
  }

  /// Whether this `LIKE` operand nests a `GROUPING(…)` — an expression's own,
  /// never a `:parameter` (see `Expression.grouping`).
  internal var grouping: Bool {
    switch self {
    case let .expression(expression): expression.grouping
    case .parameter: false
    }
  }

  /// Whether this `LIKE` operand references a query binding — an expression's
  /// own, or the operand's own `:parameter`, so a defined-function body that
  /// names a `:parameter` in a `LIKE` pattern or escape is rejected at
  /// registration (see `Expression.bound`).
  internal var bound: Bool {
    switch self {
    case let .expression(expression): expression.bound
    case .parameter: true
    }
  }

  /// Collects the distinct aggregates within this `LIKE` operand into
  /// `expressions` — an expression's own, none for a `:parameter`.
  internal func collect(into expressions: inout Array<Expression>) {
    switch self {
    case let .expression(expression): expression.collect(into: &expressions)
    case .parameter: break
    }
  }
}

extension Predicate {
  /// The flat list of top-level `AND`-conjuncts of this predicate in source
  /// ORDER (a non-`and` is a singleton). The parser leans `AND` left (`a AND b
  /// AND c` is `.and(.and(a, b), c)`), so a left-first flatten yields the
  /// conjuncts as written — the order `Scope.on` walks to bound its safe
  /// key-extraction prefix.
  internal var conjuncts: Array<Predicate> {
    guard case let .and(lhs, rhs) = self else { return [self] }
    return lhs.conjuncts + rhs.conjuncts
  }

  /// Whether the predicate contains an aggregate call anywhere within it — used
  /// to spot an aggregate hiding in a `CASE` guard (`CASE WHEN COUNT(*) > 1
  /// …`), which makes the enclosing query an aggregate one.
  internal var aggregated: Bool {
    switch self {
    case let .comparison(left, _, right):
      left.aggregated || right.aggregated
    case let .bound(left, _, _):
      left.aggregated
    case let .null(operand, _):
      operand.aggregated
    case let .membership(operand, values, _):
      operand.aggregated || values.contains { $0.aggregated }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.aggregated } || rhs.contains { $0.aggregated }
    case let .among(lhs, rows, _):
      lhs.contains { $0.aggregated }
          || rows.contains { $0.contains { $0.aggregated } }
    case .exists:
      // A subquery is its own scope, so an aggregate inside it folds over its
      // group, not the enclosing one — it never makes the OUTER query an
      // aggregate one.
      false
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      // Only the OUTER left-row components can hold an enclosing-group
      // aggregate; the subquery is its own scope.
      lhs.contains { $0.aggregated }
    case let .like(operand, pattern, escape, _):
      operand.aggregated || pattern.aggregated
          || (escape?.aggregated ?? false)
    case let .between(test, lower, upper, _):
      test.aggregated || lower.aggregated || upper.aggregated
    case let .distinct(lhs, rhs, _):
      lhs.aggregated || rhs.aggregated
    case let .truth(inner, _, _):
      inner.aggregated
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.aggregated || rhs.aggregated
    case let .not(operand):
      operand.aggregated
    }
  }

  /// Whether the predicate nests a `GROUPING(…)` anywhere within it — used to
  /// spot a GROUPING hiding in a `CASE` guard (`CASE WHEN GROUPING(x) = 1 …`),
  /// so the grouped lowering descends the guarded compound per operand rather
  /// than matching it as a whole `GROUP BY` key (see `Expression.grouping`). A
  /// subquery is its own scope, so a GROUPING inside one never makes the
  /// enclosing predicate GROUPING-bearing.
  internal var grouping: Bool {
    switch self {
    case let .comparison(left, _, right):
      left.grouping || right.grouping
    case let .bound(left, _, _):
      left.grouping
    case let .null(operand, _):
      operand.grouping
    case let .membership(operand, values, _):
      operand.grouping || values.contains { $0.grouping }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.grouping } || rhs.contains { $0.grouping }
    case let .among(lhs, rows, _):
      lhs.contains { $0.grouping }
          || rows.contains { $0.contains { $0.grouping } }
    case .exists:
      false
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      lhs.contains { $0.grouping }
    case let .like(operand, pattern, escape, _):
      operand.grouping || pattern.grouping
          || (escape?.grouping ?? false)
    case let .between(test, lower, upper, _):
      test.grouping || lower.grouping || upper.grouping
    case let .distinct(lhs, rhs, _):
      lhs.grouping || rhs.grouping
    case let .truth(inner, _, _):
      inner.grouping
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.grouping || rhs.grouping
    case let .not(operand):
      operand.grouping
    }
  }

  /// Whether the predicate references a query binding — a `.bound` operand — in
  /// any position within it. A defined-function body's `CASE` guards are walked
  /// through this to reject a `:parameter` at registration (see
  /// `Expression.bound`).
  internal var bound: Bool {
    switch self {
    case .bound:
      true
    case let .comparison(left, _, right):
      left.bound || right.bound
    case let .null(operand, _):
      operand.bound
    case let .membership(operand, values, _):
      operand.bound || values.contains { $0.bound }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.bound } || rhs.contains { $0.bound }
    case let .among(lhs, rows, _):
      lhs.contains { $0.bound } || rows.contains { $0.contains { $0.bound } }
    case let .exists(query, _):
      // A `:parameter` inside a subquery binds against the same run bindings
      // (the subquery runs under the enclosing context), so a defined-function
      // body that nests one still carries a binding to reject at registration.
      query.bound
    case let .within(lhs, query, _):
      lhs.contains { $0.bound } || query.bound
    case let .quantified(lhs, _, _, query):
      lhs.contains { $0.bound } || query.bound
    case let .like(operand, pattern, escape, _):
      operand.bound || pattern.bound || (escape?.bound ?? false)
    case let .between(test, lower, upper, _):
      test.bound || lower.bound || upper.bound
    case let .distinct(lhs, rhs, _):
      lhs.bound || rhs.bound
    case let .truth(inner, _, _):
      inner.bound
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.bound || rhs.bound
    case let .not(operand):
      operand.bound
    }
  }
}

extension Query {
  /// Whether this query references a query binding — a `.bound` operand — in
  /// any predicate within it, descending a set operation's arms. A subquery
  /// nested in a defined-function body is walked through this to reject a
  /// `:parameter` at registration (see `Expression.bound`).
  internal var bound: Bool {
    switch body {
    case let .select(select): select.bound
    case let .setop(_, left, right, _): left.bound || right.bound
    case let .values(rows): rows.contains { $0.contains(where: \.bound) }
    }
  }

  /// The uncorrelated subqueries this query nests directly — the union of every
  /// arm's `Select.subqueries`, descending a set operation's arms but NOT a
  /// nested subquery's own body (each subquery is run as a whole, resolving its
  /// inner subqueries through its own `run`). The run path materialises these
  /// once, keyed by occurrence, so a set operation's every arm reads its own
  /// `EXISTS`/`IN (Q)` result from the same cache.
  internal var subqueries: Array<Query> {
    switch body {
    case let .select(select): select.subqueries
    case let .setop(_, left, right, _): left.subqueries + right.subqueries
    case let .values(rows):
      rows.reduce(into: Array<Query>()) { queries, row in
        for expression in row { expression.collect(subqueries: &queries) }
      }
    }
  }

  /// The subqueries this query nests in an `IN (Q)` position — the ones whose
  /// single COLUMN of values a run reads, so the materialiser runs each in FULL
  /// rather than as a cardinality probe. A subquery only ever an `EXISTS`
  /// operand is absent, so its select list is never evaluated; one used by both
  /// an `EXISTS` and an `IN` appears here (its values are needed), so its lone
  /// full materialisation serves both.
  internal var valued: Set<Query> {
    switch body {
    case let .select(select): select.valued
    case let .setop(_, left, right, _): left.valued.union(right.valued)
    case let .values(rows):
      rows.reduce(into: Set<Query>()) { queries, row in
        for expression in row { expression.collect(valued: &queries) }
      }
    }
  }

  /// The subqueries this query nests in a scalar-subquery position — the ones a
  /// run collapses to a single value (empty → NULL, one row → the cell, more →
  /// `SQLError.cardinality`), distinct from a `valued` (`IN`) or `EXISTS`-probe
  /// occurrence. The materialiser reads this to decide a scalar occurrence's
  /// materialisation.
  internal var scalar: Set<Query> {
    switch body {
    case let .select(select): select.scalar
    case let .setop(_, left, right, _): left.scalar.union(right.scalar)
    case let .values(rows):
      rows.reduce(into: Set<Query>()) { queries, row in
        for expression in row { expression.collect(scalar: &queries) }
      }
    }
  }

  /// The subqueries this query nests in an `EXISTS (Q)` position — the ones a
  /// run materialises as a cardinality probe. The same query may also occur as
  /// a `valued` (`IN`) or `scalar` occurrence over identical SQL; each role is
  /// a DISTINCT cache entry (see `Role`), so the materialiser produces an
  /// existential probe entry whenever a query occurs here — never reusing a
  /// `valued`/`scalar` entry for an `EXISTS` read.
  internal var existential: Set<Query> {
    switch body {
    case let .select(select): select.existential
    case let .setop(_, left, right, _):
      left.existential.union(right.existential)
    case let .values(rows):
      rows.reduce(into: Set<Query>()) { queries, row in
        for expression in row { expression.collect(existential: &queries) }
      }
    }
  }

  /// The `Role`s `query` occupies within this arm under a carrier's `order` —
  /// the union of the roles it occupies in this leftmost arm's own clauses (a
  /// `Select`'s, or a `VALUES` body's row expressions) and the roles it
  /// occupies in the carrier's `ORDER BY` keys. The carrier path classifies its
  /// `ORDER BY` subqueries this way — over the leftmost arm's output surface
  /// plus the carrier order — rather than through a synthetic `Select`, so it
  /// resolves for any body; `compile(values:)` reuses it (with no order) to
  /// classify a row expression's own nested subqueries.
  internal func roles(of query: Query, order: Order?) -> Array<Role> {
    var scalar = Set<Query>(), valued = Set<Query>(), existential = Set<Query>()
    switch arm.body {
    case let .select(select):
      scalar = select.scalar
      valued = select.valued
      existential = select.existential
    case let .values(rows):
      for row in rows {
        for expression in row {
          expression.collect(scalar: &scalar)
          expression.collect(valued: &valued)
          expression.collect(existential: &existential)
        }
      }
    case .setop:
      break
    }
    for key in order?.keys ?? [] {
      guard case let .expression(expression) = key.sort else { continue }
      expression.collect(scalar: &scalar)
      expression.collect(valued: &valued)
      expression.collect(existential: &existential)
    }
    var roles = Array<Role>()
    if scalar.contains(query) { roles.append(.scalar) }
    if valued.contains(query) { roles.append(.valued) }
    if existential.contains(query) { roles.append(.existential) }
    return roles
  }
}

extension Select {
  /// Whether this `SELECT` references a query binding — a `.bound` operand — in
  /// its `WHERE`, any join `ON`, or its `HAVING` (the predicate positions a
  /// binding may occur in).
  internal var bound: Bool {
    if predicate?.bound ?? false { return true }
    if joins.contains(where: { $0.on.bound }) { return true }
    return having?.bound ?? false
  }

  /// The uncorrelated subqueries this `SELECT` nests directly — those in its
  /// `WHERE`, each join `ON`, its `HAVING`, its projection, its `GROUP BY` key
  /// expressions, and its `ORDER BY` sort-key expressions — in appearance
  /// order, for the `compile`/`typecheck` pre-pass to materialise once.
  ///
  /// It descends this select's own predicates and expressions but NOT into a
  /// nested subquery's own body: each subquery is compiled/run as a whole
  /// (`compile(query)`/`run(query)`), which recurses into its inner subqueries
  /// through its own pre-pass, so gathering only the directly-nested ones keeps
  /// the walk one level and lets each subquery own its inner materialisation.
  internal var subqueries: Array<Query> {
    var queries = Array<Query>()
    predicate?.collect(subqueries: &queries)
    for join in joins { join.on.collect(subqueries: &queries) }
    having?.collect(subqueries: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(subqueries: &queries) }
    }
    for key in grouping.collected { key.collect(subqueries: &queries) }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(subqueries: &queries)
      }
    }
    return queries
  }

  /// The subqueries this `SELECT` nests in an `IN (Q)` position — the same
  /// clauses `subqueries` walks, keeping only the `within` operands' queries,
  /// so a run materialises each in FULL for its values while an `EXISTS`-only
  /// subquery stays a cardinality probe.
  internal var valued: Set<Query> {
    var queries = Set<Query>()
    predicate?.collect(valued: &queries)
    for join in joins { join.on.collect(valued: &queries) }
    having?.collect(valued: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(valued: &queries) }
    }
    for key in grouping.collected { key.collect(valued: &queries) }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(valued: &queries)
      }
    }
    return queries
  }

  /// The subqueries this `SELECT` nests in a scalar-subquery position — the
  /// same clauses `subqueries` walks, keeping only the `Expression.subquery`
  /// queries, so a run materialises each as its collapsed single value (empty →
  /// NULL, one row → the cell, more → `SQLError.cardinality`), distinct from a
  /// `valued` (`IN`, full column) or `EXISTS`-probe occurrence.
  internal var scalar: Set<Query> {
    var queries = Set<Query>()
    predicate?.collect(scalar: &queries)
    for join in joins { join.on.collect(scalar: &queries) }
    having?.collect(scalar: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(scalar: &queries) }
    }
    for key in grouping.collected { key.collect(scalar: &queries) }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(scalar: &queries)
      }
    }
    return queries
  }

  /// The subqueries this `SELECT` nests in an `EXISTS (Q)` position — the
  /// same clauses `subqueries` walks, keeping only the `exists` operands'
  /// queries, so a run materialises each as a cardinality probe under its own
  /// `existential` key, distinct from any `valued`/`scalar` occurrence over the
  /// same SQL.
  internal var existential: Set<Query> {
    var queries = Set<Query>()
    predicate?.collect(existential: &queries)
    for join in joins { join.on.collect(existential: &queries) }
    having?.collect(existential: &queries)
    if case let .expressions(items) = projection {
      for item in items { item.expression.collect(existential: &queries) }
    }
    for key in grouping.collected { key.collect(existential: &queries) }
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expression.collect(existential: &queries)
      }
    }
    return queries
  }

  /// The `Role`s `query` occupies within this `SELECT` — `scalar`, `valued`,
  /// and/or `existential` — the shapes the lowered nodes carry in their
  /// `Subkey`. The same inner SQL used in more than one position occupies more
  /// than one role, so a correlated occurrence's pre-compiled plan is recorded
  /// under each, matching every lowered node that looks it up.
  internal func roles(of query: Query) -> Array<Role> {
    var roles = Array<Role>()
    if scalar.contains(query) { roles.append(.scalar) }
    if valued.contains(query) { roles.append(.valued) }
    if existential.contains(query) { roles.append(.existential) }
    return roles
  }
}

extension Predicate {
  /// Collects the subqueries this predicate nests directly into `queries` — the
  /// whole `Query` of an `exists`/`within`, and any in an operand expression,
  /// a `CASE` guard, or an `AND`/`OR`/`NOT` — without descending a collected
  /// subquery's own body (`compile`/`run` recurse into it).
  internal func collect(subqueries queries: inout Array<Query>) {
    switch self {
    case let .exists(query, _):
      queries.append(query)
    case let .within(lhs, query, _):
      for expression in lhs { expression.collect(subqueries: &queries) }
      queries.append(query)
    case let .quantified(lhs, _, _, query):
      for expression in lhs { expression.collect(subqueries: &queries) }
      queries.append(query)
    case let .comparison(left, _, right):
      left.collect(subqueries: &queries)
      right.collect(subqueries: &queries)
    case let .bound(left, _, _):
      left.collect(subqueries: &queries)
    case let .null(operand, _):
      operand.collect(subqueries: &queries)
    case let .membership(operand, values, _):
      operand.collect(subqueries: &queries)
      for value in values { value.collect(subqueries: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(subqueries: &queries) }
      for expression in rhs { expression.collect(subqueries: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(subqueries: &queries) }
      for element in rows {
        for expression in element { expression.collect(subqueries: &queries) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(subqueries: &queries)
      pattern.collect(subqueries: &queries)
      escape?.collect(subqueries: &queries)
    case let .between(test, lower, upper, _):
      test.collect(subqueries: &queries)
      lower.collect(subqueries: &queries)
      upper.collect(subqueries: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .truth(inner, _, _):
      inner.collect(subqueries: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .not(operand):
      operand.collect(subqueries: &queries)
    }
  }

  /// Whether this predicate nests any `EXISTS`/`IN (Q)` subquery — the schema
  /// path's reachability check reads this to keep a subquery-bearing `HAVING`
  /// from being pruned as unreachable, since its truth is decided at run by the
  /// subquery, not statically.
  internal var subquery: Bool {
    var queries = Array<Query>()
    collect(subqueries: &queries)
    return !queries.isEmpty
  }

  /// Collects the subqueries this predicate nests in an `IN (Q)` position into
  /// `queries` — ONLY a `within`'s `Query`, recursing the same structure
  /// `collect(subqueries:)` does. An `exists`'s `Query` is NOT collected — its
  /// values are never read — so it materialises as a probe.
  internal func collect(valued queries: inout Set<Query>) {
    switch self {
    case .exists:
      // An `EXISTS` operand's values are never read — it materialises as a
      // cardinality probe — so it is NOT a valued occurrence.
      break
    case let .within(lhs, query, _):
      // A row-valued `IN (Q)` (the scalar `x IN (Q)` its one-arity case) reads
      // the subquery's full ROWS — folding the row equality over every one — so
      // it materialises FULL under the `.valued` role, never a cardinality
      // probe.
      for expression in lhs { expression.collect(valued: &queries) }
      queries.insert(query)
    case let .quantified(lhs, _, _, query):
      // A quantified comparison reads the subquery's full ROWS too, folding the
      // row comparison over every one, so it is a `.valued` occurrence as
      // `within` is.
      for expression in lhs { expression.collect(valued: &queries) }
      queries.insert(query)
    case let .comparison(left, _, right):
      left.collect(valued: &queries)
      right.collect(valued: &queries)
    case let .bound(left, _, _):
      left.collect(valued: &queries)
    case let .null(operand, _):
      operand.collect(valued: &queries)
    case let .membership(operand, values, _):
      operand.collect(valued: &queries)
      for value in values { value.collect(valued: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(valued: &queries) }
      for expression in rhs { expression.collect(valued: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(valued: &queries) }
      for element in rows {
        for expression in element { expression.collect(valued: &queries) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(valued: &queries)
      pattern.collect(valued: &queries)
      escape?.collect(valued: &queries)
    case let .between(test, lower, upper, _):
      test.collect(valued: &queries)
      lower.collect(valued: &queries)
      upper.collect(valued: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .truth(inner, _, _):
      inner.collect(valued: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .not(operand):
      operand.collect(valued: &queries)
    }
  }

  /// Collects the scalar-subquery-position queries this predicate nests into
  /// `queries` — an operand expression's own `subquery`, a `CASE` guard's, and
  /// those under `AND`/`OR`/`NOT`, mirroring `collect(subqueries:)`. An
  /// `EXISTS`/`IN (Q)`'s own `Query` is NOT a scalar occurrence — it is
  /// probed/valued — so it is not collected here.
  internal func collect(scalar queries: inout Set<Query>) {
    switch self {
    case .exists:
      break
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      // The `IN`/quantified subquery is `valued`, not scalar; only the outer
      // left-row components' own subqueries are descended.
      for expression in lhs { expression.collect(scalar: &queries) }
    case let .comparison(left, _, right):
      left.collect(scalar: &queries)
      right.collect(scalar: &queries)
    case let .bound(left, _, _):
      left.collect(scalar: &queries)
    case let .null(operand, _):
      operand.collect(scalar: &queries)
    case let .membership(operand, values, _):
      operand.collect(scalar: &queries)
      for value in values { value.collect(scalar: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(scalar: &queries) }
      for expression in rhs { expression.collect(scalar: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(scalar: &queries) }
      for element in rows {
        for expression in element { expression.collect(scalar: &queries) }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(scalar: &queries)
      pattern.collect(scalar: &queries)
      escape?.collect(scalar: &queries)
    case let .between(test, lower, upper, _):
      test.collect(scalar: &queries)
      lower.collect(scalar: &queries)
      upper.collect(scalar: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .truth(inner, _, _):
      inner.collect(scalar: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .not(operand):
      operand.collect(scalar: &queries)
    }
  }

  /// Collects the `EXISTS (Q)`-position subqueries this predicate nests into
  /// `queries` — ONLY an `exists`'s `Query`, recursing the same structure
  /// `collect(subqueries:)` does. An `IN (Q)`'s `Query` is NOT collected
  /// here — its values are read, so it is a `valued` occurrence, not an
  /// existential one — but its operand's own subqueries are still descended.
  internal func collect(existential queries: inout Set<Query>) {
    switch self {
    case let .exists(query, _):
      queries.insert(query)
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      // The `IN`/quantified subquery is `valued` (its full rows are read), not
      // an existential probe; only the outer left-row components are descended.
      for expression in lhs { expression.collect(existential: &queries) }
    case let .comparison(left, _, right):
      left.collect(existential: &queries)
      right.collect(existential: &queries)
    case let .bound(left, _, _):
      left.collect(existential: &queries)
    case let .null(operand, _):
      operand.collect(existential: &queries)
    case let .membership(operand, values, _):
      operand.collect(existential: &queries)
      for value in values { value.collect(existential: &queries) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(existential: &queries) }
      for expression in rhs { expression.collect(existential: &queries) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(existential: &queries) }
      for element in rows {
        for expression in element {
          expression.collect(existential: &queries)
        }
      }
    case let .like(operand, pattern, escape, _):
      operand.collect(existential: &queries)
      pattern.collect(existential: &queries)
      escape?.collect(existential: &queries)
    case let .between(test, lower, upper, _):
      test.collect(existential: &queries)
      lower.collect(existential: &queries)
      upper.collect(existential: &queries)
    case let .distinct(lhs, rhs, _):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .truth(inner, _, _):
      inner.collect(existential: &queries)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .not(operand):
      operand.collect(existential: &queries)
    }
  }
}

extension Predicate.Operand {
  /// Collects the subqueries in this `LIKE` operand — an expression's own, none
  /// for a `:parameter`.
  internal func collect(subqueries queries: inout Array<Query>) {
    if case let .expression(expression) = self {
      expression.collect(subqueries: &queries)
    }
  }

  /// Collects the `IN (Q)`-position subqueries in this `LIKE` operand — an
  /// expression's own, none for a `:parameter`.
  internal func collect(valued queries: inout Set<Query>) {
    if case let .expression(expression) = self {
      expression.collect(valued: &queries)
    }
  }

  /// Collects the scalar-subquery-position queries in this `LIKE` operand — an
  /// expression's own, none for a `:parameter`.
  internal func collect(scalar queries: inout Set<Query>) {
    if case let .expression(expression) = self {
      expression.collect(scalar: &queries)
    }
  }

  /// Collects the `EXISTS (Q)`-position subqueries in this `LIKE` operand —
  /// an expression's own, none for a `:parameter`.
  internal func collect(existential queries: inout Set<Query>) {
    if case let .expression(expression) = self {
      expression.collect(existential: &queries)
    }
  }
}

extension Expression {
  /// Collects the subqueries this expression nests directly into `queries` —
  /// its own scalar `subquery`, and those reached through a `CASE` guard or an
  /// aggregate's argument/FILTER — recursing its call arguments, arithmetic,
  /// aggregate operand and FILTER, `CASE`, `CAST`, `COALESCE`, and `NULLIF`
  /// sub-expressions without descending a collected subquery's own body
  /// (`compile`/`run` recurse into it). A scalar `Expression.subquery` is
  /// collected so the pre-pass compiles it (for its width and type) and the run
  /// materialises its single value.
  internal func collect(subqueries queries: inout Array<Query>) {
    switch self {
    case .column, .literal:
      break
    case let .subquery(query):
      queries.append(query)
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(subqueries: &queries)
      }
      filter?.collect(subqueries: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(subqueries: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(subqueries: &queries)
        when.then.collect(subqueries: &queries)
      }
      otherwise?.collect(subqueries: &queries)
    case let .cast(operand, _):
      operand.collect(subqueries: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(subqueries: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(subqueries: &queries)
      rhs.collect(subqueries: &queries)
    case let .grouping(arguments):
      // As a `call`: descend the arguments so a subquery nested in one is
      // collected for the pre-pass.
      for argument in arguments { argument.collect(subqueries: &queries) }
    case let .window(_, spec):
      // As a `call`: descend the specification's expressions for a nested
      // subquery.
      for expression in spec.expressions {
        expression.collect(subqueries: &queries)
      }
    }
  }

  /// Collects the `IN (Q)`-position subqueries this expression nests — reached
  /// through a `CASE` guard or an aggregate's argument/FILTER, mirroring
  /// `collect(subqueries:)`. An `EXISTS` guard contributes none (it probes),
  /// and a scalar `subquery` contributes none here — its single value is read
  /// (`scalar`), not its column (`values`), so it is a `scalar` occurrence, not
  /// a `valued` one.
  internal func collect(valued queries: inout Set<Query>) {
    switch self {
    case .column, .literal, .subquery:
      break
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(valued: &queries)
      }
      filter?.collect(valued: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(valued: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(valued: &queries)
        when.then.collect(valued: &queries)
      }
      otherwise?.collect(valued: &queries)
    case let .cast(operand, _):
      operand.collect(valued: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(valued: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(valued: &queries)
      rhs.collect(valued: &queries)
    case let .grouping(arguments):
      // As a `call`: descend the arguments for any `IN (Q)`-position subquery.
      for argument in arguments { argument.collect(valued: &queries) }
    case let .window(_, spec):
      // As a `call`: descend the specification's expressions.
      for expression in spec.expressions { expression.collect(valued: &queries) }
    }
  }

  /// Collects the scalar-subquery-position queries this expression nests — its
  /// own `subquery`, and those reached through a `CASE` guard or an aggregate's
  /// argument/FILTER, mirroring `collect(subqueries:)`. A scalar occurrence is
  /// materialised as its collapsed single value (empty → NULL, one row → the
  /// cell, more → `SQLError.cardinality`), distinct from a `valued` (`IN`) or
  /// `EXISTS`-probe occurrence.
  internal func collect(scalar queries: inout Set<Query>) {
    switch self {
    case .column, .literal:
      break
    case let .subquery(query):
      queries.insert(query)
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(scalar: &queries)
      }
      filter?.collect(scalar: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(scalar: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(scalar: &queries)
        when.then.collect(scalar: &queries)
      }
      otherwise?.collect(scalar: &queries)
    case let .cast(operand, _):
      operand.collect(scalar: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(scalar: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(scalar: &queries)
      rhs.collect(scalar: &queries)
    case let .grouping(arguments):
      // As a `call`: descend the arguments for any scalar-subquery position.
      for argument in arguments { argument.collect(scalar: &queries) }
    case let .window(_, spec):
      // As a `call`: descend the specification's expressions.
      for expression in spec.expressions { expression.collect(scalar: &queries) }
    }
  }

  /// Collects the `EXISTS (Q)`-position subqueries this expression nests —
  /// reached through a `CASE` guard or an aggregate's FILTER, mirroring
  /// `collect(subqueries:)`. A scalar `subquery` contributes none here — its
  /// value is read, so it is a `scalar` occurrence, not an existential one.
  internal func collect(existential queries: inout Set<Query>) {
    switch self {
    case .column, .literal, .subquery:
      break
    case let .aggregate(_, operand, _, filter):
      if case let .expression(expression) = operand {
        expression.collect(existential: &queries)
      }
      filter?.collect(existential: &queries)
    case let .call(_, arguments):
      for argument in arguments { argument.collect(existential: &queries) }
    case let .binary(_, lhs, rhs):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .case(whens, otherwise):
      for when in whens {
        when.when.collect(existential: &queries)
        when.then.collect(existential: &queries)
      }
      otherwise?.collect(existential: &queries)
    case let .cast(operand, _):
      operand.collect(existential: &queries)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(existential: &queries) }
    case let .nullif(lhs, rhs):
      lhs.collect(existential: &queries)
      rhs.collect(existential: &queries)
    case let .grouping(arguments):
      // As a `call`: descend the arguments for any `EXISTS (Q)`-position
      // subquery.
      for argument in arguments { argument.collect(existential: &queries) }
    case let .window(_, spec):
      // As a `call`: descend the specification's expressions.
      for expression in spec.expressions {
        expression.collect(existential: &queries)
      }
    }
  }

  /// Whether this expression nests any `EXISTS`/`IN (Q)`/scalar subquery —
  /// reached through a `CASE` guard or an aggregate's argument/FILTER, or its
  /// own scalar `subquery`. The empty-fold reads this to validate a
  /// subquery-guarded projection or sort expression (whose selected branch a
  /// run decides at run by the subquery, not statically) rather than prune it,
  /// so `columns(of:)` surfaces the same fault the run would (`SELECT CASE WHEN
  /// EXISTS (Q) THEN 1 / 0 …` raises `.divide`). A subquery-free expression
  /// keeps the precise empty-fold.
  internal var subquery: Bool {
    var queries = Array<Query>()
    collect(subqueries: &queries)
    return !queries.isEmpty
  }
}

// MARK: - Aggregation

extension Catalog where Self: ~Escapable {
  /// Compiles an aggregate `select` into `Project(Limit(Sort(Having(Aggregate(
  /// source)))))`, the `source` the WHERE/join chain and the aggregate node
  /// grouping it.
  ///
  /// The source (a scan, or a left-deep join chain) materialises exactly the
  /// ordinals the WHERE, the `GROUP BY` keys, and the aggregate arguments read.
  /// The `aggregate` node groups it by the keys and folds each aggregate over a
  /// group, yielding grouped records whose slots are the key values then the
  /// aggregate results. The projection, `HAVING`, and `ORDER BY` lower against
  /// that grouped slot space through a `Grouped`, which also enforces the
  /// standard rule that every non-aggregated projection/`ORDER BY` column
  /// appear in the `GROUP BY`.
  internal borrowing func group(_ select: Select, _ relation: Relation,
                                _ from: Resolved, _ context: Context)
      throws(SQLError) -> Plan {
    // The augmented `context` threads to `subquery(of:)`, which reveals the
    // base — this select's and every enclosing select's derived aliases
    // dropped, the CTEs and store relations kept — before lowering a nested
    // subquery, so its FROM sees no derived alias while a CTE a same-named
    // derived alias shadows stays visible (a grouped `ORDER BY SUM((SELECT x
    // FROM d))` reads the CTE `d` beneath the derived `d`). Resolve every
    // joined relation and lay the FROM relation and each joined one end to end
    // in one combined ordinal space (as the non-aggregate join path does), so
    // the WHERE, keys, and aggregate arguments resolve uniformly. A LATERAL
    // join (CROSS/OUTER APPLY) is supported here too: the front half is shared
    // with the non-aggregate path, so the apply body's output columns land in
    // scope for the keys, aggregate arguments, HAVING, and ORDER BY, and the
    // chain carries the correlated `apply` node the aggregate then groups.
    let (joined, relations) = try resolve(from: relation, schema: from.schema,
                                          joins: select.joins, context)
    // Model the `NATURAL`/`USING` merged columns in the scope and synthesize
    // each named-column join's lowered `on` filter, as the non-aggregate join
    // path does — so a bare merged column groups/projects by the coalesced
    // value.
    let (ons, merged, merges) = try merges(over: relations, select.joins)
    let scope = Scope(relations, merged: merged)

    // Each join's ON predicate lowers to a `Filter` at its own chain level,
    // resolved against only the prefix already in scope (as the non-aggregate
    // path does). A `column = column` conjunct becomes a `match` hash-join key;
    // the rest is a residual the join runs as a filter.
    // Each join's prefix scope — the relations available at that join point,
    // never one joined later — carries the merged columns accumulated before
    // this join, so a chained `USING` `on` keys on the merged value.
    let prefixes = select.joins.indices.map { index in
      Scope(Array(relations[0 ... index + 1]), merged: merges[index])
    }
    // Resolve each LATERAL join's body once against the preceding FROM — the
    // FROM relation and the joins before this one (`relations[0…index]`, one
    // less than the prefix, which includes the join's own relation) — so a body
    // column naming a preceding relation correlates outward and the body's plan
    // is pre-compiled for the per-outer-row apply. A non-lateral join records
    // nothing here (its `nil` slot). The apply is `.inner` (CROSS APPLY, which
    // drops an unmatched outer row) or `.left` (OUTER APPLY, which NULL-extends
    // one); `.right`/`.full` are nonsensical for a correlated body, so fault.
    let empty: (key: Subkey, correlation: Correlation)? = nil
    var laterals = Array(repeating: empty, count: select.joins.count)
    for index in select.joins.indices {
      let join = select.joins[index]
      guard join.relation.lateral,
          case let .derived(body) = join.relation.source else { continue }
      guard join.kind == .inner || join.kind == .left else {
        throw .state("0A000", "a RIGHT/FULL LATERAL join is not supported")
      }
      let preceding = Scope(Array(relations[0 ... index]),
                            merged: merges[index])
      laterals[index] = try lateral(body, against: preceding,
                                    columns: join.relation.columns, context)
    }
    // Compile every nested subquery once for arity/type, ahead of lowering, and
    // discover each one's correlation: a join `ON`'s against its prefix scope,
    // the WHERE against the join `scope`. Only the WHERE and join ONs admit a
    // correlated column of this query; the aggregations, projection, `HAVING`,
    // and `ORDER BY` lower under a barred seam. `validate` gates the eager
    // type-check of a filtered-out derived body a nested subquery names, off on
    // the run path, on for a schema check.
    let plans = try subquery(of: select, context, enclosing: scope,
                             prefixes: prefixes)
    let barred = plans.rest.barred
    var matches = Array<Filter>()
    matches.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      // A `NATURAL`/`USING` join's `on` is the synthesized, already-lowered
      // filter (`ons[index]`, `nil` for a degenerate `NATURAL` join); a plain
      // join lowers its written `ON` against the prefix scope.
      if let on = ons[index] {
        matches.append(on)
      } else {
        try matches.append(prefixes[index].on(select.joins[index].on,
                                              context.routines,
                                              subquery: plans.on(index)))
      }
    }
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause, context.routines,
                                  subquery: plans.rest)
    }

    // This select's grouping keys and — for one arm of an expanded `GROUPING
    // SETS` — the superset (the union of every set's keys, so an absent key
    // NULLs by resolved identity). A `.sets` never reaches here: `compile`
    // expands it to a union of `.arm` selects before this runs.
    let (grouping, superset): (Array<Expression>, Array<Expression>) =
        switch select.grouping {
        case let .keys(keys): (keys, [])
        case let .arm(keys, superset): (keys, superset)
        case .sets: ([], [])
        }
    // The `GROUP BY` keys and the aggregate arguments lower to combined
    // base-ordinal terms; the aggregates are collected from the projection, the
    // `HAVING`, and the `ORDER BY` sort keys (deduplicated so the same
    // aggregate computes once).
    let keys = try grouping.map { key throws(SQLError) -> Term in
      // Each key lowers through `scope.term`: a bare column a local relation
      // binds reads its combined slot; a bare `NATURAL`/`USING` merged column
      // lowers to its `COALESCE(left, right)` value (so the aggregate node
      // groups a `RIGHT`/`FULL` join's unmatched row by the merged value, not a
      // NULL left column); a name none binds is a candidate correlated
      // reference (a LATERAL body grouping on a preceding column) — the
      // `barred` surface lowers it to a `Term.parameter` the apply binds per
      // outer row, admitting it only under the LATERAL `everywhere` seam and
      // faulting `.unsupported` on an ordinary grouped subquery, else the
      // genuine unknown-column `.column`. A general key lowers by `term` too.
      try scope.term(key, context.routines, subquery: barred)
    }
    var expressions = Array<Expression>()
    for expression in select.projection.projected {
      expression.collect(into: &expressions)
    }
    if let having = select.having {
      having.collect(into: &expressions)
    }
    // A grouped `ORDER BY` may sort on an aggregate that is neither projected
    // nor in the `HAVING` (`GROUP BY Dept ORDER BY COUNT(*) DESC`), so collect
    // its sort-key expressions too.
    if let order = select.order {
      for key in order.keys {
        if case let .expression(expression) = key.sort {
          expression.collect(into: &expressions)
        }
      }
    }
    // Resolve each collected aggregate and dedup by its resolved
    // `Aggregation` — function plus resolved argument term. `collect` deduped
    // only exact AST spellings, so a qualification-equivalent pair
    // (`SUM(Amount)` projected, `SUM(Sales.Amount)` in the `ORDER BY`) survived
    // as two expressions; both resolve to the same `Aggregation` in a
    // single-relation scope, so this folds them into one grouped slot — the
    // aggregate computes once and both clauses read/order that slot (which lets
    // the DISTINCT sort-key check accept it).
    var aggregations = Array<Aggregation>()
    for expression in expressions {
      let aggregation = try expression.aggregation(scope, context.routines,
                                                   subquery: barred)
      if !aggregations.contains(aggregation) {
        aggregations.append(aggregation)
      }
    }

    // The source materialises exactly the ordinals the WHERE, the keys, and the
    // aggregate arguments read — never the projection/HAVING/ORDER, which read
    // the grouped record. Pack them per relation in chain order, building the
    // combined-ordinal → slot map and each relation's leaf ordinals.
    var references = Set<Int>()
    for match in matches { match.references(into: &references) }
    predicate?.references(into: &references)
    for key in keys { key.references(into: &references) }
    for aggregation in aggregations {
      aggregation.references(into: &references)
    }
    // A LATERAL apply reads its correlation's outer ordinals from the left
    // chain's record, so those preceding-relation ordinals must be materialised
    // (given a packed slot) even when no clause of this select references them
    // — else the correlation's remap through `slot` finds no slot for the outer
    // column its body names.
    for lateral in laterals {
      references.formUnion(lateral?.correlation.slots ?? [])
    }
    let combined = references.sorted()

    var slot = Dictionary<Int, Int>(minimumCapacity: combined.count)
    var locals = Array<Array<Int>>()
    var packed = 0
    for (offset, extent) in scope.layout {
      let local = combined.compactMap {
        offset <= $0 && $0 < offset + extent ? $0 - offset : nil
      }
      for index in local.indices {
        slot[offset + local[index]] = packed + index
      }
      locals.append(local)
      packed += local.count
    }

    let seed = from.leaf(locals[0])
    var chain = select.joins.indices.reduce(seed) { chain, index in
      let on = matches[index].remapped(through: slot)
      // A LATERAL join re-evaluates its pre-compiled body per outer row (a
      // correlated apply): the apply node carries the body occurrence's `key`
      // and its correlation (its `slot` outer ordinals remapped to the left
      // chain's packed slots, so the per-row bind reads the correct cell) plus
      // the referenced body-output `ordinals` this select takes, laid after the
      // left's slots. Its `on` filters the concatenated pair; INNER APPLY drops
      // a left row with no surviving right row.
      if let lateral = laterals[index] {
        return .apply(chain, key: lateral.key,
                      correlation: lateral.correlation.remapped(through: slot),
                      ordinals: locals[index + 1], on: on,
                      kind: select.joins[index].kind)
      }
      let leaf = joined[index].leaf(locals[index + 1])
      switch select.joins[index].kind {
      case .inner:
        return .select(on, .product(chain, leaf))
      case .left, .right, .full:
        return .outer(chain, leaf, on: on, kind: select.joins[index].kind)
      }
    }
    if let predicate {
      chain = .select(predicate.remapped(through: slot), chain)
    }

    // The aggregate node groups the source by the remapped keys and folds each
    // aggregate; its output is the grouped slot space the rest lowers against.
    let node = Plan.aggregate(keys: keys.map { $0.remapped(through: slot) },
                              aggregates: aggregations.map {
                                $0.remapped(through: slot)
                              }, chain)

    // The superset's lowered terms — the columns another set groups on — so an
    // arm's projection/HAVING reference to a key this set omits NULLs by
    // resolved identity (empty for an ordinary grouped query).
    let supers = try superset.map { key throws(SQLError) -> Term in
      try scope.term(key, context.routines, subquery: barred)
    }
    // Lower the projection, HAVING, and ORDER BY against the grouped slot
    // space, enforcing the projection rule (every non-aggregated column must be
    // a GROUP BY key).
    var grouped = try Grouped(scope, grouping, keys, aggregations,
                              superset: supers, subquery: barred)
    let projection = try grouped.terms(select.projection, context.routines,
                                       subquery: barred)
    let having: Filter? = if let clause = select.having {
      try grouped.lower(clause, context.routines, subquery: barred)
    } else {
      nil
    }
    var order = if let clause = select.order {
      try grouped.order(clause, projection, context.routines,
                        subquery: barred)
    } else {
      Array<SortKey>()
    }

    // Under DISTINCT every ORDER BY key must be a select-list value — the
    // dedup runs on the projected rows, so ordering on a dropped value is
    // ill-defined (see `distinct`). The order keys and projection are
    // in grouped-slot space here, aligned with the AST keys index-for-index.
    // A key matching a projected term is rebound to that projected column so
    // the sort reuses the materialised slot rather than re-evaluating it.
    if select.distinct, let clause = select.order {
      order = try distinct(clause.keys, order, projection)
    }

    // The HAVING filters groups below the sort, the slot the WHERE occupies on
    // the non-aggregate path, so the shared `shaped` applies it identically —
    // an ORDER BY key naming a computed aggregate output (`COUNT(*) * 2 AS n`)
    // then materialises once and sorts on the returned value.
    return node.shaped(distinct: select.distinct, projection: projection,
                       filter: having, order: order, limit: select.limit)
  }
}

extension Projection {
  /// The projected expressions — an `expressions` list yields each item's
  /// expression; a `*` or bare-column list yields none (no aggregate can hide
  /// in them). An aggregate query's projection is always the `expressions` case
  /// (an aggregate call makes it one).
  internal var projected: Array<Expression> {
    switch self {
    case .all, .columns:
      []
    case let .expressions(items):
      items.map(\.expression)
    }
  }
}

extension Expression {
  /// Collects the distinct aggregate expressions within this expression into
  /// `expressions`, in first-appearance order — the same aggregate written
  /// twice computes once.
  internal func collect(into expressions: inout Array<Expression>) {
    switch self {
    case .column, .literal, .subquery:
      // An aggregate inside a scalar `subquery` belongs to that subquery's own
      // grouping, not the enclosing query's, so it is not collected here — the
      // subquery is compiled and run as a whole plan.
      break
    case .aggregate:
      if !expressions.contains(self) {
        expressions.append(self)
      }
    case let .call(_, arguments):
      for argument in arguments { argument.collect(into: &expressions) }
    case let .binary(_, lhs, rhs):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .case(whens, otherwise):
      for branch in whens {
        branch.when.collect(into: &expressions)
        branch.then.collect(into: &expressions)
      }
      otherwise?.collect(into: &expressions)
    case let .cast(operand, _):
      operand.collect(into: &expressions)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(into: &expressions) }
    case let .nullif(lhs, rhs):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .grouping(arguments):
      // GROUPING is not an aggregate, but — like a `call` — descend its
      // arguments so any aggregate nested in one is collected (a GROUP BY
      // expression never nests one, so this gathers nothing in practice).
      for argument in arguments { argument.collect(into: &expressions) }
    case let .window(_, spec):
      // A window function is not a query aggregate, but — like a `call` —
      // descend its specification's expressions so an aggregate nested in a
      // partition or order (`ROW_NUMBER() OVER (ORDER BY SUM(x))`) is collected.
      for expression in spec.expressions {
        expression.collect(into: &expressions)
      }
    }
  }

  /// Lowers this AST `.aggregate` expression to an `Aggregation`, its argument
  /// (if any) and its `FILTER` predicate resolved to combined base-ordinal
  /// forms through `scope`.
  ///
  /// `COUNT(*)` has no argument (it counts rows); every other aggregate lowers
  /// its single operand expression to a term. The `DISTINCT` set quantifier
  /// carries through as a flag; a `FILTER (WHERE …)` lowers to a source-space
  /// `Filter` — the same combined base-ordinal space the argument resolves in,
  /// so it reads the pre-aggregation row the fold gates on. `self` is always an
  /// `.aggregate` — `collect` gathers only those.
  internal func aggregation(_ scope: Scope, _ routines: Routines = [:],
                            subquery: Resolution = .unsupported)
      throws(SQLError) -> Aggregation {
    guard case let .aggregate(function, operand, distinct, filter) = self else {
      throw .state("XX000", "expected an aggregate")
    }
    let argument: Term? = switch operand {
    case .star:
      nil
    case let .expression(expression):
      try scope.term(expression, routines, subquery: subquery)
    }
    let gate: Filter? = if let filter {
      try scope.lower(filter, routines, subquery: subquery)
    } else {
      nil
    }
    return Aggregation(function: function, argument: argument,
                       distinct: distinct, filter: gate)
  }
}

extension Predicate {
  /// Collects the distinct aggregates within this predicate into `expressions`.
  internal func collect(into expressions: inout Array<Expression>) {
    switch self {
    case let .comparison(left, _, right):
      left.collect(into: &expressions)
      right.collect(into: &expressions)
    case let .bound(left, _, _):
      left.collect(into: &expressions)
    case let .null(expression, _):
      expression.collect(into: &expressions)
    case let .membership(operand, values, _):
      operand.collect(into: &expressions)
      for value in values { value.collect(into: &expressions) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(into: &expressions) }
      for expression in rhs { expression.collect(into: &expressions) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(into: &expressions) }
      for element in rows {
        for expression in element { expression.collect(into: &expressions) }
      }
    case .exists:
      // A subquery is its own scope — an aggregate inside it folds over its
      // group, not the enclosing one — so it contributes none here.
      break
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      // Only the OUTER left-row components may hold an enclosing-group
      // aggregate.
      for expression in lhs { expression.collect(into: &expressions) }
    case let .like(operand, pattern, escape, _):
      operand.collect(into: &expressions)
      pattern.collect(into: &expressions)
      escape?.collect(into: &expressions)
    case let .between(test, lower, upper, _):
      test.collect(into: &expressions)
      lower.collect(into: &expressions)
      upper.collect(into: &expressions)
    case let .distinct(lhs, rhs, _):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .truth(inner, _, _):
      inner.collect(into: &expressions)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(into: &expressions)
      rhs.collect(into: &expressions)
    case let .not(operand):
      operand.collect(into: &expressions)
    }
  }
}
