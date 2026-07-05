// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The relational operator algebra — the engine's execution layer.
///
/// The `~Escapable` adapter is the storage layer: a `Cursor` vends borrowed
/// `Row` views that never escape the borrow, and a `Table`/`Catalog` is itself
/// `~Escapable`. The operator algebra runs on *materialised* tuples, so a
/// dynamic operator tree can carry a uniform tuple type rather than a
/// heterogeneous static one. A `Record` is that uniform tuple — an escapable,
/// slot-indexed row the adapter's borrowed cells are copied into at a leaf.
///
/// The plan is *escapable and name-holding*: a `Plan` references each relation
/// by its catalog NAME rather than by a `~Escapable` `Table` (an `indirect enum`
/// cannot box a `~Escapable` payload), and carries the ordinals the query
/// actually reads from it. The executor re-resolves a name to a transient table,
/// opens its cursor, and materialises *only the referenced ordinals* into a
/// dense slot array — reals out of the cursor, virtuals (ordinals `>= width`)
/// computed by the `Row`. Slot `i` of the record holds the cell of the scan's
/// `i`th referenced ordinal; the operators address slots, never ordinals, so a
/// record is a dense `Array<Value>` with no gaps and no per-row hashing.

// MARK: - Record

/// A materialised tuple: the uniform row flowing through the operators.
///
/// A `Record` copies an adapter `Row`'s referenced cells out into an escapable,
/// dense slot array, so it conforms to `SQL.Row` (cell-by-slot access) while
/// being free of the borrowed cursor's lifetime. A scan's referenced-ordinal
/// list (in a fixed order) defines a slot for each — slot `i` is that scan's
/// `i`th referenced ordinal — so the engine remaps every ordinal to a slot at
/// compile time and the record is addressed purely by array index: no
/// dictionary, no hashing, no per-row key sort. A projection-pushdown leaf, a
/// virtual column, and a join's two relations laid end to end all live as
/// consecutive slots under the one accessor the existing `evaluate(_:_:)` and
/// the projection read through.
internal struct Record: Row, Hashable {
  /// The tuple's cells, in slot order.
  private let cells: Array<Value>

  /// Wraps a slot-ordered array of cells as a record.
  internal init(_ cells: Array<Value>) {
    self.cells = cells
  }

  /// Materialises a record from an adapter `row`, copying exactly the
  /// `ordinals` the query references into dense slots `0 ..< ordinals.count` —
  /// slot `i` is `row[ordinals[i]]`.
  ///
  /// Reading `row[ordinal]` yields a real cell for an ordinal `< width` and a
  /// computed cell for a virtual ordinal. A single relation's record and a
  /// join's inner record are both built this way; the join lays the inner's
  /// slots after the outer's by concatenating the two records.
  internal init<R: Row & ~Escapable>(_ row: borrowing R,
                                     _ ordinals: Array<Int>) {
    var cells = Array<Value>()
    cells.reserveCapacity(ordinals.count)
    for ordinal in ordinals {
      cells.append(row[ordinal])
    }
    self.cells = cells
  }

  internal subscript(_ slot: Int) -> Value {
    borrowing get { cells[slot] }
  }

  /// The projection of `slots` re-laid as slots `0 ..< count`, in the order
  /// given — the record the `project` operator yields.
  internal func project(_ slots: Array<Int>) -> Record {
    Record(slots.map { cells[$0] })
  }

  /// The cells in slot order — the projected row a client reads.
  internal var values: Array<Value> {
    cells
  }

  /// The concatenation of this record with `other`, their two slot spaces laid
  /// end to end (outer slots then inner slots) — a join or product's combined
  /// tuple.
  internal func merged(with other: Record) -> Record {
    Record(cells + other.cells)
  }
}

// MARK: - Plan

