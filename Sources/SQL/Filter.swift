// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A query's parameter bindings: each `:name` parameter mapped to the value
/// bound for this run — the operand a `bound` filter resolves, and the key the
/// seek planner reads.
public typealias Bindings = Dictionary<String, Value>

/// The engine's ordinal-addressed row filter.
///
/// `Filter` is the lowered form of the AST's name-addressed `Predicate`: a tree
/// of comparisons composed with `AND`, `OR`, and `NOT`, with every column
/// resolved to a slot once. Each comparison operand is a `Term` — a slot, a
/// constant, or a scalar call — so the executor can still seek a sorted column
/// off a bare slot before running it. The filter is fully
/// escapable; the `~Escapable` row it reads materialises only transiently at
/// evaluation.
internal indirect enum Filter: Sendable {
  /// `left <op> right`, both operands lowered to ordinal-addressed terms (a
  /// slot, a constant, or a scalar-function call).
  case compare(Term, Comparison, Term)
  /// `left <op> :parameter`, the left a term and the operand resolved at run
  /// time from the engine's bindings — the lowered form of a correlated
  /// subquery's parent-keyed predicate.
  case bound(Term, Comparison, String)
  /// `left = right`, both columns addressed by ordinal — a join's `ON`
  /// equality, lowered as a conjunct of the product's `Select` predicate.
  case match(Int, Int)
  /// `term IS NULL`, or `IS NOT NULL` when `negated` — the lowered form of the
  /// AST's `null`, a definite two-valued test (never UNKNOWN).
  case null(Term, negated: Bool)
  /// `operand [NOT] IN (element, …)` — the lowered form of the AST's
  /// `membership`. The operand term is held ONCE, the value list lowered to
  /// element terms, and `negated` marks `NOT IN`. Evaluating it reads the
  /// operand exactly once per row (an OR-chain of `compare`s would re-evaluate
  /// a non-idempotent operand, once per element) and folds `operand = element`
  /// over the elements IN ORDER under Kleene `OR`, short-circuiting at the
  /// first TRUE; `NOT IN` negates that three-valued truth (UNKNOWN maps to
  /// itself).
  case membership(Term, Array<Term>, negated: Bool)
  /// `operand [NOT] LIKE pattern [ESCAPE escape]` — the lowered form of the
  /// AST's `like`. The operand is a `Term` evaluated per row; the pattern and
  /// optional one-character escape are each an `Operand` — a `Term` or a
  /// run-time `:parameter` resolved from the bindings; `negated` marks `NOT
  /// LIKE`. The runtime reads the operand and pattern text and runs the `%`/`_`
  /// matcher (a linear two-pointer match, `%` matching any run and `_` exactly
  /// one character, an escape character taking the next character literally); a
  /// NULL operand, pattern, or escape is UNKNOWN and a non-text operand or
  /// pattern is a definite non-match (the engine's cross-kind rule), with `NOT
  /// LIKE` negating the three-valued result (UNKNOWN maps to itself).
  case like(Term, pattern: Operand, escape: Operand?, negated: Bool)
  /// `lhs AND rhs`.
  case and(Filter, Filter)
  /// `lhs OR rhs`.
  case or(Filter, Filter)
  /// `NOT operand`.
  case not(Filter)

  /// The lowered pattern or escape operand of a `Filter.like`: a `Term`
  /// evaluated per row, or a run-time `:parameter` resolved from the engine's
  /// bindings — the lowered form of the AST's `Predicate.Operand`, as
  /// `Filter.bound` carries a comparison's parameter as a name resolved at run
  /// time.
  internal enum Operand: Sendable {
    /// A `Term` evaluated against the row per its usual lowering.
    case term(Term)
    /// A `:parameter` name, resolved from the bindings at eval — an unbound one
    /// (or one bound to `NULL`) makes the `LIKE` UNKNOWN.
    case parameter(String)
  }
}

// MARK: - Terms

/// The engine's ordinal-addressed scalar expression.
///
/// `Term` is the lowered form of the AST's name-addressed `Expression`: a slot
/// reference (a column resolved to its slot in a record), a constant, or a call
/// to a registered scalar function over argument terms. A projection lowers each
/// projected expression to a `Term` the executor evaluates per record against
/// the routines; a bare-column projection lowers to a `.slot`, so the simple
/// path stays a plain slot read.
internal indirect enum Term: Sendable {
  /// The cell at `slot` of the record.
  case slot(Int)
  /// A constant value.
  case constant(Value)
  /// A call to the named scalar function over its argument terms, in order.
  case apply(name: String, arguments: Array<Term>)
  /// `lhs <op> rhs` — a binary arithmetic over two operand terms, the lowered
  /// form of the AST's `Expression.binary`.
  case binary(Arithmetic, Term, Term)
  /// A `CASE` conditional — the lowered form of the AST's `Expression.case`. Each
  /// branch is a guard `Filter` and the result `Term` it yields; the executor
  /// evaluates the guards in order and takes the first whose three-valued value
  /// is TRUE (UNKNOWN and FALSE skip), else the `else` term, or `NULL` when there
  /// is none. `type` is the unification of the branch result types (the same
  /// `ValueType.unified` reduction `derive`/`validate` compute) — the type the
  /// schema advertises for the column — so the executor COERCES the selected
  /// value to it, widening an `.integer` arm of a `.double` CASE.
  case `case`(Array<(Filter, Term)>, else: Term?, type: ValueType)
  /// A `CAST(operand AS type)` — the lowered form of the AST's
  /// `Expression.cast`. The executor evaluates the operand `Term` and CONVERTS
  /// the value to `type` (`Value.cast(to:)`), so an unconvertible value faults
  /// rather than yielding a wrong one. `type` is also the term's static type —
  /// the type the schema advertises for the column.
  case cast(Term, ValueType)
  /// `COALESCE(v1, v2, …)` — the lowered form of the AST's
  /// `Expression.coalesce`. Each element term is evaluated IN ORDER exactly
  /// ONCE, and the first whose value is non-NULL is the result, else NULL. A
  /// desugar to a `CASE WHEN vi IS NOT NULL THEN vi …` re-evaluated each `vi`,
  /// so a stateful element yielded a different value to its guard and its
  /// result; holding the element ONCE (as `membership` holds its operand) fixes
  /// that. `type` is the unification of the element types, to which the
  /// selected value is COERCED — the type the schema advertises.
  case coalesce(Array<Term>, type: ValueType)
  /// `NULLIF(a, b)` — the lowered form of the AST's `Expression.nullif`. Both
  /// operand terms are evaluated exactly ONCE (`va`, `vb`); the result is NULL
  /// when `va = vb` is TRUE, else the SAME `va` that was compared. A desugar to
  /// `CASE WHEN a = b THEN NULL ELSE a END` evaluated `a` twice — comparing one
  /// value and returning another — which holding `a` ONCE fixes.
  case nullif(Term, Term)
}

