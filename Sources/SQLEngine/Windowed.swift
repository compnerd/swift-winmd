// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Window function

extension WindowFunction {
  /// The result type of this window function.
  ///
  /// The ranking functions (`ROW_NUMBER`, `RANK`, `DENSE_RANK`) each yield a
  /// 1-based integer position, so each types as `.integer` — the type the
  /// schema advertises for a projected window column.
  internal var type: ValueType {
    switch self {
    case .rowNumber, .rank, .denseRank:
      .integer
    }
  }

  /// Whether the executor computes this window function yet — every ranking
  /// function (`ROW_NUMBER`, `RANK`, `DENSE_RANK`) now does. A future window
  /// function lands here `false` until its executor does, rejected with the
  /// feature diagnostic on both the run and validate paths until then.
  internal var supported: Bool {
    switch self {
    case .rowNumber, .rank, .denseRank:
      true
    }
  }

  /// The ISO keyword spelling of this window function, for a diagnostic.
  internal var keyword: String {
    switch self {
    case .rowNumber: "ROW_NUMBER"
    case .rank: "RANK"
    case .denseRank: "DENSE_RANK"
    }
  }

  /// This window function's result `type`, or the feature diagnostic when its
  /// executor has not yet landed — the type the schema advertises for a
  /// supported window, faulting an unsupported one in parity with the run.
  internal var result: ValueType {
    get throws(SQLError) {
      guard supported else {
        throw .state("0A000", "\(keyword) is not yet supported")
      }
      return type
    }
  }
}

extension Select {
  /// Whether the select projects (or orders by) a window function — the query
  /// compiles through the window path, appending each window's result to the
  /// source rows before the projection reads it. A window is allowed only in
  /// the SELECT list and `ORDER BY` (ISO 9075); one elsewhere is rejected.
  internal var windows: Bool {
    let projected = switch projection {
    case .all, .columns:
      false
    case let .expressions(items):
      items.contains { $0.expression.windowed }
    }
    return projected || orderKeys.contains { $0.windowed }
  }
}

// MARK: - Windowing (lowered)

/// A lowered window function — the ordinal-addressed form of an AST
/// `Expression.window`, ready for the executor to compute over a partition.
///
/// The `partition` terms and `order` sort keys are in the source's slot space
/// (the WHERE/join chain below the window node), evaluated per source record:
/// the partition terms split the records into independent partitions, and the
/// order keys fix the row order the ranking reads within a partition. The
/// `function` is the ranking (or, later, aggregate) folded over that ordered
/// partition, its value appended to each record as a fresh slot.
///
/// Two windowings are equal when they compute the same function over the same
/// resolved partition and order — the resolved form column qualification has
/// already normalized to a slot — so a window written twice
/// (`ROW_NUMBER() OVER w … ROW_NUMBER() OVER w`) is one windowing, one appended
/// slot. Equality is how the window path dedups the windows collected from the
/// projection and the `ORDER BY`.
internal struct Windowing: Equatable {
  /// The window function computed over each ordered partition.
  internal let function: WindowFunction

  /// The `PARTITION BY` keys splitting the records into partitions — empty when
  /// no `PARTITION BY` is written (the whole input is one partition).
  internal let partition: Array<Term>

  /// The window's `ORDER BY` keys fixing the row order within a partition —
  /// empty when none is written (every row a peer).
  internal let order: Array<SortKey>

  internal init(function: WindowFunction, partition: Array<Term>,
                order: Array<SortKey>) {
    self.function = function
    self.partition = partition
    self.order = order
  }
}

extension Windowing {
  /// This windowing with its partition and order terms' slots remapped through
  /// `slot` — the base-ordinal → source-slot map the window node's source is
  /// packed under.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Windowing {
    Windowing(function: function,
              partition: partition.map { $0.remapped(through: slot) },
              order: order.map { $0.remapped(through: slot) })
  }

  /// The source slots this windowing reads, accumulated into `slots` — its
  /// partition and order terms', so the source scan materialises exactly the
  /// cells the window partitions and orders on.
  internal func references(into slots: inout Set<Int>) {
    for term in partition { term.references(into: &slots) }
    for key in order { key.term.references(into: &slots) }
  }

  /// Whether every value this windowing evaluates per row — its partition and
  /// order keys and the function's own argument, value, offset default — is
  /// deterministic, so two structurally equal occurrences yield the same result
  /// and may share one appended slot (one evaluation). A stateful or
  /// non-deterministic input makes two occurrences diverge, so each keeps its
  /// own slot. An aggregate window carrying a `FILTER` is conservatively not
  /// shareable — the filter may hide a non-deterministic call this does not
  /// descend, and forgoing the share is always safe.
  internal func deterministic(_ routines: Routines) -> Bool {
    guard partition.allSatisfy({ $0.deterministic(routines) }),
          order.allSatisfy({ $0.term.deterministic(routines) }) else {
      return false
    }
    switch function {
    case .rowNumber, .rank, .denseRank:
      return true
    }
  }
}