/// An escapable, name-holding relational operator tree.
///
/// Every relation a `SELECT` names is held by its catalog NAME, not by a
/// `~Escapable` `Table`, so the whole tree is a plain escapable `indirect enum`.
/// The leaf `scan` carries the relation name, the ordinals the query reads from
/// it (reals and virtuals, in materialisation order — the order that defines the
/// scan's slots), and an optional seek — the row range to read. The unary
/// operators wrap a sub-plan: `select` keeps the records a `Filter` admits,
/// `project` restricts and reorders to the projected slots, and `sort` orders by
/// a typed key on a slot. `product` is the Cartesian product of two sub-plans
/// (records merged); `join` is the index-nested-loop equi-join that seeks the
/// inner relation per outer record rather than forming the product, the inner
/// named and its referenced ordinals carried for the executor to re-resolve and
/// materialise.
internal indirect enum Plan {
  /// The single-row leaf of a FROM-less `SELECT`: it yields exactly one empty
  /// record (no slots), the row a scalar projection (`SELECT 1 + 1`) computes
  /// its expressions against.
  case single
  /// A leaf over the relation `name`: its `ordinals` (defining its slots), over
  /// the seek's row range when present (else the whole relation).
  case scan(name: String, ordinals: Array<Int>, seek: Range<Int>?)
  /// A leaf over a view: the view's compiled sub-`plan` produces its full-width
  /// rows (its columns at slots `0 ..< columns.count`), of which `ordinals`
  /// (slots into those columns) define this leaf's slots, over the seek's row
  /// range when present. A view exposes no virtual column and no sort key, so
  /// `ordinals` index its columns directly and a seek is never planned into it.
  case derived(name: String, plan: Plan, ordinals: Array<Int>,
               seek: Range<Int>?)
  /// σ — keeps the records `Filter` admits, the filter in slot space.
  case select(Filter, Plan)
  /// π — evaluates each projected `Term` (a slot read, a constant, or a scalar
  /// call) against the record, in order, to the output row. A bare-column
  /// projection is a list of `.slot` terms, so the simple path is a reorder.
  case project(Array<Term>, Plan)
  /// τ — orders the records by a list of typed sort keys, major to minor. Each
  /// key names a `slot` and its direction; `keys[0]` is the primary key and
  /// each later key orders only the rows the earlier keys leave equal. The sort
  /// is stable, so rows equal on every key keep their input order. `keys` is
  /// never empty.
  case sort(keys: Array<(slot: Int, ascending: Bool)>, Plan)
  /// × — every concatenation of an outer record with an inner one.
  case product(Plan, Plan)
  /// ⋈ — for each outer record, seeks the inner relation `name` on
  /// `keys.right == outer[keys.left]` and concatenates each match. `keys.left`
  /// and `keys.right` are combined-space slots, `base` the inner's first slot
  /// in that combined space, and `column` the inner ordinal `keys.right` reads
  /// (for the seek `bound`). `filter` is a single-relation predicate pushed onto
  /// the inner — in the inner's OWN 0-based standalone slot space — applied WHILE
  /// each inner row is materialised, so an inner row that fails it is never
  /// paired.
  case join(Plan, name: String, ordinals: Array<Int>, base: Int,
            column: Int, keys: (left: Int, right: Int), filter: Filter?)
  /// ∪ — the rows of the `left` sub-plan followed by the `right`'s, in source
  /// order. With `all` the duplicates are kept (`UNION ALL`); without it the
  /// whole-row duplicates of the combined rows are removed, the first occurrence
  /// preserved (`UNION`). The node is binary and mirrors the left-associative
  /// `Query` chain, so each `UNION`/`UNION ALL` honours its OWN `all`: a `UNION`
  /// nested under a `UNION ALL` dedups its own pair before the outer node
  /// appends the trailing arm. Both sides yield rows of the same width — the
  /// result columns of the first arm.
  case union(Plan, Plan, all: Bool)
  /// Γ — groups its `source`'s records by the `keys` terms and folds each
  /// `aggregates` accumulator over every record of a group, yielding one grouped
  /// record per group. The grouped record's slots are the `keys` values (slots
  /// `0 ..< keys.count`, in key order) followed by the aggregate results (slot
  /// `keys.count + j` is `aggregates[j]`), the slot space the projection, the
  /// `HAVING`, and the `ORDER BY` are lowered against. With no `keys` the whole
  /// source is one group — the degenerate `SELECT COUNT(*) FROM T` — yielding a
  /// single grouped record even over an empty source (`COUNT` `0`, the others
  /// NULL). It sits above the WHERE/join chain and below the projection, so it
  /// aggregates the filtered rows and the projection reads its output.
  case aggregate(keys: Array<Term>, aggregates: Array<Aggregation>, Plan)
  /// A row cap on its `source`'s output: skips the first `offset` records then
  /// takes at most `count` of the rest, in the source's order. It sits over the
  /// sort/select but BELOW the projection, so it caps the ordered rows before
  /// the select list is evaluated — a row outside the page is never projected
  /// (a projection that could throw does not run for it). It neither reorders
  /// nor reshapes the rows, a transparent wrapper the pushdown and optimise
  /// passes recurse through.
  case limit(count: Int?, offset: Int, Plan)
}

