// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// One `WHEN predicate THEN result` branch of a `CASE` expression — the guard
/// and the value it yields when the guard is the first TRUE one.
public struct When: Hashable, Sendable {
  /// The guard predicate — TRUE selects this branch (UNKNOWN and FALSE skip
  /// it). A simple `CASE`'s `WHEN value` is normalised to the equality `operand
  /// = value` here.
  public let when: Predicate

  /// The result expression this branch yields when its guard is the first TRUE.
  public let then: Expression

  public init(when: Predicate, then: Expression) {
    self.when = when
    self.then = then
  }
}

/// A standard SQL aggregate function.
///
/// The engine recognises this fixed set by name (case-insensitively) at parse
/// time, distinct from a scalar-function `call`. `COUNT` counts rows (or
/// non-NULL values); `SUM`/`AVG` total and average the non-NULL integers;
/// `MIN`/`MAX` take the least/greatest non-NULL value by the engine's typed
/// comparison.
public enum Aggregate: Hashable, Sendable {
  /// `COUNT` — the number of rows (`*`) or of non-NULL values.
  case count
  /// `SUM` — the total of the non-NULL integer values.
  case sum
  /// `MIN` — the least non-NULL value.
  case min
  /// `MAX` — the greatest non-NULL value.
  case max
  /// `AVG` — the average of the non-NULL integer values.
  case avg
}

/// An aggregate's operand: `*` (rows), valid only for `COUNT`, or a scalar
/// expression evaluated per row and aggregated over the group.
public enum Aggregand: Hashable, Sendable {
  /// `*` — the whole row, the operand of `COUNT(*)`. It counts every row of the
  /// group, NULLs included, so it is admitted only for `COUNT`.
  case star
  /// An expression evaluated per row; the aggregate folds its non-NULL values
  /// over the group.
  case expression(Expression)
}

/// A binary operator over two scalar operands.
///
/// The four standard arithmetic operators over numbers, and the ISO `||`
/// string concatenation. `*` `/` bind tighter than `+` `-` `||`, and every
/// operator is left-associative — the precedence the parser's climbing grammar
/// encodes and parentheses override. The four arithmetic operators require
/// numeric operands; `||` requires text operands. All propagate NULL.
public enum Arithmetic: Hashable, Sendable {
  /// `+`
  case add
  /// `-`
  case subtract
  /// `*`
  case multiply
  /// `/` — integer division.
  case divide
  /// `||` — text concatenation. It joins two text operands into one text value
  /// and propagates NULL (a NULL operand yields NULL); a non-text operand is a
  /// `SQLError.operand` type error, as arithmetic faults on a non-numeric one.
  case concatenate
}

