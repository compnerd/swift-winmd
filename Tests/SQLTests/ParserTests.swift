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
  @Test func `parses a SELECT * projection`() throws {
    let select = try parse(select: "SELECT * FROM TypeDef")
    #expect(select.projection == .all)
    #expect(select.table == "TypeDef")
    #expect(select.predicate == nil)
    #expect(select.order == nil)
  }

  @Test func `parses a single-column projection`() throws {
    let select = try parse(select: "SELECT TypeName FROM TypeDef")
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test func `parses a comma-separated column list`() throws {
    let select =
        try parse(select: "SELECT TypeName, TypeNamespace, Flags FROM TypeDef")
    #expect(select.projection
                == .columns(["TypeName", "TypeNamespace", "Flags"]))
  }

  @Test func `parses a dotted column identifier`() throws {
    // Simple column identifiers may carry a qualifying dot; metadata names with
    // dots appear only as string literals.
    let select = try parse(select: "SELECT TypeDef.TypeName FROM TypeDef")
    #expect(select.projection == .columns(["TypeDef.TypeName"]))
  }

  @Test func `parses a delimited column identifier as one unqualified name`() throws {
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
  @Test func `parses lowercase keywords`() throws {
    let select =
        try parse(select: "select TypeName from TypeDef where Flags = 1")
    #expect(select.projection == .columns(["TypeName"]))
    #expect(select.table == "TypeDef")
    #expect(select.predicate == .comparison(left: .column("Flags"), op: .equal,
                                            right: .literal(.integer(1))))
  }

  @Test func `parses mixed-case keywords`() throws {
    let select =
        try parse(select: "SeLeCt * FrOm TypeDef OrDeR By TypeName DeSc")
    #expect(select.order == Order(column: "TypeName", ascending: false))
  }
}

struct SetQuantifierTests {
  @Test func `a plain SELECT is not distinct`() throws {
    let select = try parse(select: "SELECT TypeName FROM TypeDef")
    #expect(!select.distinct)
  }

  @Test func `SELECT DISTINCT sets the distinct flag`() throws {
    let select = try parse(select: "SELECT DISTINCT TypeName FROM TypeDef")
    #expect(select.distinct)
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test func `SELECT ALL is the default, not distinct`() throws {
    let select = try parse(select: "SELECT ALL TypeName FROM TypeDef")
    #expect(!select.distinct)
    #expect(select.projection == .columns(["TypeName"]))
  }

  @Test func `DISTINCT is case-insensitive`() throws {
    let select = try parse(select: "select distinct TypeName from TypeDef")
    #expect(select.distinct)
  }

  @Test func `DISTINCT applies to a FROM-less scalar select`() throws {
    let select = try parse(select: "SELECT DISTINCT 1")
    #expect(select.distinct)
    #expect(select.from == nil)
  }
}

struct PredicateTests {
  @Test func `parses each comparison operator`() throws {
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

  @Test func `parses a string-literal operand`() throws {
    let text =
        "SELECT * FROM TypeDef WHERE TypeNamespace = 'Windows.Win32.Foundation'"
    let select = try parse(select: text)
    let value = Expression.literal(.string("Windows.Win32.Foundation"))
    #expect(select.predicate
                == .comparison(left: .column("TypeNamespace"), op: .equal,
                               right: value))
  }