extension Plan {
  /// The number of values this plan projects — its output column count.
  ///
  /// `compile` shapes every arm as `Project(…)`, so the projected width is the
  /// `project`'s term count; a `union` is as wide as its (left) arm, every arm
  /// aligned by the arity check. This measures a view's sub-plan against its
  /// declared `columns` so the view never claims a width its rows lack.
  internal var width: Int {
    switch self {
    case let .project(terms, _):
      terms.count
    case let .union(left, _, _):
      left.width
    case let .limit(_, _, source):
      // A `limit` caps rows without reshaping them, so it is as wide as its
      // source.
      source.width
    case let .aggregate(keys, aggregates, _):
      // A grouped record is the key values followed by the aggregate results.
      keys.count + aggregates.count
    default:
      // `compile` always tops an arm with a `project`; nothing else reaches a
      // view's sub-plan root. Measuring nil would mask a width mismatch, so a
      // zero (which never equals a non-empty column list) surfaces it.
      0
    }
  }

  /// The combined-space slot count of this plan — the boundary past which a
  /// newly joined relation's slots begin — or `nil` if a side's width is not
  /// known.
  ///
  /// A scan or a derived view's width is its referenced-ordinal count; a
  /// `select` is as wide as its source; a `product` is the sum of its sides and
  /// a `join` the sum of its outer side and the inner's referenced ordinals — so
  /// a left-deep chain of products or joins measures correctly, letting the
  /// nest rewrite recurse into a multi-relation chain.
  internal var slots: Int? {
    switch self {
    case .single:
      // The single empty row has no slots — a FROM-less projection reads only
      // constants and calls over them, never a slot of this row.
      0
    case let .scan(_, ordinals, _):
      ordinals.count
    case let .derived(_, _, ordinals, _):
      ordinals.count
    case let .select(_, source):
      source.slots
    case let .product(left, right):
      if let left = left.slots, let right = right.slots {
        left + right
      } else {
        nil
      }
    case let .join(outer, _, ordinals, _, _, _, _):
      outer.slots.map { $0 + ordinals.count }
    case let .union(left, _, _):
      // Both sides yield rows of the same width — the result columns — so the
      // union's width is its left side's.
      left.slots
    case let .limit(_, _, source):
      // A `limit` caps rows without reshaping them, so it spans the same slots
      // as its source.
      source.slots
    case let .aggregate(keys, aggregates, _):
      // A grouped record reshapes its source into the key values followed by the
      // aggregate results — a fresh slot space of that width.
      keys.count + aggregates.count
    default:
      nil
    }
  }

  /// This plan capped by `limit` — wrapped in a `limit` operator when one is
  /// present, else returned unchanged. `shape` caps the sorted/selected rows
  /// with this and then projects, so the cap sits below the projection.
  internal func capped(limit: Limit?) -> Plan {
    guard let limit else { return self }
    return .limit(count: limit.count, offset: limit.offset, self)
  }
}

// MARK: - Interpreter

