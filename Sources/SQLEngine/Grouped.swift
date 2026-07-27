// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Grouped scope

/// The grouped slot space of an aggregate query — the lowering surface for the
/// projection, `HAVING`, and `ORDER BY` that read a grouped record.
///
/// An `aggregate` node yields grouped records whose slots are the `GROUP BY`
/// key values (slots `0 ..< keys.count`, in key order) followed by the
/// aggregate results (slot `keys.count + j` is aggregate `j`). A `Grouped`
/// lowers a name-addressed AST expression into that space: an aggregate call
/// maps to its result slot; a bare column maps to its key slot ONLY when it is
/// a `GROUP BY` key — the standard rule that a non-aggregated column must
/// appear in the `GROUP BY` (else `SQLError.grouping`). It also records each
/// projected item's output name so an `ORDER BY` may name a projection alias,
/// the standard way to order on an aggregate (`ORDER BY <count-alias>`).
///
/// The keys and aggregates resolve against the underlying `Scope`, so the same
/// combined-ordinal resolution the source uses decides which projection columns
/// are keys.
///
/// For one arm of an expanded `GROUPING SETS`, `superset` carries the lowered
/// terms of the UNION of every set's keys. A non-key column whose lowered term
/// is in the superset is a super-aggregate NULL (a grouping column another set
/// groups on but this arm does not) — `term` returns a typeless-NULL slot for
/// it instead of faulting `.grouping`, so a projected/HAVING/ORDER-BY reference
/// to it NULLs by resolved identity (`n.A` ≡ `A`, case-insensitively), not raw
/// AST. It is empty for an ordinary grouped query, whose every non-key column
/// still faults.
internal struct Grouped {
  private let scope: Scope

  /// Each bare-column `GROUP BY` key's combined base ordinal mapped to its
  /// grouped slot — key `i` sits at grouped slot `i`. A general (non-column)
  /// key holds no ordinal entry; it matches by expression through
  /// `expressions` instead.
  private let keys: Dictionary<Int, Int>

  /// Each `GROUP BY` key's lowered base-ordinal term, in key order — key `i`
  /// sits at grouped slot `i`. A projection/`HAVING`/`ORDER BY` expression that
  /// lowers to a term equal to a key's is that key, so a general (non-column)
  /// key matches a semantically-identical reference whose AST differs only by
  /// qualification or case (`Orders.Amount + 1` vs `Amount + 1`), and a bare
  /// `NATURAL`/`USING` merged column — which lowers to a `COALESCE(left,
  /// right)` term with no single ordinal, the group key AND every bare
  /// reference to it — groups and projects as one value, matched by term
  /// rather than the raw AST or an ordinal a merged column lacks.
  private let terms: Array<Term>

  /// The lowered terms of the union of every set's keys, for one arm of an
  /// expanded `GROUPING SETS` — the columns another set groups on. A non-key
  /// reference whose lowered term is in here is a super-aggregate NULL (this
  /// arm does not group on it, but another set does), so `term` returns a
  /// typeless-NULL slot rather than faulting `.grouping`. Empty for an ordinary
  /// grouped query.
  private let superset: Array<Term>

  /// The number of `GROUP BY` keys — aggregate `j` sits at grouped slot
  /// `offset + j`, following the key slots.
  private let offset: Int

  /// The query's distinct aggregations, in first-appearance order — aggregate
  /// `j` sits at grouped slot `offset + j`. Deduped by resolved `Aggregation`
  /// (function + resolved argument term), so an aggregate expression's grouped
  /// slot is found by resolving it and matching here — a
  /// qualification-equivalent aggregate (`SUM(Amount)` vs `SUM(Sales.Amount)`)
  /// maps to the same slot.
  private let aggregates: Array<Aggregation>

