// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

/// Parses `text` and returns its `Select`, failing the test on any other shape.
private func parseSelect(_ text: String) throws -> Select {
  guard case let .select(select) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

struct ProjectionTests {
  @Test("parses a SELECT * projection")
  func star() throws {
    let select = try parseSelect("SELECT * FROM TypeDef")
    #expect(select.projection == .all)
    #expect(select.table == "TypeDef")
    #expect(select.predicate == nil)
    #expect(select.order == nil)
  }

  @Test("parses a single-column projection")
  func singleColumn() throws {
    let select = try parseSelect("SELECT TypeName FROM TypeDef")
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test("parses a comma-separated column list")
  func columnList() throws {
    let select =
        try parseSelect("SELECT TypeName, TypeNamespace, Flags FROM TypeDef")
    #expect(select.projection
                == .columns(["TypeName", "TypeNamespace", "Flags"]))
  }

  @Test("parses a dotted column identifier")
  func dottedColumn() throws {
    // Simple column identifiers may carry a qualifying dot; metadata names with
    // dots appear only as string literals.
    let select = try parseSelect("SELECT TypeDef.TypeName FROM TypeDef")
    #expect(select.projection == .columns(["TypeDef.TypeName"]))
  }
}

struct KeywordTests {
  @Test("parses lowercase keywords")
  func caseInsensitive() throws {
    let select =
        try parseSelect("select TypeName from TypeDef where Flags = 1")
    #expect(select.projection == .columns(["TypeName"]))
    #expect(select.table == "TypeDef")
    #expect(select.predicate == .comparison(left: .column("Flags"), op: .equal,
                                            right: .literal(.integer(1))))
  }

  @Test("parses mixed-case keywords")
  func mixedCase() throws {
    let select = try parseSelect("SeLeCt * FrOm TypeDef OrDeR By TypeName DeSc")
    #expect(select.order == Order(column: "TypeName", ascending: false))
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
          try parseSelect("SELECT * FROM T WHERE Flags \(text) 1")
      #expect(select.predicate
                  == .comparison(left: .column("Flags"), op: op,
                                 right: .literal(.integer(1))))
    }
  }

  @Test("parses a string-literal operand")
  func stringLiteral() throws {
    let select =
        try parseSelect(
            "SELECT * FROM TypeDef WHERE TypeNamespace = 'Windows.Win32.Foundation'")
    let value = Expression.literal(.string("Windows.Win32.Foundation"))
    #expect(select.predicate
                == .comparison(left: .column("TypeNamespace"), op: .equal,
                               right: value))
  }

  @Test("parses a string with an escaped quote")
  func escapedQuote() throws {
    let select = try parseSelect("SELECT * FROM T WHERE name = 'O''Brien'")
    #expect(select.predicate
                == .comparison(left: .column("name"), op: .equal,
                               right: .literal(.string("O'Brien"))))
  }

  @Test("parses a function call as a comparison operand")
  func functionOperand() throws {
    let select = try parseSelect("SELECT * FROM T WHERE upper(Name) = 'X'")
    let call = Expression.call(name: "upper", arguments: [.column("Name")])
    #expect(select.predicate
                == .comparison(left: call, op: .equal,
                               right: .literal(.string("X"))))
  }

  @Test("binds AND tighter than OR")
  func andBindsTighterThanOr() throws {
    // a = 1 OR b = 2 AND c = 3  ==>  a OR (b AND c)
    let select =
        try parseSelect("SELECT * FROM T WHERE a = 1 OR b = 2 AND c = 3")
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
        try parseSelect("SELECT * FROM T WHERE NOT a = 1 AND b = 2")
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
        try parseSelect("SELECT * FROM T WHERE (a = 1 OR b = 2) AND c = 3")
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
    let select = try parseSelect("SELECT * FROM T WHERE Note IS NULL")
    #expect(select.predicate == .null(.column("Note"), negated: false))
  }

  @Test("parses IS NOT NULL")
  func isNotNull() throws {
    let select = try parseSelect("SELECT * FROM T WHERE Note IS NOT NULL")
    #expect(select.predicate == .null(.column("Note"), negated: true))
  }

  @Test("parses IS NULL over a function-call operand")
  func isNullCall() throws {
    let select = try parseSelect("SELECT * FROM T WHERE iid(Id) IS NULL")
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
        try parseSelect("SELECT * FROM T WHERE a = 1 OR b = 2 OR c = 3")
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
    let select = try parseSelect("SELECT * FROM T ORDER BY TypeName")
    #expect(select.order == Order(column: "TypeName", ascending: true))
  }

  @Test("parses an explicit ASC order")
  func explicitAscending() throws {
    let select = try parseSelect("SELECT * FROM T ORDER BY TypeName ASC")
    #expect(select.order == Order(column: "TypeName", ascending: true))
  }

  @Test("parses a DESC order")
  func descending() throws {
    let select = try parseSelect("SELECT * FROM T ORDER BY TypeName DESC")
    #expect(select.order == Order(column: "TypeName", ascending: false))
  }
}