extension Term {
  /// The slots this term reads, accumulated into `slots`.
  ///
  /// A `slot` reads itself; a `constant` reads none; an `apply` reads the union
  /// of its arguments. A projection unions these with the filter and order so a
  /// scan materialises exactly the cells the projection's functions consume.
  internal func references(into slots: inout Set<Int>) {
    switch self {
    case let .slot(slot):
      slots.insert(slot)
    case .constant:
      break
    case let .apply(_, arguments):
      for argument in arguments {
        argument.references(into: &slots)
      }
    case let .binary(_, lhs, rhs):
      lhs.references(into: &slots)
      rhs.references(into: &slots)
    case let .case(branches, otherwise, _):
      for (gate, result) in branches {
        gate.references(into: &slots)
        result.references(into: &slots)
      }
      otherwise?.references(into: &slots)
    case let .cast(operand, _):
      operand.references(into: &slots)
    case let .coalesce(elements, _):
      for element in elements {
        element.references(into: &slots)
      }
    case let .nullif(lhs, rhs):
      lhs.references(into: &slots)
      rhs.references(into: &slots)
    }
  }
}

extension Term {
  /// This term with every ordinal it reads remapped to a slot through `slot`: a
  /// `.slot` holding an ordinal becomes the same slot, a constant is unchanged,
  /// a call recurses into its arguments.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Term {
    switch self {
    case let .slot(ordinal):
      .slot(slot[ordinal]!)
    case .constant:
      self
    case let .apply(name, arguments):
      .apply(name: name,
             arguments: arguments.map { $0.remapped(through: slot) })
    case let .binary(op, lhs, rhs):
      .binary(op, lhs.remapped(through: slot), rhs.remapped(through: slot))
    case let .case(branches, otherwise, type):
      .case(branches.map {
              ($0.0.remapped(through: slot), $0.1.remapped(through: slot))
            }, else: otherwise?.remapped(through: slot), type: type)
    case let .cast(operand, type):
      .cast(operand.remapped(through: slot), type)
    case let .coalesce(elements, type):
      .coalesce(elements.map { $0.remapped(through: slot) }, type: type)
    case let .nullif(lhs, rhs):
      .nullif(lhs.remapped(through: slot), rhs.remapped(through: slot))
    }
  }

  /// Whether evaluating this term cannot throw — it is a bare slot read or a
  /// constant. A `binary` arithmetic (`/` raises on a zero divisor), an `apply`
  /// (a scalar function may raise), a `cast` (an unconvertible value raises),
  /// a `coalesce` (an element may raise), or a `nullif` (an operand may raise)
  /// is NOT known safe, whatever its operands.
  internal var safe: Bool {
    switch self {
    case .slot, .constant: true
    case .apply, .binary, .case, .cast, .coalesce, .nullif: false
    }
  }

  /// Whether this term is STATICALLY a valid single-character `LIKE` escape — a
  /// constant text value of exactly one character, the only form `Row.like`
  /// accepts without faulting. A slot, a call, or a constant that is NULL,
  /// non-text, or a text of any other length is not: its escape validity is not
  /// known until the row runs, so it CANNOT ride below a seek or join (see
  /// `Filter.safe`). Reused as the escape-safety gate; it does not decide the
  /// eval result, only the pushdown/seek classification.
  internal var escape: Bool {
    guard case let .constant(.text(text)) = self else { return false }
    return text.count == 1
  }
}

extension Filter.Operand {
  /// This operand with its term's ordinals remapped through `slot`; a
  /// `:parameter` reads no slot and passes unchanged.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Filter.Operand {
    switch self {
    case let .term(term): .term(term.remapped(through: slot))
    case .parameter: self
    }
  }

  /// The ordinals this operand reads, accumulated into `ordinals` — a term's
  /// own, none for a `:parameter`.
  internal func references(into ordinals: inout Set<Int>) {
    switch self {
    case let .term(term): term.references(into: &ordinals)
    case .parameter: break
    }
  }

  /// Whether evaluating this operand cannot throw — a safe term, or a
  /// `:parameter` (a bindings lookup, never a fault).
  internal var safe: Bool {
    switch self {
    case let .term(term): term.safe
    case .parameter: true
    }
  }

  /// Whether this operand is STATICALLY a valid single-character `LIKE`
  /// escape — only a constant single-character text term. A `:parameter` is
  /// per-run, not a static constant, so it is NOT statically valid (it may be
  /// unbound, NULL, or the wrong length at run time) and marks the `LIKE`
  /// unsafe, exactly as a non-constant escape term does (see `Filter.safe`).
  internal var escape: Bool {
    switch self {
    case let .term(term): term.escape
    case .parameter: false
    }
  }

  /// Whether this operand reads a run-time `:parameter` — a `.parameter` is
  /// one (it may be unbound or bound to NULL, so a `LIKE` over it is UNKNOWN);
  /// a `.term` is not, a `Term` carrying no parameter of its own. `Filter.like`
  /// folds this over its pattern and escape so a parameterised `LIKE` stays off
  /// a pushdown below a later unsafe conjunct (see `Filter.nullable`).
  internal var parameterised: Bool {
    switch self {
    case .term: false
    case .parameter: true
    }
  }
}