  @Test func `parses a string with an escaped quote`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE name = 'O''Brien'")
    #expect(select.predicate
                == .comparison(left: .column("name"), op: .equal,
                               right: .literal(.string("O'Brien"))))
  }

  @Test func `parses a function call as a comparison operand`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE upper(Name) = 'X'")
    let call = Expression.call(name: "upper", arguments: [.column("Name")])
    #expect(select.predicate
                == .comparison(left: call, op: .equal,
                               right: .literal(.string("X"))))
  }

  @Test func `binds AND tighter than OR`() throws {
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

  @Test func `binds NOT tighter than AND`() throws {
    // NOT a = 1 AND b = 2  ==>  (NOT a) AND b
    let select =
        try parse(select: "SELECT * FROM T WHERE NOT a = 1 AND b = 2")
    let a = Predicate.comparison(left: .column("a"), op: .equal,
                                 right: .literal(.integer(1)))
    let b = Predicate.comparison(left: .column("b"), op: .equal,
                                 right: .literal(.integer(2)))
    #expect(select.predicate == .and(.not(a), b))
  }

  @Test func `parentheses override operator precedence`() throws {
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

  @Test func `parses IS NULL`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Note IS NULL")
    #expect(select.predicate == .null(.column("Note"), negated: false))
  }

  @Test func `parses IS NOT NULL`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Note IS NOT NULL")
    #expect(select.predicate == .null(.column("Note"), negated: true))
  }

  @Test func `parses IS NULL over a function-call operand`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE iid(Id) IS NULL")
    let call = Expression.call(name: "iid", arguments: [.column("Id")])
    #expect(select.predicate == .null(call, negated: false))
  }

  @Test func `rejects IS without NULL`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE Note IS 1")
    }
  }

  @Test func `parses OR left-associatively`() throws {
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
  @Test func `defaults ORDER BY to ascending`() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName")
    #expect(select.order == Order(column: "TypeName", ascending: true))
  }

  @Test func `parses an explicit ASC order`() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName ASC")
    #expect(select.order == Order(column: "TypeName", ascending: true))
  }

  @Test func `parses a DESC order`() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName DESC")
    #expect(select.order == Order(column: "TypeName", ascending: false))
  }

  @Test func `parses a comma-separated list of sort keys`() throws {
    let select =
        try parse(select: "SELECT * FROM T ORDER BY A, B DESC, C")
    #expect(select.order == Order(keys: [
      Order.Key(column: "A", ascending: true),
      Order.Key(column: "B", ascending: false),
      Order.Key(column: "C", ascending: true),
    ]))
  }

  @Test func `a single-key ORDER BY is one key in the list`() throws {
    let select = try parse(select: "SELECT * FROM T ORDER BY TypeName DESC")
    #expect(select.order?.keys
              == [Order.Key(column: "TypeName", ascending: false)])
  }
}

struct CompositeTests {
  @Test func `parses a full SELECT/WHERE/ORDER BY query`() throws {
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
  @Test func `splits a dotted column into qualifier and name`() {
    let column = Column("t.Name")
    #expect(column.qualifier == "t")
    #expect(column.name == "Name")
  }

  @Test func `leaves an undotted column unqualified`() {
    let column = Column("Name")
    #expect(column.qualifier == nil)
    #expect(column.name == "Name")
  }

  @Test func `splits on the last dot only`() {
    // A two-part relation name may qualify a column — the reserved
    // `information_schema.tables.table_name` — so the split takes the text
    // before the LAST dot as the qualifier and the rest as the name.
    let column = Column("t.a.b")
    #expect(column.qualifier == "t.a")
    #expect(column.name == "b")
  }
}

struct RelationTests {
  @Test func `parses a bare FROM relation with no alias`() throws {
    let select = try parse(select: "SELECT * FROM TypeDef")
    #expect(select.from == Relation(name: "TypeDef"))
    #expect(select.joins.isEmpty)
  }

  @Test func `parses an AS alias on the FROM relation`() throws {
    let select = try parse(select: "SELECT * FROM TypeDef AS t")
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
  }

  @Test func `parses an implicit (AS-less) alias`() throws {
    let select = try parse(select: "SELECT * FROM TypeDef t")
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
  }

