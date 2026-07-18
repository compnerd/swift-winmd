// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A recursive-descent parser over a token stream.
///
/// The grammar is the minimal dialect, extended with a chain of joins:
///
/// ```
/// statement      := with | query | create
/// create         := CREATE (view | function)
/// view           := VIEW identifier
///                   ['(' identifier (',' identifier)* ')'] AS query
/// function       := FUNCTION identifier '(' [param (',' param)*] ')'
///                   RETURNS type AS expression
/// param          := identifier type
/// type           := INTEGER | INT | REAL | FLOAT | DOUBLE | VARCHAR | TEXT
///                 | CHAR | BOOLEAN | BOOL | BLOB | BINARY
/// with           := WITH [RECURSIVE] cte (',' cte)* query
/// cte            := identifier ['(' identifier (',' identifier)* ')']
///                   AS '(' query ')'
/// query          := intersection ((UNION | EXCEPT) [ALL] intersection)*
/// intersection   := term (INTERSECT [ALL] term)*
/// term           := select | TABLE identifier   // TABLE t = SELECT * FROM t
/// select         := SELECT [DISTINCT | ALL] projection
///                   [FROM relation (join)*
///                    [where] [group] [having] [order] [limit]]
/// relation       := (identifier | [LATERAL] derived) [AS identifier]
///                   // LATERAL is legal only on a derived table in a join
/// derived        := '(' query ')' AS identifier  // a derived table (aliased)
/// join           := ([INNER | (LEFT | RIGHT | FULL) [OUTER]] JOIN
///                     relation ON predicate)
///                  | (CROSS JOIN relation)  // Cartesian product, no ON/USING
///                   // INNER JOIN LATERAL = CROSS APPLY, LEFT = OUTER APPLY;
///                   // the derived body may reference preceding FROM items
/// projection     := '*' | column (',' column)*
/// where          := WHERE predicate
/// group          := GROUP BY column (',' column)*
/// having         := HAVING predicate
/// predicate      := disjunction
/// disjunction    := conjunction (OR conjunction)*
/// conjunction    := negation (AND negation)*
/// negation       := NOT negation | [NOT] EXISTS '(' query ')' | primary
/// primary        := '(' predicate ')' [IS [NOT] truthvalue] | comparison
/// comparison     := row (op row | [NOT] IN '(' row (',' row)* ')')
///                 | expression (op (quantifier '(' query ')'
///                                    | expression | param)
///                 | IS [NOT] (NULL | truthvalue | DISTINCT FROM expression)
///                 | [NOT] IN '(' (expression (',' expression)* | query) ')'
///                 | [NOT] LIKE (expression | param)
///                     [ESCAPE (expression | param)]
///                 | [NOT] BETWEEN (expression | param) AND
///                                 (expression | param))
/// row            := '(' expression (',' expression)+ ')'  // ISO row value;
///                   // a comma marks it, else '(' expression ')' is a scalar
/// quantifier     := ANY | SOME | ALL      // SOME is a synonym for ANY
/// truthvalue     := TRUE | FALSE | UNKNOWN
/// expression     := additive
/// additive       := multiplicative (('+' | '-' | '||') multiplicative)*
/// multiplicative := factor (('*' | '/') factor)*
/// factor         := subquery | '(' expression ')' | case | cast | coalesce
///                 | nullif | position | overlay | literal | aggregate | call
///                 | column
/// subquery       := '(' query ')'  // scalar: yields <= 1 row x 1 col at run
/// case           := CASE [expression] (WHEN (predicate | expression) THEN
///                     expression)+ [ELSE expression] END
/// cast           := CAST '(' expression AS type ')'
/// coalesce       := COALESCE '(' expression (',' expression)+ ')'
/// nullif         := NULLIF '(' expression ',' expression ')'
/// position       := POSITION '(' expression IN expression ')'
/// overlay        := OVERLAY '(' expression PLACING expression FROM expression
///                     [FOR expression] ')'
/// literal        := string | integer | decimal | TRUE | FALSE | blob
/// blob           := ('x' | 'X') "'" (hex hex)* "'"  // whole bytes
/// aggregate      := COUNT '(' '*' ')' [filter]
///                 | (COUNT | SUM | MIN | MAX | AVG)
///                     '(' [DISTINCT | ALL] expression ')' [filter]
/// filter         := FILTER '(' WHERE predicate ')'
/// order          := ORDER BY key (',' key)*
/// key            := (integer | expression) [ASC | DESC]
/// limit          := [OFFSET integer ROWS]
///                   [FETCH (FIRST | NEXT) [integer] ROWS ONLY]
/// column         := identifier        // a dotted identifier is qualified
/// identifier     := word | '"' … '"'  // a delimited identifier is verbatim
/// ```
///
/// Arithmetic precedence is `*` `/` > `+` `-` `||`, both levels
/// left-associative; the cascade of `additive`/`multiplicative` encodes it (the
/// `||` string concatenation sharing the additive tier), and parentheses
/// override it through `factor`.
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
  /// A leading `CREATE` selects the `CREATE VIEW`/`CREATE FUNCTION` form; a
  /// leading `WITH` the common-table-expression form; anything else is a
  /// `query` — a `SELECT` or a `UNION` of several.
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
  /// are inferred from the query's first arm, exactly as a view's are — the
  /// same arity, naming, and case-insensitive uniqueness rules `columns(_:_:)`
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
  /// projection, but not a `SELECT *`, whose width is known only at resolution
  /// — else `SQLError.columns`. Absent a list, the names are inferred from the
  /// projection (`Projection.names()`). The final names — explicit or inferred
  /// — must be case-insensitively unique, matching `Schema.ordinal(of:)`'s
  /// resolution, or the shadowed column would be unreachable
  /// (`SQLError.duplicate`).
  private func columns(_ explicit: Array<String>?, _ query: Query)
      throws(SQLError) -> Array<String> {
    if let explicit, let arity = arity(query.first.projection),
        explicit.count != arity {
      throw .columns(expected: arity, got: explicit.count)
    }
    let columns: Array<String> = if let explicit {
      explicit
    } else {
      try query.first.projection.names()
    }
    var seen = Set<String>()
    for column in columns where !seen.insert(column.lowercased()).inserted {
      throw .duplicate(column)
    }
    return columns
  }

  /// Parses `intersection ((UNION | EXCEPT) [ALL] intersection)*`, the outer
  /// set-operation tier, left-associative.
  ///
  /// The leading `intersection` is the seed `Query`; each `UNION`/`EXCEPT`
  /// (optionally `ALL`) folds the next `intersection` onto the right, so a
  /// same-precedence chain (`a UNION b EXCEPT c`) reads left to right.
  /// `INTERSECT` binds TIGHTER — it lives in the inner `intersection` tier — so
  /// `a UNION b INTERSECT c` parses as `a UNION (b INTERSECT c)`, the ISO
  /// precedence. `ALL` keeps duplicate rows per the operator's multiplicity; a
  /// bare operator removes them — the distinction the engine honours.
  private mutating func query() throws(SQLError) -> Query {
    var query = try intersection()
    while let kind: SetOperation = if try match(.union) { .union }
                                   else if try match(.except) { .except }
                                   else { nil } {
      let all = try match(.all)
      query = try .setop(kind, query, intersection(), all: all)
    }
    return query
  }

  /// Parses `term (INTERSECT [ALL] term)*`, the inner set-operation tier,
  /// left-associative.
  ///
  /// The leading `term` is the seed `Query`; each `INTERSECT` (optionally
  /// `ALL`) folds the next `term` onto the right. `INTERSECT` binds tighter
  /// than `UNION`/`EXCEPT`, so this tier is fully consumed before the outer
  /// `query` tier folds a `UNION`/`EXCEPT` around it. `INTERSECT ALL` keeps
  /// duplicate rows to the lesser multiplicity; a bare `INTERSECT` removes
  /// them.
  private mutating func intersection() throws(SQLError) -> Query {
    var query = try term()
    while try match(.intersect) {
      let all = try match(.all)
      query = try .setop(.intersect, query, term(), all: all)
    }
    return query
  }

  /// Parses a query primary — a `SELECT …` or the ISO `TABLE t` shorthand — the
  /// leaf both set-operation tiers compose over.
  ///
  /// `TABLE t` is exactly `SELECT * FROM t` (ISO 9075 `<explicit table>`): it
  /// lowers to the SAME AST a star-projection single-relation select builds — a
  /// `.all` projection over one named `Relation`, no `WHERE`/`GROUP`/`HAVING`/
  /// order/limit — so compile, execute, and the `SELECT *` column expansion all
  /// apply unchanged and it composes with `UNION`/`INTERSECT`/`EXCEPT` as a
  /// parenthesised select would. The operand is a bare table or view NAME (the
  /// same `identifier` a relation names); a derived table is not admitted, as
  /// `TABLE (…)` is not an ISO form. Ordering is a select-internal clause here,
  /// so a `TABLE t ORDER BY …` tail is not accepted at this primary level — the
  /// `SELECT * FROM t ORDER BY …` spelling carries an order.
  private mutating func term() throws(SQLError) -> Query {
    guard try match(.table) else {
      return try .select(select())
    }
    let name = try identifier()
    return .select(Select(projection: .all, from: Relation(name: name)))
  }

  /// Parses a `CREATE` statement — `CREATE VIEW …` or `CREATE FUNCTION …` (the
  /// leading `CREATE` is the next token). The keyword after `CREATE` selects
  /// the form.
  private mutating func create() throws(SQLError) -> Statement {
    try expect(.create)
    if try match(.function) {
      return try function()
    }
    try expect(.view)
    return try view()
  }

  /// Parses the `VIEW` tail — `identifier ['(' identifier (, identifier)* ')']
  /// AS query` (the `CREATE VIEW` is already consumed).
  ///
  /// An explicit `(col, col, …)` list names the view's columns; absent one, the
  /// names are inferred from the FIRST arm's projection (the ISO rule for a
  /// union's result columns) — the naming, arity, and uniqueness rules
  /// `columns(_:_:)` applies, shared with a CTE's column list.
  private mutating func view() throws(SQLError) -> Statement {
    let name = try identifier()
    let explicit = try names()
    try expect(.as)
    let query = try query()
    return try .create(name: name,
                       view: View(query: query,
                                  columns: columns(explicit, query)))
  }

  /// Parses the `FUNCTION` tail — `identifier '(' [param (, param)*] ')'
  /// RETURNS type AS expression` (the `CREATE FUNCTION` is already consumed),
  /// each `param` an `identifier type`.
  ///
  /// The parameter list is parenthesised and may be empty (`f() RETURNS …`).
  /// The body is a single scalar `expression` over the declared parameters, so
  /// a call binds its arguments to the parameter names and evaluates it. The
  /// parameter names must be case-insensitively unique — the body resolves a
  /// reference against them, and a duplicate would make the shadowed one
  /// unreachable — else `SQLError.duplicate`.
  private mutating func function() throws(SQLError) -> Statement {
    let name = try identifier()
    try expect(.lparen)
    var parameters = Array<Function.Parameter>()
    if current?.kind != .rparen {
      try parameters.append(parameter())
      while try match(.comma) {
        try parameters.append(parameter())
      }
    }
    try expect(.rparen)

    var seen = Set<String>()
    for parameter in parameters
        where !seen.insert(parameter.name.lowercased()).inserted {
      throw .duplicate(parameter.name)
    }

    try expect(.returns)
    let returns = try type()
    try expect(.as)
    let body = try expression()
    return .function(name: name,
                     function: Function(parameters: parameters,
                                        returns: returns, body: body))
  }

  /// Parses one function parameter — `identifier type`.
  private mutating func parameter() throws(SQLError) -> Function.Parameter {
    let name = try identifier()
    let type = try type()
    return Function.Parameter(name: name, type: type)
  }

  /// Parses a value type — an ISO data-type spelling — into a `ValueType`.
  ///
  /// The single-word domains map directly: `INTEGER`/`INT` to `.integer`,
  /// `REAL`/`FLOAT`/`DOUBLE` to `.double`, `VARCHAR`/`TEXT`/`CHAR` to `.text`,
  /// `BOOLEAN`/`BOOL` to `.boolean`, `BLOB`/`BINARY` to `.blob` — matched
  /// case-insensitively, so a type is written bare like a keyword. A spelling
  /// none of these name is `SQLError.unexpected`.
  private mutating func type() throws(SQLError) -> ValueType {
    let token = try advance(expecting: "a type")
    guard case let .identifier(text) = token.kind else {
      throw .unexpected(token.kind.description,
                        expected: "a type", at: token.location)
    }
    switch text.uppercased() {
    case "INTEGER", "INT": return .integer
    case "REAL", "FLOAT", "DOUBLE": return .double
    case "VARCHAR", "TEXT", "CHAR": return .text
    case "BOOLEAN", "BOOL": return .boolean
    case "BLOB", "BINARY": return .blob
    default:
      throw .unexpected(text, expected: "a type", at: token.location)
    }
  }

  /// The number of values `projection` projects, or `nil` when it is not
  /// statically known — a `SELECT *`, whose width depends on the relations it
  /// is resolved against. A `.columns` or `.expressions` projection has a fixed
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

  /// Parses a `SELECT` query.
  ///
  /// `FROM` is optional: a FROM-less `SELECT <expr-list>` projects over a
  /// single empty row (the standard way to compute a scalar, `SELECT 1 + 1`),
  /// and so admits no relation, joins, `WHERE`, `ORDER BY`, or `LIMIT` to
  /// follow.
  private mutating func select() throws(SQLError) -> Select {
    try expect(.select)
    // An optional set quantifier: `DISTINCT` deduplicates the result rows;
    // `ALL` (the default when neither is written) keeps every row.
    let distinct = try match(.distinct)
    if !distinct { _ = try match(.all) }
    let projection = try projection()
    guard try match(.from) else {
      return Select(distinct: distinct, projection: projection, from: nil)
    }
    let from = try relation()

    var joins = Array<Join>()
    while let kind = try joinKind() {
      try joins.append(join(kind.kind, cross: kind.cross))
    }
    let predicate: Predicate? = if try match(.where) {
      try predicate()
    } else {
      nil
    }
    let grouping = try match(.group) ? try grouping() : []
    let having: Predicate? = if try match(.having) {
      try self.predicate()
    } else {
      nil
    }
    let order: Order? = if try match(.order) {
      try order()
    } else {
      nil
    }
    let limit = try rowLimit()

    return Select(distinct: distinct, projection: projection, from: from,
                  joins: joins, predicate: predicate, grouping: grouping,
                  having: having, order: order, limit: limit)
  }

  /// Parses `BY column (, column)*` (the `GROUP` keyword is already consumed) —
  /// the `GROUP BY` grouping columns, in source order.
  private mutating func grouping() throws(SQLError) -> Array<Column> {
    try expect(.by)
    var columns = Array<Column>()
    try columns.append(column())
    while try match(.comma) {
      try columns.append(column())
    }
    return columns
  }

  // MARK: - Relation

  /// Parses a relation — a named base relation/view/CTE, or a DERIVED TABLE (a
  /// parenthesised subquery) — with its alias.
  ///
  /// A leading `(` is disambiguated by ONE token of lookahead: a `SELECT` after
  /// it begins a derived table `(SELECT …) AS t` (the query may itself be a
  /// `UNION`), so it parses `query`; anything else is a parenthesised relation
  /// `(a JOIN b)`, which this dialect does not yet accept in a relation
  /// position. The peek is unambiguous — `SELECT` never begins a relation
  /// name — exactly as the scalar-subquery and `IN (…)` lookaheads are, so
  /// no rewind is needed.
  ///
  /// An optional leading `LATERAL` marks the derived table lateral (ISO
  /// `LATERAL (query)`): its body may reference the PRECEDING FROM items, so it
  /// re-evaluates per their rows. `LATERAL` introduces a derived table alone —
  /// a `(SELECT …)` must follow — so a `LATERAL` before a named relation
  /// faults.
  ///
  /// Derived table's alias is REQUIRED (ISO): `FROM (SELECT …)` with no `AS t`
  /// faults. A named relation's alias is optional and may be introduced by `AS`
  /// (`TypeDef AS t`) or written directly after the name (`TypeDef t`); the
  /// latter is admitted only when the next token is a bare identifier, so a
  /// following keyword (`JOIN`, `WHERE`, …) or the end of input is not mistaken
  /// for an alias.
  private mutating func relation() throws(SQLError) -> Relation {
    let lateral = try match(.lateral)
    if try match(.lparen) {
      guard let token = current else {
        throw .incomplete(expected: "a derived table '(SELECT …)'")
      }
      // A derived table is any query, so `TABLE t` opens one as `SELECT` does.
      guard [.select, .table].contains(token.kind) else {
        throw .unexpected(token.kind.description,
                          expected: "a derived table '(SELECT …)'",
                          at: token.location)
      }
      let query = try query()
      try expect(.rparen)
      // ISO requires a derived table be named, so the alias is MANDATORY — an
      // `AS`-less spelling faults rather than binding an unnamed relation.
      guard try match(.as) || isName(current?.kind) else {
        guard let token = current else {
          throw .incomplete(expected: "'AS' and an alias for the derived table")
        }
        throw .unexpected(token.kind.description,
                          expected: "'AS' and an alias for the derived table",
                          at: token.location)
      }
      return try Relation(derived: query, as: identifier(), lateral: lateral)
    }
    // `LATERAL` introduces a derived table; a named relation may not follow it.
    if lateral {
      guard let token = current else {
        throw .incomplete(expected: "a derived table after LATERAL")
      }
      throw .unexpected(token.kind.description,
                        expected: "a derived table '(SELECT …)' after LATERAL",
                        at: token.location)
    }
    let name = try identifier()
    let alias: String? = if try match(.as) {
      try identifier()
    } else if isName(current?.kind) {
      try identifier()
    } else {
      nil
    }
    return Relation(name: name, alias: alias)
  }

  /// Whether `kind` begins an identifier — a bare or a delimited name — the
  /// token an optional (`AS`-less) relation alias may start with, so a
  /// following keyword or the end of input is not mistaken for an alias.
  private func isName(_ kind: Token.Kind?) -> Bool {
    switch kind {
    case .identifier, .quoted: true
    default: false
    }
  }

  /// Parses an optional join `kind` and its `JOIN` keyword at the current
  /// position, or `nil` when no join clause begins here. The `cross` flag marks
  /// a `CROSS JOIN` — an unqualified Cartesian product taking no `ON`/`USING`.
  ///
  /// A bare `JOIN` (or an explicit `INNER JOIN`) is `.inner`; `LEFT`/`RIGHT`/
  /// `FULL` introduce an outer join, each admitting an optional `OUTER` noise
  /// word before the mandatory `JOIN`; `CROSS` introduces a Cartesian product,
  /// lowered as an `.inner` join over a synthesized always-true predicate. A
  /// leading `INNER`/`CROSS`/`LEFT`/`RIGHT`/`FULL` commits to a join clause, so
  /// a missing `JOIN` after it faults rather than silently ending the chain.
  private mutating func joinKind()
      throws(SQLError) -> (kind: Join.Kind, cross: Bool)? {
    if try match(.join) { return (.inner, false) }
    if try match(.cross) {
      // `CROSS JOIN` is the Cartesian product; it carries no inner/outer word
      // and no `ON`, and lowers as an `.inner` join over an always-true `on`.
      try expect(.join)
      return (.inner, true)
    }
    let kind: Join.Kind
    if try match(.inner) {
      kind = .inner
    } else if try match(.left) {
      kind = .left
    } else if try match(.right) {
      kind = .right
    } else if try match(.full) {
      kind = .full
    } else {
      return nil
    }
    // `OUTER` is an optional noise word on `LEFT`/`RIGHT`/`FULL`; `INNER` never
    // carries it. Either way `JOIN` must follow.
    if kind != .inner { _ = try match(.outer) }
    try expect(.join)
    return (kind, false)
  }

  /// Parses the join tail (the `kind` and `JOIN` keyword are already consumed):
  /// a relation and, unless `cross`, an `ON` and an arbitrary boolean predicate
  /// — the same grammar a `WHERE` admits, so a join relates its sides by an
  /// equality, an inequality, an expression equality, or any `AND`/`OR`/`NOT`
  /// of comparisons. A pure `column = column` conjunct hash-joins; the rest is
  /// a residual filter.
  ///
  /// A `CROSS JOIN` (`cross`) takes NO `ON`/`USING` — a trailing `ON` is a
  /// syntax error, caught by leaving `on` unconsumed for the caller's `where`/
  /// end-of-select expectation to reject. Its `on` is a synthesized `1 = 1`,
  /// which lowers to a constant-true filter the optimiser elides, collapsing
  /// the join to a bare `.product` — the Cartesian product, equivalent to an
  /// inner join written `ON 1 = 1`.
  private mutating func join(_ kind: Join.Kind,
                             cross: Bool) throws(SQLError) -> Join {
    let relation = try relation()
    guard cross else {
      try expect(.on)
      let on = try predicate()
      return Join(relation: relation, kind: kind, on: on)
    }
    let on = Predicate.comparison(left: .literal(.integer(1)), op: .equal,
                                  right: .literal(.integer(1)))
    return Join(relation: relation, kind: kind, on: on)
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
      // parenthesised expression: a `SELECT` or `TABLE` begins a subquery —
      // `(query)`, the first-class `Expression.subquery` (the query may itself
      // be a `UNION`) — and anything else begins a parenthesised expression. No
      // rewind is needed: neither keyword begins an expression, so the peek is
      // unambiguous, exactly as the `IN (…)` and `EXISTS (…)` lookaheads are.
      if [.select, .table].contains(current?.kind) {
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

    var arguments = Array<Expression>()
    if current?.kind != .rparen {
      try arguments.append(expression())
      while try match(.comma) {
        try arguments.append(expression())
      }
    }
    try expect(.rparen)
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

  /// Parses `NOT negation`, `[NOT] EXISTS (query)`, or a primary.
  ///
  /// `EXISTS` is a complete predicate with NO left operand — `EXISTS (Q)` — so
  /// it is recognised HERE, ahead of the comparison tier a left expression
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
  /// `(expression)`). A COMMA inside the parentheses marks the row form, which
  /// `row()` detects and COMMITS to — a row is never a valid predicate, so its
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
  /// expression)+ ')'`, at least TWO elements — returning its element
  /// expressions, or `nil` when the current token does not open one so the
  /// caller falls through to the scalar path.
  ///
  /// A leading `(` is ambiguous between a row and a parenthesised scalar
  /// (`(x)`), or an arithmetic group (`(a + b)`): only a COMMA inside the
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
  /// constructor>` is already parsed to `left`, building the FIRST-CLASS AST
  /// node (`Predicate.rows` / `Predicate.among`) rather than desugaring it —
  /// each component `Expression` is held once so the lowering evaluates it
  /// exactly once per row, the correctness fix over a desugar that duplicated a
  /// component across the places a conjunction/cascade names it.
  ///
  /// A relational operator (`= <> < <= > >=`) takes a second row constructor of
  /// EQUAL arity (else `SQLError.arity`), building `Predicate.rows(left, op,
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
  /// over `left` and the parsed element rows, each of EQUAL arity (else
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
  /// After the opening `(`, ONE token of lookahead disambiguates the two forms:
  /// a `SELECT` begins a subquery — `left [NOT] IN (query)`, the first-class
  /// `Predicate.within` (the query may itself be a `UNION`) — and anything
  /// else begins the value list, a non-empty run of comma-separated
  /// expressions, the `Predicate.membership`. No rewind is needed: `SELECT`
  /// never begins an expression, so the peek is unambiguous.
  private mutating func membership(_ left: Expression, negated: Bool)
      throws(SQLError) -> Predicate {
    try expect(.lparen)
    if [.select, .table].contains(current?.kind) {
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
  /// It is the ISO null-safe comparison of the two expressions: TWO-VALUED
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
  /// keyword and builds the first-class node the engine evaluates `x` ONCE for,
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

  // MARK: - Order

  /// Parses `BY key (',' key)*` — a comma-separated list of sort keys, each a
  /// sort value and its own optional `ASC`/`DESC` — into an `Order` (the
  /// `ORDER` keyword is already consumed). The keys read in source order, major
  /// to minor.
  private mutating func order() throws(SQLError) -> Order {
    try expect(.by)
    var keys = [try key()]
    while try match(.comma) {
      try keys.append(key())
    }
    return Order(keys: keys)
  }

  /// Parses one sort key — `(integer | expression) [ASC | DESC]`, the direction
  /// defaulting to ascending.
  ///
  /// A BARE integer-literal sort key is an ISO output-column ORDINAL (`ORDER BY
  /// 1` names the first projected column, 1-based), never the integer constant
  /// — ordering by a constant is meaningless, so the standard reads a lone
  /// integer here as a select-list position. The key parses as a full value
  /// `expression` unconditionally and then CLASSIFIES: an expression that is
  /// exactly a bare integer literal becomes the ordinal, everything else stays
  /// an `expression`. This keeps `ORDER BY 1 + A` and `ORDER BY 2 * Price` the
  /// arithmetic expressions they are, and subsumes a bare column (`ORDER BY
  /// Name`) and an arbitrary computation (`ORDER BY a + b`, `ORDER BY
  /// UPPER(Name)`).
  private mutating func key() throws(SQLError) -> Order.Key {
    let sort: Order.Key.Sort
    switch try expression() {
    case let .literal(.integer(ordinal)):
      sort = .ordinal(ordinal)
    case let value:
      sort = .expression(value)
    }

    var ascending = true
    if try match(.desc) {
      ascending = false
    } else {
      _ = try match(.asc)
    }
    return Order.Key(sort: sort, ascending: ascending)
  }

  // MARK: - Row limiting

  /// Parses the standard row-limiting tail — `[OFFSET n ROWS] [FETCH { FIRST |
  /// NEXT } [n] ROWS ONLY]` — into a `Limit`, or `nil` when neither clause is
  /// present.
  ///
  /// The two ISO clauses are independent: an `OFFSET` without a `FETCH` skips
  /// rows with no cap (`count` `nil`), a `FETCH` without an `OFFSET` caps from
  /// the start. `ROW` and `ROWS` are interchangeable, as are `FIRST` and
  /// `NEXT`, and the `FETCH` count defaults to `1` when omitted (`FETCH FIRST
  /// ROW ONLY`). Both counts are non-negative integer literals; a bare or
  /// negative spelling is not one (the lexer scans a `-` as its own token), so
  /// it faults as any other misplaced token would.
  private mutating func rowLimit() throws(SQLError) -> Limit? {
    let offset: Int
    if try match(.offset) {
      offset = try count()
      try expect(.rows)
    } else {
      offset = 0
    }

    let cap: Int?
    if try match(.fetch) {
      try expect(.first)
      cap = if case .integer = current?.kind { try count() } else { 1 }
      try expect(.rows)
      try expect(.only)
    } else {
      cap = nil
    }

    if offset == 0 && cap == nil { return nil }
    return Limit(count: cap, offset: offset)
  }

  // MARK: - Terminals

  /// Consumes a non-negative integer literal and returns its value — an
  /// `OFFSET` skip or a `FETCH` row count.
  private mutating func count() throws(SQLError) -> Int {
    let token = try advance(expecting: "an integer")
    guard case let .integer(value) = token.kind else {
      throw .unexpected(token.kind.description,
                        expected: "an integer", at: token.location)
    }
    return value
  }

  /// Consumes an identifier — bare or delimited — as its text and whether it
  /// was delimited (double-quoted). A delimited name is verbatim, so a caller
  /// building a column keeps a dot in it as part of the name rather than a
  /// qualifier.
  private mutating func name()
      throws(SQLError) -> (text: String, quoted: Bool) {
    let token = try advance(expecting: "an identifier")
    switch token.kind {
    case let .identifier(text):
      return (text, false)
    case let .quoted(text):
      return (text, true)
    default:
      throw .unexpected(token.kind.description,
                        expected: "an identifier", at: token.location)
    }
  }

  /// Consumes an identifier — bare or delimited — and returns its name. Callers
  /// that name a relation, alias, or CTE take the text alone; the delimited
  /// flag matters only where a dot could be a qualifier (`column`).
  private mutating func identifier() throws(SQLError) -> String {
    try name().text
  }

  /// Consumes an identifier and parses it as a column reference.
  ///
  /// A bare identifier's qualifying dot is part of the one token the lexer
  /// scans, so `Column(_:)` splits it (`t.Name` → qualifier `t`, name `Name`).
  /// A delimited identifier is verbatim, so a dot in it belongs to an
  /// unqualified name (`"a.b"` is the column `a.b`, not `a`.`b`).
  private mutating func column() throws(SQLError) -> Column {
    let ident = try name()
    return ident.quoted ? Column(name: ident.text) : Column(ident.text)
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