// MARK: - Window discovery

extension Expression {
  /// Whether the expression contains a window function anywhere within it.
  ///
  /// A window is a first-class node (`.window`), so the flag is true for one
  /// directly and for any compound holding one (`ROW_NUMBER() OVER () + 1`, a
  /// `CASE` whose guard or result is a window). It mirrors `aggregated`, which
  /// carves the same descent for a nested aggregate; a window inside a scalar
  /// `subquery` belongs to that subquery, not the enclosing query, and a window
  /// nested in an aggregate's argument is that aggregate's problem — both are
  /// not windows of this query, so each is false here.
  internal var windowed: Bool {
    switch self {
    case .column, .literal, .subquery, .aggregate:
      false
    case .window:
      true
    case let .call(_, arguments):
      arguments.contains { $0.windowed }
    case let .binary(_, lhs, rhs):
      lhs.windowed || rhs.windowed
    case let .case(whens, otherwise):
      whens.contains { $0.when.windowed || $0.then.windowed }
          || (otherwise?.windowed ?? false)
    case let .cast(operand, _):
      operand.windowed
    case let .coalesce(arguments):
      arguments.contains { $0.windowed }
    case let .nullif(lhs, rhs):
      lhs.windowed || rhs.windowed
    case let .grouping(arguments):
      arguments.contains { $0.windowed }
    }
  }

  /// Collects the distinct window expressions within this expression into
  /// `expressions`, in first-appearance order — the same window written twice
  /// computes once. Mirrors the aggregate `collect(into:)`; a window inside a
  /// scalar `subquery` or an aggregate's argument belongs to that inner scope,
  /// so neither is collected here.
  internal func collect(windows expressions: inout Array<Expression>) {
    switch self {
    case .column, .literal, .subquery, .aggregate:
      break
    case .window:
      if !expressions.contains(self) { expressions.append(self) }
    case let .call(_, arguments):
      for argument in arguments { argument.collect(windows: &expressions) }
    case let .binary(_, lhs, rhs):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .case(whens, otherwise):
      for branch in whens {
        branch.when.collect(windows: &expressions)
        branch.then.collect(windows: &expressions)
      }
      otherwise?.collect(windows: &expressions)
    case let .cast(operand, _):
      operand.collect(windows: &expressions)
    case let .coalesce(arguments):
      for argument in arguments { argument.collect(windows: &expressions) }
    case let .nullif(lhs, rhs):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .grouping(arguments):
      for argument in arguments { argument.collect(windows: &expressions) }
    }
  }

  /// Lowers this AST `.window` expression to a `Windowing`, its `PARTITION BY`
  /// keys and window `ORDER BY` resolved to combined base-ordinal terms through
  /// `scope`. `self` is always an `.window` — the window collectors gather only
  /// those.
  internal func windowing(_ scope: Scope, _ routines: Routines = [:],
                          subquery: Resolution = .unsupported)
      throws(SQLError) -> Windowing {
    guard case let .window(function, spec) = self else {
      throw .state("XX000", "expected a window function")
    }
    let partition = try spec.partition.map { key throws(SQLError) -> Term in
      try scope.term(key, routines, subquery: subquery)
    }
    let order: Array<SortKey> = if let clause = spec.order {
      try scope.window(order: clause, routines, subquery: subquery)
    } else {
      []
    }
    return Windowing(function: function, partition: partition, order: order)
  }
}

