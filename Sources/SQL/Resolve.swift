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

/// Lowers the name-addressed AST `predicate` to the engine's `Filter`, lowering
/// each leaf's operand expressions through `term` and passing a `bound`
/// comparison's `:parameter` through unchanged.
///
/// Every predicate lowering — a single relation, a join scope, a grouped scope —
/// shares this shape, differing only in how a leaf term resolves its columns
/// (against one schema, a combined join space, or a grouped slot space); each
/// caller supplies that resolution as `term`.
private func lower(_ predicate: Predicate,
                   term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  switch predicate {
  case let .comparison(left, op, right):
    try .compare(term(left), op, term(right))
  case let .bound(left, op, parameter):
    try .bound(term(left), op, parameter)
  case let .null(expression, negated):
    try .null(term(expression), negated: negated)
  case let .and(lhs, rhs):
    try .and(lower(lhs, term: term), lower(rhs, term: term))
  case let .or(lhs, rhs):
    try .or(lower(lhs, term: term), lower(rhs, term: term))
  case let .not(operand):
    try .not(lower(operand, term: term))
  }
}

/// The resolved sort keys `order` lowers to, in major-to-minor order — each
/// key's column resolved to an ordinal through `ordinal` and its direction
/// preserved.
///
/// A single relation and a join scope share this shape, differing only in how a
/// key's column resolves to an ordinal (against one schema, or a combined join
/// space); each caller supplies that resolution as `ordinal`. A grouped scope
/// orders on projection aliases and grouped slots, so it does not share it.
private func order(_ order: Order,
                   ordinal: (Column) throws(SQLError) -> Int)
    throws(SQLError) -> Array<(column: Int, ascending: Bool)> {
  var keys = Array<(column: Int, ascending: Bool)>()
  keys.reserveCapacity(order.keys.count)
  for key in order.keys {
    try keys.append((column: ordinal(key.column), ascending: key.ascending))
  }
  return keys
}

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
    try SQL.order(order) { column throws(SQLError) in
      try ordinal(of: column, in: relation)
    }
  }

  internal func lower(_ predicate: Predicate, in relation: Relation)
      throws(SQLError) -> Filter {
    try SQL.lower(predicate) { expression throws(SQLError) in
      try term(expression, in: relation)
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

  /// The value type of a `literal` operand — the domain of the value it stands
  /// for. Shared by both the schema and type-check surfaces.
  private func type(of literal: Literal) -> ValueType {
    switch literal {
    case .string: .text
    case .integer: .integer
    case .double: .double
    case .boolean: .boolean
    case .blob: .blob
    }
  }

  /// DERIVES the nominal value type a scalar `expression` yields WITHOUT
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
  /// This is the SCHEMA surface. `validate(_:_:)` is the type-check surface: it
  /// faults exactly as a run would on a bad operand or an unknown/misused call.
  internal func derive(_ expression: Expression, _ routines: Routines = [:])
      throws(SQLError) -> ValueType {
    return switch expression {
    case let .column(column):
      try type(at: ordinal(of: column))
    case let .literal(literal):
      type(of: literal)
    case let .call(name, _):
      routines[name]?.returns ?? .integer
    case let .aggregate(function, operand):
      switch function {
      // `COUNT` always counts rows to an integer; `AVG` folds to a double;
      // `SUM`/`MIN`/`MAX` take the operand's own type (an integer for `.star`).
      case .count: .integer
      case .avg: .double
      case .sum, .min, .max:
        switch operand {
        case .star: .integer
        case let .expression(argument): try derive(argument, routines)
        }
      }
    case let .binary(_, lhs, rhs):
      try [derive(lhs, routines), derive(rhs, routines)].contains(.double)
          ? .double : .integer
    }
  }

  /// The value type a scalar `expression` yields, VALIDATING each operand and
  /// call exactly as a run would fault: an aggregate or arithmetic over a
  /// non-numeric operand (`SQLError.operand`), a call to an unregistered
  /// routine (`SQLError.function`), a bad arity or argument kind
  /// (`SQLError.argument`), a `/` by a literal zero (`SQLError.divide`), or a
  /// deterministic overflow of two folded literal operands
  /// (`SQLError.magnitude`) faults precisely where a run would raise it. It
  /// resolves column ordinals and reads no cursor, so it type-checks a query
  /// without executing it.
  ///
  /// This is the TYPE-CHECK surface. `derive(_:_:)` is the non-faulting schema
  /// surface, which only DERIVES the nominal output type.
  internal func validate(_ expression: Expression, _ routines: Routines = [:])
      throws(SQLError) -> ValueType {
    switch expression {
    case let .column(column):
      try type(at: ordinal(of: column))
    case let .literal(literal):
      type(of: literal)
    case let .call(name, arguments):
      try call(name, over: arguments, routines)
    case let .aggregate(function, operand):
      try aggregate(function, over: operand, routines)
    case let .binary(op, lhs, rhs):
      try arithmetic(op, lhs, rhs, routines)
    }
  }

  /// The result type of the scalar routine `name` called over `arguments`,
  /// validating its declared signature exactly as a run would fault: an
  /// unregistered name faults `SQLError.function`; the argument count must
  /// equal the routine's `parameters` arity; and each argument's static type
  /// must equal the declared parameter type. A nullable column of the DECLARED
  /// type passes — statically it carries its declared type and a run-time NULL
  /// propagates — so only a definitively-wrong type (text where an integer is
  /// required) is rejected, mirroring a routine like `BITAND` throwing
  /// `SQLError.argument` on a non-integer non-NULL value. Each argument is
  /// validated too, so a type error nested in a call — `BITAND(Name + 1, 1)`
  /// over text — faults exactly as a run would, rather than the call reporting
  /// its return type over an un-evaluable argument `compile` resolved but never
  /// type-checked.
  private func call(_ name: String, over arguments: Array<Expression>,
                    _ routines: Routines)
      throws(SQLError) -> ValueType {
    guard let routine = routines[name] else { throw .function(name) }
    guard arguments.count == routine.parameters.count else {
      throw .argument("\(name) takes \(routine.parameters.count) arguments")
    }
    for (argument, expected) in zip(arguments, routine.parameters) {
      let type = try validate(argument, routines)
      guard type == expected else {
        throw .argument("\(name) requires \(expected.domain) arguments")
      }
    }
    return routine.returns
  }

  /// The result type of `function` folded over `operand`, validating the
  /// operand as a run would fault. `COUNT` counts rows (`.integer`);
  /// `MIN`/`MAX` take the operand's own type — they compare, so any comparable
  /// value folds. `SUM`/`AVG` fold NUMERICALLY: `SUM` yields the operand's
  /// numeric type, `AVG` a double, so both REQUIRE a numeric operand — over
  /// text, boolean, or blob `Aggregate.fold` faults `SQLError.operand` on the
  /// first non-NULL value, so typing faults the same way rather than
  /// advertising `AVG(Name)` as a double or `SUM(Name)` as text for a query
  /// that cannot fold its rows.
  private func aggregate(_ function: Aggregate, over operand: Aggregand,
                         _ routines: Routines)
      throws(SQLError) -> ValueType {
    switch function {
    case .count:
      // `COUNT(expr)` evaluates `expr` per row to test it is non-NULL, so
      // validate the operand (`COUNT(*)` has none); the result is always an
      // integer count.
      if case let .expression(argument) = operand {
        _ = try validate(argument, routines)
      }
      return .integer
    case .min, .max:
      switch operand {
      case .star: return .integer
      case let .expression(argument):
        return try validate(argument, routines)
      }
    case .sum, .avg:
      let type: ValueType = switch operand {
      case .star: .integer
      case let .expression(argument):
        try validate(argument, routines)
      }
      if !type.numeric { throw .operand("operands must be numeric") }
      return function == .avg ? .double : type
    }
  }

  /// The result type of `lhs op rhs` — a double when either operand is a double
  /// (`Age + 1.5`), else an integer — validating both operands are numeric (a
  /// text/boolean/blob operand has no arithmetic — `Arithmetic.apply` faults
  /// `SQLError.operand`); a `/` by a literal zero is rejected up front
  /// (`SQLError.divide`); and two literal operands are folded to reject a
  /// deterministic overflow (`SQLError.magnitude`). Typing thus faults as a run
  /// would rather than advertise a header no row can produce.
  private func arithmetic(_ op: Arithmetic, _ lhs: Expression,
                          _ rhs: Expression,
                          _ routines: Routines)
      throws(SQLError) -> ValueType {
    let left = try validate(lhs, routines)
    let right = try validate(rhs, routines)
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

  /// Whether `expression` is a literal zero — the statically-known divisor a
  /// `/` would fault on.
  private func zero(_ expression: Expression) -> Bool {
    switch expression {
    case .literal(.integer(0)): true
    case let .literal(.double(value)): value == 0
    default: false
    }
  }

  /// Type-checks every operand expression in `predicate` — a comparison's two
  /// sides, an `IS NULL` operand — recursing through `AND`/`OR`/`NOT`. It types
  /// each for the side effect of validation (an operand or function fault a run
  /// would raise) and discards the result. A `left op :parameter` bound
  /// comparison is NOT checked: with no binding (the schema default) the run
  /// yields UNKNOWN without evaluating the left term.
  ///
  /// It respects the executor's short-circuit: `false AND rhs` and `true OR
  /// rhs` never evaluate `rhs` (`evaluate` returns on the left arm), so a right
  /// arm a STATICALLY-false `AND` (or true `OR`) guards is unreachable and is
  /// not type-checked — `WHERE 1 = 0 AND Name + 1 = 2` runs, so its schema
  /// resolves rather than faulting on the unreachable `Name + 1`.
  func check(_ predicate: Predicate,
             _ routines: Routines = [:])
      throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      _ = try validate(left, routines)
      _ = try validate(right, routines)
    case .bound:
      // `left op :parameter` with no binding — the schema default `[:]` —
      // yields UNKNOWN without evaluating the left term, so a run just produces
      // no rows; schema validation has no bindings, so it does not evaluate it.
      break
    case let .null(operand, _):
      _ = try validate(operand, routines)
    case let .and(lhs, rhs):
      try check(lhs, routines)
      if constant(lhs) != false { try check(rhs, routines) }
    case let .or(lhs, rhs):
      try check(lhs, routines)
      if constant(lhs) != true { try check(rhs, routines) }
    case let .not(operand):
      try check(operand, routines)
    }
  }

  /// The definite constant truth value of `predicate` when it is statically
  /// decidable — a comparison of literal operands, composed through
  /// `AND`/`OR`/`NOT` — else `nil` (a predicate reading a column or a
  /// `:parameter` is decided per row). `check(_:_:)` reads it to skip an arm
  /// the executor's short-circuit proves unreachable, matching `matches` and
  /// `value(of:)`, the primitives the run itself evaluates a comparison with.
  func constant(_ predicate: Predicate) -> Bool? {
    switch predicate {
    case let .comparison(left, op, right):
      guard case let .literal(left) = left, case let .literal(right) = right,
          let lhs = try? value(of: left), let rhs = try? value(of: right) else {
        return nil
      }
      return matches(lhs, op, rhs)
    case let .and(lhs, rhs):
      // `constant` is a pure fold with no side effect, so both arms evaluate.
      return and(constant(lhs), constant(rhs))
    case let .or(lhs, rhs):
      return or(constant(lhs), constant(rhs))
    case let .not(operand):
      guard let value = constant(operand) else { return nil }
      return !value
    case let .null(operand, negated):
      // A literal is never NULL, so `IS NULL` is definitely false and `IS NOT
      // NULL` (`negated`) definitely true; a non-literal operand is per row.
      guard case .literal = operand else { return nil }
      return negated
    case .bound:
      return nil
    }
  }

  /// Validates the aggregate sub-expressions of `expression` — an aggregate's
  /// fold runs over every row (in the aggregate node) BEFORE a `LIMIT`, so it
  /// is reachable even under a zero-row limit — WITHOUT validating the
  /// surrounding per-result expression a run never reaches. It recurses through
  /// a binary's operands and a call's arguments to reach an aggregate, then
  /// validates it (its operand included); a bare column or literal has none.
  func aggregates(in expression: Expression,
                  _ routines: Routines = [:])
      throws(SQLError) {
    switch expression {
    case .column, .literal:
      break
    case let .aggregate(function, operand):
      _ = try aggregate(function, over: operand, routines)
    case let .call(_, arguments):
      for argument in arguments { try aggregates(in: argument, routines) }
    case let .binary(_, lhs, rhs):
      try aggregates(in: lhs, routines)
      try aggregates(in: rhs, routines)
    }
  }

  /// Validates the aggregate sub-expressions of `predicate` — a `HAVING`'s
  /// aggregates are collected and FOLDED by the group node before the `HAVING`
  /// filter runs, so they are reachable even in an arm the filter's
  /// short-circuit skips. It walks EVERY arm (unlike `check`), reaching an
  /// aggregate through a comparison's operands and `AND`/`OR`/`NOT`.
  func aggregates(in predicate: Predicate,
                  _ routines: Routines = [:])
      throws(SQLError) {
    switch predicate {
    case let .comparison(left, _, right):
      try aggregates(in: left, routines)
      try aggregates(in: right, routines)
    case let .bound(left, _, _):
      try aggregates(in: left, routines)
    case let .null(operand, _):
      try aggregates(in: operand, routines)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      try aggregates(in: lhs, routines)
      try aggregates(in: rhs, routines)
    case let .not(operand):
      try aggregates(in: operand, routines)
    }
  }

  /// The value `expression` yields when a whole-result aggregate projects the
  /// single empty group a constant-false `WHERE` leaves — the fold over zero
  /// rows: `COUNT` is 0, every other aggregate NULL, a literal itself, a binary
  /// the operator applied to its folded operands, a call the routine applied to
  /// its folded arguments. It EVALUATES the empty group exactly as a run does,
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
    case let .aggregate(function, _):
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
    case .column:
      return .null
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
      return matches(try empty(left, routines), op, try empty(right, routines))
    case .bound:
      return nil
    case let .null(operand, negated):
      let value = try empty(operand, routines)
      let null = if case .null = value { true } else { false }
      return negated ? !null : null
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
    try SQL.order(order) { column throws(SQLError) in
      try ordinal(of: column)
    }
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
    try SQL.lower(predicate) { expression throws(SQLError) in
      try term(expression)
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
        // Record the output name (`Projected.name` — an alias, else a bare
        // column's name) so an `ORDER BY` may name it (the standard alias
        // ordering on an aggregate); a computed item names nothing.
        if let name = item.name { record(name, term) }
      }
      return terms
    }
  }

  /// Lowers a `HAVING`/predicate to a grouped-space `Filter`.
  internal func lower(_ predicate: Predicate) throws(SQLError) -> Filter {
    try SQL.lower(predicate) { expression throws(SQLError) in
      try term(expression)
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
