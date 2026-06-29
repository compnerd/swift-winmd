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
    let plan = try optimise(compile(query, catalog), catalog, bindings)
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
      var width = try resolve(select.from, catalog).schema.width
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
    let from = try resolve(select.from, catalog)

    guard !select.joins.isEmpty else {
      var filter: Filter? = nil
      if let predicate = select.predicate {
        filter = try from.schema.lower(predicate, in: select.from)
      }
      var order: (column: Int, ascending: Bool)? = nil
      if let clause = select.order {
        order = try from.schema.order(clause, in: select.from)
      }
      let projection =
          try from.schema.terms(select.projection, in: select.from)

      // The referenced ordinals, in slot order: slot `i` is `ordinals[i]`.
      let ordinals = referenced(projection, filter, order)
      let slot = invert(ordinals)
      let scan = from.leaf(ordinals)
      return shape(scan, projection.map { remap($0, slot) },
                   filter.map { remap($0, slot) },
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

    var relations = [(select.from, from.schema)]
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
      .select(remap(matches[index], slot),
              .product(chain, joined[index].leaf(locals[index + 1])))
    }

    return shape(chain, projection.map { remap($0, slot) },
                 predicate.map { remap($0, slot) },
                 order.map { (slot[$0.column]!, $0.ascending) })
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
  private static func resolve<C: Catalog & ~Escapable>(_ relation: Relation,
                                                       _ catalog: borrowing C)
      throws(SQLError) -> Resolved {
    if let view = catalog.view(named: relation.name) {
      let plan = try compile(view.query, catalog)
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

  /// `term` with every ordinal it reads remapped to a slot through `slot`: a
  /// `.slot` holding an ordinal becomes the same slot, a constant is unchanged,
  /// a call recurses into its arguments.
  private static func remap(_ term: Term, _ slot: Dictionary<Int, Int>)
      -> Term {
    switch term {
    case let .slot(ordinal):
      .slot(slot[ordinal]!)
    case .constant:
      term
    case let .apply(name, arguments):
      .apply(name: name, arguments: arguments.map { remap($0, slot) })
    }
  }

  /// `filter` with every ordinal it addresses remapped to a slot through `slot`.
  private static func remap(_ filter: Filter, _ slot: Dictionary<Int, Int>)
      -> Filter {
    switch filter {
    case let .compare(lhs, op, rhs):
      .compare(remap(lhs, slot), op, remap(rhs, slot))
    case let .bound(term, op, parameter):
      .bound(remap(term, slot), op, parameter)
    case let .match(left, right):
      .match(slot[left]!, slot[right]!)
    case let .null(term, negated):
      .null(remap(term, slot), negated: negated)
    case let .and(lhs, rhs):
      .and(remap(lhs, slot), remap(rhs, slot))
    case let .or(lhs, rhs):
      .or(remap(lhs, slot), remap(rhs, slot))
    case let .not(operand):
      .not(remap(operand, slot))
    }
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
  /// the other as the residual `Select`. Everything else scans under the whole
  /// filter. The `filter` is in slot space, so a comparison's slot maps back to
  /// its table ordinal through the scan's `ordinals` before reading a boundary.
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

    if case let .and(lhs, rhs) = filter {
      if let range = boundaries(lhs, ordinals, table, count, bindings) {
        return .select(rhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
      if let range = boundaries(rhs, ordinals, table, count, bindings) {
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
  /// the column seekable (a non-`nil` boundary). The comparison's slot maps
  /// back to its table ordinal through `ordinals` (slot `i` is `ordinals[i]`)
  /// for the `bound` query. A `string` operand or an unseekable column never
  /// qualifies, and the executor scans.
  private static func boundaries<T: Table & ~Escapable>(_ filter: Filter,
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

    return switch op {
    case .equal: lower ..< upper
    case .lt: 0 ..< lower
    case .leq: 0 ..< upper
    case .gt: upper ..< count
    case .geq: lower ..< count
    case .unequal: nil   // a split run is two scans; let the scan handle it
    }
  }

  // MARK: - Physical join

  /// Rewrites `Select(filter, Product(left, Scan(inner, _, nil)))` into an
  /// index-nested-loop `Join` when a `match` conjunct relates the two sides,
  /// else leaves the product (a plain nested loop) under the filter.
  ///
  /// The left side's slot count is the boundary `base` in the combined slot
  /// space: a slot below it is an outer-side key, a slot at or above it an
  /// inner-side key (still in combined space). The inner key's slot maps to its
  /// table ordinal (`column`) through the inner scan's `ordinals` for the seek's
  /// `bound`. The matching conjunct is consumed; any remaining conjuncts stay as
  /// a residual `Select`. When the inner side is not a bare `Scan`, the product
  /// is preserved.
  private static func nest<C: Catalog & ~Escapable>(_ filter: Filter,
                                                    _ left: Plan,
                                                    _ right: Plan,
                                                    _ catalog: borrowing C,
                                                    _ bindings: Bindings)
      throws(SQLError) -> Plan {
    guard case let .scan(name, ordinals, nil) = right,
        let base = slots(left) else {
      return try .select(filter, .product(optimise(left, catalog, bindings),
                                          optimise(right, catalog, bindings)))
    }

    let conjuncts = flatten(filter)
    for index in conjuncts.indices {
      guard case let .match(lhs, rhs) = conjuncts[index],
          let (leftKey, rightKey) = keys(lhs, rhs, base) else {
        continue
      }

      var residual = conjuncts
      residual.remove(at: index)
      let join = try Plan.join(optimise(left, catalog, bindings), name: name,
                               ordinals: ordinals, base: base,
                               column: ordinals[rightKey - base],
                               keys: (left: leftKey, right: rightKey))
      guard let predicate = rebuild(residual) else { return join }
      return .select(predicate, join)
    }

    return try .select(filter, .product(optimise(left, catalog, bindings),
                                        optimise(right, catalog, bindings)))
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

  /// The combined-space slot count of `plan` — the boundary past which a newly
  /// joined relation's slots begin — or `nil` if a side's width is not known.
  ///
  /// A scan or a derived view's width is its referenced-ordinal count; a
  /// `select` is as wide as its source; a `product` is the sum of its sides and
  /// a `join` the sum of its outer side and the inner's referenced ordinals — so
  /// a left-deep chain of products or joins measures correctly, letting the
  /// nest rewrite recurse into a multi-relation chain.
  private static func slots(_ plan: Plan) -> Int? {
    switch plan {
    case let .scan(_, ordinals, _):
      ordinals.count
    case let .derived(_, _, ordinals, _):
      ordinals.count
    case let .select(_, source):
      slots(source)
    case let .product(left, right):
      if let left = slots(left), let right = slots(right) {
        left + right
      } else {
        nil
      }
    case let .join(outer, _, ordinals, _, _, _):
      slots(outer).map { $0 + ordinals.count }
    case let .union(left, _, _):
      // Both sides yield rows of the same width — the result columns — so the
      // union's width is its left side's.
      slots(left)
    default:
      nil
    }
  }

  // MARK: - Conjunct algebra

  /// The flat list of `AND`-conjuncts of `filter` (a non-`and` is a singleton).
  private static func flatten(_ filter: Filter) -> Array<Filter> {
    guard case let .and(lhs, rhs) = filter else { return [filter] }
    return flatten(lhs) + flatten(rhs)
  }

  /// The right-leaning `AND` of `conjuncts`, or `nil` for an empty list.
  private static func rebuild(_ conjuncts: Array<Filter>) -> Filter? {
    guard let last = conjuncts.last else { return nil }
    return conjuncts.dropLast().reversed().reduce(last) { .and($1, $0) }
  }
}
