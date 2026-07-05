// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

/// Parses `text` and returns its `Select`, failing the test on any other shape
/// — a non-`SELECT` statement, or a `UNION` of several selects.
private func parse(select text: String) throws -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

struct ProjectionTests {
  @Test("parses a SELECT * projection")
  func star() throws {
    let select = try parse(select: "SELECT * FROM TypeDef")
    #expect(select.projection == .all)
    #expect(select.table == "TypeDef")
    #expect(select.predicate == nil)
    #expect(select.order == nil)
  }

  @Test("parses a single-column projection")
  func singleColumn() throws {
    let select = try parse(select: "SELECT TypeName FROM TypeDef")
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test("parses a comma-separated column list")
  func columnList() throws {
    let select =
        try parse(select: "SELECT TypeName, TypeNamespace, Flags FROM TypeDef")
    #expect(select.projection
                == .columns(["TypeName", "TypeNamespace", "Flags"]))
  }

  @Test("parses a dotted column identifier")
  func dottedColumn() throws {
    // Simple column identifiers may carry a qualifying dot; metadata names with
    // dots appear only as string literals.
    let select = try parse(select: "SELECT TypeDef.TypeName FROM TypeDef")
    #expect(select.projection == .columns(["TypeDef.TypeName"]))
  }

  @Test("parses a delimited column identifier as one unqualified name")
  func delimitedColumn() throws {
    // A delimited identifier is verbatim: a dot in it is part of the name,
    // not a qualifier as in the bare dotted form above.
    let dotted = try parse(select: "SELECT \"a.b\" FROM T")
    #expect(dotted.projection == .columns([Column(name: "a.b")]))
    // A quoted reserved word is likewise a plain, unqualified column name.
    let offset = try parse(select: "SELECT \"Offset\" FROM T")
    #expect(offset.projection == .columns([Column(name: "Offset")]))
  }
}

struct KeywordTests {
  @Test("parses lowercase keywords")
  func caseInsensitive() throws {
    let select =
        try parse(select: "select TypeName from TypeDef where Flags = 1")
    #expect(select.projection == .columns(["TypeName"]))
    #expect(select.table == "TypeDef")
    #expect(select.predicate == .comparison(left: .column("Flags"), op: .equal,
                                            right: .literal(.integer(1))))
  }

  @Test("parses mixed-case keywords")
  func mixedCase() throws {
    let select =
        try parse(select: "SeLeCt * FrOm TypeDef OrDeR By TypeName DeSc")
    #expect(select.order == Order(column: "TypeName", ascending: false))
  }
}

struct SetQuantifierTests {
  @Test("a plain SELECT is not distinct")
  func plain() throws {
    let select = try parse(select: "SELECT TypeName FROM TypeDef")
    #expect(!select.distinct)
  }

  @Test("SELECT DISTINCT sets the distinct flag")
  func distinct() throws {
    let select = try parse(select: "SELECT DISTINCT TypeName FROM TypeDef")
    #expect(select.distinct)
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test("SELECT ALL is the default, not distinct")
  func explicitAll() throws {
    let select = try parse(select: "SELECT ALL TypeName FROM TypeDef")
    #expect(!select.distinct)
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test("DISTINCT is case-insensitive")
  func caseInsensitive() throws {
    let select = try parse(select: "select distinct TypeName from TypeDef")
    #expect(select.distinct)
  }

  @Test("DISTINCT applies to a FROM-less scalar select")
  func scalar() throws {
    let select = try parse(select: "SELECT DISTINCT 1")
    #expect(select.distinct)
    #expect(select.from == nil)
  }
}

struct PredicateTests {
  @Test("parses each comparison operator")
  func operators() throws {
    let cases: Array<(String, Comparison)> = [
      ("=", .equal),
      ("<>", .unequal),
      ("<", .lt),
      (">", .gt),
      ("<=", .leq),
      (">=", .geq),
    ]
    for (text, op) in cases {
      let select =
          try parse(select: "SELECT * FROM T WHERE Flags \(text) 1")
      #expect(select.predicate
                  == .comparison(left: .column("Flags"), op: op,
                                 right: .literal(.integer(1))))
    }
  }

  @Test("parses a string-literal operand")
  func stringLiteral() throws {
    let text =
        "SELECT * FROM TypeDef WHERE TypeNamespace = 'Windows.Win32.Foundation'"
    let select = try parse(select: text)
    let value = Expression.literal(.string("Windows.Win32.Foundation"))
    #expect(select.predicate
                == .comparison(left: .column("TypeNamespace"), op: .equal,
                               right: value))
  }

