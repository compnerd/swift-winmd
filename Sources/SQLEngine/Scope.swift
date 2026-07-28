// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Schema {
  /// The ordinal of the column `column` names, validating its qualifier against
  /// `relation`.
  ///
  /// A single-relation query has one relation, so a qualifier — `relation`'s
  /// alias, else its table name — must name it; any other qualifier is
  /// `SQLError.column`, as a join rejects a qualifier naming neither side.
  internal func ordinal(of column: Column, in relation: Relation)
      throws(SQLError) -> Int {
    if let qualifier = column.qualifier,
        (relation.alias ?? relation.name) != qualifier {
      throw .column(column.name)
    }
    guard let ordinal = ordinal(of: column.name) else {
      throw .column(column.name)
    }
    return ordinal
  }

  /// The ordinal `column` resolves to in `relation`, or `nil` when it is a
  /// candidate correlated reference to an enclosing scope — this relation does
  /// not name it — the not-found probe the single-relation `.column` lowering
  /// consults before correlating outward.
  ///
  /// The two not-found situations `ordinal(of:in:)` conflates as `.column` are
  /// distinguished here. A qualifier this relation does NOT answer (its alias,
  /// else its name), or an unqualified name it does not carry, is a genuine
  /// not-found → `nil`, so the walk correlates to the outer query. But a
  /// qualifier this relation does answer, naming a column it lacks, is a hard
  /// `SQLError.column` that propagates: the local alias shadows a same-named
  /// outer relation, so the miss faults against the inner relation rather than
  /// falling through to bind the outer one. This is the single-relation analog
  /// of `Scope.find`.
  internal func find(_ column: Column, in relation: Relation)
      throws(SQLError) -> Int? {
    if let qualifier = column.qualifier,
        (relation.alias ?? relation.name) != qualifier {
      return nil
    }
    guard let ordinal = ordinal(of: column.name) else {
      guard column.qualifier == nil else { throw .column(column.name) }
      return nil
    }
    return ordinal
  }

  /// The projected terms of `projection`, addressed by ordinal: a `*` or a
  /// bare-column list yields one `.slot(ordinal)` per column; an expression
  /// list lowers each expression to a term. The terms hold ordinals, which the
  /// engine remaps to slots after gathering the referenced ones.
  internal func terms(_ projection: Projection, in relation: Relation,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<Term> {
    // A projection is a barred clause position: a correlated column of this
    // query has no evaluator here (only WHERE/ON/HAVING admit one). The cut is
    // intrinsic to the entry, so a caller cannot pass an admitting seam into a
    // projection — the FROM-less scalar path included — keeping the run's
    // lowering and the schema `columns(of:)` derive in lockstep.
    let subquery = subquery.barred
    switch projection {
    case .all:
      return (0 ..< width).map { .slot($0) }
    case let .columns(columns):
      // Lower each bare column through `term`, so a name this relation does not
      // bind consults the `subquery` surface: a correlated reference on the
      // barred projection surface is diagnosed unsupported (parity with the
      // schema path) rather than faulting `SQLError.column`.
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(term(.column(column), in: relation, routines,
                              subquery: subquery))
      }
      return terms
    case let .expressions(projected):
      var terms = Array<Term>()
      terms.reserveCapacity(projected.count)
      for item in projected {
        try terms.append(term(item.expression, in: relation, routines,
                              subquery: subquery))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to an ordinal-addressed `Term`: a column to a
  /// `.slot(ordinal)`, a literal to a `.constant`, a call to an `.apply` over
  /// its lowered arguments.
  internal func term(_ expression: Expression, in relation: Relation,
                     _ routines: Routines = [:],
                     subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      // Resolve against this relation first; a name it does not bind is a
      // candidate correlated reference to the enclosing scope, lowered to a
      // synthetic `Term.parameter` when the outer scope binds it, else the
      // ordinary unknown-column fault. A qualified miss on this relation (its
      // alias names it, but the column is absent) is a hard `.column` `find`
      // propagates — never a fall-through to correlate a same-qualifier outer
      // relation, which the local alias shadows.
      if let ordinal = try find(column, in: relation) { return .slot(ordinal) }
      if let name = try subquery.correlate(column) { return .parameter(name) }
      return try .slot(ordinal(of: column, in: relation))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, in: relation, routines,
                                subquery: subquery))
      }
      // Case-fold the routine name to the SQL identifier rule the `Routines`
      // lookup uses (lowercase), so two calls that spell the same routine with
      // different case — `UPPER(x)` and `upper(x)` — lower to an identical
      // `.apply` term. Term identity then agrees with dispatch (which folds on
      // lookup), so the DISTINCT ORDER BY guard's projected-term match, the
      // aggregate dedup, and every other term comparison stay consistent.
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, in: relation, routines,
                                  subquery: subquery),
                         term(rhs, in: relation, routines, subquery: subquery))
    case let .case(whens, otherwise):
      // Lower each branch's guard predicate to a `Filter` and its result to a
      // `Term`, and the `ELSE` to a `Term`, over this relation's resolution.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        let gate = try lower(branch.when, in: relation, routines,
                             subquery: subquery)
        try branches.append((gate, term(branch.then, in: relation, routines,
                                        subquery: subquery)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, in: relation, routines, subquery: subquery)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — so the executor coerces the selected
      // branch's value to the type the schema advertises. Derive it against a
      // one-relation scope, this Schema's own resolution surface.
      let scope = Scope([(relation, self)])
      let type = try scope.derive(whens, otherwise, routines,
                                  subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand and attach the target type; the executor converts the
      // evaluated value to it (`Value.cast(to:)`).
      return try .cast(term(operand, in: relation, routines,
                            subquery: subquery), type)
    case let .coalesce(arguments):
      // Lower each argument to a `Term` over this relation and hold them in a
      // first-class `Term.coalesce` so each is evaluated once. `type` is the
      // unified argument type the selected value coerces to, derived against a
      // one-relation scope.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, in: relation, routines,
                                 subquery: subquery))
      }
      let scope = Scope([(relation, self)])
      let type = try scope.derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      // Lower both operands to `Term`s over this relation and hold them in a
      // first-class `Term.nullif` so each is evaluated once.
      return try .nullif(term(lhs, in: relation, routines, subquery: subquery),
                         term(rhs, in: relation, routines, subquery: subquery))
    case let .subquery(query):
      // A scalar subquery lowers to a `Term.subquery` reading its collapsed
      // value from the run-time cache, carrying its occurrence `Subkey` and
      // single-column type, the single-column arity enforced from the compiled
      // width (no cursor). The query is uncorrelated — it reads no cell here.
      return try subquery.scalar(query)
    case .aggregate:
      // An aggregate has no per-row meaning — it folds over a group — so it may
      // not appear in a `WHERE`, a join `ON`, or a non-aggregate projection.
      throw .state("42803", "an aggregate is not allowed here")
    case .grouping:
      // GROUPING is a grouped-query construct decided by the arm's key
      // membership; it has no meaning in this non-grouped resolution (a scalar
      // projection, WHERE, or join ON), so it faults exactly as an aggregate
      // does. A grouped query lowers it through `Grouped.term` instead.
      throw .state("42803", "GROUPING requires a GROUP BY")
    }
  }

  /// The resolved sort keys an `ORDER BY` lowers to, in major-to-minor order —
  /// each key's ISO `<sort key>` a `Term` over this relation's ordinals, its
  /// direction preserved.
  ///
  /// `projection` are the query's already-lowered projection terms and `names`
  /// their output names, so an ordinal or an output-alias key resolves to the
  /// matching select-list item's `Term` and an ordinary expression key lowers
  /// fresh over this relation (see the free `order`).
  internal func order(_ order: Order, in relation: Relation,
                      _ projection: Array<Term>, _ names: Array<String?>,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // An ORDER BY is barred, as the projection is: a correlated column of this
    // query is out of the cut here, so the entry bars the seam by construction.
    let subquery = subquery.barred
    return try SQLEngine.order(order, projection, names) {
      expression throws(SQLError) in
      try term(expression, in: relation, routines, subquery: subquery)
    }
  }

  internal func lower(_ predicate: Predicate, in relation: Relation,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Filter {
    let filter =
        try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
          try term(expression, in: relation, routines, subquery: subquery)
        }, subquery: subquery)
    // Stamp the comparability classification onto every throwable leaf from
    // this single relation's own ordinal space, so a single-table WHERE's
    // cross-kind conjunct is carried as unsafe into the physical plan and its
    // seek/pushdown cannot bypass the `42804` fault (see `stamped`).
    return stamped(filter) { type(at: $0) }
  }

  /// The declared value type of the column at `ordinal` in this schema — a real
  /// column its own `types` entry, a virtual ordinal (`Id`, a foreign key) the
  /// integral `.integer`, mirroring `Scope.type(at:)` for a single relation so
  /// the comparability stamp reads the same kinds either resolution path does.
  private func type(at ordinal: Int) -> ValueType {
    ordinal < width ? types[ordinal] : .integer
  }
}

// MARK: - Join scope

/// The relations of a join chain, addressed in one combined ordinal space.
///
/// A join chain lays its relations end to end: relation `i` occupies the
/// combined ordinals `[offset_i, offset_i + extent_i)`, where `offset_i` is the
/// sum of the `extent`s of the relations before it. Using each relation's
/// `extent` — its real `width` plus the virtual columns it exposes — rather
/// than its `width` keeps a relation's virtual columns (an `Id`, an owner
/// foreign key) on its own side rather than colliding with the next relation's
/// space. A `Scope` resolves a possibly qualified `SQLEngine.Column` into that
/// combined space so the engine's `Filter`, projection, and order all address
/// cells uniformly across the chain. A qualifier names a relation by its alias,
/// else its table name; an unqualified name resolves against every relation and
/// is ambiguous if more than one resolves it — as is a qualified name two
/// relations share an alias or table name for (a self-join or a duplicated
/// alias). Resolution reads only schemas, so the scope is escapable data over
/// the relations' `Schema`s.
internal struct Scope {

  // MARK: - Members and merged columns

  /// One relation of the chain: its reference (for qualifier matching), its
  /// name-resolution schema, and its base offset in the combined space.
  private struct Member {
    let relation: Relation
    let schema: Schema
    let offset: Int
  }

  /// A `NATURAL`/`USING` merged column (ISO 9075 7.10) — the one common column
  /// a named-column join exposes, belonging to neither side. It has no physical
  /// slot of its own: its `value` is the `COALESCE(left, right)` over the two
  /// physical combined ordinals it merges (each still addressable qualified),
  /// and its `type` the unified coalesce type. A bare (unqualified) reference
  /// to its `name` resolves to `value` — the merged entry shadows its physical
  /// constituents for bare lookup — while a qualified `A.c`/`B.c` never matches
  /// it and reaches its own slot.
  internal struct Merged: Sendable {
    let name: String
    let value: Term
    let type: ValueType
    /// The two physical combined ordinals this merged column coalesces — the
    /// left constituent and the right one — kept so a `SELECT *` drops them
    /// (each is exposed once, via the merged `value`, not twice as itself).
    let constituents: Array<Int>
    /// Whether the merged column places no type constraint — TRUE only when
    /// both constituents were unconstrained (each an all-NULL/placeholder
    /// column), so a `USING` merge of two constant-NULL sides stays a
    /// placeholder that a further enclosing set-operation fold unifies with any
    /// typed arm; FALSE when either side constrained the merged type. The
    /// `unconstrained` bit the set-operation `merge(_:_:)` computes, carried so
    /// a downstream `output(of:)`/correlated read reports it rather than
    /// hard-coding the merged column constrained.
    let unconstrained: Bool

    /// This merged column as an output `ResolvedColumn` — its `type` AND its
    /// `unconstrained` mask carried together, named `name` (the reference's
    /// spelling for a bare `output(of:)`, else the merged column's own `name`
    /// for a `SELECT *`). The single construction both the `SELECT *`
    /// (`outputs`) and the explicit bare `output(of:)` merged-output paths
    /// route through, so neither can drop the mask the other carries.
    internal func resolved(named name: String) -> ResolvedColumn {
      ResolvedColumn(OutputColumn(name: name, type: type),
                     unconstrained: unconstrained)
    }
  }

  private let members: Array<Member>

  /// The `NATURAL`/`USING` merged columns of the join chain, in ISO 7.10 order
  /// — a bare reference to one resolves to its coalesce `value`, and a
  /// `SELECT *` prepends them ahead of the members' remaining physical columns.
  /// Empty for a chain with no named-column join, so an ordinary scope is
  /// unchanged.
  private let merged: Array<Merged>

  /// The physical combined ordinals a merged column subsumes — the union of
  /// every `Merged.constituents` — so a `SELECT *` skips them (each is exposed
  /// once via its merged `value`).
  private let subsumed: Set<Int>

  /// Builds a scope over `relations` — the `FROM` relation first, then each
  /// joined relation in source order — laying each past the previous one's
  /// `extent`, carrying the `NATURAL`/`USING` `merged` columns (empty for a
  /// chain with none).
  internal init(_ relations: Array<(Relation, Schema)>,
                merged: Array<Merged> = []) {
    var members = Array<Member>()
    members.reserveCapacity(relations.count)
    var offset = 0
    for (relation, schema) in relations {
      members.append(Member(relation: relation, schema: schema, offset: offset))
      offset += schema.extent
    }
    self.members = members
    self.merged = merged
    self.subsumed = Set(merged.flatMap(\.constituents))
  }

  /// The merged column named `name` (case-insensitively), or `nil` when none —
  /// the entry a bare reference shadows its two physical constituents with.
  private func merged(_ name: String) -> Merged? {
    let folded = name.lowercased()
    return merged.first { $0.name.lowercased() == folded }
  }

  /// The `NATURAL`/`USING` merged column a bare `name` resolves to (ISO 9075
  /// 7.10), or `nil` when none is merged under that name — the binding
  /// `term`/`derive`/`output(of:)` shadow the two physical sides with.
  ///
  /// The merged column shadows its own constituents, but an addressable column
  /// of the same name a later plain join contributed (`… USING (k) JOIN C …`, C
  /// carrying its own `k`) is NOT a constituent — a bare `k` now names both
  /// the merged column and that other one, so it faults `SQLError.ambiguous`
  /// rather than silently taking the merged value. A qualified `A.k`/`C.k`
  /// never reaches here and stays unambiguous.
  ///
  /// The conflict scan is the FULL addressable surface (`addressable` —
  /// physical AND virtual, the same surface `ordinal(of:)` resolves against),
  /// excluding the merged column's own physical constituents. So a merged `Id`
  /// (a virtual join column) coexisting with a later plain join's own virtual
  /// `Id` faults `.ambiguous` just as a real conflict does — the two axes stay
  /// consistent because neither the merged bare lookup nor the ordinary one
  /// scans a partial surface.
  internal func merged(binding name: String) throws(SQLError) -> Merged? {
    guard let merged = merged(name) else { return nil }
    for ordinal in addressable(Column(name: name))
        where !subsumed.contains(ordinal) {
      throw .ambiguous(name)
    }
    return merged
  }

  /// Whether the real column at `member`'s local `ordinal` is a physical
  /// constituent a merged column subsumes — one a `SELECT *` drops, since the
  /// merged `value` already exposes it once.
  private func subsumed(_ member: Member, _ ordinal: Int) -> Bool {
    subsumed.contains(member.offset + ordinal)
  }

  /// The `NATURAL`/`USING` merged columns, in ISO 7.10 order — the surface the
  /// schema-path `SELECT *`/bare-column resolution (`outputs`/`output(of:)`)
  /// reads to name and type a merged output column, matching the run's `terms`.
  internal var merges: Array<Merged> { merged }

  /// The merged column named `name` (case-insensitively), or `nil` when none —
  /// the probe `Grouped` uses to route a bare merged key to term-matching
  /// rather than the ordinal `keys` map its `find` cannot fill.
  internal func merges(_ name: String) -> Merged? { merged(name) }

  /// Whether the real column at combined `ordinal` is a physical constituent a
  /// merged column subsumes — the schema-path `SELECT *` (`outputs`) drops it.
  internal func subsumes(_ ordinal: Int) -> Bool { subsumed.contains(ordinal) }

  // MARK: - Layout and names

  /// The combined ordinals of the REAL columns a `SELECT *` emits after the
  /// merged block — every relation's real column at its combined ordinal, in
  /// chain order, skipping a physical constituent a merged column subsumes
  /// (each exposed once via its merged `value`). Never a virtual ordinal.
  ///
  /// This is the one walk the `SELECT *` surfaces share, so its length and its
  /// membership cannot drift between them: `terms(.all)` maps each to a
  /// `.slot`, `outputs`/`names` read each column's name and type, and
  /// `width(of: .all)` is `merged.count` plus this count — the width derived
  /// from the same enumeration that emits the columns, not a parallel formula.
  internal var expansion: Array<Int> {
    var ordinals = Array<Int>()
    for member in members {
      for ordinal in 0 ..< member.schema.width
          where !subsumed(member, ordinal) {
        ordinals.append(member.offset + ordinal)
      }
    }
    return ordinals
  }

  /// The visible (unqualified) column names this scope resolves, in chain order
  /// — the `NATURAL`/`USING` merged columns first, then each member's real
  /// column names skipping a physical constituent a merged column subsumes.
  /// This is the LEFT side's output-name list a `NATURAL` join intersects with
  /// the joined-in relation to find its common columns. It reads the one
  /// `expansion` enumeration the `SELECT *` surfaces share, resolving each
  /// combined ordinal back to its owning relation's spelling (`name(at:)`).
  internal var names: Array<String> {
    merged.map(\.name) + expansion.map { name(at: $0) }
  }

  /// The (unqualified) name of the real column at combined `ordinal` — the
  /// reverse of the chain layout, resolving `ordinal` to its owning relation
  /// and that relation's spelling. A combined `ordinal` from `expansion` always
  /// names a real column (`local < width`); the fallback empty string never
  /// arises for an `expansion` ordinal. Shared by `names` and the schema-path
  /// `SELECT *` (`outputs`), so both name the columns `expansion` emits.
  internal func name(at ordinal: Int) -> String {
    for member in members {
      let local = ordinal - member.offset
      if local >= 0, local < member.schema.width {
        return member.schema.names[local]
      }
    }
    return ""
  }

  /// The LEFT-side resolution of a bare join column `name` when building a
  /// `NATURAL`/`USING` merged column: its value `Term`, its `type`, its
  /// `unconstrained` mask, and the physical combined ordinals it stands over.
  ///
  /// The `unconstrained` mask is the constituent'S — an earlier-merged column's
  /// own accumulated bit, else the physical column's `unconstrained(at:)` — so
  /// the `NATURAL`/`USING` type merge honors an all-NULL/placeholder left the
  /// same way the set-operation fold does (a constant-NULL left constrains
  /// nothing, deferring the merged type to the right).
  ///
  /// A name an earlier join already merged resolves to that merged column — its
  /// coalesce `value`, unified `type`, and constituent ordinals — so a chained
  /// `… USING (k)` keys on the merged value (a `RIGHT`/`FULL` join's left-NULL
  /// row still joins), through the FULL ambiguity-aware bare lookup
  /// (`merged(binding:)`): a merged entry that now coexists with a physical
  /// column of the same name a later plain join re-introduced (`… USING (k) …
  /// JOIN C ON … JOIN … USING (k)`, C carrying its own `k`) is ambiguous, so
  /// keying a later `USING` on it faults `SQLError.ambiguous` here rather than
  /// silently taking the merged value and leaving two output columns named `k`.
  /// A name NOT yet merged must resolve to exactly one left physical column
  /// (`ordinal(of:)`); an accumulated-left name bound twice (a plain `ON` join
  /// left two columns of that name) faults `SQLError.ambiguous` here, the
  /// finding-1 trap now a first-class fault at construction rather than a
  /// downstream crash.
  internal func left(_ name: String) throws(SQLError)
      -> (value: Term, type: ValueType, unconstrained: Bool,
          constituents: Array<Int>) {
    if let merged = try merged(binding: name) {
      return (merged.value, merged.type, merged.unconstrained,
              merged.constituents)
    }
    let ordinal = try ordinal(of: Column(name: name))
    return (.slot(ordinal), type(at: ordinal), unconstrained(at: ordinal),
            [ordinal])
  }

  /// The combined-space base offset and extent of each relation, in chain order
  /// — the layout the engine packs referenced ordinals against.
  internal var layout: Array<(offset: Int, extent: Int)> {
    members.map { ($0.offset, $0.schema.extent) }
  }

  /// The relations' name-resolution schemas, in chain order — the surface the
  /// result-schema walk reads each relation's `names`/`types` off for a
  /// `SELECT *`.
  internal var schemas: Array<Schema> {
    members.map(\.schema)
  }

  /// The number of output columns `projection` yields over this scope — the
  /// count the lowered `terms(projection)` array carries, and the range a
  /// 1-based `ORDER BY` ordinal must fall in. A `*` counts the merged columns
  /// plus the real columns the shared `expansion` enumeration emits (never a
  /// virtual column); a bare-column or an expression list is its item count.
  internal func width(of projection: Projection) -> Int {
    switch projection {
    case .all:
      // derived from the one `expansion` walk `terms(.all)`/`outputs` emit —
      // the merged columns plus the real columns it yields — so the width
      // cannot drift from the emitted count. A parallel `schemas.reduce(width)
      // − subsumed.count` arithmetic undercounted when a merged column's
      // constituent was virtual (a fixture/adapter `Id`): the virtual ordinal
      // is in `subsumed` but was never in the real-width sum, so subtracting it
      // dropped a real column that IS emitted.
      return merged.count + expansion.count
    case let .columns(columns):
      return columns.count
    case let .expressions(items):
      return items.count
    }
  }

