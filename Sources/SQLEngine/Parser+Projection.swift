// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Parser {
  // MARK: - Projection

  /// Parses `*` or a comma-separated list of projected items, each an
  /// expression with an optional `AS` alias.
  ///
  /// A list of bare columns with no alias collapses to the simpler `columns`
  /// projection (the backward-compatible path); a list carrying any function
  /// call or alias is the richer `expressions` projection.
  internal mutating func projection() throws(SQLError) -> Projection {
    if try match(.star) {
      return .all
    }

    var items = Array<Projected>()
    try items.append(projected())
    while try match(.comma) {
      try items.append(projected())
    }

    // Collapse a plain column list (no calls, no aliases) to `columns`.
    var columns = Array<Column>()
    for item in items {
      guard item.alias == nil, case let .column(column) = item.expression else {
        return .expressions(items)
      }
      columns.append(column)
    }
    return .columns(columns)
  }

  /// Parses one projected item: an expression and an optional `AS alias`.
  private mutating func projected() throws(SQLError) -> Projected {
    let expression = try expression()
    let alias: String? = if try match(.as) {
      try identifier()
    } else {
      nil
    }
    return Projected(expression: expression, alias: alias)
  }

  /// Parses a scalar expression at the lowest arithmetic precedence (`+` `-`).
  internal mutating func expression() throws(SQLError) -> Expression {
    try additive()
  }

  /// Parses `multiplicative (('+' | '-' | '||') multiplicative)*`,
  /// left-associative.
  ///
  /// The ISO `||` string concatenation shares this additive precedence tier and
  /// left-associativity, so `a || b || c` reads left to right and `a + b || c`
  /// groups `(a + b) || c` — both binding looser than `*`/`/`.
  private mutating func additive() throws(SQLError) -> Expression {
    var lhs = try multiplicative()
    while true {
      let op: Arithmetic? = if try match(.plus) {
        .add
      } else if try match(.minus) {
        .subtract
      } else if try match(.concat) {
        .concatenate
      } else {
        nil
      }
      guard let op else { break }
      lhs = try .binary(op, lhs, multiplicative())
    }
    return lhs
  }

  /// Parses `factor (('*' | '/') factor)*`, left-associative — `*` and `/` bind
  /// tighter than `+` and `-`.
  private mutating func multiplicative() throws(SQLError) -> Expression {
    var lhs = try factor()
    while true {
      let op: Arithmetic? = if try match(.star) {
        .multiply
      } else if try match(.slash) {
        .divide
      } else {
        nil
      }
      guard let op else { break }
      lhs = try .binary(op, lhs, factor())
    }
    return lhs
  }

  /// Parses an arithmetic factor: a parenthesised expression, a string,
  /// integer, or decimal literal, a function call (`name(args)`), or a bare
  /// (possibly-qualified) column.
  ///
  /// Parentheses override the precedence the cascade encodes. A function call
  /// is an identifier immediately followed by `(`; an identifier not so
  /// followed is a column. The arguments are a comma-separated list of
  /// expressions, possibly empty.
  private mutating func factor() throws(SQLError) -> Expression {
    if try match(.lparen) {
      // ONE token of lookahead after `(` disambiguates a SCALAR SUBQUERY from a
      // parenthesised expression: a `SELECT`, `TABLE`, or `VALUES` begins a
      // subquery — `(query)`, the first-class `Expression.subquery` (the query
      // may itself be a `UNION`) — and anything else begins a parenthesised
      // expression. No rewind is needed: none of these keywords begins an
      // expression, so the peek is unambiguous, exactly as the `IN (…)` and
      // `EXISTS (…)` lookaheads are.
      if [.select, .table, .values].contains(current?.kind) {
        let query = try query()
        try expect(.rparen)
        return .subquery(query)
      }
      let expression = try expression()
      try expect(.rparen)
      return expression
    }
    if current?.kind == .case {
      return try conditional()
    }
    if case let .string(value) = current?.kind {
      _ = try advance(expecting: "a literal")
      return .literal(.string(value))
    }
    if case let .integer(value) = current?.kind {
      _ = try advance(expecting: "a literal")
      return .literal(.integer(value))
    }
    if case let .decimal(value) = current?.kind {
      _ = try advance(expecting: "a literal")
      return .literal(.double(value))
    }
    if case let .blob(bytes) = current?.kind {
      _ = try advance(expecting: "a literal")
      return .literal(.blob(bytes))
    }
    if current?.kind == .true || current?.kind == .false {
      let token = try advance(expecting: "a literal")
      return .literal(.boolean(token.kind == .true))
    }
    // The keyword `NULL` in value-expression position is the ISO `<null
    // specification>` — the absent value. The `IS [NOT] NULL` predicate consumes
    // its own `NULL` in the predicate parser, so a `.null` reaching here begins
    // an expression (`SELECT NULL`, `COALESCE(NULL, x)`, `x = NULL`).
    if current?.kind == .null {
      _ = try advance(expecting: "a literal")
      return .literal(.null)
    }

    let ident = try name()
    guard try match(.lparen) else {
      // A delimited name is a verbatim column (a dot in it is part of the
      // name); a bare one may be a qualified reference that `Column(_:)`
      // splits.
      return .column(ident.quoted ? Column(name: ident.text)
                                  : Column(ident.text))
    }

    // `CAST` is the ISO explicit-conversion operator, recognised bare (a
    // delimited `"CAST"` is an ordinary scalar-call name) like an aggregate.
    // Its tail is `expression AS type )`, not the comma-separated argument list
    // a call takes, so it dispatches to its own production.
    if !ident.quoted, ident.text.uppercased() == "CAST" {
      return try cast()
    }

    // `COALESCE` is an ISO-defined expansion of a searched `CASE`, recognised
    // case-insensitively only when written bare (a delimited `"COALESCE"` is a
    // scalar-call name). Desugar into the first-class `Expression.coalesce`
    // here — the `(` is consumed — so the conditional's type unification,
    // coercion, and reachability apply unchanged.
    if !ident.quoted, ident.text.uppercased() == "COALESCE" {
      return try coalesce()
    }

    // `NULLIF` is an ISO-defined expansion of a searched `CASE`, recognised
    // case-insensitively only when written bare (a delimited `"NULLIF"` is a
    // scalar-call name). Desugar into the first-class `Expression.nullif` here
    // — the `(` is consumed — so the conditional's type derivation and
    // coercion apply unchanged.
    if !ident.quoted, ident.text.uppercased() == "NULLIF" {
      return try nullif()
    }

    // `POSITION` and `OVERLAY` are ISO string functions with a
    // KEYWORD-separated argument syntax (`IN`; `PLACING`/`FROM`/`FOR`) rather
    // than the comma list an ordinary call takes, recognised case-insensitively
    // only when written bare (a delimited `"POSITION"`/`"OVERLAY"` is a
    // scalar-call name). Each desugars — the `(` already consumed — into the
    // plain `Expression.call` the registered `position`/`overlay` routine
    // evaluates, so the eval side is the routine alone.
    if !ident.quoted, ident.text.uppercased() == "POSITION" {
      return try position()
    }
    if !ident.quoted, ident.text.uppercased() == "OVERLAY" {
      return try overlay()
    }

    // An aggregate is one of the fixed set of names (recognised
    // case-insensitively, only when written bare — a delimited `"COUNT"` is a
    // scalar name), distinct from a scalar call: it accumulates over a group
    // rather than evaluating per row. `COUNT(*)` takes `*` in place of an
    // expression; every aggregate else takes one expression operand.
    if !ident.quoted, let aggregate = aggregate(ident.text) {
      let (operand, distinct) = try aggregand(aggregate)
      let filter = try self.filter()
      return .aggregate(aggregate, of: operand, distinct: distinct,
                        filter: filter)
    }

    // `GROUPING(a, …)` is the ISO grouping-sets function — a first-class node,
    // not a scalar `call` (an unregistered `GROUPING` routine would fault
    // `.function`), recognised case-insensitively only when written bare (a
    // delimited `"GROUPING"` is an ordinary scalar name) and followed by `(`
    // (a bare `grouping` not before `(` stayed an ordinary column above). It
    // takes the same comma-separated argument list a call does, and needs at
    // least one argument; it resolves to a per-arm integer bit-vector constant
    // at grouped lowering, so it never dispatches through the routines.
    let grouping = !ident.quoted && ident.text.uppercased() == "GROUPING"

    var arguments = Array<Expression>()
    if current?.kind != .rparen {
      try arguments.append(expression())
      while try match(.comma) {
        try arguments.append(expression())
      }
    }
    try expect(.rparen)
    if grouping {
      guard !arguments.isEmpty else {
        throw .state("42601", "GROUPING requires at least one argument")
      }
      // The result is a signed-integer bit-vector — one bit per argument, the
      // first the most significant — so more arguments than an `Int` payload
      // holds cannot be represented without the vector overflowing to a
      // negative value. Reject the over-wide call at parse (ISO 54023, too many
      // arguments) rather than lower it to a corrupt constant.
      guard arguments.count <= Int.bitWidth - 1 else {
        throw .state("54023",
                     "GROUPING supports at most \(Int.bitWidth - 1) arguments")
      }
      return .grouping(arguments)
    }
    return .call(name: ident.text, arguments: arguments)
  }

  /// The `Aggregate` the bare name `text` spells (case-insensitively), or `nil`
  /// when it is not an aggregate — a scalar-function name.
  private func aggregate(_ text: String) -> Aggregate? {
    switch text.uppercased() {
    case "COUNT": .count
    case "SUM": .sum
    case "MIN": .min
    case "MAX": .max
    case "AVG": .avg
    default: nil
    }
  }

  /// Parses an aggregate's operand and its optional `<set quantifier>` (the `(`
  /// is already consumed) and the closing `)`, returning the operand and
  /// whether `DISTINCT` was written.
  ///
  /// `*` is the operand of `COUNT(*)`, admitted only for `COUNT` (a non-`COUNT`
  /// aggregate over `*` (`SUM(*)`) faults) and takes no quantifier: a
  /// `COUNT(DISTINCT *)` is diagnosed, as `*` is the whole row rather than a
  /// value to fold distinctly. Every other aggregate takes one expression
  /// operand, optionally preceded by `DISTINCT` (fold each distinct value once)
  /// or `ALL` (the explicit default, fold every value); `distinct` is `true`
  /// only for a written `DISTINCT`.
  private mutating func aggregand(_ aggregate: Aggregate)
      throws(SQLError) -> (operand: Aggregand, distinct: Bool) {
    if try match(.star) {
      guard aggregate == .count else {
        throw .state("42601", "only COUNT admits a '*' operand")
      }
      try expect(.rparen)
      return (.star, false)
    }
    // The optional set quantifier precedes the value expression: `DISTINCT`
    // folds each distinct value once, `ALL` (the default) folds every value.
    let distinct = try match(.distinct)
    if !distinct { _ = try match(.all) }
    let operand = try Aggregand.expression(expression())
    try expect(.rparen)
    return (operand, distinct)
  }

  /// Parses an aggregate's optional `FILTER (WHERE <predicate>)` gate,
  /// returning the predicate, or `nil` when no `FILTER` follows.
  ///
  /// The ISO `<filter clause>` names a search condition an aggregate folds only
  /// the TRUE rows of (a FALSE or UNKNOWN row skipped), so it parses the same
  /// predicate grammar a `WHERE` admits, parenthesised after the `WHERE`
  /// keyword. It applies before the `DISTINCT` dedup (filter, then dedup) and
  /// gates even `COUNT(*)`.
  private mutating func filter() throws(SQLError) -> Predicate? {
    guard try match(.filter) else { return nil }
    try expect(.lparen)
    try expect(.where)
    let predicate = try predicate()
    try expect(.rparen)
    return predicate
  }

  /// Parses a `CASE` expression (the `CASE` is the next token) into the
  /// searched `Expression.case`, admitting both ISO forms.
  ///
  /// A `WHEN` directly after `CASE` is the SEARCHED form — each `WHEN` a full
  /// predicate. An expression after `CASE` is the SIMPLE form's operand — each
  /// `WHEN value` is normalised to the equality `operand = value`, so both
  /// forms share one searched AST. At least one `WHEN` is required; an optional
  /// `ELSE` gives the no-branch result (absent, the result is `NULL`); the
  /// whole is closed by `END`.
  private mutating func conditional() throws(SQLError) -> Expression {
    try expect(.case)
    let operand: Expression? = current?.kind == .when ? nil
                                                       : try expression()

    var whens = Array<When>()
    repeat {
      try expect(.when)
      let when: Predicate = if let operand {
        try .comparison(left: operand, op: .equal, right: expression())
      } else {
        try predicate()
      }
      try expect(.then)
      try whens.append(When(when: when, then: expression()))
    } while current?.kind == .when

    let otherwise: Expression? = if try match(.else) {
      try expression()
    } else {
      nil
    }
    try expect(.end)
    return .case(whens, else: otherwise)
  }

  /// Parses the `CAST` tail — `expression AS type )` (the `CAST (` is already
  /// consumed) — into `Expression.cast`.
  ///
  /// The operand is a full scalar expression; `AS` (already a keyword, shared
  /// with aliasing) separates it from the target `type`, which reuses the same
  /// `type()` domain spellings a `CREATE FUNCTION` parameter or a column type
  /// names (`INTEGER`, `TEXT`, `DOUBLE`, `BOOLEAN`, `BLOB`, …). The whole is
  /// closed by `)`.
  private mutating func cast() throws(SQLError) -> Expression {
    let operand = try expression()
    try expect(.as)
    let type = try type()
    try expect(.rparen)
    return .cast(operand, type)
  }

  /// Parses the argument tail of `COALESCE(v1, v2, …)` — the `(` is already
  /// consumed — into the first-class `Expression.coalesce`.
  ///
  /// ISO 9075 defines `COALESCE(v1, v2, …)` as `CASE WHEN v1 IS NOT NULL THEN
  /// v1 WHEN v2 IS NOT NULL THEN v2 … ELSE NULL END`, but that expansion
  /// re-references each `vi` in both its guard and its `THEN`, evaluating a
  /// stateful argument twice — so this builds the first-class node the engine
  /// evaluates each argument ONCE for, inheriting the same type unification and
  /// coercion the CASE would. At least two arguments are required — `COALESCE`
  /// of one value is the value itself and carries no meaning — else
  /// `SQLError.argument`.
  private mutating func coalesce() throws(SQLError) -> Expression {
    var arguments = try [expression()]
    while try match(.comma) {
      try arguments.append(expression())
    }
    try expect(.rparen)
    guard arguments.count >= 2 else {
      throw .argument("COALESCE requires at least two arguments")
    }
    return .coalesce(arguments)
  }

  /// Parses the argument tail of `NULLIF(v1, v2)` — the `(` is already consumed
  /// — into the first-class `Expression.nullif`.
  ///
  /// ISO 9075 defines `NULLIF(v1, v2)` as `CASE WHEN v1 = v2 THEN NULL ELSE v1
  /// END`, but that expansion embeds `v1` in both the equality and the `ELSE`,
  /// evaluating a stateful `v1` twice — so this builds the first-class node the
  /// engine evaluates `v1` ONCE for. It takes exactly two arguments (else
  /// `SQLError.argument`).
  private mutating func nullif() throws(SQLError) -> Expression {
    let left = try expression()
    try expect(.comma)
    let right = try expression()
    try expect(.rparen)
    return .nullif(left, right)
  }

  /// Parses the tail of `POSITION(substring IN string)` — the `(` is already
  /// consumed — into the ordinary `call("position", [substring, string])` the
  /// registered `position` routine evaluates.
  ///
  /// The ISO syntax separates the two operands with `IN` (already a keyword,
  /// shared with the membership predicate) rather than a comma; `IN` does not
  /// begin at the expression tier, so `expression()` stops at it. The result is
  /// the 1-based position of `substring` in `string`, 0 when absent — the
  /// routine's contract; the desugaring only lowers the special syntax to a
  /// two-argument call. The whole is closed by `)`.
  private mutating func position() throws(SQLError) -> Expression {
    let substring = try expression()
    try expect(.in)
    let string = try expression()
    try expect(.rparen)
    return .call(name: "position", arguments: [substring, string])
  }

  /// Parses the tail of `OVERLAY(string PLACING replacement FROM start [FOR
  /// length])` — the `(` is already consumed — into the ordinary
  /// `call("overlay", [string, replacement, start[, length]])` the registered
  /// `overlay` routine evaluates.
  ///
  /// The ISO syntax separates the operands with the keywords `PLACING`, `FROM`,
  /// and an optional `FOR`, none of which begins at the expression tier, so
  /// each `expression()` stops at the next keyword. The `FOR length` is
  /// OPTIONAL; when omitted, the call is left at THREE arguments and the
  /// routine defaults the length to the replacement's character count from the
  /// single evaluated replacement value — NOT desugared to
  /// `char_length(replacement)`, which would reference the replacement twice
  /// and evaluate a non-deterministic one (`stepper_text()`) once to insert and
  /// again to measure. `overlay`'s optional-tail arity (`minimum` 3) admits
  /// both forms. The whole is closed by `)`.
  private mutating func overlay() throws(SQLError) -> Expression {
    let string = try expression()
    try expect(.placing)
    let replacement = try expression()
    try expect(.from)
    let start = try expression()
    var arguments = [string, replacement, start]
    if try match(.for) {
      try arguments.append(expression())
    }
    try expect(.rparen)
    return .call(name: "overlay", arguments: arguments)
  }
}
