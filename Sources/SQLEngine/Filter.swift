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
internal indirect enum Filter: Equatable, Sendable {
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
  /// `(l1, …, ln) <op> (r1, …, rn)` — an ISO row-value comparison, both sides a
  /// row of ordinal-addressed terms of EQUAL arity, `op` any of the six
  /// operators. The lowered form of the AST's `rows`. Every component term is
  /// evaluated exactly ONCE per row into a `[Value]` (a parse-time desugar to a
  /// conjunction/cascade of scalar `compare`s re-evaluated a component once per
  /// place it appeared, so a stateful component yielded a different value each
  /// time), then the runtime folds those values with the SAME `matches`
  /// primitive and Kleene `AND`/`OR` a scalar comparison uses, reproducing the
  /// ISO three-valued truth: `=` is the Kleene `AND` of the componentwise
  /// equalities, `<>` its negation, and the four ordering operators the
  /// lexicographic cascade `l1 <op> r1 OR (l1 = r1 AND (l2 <op> r2 OR …))`
  /// whose earlier steps use the STRICT operator (`<`/`>`) and whose innermost
  /// step carries `op` itself (so `<=`/`>=` admit an all-equal row) — a NULL
  /// component making a componentwise test UNKNOWN, threaded through the fold.
  case comparison(Array<Term>, Comparison, Array<Term>)
  /// `(l1, …, ln) [NOT] IN ((r1, …, rn), …)` — an ISO row-value membership, the
  /// left a row of ordinal-addressed terms and `rows` a non-empty list of
  /// element rows of EQUAL arity, `negated` marking `NOT IN`. The lowered form
  /// of the AST's `among`. The left row is evaluated exactly ONCE per row into
  /// a `[Value]` (as a scalar `Filter.membership` holds its operand once), then
  /// `(l…) = (r…)` folds over the element rows IN ORDER under Kleene `OR`,
  /// seeded FALSE, short-circuiting at the first TRUE — each element equality
  /// the same componentwise Kleene `AND` the `=` comparison uses — so a NULL
  /// component keeps the ISO three-valued result (an unmatched test is UNKNOWN,
  /// not FALSE), an empty match FALSE, and `NOT IN` negates that truth (UNKNOWN
  /// maps to itself). A desugar to an OR-chain of scalar row equalities would
  /// re-evaluate the left components once per element; holding them once fixes
  /// that.
  case memberships(Array<Term>, Array<Array<Term>>, negated: Bool)
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
  /// `x [NOT] BETWEEN a AND b` — the lowered form of the AST's `between`. The
  /// test term `x` is held ONCE, the two bounds `a` and `b` beside it — each an
  /// `Operand`, a `Term` evaluated per row or a run-time `:parameter` resolved
  /// from the bindings — and `negated` marks `NOT BETWEEN`. Evaluating it reads
  /// `x` once per row (an `AND`/`OR` of two comparisons would re-evaluate a
  /// non-idempotent `x`, once per bound) and folds `x >= a` AND `x <= b` (or `x
  /// < a` OR `x > b` when negated) over the SAME `x` under Kleene logic, so a
  /// NULL `x`, `a`, or `b` — an unbound or NULL-bound `:parameter` included —
  /// makes a bound UNKNOWN and the row is excluded.
  case between(Term, Operand, Operand, negated: Bool)
  /// `a IS [NOT] DISTINCT FROM b` — the lowered form of the AST's `distinct`.
  /// Both operands are plain `Term`s (no `:parameter` form is defined for this
  /// predicate) and `negated` marks the `IS NOT DISTINCT FROM` (null-safe
  /// equality) spelling. Evaluating it is TWO-VALUED — never UNKNOWN — treating
  /// NULL as a comparable value: the two are the SAME iff both are NULL, or
  /// both non-NULL and equal (a cross-kind pair is DISTINCT, matching
  /// `matches`'s cross-kind FALSE equality), and `IS DISTINCT FROM` is TRUE
  /// when they differ, `IS NOT DISTINCT FROM` when they are the same.
  case distinct(Term, Term, negated: Bool)
  /// `[NOT] EXISTS (Q)` — the lowered form of the AST's `exists`. The subquery
  /// occurrence is carried as its cache `Subkey` (its resolution scope composed
  /// with `Q`) — never run during `compile`, so a schema-only path
  /// (`columns(of:)`, view resolution) opens no cursor. At RUN time it runs
  /// ONCE against the borrowed catalog (memoised in a `Subqueries` cache under
  /// the `Subkey`, since it is UNCORRELATED — one result for every outer row,
  /// under its OWN resolution context) and the case is the DEFINITE two-valued
  /// non-empty test of that result: TRUE iff `Q` yielded a row, `negated`
  /// flipping it (never UNKNOWN). It reads no cell of the outer row. An
  /// EXISTS-only occurrence is materialised as a cardinality PROBE — its select
  /// list never evaluated. A later correlated slice re-runs `Q` per outer row.
  case exists(Subkey, correlation: Correlation, negated: Bool)
  /// `x [NOT] IN (Q)` — the lowered form of the AST's `within`. The subquery
  /// occurrence is carried as its cache `Subkey` — never run during `compile` —
  /// and its single-column arity is enforced at COMPILE from its compiled width
  /// (`SQLError.arity`, no cursor). At RUN time `Q` executes ONCE against the
  /// borrowed catalog (memoised under the `Subkey` in the `Subqueries` cache,
  /// UNCORRELATED) and the case folds `operand = v` over its lone column under
  /// the SAME Kleene `OR` three-valued membership the value-list
  /// `Filter.membership` uses — a NULL operand or a NULL element making an
  /// unmatched test UNKNOWN, an EMPTY result FALSE, and `negated` (`NOT IN`)
  /// negating the three-valued result (UNKNOWN maps to itself). The operand
  /// `Term` is evaluated once per row.
  case within(Term, Subkey, correlation: Correlation, negated: Bool)
  /// `x op {ANY | ALL} (Q)` — the lowered form of the AST's `quantified`. The
  /// operand term `x` is held ONCE, the comparison `op` and the `Quantifier`
  /// beside it, and the subquery occurrence as its cache `Subkey` (its
  /// `.valued` role, the FULL column materialised as `within`'s is) — never
  /// run during `compile`, its single-column arity enforced at COMPILE from the
  /// compiled width (`SQLError.arity`, no cursor). At RUN `Q` executes ONCE
  /// against the borrowed catalog (memoised under the `Subkey`, UNCORRELATED)
  /// and the case folds `x op v` over its lone column with the SAME
  /// `matches`/Kleene primitives `within` uses: Kleene `OR` for `any` (seeded
  /// FALSE), Kleene `AND` for `all` (seeded TRUE), so a NULL `x` or element
  /// makes an otherwise-undecided fold UNKNOWN, and an EMPTY column takes the
  /// seed — `any` FALSE, `all` TRUE. The operand `Term` is evaluated once per
  /// row. A CORRELATED occurrence carries the discovered `correlation` (as
  /// `within` does) and re-runs its inner plan per outer row; an UNCORRELATED
  /// one carries an empty correlation and memoises once.
  case quantified(Term, Comparison, Quantifier, Subkey,
                  correlation: Correlation)
  /// `p IS [NOT] <truth value>` — the lowered form of the AST's `truth`. The
  /// inner boolean `Filter` is held once and evaluated to its three-valued
  /// result, which is then MAPPED against `value` (`TRUE`/`FALSE`/`UNKNOWN`) to
  /// a DEFINITE two-valued result — never itself UNKNOWN — and negated for `IS
  /// NOT`. An UNKNOWN inner is FALSE against `TRUE`/`FALSE` but TRUE against
  /// `UNKNOWN`, so the test collapses SQL's third value to a two-valued answer.
  case truth(Filter, Truth, negated: Bool)
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
  internal enum Operand: Equatable, Sendable {
    /// A `Term` evaluated against the row per its usual lowering.
    case term(Term)
    /// A `:parameter` name, resolved from the bindings at eval — an unbound one
    /// (or one bound to `NULL`) makes the `LIKE` UNKNOWN.
    case parameter(String)
  }
}

// MARK: - Leaf construction

extension Filter {
  /// The value-predicate leaf `compare(lhs, op, rhs)` — a labeled convenience
  /// initializer so an authoring site reads `Filter(compare: lhs, op, rhs)`
  /// rather than the bare case. A thin forward: no operand normalization.
  internal init(compare lhs: Term, _ op: Comparison, _ rhs: Term) {
    self = .compare(lhs, op, rhs)
  }

