// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The query engine — the compiler, optimiser, and executor for a `SELECT`.
///
/// `Engine` runs a `SELECT` entirely against the adapter protocols, with no
/// knowledge of any data source. It resolves the relation(s) through a borrowed
/// `Catalog`, *compiles* a logical operator tree, *optimises* it into a physical
/// one, and *executes* that. Each phase borrows the catalog: `compile`
/// re-resolves each relation by name to a transient `~Escapable` table to read
/// its schema (width, ordinals, the set of ordinals the query references) and
/// emits a name-holding `Plan`; `optimise` re-resolves to read sort-key
/// seekability and rewrites scans into seeks and the product into an
/// index-nested-loop join; `execute` re-resolves to open cursors and
/// materialise. A single relation compiles to `Project(Sort(Select(Scan)))`; a
/// chain of joins compiles to a left-deep tree of `Product`s, each level's `ON`
/// equality a `Select` over its product, with the `WHERE` wrapping the whole
/// chain. Absent layers are omitted. Executing the plan yields the result
/// records' typed values; formatting them is a client's job.
public enum Engine {
  // MARK: - WITH

  /// Whether `cte` actually references itself — the test the fixpoint routing
  /// turns on, distinct from the syntactic `recursive` flag a `WITH RECURSIVE`
  /// stamps on every member.
  ///
  /// The parser marks each member of a `WITH RECURSIVE` list recursive whether
  /// or not it names itself, but only a self-referential CTE has a recursive arm
  /// to iterate; running a non-self-referential one through the fixpoint would
  /// re-evaluate an arm that never reads the CTE, repeating its rows without end
  /// (a `UNION ALL`) or needlessly (a `UNION`). A CTE is recursive in truth when
  /// its recursive arm — the right member of the top-level `UNION`, the one the
  /// fixpoint compiles with the CTE bound — names `cte.name` in a `FROM`/`JOIN`.
  /// The anchor is the base case, compiled with the name NOT in scope, so a
  /// `FROM <name>` there reads a base relation of that name, not the CTE.
  /// Scanning the anchor too would misroute `WITH RECURSIVE Parent(Id) AS
  /// (SELECT Id FROM Parent UNION ALL SELECT Id FROM Extra)` — whose anchor
  /// merely reads the same-named base — into the fixpoint.
  internal static func recursive(_ cte: CTE) -> Bool {
    guard case let .union(_, arm, _) = cte.query else { return false }
    return references(arm, cte.name.lowercased())
  }

  /// Whether `query` names the relation `name` (case-folded) in ANY member's
  /// `FROM`/`JOIN` — walking the left-associative `UNION` chain and each arm.
  /// Used to spot a self-reference lurking in a recursive body's anchor;
  /// `recursive` itself inspects only the recursive arm.
  internal static func references(_ query: Query, _ name: String) -> Bool {
    switch query {
    case let .select(select):
      references(select, name)
    case let .union(left, select, _):
      references(left, name) || references(select, name)
    }
  }

  /// Whether `select` names the relation `name` (case-folded) in its `FROM` or
  /// any `JOIN`.
  private static func references(_ select: Select, _ name: String) -> Bool {
    if select.from?.name.lowercased() == name { return true }
    return select.joins.contains { $0.relation.name.lowercased() == name }
  }

  /// The greatest number of fixpoint iterations a recursive CTE may take before
  /// the engine concludes it does not terminate and throws
  /// `SQLError.recursion`.
  internal static let kRecursionCap = 10_000
}

// MARK: - Execution

extension Catalog where Self: ~Escapable {
  /// Runs `query` against this catalog, returning the projected, filtered, and
  /// ordered rows as typed values.
  ///
  /// A bare `SELECT` runs as before; a `UNION` runs each arm through the same
  /// compile/optimise/execute with the SAME `bindings` and `routines`, then
  /// concatenates the rows in source order — `UNION ALL` keeps every row, a
  /// bare `UNION` removes whole-row duplicates (first occurrence kept). The
  /// plan is binary and mirrors the left-associative chain, so each
  /// `UNION`/`UNION ALL` honours its own flag — `(A UNION B) UNION ALL C` dedups
  /// `A ∪ B` before appending `C`. The result columns are the first arm's
  /// projection (the ISO rule); each arm keeps its own `ORDER BY`, applied
  /// before the union.
  ///
  /// - Throws: `SQLError.relation` if the catalog resolves no such relation,
  ///   `SQLError.column` if a referenced column is absent, `SQLError.ambiguous`
  ///   if an unqualified name is resolved by more than one relation of a chain,
  ///   `SQLError.arity` if a `UNION`'s arms project differing column counts.
  public borrowing func run(_ query: Query, _ routines: Routines = [:],
                            bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    // Seed the standard prelude UNDER the caller's routines so a public call
    // always resolves the built-ins (BITAND) even when it supplies unrelated
    // UDFs; an explicitly registered function of the same name still shadows it
    // (the merge keeps the caller's binding on a clash).
    try run(query, [:], Routines.standard.merging(routines), bindings)
  }

