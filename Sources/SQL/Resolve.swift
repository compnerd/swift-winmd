// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Resolution and lowering — the bridge from the name-addressed AST to the
/// engine's ordinal-addressed forms.
///
/// The AST names columns by string; the engine addresses them by ordinal.
/// Resolution reads only a relation's schema — its `width`, its `extent`, and
/// its name → ordinal map — never its live cursor, so it runs over an escapable
/// `Schema` (lifted off a base `Table` or a compiled `View`) rather than the
/// `~Escapable` source. A single relation resolves a name against one `Schema`.
/// A join lays its two relations end to end in one combined ordinal space and
/// resolves a possibly qualified name against the pair through a `Scope`. Both
/// lower a `Projection` to ordinals (`*` → the real width, never a virtual
/// column), an `Order` to an `(ordinal, ascending)` pair, and the AST
/// `Predicate` to the engine's `Filter`. A column name resolves to a real
/// ordinal (`< width`) or a virtual one (`>= width`). A name no relation
/// resolves is `SQLError.column`; an unqualified name both relations of a join
/// resolve is `SQLError.ambiguous`.

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

  /// The projected terms of `projection`, addressed by ordinal: a `*` or a
  /// bare-column list yields one `.slot(ordinal)` per column; an expression list
  /// lowers each expression to a term. The terms hold ordinals, which the
  /// engine remaps to slots after gathering the referenced ones.
  internal func terms(_ projection: Projection, in relation: Relation)
      throws(SQLError) -> Array<Term> {
    switch projection {
    case .all:
      return (0 ..< width).map { .slot($0) }
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(.slot(ordinal(of: column, in: relation)))
      }
      return terms
    case let .expressions(projected):
      var terms = Array<Term>()
      terms.reserveCapacity(projected.count)
      for item in projected {
        try terms.append(term(item.expression, in: relation))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to an ordinal-addressed `Term`: a column to a
  /// `.slot(ordinal)`, a literal to a `.constant`, a call to an `.apply` over
  /// its lowered arguments.
  internal func term(_ expression: Expression, in relation: Relation)
      throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      return try .slot(ordinal(of: column, in: relation))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, in: relation))
      }
      return .apply(name: name, arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, in: relation), term(rhs, in: relation))
    case .aggregate:
      // An aggregate has no per-row meaning — it folds over a group — so it may
      // not appear in a `WHERE`, a join `ON`, or a non-aggregate projection.
      throw .unsupported("an aggregate is not allowed here")
    }
  }

  /// The resolved sort keys an `ORDER BY` lowers to, in major-to-minor order —
  /// each key's column an ordinal in this relation, its direction preserved.
  internal func order(_ order: Order, in relation: Relation)
      throws(SQLError) -> Array<(column: Int, ascending: Bool)> {
    var keys = Array<(column: Int, ascending: Bool)>()
    keys.reserveCapacity(order.keys.count)
    for key in order.keys {
      try keys.append((column: ordinal(of: key.column, in: relation),
                       ascending: key.ascending))
    }
    return keys
  }

  internal func lower(_ predicate: Predicate, in relation: Relation)
      throws(SQLError) -> Filter {
    switch predicate {
    case let .comparison(left, op, right):
      try .compare(term(left, in: relation), op, term(right, in: relation))
    case let .bound(left, op, parameter):
      try .bound(term(left, in: relation), op, parameter)
    case let .null(expression, negated):
      try .null(term(expression, in: relation), negated: negated)
    case let .and(lhs, rhs):
      try .and(lower(lhs, in: relation), lower(rhs, in: relation))
    case let .or(lhs, rhs):
      try .or(lower(lhs, in: relation), lower(rhs, in: relation))
    case let .not(operand):
      try .not(lower(operand, in: relation))
    }
  }
}

// MARK: - Join scope

