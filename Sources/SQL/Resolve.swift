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