  /// Each projected item's output name (an alias, else a bare column's name),
  /// lowercased, mapped to its grouped term and its 0-based projection column
  /// — the surface an `ORDER BY` names a projection alias against. The `column`
  /// is the position the name occupies in the select list, so an `ORDER BY`
  /// alias sorts on exactly the output that name introduces even when two items
  /// share one term (two calls to a `deterministic: false` routine) under
  /// distinct aliases — a term-only lookup would collapse to the first column.
  private var aliases: Dictionary<String, (term: Term, column: Int)> = [:]

  /// Output names two or more projected items share, lowercased. An `ORDER BY`
  /// that names one has no single slot to order on — the same ambiguity the
  /// non-grouped `Scope.order` reports for a shared unqualified join column
  /// (`SQLError.ambiguous`) rather than silently picking the last projection.
  private var ambiguous: Set<String> = []

  /// Builds a grouping over `scope` for the `GROUP BY` `columns` (with their
  /// already-lowered base-ordinal `terms`, so a merged column's coalesce term
  /// is matched by term) and the query's distinct `aggregates` (in
  /// first-appearance order — aggregate `j` at grouped slot `columns.count +
  /// j`). The `aggregates` are already deduped by RESOLVED `Aggregation` (see
  /// `group`), so a qualification-equivalent pair is one entry, one slot.
  internal init(_ scope: Scope, _ grouping: Array<Expression>,
                _ terms: Array<Term>,
                _ aggregates: Array<Aggregation>,
                superset: Array<Term> = [],
                subquery: Resolution = .unsupported) throws(SQLError) {
    self.scope = scope
    self.superset = superset
    var keys = Dictionary<Int, Int>(minimumCapacity: grouping.count)
    for index in grouping.indices {
      // A bare-column grouping key a local relation binds maps its combined
      // ordinal to its grouped slot. A bare `NATURAL`/`USING` merged column
      // binds no single ordinal (`find` faults `.ambiguous` over its two
      // physical sides) — its lowered `terms[index]` is a `COALESCE` matched by
      // term, so it takes no ordinal entry, as a general key does. A key none
      // binds is a candidate correlated reference (a LATERAL body grouping
      // on a preceding column): the correlation surface's non-recording
      // `correlated` probe distinguishes it from a genuine unknown column, and
      // it occupies grouped slot `index` as a `.parameter` key (in `group`'s
      // keys array) with no ordinal→slot entry — the projection reads it via
      // the same correlation, never through this key dict. A genuinely unknown
      // column re-throws the `.column` fault; a barred surface diagnoses a
      // bound outer column `.unsupported`. `correlated` records nothing, so it
      // stays idempotent against `group`'s own correlation. A general
      // (non-column) key takes no ordinal entry; it matches by term in `term`.
      guard case let .column(column) = grouping[index],
          column.qualifier == nil ? scope.merges(column.name) == nil : true
      else { continue }
      if let ordinal = try scope.find(column) {
        keys[ordinal] = index
      } else if try subquery.correlated(column) == nil {
        _ = try scope.ordinal(of: column)
      }
    }
    self.keys = keys
    self.terms = terms
    self.offset = grouping.count
    self.aggregates = aggregates
  }

