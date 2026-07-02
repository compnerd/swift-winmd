// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - Byte classes

// Each class is a 128-bit set of the ASCII bytes it admits, so membership is a
// single shift-and-test. A non-ASCII byte (>= 128) shifts past the width and
// reads as 0 — not a member — so no range check is needed.

/// Whether `byte` is ASCII whitespace: tab, newline, carriage return, space.
private func whitespace(_ byte: UInt8) -> Bool {
  let mask: UInt128 = 0x0000_0000_0000_0000_0000_0001_0000_2600
  return mask & (1 << UInt128(byte)) != 0
}

/// Whether `byte` is an ASCII decimal digit, `0`–`9`.
private func digit(_ byte: UInt8) -> Bool {
  let mask: UInt128 = 0x0000_0000_0000_0000_03ff_0000_0000_0000
  return mask & (1 << UInt128(byte)) != 0
}

/// Whether `byte` may begin an identifier: an ASCII letter or `_`.
private func initial(_ byte: UInt8) -> Bool {
  let mask: UInt128 = 0x07ff_fffe_87ff_fffe_0000_0000_0000_0000
  return mask & (1 << UInt128(byte)) != 0
}

/// Whether `byte` may continue an identifier: a letter, digit, `_`, or `.`.
private func continuation(_ byte: UInt8) -> Bool {
  let mask: UInt128 = 0x07ff_fffe_87ff_fffe_03ff_4000_0000_0000
  return mask & (1 << UInt128(byte)) != 0
}

// MARK: - String

extension String {
  /// Decodes `range` of `bytes` as UTF-8 into a `String`.
  ///
  /// The lexer's payloads are ASCII spans of the borrowed input; this copies
  /// the bytes out into an owned `String` that may outlive the borrow.
  fileprivate init(_ bytes: borrowing Span<UInt8>, _ range: Range<Int>) {
    self = bytes.extracting(range).withUnsafeBytes {
      String(decoding: $0, as: UTF8.self)
    }
  }
}

/// Scans SQL text into a stream of `Token`s, one at a time.
///
/// The lexer is single-pass over the source bytes. SQL is ASCII, so the lexer
/// scans the input's UTF-8 bytes by value and compares them against ASCII byte
/// constants. Whitespace separates tokens and is otherwise discarded; keywords
/// are recognised case-insensitively; string literals are single-quoted with
/// `''` as an escaped quote.
///
/// The lexer tracks a `SourceLocation` as it scans — advancing the column per
/// byte and starting a fresh line on each newline — so every token and fault
/// knows where it is.
///
/// The bytes are borrowed for the lexer's lifetime: the `Span<UInt8>` keeps the
/// lexer tied to the storage it scans (`Statement(parsing:)` drives the lexer
/// over the input string's UTF-8 span). No token escapes the borrow — the
/// identifier and literal payloads are copied out into `String`s.
internal struct Lexer: ~Escapable {
  private let bytes: Span<UInt8>
  private var position: Int
  private var line: Int
  private var column: Int

  @_lifetime(copy bytes)
  internal init(_ bytes: Span<UInt8>) {
    self.bytes = bytes
    self.position = 0
    self.line = 1
    self.column = 1
  }

  // MARK: - Stream

  /// Scans and returns the next token, or `nil` once the input is exhausted.
  internal mutating func next() throws(SQLError) -> Token? {
    trivia()

    guard let byte = peek() else { return nil }

    switch byte {
    case UInt8(ascii: "*"):
      return punctuation(.star)
    case UInt8(ascii: "+"):
      return punctuation(.plus)
    case UInt8(ascii: "-"):
      return punctuation(.minus)
    case UInt8(ascii: "/"):
      return punctuation(.slash)
    case UInt8(ascii: ","):
      return punctuation(.comma)
    case UInt8(ascii: "("):
      return punctuation(.lparen)
    case UInt8(ascii: ")"):
      return punctuation(.rparen)
    case UInt8(ascii: "="):
      return punctuation(.equal)

    case UInt8(ascii: "<"):
      let start = location
      advance()
      switch peek() {
      case UInt8(ascii: ">"):
        advance()
        return Token(kind: .unequal, location: start)
      case UInt8(ascii: "="):
        advance()
        return Token(kind: .leq, location: start)
      default:
        return Token(kind: .lt, location: start)
      }

    case UInt8(ascii: ">"):
      let start = location
      advance()
      switch peek() {
      case UInt8(ascii: "="):
        advance()
        return Token(kind: .geq, location: start)
      default:
        return Token(kind: .gt, location: start)
      }

    case UInt8(ascii: "'"):
      return try string()

    case UInt8(ascii: ":"):
      return try parameter()

    case let b where digit(b):
      return try integer()

    case let b where initial(b):
      return identifier()

    default:
      throw .character(Character(UnicodeScalar(byte)), at: location)
    }
  }

