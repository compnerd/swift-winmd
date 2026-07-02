// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A recursive-descent parser over a token stream.
///
/// The grammar is the minimal dialect, extended with a chain of joins:
///
/// ```
/// statement      := with | query | create
/// create         := CREATE VIEW identifier
///                   ['(' identifier (',' identifier)* ')'] AS query
/// with           := WITH [RECURSIVE] cte (',' cte)* query
/// cte            := identifier ['(' identifier (',' identifier)* ')']
///                   AS '(' query ')'
/// query          := select (UNION [ALL] select)*
/// select         := SELECT projection [FROM relation (join)* [where] [order]]
/// relation       := identifier [AS identifier]
/// join           := JOIN relation ON column '=' column
/// projection     := '*' | column (',' column)*
/// where          := WHERE predicate
/// predicate      := disjunction
/// disjunction    := conjunction (OR conjunction)*
/// conjunction    := negation (AND negation)*
/// negation       := NOT negation | primary
/// primary        := '(' predicate ')' | comparison
/// comparison     := expression (op (expression | param) | IS [NOT] NULL)
/// expression     := additive
/// additive       := multiplicative (('+' | '-') multiplicative)*
/// multiplicative := factor (('*' | '/') factor)*
/// factor         := '(' expression ')' | literal | call | column
/// order          := ORDER BY column [ASC | DESC]
/// column         := identifier        // a dotted identifier is qualified
/// ```
///
/// Arithmetic precedence is `*` `/` > `+` `-`, both levels left-associative; the
/// cascade of `additive`/`multiplicative` encodes it, and parentheses override
/// it through `factor`.
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
  ///
  /// A leading `CREATE` selects the `CREATE VIEW` form; a leading `WITH` the
  /// common-table-expression form; anything else is a `query` — a `SELECT` or a
  /// `UNION` of several.
  internal mutating func parse() throws(SQLError) -> Statement {
    let statement = switch current?.kind {
    case .create: try create()
    case .with: try with()
    default: try Statement.select(query())
    }
    if let token = current {
      throw .trailing(at: token.location)
    }
    return statement
  }

  /// Parses `WITH [RECURSIVE] cte (, cte)* query` (the leading `WITH` is the
  /// next token).
  ///
  /// The `RECURSIVE` keyword, when present, marks every CTE of the list
  /// recursive — the SQL standard scopes it to the whole `WITH`, not a single
  /// member — so a member that names itself is admitted. The CTEs parse in
  /// source order, each scoping the trailing query; the query is the same
  /// `select (UNION …)*` form a bare statement is.
  private mutating func with() throws(SQLError) -> Statement {
    try expect(.with)
    let recursive = try match(.recursive)

    var ctes = Array<CTE>()
    try ctes.append(cte(recursive: recursive))
    while try match(.comma) {
      try ctes.append(cte(recursive: recursive))
    }
    return try .with(ctes: ctes, query: query())
  }

  /// Parses one `cte := identifier ['(' identifier (, identifier)* ')'] AS '('
  /// query ')'`, binding it `recursive` per the enclosing `WITH`.
  ///
  /// An explicit `(c, …)` list names the CTE's columns; absent one, the names
  /// are inferred from the query's first arm, exactly as a view's are — the same
  /// arity, naming, and case-insensitive uniqueness rules `columns(_:_:)`
  /// applies.
  private mutating func cte(recursive: Bool) throws(SQLError) -> CTE {
    let name = try identifier()
    let explicit = try names()
    try expect(.as)
    try expect(.lparen)
    let query = try query()
    try expect(.rparen)
    return try CTE(name: name, columns: columns(explicit, query),
                   query: query, recursive: recursive)
  }

  /// Parses an optional parenthesised column-name list `'(' identifier (,
  /// identifier)* ')'`, returning the names, or `nil` when no `(` follows.
  ///
  /// Shared by a `CREATE VIEW`'s and a CTE's explicit column list.
  private mutating func names() throws(SQLError) -> Array<String>? {
    guard try match(.lparen) else { return nil }
    var columns = Array<String>()
    try columns.append(identifier())
    while try match(.comma) {
      try columns.append(identifier())
    }
    try expect(.rparen)
    return columns
  }

  /// Resolves a relation's column names from an `explicit` list (when given) or
  /// the `query`'s first arm, applying the view/CTE naming rules.
  ///
  /// An explicit list must name exactly one column per projected value when the
  /// first arm's arity is statically known — a `.columns`/`.expressions`
  /// projection, but not a `SELECT *`, whose width is known only at resolution —
  /// else `SQLError.columns`. Absent a list, the names are inferred from the
  /// projection (`infer`). The final names — explicit or inferred — must be
  /// case-insensitively unique, matching `Schema.ordinal(of:)`'s resolution, or
  /// the shadowed column would be unreachable (`SQLError.duplicate`).
  private func columns(_ explicit: Array<String>?, _ query: Query)
      throws(SQLError) -> Array<String> {
    if let explicit, let arity = arity(query.first.projection),
        explicit.count != arity {
      throw .columns(expected: arity, got: explicit.count)
    }
    let columns: Array<String> = if let explicit {
      explicit
    } else {
      try infer(query.first.projection)
    }
    var seen = Set<String>()
    for column in columns where !seen.insert(column.lowercased()).inserted {
      throw .duplicate(column)
    }
    return columns
  }

  /// Parses `select (UNION [ALL] select)*`, left-associative.
  ///
  /// The leading `SELECT` is the seed `Query`; each `UNION` (optionally `ALL`)
  /// folds the next `SELECT` onto the right, so `a UNION b UNION c` reads in
  /// source order. `UNION ALL` keeps duplicate rows; a bare `UNION` removes
  /// them — the distinction the engine honours.
  private mutating func query() throws(SQLError) -> Query {
    var query = try Query.select(select())
    while try match(.union) {
      let all = try match(.all)
      query = try .union(query, select(), all: all)
    }
    return query
  }

  /// Parses `CREATE VIEW identifier ['(' identifier (, identifier)* ')'] AS
  /// query` (the leading `CREATE` is the next token).
  ///
  /// An explicit `(col, col, …)` list names the view's columns; absent one, the
  /// names are inferred from the FIRST arm's projection (the ISO rule for a
  /// union's result columns) — the naming, arity, and uniqueness rules
  /// `columns(_:_:)` applies, shared with a CTE's column list.
  private mutating func create() throws(SQLError) -> Statement {
    try expect(.create)
    try expect(.view)
    let name = try identifier()
    let explicit = try names()
    try expect(.as)
    let query = try query()
    return try .create(name: name,
                       view: View(query: query,
                                  columns: columns(explicit, query)))
  }

  /// The number of values `projection` projects, or `nil` when it is not
  /// statically known — a `SELECT *`, whose width depends on the relations it is
  /// resolved against. A `.columns` or `.expressions` projection has a fixed
  /// item count.
  private func arity(_ projection: Projection) -> Int? {
    switch projection {
    case .all:
      nil
    case let .columns(columns):
      columns.count
    case let .expressions(items):
      items.count
    }
  }

  /// Infers a view's column names from its `projection`.
  ///
  /// A `columns` projection yields each reference's name (the qualifier
  /// dropped); an `expressions` projection yields each item's alias, or — for a
  /// bare column with no alias — the column's name; a non-column expression with
  /// no alias, and a `SELECT *`, have no inferable name and fault with
  /// `SQLError.named`.
  private func infer(_ projection: Projection) throws(SQLError)
      -> Array<String> {
    switch projection {
    case .all:
      throw .named("SELECT *")
    case let .columns(columns):
      return columns.map(\.name)
    case let .expressions(items):
      var names = Array<String>()
      for item in items {
        if let alias = item.alias {
          names.append(alias)
        } else if case let .column(column) = item.expression {
          names.append(column.name)
        } else {
          throw .named("an unaliased expression")
        }
      }
      return names
    }
  }

  /// Parses a `SELECT` query.
  ///
  /// `FROM` is optional: a FROM-less `SELECT <expr-list>` projects over a single
  /// empty row (the standard way to compute a scalar, `SELECT 1 + 1`), and so
  /// admits no relation, joins, `WHERE`, or `ORDER BY` to follow.
  private mutating func select() throws(SQLError) -> Select {
    try expect(.select)
    let projection = try projection()
    guard try match(.from) else {
      return Select(projection: projection, from: nil)
    }
    let from = try relation()

    var joins = Array<Join>()
    while try match(.join) {
      try joins.append(join())
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

    return Select(projection: projection, from: from, joins: joins,
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

  /// Parses a scalar expression at the lowest arithmetic precedence (`+` `-`).
  private mutating func expression() throws(SQLError) -> Expression {
    try additive()
  }

  /// Parses `multiplicative (('+' | '-') multiplicative)*`, left-associative.
  private mutating func additive() throws(SQLError) -> Expression {
    var lhs = try multiplicative()
    while true {
      let op: Arithmetic? = if try match(.plus) {
        .add
      } else if try match(.minus) {
        .subtract
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

  /// Parses an arithmetic factor: a parenthesised expression, a string/integer
  /// literal, a function call (`name(args)`), or a bare (possibly-qualified)
  /// column.
  ///
  /// Parentheses override the precedence the cascade encodes. A function call is
  /// an identifier immediately followed by `(`; an identifier not so followed is
  /// a column. The arguments are a comma-separated list of expressions, possibly
  /// empty.
  private mutating func factor() throws(SQLError) -> Expression {
    if try match(.lparen) {
      let expression = try expression()
      try expect(.rparen)
      return expression
    }
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
  ///
  /// A leading `(` is ambiguous: it opens either a parenthesised predicate
  /// (`(a = 1 AND b = 2)`) or the parenthesised left operand of a comparison
  /// (`(Age + 1) = 26`, where `factor` consumes the `(expression)`). The
  /// comparison is tried first; if it fails, the group was a predicate, so the
  /// parser rewinds to the saved lexer and lookahead token and parses it as one.
  private mutating func primary() throws(SQLError) -> Predicate {
    guard current?.kind == .lparen else {
      return try comparison()
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
    return predicate
  }

  /// Parses `expression (op (expression | :parameter) | IS [NOT] NULL)`.
  ///
  /// Either operand may be a column, a literal, or a scalar-function call, so a
  /// predicate can filter on a decoded value (`WHERE guid(Id) = '…'`). A
  /// `:parameter` right operand binds the comparison to a value resolved at run
  /// time from the engine's bindings — the correlated-subquery primitive. An
  /// `IS NULL` (or `IS NOT NULL`) tail tests the left expression for `NULL`
  /// rather than comparing it — the way a nullable column is filtered.
  private mutating func comparison() throws(SQLError) -> Predicate {
    let left = try expression()
    if try match(.is) {
      let negated = try match(.not)
      try expect(.null)
      return .null(left, negated: negated)
    }
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