  @Test("parses a string with an escaped quote")
  func escapedQuote() throws {
    let select = try parse(select: "SELECT * FROM T WHERE name = 'O''Brien'")
    #expect(select.predicate
                == .comparison(left: .column("name"), op: .equal,
                               right: .literal(.string("O'Brien"))))
  }

  @Test("parses a function call as a comparison operand")
  func functionOperand() throws {
    let select = try parse(select: "SELECT * FROM T WHERE upper(Name) = 'X'")
    let call = Expression.call(name: "upper", arguments: [.column("Name")])
    #expect(select.predicate
                == .comparison(left: call, op: .equal,
                               right: .literal(.string("X"))))
  }

  @Test("binds AND tighter than OR")
  func andBindsTighterThanOr() throws {
    // a = 1 OR b = 2 AND c = 3  ==>  a OR (b AND c)
    let select =
        try parse(select: "SELECT * FROM T WHERE a = 1 OR b = 2 AND c = 3")
    let a = Predicate.comparison(left: .column("a"), op: .equal,
                                 right: .literal(.integer(1)))
    let b = Predicate.comparison(left: .column("b"), op: .equal,
                                 right: .literal(.integer(2)))
    let c = Predicate.comparison(left: .column("c"), op: .equal,
                                 right: .literal(.integer(3)))
    #expect(select.predicate == .or(a, .and(b, c)))
  }

  @Test("binds NOT tighter than AND")
  func notBindsTighterThanAnd() throws {
    // NOT a = 1 AND b = 2  ==>  (NOT a) AND b
    let select =
        try parse(select: "SELECT * FROM T WHERE NOT a = 1 AND b = 2")
    let a = Predicate.comparison(left: .column("a"), op: .equal,
                                 right: .literal(.integer(1)))
    let b = Predicate.comparison(left: .column("b"), op: .equal,
                                 right: .literal(.integer(2)))
    #expect(select.predicate == .and(.not(a), b))
  }

  @Test("parentheses override operator precedence")
  func parenthesesOverridePrecedence() throws {
    // (a = 1 OR b = 2) AND c = 3
    let select =
        try parse(select: "SELECT * FROM T WHERE (a = 1 OR b = 2) AND c = 3")
    let a = Predicate.comparison(left: .column("a"), op: .equal,
                                 right: .literal(.integer(1)))
    let b = Predicate.comparison(left: .column("b"), op: .equal,
                                 right: .literal(.integer(2)))
    let c = Predicate.comparison(left: .column("c"), op: .equal,
                                 right: .literal(.integer(3)))
    #expect(select.predicate == .and(.or(a, b), c))
  }

  @Test("parses IS NULL")
  func isNull() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Note IS NULL")
    #expect(select.predicate == .null(.column("Note"), negated: false))
  }

  @Test("parses IS NOT NULL")
  func isNotNull() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Note IS NOT NULL")
    #expect(select.predicate == .null(.column("Note"), negated: true))
  }

  @Test("parses IS NULL over a function-call operand")
  func isNullCall() throws {
    let select = try parse(select: "SELECT * FROM T WHERE iid(Id) IS NULL")
    let call = Expression.call(name: "iid", arguments: [.column("Id")])
    #expect(select.predicate == .null(call, negated: false))
  }

  @Test("rejects IS without NULL")
  func isWithoutNull() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE Note IS 1")
    }
  }

  @Test("parses OR left-associatively")
  func leftAssociativeOr() throws {
    // a = 1 OR b = 2 OR c = 3  ==>  ((a OR b) OR c)
    let select =
        try parse(select: "SELECT * FROM T WHERE a = 1 OR b = 2 OR c = 3")
    let a = Predicate.comparison(left: .column("a"), op: .equal,
                                 right: .literal(.integer(1)))
    let b = Predicate.comparison(left: .column("b"), op: .equal,
                                 right: .literal(.integer(2)))
    let c = Predicate.comparison(left: .column("c"), op: .equal,
                                 right: .literal(.integer(3)))
    #expect(select.predicate == .or(.or(a, b), c))
  }
}