  /// The grouped slot an aggregate `expression` resolves to (an aggregate the
  /// query collected), or `nil` if it is not one. The expression is resolved to
  /// an `Aggregation` — column qualification normalized to a slot — and matched
  /// against the collected aggregations, so `SUM(Amount)` and
  /// `SUM(Sales.Amount)` find the same slot in a single-relation scope.
  private func slot(of expression: Expression, _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Int? {
    guard case .aggregate = expression else { return nil }
    let aggregation = try expression.aggregation(scope, routines,
                                                 subquery: subquery)
    return aggregates.firstIndex(of: aggregation).map { offset + $0 }
  }

  /// Lowers an `expression` to its grouped-space `Term` — the module-visible
  /// entry to the private `term`, so a caller (the `ordered` set-op carrier)
  /// can match an `ORDER BY` key against the projection by resolved identity,
  /// exactly as the grouped `ORDER BY` path does: a projected aggregate and a
  /// qualifier-equivalent sort key (`SUM(Qty)` vs `SUM(s.Qty)`) lower to the
  /// same grouped slot, so the carrier need not compare raw AST.
  internal func resolve(_ expression: Expression,
                        _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    try term(expression, routines, subquery: subquery)
  }

  /// Lowers a scalar `expression` to a grouped-space `Term`.
  ///
  /// An aggregate call maps to its result slot; a literal to a constant; a
  /// `call`/`binary` recurses over its operands; a bare column maps to its key
  /// slot only when it is a `GROUP BY` key, else it is `SQLError.grouping` —
  /// the standard rule.
  private func term(_ expression: Expression,
                    _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    // `GROUPING(a, …)` is a per-arm integer bit-vector decided by this arm's
    // key membership — handled before the general lowering below (which would
    // route it through `scope.term`, faulting `.state`), so it lowers to a
    // `Term.grouping` carrying that value and its cross-arm identity.
    if case let .grouping(arguments) = expression {
      return try grouping(over: arguments, routines, subquery: subquery)
    }
    if case .aggregate = expression,
       let slot = try slot(of: expression, routines, subquery: subquery) {
      return .slot(slot)
    }
    // A bare `NATURAL`/`USING` merged column and a general (non-column) key
    // both match a `GROUP BY` key by lowered `Term`, not raw AST — the
    // scope normalizes qualification and case away, so a projection/`HAVING`/
    // `ORDER BY` expression that is semantically the key matches even when its
    // spelling differs (`Orders.Amount + 1` vs `Amount + 1`, `AMOUNT + 1` vs
    // `Amount + 1`). Lower under the same scope the key lowered under, so a
    // merged column's `COALESCE(left, right)` term (which binds no single
    // ordinal — the group key AND every bare reference are one value) still
    // matches. A right-only row of a `RIGHT`/`FULL` join thus groups by its
    // coalesced value, not a NULL left column.
    //
    // A bare plain column is skipped here and falls to the ordinal path below,
    // which additionally distinguishes a genuine unknown column, a correlated
    // reference (a LATERAL body's `everywhere` seam), and a barred grouped
    // surface — cases a bare merged column and a general expression never
    // reach. A merged column that matches no key faults `.grouping`; a general
    // expression that matches none falls through so its operands are each
    // checked (`Amount + 2` faults on the bare non-key `Amount`). An aggregated
    // expression (`SUM(x) + 1`) is skipped too: `scope.term` faults on an
    // aggregate, so it descends into the switch, which routes each aggregate to
    // its result slot and each key operand to its grouped slot. A
    // GROUPING-bearing expression (`CASE WHEN GROUPING(x) = 1 …`) is skipped
    // for the same reason — `scope.term` faults on the GROUPING it cannot
    // resolve — so it too descends into the switch, where the `.case`/`.binary`
    // arms recurse through this `term` and lower the nested GROUPING to its
    // per-arm constant. A GROUPING can never itself be a `GROUP BY` key, so
    // skipping the key match loses no match.
    let merged = if case let .column(column) = expression {
      column.qualifier == nil && scope.merges(column.name) != nil
    } else {
      false
    }
    let plain = if case .column = expression { !merged } else { false }
    if !plain, !expression.aggregated, !expression.grouping {
      let lowered = try scope.term(expression, routines, subquery: subquery)
      if let index = terms.firstIndex(of: lowered) { return .slot(index) }
      // A reference to a column another set groups on but this arm's set omits
      // is a super-aggregate NULL — matched by lowered term (so `n.A` ≡ `A`,
      // case-insensitively), not raw AST — so it lowers to a typeless-NULL
      // constant rather than faulting. This dissolves the qualified/unqualified
      // and absent-key HAVING findings for a merged/general reference.
      if superset.contains(lowered) { return .constant(.null) }
      if case let .column(column) = expression {
        throw .grouping(column.name)
      }
    }
    switch expression {
    case let .column(column):
      // Resolve the column against this scope's own relations first, mirroring
      // `Scope.term`'s `.column`: a name a local relation binds must be a
      // `GROUP BY` key (the standard grouping rule), else `SQLError.grouping`.
      // A name none binds is a candidate correlated reference — consult the
      // surface, which admits it (a `Term.parameter` the apply binds per outer
      // row) only for a LATERAL body's `everywhere` seam and diagnoses it
      // `.unsupported` on an ordinary barred grouped surface. The final
      // `ordinal(of:)` re-throws the genuine unknown-column `.column` fault,
      // exactly as `Scope.term` does.
      if let ordinal = try scope.find(column) {
        if let slot = keys[ordinal] { return .slot(slot) }
        // A bare column another set groups on but this arm's set omits is a
        // super-aggregate NULL — matched by its lowered term against the
        // superset (so `n.A` ≡ `A`, case-insensitively), not the raw ordinal —
        // else the standard non-grouped fault.
        let lowered = try scope.term(expression, routines, subquery: subquery)
        if superset.contains(lowered) { return .constant(.null) }
        throw .grouping(column.name)
      }
      if let name = try subquery.correlate(column) { return .parameter(name) }
      return try .slot(scope.ordinal(of: column))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, routines, subquery: subquery))
      }
      // Case-fold the routine name to the identifier rule the lookup uses, so
      // equivalent-case calls lower to an identical term (see the primary
      // `term(_:in:_:)`).
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .case(whens, otherwise):
      // Lower each branch's guard and result, and the `ELSE`, against the
      // grouped slot space — a bare column in any of them must be a `GROUP BY`
      // key, an aggregate its result slot, as elsewhere in a grouped
      // expression.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        try branches.append((lower(branch.when, routines, subquery: subquery),
                             term(branch.then, routines, subquery: subquery)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, routines, subquery: subquery)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — over the grouped scope, so the executor
      // coerces the selected branch's value to the advertised column type.
      let type = try scope.derive(whens, otherwise, routines,
                                  subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand against the grouped slot space and attach the target
      // type; the executor converts the evaluated value to it.
      return try .cast(term(operand, routines, subquery: subquery), type)
    case let .coalesce(arguments):
      // Lower each argument to a grouped-space `Term` and hold them in a
      // first-class `Term.coalesce` so each is evaluated once; `type` is the
      // unified argument type (over the grouped scope) the value coerces to.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines, subquery: subquery))
      }
      let type = try scope.derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      // Lower both operands to grouped-space `Term`s and hold them in a
      // first-class `Term.nullif` so each is evaluated once.
      return try .nullif(term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .subquery(query):
      // A scalar subquery is uncorrelated — row-independent, so it needs no
      // `GROUP BY` key — and lowers to a `Term.subquery` reading its collapsed
      // value from the cache, carrying its `Subkey` and single-column type.
      return try subquery.scalar(query)
    case .aggregate:
      // An aggregate reaches here only when it was not collected — an internal
      // inconsistency, since the query gathers every projection/HAVING
      // aggregate.
      throw .state("XX000", "uncollected aggregate")
    case .grouping:
      // GROUPING is resolved to a constant at the top of `term` (before this
      // switch), so it never reaches here — an internal inconsistency if it
      // does.
      throw .state("XX000", "unlowered GROUPING")
    }
  }

  /// The `Term.grouping` `GROUPING(a, …)` yields for this arm — the integer
  /// bit-vector `bits` (one bit per argument, the first the most significant,
  /// `0` for a `GROUP BY` key of this arm's set and `1` for a super-aggregate a
  /// grouping column another set groups on but this arm rolls up) paired with
  /// the `over` identity. It reuses the grouped `term` lowering for the
  /// membership test: an argument returns a key slot (`< offset`) for a present
  /// key, a typeless-NULL constant for a rolled-up one (the superset path), or
  /// faults `SQLError.grouping` for a genuine non-grouping column — which
  /// propagates, as it must. Any other lowering (an aggregate's result slot
  /// `>= offset`, a literal) is not a grouping expression, so it faults.
  ///
  /// In a plain `GROUP BY` (`superset` empty) a key lowers to a `< offset` slot
  /// (bit `0`) and a non-key faults `.grouping`, so every GROUPING is `0` — the
  /// standard result when no column is rolled up.
  ///
  /// The result is a dedicated `Term.grouping`, not a bare constant, so a
  /// carrier can match a query-level `ORDER BY GROUPING(x)` to its projected
  /// column by identity rather than to an unrelated projection sharing this
  /// arm's value (see `Term.grouping`).
  private func grouping(over arguments: Array<Expression>,
                        _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    guard !arguments.isEmpty else {
      throw .state("42601", "GROUPING requires at least one argument")
    }
    // The parser rejects an over-wide GROUPING, but the `Expression.grouping`
    // AST case is public, so a programmatically built query reaches this lowering
    // without a parse. Enforce the representable width here too: the bit-vector
    // is a signed `Int`, one bit per argument, so more than `Int.bitWidth - 1`
    // arguments would shift a rolled-up vector past the sign bit to a negative
    // value. Reject it with the same ISO 54023 (too many arguments) the parser
    // raises, so every public query-construction path agrees.
    guard arguments.count <= Int.bitWidth - 1 else {
      throw .state("54023",
                   "GROUPING supports at most \(Int.bitWidth - 1) arguments")
    }
    var bits = 0
    var identity = Array<Term>()
    identity.reserveCapacity(arguments.count)
    for argument in arguments {
      // Lower through the grouped `term` so a non-grouping COLUMN faults
      // `.grouping` as it would elsewhere; the returned term is not otherwise
      // needed — membership below is decided by the arm-stable base `id`.
      _ = try term(argument, routines, subquery: subquery)
      // The argument's base-scope term is both its cross-arm identity (carried
      // into the `over` payload) and the membership key for the roll-up test. It
      // is the base term, not the grouped lowering: a rolled-up column lowers to
      // the shared super-aggregate `.constant(.null)` — and a rolled-up
      // correlated key to a `.parameter` — so the grouped term identifies
      // neither which column it was nor that it is a key. The base term is the
      // column's arm-stable slot, so two GROUPINGs match by identity iff they
      // report on the same expressions.
      let id = try scope.term(argument, routines, subquery: subquery)
      let bit: Int
      if terms.contains(id) {
        // A `GROUP BY` key present in this arm's set, matched by term against the
        // arm's keys — so a correlated key (a LATERAL body grouping on a
        // preceding-FROM column, which lowers to `Term.parameter` rather than a
        // local key slot) is recognised too, not only a local slot.
        bit = 0
      } else if superset.contains(id) {
        // A super-aggregate: a grouping column another set groups on but this arm
        // omits, so it is rolled up in this result row. Decided by superset
        // membership of the arm-stable `id` alone — not the grouped lowering's
        // `.constant(.null)`, which a rolled-up correlated key never takes (it
        // stays `.parameter`), so an omitted correlated key reports bit 1 rather
        // than faulting. A literal NULL's `id` is in no superset, so it still
        // faults below.
        bit = 1
      } else {
        // A literal (NULL among them), an aggregate's result slot, or any other
        // non-grouping term — not a valid GROUPING argument. A non-grouping
        // column already faulted `.grouping` inside `term` above.
        throw .state("42803",
                     "GROUPING argument must be a GROUP BY expression")
      }
      bits = (bits << 1) | bit
      identity.append(id)
    }
    return .grouping(over: identity, bits: bits)
  }

  /// Records a projected item's output `name` at projection `column` → its
  /// grouped `term`, flagging the name ambiguous if another projected item
  /// already claimed it.
  private mutating func record(_ name: String, _ column: Int, _ term: Term) {
    let key = name.lowercased()
    let entry = (term: term, column: column)
    if aliases.updateValue(entry, forKey: key) != nil { ambiguous.insert(key) }
  }

  /// The grouped-space projected terms, recording each item's output name for
  /// an `ORDER BY` to name.
  ///
  /// A `columns` projection (`SELECT Dept … GROUP BY Dept`) lowers each column
  /// as a grouped term — a `GROUP BY` key, else `SQLError.grouping`. An
  /// `expressions` projection lowers each item's expression and records its
  /// output name (an alias, else a bare column's name) so an `ORDER BY` may
  /// name it — the standard alias ordering on an aggregate. A `SELECT *` has no
  /// well-defined meaning over groups (which columns?), so it faults.
  internal mutating func terms(_ projection: Projection,
                               _ routines: Routines = [:],
                               subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<Term> {
    // A grouped projection is a barred clause position (see `Schema.terms`):
    // the entry bars the seam so it cannot admit a correlated column of this
    // query.
    let subquery = subquery.barred
    switch projection {
    case .all:
      throw .state("0A000",
                   "SELECT * is not allowed with GROUP BY or aggregates")
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for index in columns.indices {
        let term = try term(.column(columns[index]), routines,
                            subquery: subquery)
        terms.append(term)
        record(columns[index].name, index, term)
      }
      return terms
    case let .expressions(items):
      var terms = Array<Term>()
      terms.reserveCapacity(items.count)
      for index in items.indices {
        let term = try term(items[index].expression, routines,
                            subquery: subquery)
        terms.append(term)
        // Record the output name (`Projected.name` — an alias, else a bare
        // column's name) so an `ORDER BY` may name it (the standard alias
        // ordering on an aggregate); a computed item names nothing.
        if let name = items[index].name { record(name, index, term) }
      }
      return terms
    }
  }

  /// Lowers a `HAVING`/predicate to a grouped-space `Filter`.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Filter {
    try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }, subquery: subquery)
  }

  /// The resolved sort keys an `ORDER BY` lowers to in grouped space, major to
  /// minor — each key's ISO `<sort key>` a `Term` over the grouped record's
  /// slots, its direction preserved.
  ///
  /// Each sort key resolves as, in order:
  ///
  /// - `ordinal(n)` — the query's `n`-th projected output column (1-based),
  ///   resolving to that projection item's own grouped-space `Term`
  ///   (`projection[n - 1]`). An `n` outside `1 ... projection.count` faults
  ///   `SQLError.column`.
  /// - `expression(.column(name))` with an unqualified `name` — a projection
  ///   output alias FIRST (the standard alias ordering on an aggregate, `terms`
  ///   recorded these), then a `GROUP BY` key column, both resolving to their
  ///   grouped `Term`. A name two projections share is `SQLError.ambiguous`, as
  ///   the non-grouped `Scope.order` reports for a shared join column.
  /// - Any other `expression(e)` — an arithmetic over aggregates or keys
  ///   (`ORDER BY COUNT(*) * 2`, `ORDER BY SUM(x) DESC`) — lowered through
  ///   `term` into grouped space, so it may name only aggregates and `GROUP BY`
  ///   keys (a bare non-key column faults `SQLError.grouping`).
  ///
  /// Because the `sort` operator now evaluates a `Term` per grouped record
  /// rather than reading one slot, an alias over a computed expression
  /// (`COUNT(*) * 2 AS Doubled`) orders correctly — its recorded grouped term
  /// recomputes from the group's key and aggregate slots — where the slot-only
  /// sort once rejected it.
  ///
  /// `projection` are the query's already-lowered grouped-space projection
  /// terms — the ordinal surface the positional keys resolve against; the alias
  /// and `GROUP BY` surfaces are the `aliases` and `keys` `terms` recorded.
  internal func order(_ order: Order, _ projection: Array<Term>,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // A grouped ORDER BY is barred, as the projection is (see `Schema.order`).
    let subquery = subquery.barred
    var resolved = Array<SortKey>()
    resolved.reserveCapacity(order.keys.count)
    for key in order.keys {
      switch key.sort {
      case let .ordinal(position):
        guard position >= 1, position <= projection.count else {
          throw .column("\(position)")
        }
        resolved.append(SortKey(term: projection[position - 1],
                                ascending: key.ascending,
                                column: position - 1))
      case let .expression(expression):
        if case let .column(reference) = expression,
            reference.qualifier == nil {
          let name = reference.name.lowercased()
          // A name two projections share has no single term to order on —
          // reject it as ambiguous rather than pick the last, matching the
          // non-grouped `Scope.order` fault for a shared unqualified column.
          if ambiguous.contains(name) { throw .ambiguous(reference.name) }
          if let alias = aliases[name] {
            // Order on the recorded projection column the alias occupies, not
            // `firstIndex(of:)` — two items may share a term under distinct
            // aliases, so a term search would collapse to the first column.
            resolved.append(SortKey(term: alias.term, ascending: key.ascending,
                                    column: alias.column))
            continue
          }
        }
        try resolved.append(SortKey(term: term(expression, routines,
                                                subquery: subquery),
                                    ascending: key.ascending, column: nil))
      }
    }
    return resolved
  }
}