  /// The value type of the real column at combined `ordinal` — the type the
  /// owning relation's schema types it, for the result-schema walk.
  ///
  /// A combined `ordinal` falls in exactly one relation's `[offset, offset +
  /// extent)` span; a real one (its local index `< width`) reads that schema's
  /// `types`. A virtual ordinal (`Id`, an owner foreign key) is not an ISO
  /// column and carries no schema type, so it reports `.integer` — the identity
  /// and foreign-key columns are integral.
  internal func type(at ordinal: Int) -> ValueType {
    for member in members {
      let local = ordinal - member.offset
      guard local >= 0, local < member.schema.extent else { continue }
      return local < member.schema.width ? member.schema.types[local]
                                         : .integer
    }
    return .integer
  }

  /// Whether the real column at combined `ordinal` is unconstrained — an
  /// all-arms-NULL CTE column that places no type constraint, so a bare
  /// reference to it in a set-operation arm unifies with any typed arm order-
  /// independently (`RelationInstance.unconstrained`). A virtual ordinal
  /// (`Id`, a foreign key) or an out-of-range one carries a genuine type and is
  /// constrained, so it reports `false` — mirroring `type(at:)`'s dispatch.
  internal func unconstrained(at ordinal: Int) -> Bool {
    for member in members {
      let local = ordinal - member.offset
      guard local >= 0, local < member.schema.extent else { continue }
      return local < member.schema.width
          && member.schema.unconstrained[local]
    }
    return false
  }

  // MARK: - Value derivation

  /// The value type of a `literal` operand — the domain of the value it stands
  /// for. Shared by both the schema and type-check surfaces.
  private func type(of literal: Literal) -> ValueType {
    switch literal {
    // A bare `NULL` has no determinate type; the projection walk marks a
    // constant-NULL column `unconstrained` (so it unifies with any typed arm),
    // and this nominal placeholder is only its advertised type where no other
    // arm constrains it — `.integer`, as a result-less `CASE` defaults.
    case .null: .integer
    case .string: .text
    case .integer: .integer
    case .double: .double
    case .boolean: .boolean
    case .blob: .blob
    }
  }

  /// derives the nominal value type a scalar `expression` yields without
  /// faulting on an operand: a bare column its source type, a literal its own,
  /// a standard aggregate its result domain (`COUNT`/`SUM`/`AVG` numeric,
  /// `MIN`/`MAX` the operand's type), a scalar call its routine's declared
  /// return type (`returns`, else the `.integer` default for an unregistered
  /// name), a binary arithmetic expression a numeric result (a double when
  /// either operand is a double, else an integer). It resolves the column
  /// ordinal (so an unknown or ambiguous reference faults as a projection
  /// would) but reads no cursor and never faults on an operand's kind, so a
  /// schema resolves even for an expression a zero-row limit or a short-circuit
  /// makes unreachable (a run never evaluates it, so it cannot fault).
  ///
  /// This is the schema surface. `validate(_:_:)` is the type-check surface: it
  /// faults exactly as a run would on a bad operand or an unknown/misused call.
  internal func derive(_ expression: Expression, _ routines: Routines = [:],
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    return switch expression {
    case let .column(column):
      // A bare name matching a `NATURAL`/`USING` merged column types from the
      // unified coalesce `type` — the merged column has no physical ordinal, so
      // it is typed here rather than via `type(at:)` (a same-named physical
      // column a later plain join added faults `.ambiguous`).
      if column.qualifier == nil,
          let merged = try merged(binding: column.name) {
        merged.type
      } else if let ordinal = try find(column) {
        // A column this scope does not bind may be a correlated reference to an
        // enclosing query (in an inner `WHERE`); type it as the outer column,
        // else the ordinary column fault. A locally ambiguous name is a hard
        // error `find` propagates, never a fall-through to outer correlation.
        type(at: ordinal)
      } else if let resolved = try subquery.correlated(column) {
        resolved.type
      } else {
        try type(at: ordinal(of: column))
      }
    case let .literal(literal):
      type(of: literal)
    case let .call(name, _):
      routines[name]?.returns ?? .integer
    case let .aggregate(function, operand, _, _):
      switch function {
      // `COUNT` always counts rows to an integer; `AVG` folds to a double;
      // `SUM`/`MIN`/`MAX` take the operand's own type (an integer for `.star`).
      case .count: .integer
      case .avg: .double
      case .sum, .min, .max:
        switch operand {
        case .star: .integer
        case let .expression(argument):
          try derive(argument, routines, subquery: subquery)
        }
      }
    case let .binary(.concatenate, lhs, rhs):
      // `||` yields text; the operands' own types do not shape it, but derive
      // both for resolution — an unresolved column faults `SQLError.column`
      // (`Missing || 'x'`) — exactly as the arithmetic `.binary` branch does.
      try concatenation(lhs, rhs, routines, subquery: subquery)
    case let .binary(_, lhs, rhs):
      try [derive(lhs, routines, subquery: subquery),
           derive(rhs, routines, subquery: subquery)].contains(.double)
          ? .double : .integer
    case let .case(whens, otherwise):
      // The result type is the unification of every reachable branch result
      // (and the `ELSE`) — the executor's short-circuit means an unreachable
      // branch (a constant-false guard, or any branch after a constant-true
      // one) never yields a value, so it cannot shape the column's type. The
      // reachable result types must unify; a definitively-irreconcilable clash
      // (text beside an integer) faults `SQLError.operand` here too, so this
      // lowering surface and the faulting `validate` agree. A `CASE` always has
      // at least one `WHEN`; when none is reachable (every guard
      // constant-false, no reachable `ELSE`) the run yields NULL, for which
      // `.integer` is the schema default.
      try derive(whens, otherwise, routines, subquery: subquery)
    case let .cast(operand, type):
      // A cast's static type is the target type; the conversion is nominal, so
      // the operand's own type does not shape it. Derive the operand anyway for
      // its ordinal resolution — an unknown/ambiguous column faults as a
      // projection would.
      try derive(cast: operand, to: type, routines, subquery: subquery)
    case let .coalesce(arguments):
      // The result type is the unification of the arguments (the same
      // `ValueType.unified` reduction a `CASE`'s results take), the type the
      // selected value coerces to.
      try unified(arguments, routines, subquery: subquery)
    case let .nullif(lhs, rhs):
      // NULLIF yields either `v1` or NULL, so the column takes `v1`'s type —
      // but derive both operands for resolution, returning the LHS type: an
      // unresolved column faults `SQLError.column` (`NULLIF(1, Missing)`) on
      // this derive-only surface too, mirroring the `||`/arithmetic derive
      // branch rather than leaving the RHS unresolved.
      try nullif(lhs, rhs, routines, subquery: subquery)
    case let .subquery(query):
      // A scalar subquery's static type is its single-column output type — the
      // compile pre-pass recorded it beside the width for every subquery, so
      // `derive` reads it (enforcing the single-column arity). A surface with
      // no catalog holds none and faults, rejecting the subquery rather than
      // mis-typing it, so this derive and the run's lowering agree.
      try subquery.scalar(type: query)
    case .grouping:
      // `GROUPING(a, …)` yields an integer bit-vector; its arguments are
      // grouping keys the grouped lowering resolves, so — like a `call` (which
      // types from its routine's declared return, not its arguments) — it types
      // as `.integer` here without deriving them.
      .integer
    }
  }

  /// The result type of `NULLIF(v1, v2)` under `derive` — `v1`'s type, deriving
  /// both operands for resolution first: NULLIF yields either `v1` or NULL, so
  /// its own RHS type does not shape the column, but an unresolved column still
  /// faults `SQLError.column`, mirroring the `||`/arithmetic derive branch. So
  /// `NULLIF(1, Missing)` faults `.column` on the derive-only paths
  /// (`columns(of:validate:false)`, an unreachable projection) where `validate`
  /// never runs.
  private func nullif(_ lhs: Expression, _ rhs: Expression,
                      _ routines: Routines,
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    let type = try derive(lhs, routines, subquery: subquery)
    _ = try derive(rhs, routines, subquery: subquery)
    return type
  }

  /// The `.text` type of `lhs || rhs`, deriving both operands for resolution
  /// first: the result is always text and the operands' own types do not shape
  /// it, but an unresolved column still faults `SQLError.column`, mirroring the
  /// arithmetic `.binary` derive branch.
  private func concatenation(_ lhs: Expression, _ rhs: Expression,
                             _ routines: Routines,
                             subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    _ = try derive(lhs, routines, subquery: subquery)
    _ = try derive(rhs, routines, subquery: subquery)
    return .text
  }

  /// The target `type` of a `CAST`, deriving `operand` for its ordinal
  /// resolution — a schema-surface non-faulting derive of the operand — and
  /// discarding its type, the conversion being nominal.
  private func derive(cast operand: Expression, to type: ValueType,
                      _ routines: Routines,
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    _ = try derive(operand, routines, subquery: subquery)
    return type
  }

