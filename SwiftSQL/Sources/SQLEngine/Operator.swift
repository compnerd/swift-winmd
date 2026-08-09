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
/// by its catalog name rather than by a `~Escapable` `Table` (an `indirect
/// enum` cannot box a `~Escapable` payload), and carries the ordinals the query
/// actually reads from it. The executor re-resolves a name to a transient
/// table, opens its cursor, and materialises *only the referenced ordinals*
/// into a dense slot array — reals out of the cursor, virtuals (ordinals `>=
/// width`) computed by the `Row`. Slot `i` of the record holds the cell of the
/// scan's `i`th referenced ordinal; the operators address slots, never
/// ordinals, so a record is a dense `Array<Value>` with no gaps and no per-row
/// hashing.

// MARK: - Record

/// A materialised tuple: the uniform row flowing through the operators.
///
/// A `Record` copies an adapter `Row`'s referenced cells out into an escapable,
/// dense slot array, so it conforms to `SQLEngine.Row` (cell-by-slot access)
/// while being free of the borrowed cursor's lifetime. A scan's
/// referenced-ordinal list (in a fixed order) defines a slot for each — slot
/// `i` is that scan's `i`th referenced ordinal — so the engine remaps every
/// ordinal to a slot at compile time and the record is addressed purely by
/// array index: no
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

  /// This record with each cell coerced to the corresponding column `type`
  /// (`Value.coerced` — the ISO numeric widening a set operation applies to its
  /// arms' rows, promoting an `integer` cell to `double` where the unified
  /// column is `double`). A cell whose column type equals its own kind (a
  /// homogeneous set operation) passes through unchanged, so this is a no-op
  /// except at a widening column. `types` matches the record's width (the arm
  /// arity `compile` proved equal).
  internal func coerced(to types: Array<ValueType>) -> Record {
    Record(cells.indices.map { cells[$0].coerced(to: types[$0]) })
  }
}

// MARK: - Plan

