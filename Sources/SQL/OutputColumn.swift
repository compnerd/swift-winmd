// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The result schema of a query — the columns it would yield, named and typed,
/// WITHOUT running it.
///
/// A `SELECT`'s result has a name and a type per column: `SELECT *` takes them
/// from the relations in scope, a bare-column list from the column names, and
/// an expression list from each item's alias (else a derived name, else a
/// positional `column N`). `Catalog.columns(of:)` computes this by RESOLVING
/// the query — the same name → schema resolution compilation runs — but never
/// opening a cursor, so it is safe over an empty or costly source. It is the
/// one capability behind the `INFORMATION_SCHEMA` overlay's own headers, a
/// future `SELECT *` empty-result header, and a `.schema` metacommand.

/// One column of a query's result: its output name and its value type.
public struct OutputColumn: Hashable, Sendable {
  /// The column's output name — an alias, a source column's name, or a
  /// positional `column N` for an unnamed expression.
  public let name: String

  /// The column's value type.
  public let type: ValueType

  public init(name: String, type: ValueType) {
    self.name = name
    self.type = type
  }
}

extension Catalog where Self: ~Escapable {
  /// The result columns `query` would yield, named and typed, resolved WITHOUT
  /// executing it.
  ///
  /// The result columns are the FIRST arm's projection (the ISO rule a `UNION`
  /// follows), so a union names its result off its leading `SELECT`. The column
  /// count matches the compiled plan's `width`; the names and types come from
  /// re-walking the projection exactly as compilation resolves it:
  ///
  ///   - `SELECT *` — every real column of every relation in scope, in chain
  ///     order (never a virtual column), named and typed from each relation's
  ///     schema, matching what `Scope.terms(.all)` projects.
  ///   - `SELECT a, b` — each column's name, typed from the relation that
  ///     resolves it.
  ///   - `SELECT f(a) AS x, b` — each item's alias, else a bare column's name,
  ///     else a positional `column N` (1-based). A bare column carries its
  ///     source type and a literal its own; every other expression is reported
  ///     `.integer`, the engine's exact-numeric default.
  ///
  /// The result columns come from the first arm's projection, but ONLY after
  /// the WHOLE query validates: `compile` resolves every arm (each `WHERE`,
  /// join, and projection) and cross-checks a `UNION`'s arm arity, without
  /// opening a cursor. So a query whose first arm names its columns cleanly but
  /// whose `WHERE` references a missing column, or whose second `UNION` arm
  /// mismatches the arity, faults here EXACTLY as a run would rather than
  /// returning headers for a query that cannot run.
  ///
  /// `routines` are the scalar functions a run would resolve against — pass the
  /// SAME set here so a projected call `TAG(Name)` reports its declared return
  /// type rather than the `.integer` default. It defaults to none, matching a
  /// run with no custom routines.
  ///
  /// - Throws: the same resolution faults `run(query)` raises —
  ///   `SQLError.relation` for an unknown relation,
  ///   `SQLError.column`/`SQLError.ambiguous` for a column reference that does
  ///   not resolve to exactly one relation, `SQLError.function` for a call to
  ///   an unregistered scalar function anywhere in the query, `SQLError.arity`
  ///   for a `UNION` whose arms project differing column counts.
  public borrowing func columns(of query: Query, routines: Routines = [:])
      throws(SQLError) -> Array<OutputColumn> {
    // Validate the whole query without executing — the same compile the run
    // path drives, resolving every arm and cross-checking a UNION's arity — so
    // a schema is returned only for a query that could actually run.
    _ = try compile(query)
    // Type-check every REACHABLE operand and call across all arms — the
    // projection, `WHERE`, and `HAVING` of each. `compile` resolves a call's
    // arguments but cannot check the routine EXISTS or that it is called with
    // its declared arity and argument kinds, and the first-arm walk below
    // sees only the first projection; `typecheck` faults an unknown or
    // ill-typed call or a bad operand anywhere a run would evaluate it, and —
    // like the executor — skips an arm a `false AND`/`true OR` short-circuits,
    // so a query that runs is not rejected for an unreachable call.
    let routines = Routines.standard.merging(routines)
    try typecheck(query, [:], routines: routines)
    // The result columns are the first arm's projection (the ISO rule a UNION
    // follows), resolved against the validated scope; a scalar call types from
    // its routine's declared return type — the engine prelude merged under
    // `routines`, exactly as a run seeds them, so a standard call (`BITAND`)
    // types without the caller re-supplying it.
    return try columns(of: query.first, [:], routines: routines)
  }