struct OrderTests {
  @Test("defaults ORDER BY to ascending")
  func defaultAscending() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName")
    #expect(select.order == Order(column: "TypeName", ascending: true))
  }

  @Test("parses an explicit ASC order")
  func explicitAscending() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName ASC")
    #expect(select.order == Order(column: "TypeName", ascending: true))
  }

  @Test("parses a DESC order")
  func descending() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName DESC")
    #expect(select.order == Order(column: "TypeName", ascending: false))
  }

  @Test("parses a comma-separated list of sort keys")
  func multipleKeys() throws {
    let select =
        try parse(select: "SELECT * FROM T ORDER BY A, B DESC, C")
    #expect(select.order == Order(keys: [
      Order.Key(column: "A", ascending: true),
      Order.Key(column: "B", ascending: false),
      Order.Key(column: "C", ascending: true),
    ]))
  }

  @Test("a single-key ORDER BY is one key in the list")
  func singleKey() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName DESC")
    #expect(select.order?.keys
              == [Order.Key(column: "TypeName", ascending: false)])
  }
}

struct CompositeTests {
  @Test("parses a full SELECT/WHERE/ORDER BY query")
  func fullQuery() throws {
    let select =
        try parse(select: """
            SELECT TypeName, TypeNamespace FROM TypeDef
              WHERE TypeNamespace = 'Windows.Win32.Foundation' AND Flags >= 1
              ORDER BY TypeName DESC
            """)
    #expect(select.projection == .columns(["TypeName", "TypeNamespace"]))
    #expect(select.table == "TypeDef")
    let value = Expression.literal(.string("Windows.Win32.Foundation"))
    let namespace = Predicate.comparison(left: .column("TypeNamespace"),
                                         op: .equal, right: value)
    let flags = Predicate.comparison(left: .column("Flags"), op: .geq,
                                     right: .literal(.integer(1)))
    #expect(select.predicate == .and(namespace, flags))
    #expect(select.order == Order(column: "TypeName", ascending: false))
  }
}

struct ColumnTests {
  @Test("splits a dotted column into qualifier and name")
  func qualified() {
    let column = Column("t.Name")
    #expect(column.qualifier == "t")
    #expect(column.name == "Name")
  }

  @Test("leaves an undotted column unqualified")
  func unqualified() {
    let column = Column("Name")
    #expect(column.qualifier == nil)
    #expect(column.name == "Name")
  }

  @Test("splits on the last dot only")
  func lastDot() {
    // A two-part relation name may qualify a column — the reserved
    // `information_schema.tables.table_name` — so the split takes the text
    // before the LAST dot as the qualifier and the rest as the name.
    let column = Column("t.a.b")
    #expect(column.qualifier == "t.a")
    #expect(column.name == "b")
  }
}

struct RelationTests {
  @Test("parses a bare FROM relation with no alias")
  func bare() throws {
    let select = try parse(select: "SELECT * FROM TypeDef")
    #expect(select.from == Relation(name: "TypeDef"))
    #expect(select.joins.isEmpty)
  }

  @Test("parses an AS alias on the FROM relation")
  func alias() throws {
    let select = try parse(select: "SELECT * FROM TypeDef AS t")
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
  }

  @Test("parses an implicit (AS-less) alias")
  func implicitAlias() throws {
    let select = try parse(select: "SELECT * FROM TypeDef t")
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
  }

  @Test("does not mistake a following keyword for an alias")
  func keywordNotAlias() throws {
    let select = try parse(select: "SELECT * FROM TypeDef WHERE Flags = 1")
    #expect(select.from == Relation(name: "TypeDef"))
  }
}

