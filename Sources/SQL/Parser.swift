// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A recursive-descent parser over a token stream.
///
/// The grammar is the minimal dialect, extended with a single binary join:
///
/// ```
/// statement   := select
/// select      := SELECT projection FROM relation [join] [where] [order]
/// relation    := identifier [AS identifier]
/// join        := JOIN relation ON column '=' column
/// projection  := '*' | column (',' column)*
/// where       := WHERE predicate
/// predicate   := disjunction
/// disjunction := conjunction (OR conjunction)*
/// conjunction := negation (AND negation)*
/// negation    := NOT negation | primary
/// primary     := '(' predicate ')' | comparison
/// comparison  := column op literal
/// order       := ORDER BY column [ASC | DESC]
/// column      := identifier        // a dotted identifier is qualified
/// ```
///
/// A `column` is a single identifier token; a qualifying dot (`t.Name`) is part
/// of the identifier the lexer scans, so `Column(_:)` splits it into qualifier
/// and name.
///
/// Predicate precedence is `NOT` > `AND` > `OR`; the cascade of methods encodes
/// it, and parentheses override it through `primary`.
///
/// The parser pulls tokens from the `Lexer` on demand, holding a single token
/// of lookahead in `current`; `advance()` lexes the next one. No token array is
/// ever materialised.
internal struct Parser: ~Escapable {
  private var lexer: Lexer
  private var current: Token?

  @_lifetime(copy lexer)
  internal init(_ lexer: consuming Lexer) throws(SQLError) {
    self.lexer = lexer
    self.current = try self.lexer.next()
  }

  // MARK: - Statement

  /// Parses a complete statement and asserts the input is exhausted.
  internal mutating func parse() throws(SQLError) -> Statement {
    let statement = try Statement.select(select())
    if let token = current {
      throw .trailing(at: token.location)
    }
    return statement
  }

  /// Parses a `SELECT` query.
  private mutating func select() throws(SQLError) -> Select {
    try expect(.select)
    let projection = try projection()
    try expect(.from)
    let from = try relation()

    let join: Join? = if try match(.join) {
      try join()
    } else {
      nil
    }
    let predicate: Predicate? = if try match(.where) {
      try predicate()
    } else {
      nil
    }
    let order: Order? = if try match(.order) {
      try order()
    } else {
      nil
    }

    return Select(projection: projection, from: from, join: join,
                  predicate: predicate, order: order)
  }

  // MARK: - Relation

  /// Parses a relation name and an optional alias.
  ///
  /// The alias may be introduced by `AS` (`TypeDef AS t`) or written directly
  /// after the name (`TypeDef t`); the latter is admitted only when the next
  /// token is a bare identifier, so a following keyword (`JOIN`, `WHERE`, …) or
  /// the end of input is not mistaken for an alias.
  private mutating func relation() throws(SQLError) -> Relation {
    let name = try identifier()
    let alias: String? = if try match(.as) {
      try identifier()
    } else if case .identifier = current?.kind {
      try identifier()
    } else {
      nil
    }
    return Relation(name: name, alias: alias)
  }

  /// Parses the join tail (the `JOIN` keyword is already consumed): a relation,
  /// `ON`, and a single `column = column` equality.
  private mutating func join() throws(SQLError) -> Join {
    let relation = try relation()
    try expect(.on)
    let left = try column()
    try expect(.equal)
    let right = try column()
    return Join(relation: relation, left: left, right: right)
  }

  // MARK: - Projection