  /// Runs `query` against this catalog with the common table expressions `ctes`
  /// in scope (empty for a query with no `WITH`), the resolution phases
  /// consulting `ctes` before the base catalog.
  internal borrowing func run(_ query: Query, _ ctes: CTEs,
                              _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Array<Array<Value>> {
    // Extend the relations with any `definition_schema.` store relation the
    // query names, resolved lazily — the overlay after the
    // CTEs, before the base catalog. Every phase reads the extended map, so a
    // reserved store relation resolves, plans, and materialises exactly as a
    // common table expression does; a portable `information_schema.` view over
    // the store resolves through the ordinary view machinery. The routines ride
    // in so a store `data_type` row types a view's scalar-call column
    // (`GUID(...)`) by its declared return type.
    let ctes = augment(ctes, for: query, rows: true, routines: routines)
    let logical = try compile(query, ctes).pushdown()
    let plan = try optimise(logical, ctes, bindings)
    return try execute(plan, self, ctes, routines, bindings).map(\.values)
  }

  /// Runs a `Statement` against this catalog, returning its result rows.
  ///
  /// A `select` runs its query directly; a `with` materialises its common table
  /// expressions, in source order, into the `CTEs` the trailing query resolves
  /// against (see `with`). A `create` defines a view rather than producing
  /// rows, so it is not runnable and faults with `SQLError.statement`.
  public borrowing func run(_ statement: Statement, _ routines: Routines = [:],
                            bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    // Seed the standard prelude under the caller's routines (see the query
    // overload) so BITAND resolves regardless of what the caller supplies.
    let routines = Routines.standard.merging(routines)
    return switch statement {
    case let .select(query):
      try run(query, [:], routines, bindings)
    case let .with(ctes, query):
      try with(ctes, query, routines, bindings)
    case .create:
      throw .statement("CREATE VIEW defines a view rather than producing rows")
    }
  }

  // MARK: - WITH

  /// Materialises the common table expressions `ctes`, in source order, into
  /// the `CTEs` map and runs the trailing `query` against this catalog with that
  /// map in scope.
  ///
  /// Each CTE materialises against the base catalog plus every EARLIER CTE,
  /// so a CTE may name one defined before it (chained CTEs); a CTE name shadows
  /// a base relation of the same name (the resolver consults the map first). A
  /// recursive CTE — one that names itself in its own query — iterates a
  /// fixpoint (see `fixpoint`); every other CTE, including one a `WITH
  /// RECURSIVE` marks recursive but which does not reference itself, runs its
  /// query once and captures its rows. The fully materialised relations then
  /// resolve the trailing query, run through the same `routines` and
  /// `bindings`.
  ///
  /// Each CTE's body must project exactly the arity its column list declares —
  /// the resolver advertises `cte.columns.count` columns, so a body of a
  /// different width would index out of bounds when a later query reads it. The
  /// body's width is known once it compiles (a `SELECT *` resolves its extent
  /// against the relations in scope), so its compiled `Plan.width` is checked
  /// against the declared count BEFORE the CTE materialises — regardless of how
  /// many rows the body yields. A body filtered to zero rows still faults with
  /// `SQLError.columns`, where a per-row check would pass it through vacuously.
  internal borrowing func with(_ ctes: Array<CTE>, _ query: Query,
                               _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Array<Array<Value>> {
    var relations = CTEs()
    for cte in ctes {
      // A query name repeated in the list (case-insensitively) would silently
      // shadow the earlier binding in `relations`, so reject it rather than
      // overwrite — a typo in a multi-CTE query must not change the result.
      guard relations[cte.name.lowercased()] == nil else {
        throw .redefinition(cte.name)
      }
      // A `WITH RECURSIVE` member's recursive reference must be its FINAL UNION
      // arm — the engine's model is anchor members then ONE recursive arm. A
      // reference to the CTE's own name in an EARLIER arm resolves against the
      // base scope (the CTE is not in scope outside the recursive arm), so a
      // same-named base or view is a valid seed; but with no such base/view the
      // reference can only be a misplaced recursive arm — recursion before the
      // final arm, or a second recursive arm — a shape the engine does not
      // support. Reject it rather than silently read a same-named base or fail
      // obscurely as an unresolved relation. This covers BOTH routings below (a
      // non-recursive final arm still reaches the run-once branch).
      if cte.recursive, case let .union(anchor, _, _) = cte.query,
          Engine.references(anchor, cte.name.lowercased()),
          case nil = table(named: cte.name),
          case nil = view(named: cte.name) {
        throw .unsupported(
            "recursive WITH references the CTE outside its final UNION arm")
      }
      // A CTE that names itself iterates a fixpoint; every other one — a
      // non-recursive CTE, or one a `WITH RECURSIVE` marks recursive but which
      // does not reference itself — runs its query once. Each resolves against
      // the base catalog plus the CTEs done so far. A recursive CTE checks the
      // arity of both its arms internally (see `fixpoint`); a non-recursive one
      // checks its body's compiled width here.
      let rows: Array<Array<Value>>
      if cte.recursive && Engine.recursive(cte) {
        rows = try fixpoint(cte, relations, routines, bindings)
      } else {
        // The width check resolves the body's relations, so it reads the same
        // `definition_schema.` overlay the body's own run does — a CTE body may
        // select from a reserved store relation.
        let scope = augment(relations, for: cte.query, rows: true,
                            routines: routines)
        let width = try compile(cte.query, scope).width
        guard width == cte.columns.count else {
          throw .columns(expected: cte.columns.count, got: width)
        }
        rows = try run(cte.query, relations, routines, bindings)
      }
      relations[cte.name.lowercased()] =
          Materialised(columns: cte.columns, rows: rows)
    }
    return try run(query, relations, routines, bindings)
  }

  /// Evaluates a recursive `cte` to a fixpoint over this catalog with the
  /// `ctes` in scope, returning every produced row.
  ///
  /// A recursive CTE's query is a `UNION` of an ANCHOR (its left arm, itself a
  /// query) and a RECURSIVE arm (its right `SELECT`, which names the CTE). The
  /// anchor evaluates once — with the CTE name NOT yet bound — to seed `result`
  /// and the `working` set. Each iteration then binds the CTE name to ONLY the
  /// `working` rows (the SQL semantics — the recursive arm sees just the
  /// previous step's output) and runs the recursive arm; the rows it produces
  /// extend `result` and become the next `working` set. A `UNION ALL` keeps
  /// every produced row; a `UNION` keeps only rows not seen before (a whole-row
  /// `seen` set), and a step that adds nothing new is the fixpoint. The
  /// `kRecursionCap` guards a non-terminating CTE with `SQLError.recursion`.
  ///
  /// A non-`UNION` recursive query has no recursive arm to iterate, so it runs
  /// once like a non-recursive CTE — its compiled width validated the same way
  /// before it materialises, so a non-`UNION` body binding rows of a width other
  /// than the column list (e.g. a base relation of the CTE's own name) faults
  /// with `SQLError.columns` rather than trapping on a later read.
  ///
  /// The anchor and the recursive arm are each validated against
  /// `cte.columns.count` by their compiled `Plan.width` BEFORE any rows bind
  /// under the declared columns: the loop binds `working` as a `Materialised`
  /// of `cte.columns`, so an arm narrower or wider than the column list — a
  /// two-column anchor under a three-column list, or a recursive arm of a width
  /// differing from the anchor's — would trap in `Materialised.record` when the
  /// next iteration reads it. Checking the compiled width faults with
  /// `SQLError.columns` regardless of how many rows an arm yields, so even a
  /// `SELECT *` arm filtered to zero rows is caught. The anchor compiles with
  /// the CTE name NOT in scope (it does not reference itself); the recursive
  /// arm compiles with the name bound to `cte.columns`, the schema it reads.
  internal borrowing func fixpoint(_ cte: CTE, _ ctes: CTEs,
                                   _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Array<Array<Value>> {
    // Extend the scope with any `definition_schema.` store relation the CTE's
    // body names, so the fixpoint's width-check compiles resolve a reserved
    // relation as the body's own run does. The routines ride in: this store
    // entry is cached in `ctes` and reused by every anchor/recursive execution
    // (a later `augment` will not replace a bound name), so a view column using
    // even a standard routine (`BITAND(...)`) types the same inside the CTE as
    // the identical SELECT does outside it.
    let ctes = augment(ctes, for: cte.query, rows: true, routines: routines)
    guard case let .union(anchor, recursive, all) = cte.query else {
      // A non-`UNION` recursive query runs once, but still binds under
      // `cte.columns`, so validate its compiled width here too — the check the
      // anchor and arm get. A body naming a base relation of the CTE's own name
      // (`WITH RECURSIVE Parent(x,y,z) AS (SELECT * FROM Parent)`) would else
      // bind narrow base rows under the wider list and trap on a later read.
      let width = try compile(cte.query, ctes).width
      guard width == cte.columns.count else {
        throw .columns(expected: cte.columns.count, got: width)
      }
      return try run(cte.query, ctes, routines, bindings)
    }

    // A misplaced recursive reference in the anchor (a same-named base/view is
    // absent) was already rejected in `with`, before routing here, so the anchor
    // is a genuine base case by this point.

    // Validate the anchor's compiled width against the declared columns BEFORE
    // it seeds the working set: the loop binds `working` under `cte.columns` as
    // a `Materialised`, so an anchor narrower than the column list — a
    // two-column `Parent` under `t(a, b, c)` — would trap when the recursive
    // arm reads the absent ordinal, rather than surfacing `SQLError.columns`.
    // The anchor is the base case and does not reference the CTE, so its width
    // resolves with the name not yet in scope.
    let width = try compile(anchor, ctes).width
    guard width == cte.columns.count else {
      throw .columns(expected: cte.columns.count, got: width)
    }

    // The recursive arm compiles with the CTE name bound to `cte.columns` — the
    // schema every iteration reads it under — so its width resolves too (a
    // `SELECT *` arm spans that schema). Checking it here catches a mismatch
    // even when the arm is filtered to zero rows in every iteration.
    var probe = ctes
    probe[cte.name.lowercased()] =
        Materialised(columns: cte.columns, rows: [])
    let arm = try compile(.select(recursive), probe).width
    guard arm == cte.columns.count else {
      throw .columns(expected: cte.columns.count, got: arm)
    }

    // The anchor seeds the result and the working set, the CTE name not yet in
    // scope (the anchor is the base case, which does not reference itself). A
    // bare `UNION` dedups the seed exactly as it dedups an iteration's rows —
    // duplicate anchor rows collapse to their first occurrence — while `UNION
    // ALL` keeps every anchor row.
    let anchored = try run(anchor, ctes, routines, bindings)
    var seen = Seen()
    var result = all ? anchored
                     : anchored.filter { seen.insert($0) }
    var working = result

    var iterations = 0
    while !working.isEmpty {
      iterations += 1
      guard iterations <= Engine.kRecursionCap else {
        throw .recursion(cte.name)
      }

      // Bind the CTE name to ONLY the previous step's output and run the
      // recursive arm against the base catalog plus the earlier CTEs.
      var scope = ctes
      scope[cte.name.lowercased()] =
          Materialised(columns: cte.columns, rows: working)
      let produced =
          try run(.select(recursive), scope, routines, bindings)

      var next = Array<Array<Value>>()
      for row in produced where all || seen.insert(row) {
        next.append(row)
      }
      result += next
      working = next
    }
    return result
  }
}

// MARK: - Compilation

extension Engine {
  /// Compiles a scalar (FROM-less) `SELECT <expr-list>` into `Project(single)`
  /// — the projection evaluated against the one empty row the `single` leaf
  /// yields.
  ///
  /// The projection resolves against an empty schema (no columns), so only
  /// literals, scalar calls, and arithmetic over them lower; a `SELECT *` has no
  /// relation to expand and a bare-column reference no column to bind, each
  /// faulting (`SQLError.column` for a column, `SQLError.unsupported` for `*`).
  /// The terms hold no slots, so the `single` row's empty record carries every
  /// value the projection needs.
  internal static func scalar(_ projection: Projection)
      throws(SQLError) -> Plan {
    guard case .all = projection else {
      let schema = Schema(width: 0, extent: 0, names: [], types: [],
                          virtuals: [])
      let terms = try schema.terms(projection, in: Relation(name: ""))
      return .project(terms, .single)
    }
    // `SELECT *` names every column of the relations in scope; a FROM-less query
    // has none, so there is nothing to expand.
    throw .unsupported("SELECT * requires a FROM clause")
  }

  /// A relation resolved for compilation: its name-resolution `schema` and a
  /// `leaf` factory that, given the ordinals the query references on its side,
  /// builds the leaf `Plan` — a `scan` for a base table, a `derived` over the
  /// view's compiled sub-plan for a view.
  internal struct Resolved {
    let schema: Schema
    let leaf: (Array<Int>) -> Plan
  }

  /// The sorted, deduplicated ordinals a query references: the union of the
  /// ordinals its `projection` terms read, the columns its `filter` reads, and
  /// EVERY column its `order` keys read. The projection terms hold ordinals at
  /// this stage; a scalar call's arguments contribute their read ordinals too.
  internal static func referenced(
      _ projection: Array<Term>, _ filter: Filter?,
      _ order: Array<(column: Int, ascending: Bool)>)
      -> Array<Int> {
    var ordinals = Set<Int>()
    for term in projection {
      term.references(into: &ordinals)
    }
    filter?.references(into: &ordinals)
    for key in order { ordinals.insert(key.column) }
    return ordinals.sorted()
  }

  /// The inverse map `ordinal → slot` of a referenced-ordinal list: slot `i` is
  /// `ordinals[i]`, so the map sends `ordinals[i]` back to `i`.
  internal static func invert(_ ordinals: Array<Int>)
      -> Dictionary<Int, Int> {
    var slot = Dictionary<Int, Int>(minimumCapacity: ordinals.count)
    for index in ordinals.indices {
      slot[ordinals[index]] = index
    }
    return slot
  }

  /// Wraps `source` in the `Project(Limit(Sort(Select(_))))` operators, omitting
  /// each layer when its clause is absent. The `projection`, `filter`, and
  /// `order` keys are in slot space; an empty `order` omits the sort.
  ///
  /// The row `limit` sits BELOW the projection — after `WHERE` and `ORDER BY`,
  /// but before the select list is evaluated. A row outside the requested page
  /// is dropped by the limit before its projection runs, so a projection that
  /// could throw (`SELECT 1 / 0 … FETCH FIRST 0 ROWS ONLY`) never evaluates for
  /// a discarded row and the query returns the documented empty page.
  internal static func shape(
      _ source: Plan, _ projection: Array<Term>, _ filter: Filter?,
      _ order: Array<(slot: Int, ascending: Bool)>,
      _ limit: Limit?) -> Plan {
    var plan = source
    if let filter {
      plan = .select(filter, plan)
    }
    if !order.isEmpty {
      plan = .sort(keys: order, plan)
    }
    return .project(projection, plan.capped(limit: limit))
  }

  // MARK: - Aggregation

  /// Whether `select` aggregates — it has a `GROUP BY`, a `HAVING`, or an
  /// aggregate function anywhere in its projection.
  ///
  /// A query with any of these compiles through the grouped path; one with none
  /// keeps the ordinary `Project(Limit(Sort(Select(_))))` shape unchanged. A
  /// `HAVING` alone (no `GROUP BY`, no aggregate) still aggregates — it filters
  /// the single whole-result group.
  internal static func aggregates(_ select: Select) -> Bool {
    if !select.grouping.isEmpty || select.having != nil { return true }
    switch select.projection {
    case .all, .columns:
      return false
    case let .expressions(items):
      return items.contains { aggregated($0.expression) }
    }
  }

  /// Whether `expression` contains an aggregate call anywhere within it.
  private static func aggregated(_ expression: Expression) -> Bool {
    switch expression {
    case .column, .literal:
      false
    case .aggregate:
      true
    case let .call(_, arguments):
      arguments.contains { aggregated($0) }
    case let .binary(_, lhs, rhs):
      aggregated(lhs) || aggregated(rhs)
    }
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
  /// that grouped slot space through a `Grouping`, which also enforces the
  /// standard rule that every non-aggregated projection/`ORDER BY` column appear
  /// in the `GROUP BY`.
  internal borrowing func group(_ select: Select, _ relation: Relation,
                                _ from: Engine.Resolved, _ ctes: CTEs,
                                _ visited: Set<String>)
      throws(SQLError) -> Plan {
    // Resolve every joined relation and lay the FROM relation and each joined
    // one end to end in one combined ordinal space (as the non-aggregate join
    // path does), so the WHERE, keys, and aggregate arguments resolve uniformly.
    var joined = Array<Engine.Resolved>()
    joined.reserveCapacity(select.joins.count)
    for join in select.joins {
      try joined.append(resolve(join.relation, ctes, visited))
    }
    var relations = [(relation, from.schema)]
    for index in select.joins.indices {
      relations.append((select.joins[index].relation, joined[index].schema))
    }
    let scope = Scope(relations)

    // Each join's ON equality lowers to a `match` at its own chain level,
    // resolved against only the prefix already in scope (as the non-aggregate
    // path does).
    var matches = Array<Filter>()
    matches.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      let prefix = Scope(Array(relations[0 ... index + 1]))
      let join = select.joins[index]
      try matches.append(prefix.match(join.left, join.right))
    }
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause)
    }

    // The `GROUP BY` keys and the aggregate arguments lower to combined
    // base-ordinal terms; the aggregates are collected from the projection and
    // the `HAVING` (deduplicated so the same aggregate computes once).
    let keys = try select.grouping.map { column throws(SQLError) -> Term in
      try .slot(scope.ordinal(of: column))
    }
    var expressions = Array<Expression>()
    for expression in Engine.projected(select.projection) {
      Engine.collect(expression, into: &expressions)
    }
    if let having = select.having {
      Engine.collect(having, into: &expressions)
    }
    var aggregations = Array<Aggregation>()
    for expression in expressions {
      try aggregations.append(Engine.lower(expression, scope))
    }

    // The source materialises exactly the ordinals the WHERE, the keys, and the
    // aggregate arguments read — never the projection/HAVING/ORDER, which read
    // the GROUPED record. Pack them per relation in chain order, building the
    // combined-ordinal → slot map and each relation's leaf ordinals.
    var references = Set<Int>()
    for match in matches { match.references(into: &references) }
    predicate?.references(into: &references)
    for key in keys { key.references(into: &references) }
    for aggregation in aggregations { aggregation.references(into: &references) }
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
      .select(matches[index].remapped(through: slot),
              .product(chain, joined[index].leaf(locals[index + 1])))
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

    // Lower the projection, HAVING, and ORDER BY against the grouped slot space,
    // enforcing the projection rule (every non-aggregated column must be a
    // GROUP BY key).
    var grouping = try Grouping(scope, select.grouping, expressions)
    let projection = try grouping.terms(select.projection)
    let having: Filter? = if let clause = select.having {
      try grouping.lower(clause)
    } else {
      nil
    }
    let order = if let clause = select.order {
      try grouping.order(clause)
    } else {
      Array<(slot: Int, ascending: Bool)>()
    }

    var plan = node
    if let having {
      plan = .select(having, plan)
    }
    if !order.isEmpty {
      plan = .sort(keys: order, plan)
    }
    return .project(projection, plan.capped(limit: select.limit))
  }
}

extension Engine {
  /// The projected expressions of `projection` — an `expressions` list yields
  /// each item's expression; a `*` or bare-column list yields none (no aggregate
  /// can hide in them). An aggregate query's projection is always the
  /// `expressions` case (an aggregate call makes it one).
  internal static func projected(_ projection: Projection)
      -> Array<Expression> {
    switch projection {
    case .all, .columns:
      []
    case let .expressions(items):
      items.map(\.expression)
    }
  }