  /// The unification of the types of `arguments` — the `ValueType.unified`
  /// reduction a `CASE`'s reachable results and a `COALESCE`'s arguments both
  /// take. A definitively-irreconcilable pair (a text beside an integer) faults
  /// `SQLError.operand`; a mixed integer/double pair widens to `double`. The
  /// list is never empty (the parser requires ≥ 2 COALESCE arguments).
  ///
  /// Only a selectable argument shapes the type. A run skips an argument
  /// whose value is NULL and moves on, so an argument folding to a constant
  /// `.null` (`constant(_ expression:)`) can never be the result — its type is
  /// derived (an unknown column still faults) but is NOT merged, exactly as a
  /// `CASE` omits an unreachable branch's result type. And an argument that is
  /// the definite selection (`selects(_:)` — a constant non-NULL value, or a
  /// `COUNT` aggregate that is always non-NULL) sets the type and makes every
  /// later argument unreachable — mirroring a `CASE`'s reachable-branch
  /// unification and the faulting `validate`'s stop.
  private func unified(_ arguments: Array<Expression>,
                       _ routines: Routines,
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try derive(argument, routines, subquery: subquery)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is derived (for its errors) but skipped: it can never
        // be returned, so its type must not shape the column.
        continue
      }
      if selects(argument, routines) {
        // A definite selection: merge its type and stop, as every later
        // argument is unreachable.
        return try merged(type, next)
      }
      type = try merged(type, next)
    }
    return type ?? .integer
  }

  /// Whether `argument` is a COALESCE's definite selection — an argument the
  /// executor's short-circuit is guaranteed to return, making every later
  /// argument unreachable (neither validated nor unified). That holds when it
  /// folds to a constant non-NULL value (`constant(_ expression:)`), or when it
  /// is a `COUNT` aggregate: `COUNT` alone among the aggregates always yields a
  /// row count of 0 or more, never NULL, so it always selects — while `SUM` /
  /// `MIN` / `MAX` / `AVG` are NULL over an empty group and so do NOT stop.
  private func selects(_ argument: Expression, _ routines: Routines) -> Bool {
    return switch argument {
    case .aggregate(.count, _, _, _): true
    default: constant(argument, routines).map { $0 != .null } ?? false
    }
  }

  /// The unification of a COALESCE's running result type with the `next`
  /// selectable argument's type — `next` when there is no running type yet,
  /// else their `ValueType.unified`, faulting `SQLError.operand` on an
  /// irreconcilable pair (a text beside an integer). Shared by the `derive`
  /// (`unified`) and `validate` (`coalesce`) surfaces so both merge only a
  /// selectable argument's type identically.
  private func merged(_ running: ValueType?, _ next: ValueType)
      throws(SQLError) -> ValueType {
    guard let running else { return next }
    guard let unified = running.unified(with: next) else {
      throw .operand("COALESCE arguments have irreconcilable types")
    }
    return unified
  }

  /// The nominal type of a `CASE` under `derive` — the unification of its
  /// reachable result types, and `.integer` when no branch is reachable (the
  /// run yields NULL). The reachable result types must unify (`unified`):
  /// a definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, so this lowering surface agrees with the
  /// faulting `validate` (`conditional`) — a mixed integer/double `CASE` still
  /// widens to `double`.
  internal func derive(_ whens: Array<When>, _ otherwise: Expression?,
                       _ routines: Routines,
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> ValueType {
    let results = reachable(whens, otherwise, routines)
    // A constant-NULL result places no type constraint (a NULL unifies with any
    // arm), so it is skipped in the fold — mirroring COALESCE and the faulting
    // `validate` (`conditional`) — and an all-NULL (or empty) CASE takes the
    // `.integer` placeholder, which the projection walk marks unconstrained.
    var type: ValueType?
    for result in results {
      if case .some(.null) = constant(result, routines) { continue }
      let next = try derive(result, routines, subquery: subquery)
      guard let running = type else { type = next; continue }
      guard let unified = running.unified(with: next) else {
        throw .operand("CASE results have irreconcilable types")
      }
      type = unified
    }
    return type ?? .integer
  }

  /// The result expressions of a `CASE` the executor's short-circuit can reach,
  /// in branch order: a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result and is dropped; a `WHEN` whose guard is statically
  /// constant-TRUE is itself reachable and keeps every earlier reachable branch
  /// (a row an earlier row-dependent guard matches takes that branch, never
  /// reaching this one), but makes every strictly-later `WHEN` and the `ELSE`
  /// unreachable; an `ELSE` is reachable only when no guard is constant-TRUE. A
  /// guard that is not statically decidable (`constant` is `nil`) leaves its
  /// result reachable.
  private func reachable(_ whens: Array<When>, _ otherwise: Expression?,
                         _ routines: Routines)
      -> Array<Expression> {
    var results = Array<Expression>()
    for branch in whens {
      switch constant(branch.when, routines) {
      case false: continue
      case true: results.append(branch.then); return results
      case nil: results.append(branch.then)
      }
    }
    if let otherwise { results.append(otherwise) }
    return results
  }

  // MARK: - Validation

  /// The value type a scalar `expression` yields, validating each operand and
  /// call exactly as a run would fault: an aggregate or arithmetic over a
  /// non-numeric operand (`SQLError.operand`), a call to an unregistered
  /// routine (`SQLError.function`), a bad arity or argument kind
  /// (`SQLError.argument`), a `/` by a literal zero (`SQLError.divide`), or a
  /// deterministic overflow of two folded literal operands
  /// (`SQLError.magnitude`) faults precisely where a run would raise it. It
  /// resolves column ordinals and reads no cursor, so it type-checks a query
  /// without executing it.
  ///
  /// This is the type-CHECK surface. `derive(_:_:)` is the non-faulting schema
  /// surface, which only derives the nominal output type.
  internal func validate(_ expression: Expression, _ routines: Routines = [:],
                         subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    switch expression {
    case let .column(column):
      // A bare name matching a `NATURAL`/`USING` merged column (ISO 9075 7.10)
      // types from the unified coalesce `type` — the same merged-aware bare
      // lookup `term`/`derive` shadow the two physical sides with, so the
      // type-check accepts exactly the bare merged reference the run lowers (a
      // same-named physical column a later plain join added faults `.ambiguous`
      // in `merged(binding:)`). A column this scope does not bind may be a
      // correlated reference to an enclosing query (validated as the run
      // resolves it — a `WHERE` one types as its outer column, a
      // projection/`HAVING` one faults unsupported); else the ordinary column
      // fault. A locally ambiguous name is a hard error `find` propagates — not
      // a fall-through to outer correlation.
      if column.qualifier == nil,
          let merged = try merged(binding: column.name) {
        merged.type
      } else if let ordinal = try find(column) {
        type(at: ordinal)
      } else if let type = try subquery.correlated(column) {
        type
      } else {
        try type(at: ordinal(of: column))
      }
    case let .literal(literal):
      type(of: literal)
    case let .call(name, arguments):
      try call(name, over: arguments, routines, subquery: subquery)
    case let .aggregate(function, operand, _, filter):
      try aggregate(function, over: operand, filter: filter, routines,
                    subquery: subquery)
    case let .binary(op, lhs, rhs):
      try arithmetic(op, lhs, rhs, routines, subquery: subquery)
    case let .case(whens, otherwise):
      try conditional(whens, otherwise, routines, subquery: subquery)
    case let .cast(operand, type):
      try validate(cast: operand, to: type, routines, subquery: subquery)
    case let .coalesce(arguments):
      try coalesce(arguments, routines, subquery: subquery)
    case let .nullif(lhs, rhs):
      try nullif(validate: lhs, rhs, routines, subquery: subquery)
    case let .subquery(query):
      // A scalar subquery's static type is its single-column output type — the
      // pre-pass validated and compiled its inner query and derived the type,
      // enforcing the single-column arity (else `SQLError.arity`), so this
      // reads that type exactly as the run's lowering does. A surface with no
      // catalog holds none and faults, rejecting the subquery unvalidated.
      try subquery.type(query)
    case let .grouping(arguments):
      // `GROUPING(a, …)` yields an integer bit-vector. Validate each argument
      // resolves as a scalar (the grouped lowering additionally enforces that
      // each names a `GROUP BY` expression — `SQLError.grouping` otherwise —
      // which this per-operand type-check does not duplicate), then accept.
      try grouping(over: arguments, routines, subquery: subquery)
    }
  }

  /// The type of `GROUPING(a, …)` under `validate` — `.integer`, validating
  /// each argument resolves as a run would (an unknown column, a bad operand,
  /// or an ill-typed call inside an argument faults). The grouped lowering
  /// enforces that each argument is a `GROUP BY` expression, so this only
  /// checks resolvability and does not itself fault a valid GROUPING.
  private func grouping(over arguments: Array<Expression>,
                        _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    for argument in arguments {
      _ = try validate(argument, routines, subquery: subquery)
    }
    return .integer
  }

  /// The result type of `COALESCE(v1, v2, …)`, validating each reachable
  /// argument as a run would fault and unifying only the selectable ones'
  /// types (`merged`). A definitively-irreconcilable pair (a text argument
  /// beside an integer) faults `SQLError.operand`, as the column cannot be two
  /// kinds; a mixed integer/double pair widens to `double`.
  ///
  /// The executor returns the first non-NULL argument and never evaluates a
  /// later one, so an argument that is the definite selection (`selects(_:)` —
  /// a constant non-NULL value, or a `COUNT` aggregate that is always non-NULL)
  /// makes every later argument unreachable — those are NOT validated
  /// (`COALESCE(1, missing_udf())` and `COALESCE(COUNT(*), missing_udf())` both
  /// type-check), exactly as a constant-TRUE `CASE` guard makes later branches
  /// unreachable.
  ///
  /// An argument that folds to a constant `.null` is validated (for its own
  /// errors) but its type is NOT merged: a run skips a NULL and moves on, so
  /// that argument can never be returned — merging its declared type would
  /// reject `COALESCE(null_text(), 1)`, a text arm that can only yield the
  /// integer, exactly as a `CASE` omits a skipped branch's result type. An
  /// undecidable argument (`nil`) may be selected, so its type is merged and
  /// the walk continues.
  private func coalesce(_ arguments: Array<Expression>, _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try validate(argument, routines, subquery: subquery)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is validated (for its errors) but skipped: it can
        // never be returned, so its type must not shape the column.
        continue
      }
      if selects(argument, routines) {
        // A definite selection: merge its type and stop, as every later
        // argument is unreachable and unvalidated.
        return try merged(type, next)
      }
      type = try merged(type, next)
    }
    return type ?? .integer
  }

  /// The result type of `NULLIF(v1, v2)`, validating both operands as a run
  /// would fault. `NULLIF(v1, v2)` is `CASE WHEN v1 = v2 THEN NULL ELSE v1`, so
  /// the two must be comparable — an incomparable pair faults 42804, the fault
  /// the run's `nullif` raises through `matches`. The result is either `v1` or
  /// NULL, so the column takes `v1`'s type; `v2` does not shape it.
  private func nullif(validate lhs: Expression, _ rhs: Expression,
                      _ routines: Routines,
                      subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    let type = try validate(lhs, routines, subquery: subquery)
    let other = try validate(rhs, routines, subquery: subquery)
    try comparable(lhs, type, rhs, other, routines)
    return type
  }

  /// The target `type` of a `CAST`, validating `operand` for real errors
  /// (unknown column, bad call arity, …) as a run would fault, and rejecting a
  /// cast the runtime could never perform before advertising the target type.
  ///
  /// A cast whose (operand type → target type) pair is structurally
  /// unsupported — a boolean to a number, a number to a blob — faults `42846`
  /// for every value of the operand's kind, so `SELECT CAST(TRUE AS INTEGER)`
  /// would otherwise advertise an integer column though executing it
  /// unconditionally throws. `ValueType.castable(to:)` — the same structural
  /// truth the runtime cast consults — rejects that pair here, at validation.
  ///
  /// A castable-but-value-dependent pair still passes: a `text` to a number, or
  /// a `blob` to `text`, is a supported pair whose fault (`22018`/`22003`)
  /// depends on the value, so a reachable good value runs — `CAST('1' AS
  /// INTEGER)` type-checks. The exception is a constant operand that folds and
  /// ALWAYS fails: `CAST('abc' AS INTEGER)` is unparseable for the one value it
  /// can have, so a trial cast of the folded constant rejects it too.
  ///
  /// The constant fold runs FIRST, before the structural pair rejection: a
  /// constant operand casts to one value, so its trial cast decides the cast
  /// outright — it allows a statically-NULL operand (`CAST(CASE WHEN 1 = 0
  /// THEN 1 END AS BLOB)` folds to `.null`, which casts to ANY target) even
  /// where the operand's derived type would make the pair structurally
  /// unsupported, and it still rejects a constant that always fails. Only a
  /// non-constant operand, whose value is unknown at validation, falls to the
  /// structural pair check.
  private func validate(cast operand: Expression, to type: ValueType,
                        _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    let source = try validate(operand, routines, subquery: subquery)
    // A constant operand casts to one value only, so its trial cast is the
    // whole decision: it allows a folded NULL to any target and rejects a
    // spelling that always faults (`CAST('abc' AS INTEGER)`). A non-constant
    // operand folds to `nil`, so the structural pair check rejects a kind that
    // could never cast (`CAST(<boolean column> AS INTEGER)` → `42846`).
    if let value = constant(operand, routines) {
      _ = try value.cast(to: type)
    } else if !source.castable(to: type) {
      throw .state("42846",
                   "cannot cast \(source.domain) to \(type.domain)")
    }
    return type
  }

  /// The result type of a `CASE`, validating each reachable branch as a run
  /// would fault and honouring the executor's short-circuit: each evaluated
  /// `WHEN` guard is a boolean predicate whose operands are validated
  /// (`check`); only a reachable result expression is validated; and the
  /// reachable result types must unify to one type (`ValueType.unified`) — a
  /// definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, as a query cannot yield a column of two kinds.
  /// A mixed integer/double `CASE` widens to `double`.
  ///
  /// The executor takes the first TRUE guard's result and never evaluates a
  /// later branch, so a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result — its operands are NOT validated (`CASE WHEN 1 = 0 THEN
  /// Name + 1 ELSE 0 END` type-checks). A constant-TRUE guard is itself
  /// reachable and keeps every earlier reachable branch — a row an earlier
  /// row-dependent guard matches takes that branch, never reaching the
  /// constant-TRUE one — so those earlier results are still validated (`CASE
  /// WHEN Id = 1 THEN Name + 1 WHEN 1 = 1 THEN 0 END` faults on the reachable
  /// `Id = 1` branch's `Name + 1`); it makes only every strictly-later guard,
  /// result, and the `ELSE` unreachable. A reachable bad operand (`WHEN Id = 1
  /// THEN Name + 1`) still faults. When no branch is reachable the run yields
  /// NULL, typed `.integer` (the schema default), with no result to validate.
  private func conditional(_ whens: Array<When>, _ otherwise: Expression?,
                           _ routines: Routines,
                           subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    var results = Array<Expression>()
    var decided = false
    for branch in whens {
      // The guard up to (and including) the decisive one is evaluated, so
      // validate its operands; a constant-FALSE guard's result is unreachable
      // (skip it), a constant-TRUE one is reachable but makes every later
      // branch unreachable — so keep the earlier results and this one, then
      // stop.
      try check(branch.when, routines, subquery: subquery)
      switch constant(branch.when, routines) {
      case false: continue
      case true: results.append(branch.then); decided = true
      case nil: results.append(branch.then)
      }
      if decided { break }
    }
    if !decided, let otherwise { results.append(otherwise) }
    // A result that folds to a constant NULL places no type constraint — a NULL
    // unifies with any arm — so it is validated for its own errors but skipped
    // in the type fold, exactly as COALESCE skips a constant-NULL argument. With
    // every reachable result constant NULL (or none), the CASE is unconstrained
    // and takes the `.integer` placeholder.
    var type: ValueType?
    for result in results {
      let next = try validate(result, routines, subquery: subquery)
      if case .some(.null) = constant(result, routines) { continue }
      guard let running = type else { type = next; continue }
      guard let unified = running.unified(with: next) else {
        throw .operand("CASE results have irreconcilable types")
      }
      type = unified
    }
    return type ?? .integer
  }

  /// The result type of the scalar routine `name` called over `arguments`,
  /// validating its declared signature exactly as a run would fault: an
  /// unregistered name faults `SQLError.function`; the argument count must lie
  /// in the routine's `minimum ... parameters.count` arity (a fixed-arity
  /// routine has `minimum == parameters.count`, so this is exact for it, and an
  /// optional-tail routine like `OVERLAY` admits either count); and each
  /// supplied argument's static type must equal the declared parameter type. A
  /// nullable column of the declared
  /// type passes — statically it carries its declared type and a run-time NULL
  /// propagates — so only a definitively-wrong type (text where an integer is
  /// required) is rejected, mirroring a routine like `BITAND` throwing
  /// `SQLError.argument` on a non-integer non-NULL value. Each argument is
  /// validated too, so a type error nested in a call — `BITAND(Name + 1, 1)`
  /// over text — faults exactly as a run would, rather than the call reporting
  /// its return type over an un-evaluable argument `compile` resolved but never
  /// type-checked.
  private func call(_ name: String, over arguments: Array<Expression>,
                    _ routines: Routines,
                    subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    guard let routine = routines[name] else { throw .function(name) }
    guard (routine.minimum ... routine.parameters.count)
        .contains(arguments.count) else {
      let arity = routine.minimum == routine.parameters.count
          ? "\(routine.parameters.count)"
          : "\(routine.minimum) to \(routine.parameters.count)"
      throw .argument("\(name) takes \(arity) arguments")
    }
    for (argument, expected) in zip(arguments, routine.parameters) {
      let type = try validate(argument, routines, subquery: subquery)
      // A statically-NULL argument fits any parameter type: run-time dispatch
      // accepts NULL for every declared type and returns NULL, so a bare NULL
      // (whose nominal type is the `.integer` placeholder) must not fault a call
      // over a non-integer parameter — `UPPER(NULL)` type-checks and runs. A
      // nullable column is not statically NULL (`constant` is `nil`), so its
      // declared type is still enforced.
      if case .some(.null) = constant(argument, routines) { continue }
      guard type == expected else {
        throw .argument("\(name) requires \(expected.domain) arguments")
      }
    }
    return routine.returns
  }

  /// The result type of `function` folded over `operand`, validating the
  /// operand as a run would fault. `COUNT` counts rows (`.integer`);
  /// `MIN`/`MAX` take the operand's own type — they compare, so any comparable
  /// value folds. `SUM`/`AVG` fold numerically: `SUM` yields the operand's
  /// numeric type, `AVG` a double, so both require a numeric operand — over
  /// text, boolean, or blob `Aggregate.fold` faults `SQLError.operand` on the
  /// first non-NULL value, so typing faults the same way rather than
  /// advertising `AVG(Name)` as a double or `SUM(Name)` as text for a query
  /// that cannot fold its rows.
  private func aggregate(_ function: Aggregate, over operand: Aggregand,
                         filter: Predicate?, _ routines: Routines,
                         subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    // A `FILTER (WHERE …)` is a per-row gate, so it type-checks as an ordinary
    // predicate — its columns resolve and its comparisons are well-typed — and
    // it may not itself contain an aggregate (ISO forbids an aggregate in a
    // filter's search condition, as it has no per-row meaning).
    if let filter {
      if filter.aggregated {
        throw .state("42803", "an aggregate is not allowed in a FILTER")
      }
      try check(filter, routines, subquery: subquery)
      // A FILTER that statically cannot admit a row makes the operand
      // unreachable: the executor gates on a definite TRUE (a FALSE or UNKNOWN
      // row is skipped, and the argument is evaluated only after the gate), so
      // an operand behind a statically non-TRUE filter never folds. `SUM(1 / 0)
      // FILTER (WHERE 1 = 0)` thus runs to the empty result (NULL) — do NOT
      // validate the dead operand, or a fault it could never raise (a divide by
      // zero) would wrongly reject a runnable query. The aggregate is
      // statically empty, so advertise its declared/derived result type without
      // the operand's run-time-fault check (`dead(_:_:)` proves the filter
      // ROW-independently never TRUE); a filter that could be TRUE still
      // validates the operand as a bare aggregate does.
      if dead(filter, routines) {
        return try empty(function, over: operand, routines)
      }
    }
    switch function {
    case .count:
      // `COUNT(expr)` evaluates `expr` per row to test it is non-NULL, so
      // validate the operand (`COUNT(*)` has none); the result is always an
      // integer count.
      if case let .expression(argument) = operand {
        _ = try validate(argument, routines, subquery: subquery)
      }
      return .integer
    case .min, .max:
      switch operand {
      case .star: return .integer
      case let .expression(argument):
        return try validate(argument, routines, subquery: subquery)
      }
    case .sum, .avg:
      let type: ValueType = switch operand {
      case .star: .integer
      case let .expression(argument):
        try validate(argument, routines, subquery: subquery)
      }
      if !type.numeric { throw .operand("operands must be numeric") }
      return function == .avg ? .double : type
    }
  }

  /// The result type of `function` folded over `operand` when a statically
  /// non-TRUE `FILTER` makes the fold empty — the operand is unreachable, so it
  /// is derived for its type (resolving a column) but NOT validated for a
  /// run-time fault it can never raise (a divide by zero, a non-numeric SUM).
  /// The empty fold yields `COUNT` `0` and every other aggregate NULL, so the
  /// type is the set-function's declared/derived one, mirroring `aggregate` but
  /// non-faulting on the dead operand: `COUNT`/`AVG` fixed, `SUM`/`MIN`/`MAX`
  /// the operand's own derived type (`.integer` for `.star`).
  private func empty(_ function: Aggregate, over operand: Aggregand,
                     _ routines: Routines) throws(SQLError) -> ValueType {
    switch function {
    case .count:
      return .integer
    case .avg:
      return .double
    case .sum, .min, .max:
      switch operand {
      case .star: return .integer
      case let .expression(argument): return try derive(argument, routines)
      }
    }
  }

  /// Whether `filter` is ROW-independently never TRUE — so a `FILTER`'s gate
  /// (which admits a row only on a definite TRUE) can never admit one and the
  /// aggregate operand behind it is unreachable. An `AND` is TRUE only when
  /// every conjunct is TRUE, so a single conjunct that is row-independently
  /// non-TRUE kills the whole conjunction regardless of the others: flatten the
  /// top-level `Predicate.and` spine (`a AND (b AND c)` to `a, b, c` — each
  /// non-AND node one conjunct, not descending into `OR`) and prove it dead
  /// when ANY conjunct folds definitely FALSE (`constant(_:)` `false`), or is
  /// `settled` (row-independent) and folds to UNKNOWN (`constant(_:)` `nil`).
  /// This subsumes the whole-filter case (a settled-non-TRUE filter is a lone
  /// conjunct). It stays sound — only a provably non-TRUE conjunct kills the
  /// filter: a row-dependent conjunct (could be TRUE per row) or a settled-TRUE
  /// one does NOT, so those still validate the operand.
  private func dead(_ filter: Predicate, _ routines: Routines) -> Bool {
    var conjuncts: Array<Predicate> = [filter]
    var index = 0
    while index < conjuncts.count {
      if case let .and(lhs, rhs) = conjuncts[index] {
        conjuncts[index] = lhs
        conjuncts.append(rhs)
      } else {
        index += 1
      }
    }
    return conjuncts.contains { conjunct in
      let folded = constant(conjunct, routines)
      return folded == false
          || (folded == nil && settled(conjunct, routines))
    }
  }

  /// The result type of `lhs op rhs` — a double when either arithmetic operand
  /// is a double (`Age + 1.5`), an integer for two integer operands, and text
  /// for `||` — validating each operand's kind as a run would fault: an
  /// arithmetic operator over a text/boolean/blob operand has no arithmetic and
  /// `||` over a non-text operand has no concatenation (`Arithmetic.apply`
  /// faults `SQLError.operand`); a `/` by a literal zero is rejected up front
  /// (`SQLError.divide`); and two literal operands are folded to reject a
  /// deterministic overflow (`SQLError.magnitude`). Typing thus faults as a run
  /// would rather than advertise a header no row can produce.
  private func arithmetic(_ op: Arithmetic, _ lhs: Expression,
                          _ rhs: Expression,
                          _ routines: Routines,
                          subquery: SubqueryCheck = .unsupported)
      throws(SQLError) -> ValueType {
    let left = try validate(lhs, routines, subquery: subquery)
    let right = try validate(rhs, routines, subquery: subquery)
    if case .concatenate = op {
      // Both operands are validated above for their own errors. `||` yields
      // text and needs two text operands — unless one folds to a static NULL,
      // in which case `Arithmetic.apply` returns NULL before it inspects either
      // kind, so the whole expression yields NULL and runs whatever the other
      // operand's type (as the CAST path admits a folded NULL to any target):
      // `(CASE WHEN 1 = 0 THEN 1 END) || 1` runs. A non-text, non-NULL pairing
      // faults exactly as the run does.
      guard left == .text && right == .text
              || vanishing(lhs, routines) || vanishing(rhs, routines) else {
        throw .operand("|| operands must be text")
      }
      return .text
    }
    // A statically-NULL operand makes the whole arithmetic NULL: `Arithmetic.apply`
    // returns NULL before it inspects either operand's kind, divides, or
    // overflows, so the expression runs whatever the other operand's kind —
    // `NULL + 'x'`, `'x' + NULL`, and even `NULL / 0` yield NULL — mirroring the
    // concatenation path above. Skip the numeric-kind guard and the divide/
    // overflow folds, and take the numeric result type (the placeholder integer
    // when the other operand is non-numeric; the column is unconstrained anyway,
    // since it folds to NULL).
    if vanishing(lhs, routines) || vanishing(rhs, routines) {
      return left == .double || right == .double ? .double : .integer
    }
    guard left.numeric, right.numeric else {
      throw .operand("operands must be numeric")
    }
    // A literal-zero divisor faults `Arithmetic.apply` on the first row it
    // divides, so reject it statically; a non-literal divisor is per row.
    if case .divide = op, zero(rhs) { throw .divide }
    // Two literal operands fold to a constant, so a deterministic magnitude
    // fault (integer overflow, a non-finite double) hits every row the
    // projection reaches — a FROM-less SELECT at once. Fold them so the schema
    // rejects the column rather than advertise a header no row yields.
    if case let .literal(lhs) = lhs, case let .literal(rhs) = rhs {
      _ = try op.apply(value(of: lhs), value(of: rhs))
    }
    return left == .double || right == .double ? .double : .integer
  }

  /// Whether `expression` folds to a static NULL — a row-independent constant
  /// NULL. A `||` with a vanishing operand yields NULL before its
  /// `Arithmetic.apply` inspects either operand's kind, so the whole expression
  /// is valid whatever the other operand's type, mirroring the CAST validation
  /// path that admits a folded NULL to any target — so a no-match `CASE` typed
  /// `.integer` that yields NULL lets `(CASE WHEN 1 = 0 THEN 1 END) || 1` run.
  private func vanishing(_ expression: Expression, _ routines: Routines)
      -> Bool {
    if case .null? = constant(expression, routines) { true } else { false }
  }

  /// Whether `expression` is a literal zero — the statically-known divisor a
  /// `/` would fault on.
  private func zero(_ expression: Expression) -> Bool {
    switch expression {
    case .literal(.integer(0)): true
    case let .literal(.double(value)): value == 0
    default: false
    }
  }

  // MARK: - Predicate checking

  /// Type-checks every operand expression in `predicate` — a comparison's two
  /// sides, an `IS NULL` operand — recursing through `AND`/`OR`/`NOT`. It types
  /// each for the side effect of validation (an operand or function fault a run
  /// would raise) and discards the result. A `left op :parameter` bound
  /// comparison is NOT checked: with no binding (the schema default) the run
  /// yields UNKNOWN without evaluating the left term.
  ///
  /// It respects the executor's short-circuit: `false AND rhs` and `true OR
  /// rhs` never evaluate `rhs` (`evaluate` returns on the left arm), so a right
  /// arm a statically-false `AND` (or true `OR`) guards is unreachable and is
  /// not type-checked — `WHERE 1 = 0 AND Name + 1 = 2` runs, so its schema
  /// resolves rather than faulting on the unreachable `Name + 1`.
  func check(_ predicate: Predicate,
             _ routines: Routines = [:],
             subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      let l = try validate(left, routines, subquery: subquery)
      let r = try validate(right, routines, subquery: subquery)
      // The ISO comparability rule: an incomparable operand pair (a number
      // against a string) is a data-type mismatch (42804), not a FALSE row —
      // the fault the run's `matches` raises, so the two agree. A bare boolean
      // predicand (`WHERE Age`) reaches here as its `Age = TRUE` desugar, so a
      // non-boolean one faults exactly as an explicit `Age = TRUE` does.
      try comparable(left, l, right, r, routines)
    case let .exists(query, _):
      // Validate the inner uncorrelated query as the run's lowering does — it
      // resolves and type-checks against the enclosing catalog, so a bad column
      // or routine inside it faults at validation, matching what a run rejects.
      // Reached in the `existential` role, so the deferred phase validates its
      // cardinality probe (no select list), never the original projection.
      try subquery.validate(query, as: .existential)
    case let .within(lhs, query, _):
      // `(l…) [NOT] IN (Q)` (a bare `x IN (Q)` its one-arity case): validate
      // each left component AND the inner query, and enforce the
      // row-arity-equals-width rule the lowering does (`SQLError.arity`), so
      // schema validation matches execution — the recurring lesson that the
      // two must not diverge. Reached in the `valued` role (its rows are read),
      // so the deferred phase validates the original query. A cross-kind
      // component now faults at run through `relate` (the ISO comparability
      // rule), but the static comparability check is not applied against a
      // subquery operand here: its single-column type may be a nominal-NULL
      // placeholder (a `SELECT NULL` body types `.integer`), which would
      // mis-reject a query the run keeps — so the run stays the authority for a
      // subquery operand, while an irreconcilable set-operation subquery still
      // faults through its own union type fold.
      for expression in lhs {
        _ = try validate(expression, routines, subquery: subquery)
      }
      try subquery.validate(query, as: .valued)
      let width = try subquery.width(query)
      guard width == lhs.count else { throw .arity(lhs.count, width) }
    case let .quantified(lhs, _, _, query):
      // As `within`: validate each left component and the inner query, and
      // enforce the row-arity-equals-subquery-width rule the lowering does
      // (`SQLError.arity`), so schema validation matches execution. Reached
      // `valued` (its rows are read), so the deferred phase validates the
      // original query. A cross-kind operand faults at run through `relate`;
      // the static comparability check defers to the run for a subquery
      // operand, as `within` does.
      for expression in lhs {
        _ = try validate(expression, routines, subquery: subquery)
      }
      try subquery.validate(query, as: .valued)
      let width = try subquery.width(query)
      guard width == lhs.count else { throw .arity(lhs.count, width) }
    case .bound:
      // `left op :parameter` with no binding — the schema default `[:]` —
      // yields UNKNOWN without evaluating the left term, so a run just produces
      // no rows; schema validation has no bindings, so it does not evaluate it.
      break
    case let .null(operand, _):
      _ = try validate(operand, routines, subquery: subquery)
    case let .membership(operand, values, _):
      // `x IN (v, …)` lowers to `x = v OR …`, so type it as those comparisons:
      // validate the operand and each value for real errors (unknown column,
      // bad arity, …) AND check each reached element is comparable to the
      // operand — an incomparable element (text in an integer list) is a
      // data-type mismatch (42804), the fault the run's `member` raises, so the
      // schema check faults exactly where the run does.
      //
      // The OR-chain short-circuits: a definite match makes the whole `IN` TRUE
      // and leaves later elements unreachable, so validation stops there. Two
      // element shapes are a definite match:
      //   - A row-independent constant match (`x = v` folds TRUE, both
      //     constants) — `1 IN (1 + 0, Name + 1)` type-checks, the run matching
      //     `1 = 1 + 0` before ever reaching `Name + 1`, while `2 IN (1 + 0,
      //     Name + 1)` (no definite match) still validates `Name + 1` and
      //     faults. `matched(operand, value, routines)` is that primitive. A
      //     constant match folds only over a non-NULL operand (a NULL folds
      //     UNKNOWN), so the run genuinely short-circuits.
      //   - A reflexive element structurally equal to a stable operand (`K IN
      //     (K, …)`) is a per-row match — but a short-circuit only over
      //     a provably non-NULL operand (`defined`): `operand = operand` is
      //     TRUE, so the run's membership Kleene-OR stops there and every later
      //     element is unreachable, none validated or compared. A nullable
      //     operand makes it UNKNOWN, so a NULL row runs on and evaluates every
      //     later element: its comparison to the NULL operand is UNKNOWN (never
      //     42804), so the comparability check still stops here, but its own
      //     evaluation is reached — a `1 / 0` faults — so the evaluation check
      //     continues. So `K IN (K, 'x')` type-checks whether or not `K` is
      //     provably non-NULL (the reached `'x'` is compared to a NULL `K`,
      //     UNKNOWN), while `K IN (K, 1 / 0)` type-checks only when `K` is
      //     provably non-NULL — a nullable `K` reaches and faults the `1 / 0`.
      //     `K IN ('x', K)` still faults (the reached `'x'` is compared to a
      //     non-NULL `K` before the reflexive one) and `K IN (1, 'x')` still
      //     faults (`1` is comparable but not a match). The stability gate
      //     (`stable`) is load-bearing: it fires only for an operand whose two
      //     evaluations always agree, since the run evaluates the operand and
      //     the element independently — a deterministic `K + 1` is stable, a
      //     non-deterministic `tick()` is not, so `tick() IN (tick(), 'x')`
      //     reaches the `'x'`. The reflexive recognition is scoped to
      //     the comparability walk: it must not leak into the `matched`
      //     reachability fold `constant(_ predicate:)` shares, since `K IN
      //     (K, …)` is UNKNOWN (not constant-TRUE) for a NULL operand and the
      //     optimiser must not fold it away.
      //
      // An empty list has no OR-chain and cannot be lowered (`lower` would have
      // no seed), so reject it here too — the parser rejects `IN ()`, but a
      // caller can build `.membership(_, [], …)` directly, so this validation
      // faults on that shape rather than typing it as an always-false chain.
      if values.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      let type = try validate(operand, routines, subquery: subquery)
      // `x IN (…)` lowers to `x = v OR …`. Every element the run reaches is
      // validated for its own evaluation errors (a `1 / 0`); and until the
      // OR-chain short-circuits it is also checked comparable to the operand —
      // an incomparable element faults 42804, the fault the run's `member`
      // raises. A constant-TRUE element, or a reflexive element equal to a
      // stable operand (`operand IN (operand, …)`), short-circuits the chain.
      // `1 IN (1, 'a')` type-checks while `1 IN ('a', 1)` faults.
      //
      // A reflexive element short-circuits definitely only over a provably
      // non-NULL operand (`defined`): `operand = operand` is TRUE, so every
      // later element is unreachable and neither validated nor compared. A
      // nullable operand makes it UNKNOWN, so a NULL row runs on and evaluates
      // every later element — those still fault on their own evaluation, though
      // their comparison to the NULL operand is UNKNOWN, never 42804 — so the
      // comparability check stops at the reflexive element while the evaluation
      // check continues. A non-deterministic operand is not stable, so it
      // never short-circuits (`tick() IN (tick(), 'x')` reaches the `'x'`).
      var comparing = true
      for value in values {
        let element = try validate(value, routines, subquery: subquery)
        guard comparing else { continue }
        try comparable(operand, type, value, element, routines)
        if value == operand && stable(operand, routines) {
          if defined(operand) { break }
          comparing = false
        } else if matched(operand, value, routines) == true {
          break
        }
      }
    case let .rows(lhs, _, rhs):
      // `(l…) <op> (r…)` lowers to a componentwise comparison, so type each
      // component of both rows for real errors (unknown column, bad arity, …),
      // and enforce the equal-arity rule the lowering does (`SQLError.arity`)
      // so schema validation matches execution.
      guard lhs.count == rhs.count else {
        throw .arity(lhs.count, rhs.count)
      }
      // Validate both rows in the run's evaluation order — every left, then
      // every right component — before the componentwise comparability pass,
      // because that is the order `Filter.comparison` runs: it evaluates the
      // whole left row into a `[Value]`, then the whole right, and only then
      // does `relate` preflight every component pair's comparability. A
      // component's own evaluation fault the run raises while building a row
      // therefore surfaces ahead of any 42804 — `(1, 1 / 0) = ('x', 2)` divides
      // by zero building the left row before the incomparable `1`/`'x'` pair is
      // compared, so the type-check must fault the divide, not the 42804, to
      // match the run. Interleaving the comparability check per component would
      // fault the first pair's 42804 before the later faulting left component.
      var l = Array<ValueType>()
      l.reserveCapacity(lhs.count)
      for expression in lhs {
        try l.append(validate(expression, routines, subquery: subquery))
      }
      var r = Array<ValueType>()
      r.reserveCapacity(rhs.count)
      for expression in rhs {
        try r.append(validate(expression, routines, subquery: subquery))
      }
      // Each component pair must be comparable — `(l…) <op> (r…)` folds through
      // the componentwise `relate`, which faults 42804 on an incomparable pair
      // (`(1, 'a') = (1, 2)`), so the type-check faults the same pair.
      for index in lhs.indices {
        try comparable(lhs[index], l[index], rhs[index], r[index], routines)
      }
    case let .among(lhs, rows, _):
      // `(l…) [NOT] IN ((r…), …)` lowers to a disjunction of row equalities, so
      // type the left row and each reached element row for real errors, enforce
      // the non-empty list and per-row equal-arity rules the lowering does, and
      // check each reached component pair is comparable — an incomparable one
      // faults 42804, the fault the run's row `member` fold raises.
      //
      // The OR-chain short-circuits exactly as the scalar `.membership` does: a
      // definite constant match (both the left row and an element row fold to
      // ROW-independent constants whose tuple-equality `relate` yields TRUE)
      // makes the whole `IN` TRUE and leaves every later element unreachable,
      // so validation stops there — `(1, 2) IN ((1, 2), (Name + 1, 3))`
      // type-checks (the constant `(1, 2)` matches the first element before
      // `Name + 1` is reached), while `(1, 2) IN ((3, 4), (Name + 1, 5))` (no
      // definite match) still validates `Name + 1` and faults. A row-dependent
      // side leaves the element undecided (`nil`), so no false short-circuit
      // prunes a reachable element.
      if rows.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      var types = Array<ValueType>()
      types.reserveCapacity(lhs.count)
      for expression in lhs {
        try types.append(validate(expression, routines, subquery: subquery))
      }
      let l = constants(lhs, routines)
      _ = try membership(of: rows, each: { element throws(SQLError) in
        guard element.count == lhs.count else {
          throw .arity(lhs.count, element.count)
        }
        // Each element row folds through the componentwise `relate`, which
        // faults 42804 on an incomparable component — so type-check each
        // component pair. Short-circuit aware: a prior constant-TRUE element
        // row leaves a later one unvisited, matching the run's `member` fold.
        //
        // Validate the whole element row in the run's evaluation order —
        // `member` builds every component into a `[Value]` before `relate`
        // preflights their comparability — then the comparability pass, so a
        // component's own evaluation fault surfaces ahead of a later pair's
        // 42804: `(N) IN ((1 / 0))` over integer `N` divides before comparing,
        // and `(N, M) IN (('x', 1 / 0))` divides building the element row, not
        // faulting the incomparable `N`/`'x'` pair, matching the run.
        var r = Array<ValueType>()
        r.reserveCapacity(element.count)
        for expression in element {
          try r.append(validate(expression, routines, subquery: subquery))
        }
        for index in element.indices {
          try comparable(lhs[index], types[index], element[index], r[index],
                         routines)
        }
      }, equality: { element throws(SQLError) in
        guard let l, let r = constants(element, routines) else { return nil }
        // The short-circuit fold is a pure reachability decision — an
        // incomparable pair is undecided here (`nil`), its 42804 fault raised
        // by the comparability check in the `each` walk above, not this fold.
        return (try? relate(l, .equal, r)) ?? nil
      })
    case let .like(operand, pattern, escape, _):
      // Validate the operand, pattern, and optional escape for real errors
      // (unknown column, bad arity, …). The operand and pattern must be
      // character strings (ISO): a non-text, non-NULL operand or pattern faults
      // 42804, the same non-character fault the run's `like` raises, so the
      // type-check and the run agree.
      let type = try validate(operand, routines, subquery: subquery)
      try validate(pattern, routines, subquery: subquery)
      if let escape {
        try validate(escape, routines, subquery: subquery)
        try reject(escape, routines)
      }
      // The run reads a NULL — or a possibly-NULL, per-run — pattern or escape
      // as UNKNOWN before its non-character fallback, so the whole predicate is
      // UNKNOWN regardless of the subject's type. A constant-NULL pattern or
      // escape (`K LIKE NULL`, `K LIKE 'x' ESCAPE NULL`, integer `K`) and a
      // `:parameter` one (`K LIKE :p`, its value arriving from the bindings)
      // both run and select nothing — they do not fault 42804 — so `vanishes`
      // defers each. Mirror that NULL-first ordering: when the pattern or the
      // escape vanishes, admit the predicate without enforcing the character
      // type of the subject (or the pattern), matching the run; only a
      // non-NULL, non-parameter pattern/escape reaches the character check the
      // run's non-character fallback faults.
      guard !vanishes(pattern, routines), !vanishes(escape, routines) else {
        break
      }
      // A constant-NULL subject makes the run's `like` return UNKNOWN from its
      // `(.null, _, _)` arm before it inspects the pattern's type, so neither
      // the subject nor the pattern character type is enforced — `NULL LIKE 1`
      // runs and selects nothing, it does not fault. The pattern is already
      // validated above for the faults it can raise; only its character type is
      // skipped. Symmetric to the constant-NULL pattern `vanishes` exemption.
      if constant(operand, routines) == .null { break }
      try character(operand, type, routines)
      if case let .expression(pattern) = pattern {
        try character(pattern, try validate(pattern, routines,
                                            subquery: subquery), routines)
      }
    case let .between(test, lower, upper, _):
      // `x [NOT] BETWEEN a AND b` compares `x` against both bounds, so validate
      // the three operands for real errors (an unknown column, a bad call) and
      // check each reached bound is comparable to `x` — an incomparable bound
      // faults 42804, the fault the run's `ranged` raises.
      //
      // It respects the executor's short-circuit — the same one `ranged`
      // evaluates with: a definitely-FALSE lower comparison (`x >= a`) settles
      // the whole truth (BETWEEN FALSE, NOT BETWEEN TRUE — the latter is the
      // negation of that truth, not the divergent `x < a OR x > b` expansion),
      // leaving `upper` unreachable for both spellings, so `upper` is NOT
      // validated — `0 BETWEEN 1 AND (1 / 0)` type-checks, the lower `0 >= 1`
      // FALSE settling the row before the `1 / 0` upper is reached, exactly as
      // an `AND`'s constant-false left leaves its right unchecked.
      let type = try validate(test, routines, subquery: subquery)
      try validate(lower, routines, subquery: subquery)
      // `x BETWEEN a AND b` compares `x` against both bounds, so each bound
      // must be comparable to `x` — an incomparable one faults 42804, the fault
      // the run's `ranged` raises. The lower is always compared; the upper only
      // when the lower does not settle the truth (the same short-circuit
      // `ranged` makes), so `0 BETWEEN 1 AND 'z'` faults only if `0 >= 1` does
      // not settle it first.
      if case let .expression(low) = lower {
        let bound = try validate(low, routines, subquery: subquery)
        try comparable(test, type, low, bound, routines)
      }
      let settled = {
        guard let value = constant(test, routines),
            let low = constant(lower, routines) else {
          return false
        }
        return ((try? matches(value, .geq, low)) ?? nil) == false
      }()
      if !settled {
        try validate(upper, routines, subquery: subquery)
        if case let .expression(high) = upper {
          let bound = try validate(high, routines, subquery: subquery)
          try comparable(test, type, high, bound, routines)
        }
      }
    case let .distinct(lhs, rhs, _):
      // `a IS [NOT] DISTINCT FROM b` compares both operands, so validate the
      // two for real errors (an unknown column, a bad call). both are always
      // validated — the predicate is two-valued with no short-circuit: neither
      // side settles the truth without the other. A cross-kind pair is NOT
      // rejected: the run's `distinct` treats it as DISTINCT without faulting
      // (as an `IN` element does), so the schema check accepts what the run
      // accepts.
      _ = try validate(lhs, routines, subquery: subquery)
      _ = try validate(rhs, routines, subquery: subquery)
    case let .truth(inner, _, _):
      // `p IS [NOT] <truth value>` validates its inner boolean predicate for
      // real errors; the truth mapping cannot itself fault, so it adds no
      // further check.
      try check(inner, routines, subquery: subquery)
    case let .and(lhs, rhs):
      // A connective recurses reachability-aware — the `constant` short-circuit
      // is the run's own, so an unreached operand is not checked.
      try check(lhs, routines, subquery: subquery)
      if constant(lhs, routines) != false {
        try check(rhs, routines, subquery: subquery)
      }
    case let .or(lhs, rhs):
      try check(lhs, routines, subquery: subquery)
      if constant(lhs, routines) != true {
        try check(rhs, routines, subquery: subquery)
      }
    case let .not(operand):
      try check(operand, routines, subquery: subquery)
    }
  }

  /// Faults `SQLError.state` `42804` when the two comparison operands have
  /// incomparable declared types — the ISO 9075 comparability rule a
  /// `<comparison predicate>` (and `BETWEEN`, `IN`, quantified, and row
  /// comparison) requires of its operands. A numeric integer/double pair and
  /// any like-kind pair unify and are comparable; every other cross-kind pair
  /// (a number against a string, a boolean against a blob) is a data-type
  /// mismatch, faulted here exactly where the run's `matches`/`relate` faults
  /// it, so `run ≡ columns(of: validate:)`.
  ///
  /// An operand that folds to a constant NULL, or is a subquery, is exempt: the
  /// run reads a NULL comparison as UNKNOWN (never a fault, so a `text = NULL`
  /// must not be rejected here even though a bare `NULL` types nominally
  /// `.integer`), and a subquery operand's static single-column type may itself
  /// be a nominal-NULL placeholder — so the run, which faults per cross-kind
  /// row through `relate`, stays the authority for a subquery operand.
  private func comparable(_ lhs: Expression, _ l: ValueType,
                          _ rhs: Expression, _ r: ValueType,
                          _ routines: Routines) throws(SQLError) {
    guard !exempt(lhs, routines), !exempt(rhs, routines) else { return }
    guard l.unified(with: r) != nil else {
      throw .state("42804", "cannot compare \(l.domain) with \(r.domain)")
    }
  }

  /// Faults `SQLError.state` `42804` when `expression` (of derived type `type`)
  /// is not a character operand — the ISO rule a `LIKE` operand and pattern are
  /// character strings, the same non-text fault the run's `like` raises. A
  /// constant-NULL or subquery operand is exempt (the run reads NULL as UNKNOWN
  /// and defers a subquery to `relate`), matching `comparable`.
  private func character(_ expression: Expression, _ type: ValueType,
                         _ routines: Routines) throws(SQLError) {
    guard !exempt(expression, routines), type != .text else { return }
    throw .state("42804", "LIKE requires character operands")
  }

  /// Whether a `LIKE` pattern or escape `operand` reads as NULL — or may read
  /// as NULL, or be unbound — at run, so the whole predicate is UNKNOWN before
  /// the run's non-character fallback and neither the subject's nor the
  /// pattern's character type is enforced. It is `true` for a constant-NULL
  /// `.expression` (`K LIKE NULL`, `K LIKE 'x' ESCAPE NULL`, integer `K`, run
  /// and select nothing) and for a `.parameter` (its value arrives from the
  /// bindings, possibly NULL or unbound, so the run stays the authority for its
  /// per-run kind — an unbound or NULL one selects nothing, a non-character
  /// bound one faults 42804 at run, exactly as `Predicate.bound` defers a
  /// comparison to the run). A `nil` escape, or any non-NULL, non-parameter
  /// expression is not NULL, so the character check still applies. It is the
  /// same deferral `exempt` reads for a comparison operand, widened by the
  /// per-run `.parameter` kind LIKE carries.
  private func vanishes(_ operand: Predicate.Operand?,
                        _ routines: Routines) -> Bool {
    switch operand {
    case .none:
      return false
    case .some(.parameter):
      return true
    case let .some(.expression(expression)):
      return constant(expression, routines) == .null
    }
  }

  /// Whether `expression` is exempt from the comparability check — a subquery
  /// (whose static single-column type may be a nominal-NULL placeholder) or an
  /// expression that folds to a constant NULL (read as UNKNOWN by the run,
  /// never a fault).
  private func exempt(_ expression: Expression, _ routines: Routines) -> Bool {
    if case .subquery = expression { return true }
    return constant(expression, routines) == .null
  }

  /// Type-checks a `LIKE` pattern or escape `operand` for the side effect of
  /// validation: an expression is validated (`validate`), a `:parameter` reads
  /// nothing at compile time (its value arrives from the bindings at run time),
  /// so it needs no check, as a `Predicate.bound` parameter needs none.
  private func validate(_ operand: Predicate.Operand, _ routines: Routines,
                        subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    if case let .expression(expression) = operand {
      _ = try validate(expression, routines, subquery: subquery)
    }
  }

  /// Rejects a statically-invalid `LIKE` `escape` at validation, as `Row.like`
  /// would fault it on every row: a ROW-independent escape expression that
  /// folds (`constant`) to a value that is neither NULL (a valid UNKNOWN) nor a
  /// single-character text (a non-text, or a wrong-length text) makes the query
  /// un-runnable, so reject it here with the same message and condition the run
  /// raises. A `:parameter`, a column, or any other non-constant escape is per
  /// row and cannot be decided statically (`constant` is `nil`) — the run
  /// validates it.
  private func reject(_ escape: Predicate.Operand, _ routines: Routines)
      throws(SQLError) {
    guard case let .expression(expression) = escape,
        let value = constant(expression, routines) else {
      return
    }
    switch value {
    case .null:
      break
    case let .text(text) where text.count == 1:
      break
    default:
      throw .argument("LIKE ESCAPE must be a single character")
    }
  }

  /// The definite truth of the equality `operand = value` when both fold to
  /// ROW-independent constants (via `constant`) — the OR-chain equality an `IN`
  /// element folds to — else `nil` (a side reading a row is decided per row).
  /// It folds each side through `constant` — the same `value(of:)`, arithmetic,
  /// and comparison the run evaluates a `left = element` comparison with — so a
  /// `true` here is a definite match that short-circuits the chain.
  private func matched(_ operand: Expression, _ value: Expression,
                       _ routines: Routines) -> Bool? {
    guard let lhs = constant(operand, routines),
        let rhs = constant(value, routines) else {
      return nil
    }
    // A pure reachability fold: an incomparable constant pair is undecided
    // (`nil`) here, its 42804 fault raised by the comparability `check`.
    return (try? matches(lhs, .equal, rhs)) ?? nil
  }

  /// Whether `expression` yields the same value at every one of its textual
  /// occurrences within a single row's (or group's) evaluation — the stability
  /// the reflexive membership shortcut in `check`'s `.membership` walk relies
  /// on. That walk treats an element structurally equal to the `IN` operand
  /// (`K IN (K, …)`) as a definite per-row match that stops the walk, but the
  /// run evaluates the operand and that element independently, so the shortcut
  /// is sound only when both evaluations always agree. This differs from
  /// `constant(_ expression:)`: a column is not row-independent (it does not
  /// fold to a `Value`) yet it is stable — reading the same cell twice — so a
  /// stability test, not constancy, is what the shortcut needs.
  ///
  /// A column reads the same cell, a literal is fixed, and GROUPING lowers to a
  /// per-arm compile-time integer constant, so each is stable. Arithmetic, a
  /// `CAST`, a `COALESCE`, a `NULLIF`, and a `CASE` over stable sub-expressions
  /// stay stable, so `K + 1 IN (K + 1, 'x')` still short-circuits. A scalar
  /// `call` is re-evaluated per occurrence, so it is stable only when the
  /// routine is deterministic and every argument is stable — a non-
  /// deterministic (or unregistered) routine, or a non-stable argument, lets
  /// two calls disagree, so `tick() IN (tick(), 'x')` must reach the cross-kind
  /// `'x'`. An aggregate is stable when its aggregand and `FILTER` are (a non-
  /// deterministic aggregand two occurrences fold over the group to values that
  /// can disagree). A subquery is conservatively not stable — no reflexive
  /// shortcut over a subquery operand, which is safe: the walk keeps
  /// considering later elements, never wrongly pruning one.
  private func stable(_ expression: Expression, _ routines: Routines) -> Bool {
    switch expression {
    case .column, .literal, .grouping:
      true
    case let .call(name, arguments):
      routines[name]?.deterministic == true
          && arguments.allSatisfy { stable($0, routines) }
    case let .binary(_, lhs, rhs):
      stable(lhs, routines) && stable(rhs, routines)
    case let .aggregate(_, aggregand, _, filter):
      stable(aggregand, routines)
          && (filter.map { stable($0, routines) } ?? true)
    case let .case(whens, otherwise):
      whens.allSatisfy {
        stable($0.when, routines) && stable($0.then, routines)
      } && (otherwise.map { stable($0, routines) } ?? true)
    case let .cast(operand, _):
      stable(operand, routines)
    case let .coalesce(arguments):
      arguments.allSatisfy { stable($0, routines) }
    case let .nullif(lhs, rhs):
      stable(lhs, routines) && stable(rhs, routines)
    case .subquery:
      false
    }
  }

  /// An aggregand is stable when its expression is (`COUNT(*)` names no
  /// expression, so it is trivially stable).
  private func stable(_ aggregand: Aggregand, _ routines: Routines) -> Bool {
    switch aggregand {
    case .star:
      true
    case let .expression(expression):
      stable(expression, routines)
    }
  }

  /// Whether `operand` (a `LIKE`/`BETWEEN` operand) is stable: an expression
  /// defers to the expression rule, a `:parameter` is fixed for the whole run.
  private func stable(_ operand: Predicate.Operand, _ routines: Routines)
      -> Bool {
    switch operand {
    case let .expression(expression):
      stable(expression, routines)
    case .parameter:
      true
    }
  }

  /// Whether `predicate` yields the same truth at every occurrence within one
  /// evaluation — the stability rule extended to a `CASE` guard or an aggregate
  /// `FILTER`. A `:parameter` is fixed per run; a subquery predicate
  /// (`EXISTS`/`IN (Q)`/quantified) is conservatively not stable.
  private func stable(_ predicate: Predicate, _ routines: Routines) -> Bool {
    switch predicate {
    case let .comparison(left, _, right):
      stable(left, routines) && stable(right, routines)
    case let .bound(left, _, _):
      stable(left, routines)
    case let .null(operand, _):
      stable(operand, routines)
    case let .membership(operand, values, _):
      stable(operand, routines) && values.allSatisfy { stable($0, routines) }
    case let .rows(lhs, _, rhs):
      lhs.allSatisfy { stable($0, routines) }
          && rhs.allSatisfy { stable($0, routines) }
    case let .among(lhs, rows, _):
      lhs.allSatisfy { stable($0, routines) }
          && rows.allSatisfy { row in row.allSatisfy { stable($0, routines) } }
    case let .like(operand, pattern, escape, _):
      stable(operand, routines) && stable(pattern, routines)
          && (escape.map { stable($0, routines) } ?? true)
    case let .between(test, lower, upper, _):
      stable(test, routines) && stable(lower, routines)
          && stable(upper, routines)
    case let .distinct(lhs, rhs, _):
      stable(lhs, routines) && stable(rhs, routines)
    case let .truth(inner, _, _):
      stable(inner, routines)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      stable(lhs, routines) && stable(rhs, routines)
    case let .not(operand):
      stable(operand, routines)
    case .exists, .within, .quantified:
      false
    }
  }

  /// Whether `expression` is provably non-NULL — it yields a value on every
  /// row, never NULL. Conservative: an undecidable case is treated as nullable
  /// (`false`), so a caller pruning on non-nullness never prunes a row a NULL
  /// could reach. The reflexive membership shortcut reads it: `operand IN
  /// (operand, …)` short-circuits at `operand = operand` only when the operand
  /// is non-NULL (a NULL makes it UNKNOWN, so the run reaches the later
  /// elements), so only a provably non-NULL operand may prune them.
  ///
  /// A non-NULL literal is non-NULL, and a `GROUPING` is a settled non-NULL
  /// integer. Arithmetic and a `CAST` over non-NULL operands stay non-NULL — a
  /// fault throws rather than yielding NULL. A `COALESCE` is non-NULL when any
  /// argument is, since it returns the first non-NULL one. A `CASE` is non-NULL
  /// when it has an `ELSE` and every result arm (each `THEN` and the `ELSE`) is
  /// non-NULL — a no-match `CASE` without `ELSE` yields NULL. Everything else
  /// is treated as nullable: a `column` carries no NOT NULL schema flag (the
  /// engine does not track column nullability), a `NULLIF` yields NULL on an
  /// equal pair, and a `call`, `aggregate`, or `subquery` can yield NULL.
  private func defined(_ expression: Expression) -> Bool {
    switch expression {
    case let .literal(literal):
      if case .null = literal { false } else { true }
    case .grouping:
      true
    case let .binary(_, lhs, rhs):
      defined(lhs) && defined(rhs)
    case let .cast(operand, _):
      defined(operand)
    case let .coalesce(arguments):
      arguments.contains { defined($0) }
    case let .case(whens, otherwise):
      (otherwise.map { defined($0) } ?? false)
          && whens.allSatisfy { defined($0.then) }
    case .column, .call, .aggregate, .nullif, .subquery:
      false
    }
  }

  /// The constant `Value` `expression` folds to when it is ROW-independent —
  /// else `nil` (an operand a row, group, or run context decides). A literal
  /// folds to its value; a binary folds its two operands and applies the same
  /// `Arithmetic.apply(Value, Value)` the run's binary evaluation uses, so the
  /// fold matches the run exactly (and a would-be fault — a divide, an overflow
  /// — collapses to `nil` rather than deciding a match). A ROW-independent call
  /// to a deterministic routine (every argument folds constant) folds to its
  /// routine's value over those folded arguments — the same `Routine` the run
  /// invokes over the same constant arguments, so the fold matches the run; an
  /// unregistered name, a NOT deterministic routine, a non-constant argument,
  /// or a throwing routine collapses to `nil`. Only a deterministic routine
  /// folds (ISO): executing a non-deterministic one here could return one value
  /// while this compile-time walk decides reachability and a different one when
  /// the run reaches the same call — pruning an element the run keeps. Every
  /// other expression is not statically foldable: a `column` reads a row and an
  /// `aggregate` folds a group, so each is `nil`. A ROW-independent `case`
  /// folds too — walking the `WHEN`s in order over `constant(_ predicate:)`:
  /// the first constant-TRUE guard yields its folded result, a constant-FALSE
  /// guard is skipped, and a guard the fold cannot decide (`nil`) means the
  /// taken branch is per row, so the whole `case` is `nil`; with no
  /// constant-TRUE guard it folds the `ELSE`, or `.null` when there is none (a
  /// no-match `CASE` yields NULL). This honours the same reachability
  /// `reachable(_:_:_:)` validates with. Returning `nil` is sound — a caller
  /// that cannot fold an element keeps considering it, never wrongly pruning a
  /// later one.
  private func constant(_ expression: Expression, _ routines: Routines)
      -> Value? {
    switch expression {
    case let .literal(literal):
      return try? SQLEngine.value(of: literal)
    case let .binary(op, lhs, rhs):
      guard let lhs = constant(lhs, routines),
          let rhs = constant(rhs, routines) else {
        return nil
      }
      return try? op.apply(lhs, rhs)
    case let .call(name, arguments):
      guard let routine = routines[name], routine.deterministic else {
        return nil
      }
      var values = Array<Value>()
      values.reserveCapacity(arguments.count)
      for argument in arguments {
        guard let value = constant(argument, routines) else { return nil }
        values.append(value)
      }
      guard let result = try? routine(values) else { return nil }
      // A routine call bypasses `Arithmetic.apply`'s finite check, so a
      // non-finite double is not a definite value the run would accept — it
      // faults there — so do not claim a match: fold to `nil` (parity with
      // `empty(_:_:)`, which rejects the same non-finite result).
      if case let .double(number) = result, !number.isFinite { return nil }
      return result
    case let .case(whens, otherwise):
      for branch in whens {
        switch constant(branch.when, routines) {
        case false: continue
        case true: return constant(branch.then, routines)
        case nil: return nil
        }
      }
      guard let otherwise else { return .null }
      return constant(otherwise, routines)
    case let .cast(operand, type):
      // A ROW-independent operand folds to its converted value — the same
      // `Value.cast(to:)` the run applies, so the fold matches. A would-be
      // fault (an unconvertible value) collapses to `nil`, so the cast stays
      // undecided rather than deciding a match, just as a would-be-faulting
      // binary fold does.
      guard let value = constant(operand, routines) else { return nil }
      return try? value.cast(to: type)
    case let .coalesce(arguments):
      // Fold as the run evaluates it — the first argument that folds to a
      // non-NULL value (coerced to the unified type, as the executor's
      // `Term.coalesce` coerces the selected value), else NULL when every
      // argument folds NULL. An argument the fold cannot decide (`nil`) before
      // a decisive non-NULL one means the taken value is per row, so the whole
      // `COALESCE` is `nil`. Coercing an `.integer` selected from a COALESCE
      // that unifies to `.double` folds to `.double`, matching the advertised
      // column type — so a `.double`-typed routine over `COALESCE(1, 2.5)`
      // folds against the same value the run supplies. The unified type is the
      // one `derive`/`unified` already reduces over the selectable arguments;
      // an irreconcilable pair (which `derive` would fault on) leaves the value
      // uncoerced (`try?` → `nil`), a no-op the executor never reaches.
      let type = try? unified(arguments, routines)
      for argument in arguments {
        guard let value = constant(argument, routines) else { return nil }
        if case .null = value { continue }
        return type.map { value.coerced(to: $0) } ?? value
      }
      return .null
    case let .nullif(lhs, rhs):
      // Fold as the run evaluates it — NULL when `v1 = v2` folds definitely
      // TRUE, else `v1`; a side the fold cannot decide leaves it per row
      // (`nil`).
      guard let va = constant(lhs, routines),
          let vb = constant(rhs, routines) else {
        return nil
      }
      // An incomparable `v1 = v2` is a would-be `42804` fault, so leave the
      // fold undecided (`nil`) rather than deciding it is `va` — a soundness
      // guard matching the divide/overflow collapse, so the reachability walk
      // never prunes a branch the run would fault.
      guard let equal = try? matches(va, .equal, vb) else { return nil }
      return equal == true ? .null : va
    case .column, .aggregate, .subquery, .grouping:
      // A `subquery` is row-independent but is materialised at run (this
      // compile-time fold has no cache), so it is not statically foldable —
      // `nil`, like a `column` or `aggregate`. A `grouping` is constant only
      // relative to a specific grouped ARM (this AST-level fold has no arm
      // context), so it too is `nil` here — decided later by `Grouped.term`.
      return nil
    }
  }

  /// Whether `expression` folds to a constant NULL for every row — a projected
  /// column that places no type constraint on a set-operation's unified column,
  /// so the fold skips its (literal-fix) type exactly as `COALESCE` skips a
  /// constant-NULL argument. The projection walk (`output(_ item:)`) reads this
  /// beside its type derive, so a column's type and its `unconstrained` mask
  /// come from one resolution over the same expression and cannot diverge.
  ///
  /// A `CASE` every reachable result of which is NULL yields NULL whichever
  /// branch runs, so it is constant NULL even when a row-dependent guard leaves
  /// the whole-expression `constant` fold undecided (`nil`) — `CASE WHEN Id = 1
  /// THEN NULL ELSE NULL END` is unconstrained, so it unifies with a text arm in
  /// a set operation rather than hard-typing the placeholder integer.
  internal func null(_ expression: Expression, _ routines: Routines) -> Bool {
    if case .some(.null) = constant(expression, routines) { return true }
    if case let .case(whens, otherwise) = expression {
      return reachable(whens, otherwise, routines)
          .allSatisfy { null($0, routines) }
    }
    return false
  }

  /// Whether evaluating `expression` would dispatch an invalid routine call —
  /// the tree contains, at ANY depth, a `.call(name, _)` that is unregistered
  /// (`routines[name] == nil`) or invalid for its routine (bad arity or a
  /// definitively-wrong argument type). Such a call has no genuine return type
  /// (`derive` fabricates the declared `returns`, or the `.integer` default for
  /// a missing name), yet the run faults on it (`SQLError.function` for the
  /// missing name, `SQLError.argument` for the bad arity/type), so a projection
  /// over it places no type constraint on a set-operation's unified column:
  /// mark it unconstrained and let the fold defer to the other arm rather than
  /// fault on the fabricated type. This is sound either way — if the arm is
  /// reached the run dispatches it and faults, and if it is NOT reached (a
  /// zero-row limit, a filtered-out arm) the expression is never evaluated, so
  /// its fabricated type is irrelevant. Only an invalid call trips it, so a
  /// valid call (correct arity and argument types) stays constrained — its
  /// declared `returns` still shapes the fold — and a genuine type mismatch
  /// still faults `SQLError.operand` (42804).
  ///
  /// It mirrors `derive`'s expression arms exactly so no form escapes: a bare
  /// call is the depth-0 case of the `.call` arm, and every composite arm
  /// recurses the same sub-expressions `derive` traverses.
  internal func unresolved(_ expression: Expression,
                           _ routines: Routines) -> Bool {
    switch expression {
    // `.column`/`.literal`: no call, so never unresolved — mirroring
    // `derive`'s leaf arms, which fabricate no routine type.
    case .column, .literal:
      return false
    // `.call`: the depth-0 case (an unregistered name), OR an unregistered
    // call nested in an argument — subsuming the former bare-call special case
    // in `output(_ item:)`. An invalid call to an existing routine (bad arity
    // or a definitively-wrong argument type) is treated like a missing one:
    // `derive` fabricates the declared `returns` for it, but the run faults
    // (`SQLError.argument`), so its type must not constrain the fold. This
    // mirrors the strict validator `call(_:over:_:)`'s arity/type guards as a
    // non-throwing probe.
    case let .call(name, arguments):
      guard let routine = routines[name] else { return true }
      guard (routine.minimum ... routine.parameters.count)
          .contains(arguments.count) else { return true }
      if arguments.contains(where: { unresolved($0, routines) }) { return true }
      for (argument, expected) in zip(arguments, routine.parameters) {
        guard let type = try? derive(argument, routines) else { return true }
        if type != expected { return true }
      }
      return false
    // `.binary` (arithmetic AND `||`): both derive arms derive both operands.
    case let .binary(_, lhs, rhs):
      return unresolved(lhs, routines) || unresolved(rhs, routines)
    // `.aggregate`: `derive` recurses only the operand (a `.star` counts
    // rows, deriving nothing); the `filter` is a `Predicate`, not shaping the
    // derived type.
    case let .aggregate(_, operand, _, _):
      switch operand {
      case .star: return false
      case let .expression(argument): return unresolved(argument, routines)
      }
    // `.case`: `derive` unifies only the reachable result expressions
    // (`reachable`), so mirror that reach — an unregistered call in an
    // unreachable branch never runs and never shapes the type.
    case let .case(whens, otherwise):
      return reachable(whens, otherwise, routines)
          .contains { unresolved($0, routines) }
    // `.cast`: `derive` recurses the operand for its resolution.
    case let .cast(operand, _):
      return unresolved(operand, routines)
    // `.coalesce`: `derive` (`unified`) scans only the reachable prefix — it
    // stops at the first argument a constant non-NULL value `selects`, so a
    // later argument never runs nor shapes the type. Mirror that reach, else
    // `COALESCE(1, missing())` wrongly defers instead of constraining `1`.
    case let .coalesce(arguments):
      for argument in arguments {
        if unresolved(argument, routines) { return true }
        if selects(argument, routines) { break }
      }
      return false
    // `.nullif`: `derive` (`nullif`) derives both operands.
    case let .nullif(lhs, rhs):
      return unresolved(lhs, routines) || unresolved(rhs, routines)
    // `.subquery`: a nested scalar subquery resolves its own columns through
    // the memo (`scalar(resolved:)`), which already carries the unconstrained
    // mask for any unregistered call inside it — do NOT double-handle it here.
    case .subquery:
      return false
    // `.grouping`: `derive` types it `.integer` as a leaf (it does not derive
    // the arguments, exactly as a `call` types from its declared return), so it
    // fabricates no routine type and constrains the fold — never unresolved.
    case .grouping:
      return false
    }
  }

  /// The constant `Value`s a ROW `row` folds to when every component is
  /// row-independent — else `nil` (any component a row/group/run decides). A
  /// row comparison and a row `IN` element fold through this so a single row-
  /// dependent component leaves the whole row undecided, matching the runtime's
  /// whole-row evaluation.
  private func constants(_ row: Array<Expression>, _ routines: Routines)
      -> Array<Value>? {
    var values = Array<Value>()
    values.reserveCapacity(row.count)
    for expression in row {
      guard let value = constant(expression, routines) else { return nil }
      values.append(value)
    }
    return values
  }

  /// Folds an `IN` value list as its OR-chain of `operand = element`
  /// equalities, honouring the executor's short-circuit: the elements are
  /// visited in order, each mapped to its three-valued equality truth by
  /// `equality`, and the truths are OR-folded — but a definite `true` stops the
  /// walk, since the OR-chain matches there and every later element is
  /// unreachable (`Row.matches` returns on the first true arm). This is the one
  /// short-circuit the `IN` type-check (`check`), constant fold (`constant`),
  /// and empty-group evaluator (`empty`) all share: each supplies the
  /// per-element `equality` its surface computes with, and every surface stops
  /// at the same element the run does.
  ///
  /// `visit` runs on each element before its truth is taken, so a surface with
  /// a per-element side effect (validation) applies it to exactly the reachable
  /// prefix. The fold seeds FALSE (an empty match is FALSE), so the returned
  /// truth is the disjunction over the visited prefix.
  ///
  /// The element is generic — a scalar value list supplies an `Expression` per
  /// element, a row `IN` a whole `Array<Expression>` row — so the same
  /// short-circuit drives the scalar `.membership` and the row `.among` folds,
  /// the tuple-equality via `relate` standing in for the scalar equality.
  private func membership<Element, E: Error>(
      of elements: Array<Element>,
      each visit: (Element) throws(E) -> Void = { (_: Element) in },
      equality: (Element) throws(E) -> Bool?)
      throws(E) -> Bool? {
    var truth: Bool? = false
    for element in elements {
      try visit(element)
      truth = or(truth, try equality(element))
      // A definite match makes every later element unreachable — the OR-chain
      // short-circuits here, exactly as the run does.
      if truth == true { break }
    }
    return truth
  }

  /// The definite constant truth value of `predicate` when it is statically
  /// decidable — a comparison or `IS [NOT] NULL` whose operands fold to
  /// ROW-independent `Value`s (via `constant(_ expression:)`: literals,
  /// arithmetic, deterministic calls, nested `CASE`s), composed through
  /// `AND`/`OR`/`NOT`/`IN` — else `nil` (a predicate reading a column or a
  /// `:parameter` is decided per row). `check(_:_:)` reads it to skip an arm
  /// the executor's short-circuit proves unreachable, matching `matches` and
  /// `value(of:)`, the primitives the run itself evaluates a comparison with.
  /// Folding each operand through `constant(_ expression:)` carries its
  /// determinism gate: a non-deterministic call operand folds to `nil`, so the
  /// comparison stays undecided (`nil`) rather than deciding a match the run
  /// might not make.
  func constant(_ predicate: Predicate, _ routines: Routines) -> Bool? {
    switch predicate {
    case let .comparison(left, op, right):
      guard let lhs = constant(left, routines),
          let rhs = constant(right, routines) else {
        return nil
      }
      // A pure reachability fold: an incomparable pair is undecided (`nil`)
      // here, its 42804 fault raised by the comparability check in `check`.
      return (try? matches(lhs, op, rhs)) ?? nil
    case let .and(lhs, rhs):
      // `constant` is a pure fold with no side effect, so both arms evaluate.
      return and(constant(lhs, routines), constant(rhs, routines))
    case let .or(lhs, rhs):
      return or(constant(lhs, routines), constant(rhs, routines))
    case let .not(operand):
      guard let value = constant(operand, routines) else { return nil }
      return !value
    case let .null(operand, negated):
      // A ROW-independent operand that folds to a concrete value is not NULL;
      // one that folds to `.null` (a NULL literal, or a deterministic routine
      // returning NULL) is NULL — matching the run. An operand the fold cannot
      // decide (`nil`) is per row, so the truth is too. This mirrors
      // `empty(_ predicate:)`'s `.null` arm, which folds via `empty(operand)`.
      guard let value = constant(operand, routines) else { return nil }
      let null = if case .null = value { true } else { false }
      return negated ? !null : null
    case let .membership(operand, values, negated):
      // Fold `x IN (…)` exactly as its OR-chain of equalities folds — the same
      // primitives (`matched`/`constant`, `matches`, `membership`'s
      // short-circuit) — honouring the OR-chain's short-circuit: once a
      // ROW-independent element definitely equals the constant operand the fold
      // is `true`, so a later row-dependent element (which alone would make the
      // fold per-row `nil`) is unreachable and does not spoil it —
      // `1 IN (1 + 0, Name + 1)` folds `true`. Absent a decisive match, any
      // row-dependent element makes it per row (`nil`). `NOT IN` negates the
      // folded truth (UNKNOWN maps to itself).
      let truth = membership(of: values) { value in
        matched(operand, value, routines)
      }
      return negated ? truth.map { !$0 } : truth
    case let .like(operand, pattern, escape, negated):
      // Fold `x LIKE p` when the operand, pattern, and optional escape all fold
      // to ROW-independent constants — the same `constant(_ expression:)` the
      // run's terms evaluate through — running the same matcher `Row.like`
      // does; any row-dependent operand leaves it per row (`nil`). `NOT LIKE`
      // negates the folded truth (UNKNOWN maps to itself).
      guard let truth = matched(operand, pattern, escape, routines) else {
        return nil
      }
      return negated ? !truth : truth
    case let .between(test, lower, upper, negated):
      // Fold `x [NOT] BETWEEN a AND b` as `ranged` evaluates it: BETWEEN is the
      // Kleene `x >= a AND x <= b`, and NOT BETWEEN its negation (not the
      // `x < a OR x > b` expansion, which diverges on a cross-kind bound — see
      // `ranged`). The folded `x >= a` short-circuits before the upper: a
      // definitely-FALSE one settles BETWEEN FALSE (and NOT BETWEEN TRUE)
      // without folding the upper — or any fault it carries — so
      // `0 BETWEEN 1 AND (1 / 0)` folds definitely FALSE rather than `nil`. A
      // side the fold cannot decide leaves it per row (`nil`).
      guard let value = constant(test, routines),
          let low = constant(lower, routines) else {
        return nil
      }
      let above = (try? matches(value, .geq, low)) ?? nil
      if above == false { return negated }
      guard let high = constant(upper, routines) else { return nil }
      let within = and(above, (try? matches(value, .leq, high)) ?? nil)
      return negated ? within.map { !$0 } : within
    case let .distinct(lhs, rhs, negated):
      // Fold `a IS [NOT] DISTINCT FROM b` as `differs` evaluates it: the
      // null-safe `distinct` of the two folded values, negated for `IS NOT`.
      // It is two-valued, so when both sides fold to ROW-independent constants
      // the truth is definite; a row-dependent side leaves it per row (`nil`).
      guard let lhs = constant(lhs, routines),
          let rhs = constant(rhs, routines) else {
        return nil
      }
      let differ = distinct(lhs, rhs)
      return negated ? !differ : differ
    case let .truth(inner, value, negated):
      // Fold `p IS [NOT] <truth value>` whenever the inner boolean is ROW-
      // independent. `constant` gives its definite truth; and a `nil` from it
      // over a `settled` inner (every operand a constant) is a definite UNKNOWN
      // — NOT a per-row deferral — which `tested` maps to a definite result
      // (`p IS UNKNOWN` TRUE, `p IS TRUE` FALSE), so a constant-UNKNOWN test
      // short-circuits/type-checks as the run does rather than deferring and
      // validating an unreachable conjunct.
      let folded = constant(inner, routines)
      if folded != nil || settled(inner, routines) {
        return tested(folded, value, negated)
      }
      // An `IS [NOT] UNKNOWN` test folds even over a ROW-dependent inner when
      // the inner is definite (two-valued — `IS NULL`, `IS DISTINCT FROM`,
      // another truth test, and their `AND`/`OR`/`NOT`, never take UNKNOWN):
      // such an inner is never the third value the test checks for, so
      // `p IS UNKNOWN` is definitely FALSE and `p IS NOT UNKNOWN` definitely
      // TRUE regardless of the rows — `(Flag IS NULL) IS UNKNOWN` folds FALSE.
      // A `TRUE`/`FALSE` test still turns on the inner's per-row value, so it
      // stays per row.
      if value == .unknown, definite(inner) { return negated }
      return nil
    case .bound:
      return nil
    case let .rows(lhs, op, rhs):
      // Fold `(l…) <op> (r…)` exactly as the scalar `.comparison` folds — each
      // component of both rows folds through `constant(_ expression:)`, then
      // the folded values combine through the shared `relate` primitive the run
      // (`Filter.comparison`) and the empty-group pre-fold drive, so the fold
      // matches the run. A single row-dependent component (`nil`) leaves the
      // whole comparison per row (`nil`), so both `AND` arms stay reachable; an
      // all-constant pair settles it, so a constant-false row guard prunes its
      // right arm as `1 = 0 AND …` does.
      guard let l = constants(lhs, routines),
          let r = constants(rhs, routines) else {
        return nil
      }
      return (try? relate(l, op, r)) ?? nil
    case let .among(lhs, rows, negated):
      // Fold `(l…) [NOT] IN ((r…), …)` exactly as the scalar `.membership`
      // folds — the left row folds through `constant(_ expression:)`, then the
      // element rows OR-fold under the `membership` short-circuit: an element
      // whose components ALL fold constant contributes its tuple-equality
      // (`relate(l, =, r)`, the same shared primitive), and once one folds
      // definitely TRUE the walk stops, so a later row-dependent element is
      // unreachable and does not spoil it — `(1, 2) IN ((1, 2), (Name + 1, 3))`
      // folds `true`. Absent a decisive match, a row-dependent element makes it
      // per row (`nil`); a row-dependent LEFT row leaves the whole `IN` per
      // row. `NOT IN` negates the folded truth (UNKNOWN maps to itself).
      guard let l = constants(lhs, routines) else { return nil }
      let truth = membership(of: rows) { element in
        guard let r = constants(element, routines) else { return nil }
        return (try? relate(l, .equal, r)) ?? nil
      }
      return negated ? truth.map { !$0 } : truth
    case .exists, .within, .quantified:
      // A subquery predicate is not a ROW-independent constant fold — its truth
      // is decided by the materialised result at lowering time, not by folding
      // operands here — so it never folds statically; treat it as undecided
      // (per-row) so a reachability walk neither prunes nor faults on it.
      return nil
    }
  }

  /// Whether every operand `predicate` reads folds to a ROW-independent
  /// constant — so its three-valued truth is fully determined at compile time.
  /// When it is and `constant(_ predicate:)` is `nil`, that `nil` is a definite
  /// UNKNOWN (a NULL propagated through constant operands), NOT a per-row
  /// deferral: the distinction `constant`'s `Bool?` cannot carry, which the
  /// truth test needs to fold `p IS UNKNOWN`/`p IS TRUE` over a
  /// constant-UNKNOWN `p`. A row or non-deterministic operand is NOT constant
  /// (`constant(_ expression:)` is `nil`), so it is not settled; a `:parameter`
  /// (`.bound`) is per-run, never settled.
  private func settled(_ predicate: Predicate, _ routines: Routines) -> Bool {
    switch predicate {
    case let .comparison(left, _, right):
      constant(left, routines) != nil && constant(right, routines) != nil
    case let .null(operand, _):
      constant(operand, routines) != nil
    case let .membership(operand, values, _):
      constant(operand, routines) != nil
          && values.allSatisfy { constant($0, routines) != nil }
    case let .like(operand, pattern, escape, _):
      constant(operand, routines) != nil
          && constant(pattern, routines) != nil
          && (escape.map { constant($0, routines) != nil } ?? true)
    case let .between(test, lower, upper, _):
      constant(test, routines) != nil && constant(lower, routines) != nil
          && constant(upper, routines) != nil
    case let .distinct(lhs, rhs, _):
      constant(lhs, routines) != nil && constant(rhs, routines) != nil
    case let .truth(inner, _, _):
      settled(inner, routines)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      settled(lhs, routines) && settled(rhs, routines)
    case let .not(operand):
      settled(operand, routines)
    case .bound:
      false
    case let .rows(lhs, _, rhs):
      // A row comparison is settled when every component of both rows folds to
      // a ROW-independent constant — the row analog of `.comparison`, so a
      // constant-UNKNOWN row comparison (a NULL component) folds a `truth` test
      // definitely rather than deferring it.
      lhs.allSatisfy { constant($0, routines) != nil }
          && rhs.allSatisfy { constant($0, routines) != nil }
    case let .among(lhs, rows, _):
      // A row `IN` is settled when the LEFT row and every element row fold to
      // ROW-independent constants — the row analog of `.membership`.
      lhs.allSatisfy { constant($0, routines) != nil }
          && rows.allSatisfy { element in
            element.allSatisfy { constant($0, routines) != nil }
          }
    case .exists, .within, .quantified:
      // A subquery predicate's truth comes from a materialised result, not from
      // folding constant operands, so it is never settled at compile time.
      false
    }
  }

  /// Whether `predicate` is definite — two-valued, never evaluating to UNKNOWN,
  /// even when it reads row data. `IS [NOT] NULL`, `IS [NOT] DISTINCT FROM`,
  /// and a boolean test all collapse SQL's third value to a definite result by
  /// construction, and `AND`/`OR`/`NOT` of definite predicates stay definite. A
  /// comparison, membership, `LIKE`, `BETWEEN`, or bound parameter can be
  /// UNKNOWN (a NULL operand), so none is definite. This lets an `IS [NOT]
  /// UNKNOWN` test fold — the third value it checks for can never occur — over
  /// a row-dependent inner `settled` cannot reach.
  private func definite(_ predicate: Predicate) -> Bool {
    switch predicate {
    case .null, .distinct, .truth:
      true
    // `EXISTS` is definitely two-valued — a non-empty test never yields UNKNOWN
    // — so it is definite, while `IN (Q)` is three-valued over NULLs (a NULL
    // element or operand makes an unmatched test UNKNOWN), so it is not.
    case .exists:
      true
    // A quantified comparison is three-valued over NULLs exactly as `IN (Q)` —
    // a NULL component makes an undecided fold UNKNOWN — so it is not definite
    // either.
    case .within, .quantified:
      false
    case let .and(lhs, rhs), let .or(lhs, rhs):
      definite(lhs) && definite(rhs)
    case let .not(operand):
      definite(operand)
    // A row-value comparison and row `IN` are three-valued over NULLs — a NULL
    // component makes a componentwise test UNKNOWN — exactly as the scalar
    // `.comparison`/`.membership` are, so neither is definite.
    case .comparison, .membership, .rows, .among, .like, .between, .bound:
      false
    }
  }

  /// The definite truth of `operand LIKE pattern [ESCAPE escape]` when the
  /// operand, pattern, and optional escape all fold to ROW-independent
  /// constants (via `constant(_ expression:)`), else `nil`. It folds each side
  /// and runs the same `matches` the run's `Row.like` does — a NULL side is
  /// UNKNOWN (`nil`), a non-text operand or pattern a definite non-match
  /// (FALSE), a bad escape collapses to `nil` (undecided) rather than faulting
  /// a compile-time reachability walk.
  private func matched(_ operand: Expression, _ pattern: Predicate.Operand,
                       _ escape: Predicate.Operand?, _ routines: Routines)
      -> Bool? {
    guard let operand = constant(operand, routines),
        let pattern = constant(pattern, routines) else {
      return nil
    }
    let character: Character?
    switch escape {
    case .none:
      character = nil
    case let .some(escape):
      switch constant(escape, routines) {
      case let .text(text) where text.count == 1:
        character = text.first
      // A NULL, absent, ill-formed, or `:parameter` escape is not a decidable
      // fold — leave the LIKE per row (`nil`) rather than deciding a match.
      default:
        return nil
      }
    }
    return switch (operand, pattern) {
    case (.null, _), (_, .null):
      nil
    case let (.text(operand), .text(pattern)):
      matches(operand, pattern, escape: character)
    default:
      false
    }
  }

  /// The constant `Value` a `LIKE` pattern or escape `operand` folds to when it
  /// is ROW-independent (`constant(_ expression:)`), else `nil`. A `:parameter`
  /// is per run — its value arrives from the bindings — so it never folds
  /// constant, exactly as a column does.
  private func constant(_ operand: Predicate.Operand, _ routines: Routines)
      -> Value? {
    switch operand {
    case let .expression(expression): constant(expression, routines)
    case .parameter: nil
    }
  }

  // MARK: - Aggregate discovery

  /// Validates the aggregate sub-expressions of `expression` — an aggregate's
  /// fold runs over every row (in the aggregate node) before a `LIMIT`, so it
  /// is reachable even under a zero-row limit — without validating the
  /// surrounding per-result expression a run never reaches. It recurses through
  /// a binary's operands and a call's arguments to reach an aggregate, then
  /// validates it (its operand included); a bare column or literal has none.
  func aggregates(in expression: Expression,
                  _ routines: Routines = [:],
                  subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    switch expression {
    case .column, .literal, .subquery:
      // A scalar `subquery` nests no OUTER aggregate — its inner aggregates are
      // validated within the subquery's own type-check — so it contributes none
      // here, like a bare `column`.
      break
    case let .aggregate(function, operand, _, filter):
      _ = try aggregate(function, over: operand, filter: filter, routines,
                        subquery: subquery)
    case let .call(_, arguments):
      for argument in arguments {
        try aggregates(in: argument, routines, subquery: subquery)
      }
    case let .binary(_, lhs, rhs):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .case(whens, otherwise):
      for branch in whens {
        try aggregates(in: branch.when, routines, subquery: subquery)
        try aggregates(in: branch.then, routines, subquery: subquery)
      }
      if let otherwise {
        try aggregates(in: otherwise, routines, subquery: subquery)
      }
    case let .cast(operand, _):
      try aggregates(in: operand, routines, subquery: subquery)
    case let .coalesce(arguments):
      for argument in arguments {
        try aggregates(in: argument, routines, subquery: subquery)
      }
    case let .nullif(lhs, rhs):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .grouping(arguments):
      // GROUPING is not itself an aggregate, but — like a `call` — recurse its
      // arguments so any aggregate they nest is validated (an aggregate is not
      // a valid GROUPING argument, but the walk mirrors the neighbouring arms).
      for argument in arguments {
        try aggregates(in: argument, routines, subquery: subquery)
      }
    }
  }

  /// Validates the aggregate sub-expressions of a `LIKE` pattern or escape
  /// `operand` — an expression's own, none in a `:parameter`.
  func aggregates(in operand: Predicate.Operand, _ routines: Routines = [:],
                  subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    if case let .expression(expression) = operand {
      try aggregates(in: expression, routines, subquery: subquery)
    }
  }

  /// Validates the aggregate sub-expressions of `predicate` — a `HAVING`'s
  /// aggregates are collected and folded by the group node before the `HAVING`
  /// filter runs, so they are reachable even in an arm the filter's
  /// short-circuit skips. It walks every arm (unlike `check`), reaching an
  /// aggregate through a comparison's operands and `AND`/`OR`/`NOT`.
  func aggregates(in predicate: Predicate,
                  _ routines: Routines = [:],
                  subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      try aggregates(in: left, routines, subquery: subquery)
      try aggregates(in: right, routines, subquery: subquery)
    case let .bound(left, _, _):
      try aggregates(in: left, routines, subquery: subquery)
    case let .null(operand, _):
      try aggregates(in: operand, routines, subquery: subquery)
    case let .membership(operand, values, _):
      try aggregates(in: operand, routines, subquery: subquery)
      for value in values {
        try aggregates(in: value, routines, subquery: subquery)
      }
    case let .rows(lhs, _, rhs):
      for expression in lhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
      for expression in rhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
    case let .among(lhs, rows, _):
      for expression in lhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
      for element in rows {
        for expression in element {
          try aggregates(in: expression, routines, subquery: subquery)
        }
      }
    case .exists:
      // A subquery is its own scope — any aggregate inside it folds over its
      // group, not the enclosing one — so an `EXISTS (Q)` contributes no outer
      // aggregate to collect.
      break
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      // Only the OUTER left-row components may hold an enclosing-group
      // aggregate; the subquery is its own scope, so it is not walked here.
      for expression in lhs {
        try aggregates(in: expression, routines, subquery: subquery)
      }
    case let .like(operand, pattern, escape, _):
      try aggregates(in: operand, routines, subquery: subquery)
      try aggregates(in: pattern, routines, subquery: subquery)
      if let escape {
        try aggregates(in: escape, routines, subquery: subquery)
      }
    case let .between(test, lower, upper, _):
      try aggregates(in: test, routines, subquery: subquery)
      try aggregates(in: lower, routines, subquery: subquery)
      try aggregates(in: upper, routines, subquery: subquery)
    case let .distinct(lhs, rhs, _):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .truth(inner, _, _):
      try aggregates(in: inner, routines, subquery: subquery)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      try aggregates(in: lhs, routines, subquery: subquery)
      try aggregates(in: rhs, routines, subquery: subquery)
    case let .not(operand):
      try aggregates(in: operand, routines, subquery: subquery)
    }
  }

  // MARK: - Constant folding

  /// Validates a whole-result aggregate's projection or sort `expression` over
  /// the single empty group a constant-false `WHERE` leaves — the empty-fold's
  /// per-expression check, dispatching on whether the expression nests a
  /// subquery.
  ///
  /// A subquery-free expression is precisely empty-folded (`empty`): its value
  /// over the empty group is evaluated exactly as a run does, pruning a
  /// statically-decided `CASE` branch (a constant-false guard's arm never
  /// folds, so it cannot fault) — the precise reachability a false-`WHERE`
  /// whole-result aggregate gives its projection.
  ///
  /// An expression that nests a subquery cannot be folded: the empty group
  /// carries no catalog, so a `CASE WHEN EXISTS (Q) …` guard folds UNKNOWN and
  /// its arms would be pruned — but the subquery is row-independent and may be
  /// TRUE at run, running the guarded arm. So validate it as a run would
  /// (`validate`), which validates both arms of a subquery-guarded `CASE` (a
  /// `nil`-constant guard leaves both reachable), surfacing the fault the run
  /// raises — `SELECT CASE WHEN EXISTS (Q) THEN 1 / 0 … WHERE 1 = 0` faults
  /// `.divide`, matching a run that keeps the empty group and evaluates the
  /// THEN arm. This mirrors the `having.subquery` carve-out, extended to
  /// projection and sort expressions.
  func fold(_ expression: Expression, _ routines: Routines = [:],
            subquery: SubqueryCheck = .unsupported)
      throws(SQLError) {
    if expression.subquery {
      _ = try validate(expression, routines, subquery: subquery)
    } else {
      _ = try empty(expression, routines)
    }
  }

  /// The value `expression` yields when a whole-result aggregate projects the
  /// single empty group a constant-false `WHERE` leaves — the fold over zero
  /// rows: `COUNT` is 0, every other aggregate NULL, a literal itself, a binary
  /// the operator applied to its folded operands, a call the routine applied to
  /// its folded arguments. It evaluates the empty group exactly as a run does,
  /// so it raises precisely the run's fault — an unregistered routine
  /// (`SQLError.function`), a bad arity or kind (`SQLError.argument`), a divide
  /// by zero (`SQLError.divide`), an overflow (`SQLError.magnitude`) —
  /// while a NULL operand propagates without faulting. An aggregate's own
  /// operand is never reached (the fold sees no row), and a bare column cannot
  /// appear (a non-grouped column is a grouping error `compile` already
  /// rejected), so a `SUM(text)` is NULL here rather than a type fault.
  func empty(_ expression: Expression, _ routines: Routines = [:])
      throws(SQLError) -> Value {
    switch expression {
    case let .literal(literal):
      return try value(of: literal)
    case let .aggregate(function, _, _, _):
      return function == .count ? .integer(0) : .null
    case let .binary(op, lhs, rhs):
      return try op.apply(empty(lhs, routines), empty(rhs, routines))
    case let .call(name, arguments):
      guard let routine = routines[name] else { throw .function(name) }
      var values = Array<Value>()
      values.reserveCapacity(arguments.count)
      for argument in arguments {
        try values.append(empty(argument, routines))
      }
      let result = try routine(values)
      // A routine call bypasses `Arithmetic.apply`'s finite check, so enforce
      // it here: a non-finite double faults as a run would (magnitude).
      if case let .double(number) = result, !number.isFinite {
        throw .magnitude("function '\(name)' produced a non-finite double")
      }
      return result
    case let .case(whens, otherwise):
      // Evaluate the `CASE` over the empty group exactly as a run does: the
      // first branch whose guard folds TRUE (`empty(predicate)`) yields its
      // result, else the `ELSE`, else `NULL`. A skipped branch's result never
      // folds, so it cannot fault. The selected value is coerced to the CASE's
      // unified result type (`derive`), just as the executor's
      // `Row.conditional` widens it — an `.integer` arm of a CASE that unifies
      // to `.double` folds to `.double`, so the empty group matches the
      // advertised column type. NULL (a no-match, no-ELSE fold) passes through.
      let type = try derive(whens, otherwise, routines)
      for branch in whens where try empty(branch.when, routines) == true {
        return try empty(branch.then, routines).coerced(to: type)
      }
      guard let otherwise else { return .null }
      return try empty(otherwise, routines).coerced(to: type)
    case let .cast(operand, type):
      // Convert the operand's empty-group value exactly as a run does — a NULL
      // (the common empty-group operand) casts to NULL, an unconvertible value
      // faults as the run would.
      return try empty(operand, routines).cast(to: type)
    case let .coalesce(arguments):
      // Evaluate the empty group as a run does — the first argument that folds
      // to a non-NULL value (coerced to the unified type, as the executor
      // coerces the selected value), else NULL. A NULL argument propagates
      // without faulting; a later one is not reached once a non-NULL is taken.
      let type = try unified(arguments, routines)
      for argument in arguments {
        let value = try empty(argument, routines)
        if case .null = value { continue }
        return value.coerced(to: type)
      }
      return .null
    case let .nullif(lhs, rhs):
      // Evaluate the empty group as a run does — NULL when `v1 = v2` is TRUE,
      // else the folded `v1`.
      let va = try empty(lhs, routines)
      let vb = try empty(rhs, routines)
      return try matches(va, .equal, vb) == true ? .null : va
    case .column, .subquery:
      // A bare column cannot appear over an empty group (a grouping error
      // `compile` rejected). A scalar `subquery` is materialised at run (this
      // fold carries no cache), and its value is uncorrelated — group-
      // independent — so this pre-run fold treats it as the undecided `.null`,
      // never faulting on a subquery the run would materialise cleanly.
      return .null
    case let .grouping(arguments):
      // This fold only ever runs over the single empty group a constant-false
      // WHERE leaves — the grand total, which forms no grouping key, so every
      // GROUPING argument is rolled up. GROUPING is therefore the all-ones
      // bit-vector here, exactly the value the run's grouped lowering yields for
      // an arm with no keys. Returning a placeholder `0` instead would pick the
      // wrong `CASE` branch, so a reachability fold could drop the faulting arm
      // a run keeps (`CASE WHEN GROUPING(x) = 1 THEN 1 / 0 ELSE 0` folds to the
      // ELSE and misses the divide the grand-total group raises). Build the
      // vector the same iterative way the grouped lowering does, so a 63-column
      // GROUPING lands on `Int.max` rather than overflowing.
      var bits = 0
      for _ in arguments { bits = (bits << 1) | 1 }
      return .integer(bits)
    }
  }

  /// The value a `LIKE` pattern or escape `operand` folds to over the empty
  /// group: an expression folds through `empty(_ expression:)`; a `:parameter`
  /// is unbound here — the empty-group fold carries no bindings — so it is
  /// `.null`, reading UNKNOWN exactly as a `Predicate.bound` parameter does.
  func empty(_ operand: Predicate.Operand, _ routines: Routines = [:])
      throws(SQLError) -> Value {
    switch operand {
    case let .expression(expression): try empty(expression, routines)
    case .parameter: .null
    }
  }

  /// Whether a `HAVING` `predicate` passes over the single empty group a
  /// constant-false `WHERE` leaves — TRUE keeps the group (the projection then
  /// runs), FALSE or UNKNOWN (`nil`) drops it (the projection is unreachable).
  /// It evaluates the predicate as a run does: comparing the folded operand
  /// values (`empty(_:_:)`) with three-valued logic, and short-circuiting
  /// `AND`/`OR` so an unreachable arm's operand never folds — and never faults.
  /// A `left op :parameter` with no binding is UNKNOWN, its left unevaluated.
  func empty(_ predicate: Predicate,
             _ routines: Routines = [:])
      throws(SQLError) -> Bool? {
    switch predicate {
    case let .comparison(left, op, right):
      return try matches(empty(left, routines), op, empty(right, routines))
    case .bound:
      return nil
    case let .null(operand, negated):
      let value = try empty(operand, routines)
      let null = if case .null = value { true } else { false }
      return negated ? !null : null
    case let .membership(operand, values, negated):
      // Fold `x IN (…)` over the empty group as its OR-chain of equalities does
      // — the folded operand matched against each folded element under
      // three-valued `OR`, honouring the OR-chain's short-circuit
      // (`membership`): the run stops at the first TRUE comparison and never
      // evaluates a later element, so `1 IN (1, 1 / 0)` folds `true` here
      // without folding `1 / 0` to a `.divide` fault. Negated for `NOT IN`.
      //
      // Reject an empty list, as `check` and `lower` do — a whole-result
      // aggregate `HAVING` over the empty group reaches this fold without a
      // prior `check` (`OutputColumn.typecheck`), so an empty list would
      // otherwise fold `false` (`true` under `NOT IN`) here while both compile
      // (`lower`) and schema (`check`) reject it. The parser rejects `IN ()`,
      // but a caller can build `.membership(_, [], …)` directly.
      if values.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      let lhs = try empty(operand, routines)
      let truth = try membership(of: values) { value throws(SQLError) in
        try matches(lhs, .equal, empty(value, routines))
      }
      return negated ? truth.map { !$0 } : truth
    case let .rows(lhs, op, rhs):
      // Fold `(l…) <op> (r…)` over the empty group as `Filter.comparison`
      // evaluates it: each component folds through `empty(_ expression:)`, then
      // the values combine with the same `matches`/Kleene primitives — the
      // componentwise Kleene `AND` for `=` (its negation for `<>`), the
      // lexicographic cascade for the ordering operators. Reject an unequal
      // arity as `lower`/`check` do.
      guard lhs.count == rhs.count else {
        throw .arity(lhs.count, rhs.count)
      }
      var l = Array<Value>()
      l.reserveCapacity(lhs.count)
      for expression in lhs { try l.append(empty(expression, routines)) }
      var r = Array<Value>()
      r.reserveCapacity(rhs.count)
      for expression in rhs { try r.append(empty(expression, routines)) }
      return try relate(l, op, r)
    case let .among(lhs, rows, negated):
      // Fold `(l…) [NOT] IN ((r…), …)` over the empty group as
      // `Filter.memberships` evaluates it: the left row folds once, then
      // `(l…) = (r…)` folds over the element rows under Kleene `OR`, each
      // element equality the componentwise Kleene `AND`. Reject an empty list
      // or unequal arity as `lower`/`check` do.
      if rows.isEmpty {
        throw .state("42601", "IN requires a non-empty value list")
      }
      var l = Array<Value>()
      l.reserveCapacity(lhs.count)
      for expression in lhs { try l.append(empty(expression, routines)) }
      var truth: Bool? = false
      for element in rows {
        guard element.count == lhs.count else {
          throw .arity(lhs.count, element.count)
        }
        var r = Array<Value>()
        r.reserveCapacity(element.count)
        for expression in element { try r.append(empty(expression, routines)) }
        truth = try or(truth, relate(l, .equal, r))
        if truth == true { break }
      }
      return negated ? truth.map { !$0 } : truth
    case let .like(operand, pattern, escape, negated):
      // Fold `x LIKE p` over the empty group as `Row.like` evaluates it: the
      // operand, pattern, and optional escape are each folded once, IN ORDER,
      // before the result is decided (so a faulting reached operand surfaces
      // its throw rather than being swallowed by a NULL escape). Then a NULL
      // operand, pattern, or escape is UNKNOWN, a non-NULL non-character
      // operand or pattern a `42804` data-type mismatch (ISO `LIKE` requires
      // character operands), else the `%`/`_` matcher decides; a non-NULL
      // escape that is not a single character faults `SQLError.argument`, as
      // the run does. `NOT LIKE` negates.
      let subject = try empty(operand, routines)
      let template = try empty(pattern, routines)
      let separator: Value? =
          if let escape { try empty(escape, routines) } else { nil }
      var character: Character? = nil
      switch separator {
      case .none, .null:
        break
      case let .text(text) where text.count == 1:
        character = text.first
      default:
        throw .argument("LIKE ESCAPE must be a single character")
      }
      let truth: Bool?
      switch (subject, template, separator) {
      case (.null, _, _), (_, .null, _), (_, _, .some(.null)):
        truth = nil
      case let (.text(subject), .text(template), _):
        truth = matches(subject, template, escape: character)
      default:
        throw .state("42804", "LIKE requires character operands")
      }
      return negated ? truth.map { !$0 } : truth
    case let .between(test, lower, upper, negated):
      // Fold `x [NOT] BETWEEN a AND b` over the empty group as `ranged` does:
      // BETWEEN is `x >= a AND x <= b`, and NOT BETWEEN its negation (not the
      // `x < a OR x > b` expansion, which diverges on a cross-kind bound — see
      // `ranged`). The folded `x >= a` short-circuits before the upper: a
      // definitely-FALSE one settles BETWEEN FALSE (and NOT BETWEEN TRUE)
      // leaving the upper unfolded — and any fault it would raise unraised — so
      // `HAVING 0 BETWEEN 1 AND (1 / 0)` drops the group without a `.divide`
      // fault, exactly as the run does.
      let value = try empty(test, routines)
      let low = try empty(lower, routines)
      let above = try matches(value, .geq, low)
      if above == false { return negated }
      let within =
          try and(above, matches(value, .leq, empty(upper, routines)))
      return negated ? within.map { !$0 } : within
    case let .distinct(lhs, rhs, negated):
      // Fold `a IS [NOT] DISTINCT FROM b` over the empty group as `differs`
      // does: the null-safe `distinct` of the two folded values, negated for
      // `IS NOT`. It is two-valued — both operands fold to definite values, so
      // the truth is definite (never UNKNOWN, unlike a `=` over a NULL).
      let differ = distinct(try empty(lhs, routines), try empty(rhs, routines))
      return negated ? !differ : differ
    case let .truth(inner, value, negated):
      // Fold `p IS [NOT] <truth value>` over the empty group as `Filter.truth`
      // evaluates it: `empty` yields the inner's genuine three-valued result
      // (over zero rows every side is constant, so a `nil` here is a real
      // UNKNOWN, not a per-row deferral), which `tested` maps to a definite
      // result — never itself UNKNOWN.
      return tested(try empty(inner, routines), value, negated)
    case let .and(lhs, rhs):
      // A `false` left proves the `AND` false without folding the right arm,
      // which a run's short-circuit never evaluates and so must not fault.
      let left = try empty(lhs, routines)
      if left == false { return false }
      return and(left, try empty(rhs, routines))
    case let .or(lhs, rhs):
      // A `true` left proves the `OR` true without folding the right arm.
      let left = try empty(lhs, routines)
      if left == true { return true }
      return or(left, try empty(rhs, routines))
    case let .not(operand):
      return try empty(operand, routines).map { !$0 }
    case .exists, .within, .quantified:
      // The whole-result empty-group fold carries no catalog, so it cannot
      // materialise a subquery to decide the predicate — it reads UNKNOWN,
      // dropping the lone empty group, the conservative outcome for the rare
      // `HAVING <subquery predicate>` over a constant-false `WHERE`.
      return nil
    }
  }

  // MARK: - Column resolution

  /// Whether `column`'s qualifier admits `member`: an unqualified name admits
  /// every relation, a qualified one only a relation its qualifier (an alias,
  /// else a table name) names.
  private func admits(_ member: Member, _ column: Column) -> Bool {
    guard let qualifier = column.qualifier else { return true }
    return (member.relation.alias ?? member.relation.name) == qualifier
  }

  /// Whether `column` is a qualified reference whose qualifier a relation of
  /// this scope answers — a qualified name a present alias (else a table name)
  /// names. An UNqualified name is FALSE (it names no one local relation to
  /// shadow an outer one), as is a qualified name no local relation answers.
  ///
  /// A qualified name a local relation answers but none of this scope binds is
  /// a qualified miss on that relation — the local alias shadows a same-named
  /// enclosing relation, so `find` faults it hard rather than correlating
  /// outward; an unadmitted qualifier is genuinely not local and correlates.
  private func shadows(_ column: Column) -> Bool {
    if column.qualifier == nil { return false }
    return members.contains { admits($0, column) }
  }

  /// Every combined ordinal `column` addresses — the FULL addressable surface
  /// (each admitted relation's physical columns AND its virtual ones, through
  /// `Schema.ordinal(of:)`), in chain order. This is the one bare-name scan
  /// every ambiguity/presence determination routes through, so no site can scan
  /// a partial surface (real-only) and drift: a name matching more than one
  /// entry here is ambiguous, one present, none absent — measured over the same
  /// physical∪virtual surface `ordinal(of:)` resolves against. An unqualified
  /// `column` admits every relation; a qualified one only a relation its
  /// qualifier names.
  private func addressable(_ column: Column) -> Array<Int> {
    var ordinals = Array<Int>()
    for member in members where admits(member, column) {
      guard let local = member.schema.ordinal(of: column.name) else { continue }
      ordinals.append(member.offset + local)
    }
    return ordinals
  }

  /// The combined ordinal `column` resolves to.
  ///
  /// The name resolves against every admitted relation: present in exactly one
  /// it yields that relation's `offset` plus the local ordinal; present in more
  /// than one — an unqualified name in several relations, or a qualified name
  /// two relations share a name for — it is `SQLError.ambiguous`; in none it is
  /// `SQLError.column`. Resolution reads the one full-addressable scan
  /// (`addressable`), so it and every ambiguity/presence check measure the same
  /// physical∪virtual surface.
  internal func ordinal(of column: Column) throws(SQLError) -> Int {
    let ordinals = addressable(column)
    if ordinals.count > 1 { throw .ambiguous(column.name) }
    guard let resolved = ordinals.first else { throw .column(column.name) }
    return resolved
  }

  /// The combined ordinal `column` resolves to as an enclosing reference, or
  /// `nil` when this scope binds it in none of its relations — the probe a
  /// nested subquery's `Outer` consults for a candidate correlated column. The
  /// three outcomes are DISTINCT: a name bound by exactly one relation yields
  /// its ordinal, a name bound by none reports `nil` (the `Outer` walk keeps
  /// looking outward), and a name bound by more than one relation of this scope
  /// is `SQLError.ambiguous` and propagates — a nearer ambiguous scope shadows
  /// farther ones rather than falling through to rebind the name to an outer
  /// column. Only the not-found `SQLError.column` becomes `nil`; every other
  /// fault (an ambiguity or a qualifier fault) propagates. This is the
  /// enclosing analog of `find`, which the local lowering consults for the same
  /// reason.
  internal func correlated(_ column: Column) throws(SQLError) -> Int? {
    try find(column)
  }

  /// The combined ordinal `column` resolves to, or `nil` when it is a candidate
  /// correlated reference to an enclosing scope — the not-found probe a
  /// `.column` lowering consults before correlating outward. four outcomes stay
  /// DISTINCT.
  ///
  /// A name bound by exactly one relation yields its ordinal (found → bind). A
  /// name bound by more than one relation is `SQLError.ambiguous`, propagated
  /// (never `nil`): a local ambiguity is a hard error, not a fall-through, so
  /// `try?`-swallowing it would silently rebind an ambiguous local name to an
  /// outer column. The remaining `SQLError.column` — no relation binds the name
  /// — splits on whether some local relation admitted the qualifier: an
  /// unadmitted qualifier (or an absent unqualified name) is a genuine
  /// not-found → `nil`, so the walk correlates outward; a qualifier a local
  /// relation does admit, naming a column it lacks, is a qualified miss that
  /// propagates as a hard `.column` — the local alias shadows a same-qualifier
  /// enclosing relation, so it faults against the inner relation rather than
  /// falling through to bind the outer one.
  internal func find(_ column: Column) throws(SQLError) -> Int? {
    do {
      return try ordinal(of: column)
    } catch let error {
      guard case .column = error else { throw error }
      if shadows(column) { throw error }
      return nil
    }
  }

  /// The resolved column a bare `column` locally names — carrying its output
  /// name, its `type(at:)` type, and its `unconstrained(at:)` mask together
  /// from one `find` — or `nil` when this scope binds it in none of its
  /// relations (the reference is a candidate correlated one).
  ///
  /// invariant: a column reference's type and mask (and any future per-column
  /// attribute) are obtained from one resolution that traverses the same paths
  /// — local (here), correlation (`Outer.resolved(for:)`), schema — so the two
  /// attributes cannot diverge. The mask reader once consulted a different
  /// (local-only) path than the type reader, so a correlated all-NULL column
  /// lost its mask; folding both through the single ordinal closes that gap.
  internal func resolved(_ column: Column) throws(SQLError) -> ResolvedColumn? {
    guard let ordinal = try find(column) else { return nil }
    return ResolvedColumn(name: column.name, type: type(at: ordinal),
                          unconstrained: unconstrained(at: ordinal))
  }

  /// The resolved column at combined `ordinal`, named `name` — its `type(at:)`
  /// type and `unconstrained(at:)` mask read together, so an enclosing
  /// correlation walk (`Outer.resolved(for:)`) carries both up from the one
  /// ordinal it matched.
  internal func resolved(at ordinal: Int, named name: String)
      -> ResolvedColumn {
    ResolvedColumn(name: name, type: type(at: ordinal),
                   unconstrained: unconstrained(at: ordinal))
  }

  /// The combined-ordinal projected terms: every real column of every relation
  /// for `*` (in chain order, never a virtual column) as `.slot` terms, a
  /// bare-column list as `.slot` terms at their combined ordinals, an
  /// expression list as lowered terms — in source order.
  internal func terms(_ projection: Projection,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported) throws(SQLError)
      -> Array<Term> {
    // A projection is a barred clause position (see `Schema.terms`): the entry
    // bars the seam, so no join-scope projection can admit a correlated column
    // of this query.
    let subquery = subquery.barred
    switch projection {
    case .all:
      // The `NATURAL`/`USING` merged columns FIRST (ISO 9075 7.10), each as its
      // coalesce `value`, then every real column the shared `expansion`
      // enumeration yields as a `.slot` at its combined ordinal — in chain
      // order, never a virtual column, and never a physical constituent a
      // merged column subsumes. `width(of: .all)` counts this same
      // enumeration, so the emitted arity and the width cannot diverge.
      return merged.map(\.value) + expansion.map { .slot($0) }
    case let .columns(columns):
      // Lower each bare column through `term`, so a name none of this scope's
      // relations bind consults the `subquery` surface: a correlated reference
      // on the barred projection surface is diagnosed unsupported (parity with
      // the schema path) rather than faulting `SQLError.column`.
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(term(.column(column), routines, subquery: subquery))
      }
      return terms
    case let .expressions(projected):
      var terms = Array<Term>()
      terms.reserveCapacity(projected.count)
      for item in projected {
        try terms.append(term(item.expression, routines, subquery: subquery))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to a combined-ordinal `Term`.
  internal func term(_ expression: Expression,
                     _ routines: Routines = [:],
                     subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      // A bare (unqualified) name matching a `NATURAL`/`USING` merged column
      // (ISO 9075 7.10) resolves to its one coalesced `value` — the merged
      // entry shadows its two physical constituents, so the name is not
      // ambiguous between the two sides. A qualified `A.c`/`B.c` never matches
      // a (unqualified) merged column and reaches its own side below. A
      // physical column of the same name a later plain join contributed faults
      // `.ambiguous` (`merged(binding:)`).
      if column.qualifier == nil,
          let merged = try merged(binding: column.name) {
        return merged.value
      }
      // Resolve the column against this scope's own relations first; a name
      // none binds is a candidate correlated reference — consult the enclosing
      // scope, lowering to a synthetic `Term.parameter` bound from the outer
      // row when it resolves there, else the ordinary unknown-column fault. A
      // locally ambiguous name (bound by more than one relation) is a hard
      // error `find` propagates — never a fall-through to outer correlation
      // that would rebind it to an outer column.
      if let ordinal = try find(column) { return .slot(ordinal) }
      if let name = try subquery.correlate(column) { return .parameter(name) }
      return try .slot(ordinal(of: column))
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
      // Lower each branch's guard to a combined-ordinal `Filter` and its result
      // to a `Term`, and the `ELSE` to a `Term`, across the join chain.
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
      // `derive`/`validate` compute — so the executor coerces the selected
      // branch's value to the type the schema advertises.
      let type = try derive(whens, otherwise, routines, subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand across the join chain and attach the target type; the
      // executor converts the evaluated value to it (`Value.cast(to:)`).
      return try .cast(term(operand, routines, subquery: subquery), type)
    case let .coalesce(arguments):
      // Lower each argument to a combined-ordinal `Term` and hold them in a
      // first-class `Term.coalesce` so each is evaluated once; `type` is the
      // unified argument type the selected value coerces to.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines, subquery: subquery))
      }
      let type = try derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      // Lower both operands to combined-ordinal `Term`s and hold them in a
      // first-class `Term.nullif` so each is evaluated once.
      return try .nullif(term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .subquery(query):
      // A scalar subquery lowers to a `Term.subquery` reading its collapsed
      // value from the run-time cache, carrying its occurrence `Subkey` and
      // single-column type; the single-column arity is enforced from the
      // compiled width here (no cursor). The query is uncorrelated, so it reads
      // no cell of this row.
      return try subquery.scalar(query)
    case .aggregate:
      // An aggregate has no per-row meaning — it folds over a group — so it may
      // not appear in a `WHERE`, a join `ON`, or a non-aggregate projection.
      throw .state("42803", "an aggregate is not allowed here")
    case .grouping:
      // GROUPING is a grouped-query construct decided by the arm's key
      // membership; it has no meaning in this non-grouped join resolution, so
      // it faults as an aggregate does. A grouped query lowers it through
      // `Grouped.term` instead.
      throw .state("42803", "GROUPING requires a GROUP BY")
    }
  }

  /// The resolved sort keys an `ORDER BY` lowers to, in major-to-minor order —
  /// each key's ISO `<sort key>` a `Term` over the chain's combined ordinals,
  /// its direction preserved.
  ///
  /// `projection` are the query's already-lowered projection terms and `names`
  /// their output names, so an ordinal or an output-alias key resolves to the
  /// matching select-list item's `Term` and an ordinary expression key lowers
  /// fresh over the chain (see the free `order`).
  internal func order(_ order: Order, _ projection: Array<Term>,
                      _ names: Array<String?>, _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // An ORDER BY is barred, as the projection is (see `Schema.order`).
    let subquery = subquery.barred
    return try SQLEngine.order(order, projection, names) {
      expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }
  }

  /// Lowers a join's `ON predicate` to the engine's `Filter` across the chain,
  /// emitting a `match` for each pure `column = column` equality — the
  /// hash-join key `nest` folds into a physical `Join` — ONLY WHEN the whole
  /// `ON` is safe, and otherwise lowering the entire conjunction as one
  /// residual.
  ///
  /// The key is read off the already-lowered conjunct, not by re-resolving the
  /// AST: a conjunct whose lowered form is a `compare(.slot, .equal, .slot)` —
  /// both operands columns of the join prefix — IS the hash-join key `nest`
  /// folds into a physical `Join`, so it is rewritten to the `match(left,
  /// right)` node `nest` recognises. A conjunct that lowered to a `.parameter`
  /// operand is a correlated outer reference (`ON V.x = T.id` under an EXISTS,
  /// lowering to `compare(.slot, .equal, .parameter)`), NOT a column = column
  /// key, so it stays the residual `ON` filter — re-resolving its AST would
  /// consult only the prefix and fault `SQLError.column` on the outer column
  /// that already lowered correctly. Every other leaf (an inequality, an
  /// expression equality such as `a.x = b.y + 1`, an `IS NULL`, a membership,
  /// an `OR`/`NOT`) lowers through `lower`, becoming a residual the join runs
  /// as a filter over the product — nested-loop semantics, correct if O(n·m).
  ///
  /// A `match` key is extracted ONLY WHEN every lowered conjunct is `safe`; if
  /// ANY conjunct is unsafe, the whole `ON` lowers to a single residual and no
  /// key is hoisted. The hash join evaluates its key equality before any
  /// residual conjunct AND skips a NULL key (an equi `match` drops a pair whose
  /// key cell is NULL), so an extracted key changes the `ON`'s left-to-right
  /// Kleene error behaviour on two hazards, both suppressing a throw the
  /// residual `select` over the product would raise (the order the WHERE
  /// pushdown barriers preserve):
  ///   - an unsafe conjunct before the key (`ON (1 / A.x) = 0 AND A.k = B.k`):
  ///     hoisting the key would let its non-match drop a pair before the
  ///     unsafe conjunct runs (`A.x = 0` ⇒ `SQLError.divide`);
  ///   - a nullable key before an unsafe conjunct (`ON A.k = B.k AND (1 / A.x)
  ///     = 0`, `A.k` NULL, `A.x = 0`): the equality is UNKNOWN, so the Kleene
  ///     `AND` must still evaluate the unsafe RHS and raise — but the hash join
  ///     skips the NULL key and drops the pair before the RHS runs.
  /// The engine has no NOT NULL schema (a column surfaces as a `Value` that may
  /// be `.null`), so it cannot prove a key operand non-nullable; every equi key
  /// is treated as nullable, collapsing both hazards to the single whole-`ON`
  /// rule. An equi `column = column` is always `safe` (comparing two cells
  /// never raises), so an all-equi or otherwise all-safe `ON` still hash-joins
  /// byte-for-byte.
  internal func on(_ predicate: Predicate,
                   _ routines: Routines = [:],
                   subquery: Resolution = .unsupported)
      throws(SQLError) -> Filter {
    let conjuncts = predicate.conjuncts
    let lowered = try conjuncts.map { conjunct throws(SQLError) in
      try lower(conjunct, routines, subquery: subquery)
    }
    // An unsafe conjunct anywhere forbids extracting ANY key: a hoisted key
    // both skips a NULL pair before a later unsafe conjunct runs and drops a
    // non-match before an earlier one does — either suppressing the throw the
    // whole-ON residual owes. Lower the entire conjunction as one residual.
    //
    // A comparison whose operands' declared types do not reconcile now faults
    // 42804 through the nested-loop `matches`/`relate`/`like`, so it is as
    // throwing as a divide — and equally unsafe to bypass. A hoisted key drops
    // every non-matching pair before that residual is reached, so a `ON L.n =
    // R.t AND L.n = R.m` (`n`/`m` integer, `t` text) that hashes the comparable
    // `n = m` key would let a run with no `n = m` pair silently return no rows
    // rather than fault the cross-kind `n = t` residual — a run the validate
    // path (`check`) already faults 42804. `lower` stamps a provably-cross-kind
    // conjunct `Filter.incomparable`, so `safe` already reports it unsafe (the
    // same carried classification `seek`/pushdown read — computed once, no
    // separate recompute here): the whole `ON` stays one always-evaluated
    // residual `nest` runs nested-loop, faulting the cross-kind pair exactly as
    // validation does. A conjunct whose comparability the static types cannot
    // decide — a `:parameter`/subquery operand, a constant NULL — was left
    // unstamped (the run stays the authority for its per-run kind, as `check`
    // defers those too), so a plain equi `ON` still hash-joins.
    guard lowered.allSatisfy(\.safe) else {
      return lowered.conjunction!
    }
    // Read the equi-join key off the already-lowered term rather than
    // re-resolving the AST: a key is a `compare(.slot, .equal, .slot)` whose
    // both operands are columns of the join prefix. A conjunct that lowered to
    // a `.parameter` operand is a correlated outer reference (`V.x = :outer`),
    // NOT a column = column key, so it stays the residual `ON` filter — a
    // re-resolution of its AST would consult only the prefix and fault
    // `SQLError.column` on the outer column already lowered correctly.
    //
    // Hoist the key only when the two columns' declared types are comparable
    // (`ValueType.unified`, the same notion `check`'s `comparable` and the
    // run's `matches` share) — a like-kind or numeric integer/double pair. A
    // `.match` is the sole shape every physical join keys on (`nest`'s hash
    // seek, the `.outer`/semijoin bucketed fast paths through `equikey`), and
    // it never funnels through `matches`: `nest` buckets each side by its own
    // key value, so an incomparable `A.n = B.s` (an integer against a string)
    // hashes the two sides to disjoint buckets and no pair is ever compared —
    // the join would silently drop every row rather than fault, whereas the
    // validate path (`check`) already faults it 42804. Leaving an incomparable
    // equality as the residual `compare(.slot, .equal, .slot)` routes it
    // through the nested-loop `matches`, which faults 42804 on the cross-kind
    // pair, so run ≡ validate. A comparable key still hoists and hashes exactly
    // as before.
    let filters = lowered.map { residual -> Filter in
      if case let .compare(.slot(left), .equal, .slot(right)) = residual,
          type(at: left).unified(with: type(at: right)) != nil {
        return Filter(match: left, right)
      }
      return residual
    }
    return filters.conjunction!
  }

  /// Lowers the name-addressed AST `predicate` to the engine's `Filter`, each
  /// column reference resolved to a combined ordinal across the chain, then
  /// stamps the comparability classification onto every throwable leaf (see
  /// `stamped`) from this scope's combined-space `type(at:)` — so the untyped
  /// physical layer reads a cross-kind comparison's `42804` hazard through
  /// `Filter.safe` and cannot seek/push past it.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Filter {
    let filter =
        try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
          try term(expression, routines, subquery: subquery)
        }, subquery: subquery)
    return stamped(filter) { type(at: $0) }
  }
}

