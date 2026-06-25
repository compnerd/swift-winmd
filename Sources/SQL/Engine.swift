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
/// join compiles to a `Select` over the Cartesian `Product` of two scans, the
/// `ON` equality folded into the `Select` predicate. Absent layers are omitted.
/// Executing the plan yields the result records' typed values; formatting them
/// is a client's job.
public enum Engine {
  /// Runs `select` against `catalog`, returning the projected, filtered, and
  /// ordered rows as typed values.
  ///
  /// - Throws: `SQLError.relation` if the catalog resolves no such relation,
  ///   `SQLError.column` if a referenced column is absent, `SQLError.ambiguous`
  ///   if an unqualified name is resolved by both relations of a join.
  public static func run<C: Catalog & ~Escapable>(_ select: Select,
                                                  _ catalog: borrowing C)
      throws(SQLError) -> Array<Array<Value>> {
    let plan = try optimise(compile(select, catalog), catalog)
    return try execute(plan, catalog).map(\.values)
  }

  // MARK: - Compilation

  /// Compiles `select` over `catalog` into a logical operator tree in slot
  /// space.
  ///
  /// The relation(s) resolve through the borrowed catalog (`SQLError.relation`
  /// on a miss). A single relation shapes `Project(Sort(Select(Scan)))`; a join
  /// shapes `Project(Sort(Select(Product(Scan, Scan))))`, the `ON` equality
  /// conjoined onto the `WHERE` predicate over the product. The `Select` and
  /// `Sort` layers are present only when a predicate or an `ORDER BY` is. Each
  /// scan carries the set of ordinals the query references on its side
  /// (projection ∪ filter ∪ order ∪ join keys, reals and virtuals) so the
  /// executor materialises exactly those, in a fixed order that defines a dense
  /// SLOT for each — slot `i` is the scan's `i`th referenced ordinal.
  ///
  /// The operators run in slot space: `compile` remaps every ordinal it lowered
  /// (the projection, the `filter`, the order column, and a join's keys) through
  /// `ordinal → slot` so the records the operators address are dense arrays.
  /// A join's combined slot space lays the outer scan's slots `[0, outerCount)`
  /// then the inner scan's `[outerCount, outerCount + innerCount)`, matching the
  /// merged record (outer cells ++ inner cells). The tree is logical: every scan
  /// is a full `Scan(_, _, nil)`; the optimiser turns scans into seeks and the
  /// product into a join.
  internal static func compile<C: Catalog & ~Escapable>(_ select: Select,
                                                        _ catalog: borrowing C)
      throws(SQLError) -> Plan {
    guard let table = catalog.table(named: select.from.name) else {
      throw .relation(select.from.name)
    }

    guard let join = select.join else {
      var filter: Filter? = nil
      if let predicate = select.predicate {
        filter = try table.lower(predicate, in: select.from)
      }
      var order: (column: Int, ascending: Bool)? = nil
      if let clause = select.order {
        order = try table.order(clause, in: select.from)
      }
      let projection = try table.projection(select.projection, in: select.from)

      // The referenced ordinals, in slot order: slot `i` is `ordinals[i]`.
      let ordinals = referenced(projection, filter, order)
      let slot = invert(ordinals)
      let scan = Plan.scan(name: select.from.name, ordinals: ordinals,
                           seek: nil)
      return shape(scan, projection.map { slot[$0]! },
                   filter.map { remap($0, slot) },
                   order.map { (slot[$0.column]!, $0.ascending) })
    }

    guard let inner = catalog.table(named: join.relation.name) else {
      throw .relation(join.relation.name)
    }

    let scope = Scope(select.from, table, join.relation, inner)
    let on = try scope.match(join.left, join.right)
    var predicate: Filter? = nil
    if let clause = select.predicate {
      predicate = try scope.lower(clause)
    }
    let filter = conjoin(on, predicate)
    var order: (column: Int, ascending: Bool)? = nil
    if let clause = select.order {
      order = try scope.order(clause)
    }
    let projection = try scope.projection(select.projection)
    let base = scope.base

    let combined = referenced(projection, filter, order)
    let outerOrdinals = combined.filter { $0 < base }
    let innerOrdinals = combined.filter { $0 >= base }.map { $0 - base }

    // The combined slot map: the outer scan's referenced ordinals take slots
    // `[0, outerCount)`, the inner scan's take `[outerCount, outerCount +
    // innerCount)`, matching the merged record's outer-then-inner layout.
    var slot = invert(outerOrdinals)
    let split = outerOrdinals.count
    for index in innerOrdinals.indices {
      slot[innerOrdinals[index] + base] = split + index
    }

    let outer = Plan.scan(name: select.from.name, ordinals: outerOrdinals,
                          seek: nil)
    let right = Plan.scan(name: join.relation.name, ordinals: innerOrdinals,
                          seek: nil)
    return shape(.product(outer, right), projection.map { slot[$0]! },
                 remap(filter, slot),
                 order.map { (slot[$0.column]!, $0.ascending) })
  }