  /// The result columns of a single `select`, resolved against this catalog
  /// with the in-scope `ctes` — the per-arm worker `columns(of:)` drives.
  ///
  /// This NAMES AND TYPES the projection; it does not re-validate the WHERE,
  /// joins, GROUP BY, HAVING, or ORDER BY. Whole-query validation belongs to
  /// `compile` — the public `columns(of query:)` runs it — so this worker never
  /// duplicates (and never drifts from) that resolution. It runs only after
  /// compilation has proved the arm resolves. `routines` are the scalar
  /// routines a call types from — its declared return type — rather than the
  /// `.integer` default.
  borrowing func columns(of select: Select, _ ctes: CTEs,
                         visited: Set<String> = [],
                         routines: Routines = [:])
      throws(SQLError) -> Array<OutputColumn> {
    try scope(of: select, ctes, visited: visited, routines: routines)
        .columns(of: select.projection, routines)
  }

  /// The name-resolution scope of `select` — its FROM relation and each joined
  /// relation resolved to schema and laid end to end in one combined ordinal
  /// space, the same layout compilation resolves a projection against. A
  /// FROM-less `SELECT <expr-list>` projects over no relation, so its scope is
  /// empty. It reads only schemas, never a cursor.
  borrowing func scope(of select: Select, _ ctes: CTEs,
                       visited: Set<String> = [],
                       routines: Routines = [:])
      throws(SQLError) -> Scope {
    guard let relation = select.from else { return Scope([]) }
    var relations =
        [(relation, try schema(of: relation, ctes, visited: visited,
                               routines: routines))]
    for join in select.joins {
      let joined = try schema(of: join.relation, ctes, visited: visited,
                              routines: routines)
      relations.append((join.relation, joined))
    }
    return Scope(relations)
  }

  /// Type-checks every operand in `query` — the projection, `WHERE`, and
  /// `HAVING` of EVERY arm — throwing the run-time fault a bad operand would.
  ///
  /// The result schema types only the FIRST arm's projection (the ISO rule), so
  /// a later `UNION` arm's or a `HAVING`'s operand-type error would otherwise
  /// go unadvertised — `SELECT Age FROM t UNION SELECT Name + 1 FROM t` or `…
  /// HAVING SUM(Name) > 0` resolves its names but `Arithmetic.apply`/
  /// `Aggregate.fold` faults `SQLError.operand` at run. `compile` cannot catch
  /// this (no evaluating term is built), so a schema path type-checks each arm
  /// before returning metadata. It reads no cursor.
  borrowing func typecheck(_ query: Query, _ ctes: CTEs,
                           visited: Set<String> = [],
                           routines: Routines = [:])
      throws(SQLError) {
    switch query {
    case let .select(select):
      try typecheck(select, ctes, visited: visited, routines: routines)
    case let .union(left, select, _):
      try typecheck(left, ctes, visited: visited, routines: routines)
      try typecheck(select, ctes, visited: visited, routines: routines)
    }
  }