// MARK: - Comparability finder

/// The comparison-finder: a dedicated traversal that faults a statically-typed
/// incomparable comparison (ISO `SQLSTATE 42804`) anywhere a query reaches one,
/// and cannot leak a non-comparability fault by construction.
///
/// Unlike the strict validator (`validate`/`check`), which resolves and
/// type-checks every operand and aborts on the first fault of any kind, the
/// finder walks a resolved predicate or expression looking only for
/// comparison-bearing constructs. At each comparison it invokes the same leaf
/// `comparable`/`character` check the validator uses, resolving the operand
/// types through `validate` but deferring that resolution's own fault locally
/// (`deferred`): an ill-typed arithmetic operand, an unknown routine, a bad
/// arity — every fault the run defers to execution — is swallowed at the
/// comparison it decorates, so the traversal continues to the sibling and later
/// comparisons rather than aborting. Only a 42804 escapes. Because each
/// comparison's own resolution fault is caught there, no expression
/// (a `COALESCE` arg, a `NULLIF` operand, a `CASE` result) can hide a later
/// sibling's incomparable comparison behind an earlier one's deferred fault —
/// the leak the walk-reuse mechanism it replaces suffered at every recursive
/// site.
///
/// The traversal is reachability-aware, reusing the same short-circuit and
/// const-fold primitives the run evaluates with (`constant`, `selects`,
/// `stable`, `matched`, `membership`, `dead`), so a comparison an unreachable
/// `CASE`/`COALESCE` arm or a short-circuited `AND`/`OR` leg holds is never
/// visited — the finder faults exactly the reachable static 42804 the strict
/// validate path faults, and no others (`run ≡ validate`).
extension Scope {
  /// Runs `body`, deferring every fault but the ISO comparability fault
  /// (`SQLSTATE 42804`): resolving a comparison operand's own type may raise a
  /// fault the run defers to execution (an ill-typed arithmetic operand, an
  /// unknown routine, a bad cast), so swallow it and let the search continue,
  /// while a 42804 from the leaf check propagates. Applied at each comparison,
  /// never around a whole expression, so a deferred fault never hides a later
  /// reachable incomparable comparison.
  private func deferred(_ body: () throws(SQLError) -> Void)
      throws(SQLError) {
    do {
      try body()
    } catch let error {
      guard case let .state(code, _) = error, code == "42804" else { return }
      throw error
    }
  }