/// A row filter — a tree of comparisons composed with `AND`, `OR`, and `NOT`.
///
/// The tree is `data`, not an opaque closure, so a consumer may inspect it (for
/// example to lower an equality test on a sorted column to a binary search).
public indirect enum Predicate: Hashable, Sendable {
  /// `left <op> right` — each operand a scalar `Expression` (a column, a
  /// literal, or a call to a registered scalar function).
  case comparison(left: Expression, op: Comparison, right: Expression)
  /// `left <op> :parameter` — the left a scalar `Expression`, the operand
  /// resolved at run time from the engine's bindings (the correlated-subquery
  /// primitive a child view keys on the parent's value).
  case bound(left: Expression, op: Comparison, parameter: String)
  /// `operand IS NULL`, or `IS NOT NULL` when `negated` — a definite test of
  /// whether the operand evaluates to `NULL` (never itself UNKNOWN), the way a
  /// nullable column — an absent decoded attribute — is filtered (`WHERE iid IS
  /// NOT NULL`).
  case null(Expression, negated: Bool)
  /// `operand IN (v, …)`, or `NOT IN` when `negated` — whether the operand
  /// equals any value of the non-empty `values` list. It is ISO shorthand for a
  /// disjunction of equalities under three-valued logic: `x IN (a, b)` is `x =
  /// a OR x = b`, so a NULL operand or a NULL element makes an
  /// otherwise-unmatched test UNKNOWN rather than FALSE, and `NOT IN` is the
  /// negation of that (never TRUE when a NULL element is present). The engine
  /// lowers it to that disjunction rather than carrying a dedicated `Filter`
  /// case.
  case membership(Expression, Array<Expression>, negated: Bool)
  /// `(l1, …, ln) <op> (r1, …, rn)` — an ISO `<row value constructor>`
  /// comparison, both sides a row of scalar `Expression`s of EQUAL arity
  /// (`SQLError.arity` at compile otherwise), `op` any of the six operators. It
  /// is a FIRST-CLASS node rather than a parse-time desugar to a
  /// conjunction/cascade of scalar comparisons so that each component
  /// `Expression` is evaluated EXACTLY ONCE: the desugar duplicated a component
  /// across the places it appears (a `<` cascade names an earlier component in
  /// both a strict step and an equality tie-guard), so a stateful component
  /// yielded a different value each time. It keeps the ISO three-valued
  /// semantics — `=` the conjunction of the componentwise equalities, `<>` its
  /// negation, the ordering operators the lexicographic cascade — lowered to a
  /// `Filter.comparison` the runtime evaluates once-per-component.
  case rows(Array<Expression>, Comparison, Array<Expression>)
  /// `(l1, …, ln) [NOT] IN ((r1, …, rn), …)` — an ISO row-value membership, the
  /// left a `<row value constructor>` and the right a non-empty list of element
  /// rows, each of EQUAL arity (`SQLError.arity` otherwise), `negated` marking
  /// `NOT IN`. As `rows`, it is a FIRST-CLASS node rather than a desugar to an
  /// OR-chain of row equalities so the left components are evaluated EXACTLY
  /// ONCE rather than once per element row. It keeps the value-list `IN`'s
  /// three-valued semantics — a disjunction of row equalities under Kleene
  /// `OR`, a NULL component making an unmatched test UNKNOWN, `NOT IN` its
  /// negation — lowered to a `Filter.memberships`.
  case among(Array<Expression>, Array<Array<Expression>>, negated: Bool)
  /// `operand [NOT] LIKE pattern [ESCAPE escape]` — whether the operand's text
  /// matches the pattern, in which `%` matches any sequence of characters
  /// (including the empty one) and `_` matches exactly one character; every
  /// other pattern character matches itself. An optional `ESCAPE escape` names
  /// a one-character escape whose following `%`, `_`, or escape character
  /// matches that literal character. It is three-valued: a NULL operand, a NULL
  /// pattern, or a NULL escape makes the result UNKNOWN, and `negated` (`NOT
  /// LIKE`) negates the three-valued result (UNKNOWN maps to itself). A
  /// non-text operand or pattern does not match — the engine's cross-kind
  /// comparison rule — so a run yields FALSE without faulting. The pattern and
  /// escape are each an `Operand` — an ordinary scalar expression or a run-time
  /// `:parameter` resolved from the engine's bindings — so a caller can bind a
  /// pattern (`Name LIKE :pattern`) rather than interpolate it.
  case like(Expression, pattern: Operand, escape: Operand?, negated: Bool)
  /// `x [NOT] BETWEEN a AND b` — whether `x` is within the inclusive range
  /// `[a, b]`, or outside it when `negated`. The ISO definition is `x >= a AND
  /// x <= b` (and `x < a OR x > b` negated), but it is a FIRST-CLASS node
  /// rather than that expansion so the test expression `x` is evaluated EXACTLY
  /// ONCE: the desugar duplicated `x` across both bound comparisons, testing a
  /// stateful `x`'s lower bound with one call and its upper with another. It
  /// keeps the ISO three-valued semantics — a NULL `x`, `a`, or `b` makes a
  /// bound UNKNOWN, excluding the row. Each bound `a` and `b` is an `Operand` —
  /// an ordinary scalar expression or a run-time `:parameter` resolved from the
  /// bindings (`x BETWEEN :lo AND :hi`) — the same binding the comparison and
  /// `LIKE` arms accept, so a caller can bind a range rather than interpolate
  /// it.
  case between(Expression, Operand, Operand, negated: Bool)
  /// `a IS [NOT] DISTINCT FROM b` — the ISO null-safe comparison of `a` and
  /// `b`, `negated` marking the `IS NOT DISTINCT FROM` (null-safe equality)
  /// spelling. It is TWO-VALUED — never UNKNOWN — treating NULL as a comparable
  /// value: `a IS DISTINCT FROM b` is FALSE iff both are NULL, or both are
  /// non-NULL and equal, and TRUE otherwise (exactly one NULL, or both non-NULL
  /// and unequal). `IS NOT DISTINCT FROM` is its negation. A cross-kind pair is
  /// DISTINCT — the two differ — matching the engine's cross-kind FALSE
  /// equality. Unlike `=`, a NULL operand never makes the row UNKNOWN.
  case distinct(Expression, Expression, negated: Bool)
  /// `[NOT] EXISTS (Q)` — whether the subquery `Q` yields at least one row,
  /// `negated` marking `NOT EXISTS`. It is DEFINITELY two-valued — never
  /// UNKNOWN — even when `Q` produces NULL-valued rows: the presence of a row
  /// is TRUE regardless of its values, so `EXISTS` tests cardinality alone. In
  /// this first slice `Q` is UNCORRELATED — it names no column of the enclosing
  /// query — so the engine materialises it ONCE (as a common table expression's
  /// body is materialised) and the whole predicate is the definite non-empty
  /// test of that result; `negated` flips it. `Predicate` is `indirect`, so it
  /// nests the whole `Query` without boxing.
  case exists(Query, negated: Bool)
  /// `x [NOT] IN (Q)` — whether the operand `x` equals any value the subquery
  /// `Q` yields, `negated` marking `NOT IN`. `Q` must project exactly ONE
  /// column (else `SQLError.arity`); the predicate is the three-valued
  /// membership of `x` in that column, exactly as the value-list `membership`
  /// is — a NULL `x` or a NULL element makes an otherwise-unmatched test
  /// UNKNOWN rather than FALSE, and `NOT IN` its negation (never TRUE when a
  /// NULL element is present), while an EMPTY result is FALSE (TRUE negated).
  /// In this first slice `Q` is UNCORRELATED (it names no enclosing column), so
  /// the engine materialises it ONCE and folds `x = v` over the materialised
  /// column under Kleene `OR`, the SAME three-valued core the value-list `IN`
  /// uses.
  case within(Expression, Query, negated: Bool)
  /// `x op {ANY | SOME | ALL} (Q)` — a QUANTIFIED comparison, whether `x op v`
  /// holds for at least one (`ANY`/`SOME`) or every (`ALL`) value `v` the
  /// subquery `Q` yields, `op` any of `= <> < <= > >=`. `Q` must project
  /// exactly ONE column (else `SQLError.arity`). It is three-valued exactly as
  /// `within` (`IN`) is — reusing the SAME `matches` comparison and Kleene
  /// combine — folding `x op v` over `Q`'s column under Kleene `OR` for `any`
  /// (TRUE at the first TRUE, else UNKNOWN if any comparison is UNKNOWN through
  /// a NULL `x` or element, else FALSE) and under Kleene `AND` for `all` (FALSE
  /// at the first FALSE, else UNKNOWN if any is UNKNOWN, else TRUE). An EMPTY
  /// `Q` takes the fold's identity — `any` FALSE (no witness), `all` TRUE
  /// (vacuous). `= ANY` is `IN` and `<> ALL` is `NOT IN`, but the case is kept
  /// distinct for the general operator. `SOME` is a synonym for `ANY`,
  /// normalised to `any` at parse time. In this slice `Q` is UNCORRELATED — it
  /// names no column of the enclosing query — so the engine materialises it
  /// ONCE (as `within` does) and folds over that single column; correlation is
  /// a later slice.
  case quantified(Expression, Comparison, Quantifier, Query)
  /// `p IS [NOT] <truth value>` — the ISO `<boolean test>`, whether the inner
  /// boolean `Predicate` `p`'s THREE-VALUED result equals the `value`
  /// (`TRUE`/`FALSE`/`UNKNOWN`), or does not when `negated`. Unlike the other
  /// predicates the result is DEFINITE two-valued — never itself UNKNOWN — so
  /// `p IS TRUE` is FALSE (not UNKNOWN) for an UNKNOWN `p`, and `p IS UNKNOWN`
  /// TESTS for that UNKNOWN. The operand is a `Predicate` rather than an
  /// `Expression`: a boolean is a predicate to this engine — a bare boolean
  /// operand `x` bridges as the comparison `x = TRUE`, whose three-valued
  /// truth IS `x`'s boolean value (`NULL` yielding UNKNOWN) — so a boolean
  /// column (`flag IS TRUE`) and a parenthesised comparison (`(a > b) IS TRUE`)
  /// share the one inner-predicate form and reuse the whole comparison
  /// machinery to evaluate it.
  case truth(Predicate, value: Truth, negated: Bool)
  /// `lhs AND rhs`.
  case and(Predicate, Predicate)
  /// `lhs OR rhs`.
  case or(Predicate, Predicate)
  /// `NOT operand`.
  case not(Predicate)

  /// The pattern or escape operand of a `LIKE` predicate: either an ordinary
  /// scalar `Expression` (a literal, a column, or a call, evaluated per row) or
  /// a run-time `:parameter` (a name resolved from the engine's bindings, the
  /// same mechanism `Predicate.bound` uses for a comparison's right operand).
  ///
  /// SQL's grammar admits only an expression here, but a `:parameter` is not an
  /// expression token — it is consumed by the comparison arm — so LIKE carries
  /// its bindable operands through this dedicated form rather than widening
  /// every expression walk with a parameter case. An unbound parameter, or one
  /// bound to `NULL`, makes the LIKE UNKNOWN, as a `NULL` pattern or escape
  /// does.
  public enum Operand: Hashable, Sendable {
    /// An ordinary scalar expression, evaluated per row.
    case expression(Expression)
    /// A `:parameter` placeholder, resolved at run time from the bindings.
    case parameter(String)
  }
}