  /// Collects the distinct aggregate expressions within `expression` into
  /// `expressions`, in first-appearance order — the same aggregate written twice
  /// computes once.
  internal static func collect(_ expression: Expression,
                               into expressions: inout Array<Expression>) {
    switch expression {
    case .column, .literal:
      break
    case .aggregate:
      if !expressions.contains(expression) {
        expressions.append(expression)
      }
    case let .call(_, arguments):
      for argument in arguments { collect(argument, into: &expressions) }
    case let .binary(_, lhs, rhs):
      collect(lhs, into: &expressions)
      collect(rhs, into: &expressions)
    }
  }

  /// Collects the distinct aggregates within a `predicate` into `expressions`.
  internal static func collect(_ predicate: Predicate,
                               into expressions: inout Array<Expression>) {
    switch predicate {
    case let .comparison(left, _, right):
      collect(left, into: &expressions)
      collect(right, into: &expressions)
    case let .bound(left, _, _):
      collect(left, into: &expressions)
    case let .null(expression, _):
      collect(expression, into: &expressions)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      collect(lhs, into: &expressions)
      collect(rhs, into: &expressions)
    case let .not(operand):
      collect(operand, into: &expressions)
    }
  }

  /// Lowers an AST `.aggregate` expression to an `Aggregation`, its argument (if
  /// any) resolved to a combined base-ordinal term through `scope`.
  ///
  /// `COUNT(*)` has no argument (it counts rows); every other aggregate lowers
  /// its single operand expression to a term. `expression` is always an
  /// `.aggregate` — `collect` gathers only those.
  internal static func lower(_ expression: Expression, _ scope: Scope)
      throws(SQLError) -> Aggregation {
    guard case let .aggregate(function, operand) = expression else {
      throw .unsupported("expected an aggregate")
    }
    let argument: Term? = switch operand {
    case .star:
      nil
    case let .expression(expression):
      try scope.term(expression)
    }
    return Aggregation(function: function, argument: argument)
  }

}

// MARK: - Optimisation

extension Catalog where Self: ~Escapable {
  /// Rewrites the logical `plan` into a physical one, re-resolving relations by
  /// name through this catalog for their seekability and a bound key through
  /// `bindings` so it seeks like a literal.
  ///
  /// Two pattern rewrites fire, the rest of the tree recursing unchanged:
  ///
  /// (a) **Seek.** A `Select` over a full `Scan` whose predicate (or a
  ///     conjunct of it) is a sort-key equality or range on a seekable column
  ///     becomes a seeked `Scan`, the remaining predicate kept as a residual
  ///     `Select`.
  ///
  /// (b) **Index-nested-loop join.** A `Select` over a `Product` whose
  ///     predicate carries a `match` conjunct relating an outer-side ordinal to
  ///     an inner-side ordinal — the inner side a bare `Scan` — becomes a
  ///     `Join` that seeks the inner per outer record, the remaining conjuncts
  ///     kept as a residual `Select`. If the inner side is not a bare `Scan`,
  ///     the product stays (a plain nested loop).
  internal borrowing func optimise(_ plan: Plan, _ bindings: Bindings)
      throws(SQLError) -> Plan {
    try optimise(plan, [:], bindings)
  }

