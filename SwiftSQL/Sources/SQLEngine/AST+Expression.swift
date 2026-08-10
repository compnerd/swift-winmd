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

/// A window function — a function evaluated over a window of rows without
/// collapsing them, so each input row keeps its identity and gains the
/// function's value for its position in the window.
///
/// Unlike an aggregate — which folds a group to one row — a window function is
/// cardinality-preserving: `ROW_NUMBER() OVER (ORDER BY x)` numbers every row
/// rather than reducing the rows to one. The engine recognises this fixed set
/// by name at parse time, each requiring an `OVER` clause, distinct from both
/// an aggregate and a scalar `call`.
public enum WindowFunction: Hashable, Sendable {
  /// `ROW_NUMBER()` — the 1-based sequential number of the row within its
  /// partition, in the window's order; distinct for every row of the partition
  /// even where the order keys tie.
  case number
  /// `RANK()` — the 1-based rank of the row within its partition: peer rows
  /// (equal on the window's order keys) share a rank, and the next distinct row
  /// takes the rank one past the peers already seen, so ranks skip after a tie.
  case rank
  /// `DENSE_RANK()` — like `RANK`, but the ranks are dense: the next distinct
  /// row after a tie takes the immediately following rank, leaving no gap.
  case dense
  /// A standard aggregate computed over the window frame rather than folded to
  /// one row — `SUM(x) OVER (…)`, `COUNT(*) OVER (…)`, `AVG`/`MIN`/`MAX` — so
  /// each row keeps its identity and gains the aggregate over its frame. It
  /// carries the same operand shape a collapsing aggregate does: the aggregate,
  /// its `*`-or-expression operand, the `DISTINCT` set quantifier, and an
  /// optional `FILTER (WHERE …)` gate; the frame is the window default (with no
  /// `ORDER BY` the whole partition, with one the running rows up to the
  /// current peer group).
  case aggregate(Aggregate, of: Aggregand, distinct: Bool = false,
                 filter: Predicate? = nil)
  /// `LEAD(value [, offset [, default]]) OVER (…)` — the `value` expression
  /// evaluated at the row `offset` positions after the current row in the
  /// window order (`offset` defaulting to `1`); when that row falls past the
  /// partition end, the `default` expression (or `NULL` when none is written).
  /// It requires a window `ORDER BY` — the offset is meaningless without a row
  /// order.
  case lead(Expression, offset: Int = 1, default: Expression? = nil)
  /// `LAG(value [, offset [, default]]) OVER (…)` — the mirror of `LEAD`,
  /// reading the row `offset` positions before the current row; `default` (or
  /// `NULL`) when that row falls before the partition start. It requires a
  /// window `ORDER BY`.
  case lag(Expression, offset: Int = 1, default: Expression? = nil)
  /// `FIRST_VALUE(value) OVER (…)` — the `value` expression evaluated at the
  /// first row of the window frame. It is frame-sensitive: over the default
  /// frame (the partition start through the current peer group) the first row
  /// is the partition's first in window order.
  case first(Expression)
  /// `LAST_VALUE(value) OVER (…)` — the `value` at the last row of the frame.
  /// Over the default frame the last row is the current row's peer group end
  /// (the current row itself with distinct order keys) — not the partition's
  /// last row — the classic frame-sensitivity gotcha.
  case last(Expression)
  /// `NTH_VALUE(value, n) OVER (…)` — the `value` at the `n`-th row (1-based)
  /// of the frame, or `NULL` when the frame holds fewer than `n` rows.
  case nth(Expression, Int)
  /// `NTILE(n) OVER (…)` — the 1-based number of the bucket the row falls in
  /// when the ordered partition is split into `n` buckets as equally as
  /// possible (the first `rows mod n` buckets one row larger). A whole-number
  /// distribution, so it types `.integer`.
  case ntile(Int)
  /// `PERCENT_RANK() OVER (…)` — the relative rank `(rank - 1) / (rows - 1)` in
  /// `[0, 1]` (`0` for a single-row partition), where `rank` is the `RANK`
  /// value. An approximate-numeric ratio, so it types `.double`.
  case percent
  /// `CUME_DIST() OVER (…)` — the cumulative distribution `rows up to and
  /// including the current peer group / rows`, in `(0, 1]`. An
  /// approximate-numeric ratio, so it types `.double`.
  case cumulative
}