/// A truth value a `<boolean test>` (`Predicate.truth`) tests against — the
/// three SQL truth values, `UNKNOWN` being the spelling the test uses for a
/// NULL boolean (SQL spells UNKNOWN as `NULL` in a value position, but names it
/// `UNKNOWN` in this test). `p IS TRUE`/`FALSE`/`UNKNOWN` yields a DEFINITE
/// two-valued result, never itself UNKNOWN.
public enum Truth: Hashable, Sendable {
  /// The truth value `TRUE`.
  case `true`
  /// The truth value `FALSE`.
  case `false`
  /// The truth value `UNKNOWN` — a NULL boolean.
  case unknown
}

/// The quantifier of a quantified comparison subquery `x op {ANY|ALL} (Q)`.
///
/// `ANY` (and its synonym `SOME`, normalised to `any` at parse time) holds when
/// `x op v` is TRUE for AT LEAST ONE value `v` the subquery yields; `ALL` holds
/// when it is TRUE for EVERY value. Both are three-valued over NULLs and take
/// the empty-set identity of their Kleene fold — `ANY` over no rows is FALSE
/// (OR's identity), `ALL` over no rows is TRUE (AND's identity). `x = ANY (Q)`
/// is the `IN (Q)` special case and `x <> ALL (Q)` the `NOT IN (Q)` one, but
/// the general operator makes `< ANY`, `>= ALL`, and the rest first-class.
public enum Quantifier: Hashable, Sendable {
  /// `ANY` (or `SOME`) — TRUE for at least one subquery value.
  case any
  /// `ALL` — TRUE for every subquery value.
  case all
}

/// A comparison operator.
public enum Comparison: Hashable, Sendable {
  /// `=`
  case equal
  /// `<>`
  case unequal
  /// `<`
  case lt
  /// `>`
  case gt
  /// `<=`
  case leq
  /// `>=`
  case geq
}

/// A literal operand of a comparison.
public enum Literal: Hashable, Sendable {
  /// A single-quoted string literal, with its escapes resolved.
  case string(String)
  /// An integer literal — a bare run of digits, exact numeric.
  case integer(Int)
  /// An approximate-numeric literal — a decimal with a `.` fraction and/or an
  /// exponent (`3.14`, `1.0`, `1e3`, `2.5e-1`), a binary64 `Double`.
  case double(Double)
  /// A truth-valued literal — the keyword `TRUE` or `FALSE`. SQL's third truth
  /// value UNKNOWN is spelled `NULL`, not a literal here.
  case boolean(Bool)
  /// A binary-string literal — a hex `x'…'` run of byte pairs, its bytes taken
  /// verbatim.
  case blob(Array<UInt8>)
}