/// The relations of a join chain, addressed in one combined ordinal space.
///
/// A join chain lays its relations end to end: relation `i` occupies the
/// combined ordinals `[offset_i, offset_i + extent_i)`, where `offset_i` is the
/// sum of the `extent`s of the relations before it. Using each relation's
/// `extent` — its real `width` plus the virtual columns it exposes — rather than
/// its `width` keeps a relation's virtual columns (an `Id`, an owner foreign
/// key) on its own side rather than colliding with the next relation's space. A
/// `Scope` resolves a possibly qualified `SQL.Column` into that combined space
/// so the engine's `Filter`, projection, and order all address cells uniformly
/// across the chain. A qualifier names a relation by its alias, else its table
/// name; an unqualified name resolves against every relation and is ambiguous
/// if more than one resolves it — as is a qualified name two relations share an
/// alias or table name for (a self-join or a duplicated alias). Resolution
/// reads only schemas, so the scope is escapable data over the relations'
/// `Schema`s.
internal struct Scope {
  /// One relation of the chain: its reference (for qualifier matching), its
  /// name-resolution schema, and its base offset in the combined space.
  private struct Member {
    let relation: Relation
    let schema: Schema
    let offset: Int
  }

  private let members: Array<Member>

  /// Builds a scope over `relations` — the `FROM` relation first, then each
  /// joined relation in source order — laying each past the previous one's
  /// `extent`.
  internal init(_ relations: Array<(Relation, Schema)>) {
    var members = Array<Member>()
    members.reserveCapacity(relations.count)
    var offset = 0
    for (relation, schema) in relations {
      members.append(Member(relation: relation, schema: schema, offset: offset))
      offset += schema.extent
    }
    self.members = members
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

  /// The value type a scalar `expression` yields, statically: a bare column its
  /// source type, a literal its own, a standard aggregate its result domain, a
  /// scalar call its routine's declared return type (`returns`), a binary
  /// arithmetic expression a double when either operand is a double (else an
  /// integer); every other expression `.integer`, the engine's exact-numeric
  /// default. It resolves the column ordinal (so an unknown or ambiguous
  /// reference faults exactly as a projection would) but reads no cursor.
  ///
  /// A `COUNT` yields `.integer` (a row count); `AVG` always `.double` (the
  /// engine averages to a non-NULL double); `SUM`/`MIN`/`MAX` the type of the
  /// aggregated argument — a `COUNT(*)`, having no argument, is `.integer`.
  ///
  /// A `.call` types from `returns` — the routine return-type map the run
  /// carries — so a text-returning scalar (`GUID(...)`) reports `.text` rather
  /// than the `.integer` default; a call to a routine the map does not name
  /// (whose return type the engine cannot see) stays `.integer`.
  internal func type(of expression: Expression,
                     _ returns: Dictionary<String, ValueType> = [:])
      throws(SQLError) -> ValueType {
    switch expression {
    case let .column(column):
      try type(at: ordinal(of: column))
    case let .literal(literal):
      switch literal {
      case .string: .text
      case .integer: .integer
      case .double: .double
      }
    case let .call(name, _):
      returns[name.lowercased()] ?? .integer
    case let .aggregate(function, operand):
      switch function {
      case .count:
        .integer
      case .avg:
        .double
      case .sum, .min, .max:
        switch operand {
        case .star: .integer
        case let .expression(argument): try type(of: argument, returns)
        }
      }
    case let .binary(_, lhs, rhs):
      // Arithmetic promotes to a double when either operand is a double
      // (`Age + 1.5`); an all-integer expression stays an integer.
      switch (try type(of: lhs, returns), try type(of: rhs, returns)) {
      case (.double, _), (_, .double): .double
      default: .integer
      }
    }
  }

  /// Whether `column`'s qualifier admits `member`: an unqualified name admits
  /// every relation, a qualified one only a relation its qualifier (an alias,
  /// else a table name) names.
  private func admits(_ member: Member, _ column: Column) -> Bool {
    guard let qualifier = column.qualifier else { return true }
    return (member.relation.alias ?? member.relation.name) == qualifier
  }

  /// The combined ordinal `column` resolves to.
  ///
  /// The name resolves against every admitted relation: present in exactly one
  /// it yields that relation's `offset` plus the local ordinal; present in more
  /// than one — an unqualified name in several relations, or a qualified name
  /// two relations share a name for — it is `SQLError.ambiguous`; in none it is
  /// `SQLError.column`.
  internal func ordinal(of column: Column) throws(SQLError) -> Int {
    var resolved: Int? = nil
    for member in members where admits(member, column) {
      guard let local = member.schema.ordinal(of: column.name) else { continue }
      if resolved != nil { throw .ambiguous(column.name) }
      resolved = member.offset + local
    }
    guard let resolved else { throw .column(column.name) }
    return resolved
  }

  /// The combined-ordinal projected terms: every real column of every relation
  /// for `*` (in chain order, never a virtual column) as `.slot` terms, a
  /// bare-column list as `.slot` terms at their combined ordinals, an expression
  /// list as lowered terms — in source order.
  internal func terms(_ projection: Projection) throws(SQLError)
      -> Array<Term> {
    switch projection {
    case .all:
      // Every real column of every relation, at its combined ordinal — in chain
      // order, never a virtual column of any relation.
      var terms = Array<Term>()
      for member in members {
        for ordinal in 0 ..< member.schema.width {
          terms.append(.slot(member.offset + ordinal))
        }
      }
      return terms
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        try terms.append(.slot(ordinal(of: column)))
      }
      return terms
    case let .expressions(projected):
      var terms = Array<Term>()
      terms.reserveCapacity(projected.count)
      for item in projected {
        try terms.append(term(item.expression))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to a combined-ordinal `Term`.
  internal func term(_ expression: Expression) throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      return try .slot(ordinal(of: column))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument))
      }
      return .apply(name: name, arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs), term(rhs))
    case .aggregate:
      // An aggregate has no per-row meaning — it folds over a group — so it may
      // not appear in a `WHERE`, a join `ON`, or a non-aggregate projection.
      throw .unsupported("an aggregate is not allowed here")
    }
  }

  /// The resolved sort keys an `ORDER BY` lowers to, in major-to-minor order —
  /// each key's column a combined ordinal across the chain, its direction
  /// preserved.
  internal func order(_ order: Order) throws(SQLError)
      -> Array<(column: Int, ascending: Bool)> {
    var keys = Array<(column: Int, ascending: Bool)>()
    keys.reserveCapacity(order.keys.count)
    for key in order.keys {
      try keys.append((column: ordinal(of: key.column),
                       ascending: key.ascending))
    }
    return keys
  }

  /// Lowers a join's `ON left = right` to a `match` conjunct, each side
  /// resolved to a combined ordinal across the chain.
  internal func match(_ left: Column, _ right: Column) throws(SQLError)
      -> Filter {
    try .match(ordinal(of: left), ordinal(of: right))
  }

  /// Lowers the name-addressed AST `predicate` to the engine's `Filter`, each
  /// column reference resolved to a combined ordinal across the chain.
  internal func lower(_ predicate: Predicate) throws(SQLError) -> Filter {
    switch predicate {
    case let .comparison(left, op, right):
      try .compare(term(left), op, term(right))
    case let .bound(left, op, parameter):
      try .bound(term(left), op, parameter)
    case let .null(expression, negated):
      try .null(term(expression), negated: negated)
    case let .and(lhs, rhs):
      try .and(lower(lhs), lower(rhs))
    case let .or(lhs, rhs):
      try .or(lower(lhs), lower(rhs))
    case let .not(operand):
      try .not(lower(operand))
    }
  }
}