  /// The sorted, deduplicated ordinals a query references: the union of its
  /// `projection`, the columns its `filter` reads, and its `order` column.
  private static func referenced(_ projection: Array<Int>, _ filter: Filter?,
                                 _ order: (column: Int, ascending: Bool)?)
      -> Array<Int> {
    var ordinals = Set(projection)
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

  /// `filter` with every ordinal it addresses remapped to a slot through `slot`.
  private static func remap(_ filter: Filter, _ slot: Dictionary<Int, Int>)
      -> Filter {
    switch filter {
    case let .compare(column, op, value):
      .compare(slot[column]!, op, value)
    case let .match(left, right):
      .match(slot[left]!, slot[right]!)
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
  private static func shape(_ source: Plan, _ projection: Array<Int>,
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

  /// `on` conjoined with `predicate` when present, else `on` alone.
  private static func conjoin(_ on: Filter, _ predicate: Filter?) -> Filter {
    guard let predicate else { return on }
    return .and(on, predicate)
  }

  // MARK: - Optimisation

  /// Rewrites the logical `plan` into a physical one, re-resolving relations by
  /// name through the borrowed `catalog` to read their seekability.
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
                                                         _ catalog: borrowing C)
      throws(SQLError) -> Plan {
    switch plan {
    case .scan:
      plan
    case let .select(filter, .scan(name, ordinals, nil)):
      try seek(filter, name, ordinals, catalog)
    case let .select(filter, .product(left, right)):
      try nest(filter, left, right, catalog)
    case let .select(filter, source):
      try .select(filter, optimise(source, catalog))
    case let .project(ordinals, source):
      try .project(ordinals, optimise(source, catalog))
    case let .sort(slot, ascending, source):
      try .sort(slot: slot, ascending: ascending, optimise(source, catalog))
    case let .product(left, right):
      try .product(optimise(left, catalog), optimise(right, catalog))
    case .join:
      plan
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
                                                    _ catalog: borrowing C)
      throws(SQLError) -> Plan {
    guard let table = catalog.table(named: name) else { throw .relation(name) }
    let count = table.cursor().count

    if let range = boundaries(filter, ordinals, table, count) {
      return .scan(name: name, ordinals: ordinals, seek: range)
    }

    if case let .and(lhs, rhs) = filter {
      if let range = boundaries(lhs, ordinals, table, count) {
        return .select(rhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
      if let range = boundaries(rhs, ordinals, table, count) {
        return .select(lhs, .scan(name: name, ordinals: ordinals, seek: range))
      }
    }

    return .select(filter, .scan(name: name, ordinals: ordinals, seek: nil))
  }

  /// The boundaries `[lower, upper)` to seek for a sort-key comparison, or `nil`
  /// if `filter` does not qualify for the seek path.
  ///
  /// It qualifies when `filter` is a `compare` whose operand is an `integer`,
  /// the operator is an equality or a range, and `table.bound` reports the
  /// column seekable (a non-`nil` boundary). The comparison's slot maps back to
  /// its table ordinal through `ordinals` (slot `i` is `ordinals[i]`) for the
  /// `bound` query. A `string` operand or an unseekable column never qualifies,
  /// and the executor scans.
  private static func boundaries<T: Table & ~Escapable>(
      _ filter: Filter, _ ordinals: Array<Int>, _ table: borrowing T,
      _ count: Int) -> Range<Int>? {
    guard case let .compare(slot, op, .integer(value)) = filter,
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
                                                    _ catalog: borrowing C)
      throws(SQLError) -> Plan {
    guard case let .scan(name, ordinals, nil) = right,
        let base = slots(left) else {
      return try .select(filter, .product(optimise(left, catalog),
                                          optimise(right, catalog)))
    }

    let conjuncts = flatten(filter)
    for index in conjuncts.indices {
      guard case let .match(lhs, rhs) = conjuncts[index],
          let (leftKey, rightKey) = keys(lhs, rhs, base) else {
        continue
      }

      var residual = conjuncts
      residual.remove(at: index)
      let join = try Plan.join(optimise(left, catalog), name: name,
                               ordinals: ordinals, base: base,
                               column: ordinals[rightKey - base],
                               keys: (left: leftKey, right: rightKey))
      guard let predicate = rebuild(residual) else { return join }
      return .select(predicate, join)
    }

    return try .select(filter, .product(optimise(left, catalog),
                                        optimise(right, catalog)))
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

  /// The slot count of `plan`'s left-side scan — the outer relation's slots,
  /// the boundary past which inner slots begin in the combined space — or `nil`
  /// if the side is not a scan the boundary reads from.
  private static func slots(_ plan: Plan) -> Int? {
    switch plan {
    case let .scan(_, ordinals, _):
      ordinals.count
    case let .select(_, source):
      slots(source)
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