  /// The value-predicate leaf `match(left, right)` — a labeled convenience
  /// initializer so an authoring site reads `Filter(match: left, right)`. A
  /// thin forward to the case.
  internal init(match left: Int, _ right: Int) {
    self = .match(left, right)
  }

  /// The value-predicate leaf `null(term, negated:)` — a labeled convenience
  /// initializer so an authoring site reads `Filter(null: term, negated:)`. A
  /// thin forward to the case.
  internal init(null term: Term, negated: Bool) {
    self = .null(term, negated: negated)
  }

  /// The value-predicate leaf `membership(operand, values, negated:)` — a
  /// labeled convenience initializer so an authoring site reads
  /// `Filter(membership: operand, values, negated:)`. The middle value list is
  /// unlabeled as in the case. A thin forward.
  internal init(membership operand: Term, _ values: Array<Term>,
                negated: Bool) {
    self = .membership(operand, values, negated: negated)
  }

  /// The value-predicate leaf `between(test, lower, upper, negated:)` — a
  /// labeled convenience initializer so an authoring site reads
  /// `Filter(between: test, lower, upper, negated:)`. A thin forward.
  internal init(between test: Term, _ lower: Operand, _ upper: Operand,
                negated: Bool) {
    self = .between(test, lower, upper, negated: negated)
  }

  /// The value-predicate leaf `like(operand, pattern:, escape:, negated:)` — a
  /// labeled convenience initializer so an authoring site reads
  /// `Filter(like: operand, pattern:, escape:, negated:)`. A thin forward.
  internal init(like operand: Term, pattern: Operand, escape: Operand?,
                negated: Bool) {
    self = .like(operand, pattern: pattern, escape: escape, negated: negated)
  }

  /// The value-predicate leaf `distinct(lhs, rhs, negated:)` — a labeled
  /// convenience initializer so an authoring site reads
  /// `Filter(distinct: lhs, rhs, negated:)`. A thin forward.
  internal init(distinct lhs: Term, _ rhs: Term, negated: Bool) {
    self = .distinct(lhs, rhs, negated: negated)
  }

  /// The value-predicate leaf `comparison(lhs, op, rhs)` — a labeled
  /// convenience initializer so a row-value authoring site reads
  /// `Filter(comparison: lhs, op, rhs)`. A thin forward.
  internal init(comparison lhs: Array<Term>, _ op: Comparison,
                _ rhs: Array<Term>) {
    self = .comparison(lhs, op, rhs)
  }

  /// The value-predicate leaf `memberships(lhs, rows, negated:)` — a labeled
  /// convenience initializer so a row-value authoring site reads
  /// `Filter(memberships: lhs, rows, negated:)`. The middle row list is
  /// unlabeled as in the case. A thin forward.
  internal init(memberships lhs: Array<Term>, _ rows: Array<Array<Term>>,
                negated: Bool) {
    self = .memberships(lhs, rows, negated: negated)
  }
}

// MARK: - Terms

/// The engine's ordinal-addressed scalar expression.
///
/// `Term` is the lowered form of the AST's name-addressed `Expression`: a slot
/// reference (a column resolved to its slot in a record), a constant, or a call
/// to a registered scalar function over argument terms. A projection lowers
/// each projected expression to a `Term` the executor evaluates per record
/// against the routines; a bare-column projection lowers to a `.slot`, so the
/// simple path stays a plain slot read.
internal indirect enum Term: Equatable, Sendable {
  /// The cell at `slot` of the record.
  case slot(Int)
  /// A run-time `:parameter`, resolved from the engine's bindings — the lowered
  /// form of a CORRELATED subquery's reference to an ENCLOSING query's column.
  /// An outer column the inner query names binds neither locally nor as an
  /// ordinary parameter; it lowers to this synthetic name, and the
  /// per-outer-row re-execution binds it to that row's cell before running the
  /// inner plan (see `Correlation`). An unbound name (or one bound to NULL)
  /// reads `.null`, so a comparison against it is UNKNOWN, exactly as a
  /// `Filter.bound` operand is.
  case parameter(String)
  /// A constant value.
  case constant(Value)
  /// A call to the named scalar function over its argument terms, in order.
  case apply(name: String, arguments: Array<Term>)
  /// `lhs <op> rhs` — a binary arithmetic over two operand terms, the lowered
  /// form of the AST's `Expression.binary`.
  case binary(Arithmetic, Term, Term)
  /// A `CASE` conditional — the lowered form of the AST's `Expression.case`.
  /// Each branch is a guard `Filter` and the result `Term` it yields; the
  /// executor evaluates the guards in order and takes the first whose
  /// three-valued value is TRUE (UNKNOWN and FALSE skip), else the `else` term,
  /// or `NULL` when there is none. `type` is the unification of the branch
  /// result types (the same `ValueType.unified` reduction `derive`/`validate`
  /// compute) — the type the schema advertises for the column — so the executor
  /// COERCES the selected value to it, widening an `.integer` arm of a
  /// `.double` CASE.
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
  /// A scalar subquery `(SELECT …)` — the lowered form of the AST's
  /// `Expression.subquery`. The subquery occurrence is carried as its cache
  /// `Subkey` (its resolution scope composed with the inner `Query`) — never
  /// run during `compile`, so a schema-only path opens no cursor — and its
  /// single-column arity is enforced at COMPILE from its compiled width
  /// (`SQLError.arity`, no cursor). At RUN it runs ONCE against the borrowed
  /// catalog (memoised under the `Subkey` in the `Subqueries` cache,
  /// UNCORRELATED), collapsing to its lone cell (empty → NULL, one row → the
  /// cell, more → `SQLError.cardinality`), and the case reads that collapsed
  /// value, COERCED to `type` — the inner column's single-column type — as a
  /// `CASE` coerces its selected arm. A later correlated slice re-runs it per
  /// outer row.
  case subquery(Subkey, correlation: Correlation, type: ValueType)
}

extension Term {
  /// Structural equality over two lowered terms — the RESOLVED form column
  /// qualification has already normalized to a slot — so a `DISTINCT` ORDER BY
  /// key can be recognised as one of the projected select-list values it must
  /// order on (see `distinct`). The compiler cannot synthesise `Equatable` for
  /// `Term`: the `.case` payload is an `Array<(Filter, Term)>` of tuples, and a
  /// tuple is not `Equatable`, so the array is not either. Every other case has
  /// `Equatable` components (the leaf `Value`/`ValueType`/`Arithmetic` are
  /// `Hashable`, and `Filter`/`Term` conform here), so only the `.case` branch
  /// needs the element-wise tuple comparison spelled out.
  internal static func ==(lhs: Term, rhs: Term) -> Bool {
    switch (lhs, rhs) {
    case let (.slot(lhs), .slot(rhs)):
      lhs == rhs
    case let (.parameter(lhs), .parameter(rhs)):
      lhs == rhs
    case let (.constant(lhs), .constant(rhs)):
      lhs == rhs
    case let (.apply(lname, largs), .apply(rname, rargs)):
      lname == rname && largs == rargs
    case let (.binary(lop, ll, lr), .binary(rop, rl, rr)):
      lop == rop && ll == rl && lr == rr
    case let (.case(lbranches, lelse, ltype),
              .case(rbranches, relse, rtype)):
      ltype == rtype && lelse == relse
          && lbranches.count == rbranches.count
          && zip(lbranches, rbranches).allSatisfy {
               $0.0 == $1.0 && $0.1 == $1.1
             }
    case let (.cast(lterm, ltype), .cast(rterm, rtype)):
      lterm == rterm && ltype == rtype
    case let (.coalesce(lelems, ltype), .coalesce(relems, rtype)):
      lelems == relems && ltype == rtype
    case let (.nullif(ll, lr), .nullif(rl, rr)):
      ll == rl && lr == rr
    case let (.subquery(lkey, lcorr, ltype), .subquery(rkey, rcorr, rtype)):
      lkey == rkey && lcorr == rcorr && ltype == rtype
    default:
      false
    }
  }

