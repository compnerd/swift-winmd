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

  @Test("lexes the NULL-test keywords")
  func nullKeywords() throws {
    #expect(try lex("IS NOT NULL") == [.is, .not, .null])
    #expect(try lex("is null") == [.is, .null])
  }

  @Test("lexes the WITH-clause keywords")
  func withKeywords() throws {
    #expect(try lex("WITH RECURSIVE") == [.with, .recursive])
  }

  @Test("lexes the WITH-clause keywords case-insensitively")
  func withKeywordsCaseInsensitive() throws {
    #expect(try lex("with Recursive") == [.with, .recursive])
  }

  @Test("lexes the row-limiting keywords")
  func rowLimitKeywords() throws {
    #expect(try lex("OFFSET FETCH FIRST ROWS ONLY")
                == [.offset, .fetch, .first, .rows, .only])
    // ROW is a synonym of ROWS, and NEXT of FIRST.
    #expect(try lex("ROW NEXT") == [.rows, .first])
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

  @Test("lexes decimal literals with a fraction")
  func decimalFraction() throws {
    #expect(try lex("3.14 1.0 0.5")
                == [.decimal(3.14), .decimal(1.0), .decimal(0.5)])
  }

  @Test("lexes decimal literals with an exponent")
  func decimalExponent() throws {
    // A bare integer with an exponent is approximate-numeric, as is one with a
    // signed exponent or a fraction and an exponent together.
    #expect(try lex("1e3 2.5e-1 6E2 1.5e+2")
                == [.decimal(1e3), .decimal(2.5e-1),
                    .decimal(6e2), .decimal(1.5e2)])
  }

  @Test("a bare run of digits stays an integer")
  func integerNotDecimal() throws {
    // Neither a `.` nor an `e` follows, so each is exact numeric.
    #expect(try lex("7 100") == [.integer(7), .integer(100)])
  }

  @Test("a dot fraction is taken only when a digit follows")
  func fractionRequiresDigit() throws {
    // A `.` begins a fraction only before a digit: `1.5` is one decimal, while
    // `1.5e0` also folds the exponent in.
    #expect(try lex("1.5") == [.decimal(1.5)])
    #expect(try lex("1.5e0") == [.decimal(1.5)])
  }

  @Test("an e with no exponent digit is not an exponent")
  func bareExponentLetter() throws {
    // `1e` has no exponent digit, so the number ends at `1` and `e` begins an
    // identifier.
    #expect(try lex("1e") == [.integer(1), .identifier("e")])
  }

  @Test("a decimal literal past Double's range is an overflow")
  func decimalOverflow() {
    // `Double("1e9999")` is `inf`, not nil — reject it as an overflow, like an
    // out-of-range integer, so no `inf` enters the token stream.
    #expect(throws: SQLError.self) { _ = try lex("1e9999") }
  }

  @Test("a qualified reference is not read as a decimal")
  func qualifiedReference() throws {
    // A qualified name begins with a letter, so it never enters the numeric
    // scanner — `Field.Flags` is one identifier, dot and all.
    #expect(try lex("Field.Flags") == [.identifier("Field.Flags")])
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

  @Test("lexes a delimited identifier verbatim")
  func delimitedIdentifier() throws {
    // A double-quoted name is a `quoted` token, case-preserved and never a
    // keyword — distinct from a bare identifier so a dot in it is kept.
    #expect(try lex("\"Offset\"") == [.quoted("Offset")])
    #expect(try lex("\"select\"") == [.quoted("select")])
    #expect(try lex("\"a.b\"") == [.quoted("a.b")])
  }

  @Test("unescapes a doubled quote in a delimited identifier")
  func escapedQuoteInIdentifier() throws {
    #expect(try lex("\"a\"\"b\"") == [.quoted("a\"b")])
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

  @Test("rejects an unterminated delimited identifier")
  func unterminatedIdentifier() {
    #expect(throws: SQLError.self) { _ = try lex("\"oops") }
  }

  @Test("skips a line comment between tokens")
  func lineComment() throws {
    #expect(try lex("SELECT -- pick a star\n*")
                == [.select, .star])
  }

  @Test("skips a line comment at end of input")
  func lineCommentAtEnd() throws {
    // An unterminated `--` comment at EOF is not a fault.
    #expect(try lex("SELECT * -- trailing") == [.select, .star])
  }

  @Test("skips a block comment spanning a newline")
  func blockComment() throws {
    #expect(try lex("SELECT /* a\n block */ *") == [.select, .star])
  }

  @Test("skips a block comment between tokens on one line")
  func blockCommentInline() throws {
    #expect(try lex("SELECT /* star */ *") == [.select, .star])
  }

  @Test("lexes a lone minus and slash as operators")
  func loneOperators() throws {
    // A single `-` or `/` is still an operator; only `--` and `/*` begin a
    // comment.
    #expect(try lex("a - 1 / 2")
                == [.identifier("a"), .minus, .integer(1), .slash,
                    .integer(2)])
  }

  @Test("rejects an unterminated block comment")
  func unterminatedBlockComment() {
    #expect(throws: SQLError.self) { _ = try lex("SELECT /* oops") }
  }

  @Test("tracks line and column across a block comment")
  func commentLocation() throws {
    // Newlines inside a block comment still advance the line counter.
    let locations = try tokens("SELECT /* a\nb */ *").map(\.location)
    #expect(locations.map(\.line) == [1, 2])
    #expect(locations.map(\.column) == [1, 6])
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