  /// Rewrites `plan` into a physical one with the in-scope `ctes` (consulted
  /// before the base catalog for seekability) and `bindings`.
  internal borrowing func optimise(_ plan: Plan, _ ctes: CTEs,
                                   _ bindings: Bindings)
      throws(SQLError) -> Plan {
    switch plan {
    case .single:
      plan
    case .scan:
      plan
    case let .derived(name, plan, ordinals, seek):
      // Optimise the view's sub-plan with the bindings so a bound predicate
      // inside the view seeks; the derived leaf itself carries no sort key, so
      // the outer query still scans its result as is. The sub-plan resolves
      // OUTSIDE the statement's CTE scope — never a caller's `WITH` — so a view
      // means what it was registered to mean; its scope is the
      // `definition_schema.` overlay its OWN query names (the same one it
      // compiled under), so a view body's store scan re-resolves.
      try .derived(name: name, plan: optimise(plan, overlay(name), bindings),
                   ordinals: ordinals, seek: seek)
    case let .select(filter, .scan(name, ordinals, nil)):
      try seek(filter, name, ordinals, ctes, bindings)
    case let .select(filter, .product(left, right)):
      try nest(filter, left, right, ctes, bindings)
    case let .select(filter, source):
      try .select(filter, optimise(source, ctes, bindings))
    case let .project(ordinals, source):
      try .project(ordinals, optimise(source, ctes, bindings))
    case let .sort(keys, source):
      try .sort(keys: keys, optimise(source, ctes, bindings))
    case let .product(left, right):
      try .product(optimise(left, ctes, bindings),
                   optimise(right, ctes, bindings))
    case .join:
      plan
    case let .union(left, right, all):
      // Optimise each side with the same bindings so a bound predicate inside an
      // arm seeks; the union itself merely concatenates and deduplicates,
      // preserving this node's own `all`.
      try .union(optimise(left, ctes, bindings),
                 optimise(right, ctes, bindings), all: all)
    case let .aggregate(keys, aggregates, source):
      // An aggregate reshapes its source and has no seek or join of its own;
      // optimise its source (the WHERE/join chain below it seeks and nests as
      // usual) and rewrap. The `HAVING`/projection sit above it as `select`s the
      // recursion reaches through here, but their grouped-space slots never seek
      // a base relation.
      try .aggregate(keys: keys, aggregates: aggregates,
                     optimise(source, ctes, bindings))
    case let .limit(count, offset, source):
      // A `limit` is a transparent wrapper — optimise its source and re-cap;
      // the cap itself has no seek or join to rewrite.
      try .limit(count: count, offset: offset,
                 optimise(source, ctes, bindings))
    }
  }

  // MARK: - Physical seek