  /// The slots this term reads, accumulated into `slots`.
  ///
  /// A `slot` reads itself; a `constant` reads none; an `apply` reads the union
  /// of its arguments. A projection unions these with the filter and order so a
  /// scan materialises exactly the cells the projection's functions consume.
  internal func references(into slots: inout Set<Int>) {
    switch self {
    case let .slot(slot):
      slots.insert(slot)
    case .parameter:
      // A correlated `:parameter` reads no cell of THIS row — its value comes
      // from an enclosing row bound into the run's bindings — so it references
      // no slot of the current record.
      break
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
    case let .subquery(_, correlation, _):
      // A CORRELATED scalar subquery reads the enclosing row's cells its inner
      // `WHERE` names — the correlation's `slot` outer ordinals — so those must
      // be materialised into the outer record for the per-row re-execution to
      // bind them. A `bound` source is a threaded binding, not an outer cell,
      // so it references none. An UNCORRELATED one (empty correlation)
      // references none — its value is a single cache lookup.
      slots.formUnion(correlation.slots)
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
    case .parameter:
      // A correlated `:parameter` reads the bindings, not a slot, so the
      // ordinal-to-slot remap leaves it unchanged.
      self
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
    case let .subquery(key, correlation, type):
      // A CORRELATED scalar subquery's correlation reads OUTER ordinals; remap
      // each `slot` to its packed slot so the per-row re-execution reads the
      // outer record's cell (a `bound` source is unchanged — it reads a
      // threaded binding). An UNCORRELATED one has an empty map and is
      // unchanged.
      .subquery(key, correlation: correlation.remapped(through: slot),
                type: type)
    }
  }

  /// Whether evaluating this term cannot throw — it is a bare slot read or a
  /// constant. A `binary` arithmetic (`/` raises on a zero divisor), an `apply`
  /// (a scalar function may raise), a `cast` (an unconvertible value raises),
  /// a `coalesce` (an element may raise), or a `nullif` (an operand may raise)
  /// is NOT known safe, whatever its operands.
  internal var safe: Bool {
    switch self {
    // A `:parameter` is a bindings lookup, never a fault — safe, as
    // `Filter.Operand.parameter` is.
    case .slot, .parameter, .constant: true
    case .apply, .binary, .case, .cast, .coalesce, .nullif, .subquery: false
    }
  }

