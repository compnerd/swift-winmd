// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLStandard
@testable import SQLShell

// The standalone shell's pieces — the in-memory `Database` session, the box
// renderer, and the `Statements` splitter — exercised without capturing the
// REPL's stdout.

struct DatabaseTests {
  @Test func `a VALUES query yields its rows over an empty catalog`() throws {
    var database = Database()
    let rows = try database.run("SELECT * FROM (VALUES (1), (2), (3)) AS t")
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
  }

  @Test func `CREATE VIEW registers and a later SELECT reads it`() throws {
    var database = Database()
    let define = "CREATE VIEW v AS SELECT column1 FROM (VALUES (7)) AS t"
    #expect(try database.run(define).isEmpty)
    let rows = try database.run("SELECT * FROM v")
    #expect(rows == [[.integer(7)]])
    #expect(database.views().contains("v"))
  }

  @Test func `CREATE FUNCTION registers and a later query calls it`() throws {
    var database = Database()
    let define = "CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER AS n * 2"
    #expect(try database.run(define).isEmpty)
    let rows = try database.run("SELECT twice(21) FROM (VALUES (0)) AS t")
    #expect(rows == [[.integer(42)]])
  }

  @Test func `a standard built-in resolves without registration`() throws {
    var database = Database()
    let rows = try database.run("SELECT UPPER('abc') FROM (VALUES (0)) AS t")
    #expect(rows == [[.text("ABC")]])
  }

  @Test func `a bound parameter threads into the query`() throws {
    var database = Database()
    let query = "SELECT column1 FROM (VALUES (1), (2)) AS t WHERE column1 = :n"
    let rows = try database.run(query, bindings: ["n": .integer(2)])
    #expect(rows == [[.integer(2)]])
  }

  @Test func `the base catalog has no relations`() throws {
    let database = Database()
    #expect(database.relations().isEmpty)
    #expect(database.table(named: "anything") == nil)
  }
}

struct MemoryCatalogTests {
  @Test func `a naturally-cased view key resolves case-insensitively`() throws {
    // The initializer must fold the supplied keys, so a `"MyView"` name
    // resolves through the case-insensitive `view(named:)` (which lowercases
    // the lookup); an unfolded key would leave the view unreachable.
    let sql = "CREATE VIEW x AS SELECT column1 FROM (VALUES (1)) AS t"
    guard case let .create(_, view) = try Statement(parsing: sql) else {
      Issue.record("expected a CREATE VIEW")
      return
    }
    let catalog = MemoryCatalog(views: ["MyView": view])
    #expect(catalog.view(named: "myview") != nil)
    #expect(catalog.view(named: "MyView") != nil)
    #expect(catalog.view(named: "MYVIEW") != nil)
    #expect(catalog.views() == ["myview"])
  }
}

struct BoxTests {
  @Test func `render frames a header, rule, and rows`() throws {
    let table = Box.render(["n"], [[.integer(1)], [.integer(22)]])
    #expect(table == """
        ┌────┐
        │ n  │
        ├────┤
        │ 1  │
        │ 22 │
        └────┘
        """)
  }

  @Test func `render frames the header alone over an empty result`() throws {
    let table = Box.render(["x"], [])
    #expect(table == """
        ┌───┐
        │ x │
        ├───┤
        └───┘
        """)
  }
}

struct StatementStreamTests {
  @Test func `the stream splits on unquoted semicolons`() throws {
    let text = "SELECT 1; SELECT 2;\nSELECT 3"
    let statements = Array(Statements(of: text))
    #expect(statements == ["SELECT 1", "SELECT 2", "SELECT 3"])
  }

  @Test func `a semicolon inside a string is not a terminator`() throws {
    let statements = Array(Statements(of: "SELECT 'a;b'; SELECT 2"))
    #expect(statements == ["SELECT 'a;b'", "SELECT 2"])
  }

  @Test func `a trailing comment is trivia, not a statement`() throws {
    let statements = Array(Statements(of: "SELECT 1;\n-- done"))
    #expect(statements == ["SELECT 1"])
  }
}

struct HeaderTests {
  @Test func `a resolved projection names the box columns`() throws {
    let console = Console()
    let query = "SELECT 1 AS a, 2 AS b FROM (VALUES (0)) AS t"
    let names = console.headers(of: query, [[.integer(1), .integer(2)]])
    #expect(names == ["a", "b"])
  }

  @Test func `a definition names no columns`() throws {
    let console = Console()
    let define = "CREATE VIEW v AS SELECT column1 FROM (VALUES (1)) AS t"
    #expect(console.headers(of: define, []) == nil)
  }
}