  /// Type-checks a single arm against its own scope, validating exactly the
  /// expressions a run reaches — throwing the operand or function fault a run
  /// would — and skipping those the executor's evaluation order makes
  /// unreachable. The clauses run `WHERE` → group/fold → `HAVING` → limit →
  /// projection, so:
  ///
  ///   - `WHERE` runs first and always validates (`check`, short-circuit
  ///     aware).
  ///   - A statically-false `WHERE` filters every row, so a `GROUP BY` forms no
  ///     group and a non-aggregate query yields no row — nothing after it is
  ///     checked. A whole-result aggregate (no `GROUP BY`) is the exception: it
  ///     emits one empty group, so its `HAVING` and projection are EVALUATED
  ///     over that group (`empty`) — a divide, overflow, or bad routine call
  ///     faults as a run would; an aggregate operand (zero rows) does not.
  ///   - Otherwise the aggregate FOLDS in the projection and `HAVING` run over
  ///     the filtered rows in the group node, before `HAVING` and any limit, so
  ///     every aggregate operand is validated unconditionally (a short-circuit
  ///     or zero-row limit does not spare it).
  ///   - `HAVING` filters grouped rows before the limit: it validates
  ///     short-circuit aware, and a statically false `HAVING` (like a false
  ///     `WHERE`) leaves the projection's non-aggregate work unreachable.
  ///   - The projection runs LAST: a limit that drops every row it would yield
  ///     leaves its non-aggregate work unreachable — a `FETCH FIRST 0 ROWS
  ///     ONLY`, or a positive `OFFSET` over a whole-result aggregate's sole row
  ///     (its output type is still DERIVED for the schema, non-faulting);
  ///     otherwise it validates fully.
  private borrowing func typecheck(_ select: Select, _ ctes: CTEs,
                                   visited: Set<String>,
                                   routines: Routines)
      throws(SQLError) {
    let scope = try scope(of: select, ctes, visited: visited,
                          routines: routines)
    if let predicate = select.predicate {
      try scope.check(predicate, routines)
      // A false WHERE filters every row, so a GROUP BY forms no group and a
      // non-aggregate query yields no row — nothing after is reachable. A
      // whole-result aggregate (an aggregate projection or HAVING, no GROUP BY)
      // still emits ONE empty group: the fold sees zero rows, so an aggregate
      // operand never evaluates (it propagates NULL), but the HAVING and
      // projection run over the group's results, so EVALUATE them (`empty`) — a
      // divide, overflow, or bad routine call faults as the run would.
      if scope.constant(predicate) == false {
        if Engine.aggregates(select), select.grouping.isEmpty {
          if let having = select.having {
            // HAVING filters the group BEFORE any OFFSET/FETCH limit, so
            // evaluate it UNCONDITIONALLY — a zero `FETCH` or positive `OFFSET`
            // spares only the projection, never HAVING. It validates its
            // operands (a divide, overflow, or bad routine call faults) AND
            // yields the group's fate — a group passes only when HAVING is TRUE,
            // so FALSE or UNKNOWN drops it and the projection is unreachable.
            if try scope.empty(having, routines) != true { return }
          }
          // The lone empty group is itself unreachable when a limit drops the
          // one row it would emit — a zero `FETCH` or any positive `OFFSET` — so
          // the projection never evaluates over it.
          if !drops(select.limit, single: true),
              case let .expressions(items) = select.projection {
            for item in items { _ = try scope.empty(item.expression, routines) }
          }
        }
        return
      }
    }
    // Aggregate folds run before HAVING and any limit, so validate every
    // aggregate operand in the projection and HAVING unconditionally.
    if case let .expressions(items) = select.projection {
      for item in items { try scope.aggregates(in: item.expression, routines) }
    }
    if let having = select.having {
      try scope.aggregates(in: having, routines)
      try scope.check(having, routines)
      // A false HAVING filters every group before the projection, so the
      // projection's non-aggregate work is unreachable.
      if scope.constant(having) == false { return }
    }
    // The projection runs after any limit: a limit that drops every row it
    // would yield leaves only its aggregate folds (validated above) reachable.
    // A whole-result aggregate emits exactly ONE row, so a positive OFFSET
    // drops it too — not just a zero FETCH.
    let sole = Engine.aggregates(select) && select.grouping.isEmpty
    if !drops(select.limit, single: sole),
        case let .expressions(items) = select.projection {
      for item in items { _ = try scope.type(of: item.expression, routines) }
    }
  }

  /// Whether `limit` drops the one row a `single`-row result would yield,
  /// making a projection over that row unreachable. A zero `FETCH`
  /// (`count == 0`) drops every row; a positive `OFFSET` skips the sole row of
  /// a single-row result (a whole-result aggregate). A `nil` `count` caps
  /// nothing, and an `offset` of `0` skips nothing.
  private func drops(_ limit: Limit?, single: Bool) -> Bool {
    guard let limit else { return false }
    return limit.count == 0 || (single && limit.offset >= 1)
  }