// MARK: - Grouped scope

/// The grouped slot space of an aggregate query — the lowering surface for the
/// projection, `HAVING`, and `ORDER BY` that read a grouped record.
///
/// An `aggregate` node yields grouped records whose slots are the `GROUP BY` key
/// values (slots `0 ..< keys.count`, in key order) followed by the aggregate
/// results (slot `keys.count + j` is aggregate `j`). A `Grouping` lowers a
/// name-addressed AST expression into that space: an aggregate call maps to its
/// result slot; a bare column maps to its key slot ONLY when it is a `GROUP BY`
/// key — the standard rule that a non-aggregated column must appear in the
/// `GROUP BY` (else `SQLError.grouping`). It also records each projected item's
/// output name so an `ORDER BY` may name a projection alias, the standard way to
/// order on an aggregate (`ORDER BY <count-alias>`).
///
/// The keys and aggregates resolve against the underlying `Scope`, so the same
/// combined-ordinal resolution the source uses decides which projection columns
/// are keys.
internal struct Grouping {
  private let scope: Scope

  /// Each `GROUP BY` key's combined base ordinal mapped to its grouped slot —
  /// key `i` sits at grouped slot `i`.
  private let keys: Dictionary<Int, Int>

  /// The distinct aggregate expressions mapped to their grouped slots — aggregate
  /// `j` sits at grouped slot `keys.count + j`.
  private let aggregates: Dictionary<Expression, Int>