extension Predicate {
  /// Whether this predicate compares a window function anywhere within it — a
  /// window in a comparison operand (a `CASE` guard's `ROW_NUMBER() OVER () >
  /// 1`). Mirrors `Predicate.aggregated`; an `EXISTS`/`IN (Q)` subquery is its
  /// own scope, so a window inside it is that query's, not this predicate's.
  internal var windowed: Bool {
    switch self {
    case let .comparison(left, _, right):
      left.windowed || right.windowed
    case let .bound(left, _, _):
      left.windowed
    case let .null(expression, _):
      expression.windowed
    case let .membership(operand, values, _):
      operand.windowed || values.contains { $0.windowed }
    case let .rows(lhs, _, rhs):
      lhs.contains { $0.windowed } || rhs.contains { $0.windowed }
    case let .among(lhs, rows, _):
      lhs.contains { $0.windowed }
          || rows.contains { $0.contains { $0.windowed } }
    case .exists:
      false
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      lhs.contains { $0.windowed }
    case let .like(operand, pattern, escape, _):
      operand.windowed || pattern.windowed || (escape?.windowed ?? false)
    case let .between(test, lower, upper, _):
      test.windowed || lower.windowed || upper.windowed
    case let .distinct(lhs, rhs, _):
      lhs.windowed || rhs.windowed
    case let .truth(inner, _, _):
      inner.windowed
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.windowed || rhs.windowed
    case let .not(operand):
      operand.windowed
    }
  }
}

extension Predicate.Operand {
  /// Whether this LIKE pattern/escape operand holds a window — an expression
  /// operand may, a run-time `:parameter` never does.
  fileprivate var windowed: Bool {
    switch self {
    case let .expression(expression): expression.windowed
    case .parameter: false
    }
  }

  /// Collects the distinct windows within this operand — an expression operand
  /// may hold one, a `:parameter` never does.
  fileprivate func collect(windows expressions: inout Array<Expression>) {
    if case let .expression(expression) = self {
      expression.collect(windows: &expressions)
    }
  }
}

extension Predicate {
  /// Collects the distinct window expressions within this predicate into
  /// `expressions` — those in a comparison operand (a `CASE` guard's window).
  /// Mirrors the aggregate `collect(into:)`; an `EXISTS`/`IN (Q)` subquery is
  /// its own scope, so a window inside it is not collected here.
  internal func collect(windows expressions: inout Array<Expression>) {
    switch self {
    case let .comparison(left, _, right):
      left.collect(windows: &expressions)
      right.collect(windows: &expressions)
    case let .bound(left, _, _):
      left.collect(windows: &expressions)
    case let .null(expression, _):
      expression.collect(windows: &expressions)
    case let .membership(operand, values, _):
      operand.collect(windows: &expressions)
      for value in values { value.collect(windows: &expressions) }
    case let .rows(lhs, _, rhs):
      for expression in lhs { expression.collect(windows: &expressions) }
      for expression in rhs { expression.collect(windows: &expressions) }
    case let .among(lhs, rows, _):
      for expression in lhs { expression.collect(windows: &expressions) }
      for element in rows {
        for expression in element { expression.collect(windows: &expressions) }
      }
    case .exists:
      break
    case let .within(lhs, _, _), let .quantified(lhs, _, _, _):
      for expression in lhs { expression.collect(windows: &expressions) }
    case let .like(operand, pattern, escape, _):
      operand.collect(windows: &expressions)
      pattern.collect(windows: &expressions)
      escape?.collect(windows: &expressions)
    case let .between(test, lower, upper, _):
      test.collect(windows: &expressions)
      lower.collect(windows: &expressions)
      upper.collect(windows: &expressions)
    case let .distinct(lhs, rhs, _):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .truth(inner, _, _):
      inner.collect(windows: &expressions)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.collect(windows: &expressions)
      rhs.collect(windows: &expressions)
    case let .not(operand):
      operand.collect(windows: &expressions)
    }
  }
}

// MARK: - Window ORDER BY

extension Scope {
  /// Lowers a window's `ORDER BY` to sort keys over the source scope, major to
  /// minor — each key an ISO `<sort key>` value expression lowered to a `Term`,
  /// its direction preserved.
  ///
  /// A window `ORDER BY` fixes the input row order the ranking reads, so each
  /// key is a value expression over the source columns — never an output
  /// ordinal or alias (there is no projected output to name at this point). An
  /// integer-literal sort key parses as an `ordinal`, which names an output
  /// column, so it is meaningless here and faults the feature diagnostic on
  /// both the run and validate paths (kept in parity through the shared
  /// resolver).
  internal func window(order: Order, _ routines: Routines = [:],
                       subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    var keys = Array<SortKey>()
    keys.reserveCapacity(order.keys.count)
    for key in order.keys {
      switch key.sort {
      case .ordinal:
        throw .state("0A000",
                     "a window ORDER BY output ordinal is not supported")
      case let .expression(expression):
        try keys.append(SortKey(term: term(expression, routines,
                                            subquery: subquery),
                                ascending: key.ascending, column: nil))
      }
    }
    return keys
  }
}