  // MARK: - Scanners

  /// Consumes a single-byte punctuation or operator token of `kind`.
  private mutating func punctuation(_ kind: Token.Kind) -> Token {
    let token = Token(kind: kind, location: location)
    advance()
    return token
  }

  /// Scans a single-quoted string literal at the current position.
  ///
  /// A doubled quote `''` is an escaped quote; the closing quote ends the
  /// literal. Faults if the literal is never closed.
  private mutating func string() throws(SQLError) -> Token {
    let start = location
    advance()
    let begin = position

    // The common literal is a contiguous run of bytes; only a doubled quote
    // forces the text to be assembled from segments, so defer that until one
    // appears and otherwise materialise the whole range at the close.
    var value: String? = nil
    var segment = position
    while let byte = peek() {
      switch byte {
      case UInt8(ascii: "'") where peek(1) == UInt8(ascii: "'"):
        value = (value ?? "") + String(bytes, segment ..< position) + "'"
        advance()
        advance()
        segment = position
      case UInt8(ascii: "'"):
        let text = if let value {
          value + String(bytes, segment ..< position)
        } else {
          String(bytes, begin ..< position)
        }
        advance()
        return Token(kind: .string(text), location: start)
      default:
        advance()
      }
    }

    throw .unterminated(at: start)
  }

  /// Scans a bound-parameter placeholder `:name` at the current position.
  ///
  /// The leading `:` is consumed; an identifier must follow (a letter or `_`
  /// then identifier continuations), else the `:` begins no valid token.
  private mutating func parameter() throws(SQLError) -> Token {
    let start = location
    advance()
    guard let byte = peek(), initial(byte) else {
      throw .character(":", at: start)
    }
    let begin = position
    while let byte = peek(), continuation(byte) {
      advance()
    }
    return Token(kind: .parameter(String(bytes, begin ..< position)),
                 location: start)
  }

  /// Scans an integer literal at the current position.
  private mutating func integer() throws(SQLError) -> Token {
    let start = location
    while let byte = peek(), digit(byte) {
      advance()
    }

    let text = String(bytes, start.offset ..< position)
    guard let value = Int(text) else {
      throw .overflow(text, at: start)
    }
    return Token(kind: .integer(value), location: start)
  }

  /// Scans an identifier or keyword at the current position.
  ///
  /// Identifier bytes are letters, digits, `_`, and `.`. The scanned text is
  /// matched case-insensitively against the keyword spellings; anything else is
  /// an identifier.
  private mutating func identifier() -> Token {
    let start = location
    while let byte = peek(), continuation(byte) {
      advance()
    }

    let text = String(bytes, start.offset ..< position)
    let kind: Token.Kind = switch text.uppercased() {
    case "CREATE": .create
    case "VIEW": .view
    case "SELECT": .select
    case "FROM": .from
    case "WHERE": .where
    case "ORDER": .order
    case "BY": .by
    case "ASC": .asc
    case "DESC": .desc
    case "AND": .and
    case "OR": .or
    case "NOT": .not
    case "JOIN": .join
    case "ON": .on
    case "AS": .as
    case "IS": .is
    case "NULL": .null
    case "UNION": .union
    case "ALL": .all
    case "WITH": .with
    case "RECURSIVE": .recursive
    default: .identifier(text)
    }
    return Token(kind: kind, location: start)
  }

  // MARK: - Cursor

  /// The `SourceLocation` of the cursor.
  private var location: SourceLocation {
    SourceLocation(line: line, column: column, offset: position)
  }

  /// Consumes the byte under the cursor, tracking line and column.
  private mutating func advance() {
    switch peek() {
    case UInt8(ascii: "\n"):
      line += 1
      column = 1
    case .some:
      column += 1
    case nil:
      break
    }
    position += 1
  }

  /// Advances past any run of insignificant bytes (whitespace, and in time
  /// comments) separating tokens.
  private mutating func trivia() {
    while let byte = peek(), whitespace(byte) {
      advance()
    }
  }

  /// The byte `offset` positions ahead of the cursor, or `nil` past the end.
  private func peek(_ offset: Int = 0) -> UInt8? {
    let index = position + offset
    return index < bytes.count ? bytes[index] : nil
  }
}