  /// Each projected item's output name (an alias, else a bare column's name),
  /// lowercased, mapped to its grouped term — the surface an `ORDER BY` names a
  /// projection alias against.
  private var aliases: Dictionary<String, Term> = [:]

  /// Output names two or more projected items share, lowercased. An `ORDER BY`
  /// that names one has no single slot to order on — the same ambiguity the
  /// non-grouped `Scope.order` reports for a shared unqualified join column
  /// (`SQLError.ambiguous`) rather than silently picking the last projection.
  private var ambiguous: Set<String> = []

  /// Builds a grouping over `scope` for the `GROUP BY` `columns` and the
  /// query's distinct `aggregates` (in first-appearance order — aggregate `j` at
  /// grouped slot `columns.count + j`).
  internal init(_ scope: Scope, _ columns: Array<Column>,
                _ aggregates: Array<Expression>) throws(SQLError) {
    self.scope = scope
    var keys = Dictionary<Int, Int>(minimumCapacity: columns.count)
    for index in columns.indices {
      try keys[scope.ordinal(of: columns[index])] = index
    }
    self.keys = keys
    var map = Dictionary<Expression, Int>(minimumCapacity: aggregates.count)
    for index in aggregates.indices {
      map[aggregates[index]] = columns.count + index
    }
    self.aggregates = map
  }

  /// The grouped slot an aggregate expression resolves to (an aggregate the
  /// query collected), or `nil` if it is not one.
  private func slot(of aggregate: Expression) -> Int? {
    aggregates[aggregate]
  }