  @Test func `does not mistake a following keyword for an alias`() throws {
    let select = try parse(select: "SELECT * FROM TypeDef WHERE Flags = 1")
    #expect(select.from == Relation(name: "TypeDef"))
  }
}

struct JoinTests {
  @Test func `parses a list-shape join with aliases`() throws {
    let select = try parse(select: """
        SELECT m.Name FROM TypeDef AS t
          JOIN MethodDef AS m ON m.parent = t.Id
          WHERE t.TypeName = 'IUnknown'
        """)
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
    #expect(select.joins == [
      Join(relation: Relation(name: "MethodDef", alias: "m"),
           left: Column("m.parent"), right: Column("t.Id")),
    ])
    #expect(select.projection == .columns([Column("m.Name")]))
    let value = Expression.literal(.string("IUnknown"))
    #expect(select.predicate == .comparison(left: .column("t.TypeName"),
                                            op: .equal, right: value))
  }

  @Test func `parses a forward-key join`() throws {
    let select = try parse(select: """
        SELECT r.TypeName FROM TypeDef AS t
          JOIN TypeRef AS r ON t.Extends = r.Id
        """)
    #expect(select.joins == [
      Join(relation: Relation(name: "TypeRef", alias: "r"),
           left: Column("t.Extends"), right: Column("r.Id")),
    ])
  }

  @Test func `parses a join without aliases`() throws {
    let select = try parse(select: """
        SELECT Name FROM MethodDef
          JOIN Param ON Param.parent = MethodDef.Id
        """)
    #expect(select.from == Relation(name: "MethodDef"))
    #expect(select.joins == [
      Join(relation: Relation(name: "Param"),
           left: Column("Param.parent"),
           right: Column("MethodDef.Id")),
    ])
  }

  @Test func `parses a chain of two joins in source order`() throws {
    let select = try parse(select: """
        SELECT Param.Name FROM TypeDef AS t
          JOIN MethodDef AS m ON m.parent = t.Id
          JOIN Param ON Param.parent = m.Id
        """)
    #expect(select.from == Relation(name: "TypeDef", alias: "t"))
    #expect(select.joins == [
      Join(relation: Relation(name: "MethodDef", alias: "m"),
           left: Column("m.parent"), right: Column("t.Id")),
      Join(relation: Relation(name: "Param"),
           left: Column("Param.parent"), right: Column("m.Id")),
    ])
  }

  @Test func `rejects a join missing ON`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM A JOIN B b")
    }
  }

  @Test func `parses a non-equi ON as an arbitrary predicate`() throws {
    let select = try parse(select: """
        SELECT * FROM A JOIN B ON a.x < b.Id
        """)
    #expect(select.joins == [
      Join(relation: Relation(name: "B"),
           on: .comparison(left: .column("a.x"), op: .lt,
                           right: .column("b.Id"))),
    ])
  }

  @Test func `parses a mixed equi-and-residual ON`() throws {
    let select = try parse(select: """
        SELECT * FROM A JOIN B ON a.k = b.k AND a.x < b.y
        """)
    #expect(select.joins == [
      Join(relation: Relation(name: "B"),
           on: .and(.comparison(left: .column("a.k"), op: .equal,
                                right: .column("b.k")),
                    .comparison(left: .column("a.x"), op: .lt,
                                right: .column("b.y")))),
    ])
  }

  @Test func `a bare JOIN is an inner join`() throws {
    let select = try parse(select: "SELECT * FROM A JOIN B ON a.x = b.x")
    #expect(select.joins.first?.kind == .inner)
  }

  @Test func `parses each outer join kind, OUTER optional`() throws {
    let cases: Array<(String, Join.Kind)> = [
      ("INNER JOIN", .inner),
      ("LEFT JOIN", .left),
      ("LEFT OUTER JOIN", .left),
      ("RIGHT JOIN", .right),
      ("RIGHT OUTER JOIN", .right),
      ("FULL JOIN", .full),
      ("FULL OUTER JOIN", .full),
    ]
    for (spelling, kind) in cases {
      let select = try parse(select: """
          SELECT * FROM A \(spelling) B ON a.x = b.x
          """)
      #expect(select.joins == [
        Join(relation: Relation(name: "B"), kind: kind,
             left: Column("a.x"), right: Column("b.x")),
      ])
    }
  }

  @Test func `a join kind without JOIN faults`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM A LEFT B ON a.x = b.x")
    }
  }
}

// MARK: - Literals

