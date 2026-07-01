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
  /// Runs `query` against `catalog`, returning the projected, filtered, and
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
  public static func run<C: Catalog & ~Escapable>(_ query: Query,
                                                  _ catalog: borrowing C,
                                                  _ routines: Routines = [:],
                                                  bindings: Bindings = [:])
      throws(SQLError) -> Array<Array<Value>> {
    let logical = try compile(query, catalog).pushdown()
    let plan = try optimise(logical, catalog, bindings)
    return try execute(plan, catalog, routines, bindings).map(\.values)
  }

  // MARK: - Compilation

  /// Compiles `query` over `catalog` into a logical operator tree.
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
  internal static func compile<C: Catalog & ~Escapable>(_ query: Query,
                                                        _ catalog: borrowing C)
      throws(SQLError) -> Plan {
    guard case let .union(left, select, all) = query else {
      return try compile(query.first, catalog)
    }

    let width = try arity(query.first, catalog)
    let count = try arity(select, catalog)
    guard count == width else { throw .arity(width, count) }
    return try .union(compile(left, catalog), compile(.select(select), catalog),
                      all: all)
  }

  /// The number of result columns `select` projects — the extent of a `*` over
  /// its relations, else the count of its projected items — for the `UNION`
  /// arity check. The relations resolve through the borrowed `catalog`.
  private static func arity<C: Catalog & ~Escapable>(_ select: Select,
                                                     _ catalog: borrowing C)
      throws(SQLError) -> Int {
    switch select.projection {
    case .all:
      // `SELECT *` spans the relations in scope; a FROM-less arm has none.
      guard let relation = select.from else {
        throw .named("SELECT * with no FROM")
      }
      var width = try resolve(relation, catalog).schema.width
      for join in select.joins {
        try width += resolve(join.relation, catalog).schema.width
      }
      return width
    case let .columns(columns):
      return columns.count
    case let .expressions(items):
      return items.count
    }
  }

  /// Compiles `select` over `catalog` into a logical operator tree in slot
  /// space.
  ///
  /// The relation(s) resolve through the borrowed catalog (`SQLError.relation`
  /// on a miss). A single relation shapes `Project(Sort(Select(Scan)))`; a chain
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
  internal static func compile<C: Catalog & ~Escapable>(_ select: Select,
                                                        _ catalog: borrowing C)
      throws(SQLError) -> Plan {
    guard let relation = select.from else {
      // A FROM-less select projects expressions over a single row; a `WHERE`,
      // `ORDER BY`, or `JOIN` has no relation to apply to. The parser never
      // produces that shape, but a direct `Select(from: nil, …)` can, so reject
      // it rather than silently ignore the clause.
      guard select.joins.isEmpty, select.predicate == nil,
          select.order == nil else {
        throw .unsupported("a WHERE, ORDER BY, or JOIN requires a FROM clause")
      }
      return try scalar(select.projection)
    }
    let from = try resolve(relation, catalog)

    guard !select.joins.isEmpty else {
      var filter: Filter? = nil
      if let predicate = select.predicate {
        filter = try from.schema.lower(predicate, in: relation)
      }
      var order: (column: Int, ascending: Bool)? = nil
      if let clause = select.order {
        order = try from.schema.order(clause, in: relation)
      }
      let projection =
          try from.schema.terms(select.projection, in: relation)

      // The referenced ordinals, in slot order: slot `i` is `ordinals[i]`.
      let ordinals = referenced(projection, filter, order)
      let slot = invert(ordinals)
      let scan = from.leaf(ordinals)
      return shape(scan, projection.map { $0.remapped(through: slot) },
                   filter.map { $0.remapped(through: slot) },
                   order.map { (slot[$0.column]!, $0.ascending) })
    }

    // Resolve every joined relation and lay all relations — the FROM relation
    // first, then each joined one in source order — end to end in one combined
    // ordinal space.
    var joined = Array<Resolved>()
    joined.reserveCapacity(select.joins.count)
    for join in select.joins {
      try joined.append(resolve(join.relation, catalog))
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
    var order: (column: Int, ascending: Bool)? = nil
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
    if let order { references.insert(order.column) }
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

    return shape(chain, projection.map { $0.remapped(through: slot) },
                 predicate.map { $0.remapped(through: slot) },
                 order.map { (slot[$0.column]!, $0.ascending) })
  }

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
  private static func scalar(_ projection: Projection)
      throws(SQLError) -> Plan {
    guard case .all = projection else {
      let schema = Schema(width: 0, extent: 0, names: [], virtuals: [])
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
  private struct Resolved {
    let schema: Schema
    let leaf: (Array<Int>) -> Plan
  }

  /// Resolves a `Relation` against `catalog` to its schema and leaf factory.
  ///
  /// A view shadows a base table of the same name: the catalog is consulted for
  /// a view first, its `select` compiled to a sub-plan and wrapped in a
  /// `derived` leaf; otherwise a base table resolves and scans. A name neither
  /// resolves is `SQLError.relation`.
  ///
  /// A view's `columns` must name exactly one column per value its query
  /// projects, or the view's schema would let a query index past a sub-plan row.
  /// The parser checks this whenever the projection's arity is statically known;
  /// this is the backstop for a `SELECT *` view, whose width is known only here,
  /// after the sub-plan compiles — a mismatch is `SQLError.columns`.
  private static func resolve<C: Catalog & ~Escapable>(_ relation: Relation,
                                                       _ catalog: borrowing C)
      throws(SQLError) -> Resolved {
    if let view = catalog.view(named: relation.name) {
      let plan = try compile(view.query, catalog)
      let projected = plan.width
      guard view.columns.count == projected else {
        throw .columns(expected: projected, got: view.columns.count)
      }
      let schema = view.schema()
      return Resolved(schema: schema) { ordinals in
        .derived(name: relation.name, plan: plan, ordinals: ordinals,
                 seek: nil)
      }
    }

    guard let table = catalog.table(named: relation.name) else {
      throw .relation(relation.name)
    }
    let schema = table.schema()
    let name = relation.name
    return Resolved(schema: schema) { ordinals in
      .scan(name: name, ordinals: ordinals, seek: nil)
    }
  }

  /// The sorted, deduplicated ordinals a query references: the union of the
  /// ordinals its `projection` terms read, the columns its `filter` reads, and
  /// its `order` column. The projection terms hold ordinals at this stage; a
  /// scalar call's arguments contribute their read ordinals too.
  private static func referenced(_ projection: Array<Term>, _ filter: Filter?,
                                 _ order: (column: Int, ascending: Bool)?)
      -> Array<Int> {
    var ordinals = Set<Int>()
    for term in projection {
      term.references(into: &ordinals)
    }
    filter?.references(into: &ordinals)
    if let order { ordinals.insert(order.column) }
    return ordinals.sorted()
  }

  /// The inverse map `ordinal → slot` of a referenced-ordinal list: slot `i` is
  /// `ordinals[i]`, so the map sends `ordinals[i]` back to `i`.
  private static func invert(_ ordinals: Array<Int>) -> Dictionary<Int, Int> {
    var slot = Dictionary<Int, Int>(minimumCapacity: ordinals.count)
    for index in ordinals.indices {
      slot[ordinals[index]] = index
    }
    return slot
  }

  /// Wraps `source` in the `Project(Sort(Select(_)))` operators, omitting the
  /// `Select` and `Sort` layers when their clause is absent. The `projection`,
  /// `filter`, and `order` are in slot space.
  private static func shape(_ source: Plan, _ projection: Array<Term>,
                            _ filter: Filter?,
                            _ order: (slot: Int, ascending: Bool)?) -> Plan {
    var plan = source
    if let filter {
      plan = .select(filter, plan)
    }
    if let order {
      plan = .sort(slot: order.slot, ascending: order.ascending, plan)
    }
    return .project(projection, plan)
  }

  // MARK: - Optimisation

  /// Rewrites the logical `plan` into a physical one, re-resolving relations by
  /// name through the borrowed `catalog` for their seekability and a bound key
  /// through `bindings` so it seeks like a literal.
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
  internal static func optimise<C: Catalog & ~Escapable>(_ plan: Plan,
                                                         _ catalog: borrowing C,
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
      // the outer query still scans its result as is.
      try .derived(name: name, plan: optimise(plan, catalog, bindings),
                   ordinals: ordinals, seek: seek)
    case let .select(filter, .scan(name, ordinals, nil)):
      try seek(filter, name, ordinals, catalog, bindings)
    case let .select(filter, .product(left, right)):
      try nest(filter, left, right, catalog, bindings)
    case let .select(filter, source):
      try .select(filter, optimise(source, catalog, bindings))
    case let .project(ordinals, source):
      try .project(ordinals, optimise(source, catalog, bindings))
    case let .sort(slot, ascending, source):
      try .sort(slot: slot, ascending: ascending,
                optimise(source, catalog, bindings))
    case let .product(left, right):
      try .product(optimise(left, catalog, bindings),
                   optimise(right, catalog, bindings))
    case .join:
      plan
    case let .union(left, right, all):
      // Optimise each side with the same bindings so a bound predicate inside an
      // arm seeks; the union itself merely concatenates and deduplicates,
      // preserving this node's own `all`.
      try .union(optimise(left, catalog, bindings),
                 optimise(right, catalog, bindings), all: all)
    }
  }

  // MARK: - Physical seek

  /// Rewrites `Select(filter, Scan(name, ordinals, nil))` into a seeked scan
  /// when a sort-key conjunct qualifies, else leaves the full scan under the
  /// filter. The relation re-resolves through `catalog` to read its boundaries.
  ///
  /// A standalone qualifying comparison seeks its run and admits all of it (no
  /// residual). An `AND` with one qualifying conjunct seeks that run and keeps
  /// the other as the residual `Select` — but ONLY when that residual is safe,
  /// since seeking narrows the scan and a throwing residual would then raise
  /// over just the sought run, suppressing a throw the un-seeked scan owes on a
  /// skipped row. Everything else scans under the whole filter. The `filter` is
  /// in slot space, so a comparison's slot maps back to its table ordinal
  /// through the scan's `ordinals` before reading a boundary.
  private static func seek<C: Catalog & ~Escapable>(_ filter: Filter,
                                                    _ name: String,
                                                    _ ordinals: Array<Int>,
                                                    _ catalog: borrowing C,
                                                    _ bindings: Bindings)
      throws(SQLError) -> Plan {
    guard let table = catalog.table(named: name) else { throw .relation(name) }
    let count = table.cursor().count

    if let range = boundaries(filter, ordinals, table, count, bindings) {
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
          let range = boundaries(lhs, ordinals, table, count, bindings) {
        return .select(rhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
      if lhs.safe,
          let range = boundaries(rhs, ordinals, table, count, bindings) {
        return .select(lhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
    }

    return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
  }

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

  // MARK: - Physical join

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
  private static func nest<C: Catalog & ~Escapable>(_ filter: Filter,
                                                    _ left: Plan,
                                                    _ right: Plan,
                                                    _ catalog: borrowing C,
                                                    _ bindings: Bindings)
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
      return try gated(filter, .product(optimise(left, catalog, bindings),
                                        optimise(right, catalog, bindings)))
    }

    let conjuncts = filter.conjuncts
    for index in conjuncts.indices {
      guard case let .match(lhs, rhs) = conjuncts[index],
          let (leftKey, rightKey) = keys(lhs, rhs, base) else {
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
      let join = try Plan.join(optimise(left, catalog, bindings),
                               name: inner.name, ordinals: inner.ordinals,
                               base: base,
                               column: inner.ordinals[rightKey - base],
                               keys: (left: leftKey, right: rightKey),
                               filter: inner.filter)
      guard let predicate = residual.conjunction else { return join }
      return .select(predicate, join)
    }

    return try gated(filter, .product(optimise(left, catalog, bindings),
                                      optimise(right, catalog, bindings)))
  }

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
  private static func gated(_ filter: Filter, _ product: Plan) -> Plan {
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
  private static func keys(_ lhs: Int, _ rhs: Int, _ base: Int)
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
    case let .sort(slot, ascending, source):
      try .sort(slot: slot, ascending: ascending, source.pushdown())
    case let .product(left, right):
      try .product(left.pushdown(), right.pushdown())
    case let .union(left, right, all):
      try .union(left.pushdown(), right.pushdown(), all: all)
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
