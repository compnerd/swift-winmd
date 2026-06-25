// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// Resolution and lowering — the bridge from the name-addressed AST to the
/// engine's ordinal-addressed forms.
///
/// The AST names columns by string; the engine addresses them by ordinal. A
/// single relation resolves a name against its `Table` directly. A join lays its
/// two relations end to end in one combined ordinal space and resolves a
/// possibly qualified name against the pair through a `Scope`. Both lower a
/// `Projection` to ordinals (`*` → the real width, never a virtual column), an
/// `Order` to an `(ordinal, ascending)` pair, and the AST `Predicate` to the
/// engine's `Filter`. A column name resolves to a real ordinal (`< width`) or a
/// virtual one (`>= width`). A name no relation resolves is `SQLError.column`;
/// an unqualified name both relations of a join resolve is `SQLError.ambiguous`.
///
/// The table is `~Escapable`, so resolution borrows it rather than storing it.
/// The `Table` extension methods are `borrowing`; a join resolves through a
/// `~Escapable` `Scope` that borrows both relations for the span of
/// compilation, where both tables are live.

extension Table where Self: ~Escapable {
  /// The ordinal of the column `column` names, validating its qualifier against
  /// `relation`.
  ///
  /// A single-relation query has one relation, so a qualifier — `relation`'s
  /// alias, else its table name — must name it; any other qualifier is
  /// `SQLError.column`, as a join rejects a qualifier naming neither side.
  internal borrowing func ordinal(of column: Column, in relation: Relation)
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

  internal borrowing func projection(_ projection: Projection,
                                     in relation: Relation)
      throws(SQLError) -> Array<Int> {
    switch projection {
    case .all:
      return Array(0 ..< width)
    case let .columns(columns):
      var ordinals = Array<Int>()
      ordinals.reserveCapacity(columns.count)
      for column in columns {
        ordinals.append(try ordinal(of: column, in: relation))
      }
      return ordinals
    }
  }

  internal borrowing func order(_ order: Order, in relation: Relation)
      throws(SQLError) -> (column: Int, ascending: Bool) {
    try (column: ordinal(of: order.column, in: relation),
         ascending: order.ascending)
  }