extension WindowFunction {
  /// The value expression and optional default of a positional window function
  /// (`LEAD`/`LAG`, `FIRST_VALUE`/`LAST_VALUE`/`NTH_VALUE`), or `nil` for a
  /// ranking or aggregate window. The structural walks descend these exactly as
  /// they descend an aggregate window's operand, so a subquery or unregistered
  /// call nested in either is seen; a positional function types as its value.
  internal var positional: (value: Expression, default: Expression?)? {
    switch self {
    case let .lead(value, _, fallback), let .lag(value, _, fallback):
      (value, fallback)
    case let .first(value), let .last(value),
         let .nth(value, _):
      (value, nil)
    case .number, .rank, .dense, .aggregate,
         .ntile, .percent, .cumulative:
      nil
    }
  }

  /// Whether an explicit window frame governs this function's result — an
  /// aggregate window folds over its frame, and `FIRST_VALUE`/`LAST_VALUE`/
  /// `NTH_VALUE` read a row of it. A ranking function reads its whole-partition
  /// position, and `LEAD`/`LAG` read a fixed offset along the order, so neither
  /// takes a frame.
  internal var frameable: Bool {
    switch self {
    case .aggregate, .first, .last, .nth:
      true
    case .number, .rank, .dense, .lead, .lag,
         .ntile, .percent, .cumulative:
      false
    }
  }
}

/// A window specification — the `OVER (…)` clause governing a window function:
/// how the rows are partitioned and, within a partition, ordered.
///
/// `partition` are the `PARTITION BY` keys splitting the rows into independent
/// partitions the function folds over (empty when no `PARTITION BY` is written
/// — the whole input is one partition). `order` is the window's `ORDER BY`,
/// fixing the row order the ranking functions read (`nil` when none is
/// written).
public struct WindowSpec: Hashable, Sendable {
  /// The name of a `WINDOW` clause window this specification references
  /// (`OVER w`, `OVER (w …)`), or `nil` for an inline specification naming no
  /// base. It is resolved to the named window's specification by the
  /// `Query.expanded` prelude before any structural walk descends it, so a
  /// reference and the inline form resolve identically.
  public let base: String?

  /// Whether this is a parenthesized in-line specification that references a
  /// base (`OVER (w)`, `OVER (w …)`, or a `WINDOW name AS (…)` definition)
  /// rather than a bare window-name reference (`OVER w`). ISO 9075 splits a
  /// bare `<window name>`, which uses the named window wholesale (frame
  /// included), from an `<in-line window specification>` `(w …)`, which copies
  /// the named window and so cannot copy a framed one — even `OVER (w)` adding
  /// nothing. It defaults to `false`, so a programmatic `WindowSpec(base: "w")`
  /// is the wholesale bare form; the parser passes `true` for a parenthesized
  /// spec. It matters only with a `base`, so a base-less spec normalizes to
  /// `false` — its value never distinguishes two otherwise-equal specs.
  public let parenthesized: Bool

  /// The `PARTITION BY` keys — the rows split into one partition per distinct
  /// key combination — empty when no `PARTITION BY` is written.
  public let partition: Array<Expression>

  /// The window's `ORDER BY`, or `nil` when none is written.
  public let order: Order?

  /// The explicit window frame (`ROWS`/`RANGE`/`GROUPS BETWEEN … AND …`), or
  /// `nil` when none is written — the default frame then applies (the whole
  /// partition with no `ORDER BY`, the running `RANGE UNBOUNDED PRECEDING`
  /// through the current peer group with one).
  public let frame: Frame?

  public init(base: String? = nil, parenthesized: Bool = false,
              partition: Array<Expression> = [], order: Order? = nil,
              frame: Frame? = nil) {
    self.base = base
    // The flag is meaningful only for a base reference; normalize a base-less
    // spec to `false` so two otherwise-equal specs never differ on a dead flag.
    self.parenthesized = base == nil ? false : parenthesized
    self.partition = partition
    self.order = order
    self.frame = frame
  }
}

/// A named window definition — one `name AS (<window spec>)` entry of a
/// `SELECT`'s `WINDOW` clause, a specification a later `OVER name` reference
/// resolves to. The `spec` is an ordinary `WindowSpec` (it may carry
/// `PARTITION`/`ORDER`/frame), inlined into each reference by the
/// `Query.expanded` prelude.
public struct NamedWindow: Hashable, Sendable {
  /// The window's name, the identifier an `OVER name` reference spells.
  public let name: String

  /// The window's specification.
  public let spec: WindowSpec

  public init(name: String, spec: WindowSpec) {
    self.name = name
    self.spec = spec
  }
}

