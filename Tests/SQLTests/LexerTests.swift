// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQL

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

struct LexerTests {
  @Test("lexes every keyword")
  func keywords() throws {
    #expect(try lex("SELECT FROM WHERE ORDER BY ASC DESC AND OR NOT")
                == [.select, .from, .where, .order, .by, .asc, .desc,
                    .and, .or, .not])
  }

  @Test("lexes keywords case-insensitively")
  func keywordsCaseInsensitive() throws {
    #expect(try lex("select Order by") == [.select, .order, .by])
  }

  @Test("lexes the join keywords")
  func joinKeywords() throws {
    #expect(try lex("JOIN ON AS") == [.join, .on, .as])
  }

  @Test("lexes the join keywords case-insensitively")
  func joinKeywordsCaseInsensitive() throws {
    #expect(try lex("join on As") == [.join, .on, .as])
  }

  @Test("lexes the comparison operators")
  func operators() throws {
    #expect(try lex("= <> < > <= >=")
                == [.equal, .unequal, .lt, .gt, .leq, .geq])
  }

  @Test("lexes punctuation tokens")
  func punctuation() throws {
    #expect(try lex("* , ( )")
                == [.star, .comma, .lparen, .rparen])
  }

  @Test("lexes a dotted identifier as one token")
  func identifierWithDot() throws {
    #expect(try lex("TypeDef.TypeName") == [.identifier("TypeDef.TypeName")])
  }

  @Test("lexes integer literals")
  func integerLiteral() throws {
    #expect(try lex("0 42 1024")
                == [.integer(0), .integer(42), .integer(1024)])
  }

  @Test("lexes a quoted string literal")
  func stringLiteral() throws {
    #expect(try lex("'Windows.Win32.Foundation'")
                == [.string("Windows.Win32.Foundation")])
  }

  @Test("unescapes a doubled quote in a string")
  func escapedQuoteInString() throws {
    #expect(try lex("'O''Brien'") == [.string("O'Brien")])
  }

  @Test("lexes an empty string literal")
  func emptyString() throws {
    #expect(try lex("''") == [.string("")])
  }

  @Test("lexes tokens with no separating whitespace")
  func adjacentOperators() throws {
    // No whitespace required between an identifier and an operator.
    #expect(try lex("a<=1")
                == [.identifier("a"), .leq, .integer(1)])
  }

  @Test("records each token's byte offset")
  func position() throws {
    #expect(try tokens("SELECT *").map(\.location.offset) == [0, 7])
  }

  @Test("tracks line and column across a newline")
  func location() throws {
    // The lexer tracks 1-based line and column, resetting the column on each
    // newline.
    let locations = try tokens("SELECT *\nFROM T").map(\.location)
    #expect(locations.map(\.line) == [1, 1, 2, 2])
    #expect(locations.map(\.column) == [1, 8, 1, 6])
  }

  @Test("yields one token per next() and nil at end")
  func streaming() throws {
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

  @Test("rejects an unexpected character")
  func unexpectedCharacter() {
    #expect(throws: SQLError.self) { _ = try lex("SELECT @ FROM T") }
  }

  @Test("rejects an unterminated string")
  func unterminatedString() {
    #expect(throws: SQLError.self) { _ = try lex("'oops") }
  }

  @Test("scans a bound-parameter placeholder")
  func parameter() throws {
    #expect(try lex("WHERE a = :pid")
                == [.where, .identifier("a"), .equal, .parameter("pid")])
  }

  @Test("rejects a colon not followed by an identifier")
  func bareColon() {
    #expect(throws: SQLError.self) { _ = try lex("SELECT : FROM T") }
  }
}