  internal borrowing func lower(_ predicate: Predicate, in relation: Relation)
      throws(SQLError) -> Filter {
    switch predicate {
    case let .comparison(column, op, value):
      try .compare(ordinal(of: column, in: relation), op, value)
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

/// The two relations of a join, addressed in one combined ordinal space.
///
/// A join lays its two relations end to end: the outer (the `FROM`) relation
/// occupies the ordinals below `base`, the inner (the `JOIN`) relation those at
/// or above it. `base` is the outer relation's `extent` — one past the highest
/// ordinal it can address — rather than its `width`, so the outer relation's
/// virtual columns — ordinals at or past its real width, such as a `rowid` or a
/// `parent` — stay on the outer side rather than colliding with the inner's
/// space; an outer column resolves to its own ordinal, an inner column to
/// `base + ordinal`. A `Scope` resolves a possibly qualified
/// `SQL.Column` into that combined space so the engine's `Filter`, projection,
/// and order all address cells uniformly across the pair. A qualifier names a
/// relation by its alias, else its table name; an unqualified name resolves
/// against both relations and is ambiguous if each has it. The scope is
/// `~Escapable`: it borrows both `~Escapable` tables, and the engine resolves
/// through it entirely within compilation, where the tables are live.
internal struct Scope<T: Table & ~Escapable>: ~Escapable {
  /// The left (outer, `FROM`) relation reference; its alias, else its table
  /// name, is the qualifier that selects the `outer` table.
  private let left: Relation
  /// The right (inner, `JOIN`) relation reference; its qualifier selects the
  /// `inner` table.
  private let right: Relation
  /// The outer and inner tables, laid end to end.
  private let outer: T
  private let inner: T

  @_lifetime(borrow outer, borrow inner)
  internal init(_ left: Relation, _ outer: borrowing T,
                _ right: Relation, _ inner: borrowing T) {
    self.left = left
    self.right = right
    self.outer = copy outer
    self.inner = copy inner
  }

  /// The base ordinal of the inner relation in the combined space.
  ///
  /// The outer relation's `extent` — its real `width` plus the virtual columns
  /// it exposes, i.e. one past the highest ordinal it can address — past which
  /// inner ordinals begin. No outer ordinal — a real column below the width or a
  /// virtual column at or just past it — reaches it, so the `< base` / `>= base`
  /// split classifies a combined ordinal to its side even when the outer
  /// relation contributes a virtual column. Anchoring on the outer's real extent
  /// (rather than a fixed `1 << 32` reserve, which a 32-bit shift collapses to
  /// zero) keeps the layout correct on every word size with no giant gap.
  internal var base: Int {
    outer.extent
  }

  /// Whether `qualifier` (an alias, else a table name) names `relation`.
  private func names(_ relation: Relation, _ qualifier: String) -> Bool {
    (relation.alias ?? relation.name) == qualifier
  }

  /// Whether `column`'s qualifier admits `relation`: an unqualified name admits
  /// either relation, a qualified one only the relation its qualifier names.
  private func admits(_ relation: Relation, _ column: Column) -> Bool {
    if let qualifier = column.qualifier {
      names(relation, qualifier)
    } else {
      true
    }
  }

  /// The combined ordinal `column` resolves to.
  ///
  /// A qualifier admits only the relation it names; an unqualified name admits
  /// both. Within the admitted relations the name resolves: present in exactly
  /// one it yields that ordinal; in both â two relations sharing a qualifier (a
  /// self-join or a duplicated alias), or an unqualified name sitting in each â
  /// it is `SQLError.ambiguous`; in neither it is `SQLError.column`.
  internal func ordinal(of column: Column) throws(SQLError) -> Int {
    let here =
        admits(left, column) ? outer.ordinal(of: column.name) : nil
    let there =
        admits(right, column) ? inner.ordinal(of: column.name) : nil
    switch (here, there) {
    case let (.some(ordinal), nil):
      return ordinal
    case let (nil, .some(ordinal)):
      return base + ordinal
    case (.some, .some):
      throw .ambiguous(column.name)
    case (nil, nil):
      throw .column(column.name)
    }
  }

  /// The combined ordinals a projection yields: every real column of both
  /// relations for `*` (outer then inner, never a virtual column), the named
  /// columns' combined ordinals otherwise, in source order.
  internal func projection(_ projection: Projection) throws(SQLError)
      -> Array<Int> {
    switch projection {
    case .all:
      // Every real outer column, then every real inner column at its
      // `base`-offset ordinal — never a virtual column of either side.
      return Array(0 ..< outer.width)
          + (0 ..< inner.width).map { base + $0 }
    case let .columns(columns):
      var ordinals = Array<Int>()
      ordinals.reserveCapacity(columns.count)
      for column in columns {
        ordinals.append(try ordinal(of: column))
      }
      return ordinals
    }
  }

  /// The `(column, ascending)` pair an `ORDER BY` resolves to, the column a
  /// combined ordinal.
  internal func order(_ order: Order) throws(SQLError)
      -> (column: Int, ascending: Bool) {
    try (column: ordinal(of: order.column), ascending: order.ascending)
  }

  /// Lowers a join's `ON left = right` to a `match` conjunct, each side
  /// resolved to a combined ordinal across the pair.
  internal func match(_ left: Column, _ right: Column) throws(SQLError)
      -> Filter {
    try .match(ordinal(of: left), ordinal(of: right))
  }

  /// Lowers the name-addressed AST `predicate` to the engine's `Filter`, each
  /// column reference resolved to a combined ordinal across the join.
  internal func lower(_ predicate: Predicate) throws(SQLError) -> Filter {
    switch predicate {
    case let .comparison(column, op, value):
      try .compare(ordinal(of: column), op, value)
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
  /// A `compare` reads its one column; a `match` reads both; the connectives
  /// recurse. The engine unions these with the projection, order, and join keys
  /// to materialise exactly the columns a scan's rows are read through.
  internal func references(into ordinals: inout Set<Int>) {
    switch self {
    case let .compare(column, _, _):
      ordinals.insert(column)
    case let .match(left, right):
      ordinals.insert(left)
      ordinals.insert(right)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .not(operand):
      operand.references(into: &ordinals)
    }
  }
}