struct JoinTests {
  @Test("parses a list-shape join with aliases")
  func listJoin() throws {
    let select = try parse(select: """
        SELECT m.Name FROM TypeDef AS t
          JOIN MethodDef AS m ON m.parent = t.rowid
          WHERE t.TypeName = 'IUnknown'
        """)
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
    #expect(select.joins == [
      Join(relation: Relation(name: "MethodDef", alias: "m"),
           left: Column("m.parent"), right: Column("t.rowid")),
    ])
    #expect(select.projection == .columns([Column("m.Name")]))
    let value = Expression.literal(.string("IUnknown"))
    #expect(select.predicate == .comparison(left: .column("t.TypeName"),
                                            op: .equal, right: value))
  }

  @Test("parses a forward-key join")
  func forwardJoin() throws {
    let select = try parse(select: """
        SELECT r.TypeName FROM TypeDef AS t
          JOIN TypeRef AS r ON t.Extends = r.rowid
        """)
    #expect(select.joins == [
      Join(relation: Relation(name: "TypeRef", alias: "r"),
           left: Column("t.Extends"), right: Column("r.rowid")),
    ])
  }

  @Test("parses a join without aliases")
  func unaliasedJoin() throws {
    let select = try parse(select: """
        SELECT Name FROM MethodDef
          JOIN Param ON Param.parent = MethodDef.rowid
        """)
    #expect(select.from == Relation(name: "MethodDef"))
    #expect(select.joins == [
      Join(relation: Relation(name: "Param"),
           left: Column("Param.parent"),
           right: Column("MethodDef.rowid")),
    ])
  }

  @Test("parses a chain of two joins in source order")
  func chainedJoins() throws {
    let select = try parse(select: """
        SELECT Param.Name FROM TypeDef AS t
          JOIN MethodDef AS m ON m.parent = t.rowid
          JOIN Param ON Param.parent = m.rowid
        """)
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
    #expect(select.joins == [
      Join(relation: Relation(name: "MethodDef", alias: "m"),
           left: Column("m.parent"), right: Column("t.rowid")),
      Join(relation: Relation(name: "Param"),
           left: Column("Param.parent"), right: Column("m.rowid")),
    ])
  }

  @Test("rejects a join missing ON")
  func missingOn() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM A JOIN B b")
    }
  }

  @Test("rejects a join whose ON is not an equality")
  func nonEqualityOn() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM A JOIN B ON a.x < b.rowid")
    }
  }
}

// MARK: - Literals

struct LiteralTests {
  @Test("parses TRUE and FALSE as boolean literals")
  func boolean() throws {
    let yes = try parse(select: "SELECT * FROM T WHERE Sealed = TRUE")
    #expect(yes.predicate
                == .comparison(left: .column("Sealed"), op: .equal,
                               right: .literal(.boolean(true))))
    let no = try parse(select: "SELECT * FROM T WHERE Sealed = FALSE")
    #expect(no.predicate
                == .comparison(left: .column("Sealed"), op: .equal,
                               right: .literal(.boolean(false))))
  }

  @Test("recognises the boolean keywords case-insensitively")
  func booleanCase() throws {
    let select = try parse(select: "SELECT * FROM T WHERE a = true")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .literal(.boolean(true))))
  }

  @Test("parses an x'…' hex blob literal into its bytes")
  func blob() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Sig = x'53514c'")
    #expect(select.predicate
                == .comparison(left: .column("Sig"), op: .equal,
                               right: .literal(.blob([0x53, 0x51, 0x4c]))))
  }

  @Test("parses an uppercase X'…' prefix and mixed-case hex digits")
  func blobPrefixAndDigits() throws {
    let select = try parse(select: "SELECT * FROM T WHERE a = X'aBcDeF'")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .literal(.blob([0xab, 0xcd, 0xef]))))
  }

  @Test("parses an empty blob x''")
  func emptyBlob() throws {
    let select = try parse(select: "SELECT * FROM T WHERE a = x''")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .literal(.blob([]))))
  }

  @Test("a bare x is an ordinary identifier, not a blob prefix")
  func bareX() throws {
    // The `x` prefix opens a blob only when a quote follows; alone it is a
    // column name.
    let select = try parse(select: "SELECT x FROM T")
    #expect(select.projection == .columns(["x"]))
  }

  @Test("rejects a blob with an odd hex digit count")
  func oddBlob() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = x'abc'")
    }
  }

  @Test("rejects a blob with a non-hex digit")
  func nonHexBlob() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = x'gg'")
    }
  }

  @Test("rejects an unterminated blob")
  func unterminatedBlob() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = x'abcd")
    }
  }
}