extension Filter {
  /// This filter with every ordinal it addresses remapped to a slot through
  /// `slot`.
  internal func remapped(through slot: Dictionary<Int, Int>) -> Filter {
    switch self {
    case let .compare(lhs, op, rhs):
      .compare(lhs.remapped(through: slot), op, rhs.remapped(through: slot))
    case let .bound(term, op, parameter):
      .bound(term.remapped(through: slot), op, parameter)
    case let .match(left, right):
      .match(slot[left]!, slot[right]!)
    case let .null(term, negated):
      .null(term.remapped(through: slot), negated: negated)
    case let .membership(operand, elements, negated):
      .membership(operand.remapped(through: slot),
                  elements.map { $0.remapped(through: slot) },
                  negated: negated)
    case let .like(operand, pattern, escape, negated):
      .like(operand.remapped(through: slot),
            pattern: pattern.remapped(through: slot),
            escape: escape?.remapped(through: slot), negated: negated)
    case let .and(lhs, rhs):
      .and(lhs.remapped(through: slot), rhs.remapped(through: slot))
    case let .or(lhs, rhs):
      .or(lhs.remapped(through: slot), rhs.remapped(through: slot))
    case let .not(operand):
      .not(operand.remapped(through: slot))
    }
  }

  /// The flat list of `AND`-conjuncts of this filter (a non-`and` is a
  /// singleton).
  internal var conjuncts: Array<Filter> {
    guard case let .and(lhs, rhs) = self else { return [self] }
    return lhs.conjuncts + rhs.conjuncts
  }

  /// The set of slots this filter addresses — the slot form of
  /// `references(into:)`, used by selection pushdown to decide which relation a
  /// conjunct belongs to.
  internal var slots: Set<Int> {
    var slots = Set<Int>()
    references(into: &slots)
    return slots
  }

  /// This filter with each slot `s` shifted to `s - offset` — the remap that
  /// rebases a conjunct from combined slot space into a right-hand child's own
  /// slot space (whose first slot is `offset`).
  internal func shifted(by offset: Int) -> Filter {
    var map = Dictionary<Int, Int>(minimumCapacity: slots.count)
    for slot in slots { map[slot] = slot - offset }
    return remapped(through: map)
  }

  /// `product` gated by this filter for a join `nest` that cannot fold into a
  /// `Join`, keeping the ON `match` conjuncts as a SEPARATE inner gate below
  /// the rest — `Select(rest, Select(match, product))`. Because evaluating
  /// `.and` does not short-circuit, folding the match into one `AND` with WHERE
  /// would, for a pair whose NULL join key makes the match UNKNOWN, still
  /// evaluate a throwing WHERE (`(1 / A.x) = 0`) — a pair the join forms no row
  /// for. Gating on the match first drops that pair before the WHERE runs, as
  /// the `Select(match, product)` did before `distribute` folded the match into
  /// the conjuncts for `nest` to find. When there is no match, `rest` is the
  /// whole filter and this is the plain `Select(self, product)`.
  internal func gated(over product: Plan) -> Plan {
    var matches = Array<Filter>()
    var rest = Array<Filter>()
    for conjunct in conjuncts {
      if case .match = conjunct {
        matches.append(conjunct)
      } else {
        rest.append(conjunct)
      }
    }
    var plan = product
    if let gate = matches.conjunction { plan = .select(gate, plan) }
    if let predicate = rest.conjunction { plan = .select(predicate, plan) }
    return plan
  }

  /// Whether evaluating this filter cannot throw — every term it reads is a bare
  /// slot or a constant. Selection pushdown keeps a filter that is NOT safe at
  /// the product level (evaluated per pair), so a division or scalar-call
  /// predicate raises only when a pair exists — never on an empty product it
  /// would have skipped had it stayed above the join.
  internal var safe: Bool {
    switch self {
    case let .compare(lhs, _, rhs): lhs.safe && rhs.safe
    case let .bound(term, _, _): term.safe
    case .match: true
    case let .null(term, _): term.safe
    case let .membership(operand, elements, _):
      operand.safe && elements.allSatisfy(\.safe)
    case let .like(operand, pattern, escape, _):
      // An escape makes the predicate UNSAFE unless it is STATICALLY a valid
      // single-character escape: `Row.like` faults (`SQLError.argument`) on any
      // escape that does not evaluate to a one-character text — a throw
      // INDEPENDENT of whether a pair matches, so it must not ride below a seek
      // or join and fire on an empty product (or be dropped by a hash key). A
      // non-constant escape (a slot or call) or a constant that is NULL,
      // non-text, or the wrong length is unsafe; only a `.constant` text of
      // exactly one character (`escape.escape`) is safe. Plain LIKE (no escape)
      // stays safe — the matcher itself never throws, a non-text operand or
      // pattern being a definite non-match and a NULL UNKNOWN.
      operand.safe && pattern.safe
          && (escape.map(\.escape) ?? true)
    case let .and(lhs, rhs): lhs.safe && rhs.safe
    case let .or(lhs, rhs): lhs.safe && rhs.safe
    case let .not(operand): operand.safe
    }
  }