// MARK: - Referenced ordinals

extension Filter {
  /// The ordinals this filter reads, accumulated into `ordinals`.
  ///
  /// A `compare` reads both operand terms, a `bound` its left term, a `match`
  /// both columns; the connectives recurse. The engine unions these with the
  /// projection, order, and join keys to materialise exactly the columns a
  /// scan's rows are read through.
  internal func references(into ordinals: inout Set<Int>) {
    switch self {
    case let .compare(lhs, _, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .bound(term, _, _):
      term.references(into: &ordinals)
    case let .match(left, right):
      ordinals.insert(left)
      ordinals.insert(right)
    case let .null(term, _):
      term.references(into: &ordinals)
    case let .membership(operand, elements, _):
      operand.references(into: &ordinals)
      for element in elements {
        element.references(into: &ordinals)
      }
    case let .comparison(lhs, _, rhs):
      for term in lhs { term.references(into: &ordinals) }
      for term in rhs { term.references(into: &ordinals) }
    case let .memberships(lhs, rows, _):
      for term in lhs { term.references(into: &ordinals) }
      for element in rows {
        for term in element { term.references(into: &ordinals) }
      }
    case let .exists(_, correlation, _):
      // A correlated EXISTS reads the enclosing row's cells its inner `WHERE`
      // names — the correlation's `slot` outer ordinals — so those must be
      // materialised for the per-row re-execution (a `bound` source reads a
      // threaded binding, not the outer record). An uncorrelated one names
      // none.
      ordinals.formUnion(correlation.slots)
    case let .within(lhs, _, correlation, _):
      // The left row's terms read ordinals; a correlated subquery also reads
      // the outer `slot` cells its inner `WHERE` names.
      for term in lhs { term.references(into: &ordinals) }
      ordinals.formUnion(correlation.slots)
    case let .quantified(lhs, _, _, _, correlation):
      // As `within`: the left row's terms read ordinals and a correlated
      // subquery reads the outer `slot` cells its inner `WHERE` names.
      for term in lhs { term.references(into: &ordinals) }
      ordinals.formUnion(correlation.slots)
    case let .like(operand, pattern, escape, _):
      operand.references(into: &ordinals)
      pattern.references(into: &ordinals)
      escape?.references(into: &ordinals)
    case let .between(test, lower, upper, _):
      test.references(into: &ordinals)
      lower.references(into: &ordinals)
      upper.references(into: &ordinals)
    case let .distinct(lhs, rhs, _):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .truth(inner, _, _):
      inner.references(into: &ordinals)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .not(operand):
      operand.references(into: &ordinals)
    case let .incomparable(inner):
      inner.references(into: &ordinals)
    }
  }
}