  /// Lowers a scalar `expression` to a grouped-space `Term`.
  ///
  /// An aggregate call maps to its result slot; a literal to a constant; a
  /// `call`/`binary` recurses over its operands; a bare column maps to its key
  /// slot only when it is a `GROUP BY` key, else it is `SQLError.grouping` — the
  /// standard rule.
  private func term(_ expression: Expression) throws(SQLError) -> Term {
    if case .aggregate = expression, let slot = slot(of: expression) {
      return .slot(slot)
    }
    switch expression {
    case let .column(column):
      let ordinal = try scope.ordinal(of: column)
      guard let slot = keys[ordinal] else { throw .grouping(column.name) }
      return .slot(slot)
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument))
      }
      return .apply(name: name, arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs), term(rhs))
    case .aggregate:
      // An aggregate reaches here only when it was not collected — an internal
      // inconsistency, since the query gathers every projection/HAVING aggregate.
      throw .unsupported("uncollected aggregate")
    }
  }

  /// Records a projected item's output `name` → grouped `term`, flagging the
  /// name ambiguous if another projected item already claimed it.
  private mutating func record(_ name: String, _ term: Term) {
    let key = name.lowercased()
    if aliases.updateValue(term, forKey: key) != nil { ambiguous.insert(key) }
  }

  /// The grouped-space projected terms, recording each item's output name for an
  /// `ORDER BY` to name.
  ///
  /// A `columns` projection (`SELECT Dept … GROUP BY Dept`) lowers each column
  /// as a grouped term — a `GROUP BY` key, else `SQLError.grouping`. An
  /// `expressions` projection lowers each item's expression and records its
  /// output name (an alias, else a bare column's name) so an `ORDER BY` may name
  /// it — the standard alias ordering on an aggregate. A `SELECT *` has no
  /// well-defined meaning over groups (which columns?), so it faults.
  internal mutating func terms(_ projection: Projection)
      throws(SQLError) -> Array<Term> {
    switch projection {
    case .all:
      throw .unsupported("SELECT * is not allowed with GROUP BY or aggregates")
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        let term = try term(.column(column))
        terms.append(term)
        record(column.name, term)
      }
      return terms
    case let .expressions(items):
      var terms = Array<Term>()
      terms.reserveCapacity(items.count)
      for item in items {
        let term = try term(item.expression)
        terms.append(term)
        // Record the output name — an alias, else a bare column's name — so an
        // `ORDER BY` may name it (the standard alias ordering on an aggregate).
        if let alias = item.alias {
          record(alias, term)
        } else if case let .column(column) = item.expression {
          record(column.name, term)
        }
      }
      return terms
    }
  }

  /// Lowers a `HAVING`/predicate to a grouped-space `Filter`.
  internal func lower(_ predicate: Predicate) throws(SQLError) -> Filter {
    switch predicate {
    case let .comparison(left, op, right):
      try .compare(term(left), op, term(right))
    case let .bound(left, op, parameter):
      try .bound(term(left), op, parameter)
    case let .null(expression, negated):
      try .null(term(expression), negated: negated)
    case let .and(lhs, rhs):
      try .and(lower(lhs), lower(rhs))
    case let .or(lhs, rhs):
      try .or(lower(lhs), lower(rhs))
    case let .not(operand):
      try .not(lower(operand))
    }
  }

  /// The `(slot, ascending)` keys an `ORDER BY` resolves to in grouped
  /// space, major to minor.
  ///
  /// Each order column names a projection output first — an alias, or a bare
  /// column's name (`terms` recorded these), the standard way to order on an
  /// aggregate — else a `GROUP BY` key column. A column that is neither is
  /// `SQLError.grouping`, as a bare non-key column is meaningless over groups.
  ///
  /// The `sort` operator orders by grouped slots, so an alias resolves only
  /// when its projected term is a bare `.slot` — a plain group key or a whole
  /// aggregate (`SUM(x) AS Total`). An alias over a COMPUTED expression
  /// (`COUNT(*) * 2 AS Doubled`) has no standalone slot to sort on — the
  /// projection computes it after the sort — so ordering on it is unsupported
  /// rather than misreported as an unknown column.
  internal func order(_ order: Order) throws(SQLError)
      -> Array<(slot: Int, ascending: Bool)> {
    var resolved = Array<(slot: Int, ascending: Bool)>()
    resolved.reserveCapacity(order.keys.count)
    for key in order.keys {
      if key.column.qualifier == nil {
        let name = key.column.name.lowercased()
        // A name two projections share has no single slot to order on — reject
        // it as ambiguous rather than pick the last, matching the non-grouped
        // `Scope.order` fault for a shared unqualified join column.
        if ambiguous.contains(name) { throw .ambiguous(key.column.name) }
        if let term = aliases[name] {
          guard case let .slot(slot) = term else {
            throw .unsupported(
                "ORDER BY on a computed column alias is not supported")
          }
          resolved.append((slot, key.ascending))
          continue
        }
      }
      let ordinal = try scope.ordinal(of: key.column)
      guard let slot = keys[ordinal] else {
        throw .grouping(key.column.name)
      }
      resolved.append((slot, key.ascending))
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
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .not(operand):
      operand.references(into: &ordinals)
    }
  }
}