struct ErrorTests {
  @Test("rejects a query missing FROM")
  func missingFrom() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT TypeName TypeDef")
    }
  }

  @Test("rejects an invalid operator")
  func badOperator() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a ! 1")
    }
  }

  @Test("rejects an unterminated string")
  func unterminatedString() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = 'unterminated")
    }
  }

  @Test("rejects trailing tokens")
  func trailingTokens() {
    // A bare identifier after the relation is now an implicit alias, so
    // trailing garbage must come after a clause that admits no alias — here a
    // second identifier past the relation's (implicit) alias.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T t garbage")
    }
  }

  @Test("rejects an empty projection")
  func emptyProjection() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT FROM T")
    }
  }

  @Test("rejects a FROM keyword with no following relation")
  func unexpectedEnd() {
    // FROM is now optional, so `SELECT *` parses as a FROM-less projection (the
    // engine rejects a `*` with no relation). A bare FROM with no relation,
    // though, ends the input where a relation is required.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM")
    }
  }

  @Test("parses a column on either side of a comparison")
  func columnOperands() throws {
    // Either operand may be an expression, so a column-vs-column predicate is
    // valid SQL (`a = b`), not an error.
    let select = try parse(select: "SELECT * FROM T WHERE a = b")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .column("b")))
  }
}

// MARK: - Expression projections

struct ExpressionTests {
  @Test("a bare-column list stays the simpler columns projection")
  func columns() throws {
    let select = try parse(select: "SELECT a, b FROM T")
    #expect(select.projection == .columns(["a", "b"]))
  }

  @Test("a function call yields an expression projection")
  func call() throws {
    let select = try parse(select: "SELECT guid(Name) FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .call(name: "guid",
                                              arguments: [.column("Name")]))
                ]))
  }

  @Test("an aliased column yields an expression projection")
  func alias() throws {
    let select = try parse(select: "SELECT Name AS label FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .column("Name"), alias: "label")
                ]))
  }

  @Test("a call takes literal and nested-call arguments")
  func arguments() throws {
    let select = try parse(select: "SELECT f(1, g(x), 'lit') FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression:
                    .call(name: "f", arguments: [
                      .literal(.integer(1)),
                      .call(name: "g", arguments: [.column("x")]),
                      .literal(.string("lit")),
                    ]))
                ]))
  }

  @Test("a zero-argument call parses")
  func nullary() throws {
    let select = try parse(select: "SELECT now() FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .call(name: "now", arguments: []))
                ]))
  }
}

// MARK: - Arithmetic expressions

struct ArithmeticTests {
  /// The lone projected expression of a single-item projection, failing on any
  /// other shape.
  private func expression(_ text: String) throws -> Expression {
    let select = try parse(select: text)
    guard case let .expressions(items) = select.projection,
        items.count == 1 else {
      Issue.record("expected a single expression projection")
      throw SQLError.incomplete(expected: "an expression projection")
    }
    return items[0].expression
  }

  @Test("parses each arithmetic operator")
  func operators() throws {
    let cases: Array<(String, Arithmetic)> = [
      ("+", .add),
      ("-", .subtract),
      ("*", .multiply),
      ("/", .divide),
    ]
    for (text, op) in cases {
      let parsed = try expression("SELECT 1 \(text) 2 FROM T")
      #expect(parsed
                  == .binary(op, .literal(.integer(1)), .literal(.integer(2))))
    }
  }

  @Test("multiplication binds tighter than addition")
  func precedence() throws {
    // 2 + 3 * 4  ==>  2 + (3 * 4)
    let parsed = try expression("SELECT 2 + 3 * 4 FROM T")
    let product = Expression.binary(.multiply, .literal(.integer(3)),
                                    .literal(.integer(4)))
    #expect(parsed == .binary(.add, .literal(.integer(2)), product))
  }

  @Test("parentheses override precedence")
  func grouping() throws {
    // (2 + 3) * 4  ==>  (2 + 3) * 4
    let parsed = try expression("SELECT (2 + 3) * 4 FROM T")
    let sum = Expression.binary(.add, .literal(.integer(2)),
                                .literal(.integer(3)))
    #expect(parsed == .binary(.multiply, sum, .literal(.integer(4))))
  }

  @Test("addition is left-associative")
  func leftAssociative() throws {
    // 1 - 2 - 3  ==>  (1 - 2) - 3
    let parsed = try expression("SELECT 1 - 2 - 3 FROM T")
    let left = Expression.binary(.subtract, .literal(.integer(1)),
                                 .literal(.integer(2)))
    #expect(parsed == .binary(.subtract, left, .literal(.integer(3))))
  }

  @Test("arithmetic combines columns and calls")
  func operands() throws {
    let parsed = try expression("SELECT add(Id, 1) * 10 FROM T")
    let call = Expression.call(name: "add",
                               arguments: [.column("Id"), .literal(.integer(1))])
    #expect(parsed == .binary(.multiply, call, .literal(.integer(10))))
  }

  @Test("arithmetic parses on either side of a comparison")
  func predicate() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Age + 1 = 26")
    let sum = Expression.binary(.add, .column("Age"), .literal(.integer(1)))
    #expect(select.predicate
                == .comparison(left: sum, op: .equal,
                               right: .literal(.integer(26))))
  }
}