struct LiteralTests {
  @Test func `parses TRUE and FALSE as boolean literals`() throws {
    let yes = try parse(select: "SELECT * FROM T WHERE Sealed = TRUE")
    #expect(yes.predicate
                == .comparison(left: .column("Sealed"), op: .equal,
                               right: .literal(.boolean(true))))
    let no = try parse(select: "SELECT * FROM T WHERE Sealed = FALSE")
    #expect(no.predicate
                == .comparison(left: .column("Sealed"), op: .equal,
                               right: .literal(.boolean(false))))
  }

  @Test func `recognises the boolean keywords case-insensitively`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE a = true")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .literal(.boolean(true))))
  }

  @Test func `parses an x'…' hex blob literal into its bytes`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Sig = x'53514c'")
    #expect(select.predicate
                == .comparison(left: .column("Sig"), op: .equal,
                               right: .literal(.blob([0x53, 0x51, 0x4c]))))
  }

  @Test func `parses an uppercase X'…' prefix and mixed-case hex digits`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE a = X'aBcDeF'")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .literal(.blob([0xab, 0xcd, 0xef]))))
  }

  @Test func `parses an empty blob x''`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE a = x''")
    #expect(select.predicate
                == .comparison(left: .column("a"), op: .equal,
                               right: .literal(.blob([]))))
  }

  @Test func `a bare x is an ordinary identifier, not a blob prefix`() throws {
    // The `x` prefix opens a blob only when a quote follows; alone it is a
    // column name.
    let select = try parse(select: "SELECT x FROM T")
    #expect(select.projection == .columns(["x"]))
  }

  @Test func `rejects a blob with an odd hex digit count`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = x'abc'")
    }
  }

  @Test func `rejects a blob with a non-hex digit`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = x'gg'")
    }
  }

  @Test func `rejects an unterminated blob`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = x'abcd")
    }
  }
}

