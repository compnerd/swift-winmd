// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Parser {
  // MARK: - Predicate

  /// Parses a predicate at the lowest precedence (`OR`).
  internal mutating func predicate() throws(SQLError) -> Predicate {
    try disjunction()
  }

  /// Parses `conjunction (OR conjunction)*`, left-associative.
  private mutating func disjunction() throws(SQLError) -> Predicate {
    var lhs = try conjunction()
    while try match(.or) {
      lhs = try .or(lhs, conjunction())
    }
    return lhs
  }

  /// Parses `negation (AND negation)*`, left-associative.
  private mutating func conjunction() throws(SQLError) -> Predicate {
    var lhs = try negation()
    while try match(.and) {
      lhs = try .and(lhs, negation())
    }
    return lhs
  }

  /// Parses `NOT negation`, `[NOT] EXISTS (query)`, or a primary.
  ///
  /// `EXISTS` is a complete predicate with no left operand — `EXISTS (Q)` — so
  /// it is recognised here, ahead of the comparison tier a left expression
  /// begins in. A prefix `NOT` before it sets the `negated` flag directly
  /// (`NOT EXISTS (Q)`) rather than wrapping it in a `.not`, symmetric with how
  /// `membership`/`between`/`like` carry their `NOT`; a prefix `NOT` before
  /// anything else is the ordinary boolean negation.
  private mutating func negation() throws(SQLError) -> Predicate {
    if try match(.not) {
      if try match(.exists) {
        return try exists(negated: true)
      }
      return try .not(negation())
    }
    if try match(.exists) {
      return try exists(negated: false)
    }
    return try primary()
  }

  /// Parses the `(query)` tail of `[NOT] EXISTS (query)` — the `EXISTS` is
  /// already consumed — into the first-class `Predicate.exists`, `negated`
  /// carrying the `NOT EXISTS` spelling. The subquery is a parenthesised
  /// `query`, so it may itself be a `UNION`; `Predicate` is `indirect`, so it
  /// nests the whole `Query`.
  private mutating func exists(negated: Bool) throws(SQLError) -> Predicate {
    try expect(.lparen)
    let query = try query()
    try expect(.rparen)
    return .exists(query, negated: negated)
  }

  /// Parses a parenthesised predicate or a comparison.
  ///
  /// A leading `(` is ambiguous: it opens either an ISO `<row value
  /// constructor>` heading a row comparison or row `IN` (`(a, b) = (c, d)`), a
  /// parenthesised predicate (`(a = 1 AND b = 2)`), or the parenthesised left
  /// operand of a comparison (`(Age + 1) = 26`, where `factor` consumes the
  /// `(expression)`). A comma inside the parentheses marks the row form, which
  /// `row()` detects and commits to — a row is never a valid predicate, so its
  /// tail errors (an arity mismatch) must propagate rather than trigger the
  /// predicate rewind. Otherwise the comparison is tried first; if it fails,
  /// the group was a predicate, so the parser rewinds to the saved lexer and
  /// lookahead token and parses it as one.
  private mutating func primary() throws(SQLError) -> Predicate {
    guard current?.kind == .lparen else {
      return try comparison()
    }
    if let left = try row() {
      return try rows(left)
    }
    let lexer = self.lexer
    let token = self.current
    do {
      return try comparison()
    } catch {
      self.lexer = lexer
      self.current = token
    }
    try expect(.lparen)
    let predicate = try predicate()
    try expect(.rparen)
    // A parenthesised predicate is itself a `<boolean primary>`, so an `IS
    // [NOT] TRUE/FALSE/UNKNOWN` tail may test its three-valued result directly
    // (`(a > b) IS TRUE`) — the inner `Predicate` the test maps against the
    // truth value. Only a truth-value tail applies here; an `IS NULL` over a
    // predicate is not a value test.
    if try match(.is) {
      let negated = try match(.not)
      guard let value = try truth() else {
        let token = try advance(expecting: "TRUE, FALSE, or UNKNOWN")
        throw .unexpected(token.kind.description,
                          expected: "TRUE, FALSE, or UNKNOWN",
                          at: token.location)
      }
      return .truth(predicate, value: value, negated: negated)
    }
    return predicate
  }

  /// Parses `expression (op (expression | :parameter) | IS [NOT] NULL | [NOT]
  /// IN '(' expression (',' expression)* ')')`.
  ///
  /// Either operand may be a column, a literal, or a scalar-function call, so a
  /// predicate can filter on a decoded value (`WHERE guid(Id) = '…'`). A
  /// `:parameter` right operand binds the comparison to a value resolved at run
  /// time from the engine's bindings — the correlated-subquery primitive. An
  /// `IS NULL` (or `IS NOT NULL`) tail tests the left expression for `NULL`
  /// rather than comparing it — the way a nullable column is filtered. An `IS
  /// [NOT] DISTINCT FROM` tail is the ISO null-safe comparison of the two
  /// expressions, treating NULL as a comparable value; an `IS [NOT]
  /// TRUE/FALSE/UNKNOWN` tail is the ISO `<boolean test>`, the boolean operand
  /// bridging as the comparison `x = TRUE` the test maps to a definite truth.
  /// An `IN`
  /// (or `NOT IN`) tail tests the left expression for membership in a
  /// parenthesised value list, or — when a `SELECT` follows the `(` — in the
  /// single column a parenthesised subquery yields. A `LIKE` (or `NOT LIKE`)
  /// tail tests the left
  /// expression's text against a pattern, with an optional `ESCAPE` character.
  /// A `BETWEEN a AND b` (or `NOT BETWEEN`) tail is the ISO range test,
  /// desugared into a conjunction (or disjunction) of bounds. A leading `NOT`
  /// here introduces `NOT IN`, `NOT LIKE`, or `NOT BETWEEN`: a prefix `NOT`
  /// predicate is consumed by `negation` before this point.
  private mutating func comparison() throws(SQLError) -> Predicate {
    let left = try expression()
    if try match(.is) {
      let negated = try match(.not)
      if try match(.distinct) {
        return try distinct(left, negated: negated)
      }
      if let value = try truth() {
        // `x IS [NOT] TRUE/FALSE/UNKNOWN` — the boolean operand `x` bridges as
        // the comparison `x = TRUE`, whose three-valued truth IS `x`'s boolean
        // value (a NULL `x` reading UNKNOWN), the inner `Predicate` the test
        // maps against `value` to a definite two-valued result.
        let boolean = Predicate.comparison(left: left, op: .equal,
                                           right: .literal(.boolean(true)))
        return .truth(boolean, value: value, negated: negated)
      }
      try expect(.null)
      return .null(left, negated: negated)
    }
    if try match(.in) {
      return try membership(left, negated: false)
    }
    if try match(.like) {
      return try like(left, negated: false)
    }
    if try match(.between) {
      return try between(left, negated: false)
    }
    if try match(.not) {
      if try match(.like) {
        return try like(left, negated: true)
      }
      if try match(.between) {
        return try between(left, negated: true)
      }
      try expect(.in)
      return try membership(left, negated: true)
    }
    let op = try op()
    if let quantifier = try quantifier() {
      // `left op {ANY | SOME | ALL} (query)` — a quantified comparison. The
      // quantifier follows the operator, so the peek is unambiguous: it is
      // never a right operand. The subquery is parenthesised as `IN (Q)` is.
      try expect(.lparen)
      let query = try query()
      try expect(.rparen)
      return .quantified(left, op, quantifier, query)
    }
    if case let .parameter(name) = current?.kind {
      _ = try advance(expecting: "a parameter")
      return .bound(left: left, op: op, parameter: name)
    }
    let right = try expression()
    return .comparison(left: left, op: op, right: right)
  }

  /// Parses an ISO `<row value constructor>` — `'(' expression (','
  /// expression)+ ')'`, at least two elements — returning its element
  /// expressions, or `nil` when the current token does not open one so the
  /// caller falls through to the scalar path.
  ///
  /// A leading `(` is ambiguous between a row and a parenthesised scalar
  /// (`(x)`), or an arithmetic group (`(a + b)`): only a comma inside the
  /// parentheses makes it a row. So this saves the lexer and lookahead, opens
  /// the `(`, and parses the first element; a following `,` confirms the row —
  /// it collects the rest and the `)`. Without a comma it is a scalar, so the
  /// parser rewinds to the saved state and returns `nil`, leaving the `(`
  /// unconsumed for `expression()` to parse. A `(` not present at all returns
  /// `nil` without touching the stream.
  private mutating func row() throws(SQLError) -> Array<Expression>? {
    guard current?.kind == .lparen else { return nil }
    let lexer = self.lexer
    let token = self.current
    try expect(.lparen)
    // A `(SELECT …)` opens a scalar subquery, never a row — `factor()` reads it
    // through the whole `(query)`. Rewind so the scalar path parses it rather
    // than `expression()` choking on the bare `SELECT` (the `(` already
    // consumed), the same `SELECT` lookahead `factor()` and `IN` use.
    if current?.kind == .select {
      self.lexer = lexer
      self.current = token
      return nil
    }
    // A token that cannot begin an expression (`NOT`, `EXISTS`, `TABLE`, …) is
    // not a row element, so a parse failure of the FIRST element means this `(`
    // opens a parenthesised predicate, not a row: rewind and return `nil` so
    // the caller's predicate path runs. Only a `,` commits to row syntax, after
    // which a later element's error is a real error and propagates.
    guard let first = try? expression() else {
      self.lexer = lexer
      self.current = token
      return nil
    }
    guard try match(.comma) else {
      self.lexer = lexer
      self.current = token
      return nil
    }
    var elements = [first]
    repeat {
      try elements.append(expression())
    } while try match(.comma)
    try expect(.rparen)
    return elements
  }

  /// Parses the tail of a row comparison or row `IN` whose left `<row value
  /// constructor>` is already parsed to `left`, building the FIRST-class AST
  /// node (`Predicate.rows` / `Predicate.among`) rather than desugaring it —
  /// each component `Expression` is held once so the lowering evaluates it
  /// exactly once per row, the correctness fix over a desugar that duplicated a
  /// component across the places a conjunction/cascade names it.
  ///
  /// A relational operator (`= <> < <= > >=`) takes a second row constructor of
  /// equal arity (else `SQLError.arity`), building `Predicate.rows(left, op,
  /// right)`. An `IN` (or `NOT IN`) takes a parenthesised list of row
  /// constructors, building `Predicate.among(left, elements, negated:)`. The
  /// ISO three-valued semantics (the componentwise conjunction for `=`, the
  /// lexicographic cascade for the ordering operators, the `IN` disjunction)
  /// live in the lowering and runtime, not this parse.
  private mutating func rows(_ left: Array<Expression>)
      throws(SQLError) -> Predicate {
    if try match(.in) {
      return try rows(left, in: false)
    }
    if try match(.not) {
      try expect(.in)
      return try rows(left, in: true)
    }
    let op = try op()
    guard let right = try row() else {
      let token = try advance(expecting: "a row value constructor")
      throw .unexpected(token.kind.description,
                        expected: "a row value constructor",
                        at: token.location)
    }
    guard left.count == right.count else {
      throw .arity(left.count, right.count)
    }
    return .rows(left, op, right)
  }

  /// Parses the tail of a row `[NOT] IN '(' row (',' row)* ')'` — the `IN` is
  /// already consumed — building `Predicate.among(left, elements, negated:)`
  /// over `left` and the parsed element rows, each of equal arity (else
  /// `SQLError.arity`) and the list non-empty. `negated` marks `NOT IN`.
  private mutating func rows(_ left: Array<Expression>, in negated: Bool)
      throws(SQLError) -> Predicate {
    try expect(.lparen)
    var elements = Array<Array<Expression>>()
    repeat {
      guard let element = try row() else {
        let token = try advance(expecting: "a row value constructor")
        throw .unexpected(token.kind.description,
                          expected: "a row value constructor",
                          at: token.location)
      }
      guard left.count == element.count else {
        throw .arity(left.count, element.count)
      }
      elements.append(element)
    } while try match(.comma)
    try expect(.rparen)
    guard !elements.isEmpty else {
      throw .state("42601", "IN requires a non-empty value list")
    }
    return .among(left, elements, negated: negated)
  }

  /// Consumes an `ANY`, `SOME`, or `ALL` quantifier keyword at the head of a
  /// quantified comparison's right side — the `ANY`/`ALL` `Quantifier`, `SOME`
  /// a synonym for `ANY` normalised to `any` here — or `nil` when the next
  /// token is none of them (an ordinary right operand, which the caller then
  /// parses). `ALL` is the same keyword a `UNION ALL`/`SELECT ALL` uses,
  /// disambiguated by grammar position: after a comparison operator it is only
  /// ever the quantifier.
  private mutating func quantifier() throws(SQLError) -> Quantifier? {
    if try match(.any) { return .any }
    if try match(.some) { return .any }
    if try match(.all) { return .all }
    return nil
  }

  /// Parses the tail of `left [NOT] IN (…)` — the `IN` is already consumed —
  /// into a `membership` (value-list) or a `within` (subquery) predicate over
  /// `left`.
  ///
  /// After the opening `(`, one token of lookahead disambiguates the two forms:
  /// a `SELECT` begins a subquery — `left [NOT] IN (query)`, the first-class
  /// `Predicate.within` (the query may itself be a `UNION`) — and anything
  /// else begins the value list, a non-empty run of comma-separated
  /// expressions, the `Predicate.membership`. No rewind is needed: `SELECT`
  /// never begins an expression, so the peek is unambiguous.
  private mutating func membership(_ left: Expression, negated: Bool)
      throws(SQLError) -> Predicate {
    try expect(.lparen)
    if [.select, .table, .values].contains(current?.kind) {
      let query = try query()
      try expect(.rparen)
      return .within(left, query, negated: negated)
    }
    var values = [try expression()]
    while try match(.comma) {
      try values.append(expression())
    }
    try expect(.rparen)
    return .membership(left, values, negated: negated)
  }

  /// Parses the right operand of `left IS [NOT] DISTINCT FROM right` — the `IS
  /// [NOT] DISTINCT` is already consumed — into the first-class
  /// `Predicate.distinct`, `negated` carrying the `IS NOT` (null-safe equality)
  /// spelling.
  ///
  /// It is the ISO null-safe comparison of the two expressions: two-valued
  /// (never UNKNOWN), treating NULL as a comparable value, unlike `=`. The
  /// right operand is an ordinary scalar `expression` — not an `Operand`, as no
  /// `:parameter` form is defined for this predicate.
  private mutating func distinct(_ left: Expression, negated: Bool)
      throws(SQLError) -> Predicate {
    try expect(.from)
    let right = try expression()
    return .distinct(left, right, negated: negated)
  }

  /// Parses the bounds tail of `left [NOT] BETWEEN a AND b` — the `BETWEEN` is
  /// already consumed — into the first-class `Predicate.between`.
  ///
  /// ISO 9075 defines `x BETWEEN a AND b` as `x >= a AND x <= b` (an inclusive
  /// range) and `x NOT BETWEEN a AND b` as its negation `x < a OR x > b`, but
  /// that expansion duplicates `x` across both bound comparisons, evaluating a
  /// stateful `x` twice — so this parses the two bounds around the `AND`
  /// keyword and builds the first-class node the engine evaluates `x` once for,
  /// keeping the same three-valued NULL semantics (a NULL `x`, `a`, or `b`
  /// makes a bound UNKNOWN, and the row is excluded).
  ///
  /// Each bound is an `Operand` — a scalar expression, or a run-time
  /// `:parameter` bound at eval (`Id BETWEEN :lo AND :hi`), the same binding
  /// the comparison and `LIKE` arms accept — so a caller can bind a range
  /// rather than fall back to the duplicated `Id >= :lo AND Id <= :hi` desugar.
  private mutating func between(_ left: Expression, negated: Bool)
      throws(SQLError) -> Predicate {
    let lower = try operand()
    try expect(.and)
    let upper = try operand()
    return .between(left, lower, upper, negated: negated)
  }

  /// Consumes a `<truth value>` keyword — `TRUE`, `FALSE`, or `UNKNOWN` — at
  /// the head of an `IS [NOT]` tail, returning its `Truth`, or `nil` when the
  /// next token is none of them (an `IS NULL` tail, which the caller then
  /// handles). The `TRUE`/`FALSE` keywords are the boolean literals; `UNKNOWN`
  /// is a keyword valid ONLY in this test position.
  private mutating func truth() throws(SQLError) -> Truth? {
    if try match(.true) { return .true }
    if try match(.false) { return .false }
    if try match(.unknown) { return .unknown }
    return nil
  }

  /// Parses the pattern tail of `left [NOT] LIKE pattern [ESCAPE escape]` — the
  /// `LIKE` is already consumed — into a `like` predicate over `left`.
  ///
  /// The pattern is an `Operand` — a scalar expression (a literal, a column, or
  /// a call), so a pattern can be computed rather than only a literal, or a
  /// run-time `:parameter` bound at eval (`Name LIKE :pattern`), the same
  /// binding the comparison arm accepts as a right operand. An optional
  /// `ESCAPE` names the escape as a further `Operand`, so it too can be bound
  /// (`ESCAPE :e`).
  private mutating func like(_ left: Expression, negated: Bool)
      throws(SQLError) -> Predicate {
    let pattern = try operand()
    let escape: Predicate.Operand? = if try match(.escape) {
      try operand()
    } else {
      nil
    }
    return .like(left, pattern: pattern, escape: escape, negated: negated)
  }

  /// Parses a `LIKE` pattern or escape operand: a `:parameter` placeholder
  /// (bound at eval from the engine's bindings, as the comparison arm consumes
  /// one after an operator) or an ordinary scalar expression.
  private mutating func operand() throws(SQLError) -> Predicate.Operand {
    if case let .parameter(name) = current?.kind {
      _ = try advance(expecting: "a parameter")
      return .parameter(name)
    }
    return try .expression(expression())
  }

  /// Parses a comparison operator.
  private mutating func op() throws(SQLError) -> Comparison {
    let token = try advance(expecting: "a comparison operator")
    return switch token.kind {
    case .equal: .equal
    case .unequal: .unequal
    case .lt: .lt
    case .gt: .gt
    case .leq: .leq
    case .geq: .geq
    default:
      throw .unexpected(token.kind.description,
                        expected: "a comparison operator",
                        at: token.location)
    }
  }

  /// Parses a string, integer, decimal, boolean, or binary literal.
  private mutating func literal() throws(SQLError) -> Literal {
    let token = try advance(expecting: "a literal")
    return switch token.kind {
    case let .string(value): .string(value)
    case let .integer(value): .integer(value)
    case let .decimal(value): .double(value)
    case let .blob(bytes): .blob(bytes)
    case .true: .boolean(true)
    case .false: .boolean(false)
    default:
      throw .unexpected(token.kind.description,
                        expected: "a literal", at: token.location)
    }
  }
}