// MARK: - Scalar (FROM-less) SELECT

struct ScalarSelectTests {
  @Test("parses a FROM-less SELECT with no relation")
  func bare() throws {
    let select = try parse(select: "SELECT 1")
    #expect(select.from == nil)
    #expect(select.joins.isEmpty)
    #expect(select.predicate == nil)
    #expect(select.order == nil)
    #expect(select.projection
                == .expressions([Projected(expression: .literal(.integer(1)))]))
  }

  @Test("parses a FROM-less arithmetic projection")
  func arithmetic() throws {
    let select = try parse(select: "SELECT 1 + 1")
    let sum = Expression.binary(.add, .literal(.integer(1)),
                                .literal(.integer(1)))
    #expect(select.from == nil)
    #expect(select.projection == .expressions([Projected(expression: sum)]))
  }

  @Test("parses a FROM-less multi-column projection")
  func multiColumn() throws {
    let select = try parse(select: "SELECT 1, 2")
    #expect(select.from == nil)
    #expect(select.projection == .expressions([
      Projected(expression: .literal(.integer(1))),
      Projected(expression: .literal(.integer(2))),
    ]))
  }

  @Test("a FROM-less alias names the projected column")
  func aliased() throws {
    let select = try parse(select: "SELECT 1 + 1 AS two")
    let sum = Expression.binary(.add, .literal(.integer(1)),
                                .literal(.integer(1)))
    #expect(select.projection
                == .expressions([Projected(expression: sum, alias: "two")]))
  }

  @Test("a FROM-less query admits no trailing WHERE")
  func noWhere() {
    // With FROM absent there is no relation to filter, so a WHERE that follows
    // is trailing input rather than a clause.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT 1 WHERE 1 = 1")
    }
  }
}

// MARK: - CREATE VIEW

/// Parses `text` and returns its `(name, view)`, failing on any other shape.
private func parseCreate(_ text: String) throws -> (String, View) {
  guard case let .create(name, view) = try Statement(parsing: text) else {
    Issue.record("expected a CREATE VIEW statement")
    throw SQLError.incomplete(expected: "a CREATE VIEW statement")
  }
  return (name, view)
}

