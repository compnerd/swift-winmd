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
    // Extend the scope with any `definition_schema.` store relation the query
    // names, so its result schema resolves the reserved relation the same as a
    // run would.
    let ctes = augment([:], for: query)
    // Validate the whole query without executing — the same compile the run
    // path drives, resolving every arm and cross-checking a UNION's arity — so
    // a schema is returned only for a query that could actually run.
    _ = try compile(query, ctes)
    // `compile` resolves each call's ARGUMENTS but cannot check the routine
    // EXISTS (it holds no routine set; the name binds at execute), and the
    // first-arm type walk below faults an unknown call it PROJECTS but not one
    // in a `WHERE`/`HAVING` or a later `UNION` arm — so gate on `calls`, the
    // whole-query inventory, against the same routines a run resolves: a query
    // naming an unregistered function faults here EXACTLY as a run would rather
    // than returning headers for a schema it could not produce.
    let returns = Routines.standard.merging(routines).returns
    for name in query.calls where returns[name.lowercased()] == nil {
      throw .function(name)
    }
    // Calls resolve, so type-check every arm's operands (a later arm's
    // `Name + 1`, a `HAVING SUM(Name)`) — a fault the first-arm schema walk
    // below would miss but a run would raise.
    try typecheck(query, ctes, returns: returns)
    // The result columns are the first arm's projection (the ISO rule a UNION
    // follows), resolved against the validated scope; a scalar call types from
    // the routine return types — the engine prelude merged under `routines`,
    // exactly as a run seeds them, so a standard call (`BITAND`) types without
    // the caller re-supplying it.
    return try columns(of: query.first, ctes, returns: returns)
  }

  /// The result columns of a single `select`, resolved against this catalog
  /// with the in-scope `ctes` — the per-arm worker `columns(of:)` drives.
  ///
  /// This NAMES AND TYPES the projection; it does not re-validate the WHERE,
  /// joins, GROUP BY, HAVING, or ORDER BY. Whole-query validation belongs to
  /// `compile` — the public `columns(of query:)` runs it, and the introspection
  /// builder runs it per view — so this worker never duplicates (and never
  /// drifts from) that resolution. It runs only after compilation has proved
  /// the arm resolves. `returns` maps a scalar routine's name to its declared
  /// return type, so a call types from it rather than the `.integer` default.
  borrowing func columns(of select: Select, _ ctes: CTEs,
                         visited: Set<String> = [],
                         returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) -> Array<OutputColumn> {
    try scope(of: select, ctes, visited: visited, returns: returns)
        .columns(of: select.projection, returns)
  }

  /// The name-resolution scope of `select` — its FROM relation and each joined
  /// relation resolved to schema and laid end to end in one combined ordinal
  /// space, the same layout compilation resolves a projection against. A
  /// FROM-less `SELECT <expr-list>` projects over no relation, so its scope is
  /// empty. It reads only schemas, never a cursor.
  borrowing func scope(of select: Select, _ ctes: CTEs,
                       visited: Set<String> = [],
                       returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) -> Scope {
    guard let relation = select.from else { return Scope([]) }
    var relations =
        [(relation, try schema(of: relation, ctes, visited: visited,
                               returns: returns))]
    for join in select.joins {
      let joined = try schema(of: join.relation, ctes, visited: visited,
                              returns: returns)
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
                           returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) {
    switch query {
    case let .select(select):
      try typecheck(select, ctes, visited: visited, returns: returns)
    case let .union(left, select, _):
      try typecheck(left, ctes, visited: visited, returns: returns)
      try typecheck(select, ctes, visited: visited, returns: returns)
    }
  }

  /// Type-checks a single arm — its projection expressions, `WHERE`, and
  /// `HAVING` — against its own scope, discarding the types and throwing on the
  /// first operand or function fault. `check(_:_:)` walks a predicate's operand
  /// expressions.
  private borrowing func typecheck(_ select: Select, _ ctes: CTEs,
                                   visited: Set<String>,
                                   returns: Dictionary<String, ValueType>)
      throws(SQLError) {
    let scope = try scope(of: select, ctes, visited: visited, returns: returns)
    if case let .expressions(items) = select.projection {
      for item in items { _ = try scope.type(of: item.expression, returns) }
    }
    if let predicate = select.predicate { try scope.check(predicate, returns) }
    if let having = select.having { try scope.check(having, returns) }
  }

  /// The name-resolution schema of `relation`, resolved against this catalog
  /// and the in-scope `ctes` — a CTE first, then a reserved
  /// `definition_schema.` store relation, then a view, then a base table, the
  /// same precedence `compile` resolves a relation by. It reads only schemas,
  /// never a cursor, so it never executes. `visited` names the views already
  /// being resolved down this chain, breaking a cyclic view (`A` over `B` over
  /// `A`) that would otherwise re-enter here. `returns` rides through so a view
  /// body projecting a scalar call types it from the routine's declared return
  /// type, not the `.integer` default.
  borrowing func schema(of relation: Relation, _ ctes: CTEs,
                        visited: Set<String> = [],
                        returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) -> Schema {
    let name = relation.name
    if let cte = ctes[name.lowercased()] {
      return cte.schema()
    }
    // A reserved store relation types through its SCHEMA-ONLY build (header +
    // types, no rows), so resolving a view over `definition_schema.tables`/
    // `.columns` reads only the schema and never triggers the row builder — the
    // intrinsic schema path that dissolved the threaded seed.
    if let relation = Definition(name) {
      return schematise(relation).schema()
    }
    if let view = resolve(view: name) {
      // A view's declared schema types every column `.integer`, since a view
      // stores no types; resolve the view body's own types so a `SELECT *` over
      // the view reports each column's true type. Resolving runs the
      // RESOLVE-only worker over the view's OWN `definition_schema.` overlay,
      // built SCHEMA-ONLY (`schemas`) so a view over a reserved relation
      // resolves its types without a row build — never the public `columns(of:
      // query)`, which would re-run `compile`. The names stay the view's
      // DECLARED ones; only the types come from the resolved body.
      let base = view.schema()
      // A cyclic view cannot resolve its body's types: resolving it would
      // re-enter this view forever, so break the cycle and fall back to the
      // declared schema (every type the `.integer` default). `try?` cannot
      // catch this — the recursion overflows the stack rather than throwing.
      guard !visited.contains(name.lowercased()) else { return base }
      // `compile` checks the body's relations, arities, and call arguments but
      // not that a called routine EXISTS (no routine set; the name binds at
      // execute), and the outer query's `calls` never reach into a view body.
      // So validate the body's whole call inventory here: a view calling an
      // unregistered function in a clause the first-arm walk misses — a
      // `WHERE`/`HAVING`, a later `UNION` arm — faults as a run of it would.
      for call in view.query.calls where returns[call.lowercased()] == nil {
        throw .function(call)
      }
      // Operand types too, across every arm and `HAVING` — the first-arm
      // resolve below would miss a later arm's `Name + 1` or a `HAVING
      // SUM(Name)`, but a `SELECT * FROM v` run over the view would fault.
      let overlay = schemas([:], for: view.query)
      let inner = visited.union([name.lowercased()])
      try typecheck(view.query, overlay, visited: inner, returns: returns)
      // Type off the body's first arm (the ISO rule for a UNION). Arity — the
      // body's width against the declared columns — is `compile`'s job (the
      // public entry and the introspection builder run it), so on a shortfall
      // fall back to the declared schema rather than re-checking it here.
      let resolved =
          try columns(of: view.query.first, overlay, visited: inner,
                      returns: returns)
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
  /// — `returns` maps a scalar routine's name to its declared return type.
  internal func columns(of projection: Projection,
                        _ returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) -> Array<OutputColumn> {
    return switch projection {
    case .all:
      outputs()
    case let .columns(references):
      try references.map { column throws(SQLError) in try output(of: column) }
    case let .expressions(items):
      try items.indices.map { index throws(SQLError) in
        try output(items[index], at: index, returns)
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

  /// The output column a projected `item` at 0-based `index` yields: its alias,
  /// else a bare column's name, else a positional `column N` (1-based). A bare
  /// column carries its source type and a literal its own; a scalar call its
  /// routine's declared return type (`returns`); every other expression
  /// `.integer`.
  internal func output(_ item: Projected, at index: Int,
                       _ returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) -> OutputColumn {
    let name = if let alias = item.alias {
      alias
    } else if case let .column(column) = item.expression {
      column.name
    } else {
      "column \(index + 1)"
    }
    return try OutputColumn(name: name,
                            type: type(of: item.expression, returns))
  }
}