  /// Whether evaluating this filter can be UNKNOWN — it reads at least one slot
  /// (a NULL cell there makes a comparison against it UNKNOWN) or compares against
  /// a run-time `:parameter` (which may be unbound or bound to NULL, likewise
  /// UNKNOWN). Only a filter over constants alone is definite. Selection pushdown
  /// must not ride a nullable conjunct below a join or into a view when a LATER
  /// conjunct is unsafe: the evaluator's `AND` does not short-circuit, so the
  /// un-pushed query evaluates the later conjunct even when this one is UNKNOWN —
  /// pushing this one down would drop the UNKNOWN row before the later conjunct
  /// runs, suppressing a throw the left-to-right `AND` owes (`A.x = 1 AND (1 /
  /// B.y) = 0`, `A.x` NULL and `B.y = 0` on a matching pair; or `1 = :missing AND
  /// (1 / y) = 0` over a view, `:missing` unbound — slotless yet UNKNOWN).
  internal var nullable: Bool {
    !slots.isEmpty || parameterised
  }

  /// Whether this filter compares against a run-time `:parameter` — a `.bound`
  /// anywhere in it, or a `.like` whose pattern or escape operand is a
  /// `:parameter`. Such a predicate reads no slot yet can be UNKNOWN, because
  /// the parameter may be unbound (or bound to NULL), so `nullable` counts it
  /// even when `slots` is empty — keeping `'x' LIKE :p` off a pushdown below
  /// a later unsafe conjunct the non-short-circuiting `AND` still owes.
  private var parameterised: Bool {
    switch self {
    case .bound: true
    case .compare, .match, .null, .membership: false
    case let .like(_, pattern, escape, _):
      pattern.parameterised || (escape?.parameterised ?? false)
    case let .and(lhs, rhs): lhs.parameterised || rhs.parameterised
    case let .or(lhs, rhs): lhs.parameterised || rhs.parameterised
    case let .not(operand): operand.parameterised
    }
  }
}

extension Array where Element == Filter {
  /// The left-leaning `AND` of these conjuncts, or `nil` for an empty list —
  /// `[a, b, c]` folds to `(a AND b) AND c`, matching the parser's own
  /// association.
  ///
  /// The left fold is deliberate: `seek` only inspects a top-level `AND`'s two
  /// immediate children, so a trailing sort-key comparison must remain the
  /// immediate right operand to be seekable. A right-leaning rebuild (`a AND (b
  /// AND c)`) would bury it under a nested `AND` and defeat the seek — so when
  /// pushdown flattens a filter through `conjuncts` and rebuilds it here, the
  /// association it restores is the parser's, keeping a seekable conjunct
  /// visible.
  internal var conjunction: Filter? {
    guard let first else { return nil }
    return dropFirst().reduce(first) { .and($0, $1) }
  }
}

/// The literal `literal` as a typed `Value`.
internal func value(of literal: Literal) throws(SQLError) -> Value {
  return switch literal {
  case let .integer(integer): .integer(integer)
  case let .string(string): .text(string)
  case let .boolean(boolean): .boolean(boolean)
  case let .blob(bytes): .blob(bytes)
  case let .double(double) where double.isFinite: .double(double)
  // A directly-built `Literal.double` bypasses the lexer's finite check; reject
  // NaN/inf at lowering so no non-finite double reaches a plan (it would break
  // dedup and ordering — see the `Value.double` invariant).
  case .double: throw .magnitude("double literal is not finite")
  }
}

extension Row where Self: ~Escapable {
  /// Evaluates `term` against this row through `routines`, yielding a typed
  /// value.
  ///
  /// A `slot` reads the row's cell; a `constant` is itself; an `apply` looks
  /// the function up in the routines (`SQLError.function` on a miss), evaluates
  /// its arguments, and applies it. The `borrowing` row is non-escaping — a
  /// term runs over a materialised projection record or a predicate's borrowed
  /// cursor row.
  internal borrowing func evaluate(_ term: Term, _ routines: Routines,
                                   _ bindings: Bindings = [:])
      throws(SQLError) -> Value {
    switch term {
    case let .slot(slot):
      self[slot]
    case let .constant(value):
      value
    case let .apply(name, arguments):
      try apply(name, arguments, routines, bindings)
    case let .binary(op, lhs, rhs):
      try op.apply(evaluate(lhs, routines, bindings),
                   evaluate(rhs, routines, bindings))
    case let .case(branches, otherwise, type):
      // Take the FIRST branch whose guard is three-valued TRUE (UNKNOWN and
      // FALSE skip); with none matching, the `else` term, or `NULL` when there
      // is none. The guard is a `Filter`, so it evaluates over the same row,
      // routines, and bindings a `WHERE` filter does — a `:parameter` guard
      // resolves against the bindings, an UNKNOWN one does not select its
      // branch. The selected value is COERCED to the CASE's unified result
      // `type` so it matches the column type the schema advertised.
      try conditional(branches, otherwise, type, routines, bindings)
    case let .cast(operand, type):
      // Evaluate the operand and CONVERT it to the target type: NULL casts to
      // NULL, an unconvertible value faults (`Value.cast(to:)`), never yielding
      // a wrong value.
      try evaluate(operand, routines, bindings).cast(to: type)
    case let .coalesce(elements, type):
      try coalesce(elements, type, routines, bindings)
    case let .nullif(lhs, rhs):
      try nullif(lhs, rhs, routines, bindings)
    }
  }

