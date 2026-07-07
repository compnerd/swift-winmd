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
  case let .membership(expression, values, negated):
    // `x IN (a, b, …)` is the disjunction `x = a OR x = b OR …` and `NOT IN`
    // its negation, lowered to a first-class `Filter.membership` that evaluates
    // the operand ONCE per row (an OR-chain would re-evaluate a side-effecting
    // operand once per element) and folds the element equalities under Kleene
    // `OR`. That yields the ISO three-valued result: an unmatched test with a
    // NULL operand or a NULL element is UNKNOWN — Kleene `OR` of a FALSE and an
    // UNKNOWN is UNKNOWN — not FALSE, and `NOT` maps that UNKNOWN to itself, so
    // `NOT IN` a list holding NULL is never TRUE.
    try membership(term(expression), values, negated: negated, term: term)
  case let .like(operand, pattern, escape, negated):
    // Lower each operand to a first-class `Filter.like`; the optional escape
    // lowers only when present. The matcher and three-valued handling live in
    // the runtime, so lowering just resolves the operand terms.
    try like(operand, pattern, escape, negated: negated, term: term)
  case let .and(lhs, rhs):
    try .and(lower(lhs, term: term), lower(rhs, term: term))
  case let .or(lhs, rhs):
    try .or(lower(lhs, term: term), lower(rhs, term: term))
  case let .not(operand):
    try .not(lower(operand, term: term))
  }
}

/// Lowers `x [NOT] IN (v, …)` — the operand already lowered to `left` — to a
/// first-class `Filter.membership(left, [v0, v1, …], negated:)`, each value
/// lowered through `term`.
///
/// The operand is held ONCE rather than copied into an OR-chain of `left = vi`
/// comparisons: that chain re-evaluated `left` per element, so a non-idempotent
/// operand (a side-effecting scalar call) yielded a different value each
/// element compared against. The `Filter.membership` runtime evaluates `left`
/// exactly once per row, then folds `left = vi` over the elements IN ORDER
/// under Kleene `OR` — the same left-to-right short-circuit and
/// NULL/three-valued semantics the OR-chain had — and `negated` applies the
/// `NOT IN` negation.
///
/// The value list must be non-empty: the parser rejects `IN ()`, but
/// `Predicate.membership` is public, so a caller can hand this lowering an
/// empty list directly, bypassing the grammar. An empty list has no element to
/// compare against — the membership is undefined — so reject it as an
/// unsupported shape rather than folding it.
private func membership(_ left: Term, _ values: Array<Expression>,
                        negated: Bool,
                        term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  guard !values.isEmpty else {
    throw .unsupported("IN requires a non-empty value list")
  }
  var elements = Array<Term>()
  elements.reserveCapacity(values.count)
  for value in values {
    try elements.append(term(value))
  }
  return .membership(left, elements, negated: negated)
}

