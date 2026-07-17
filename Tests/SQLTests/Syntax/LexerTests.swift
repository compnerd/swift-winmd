// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

/// Drains the streaming lexer over `text` into an array of tokens.
private func tokens(_ text: String) throws -> Array<Token> {
  var lexer = Lexer(text.utf8Span.span)
  var tokens = Array<Token>()
  while let token = try lexer.next() {
    tokens.append(token)
  }
  return tokens
}

/// The kinds of the tokens the lexer yields for `text`.
private func lex(_ text: String) throws -> Array<Token.Kind> {
  try tokens(text).map(\.kind)
}

private struct Lexing: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let text: String
  internal let expected: Array<Token.Kind>

  internal var testDescription: String { name }
}

private let kLexing: Array<Lexing> = [
  Lexing(name: "every keyword",
         text: "SELECT FROM WHERE ORDER BY ASC DESC AND OR NOT",
         expected: [.select, .from, .where, .order, .by, .asc, .desc,
                    .and, .or, .not]),
  Lexing(name: "case-insensitive keywords", text: "select Order by",
         expected: [.select, .order, .by]),
  Lexing(name: "join keywords", text: "JOIN ON AS",
         expected: [.join, .on, .as]),
  Lexing(name: "case-insensitive join keywords", text: "join on As",
         expected: [.join, .on, .as]),
  Lexing(name: "NULL-test keywords", text: "IS NOT NULL is null",
         expected: [.is, .not, .null, .is, .null]),
  Lexing(name: "WITH-clause keywords", text: "WITH RECURSIVE",
         expected: [.with, .recursive]),
  Lexing(name: "case-insensitive WITH-clause keywords",
         text: "with Recursive", expected: [.with, .recursive]),
  Lexing(name: "row-limiting keywords and synonyms",
         text: "OFFSET FETCH FIRST ROWS ONLY ROW NEXT",
         expected: [.offset, .fetch, .first, .rows, .only, .rows, .first]),
  Lexing(name: "comparison operators", text: "= <> < > <= >=",
         expected: [.equal, .unequal, .lt, .gt, .leq, .geq]),
  Lexing(name: "punctuation", text: "* , ( )",
         expected: [.star, .comma, .lparen, .rparen]),
  Lexing(name: "dotted identifier", text: "TypeDef.TypeName",
         expected: [.identifier("TypeDef.TypeName")]),
  Lexing(name: "integer literals", text: "0 42 1024",
         expected: [.integer(0), .integer(42), .integer(1024)]),
  Lexing(name: "decimal fractions", text: "3.14 1.0 0.5",
         expected: [.decimal(3.14), .decimal(1.0), .decimal(0.5)]),
  Lexing(name: "decimal exponents", text: "1e3 2.5e-1 6E2 1.5e+2",
         expected: [.decimal(1e3), .decimal(2.5e-1),
                    .decimal(6e2), .decimal(1.5e2)]),
  Lexing(name: "bare digits remain integers", text: "7 100",
         expected: [.integer(7), .integer(100)]),
  Lexing(name: "fractions require a digit after the dot", text: "1.5 1.5e0",
         expected: [.decimal(1.5), .decimal(1.5)]),
  Lexing(name: "an e without exponent digits", text: "1e",
         expected: [.integer(1), .identifier("e")]),
  Lexing(name: "qualified reference", text: "Field.Flags",
         expected: [.identifier("Field.Flags")]),
  Lexing(name: "quoted string", text: "'Windows.Win32.Foundation'",
         expected: [.string("Windows.Win32.Foundation")]),
  Lexing(name: "doubled quote in a string", text: "'O''Brien'",
         expected: [.string("O'Brien")]),
  Lexing(name: "empty string", text: "''", expected: [.string("")]),
  Lexing(name: "delimited identifiers",
         text: "\"Offset\" \"select\" \"a.b\"",
         expected: [.quoted("Offset"), .quoted("select"), .quoted("a.b")]),
  Lexing(name: "doubled quote in a delimited identifier",
         text: "\"a\"\"b\"", expected: [.quoted("a\"b")]),
  Lexing(name: "tokens without whitespace", text: "a<=1",
         expected: [.identifier("a"), .leq, .integer(1)]),
  Lexing(name: "line comment between tokens",
         text: "SELECT -- pick a star\n*", expected: [.select, .star]),
  Lexing(name: "line comment at end of input",
         text: "SELECT * -- trailing", expected: [.select, .star]),
  Lexing(name: "block comment spanning a newline",
         text: "SELECT /* a\n block */ *", expected: [.select, .star]),
  Lexing(name: "block comment between tokens",
         text: "SELECT /* star */ *", expected: [.select, .star]),
  Lexing(name: "lone minus and slash operators", text: "a - 1 / 2",
         expected: [.identifier("a"), .minus, .integer(1), .slash,
                    .integer(2)]),
  Lexing(name: "bound-parameter placeholder", text: "WHERE a = :pid",
         expected: [.where, .identifier("a"), .equal, .parameter("pid")]),
]

private struct Fault: Sendable, CustomTestStringConvertible {
  internal let name: String
  internal let text: String

  internal var testDescription: String { name }
}

private let kFaults: Array<Fault> = [
  Fault(name: "decimal overflow", text: "1e9999"),
  Fault(name: "unexpected character", text: "SELECT @ FROM T"),
  Fault(name: "unterminated string", text: "'oops"),
  Fault(name: "unterminated delimited identifier", text: "\"oops"),
  Fault(name: "unterminated block comment", text: "SELECT /* oops"),
  Fault(name: "colon without an identifier", text: "SELECT : FROM T"),
]

struct LexerTests {
  @Test(arguments: kLexing)
  fileprivate func lexes(_ test: Lexing) throws {
    #expect(try lex(test.text) == test.expected)
  }

  @Test func `records each token's byte offset`() throws {
    #expect(try tokens("SELECT *").map(\.location.offset) == [0, 7])
  }

  @Test func `tracks line and column across a newline`() throws {
    // The lexer tracks 1-based line and column, resetting the column on each
    // newline.
    let locations = try tokens("SELECT *\nFROM T").map(\.location)
    #expect(locations.map(\.line) == [1, 1, 2, 2])
    #expect(locations.map(\.column) == [1, 8, 1, 6])
  }

  @Test func `yields one token per next() and nil at end`() throws {
    // The lexer yields one token per `next()` call and signals end of input
    // with a trailing `nil`, without ever materialising a token array.
    let text = "SELECT *"
    var lexer = Lexer(text.utf8Span.span)
    #expect(try lexer.next()
                == Token(kind: .select,
                         location: SourceLocation(line: 1, column: 1,
                                                  offset: 0)))
    #expect(try lexer.next()
                == Token(kind: .star,
                         location: SourceLocation(line: 1, column: 8,
                                                  offset: 7)))
    #expect(try lexer.next() == nil)
    #expect(try lexer.next() == nil)
  }

  @Test(arguments: kFaults)
  fileprivate func rejects(_ test: Fault) {
    #expect(throws: SQLError.self) { _ = try lex(test.text) }
  }

  @Test func `tracks line and column across a block comment`() throws {
    // Newlines inside a block comment still advance the line counter.
    let locations = try tokens("SELECT /* a\nb */ *").map(\.location)
    #expect(locations.map(\.line) == [1, 2])
    #expect(locations.map(\.column) == [1, 6])
  }

}