  /// Evaluates a lowered `COALESCE(v1, v2, …)` against this row — the
  /// `elements` visited IN ORDER exactly ONCE, returning the first whose value
  /// is non-NULL (coerced to the unified `type` the schema advertises), else
  /// NULL.
  ///
  /// Each element is evaluated ONCE: a desugar to `CASE WHEN vi IS NOT NULL
  /// THEN vi …` evaluated each `vi` twice — its guard and its result — so a
  /// stateful element tested one value for NULL and returned another.
  /// `Value.coerced` widens the selected value to `type` (a `.integer` element
  /// of a `.double` COALESCE), exactly as a `CASE` coerces its taken branch;
  /// NULL passes unchanged.
  private borrowing func coalesce(_ elements: Array<Term>, _ type: ValueType,
                                  _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Value {
    for element in elements {
      let value = try evaluate(element, routines, bindings)
      if case .null = value { continue }
      return value.coerced(to: type)
    }
    return .null
  }

  /// Evaluates a lowered `NULLIF(a, b)` against this row — `a` and `b` each
  /// evaluated ONCE — returning NULL when `a = b` is TRUE, else the SAME `va`
  /// that was compared.
  ///
  /// A desugar to `CASE WHEN a = b THEN NULL ELSE a END` evaluated `a` twice —
  /// once in the equality and once as the `ELSE` — so a stateful `a` compared
  /// one value and returned another; holding `va` fixes that. `matches` is
  /// three-valued: only a definite TRUE equality nulls out, so an UNKNOWN (a
  /// NULL operand) yields `va`.
  private borrowing func nullif(_ lhs: Term, _ rhs: Term,
                                _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Value {
    let va = try evaluate(lhs, routines, bindings)
    let vb = try evaluate(rhs, routines, bindings)
    return matches(va, .equal, vb) == true ? .null : va
  }

  /// Evaluates a lowered `CASE` — its `branches` and optional `otherwise`
  /// term — against this row, taking the first guard that is TRUE and coercing
  /// the selected value to the CASE's unified result `type`.
  ///
  /// The schema advertises the column as `type` — the unification of the branch
  /// result types — yet a branch yields its own raw `Value`, so a `.integer`
  /// arm of a CASE that unifies to `.double` must widen to match.
  /// `Value.coerced` performs that one widening; NULL and an already-matching
  /// value pass unchanged, so an all-same CASE (no widening) is untouched.
  private borrowing func conditional(_ branches: Array<(Filter, Term)>,
                                     _ otherwise: Term?, _ type: ValueType,
                                     _ routines: Routines,
                                     _ bindings: Bindings)
      throws(SQLError) -> Value {
    for (gate, result) in branches {
      if try evaluate(gate, routines, bindings) == true {
        return try evaluate(result, routines, bindings).coerced(to: type)
      }
    }
    guard let otherwise else { return .null }
    return try evaluate(otherwise, routines, bindings).coerced(to: type)
  }

  /// Resolves `name` in `routines` and applies it to its evaluated `arguments`.
  private borrowing func apply(_ name: String, _ arguments: Array<Term>,
                               _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Value {
    guard let routine = routines[name] else {
      throw .function(name)
    }
    var values = Array<Value>()
    values.reserveCapacity(arguments.count)
    for argument in arguments {
      try values.append(evaluate(argument, routines, bindings))
    }
    let result = try routine(values)
    // A registered routine is a public producer of `Value`s that bypasses the
    // literal/arithmetic finite checks; enforce the invariant here so a routine
    // cannot return `inf`/NaN. NaN in particular is unequal to itself and would
    // break UNION/CTE dedup and ORDER BY (and stall a recursive UNION at the
    // cap).
    if case let .double(number) = result, !number.isFinite {
      throw .magnitude("function '\(name)' produced a non-finite double")
    }
    return result
  }
}

// MARK: - Evaluation

extension Arithmetic {
  /// Applies the operator to two typed operands, yielding a typed `Value`.
  ///
  /// The operands must be numeric — integer or double. An `integer ∘ integer`
  /// stays an integer, with `/` integer division; any double operand makes the
  /// result a double (a lone integer promoted to `Double`), with `/` real
  /// division. A NULL on either side propagates — the result is NULL, not a
  /// fault. A division by zero is `SQLError.divide`, as standard SQL raises
  /// rather than yielding a value (`inf`/`NaN`), on either an integer or a
  /// double divisor; a non-numeric (text/boolean/blob) operand is a
  /// `SQLError.operand` type error rather than a silent coercion; an integer
  /// result past the `Int` boundary is `SQLError.magnitude`.
  internal func apply(_ lhs: Value, _ rhs: Value) throws(SQLError) -> Value {
    if case .null = lhs { return .null }
    if case .null = rhs { return .null }
    return switch (lhs, rhs) {
    case let (.integer(lhs), .integer(rhs)):
      try apply(lhs, rhs)
    // Any double operand widens the pair to double arithmetic — both operands
    // being numeric — with a lone integer promoted to `Double`.
    case let (.double(lhs), .double(rhs)):
      try apply(lhs, rhs)
    case let (.integer(lhs), .double(rhs)):
      try apply(Double(lhs), rhs)
    case let (.double(lhs), .integer(rhs)):
      try apply(lhs, Double(rhs))
    default:
      throw .operand("operands must be numeric")
    }
  }

  /// Applies the operator to two integers: `integer ∘ integer` is an integer,
  /// with `/` integer division.
  private func apply(_ lhs: Int, _ rhs: Int) throws(SQLError) -> Value {
    // Report overflow rather than trap: operands are parsed literals or column
    // values that can reach the `Int` boundary (`Int.max + 1`, `Int.min / -1`),
    // and Swift's `+`/`-`/`*`/`/` would trap — aborting the process — instead of
    // surfacing a `SQLError`.
    let outcome: (partialValue: Int, overflow: Bool) = switch self {
    case .add: lhs.addingReportingOverflow(rhs)
    case .subtract: lhs.subtractingReportingOverflow(rhs)
    case .multiply: lhs.multipliedReportingOverflow(by: rhs)
    case .divide where rhs == 0: throw .divide
    case .divide: lhs.dividedReportingOverflow(by: rhs)
    }
    guard !outcome.overflow else { throw .magnitude("integer overflow") }
    return .integer(outcome.partialValue)
  }

  /// Applies the operator to two doubles: `double ∘ double` is a double, with
  /// `/` real division (no truncation).
  ///
  /// A non-finite result is rejected rather than returned: division by zero is
  /// `SQLError.divide` (matching the integer policy), and an overflow to `inf`
  /// or a NaN from an indeterminate form (`inf - inf`) is `SQLError.magnitude`.
  /// A NaN must never reach a result — it is unequal to itself, so it would
  /// break duplicate elimination (a UNION would keep both copies) and ordering
  /// (a non-transitive sort key), and a recursive UNION echoing it would
  /// iterate to the recursion cap.
  private func apply(_ lhs: Double, _ rhs: Double) throws(SQLError) -> Value {
    let result: Double = switch self {
    case .add: lhs + rhs
    case .subtract: lhs - rhs
    case .multiply: lhs * rhs
    case .divide where rhs == 0: throw .divide
    case .divide: lhs / rhs
    }
    guard result.isFinite else {
      throw .magnitude("double result is not finite")
    }
    return .double(result)
  }
}

extension Comparison {
  /// Applies the operator to two comparable operands.
  internal func apply<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool {
    switch self {
    case .equal: lhs == rhs
    case .unequal: lhs != rhs
    case .lt: lhs < rhs
    case .gt: lhs > rhs
    case .leq: lhs <= rhs
    case .geq: lhs >= rhs
    }
  }

  /// Applies the operator to two byte strings: `=`/`<>` is byte equality and
  /// the ordering relations are lexicographic (memcmp) order over the bytes.
  ///
  /// `Array` is not `Comparable` — only `Equatable` when its element is — so a
  /// blob cannot ride the generic `apply`. Equality is `==`; order derives from
  /// `lexicographicallyPrecedes` (strict `<`): `>` reverses the operands, and
  /// `<=`/`>=` are the strict order OR equality.
  internal func apply(_ lhs: Array<UInt8>, _ rhs: Array<UInt8>) -> Bool {
    switch self {
    case .equal: lhs == rhs
    case .unequal: lhs != rhs
    case .lt: lhs.lexicographicallyPrecedes(rhs)
    case .gt: rhs.lexicographicallyPrecedes(lhs)
    case .leq: !rhs.lexicographicallyPrecedes(lhs)
    case .geq: !lhs.lexicographicallyPrecedes(rhs)
    }
  }
}

/// Matches two typed values under operator `op`, under three-valued logic.
///
/// A `NULL` on either side is UNKNOWN (`nil`): `NULL` is unordered and unequal
/// to everything, itself included, so no comparison against it is ever true or
/// false. A like-typed non-null pair compares — two integers, two doubles, two
/// strings, two booleans (`false < true`), or two blobs (byte equality,
/// lexicographic order). An integer against a double is numeric too — both
/// sides are numbers — so the integer promotes to `Double` and they compare by
/// magnitude (`1 = 1.0` is true); only a cross-*kind* pair (a number against a
/// string) never matches.
internal func matches(_ lhs: Value, _ op: Comparison, _ rhs: Value) -> Bool? {
  switch (lhs, rhs) {
  case (.null, _), (_, .null): nil
  case let (.integer(lhs), .integer(rhs)): op.apply(lhs, rhs)
  case let (.double(lhs), .double(rhs)): op.apply(lhs, rhs)
  // A mixed integer/double pair is numeric, not cross-type: promote the integer
  // to `Double` and compare by magnitude, so `1 = 1.0` and `1 < 1.5`.
  case let (.integer(lhs), .double(rhs)): op.apply(Double(lhs), rhs)
  case let (.double(lhs), .integer(rhs)): op.apply(lhs, Double(rhs))
  case let (.text(lhs), .text(rhs)): op.apply(lhs, rhs)
  // `Bool` is not `Comparable`, so compare on its truth ordinal — `false` is
  // `0`, `true` is `1` — which orders `false < true` and equates like values.
  case let (.boolean(lhs), .boolean(rhs)):
    op.apply(lhs ? 1 : 0, rhs ? 1 : 0)
  // `Array` is not `Comparable`, so `=`/`<>` is byte equality and the ordering
  // relations are lexicographic (memcmp) order over the bytes.
  case let (.blob(lhs), .blob(rhs)): op.apply(lhs, rhs)
  default: false
  }
}

/// Kleene `AND` over two three-valued operands: `false` dominates (a `false`
/// side makes the whole `false` even against UNKNOWN), both `true` is `true`,
/// and any other pair is UNKNOWN (`nil`).
internal func and(_ lhs: Bool?, _ rhs: Bool?) -> Bool? {
  if lhs == false || rhs == false { return false }
  return lhs == true && rhs == true ? true : nil
}

/// Kleene `OR` over two three-valued operands: `true` dominates (a `true` side
/// makes the whole `true` even against UNKNOWN), both `false` is `false`, and
/// any other pair is UNKNOWN (`nil`).
internal func or(_ lhs: Bool?, _ rhs: Bool?) -> Bool? {
  if lhs == true || rhs == true { return true }
  return lhs == false && rhs == false ? false : nil
}

extension Row where Self: ~Escapable {
  /// Evaluates `filter` against this row under three-valued logic, resolving
  /// scalar calls through `routines` and any bound parameter from `bindings`.
  ///
  /// The result is `true`, `false`, or `nil` — SQL's UNKNOWN. A `compare`
  /// evaluates both operand terms and matches them — a `NULL` operand making
  /// the comparison UNKNOWN; a `bound` matches the left term against the
  /// parameter's bound value, but an unbound or absent parameter is UNKNOWN
  /// (`nil`), not `false` — a missing binding cannot be inverted into a match
  /// by `NOT`. A `match` tests both cells equal under the same three-valued
  /// rule, so a `NULL` join key matches nothing; a `null` is a definite test of
  /// whether its term is `NULL` (`true`/`false`, never UNKNOWN), negated for
  /// `IS NOT NULL`. `AND` and `OR` follow Kleene logic (`false` dominates
  /// `AND`, `true` dominates `OR`, UNKNOWN otherwise) and `NOT` maps UNKNOWN to
  /// itself. The executor admits a row only when the whole predicate is `true`
  /// (its `== true` gate), so UNKNOWN and `false` both reject. The `borrowing`
  /// row is non-escaping; it threads into the recursion freely and is never
  /// stored.
  internal borrowing func evaluate(_ filter: Filter, _ routines: Routines,
                                   _ bindings: Bindings)
      throws(SQLError) -> Bool? {
    switch filter {
    case let .compare(lhs, op, rhs):
      try matches(evaluate(lhs, routines, bindings), op,
                  evaluate(rhs, routines, bindings))
    case let .bound(term, op, parameter):
      if let operand = bindings[parameter] {
        try matches(evaluate(term, routines, bindings), op, operand)
      } else {
        nil
      }
    case let .match(left, right):
      matches(self[left], .equal, self[right])
    case let .null(term, negated):
      try (evaluate(term, routines, bindings) == .null) != negated
    case let .membership(operand, elements, negated):
      try member(operand, elements, negated, routines, bindings)
    case let .like(operand, pattern, escape, negated):
      try like(operand, pattern, escape, negated, routines, bindings)
    case let .and(lhs, rhs):
      // `&&`/`||` take an `@autoclosure` right operand, which would capture the
      // borrowed `~Escapable` row; spell each connective explicitly so a branch
      // re-borrows the row rather than capturing it. Kleene `AND`: `false`
      // dominates, an UNKNOWN left yields `false` only against a `false` right.
      switch try evaluate(lhs, routines, bindings) {
      case false?: false
      case true?: try evaluate(rhs, routines, bindings)
      case nil: try evaluate(rhs, routines, bindings) == false ? false : nil
      }
    case let .or(lhs, rhs):
      // Kleene `OR`: `true` dominates, an UNKNOWN left yields `true` only
      // against a `true` right.
      switch try evaluate(lhs, routines, bindings) {
      case true?: true
      case false?: try evaluate(rhs, routines, bindings)
      case nil: try evaluate(rhs, routines, bindings) == true ? true : nil
      }
    case let .not(operand):
      try evaluate(operand, routines, bindings).map { !$0 }
    }
  }

  /// Evaluates a lowered `operand [NOT] IN (element, …)` against this row.
  ///
  /// The `operand` is evaluated ONCE per row — an OR-chain of `compare`s would
  /// re-evaluate a non-idempotent operand once per element — then `operand =
  /// element` folds over the elements IN ORDER under Kleene `OR`, seeded FALSE
  /// and short-circuiting at the first TRUE (the same left-to-right visit the
  /// OR-chain made, so a NULL operand or a NULL element keeps the ISO
  /// three-valued result: an unmatched test yields UNKNOWN, not FALSE). `NOT
  /// IN` negates that three-valued truth, mapping UNKNOWN to itself via
  /// `map(!)`.
  private borrowing func member(_ operand: Term, _ elements: Array<Term>,
                                _ negated: Bool, _ routines: Routines,
                                _ bindings: Bindings)
      throws(SQLError) -> Bool? {
    let value = try evaluate(operand, routines, bindings)
    var truth: Bool? = false
    for element in elements {
      let element = try evaluate(element, routines, bindings)
      truth = or(truth, matches(value, .equal, element))
      if truth == true { break }
    }
    return negated ? truth.map { !$0 } : truth
  }

  /// Resolves a `LIKE` pattern or escape operand to a value: a term evaluates
  /// against this row, a `:parameter` resolves from the bindings — an unbound
  /// name yields `.null`, so it reads UNKNOWN exactly as a bound `NULL` does.
  private borrowing func evaluate(_ operand: Filter.Operand,
                                  _ routines: Routines,
                                  _ bindings: Bindings)
      throws(SQLError) -> Value {
    switch operand {
    case let .term(term):
      try evaluate(term, routines, bindings)
    case let .parameter(name):
      bindings[name] ?? .null
    }
  }

  /// Evaluates a lowered `operand [NOT] LIKE pattern [ESCAPE escape]` against
  /// this row under three-valued logic.
  ///
  /// The operand, pattern, and optional escape are each evaluated ONCE, IN
  /// ORDER, BEFORE the three-valued result is decided — so a faulting reached
  /// operand (`(1 / K)` with `K = 0`) surfaces its throw rather than being
  /// silently swallowed by a NULL escape. Only once all three have evaluated is
  /// the result decided: a non-NULL escape that is not a single character is
  /// `SQLError.argument` (the ISO rule); a NULL operand, pattern, or escape is
  /// UNKNOWN (`nil`), the row excluded; a non-text operand or pattern is a
  /// definite non-match (FALSE), mirroring the engine's cross-kind comparison
  /// rule (`Row.matches`) rather than faulting. Otherwise the pattern runs
  /// against the operand through the `%`/`_` matcher. The pattern and escape
  /// may be a `:parameter` resolved from the bindings. `NOT LIKE` negates the
  /// result (UNKNOWN maps to itself).
  private borrowing func like(_ operand: Term, _ pattern: Filter.Operand,
                              _ escape: Filter.Operand?, _ negated: Bool,
                              _ routines: Routines, _ bindings: Bindings)
      throws(SQLError) -> Bool? {
    // Evaluate all three reached operands once, in order — a fault in any of
    // them (a divide, an overflow) propagates HERE, before the NULL/escape
    // result below can turn it into a silent UNKNOWN.
    let subject = try evaluate(operand, routines, bindings)
    let template = try evaluate(pattern, routines, bindings)
    let separator: Value? =
        if let escape { try evaluate(escape, routines, bindings) } else { nil }

    // Decide the escape character. A NULL escape is UNKNOWN like a NULL
    // operand; anything but a one-character text is `SQLError.argument`.
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
    // A NULL operand, pattern, or escape is UNKNOWN.
    case (.null, _, _), (_, .null, _), (_, _, .some(.null)):
      nil
    case let (.text(subject), .text(template), _):
      matches(subject, template, escape: character)
    // A non-text operand or pattern never matches — the engine's cross-kind
    // comparison rule — so the run is a definite non-match, not a fault.
    default:
      false
    }
    return negated ? truth.map { !$0 } : truth
  }
}

/// One decoded `LIKE` pattern atom, escape already resolved: `%` matches any
/// run, `_` exactly one character, and a literal matches itself.
private enum Atom: Equatable {
  /// `%` — any run of characters (including the empty run).
  case any
  /// `_` — exactly one character.
  case single
  /// A literal character, matching itself (an escaped `%`, `_`, or escape
  /// character among them).
  case literal(Character)
}

/// The `pattern` decoded into atoms, its escape resolved, or `nil` when the
/// pattern is ILL-FORMED — a trailing escape with no character to escape, which
/// matches nothing. An escape character makes the next character a `.literal`
/// (so escaped `%`, `_`, or the escape character are literals); every other
/// character is `%` → `.any`, `_` → `.single`, else `.literal`.
private func atoms(of pattern: Array<Character>,
                   escape: Character?) -> Array<Atom>? {
  var atoms = Array<Atom>()
  atoms.reserveCapacity(pattern.count)
  var index = 0
  while index < pattern.count {
    let symbol = pattern[index]
    if symbol == escape {
      // The next character is taken literally; a trailing escape (no character
      // follows) makes the whole pattern match nothing.
      guard index + 1 < pattern.count else { return nil }
      atoms.append(.literal(pattern[index + 1]))
      index += 2
    } else {
      switch symbol {
      case "%": atoms.append(.any)
      case "_": atoms.append(.single)
      default: atoms.append(.literal(symbol))
      }
      index += 1
    }
  }
  return atoms
}

/// Whether `text` matches the SQL `LIKE` `pattern`, in which `%` matches any
/// run of characters (including the empty run) and `_` matches exactly one
/// character; every other character matches itself. When `escape` is given, the
/// character following it in the pattern matches that literal character (so
/// `escape` followed by `%`, `_`, or `escape` matches a literal `%`, `_`, or
/// the escape character).
///
/// The match is ANCHORED — the whole `text` must be consumed. It is the classic
/// LINEAR two-pointer `LIKE` scan: a `%` is remembered (the pattern position
/// after it, and the text mark it may extend to) and matching proceeds
/// greedily; on a later mismatch the TEXT pointer is advanced past the mark and
/// the scan resumes after the remembered `%`, rather than re-recursing. This is
/// O(text · pattern) worst case — a pattern like `%a%a%a%b` against a long run
/// of `a`s cannot blow up combinatorially, as a per-split recursion would. A
/// trailing escape with no character to escape matches nothing, as no literal
/// follows it. The comparison is over `Character`s (grapheme clusters), so it
/// is Unicode-correct for the ASCII metadata names the engine filters and any
/// wider text.
internal func matches(_ text: String, _ pattern: String,
                      escape: Character?) -> Bool {
  let text = Array(text)
  // A trailing escape makes the pattern match nothing.
  guard let pattern = atoms(of: Array(pattern), escape: escape) else {
    return false
  }

  var t = 0           // the text cursor.
  var p = 0           // the pattern cursor.
  var star = -1       // pattern position after the last `%`, or -1 for none.
  var mark = 0        // the text position the last `%` may extend to consume.
  while t < text.count {
    if p < pattern.count, pattern[p] == .single
        || pattern[p] == .literal(text[t]) {
      // `_` or a matching literal consumes one character of each.
      t += 1
      p += 1
    } else if p < pattern.count, pattern[p] == .any {
      // Remember this `%` — its tail starts at `p + 1` and may extend the text
      // from `t` — and first try to match it against the empty run.
      star = p + 1
      mark = t
      p += 1
    } else if star != -1 {
      // A mismatch under a remembered `%`: let it consume one more character
      // (advance the mark) and resume the pattern just after it. Backtracking
      // the TEXT pointer, not re-recursing, keeps the scan linear.
      p = star
      mark += 1
      t = mark
    } else {
      // A mismatch with no `%` to extend: no match.
      return false
    }
  }
  // The text is exhausted; consume any trailing `%` atoms (each matches the
  // empty run). The match holds only if the whole pattern is then consumed.
  while p < pattern.count, pattern[p] == .any {
    p += 1
  }
  return p == pattern.count
}