  /// Comparability-checks a single comparison `lhs <op> rhs` — the finder's
  /// leaf. It resolves each operand's type through `validate` (deferring that
  /// resolution's own non-comparability fault locally) and runs the leaf
  /// `comparable` check, so a cross-kind non-exempt pair faults 42804 while a
  /// constant-NULL, subquery, or unresolvable-typed operand defers. The nested
  /// comparisons of the operands themselves are found by the callers' recursion
  /// before this runs, so a 42804 buried in an operand never rides `validate`
  /// here — that operand's own reachable 42804 already escaped.
  private func compare(_ lhs: Expression, _ rhs: Expression,
                       _ routines: Routines, subquery: SubqueryCheck)
      throws(SQLError) {
    try deferred { () throws(SQLError) in
      let l = try validate(lhs, routines, subquery: subquery)
      let r = try validate(rhs, routines, subquery: subquery)
      try comparable(lhs, l, rhs, r, routines)
    }
  }

  /// Comparability-checks a `LIKE`'s character rule — the ISO rule its operand
  /// and pattern are character strings. A pattern or escape that `vanishes` —
  /// a constant-NULL one, or a `:parameter` whose value arrives from the
  /// bindings — makes the whole predicate defer to the run: the run reads an
  /// unbound/NULL pattern as UNKNOWN and never reaches the character fault, so
  /// faulting the operand at compile would reject `K LIKE :p` a run keeps. A
  /// non-NULL, non-parameter pattern reaches the character check, faulting a
  /// non-character operand or pattern (`K LIKE 'x'` over an integer `K`) 42804
  /// as the run's `like` does. It reads the same `vanishes` the strict
  /// validator's `.like` does, so the finder and the validator cannot drift.
  private func like(_ operand: Expression, _ pattern: Predicate.Operand,
                    _ escape: Predicate.Operand?, _ routines: Routines,
                    subquery: SubqueryCheck) throws(SQLError) {
    guard !vanishes(pattern, routines), !vanishes(escape, routines) else {
      return
    }
    try deferred { () throws(SQLError) in
      let type = try validate(operand, routines, subquery: subquery)
      // A constant-NULL subject short-circuits the run's `like` to UNKNOWN
      // before its pattern-type check, so enforce no character type here —
      // matching the run and the strict validator's subject-NULL skip. Nested
      // comparisons in the pattern are still found by the `.like` case's own
      // recursion above.
      if constant(operand, routines) == .null { return }
      try character(operand, type, routines)
      if case let .expression(pattern) = pattern {
        let type = try validate(pattern, routines, subquery: subquery)
        try character(pattern, type, routines)
      }
    }
  }

