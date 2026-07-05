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
  @Test func `lexes every keyword`() throws {
    #expect(try lex("SELECT FROM WHERE ORDER BY ASC DESC AND OR NOT")
                == [.select, .from, .where, .order, .by, .asc, .desc,
                    .and, .or, .not])
  }

  @Test func `lexes keywords case-insensitively`() throws {
    #expect(try lex("select Order by") == [.select, .order, .by])
  }

  @Test func `lexes the join keywords`() throws {
    #expect(try lex("JOIN ON AS") == [.join, .on, .as])
  }

  @Test func `lexes the join keywords case-insensitively`() throws {
    #expect(try lex("join on As") == [.join, .on, .as])
  }

  @Test func `lexes the NULL-test keywords`() throws {
    #expect(try lex("IS NOT NULL") == [.is, .not, .null])
    #expect(try lex("is null") == [.is, .null])
  }

  @Test func `lexes the WITH-clause keywords`() throws {
    #expect(try lex("WITH RECURSIVE") == [.with, .recursive])
  }

  @Test func `lexes the WITH-clause keywords case-insensitively`() throws {
    #expect(try lex("with Recursive") == [.with, .recursive])
  }

  @Test func `lexes the row-limiting keywords`() throws {
    #expect(try lex("OFFSET FETCH FIRST ROWS ONLY")
                == [.offset, .fetch, .first, .rows, .only])
    // ROW is a synonym of ROWS, and NEXT of FIRST.
    #expect(try lex("ROW NEXT") == [.rows, .first])
  }

  @Test func `lexes the comparison operators`() throws {
    #expect(try lex("= <> < > <= >=")
                == [.equal, .unequal, .lt, .gt, .leq, .geq])
  }

  @Test func `lexes punctuation tokens`() throws {
    #expect(try lex("* , ( )")
                == [.star, .comma, .lparen, .rparen])
  }

  @Test func `lexes a dotted identifier as one token`() throws {
    #expect(try lex("TypeDef.TypeName") == [.identifier("TypeDef.TypeName")])
  }

  @Test func `lexes integer literals`() throws {
    #expect(try lex("0 42 1024")
                == [.integer(0), .integer(42), .integer(1024)])
  }

  @Test func `lexes decimal literals with a fraction`() throws {
    #expect(try lex("3.14 1.0 0.5")
                == [.decimal(3.14), .decimal(1.0), .decimal(0.5)])
  }

  @Test func `lexes decimal literals with an exponent`() throws {
    // A bare integer with an exponent is approximate-numeric, as is one with a
    // signed exponent or a fraction and an exponent together.
    #expect(try lex("1e3 2.5e-1 6E2 1.5e+2")
                == [.decimal(1e3), .decimal(2.5e-1),
                    .decimal(6e2), .decimal(1.5e2)])
  }

  @Test func `a bare run of digits stays an integer`() throws {
    // Neither a `.` nor an `e` follows, so each is exact numeric.
    #expect(try lex("7 100") == [.integer(7), .integer(100)])
  }

  @Test func `a dot fraction is taken only when a digit follows`() throws {
    // A `.` begins a fraction only before a digit: `1.5` is one decimal, while
    // `1.5e0` also folds the exponent in.
    #expect(try lex("1.5") == [.decimal(1.5)])
    #expect(try lex("1.5e0") == [.decimal(1.5)])
  }

  @Test func `an e with no exponent digit is not an exponent`() throws {
    // `1e` has no exponent digit, so the number ends at `1` and `e` begins an
    // identifier.
    #expect(try lex("1e") == [.integer(1), .identifier("e")])
  }

  @Test func `a decimal literal past Double's range is an overflow`() {
    // `Double("1e9999")` is `inf`, not nil — reject it as an overflow, like an
    // out-of-range integer, so no `inf` enters the token stream.
    #expect(throws: SQLError.self) { _ = try lex("1e9999") }
  }

  @Test func `a qualified reference is not read as a decimal`() throws {
    // A qualified name begins with a letter, so it never enters the numeric
    // scanner — `Field.Flags` is one identifier, dot and all.
    #expect(try lex("Field.Flags") == [.identifier("Field.Flags")])
  }

  @Test func `lexes a quoted string literal`() throws {
    #expect(try lex("'Windows.Win32.Foundation'")
                == [.string("Windows.Win32.Foundation")])
  }

  @Test func `unescapes a doubled quote in a string`() throws {
    #expect(try lex("'O''Brien'") == [.string("O'Brien")])
  }

  @Test func `lexes an empty string literal`() throws {
    #expect(try lex("''") == [.string("")])
  }

  @Test func `lexes a delimited identifier verbatim`() throws {
    // A double-quoted name is a `quoted` token, case-preserved and never a
    // keyword — distinct from a bare identifier so a dot in it is kept.
    #expect(try lex("\"Offset\"") == [.quoted("Offset")])
    #expect(try lex("\"select\"") == [.quoted("select")])
    #expect(try lex("\"a.b\"") == [.quoted("a.b")])
  }

  @Test func `unescapes a doubled quote in a delimited identifier`() throws {
    #expect(try lex("\"a\"\"b\"") == [.quoted("a\"b")])
  }

  @Test func `lexes tokens with no separating whitespace`() throws {
    // No whitespace required between an identifier and an operator.
    #expect(try lex("a<=1")
                == [.identifier("a"), .leq, .integer(1)])
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

  @Test func `rejects an unexpected character`() {
    #expect(throws: SQLError.self) { _ = try lex("SELECT @ FROM T") }
  }

  @Test func `rejects an unterminated string`() {
    #expect(throws: SQLError.self) { _ = try lex("'oops") }
  }

  @Test func `rejects an unterminated delimited identifier`() {
    #expect(throws: SQLError.self) { _ = try lex("\"oops") }
  }

  @Test func `skips a line comment between tokens`() throws {
    #expect(try lex("SELECT -- pick a star\n*")
                == [.select, .star])
  }

  @Test func `skips a line comment at end of input`() throws {
    // An unterminated `--` comment at EOF is not a fault.
    #expect(try lex("SELECT * -- trailing") == [.select, .star])
  }

  @Test func `skips a block comment spanning a newline`() throws {
    #expect(try lex("SELECT /* a\n block */ *") == [.select, .star])
  }

  @Test func `skips a block comment between tokens on one line`() throws {
    #expect(try lex("SELECT /* star */ *") == [.select, .star])
  }

  @Test func `lexes a lone minus and slash as operators`() throws {
    // A single `-` or `/` is still an operator; only `--` and `/*` begin a
    // comment.
    #expect(try lex("a - 1 / 2")
                == [.identifier("a"), .minus, .integer(1), .slash,
                    .integer(2)])
  }

  @Test func `rejects an unterminated block comment`() {
    #expect(throws: SQLError.self) { _ = try lex("SELECT /* oops") }
  }

  @Test func `tracks line and column across a block comment`() throws {
    // Newlines inside a block comment still advance the line counter.
    let locations = try tokens("SELECT /* a\nb */ *").map(\.location)
    #expect(locations.map(\.line) == [1, 2])
    #expect(locations.map(\.column) == [1, 6])
  }

  @Test func `scans a bound-parameter placeholder`() throws {
    #expect(try lex("WHERE a = :pid")
                == [.where, .identifier("a"), .equal, .parameter("pid")])
  }

  @Test func `rejects a colon not followed by an identifier`() {
    #expect(throws: SQLError.self) { _ = try lex("SELECT : FROM T") }
  }
}