// MARK: - Windowed scope

/// The output slot space of a window query — the lowering surface for the
/// projection and `ORDER BY` that read a window node's records.
///
/// A `window` node passes its source's records through unchanged (slots `0 ..<
/// width`) and appends one slot per windowing (slot `width + j` is
/// `windowings[j]`'s value). A `Windowed` lowers a name-addressed AST
/// expression into that space: a window function maps to its appended slot; any
/// other reference lowers over the source scope and remaps into the packed
/// source slots. Unlike the grouped scope — where a bare non-key column faults
/// — a window is cardinality-preserving, so a bare source column is an ordinary
/// pass-through reference to its own slot.
///
/// It also records each projected item's output name so an `ORDER BY` may name
/// a projection alias, exactly as the grouped surface does.
internal struct Windowed {
  private let scope: Scope

  /// The base-ordinal → packed source-slot map the window node's source is
  /// materialised under — the same map the source chain's terms are remapped
  /// through, so a window-free reference lowers over the source scope and lands
  /// in the source's slot space.
  private let slot: Dictionary<Int, Int>

  /// The source slot count — the boundary the appended window results begin at
  /// (windowing `j` at slot `width + j`).
  private let width: Int

  /// The windowings the query computes, appended one slot each (windowing `j` at
  /// slot `width + j`), built as `slot(of:)` first meets each window during
  /// lowering — a deterministic window shared by its resolved `Windowing`, a
  /// stateful or non-deterministic one kept distinct per occurrence. It is a
  /// reference so the non-mutating lowering accumulates into it; the two lowering
  /// passes each walk the same projection and `ORDER BY`, so each builds an
  /// identical list (one over the identity space, one over the packed source).
  private final class Registry {
    var windowings = Array<Windowing>()
  }
  private let registry = Registry()

  /// The windowings collected so far — after a full projection/`ORDER BY`
  /// lowering, the query's complete list, windowing `j` at appended slot `width
  /// + j`.
  internal var windowings: Array<Windowing> { registry.windowings }

  /// Each projected item's output name (an alias, else a bare column's name),
  /// lowercased, mapped to its output term and its 0-based projection column —
  /// the surface an `ORDER BY` names a projection alias against.
  private var aliases: Dictionary<String, (term: Term, column: Int)> = [:]

  /// Output names two or more projected items share, lowercased. An `ORDER BY`
  /// naming one has no single slot to order on — the ambiguity the ordinary
  /// `order` reports for a shared unqualified column.
  private var ambiguous: Set<String> = []

  /// Builds a windowed surface over `scope`, the packed source-slot map `slot`,
  /// and the source `width` (the boundary appended window results begin at). The
  /// windowings are gathered during lowering, so `windowings` is empty until the
  /// projection and `ORDER BY` have been lowered.
  internal init(_ scope: Scope, _ slot: Dictionary<Int, Int>, width: Int) {
    self.scope = scope
    self.slot = slot
    self.width = width
  }