/// An explicit window frame — the `ROWS`/`RANGE`/`GROUPS BETWEEN <start> AND
/// <end>` clause narrowing which of a partition's ordered rows a
/// frame-sensitive window function reads.
///
/// The `unit` fixes how the bounds are measured: `ROWS` counts physical rows,
/// `RANGE` measures by the order-key value (a `CURRENT ROW` bound spans the
/// current row's whole peer group — the rows tied with it on the order key),
/// and `GROUPS` counts peer groups. `start` and `end` are the frame's lower and
/// upper bounds, in row order — the ISO `BETWEEN <start> AND <end>` form, with
/// the single-bound shorthand `ROWS <start>` read as `BETWEEN <start> AND
/// CURRENT ROW`.
public struct Frame: Hashable, Sendable {
  /// How a frame's bounds are measured.
  public enum Unit: Hashable, Sendable {
    /// `ROWS` — bounds are physical row offsets from the current row.
    case rows
    /// `RANGE` — bounds are order-key values; a `CURRENT ROW` bound is the
    /// current row's peer group.
    case range
    /// `GROUPS` — bounds are peer-group counts from the current row's group.
    case groups
  }

  /// One frame bound — a partition edge, the current row/peer group, or an
  /// offset from it.
  public enum Bound: Hashable, Sendable {
    /// `UNBOUNDED PRECEDING` — the partition start.
    case head
    /// `n PRECEDING` — `n` rows/values/groups before the current row.
    case preceding(Int)
    /// `CURRENT ROW` — the current row (`ROWS`/`GROUPS`) or its peer group
    /// (`RANGE`).
    case current
    /// `n FOLLOWING` — `n` rows/values/groups after the current row.
    case following(Int)
    /// `UNBOUNDED FOLLOWING` — the partition end.
    case tail
  }

  /// How the bounds are measured — `ROWS`, `RANGE`, or `GROUPS`.
  public let unit: Unit

  /// The frame's lower bound (the earlier row in the window order).
  public let start: Bound

  /// The frame's upper bound (the later row in the window order).
  public let end: Bound

  public init(unit: Unit, start: Bound, end: Bound) {
    self.unit = unit
    self.start = start
    self.end = end
  }
}

