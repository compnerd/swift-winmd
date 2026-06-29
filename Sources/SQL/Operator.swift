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
  /// τ — orders the records by a typed key on `slot`.
  case sort(slot: Int, ascending: Bool, Plan)
  /// × — every concatenation of an outer record with an inner one.
  case product(Plan, Plan)
  /// ⋈ — for each outer record, seeks the inner relation `name` on
  /// `keys.right == outer[keys.left]` and concatenates each match. `keys.left`
  /// and `keys.right` are combined-space slots, `base` the inner's first slot
  /// in that combined space, and `column` the inner ordinal `keys.right` reads
  /// (for the seek `bound`).
  case join(Plan, name: String, ordinals: Array<Int>, base: Int,
            column: Int, keys: (left: Int, right: Int))
}

// MARK: - Interpreter

/// Interprets `plan` against `catalog`, producing its result records.
///
/// Each operator transforms the records its sub-plan yields: `scan` re-resolves
/// the relation by name, opens its cursor, and materialises its referenced
/// ordinals over the seek range into dense slots; `select` keeps the admitted
/// records; `project` rebuilds each from the projected slots; `sort` orders them
/// by a typed key, stably and in the requested direction; `product` pairs every
/// outer record with every inner one; `join` re-resolves the inner relation,
/// seeks it per outer record, and concatenates the matches. The catalog is
/// borrowed throughout — a `~Escapable` source is never copied or stored.
internal func execute<C: Catalog & ~Escapable>(_ plan: Plan,
                                               _ catalog: borrowing C,
                                               _ routines: Routines,
                                               _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  switch plan {
  case let .scan(name, ordinals, seek):
    try materialise(name, ordinals, seek, catalog)
  case let .derived(_, source, ordinals, seek):
    try derive(source, ordinals, seek, catalog, routines, bindings)
  case let .select(filter, source):
    try admitted(execute(source, catalog, routines, bindings), filter,
                 routines, bindings)
  case let .project(terms, source):
    try execute(source, catalog, routines, bindings)
      .map { record throws(SQLError) in try project(terms, record, routines) }
  case let .sort(slot, ascending, source):
    try execute(source, catalog, routines, bindings)
      .enumerated()
      .sorted { lhs, rhs in
        let ordered = less(lhs.element[slot], rhs.element[slot])
        let reverse = less(rhs.element[slot], lhs.element[slot])
        // A stable sort: keep the source order within an equal-key group by
        // tie-breaking on the original index.
        if ordered == reverse { return lhs.offset < rhs.offset }
        return ascending ? ordered : reverse
      }
      .map(\.element)
  case let .product(outer, inner):
    try product(execute(outer, catalog, routines, bindings),
                execute(inner, catalog, routines, bindings))
  case let .join(outer, name, ordinals, base, column, keys):
    try join(execute(outer, catalog, routines, bindings), name, ordinals,
             base, column, keys, catalog)
  }
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

/// Re-resolves `name` against `catalog`, opens its cursor, and materialises the
/// referenced `ordinals` of the seek's row range (the whole relation when
/// `nil`) into dense slot `Record`s.
///
/// - Throws: `SQLError.relation` if the name no longer resolves.
private func materialise<C: Catalog & ~Escapable>(_ name: String,
                                                  _ ordinals: Array<Int>,
                                                  _ seek: Range<Int>?,
                                                  _ catalog: borrowing C)
    throws(SQLError) -> Array<Record> {
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
private func derive<C: Catalog & ~Escapable>(_ plan: Plan,
                                             _ ordinals: Array<Int>,
                                             _ seek: Range<Int>?,
                                             _ catalog: borrowing C,
                                             _ routines: Routines,
                                             _ bindings: Bindings)
    throws(SQLError) -> Array<Record> {
  let rows = try execute(plan, catalog, routines, bindings)
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

/// The index-nested-loop equi-join of `outer` against the inner relation `name`.
///
/// The inner relation is re-resolved through `catalog`. For each outer record,
/// the value at slot `keys.left` is the probe. When that value is an integer
/// and the inner reports `column` (the inner ordinal `keys.right` reads)
/// seekable, the inner is seeked to its `[lower, upper)` run; otherwise the
/// whole inner is scanned. Each candidate is materialised over the referenced
/// `ordinals` into inner slots `0 ..< ordinals.count`, then re-tested for the
/// inner's `keys.right` slot — `keys.right - base` in the standalone inner
/// record — equal to `value`, the seek narrowing the scan but the equality
/// being the join's truth, and a match is concatenated (the inner's slots
/// landing at `base` in the combined space).
///
/// - Throws: `SQLError.relation` if the inner name no longer resolves.
private func join<C: Catalog & ~Escapable>(_ outer: Array<Record>,
                                           _ name: String,
                                           _ ordinals: Array<Int>, _ base: Int,
                                           _ column: Int,
                                           _ keys: (left: Int, right: Int),
                                           _ catalog: borrowing C)
    throws(SQLError) -> Array<Record> {
  guard let inner = catalog.table(named: name) else { throw .relation(name) }
  let cursor = inner.cursor()
  let slot = keys.right - base
  var records = Array<Record>()
  for left in outer {
    let value = left[keys.left]
    // A NULL key equi-joins to nothing — NULL is unequal to every value,
    // itself included — so it contributes no pair and need not probe.
    if case .null = value { continue }
    let range = probe(inner, column, value, cursor.count)
    for index in range {
      guard let row = cursor.row(index) else { continue }
      let right = Record(row, ordinals)
      if right[slot] == value {
        records.append(left.merged(with: right))
      }
    }
  }
  return records
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
  case let (.text(lhs), .text(rhs)): lhs < rhs
  default: false
  }
}