  /// Parses `*` or a comma-separated list of projected items, each an
  /// expression with an optional `AS` alias.
  ///
  /// A list of bare columns with no alias collapses to the simpler `columns`
  /// projection (the backward-compatible path); a list carrying any function
  /// call or alias is the richer `expressions` projection.
  private mutating func projection() throws(SQLError) -> Projection {
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

  /// Parses a scalar expression: a string/integer literal, a function call
  /// (`name(args)`), or a bare (possibly-qualified) column.
  ///
  /// A function call is an identifier immediately followed by `(`; an identifier
  /// not so followed is a column. The arguments are a comma-separated list of
  /// expressions, possibly empty.
  private mutating func expression() throws(SQLError) -> Expression {
    if case let .string(value) = current?.kind {
      _ = try advance(expecting: "a literal")
      return .literal(.string(value))
    }
    if case let .integer(value) = current?.kind {
      _ = try advance(expecting: "a literal")
      return .literal(.integer(value))
    }

    let name = try identifier()
    guard try match(.lparen) else {
      return .column(Column(name))
    }

    var arguments = Array<Expression>()
    if current?.kind != .rparen {
      try arguments.append(expression())
      while try match(.comma) {
        try arguments.append(expression())
      }
    }
    try expect(.rparen)
    return .call(name: name, arguments: arguments)
  }

  // MARK: - Predicate

  /// Parses a predicate at the lowest precedence (`OR`).
  private mutating func predicate() throws(SQLError) -> Predicate {
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

  /// Parses `NOT negation` or a primary.
  private mutating func negation() throws(SQLError) -> Predicate {
    if try match(.not) {
      return try .not(negation())
    }
    return try primary()
  }

  /// Parses a parenthesised predicate or a comparison.
  private mutating func primary() throws(SQLError) -> Predicate {
    if try match(.lparen) {
      let predicate = try predicate()
      try expect(.rparen)
      return predicate
    }
    return try comparison()
  }

  /// Parses `expression op (expression | :parameter)`.
  ///
  /// Either operand may be a column, a literal, or a scalar-function call, so a
  /// predicate can filter on a decoded value (`WHERE guid(Id) = '…'`). A
  /// `:parameter` right operand binds the comparison to a value resolved at run
  /// time from the engine's bindings — the correlated-subquery primitive.
  private mutating func comparison() throws(SQLError) -> Predicate {
    let left = try expression()
    let op = try op()
    if case let .parameter(name) = current?.kind {
      _ = try advance(expecting: "a parameter")
      return .bound(left: left, op: op, parameter: name)
    }
    let right = try expression()
    return .comparison(left: left, op: op, right: right)
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

  /// Parses a string or integer literal.
  private mutating func literal() throws(SQLError) -> Literal {
    let token = try advance(expecting: "a literal")
    return switch token.kind {
    case let .string(value): .string(value)
    case let .integer(value): .integer(value)
    default:
      throw .unexpected(token.kind.description,
                        expected: "a literal", at: token.location)
    }
  }

  // MARK: - Order

  /// Parses `BY identifier [ASC | DESC]` (the `ORDER` keyword is already
  /// consumed).
  private mutating func order() throws(SQLError) -> Order {
    try expect(.by)
    let column = try column()

    var ascending = true
    if try match(.desc) {
      ascending = false
    } else {
      _ = try match(.asc)
    }
    return Order(column: column, ascending: ascending)
  }

  // MARK: - Terminals

  /// Consumes an identifier and returns its name.
  private mutating func identifier() throws(SQLError) -> String {
    let token = try advance(expecting: "an identifier")
    guard case let .identifier(name) = token.kind else {
      throw .unexpected(token.kind.description,
                        expected: "an identifier", at: token.location)
    }
    return name
  }

  /// Consumes an identifier and parses it as a (possibly-qualified) column.
  ///
  /// A qualifying dot is part of the identifier the lexer scans, so the column
  /// reference is one identifier token that `Column(_:)` splits.
  private mutating func column() throws(SQLError) -> Column {
    try Column(identifier())
  }

  // MARK: - Cursor

  /// Consumes and returns the current token, faulting at the end of input.
  private mutating func advance(expecting expectation: String)
      throws(SQLError) -> Token {
    guard let token = current else {
      throw .incomplete(expected: expectation)
    }
    current = try lexer.next()
    return token
  }

  /// Consumes the current token if it has `kind`, reporting whether it did.
  private mutating func match(_ kind: Token.Kind) throws(SQLError) -> Bool {
    guard let token = current, token.kind == kind else { return false }
    current = try lexer.next()
    return true
  }

  /// Consumes a token of `kind`, faulting otherwise.
  private mutating func expect(_ kind: Token.Kind) throws(SQLError) {
    let token = try advance(expecting: "'\(kind.description)'")
    guard token.kind == kind else {
      throw .unexpected(token.kind.description,
                        expected: "'\(kind.description)'",
                        at: token.location)
    }
  }
}