extension WindowSpec {
  /// The constituent scalar expressions of this specification — its
  /// `PARTITION BY` keys and its `ORDER BY` keys' value expressions (an ordinal
  /// key names an output column, not a value, so it contributes none). The
  /// structural walks (`aggregated`, `collect(subqueries:)`, …) descend these
  /// as they descend a call's arguments, so a subquery or aggregate nested in a
  /// window's partition or order is seen by the same machinery.
  internal var expressions: Array<Expression> {
    var expressions = partition
    for key in order?.keys ?? [] {
      if case let .expression(expression) = key.sort {
        expressions.append(expression)
      }
    }
    return expressions
  }
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
  /// comparison, both sides a row of scalar `Expression`s of equal arity
  /// (`SQLError.arity` at compile otherwise), `op` any of the six operators. It
  /// is a FIRST-class node rather than a parse-time desugar to a
  /// conjunction/cascade of scalar comparisons so that each component
  /// `Expression` is evaluated exactly once: the desugar duplicated a component
  /// across the places it appears (a `<` cascade names an earlier component in
  /// both a strict step and an equality tie-guard), so a stateful component
  /// yielded a different value each time. It keeps the ISO three-valued
  /// semantics — `=` the conjunction of the componentwise equalities, `<>` its
  /// negation, the ordering operators the lexicographic cascade — lowered to a
  /// `Filter.comparison` the runtime evaluates once-per-component.
  case rows(Array<Expression>, Comparison, Array<Expression>)
  /// `(l1, …, ln) [NOT] IN ((r1, …, rn), …)` — an ISO row-value membership, the
  /// left a `<row value constructor>` and the right a non-empty list of element
  /// rows, each of equal arity (`SQLError.arity` otherwise), `negated` marking
  /// `NOT IN`. As `rows`, it is a FIRST-class node rather than a desugar to an
  /// OR-chain of row equalities so the left components are evaluated exactly
  /// once rather than once per element row. It keeps the value-list `IN`'s
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
  /// x <= b` (and `x < a OR x > b` negated), but it is a FIRST-class node
  /// rather than that expansion so the test expression `x` is evaluated exactly
  /// once: the desugar duplicated `x` across both bound comparisons, testing a
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
  /// spelling. It is two-valued — never UNKNOWN — treating NULL as a comparable
  /// value: `a IS DISTINCT FROM b` is FALSE iff both are NULL, or both are
  /// non-NULL and equal, and TRUE otherwise (exactly one NULL, or both non-NULL
  /// and unequal). `IS NOT DISTINCT FROM` is its negation. A cross-kind pair is
  /// DISTINCT — the two differ — matching the engine's cross-kind FALSE
  /// equality. Unlike `=`, a NULL operand never makes the row UNKNOWN.
  case distinct(Expression, Expression, negated: Bool)
  /// `[NOT] EXISTS (Q)` — whether the subquery `Q` yields at least one row,
  /// `negated` marking `NOT EXISTS`. It is definitely two-valued — never
  /// UNKNOWN — even when `Q` produces NULL-valued rows: the presence of a row
  /// is TRUE regardless of its values, so `EXISTS` tests cardinality alone. In
  /// this first slice `Q` is uncorrelated — it names no column of the enclosing
  /// query — so the engine materialises it once (as a common table expression's
  /// body is materialised) and the whole predicate is the definite non-empty
  /// test of that result; `negated` flips it. `Predicate` is `indirect`, so it
  /// nests the whole `Query` without boxing.
  case exists(Query, negated: Bool)
  /// `(l1, …, ln) [NOT] IN (Q)` — whether the left `<row value constructor>`
  /// equals any row the subquery `Q` yields, `negated` marking `NOT IN`. The
  /// left is a row of one or more `Expression`s (a bare `x IN (Q)` is the
  /// one-arity case, its left `[x]`); `Q` must project exactly as many columns
  /// as the row has degree (else `SQLError.arity`, checked from the compiled
  /// width). The predicate is the three-valued disjunction of row equalities
  /// `(l…) = (r…)` over `Q`'s rows under Kleene `OR` — each row equality the
  /// componentwise Kleene `AND` the row comparison `rows` uses, degenerating to
  /// the scalar `x = v` at arity one, exactly as the value-list `membership`/
  /// `among` do. So a NULL component makes an otherwise-unmatched test UNKNOWN
  /// rather than FALSE, an empty `Q` folds FALSE (no witness), and `NOT IN`
  /// negates that truth — never TRUE when a candidate comparison is UNKNOWN and
  /// none is TRUE (the NULL trap). In this slice `Q` is uncorrelated (it names
  /// no enclosing column), so the engine materialises its rows once and folds
  /// over them.
  case within(Array<Expression>, Query, negated: Bool)
  /// `(l1, …, ln) op {ANY | SOME | ALL} (Q)` — a quantified comparison, whether
  /// `(l…) op r` holds for at least one (`ANY`/`SOME`) or every (`ALL`) row `r`
  /// the subquery `Q` yields, `op` any of `= <> < <= > >=`. The left is a row
  /// of one or more `Expression`s (a bare `x op ANY (Q)` is the one-arity case,
  /// its left `[x]`); `Q` must project exactly as many columns as the row has
  /// degree (else `SQLError.arity`). It folds the row comparison `(l…) op r`
  /// — the same componentwise-`=`/lexicographic-ordering three-valued relation
  /// `rows` uses, degenerating to the scalar `x op v` at arity one — over `Q`'s
  /// rows under Kleene `OR` for `any` (TRUE at the first TRUE, else UNKNOWN if
  /// any comparison is UNKNOWN through a NULL component, else FALSE) and under
  /// Kleene `AND` for `all` (FALSE at the first FALSE, else UNKNOWN if any is
  /// UNKNOWN, else TRUE). An empty `Q` takes the fold's identity — `any` FALSE
  /// (no witness), `all` TRUE (vacuous). `= ANY` is `within` and `<> ALL` its
  /// `NOT IN`, but the case is kept distinct for the operator. `SOME` is
  /// a synonym for `ANY`, normalised to `any` at parse time. In this slice `Q`
  /// is uncorrelated — the engine materialises its rows once and folds over
  /// them; correlation is a later slice.
  case quantified(Array<Expression>, Comparison, Quantifier, Query)
  /// `p IS [NOT] <truth value>` — the ISO `<boolean test>`, whether the inner
  /// boolean `Predicate` `p`'s three-valued result equals the `value`
  /// (`TRUE`/`FALSE`/`UNKNOWN`), or does not when `negated`. Unlike the other
  /// predicates the result is definite two-valued — never itself UNKNOWN — so
  /// `p IS TRUE` is FALSE (not UNKNOWN) for an UNKNOWN `p`, and `p IS UNKNOWN`
  /// tests for that UNKNOWN. The operand is a `Predicate` rather than an
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
/// `UNKNOWN` in this test). `p IS TRUE`/`FALSE`/`UNKNOWN` yields a definite
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
/// `x op v` is TRUE for at least one value `v` the subquery yields; `ALL` holds
/// when it is TRUE for every value. Both are three-valued over NULLs and take
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
  /// The keyword `NULL` written as a value expression — SQL's absent value, of
  /// no determinate type (ISO `<null specification>`). It lowers to a constant
  /// NULL, so a projection of it places no type constraint on a set-operation's
  /// unified column (it unifies with any typed arm, as `COALESCE` skips a
  /// constant-NULL argument), and its comparisons are UNKNOWN under three-valued
  /// logic. Distinct from the `IS NULL` predicate, which tests a value.
  case null
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
