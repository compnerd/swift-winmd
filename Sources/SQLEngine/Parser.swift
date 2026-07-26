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
///                   returns type AS expression
/// param          := identifier type
/// type           := INTEGER | INT | REAL | FLOAT | DOUBLE | VARCHAR | TEXT
///                 | CHAR | BOOLEAN | BOOL | BLOB | BINARY
/// with           := WITH [RECURSIVE] cte (',' cte)* query
/// cte            := identifier ['(' identifier (',' identifier)* ')']
///                   AS '(' query ')'
/// query          := intersection ((UNION | EXCEPT) [ALL] intersection)*
/// intersection   := term (INTERSECT [ALL] term)*
/// term           := select | TABLE identifier | values
///                   // TABLE t = SELECT * FROM t
/// values         := VALUES tuple (',' tuple)*  // ISO table value constructor;
///                   // desugars to a UNION ALL of FROM-less constant SELECTs
/// tuple          := '(' expression (',' expression)* ')'
/// select         := SELECT [DISTINCT | ALL] projection
///                   [FROM relation (join)*
///                    [where] [group] [having] [order] [limit]]
/// relation       := (identifier | [LATERAL] derived) [AS identifier]
///                   // LATERAL is legal only on a derived table in a join
/// derived        := '(' query ')' AS identifier  // a derived table (aliased);
///                   // the query may be a SELECT, TABLE t, or VALUES (…)
/// join           := ([NATURAL] [INNER | (LEFT | RIGHT | FULL) [OUTER]] JOIN
///                     relation [ON predicate | USING '(' identifier
///                                (',' identifier)* ')'])
///                     // ON and USING are mutually exclusive, and NATURAL bars
///                     // both (its columns are the shared ones); a non-NATURAL
///                     // non-CROSS join requires exactly one of ON/USING
///                  | (CROSS JOIN relation)  // Cartesian product, no ON/USING
///                   // INNER JOIN LATERAL = CROSS APPLY, LEFT = OUTER APPLY;
///                   // the derived body may reference preceding FROM items
/// projection     := '*' | column (',' column)*
/// where          := WHERE predicate
/// group          := GROUP BY element (',' element)*
///                   // the elements' grouping-set lists are CROSS-producted
///                   // into one set list; a purely ordinary clause stays plain
///                   // GROUP BY keys, and any ROLLUP/CUBE/GROUPING SETS makes
///                   // the whole clause a GROUPING SETS — a UNION ALL of
///                   // per-set arms expanded at compile/schema time (by
///                   // resolved identity), not here
/// element        := set | rollup | cube | sets  // set = an ordinary set
/// rollup         := ROLLUP '(' [unit (',' unit)*] ')'  // n+1 prefixes
/// cube           := CUBE '(' [unit (',' unit)*] ')'    // 2ⁿ unit subsets
/// sets           := GROUPING SETS '(' element (',' element)* ')'  // nests
/// unit           := set  // a ROLLUP/CUBE unit is an ordinary set
/// set            := expression | '(' [expression (',' expression)*] ')'
///                   // '()' is the grand-total set; a top-level ordinary key
///                   // is a bare scalar expression ('(SELECT 1)' a subquery);
///                   // ROLLUP/CUBE/GROUPING/SETS are context identifiers, not
///                   // keywords — ROLLUP/CUBE open only before a '(', and
///                   // GROUPING only before SETS
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
  internal var lexer: Lexer
  internal var current: Token?
  // `internal`, not `private`: a speculative parse in another parser extension
  // (`membership`'s `IN ((query))` disambiguation) must save and restore the
  // full cursor — lexer, current, AND this lookahead buffer — on rewind.
  internal var pending: Token?

  @_lifetime(copy lexer)
  internal init(_ lexer: consuming Lexer) throws(SQLError) {
    self.lexer = lexer
    self.current = try self.lexer.next()
    self.pending = nil
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
  /// `INTERSECT` binds tighter — it lives in the inner `intersection` tier — so
  /// `a UNION b INTERSECT c` parses as `a UNION (b INTERSECT c)`, the ISO
  /// precedence. `ALL` keeps duplicate rows per the operator's multiplicity; a
  /// bare operator removes them — the distinction the engine honours.
  internal mutating func query() throws(SQLError) -> Query {
    var (query, parenthesized) = try intersection()
    while let kind: SetOperation = if try match(.union) { .union }
                                   else if try match(.except) { .except }
                                   else { nil } {
      let all = try match(.all)
      query = try .setop(kind, query, intersection().query, all: all)
      parenthesized = false
    }
    // ISO 9075: an `ORDER BY` / `OFFSET`·`FETCH` binds to the whole `<query
    // expression body>` — a set operation, or a single primary — never to an
    // arm. `select()` does not consume it, so no arm eats a query-level tail;
    // parse it once here and apply it by scope.
    let order: Order? = try match(.order) ? try self.order() : nil
    let limit = try rowLimit()
    guard order != nil || limit != nil else { return query }
    // A bare simple select (not parenthesised) carries the tail on itself,
    // resolved under its own full scope — an `ORDER BY` over a non-projected
    // column resolves, as a derived table's does; `select()` consumes no tail,
    // so such a select has none of its own yet. Everything else — a set
    // operation, or a parenthesised primary — carries the outer tail on an
    // output-scoped `ordered` carrier, so `(SELECT n FROM B) ORDER BY m` faults
    // on the non-output `m` rather than sorting by a hidden column. A
    // parenthesised primary that already has its own inner tail rides a second
    // carrier — `(SELECT … ORDER BY … FETCH 1) ORDER BY …` has two independent,
    // separately scoped tails (the inner picks the operand's rows, the outer
    // orders that primary's result), the ISO nesting boundary — not a `42601`
    // duplicate-clause error.
    if case let .select(select) = query, !parenthesized {
      return .select(Select(distinct: select.distinct,
                            projection: select.projection, from: select.from,
                            joins: select.joins, predicate: select.predicate,
                            grouping: select.grouping, having: select.having,
                            order: order, limit: limit))
    }
    return .ordered(query, distinct: false, order: order, limit: limit,
                    generated: 0)
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
  private mutating func intersection()
      throws(SQLError) -> (query: Query, parenthesized: Bool) {
    var (query, parenthesized) = try term()
    while try match(.intersect) {
      let all = try match(.all)
      query = try .setop(.intersect, query, term().query, all: all)
      // A set operation is no longer a single parenthesised primary, so an
      // outer tail is output-scoped through the `.setop` carrier path anyway.
      parenthesized = false
    }
    return (query, parenthesized)
  }

  /// Parses a query primary — a `SELECT …`, a parenthesised query expression
  /// `( … )`, the ISO `TABLE t` shorthand, or the ISO `VALUES (…), …` table
  /// value constructor — the leaf both set-operation tiers compose over.
  ///
  /// A parenthesised `( <query expression> )` is the ISO `<query primary>` that
  /// groups a set operation explicitly and carries a per-operand `ORDER BY`/
  /// `OFFSET`·`FETCH`: `(A UNION B) INTERSECT C` overrides the default
  /// INTERSECT-binds-tighter precedence, and `(SELECT … ORDER BY … FETCH n)
  /// UNION …` takes the top `n` of one operand before the union. A `(` in this
  /// query-primary position always begins a parenthesised query — no other form
  /// starts with one here — so it is consumed without lookahead. The inner
  /// `query()` parses that operand's own tail inside the parentheses and binds
  /// it (on the operand's select, or an `ordered` carrier over its union), a
  /// plain `select`/`setop`/`ordered` `Query` the enclosing tier composes.
  ///
  /// `TABLE t` is exactly `SELECT * FROM t` (ISO 9075 `<explicit table>`): it
  /// lowers to the same AST a star-projection single-relation select builds — a
  /// `.all` projection over one named `Relation` — so compile, execute, and
  /// the `SELECT *` column expansion all apply unchanged and it composes with
  /// `UNION`/`INTERSECT`/`EXCEPT`. The operand is a bare table or view name
  /// (the same `identifier` a relation names); a derived table is not admitted,
  /// as `TABLE (…)` is not an ISO form. A trailing `TABLE t ORDER BY …` binds
  /// to the enclosing query expression (`query()` takes it), as after any
  /// primary — the primary itself carries no order.
  ///
  /// `VALUES (…), …` desugars to a `UNION ALL` of FROM-less constant selects
  /// (see `values()`); a trailing `ORDER BY`/limit binds to the enclosing
  /// query expression, as after any primary.
  private mutating func term()
      throws(SQLError) -> (query: Query, parenthesized: Bool) {
    if try match(.lparen) {
      // A parenthesised `<query expression>` — the inner `query()` parses its
      // own `ORDER BY`/limit inside the parentheses and binds it to this
      // operand (a lone select carries it on itself, a set operation on an
      // `ordered` carrier). The operand's tail is bounded by the parentheses;
      // a trailing tail after the `)` is the enclosing query expression's,
      // taken by that `query()`. A `(` in query-primary position always begins
      // a parenthesised query — no other primary starts with one — so it is
      // consumed without lookahead. The `parenthesized` flag rides back so the
      // enclosing `query()` resolves any outer tail against this primary's
      // output columns, not the from-clause scope hidden inside it.
      let query = try query()
      try expect(.rparen)
      return (query, true)
    }
    if try match(.table) {
      let name = try identifier()
      return (.select(Select(projection: .all, from: Relation(name: name))),
              false)
    }
    if current?.kind == .values {
      return (try values(), false)
    }
    return (.select(try select()), false)
  }

  /// Parses the ISO `<table value constructor>` `VALUES (v, …), (v, …), …` (the
  /// `VALUES` keyword is the next token), desugaring it to a `UNION ALL` of
  /// FROM-less constant `SELECT`s — no new AST node, so `compile`, execute, the
  /// per-column type unification, and set-operation composition all apply
  /// unchanged.
  ///
  /// Each parenthesised row is a tuple of scalar expressions (usually literals,
  /// but any row-independent expression is admitted, since a FROM-less `SELECT`
  /// evaluates it over the single empty row). Every row must have equal arity —
  /// a mismatch is `SQLError.arity` — and there is at least one row, each with
  /// at least one element (the parser rejects an empty `VALUES ()`). The rows
  /// lower to `SELECT v, … UNION ALL SELECT v, …` in source order, so `UNION
  /// ALL` preserves both the order and any duplicate rows.
  ///
  /// The constructor's DEFAULT column names are the ISO `column1, column2, …`,
  /// emitted as the FIRST arm's projection aliases (the ISO rule that a set
  /// operation's result columns come from its first arm) so a `SELECT column1
  /// FROM (VALUES …) AS t` names them. A per-column `ValueType` unifies across
  /// the rows through the same set-operation schema derivation `UNION` uses (a
  /// column mixing integer and double widens to double), so this parse only
  /// shapes the desugar and leaves the typing to resolution.
  private mutating func values() throws(SQLError) -> Query {
    try expect(.values)

    var rows = Array<Array<Expression>>()
    try rows.append(tuple())
    while try match(.comma) {
      try rows.append(tuple())
    }

    // Every row constructs the same number of columns; a later row of a
    // different arity is an ISO arity error.
    let arity = rows[0].count
    for row in rows.dropFirst() where row.count != arity {
      throw .arity(arity, row.count)
    }

    // The FIRST arm carries the default `column1, column2, …` output names as
    // explicit aliases; the ISO first-arm rule propagates them to the result.
    // Later arms need no aliases — a set operation names its result from the
    // first arm alone — so they project the bare expressions.
    var query = Query.select(row(rows[0], named: true))
    for arm in rows.dropFirst() {
      query = .setop(.union, query, .select(row(arm, named: false)),
                     all: true)
    }
    return query
  }

  /// Builds one `VALUES` arm — a FROM-less `SELECT` projecting `row`'s element
  /// expressions. The FIRST arm (`named`) aliases each column `column1,
  /// column2, …` (the constructor's default names); a later arm leaves them
  /// bare, as a set operation names its result from the first arm alone.
  private func row(_ row: Array<Expression>, named: Bool) -> Select {
    let items = row.enumerated().map { (index, expression) in
      Projected(expression: expression,
                alias: named ? "column\(index + 1)" : nil)
    }
    return Select(projection: .expressions(items), from: nil)
  }

  /// Parses one parenthesised `VALUES` row — `'(' expression (',' expression)*
  /// ')'` — returning its element expressions, at least one required (an empty
  /// `()` faults).
  private mutating func tuple() throws(SQLError) -> Array<Expression> {
    try expect(.lparen)
    var elements = try [expression()]
    while try match(.comma) {
      try elements.append(expression())
    }
    try expect(.rparen)
    return elements
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
  /// returns type AS expression` (the `CREATE FUNCTION` is already consumed),
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
  internal mutating func type() throws(SQLError) -> ValueType {
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
      try joins.append(join(kind.kind, cross: kind.cross,
                            natural: kind.natural))
    }
    let predicate: Predicate? = if try match(.where) {
      try predicate()
    } else {
      nil
    }
    let grouping = try match(.group) ? try grouping() : .keys([])
    let having: Predicate? = if try match(.having) {
      try self.predicate()
    } else {
      nil
    }

    // ORDER BY / OFFSET·FETCH are not consumed here: they belong to the
    // enclosing `<query expression>`, not this `<query specification>`, so
    // `query()` parses the tail once over the whole body — no set-operation arm
    // eats a query-level tail — and applies it (on a lone select, or an
    // `ordered` carrier over a union). The `GROUP BY` tail is stored as-parsed:
    // a `.keys` ordinary key list (or none) or a `.sets` `GROUPING SETS (…)`
    // list expanded into a `UNION ALL` of per-arm groupings at compile and
    // schema time (by resolved identity), not desugared here.
    return Select(distinct: distinct, projection: projection, from: from,
                  joins: joins, predicate: predicate, grouping: grouping,
                  having: having, order: nil, limit: nil)
  }

  /// Parses `BY <element> (',' <element>)*` (the `GROUP` keyword is already
  /// consumed) — the ISO comma list of grouping elements, cross-producted into
  /// one grouping-set list.
  ///
  /// Each element yields a set list (`Array<Array<Expression>>`): an ordinary
  /// key is the single-set list `[[key]]`; `ROLLUP`/`CUBE`/`GROUPING SETS`
  /// yield their expanded set lists (see `element`). The whole clause is the
  /// product of the elements' set lists — one result set per combination, the
  /// concatenation of the chosen sets — so `GROUP BY a, ROLLUP(b, c)` crosses
  /// `[[a]]` with `[[b, c], [b], []]` into `[[a, b, c], [a, b], [a]]`.
  ///
  /// A purely ordinary clause (no `ROLLUP`/`CUBE`/`GROUPING SETS`) returns
  /// `.keys` — the plain path, so `GROUP BY a, b` stays `.keys([a, b])`. Any
  /// construct makes the whole clause `.sets`, which the shared `expand`
  /// desugars to a `UNION ALL` of per-set arms (Stage 1), so `ROLLUP`/`CUBE`
  /// reuse that machinery verbatim.
  ///
  /// Each ordinary key parses as a general scalar `expression` (a column, an
  /// arithmetic/`||` expression, a function call, a `CASE`/`COALESCE`, …),
  /// resolved and lowered through `scope.term`; a bare identifier is itself an
  /// `Expression.column`, so `GROUP BY col` is unchanged and a `NATURAL`/
  /// `USING` merged key still lowers through the join scope.
  private mutating func grouping() throws(SQLError) -> Grouping {
    try expect(.by)
    // The grouping sets, built left to right from the single empty set (`[[]]`,
    // the identity), and whether ANY element was a construct — the flag that
    // chooses `.sets` over the plain `.keys` path.
    var product: Array<Array<Expression>> = [[]]
    var construct = false
    var total = 0
    repeat {
      let (sets, opens) = try element()
      construct = construct || opens
      if sets.count == 1 {
        // A single-set element (an ordinary key, or `()`) appends its keys to
        // every set so far — O(keys) per element, keeping a purely ordinary
        // `GROUP BY a, b, …` linear rather than O(n²) via `cross`. Its keys are
        // copied into every set, so bound the reference growth first.
        let added = product.count * sets[0].count
        guard total + added <= Limits.references else { throw overflow }
        for index in product.indices { product[index] += sets[0] }
        total += added
      } else {
        // A multi-set element (a construct) needs the cross product. Bound its
        // growth before `cross` allocates it — the set count (`sets / count`
        // also keeps the multiply from overflowing) and the reference total,
        // which the cross multiplies to `sets × total + product × expressions`.
        let expressions = references(of: sets)
        guard product.count <= Limits.sets / sets.count else {
          throw .state("54001",
                       "GROUP BY produces too many grouping sets (max 4096)")
        }
        let grown = sets.count * total + product.count * expressions
        guard grown <= Limits.references else { throw overflow }
        total = grown
        product = cross(product, sets)
      }
    } while try match(.comma)
    // A purely ordinary clause is a single set (each element appended its keys
    // in source order) — the plain `.keys` path. An explicit `GROUP BY ()` is
    // the exception: it resolves to a single empty set, which must stay the
    // grand total `.sets([[]])`, NOT collapse to `.keys([])` — the shape an
    // absent `GROUP BY` carries, which `Select.aggregates` reads as no grouping
    // (one row per input row rather than one grand-total group).
    if construct || product == [[]] {
      return .sets(product)
    }
    return .keys(product[0])
  }

  /// Parses one grouping element into its set list, with a flag marking whether
  /// it is a construct (`ROLLUP`/`CUBE`/`GROUPING SETS`) rather than an
  /// ordinary set — the flag `grouping` ORs to choose `.keys` over `.sets`.
  ///
  /// `ROLLUP`/`CUBE`/`GROUPING`/`SETS` are context identifiers, not lexer
  /// keywords: a bare `GROUPING` immediately followed by a bare `SETS` opens a
  /// (possibly nested) `GROUPING SETS`; a bare `ROLLUP`/`CUBE` immediately
  /// followed by `(` opens that construct. A delimited `"rollup"` (a `.quoted`,
  /// not `.identifier`), or a bare `rollup`/`cube`/`grouping` NOT so followed,
  /// falls through to an ordinary key — so those words stay usable as column
  /// names (ISO reserves them; a UDF named `rollup`/`cube` cannot be a bare
  /// grouping key, which is acceptable). The two-token lookahead (`secondary`)
  /// resolves each prefix before consuming any token.
  ///
  /// A leading `(` opens a composite ordinary set — a comma list `(a, b, …)` or
  /// the grand-total `()` — via `composite`, which rewinds a single `(a)`, a
  /// parenthesised expression `(a + b)` / `(a) + 1`, or a scalar subquery
  /// `(SELECT 1)` so it reads as one ordinary key `expression`. The same
  /// disambiguation applies at the top level and inside a `GROUPING SETS` list.
  private mutating func element() throws(SQLError)
      -> (sets: Array<Array<Expression>>, construct: Bool) {
    if case let .identifier(text) = current?.kind,
        text.uppercased() == "GROUPING",
        case let .identifier(next) = try secondary()?.kind,
        next.uppercased() == "SETS" {
      return (try sets(), true)
    }
    if case let .identifier(text) = current?.kind {
      switch text.uppercased() {
      case "ROLLUP":
        if try secondary()?.kind == .lparen { return (try rollup(), true) }
      case "CUBE":
        if try secondary()?.kind == .lparen { return (try cube(), true) }
      default:
        break
      }
    }
    if let keys = try composite() {
      return ([keys], false)
    }
    return ([[try expression()]], false)
  }

  /// Parses the `GROUPING SETS '(' element (',' element)* ')'` construct — the
  /// `GROUPING` and `SETS` context identifiers are the next two tokens
  /// (confirmed by `element`) — into one set list: the concatenation of each
  /// contained element's set list, in source order. Elements nest — a member
  /// may be an ordinary set, a `ROLLUP`/`CUBE`, or another `GROUPING SETS`. At
  /// least one element is required.
  private mutating func sets() throws(SQLError) -> Array<Array<Expression>> {
    _ = try advance(expecting: "GROUPING")
    _ = try advance(expecting: "SETS")
    try expect(.lparen)
    var result = try element().sets
    var total = references(of: result)
    while try match(.comma) {
      let more = try element().sets
      total += references(of: more)
      result += more
      // Members may themselves be constructs (`GROUPING SETS (CUBE(…), …)`);
      // cap both the set count (4096, the clause-wide ceiling) and the
      // reference total so a concatenation cannot amass unboundedly before
      // `grouping`'s guard.
      guard result.count <= Limits.sets else {
        throw .state("54001",
                     "GROUP BY produces too many grouping sets (max 4096)")
      }
      guard total <= Limits.references else { throw overflow }
    }
    try expect(.rparen)
    return result
  }

  /// Parses a `ROLLUP '(' unit (',' unit)* ')'` element (the `ROLLUP` context
  /// identifier is `current`) into its `n + 1` grouping sets — the descending
  /// prefixes of the `n` units. `ROLLUP(a, b)` yields `[[a, b], [a], []]`;
  /// `ROLLUP((a, b), c)` yields `[[a, b, c], [a, b], []]`.
  private mutating func rollup() throws(SQLError) -> Array<Array<Expression>> {
    let units = try units()
    // A ROLLUP of n units materialises n + 1 prefixes whose sizes sum to
    // O(n²) expression references — before `grouping`'s 4096-set guard runs, so
    // a large but compact input (a 100,000-unit ROLLUP) would exhaust memory
    // rather than fault. Reject the arity here first: n + 1 sets must stay
    // within the 4096 cap, so n ≤ 4095.
    guard units.count <= 4095 else {
      throw .state("54001",
                   "GROUP BY ROLLUP supports at most 4095 grouping elements")
    }
    // As with CUBE, a unit is copied into up to n + 1 prefixes, so a large
    // composite unit multiplies. Bound the projected expansion — at most
    // (n + 1) × the units' total expressions — before building the prefixes.
    let budget = Limits.references / (units.count + 1)
    guard references(of: units) <= budget else { throw overflow }
    return prefixes(of: units)
  }

  /// Parses a `CUBE '(' unit (',' unit)* ')'` element (the `CUBE` context
  /// identifier is `current`) into its `2ⁿ` grouping sets — one per subset of
  /// the `n` units. `CUBE(a, b)` yields `[[a, b], [b], [a], []]`.
  private mutating func cube() throws(SQLError) -> Array<Array<Expression>> {
    let units = try units()
    // A CUBE of n units enumerates 2ⁿ subsets. Reject a large arity before the
    // `1 << n` shift: at n ≥ 63 it overflows `Int` (wrapping negative, then to
    // zero at 64), silently yielding no sets — later misreported as "requires
    // at least one set" — and even a moderate n eagerly allocates
    // exponentially many arrays. 2¹² = 4096 sets is the cap.
    guard units.count <= 12 else {
      throw .state("54001",
                   "GROUP BY CUBE supports at most 12 grouping elements")
    }
    // units.count alone is not enough: each unit is copied into 2ⁿ⁻¹ of the 2ⁿ
    // subsets, so a large composite unit `(a, a, …)` multiplies its expressions
    // across them. Bound the projected expansion — 2ⁿ⁻¹ × the units' total
    // expressions — before building the subsets.
    let budget = Limits.references / (1 << max(units.count - 1, 0))
    guard references(of: units) <= budget else { throw overflow }
    return subsets(of: units)
  }

  /// Parses the `'(' [unit (',' unit)*] ')'` unit list shared by `ROLLUP`/
  /// `CUBE` (the context identifier is consumed here). Each unit is an ordinary
  /// set — a bare key or a parenthesised `(a, b)` composite that groups as one
  /// indivisible level. An empty list (`ROLLUP()`/`CUBE()`) is admitted and
  /// collapses to the single empty grand-total set.
  private mutating func units() throws(SQLError) -> Array<Array<Expression>> {
    _ = try advance(expecting: "ROLLUP or CUBE")
    try expect(.lparen)
    guard !(try match(.rparen)) else { return [] }
    var units = try [unit()]
    while try match(.comma) {
      try units.append(unit())
    }
    try expect(.rparen)
    return units
  }

  /// Parses one `ROLLUP`/`CUBE` unit — an ordinary set. A leading `(` opens a
  /// parenthesised `(a, b)` / `()` composite unless it merely starts a scalar
  /// key — `(a) + 1`, `(a + b)`, or a scalar subquery `(SELECT …)`, whose own
  /// parenthesis `expression` consumes — which `composite` rewinds; otherwise
  /// the unit is a bare scalar key.
  private mutating func unit() throws(SQLError) -> Array<Expression> {
    if let keys = try composite() { return keys }
    return [try expression()]
  }

  /// A parenthesised composite grouping set — the grand-total `()` or a comma
  /// list `(a, b, …)` — returning its keys, or `nil` (having rewound the full
  /// parser state) when the `(` instead begins a single scalar key that merely
  /// starts with a parenthesis: a parenthesised expression `(a + b)` / `(a) +
  /// 1`, or a scalar subquery `(SELECT …)`.
  ///
  /// The committing signal — an empty `()` or a top-level comma — sits an
  /// unbounded distance past the `(` (the first key is an arbitrary
  /// expression), so no fixed lookahead decides it: speculatively read past
  /// the `(`, commit to a set only on `()` or a top-level comma (the
  /// row-constructor rule), else rewind the `lexer`, `current`, AND the
  /// `pending` lookahead so the caller reads one ordinary key `expression`.
  private mutating func composite() throws(SQLError) -> Array<Expression>? {
    guard case .lparen = current?.kind else { return nil }
    let lexer = self.lexer
    let token = self.current
    let buffer = self.pending
    try expect(.lparen)
    if try match(.rparen) { return [] }
    if current?.kind != .select, current?.kind != .table,
        current?.kind != .values,
        let first = try? expression(), try match(.comma) {
      var keys = [first]
      repeat {
        try keys.append(expression())
      } while try match(.comma)
      try expect(.rparen)
      return keys
    }
    self.lexer = lexer
    self.current = token
    self.pending = buffer
    return nil
  }

  /// The descending prefixes of a unit list — the `ROLLUP` set list. For `n`
  /// units it is `n + 1` sets: units `1..n` concatenated, then `1..n-1`, …,
  /// down to the empty grand-total set. An empty unit list (`ROLLUP()`) yields
  /// the single empty set `[[]]`.
  private func prefixes(of units: Array<Array<Expression>>)
      -> Array<Array<Expression>> {
    var result = Array<Array<Expression>>()
    var index = units.count
    while index >= 0 {
      result.append(units.prefix(index)
                         .reduce(into: Array<Expression>()) { $0 += $1 })
      index -= 1
    }
    return result
  }

  /// Every subset of a unit list — the `CUBE` set list — enumerated
  /// FULL-SET-FIRST by descending subset mask (bit `i` selects unit `i`, units
  /// concatenated in source order). For `n` units it is `2ⁿ` sets, the full set
  /// first and the empty grand-total set last. An empty unit list (`CUBE()`)
  /// yields the single empty set `[[]]`.
  private func subsets(of units: Array<Array<Expression>>)
      -> Array<Array<Expression>> {
    var result = Array<Array<Expression>>()
    var mask = 1 << units.count
    while mask > 0 {
      mask -= 1
      var keys = Array<Expression>()
      for (index, member) in units.enumerated() where mask & (1 << index) != 0 {
        keys += member
      }
      result.append(keys)
    }
    return result
  }

  /// The CROSS product of two set lists — for each set on the left and each on
  /// the right, their concatenation — the operator that combines the successive
  /// `GROUP BY` elements. The seed `[[]]` (the single empty set) is its
  /// identity.
  private func cross(_ left: Array<Array<Expression>>,
                     _ right: Array<Array<Expression>>)
      -> Array<Array<Expression>> {
    var result = Array<Array<Expression>>()
    for lhs in left {
      for rhs in right {
        result.append(lhs + rhs)
      }
    }
    return result
  }

  /// The caps bounding `GROUP BY` grouping-set expansion — the single source
  /// of truth for every artificial limit the desugar enforces, so they are
  /// tracked and tunable in one place (every guard below cites one of these).
  /// `sets` is the most grouping sets a clause may expand to; `references` the
  /// most expression references those sets may hold in total. Both bound a
  /// compact but heavily-duplicating clause — a wide `CUBE`/`ROLLUP`, a cross
  /// product, a concatenation — from exhausting memory. The per-construct arity
  /// guards derive from `sets`: `CUBE ≤ 12` units (2¹² = `sets`) and `ROLLUP ≤
  /// 4095` units (n + 1 ≤ `sets`) reject before the 2ⁿ / prefix expansion.
  private enum Limits {
    static let sets = 4096
    static let references = 1 << 20
  }

  /// The total expression references across a grouping-set list — the memory an
  /// expansion materialises. Bounded by `Limits.references` (with the
  /// `Limits.sets` count cap) at every producing site so a compact but
  /// heavily-duplicating construct — a CUBE copying a large composite unit
  /// across 2ⁿ⁻¹ subsets, a cross product, a concatenation — cannot allocate
  /// unboundedly.
  private func references(of sets: Array<Array<Expression>>) -> Int {
    sets.reduce(0) { $0 + $1.count }
  }

  /// The program-limit fault raised when a grouping expansion would materialise
  /// more than the budgeted `Limits.references` expression references.
  private var overflow: SQLError {
    .state("54001", "GROUP BY expands too many grouping expressions")
  }

  // MARK: - Relation

  /// Parses a relation — a named base relation/view/CTE, or a derived TABLE (a
  /// parenthesised subquery) — with its alias.
  ///
  /// A leading `(` is disambiguated by one token of lookahead: a `SELECT` after
  /// it begins a derived table `(SELECT …) AS t` (the query may itself be a
  /// `UNION`), so it parses `query`; anything else is a parenthesised relation
  /// `(a JOIN b)`, which this dialect does not yet accept in a relation
  /// position. The peek is unambiguous — `SELECT` never begins a relation
  /// name — exactly as the scalar-subquery and `IN (…)` lookaheads are, so
  /// no rewind is needed.
  ///
  /// An optional leading `LATERAL` marks the derived table lateral (ISO
  /// `LATERAL (query)`): its body may reference the preceding FROM items, so it
  /// re-evaluates per their rows. `LATERAL` introduces a derived table alone —
  /// a `(SELECT …)` must follow — so a `LATERAL` before a named relation
  /// faults.
  ///
  /// Derived table's alias is required (ISO): `FROM (SELECT …)` with no `AS t`
  /// faults. A named relation's alias is optional and may be introduced by `AS`
  /// (`TypeDef AS t`) or written directly after the name (`TypeDef t`); the
  /// latter is admitted only when the next token is a bare identifier, so a
  /// following keyword (`JOIN`, `WHERE`, …) or the end of input is not mistaken
  /// for an alias.
  ///
  /// Either alias may carry an ISO explicit output column list `'(' identifier
  /// (, identifier)* ')'` (`AS t(c, d)`), positionally renaming the relation's
  /// output columns — admitted on both a derived table and a named relation.
  /// The list's arity and case-insensitive uniqueness are checked where the
  /// output width is known (the schema-derivation seam), not here, so a list
  /// over a `SELECT *` derived table (whose width resolves later) parses.
  ///
  /// `relation := [LATERAL] ('(' query ')' | identifier) [[AS] alias ['('
  /// identifier (, identifier)* ')']]`
  private mutating func relation() throws(SQLError) -> Relation {
    let lateral = try match(.lateral)
    if try match(.lparen) {
      guard let token = current else {
        throw .incomplete(expected: "a derived table '(SELECT …)'")
      }
      // A derived table is any query, so `TABLE t`, `VALUES (…)`, and a nested
      // parenthesised query primary `((SELECT …))` each open one as `SELECT`
      // does. There is no value-list alternative in a FROM position, so a
      // leading `(` is unambiguously a nested query primary.
      guard [.select, .table, .values, .lparen].contains(token.kind) else {
        throw .unexpected(token.kind.description,
                          expected: "a derived table '(SELECT …)'",
                          at: token.location)
      }
      let query = try query()
      try expect(.rparen)
      // ISO requires a derived table be named, so the alias is mandatory — an
      // `AS`-less spelling faults rather than binding an unnamed relation.
      guard try match(.as) || isName(current?.kind) else {
        guard let token = current else {
          throw .incomplete(expected: "'AS' and an alias for the derived table")
        }
        throw .unexpected(token.kind.description,
                          expected: "'AS' and an alias for the derived table",
                          at: token.location)
      }
      let alias = try identifier()
      return try Relation(derived: query, as: alias,
                          columns: names() ?? [], lateral: lateral)
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
    // An explicit column list requires an alias to key the renamed columns
    // under (`T(c, d)` with no alias is ISO-invalid); the `names()` peek only
    // fires when an alias was taken, so a bare `T` never consumes a following
    // grouping's `(`.
    let columns = alias == nil ? [] : try names() ?? []
    return Relation(name: name, alias: alias, columns: columns)
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
  /// a `CROSS JOIN` — an unqualified Cartesian product taking no `ON`/`USING` —
  /// and `natural` a `NATURAL` join, whose columns are the ones the two sides
  /// share (resolved by name, so it takes no `ON`/`USING` either).
  ///
  /// A bare `JOIN` (or an explicit `INNER JOIN`) is `.inner`; `LEFT`/`RIGHT`/
  /// `FULL` introduce an outer join, each admitting an optional `OUTER` noise
  /// word before the mandatory `JOIN`; `CROSS` introduces a Cartesian product,
  /// lowered as an `.inner` join over a synthesized always-true predicate. A
  /// leading `NATURAL` prefixes any of the inner/outer varieties (`NATURAL
  /// [INNER | LEFT | RIGHT | FULL [OUTER]] JOIN`), but not `CROSS`. A leading
  /// `NATURAL`/`INNER`/`CROSS`/`LEFT`/`RIGHT`/`FULL` commits to a join clause,
  /// so a missing `JOIN` after it faults rather than silently ending the chain.
  private mutating func joinKind()
      throws(SQLError) -> (kind: Join.Kind, cross: Bool, natural: Bool)? {
    let natural = try match(.natural)
    if try match(.join) { return (.inner, false, natural) }
    // `CROSS` is a product join taking no criterion, so `NATURAL CROSS` is
    // ill-formed; reject it rather than silently drop the `NATURAL`.
    if !natural, try match(.cross) {
      // `CROSS JOIN` is the Cartesian product; it carries no inner/outer word
      // and no `ON`, and lowers as an `.inner` join over an always-true `on`.
      try expect(.join)
      return (.inner, true, false)
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
    } else if natural {
      // A `NATURAL` with no inner/outer word is a `NATURAL [INNER] JOIN`; the
      // mandatory `JOIN` must follow.
      try expect(.join)
      return (.inner, false, true)
    } else {
      return nil
    }
    // `OUTER` is an optional noise word on `LEFT`/`RIGHT`/`FULL`; `INNER` never
    // carries it. Either way `JOIN` must follow.
    if kind != .inner { _ = try match(.outer) }
    try expect(.join)
    return (kind, false, natural)
  }

  /// Parses the join tail (the `kind` and `JOIN` keyword are already consumed):
  /// a relation and its join criterion. A plain join takes exactly one of `ON
  /// <predicate>` (an arbitrary boolean expression, the same grammar a `WHERE`
  /// admits, so a join relates its sides by an equality, an inequality, an
  /// expression equality, or any `AND`/`OR`/`NOT` of comparisons — a pure
  /// `column = column` conjunct hash-joins, the rest a residual filter) or
  /// `USING '(' identifier (, identifier)* ')'` (the named-column shorthand,
  /// resolved into an equality `on` and a coalesced `SELECT *` at compile). A
  /// `NATURAL` join (`natural`) takes neither — its columns are the shared ones
  /// — so a trailing `ON`/`USING` after it faults; a plain non-`CROSS` join
  /// requires exactly one of them.
  ///
  /// A `CROSS JOIN` (`cross`) takes no criterion — a trailing `ON`/`USING` is a
  /// syntax error, caught by leaving it unconsumed for the caller's `where`/
  /// end-of-select expectation to reject. Its `on` is a synthesized `1 = 1`,
  /// which lowers to a constant-true filter the optimiser elides, collapsing
  /// the join to a bare `.product` — the Cartesian product, equivalent to an
  /// inner join written `ON 1 = 1`.
  private mutating func join(_ kind: Join.Kind, cross: Bool,
                             natural: Bool) throws(SQLError) -> Join {
    let relation = try relation()
    if natural {
      // A `NATURAL` join resolves its columns by name; an `ON`/`USING` after it
      // is ill-formed (its criterion is fixed), so leave the token for the
      // caller's clause expectation to reject.
      return Join(relation: relation, kind: kind, using: .natural)
    }
    if cross {
      let on = Predicate.comparison(left: .literal(.integer(1)), op: .equal,
                                    right: .literal(.integer(1)))
      return Join(relation: relation, kind: kind, on: on)
    }
    if try match(.using) {
      // `USING` requires a parenthesised, non-empty column list; `names()`
      // yields `nil` when no `(` follows, which is a syntax error here.
      guard let columns = try names() else {
        guard let token = current else {
          throw .incomplete(expected: "'(' after USING")
        }
        throw .unexpected(token.kind.description, expected: "'(' after USING",
                          at: token.location)
      }
      return Join(relation: relation, kind: kind, using: .columns(columns))
    }
    try expect(.on)
    let on = try predicate()
    return Join(relation: relation, kind: kind, on: on)
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
  /// A bare integer-literal sort key is an ISO output-column ordinal (`ORDER BY
  /// 1` names the first projected column, 1-based), never the integer constant
  /// — ordering by a constant is meaningless, so the standard reads a lone
  /// integer here as a select-list position. The key parses as a full value
  /// `expression` unconditionally and then classifies: an expression that is
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
  internal mutating func name()
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
  internal mutating func identifier() throws(SQLError) -> String {
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

  /// The token after `current` without consuming either — a second token of
  /// lookahead, buffered in `pending` and drained by `advance` before the lexer
  /// is next pulled. It disambiguates a two-token context prefix a single
  /// `current` cannot (`GROUP BY GROUPING SETS`, whose `GROUPING`/`SETS` are
  /// context identifiers, not keywords, so a bare column named `grouping`
  /// followed by anything but `SETS` must NOT be mistaken for the construct).
  private mutating func secondary() throws(SQLError) -> Token? {
    if pending == nil {
      pending = try lexer.next()
    }
    return pending
  }

  /// Consumes and returns the current token, faulting at the end of input. A
  /// buffered `pending` lookahead becomes the new `current`; otherwise the
  /// lexer is pulled.
  internal mutating func advance(expecting expectation: String)
      throws(SQLError) -> Token {
    guard let token = current else {
      throw .incomplete(expected: expectation)
    }
    if let pending {
      current = pending
      self.pending = nil
    } else {
      current = try lexer.next()
    }
    return token
  }

  /// Consumes the current token if it has `kind`, reporting whether it did. A
  /// buffered `pending` lookahead becomes the new `current` on a match.
  internal mutating func match(_ kind: Token.Kind) throws(SQLError) -> Bool {
    guard let token = current, token.kind == kind else { return false }
    if let pending {
      current = pending
      self.pending = nil
    } else {
      current = try lexer.next()
    }
    return true
  }

  /// Consumes a token of `kind`, faulting otherwise.
  internal mutating func expect(_ kind: Token.Kind) throws(SQLError) {
    let token = try advance(expecting: "'\(kind.description)'")
    guard token.kind == kind else {
      throw .unexpected(token.kind.description,
                        expected: "'\(kind.description)'",
                        at: token.location)
    }
  }
}