struct ErrorTests {
  @Test func `rejects a query missing FROM`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT TypeName TypeDef")
    }
  }

  @Test func `rejects an invalid operator`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a ! 1")
    }
  }

  @Test func `rejects an unterminated string`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T WHERE a = 'unterminated")
    }
  }

  @Test func `rejects trailing tokens`() {
    // A bare identifier after the relation is now an implicit alias, so
    // trailing garbage must come after a clause that admits no alias — here a
    // second identifier past the relation's (implicit) alias.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM T t garbage")
    }
  }

  @Test func `rejects an empty projection`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT FROM T")
    }
  }

  @Test func `rejects a FROM keyword with no following relation`() {
    // FROM is now optional, so `SELECT *` parses as a FROM-less projection (the
    // engine rejects a `*` with no relation). A bare FROM with no relation,
    // though, ends the input where a relation is required.
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT * FROM")
    }
  }

  @Test func `parses a column on either side of a comparison`() throws {
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
  @Test func `a bare-column list stays the simpler columns projection`() throws {
    let select = try parse(select: "SELECT a, b FROM T")
    #expect(select.projection == .columns(["a", "b"]))
  }

  @Test func `a function call yields an expression projection`() throws {
    let select = try parse(select: "SELECT guid(Name) FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .call(name: "guid",
                                              arguments: [.column("Name")]))
                ]))
  }

  @Test func `an aliased column yields an expression projection`() throws {
    let select = try parse(select: "SELECT Name AS label FROM T")
    #expect(select.projection
                == .expressions([
                  Projected(expression: .column("Name"), alias: "label")
                ]))
  }

  @Test func `a call takes literal and nested-call arguments`() throws {
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

  @Test func `a zero-argument call parses`() throws {
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

  @Test func `parses each arithmetic operator`() throws {
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

  @Test func `multiplication binds tighter than addition`() throws {
    // 2 + 3 * 4  ==>  2 + (3 * 4)
    let parsed = try expression("SELECT 2 + 3 * 4 FROM T")
    let product = Expression.binary(.multiply, .literal(.integer(3)),
                                    .literal(.integer(4)))
    #expect(parsed == .binary(.add, .literal(.integer(2)), product))
  }

  @Test func `parentheses override precedence`() throws {
    // (2 + 3) * 4  ==>  (2 + 3) * 4
    let parsed = try expression("SELECT (2 + 3) * 4 FROM T")
    let sum = Expression.binary(.add, .literal(.integer(2)),
                                .literal(.integer(3)))
    #expect(parsed == .binary(.multiply, sum, .literal(.integer(4))))
  }

  @Test func `addition is left-associative`() throws {
    // 1 - 2 - 3  ==>  (1 - 2) - 3
    let parsed = try expression("SELECT 1 - 2 - 3 FROM T")
    let left = Expression.binary(.subtract, .literal(.integer(1)),
                                 .literal(.integer(2)))
    #expect(parsed == .binary(.subtract, left, .literal(.integer(3))))
  }

  @Test func `arithmetic combines columns and calls`() throws {
    let parsed = try expression("SELECT add(Id, 1) * 10 FROM T")
    let call = Expression.call(name: "add",
                               arguments: [.column("Id"), .literal(.integer(1))])
    #expect(parsed == .binary(.multiply, call, .literal(.integer(10))))
  }

  @Test func `arithmetic parses on either side of a comparison`() throws {
    let select = try parse(select: "SELECT * FROM T WHERE Age + 1 = 26")
    let sum = Expression.binary(.add, .column("Age"), .literal(.integer(1)))
    #expect(select.predicate
                == .comparison(left: sum, op: .equal,
                               right: .literal(.integer(26))))
  }
}

// MARK: - Scalar (FROM-less) SELECT

struct ScalarSelectTests {
  @Test func `parses a FROM-less SELECT with no relation`() throws {
    let select = try parse(select: "SELECT 1")
    #expect(select.from == nil)
    #expect(select.joins.isEmpty)
    #expect(select.predicate == nil)
    #expect(select.order == nil)
    #expect(select.projection
                == .expressions([Projected(expression: .literal(.integer(1)))]))
  }

  @Test func `parses a FROM-less arithmetic projection`() throws {
    let select = try parse(select: "SELECT 1 + 1")
    let sum = Expression.binary(.add, .literal(.integer(1)),
                                .literal(.integer(1)))
    #expect(select.from == nil)
    #expect(select.projection == .expressions([Projected(expression: sum)]))
  }

  @Test func `parses a FROM-less multi-column projection`() throws {
    let select = try parse(select: "SELECT 1, 2")
    #expect(select.from == nil)
    #expect(select.projection == .expressions([
      Projected(expression: .literal(.integer(1))),
      Projected(expression: .literal(.integer(2))),
    ]))
  }

  @Test func `a FROM-less alias names the projected column`() throws {
    let select = try parse(select: "SELECT 1 + 1 AS two")
    let sum = Expression.binary(.add, .literal(.integer(1)),
                                .literal(.integer(1)))
    #expect(select.projection
                == .expressions([Projected(expression: sum, alias: "two")]))
  }

  @Test func `a FROM-less query admits no trailing WHERE`() {
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
  @Test func `infers a view's columns from a bare-column projection`() throws {
    let (name, view) = try parseCreate("CREATE VIEW v AS SELECT a, b FROM t")
    #expect(name == "v")
    #expect(view.columns == ["a", "b"])
    #expect(view.query == .select(Select(projection: .columns(["a", "b"]),
                                         from: Relation(name: "t"))))
  }

  @Test func `drops a qualifier when inferring a column name`() throws {
    let (_, view) = try parseCreate("CREATE VIEW v AS SELECT t.a FROM t")
    #expect(view.columns == ["a"])
  }

  @Test func `takes an explicit column list over the projection`() throws {
    let (name, view) =
        try parseCreate("CREATE VIEW v (x, y) AS SELECT a, b FROM t")
    #expect(name == "v")
    #expect(view.columns == ["x", "y"])
  }

  @Test func `rejects an explicit list wider than the projection`() {
    // (a, b) names two columns over a one-value projection — the view would
    // claim a column its rows lack.
    #expect(throws: SQLError.columns(expected: 1, got: 2)) {
      _ = try Statement(parsing: "CREATE VIEW v (a, b) AS SELECT id FROM t")
    }
  }

  @Test func `rejects an explicit list narrower than the projection`() {
    // (a) names one column over a two-value projection — the projected `name`
    // would have no view column.
    #expect(throws: SQLError.columns(expected: 2, got: 1)) {
      _ = try Statement(parsing: "CREATE VIEW v (a) AS SELECT id, name FROM t")
    }
  }

  @Test func `accepts an explicit list matching the projection arity`() throws {
    let (_, view) =
        try parseCreate("CREATE VIEW v (a, b) AS SELECT id, name FROM t")
    #expect(view.columns == ["a", "b"])
  }

  @Test func `defers a SELECT * view's column-count check to the engine`() throws {
    // A `SELECT *` has no statically known arity, so the parser admits any
    // explicit list; the engine validates it against the relation at
    // resolution.
    let (_, view) =
        try parseCreate("CREATE VIEW v (a, b) AS SELECT * FROM t")
    #expect(view.columns == ["a", "b"])
  }

  @Test func `infers a column name from an expression's alias`() throws {
    let (_, view) =
        try parseCreate("CREATE VIEW v AS SELECT guid(Id) AS iid FROM t")
    #expect(view.columns == ["iid"])
  }

  @Test func `infers a bare column's name in an expression projection`() throws {
    // A projection carrying any alias is the richer expressions form; a bare
    // column in it still infers to its own name.
    let (_, view) =
        try parseCreate("CREATE VIEW v AS SELECT Name, guid(Id) AS iid FROM t")
    #expect(view.columns == ["Name", "iid"])
  }

  @Test func `parses lowercase CREATE VIEW keywords`() throws {
    let (name, view) =
        try parseCreate("create view v as select a from t")
    #expect(name == "v")
    #expect(view.columns == ["a"])
  }

  @Test func `rejects a SELECT * view with no explicit columns`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "CREATE VIEW v AS SELECT * FROM t")
    }
  }

  @Test func `rejects an unaliased expression with no explicit columns`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "CREATE VIEW v AS SELECT guid(Id) FROM t")
    }
  }

  @Test func `rejects an explicit duplicate column name`() {
    #expect(throws: SQLError.duplicate("x")) {
      _ = try Statement(parsing: "CREATE VIEW v (x, x) AS SELECT a, b FROM t")
    }
  }

  @Test func `rejects a case-insensitive explicit duplicate column name`() {
    #expect(throws: SQLError.duplicate("x")) {
      _ = try Statement(parsing: "CREATE VIEW v (X, x) AS SELECT a, b FROM t")
    }
  }

  @Test func `rejects an inferred duplicate column name`() {
    #expect(throws: SQLError.duplicate("Name")) {
      _ = try Statement(
          parsing: "CREATE VIEW v AS SELECT t.Name, u.Name FROM t "
              + "JOIN u ON t.Id = u.Id")
    }
  }

  @Test func `accepts a distinct inferred column list`() throws {
    let (_, view) = try parseCreate("CREATE VIEW v AS SELECT a, b FROM t")
    #expect(view.columns == ["a", "b"])
  }
}