/// An escapable, name-holding relational operator tree.
///
/// Every relation a `SELECT` names is held by its catalog name, not by a
/// `~Escapable` `Table`, so the whole tree is a plain escapable `indirect
/// enum`. The leaf `scan` carries the relation name, the ordinals the query
/// reads from it (reals and virtuals, in materialisation order — the order that
/// defines the scan's slots), and an optional seek — the row range to read. The
/// unary operators wrap a sub-plan: `select` keeps the records a `Filter`
/// admits, `project` restricts and reorders to the projected slots, and `sort`
/// orders by a typed key on a slot. `product` is the Cartesian product of two
/// sub-plans (records merged); `join` is the index-nested-loop equi-join that
/// seeks the inner relation per outer record rather than forming the product,
/// the inner named and its referenced ordinals carried for the executor to
/// re-resolve and materialise.
internal indirect enum Plan {
  /// The single-row leaf of a FROM-less `SELECT`: it yields exactly one empty
  /// record (no slots), the row a scalar projection (`SELECT 1 + 1`) computes
  /// its expressions against.
  case single
  /// The ISO `<table value constructor>` leaf — one `Record` per row, each the
  /// row's lowered `Term`s evaluated against the single empty record (as the
  /// `single` leaf's row is) then coerced to the unified column `types`.
  /// `types` is the per-column type unified across the rows (a mixed
  /// integer/double column widening to `double`), one entry per output column;
  /// every row has `types.count` terms (the ISO equal-degree rule the compile
  /// enforces). It is a leaf the pushdown/optimise/decorrelate passes recurse
  /// through unchanged, feeding a query-level `ORDER BY`/`OFFSET`·`FETCH`/
  /// `DISTINCT` carrier.
  case values(rows: Array<Array<Term>>, types: Array<ValueType>)
  /// The known-empty relation of `slots` columns: it yields zero records over
  /// exactly that combined slot width, the shape the optimiser rewrites a
  /// provably constant-false selection into (a `WHERE 1 = 0` admits no row).
  /// `slots` is the width of the subtree the empty replaced, so a downstream
  /// consumer that reads a side's width (`Plan.slots`, the outer/semijoin
  /// NULL-extension) mis-shapes nothing — the schema is preserved, only the
  /// rows are gone. An aggregate over it still yields its degenerate one row
  /// (`COUNT(*)` `0`), since the empty sits below the aggregate as its source.
  case empty(slots: Int)
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
  /// key is a `Term` evaluated against the record (a slot read for a bare
  /// column, but any lowered expression — `a + b`, `UPPER(Name)`, or the
  /// expression the select list's `n`-th item or an aliased item stands for)
  /// and its direction; `keys[0]` is the primary key and each later key orders
  /// only the rows the earlier keys leave equal. The sort is stable, so rows
  /// equal on every key keep their input order. `keys` is never empty.
  case sort(keys: Array<(term: Term, ascending: Bool)>, Plan)
  /// × — every concatenation of an outer record with an inner one.
  case product(Plan, Plan)
  /// ⋈ — for each outer record, seeks the inner relation `name` on `keys.right
  /// == outer[keys.left]` and concatenates each match. `keys.left` and
  /// `keys.right` are combined-space slots, `base` the inner's first slot in
  /// that combined space, and `column` the inner ordinal `keys.right` reads
  /// (for the seek `bound`). `filter` is a single-relation predicate pushed
  /// onto the inner — in the inner's own 0-based standalone slot space —
  /// applied while each inner row is materialised, so an inner row that fails
  /// it is never paired.
  case join(Plan, name: String, ordinals: Array<Int>, base: Int,
            column: Int, keys: (left: Int, right: Int), filter: Filter?)
  /// ⟕/⟖/⟗ — the OUTER join of `left` and `right` on the `on` predicate, in
  /// combined slot space (the left's slots then the right's). Unlike an inner
  /// join, the `on` predicate is NOT distributed into the product or pushed
  /// onto a leaf — it governs matching alone, so an unmatched outer row is
  /// still emitted with the other side NULL-extended. `kind` selects which
  /// side's unmatched rows survive: `left` every left row, `right` every right
  /// row, `full` both — a `.inner` kind never reaches this node (an inner join
  /// lowers to the `select`/`product`/`join` path). The executor runs it as a
  /// nested loop that tracks matches, so it composes with an arbitrary
  /// (non-equi) `on`.
  case outer(Plan, Plan, on: Filter, kind: Join.Kind)
  /// A semijoin of `left` against `right` on the `on` predicate — an existence
  /// test whose output is the LEFT side's slots alone. Unlike an inner or outer
  /// join it neither appends the right's columns nor NULL-extends: it merely
  /// keeps or drops each left row by whether the right holds a match, so a left
  /// row survives with its own width unchanged and its slot geometry preserved.
  /// `on` addresses the combined `left ++ right` slot space (the left's slots
  /// then the right's), so a candidate is merged to evaluate it — but the LEFT
  /// record alone is emitted. `anti` selects the sense: `false` keeps a left
  /// row iff SOME right row makes `on` TRUE (a decorrelated `EXISTS`), `true`
  /// keeps it iff no right row does (a decorrelated `NOT EXISTS`). A left row
  /// emitted at most once regardless of its match count — the semijoin short-
  /// circuits on the first match, never multiplying a left row by the number of
  /// right rows it matches, exactly as `EXISTS` is a decided per-row test. The
  /// decorrelation pass emits it for a top-level correlated `EXISTS`/`NOT
  /// EXISTS` conjunct; the executor runs it as a nested loop (or a hash probe
  /// when `on` carries a straddling equi key), so it composes with an arbitrary
  /// `on`.
  case semijoin(Plan, Plan, on: Filter, anti: Bool)
  /// A correlated APPLY — a `LATERAL` derived table's nested loop. For each
  /// record of the left sub-plan it re-executes the pre-compiled body plan
  /// (looked up by `key` composed with `correlation`, whose `slot` sources bind
  /// from that left record), takes `ordinals` from each produced right record
  /// into the combined space laid after the left's slots, concatenates it onto
  /// the left, and keeps the pair the `on` predicate admits. INNER/CROSS APPLY
  /// (`kind` `.inner`, the only kind emitted): a left record with no surviving
  /// right record is dropped. Unlike a `product`/`outer` the right side is not
  /// a static sub-plan — it re-runs per left row against the correlated
  /// bindings — so the optimiser treats it as an opaque pushdown barrier and
  /// never rebases a conjunct across it.
  case apply(Plan, key: Subkey, correlation: Correlation,
             ordinals: Array<Int>, on: Filter, kind: Join.Kind)
  /// A set operation of `kind` (`UNION`/`INTERSECT`/`EXCEPT`) over the `left`
  /// and `right` sub-plans, both yielding rows of the same width — the result
  /// columns, whose names are the first arm's and whose `types` are unified
  /// across the arms.
  ///
  /// `types` is the per-column unified result type (`ValueType.unified` folded
  /// over the arms — a mixed integer/double column widening to `double`), one
  /// entry per output column. The executor coerces each arm's cells to these
  /// types (`Value.coerced`) before applying the operator, so `SELECT 1 UNION
  /// SELECT 2.5` yields a `double` column `[1.0, 2.5]`. It is computed at
  /// compile — where the arm queries and the resolution scope are in hand —
  /// because this node carries only the sub-plans, not the arm `Query`s the
  /// fold reads. A homogeneous set operation's `types` matches every arm's own
  /// types, so the coercion is a no-op and the result is byte-identical.
  ///
  /// `widened` is the output columns whose unified `types[c]` differs from an
  /// arm's own native projected type — the columns the coercion actually
  /// changes (a `double` unified over an `integer` arm). It is derived at
  /// compile from the unified `types` against each arm's native types and
  /// carried here so the pushdown pass — a pure Plan rewrite with no catalog —
  /// can tell a widened column from a same-typed one without re-typing the
  /// arms. A predicate over a widened column must NOT push below this node into
  /// the arms: an arm evaluates it on the pre-coercion value, but `combine`
  /// coerces only the arm's emitted rows after the arm runs, so the pushed
  /// predicate would test the un-widened type. A predicate over a non-widened
  /// column still pushes (a same-typed `UNION ALL`). Empty for a homogeneous
  /// set operation.
  ///
  /// Without `all` the result is the distinct rows the operator selects — the
  /// rows of either (`UNION`), of both (`INTERSECT`), or of the left not in the
  /// right (`EXCEPT`) — the first occurrence of each kept. With `all` each
  /// operator keeps multiplicity: `UNION ALL` every row of both sides,
  /// `INTERSECT ALL` each common row to the lesser count, `EXCEPT ALL` each
  /// left row beyond the count the right removes. The node is binary and
  /// mirrors the `Query` set-operation tree, so each node honours its own
  /// `kind`/`all`.
  case setop(SetOperation, Plan, Plan, all: Bool, types: Array<ValueType>,
             widened: Set<Int>)
  /// δ — deduplicates its `source`'s rows, keeping the first occurrence of each
  /// distinct whole row and preserving their order (`SELECT DISTINCT`). It sits
  /// above the projection, so it dedups the projected output rows on the same
  /// whole-row key `UNION` uses (`Value` is `Hashable`). The plain `SELECT`
  /// (equivalently `SELECT ALL`) omits it.
  case distinct(Plan)
  /// Γ — groups its `source`'s records by the `keys` terms and folds each
  /// `aggregates` accumulator over every record of a group, yielding one
  /// grouped record per group. The grouped record's slots are the `keys` values
  /// (slots `0 ..< keys.count`, in key order) followed by the aggregate results
  /// (slot `keys.count + j` is `aggregates[j]`), the slot space the projection,
  /// the `HAVING`, and the `ORDER BY` are lowered against. With no `keys` the
  /// whole source is one group — the degenerate `SELECT COUNT(*) FROM T` —
  /// yielding a single grouped record even over an empty source (`COUNT` `0`,
  /// the others NULL). It sits above the WHERE/join chain and below the
  /// projection, so it aggregates the filtered rows and the projection reads
  /// its output.
  case aggregate(keys: Array<Term>, aggregates: Array<Aggregation>, Plan)
  /// ω — computes each `windowings` window function over its `source`'s records
  /// and appends the result as a fresh slot, cardinality-preserving. Unlike the
  /// grouping `aggregate` — which folds a group to one row — a window function
  /// keeps every input row and gives it the function's value for its position
  /// in the window, so the node's output is the source's records widened by one
  /// slot per windowing: slot `source.slots + j` holds `windowings[j]`'s value,
  /// the source's own slots `0 ..< source.slots` passing through unchanged. Each
  /// windowing partitions the records by its own `PARTITION BY` terms, orders
  /// each partition by its own `ORDER BY` keys, and assigns the ranking value;
  /// the several windowings of one query (each with its own `OVER`) are computed
  /// independently over the shared source. It sits above the WHERE/join chain
  /// and below the projection, so the projection reads the appended slots
  /// through a `Windowed`.
  case window(Array<Windowing>, Plan)
  /// A row cap on its `source`'s output: skips the first `offset` records then
  /// takes at most `count` of the rest, in the source's order. It sits over the
  /// sort/select but below the projection, so it caps the ordered rows before
  /// the select list is evaluated — a row outside the page is never projected
  /// (a projection that could throw does not run for it). It neither reorders
  /// nor reshapes the rows, a transparent wrapper the pushdown and optimise
  /// passes recurse through.
  case limit(count: Int?, offset: Int, Plan)
  /// A bounded selection fusing a `sort` with the `limit` directly above it: it
  /// orders its `source` by `keys` (major to minor, each in its own direction —
  /// exactly the `sort` node's semantics), skips the first `offset`, and takes
  /// at most `count` — but selects only the `offset + count` head rows rather
  /// than sorting the whole input, an `O(n log(offset + count))` partial sort
  /// in place of `sort`'s full `O(n log n)`. The optimiser folds a
  /// `limit(count?, offset, sort(keys, source))` into this when `count` is
  /// bounded (`count != nil`); an unbounded `OFFSET` keeps the full sort under
  /// a `limit`. The
  /// retained prefix is byte-identical to `sort` then `limit`: the executor
  /// selects by the same `less` comparator with the same original-index stable
  /// tie-break, so among equal keys the lowest input index wins, exactly the
  /// stable sort's head. It sits where the `limit` sat — over the sort/select
  /// but below the projection — so a row outside the page is never projected.
  case top(keys: Array<(term: Term, ascending: Bool)>, offset: Int,
            count: Int, Plan)
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
    case let .empty(slots):
      // The known-empty relation advertises the width of the subtree it
      // replaced, so a view sub-plan measuring a data-empty body reads its true
      // column count rather than the `select`'s conservative zero.
      slots
    case let .values(_, types):
      // A values leaf's output is one column per unified column type.
      types.count
    case let .project(terms, _):
      terms.count
    case let .setop(_, left, _, _, _, _):
      left.width
    case let .distinct(source):
      // A `distinct` dedups rows without reshaping them, so it is as wide as
      // its source.
      source.width
    case let .limit(_, _, source):
      // A `limit` caps rows without reshaping them, so it is as wide as its
      // source.
      source.width
    case let .top(_, _, _, source):
      // A `top` orders and caps rows without reshaping them, so it is as wide
      // as its source — exactly as the `sort` then `limit` it fuses.
      source.width
    case let .aggregate(keys, aggregates, _):
      // A grouped record is the key values followed by the aggregate results.
      keys.count + aggregates.count
    case let .window(windowings, source):
      // A window node passes its source's rows through and appends one slot per
      // windowing, so it is as wide as its source plus the window results.
      source.width + windowings.count
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
  /// a `join` the sum of its outer side and the inner's referenced ordinals —
  /// so a left-deep chain of products or joins measures correctly, letting the
  /// nest rewrite recurse into a multi-relation chain.
  internal var slots: Int? {
    switch self {
    case .single:
      // The single empty row has no slots — a FROM-less projection reads only
      // constants and calls over them, never a slot of this row.
      0
    case let .values(_, types):
      // A values leaf yields one slot per unified column, so a downstream
      // consumer that reads its width shapes correctly.
      types.count
    case let .empty(slots):
      // The known-empty relation spans exactly the slots of the subtree it
      // replaced — it drops the rows, never the schema — so a downstream join's
      // NULL-extension width and a product's slot boundary stay correct.
      slots
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
    case let .outer(left, right, _, _):
      // An outer join lays the right's slots after the left's, exactly as a
      // product does — the NULL-extended side still occupies its slots.
      if let left = left.slots, let right = right.slots {
        left + right
      } else {
        nil
      }
    case let .semijoin(left, _, _, _):
      // A semijoin is an existence test: it keeps or drops each left row but
      // appends nothing, so it spans exactly the left side's slots.
      left.slots
    case let .apply(left, _, _, ordinals, _, _):
      // An apply lays the lateral body's taken `ordinals` after the left's
      // slots, exactly as a product lays a scan's referenced ordinals.
      left.slots.map { $0 + ordinals.count }
    case let .setop(_, left, _, _, _, _):
      // Both sides yield rows of the same width — the result columns — so the
      // set operation's width is its left side's.
      left.slots
    case let .distinct(source):
      // A `distinct` dedups rows without reshaping them, so it spans the same
      // slots as its source.
      source.slots
    case let .limit(_, _, source):
      // A `limit` caps rows without reshaping them, so it spans the same slots
      // as its source.
      source.slots
    case let .aggregate(keys, aggregates, _):
      // A grouped record reshapes its source into the key values followed by
      // the aggregate results — a fresh slot space of that width.
      keys.count + aggregates.count
    case let .window(windowings, source):
      // A window node preserves its source's rows and appends one slot per
      // windowing, so the next relation's slots begin past the source's own
      // width plus the window results.
      source.slots.map { $0 + windowings.count }
    case let .project(terms, _):
      // A projection's output is exactly its projected terms, so the next
      // relation's slots begin at `terms.count` — regardless of the source's
      // width. A decorrelated CROSS APPLY tops out in a `project`, so this is
      // what lets it measure correctly as the left side of an outer join.
      terms.count
    case let .sort(_, source):
      // A `sort` reorders rows without reshaping them, so it spans the same
      // slots as its source.
      source.slots
    case let .top(_, _, _, source):
      // A `top` orders and caps rows without reshaping them, so it spans the
      // same slots as its source — exactly as the `sort`/`limit` it fuses.
      source.slots
    }
  }

  /// This plan capped by `limit` — wrapped in a `limit` operator when one is
  /// present, else returned unchanged. `shape` caps the sorted/selected rows
  /// with this and then projects, so the cap sits below the projection.
  internal func capped(limit: Limit?) -> Plan {
    guard let limit else { return self }
    return .limit(count: limit.count, offset: limit.offset, self)
  }

  /// Whether executing this plan cannot throw — the throw-freedom the optimiser
  /// needs before it may rewrite a constant-false `select` OVER this plan into
  /// `.empty`, discarding the plan unexecuted. Executing `select(false, child)`
  /// today runs `child` (which may raise — a throwing scalar term, a `SUM`
  /// overflow, a subquery fault) and only then filters every row out; folding
  /// to `.empty` skips `child`, so it is sound ONLY when `child` raises on no
  /// input, i.e. is `safe`. This is the plan-level analogue of
  /// `Filter.safe`/`Term.safe` and is deliberately conservative: a shape whose
  /// throw-freedom is not certain (a `derived` view body, any
  /// join/apply/aggregate) reports `false`, so the fold is merely missed —
  /// never unsound. Under-folding costs a per-row
  /// predicate; over-folding would suppress a raise, so doubt resolves to
  /// `false`.
  internal var safe: Bool {
    switch self {
    case .single, .empty:
      // A single empty row and the known-empty relation both yield their rows
      // without evaluating anything — neither can raise.
      true
    case let .values(rows, _):
      // Each row's terms evaluate over the empty record, so a values leaf is
      // throw-free only when every term is (a constant row is; a `1 / 0` row is
      // not).
      rows.allSatisfy { $0.allSatisfy(\.safe) }
    case .scan:
      // A scan reads cells and never evaluates an expression, so materialising
      // it cannot raise; a compiled plan's scan name is already resolved.
      true
    case let .select(filter, source):
      // The per-row predicate and everything below it must be throw-free.
      filter.safe && source.safe
    case let .project(terms, source):
      // Every projected term is evaluated per row, so all must be safe.
      terms.allSatisfy(\.safe) && source.safe
    case let .sort(keys, source):
      // Each sort key's term is evaluated per row before the comparison.
      keys.allSatisfy { $0.term.safe } && source.safe
    case let .product(left, right):
      left.safe && right.safe
    case let .setop(_, left, right, _, _, _):
      // Combining rows never raises, so it is safe when its arms are.
      left.safe && right.safe
    case let .distinct(source):
      source.safe
    case let .limit(_, _, source):
      source.safe
    case let .top(keys, _, _, source):
      // Each sort key's term is evaluated per row before the selection, exactly
      // as the fused `sort` evaluates it — so every key term and the source
      // must be throw-free.
      keys.allSatisfy { $0.term.safe } && source.safe
    // A `derived` view body runs an arbitrary sub-plan (and augments/validates
    // its schema); a `join`/`outer`/`semijoin`/`apply` evaluates an `on`,
    // seeks, or re-executes a correlated body; an `aggregate` may overflow a
    // `SUM` or type-fault a `MIN`/`MAX`; a `window` evaluates a partition/order
    // term per row. None is provably throw-free here, so each reports `false` —
    // the fold is missed, never unsound.
    case .derived, .join, .outer, .semijoin, .apply, .aggregate, .window:
      false
    }
  }

  /// Whether this plan provably yields no two equal FULL rows — every output
  /// record distinct across ALL its columns — the uniqueness the optimiser
  /// needs before it may DROP a `.distinct` over this plan (a redundant dedup).
  /// This is the deduplication analogue of `safe` and is deliberately
  /// conservative: a shape whose full-row distinctness is not certain reports
  /// `false`, so the `.distinct` is merely kept — never unsound. Over-claiming
  /// here would leak duplicates (wrong results); under-claiming costs one extra
  /// dedup, so doubt resolves to `false`.
  internal var unique: Bool {
    switch self {
    case .single, .empty:
      // A single empty row and the known-empty relation yield 0 or 1 row — at
      // most one row is trivially distinct from itself.
      return true
    case .distinct:
      // A `distinct` deduplicates its source's whole rows, so its output holds
      // no duplicate — the DISTINCT-of-DISTINCT collapse.
      return true
    case let .setop(_, _, _, all, _, _):
      // Without `all` the set operator (UNION/INTERSECT/EXCEPT) dedups its
      // result to distinct rows; `all` (UNION ALL, …) is a multiset that keeps
      // duplicates, so it is NOT unique.
      return !all
    case .aggregate:
      // A grouped aggregate emits one row per distinct group-key combination —
      // the key values are a prefix of each output record, so two output rows
      // differ in those key slots and the full rows are distinct. A no-GROUP-BY
      // aggregate emits exactly one row (its degenerate group), trivially
      // distinct. (`grouped` keys each group on its canonical key cells and
      // appends the aggregates, emitting one record per group.)
      return true
    case let .select(_, source):
      // A selection drops rows (never duplicates one), so it preserves the
      // source's full-row distinctness.
      return source.unique
    case let .limit(_, _, source):
      // A limit skips/caps rows without duplicating one, so it preserves the
      // source's distinctness.
      return source.unique
    case let .sort(_, source):
      // A sort reorders rows without duplicating one, so it preserves the
      // source's distinctness (which ignores row order).
      return source.unique
    case let .top(_, _, _, source):
      // A top orders and caps rows without duplicating one, so it preserves
      // the source's distinctness — exactly as the sort/limit it fuses.
      return source.unique
    case let .window(_, source):
      // A window node passes every source row through and appends a computed
      // slot, so two source rows that already differ still differ (the extra
      // column cannot collapse them); it preserves the source's distinctness.
      return source.unique
    case let .project(terms, source):
      // A projection preserves full-row distinctness ONLY when it is an
      // injective map of the source's whole row: two distinct source rows must
      // stay distinct. That holds when every term is a bare slot read and the
      // read slots cover every source slot (`0 ..< source.slots`) — then the
      // projected row retains all source columns (reordered/renamed, possibly
      // duplicated), so two source rows differing in ANY column still differ in
      // its retained copy. Dropping a source column, computing an expression,
      // or an unknown source width could collapse distinct rows to an equal
      // output, so each of those keeps the projection non-unique. (In practice
      // a `.distinct` always sits over a `.project`, so this arm decides it.)
      guard let width = source.slots, source.unique else { return false }
      var covered = Set<Int>()
      for term in terms {
        guard case let .slot(slot) = term else { return false }
        covered.insert(slot)
      }
      return covered == Set(0 ..< width)
    // A base `scan` is an ISO multiset (a duplicate row is possible, no unique
    // key is tracked); a `values` leaf likewise keeps duplicate rows (`VALUES
    // (1), (1)`); a `derived` view body runs an arbitrary sub-plan; a
    // `product`/`join`/`outer`/`apply` can multiply rows (a fan-out pairs one
    // row with many). None provably yields distinct full rows, so each reports
    // `false` — the `.distinct` stays, never unsound. A `semijoin` emits each
    // left row at most once but does not deduplicate the left, so it is only as
    // unique as its left source and is conservatively `false` here.
    case .scan, .values, .derived, .product, .join, .outer, .semijoin, .apply:
      return false
    }
  }
}