  /// Finds every reachable comparison in a `LIKE` pattern or escape `operand`.
  private func comparisons(in operand: Predicate.Operand,
                           _ routines: Routines, subquery: SubqueryCheck)
      throws(SQLError) {
    if case let .expression(expression) = operand {
      try comparisons(in: expression, routines, subquery: subquery)
    }
  }

  /// Finds and comparability-checks every reachable comparison in `predicate`,
  /// short-circuit aware — the predicate arm of the finder. Each comparison-
  /// bearing construct (`comparison`, `membership`, `between`, `rows`, `among`,
  /// `like`, and the implicit equality a `NULLIF` inside an operand carries) is
  /// leaf-checked with its own resolution fault deferred; a total predicate
  /// (`IS [NOT] NULL`, `IS [NOT] DISTINCT FROM`, `bound`) faults never but has
  /// its operands recursed for a nested one. `EXISTS`/`IN (Q)`/quantified
  /// record the reached subquery for the driver to recurse its body, then
  /// their left row's operands; the subquery operand itself is exempt (its
  /// cross-kind rows fault at run through `relate`).
  func comparisons(in predicate: Predicate, _ routines: Routines,
                   subquery: SubqueryCheck = .unsupported) throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      try comparisons(in: left, routines, subquery: subquery)
      try comparisons(in: right, routines, subquery: subquery)
      try compare(left, right, routines, subquery: subquery)
    case let .bound(left, _, _):
      // `left op :parameter` — the parameter operand is deferred to the run, so
      // the comparison itself never faults at compile; recurse the left for a
      // nested comparison.
      try comparisons(in: left, routines, subquery: subquery)
    case let .null(operand, _):
      // `IS [NOT] NULL` is total, so recurse the operand for a nested
      // comparison but leaf-check nothing.
      try comparisons(in: operand, routines, subquery: subquery)
    case let .membership(operand, values, _):
      // `x IN (v, …)` is the OR-chain `x = v OR …`. Every element the run
      // reaches is recursed for a nested comparison it evaluates (a `CASE`
      // guard that self-faults); and until the OR-chain short-circuits it is
      // also compared to the operand — the comparability the run's `member`
      // faults 42804 on. A constant match, or a reflexive element equal to a
      // stable operand, stops the comparison as the run's Kleene-OR does. But a
      // reflexive match fully prunes the tail (neither recursed nor compared)
      // only over a provably non-NULL operand (`defined`): a nullable operand
      // makes `operand = operand` UNKNOWN, so a NULL row runs on and evaluates
      // every later element — its comparison to the NULL operand is UNKNOWN
      // (never 42804), but a nested comparison it carries self-faults — so
      // the comparability stops at the reflexive element while the recursion of
      // the later elements continues.
      try comparisons(in: operand, routines, subquery: subquery)
      var comparing = true
      for value in values {
        try comparisons(in: value, routines, subquery: subquery)
        guard comparing else { continue }
        try compare(operand, value, routines, subquery: subquery)
        if value == operand && stable(operand, routines) {
          if defined(operand) { break }
          comparing = false
        } else if matched(operand, value, routines) == true {
          break
        }
      }
    case let .rows(lhs, _, rhs):
      for expression in lhs {
        try comparisons(in: expression, routines, subquery: subquery)
      }
      for expression in rhs {
        try comparisons(in: expression, routines, subquery: subquery)
      }
      // A componentwise comparison; an arity mismatch is a structural fault the
      // run defers, so a mismatched pair is not leaf-checked here.
      guard lhs.count == rhs.count else { return }
      // The run evaluates every left component, then every right, into a
      // `[Value]` before `relate` preflights any pair's comparability — so a
      // component's own evaluation fault (a `1 / 0`) it raises building a row
      // preempts every pair's 42804 (`(1, 1 / 0) = ('x', 2)` divides, it does
      // not fault the incomparable first pair). Defer the whole componentwise
      // pass around the operand resolution in that order, so such a fault stops
      // it (deferred to the run) before any pair faults 42804, then compare the
      // resolved pairs — matching the run and the strict validator's `.rows`.
      try deferred { () throws(SQLError) in
        let l = try lhs.map { expression throws(SQLError) in
          try validate(expression, routines, subquery: subquery)
        }
        let r = try rhs.map { expression throws(SQLError) in
          try validate(expression, routines, subquery: subquery)
        }
        for index in lhs.indices {
          try comparable(lhs[index], l[index], rhs[index], r[index], routines)
        }
      }
    case let .among(lhs, rows, _):
      // `(l…) [NOT] IN ((r…), …)` is the OR-chain of row equalities, short-
      // circuit aware exactly as the scalar `.membership`.
      for expression in lhs {
        try comparisons(in: expression, routines, subquery: subquery)
      }
      // The run's `member` evaluates the whole left row once, then each element
      // row, before `relate` preflights any pair — so a component's own
      // evaluation fault preempts the 42804, and an element-row fault stops the
      // fold there (the run raises it, never reaching a later element). Defer
      // the whole componentwise pass so a left-row fault stops it before any
      // element is checked, and an element-row fault (thrown out of the fold)
      // stops it before a later element faults 42804 — each deferred to the
      // run — while a comparability 42804 propagates. The nested-comparison
      // recursion above stays eager (a comparison a component itself carries is
      // found regardless), matching the run's per-component evaluation.
      try deferred { () throws(SQLError) in
        let types = try lhs.map { expression throws(SQLError) in
          try validate(expression, routines, subquery: subquery)
        }
        let l = constants(lhs, routines)
        _ = try membership(of: rows, each: { element throws(SQLError) in
          for expression in element {
            try comparisons(in: expression, routines, subquery: subquery)
          }
          guard element.count == lhs.count else { return }
          let r = try element.map { expression throws(SQLError) in
            try validate(expression, routines, subquery: subquery)
          }
          for index in element.indices {
            try comparable(lhs[index], types[index], element[index], r[index],
                           routines)
          }
        }, equality: { element throws(SQLError) in
          guard let l, let r = constants(element, routines) else { return nil }
          return (try? relate(l, .equal, r)) ?? nil
        })
      }
    case let .like(operand, pattern, escape, _):
      try comparisons(in: operand, routines, subquery: subquery)
      try comparisons(in: pattern, routines, subquery: subquery)
      if let escape {
        try comparisons(in: escape, routines, subquery: subquery)
      }
      try like(operand, pattern, escape, routines, subquery: subquery)
    case let .between(test, lower, upper, _):
      // `x BETWEEN a AND b` compares `x` to each bound, short-circuit aware: a
      // definitely-FALSE lower comparison settles the truth, leaving the upper
      // unreachable, exactly as `ranged` evaluates it.
      try comparisons(in: test, routines, subquery: subquery)
      try comparisons(in: lower, routines, subquery: subquery)
      if case let .expression(low) = lower {
        try compare(test, low, routines, subquery: subquery)
      }
      let settled = {
        guard let value = constant(test, routines),
            let low = constant(lower, routines) else {
          return false
        }
        return ((try? matches(value, .geq, low)) ?? nil) == false
      }()
      if !settled {
        try comparisons(in: upper, routines, subquery: subquery)
        if case let .expression(high) = upper {
          try compare(test, high, routines, subquery: subquery)
        }
      }
    case let .distinct(lhs, rhs, _):
      // `IS [NOT] DISTINCT FROM` is total — a cross-kind pair is DISTINCT,
      // a fault — so recurse both operands but leaf-check nothing.
      try comparisons(in: lhs, routines, subquery: subquery)
      try comparisons(in: rhs, routines, subquery: subquery)
    case let .truth(inner, _, _):
      try comparisons(in: inner, routines, subquery: subquery)
    case let .exists(query, _):
      // Record the reached occurrence so the driver recurses its body; its own
      // resolution fault (an unsupported position) defers.
      try deferred { () throws(SQLError) in
        try subquery.validate(query, as: .existential)
      }
    case let .within(lhs, query, _):
      for expression in lhs {
        try comparisons(in: expression, routines, subquery: subquery)
      }
      try deferred { () throws(SQLError) in
        try subquery.validate(query, as: .valued)
      }
    case let .quantified(lhs, _, _, query):
      for expression in lhs {
        try comparisons(in: expression, routines, subquery: subquery)
      }
      try deferred { () throws(SQLError) in
        try subquery.validate(query, as: .valued)
      }
    case let .and(lhs, rhs):
      // A connective recurses reachability-aware: the `constant` short-circuit
      // is the run's, so an unreached operand's comparisons are not visited.
      try comparisons(in: lhs, routines, subquery: subquery)
      if constant(lhs, routines) != false {
        try comparisons(in: rhs, routines, subquery: subquery)
      }
    case let .or(lhs, rhs):
      try comparisons(in: lhs, routines, subquery: subquery)
      if constant(lhs, routines) != true {
        try comparisons(in: rhs, routines, subquery: subquery)
      }
    case let .not(operand):
      try comparisons(in: operand, routines, subquery: subquery)
    }
  }

  /// Finds and comparability-checks every reachable comparison in `expression`,
  /// short-circuit aware — the expression arm of the finder. It recurses every
  /// sub-expression that can hold a comparison (a `binary`/`cast` operand, a
  /// call argument, a `COALESCE`/`CASE`/aggregate sub-expression) and leaf-
  /// checks the implicit `v1 = v2` a `NULLIF` carries. A scalar subquery
  /// its reached occurrence for the driver to recurse its body.
  func comparisons(in expression: Expression, _ routines: Routines,
                   subquery: SubqueryCheck = .unsupported) throws(SQLError) {
    switch expression {
    case .column, .literal:
      break
    case let .call(_, arguments):
      for argument in arguments {
        try comparisons(in: argument, routines, subquery: subquery)
      }
    case let .binary(_, lhs, rhs):
      try comparisons(in: lhs, routines, subquery: subquery)
      try comparisons(in: rhs, routines, subquery: subquery)
    case let .aggregate(_, operand, _, filter):
      // The `FILTER` is a per-row gate evaluated over every row, so its
      // comparisons are always reachable; the aggregand folds only when the
      // filter can admit a row (`dead`), matching the run's gate.
      if let filter {
        try comparisons(in: filter, routines, subquery: subquery)
      }
      if case let .expression(argument) = operand,
          !(filter.map { dead($0, routines) } ?? false) {
        try comparisons(in: argument, routines, subquery: subquery)
      }
    case let .case(whens, otherwise):
      // Reachability mirrors `conditional`/`reachable`: each guard up to (and
      // including) a constant-TRUE one is evaluated; a constant-FALSE guard's
      // result is unreachable; a constant-TRUE guard makes every later branch
      // and the `ELSE` unreachable.
      for branch in whens {
        try comparisons(in: branch.when, routines, subquery: subquery)
        switch constant(branch.when, routines) {
        case false:
          continue
        case true:
          try comparisons(in: branch.then, routines, subquery: subquery)
          return
        case nil:
          try comparisons(in: branch.then, routines, subquery: subquery)
        }
      }
      if let otherwise {
        try comparisons(in: otherwise, routines, subquery: subquery)
      }
    case let .cast(operand, _):
      try comparisons(in: operand, routines, subquery: subquery)
    case let .coalesce(arguments):
      // Reachability mirrors `coalesce`: a definite selection makes every later
      // argument unreachable, so stop the walk there.
      for argument in arguments {
        try comparisons(in: argument, routines, subquery: subquery)
        if selects(argument, routines) { break }
      }
    case let .nullif(lhs, rhs):
      // `NULLIF(v1, v2)` is `CASE WHEN v1 = v2 THEN NULL ELSE v1`, so v1 and v2
      // must be comparable — recurse both, then check the implicit equality.
      try comparisons(in: lhs, routines, subquery: subquery)
      try comparisons(in: rhs, routines, subquery: subquery)
      try compare(lhs, rhs, routines, subquery: subquery)
    case let .subquery(query):
      // Record the reached scalar occurrence so the driver recurses its body;
      // its own arity fault defers.
      try deferred { () throws(SQLError) in
        _ = try subquery.type(query)
      }
    case let .grouping(arguments):
      for argument in arguments {
        try comparisons(in: argument, routines, subquery: subquery)
      }
    }
  }

  /// Finds every reachable comparison inside the aggregate sub-expressions of
  /// `expression`, ignoring its non-aggregate structure — mirroring
  /// `aggregates(in:)`. An aggregate folds over the group's rows before any
  /// `LIMIT`, so its operand and `FILTER` comparisons are reachable even when a
  /// row-dropping limit that leaves the surrounding projection unreachable, so
  /// the driver runs this unconditionally over the projection.
  func comparisons(aggregatesIn expression: Expression, _ routines: Routines,
                   subquery: SubqueryCheck = .unsupported) throws(SQLError) {
    switch expression {
    case .column, .literal, .subquery:
      break
    case .aggregate:
      // Found an aggregate — check its own operand and FILTER comparisons.
      try comparisons(in: expression, routines, subquery: subquery)
    case let .call(_, arguments), let .grouping(arguments):
      for argument in arguments {
        try comparisons(aggregatesIn: argument, routines, subquery: subquery)
      }
    case let .binary(_, lhs, rhs), let .nullif(lhs, rhs):
      try comparisons(aggregatesIn: lhs, routines, subquery: subquery)
      try comparisons(aggregatesIn: rhs, routines, subquery: subquery)
    case let .case(whens, otherwise):
      for branch in whens {
        try comparisons(aggregatesIn: branch.when, routines, subquery: subquery)
        try comparisons(aggregatesIn: branch.then, routines, subquery: subquery)
      }
      if let otherwise {
        try comparisons(aggregatesIn: otherwise, routines, subquery: subquery)
      }
    case let .cast(operand, _):
      try comparisons(aggregatesIn: operand, routines, subquery: subquery)
    case let .coalesce(arguments):
      for argument in arguments {
        try comparisons(aggregatesIn: argument, routines, subquery: subquery)
      }
    }
  }

  /// Finds every reachable comparison inside the aggregate sub-expressions of
  /// `predicate` — a `HAVING` or `CASE` guard's aggregates fold before the
  /// filter runs, so they are reachable whatever the filter's short-circuit
  /// — mirroring `aggregates(in predicate:)`.
  func comparisons(aggregatesIn predicate: Predicate, _ routines: Routines,
                   subquery: SubqueryCheck = .unsupported) throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      try comparisons(aggregatesIn: left, routines, subquery: subquery)
      try comparisons(aggregatesIn: right, routines, subquery: subquery)
    case let .bound(left, _, _):
      try comparisons(aggregatesIn: left, routines, subquery: subquery)
    case let .null(operand, _):
      try comparisons(aggregatesIn: operand, routines, subquery: subquery)
    case let .membership(operand, values, _):
      try comparisons(aggregatesIn: operand, routines, subquery: subquery)
      for value in values {
        try comparisons(aggregatesIn: value, routines, subquery: subquery)
      }
    case let .rows(lhs, _, rhs):
      for expression in lhs + rhs {
        try comparisons(aggregatesIn: expression, routines, subquery: subquery)
      }
    case let .among(lhs, rows, _):
      for expression in lhs {
        try comparisons(aggregatesIn: expression, routines, subquery: subquery)
      }
      for element in rows {
        for expression in element {
          try comparisons(aggregatesIn: expression, routines,
                          subquery: subquery)
        }
      }
    case .exists:
      break
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      for expression in lhs {
        try comparisons(aggregatesIn: expression, routines, subquery: subquery)
      }
    case let .like(operand, pattern, escape, _):
      try comparisons(aggregatesIn: operand, routines, subquery: subquery)
      if case let .expression(pattern) = pattern {
        try comparisons(aggregatesIn: pattern, routines, subquery: subquery)
      }
      if case let .expression(escape) = escape {
        try comparisons(aggregatesIn: escape, routines, subquery: subquery)
      }
    case let .between(test, lower, upper, _):
      try comparisons(aggregatesIn: test, routines, subquery: subquery)
      if case let .expression(lower) = lower {
        try comparisons(aggregatesIn: lower, routines, subquery: subquery)
      }
      if case let .expression(upper) = upper {
        try comparisons(aggregatesIn: upper, routines, subquery: subquery)
      }
    case let .distinct(lhs, rhs, _):
      try comparisons(aggregatesIn: lhs, routines, subquery: subquery)
      try comparisons(aggregatesIn: rhs, routines, subquery: subquery)
    case let .truth(inner, _, _):
      try comparisons(aggregatesIn: inner, routines, subquery: subquery)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      try comparisons(aggregatesIn: lhs, routines, subquery: subquery)
      try comparisons(aggregatesIn: rhs, routines, subquery: subquery)
    case let .not(operand):
      try comparisons(aggregatesIn: operand, routines, subquery: subquery)
    }
  }
}