// MARK: - CREATE FUNCTION

/// Parses `text` and returns `(name, function)`, failing on any other shape.
private func parse(function text: String) throws -> (String, Function) {
  guard case let .function(name, function) = try Statement(parsing: text)
  else {
    Issue.record("expected a CREATE FUNCTION statement")
    throw SQLError.incomplete(expected: "a CREATE FUNCTION statement")
  }
  return (name, function)
}

struct CreateFunctionTests {
  @Test func `parses a scalar function's name, parameters, return, and body`() throws {
    let (name, function) = try parse(function: """
        CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER AS n + n
        """)
    #expect(name == "twice")
    #expect(function.parameters
                == [Function.Parameter(name: "n", type: .integer)])
    #expect(function.returns == .integer)
    #expect(function.body == .binary(.add, .column("n"), .column("n")))
  }

  @Test func `parses several typed parameters in order`() throws {
    let (_, function) = try parse(function: """
        CREATE FUNCTION f(a INTEGER, b TEXT, c BOOLEAN) RETURNS TEXT AS b
        """)
    #expect(function.parameters == [
      Function.Parameter(name: "a", type: .integer),
      Function.Parameter(name: "b", type: .text),
      Function.Parameter(name: "c", type: .boolean),
    ])
    #expect(function.returns == .text)
  }

  @Test func `parses a parameterless function over a literal body`() throws {
    let (name, function) = try parse(function: """
        CREATE FUNCTION answer() RETURNS INTEGER AS 42
        """)
    #expect(name == "answer")
    #expect(function.parameters.isEmpty)
    #expect(function.body == .literal(.integer(42)))
  }

  @Test func `maps the ISO type spellings onto value types`() throws {
    let (_, function) = try parse(function: """
        CREATE FUNCTION f(a INT, b REAL, c VARCHAR, d BOOL, e BLOB) \
        RETURNS DOUBLE AS b
        """)
    #expect(function.parameters.map(\.type)
                == [.integer, .double, .text, .boolean, .blob])
    #expect(function.returns == .double)
  }

  @Test func `parses lowercase CREATE FUNCTION keywords`() throws {
    let (name, function) = try parse(function: """
        create function f(n integer) returns integer as n
        """)
    #expect(name == "f")
    #expect(function.returns == .integer)
  }

  @Test func `rejects a duplicate parameter name`() {
    #expect(throws: SQLError.duplicate("n")) {
      _ = try Statement(
          parsing: "CREATE FUNCTION f(n INTEGER, n TEXT) RETURNS INTEGER AS n")
    }
  }

  @Test func `rejects a case-insensitive duplicate parameter name`() {
    // The offending (later) spelling is reported, matching the explicit
    // view-column duplicate fault (`CREATE VIEW v (X, x)` reports `x`).
    #expect(throws: SQLError.duplicate("n")) {
      _ = try Statement(
          parsing: "CREATE FUNCTION f(N INTEGER, n TEXT) RETURNS INTEGER AS n")
    }
  }

  @Test func `rejects an unknown type spelling`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(
          parsing: "CREATE FUNCTION f(n WIDGET) RETURNS INTEGER AS n")
    }
  }

  @Test func `rejects a function with no RETURNS clause`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "CREATE FUNCTION f(n INTEGER) AS n")
    }
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
  @Test func `parses UNION into a deduplicating union of two selects`() throws {
    let query = try parse(query: "SELECT a FROM t UNION SELECT b FROM u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .setop(.union, .select(left), .select(right),
                            all: false))
  }

  @Test func `parses UNION ALL into a duplicate-keeping union`() throws {
    let query = try parse(query: "SELECT a FROM t UNION ALL SELECT b FROM u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .setop(.union, .select(left), .select(right), all: true))
  }

  @Test func `nests a chain of UNIONs left-associatively in source order`() throws {
    let query = try parse(query:
        "SELECT a FROM t UNION SELECT b FROM u UNION ALL SELECT c FROM v")
    let a = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let b = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    let c = Select(projection: .columns(["c"]), from: Relation(name: "v"))
    #expect(query == .setop(.union,
                            .setop(.union, .select(a), .select(b), all: false),
                            .select(c), all: true))
  }

  @Test func `recognises lowercase union and all keywords`() throws {
    let query = try parse(query: "select a from t union all select b from u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .setop(.union, .select(left), .select(right), all: true))
  }

  @Test func `a CREATE VIEW over a UNION stores the query and the first arm's names`() throws {
    let (name, view) = try parseCreate(
        "CREATE VIEW v AS SELECT a, b FROM t UNION SELECT c, d FROM u")
    let left = Select(projection: .columns(["a", "b"]),
                      from: Relation(name: "t"))
    let right = Select(projection: .columns(["c", "d"]),
                       from: Relation(name: "u"))
    #expect(name == "v")
    #expect(view.columns == ["a", "b"])
    #expect(view.query == .setop(.union, .select(left), .select(right),
                                 all: false))
  }

  @Test func `parses INTERSECT into a set operation of two selects`() throws {
    let query = try parse(query: "SELECT a FROM t INTERSECT SELECT b FROM u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .setop(.intersect, .select(left), .select(right),
                            all: false))
  }

  @Test func `parses EXCEPT ALL into a duplicate-keeping set operation`() throws {
    let query = try parse(query: "SELECT a FROM t EXCEPT ALL SELECT b FROM u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .setop(.except, .select(left), .select(right), all: true))
  }

  @Test func `INTERSECT binds tighter than UNION, nesting on the right`() throws {
    // `a UNION b INTERSECT c` is `a UNION (b INTERSECT c)` — ISO precedence.
    let query = try parse(query:
        "SELECT a FROM t UNION SELECT b FROM u INTERSECT SELECT c FROM v")
    let a = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let b = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    let c = Select(projection: .columns(["c"]), from: Relation(name: "v"))
    #expect(query == .setop(.union, .select(a),
                            .setop(.intersect, .select(b), .select(c),
                                   all: false),
                            all: false))
  }

  @Test func `UNION and EXCEPT associate left at the same precedence`() throws {
    // `a UNION b EXCEPT c` is `(a UNION b) EXCEPT c`.
    let query = try parse(query:
        "SELECT a FROM t UNION SELECT b FROM u EXCEPT SELECT c FROM v")
    let a = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let b = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    let c = Select(projection: .columns(["c"]), from: Relation(name: "v"))
    #expect(query == .setop(.except,
                            .setop(.union, .select(a), .select(b), all: false),
                            .select(c), all: false))
  }

  @Test func `recognises lowercase intersect and except keywords`() throws {
    let query = try parse(query: "select a from t intersect select b from u")
    let left = Select(projection: .columns(["a"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["b"]), from: Relation(name: "u"))
    #expect(query == .setop(.intersect, .select(left), .select(right),
                            all: false))
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
  @Test func `parses a single non-recursive CTE and its trailing query`() throws {
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

  @Test func `infers a CTE's columns from its query's projection`() throws {
    let (ctes, _) = try parseWith("""
        WITH a AS (SELECT p, q FROM t) SELECT p FROM a
        """)
    #expect(ctes[0].columns == ["p", "q"])
  }

  @Test func `an explicit column list names a CTE's columns`() throws {
    let (ctes, _) = try parseWith("""
        WITH a (k, v) AS (SELECT p, q FROM t) SELECT k FROM a
        """)
    #expect(ctes[0].columns == ["k", "v"])
  }

  @Test func `parses several comma-separated CTEs in source order`() throws {
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

  @Test func `RECURSIVE marks every CTE of the list recursive`() throws {
    let (ctes, _) = try parseWith("""
        WITH RECURSIVE a (n) AS (SELECT n FROM seed UNION ALL SELECT n FROM a)
          SELECT n FROM a
        """)
    #expect(ctes[0].recursive == true)
    #expect(ctes[0].columns == ["n"])
    guard case .setop(.union, _, _, _) = ctes[0].query else {
      Issue.record("expected the recursive CTE's query to be a UNION")
      return
    }
  }

  @Test func `a CTE's query may itself be a UNION`() throws {
    let (ctes, _) = try parseWith("""
        WITH a AS (SELECT x FROM t UNION SELECT y FROM u) SELECT x FROM a
        """)
    let left = Select(projection: .columns(["x"]), from: Relation(name: "t"))
    let right = Select(projection: .columns(["y"]), from: Relation(name: "u"))
    #expect(ctes[0].query == .setop(.union, .select(left), .select(right),
                                    all: false))
  }

  @Test func `recognises lowercase with and recursive keywords`() throws {
    let (ctes, query) = try parseWith("""
        with recursive a (n) as (select n from a) select n from a
        """)
    #expect(ctes[0].name == "a")
    #expect(ctes[0].recursive == true)
    #expect(query == .select(Select(projection: .columns(["n"]),
                                    from: Relation(name: "a"))))
  }

  @Test func `an explicit list of the wrong arity is rejected`() throws {
    #expect(throws: SQLError.columns(expected: 2, got: 3)) {
      _ = try parseWith("""
          WITH a (x, y, z) AS (SELECT p, q FROM t) SELECT x FROM a
          """)
    }
  }

  @Test func `a CTE naming two columns that collide by case is rejected`() throws {
    #expect(throws: SQLError.duplicate("X")) {
      _ = try parseWith("WITH a (x, X) AS (SELECT p, q FROM t) SELECT x FROM a")
    }
  }

  @Test func `a CTE projecting an un-nameable column with no list is rejected`() throws {
    #expect(throws: SQLError.named("SELECT *")) {
      _ = try parseWith("WITH a AS (SELECT * FROM t) SELECT x FROM a")
    }
  }

  @Test func `a CTE missing its parenthesised query is rejected`() throws {
    #expect(throws: SQLError.self) {
      _ = try parseWith("WITH a AS SELECT x FROM t SELECT x FROM a")
    }
  }
}