struct CreateViewTests {
  @Test("infers a view's columns from a bare-column projection")
  func inferred() throws {
    let (name, view) = try parseCreate("CREATE VIEW v AS SELECT a, b FROM t")
    #expect(name == "v")
    #expect(view.columns == ["a", "b"])
    #expect(view.query == .select(Select(projection: .columns(["a", "b"]),
                                         from: Relation(name: "t"))))
  }

  @Test("drops a qualifier when inferring a column name")
  func qualified() throws {
    let (_, view) = try parseCreate("CREATE VIEW v AS SELECT t.a FROM t")
    #expect(view.columns == ["a"])
  }

  @Test("takes an explicit column list over the projection")
  func explicit() throws {
    let (name, view) =
        try parseCreate("CREATE VIEW v (x, y) AS SELECT a, b FROM t")
    #expect(name == "v")
    #expect(view.columns == ["x", "y"])
  }

  @Test("rejects an explicit list wider than the projection")
  func tooWide() {
    // (a, b) names two columns over a one-value projection — the view would
    // claim a column its rows lack.
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try Statement(parsing: "CREATE VIEW v (a, b) AS SELECT id FROM t")
    }
  }

  @Test("rejects an explicit list narrower than the projection")
  func tooNarrow() {
    // (a) names one column over a two-value projection — the projected `name`
    // would have no view column.
    #expect(throws: SQLError.columns(expected: 2, got: 1)) {
      _ = try Statement(parsing: "CREATE VIEW v (a) AS SELECT id, name FROM t")
    }
  }

  @Test("accepts an explicit list matching the projection arity")
  func matched() throws {
    let (_, view) =
        try parseCreate("CREATE VIEW v (a, b) AS SELECT id, name FROM t")
    #expect(view.columns == ["a", "b"])
  }

  @Test("defers a SELECT * view's column-count check to the engine")
  func starExplicit() throws {
    // A `SELECT *` has no statically known arity, so the parser admits any
    // explicit list; the engine validates it against the relation at
    // resolution.
    let (_, view) =
        try parseCreate("CREATE VIEW v (a, b) AS SELECT * FROM t")
    #expect(view.columns == ["a", "b"])
  }

  @Test("infers a column name from an expression's alias")
  func aliased() throws {
    let (_, view) =
        try parseCreate("CREATE VIEW v AS SELECT guid(Id) AS iid FROM t")
    #expect(view.columns == ["iid"])
  }

  @Test("infers a bare column's name in an expression projection")
  func mixed() throws {
    // A projection carrying any alias is the richer expressions form; a bare
    // column in it still infers to its own name.
    let (_, view) =
        try parseCreate("CREATE VIEW v AS SELECT Name, guid(Id) AS iid FROM t")
    #expect(view.columns == ["Name", "iid"])
  }

  @Test("parses lowercase CREATE VIEW keywords")
  func caseInsensitive() throws {
    let (name, view) =
        try parseCreate("create view v as select a from t")
    #expect(name == "v")
    #expect(view.columns == ["a"])
  }

  @Test("rejects a SELECT * view with no explicit columns")
  func star() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "CREATE VIEW v AS SELECT * FROM t")
    }
  }

  @Test("rejects an unaliased expression with no explicit columns")
  func unnamed() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "CREATE VIEW v AS SELECT guid(Id) FROM t")
    }
  }

  @Test("rejects an explicit duplicate column name")
  func duplicateExplicit() {
    #expect(throws: SQLError.duplicate("x")) {
      _ = try Statement(parsing: "CREATE VIEW v (x, x) AS SELECT a, b FROM t")
    }
  }

  @Test("rejects a case-insensitive explicit duplicate column name")
  func duplicateExplicitFolded() {
    #expect(throws: SQLError.duplicate("x")) {
      _ = try Statement(parsing: "CREATE VIEW v (X, x) AS SELECT a, b FROM t")
    }
  }

  @Test("rejects an inferred duplicate column name")
  func duplicateInferred() {
    #expect(throws: SQLError.duplicate("Name")) {
      _ = try Statement(
          parsing: "CREATE VIEW v AS SELECT t.Name, u.Name FROM t "
              + "JOIN u ON t.Id = u.Id")
    }
  }

  @Test("accepts a distinct inferred column list")
  func distinctInferred() throws {
    let (_, view) = try parseCreate("CREATE VIEW v AS SELECT a, b FROM t")
    #expect(view.columns == ["a", "b"])
  }
}

// MARK: - UNION

/// Parses `text` and returns its `Query`, failing on any other statement shape.
private func parse(query text: String) throws -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