  /// Rewrites `Select(filter, Scan(name, ordinals, nil))` into a seeked scan
  /// when a sort-key conjunct qualifies, else leaves the full scan under the
  /// filter. The relation re-resolves through this catalog for its boundaries.
  ///
  /// A standalone qualifying comparison seeks its run and admits all of it (no
  /// residual). An `AND` with one qualifying conjunct seeks that run and keeps
  /// the other as the residual `Select` — but ONLY when that residual is safe,
  /// since seeking narrows the scan and a throwing residual would then raise
  /// over just the sought run, suppressing a throw the un-seeked scan owes on a
  /// skipped row. Everything else scans under the whole filter. The `filter` is
  /// in slot space, so a comparison's slot maps back to its table ordinal
  /// through the scan's `ordinals` before reading a boundary.
  private borrowing func seek(_ filter: Filter, _ name: String,
                              _ ordinals: Array<Int>, _ ctes: CTEs,
                              _ bindings: Bindings)
      throws(SQLError) -> Plan {
    // A materialised CTE relation stores no sort key, so it is never seekable —
    // leave the scan under the whole filter.
    guard ctes[name.lowercased()] == nil else {
      return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
    }
    guard let table = table(named: name) else { throw .relation(name) }
    let count = table.cursor().count

    if let range = Engine.boundaries(filter, ordinals, table, count, bindings) {
      return .scan(name: name, ordinals: ordinals, seek: range)
    }

    // Seek by one conjunct only when the OTHER — the residual, then run over
    // just the sought run — is safe. Seeking narrows the scan, so a residual
    // that can throw would raise only on the rows the seek kept, suppressing a
    // throw the un-seeked scan owes on a skipped row: `(1 / x) = 0 AND id < 0`
    // over an id-sorted table (an empty id < 0 run) must still raise the
    // division rather than seek past it, as must a grouped `… AND (… AND id <
    // 0)` the left fold rebuilds so a seekable `id < 0` is the top-level RHS.
    if case let .and(lhs, rhs) = filter {
      if rhs.safe,
          let range =
              Engine.boundaries(lhs, ordinals, table, count, bindings) {
        return .select(rhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
      if lhs.safe,
          let range =
              Engine.boundaries(rhs, ordinals, table, count, bindings) {
        return .select(lhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
    }

    return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
  }
}

extension Engine {
  /// The seekable `(slot, op, integer)` of `filter`: a `compare` against an
  /// integer literal, or a `bound` whose parameter resolves to an integer in
  /// `bindings`. A string operand, an unbound or non-integer parameter, or a
  /// non-comparison does not qualify, and the relation scans.
  private static func comparison(_ filter: Filter, _ bindings: Bindings)
      -> (Int, Comparison, Int)? {
    switch filter {
    case let .compare(.slot(slot), op, .constant(.integer(value))):
      (slot, op, value)
    case let .bound(.slot(slot), op, parameter):
      if case let .integer(value)? = bindings[parameter] {
        (slot, op, value)
      } else {
        nil
      }
    default:
      nil
    }
  }

  /// The boundaries `[lower, upper)` to seek for a sort-key comparison, or `nil`
  /// if `filter` does not qualify for the seek path.
  ///
  /// It qualifies when `filter` is a sort-key equality or range whose operand
  /// is an integer — a literal, or a bound parameter resolved from `bindings`
  /// so a correlated child seeks on its parent key — and `table.bound` reports
  /// the column seekable (a non-`nil` boundary). A range additionally requires
  /// the column `ordered`: a `bound` boundary partitions a range correctly only
  /// when the seeked column is monotonic, so a range on a seekable, unordered
  /// column (a decoded coded-index key) does not qualify and scans, while its
  /// equality still seeks. The comparison's slot maps back to its table ordinal
  /// through `ordinals` (slot `i` is `ordinals[i]`) for the `bound` query. A
  /// `string` operand or an unseekable column never qualifies, and the executor
  /// scans.
  ///
  /// The hash-join executor reuses this over a pushed inner filter's conjuncts
  /// to seek the inner by a seekable conjunct before bucketing, so a
  /// seekable/contradictory inner filter reads few or no inner rows — hence it is
  /// `internal` rather than private to `seek`.
  internal static func boundaries<T: Table & ~Escapable>(_ filter: Filter,
                                                         _ ordinals: Array<Int>,
                                                         _ table: borrowing T,
                                                         _ count: Int,
                                                         _ bindings: Bindings)
      -> Range<Int>? {
    guard let (slot, op, value) = comparison(filter, bindings),
        let lower = table.bound(ordinals[slot], value, strict: false),
        let upper = table.bound(ordinals[slot], value, strict: true) else {
      return nil
    }

    // A range takes the rows on one side of the boundary, which is correct only
    // when the column is ordered — every row on that side compares that way. An
    // equality takes only the boundary's own run, which `bound` brackets
    // exactly even for an unordered seek (a decoded coded-index key: the sorted
    // raw run brackets one tag's value, and the join re-tests the decoded key
    // per row), so equality always seeks; a range on an unordered column
    // returns `nil` and the engine scans and filters.
    let ordered = table.ordered(ordinals[slot])
    return switch op {
    case .equal: lower ..< upper
    case .lt: ordered ? 0 ..< lower : nil
    case .leq: ordered ? 0 ..< upper : nil
    case .gt: ordered ? upper ..< count : nil
    case .geq: ordered ? lower ..< count : nil
    case .unequal: nil   // a split run is two scans; let the scan handle it
    }
  }
}

// MARK: - Physical join

extension Catalog where Self: ~Escapable {
  /// Rewrites `Select(filter, Product(left, Scan(inner, _, nil)))` into an
  /// index-nested-loop `Join` when a `match` conjunct relates the two sides,
  /// else leaves the product (a plain nested loop) under the filter.
  ///
  /// The inner side is a bare `Scan(inner, _, nil)`, or that scan under a pushed
  /// single-relation filter — `Select(inner-filter, Scan(inner, _, nil))`, the
  /// shape selection pushdown leaves when a `WHERE` conjunct references only the
  /// joined-in relation. Either way the join folds in the scan; the pushed
  /// filter is preserved so the joined-in relation's non-key predicate still
  /// rides the `Join` path rather than degrading to a residual product.
  ///
  /// The left side's slot count is the boundary `base` in the combined slot
  /// space: a slot below it is an outer-side key, a slot at or above it an
  /// inner-side key (still in combined space). The inner key's slot maps to its
  /// table ordinal (`column`) through the inner scan's `ordinals` for the
  /// seek's `bound`. The matching conjunct is consumed; any remaining conjuncts
  /// stay as a residual `Select`. The pushed inner filter rides on the `Join`
  /// node itself — in the inner's OWN 0-based standalone slot space, the space it
  /// already lives in on the inner scan — so the executor applies it WHILE
  /// materialising inner rows (before bucketing / as part of the inner scan),
  /// rather than lifting it into the residual to run after the join. Applying it
  /// during materialisation means a pair forms only when the filter holds, so it
  /// still gates a later unsafe residual conjunct (the pushdown barrier having
  /// kept the safe inner filter ahead of any unsafe conjunct). When the inner
  /// side is neither shape, the product is preserved.
  private borrowing func nest(_ filter: Filter, _ left: Plan, _ right: Plan,
                              _ ctes: CTEs, _ bindings: Bindings)
      throws(SQLError) -> Plan {
    let inner: (name: String, ordinals: Array<Int>, filter: Filter?)?
    switch right {
    case let .scan(name, ordinals, nil):
      inner = (name, ordinals, nil)
    case let .select(pushed, .scan(name, ordinals, nil)):
      inner = (name, ordinals, pushed)
    default:
      inner = nil
    }

    guard let inner, let base = left.slots else {
      return try Engine.gated(filter,
                              .product(optimise(left, ctes, bindings),
                                       optimise(right, ctes, bindings)))
    }

    let conjuncts = filter.conjuncts
    for index in conjuncts.indices {
      guard case let .match(lhs, rhs) = conjuncts[index],
          let (leftKey, rightKey) = Engine.keys(lhs, rhs, base) else {
        continue
      }

      var residual = conjuncts
      residual.remove(at: index)
      // The pushed inner filter stays in the inner's 0-based standalone slot
      // space and rides on the `Join` node, applied while the executor
      // materialises the inner (before bucketing / as part of the inner scan) —
      // NOT lifted into the residual to run after the join. It is always safe and
      // the pushdown barrier kept it ahead of any unsafe conjunct, so applying it
      // during materialisation still gates a later unsafe residual (a pair forms
      // only when the filter holds), without letting that conjunct throw first
      // (`Parent.Name = 'nope' AND (1 / Child.x) = 0`, the false name excluding
      // the row before the division runs).
      let join = try Plan.join(optimise(left, ctes, bindings),
                               name: inner.name, ordinals: inner.ordinals,
                               base: base,
                               column: inner.ordinals[rightKey - base],
                               keys: (left: leftKey, right: rightKey),
                               filter: inner.filter)
      guard let predicate = residual.conjunction else { return join }
      return .select(predicate, join)
    }

    return try Engine.gated(filter,
                            .product(optimise(left, ctes, bindings),
                                     optimise(right, ctes, bindings)))
  }
}

extension Engine {
  /// A `product` under `filter` for a join `nest` cannot fold into a `Join`,
  /// keeping the ON `match` conjuncts as a SEPARATE inner gate below the rest —
  /// `Select(rest, Select(match, product))`. Because `evaluate(.and)` does not
  /// short-circuit, folding the match into one `AND` with the WHERE would, for a
  /// pair whose NULL join key makes the match UNKNOWN, still evaluate a throwing
  /// WHERE (`(1 / A.x) = 0`) — a pair the join forms no row for. Gating on the
  /// match first drops that pair before the WHERE runs, as the `Select(match,
  /// product)` did before `distribute` folded the match into the conjuncts for
  /// `nest` to find. When there is no match, `rest` is the whole filter and this
  /// is the plain `Select(filter, product)`.
  internal static func gated(_ filter: Filter, _ product: Plan) -> Plan {
    var matches = Array<Filter>()
    var rest = Array<Filter>()
    for conjunct in filter.conjuncts {
      if case .match = conjunct {
        matches.append(conjunct)
      } else {
        rest.append(conjunct)
      }
    }
    var plan = product
    if let gate = matches.conjunction { plan = .select(gate, plan) }
    if let predicate = rest.conjunction { plan = .select(predicate, plan) }
    return plan
  }

  /// The `(outerKey, innerKey)` an equality between slots `lhs` and `rhs`
  /// relates across the boundary `base`, or `nil` if both fall on one side.
  ///
  /// Exactly one slot must be below `base` (the outer key) and the other at or
  /// above it (the inner key, still in combined space); the order the equality
  /// was written in does not matter.
  internal static func keys(_ lhs: Int, _ rhs: Int, _ base: Int)
      -> (outer: Int, inner: Int)? {
    switch (lhs < base, rhs < base) {
    case (true, false): (lhs, rhs)
    case (false, true): (rhs, lhs)
    default: nil
    }
  }
}

// MARK: - Selection pushdown

extension Plan {
  /// Pushes each `WHERE` conjunct that references a single relation's slots down
  /// to just above that relation's leaf, before the join/product chain folds it
  /// in — so a relation is filtered as it is read rather than after the whole
  /// product is formed.
  ///
  /// `compile` leaves the `WHERE` as one `select` atop the left-deep chain, so a
  /// join runs on unfiltered inputs. This pass descends the chain: a conjunct
  /// whose slots all fall in one relation's contiguous slot run rides down to
  /// that relation's leaf as a `select` over its `scan`/`derived`, where the
  /// seek and nest rewrites can then act on it; a conjunct spanning two
  /// relations (a residual, an `OR` across sides) stays at the level whose two
  /// children it straddles. A conjunct over a `derived` view's output columns is
  /// pushed INTO the view's sub-plan — its outer slot mapped back through the
  /// view's projection to the sub-plan slot the column reads — recursing below
  /// the view's own joins. A `union` pushes into every arm. The pass is a pure
  /// logical rewrite; `optimise` runs after it and still sees the `select`s the
  /// seek and nest rewrites match.
  internal func pushdown() throws(SQLError) -> Plan {
    switch self {
    case .single, .scan, .join:
      self
    case let .derived(name, sub, ordinals, seek):
      try .derived(name: name, plan: sub.pushdown(), ordinals: ordinals,
                   seek: seek)
    case let .select(filter, source):
      try source.pushdown().distribute(filter.conjuncts)
    case let .project(terms, source):
      try .project(terms, source.pushdown())
    case let .sort(keys, source):
      try .sort(keys: keys, source.pushdown())
    case let .product(left, right):
      try .product(left.pushdown(), right.pushdown())
    case let .union(left, right, all):
      try .union(left.pushdown(), right.pushdown(), all: all)
    case let .aggregate(keys, aggregates, source):
      // An aggregate reshapes rows into a fresh grouped slot space, so it is a
      // pushdown barrier: a `HAVING`/projection filter above it is in grouped
      // space and stays there (`distribute`'s default keeps it as a `select`
      // over the aggregate), while the WHERE below it — already placed under the
      // aggregate at compile — pushes down within the source as usual.
      try .aggregate(keys: keys, aggregates: aggregates, source.pushdown())
    case let .limit(count, offset, source):
      // A `limit` is the outermost operator, so no `WHERE` conjunct ever reaches
      // it to push down; it recurses transparently, its source pushed as usual.
      // A filter must never cross it — capping before or after a filter yields
      // different rows — and none can, since the cap sits above the projection.
      try .limit(count: count, offset: offset, source.pushdown())
    }
  }

  /// Places each of `conjuncts` as deep in the already-pushed `self` as the
  /// slots it reads allow, wrapping the level whose children a conjunct straddles
  /// in a residual `select`.
  ///
  /// At a `product`, `left.slots` is the boundary: a conjunct entirely below it
  /// belongs to the left child and rides down; one entirely at or above it
  /// belongs to the right child, rebased into that child's own slot space; one
  /// straddling the boundary — or reading no slots, or able to throw when
  /// evaluated (a division or scalar call) — stays here. A
  /// `select` (a join's `ON` match, whose
  /// two sides straddle every boundary) is transparent — the conjuncts descend
  /// through it into the product beneath. At a `derived` leaf the conjuncts push
  /// into the view; at a base `scan` they land directly above it. Any conjunct
  /// that cannot descend is re-conjoined as a `select` at this level.
  private func distribute(_ conjuncts: Array<Filter>)
      throws(SQLError) -> Plan {
    switch self {
    case let .product(left, right):
      guard let base = left.slots else {
        return residual(conjuncts)
      }
      var here = Array<Filter>()
      var down = Array<Filter>()
      var over = Array<Filter>()
      var barrier = false
      for (index, conjunct) in conjuncts.enumerated() {
        let slots = conjunct.slots
        // A conjunct stays here — at the product level, run per pair, in the
        // order the `AND` chain wrote — when a preceding conjunct was unsafe
        // (`barrier`), when it reads no slots (e.g. `(1 / 0) = 0`, where
        // `allSatisfy` is vacuously true), when evaluating it can throw (a
        // division or scalar call, e.g. `(1 / A.x) = 0`), or when it is nullable
        // (reads a slot, so a NULL there makes it UNKNOWN) and a LATER conjunct
        // is unsafe. Riding a throwing conjunct down would raise while scanning a
        // child even when the join's other side is empty; riding a safe conjunct
        // PAST an earlier unsafe one would filter its rows before the unsafe one
        // runs, suppressing a throw the left-to-right `AND` owes (`(1 / A.x) = 0
        // AND A.x <> 0`, `A.x = 0`, on a matching pair). Because the evaluator's
        // `AND` does not short-circuit, riding a nullable conjunct BELOW a later
        // unsafe one likewise suppresses a throw: the un-pushed `AND` runs the
        // later conjunct even for the UNKNOWN row, but the pushed conjunct drops
        // that row first (`A.x = 1 AND (1 / B.y) = 0`, `A.x` NULL and `B.y = 0`).
        // Only a safe single-relation conjunct with no unsafe predecessor — and,
        // if nullable, no unsafe successor — rides down.
        let hazard =
            conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
        if barrier || slots.isEmpty || !conjunct.safe || hazard {
          here.append(conjunct)
        } else if slots.allSatisfy({ $0 < base }) {
          down.append(conjunct)
        } else if slots.allSatisfy({ $0 >= base }) {
          over.append(conjunct)
        } else {
          here.append(conjunct)
        }
        // An unsafe conjunct bars every later conjunct from riding past it.
        if !conjunct.safe { barrier = true }
      }
      let product =
          Plan.product(try left.distribute(down),
                       try right.distribute(over.map { $0.shifted(by: base) }))
      return product.residual(here)
    case let .select(match, source):
      // A join's `ON` match straddles both sides, so it never captures a
      // single-relation conjunct. Fold it in with the descending conjuncts so
      // the product carries one `Select([match, spanning…], Product)`: `nest`
      // finds the match to form the `Join` and keeps any spanning residual above
      // it. Wrapping it outside instead — `Select(match, source.distribute(…))`
      // — would leave `Select(match, Select(spanning, Product))`, whose match is
      // no longer adjacent to the product, so `nest` could not fold it.
      return try source.distribute(match.conjuncts + conjuncts)
    case .derived:
      return try into(conjuncts)
    default:
      return residual(conjuncts)
    }
  }

  /// Pushes `conjuncts` INTO this `derived` view's sub-plan, below its own
  /// projection and joins, mapping each conjunct's outer slot (a slot into the
  /// leaf's `ordinals`, i.e. a view output column) back to the sub-plan slot the
  /// column reads.
  ///
  /// A view's sub-plan is `Project(terms, body)` (or a `union` of such), so an
  /// output column `ordinals[slot]` is `terms[ordinals[slot]]`. A conjunct
  /// pushes in only when every slot it reads maps to a bare `.slot` term — a
  /// plain column of the body; a conjunct over a computed column (a call or
  /// arithmetic) cannot rebase and stays as a `select` on the derived leaf. A
  /// `union` sub-plan admits a conjunct only when every arm's projection admits
  /// it — the arms are combined, so a conjunct that cannot push into one arm
  /// must stay outside them all. The admitted conjuncts, still in the view's
  /// OUTPUT slot space, push in through `inject`, which rebases each against the
  /// projection it lands under — PER ARM for a union, since the arms map the
  /// same output column to DIFFERENT body slots; the rest wrap the leaf.
  ///
  /// The partition carries the SAME ordering barrier `distribute`'s product loop
  /// has: a conjunct stays `outer` — on the derived leaf, run in the `AND`
  /// chain's order — when a preceding conjunct was unsafe (`barrier`), when it is
  /// itself unsafe (a division or scalar call), when it is nullable and a LATER
  /// conjunct is unsafe, or when the view's projection cannot admit it; only a
  /// safe conjunct with no unsafe predecessor — and, if nullable, no unsafe
  /// successor — pushes in. An unsafe conjunct bars every later one from riding
  /// into the view: pushing a later conjunct past it would let the view seek and
  /// drop the row before the unsafe outer conjunct runs, suppressing a throw the
  /// left-to-right `AND` owes (`(1 / x) = 0 AND x = 1` over a view whose `x` is
  /// sorted, the `x = 1` seek dropping the `x = 0` row before the outer division
  /// raises). Symmetrically a nullable conjunct pushed BELOW a later unsafe one
  /// suppresses a throw: the non-short-circuiting `AND` runs the later conjunct
  /// even for the UNKNOWN row, but the injected conjunct drops that row first
  /// (`x = 1 AND (1 / y) = 0`, `x` NULL and `y = 0`).
  private func into(_ conjuncts: Array<Filter>) throws(SQLError) -> Plan {
    guard case let .derived(name, plan, ordinals, seek) = self else {
      return residual(conjuncts)
    }
    var inner = Array<Filter>()
    var outer = Array<Filter>()
    var barrier = false
    for (index, conjunct) in conjuncts.enumerated() {
      // A nullable conjunct (reads a slot, so a NULL there makes it UNKNOWN) must
      // also stay outer when a LATER conjunct is unsafe: the evaluator's `AND`
      // does not short-circuit, so the un-pushed query runs the later conjunct
      // even for the UNKNOWN row, but injecting this one into the view would seek
      // or filter that row away first — suppressing a throw the left-to-right
      // `AND` owes (`x = 1 AND (1 / y) = 0` over a view exposing `x`/`y`, `x`
      // NULL and `y = 0`).
      let hazard =
          conjunct.nullable && conjuncts[(index + 1)...].contains { !$0.safe }
      if barrier || !conjunct.safe || hazard
          || !plan.pushable(conjunct, ordinals) {
        outer.append(conjunct)
      } else {
        inner.append(conjunct)
      }
      // An unsafe conjunct bars every later conjunct from riding past it.
      if !conjunct.safe { barrier = true }
    }
    let sub = inner.isEmpty ? plan : try plan.inject(inner, ordinals)
    let leaf = Plan.derived(name: name, plan: sub, ordinals: ordinals,
                            seek: seek)
    return leaf.residual(outer)
  }

  /// Whether `conjunct` (in this view's OUTPUT slot space, its slots indices
  /// into `ordinals`) can push below this sub-plan's projection.
  ///
  /// A `project` admits it when every slot it reads maps to a bare `.slot` term
  /// of the body — the `rebase` helper produces a mapping; a computed column
  /// (call or arithmetic) has none. A `union` admits it only when EVERY arm
  /// does — the arms are combined, so a conjunct pushable into one but not
  /// another cannot descend into any and must stay outside. Anything else does
  /// not admit it.
  private func pushable(_ conjunct: Filter, _ ordinals: Array<Int>) -> Bool {
    switch self {
    case let .project(terms, _):
      // A conjunct pushes below the projection only when every projected term is
      // safe: pushing it filters rows before the projection runs, so a throwing
      // term — a division or scalar call, even one the conjunct does not read —
      // would be skipped for the filtered rows, suppressing a raise `derive`
      // owes by evaluating every column of every view row.
      terms.allSatisfy(\.safe) && rebase(conjunct, ordinals) != nil
    case let .union(left, right, _):
      left.pushable(conjunct, ordinals) && right.pushable(conjunct, ordinals)
    default:
      false
    }
  }

  /// This view sub-plan with `conjuncts` (in the view's OUTPUT slot space)
  /// pushed below its projection, each rebased into the body slots the
  /// projection it lands under reads.
  ///
  /// For a `union` each arm rebases the conjuncts against ITS OWN projection —
  /// the same output column sits at different body slots across arms, so a
  /// single pre-rebased filter cannot serve them all; the rebase must happen per
  /// arm. `pushable` has already vetted every conjunct against every arm, so the
  /// per-arm `rebase` is guaranteed non-nil.
  private func inject(_ conjuncts: Array<Filter>, _ ordinals: Array<Int>)
      throws(SQLError) -> Plan {
    switch self {
    case let .project(terms, body):
      try .project(terms,
                   body.distribute(conjuncts.map { rebase($0, ordinals)! }))
    case let .union(left, right, all):
      try .union(left.inject(conjuncts, ordinals),
                 right.inject(conjuncts, ordinals), all: all)
    default:
      // A view sub-plan is always a `project` (or a `union` of them); anything
      // else keeps the conjuncts as an outer `select` rather than dropping them.
      residual(conjuncts)
    }
  }

  /// `conjunct` rebased from a `derived` leaf's OUTPUT slot space into this
  /// projection sub-plan's body slot space, or `nil` if any slot it reads is a
  /// computed view column (not a bare `.slot` projection term) and so cannot be
  /// pushed in.
  ///
  /// Slot `s` of the leaf reads view column `ordinals[s]`, whose value is the
  /// projection term `terms[ordinals[s]]`; the conjunct pushes in only when that
  /// term is a bare `.slot(body)`, in which case `s` maps to `body`. Shared by
  /// `pushable` (the non-nil check) and `inject` (the rebased value).
  private func rebase(_ conjunct: Filter, _ ordinals: Array<Int>) -> Filter? {
    guard case let .project(terms, _) = self else { return nil }
    var map = Dictionary<Int, Int>(minimumCapacity: conjunct.slots.count)
    for slot in conjunct.slots {
      guard case let .slot(body) = terms[ordinals[slot]] else { return nil }
      map[slot] = body
    }
    return conjunct.remapped(through: map)
  }

  /// This plan wrapped in a `select` of `conjuncts`, or unchanged for an empty
  /// list — the residual placement of conjuncts that descend no further.
  private func residual(_ conjuncts: Array<Filter>) -> Plan {
    guard let filter = conjuncts.conjunction else { return self }
    return .select(filter, self)
  }
}

// MARK: - Compilation

extension Catalog where Self: ~Escapable {
  /// Compiles `query` over this catalog into a logical operator tree.
  ///
  /// A single `SELECT` compiles as itself; a `UNION` compiles recursively into a
  /// BINARY `union` plan that mirrors the left-associative `Query`:
  /// `compile(.union(left, select, all))` is `.union(compile(left),
  /// compile(.select(select)), all)`. Each node carries its OWN `all`, so the
  /// executor honours every `UNION`/`UNION ALL` distinctly — `(A UNION B) UNION
  /// ALL C` dedups `A ∪ B` before appending `C`, rather than treating the whole
  /// chain by the trailing arm's flag. The new arm must project the same column
  /// count as the chain's first `SELECT` — the result columns — else
  /// `SQLError.arity`.
  internal borrowing func compile(_ query: Query, _ ctes: CTEs = [:],
                                  _ visited: Set<String> = [])
      throws(SQLError) -> Plan {
    guard case let .union(left, select, all) = query else {
      return try compile(query.first, ctes, visited)
    }

    let width = try arity(query.first, ctes, visited)
    let count = try arity(select, ctes, visited)
    guard count == width else { throw .arity(width, count) }
    return try .union(compile(left, ctes, visited),
                      compile(.select(select), ctes, visited), all: all)
  }

  /// The number of result columns `select` projects — the extent of a `*` over
  /// its relations, else the count of its projected items — for the `UNION`
  /// arity check. The relations resolve through this catalog, the `ctes`
  /// consulted first.
  private borrowing func arity(_ select: Select, _ ctes: CTEs,
                               _ visited: Set<String>)
      throws(SQLError) -> Int {
    switch select.projection {
    case .all:
      // `SELECT *` spans the relations in scope; a FROM-less arm has none.
      guard let relation = select.from else {
        throw .named("SELECT * with no FROM")
      }
      var width = try resolve(relation, ctes, visited).schema.width
      for join in select.joins {
        try width += resolve(join.relation, ctes, visited).schema.width
      }
      return width
    case let .columns(columns):
      return columns.count
    case let .expressions(items):
      return items.count
    }
  }

  /// Resolves a `Relation` against this catalog and the in-scope `ctes` to its
  /// schema and leaf factory.
  ///
  /// A common table expression shadows a base relation of the same name:
  /// `ctes` is consulted first, a CTE resolving to its materialised schema and
  /// a `scan` leaf (the executor materialises its records from the rows). Else
  /// a view shadows a base table — its `select` compiled to a sub-plan in a
  /// `derived` leaf — and finally a base table scans. A name none resolves is
  /// `SQLError.relation`.
  ///
  /// A view's body compiles OUTSIDE the statement's CTE scope — with an empty
  /// CTE map, not the caller's `ctes` — so a stored view means exactly what it
  /// was registered to mean regardless of the `WITH` a caller wraps around it. A
  /// name that IS a statement CTE has already resolved above (a CTE shadows a
  /// view, as it shadows a base table), so a name reaching the view branch is
  /// genuinely a view; letting its body see the caller's CTEs would let an
  /// unrelated statement-local `WITH Parent AS …` reach into a view whose own
  /// `FROM Parent` must mean the base relation. The view's `FROM`/`JOIN` names
  /// therefore resolve against the base catalog (and other views) alone.
  ///
  /// A view's `columns` must name exactly one column per value its query
  /// projects, or the view's schema would let a query index past a sub-plan row.
  /// The parser checks this whenever the projection's arity is statically known;
  /// this is the backstop for a `SELECT *` view, whose width is known only here,
  /// after the sub-plan compiles — a mismatch is `SQLError.columns`.
  ///
  /// `visited` names the views already being resolved down this chain. A view
  /// whose body reaches back to itself — `A` over `B` over `A`, or a view over
  /// itself — would recurse resolve→compile→resolve without end (a stack
  /// overflow, not an `SQLError`); re-encountering a name is a cyclic
  /// definition, reported as `.recursion` rather than hung. The
  /// `definition_schema.` store's `columns` builder, which compiles every view
  /// to advertise it, relies on this: a cyclic view's `try? compile` catches
  /// the fault and skips it.
  internal borrowing func resolve(_ relation: Relation, _ ctes: CTEs,
                                  _ visited: Set<String> = [])
      throws(SQLError) -> Engine.Resolved {
    let name = relation.name
    if let cte = ctes[name.lowercased()] {
      let schema = cte.schema()
      return Engine.Resolved(schema: schema) { ordinals in
        .scan(name: name, ordinals: ordinals, seek: nil)
      }
    }

    if let view = view(named: name) {
      // A view whose body reaches back to itself — `A` over `B` over `A`, or a
      // view over itself — would recurse resolve→compile→resolve without end (a
      // stack overflow, not an `SQLError`). `visited` names the views already
      // being resolved down this chain; re-encountering one is a cyclic
      // definition, reported as `.recursion` rather than hung.
      guard !visited.contains(name.lowercased()) else {
        throw .recursion(name)
      }
      // The view body compiles OUTSIDE the caller's statement CTEs, but it may
      // still name a reserved `definition_schema.` store relation, so seed its
      // scope with the overlay built from the view's OWN query — never the
      // caller's `ctes` — so a view defined over a store relation resolves.
      //
      // Compilation resolves only SCHEMAS (names → ordinals/types), never rows,
      // so the overlay is built SCHEMA-ONLY: a reserved relation types from its
      // header+types, and the row build is never triggered here. A view over
      // `definition_schema.columns` would otherwise re-enter that row builder
      // (which lists views, whose bodies name the relation again) — an
      // unbounded recursion. The rows a view over a reserved relation actually
      // returns are supplied at EXECUTE time, where `derive` rebuilds the
      // overlay with rows and runs the sub-plan.
      let overlay = augment([:], for: view.query, rows: false)
      let plan =
          try compile(view.query, overlay, visited.union([name.lowercased()]))
      let projected = plan.width
      guard view.columns.count == projected else {
        throw .columns(expected: projected, got: view.columns.count)
      }
      let schema = view.schema()
      return Engine.Resolved(schema: schema) { ordinals in
        .derived(name: name, plan: plan, ordinals: ordinals, seek: nil)
      }
    }

    guard let table = table(named: name) else {
      throw .relation(name)
    }
    let schema = table.schema()
    return Engine.Resolved(schema: schema) { ordinals in
      .scan(name: name, ordinals: ordinals, seek: nil)
    }
  }

  /// Compiles `select` over this catalog into a logical operator tree in slot
  /// space.
  ///
  /// The relation(s) resolve through this catalog (`SQLError.relation` on a
  /// miss). A single relation shapes `Project(Sort(Select(Scan)))`; a chain
  /// of joins shapes a left-deep tree, each join level a `Select(match,
  /// Product(chain, Scan))` on that join's `ON` equality, with the `WHERE`
  /// wrapped outside as `Project(Sort(Select(where, chain)))`. The `Select` and
  /// `Sort` layers are present only when a predicate or an `ORDER BY` is. Each
  /// scan carries the set of ordinals the query references on its side
  /// (projection ∪ every match ∪ filter ∪ order, reals and virtuals) so the
  /// executor materialises exactly those, in a fixed order that defines a dense
  /// SLOT for each — slot `i` is the scan's `i`th referenced ordinal.
  ///
  /// The operators run in slot space: `compile` remaps every ordinal it lowered
  /// (the projection, the `filter`, the order column, and each join's keys)
  /// through `ordinal → slot` so the records the operators address are dense
  /// arrays. The combined slot space lays the relations end to end in chain
  /// order — relation `i`'s referenced ordinals take a contiguous slot run after
  /// every earlier relation's — matching the merged record (each relation's
  /// cells concatenated in order). The tree is logical: every scan is a full
  /// `Scan(_, _, nil)`; the optimiser turns scans into seeks and each product
  /// into a join.
  internal borrowing func compile(_ select: Select, _ ctes: CTEs = [:],
                                  _ visited: Set<String> = [])
      throws(SQLError) -> Plan {
    guard let relation = select.from else {
      // A FROM-less select projects expressions over a single row; a `WHERE`,
      // `GROUP BY`, `HAVING`, `ORDER BY`, `OFFSET`/`FETCH`, or `JOIN` has no
      // relation to apply to. The parser never produces that shape, but a direct
      // `Select(from: nil, …)` can, so reject it rather than silently ignore the
      // clause — a scalar projection would drop a `GROUP BY`/`HAVING` otherwise.
      guard select.joins.isEmpty, select.predicate == nil,
          select.grouping.isEmpty, select.having == nil,
          select.order == nil, select.limit == nil else {
        throw .unsupported(
            "a WHERE, GROUP BY, HAVING, ORDER BY, OFFSET/FETCH, or JOIN " +
            "requires a FROM clause")
      }
      return try Engine.scalar(select.projection)
    }
    let from = try resolve(relation, ctes, visited)

    if let limit = select.limit {
      // The parser yields only non-negative counts (a `-` is its own token), but
      // a direct `Limit(count:offset:)` may carry negatives the executor's skip
      // and take would trap on. Reject them as a query error rather than crash.
      guard limit.offset >= 0, (limit.count ?? 0) >= 0 else {
        throw .unsupported("OFFSET and FETCH row counts must be non-negative")
      }
    }

    // An aggregate query — one with a `GROUP BY`, a `HAVING`, or an aggregate in
    // its projection — compiles through the grouped path, which places an
    // `aggregate` node above the WHERE/join chain and lowers the projection,
    // `HAVING`, and `ORDER BY` against the grouped slot space. A non-aggregate
    // query compiles exactly as before.
    if Engine.aggregates(select) {
      return try group(select, relation, from, ctes, visited)
    }

    guard !select.joins.isEmpty else {
      var filter: Filter? = nil
      if let predicate = select.predicate {
        filter = try from.schema.lower(predicate, in: relation)
      }
      var order = Array<(column: Int, ascending: Bool)>()
      if let clause = select.order {
        order = try from.schema.order(clause, in: relation)
      }
      let projection =
          try from.schema.terms(select.projection, in: relation)

      // The referenced ordinals, in slot order: slot `i` is `ordinals[i]`.
      let ordinals = Engine.referenced(projection, filter, order)
      let slot = Engine.invert(ordinals)
      let scan = from.leaf(ordinals)
      return Engine.shape(scan,
                          projection.map { $0.remapped(through: slot) },
                          filter.map { $0.remapped(through: slot) },
                          order.map { (slot[$0.column]!, $0.ascending) },
                          select.limit)
    }

    // Resolve every joined relation and lay all relations — the FROM relation
    // first, then each joined one in source order — end to end in one combined
    // ordinal space.
    var joined = Array<Engine.Resolved>()
    joined.reserveCapacity(select.joins.count)
    for join in select.joins {
      try joined.append(resolve(join.relation, ctes, visited))
    }

    var relations = [(relation, from.schema)]
    for index in select.joins.indices {
      relations.append((select.joins[index].relation, joined[index].schema))
    }
    let scope = Scope(relations)

    // Each join's ON equality lowers to a `match` at its own chain level,
    // resolved against only the prefix already in scope plus the relation that
    // join introduces — the FROM relation and joins `0…index` — never a
    // relation joined later. Since `Scope` lays relations at cumulative offsets
    // from 0, a prefix scope yields the same global combined ordinals as the
    // full-chain scope, so the match ordinals remap through `slot` as before;
    // resolving against the prefix rejects a reference to a not-yet-joined
    // relation (`SQLError.column`) and judges ambiguity only within the prefix.
    // The WHERE and ORDER lower against the whole chain, which legitimately
    // sees every relation.
    var matches = Array<Filter>()
    matches.reserveCapacity(select.joins.count)
    for index in select.joins.indices {
      let prefix = Scope(Array(relations[0 ... index + 1]))
      let join = select.joins[index]
      try matches.append(prefix.match(join.left, join.right))
    }
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause)
    }
    var order = Array<(column: Int, ascending: Bool)>()
    if let clause = select.order {
      order = try scope.order(clause)
    }
    let projection = try scope.terms(select.projection)

    // The combined referenced ordinals — projection ∪ every match ∪ WHERE ∪
    // order — packed per relation in chain order: relation i's referenced
    // ordinals take a contiguous slot run after every earlier relation's,
    // building the combined-ordinal → slot map and each relation's leaf ordinals.
    var references = Set<Int>()
    for term in projection { term.references(into: &references) }
    for match in matches { match.references(into: &references) }
    predicate?.references(into: &references)
    for key in order { references.insert(key.column) }
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

    // The left-deep chain: starting from the FROM relation's leaf, each join
    // folds in the next relation's scan as a `Select` on that join's match over
    // their product. The optimiser turns each `Select`-over-`Product` level into
    // an index-nested-loop join.
    let seed = from.leaf(locals[0])
    let chain = select.joins.indices.reduce(seed) { chain, index in
      .select(matches[index].remapped(through: slot),
              .product(chain, joined[index].leaf(locals[index + 1])))
    }

    return Engine.shape(chain,
                        projection.map { $0.remapped(through: slot) },
                        predicate.map { $0.remapped(through: slot) },
                        order.map { (slot[$0.column]!, $0.ascending) },
                        select.limit)
  }
}
