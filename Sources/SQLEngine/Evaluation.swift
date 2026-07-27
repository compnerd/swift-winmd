// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Evaluation

extension Arithmetic {
  /// Applies the operator to two typed operands, yielding a typed `Value`.
  ///
  /// A `||` concatenates two text operands into one text value; the four
  /// arithmetic operators require numeric operands — integer or double. An
  /// `integer ∘ integer` stays an integer, with `/` integer division; any
  /// double operand makes the result a double (a lone integer promoted to
  /// `Double`), with `/` real division. A NULL on either side propagates — the
  /// result is NULL, not a fault. A division by zero is `SQLError.divide`, as
  /// standard SQL raises rather than yielding a value (`inf`/`NaN`), on either
  /// an integer or a double divisor; an operand of the wrong kind (a
  /// non-numeric arithmetic operand, or a non-text `||` operand) is a
  /// `SQLError.operand` type error rather than a silent coercion; an integer
  /// result past the `Int` boundary is `SQLError.magnitude`.
  internal func apply(_ lhs: Value, _ rhs: Value) throws(SQLError) -> Value {
    if case .null = lhs { return .null }
    if case .null = rhs { return .null }
    if case .concatenate = self {
      guard case let .text(lhs) = lhs, case let .text(rhs) = rhs else {
        throw .operand("|| operands must be text")
      }
      return .text(lhs + rhs)
    }
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
    // and Swift's `+`/`-`/`*`/`/` would trap — aborting the process — instead
    // of surfacing a `SQLError`.
    let outcome: (partialValue: Int, overflow: Bool) = switch self {
    case .add: lhs.addingReportingOverflow(rhs)
    case .subtract: lhs.subtractingReportingOverflow(rhs)
    case .multiply: lhs.multipliedReportingOverflow(by: rhs)
    case .divide where rhs == 0: throw .divide
    case .divide: lhs.dividedReportingOverflow(by: rhs)
    // `||` never reaches the numeric path — the public `apply` handles it over
    // text before dispatching a numeric pair here — so a concatenate over two
    // integers is an unreachable operand fault.
    case .concatenate: throw .operand("|| operands must be text")
    }
    if outcome.overflow { throw .magnitude("integer overflow") }
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
    // `||` never reaches the numeric path — the public `apply` handles it over
    // text — so a concatenate over two doubles is an unreachable operand fault.
    case .concatenate: throw .operand("|| operands must be text")
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

/// Whether two typed values differ under ISO `IS DISTINCT FROM` — the null-safe
/// comparison, treating NULL as a comparable value. Unlike `matches`, it is
/// two-valued (never UNKNOWN): two NULLs are the same (not DISTINCT), exactly
/// one NULL is DISTINCT, and two non-NULLs are DISTINCT unless they are equal —
/// a cross-kind pair being DISTINCT, as `matches` yields FALSE (`== true` is
/// false) for cross-kind equality. `IS DISTINCT FROM` returns this; `IS NOT
/// DISTINCT FROM` (null-safe equality) negates it.
internal func distinct(_ lhs: Value, _ rhs: Value) -> Bool {
  switch (lhs, rhs) {
  case (.null, .null): false
  case (.null, _), (_, .null): true
  case let (lhs, rhs): matches(lhs, .equal, rhs) != true
  }
}

/// The three-valued truth of an ISO row-value comparison `(l…) <op> (r…)` over
/// two already-evaluated rows of equal, non-empty arity — the shared fold both
/// the runtime (`Filter.comparison`) and the empty-group pre-fold drive so the
/// two agree by construction.
///
/// `=` is the Kleene `AND` of the componentwise `matches(l[i], =, r[i])` (FALSE
/// dominating — short-circuited), `<>` its negation (UNKNOWN mapping to
/// itself), and the four ordering operators the lexicographic cascade `l0 <op>
/// r0 OR (l0 = r0 AND (l1 <op> r1 OR …))`, right-nested from the last component
/// inward — the innermost step carrying `op` itself (so `<=`/`>=` admit an
/// all-equal row), every earlier step the strict operator (`<`/`>`) tie-guarded
/// by the componentwise equality. A NULL component makes a componentwise test
/// UNKNOWN, propagated through the Kleene fold.
internal func relate(_ l: Array<Value>, _ op: Comparison,
                     _ r: Array<Value>) -> Bool? {
  switch op {
  case .equal:
    var truth: Bool? = true
    for index in l.indices {
      truth = and(truth, matches(l[index], .equal, r[index]))
      if truth == false { break }
    }
    return truth
  case .unequal:
    var truth: Bool? = true
    for index in l.indices {
      truth = and(truth, matches(l[index], .equal, r[index]))
      if truth == false { break }
    }
    return truth.map { !$0 }
  case .lt, .leq, .gt, .geq:
    let strict: Comparison = op == .lt || op == .leq ? .lt : .gt
    var cascade: Bool? = nil
    for index in stride(from: l.count - 1, through: 0, by: -1) {
      let last = index == l.count - 1
      let step = matches(l[index], last ? op : strict, r[index])
      if let tail = cascade {
        let equal = matches(l[index], .equal, r[index])
        cascade = or(step, and(equal, tail))
      } else {
        cascade = step
      }
    }
    return cascade
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

/// The ISO `<boolean test>` mapping — a three-valued `operand` tested against a
/// `Truth` value, negated for `IS NOT`, yielding a definite two-valued result
/// that is never itself UNKNOWN. `p IS TRUE` is `operand == true`, `IS FALSE`
/// is `operand == false`, and `IS UNKNOWN` is `operand == nil` — so an UNKNOWN
/// operand is FALSE against `TRUE`/`FALSE` and TRUE against `UNKNOWN`. This is
/// the shared primitive the run (`Filter.truth`) and the folds
/// (`constant`/`empty`) all map through.
internal func tested(_ operand: Bool?, _ value: Truth, _ negated: Bool)
    -> Bool {
  let matched = switch value {
  case .true: operand == true
  case .false: operand == false
  case .unknown: operand == nil
  }
  return negated ? !matched : matched
}

extension Row where Self: ~Escapable {
  /// Evaluates a subquery-free `filter` against this row under three-valued
  /// logic through `routines` and `bindings` — the choke point a unit test
  /// drives directly. It runs against `NoCatalog`, so a filter that reached an
  /// `EXISTS`/`IN (Q)`/scalar subquery would fault; a subquery-free one never
  /// does.
  internal borrowing func evaluate(_ filter: Filter, _ routines: Routines,
                                   _ bindings: Bindings)
      throws(SQLError) -> Bool? {
    try NoCatalog().evaluate(self, filter,
                             Context(routines: routines, bindings: bindings))
  }
}

extension Catalog where Self: ~Escapable {
  /// Evaluates `filter` against `row` under three-valued logic, resolving
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
  internal borrowing func evaluate(_ row: borrowing some Row & ~Escapable,
                                   _ filter: Filter, _ context: Context)
      throws(SQLError) -> Bool? {
    switch filter {
    case let .compare(lhs, op, rhs):
      try matches(evaluate(row, lhs, context), op, evaluate(row, rhs, context))
    case let .bound(term, op, parameter):
      if let operand = context.bindings[parameter] {
        try matches(evaluate(row, term, context), op, operand)
      } else {
        nil
      }
    case let .match(left, right):
      matches(row[left], .equal, row[right])
    case let .null(term, negated):
      try (evaluate(row, term, context) == .null) != negated
    case let .membership(operand, elements, negated):
      try member(row, operand, elements, negated, context)
    case let .comparison(lhs, op, rhs):
      try compare(row, lhs, op, rhs, context)
    case let .memberships(lhs, rows, negated):
      try member(row, lhs, rows, negated, context)
    case let .like(operand, pattern, escape, negated):
      try like(row, operand, pattern, escape, negated, context)
    case let .between(test, lower, upper, negated):
      try ranged(row, test, lower, upper, negated, context)
    case let .distinct(lhs, rhs, negated):
      try differs(row, lhs, rhs, negated, context)
    case let .exists(key, correlation, negated):
      // The definite two-valued `EXISTS` non-empty test — never UNKNOWN,
      // `negated` flipping it. The subquery runs lazily on this first reach (so
      // an `EXISTS` a short-circuited `AND`/`OR` or an unreached `CASE` arm
      // guards never runs): an uncorrelated one memoises under its `Subkey`; a
      // correlated one re-runs against this row's correlated bindings,
      // bypassing the memo.
      try present(row, key, correlation, context) != negated
    case let .within(lhs, key, correlation, negated):
      // Fold the row equality `(l…) = (r…)` over the subquery's rows under the
      // same Kleene `OR` three-valued membership the value-list row `IN`
      // (`memberships`) uses — degenerating to the scalar `x = v` at arity one.
      // The rows are materialised lazily on this first reach (an uncorrelated
      // one memoised, a correlated one re-run per row against this row's
      // correlated bindings).
      try member(row, lhs, tuples(row, key, correlation, context), negated,
                 context)
    case let .quantified(lhs, op, quantifier, key, correlation):
      // Fold the row comparison `(l…) op r` over the subquery's rows with the
      // same `relate`/Kleene primitives `within` uses — Kleene `OR` (seeded
      // FALSE) for `any`, Kleene `AND` (seeded TRUE) for `all` — degenerating
      // to the scalar `x op v` at arity one. The rows are materialised lazily
      // through the same `tuples` path `within` drives.
      try quantified(row, lhs, op, quantifier,
                     tuples(row, key, correlation, context), context)
    case let .truth(inner, value, negated):
      try tested(evaluate(row, inner, context), value, negated)
    case let .and(lhs, rhs):
      // `&&`/`||` take an `@autoclosure` right operand, which would capture the
      // borrowed `~Escapable` row; spell each connective explicitly so a branch
      // re-borrows the row rather than capturing it. Kleene `AND`: `false`
      // dominates, an UNKNOWN left yields `false` only against a `false` right.
      switch try evaluate(row, lhs, context) {
      case false?: false
      case true?:
        try evaluate(row, rhs, context)
      case nil:
        try evaluate(row, rhs, context) == false ? false : nil
      }
    case let .or(lhs, rhs):
      // Kleene `OR`: `true` dominates, an UNKNOWN left yields `true` only
      // against a `true` right.
      switch try evaluate(row, lhs, context) {
      case true?: true
      case false?:
        try evaluate(row, rhs, context)
      case nil:
        try evaluate(row, rhs, context) == true ? true : nil
      }
    case let .not(operand):
      try evaluate(row, operand, context).map { !$0 }
    }
  }

  /// Evaluates a lowered `operand [NOT] IN (element, …)` against `row`.
  ///
  /// The `operand` is evaluated once per row — an OR-chain of `compare`s would
  /// re-evaluate a non-idempotent operand once per element — then `operand =
  /// element` folds over the elements IN ORDER under Kleene `OR`, seeded FALSE
  /// and short-circuiting at the first TRUE (the same left-to-right visit the
  /// OR-chain made, so a NULL operand or a NULL element keeps the ISO
  /// three-valued result: an unmatched test yields UNKNOWN, not FALSE). `NOT
  /// IN` negates that three-valued truth, mapping UNKNOWN to itself via
  /// `map(!)`.
  private borrowing func member(_ row: borrowing some Row & ~Escapable,
                                _ operand: Term, _ elements: Array<Term>,
                                _ negated: Bool, _ context: Context)
      throws(SQLError) -> Bool? {
    let value = try evaluate(row, operand, context)
    var truth: Bool? = false
    for element in elements {
      let element = try evaluate(row, element, context)
      truth = or(truth, matches(value, .equal, element))
      if truth == true { break }
    }
    return negated ? truth.map { !$0 } : truth
  }

  /// Evaluates a lowered `(l…) <op> (r…)` row-value comparison against `row`.
  ///
  /// Each side is evaluated exactly once per row into a `[Value]` — a desugar
  /// to a conjunction/cascade of scalar `compare`s re-evaluated a component
  /// once per place it appeared, so a stateful component yielded a different
  /// value each time — then the two rows fold through the shared `relate`
  /// primitive, which reproduces the ISO three-valued truth with the same
  /// `matches`/Kleene logic a scalar comparison uses.
  private borrowing func compare(_ row: borrowing some Row & ~Escapable,
                                 _ lhs: Array<Term>, _ op: Comparison,
                                 _ rhs: Array<Term>, _ context: Context)
      throws(SQLError) -> Bool? {
    var l = Array<Value>()
    l.reserveCapacity(lhs.count)
    for term in lhs { try l.append(evaluate(row, term, context)) }
    var r = Array<Value>()
    r.reserveCapacity(rhs.count)
    for term in rhs { try r.append(evaluate(row, term, context)) }
    return relate(l, op, r)
  }

  /// Evaluates a lowered `(l…) [NOT] IN ((r…), …)` row-value membership against
  /// `row`.
  ///
  /// The left row is evaluated once per row into a `[Value]` — as a scalar
  /// `member` holds its operand once, so a stateful component is read a single
  /// time rather than once per element row — then `(l…) = (r…)` folds over the
  /// element rows IN ORDER under Kleene `OR`, seeded FALSE and short-circuiting
  /// at the first TRUE. Each element equality is the shared `relate(_, =, _)`
  /// componentwise Kleene `AND`, so a NULL component keeps the ISO three-valued
  /// result: an unmatched test is UNKNOWN, not FALSE, an empty match FALSE, and
  /// `NOT IN` negates that truth, mapping UNKNOWN to itself.
  private borrowing func member(_ row: borrowing some Row & ~Escapable,
                                _ lhs: Array<Term>, _ rows: Array<Array<Term>>,
                                _ negated: Bool, _ context: Context)
      throws(SQLError) -> Bool? {
    var l = Array<Value>()
    l.reserveCapacity(lhs.count)
    for term in lhs { try l.append(evaluate(row, term, context)) }
    var truth: Bool? = false
    for element in rows {
      var r = Array<Value>()
      r.reserveCapacity(element.count)
      for term in element { try r.append(evaluate(row, term, context)) }
      truth = or(truth, relate(l, .equal, r))
      if truth == true { break }
    }
    return negated ? truth.map { !$0 } : truth
  }

  /// Evaluates a lowered `(l…) [NOT] IN (Q)` against `row` over the subquery's
  /// already-materialised full rows `tuples`.
  ///
  /// It is the value-list row `member` fold over the subquery's rows: the left
  /// row is evaluated once per row into a `[Value]` (as `memberships` holds it
  /// once), then the row equality `(l…) = (r…)` — the shared componentwise
  /// `relate(_, =, _)` Kleene `AND` — folds over `tuples` IN ORDER under Kleene
  /// `OR`, seeded FALSE and short-circuiting at the first TRUE. So a NULL left
  /// component or subquery component keeps the ISO three-valued result (an
  /// unmatched test is UNKNOWN, not FALSE), an empty `tuples` folds FALSE (no
  /// witness), and `NOT IN` negates that truth, mapping UNKNOWN to itself — the
  /// row NULL trap. It reuses the same `relate`/`or` primitives the value-list
  /// row `IN` does, so the two forms share one three-valued core.
  private borrowing func member(_ row: borrowing some Row & ~Escapable,
                                _ lhs: Array<Term>,
                                _ tuples: Array<Array<Value>>,
                                _ negated: Bool, _ context: Context)
      throws(SQLError) -> Bool? {
    var l = Array<Value>()
    l.reserveCapacity(lhs.count)
    for term in lhs { try l.append(evaluate(row, term, context)) }
    var truth: Bool? = false
    for element in tuples {
      truth = or(truth, relate(l, .equal, element))
      if truth == true { break }
    }
    return negated ? truth.map { !$0 } : truth
  }

  /// Evaluates a lowered `(l…) op {ANY | ALL} (Q)` against `row` over the
  /// subquery's already-materialised full rows `tuples`.
  ///
  /// The left row is evaluated once per row into a `[Value]`, then the row
  /// comparison `(l…) op r` — the shared `relate` three-valued relation
  /// (componentwise Kleene `AND` for `=`, its negation for `<>`, the
  /// lexicographic cascade for the ordering operators) — folds over `tuples` IN
  /// ORDER with the same Kleene primitives the `member` `IN` fold uses: Kleene
  /// `OR` seeded FALSE for `any` (short-circuiting at the first TRUE), Kleene
  /// `AND` seeded TRUE for `all` (short-circuiting at the first FALSE). So a
  /// NULL component makes an otherwise-undecided fold UNKNOWN, and an empty
  /// `tuples` takes the seed — `any` FALSE (no witness), `all` TRUE (vacuous).
  /// `= ANY` reduces to the `member` row `IN` fold and `<> ALL` to its inverse.
  private borrowing func quantified(_ row: borrowing some Row & ~Escapable,
                                    _ lhs: Array<Term>, _ op: Comparison,
                                    _ quantifier: Quantifier,
                                    _ tuples: Array<Array<Value>>,
                                    _ context: Context)
      throws(SQLError) -> Bool? {
    var l = Array<Value>()
    l.reserveCapacity(lhs.count)
    for term in lhs { try l.append(evaluate(row, term, context)) }
    var truth: Bool? = quantifier == .any ? false : true
    for element in tuples {
      let matched = relate(l, op, element)
      switch quantifier {
      case .any:
        truth = or(truth, matched)
        if truth == true { return true }
      case .all:
        truth = and(truth, matched)
        if truth == false { return false }
      }
    }
    return truth
  }

  /// Evaluates a lowered `test [NOT] BETWEEN lower AND upper` against this row.
  ///
  /// The `test` term is evaluated once per row — an `AND`/`OR` of two
  /// comparisons would re-evaluate a non-idempotent test once per bound — then
  /// the two bounds fold against that same value under Kleene logic as `test >=
  /// lower AND test <= upper`. `NOT BETWEEN` is the negation of that same
  /// truth, NOT the `test < lower OR test > upper` expansion: with a cross-kind
  /// bound `matches` yields FALSE for every ordering operator (so `test <
  /// lower` is not the complement of `test >= lower`), and the expansion would
  /// diverge from `NOT (test BETWEEN lower AND upper)` — e.g. `K NOT BETWEEN
  /// 'a' AND 10` must KEEP the row (the cross-kind `K >= 'a'` is FALSE, so
  /// BETWEEN is FALSE and its negation TRUE), which the expansion's two FALSE
  /// ordering checks would wrongly reject. A NULL `test`, `lower`, or `upper`
  /// makes a bound UNKNOWN (`matches` yields `nil`), so the row is excluded —
  /// the ISO three-valued range semantics.
  ///
  /// The `upper` bound is evaluated ONLY when the lower does not already settle
  /// the truth: a definitely-FALSE `test >= lower` makes BETWEEN FALSE (and NOT
  /// BETWEEN TRUE) under Kleene `AND` without reaching the `upper` term — or
  /// any error it would raise — so `0 BETWEEN 1 AND (1 / 0)` rejects the row
  /// rather than dividing by zero, as the desugar's constant-false left would
  /// leave its right unevaluated.
  ///
  /// Each bound is an `Operand` — a `Term` evaluated against the row or a
  /// run-time `:parameter` resolved from the bindings (an unbound or NULL-bound
  /// one reading UNKNOWN, excluding the row) — the same binding a comparison's
  /// right operand accepts.
  private borrowing func ranged(_ row: borrowing some Row & ~Escapable,
                                _ test: Term, _ lower: Filter.Operand,
                                _ upper: Filter.Operand, _ negated: Bool,
                                _ context: Context)
      throws(SQLError) -> Bool? {
    let value = try evaluate(row, test, context)
    let low = try evaluate(row, lower, context)
    let above = matches(value, .geq, low)
    if above == false { return negated }
    let high = try evaluate(row, upper, context)
    let within = and(above, matches(value, .leq, high))
    return negated ? within.map { !$0 } : within
  }

  /// Evaluates a lowered `lhs IS [NOT] DISTINCT FROM rhs` against this row.
  ///
  /// It is the ISO null-safe comparison — two-valued, never UNKNOWN — treating
  /// NULL as a comparable value: `distinct` yields whether the two operand
  /// values differ (both NULL are the same, exactly one NULL differs, two
  /// non-NULLs differ unless equal, a cross-kind pair differs). `IS DISTINCT
  /// FROM` reads that; `IS NOT DISTINCT FROM` (`negated`, null-safe equality)
  /// negates it. Unlike a `compare`, a NULL operand never makes the row
  /// UNKNOWN.
  private borrowing func differs(_ row: borrowing some Row & ~Escapable,
                                 _ lhs: Term, _ rhs: Term, _ negated: Bool,
                                 _ context: Context)
      throws(SQLError) -> Bool? {
    let differ = try distinct(evaluate(row, lhs, context),
                              evaluate(row, rhs, context))
    return negated ? !differ : differ
  }

  /// Resolves a `LIKE` pattern or escape operand to a value: a term evaluates
  /// against `row`, a `:parameter` resolves from the bindings — an unbound name
  /// yields `.null`, so it reads UNKNOWN exactly as a bound `NULL` does.
  private borrowing func evaluate(_ row: borrowing some Row & ~Escapable,
                                  _ operand: Filter.Operand, _ context: Context)
      throws(SQLError) -> Value {
    switch operand {
    case let .term(term):
      try evaluate(row, term, context)
    case let .parameter(name):
      context.bindings[name] ?? .null
    }
  }

  /// Evaluates a lowered `operand [NOT] LIKE pattern [ESCAPE escape]` against
  /// this row under three-valued logic.
  ///
  /// The operand, pattern, and optional escape are each evaluated once, IN
  /// ORDER, before the three-valued result is decided — so a faulting reached
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
  private borrowing func like(_ row: borrowing some Row & ~Escapable,
                              _ operand: Term, _ pattern: Filter.Operand,
                              _ escape: Filter.Operand?, _ negated: Bool,
                              _ context: Context)
      throws(SQLError) -> Bool? {
    // Evaluate all three reached operands once, in order — a fault in any of
    // them (a divide, an overflow) propagates here, before the NULL/escape
    // result below can turn it into a silent UNKNOWN.
    let subject = try evaluate(row, operand, context)
    let template = try evaluate(row, pattern, context)
    let separator: Value? =
        if let escape {
          try evaluate(row, escape, context)
        } else {
          nil
        }

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
/// pattern is ill-formed — a trailing escape with no character to escape, which
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
/// The match is anchored — the whole `text` must be consumed. It is the classic
/// linear two-pointer `LIKE` scan: a `%` is remembered (the pattern position
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