struct UnionTests {
  @Test("parses UNION into a deduplicating union of two selects")
  func union() throws {
    let query = try parse(query: "SELECT a FROM t UNION SELECT b FROM u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .union(.select(left), right, all: false))
  }

  @Test("parses UNION ALL into a duplicate-keeping union")
  func all() throws {
    let query = try parse(query: "SELECT a FROM t UNION ALL SELECT b FROM u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .union(.select(left), right, all: true))
  }

  @Test("nests a chain of UNIONs left-associatively in source order")
  func chain() throws {
    let query = try parse(query:
        "SELECT a FROM t UNION SELECT b FROM u UNION ALL SELECT c FROM v")
    let a = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let b = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    let c = Select(projection: .columns(["c"]), from: Relation(name: "v"))
    #expect(query == .union(.union(.select(a), b, all: false), c, all: true))
  }

  @Test("recognises lowercase union and all keywords")
  func caseInsensitive() throws {
    let query = try parse(query: "select a from t union all select b from u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .union(.select(left), right, all: true))
  }

  @Test("a CREATE VIEW over a UNION stores the query and the first arm's names")
  func view() throws {
    let (name, view) = try parseCreate(
        "CREATE VIEW v AS SELECT a, b FROM t UNION SELECT c, d FROM u")
    let left = Select(projection: .columns(["a", "b"]),
                      from: Relation(name: "t"))
    let right = Select(projection: .columns(["c", "d"]),
                       from: Relation(name: "u"))
    #expect(name == "v")
    #expect(view.columns == ["a", "b"])
    #expect(view.query == .union(.select(left), right, all: false))
  }
}

// MARK: - WITH / CTE tests

/// Parses `text` and returns its `(ctes, query)`, failing on any other shape.
private func parseWith(_ text: String) throws -> (Array<CTE>, Query) {
  guard case let .with(ctes, query) = try Statement(parsing: text) else {
    Issue.record("expected a WITH statement")
    throw SQLError.incomplete(expected: "a WITH statement")
  }
  return (ctes, query)
}

struct WithTests {
  @Test("parses a single non-recursive CTE and its trailing query")
  func single() throws {
    let (ctes, query) = try parseWith("""
        WITH a AS (SELECT x FROM t) SELECT x FROM a
        """)
    #expect(ctes.count == 1)
    #expect(ctes[0].name == "a")
    #expect(ctes[0].columns == ["x"])
    #expect(ctes[0].recursive == false)
    #expect(ctes[0].query
                == .select(Select(projection: .columns(["x"]),
                                  from: Relation(name: "t"))))
    #expect(query == .select(Select(projection: .columns(["x"]),
                                    from: Relation(name: "a"))))
  }

  @Test("infers a CTE's columns from its query's projection")
  func inferred() throws {
    let (ctes, _) = try parseWith("""
        WITH a AS (SELECT p, q FROM t) SELECT p FROM a
        """)
    #expect(ctes[0].columns == ["p", "q"])
  }

  @Test("an explicit column list names a CTE's columns")
  func explicit() throws {
    let (ctes, _) = try parseWith("""
        WITH a (k, v) AS (SELECT p, q FROM t) SELECT k FROM a
        """)
    #expect(ctes[0].columns == ["k", "v"])
  }

  @Test("parses several comma-separated CTEs in source order")
  func chain() throws {
    let (ctes, query) = try parseWith("""
        WITH a AS (SELECT x FROM t), b AS (SELECT y FROM a) SELECT y FROM b
        """)
    #expect(ctes.map(\.name) == ["a", "b"])
    #expect(ctes[1].query
                == .select(Select(projection: .columns(["y"]),
                                  from: Relation(name: "a"))))
    #expect(query == .select(Select(projection: .columns(["y"]),
                                    from: Relation(name: "b"))))
  }

  @Test("RECURSIVE marks every CTE of the list recursive")
  func recursive() throws {
    let (ctes, _) = try parseWith("""
        WITH RECURSIVE a (n) AS (SELECT n FROM seed UNION ALL SELECT n FROM a)
          SELECT n FROM a
        """)
    #expect(ctes[0].recursive == true)
    #expect(ctes[0].columns == ["n"])
    guard case .union = ctes[0].query else {
      Issue.record("expected the recursive CTE's query to be a UNION")
      return
    }
  }

  @Test("a CTE's query may itself be a UNION")
  func union() throws {
    let (ctes, _) = try parseWith("""
        WITH a AS (SELECT x FROM t UNION SELECT y FROM u) SELECT x FROM a
        """)
    let left = Select(projection: .columns(["x"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["y"]), from: Relation(name: "u"))
    #expect(ctes[0].query == .union(.select(left), right, all: false))
  }

  @Test("recognises lowercase with and recursive keywords")
  func caseInsensitive() throws {
    let (ctes, query) = try parseWith("""
        with recursive a (n) as (select n from a) select n from a
        """)
    #expect(ctes[0].name == "a")
    #expect(ctes[0].recursive == true)
    #expect(query == .select(Select(projection: .columns(["n"]),
                                    from: Relation(name: "a"))))
  }

  @Test("an explicit list of the wrong arity is rejected")
  func arity() throws {
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
      _ = try parseWith("""
          WITH a (x, y, z) AS (SELECT p, q FROM t) SELECT x FROM a
          """)
    }
  }

  @Test("a CTE naming two columns that collide by case is rejected")
  func duplicate() throws {
    #expect(throws: SQLError.duplicate("X")) {
      _ = try parseWith("WITH a (x, X) AS (SELECT p, q FROM t) SELECT x FROM a")
    }
  }

  @Test("a CTE projecting an un-nameable column with no list is rejected")
  func unnamed() throws {
    #expect(throws: SQLError.named("SELECT *")) {
      _ = try parseWith("WITH a AS (SELECT * FROM t) SELECT x FROM a")
    }
  }

  @Test("a CTE missing its parenthesised query is rejected")
  func missingParen() throws {
    #expect(throws: SQLError.self) {
      _ = try parseWith("WITH a AS SELECT x FROM t SELECT x FROM a")
    }
  }
}