  /// The appended slot a window `expression` resolves to, or `nil` if it is not
  /// a window. The expression is resolved to a source-space `Windowing`; a
  /// deterministic one matches those already collected — so a
  /// qualification-equivalent window (`OVER (ORDER BY x)` vs `OVER (ORDER BY
  /// T.x)`) shares one slot — while an unmatched or non-deterministic one is
  /// appended to take a fresh slot.
  private func slot(of expression: Expression, _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Int? {
    guard case .window = expression else { return nil }
    let windowing = try expression.windowing(scope, routines,
                                             subquery: subquery)
        .remapped(through: slot)
    // Share an appended slot only with an already-collected deterministic
    // window; a stateful or non-deterministic window takes a fresh slot per
    // occurrence, so two occurrences of it (`FIRST_VALUE(tick())` written twice)
    // each evaluate independently rather than reading one shared computation.
    if windowing.deterministic(routines),
        let index = registry.windowings.firstIndex(of: windowing) {
      return width + index
    }
    let index = registry.windowings.count
    registry.windowings.append(windowing)
    return width + index
  }

  /// Lowers an `expression` to its output-space `Term` — the module-visible
  /// entry to the private `term`.
  internal func resolve(_ expression: Expression,
                        _ routines: Routines = [:],
                        subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    try term(expression, routines, subquery: subquery)
  }

  /// Lowers a scalar `expression` to an output-space `Term`.
  ///
  /// A window function maps to its appended slot; a window-free expression
  /// lowers wholesale over the source scope and remaps into the packed source
  /// slots; a compound nesting a window (`ROW_NUMBER() OVER () + 1`) recurses,
  /// lowering the window leaves to their appended slots and the ordinary leaves
  /// over the source.
  private func term(_ expression: Expression,
                    _ routines: Routines = [:],
                    subquery: Resolution = .unsupported)
      throws(SQLError) -> Term {
    if case .window = expression {
      if let slot = try slot(of: expression, routines, subquery: subquery) {
        return .slot(slot)
      }
      // A window reaches here only when it was not collected — an internal
      // inconsistency, since the query gathers every projection/ORDER BY window.
      throw .state("XX000", "uncollected window")
    }
    // A window-free expression carries no appended slot, so it lowers as an
    // ordinary source reference — over the source scope, then remapped into the
    // packed source slots. A bare source column reads its own slot (a window is
    // cardinality-preserving, so no grouping rule bars it).
    if !expression.windowed {
      return try scope.term(expression, routines, subquery: subquery)
          .remapped(through: slot)
    }
    // A compound nesting a window: recurse so each window leaf maps to its
    // appended slot and each ordinary leaf lowers over the source.
    switch expression {
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, routines, subquery: subquery))
      }
      return .apply(name: name.lowercased(), arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    case let .case(whens, otherwise):
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
      let type = try scope.derive(whens, otherwise, routines,
                                  subquery: subquery)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      return try .cast(term(operand, routines, subquery: subquery), type)
    case let .coalesce(arguments):
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines, subquery: subquery))
      }
      let type = try scope.derive(expression, routines, subquery: subquery)
      return .coalesce(elements, type: type)
    case let .nullif(lhs, rhs):
      return try .nullif(term(lhs, routines, subquery: subquery),
                         term(rhs, routines, subquery: subquery))
    default:
      // Every other shape is either not window-bearing (handled above) or a
      // leaf a window cannot nest through, so it never reaches here.
      throw .state("XX000", "unlowered window expression")
    }
  }

  /// Lowers a predicate (a `CASE` guard) to an output-space `Filter`, its
  /// operand expressions lowered through `term` so a window in a comparison
  /// maps to its appended slot.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Filter {
    try SQLEngine.lower(predicate, term: { expression throws(SQLError) in
      try term(expression, routines, subquery: subquery)
    }, subquery: subquery)
  }

  /// Records a projected item's output `name` at projection `column` → its
  /// output `term`, flagging the name ambiguous if another item already claimed
  /// it.
  private mutating func record(_ name: String, _ column: Int, _ term: Term) {
    let key = name.lowercased()
    let entry = (term: term, column: column)
    if aliases.updateValue(entry, forKey: key) != nil { ambiguous.insert(key) }
  }

  /// The output-space projected terms, recording each item's output name for an
  /// `ORDER BY` to name. A `SELECT *` over a window query has no well-defined
  /// meaning (which windows?), so it faults.
  internal mutating func terms(_ projection: Projection,
                               _ routines: Routines = [:],
                               subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<Term> {
    // A window-query projection is a barred clause position (a correlated
    // column of this query is diagnosed there, as the run's projection bars it).
    let subquery = subquery.barred
    switch projection {
    case .all:
      throw .state("0A000",
                   "SELECT * is not allowed with a window function")
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
        if let name = items[index].name { record(name, index, term) }
      }
      return terms
    }
  }

  /// The resolved sort keys a query `ORDER BY` lowers to in output space, major
  /// to minor — an ordinal names the query's `n`-th projected column, an
  /// unqualified name a projection alias first (else a source column), and any
  /// other expression lowers over the output through `term`.
  internal func order(_ order: Order, _ projection: Array<Term>,
                      _ routines: Routines = [:],
                      subquery: Resolution = .unsupported)
      throws(SQLError) -> Array<SortKey> {
    // A query ORDER BY is barred, as the projection is.
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
          if ambiguous.contains(name) { throw .ambiguous(reference.name) }
          if let alias = aliases[name] {
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