  /// The name-resolution schema of `relation`, resolved against this catalog
  /// and the in-scope `ctes` — a CTE first, then a view, then a base table, the
  /// same precedence `compile` resolves a relation by. It reads only schemas,
  /// never a cursor, so it never executes. `visited` names the views already
  /// being resolved down this chain, breaking a cyclic view (`A` over `B` over
  /// `A`) that would otherwise re-enter here. `routines` ride through so a view
  /// body projecting a scalar call types it from the routine's declared return
  /// type, not the `.integer` default.
  borrowing func schema(of relation: Relation, _ ctes: CTEs,
                        visited: Set<String> = [],
                        routines: Routines = [:])
      throws(SQLError) -> Schema {
    let name = relation.name
    if let cte = ctes[name.lowercased()] {
      return cte.schema()
    }
    if let view = view(named: name) {
      // A view's declared schema types every column `.integer`, since a view
      // stores no types; resolve the view body's own types so a `SELECT *` over
      // the view reports each column's true type. The names stay the view's
      // DECLARED ones; only the types come from the resolved body.
      let base = view.schema()
      // A cyclic view cannot resolve its body's types: resolving it would
      // re-enter this view forever, so break the cycle and fall back to the
      // declared schema (every type the `.integer` default). `try?` cannot
      // catch this — the recursion overflows the stack rather than throwing.
      guard !visited.contains(name.lowercased()) else { return base }
      // Type-check the body's REACHABLE operands and calls across every arm and
      // clause — `compile` cannot check a routine EXISTS, the first-arm resolve
      // below sees only the first projection, and the outer query's walk does
      // not reach into a body. `typecheck` faults an unknown call or a bad
      // operand a `SELECT * FROM v` run would evaluate — a `WHERE`/`HAVING`, a
      // later `UNION` arm — while skipping an arm a short-circuit proves
      // unreachable.
      let inner = visited.union([name.lowercased()])
      try typecheck(view.query, [:], visited: inner, routines: routines)
      // Type off the body's first arm (the ISO rule for a UNION). Arity — the
      // body's width against the declared columns — is `compile`'s job (the
      // public entry runs it), so on a shortfall fall back to the declared
      // schema rather than re-checking it here.
      let resolved =
          try columns(of: view.query.first, [:], visited: inner,
                      routines: routines)
      guard resolved.count == base.width else { return base }
      return Schema(width: base.width, extent: base.extent, names: base.names,
                    types: resolved.map(\.type), virtuals: base.virtuals)
    }
    guard let table = table(named: name) else {
      throw .relation(name)
    }
    return table.schema()
  }
}

extension Scope {
  /// The output columns a `projection` yields over this scope, named and typed
  /// — `routines` type a scalar call from its declared return type.
  internal func columns(of projection: Projection,
                        _ routines: Routines = [:])
      throws(SQLError) -> Array<OutputColumn> {
    return switch projection {
    case .all:
      outputs()
    case let .columns(references):
      try references.map { column throws(SQLError) in try output(of: column) }
    case let .expressions(items):
      try items.indices.map { index throws(SQLError) in
        try output(items[index], at: index, routines)
      }
    }
  }

  /// The output columns of a `SELECT *` over this scope — every real column of
  /// every relation, in chain order, named and typed from each relation's
  /// schema (never a virtual column) — the terms `terms(.all)` projects.
  internal func outputs() -> Array<OutputColumn> {
    schemas.flatMap { schema in
      (0 ..< schema.width).map {
        OutputColumn(name: schema.names[$0], type: schema.types[$0])
      }
    }
  }

  /// The output column a bare `column` reference yields: its own name (its
  /// spelling as written), typed from the relation that resolves it.
  internal func output(of column: Column) throws(SQLError) -> OutputColumn {
    let type = try type(at: ordinal(of: column))
    return OutputColumn(name: column.name, type: type)
  }

  /// The output column a projected `item` at 0-based `index` yields: its
  /// inferable output name (`Projected.name` — an alias, else a bare column's
  /// name), else a positional `column N` (1-based). A bare column carries its
  /// source type and a literal its own; a scalar call its routine's declared
  /// return type; every other expression `.integer`.
  internal func output(_ item: Projected, at index: Int,
                       _ routines: Routines = [:])
      throws(SQLError) -> OutputColumn {
    let name = item.name ?? "column \(index + 1)"
    // DERIVE the nominal output type (`validate: false`): the schema reports
    // the type a run would produce and never faults on an operand. Run-time
    // operand and call validation is `typecheck`'s job, reachability-aware, so
    // a schema resolves even for an expression a zero-row limit makes
    // unreachable.
    return try OutputColumn(name: name,
                            type: type(of: item.expression, routines,
                                       validate: false))
  }
}