  /// Whether this term reads a run-time `:parameter` anywhere — a CORRELATED
  /// subquery's synthetic outer binding, which may be unbound or bound to NULL,
  /// so a comparison over it can be UNKNOWN even when it reads NO slot.
  /// Selection pushdown reads this (through `Filter.nullable`) so a
  /// `.compare`/`.null` over a correlated `:parameter` — a slotless `outer_id =
  /// 1` — is not moved ahead of a later unsafe conjunct the
  /// non-short-circuiting `AND` still owes, the same treatment a `Filter.bound`
  /// parameter already gets.
  internal var parameterised: Bool {
    switch self {
    case .parameter: true
    case .slot, .constant: false
    case let .apply(_, arguments): arguments.contains(where: \.parameterised)
    case let .binary(_, lhs, rhs): lhs.parameterised || rhs.parameterised
    case let .case(branches, otherwise, _):
      branches.contains { $0.0.parameterised || $0.1.parameterised }
          || (otherwise?.parameterised ?? false)
    case let .cast(operand, _): operand.parameterised
    case let .coalesce(elements, _): elements.contains(where: \.parameterised)
    case let .nullif(lhs, rhs): lhs.parameterised || rhs.parameterised
    // A scalar `.subquery` carries its correlation on the `Filter` side and is
    // never `safe`, so it stays un-pushed regardless; report false here.
    case .subquery: false
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

  /// Whether this operand reads a run-time `:parameter` — a `.parameter` is one
  /// (it may be unbound or bound to NULL, so a `LIKE` over it is UNKNOWN), and
  /// a `.term` is one when its `Term` itself carries a correlated
  /// `Term.parameter`. `Filter.like` folds this over its pattern and escape so
  /// a parameterised `LIKE` stays off a pushdown below a later unsafe conjunct
  /// (see `Filter.nullable`).
  internal var parameterised: Bool {
    switch self {
    case let .term(term): term.parameterised
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
      Filter(compare: lhs.remapped(through: slot), op,
             rhs.remapped(through: slot))
    case let .bound(term, op, parameter):
      .bound(term.remapped(through: slot), op, parameter)
    case let .match(left, right):
      Filter(match: slot[left]!, slot[right]!)
    case let .null(term, negated):
      Filter(null: term.remapped(through: slot), negated: negated)
    case let .membership(operand, elements, negated):
      Filter(membership: operand.remapped(through: slot),
             elements.map { $0.remapped(through: slot) },
             negated: negated)
    case let .comparison(lhs, op, rhs):
      Filter(comparison: lhs.map { $0.remapped(through: slot) }, op,
             rhs.map { $0.remapped(through: slot) })
    case let .memberships(lhs, rows, negated):
      Filter(memberships: lhs.map { $0.remapped(through: slot) },
             rows.map { $0.map { $0.remapped(through: slot) } },
             negated: negated)
    case let .like(operand, pattern, escape, negated):
      Filter(like: operand.remapped(through: slot),
             pattern: pattern.remapped(through: slot),
             escape: escape?.remapped(through: slot), negated: negated)
    case let .between(test, lower, upper, negated):
      Filter(between: test.remapped(through: slot),
             lower.remapped(through: slot),
             upper.remapped(through: slot), negated: negated)
    case let .distinct(lhs, rhs, negated):
      Filter(distinct: lhs.remapped(through: slot),
             rhs.remapped(through: slot),
             negated: negated)
    case let .exists(key, correlation, negated):
      // A CORRELATED EXISTS reads the enclosing row's cells its inner `WHERE`
      // names; remap each `slot` outer ordinal to its packed slot (a `bound`
      // source is unchanged). An UNCORRELATED one has an empty map and passes
      // its cache key through unchanged.
      .exists(key, correlation: correlation.remapped(through: slot),
              negated: negated)
    case let .within(operand, key, correlation, negated):
      // The outer operand term reads slots; a CORRELATED subquery ALSO reads
      // the outer cells its inner `WHERE` names, so remap both. An UNCORRELATED
      // one carries an empty correlation.
      .within(operand.remapped(through: slot), key,
              correlation: correlation.remapped(through: slot),
              negated: negated)
    case let .quantified(operand, op, quantifier, key, correlation):
      // As `within`: the outer operand term reads slots; a CORRELATED subquery
      // ALSO reads the outer cells its inner `WHERE` names, so remap both. An
      // UNCORRELATED one carries an empty correlation.
      .quantified(operand.remapped(through: slot), op, quantifier, key,
                  correlation: correlation.remapped(through: slot))
    case let .truth(inner, value, negated):
      .truth(inner.remapped(through: slot), value, negated: negated)
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

  /// Whether evaluating this filter cannot throw — every term it reads is a
  /// bare slot or a constant. Selection pushdown keeps a filter that is NOT
  /// safe at the product level (evaluated per pair), so a division or
  /// scalar-call predicate raises only when a pair exists — never on an empty
  /// product it would have skipped had it stayed above the join.
  internal var safe: Bool {
    switch self {
    case let .compare(lhs, _, rhs): lhs.safe && rhs.safe
    case let .bound(term, _, _): term.safe
    case .match: true
    case let .null(term, _): term.safe
    case let .membership(operand, elements, _):
      operand.safe && elements.allSatisfy(\.safe)
    case let .comparison(lhs, _, rhs):
      lhs.allSatisfy(\.safe) && rhs.allSatisfy(\.safe)
    case let .memberships(lhs, rows, _):
      lhs.allSatisfy(\.safe) && rows.allSatisfy { $0.allSatisfy(\.safe) }
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
    case let .between(test, lower, upper, _):
      test.safe && lower.safe && upper.safe
    case let .distinct(lhs, rhs, _): lhs.safe && rhs.safe
    case .exists, .within, .quantified:
      // A subquery predicate is NEVER safe to push below a seek or short-
      // circuiting derived/view filter. Under LAZY materialisation the FIRST
      // evaluation of even an UNCORRELATED occurrence RUNS the inner query,
      // which may FAULT (`EXISTS (SELECT 1 FROM S WHERE 1 / z = 0)`); a
      // CORRELATED one re-runs per outer row. Pushed below a short-circuiting
      // filter — a view's `WHERE 1 = 0`, a seek — it would be evaluated for a
      // row the filter drops, raising a throw the unmoved query never reaches,
      // so it stays at the product level, run only where the outer predicate
      // reaches it.
      false
    case let .truth(inner, _, _): inner.safe
    case let .and(lhs, rhs): lhs.safe && rhs.safe
    case let .or(lhs, rhs): lhs.safe && rhs.safe
    case let .not(operand): operand.safe
    }
  }

  /// Whether evaluating this filter can be UNKNOWN — it reads at least one slot
  /// (a NULL cell there makes a comparison against it UNKNOWN), compares
  /// against a run-time `:parameter` (which may be unbound or bound to NULL,
  /// likewise UNKNOWN), or is an `IN (Q)` subquery test (three-valued: UNKNOWN
  /// when the materialised subquery holds a NULL, even over a constant
  /// operand — slotless yet not definite). Only a filter over constants alone
  /// whose leaves are all definite is TRUE/FALSE for certain. Selection
  /// pushdown must not ride a nullable conjunct below a join or into a view
  /// when a LATER conjunct is unsafe: the evaluator's `AND` does not
  /// short-circuit, so the un-pushed query evaluates the later conjunct even
  /// when this one is UNKNOWN — pushing this one down drops the UNKNOWN row
  /// before the later conjunct runs, suppressing a throw the left-to-right
  /// `AND` owes (`A.x = 1 AND (1 / B.y) = 0`, `A.x` NULL and `B.y = 0` on a
  /// matching pair; `1 = :missing AND (1 / y) = 0` over a view, `:missing`
  /// unbound; or `1 IN (SELECT N FROM S) AND (1 / 0) = 0`, `S.N` a non-matching
  /// NULL making the `IN` UNKNOWN — all slotless yet UNKNOWN).
  internal var nullable: Bool {
    !slots.isEmpty || parameterised || contingent
  }

  /// Whether this filter can be UNKNOWN INDEPENDENT of any slot or
  /// `:parameter` — an `IN (Q)` subquery test (`Filter.within`), which is
  /// three-valued: `x IN (Q)` is UNKNOWN when `Q`'s materialised column holds a
  /// NULL and no element matches, so a slotless `1 IN (Q)` over a constant
  /// operand is still not definite. `nullable` counts it even when `slots` is
  /// empty and nothing is parameterised, keeping an `IN (Q)` conjunct off a
  /// pushdown ahead of a later unsafe conjunct the non-short-circuiting `AND`
  /// still owes. An `EXISTS (Q)` is genuinely TWO-valued — a decided non-empty
  /// test, never UNKNOWN — so it is NOT contingent and stays freely pushable.
  private var contingent: Bool {
    switch self {
    // A quantified comparison is three-valued exactly as `IN (Q)` is — a NULL
    // in `Q`'s column (or a NULL operand) can make an otherwise-undecided fold
    // UNKNOWN, slotless yet not definite — so both stay off a pushdown ahead of
    // a later unsafe conjunct the non-short-circuiting `AND` still owes.
    case .within, .quantified: true
    // A row comparison and row `IN` read slots (their components), so they are
    // never slotless-UNKNOWN; `nullable`'s `slots` term already accounts for
    // them, exactly as the scalar `.compare`/`.membership` do.
    case .compare, .bound, .match, .null, .membership, .comparison,
         .memberships, .like, .between, .distinct, .exists: false
    case let .truth(inner, _, _): inner.contingent
    case let .and(lhs, rhs): lhs.contingent || rhs.contingent
    case let .or(lhs, rhs): lhs.contingent || rhs.contingent
    case let .not(operand): operand.contingent
    }
  }

  /// Whether this filter compares against a run-time `:parameter` — a `.bound`
  /// anywhere in it, a `.compare`/`.null`/`.membership`/`.distinct` whose TERM
  /// carries a `Term.parameter` (a CORRELATED subquery's synthetic outer
  /// binding), a `.like` whose pattern or escape operand is a `:parameter`, or
  /// a `.between` whose test or bound carries one. Such a predicate reads no
  /// slot yet can be UNKNOWN, because the parameter may be unbound (or bound to
  /// NULL), so `nullable` counts it even when `slots` is empty — keeping `'x'
  /// LIKE :p`, `1 BETWEEN :lo AND :hi`, or a correlated slotless `outer_id = 1`
  /// off a pushdown below a later unsafe conjunct the non-short-circuiting
  /// `AND` still owes.
  ///
  /// `internal` (not `private`) so `Term.parameterised` can consult a `.case`
  /// guard `Filter` for a correlated `:parameter`.
  internal var parameterised: Bool {
    switch self {
    case .bound: true
    // A term-bearing predicate is parameterised when a TERM carries a
    // correlated `Term.parameter` — a slotless comparison that can be UNKNOWN,
    // so it must not ride ahead of a later unsafe conjunct, the same treatment
    // `.bound` gets.
    case let .compare(lhs, _, rhs): lhs.parameterised || rhs.parameterised
    case let .null(term, _): term.parameterised
    case let .membership(operand, elements, _):
      operand.parameterised || elements.contains(where: \.parameterised)
    case let .comparison(lhs, _, rhs):
      lhs.contains(where: \.parameterised)
          || rhs.contains(where: \.parameterised)
    case let .memberships(lhs, rows, _):
      lhs.contains(where: \.parameterised)
          || rows.contains { $0.contains(where: \.parameterised) }
    case let .distinct(lhs, rhs, _): lhs.parameterised || rhs.parameterised
    case .match: false
    // An UNCORRELATED subquery predicate reads no run-time `:parameter` of the
    // OUTER query — the subquery runs once at run start with the same bindings
    // — so none is parameterised for the outer row. A CORRELATED one is already
    // NOT `safe` (it re-runs per row), so it never rides a pushdown regardless.
    case .exists, .within, .quantified: false
    case let .like(operand, pattern, escape, _):
      operand.parameterised || pattern.parameterised
          || (escape?.parameterised ?? false)
    case let .between(test, lower, upper, _):
      test.parameterised || lower.parameterised || upper.parameterised
    case let .truth(inner, _, _): inner.parameterised
    case let .and(lhs, rhs): lhs.parameterised || rhs.parameterised
    case let .or(lhs, rhs): lhs.parameterised || rhs.parameterised
    case let .not(operand): operand.parameterised
    }
  }

  /// This filter's PROVABLE two-valued truth INDEPENDENT of any row, binding,
  /// or subquery — `true` when it is always TRUE, `false` when always FALSE,
  /// and `nil` when it is not statically decidable (the CONSERVATIVE default).
  /// A `select` treats UNKNOWN as reject, so the optimiser folds only a
  /// definite `true` (drops the select) and never mistakes an undecidable
  /// filter for one.
  ///
  /// The ONLY provable leaf is a `compare(a, op, b)` over TWO `.constant`
  /// operands: it evaluates through the SAME `matches` three-valued primitive
  /// the executor uses, so a NULL-bearing constant compare is UNKNOWN
  /// (`matches` yields `nil`) and reports `nil` — NOT provably true and NOT
  /// provably false — so a `WHERE NULL = 1` is left filtering (correctly
  /// rejecting), never folded to true. Any other leaf reads a slot, a
  /// `:parameter`, or a
  /// subquery — `bound`, a `compare` with a non-constant term, `match`, `null`,
  /// `membership`, `like`, `between`, `distinct`, `exists`, `within`,
  /// `quantified` — so its truth is not known here and it reports `nil`. The
  /// connectives require BOTH operands to be DEFINITE: `and`/`or` report a
  /// definite result only when neither side is `nil` (an undecidable side makes
  /// the whole compound `nil`), `not` flips a definite operand, and `truth`
  /// maps a DEFINITE inner through `tested`. This is STRICTER than the Kleene
  /// dominance the executor uses (a `false` conjunct or `true` disjunct short-
  /// circuiting the other side): dominance is sound for COMBINING already-
  /// evaluated results, but `constant` licenses the optimiser to SKIP a filter
  /// entirely, and an undecidable operand reads row data and can THROW — so it
  /// must never be dropped, and its parent can never be a compile-time
  /// constant.
  internal var constant: Bool? {
    switch self {
    case let .compare(.constant(lhs), op, .constant(rhs)):
      // Both operands are constants: evaluate through the engine's own
      // three-valued `matches`. A NULL on either side is UNKNOWN (`nil`) — not
      // provably true and not provably false — so a NULL-bearing compare is
      // never folded.
      matches(lhs, op, rhs)
    // A comparison against a non-constant term reads a slot or `:parameter`;
    // its truth is not statically known. A row comparison and row `IN` are not
    // statically folded — CONSERVATIVE, matching `.membership`/`.between`.
    case .compare, .bound, .match, .null, .membership, .comparison,
         .memberships, .like, .between, .distinct, .exists, .within,
         .quantified:
      nil
    case let .and(lhs, rhs):
      // Both operands must be DEFINITE: a compile-time constant is only sound
      // for FOLDING when the fold skips no runtime work. An undecidable operand
      // reads row data and can THROW (e.g. `1 / X`), so it MUST be evaluated —
      // even a `false`/`true` sibling cannot license dropping it. The Kleene
      // dominance that lets `matches` short-circuit already-evaluated results
      // is UNSOUND here, where a definite `constant` authorises skipping the
      // evaluation.
      if let l = lhs.constant, let r = rhs.constant { l && r } else { nil }
    case let .or(lhs, rhs):
      // Both operands must be DEFINITE (see `.and`): a `true` disjunct cannot
      // license dropping an undecidable sibling that reads row data and may
      // throw — the parent is a compile-time constant only when both sides are.
      if let l = lhs.constant, let r = rhs.constant { l || r } else { nil }
    case let .not(operand):
      operand.constant.map { !$0 }
    case let .truth(inner, value, negated):
      // `IS <truth>` is a DEFINITE two-valued test, but only when the inner's
      // value is itself statically decided; an undecidable inner leaves `nil`.
      inner.constant == nil ? nil : tested(inner.constant, value, negated)
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
  /// Evaluates a SUBQUERY-FREE `term` against this row through `routines` — the
  /// entry point for a `CREATE FUNCTION` body (which cannot nest a subquery,
  /// see `NoCatalog`) and the unit choke points. It runs against `NoCatalog`,
  /// so a term that reached a scalar `.subquery` would fault; a subquery-free
  /// one never does.
  internal borrowing func evaluate(_ term: Term, _ routines: Routines,
                                   _ bindings: Bindings = [:])
      throws(SQLError) -> Value {
    try NoCatalog().evaluate(self, term,
                             Context(routines: routines, bindings: bindings))
  }
}

extension Catalog where Self: ~Escapable {
  /// Evaluates `term` against `row` through `routines`, yielding a typed value.
  ///
  /// A `slot` reads the row's cell; a `constant` is itself; an `apply` looks
  /// the function up in the routines (`SQLError.function` on a miss), evaluates
  /// its arguments, and applies it; a scalar `.subquery` materialises against
  /// this catalog LAZILY on first reach (memoised, so an unreachable arm never
  /// runs it). The `borrowing` row is non-escaping — a term runs over a
  /// materialised projection record or a predicate's borrowed cursor row.
  internal borrowing func evaluate(_ row: borrowing some Row & ~Escapable,
                                   _ term: Term, _ context: Context)
      throws(SQLError) -> Value {
    switch term {
    case let .slot(slot):
      row[slot]
    case let .parameter(name):
      // A correlated `:parameter` reads its value from the bindings — the
      // enclosing row's cell, merged in by the per-outer-row re-execution. An
      // unbound name reads `.null` (a comparison against it is UNKNOWN),
      // exactly as a `Filter.bound` operand resolves an absent parameter.
      context.bindings[name] ?? .null
    case let .constant(value):
      value
    case let .apply(name, arguments):
      try apply(row, name, arguments, context)
    case let .binary(op, lhs, rhs):
      try op.apply(evaluate(row, lhs, context), evaluate(row, rhs, context))
    case let .case(branches, otherwise, type):
      // Take the FIRST branch whose guard is three-valued TRUE (UNKNOWN and
      // FALSE skip); with none matching, the `else` term, or `NULL` when there
      // is none. The guard is a `Filter`, so it evaluates over the same row,
      // routines, bindings, and subquery results a `WHERE` filter does — a
      // `:parameter` guard resolves against the bindings, an UNKNOWN one does
      // not select its branch. The selected value is COERCED to the CASE's
      // unified result `type` so it matches the column type the schema
      // advertised. A scalar subquery in an UNREACHED arm is never evaluated,
      // so it never runs (never throws) — the lazy `.subquery` case honours it.
      try conditional(row, branches, otherwise, type, context)
    case let .cast(operand, type):
      // Evaluate the operand and CONVERT it to the target type: NULL casts to
      // NULL, an unconvertible value faults (`Value.cast(to:)`), never yielding
      // a wrong value.
      try evaluate(row, operand, context).cast(to: type)
    case let .coalesce(elements, type):
      try coalesce(row, elements, type, context)
    case let .nullif(lhs, rhs):
      try nullif(row, lhs, rhs, context)
    case let .subquery(key, correlation, type):
      // Materialise the scalar subquery LAZILY on this first reach — an
      // occurrence in a skipped `CASE`/`COALESCE` arm is never reached, so it
      // never runs (never throws). COERCE the collapsed value to the inner
      // column's type, as a `CASE` coerces its selected arm. An UNCORRELATED
      // one memoises; a CORRELATED one re-runs against this row's correlated
      // bindings.
      try scalar(row, key, correlation, type, context)
    }
  }

  /// The `bindings` extended with `correlation`'s outer cells — a `slot` entry
  /// bound to the cell at that packed ordinal of the IMMEDIATE enclosing `row`,
  /// a `bound` entry left as the incoming binding the CONTAINING subquery
  /// already threaded down (a NESTED correlation to a grandparent column) — the
  /// per-outer-row binding a CORRELATED subquery re-executes under. An
  /// UNCORRELATED occurrence has an empty correlation, so this returns the
  /// bindings unchanged.
  private borrowing func correlated(_ row: borrowing some Row & ~Escapable,
                                    _ correlation: Correlation,
                                    _ bindings: Bindings) -> Bindings {
    if correlation.isEmpty { return bindings }
    var extended = bindings
    for (name, source) in correlation {
      // A `bound` source is already in `bindings` (threaded by the containing
      // subquery), so it passes through unchanged; a `slot` reads this
      // subquery's immediate enclosing row, and a `coalesce` (a correlated
      // `NATURAL`/`USING` merged column) reads the FIRST non-NULL of its
      // constituent cells of that row — its ISO 7.10 merged value.
      switch source {
      case let .slot(slot):
        extended[name] = row[slot]
      case let .coalesce(slots, type):
        var value = Value.null
        for slot in slots {
          let cell = row[slot]
          if case .null = cell { continue }
          value = cell.coerced(to: type)
          break
        }
        extended[name] = value
      case .bound:
        break
      }
    }
    return extended
  }

  /// `context` re-scoped to the RECORDED revealed overlay of the occurrence
  /// `key`'s scope — the SAME revealed base (CTEs plus `definition_schema.`
  /// store relations, every enclosing SELECT's derived aliases STRIPPED) the
  /// occurrence's plan was COMPILED against. The run records it under the scope
  /// (`.caller` at the top level, `.view(name)` in a view body) as
  /// `revealed().relations`; scoping the EXECUTION context to it makes a
  /// re-executed body resolve its `FROM` identically to compile, so a body
  /// `.scan` binds the CTE compile chose rather than a caller derived alias of
  /// the same name the unrevealed execution overlay would carry. On a miss (no
  /// box recorded) it leaves the overlay unchanged.
  ///
  /// The predicate-subquery paths (`present`/`values`/`scalar`) and the LATERAL
  /// apply share this ONE seam, so the body plan a `Plan.apply` re-runs
  /// per left row resolves under the identical revealed overlay `lateral(_:
  /// against:_:)` used at compile — the FROM-clause and predicate correlation
  /// paths cannot diverge from it.
  private borrowing func revealed(under key: Subkey, _ context: Context)
      -> Context {
    context.scoping(context.subqueries.overlay(key.scope) ?? context.relations)
  }

  /// The rows a CORRELATED subquery occurrence `key` yields for `row` — the
  /// SINGLE augment-and-execute path every correlated caller (`present`,
  /// `values`, `scalar`) routes through, so none can skip the augmentation or
  /// the per-row overlay. It extends `bindings` with this row's correlated
  /// values, builds the execution context from the occurrence's scope overlay
  /// AUGMENTED with the subquery's OWN `WITH`/derived-table rows, looks up the
  /// PRE-COMPILED plan, and executes it.
  ///
  /// The precompiled plan resolves a `WITH` item or a derived table `d` — `FROM
  /// (SELECT …) AS d` — to a `.scan("d")` the executor binds by NAME from
  /// `context.relations`, so the rows must be MATERIALISED into the overlay
  /// first, exactly as the UNCORRELATED `run`/`probe`/`cell` path augments the
  /// query before running it. Without this the `.scan("d")` faults
  /// `SQLError.relation("d")` (or mis-binds an outer relation of the same
  /// name). Augmenting on top of the per-row overlay PRESERVES both the
  /// correlation bindings and the parent overlay: `augment` only ADDS this
  /// query's own aliases, and `validate: false` matches the lenient run path (a
  /// REACHED body operand still faults at execution).
  ///
  /// A SET OPERATION binds NO derived alias at the query level — its arms are
  /// SELECT-scoped, each `FROM (SELECT …) AS d` local to its own arm — so a
  /// whole-query augment misses them and an arm's `.scan("d")` would fault
  /// `.relation("d")`. When the plan is a set operation this descends the plan
  /// and query in lockstep and augments EACH ARM's own aliases before executing
  /// that arm's sub-plan, exactly as the run and view setop paths do, while the
  /// correlation bindings and parent overlay ride into every arm through the
  /// shared `context`.
  private borrowing func executed(_ row: borrowing some Row & ~Escapable,
                                  _ key: Subkey, _ correlation: Correlation,
                                  _ context: Context)
      throws(SQLError) -> Array<Record> {
    let bindings = correlated(row, correlation, context.bindings)
    let context = context.binding(bindings)
    // A REACHED correlated scalar/`IN`/quantified occurrence over a SET
    // OPERATION strictly re-folds its arms' column types before executing the
    // SHAPED (placeholder-typed) plan the pre-pass recorded — the pre-pass
    // compiles under `.shaping()`, so an irreconcilable pair was deferred to a
    // placeholder there; this seam runs `context` WITHOUT a shape, so the fold
    // faults `.operand`/42804 exactly as the uncorrelated `run` path does,
    // firing ONLY for reached occurrences (an unreachable one never calls
    // `executed`, so its shape deferral stands). Only a SET OPERATION has a
    // cross-arm fold to check — a plain `SELECT` subquery has no arms to unify,
    // and resolving its projection here would fault on its own correlated
    // columns (out of scope in this fold context) — so a non-setop query skips
    // it. `EXISTS`/`LATERAL` skip it too: `EXISTS` ignores column types and the
    // recorded probe is already the shape. The fold runs ONCE per occurrence —
    // memoised on the `Subkey` — so a reached incompatibility faults on the
    // FIRST reached outer row and later rows skip the redundant (pure) re-fold.
    if key.role == .scalar || key.role == .valued, case .setop = key.query,
        !context.subqueries.validated(key) {
      _ = try types(unifying: key.query, context)
      context.subqueries.validate(key)
    }
    guard let plan = context.subqueries.plan(key, correlation) else {
      throw .named("a correlated subquery plan was not compiled")
    }
    // A SET-OPERATION plan augments PER ARM (arm-local derived aliases the
    // query-level augment misses); a single plan augments the whole query once.
    if case .setop = plan {
      return try arms(plan, key.query, context)
    }
    let augmented =
        try augment(context.validating(false), for: key.query, rows: true)
    return try execute(plan, augmented)
  }

  /// The CROSS/OUTER APPLY of a LATERAL derived table: for each `left` record,
  /// re-executes the pre-compiled body (`key`/`correlation`) against that
  /// record's correlated cells, takes `ordinals` from each produced right
  /// record, concatenates it onto the left, and keeps the pair the `on`
  /// predicate admits. `.inner` (CROSS APPLY) DROPS a left record with no
  /// surviving right record; `.left` (OUTER APPLY) preserves it, NULL-extending
  /// the taken width (`ordinals.count` NULL cells) — the same NULL-padding a
  /// regular outer join's `outer(…)` uses for an unmatched row. A `.right` or
  /// `.full` apply makes no sense for a correlated body: rejected at compile.
  ///
  /// The lateral body runs through the SAME `executed` path a correlated
  /// subquery does — it binds the correlation's `slot` sources from the
  /// borrowed left `record`, augments the body's OWN aliases, and runs the
  /// pre-compiled plan — so the borrow is never retained: `executed` returns
  /// owned `Record`s, and the pair merges two owned records. The right record
  /// is the body's FULL output, so `ordinals` select the referenced columns
  /// into the combined space laid after the left's slots, exactly as a scan's
  /// referenced ordinals sit after the left in a `product`.
  ///
  /// A lateral derived table exposes the universal virtual `Id` column at its
  /// real `width` — its resolution schema is a `RelationInstance.schema()`, so
  /// a body reference `d.Id` puts the virtual ordinal `width` into `ordinals`.
  /// The `executed` body rows hold only the REAL columns (`0 ..< width`), so
  /// taking `right.values[width]` would trap. This wraps THIS left row's body
  /// output as a `RelationInstance` and materialises each right record through
  /// `RelationInstance.record`, so the virtual `Id` ordinal yields the 1-based
  /// row position within this left row's output — the SAME id derivation a
  /// non-lateral derived table's `record` produces — while a real ordinal reads
  /// its stored cell.
  internal borrowing func applied(_ left: Array<Record>, _ key: Subkey,
                                  _ correlation: Correlation,
                                  _ ordinals: Array<Int>, _ on: Filter,
                                  _ kind: Join.Kind, _ context: Context)
      throws(SQLError) -> Array<Record> {
    var records = Array<Record>()
    // Re-run the pre-compiled body under the SAME revealed overlay it was
    // COMPILED against — the occurrence scope's recorded revealed base — so a
    // body `FROM e` scans the CTE `e` compile chose, not a caller derived alias
    // `e` that shadows it in the UNREVEALED execution overlay. The `on`
    // predicate stays on the caller `context`: it is a caller-level join
    // predicate over the merged record's ordinals, and any subquery in it
    // scopes to its OWN recorded overlay.
    let body = revealed(under: key, context)
    // An unmatched left row under OUTER APPLY (`.left`) is NULL-extended by the
    // taken width, mirroring `outer(…)`'s NULL-padding of an unmatched row.
    let nulls = Record(Array(repeating: .null, count: ordinals.count))
    // A LATERAL/CROSS/OUTER apply always emits `ON 1 = 1` — a PROVABLY-true
    // predicate every merged row passes — so a constant-true `on` skips the
    // redundant per-row `evaluate(paired, on, context)` and admits the pair
    // directly (identical result). A non-trivial `on` still runs per row.
    let unconditional = on.constant == true
    for record in left {
      let right = try executed(record, key, correlation, body)
      let width = right.first?.values.count ?? 0
      let instance =
          RelationInstance(columns: Array(repeating: "", count: width),
                           rows: right.map(\.values),
                           types: Array(repeating: .integer, count: width))
      var matched = false
      for index in right.indices {
        let taken = instance.record(index, ordinals)
        let paired = record.merged(with: taken)
        let admits =
            try unconditional ? true : evaluate(paired, on, context) == true
        if admits {
          records.append(paired)
          matched = true
        }
      }
      if !matched && kind == .left {
        records.append(record.merged(with: nulls))
      }
    }
    return records
  }

  /// Executes a correlated subquery's SET-OPERATION `plan` arm by arm — the
  /// plan and its `query` descend in lockstep (compile builds `.setop(kind,
  /// compile(left), compile(right), all)` from `.setop(kind, left, right,
  /// all)`), a `.setop` node recursing into both arms and `combine`-ing the
  /// results and a LEAF arm augmenting THAT arm's own derived aliases into
  /// `context` (rows, so its `.scan` reads them) before executing its sub-plan.
  ///
  /// `context` already carries the per-row correlation bindings and the parent
  /// overlay, so each arm's augment ADDS only that arm's aliases and every arm
  /// runs under the same correlated bindings — mirroring the run and view setop
  /// per-arm augmentation for the correlated shape. Executing the arm sub-plans
  /// (not re-running the arm queries) preserves any pushed conjunct in the arm
  /// plan; `validate: false` keeps a data-dependent-empty arm body lenient, as
  /// the run path is.
  private borrowing func arms(_ plan: Plan, _ query: Query, _ context: Context)
      throws(SQLError) -> Array<Record> {
    if case let .setop(kind, left, right, all, types, _) = plan,
        case let .setop(_, leftQuery, rightQuery, _) = query {
      // The unified column `types` the plan carries (computed at compile) drive
      // the arm coercion `combine` applies — the SAME types every set-op path
      // uses, so a mixed-type arm widens identically here.
      return try combine(kind, arms(left, leftQuery, context),
                         arms(right, rightQuery, context), all, types: types)
    }
    let augmented =
        try augment(context.validating(false), for: query, rows: true)
    return try execute(plan, augmented)
  }

  /// The `EXISTS` non-empty result of the occurrence `key`, run LAZILY: an
  /// UNCORRELATED one (empty `correlation`) reads the memo and, on a miss,
  /// probes once and stores it; a CORRELATED one re-probes per outer row
  /// against the correlated bindings, never touching the memo.
  private borrowing func present(_ row: borrowing some Row & ~Escapable,
                                 _ key: Subkey, _ correlation: Correlation,
                                 _ context: Context)
      throws(SQLError) -> Bool {
    // Run under the overlay the occurrence's SCOPE was lowered under — the
    // caller's or the view body's — not the current execution site a pushdown
    // may have moved this predicate to.
    let context = revealed(under: key, context)
    // A CORRELATED EXISTS re-executes its PRE-COMPILED PROBE plan (correlated
    // columns are bound `Term.parameter`s; the plan is the cardinality-only
    // probed shape, so its select list — a would-fault `1 / 0` — never runs)
    // against this row's correlated bindings, testing non-empty — bypassing the
    // memo (the result depends on the row). An UNCORRELATED one memoises and
    // probes cardinality once, the SAME probed shape.
    guard correlation.isEmpty else {
      return try !executed(row, key, correlation, context).isEmpty
    }
    if let cached = context.subqueries.present(cached: key) { return cached }
    let present = try probe(key.query, context)
    context.subqueries.store(present: present, for: key)
    return present
  }

  /// The `IN (Q)` single column of the occurrence `key`, materialised LAZILY:
  /// an UNCORRELATED one reads the memo and, on a miss, runs the inner query
  /// once and stores its lone column; a CORRELATED one re-runs per outer row
  /// against the correlated bindings, bypassing the memo.
  private borrowing func values(_ row: borrowing some Row & ~Escapable,
                                _ key: Subkey, _ correlation: Correlation,
                                _ context: Context)
      throws(SQLError) -> Array<Value> {
    let context = revealed(under: key, context)
    // A CORRELATED `IN (Q)` re-executes its PRE-COMPILED inner plan against
    // this row's correlated bindings for its lone column, bypassing the memo.
    // An UNCORRELATED one memoises and re-runs its `Query` (recompiling
    // resolves).
    guard correlation.isEmpty else {
      return try executed(row, key, correlation, context).map { $0.values[0] }
    }
    if let cached = context.subqueries.values(cached: key) { return cached }
    let values = try run(key.query, context).map { $0[0] }
    context.subqueries.store(values: values, for: key)
    return values
  }

  /// The value of a scalar subquery occurrence `key`, materialised LAZILY and
  /// MEMOISED: on the first reach it runs the inner query ONCE (where this
  /// catalog is in scope) — empty → NULL, one row → its cell, more →
  /// `.cardinality`, plus any inner fault — collapsing to one value and caching
  /// it under `key`; a later reach returns the cached value WITHOUT re-running.
  ///
  /// The subquery is UNCORRELATED, so its value is row-invariant — one run per
  /// REACHED occurrence, none for one only in a skipped arm. The value is
  /// COERCED to the inner column's `type`, as a `CASE` coerces its taken arm.
  private borrowing func scalar(_ row: borrowing some Row & ~Escapable,
                                _ key: Subkey, _ correlation: Correlation,
                                _ type: ValueType, _ context: Context)
      throws(SQLError) -> Value {
    let context = revealed(under: key, context)
    // A CORRELATED scalar subquery re-executes its PRE-COMPILED inner plan per
    // outer row against the correlated bindings, collapsing to its lone cell
    // (empty → NULL, one row → the cell, more → `.cardinality`), bypassing the
    // memo (its cell depends on the row). An UNCORRELATED one memoises and
    // re-runs its `Query`.
    guard correlation.isEmpty else {
      let rows = try executed(row, key, correlation, context)
      guard rows.count <= 1 else { throw .cardinality }
      return (rows.first?.values.first ?? .null).coerced(to: type)
    }
    if let cached = context.subqueries.scalar(cached: key) {
      return cached.coerced(to: type)
    }
    let value = try cell(of: key.query, context)
    context.subqueries.store(scalar: value, for: key)
    return value.coerced(to: type)
  }

  /// Evaluates a lowered `COALESCE(v1, v2, …)` against `row` — the `elements`
  /// visited IN ORDER exactly ONCE, returning the first whose value is
  /// non-NULL (coerced to the unified `type` the schema advertises), else NULL.
  ///
  /// Each element is evaluated ONCE: a desugar to `CASE WHEN vi IS NOT NULL
  /// THEN vi …` evaluated each `vi` twice — its guard and its result — so a
  /// stateful element tested one value for NULL and returned another.
  /// `Value.coerced` widens the selected value to `type` (a `.integer` element
  /// of a `.double` COALESCE), exactly as a `CASE` coerces its taken branch;
  /// NULL passes unchanged.
  private borrowing func coalesce(_ row: borrowing some Row & ~Escapable,
                                  _ elements: Array<Term>, _ type: ValueType,
                                  _ context: Context)
      throws(SQLError) -> Value {
    for element in elements {
      let value = try evaluate(row, element, context)
      if case .null = value { continue }
      return value.coerced(to: type)
    }
    return .null
  }

  /// Evaluates a lowered `NULLIF(a, b)` against `row` — `a` and `b` each
  /// evaluated ONCE — returning NULL when `a = b` is TRUE, else the SAME `va`
  /// that was compared.
  ///
  /// A desugar to `CASE WHEN a = b THEN NULL ELSE a END` evaluated `a` twice —
  /// once in the equality and once as the `ELSE` — so a stateful `a` compared
  /// one value and returned another; holding `va` fixes that. `matches` is
  /// three-valued: only a definite TRUE equality nulls out, so an UNKNOWN (a
  /// NULL operand) yields `va`.
  private borrowing func nullif(_ row: borrowing some Row & ~Escapable,
                                _ lhs: Term, _ rhs: Term, _ context: Context)
      throws(SQLError) -> Value {
    let va = try evaluate(row, lhs, context)
    let vb = try evaluate(row, rhs, context)
    return matches(va, .equal, vb) == true ? .null : va
  }

  /// Evaluates a lowered `CASE` — its `branches` and optional `otherwise`
  /// term — against `row`, taking the first guard that is TRUE and coercing the
  /// selected value to the CASE's unified result `type`.
  ///
  /// The schema advertises the column as `type` — the unification of the branch
  /// result types — yet a branch yields its own raw `Value`, so a `.integer`
  /// arm of a CASE that unifies to `.double` must widen to match.
  /// `Value.coerced` performs that one widening; NULL and an already-matching
  /// value pass unchanged, so an all-same CASE (no widening) is untouched.
  private borrowing func conditional(_ row: borrowing some Row & ~Escapable,
                                     _ branches: Array<(Filter, Term)>,
                                     _ otherwise: Term?, _ type: ValueType,
                                     _ context: Context)
      throws(SQLError) -> Value {
    for (gate, result) in branches {
      if try evaluate(row, gate, context) == true {
        return try evaluate(row, result, context).coerced(to: type)
      }
    }
    guard let otherwise else { return .null }
    return try evaluate(row, otherwise, context).coerced(to: type)
  }

  /// Resolves `name` in `routines` and applies it to its `arguments` evaluated
  /// against `row`.
  ///
  /// This run-path dispatch checks a routine EXISTS — an unregistered `name`
  /// faults `SQLError.function` — but does NOT validate the call's ARITY or
  /// its argument TYPES: it evaluates the supplied `arguments` and hands them
  /// to the routine. That is deliberate. A run assumes the statement was
  /// already type-checked; `columns(of:validate:)` (via `Scope.call`) is the
  /// STRICT gate that faults `SQLError.argument` on a wrong argument count or a
  /// definitively-wrong argument type, so a caller wanting arity/type
  /// enforcement validates FIRST and a run trusts that check. The engine's own
  /// routines self-check inside their closures (a native `BITAND` faults on a
  /// bad count, a `.defined` body enforces its arity/types in
  /// `callAsFunction`), so a mis-shaped call over them still faults; but a host
  /// routine that does NOT self-check its count runs regardless at this site.
  /// See `RoutineArityPostureTests`, which pins the run/validate split. (The
  /// one value the run DOES enforce here is the finite-double invariant below,
  /// which no static type-check can see.)
  private borrowing func apply(_ row: borrowing some Row & ~Escapable,
                               _ name: String, _ arguments: Array<Term>,
                               _ context: Context)
      throws(SQLError) -> Value {
    guard let routine = context.routines[name] else {
      throw .function(name)
    }
    var values = Array<Value>()
    values.reserveCapacity(arguments.count)
    for argument in arguments {
      try values.append(evaluate(row, argument, context))
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

/// Whether two typed values DIFFER under ISO `IS DISTINCT FROM` — the null-safe
/// comparison, treating NULL as a comparable value. Unlike `matches`, it is
/// TWO-VALUED (never UNKNOWN): two NULLs are the SAME (not DISTINCT), exactly
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
/// two ALREADY-EVALUATED rows of EQUAL, non-empty arity — the shared fold both
/// the runtime (`Filter.comparison`) and the empty-group pre-fold drive so the
/// two agree by construction.
///
/// `=` is the Kleene `AND` of the componentwise `matches(l[i], =, r[i])` (FALSE
/// dominating — short-circuited), `<>` its negation (UNKNOWN mapping to
/// itself), and the four ordering operators the lexicographic cascade `l0 <op>
/// r0 OR (l0 = r0 AND (l1 <op> r1 OR …))`, right-nested from the last component
/// inward — the innermost step carrying `op` itself (so `<=`/`>=` admit an
/// all-equal row), every earlier step the STRICT operator (`<`/`>`) tie-guarded
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
/// `Truth` value, negated for `IS NOT`, yielding a DEFINITE two-valued result
/// that is NEVER itself UNKNOWN. `p IS TRUE` is `operand == true`, `IS FALSE`
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
  /// Evaluates a SUBQUERY-FREE `filter` against this row under three-valued
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
      // The DEFINITE two-valued `EXISTS` non-empty test — never UNKNOWN,
      // `negated` flipping it. The subquery runs LAZILY on this first reach (so
      // an `EXISTS` a short-circuited `AND`/`OR` or an unreached `CASE` arm
      // guards never runs): an UNCORRELATED one memoises under its `Subkey`; a
      // CORRELATED one re-runs against this row's correlated bindings,
      // bypassing the memo.
      try present(row, key, correlation, context) != negated
    case let .within(operand, key, correlation, negated):
      // Fold `operand = v` over the subquery's single column under the SAME
      // three-valued membership the value-list `IN` uses. The column is
      // materialised LAZILY on this first reach (an UNCORRELATED one memoised,
      // a CORRELATED one re-run per row against this row's correlated
      // bindings).
      try member(row, operand, values(row, key, correlation, context),
                 negated, context)
    case let .quantified(operand, op, quantifier, key, correlation):
      // Fold `operand op v` over the subquery's single column with the SAME
      // `matches`/Kleene primitives `within` uses — Kleene `OR` (seeded FALSE)
      // for `any`, Kleene `AND` (seeded TRUE) for `all`. It materialises its
      // lone column LAZILY through the SAME `values` path `within` drives: an
      // UNCORRELATED one memoises under its `Subkey`, a CORRELATED one re-runs
      // its inner plan per outer row against this row's correlated bindings.
      try quantified(row, operand, op, quantifier,
                     values(row, key, correlation, context), context)
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
  /// The `operand` is evaluated ONCE per row — an OR-chain of `compare`s would
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

  /// Evaluates a lowered `operand [NOT] IN (Q)` against `row` over the
  /// subquery's ALREADY-MATERIALISED single column `values`.
  ///
  /// It is the value-list `member` fold over constants: the `operand` is
  /// evaluated ONCE per row, then `operand = v` folds over the materialised
  /// `values` IN ORDER under Kleene `OR`, seeded FALSE and short-circuiting at
  /// the first TRUE — so a NULL operand or a NULL element keeps the ISO
  /// three-valued result (an unmatched test is UNKNOWN, not FALSE), an EMPTY
  /// `values` folds FALSE (no witness), and `NOT IN` negates that truth,
  /// mapping UNKNOWN to itself. It reuses the SAME `matches`/`or` primitives
  /// the value-list `IN` does, so the two forms share one three-valued core.
  private borrowing func member(_ row: borrowing some Row & ~Escapable,
                                _ operand: Term, _ values: Array<Value>,
                                _ negated: Bool, _ context: Context)
      throws(SQLError) -> Bool? {
    let value = try evaluate(row, operand, context)
    var truth: Bool? = false
    for element in values {
      truth = or(truth, matches(value, .equal, element))
      if truth == true { break }
    }
    return negated ? truth.map { !$0 } : truth
  }

  /// Evaluates a lowered `(l…) <op> (r…)` row-value comparison against `row`.
  ///
  /// Each side is evaluated exactly ONCE per row into a `[Value]` — a desugar
  /// to a conjunction/cascade of scalar `compare`s re-evaluated a component
  /// once per place it appeared, so a stateful component yielded a different
  /// value each time — then the two rows fold through the shared `relate`
  /// primitive, which reproduces the ISO three-valued truth with the SAME
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
  /// The left row is evaluated ONCE per row into a `[Value]` — as a scalar
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

  /// Evaluates a lowered `operand op {ANY | ALL} (Q)` against `row` over the
  /// subquery's ALREADY-MATERIALISED single column `values`.
  ///
  /// The `operand` is evaluated ONCE per row, then `operand op v` folds over
  /// the materialised `values` IN ORDER with the SAME `matches`/Kleene
  /// primitives the value-list and `IN (Q)` `member` folds use — Kleene `OR`
  /// seeded FALSE for `any` (short-circuiting at the first TRUE), Kleene `AND`
  /// seeded TRUE for `all` (short-circuiting at the first FALSE). So a NULL
  /// `operand` or a NULL element makes an otherwise-undecided fold UNKNOWN (not
  /// FALSE), an EMPTY `values` takes the seed — `any` FALSE (no witness), `all`
  /// TRUE (vacuous) — and the identity falls out of the fold rather than a
  /// special case. `= ANY` reduces to the `member` `IN` fold and `<> ALL` to
  /// its negation, sharing one three-valued core with `within`.
  private borrowing func quantified(_ row: borrowing some Row & ~Escapable,
                                    _ operand: Term, _ op: Comparison,
                                    _ quantifier: Quantifier,
                                    _ values: Array<Value>, _ context: Context)
      throws(SQLError) -> Bool? {
    let value = try evaluate(row, operand, context)
    var truth: Bool? = quantifier == .any ? false : true
    for element in values {
      let matched = matches(value, op, element)
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
  /// The `test` term is evaluated ONCE per row — an `AND`/`OR` of two
  /// comparisons would re-evaluate a non-idempotent test once per bound — then
  /// the two bounds fold against that SAME value under Kleene logic as `test >=
  /// lower AND test <= upper`. `NOT BETWEEN` is the NEGATION of that same
  /// truth, NOT the `test < lower OR test > upper` expansion: with a cross-kind
  /// bound `matches` yields FALSE for EVERY ordering operator (so `test <
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
  /// It is the ISO null-safe comparison — TWO-VALUED, never UNKNOWN — treating
  /// NULL as a comparable value: `distinct` yields whether the two operand
  /// values DIFFER (both NULL are the SAME, exactly one NULL DIFFERS, two
  /// non-NULLs DIFFER unless equal, a cross-kind pair DIFFERS). `IS DISTINCT
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
  private borrowing func like(_ row: borrowing some Row & ~Escapable,
                              _ operand: Term, _ pattern: Filter.Operand,
                              _ escape: Filter.Operand?, _ negated: Bool,
                              _ context: Context)
      throws(SQLError) -> Bool? {
    // Evaluate all three reached operands once, in order — a fault in any of
    // them (a divide, an overflow) propagates HERE, before the NULL/escape
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