/// Interprets `plan` against `catalog`, producing its result records.
///
/// Each operator transforms the records its sub-plan yields: `scan` re-resolves
/// the relation by name, opens its cursor, and materialises its referenced
/// ordinals over the seek range into dense slots; `select` keeps the admitted
/// records; `project` rebuilds each from the projected slots; `sort` orders them
/// by its typed keys major to minor, stably and each in its own direction;
/// `product` pairs every
/// outer record with every inner one; `join` re-resolves the inner relation,
/// seeks it per outer record, and concatenates the matches; `union` runs its
/// two sides — each with its own union semantics — and concatenates their rows,
/// deduplicating the whole row unless `all`; `limit` skips the first `offset` of
/// its source's rows then takes at most `count`.
/// The catalog is borrowed throughout — a `~Escapable` source is never copied
/// or stored.
internal func execute<C: Catalog & ~Escapable>(_ plan: Plan,
                                               _ catalog: borrowing C,
                                               _ ctes: CTEs,
                                               _ routines: Routines,
                                               _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  switch plan {
  case .single:
    // The FROM-less single row: one record with no cells, the source a scalar
    // projection evaluates its constant/call expressions against.
    [Record([])]
  case let .scan(name, ordinals, seek):
    try materialise(name, ordinals, seek, catalog, ctes)
  case let .derived(name, source, ordinals, seek):
    try derive(name, source, ordinals, seek, catalog, routines, bindings)
  case let .select(filter, .product(outer, inner)):
    // Fuse a residual product with its filter: stream each pair through the
    // predicate rather than materialising the whole cross product first.
    try sift(execute(outer, catalog, ctes, routines, bindings),
             execute(inner, catalog, ctes, routines, bindings), filter, routines,
             bindings)
  case let .select(filter, source):
    try admitted(execute(source, catalog, ctes, routines, bindings), filter,
                 routines, bindings)
  case let .project(terms, source):
    try execute(source, catalog, ctes, routines, bindings)
      .map { record throws(SQLError) in try project(terms, record, routines) }
  case let .sort(keys, source):
    try execute(source, catalog, ctes, routines, bindings)
      .enumerated()
      .sorted { lhs, rhs in
        // Compare the keys major to minor: the first key on which the rows
        // differ decides the order; a key they are equal on falls through to
        // the next. A key's direction governs that key alone.
        for key in keys {
          let ordered = less(lhs.element[key.slot], rhs.element[key.slot])
          let reverse = less(rhs.element[key.slot], lhs.element[key.slot])
          if ordered == reverse { continue }
          return key.ascending ? ordered : reverse
        }
        // Equal on every key: keep the source order (a stable sort) by
        // tie-breaking on the original index.
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  case let .product(outer, inner):
    try product(execute(outer, catalog, ctes, routines, bindings),
                execute(inner, catalog, ctes, routines, bindings))
  case let .join(outer, name, ordinals, base, column, keys, filter):
    try join(execute(outer, catalog, ctes, routines, bindings), name, ordinals,
             base, column, keys, filter, catalog, ctes, routines, bindings)
  case let .union(left, right, all):
    try union(left, right, all, catalog, ctes, routines, bindings)
  case let .aggregate(keys, aggregates, source):
    try grouped(execute(source, catalog, ctes, routines, bindings), keys,
                aggregates, routines)
  case let .limit(count, offset, source):
    limited(try execute(source, catalog, ctes, routines, bindings),
            count, offset)
  }
}

/// Caps `records` to at most `count` rows after skipping the first `offset`, in
/// their existing (ordered) order.
///
/// A `nil` `count` is no cap — every row after the skip (an `OFFSET` without a
/// `FETCH`). An `offset` at or past the end yields no rows; a `count` reaching
/// past the remaining rows takes all of them. Both are non-negative, so the skip
/// and the take never index before the start. The take is a `prefix` of the
/// skipped slice rather than an `offset + count` bound, so a `count` near
/// `Int.max` caps the slice instead of overflowing.
private func limited(_ records: Array<Record>, _ count: Int?, _ offset: Int)
    -> Array<Record> {
  guard offset < records.count else { return [] }
  let tail = records[offset...]
  guard let count else { return Array(tail) }
  return Array(tail.prefix(count))
}

/// Concatenates the rows of `left` followed by `right`, deduplicating the whole
/// combined row — first occurrence kept — unless `all` (`UNION ALL`, every row
/// kept).
///
/// Each side runs through the same `catalog`, `routines`, and `bindings`, so a
/// bound parameter threads into every arm alike. A side may itself be a `union`,
/// and it executes with its OWN semantics first — a `UNION` nested under a
/// `UNION ALL` dedups its pair before the outer node appends `right`. A `Record`
/// is `Hashable`, so `UNION`'s dedup keys on the materialised row.
private func union<C: Catalog & ~Escapable>(_ left: Plan, _ right: Plan,
                                            _ all: Bool,
                                            _ catalog: borrowing C,
                                            _ ctes: CTEs,
                                            _ routines: Routines,
                                            _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  let rows = try execute(left, catalog, ctes, routines, bindings)
      + execute(right, catalog, ctes, routines, bindings)
  guard !all else { return rows }

  var records = Array<Record>()
  var seen = Seen()
  for record in rows where seen.insert(record.values) {
    records.append(record)
  }
  return records
}

/// Evaluates each projected `term` against `record` through `routines` to the
/// output row, in order — slot `i` of the result is `terms[i]`.
private func project(_ terms: Array<Term>, _ record: Record,
                     _ routines: Routines) throws(SQLError) -> Record {
  var cells = Array<Value>()
  cells.reserveCapacity(terms.count)
  for term in terms {
    try cells.append(evaluate(term, record, routines))
  }
  return Record(cells)
}

/// Keeps the `records` the `filter` admits — those it evaluates to `true` under
/// three-valued logic (UNKNOWN and `false` both reject), resolving scalar calls
/// through `routines` and parameters from `bindings`.
private func admitted(_ records: Array<Record>, _ filter: Filter,
                      _ routines: Routines, _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  var kept = Array<Record>()
  for record in records {
    if try evaluate(filter, record, routines, bindings) == true {
      kept.append(record)
    }
  }
  return kept
}

/// Materialises the referenced `ordinals` of the relation `name` over the
/// seek's row range (the whole relation when `nil`) into dense slot `Record`s.
///
/// A common table expression `name` (in `ctes`, consulted first — a CTE shadows
/// a base relation) materialises its records directly from the in-engine
/// `Materialised` rows; else the base relation re-resolves through `catalog`,
/// its cursor opened.
///
/// - Throws: `SQLError.relation` if the name resolves to neither.
private func materialise<C: Catalog & ~Escapable>(_ name: String,
                                                  _ ordinals: Array<Int>,
                                                  _ seek: Range<Int>?,
                                                  _ catalog: borrowing C,
                                                  _ ctes: CTEs)
    throws(SQLError) -> Array<Record> {
  if let cte = ctes[name.lowercased()] {
    return (seek ?? 0 ..< cte.rows.count).map { cte.record($0, ordinals) }
  }
  guard let table = catalog.table(named: name) else { throw .relation(name) }
  let cursor = table.cursor()
  var records = Array<Record>()
  for index in seek ?? 0 ..< cursor.count {
    guard let row = cursor.row(index) else { continue }
    records.append(Record(row, ordinals))
  }
  return records
}

/// Executes a view's sub-`plan` against `catalog` and re-lays each resulting
/// record to the referenced `ordinals` (slots into the view's columns) over the
/// seek's row range (the whole result when `nil`).
///
/// The sub-plan yields full-width view records — its columns at slots
/// `0 ..< columns.count`; this projects each to the `ordinals` the outer query
/// reads, in the slot order the outer scan expects (slot `i` is `ordinals[i]`).
///
/// The sub-plan runs OUTSIDE the statement's CTE scope — never the caller's
/// `WITH` — so a caller's `WITH` never reaches into a stored view's body: a
/// view's own `FROM`/`JOIN` names resolve to base relations (and other views),
/// never to a statement-local CTE that happens to share a name. Its scope is
/// instead the `definition_schema.` overlay the view's OWN query names (empty
/// when it names none), so a view defined over a store relation materialises
/// exactly as the inline query does — the same overlay the body compiled and
/// optimised under.
private func derive<C: Catalog & ~Escapable>(_ name: String, _ plan: Plan,
                                             _ ordinals: Array<Int>,
                                             _ seek: Range<Int>?,
                                             _ catalog: borrowing C,
                                             _ routines: Routines,
                                             _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  let overlay = if let view = catalog.resolve(view: name) {
    catalog.augment([:], for: view.query, rows: true, routines: routines)
  } else {
    CTEs()
  }
  let rows = try execute(plan, catalog, overlay, routines, bindings)
  let range = seek ?? 0 ..< rows.count
  return range.map { rows[$0].project(ordinals) }
}

/// The Cartesian product of two materialised relations: every concatenation of
/// an `outer` record with an `inner` one, in outer-major order.
private func product(_ outer: Array<Record>, _ inner: Array<Record>)
    -> Array<Record> {
  var records = Array<Record>()
  records.reserveCapacity(outer.count * inner.count)
  for left in outer {
    for right in inner {
      records.append(left.merged(with: right))
    }
  }
  return records
}

/// The Cartesian product of `outer` and `inner` filtered row by row by
/// `filter` — the fused product-under-select, streamed.
///
/// A residual (non-equi) `product` under a `select` would otherwise materialise
/// the whole `outer.count * inner.count` cross product and only then filter it,
/// a memory blowup quadratic in the inputs. Here each pair is merged, tested,
/// and kept or dropped in turn, so only the surviving rows — not the full
/// product — are ever held. The order is identical to filtering the eager
/// product: outer-major, each admitted inner in its own order. A pair the
/// `filter` evaluates to `true` under three-valued logic is kept; UNKNOWN and
/// `false` both drop, exactly as `admitted`.
private func sift(_ outer: Array<Record>, _ inner: Array<Record>,
                  _ filter: Filter, _ routines: Routines, _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  var records = Array<Record>()
  for left in outer {
    for right in inner {
      let record = left.merged(with: right)
      if try evaluate(filter, record, routines, bindings) == true {
        records.append(record)
      }
    }
  }
  return records
}

/// The equi-join of `outer` against the inner relation `name`, resolved through
/// `ctes` first then `catalog`, seeking or hashing the inner as its shape allows.
///
/// A materialised CTE inner has no sort key, so it is scanned in full and joined
/// by the equality on its `keys.right` slot (`joined`). A base relation that
/// reports `column` (the inner ordinal `keys.right` reads) seekable is sought per
/// outer record — an index-nested loop, cheap because the seek narrows the scan;
/// one that is NOT seekable is scanned ONCE into a hash map keyed by its join
/// value and each outer record probes it in O(1) (`hashed`), rather than reading
/// the whole inner once per outer record. Every strategy materialises a candidate
/// over the referenced `ordinals` into inner slots `0 ..< ordinals.count`, admits
/// it only when the pushed inner `filter` (in the inner's standalone slot space)
/// also holds — applied WHILE the inner row is materialised, so a filtered inner
/// row is never paired or bucketed — keys on the inner's `keys.right` slot
/// (`keys.right - base` in the standalone inner record), and concatenates a match
/// (the inner's slots landing at `base` in the combined space). A NULL key joins
/// to nothing, and every path preserves outer-major order, the inner matches in
/// cursor order within each outer.
///
/// The HASH-JOIN bucket a key falls in — a grouping key, NOT the equality. A
/// numeric value buckets by its `Double` magnitude (an `.integer` promoted), so
/// every value equal to it under `Filter.matches` shares a bucket: `1` and
/// `1.0`, and an integer and the double it rounds to past 2^53. A non-numeric
/// value (text, boolean, blob, null) buckets as itself. The bucket may over-
/// group — two distinct large integers can share a `Double` bucket — so hash
/// probing pairs it with a RESIDUAL `matches(_,.equal,_)` check, the same exact
/// equality the predicate uses (integer/integer exact, mixed promoted). The
/// seek and CTE nested-loop paths compare with `matches` directly.
private func bucket(_ value: Value) -> Value {
  if case let .integer(number) = value { return .double(Double(number)) }
  return value
}

/// A value folded to its EXACT canonical form for duplicate elimination: a
/// whole `double` exactly equal to an `Int` (`Int(exactly:)`) becomes that
/// `.integer`, so `1.0` and `1` are the same value; every other value (a
/// fractional double, text, boolean, blob, null) is itself. Unlike the join's
/// promoted `bucket`, this is EXACT and transitive, so two integers stay
/// distinct even when they round to the same double — an earlier approximate
/// row cannot absorb two unequal exact integers. Grouping reuses it to key its
/// groups so `1` and `1.0` fall in one group, matching UNION's dedup.
internal func canonical(_ value: Value) -> Value {
  if case let .double(number) = value, let integer = Int(exactly: number) {
    return .integer(integer)
  }
  return value
}

/// Tracks the rows already emitted for UNION / recursive-CTE duplicate
/// elimination under the engine's EXACT numeric equality. A plain
/// `Set<Array<Value>>` over raw cells keeps `1` and `1.0` (and would keep both)
/// apart; keying each row by its cells' `canonical` form — exact and transitive
/// — dedups `1`/`1.0` while keeping distinct integers separate even when they
/// round to the same double, and (unlike a promoted key) makes the result
/// independent of arm order. Two NULLs stay not distinct (`.null` is its own
/// canonical). No residual check needed: exact equality is an equivalence.
internal struct Seen {
  private var keys = Set<Array<Value>>()

  /// Records `row` and reports whether it was NEW (not a duplicate of one
  /// already seen) — the `Set.insert(_:).inserted` shape the dedup sites use.
  internal mutating func insert(_ row: Array<Value>) -> Bool {
    keys.insert(row.map(canonical)).inserted
  }
}

/// - Throws: `SQLError.relation` if the inner name resolves to neither.
private func join<C: Catalog & ~Escapable>(_ outer: Array<Record>,
                                           _ name: String,
                                           _ ordinals: Array<Int>, _ base: Int,
                                           _ column: Int,
                                           _ keys: (left: Int, right: Int),
                                           _ filter: Filter?,
                                           _ catalog: borrowing C,
                                           _ ctes: CTEs,
                                           _ routines: Routines,
                                           _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  // A materialised CTE inner has no sort key, so it is scanned in full and the
  // equality on its `keys.right` slot is the join's truth — the same probe a
  // base relation falls back to when its key is unseekable. A pushed inner
  // filter (in the inner's standalone slot space) is applied as each record
  // materialises, before it can pair — mirroring the base seek/hash paths — so a
  // filtered CTE row is never joined.
  if let cte = ctes[name.lowercased()] {
    var inner = Array<Record>()
    for index in 0 ..< cte.rows.count {
      let right = cte.record(index, ordinals)
      if let filter,
          try evaluate(filter, right, routines, bindings) != true { continue }
      inner.append(right)
    }
    return joined(outer, inner, base, keys)
  }
  guard let inner = catalog.table(named: name) else { throw .relation(name) }
  guard seekable(inner, column) else {
    return try hashed(outer, inner, ordinals, base, keys, filter, routines,
                      bindings)
  }

  let cursor = inner.cursor()
  let slot = keys.right - base
  var records = Array<Record>()
  for left in outer {
    let value = left[keys.left]
    // A NULL key equi-joins to nothing — NULL is unequal to every value,
    // itself included — so it contributes no pair and need not probe.
    if case .null = value { continue }
    // Seek by the RAW value — the sorted key is a single-kind (integer) column,
    // and a promoted double would defeat the seek; the numeric equality below
    // still admits a mixed-kind match (a whole double past the range is caught
    // by the residual check even if the seek scanned wide).
    let range = probe(inner, column, value, cursor.count)
    for index in range {
      guard let row = cursor.row(index) else { continue }
      let right = Record(row, ordinals)
      // A pushed inner filter is applied as each candidate materialises, before
      // it can pair — an inner row it rejects joins to nothing.
      if let filter,
          try evaluate(filter, right, routines, bindings) != true { continue }
      // Equal by the SAME rule the predicate uses — integer/integer exact,
      // mixed integer/double promoted — so a seek that scanned wide still pairs
      // exactly.
      if matches(value, .equal, right[slot]) == true {
        records.append(left.merged(with: right))
      }
    }
  }
  return records
}

/// The hash equi-join of `outer` against `inner`: the inner scanned once into a
/// value → records map keyed on its join column, then each outer record probed
/// in O(1).
///
/// The inner is materialised over `ordinals` into standalone slots, its key the
/// slot `keys.right - base`; a NULL-keyed inner record joins to nothing and is
/// never bucketed. Each bucket keeps its rows in cursor order, so probing an
/// outer record in outer order yields the same outer-major, inner-cursor-order
/// result the seek path does. An outer NULL key probes nothing.
///
/// A pushed inner `filter` (in the inner's standalone slot space) is applied
/// DURING this scan, before a row is bucketed: the inner is SEEKED by the
/// filter's seekable conjunct — `Engine.boundaries` over each conjunct, the same
/// boundary logic the scan seek uses, mapping a slot back to its table column
/// through `ordinals` — so a seekable/contradictory inner filter reads few or no
/// inner rows rather than scanning the whole table; when no conjunct is seekable
/// the whole inner scans. Each read row is then admitted only when the whole
/// `filter` holds, so a filtered inner row is never bucketed or paired.
///
/// An outer with no non-null key has no probe that can match — an empty outer
/// has no probes at all, and a NULL key joins to nothing — so no match can
/// result; return before scanning and bucketing the inner rather than reading
/// every inner row to answer nothing. The nested-loop path this replaces read
/// zero inner rows for such an outer, and a selective or contradictory outer
/// WHERE (`… WHERE key IS NULL`, or one pruning every row) must not force a full
/// scan of a large unseekable inner.
private func hashed<T: Table & ~Escapable>(_ outer: Array<Record>,
                                           _ inner: borrowing T,
                                           _ ordinals: Array<Int>, _ base: Int,
                                           _ keys: (left: Int, right: Int),
                                           _ filter: Filter?,
                                           _ routines: Routines,
                                           _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  guard outer.contains(where: {
    if case .null = $0[keys.left] { false } else { true }
  }) else { return [] }

  let cursor = inner.cursor()
  let slot = keys.right - base
  // Seek the inner by the pushed filter's seekable conjunct, so a
  // seekable/contradictory inner filter reads few or no rows; scan the whole
  // inner when the filter has none (or when there is no filter).
  let range = seek(filter, ordinals, inner, cursor.count, bindings)
  var buckets = Dictionary<Value, Array<Record>>()
  for index in range {
    guard let row = cursor.row(index) else { continue }
    let right = Record(row, ordinals)
    // Apply the whole pushed filter before bucketing — a filtered inner row is
    // never a join candidate.
    if let filter,
        try evaluate(filter, right, routines, bindings) != true { continue }
    if case .null = right[slot] { continue }
    buckets[bucket(right[slot]), default: Array<Record>()].append(right)
  }

  var records = Array<Record>()
  for left in outer {
    let value = left[keys.left]
    if case .null = value { continue }
    // Probe the bucket, then confirm each candidate with the exact `matches`
    // equality — the bucket over-groups (two distinct large integers can share
    // a `Double` bucket), so the residual check keeps integer/integer exact.
    for right in buckets[bucket(value)] ?? []
        where matches(value, .equal, right[slot]) == true {
      records.append(left.merged(with: right))
    }
  }
  return records
}

/// The equi-join of `outer` against a fully materialised `inner` record set:
/// for each outer record whose `keys.left` value is non-NULL, every inner row
/// whose `keys.right` slot (`keys.right - base` in the standalone inner record)
/// equals it, the pair concatenated. The plain nested-loop a CTE inner takes.
private func joined(_ outer: Array<Record>, _ inner: Array<Record>,
                    _ base: Int, _ keys: (left: Int, right: Int))
    -> Array<Record> {
  let slot = keys.right - base
  var records = Array<Record>()
  for left in outer {
    let value = left[keys.left]
    if case .null = value { continue }
    // The same exact/promoted equality the predicate and the other join paths
    // use — integer/integer exact, mixed integer/double promoted.
    for right in inner where matches(value, .equal, right[slot]) == true {
      records.append(left.merged(with: right))
    }
  }
  return records
}

/// The inner row range the hash join scans and buckets: the `[lower, upper)`
/// seeked by `filter`'s first seekable conjunct — `Engine.boundaries` over each,
/// mapping a slot to its table column through `ordinals` — else the whole
/// `0 ..< count` when no conjunct qualifies (or there is no filter).
private func seek<T: Table & ~Escapable>(_ filter: Filter?,
                                         _ ordinals: Array<Int>,
                                         _ inner: borrowing T, _ count: Int,
                                         _ bindings: Bindings) -> Range<Int> {
  guard let filter else { return 0 ..< count }
  for conjunct in filter.conjuncts {
    if let range =
        Engine.boundaries(conjunct, ordinals, inner, count, bindings) {
      return range
    }
  }
  return 0 ..< count
}

/// Whether the inner `column` of `table` can be seeked — the executor probes it
/// per outer record — as opposed to needing a hash build.
///
/// A seekable column reports a boundary for a valid key; an unseekable one
/// reports `nil`. The probe key must be a VALID one: a decoded coded-index join
/// key is 1-based and reports `nil` for the null reference `0`, so probing with
/// `0` would misclassify a seekable coded-index column as unseekable and force a
/// hash build even for a selective join. `1` — the least valid key — answers for
/// every seekable column (`Id`, an owner foreign key, a sorted key, a
/// coded-index key); its value is otherwise irrelevant, since this is only a
/// capability check (the join loop seeks with the real outer key).
private func seekable<T: Table & ~Escapable>(_ table: borrowing T,
                                             _ column: Int) -> Bool {
  table.bound(column, 1, strict: false) != nil
}

/// The inner range to probe for `value` on `column` of `table` of `count` rows:
/// the seeked `[lower, upper)` run when `value` is an integer on a seekable
/// column, else the whole `0 ..< count` to scan.
private func probe<T: Table & ~Escapable>(_ table: borrowing T, _ column: Int,
                                          _ value: Value, _ count: Int)
    -> Range<Int> {
  guard case let .integer(key) = value,
      let lower = table.bound(column, key, strict: false),
      let upper = table.bound(column, key, strict: true) else {
    return 0 ..< count
  }
  return lower ..< upper
}

/// Orders two typed sort keys ascending, by their value.
///
/// `NULL` sorts before every non-null value — consistently first in ascending
/// order, last in descending — so a nullable sort key holds a stable, total
/// position rather than tying with every value (which is not a strict ordering
/// and leaves the rest unsorted). Otherwise both keys share a `Value` kind, as
/// they are read from the same slot, and compare by value; a kind mismatch a
/// single-slot key never produces orders as equal.
internal func less(_ lhs: Value, _ rhs: Value) -> Bool {
  switch (lhs, rhs) {
  case (.null, .null): false
  case (.null, _): true
  case (_, .null): false
  case let (.integer(lhs), .integer(rhs)): lhs < rhs
  case let (.double(lhs), .double(rhs)): lhs < rhs
  // A mixed integer/double key is numeric and ordered by magnitude — but
  // EXACTLY, not via a lossy `Double(integer)`. Past 2^53 a promotion ties a
  // double with two distinct integers that themselves order exactly, which
  // would make this comparator non-transitive (not a strict weak ordering);
  // the exact form breaks the tie by the integer the double denotes.
  case let (.integer(lhs), .double(rhs)): less(integer: lhs, double: rhs)
  case let (.double(lhs), .integer(rhs)): less(double: lhs, integer: rhs)
  case let (.text(lhs), .text(rhs)): lhs < rhs
  case let (.boolean(lhs), .boolean(rhs)): !lhs && rhs
  case let (.blob(lhs), .blob(rhs)): lhs.lexicographicallyPrecedes(rhs)
  default: false
  }
}

/// Whether integer `lhs` is strictly less than double `rhs`, compared EXACTLY.
/// `Double(lhs) < rhs` decides it unless the two tie under promotion — then
/// `rhs` is a whole double equal to `Double(lhs)`. If it denotes an exact `Int`
/// the integers compare directly, so a value past 2^53 orders by its true
/// magnitude; if it does not (`Double(Int.max)` rounds to 2^63, past `Int`),
/// `rhs` lies outside `Int` — positive here, so `lhs < rhs` — never a false tie
/// leaving the pair unordered.
private func less(integer lhs: Int, double rhs: Double) -> Bool {
  let promoted = Double(lhs)
  guard promoted == rhs else { return promoted < rhs }
  guard let exact = Int(exactly: rhs) else { return rhs > 0 }
  return lhs < exact
}

/// Whether double `lhs` is strictly less than integer `rhs`, compared EXACTLY —
/// the mirror of `less(integer:double:)`. An out-of-`Int` tie means `lhs` lies
/// outside `Int`, so its sign decides: a positive `lhs` (past `Int.max`) is not
/// less than any `Int`.
private func less(double lhs: Double, integer rhs: Int) -> Bool {
  let promoted = Double(rhs)
  guard lhs == promoted else { return lhs < promoted }
  guard let exact = Int(exactly: lhs) else { return lhs < 0 }
  return exact < rhs
}