/// Lowers `operand [NOT] LIKE pattern [ESCAPE escape]` to a first-class
/// `Filter.like`, the operand lowered through `term`, the pattern and optional
/// escape through `operand(_:)` — an expression lowers to a term, a
/// `:parameter` passes through as a bound name resolved at eval.
///
/// Lowering is a plain term resolution — the `%`/`_` matcher and the
/// three-valued/cross-kind handling are the runtime's — so this mirrors the
/// membership lowering, differing only in carrying the pattern and escape
/// operands rather than a value list.
private func like(_ operand: Expression, _ pattern: Predicate.Operand,
                  _ escape: Predicate.Operand?, negated: Bool,
                  term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter {
  let escape: Filter.Operand? =
      if let escape { try lower(escape, term: term) } else { nil }
  return try .like(term(operand), pattern: lower(pattern, term: term),
                   escape: escape, negated: negated)
}

/// Lowers a `LIKE` pattern or escape `operand` to its filter form: an
/// expression lowers to a `.term` through `term`; a `:parameter` passes through
/// as a bound `.parameter` name resolved from the bindings at eval, the same
/// mechanism a `Predicate.bound` comparison uses.
private func lower(_ operand: Predicate.Operand,
                   term: (Expression) throws(SQLError) -> Term)
    throws(SQLError) -> Filter.Operand {
  switch operand {
  case let .expression(expression): try .term(term(expression))
  case let .parameter(name): .parameter(name)
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
  internal func terms(_ projection: Projection, in relation: Relation,
                      _ routines: Routines = [:])
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
        try terms.append(term(item.expression, in: relation, routines))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to an ordinal-addressed `Term`: a column to a
  /// `.slot(ordinal)`, a literal to a `.constant`, a call to an `.apply` over
  /// its lowered arguments.
  internal func term(_ expression: Expression, in relation: Relation,
                     _ routines: Routines = [:])
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
        try lowered.append(term(argument, in: relation, routines))
      }
      return .apply(name: name, arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, in: relation, routines),
                         term(rhs, in: relation, routines))
    case let .case(whens, otherwise):
      // Lower each branch's guard predicate to a `Filter` and its result to a
      // `Term`, and the `ELSE` to a `Term`, over this relation's resolution.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        let gate = try lower(branch.when, in: relation, routines)
        try branches.append((gate, term(branch.then, in: relation, routines)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, in: relation, routines)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — so the executor COERCES the selected
      // branch's value to the type the schema advertises. Derive it against a
      // one-relation scope, this Schema's own resolution surface.
      let scope = Scope([(relation, self)])
      let type = try scope.derive(whens, otherwise, routines)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand and attach the target type; the executor converts the
      // evaluated value to it (`Value.cast(to:)`).
      return try .cast(term(operand, in: relation, routines), type)
    case let .coalesce(arguments):
      // Lower each argument to a `Term` over this relation and hold them in a
      // first-class `Term.coalesce` so each is evaluated ONCE. `type` is the
      // unified argument type the selected value coerces to, derived against a
      // one-relation scope.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, in: relation, routines))
      }
      let scope = Scope([(relation, self)])
      let type = try scope.derive(expression, routines)
      return .coalesce(elements, type: type)
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

  internal func lower(_ predicate: Predicate, in relation: Relation,
                      _ routines: Routines = [:])
      throws(SQLError) -> Filter {
    try SQL.lower(predicate) { expression throws(SQLError) in
      try term(expression, in: relation, routines)
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
    case let .case(whens, otherwise):
      // The result type is the unification of every REACHABLE branch result (and
      // the `ELSE`) — the executor's short-circuit means an unreachable branch
      // (a constant-false guard, or any branch after a constant-true one) never
      // yields a value, so it cannot shape the column's type. The reachable
      // result types must UNIFY; a definitively-irreconcilable clash (text
      // beside an integer) faults `SQLError.operand` here too, so this lowering
      // surface and the faulting `validate` AGREE. A `CASE` always has at least
      // one `WHEN`; when none is reachable (every guard constant-false, no
      // reachable `ELSE`) the run yields NULL, for which `.integer` is the
      // schema default.
      try derive(whens, otherwise, routines)
    case let .cast(operand, type):
      // A cast's static type is the target type; the conversion is nominal, so
      // the operand's own type does not shape it. Derive the operand anyway for
      // its ordinal resolution — an unknown/ambiguous column faults as a
      // projection would.
      try derive(cast: operand, to: type, routines)
    case let .coalesce(arguments):
      // The result type is the unification of the arguments (the same
      // `ValueType.unified` reduction a `CASE`'s results take), the type the
      // selected value coerces to.
      try unified(arguments, routines)
    }
  }

  /// The target `type` of a `CAST`, deriving `operand` for its ordinal
  /// resolution — a schema-surface non-faulting derive of the operand — and
  /// discarding its type, the conversion being nominal.
  private func derive(cast operand: Expression, to type: ValueType,
                      _ routines: Routines) throws(SQLError) -> ValueType {
    _ = try derive(operand, routines)
    return type
  }

  /// The unification of the types of `arguments` — the `ValueType.unified`
  /// reduction a `CASE`'s reachable results and a `COALESCE`'s arguments both
  /// take. A definitively-irreconcilable pair (a text beside an integer) faults
  /// `SQLError.operand`; a mixed integer/double pair widens to `double`. The
  /// list is never empty (the parser requires ≥ 2 COALESCE arguments).
  ///
  /// Only a SELECTABLE argument shapes the type. A run skips an argument
  /// whose value is NULL and moves on, so an argument folding to a constant
  /// `.null` (`constant(_ expression:)`) can NEVER be the result — its type is
  /// derived (an unknown column still faults) but is NOT merged, exactly as a
  /// `CASE` omits an unreachable branch's result type. And an argument that is
  /// the definite selection (`selects(_:)` — a constant NON-NULL value, or a
  /// `COUNT` aggregate that is always non-NULL) sets the type and makes every
  /// LATER argument unreachable — mirroring a `CASE`'s reachable-branch
  /// unification and the faulting `validate`'s stop.
  private func unified(_ arguments: Array<Expression>,
                       _ routines: Routines) throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try derive(argument, routines)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is derived (for its errors) but skipped: it can never
        // be returned, so its type must not shape the column.
        continue
      }
      guard !selects(argument, routines) else {
        // A definite selection: merge its type and stop, as every later
        // argument is unreachable.
        return try merged(type, next)
      }
      type = try merged(type, next)
    }
    return type ?? .integer
  }

  /// Whether `argument` is a COALESCE's definite selection — an argument the
  /// executor's short-circuit is GUARANTEED to return, making every later
  /// argument unreachable (neither validated nor unified). That holds when it
  /// folds to a constant NON-NULL value (`constant(_ expression:)`), or when it
  /// is a `COUNT` aggregate: `COUNT` alone among the aggregates always yields a
  /// row count of 0 or more, never NULL, so it always selects — while `SUM` /
  /// `MIN` / `MAX` / `AVG` are NULL over an empty group and so do NOT stop.
  private func selects(_ argument: Expression, _ routines: Routines) -> Bool {
    return switch argument {
    case .aggregate(.count, _): true
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
  /// REACHABLE result types, and `.integer` when no branch is reachable (the
  /// run yields NULL). The reachable result types must UNIFY (`unified`):
  /// a definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, so this lowering surface AGREES with the
  /// faulting `validate` (`conditional`) — a mixed integer/double `CASE` still
  /// widens to `double`.
  internal func derive(_ whens: Array<When>, _ otherwise: Expression?,
                       _ routines: Routines)
      throws(SQLError) -> ValueType {
    let results = reachable(whens, otherwise, routines)
    guard !results.isEmpty else { return .integer }
    var type = try derive(results[0], routines)
    for result in results.dropFirst() {
      let next = try derive(result, routines)
      guard let unified = type.unified(with: next) else {
        throw .operand("CASE results have irreconcilable types")
      }
      type = unified
    }
    return type
  }

  /// The result expressions of a `CASE` the executor's short-circuit can REACH,
  /// in branch order: a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result and is dropped; a `WHEN` whose guard is statically
  /// constant-TRUE is itself reachable and keeps every EARLIER reachable branch
  /// (a row an earlier row-dependent guard matches takes that branch, never
  /// reaching this one), but makes every STRICTLY-LATER `WHEN` and the `ELSE`
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
    case let .case(whens, otherwise):
      try conditional(whens, otherwise, routines)
    case let .cast(operand, type):
      try validate(cast: operand, to: type, routines)
    case let .coalesce(arguments):
      try coalesce(arguments, routines)
    }
  }

  /// The result type of `COALESCE(v1, v2, …)`, validating each REACHABLE
  /// argument as a run would fault and unifying only the SELECTABLE ones'
  /// types (`merged`). A definitively-irreconcilable pair (a text argument
  /// beside an integer) faults `SQLError.operand`, as the column cannot be two
  /// kinds; a mixed integer/double pair widens to `double`.
  ///
  /// The executor returns the first NON-NULL argument and never evaluates a
  /// later one, so an argument that is the definite selection (`selects(_:)` —
  /// a constant NON-NULL value, or a `COUNT` aggregate that is always non-NULL)
  /// makes every LATER argument unreachable — those are NOT validated
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
  private func coalesce(_ arguments: Array<Expression>, _ routines: Routines)
      throws(SQLError) -> ValueType {
    var type: ValueType?
    for argument in arguments {
      let next = try validate(argument, routines)
      if case .some(.null) = constant(argument, routines) {
        // A constant NULL is validated (for its errors) but skipped: it can
        // never be returned, so its type must not shape the column.
        continue
      }
      guard !selects(argument, routines) else {
        // A definite selection: merge its type and stop, as every later
        // argument is unreachable and unvalidated.
        return try merged(type, next)
      }
      type = try merged(type, next)
    }
    return type ?? .integer
  }

  /// The target `type` of a `CAST`, VALIDATING `operand` for real errors
  /// (unknown column, bad call arity, …) as a run would fault, and REJECTING a
  /// cast the runtime could never perform before advertising the target type.
  ///
  /// A cast whose (operand type → target type) PAIR is structurally
  /// unsupported — a boolean to a number, a number to a blob — faults `42846`
  /// for EVERY value of the operand's kind, so `SELECT CAST(TRUE AS INTEGER)`
  /// would otherwise advertise an integer column though executing it
  /// unconditionally throws. `ValueType.castable(to:)` — the same structural
  /// truth the runtime cast consults — rejects that pair here, at validation.
  ///
  /// A castable-but-VALUE-dependent pair still passes: a `text` to a number, or
  /// a `blob` to `text`, is a supported pair whose fault (`22018`/`22003`)
  /// depends on the value, so a reachable good value runs — `CAST('1' AS
  /// INTEGER)` type-checks. The exception is a CONSTANT operand that folds and
  /// ALWAYS fails: `CAST('abc' AS INTEGER)` is unparseable for the one value it
  /// can have, so a trial cast of the folded constant rejects it too.
  ///
  /// The constant fold runs FIRST, before the structural pair rejection: a
  /// constant operand casts to ONE value, so its trial cast decides the cast
  /// outright — it ALLOWS a statically-NULL operand (`CAST(CASE WHEN 1 = 0
  /// THEN 1 END AS BLOB)` folds to `.null`, which casts to ANY target) even
  /// where the operand's DERIVED type would make the pair structurally
  /// unsupported, and it still REJECTS a constant that always fails. Only a
  /// NON-constant operand, whose value is unknown at validation, falls to the
  /// structural pair check.
  private func validate(cast operand: Expression, to type: ValueType,
                        _ routines: Routines) throws(SQLError) -> ValueType {
    let source = try validate(operand, routines)
    // A constant operand casts to one value only, so its trial cast is the
    // whole decision: it ALLOWS a folded NULL to any target and REJECTS a
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

  /// The result type of a `CASE`, validating each REACHABLE branch as a run
  /// would fault and honouring the executor's short-circuit: each evaluated
  /// `WHEN` guard is a boolean predicate whose operands are validated (`check`);
  /// only a REACHABLE result expression is validated; and the reachable result
  /// types must UNIFY to one type (`ValueType.unified`) — a
  /// definitively-irreconcilable pair (a text result beside an integer one)
  /// faults `SQLError.operand`, as a query cannot yield a column of two kinds. A
  /// mixed integer/double `CASE` widens to `double`.
  ///
  /// The executor takes the first TRUE guard's result and never evaluates a
  /// later branch, so a `WHEN` whose guard is statically constant-FALSE has an
  /// unreachable result — its operands are NOT validated (`CASE WHEN 1 = 0 THEN
  /// Name + 1 ELSE 0 END` type-checks). A constant-TRUE guard is itself
  /// reachable and KEEPS every earlier reachable branch — a row an earlier
  /// row-dependent guard matches takes that branch, never reaching the
  /// constant-TRUE one — so those earlier results are still validated (`CASE WHEN
  /// Id = 1 THEN Name + 1 WHEN 1 = 1 THEN 0 END` faults on the reachable `Id = 1`
  /// branch's `Name + 1`); it makes only every STRICTLY-LATER guard, result, and
  /// the `ELSE` unreachable. A REACHABLE bad operand (`WHEN Id = 1 THEN Name +
  /// 1`) still faults. When no branch is reachable the run yields NULL, typed
  /// `.integer` (the schema default), with no result to validate.
  private func conditional(_ whens: Array<When>, _ otherwise: Expression?,
                           _ routines: Routines)
      throws(SQLError) -> ValueType {
    var results = Array<Expression>()
    var decided = false
    for branch in whens {
      // The guard up to (and including) the decisive one is evaluated, so
      // validate its operands; a constant-FALSE guard's result is unreachable
      // (skip it), a constant-TRUE one is reachable but makes every LATER branch
      // unreachable — so keep the earlier results and this one, then stop.
      try check(branch.when, routines)
      switch constant(branch.when, routines) {
      case false: continue
      case true: results.append(branch.then); decided = true
      case nil: results.append(branch.then)
      }
      if decided { break }
    }
    if !decided, let otherwise { results.append(otherwise) }
    guard !results.isEmpty else { return .integer }
    var type = try validate(results[0], routines)
    for result in results.dropFirst() {
      let next = try validate(result, routines)
      guard let unified = type.unified(with: next) else {
        throw .operand("CASE results have irreconcilable types")
      }
      type = unified
    }
    return type
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
    case let .membership(operand, values, _):
      // `x IN (v, …)` lowers to `x = v OR …`, so type it as those comparisons:
      // validate the operand and each value for real errors (unknown column,
      // bad arity, …). A cross-kind element (text in an integer list) is NOT
      // rejected: the lowered `operand = element` comparison yields FALSE at
      // runtime via `Row.matches` without faulting, so a row still runs (and
      // may match a like-kind element), and the schema check must accept what
      // the run accepts — rejecting it here would diverge from the run.
      //
      // The OR-chain short-circuits: a DEFINITE constant match (`x = v` folds
      // TRUE, both row-independent constants) makes the whole `IN` TRUE and
      // leaves every later element unreachable, so validation stops there —
      // `1 IN (1 + 0, Name + 1)` type-checks, the run matching `1 = 1 + 0`
      // before ever reaching `Name + 1`, while `2 IN (1 + 0, Name + 1)` (no
      // definite match) still validates `Name + 1` and faults.
      // `matched(operand, value, routines)` is the fold's own primitive.
      //
      // An empty list has no OR-chain and cannot be lowered (`lower` would have
      // no seed), so reject it here too — the parser rejects `IN ()`, but a
      // caller can build `.membership(_, [], …)` directly, so this validation
      // faults on that shape rather than typing it as an always-false chain.
      guard !values.isEmpty else {
        throw .unsupported("IN requires a non-empty value list")
      }
      _ = try validate(operand, routines)
      _ = try membership(of: values, each: { value throws(SQLError) in
        _ = try validate(value, routines)
      }, equality: { value throws(SQLError) in
        matched(operand, value, routines)
      })
    case let .like(operand, pattern, escape, _):
      // Validate the operand, pattern, and optional escape for REAL errors
      // (unknown column, bad arity, …); a non-text operand or pattern is NOT
      // rejected — the run yields a definite FALSE via `Row.like` without
      // faulting (the cross-kind rule), and the schema check must accept what
      // the run accepts, as the `IN` cross-kind element does.
      _ = try validate(operand, routines)
      try validate(pattern, routines)
      if let escape {
        try validate(escape, routines)
        try reject(escape, routines)
      }
    case let .and(lhs, rhs):
      try check(lhs, routines)
      if constant(lhs, routines) != false { try check(rhs, routines) }
    case let .or(lhs, rhs):
      try check(lhs, routines)
      if constant(lhs, routines) != true { try check(rhs, routines) }
    case let .not(operand):
      try check(operand, routines)
    }
  }

  /// Type-checks a `LIKE` pattern or escape `operand` for the side effect of
  /// validation: an expression is validated (`validate`), a `:parameter` reads
  /// nothing at compile time (its value arrives from the bindings at run time),
  /// so it needs no check, as a `Predicate.bound` parameter needs none.
  private func validate(_ operand: Predicate.Operand, _ routines: Routines)
      throws(SQLError) {
    if case let .expression(expression) = operand {
      _ = try validate(expression, routines)
    }
  }

  /// Rejects a STATICALLY-invalid `LIKE` `escape` at validation, as `Row.like`
  /// would fault it on EVERY row: a ROW-INDEPENDENT escape expression that
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
  /// ROW-INDEPENDENT CONSTANTS (via `constant`) — the OR-chain equality an `IN`
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
    return matches(lhs, .equal, rhs)
  }

  /// The constant `Value` `expression` folds to when it is ROW-INDEPENDENT —
  /// else `nil` (an operand a row, group, or run context decides). A literal
  /// folds to its value; a binary folds its two operands and applies the SAME
  /// `Arithmetic.apply(Value, Value)` the run's binary evaluation uses, so the
  /// fold matches the run exactly (and a would-be fault — a divide, an overflow
  /// — collapses to `nil` rather than deciding a match). A ROW-INDEPENDENT call
  /// to a DETERMINISTIC routine (every argument folds constant) folds to its
  /// routine's value over those folded arguments — the SAME `Routine` the run
  /// invokes over the same constant arguments, so the fold matches the run; an
  /// unregistered name, a NOT DETERMINISTIC routine, a non-constant argument,
  /// or a throwing routine collapses to `nil`. Only a deterministic routine
  /// folds (ISO): executing a non-deterministic one here could return one value
  /// while this compile-time walk decides reachability and a DIFFERENT one when
  /// the run reaches the same call — pruning an element the run keeps. Every
  /// other expression is not statically foldable: a `column` reads a row and an
  /// `aggregate` folds a group, so each is `nil`. A ROW-INDEPENDENT `case`
  /// folds too — walking the `WHEN`s in order over `constant(_ predicate:)`:
  /// the first constant-TRUE guard yields its folded result, a constant-FALSE
  /// guard is skipped, and a guard the fold cannot decide (`nil`) means the
  /// taken branch is per row, so the whole `case` is `nil`; with no
  /// constant-TRUE guard it folds the `ELSE`, or `.null` when there is none (a
  /// no-match `CASE` yields NULL). This honours the SAME reachability
  /// `reachable(_:_:_:)` validates with. Returning `nil` is SOUND — a caller
  /// that cannot fold an element keeps considering it, never wrongly pruning a
  /// later one.
  private func constant(_ expression: Expression, _ routines: Routines)
      -> Value? {
    switch expression {
    case let .literal(literal):
      return try? SQL.value(of: literal)
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
      // A ROW-INDEPENDENT operand folds to its converted value — the SAME
      // `Value.cast(to:)` the run applies, so the fold matches. A would-be
      // fault (an unconvertible value) collapses to `nil`, so the cast stays
      // undecided rather than deciding a match, just as a would-be-faulting
      // binary fold does.
      guard let value = constant(operand, routines) else { return nil }
      return try? value.cast(to: type)
    case let .coalesce(arguments):
      // Fold as the run evaluates it — the first argument that folds to a
      // non-NULL value (COERCED to the unified type, as the executor's
      // `Term.coalesce` coerces the selected value), else NULL when every
      // argument folds NULL. An argument the fold cannot decide (`nil`) BEFORE
      // a decisive non-NULL one means the taken value is per row, so the whole
      // `COALESCE` is `nil`. Coercing an `.integer` selected from a COALESCE
      // that unifies to `.double` folds to `.double`, matching the advertised
      // column type — so a `.double`-typed routine over `COALESCE(1, 2.5)`
      // folds against the SAME value the run supplies. The unified type is the
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
    case .column, .aggregate:
      return nil
    }
  }

  /// Folds an `IN` value list as its OR-chain of `operand = element` equalities,
  /// honouring the executor's SHORT-CIRCUIT: the elements are visited in order,
  /// each mapped to its three-valued equality truth by `equality`, and the truths
  /// are OR-folded — but a definite `true` stops the walk, since the OR-chain
  /// matches there and every LATER element is unreachable (`Row.matches` returns
  /// on the first true arm). This is the ONE short-circuit the `IN`
  /// type-check (`check`), constant fold (`constant`), and empty-group evaluator
  /// (`empty`) all share: each supplies the per-element `equality` its surface
  /// computes with, and every surface stops at the same element the run does.
  ///
  /// `visit` runs on each element BEFORE its truth is taken, so a surface with a
  /// per-element side effect (validation) applies it to exactly the reachable
  /// prefix. The fold seeds FALSE (an empty match is FALSE), so the returned
  /// truth is the disjunction over the visited prefix.
  private func membership<E: Error>(
      of elements: Array<Expression>,
      each visit: (Expression) throws(E) -> Void = { (_: Expression) in },
      equality: (Expression) throws(E) -> Bool?)
      throws(E) -> Bool? {
    var truth: Bool? = false
    for element in elements {
      try visit(element)
      truth = or(truth, try equality(element))
      // A definite match makes every LATER element unreachable — the OR-chain
      // short-circuits here, exactly as the run does.
      if truth == true { break }
    }
    return truth
  }

  /// The definite constant truth value of `predicate` when it is statically
  /// decidable — a comparison or `IS [NOT] NULL` whose operands fold to
  /// ROW-INDEPENDENT `Value`s (via `constant(_ expression:)`: literals,
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
      return matches(lhs, op, rhs)
    case let .and(lhs, rhs):
      // `constant` is a pure fold with no side effect, so both arms evaluate.
      return and(constant(lhs, routines), constant(rhs, routines))
    case let .or(lhs, rhs):
      return or(constant(lhs, routines), constant(rhs, routines))
    case let .not(operand):
      guard let value = constant(operand, routines) else { return nil }
      return !value
    case let .null(operand, negated):
      // A ROW-INDEPENDENT operand that folds to a concrete value is not NULL;
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
      // ROW-INDEPENDENT element definitely equals the constant operand the fold
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
      // to ROW-INDEPENDENT constants — the same `constant(_ expression:)` the
      // run's terms evaluate through — running the SAME matcher `Row.like`
      // does; any row-dependent operand leaves it per row (`nil`). `NOT LIKE`
      // negates the folded truth (UNKNOWN maps to itself).
      guard let truth = matched(operand, pattern, escape, routines) else {
        return nil
      }
      return negated ? !truth : truth
    case .bound:
      return nil
    }
  }

  /// The definite truth of `operand LIKE pattern [ESCAPE escape]` when the
  /// operand, pattern, and optional escape all fold to ROW-INDEPENDENT
  /// constants (via `constant(_ expression:)`), else `nil`. It folds each side
  /// and runs the SAME `matches` the run's `Row.like` does — a NULL side is
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
  /// is ROW-INDEPENDENT (`constant(_ expression:)`), else `nil`. A `:parameter`
  /// is per run — its value arrives from the bindings — so it never folds
  /// constant, exactly as a column does.
  private func constant(_ operand: Predicate.Operand, _ routines: Routines)
      -> Value? {
    switch operand {
    case let .expression(expression): constant(expression, routines)
    case .parameter: nil
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
    case let .case(whens, otherwise):
      for branch in whens {
        try aggregates(in: branch.when, routines)
        try aggregates(in: branch.then, routines)
      }
      if let otherwise { try aggregates(in: otherwise, routines) }
    case let .cast(operand, _):
      try aggregates(in: operand, routines)
    case let .coalesce(arguments):
      for argument in arguments { try aggregates(in: argument, routines) }
    }
  }

  /// Validates the aggregate sub-expressions of a `LIKE` pattern or escape
  /// `operand` — an expression's own, none in a `:parameter`.
  func aggregates(in operand: Predicate.Operand, _ routines: Routines = [:])
      throws(SQLError) {
    if case let .expression(expression) = operand {
      try aggregates(in: expression, routines)
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
    case let .membership(operand, values, _):
      try aggregates(in: operand, routines)
      for value in values { try aggregates(in: value, routines) }
    case let .like(operand, pattern, escape, _):
      try aggregates(in: operand, routines)
      try aggregates(in: pattern, routines)
      if let escape { try aggregates(in: escape, routines) }
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
    case let .case(whens, otherwise):
      // Evaluate the `CASE` over the empty group exactly as a run does: the
      // first branch whose guard folds TRUE (`empty(predicate)`) yields its
      // result, else the `ELSE`, else `NULL`. A skipped branch's result never
      // folds, so it cannot fault. The selected value is COERCED to the CASE's
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
    case .column:
      return .null
    }
  }

  /// The value a `LIKE` pattern or escape `operand` folds to over the empty
  /// group: an expression folds through `empty(_ expression:)`; a `:parameter`
  /// is UNBOUND here — the empty-group fold carries no bindings — so it is
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
      return matches(try empty(left, routines), op, try empty(right, routines))
    case .bound:
      return nil
    case let .null(operand, negated):
      let value = try empty(operand, routines)
      let null = if case .null = value { true } else { false }
      return negated ? !null : null
    case let .membership(operand, values, negated):
      // Fold `x IN (…)` over the empty group as its OR-chain of equalities does
      // — the folded operand matched against each folded element under
      // three-valued `OR`, honouring the OR-chain's short-circuit (`membership`):
      // the run stops at the first TRUE comparison and never evaluates a later
      // element, so `1 IN (1, 1 / 0)` folds `true` here without folding `1 / 0`
      // to a `.divide` fault. Negated for `NOT IN`.
      //
      // Reject an empty list, as `check` and `lower` do — a whole-result
      // aggregate `HAVING` over the empty group reaches this fold WITHOUT a
      // prior `check` (`OutputColumn.typecheck`), so an empty list would
      // otherwise fold `false` (`true` under `NOT IN`) here while both compile
      // (`lower`) and schema (`check`) reject it. The parser rejects `IN ()`,
      // but a caller can build `.membership(_, [], …)` directly.
      guard !values.isEmpty else {
        throw .unsupported("IN requires a non-empty value list")
      }
      let lhs = try empty(operand, routines)
      let truth = try membership(of: values) { value throws(SQLError) in
        matches(lhs, .equal, try empty(value, routines))
      }
      return negated ? truth.map { !$0 } : truth
    case let .like(operand, pattern, escape, negated):
      // Fold `x LIKE p` over the empty group as `Row.like` evaluates it: the
      // operand, pattern, and optional escape are each folded ONCE, IN ORDER,
      // BEFORE the result is decided (so a faulting reached operand surfaces
      // its throw rather than being swallowed by a NULL escape). Then a NULL
      // operand, pattern, or escape is UNKNOWN, a non-text operand or pattern a
      // definite non-match, else the `%`/`_` matcher decides; a non-NULL escape
      // that is not a single character faults `SQLError.argument`, as the run
      // does. `NOT LIKE` negates.
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
      let truth: Bool? = switch (subject, template, separator) {
      case (.null, _, _), (_, .null, _), (_, _, .some(.null)):
        nil
      case let (.text(subject), .text(template), _):
        matches(subject, template, escape: character)
      default:
        false
      }
      return negated ? truth.map { !$0 } : truth
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
  internal func terms(_ projection: Projection,
                      _ routines: Routines = [:]) throws(SQLError)
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
        try terms.append(term(item.expression, routines))
      }
      return terms
    }
  }

  /// Lowers a scalar `expression` to a combined-ordinal `Term`.
  internal func term(_ expression: Expression,
                     _ routines: Routines = [:]) throws(SQLError) -> Term {
    switch expression {
    case let .column(column):
      return try .slot(ordinal(of: column))
    case let .literal(literal):
      return try .constant(value(of: literal))
    case let .call(name, arguments):
      var lowered = Array<Term>()
      lowered.reserveCapacity(arguments.count)
      for argument in arguments {
        try lowered.append(term(argument, routines))
      }
      return .apply(name: name, arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines), term(rhs, routines))
    case let .case(whens, otherwise):
      // Lower each branch's guard to a combined-ordinal `Filter` and its result
      // to a `Term`, and the `ELSE` to a `Term`, across the join chain.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        try branches.append((lower(branch.when, routines),
                             term(branch.then, routines)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, routines)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — so the executor COERCES the selected
      // branch's value to the type the schema advertises.
      let type = try derive(whens, otherwise, routines)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand across the join chain and attach the target type; the
      // executor converts the evaluated value to it (`Value.cast(to:)`).
      return try .cast(term(operand, routines), type)
    case let .coalesce(arguments):
      // Lower each argument to a combined-ordinal `Term` and hold them in a
      // first-class `Term.coalesce` so each is evaluated ONCE; `type` is the
      // unified argument type the selected value coerces to.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines))
      }
      let type = try derive(expression, routines)
      return .coalesce(elements, type: type)
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

  /// Lowers a join's `ON predicate` to the engine's `Filter` across the chain,
  /// emitting a `match` for each pure `column = column` equality — the
  /// hash-join key `nest` folds into a physical `Join` — ONLY WHEN the WHOLE
  /// `ON` is safe, and otherwise lowering the entire conjunction as one
  /// residual.
  ///
  /// A `column = column` conjunct is the hash-join key `nest` folds into a
  /// physical `Join`, so it lowers to a `match(left, right)` — the same node
  /// the equi-only `ON` produced — rather than a `compare(.slot, .equal,
  /// .slot)`, which `nest` would not recognise as a key. Every other leaf (an
  /// inequality, an expression equality such as `a.x = b.y + 1`, an `IS NULL`,
  /// a membership, an `OR`/`NOT`) lowers through `lower`, becoming a residual
  /// the join runs as a filter over the product — nested-loop semantics,
  /// correct if O(n·m).
  ///
  /// A `match` key is extracted ONLY WHEN EVERY lowered conjunct is `safe`; if
  /// ANY conjunct is unsafe, the whole `ON` lowers to a single residual and NO
  /// key is hoisted. The hash join evaluates its key equality BEFORE any
  /// residual conjunct AND skips a NULL key (an equi `match` drops a pair whose
  /// key cell is NULL), so an extracted key changes the `ON`'s left-to-right
  /// Kleene error behaviour on two hazards, both suppressing a throw the
  /// residual `select` over the product would raise (the order the WHERE
  /// pushdown barriers preserve):
  ///   - an UNSAFE conjunct BEFORE the key (`ON (1 / A.x) = 0 AND A.k = B.k`):
  ///     hoisting the key would let its non-match drop a pair before the
  ///     unsafe conjunct runs (`A.x = 0` ⇒ `SQLError.divide`);
  ///   - a NULLABLE key BEFORE an UNSAFE conjunct (`ON A.k = B.k AND (1 / A.x)
  ///     = 0`, `A.k` NULL, `A.x = 0`): the equality is UNKNOWN, so the Kleene
  ///     `AND` must still evaluate the unsafe RHS and raise — but the hash join
  ///     skips the NULL key and drops the pair before the RHS runs.
  /// The engine has no NOT NULL schema (a column surfaces as a `Value` that may
  /// be `.null`), so it cannot prove a key operand non-nullable; EVERY equi key
  /// is treated as nullable, collapsing both hazards to the single whole-`ON`
  /// rule. An equi `column = column` is always `safe` (comparing two cells
  /// never raises), so an all-equi or otherwise all-safe `ON` still hash-joins
  /// byte-for-byte.
  internal func on(_ predicate: Predicate,
                   _ routines: Routines = [:]) throws(SQLError) -> Filter {
    let conjuncts = predicate.conjuncts
    let lowered = try conjuncts.map { conjunct throws(SQLError) in
      try lower(conjunct, routines)
    }
    // An unsafe conjunct anywhere forbids extracting ANY key: a hoisted key
    // both skips a NULL pair before a LATER unsafe conjunct runs and drops a
    // non-match before an EARLIER one does — either suppressing the throw the
    // whole-ON residual owes. Lower the entire conjunction as one residual.
    guard lowered.allSatisfy(\.safe) else { return lowered.conjunction! }
    var filters = Array<Filter>()
    for (conjunct, residual) in zip(conjuncts, lowered) {
      if case let .comparison(.column(left),
                              .equal, .column(right)) = conjunct {
        try filters.append(match(left, right))
      } else {
        filters.append(residual)
      }
    }
    return filters.conjunction!
  }

  /// Lowers the name-addressed AST `predicate` to the engine's `Filter`, each
  /// column reference resolved to a combined ordinal across the chain.
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:]) throws(SQLError) -> Filter {
    try SQL.lower(predicate) { expression throws(SQLError) in
      try term(expression, routines)
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
  private func term(_ expression: Expression,
                    _ routines: Routines = [:]) throws(SQLError) -> Term {
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
        try lowered.append(term(argument, routines))
      }
      return .apply(name: name, arguments: lowered)
    case let .binary(op, lhs, rhs):
      return try .binary(op, term(lhs, routines), term(rhs, routines))
    case let .case(whens, otherwise):
      // Lower each branch's guard and result, and the `ELSE`, against the
      // grouped slot space — a bare column in any of them must be a `GROUP BY`
      // key, an aggregate its result slot, as elsewhere in a grouped expression.
      var branches = Array<(Filter, Term)>()
      branches.reserveCapacity(whens.count)
      for branch in whens {
        try branches.append((lower(branch.when, routines),
                             term(branch.then, routines)))
      }
      let fallback: Term? = if let otherwise {
        try term(otherwise, routines)
      } else {
        nil
      }
      // Attach the unified result type — the same `ValueType.unified` reduction
      // `derive`/`validate` compute — over the grouped scope, so the executor
      // COERCES the selected branch's value to the advertised column type.
      let type = try scope.derive(whens, otherwise, routines)
      return .case(branches, else: fallback, type: type)
    case let .cast(operand, type):
      // Lower the operand against the grouped slot space and attach the target
      // type; the executor converts the evaluated value to it.
      return try .cast(term(operand, routines), type)
    case let .coalesce(arguments):
      // Lower each argument to a grouped-space `Term` and hold them in a
      // first-class `Term.coalesce` so each is evaluated ONCE; `type` is the
      // unified argument type (over the grouped scope) the value coerces to.
      var elements = Array<Term>()
      elements.reserveCapacity(arguments.count)
      for argument in arguments {
        try elements.append(term(argument, routines))
      }
      let type = try scope.derive(expression, routines)
      return .coalesce(elements, type: type)
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
  internal mutating func terms(_ projection: Projection,
                               _ routines: Routines = [:])
      throws(SQLError) -> Array<Term> {
    switch projection {
    case .all:
      throw .unsupported("SELECT * is not allowed with GROUP BY or aggregates")
    case let .columns(columns):
      var terms = Array<Term>()
      terms.reserveCapacity(columns.count)
      for column in columns {
        let term = try term(.column(column), routines)
        terms.append(term)
        record(column.name, term)
      }
      return terms
    case let .expressions(items):
      var terms = Array<Term>()
      terms.reserveCapacity(items.count)
      for item in items {
        let term = try term(item.expression, routines)
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
  internal func lower(_ predicate: Predicate,
                      _ routines: Routines = [:]) throws(SQLError) -> Filter {
    try SQL.lower(predicate) { expression throws(SQLError) in
      try term(expression, routines)
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
    case let .membership(operand, elements, _):
      operand.references(into: &ordinals)
      for element in elements {
        element.references(into: &ordinals)
      }
    case let .like(operand, pattern, escape, _):
      operand.references(into: &ordinals)
      pattern.references(into: &ordinals)
      escape?.references(into: &ordinals)
    case let .and(lhs, rhs), let .or(lhs, rhs):
      lhs.references(into: &ordinals)
      rhs.references(into: &ordinals)
    case let .not(operand):
      operand.references(into: &ordinals)
    }
  }
}