struct CompositeTests {
  @Test("parses a full SELECT/WHERE/ORDER BY query")
  func fullQuery() throws {
    let select =
        try parseSelect("""
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

  @Test("splits on the first dot only")
  func firstDot() {
    let column = Column("t.a.b")
    #expect(column.qualifier == "t")
    #expect(column.name == "a.b")
  }
}

struct RelationTests {
  @Test("parses a bare FROM relation with no alias")
  func bare() throws {
    let select = try parseSelect("SELECT * FROM TypeDef")
    #expect(select.from == Relation(name: "TypeDef"))
    #expect(select.joins.isEmpty)
  }

  @Test("parses an AS alias on the FROM relation")
  func alias() throws {
    let select = try parseSelect("SELECT * FROM TypeDef AS t")
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
  }

  @Test("parses an implicit (AS-less) alias")
  func implicitAlias() throws {
    let select = try parseSelect("SELECT * FROM TypeDef t")
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
  }

  @Test("does not mistake a following keyword for an alias")
  func keywordNotAlias() throws {
    let select = try parseSelect("SELECT * FROM TypeDef WHERE Flags = 1")
    #expect(select.from == Relation(name: "TypeDef"))
  }
}

struct JoinTests {
  @Test("parses a list-shape join with aliases")
  func listJoin() throws {
    let select = try parseSelect("""
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
    let select = try parseSelect("""
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
    let select = try parseSelect("""
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
    let select = try parseSelect("""
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

  @Test("rejects input ending after the projection")
  func unexpectedEnd() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT *")
    }
  }

  @Test("parses a column on either side of a comparison")
  func columnOperands() throws {
    // Either operand may be an expression, so a column-vs-column predicate is
    // valid SQL (`a = b`), not an error.
    let select = try parseSelect("SELECT * FROM T WHERE a = b")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .column("b")))
  }
}

// MARK: - Expression projections

struct ExpressionTests {
  @Test("a bare-column list stays the simpler columns projection")
  func columns() throws {
    let select = try parseSelect("SELECT a, b FROM T")
    #expect(select.projection == .columns(["a", "b"]))
  }

  @Test("a function call yields an expression projection")
  func call() throws {
    let select = try parseSelect("SELECT guid(Name) FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .call(name: "guid",
                                              arguments: [.column("Name")]))
                ]))
  }

  @Test("an aliased column yields an expression projection")
  func alias() throws {
    let select = try parseSelect("SELECT Name AS label FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .column("Name"), alias: "label")
                ]))
  }

  @Test("a call takes literal and nested-call arguments")
  func arguments() throws {
    let select = try parseSelect("SELECT f(1, g(x), 'lit') FROM T")
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
    let select = try parseSelect("SELECT now() FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .call(name: "now", arguments: []))
                ]))
  }
}
