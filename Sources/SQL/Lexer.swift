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
/// constants. Whitespace and comments separate tokens and are otherwise
/// discarded; keywords are recognised case-insensitively; string literals are
/// single-quoted with `''` as an escaped quote; a double-quoted delimited
/// identifier (`""` an escaped quote) spells a name — a reserved word or
/// otherwise — as an identifier verbatim.
///
/// Two comment forms are skipped as trivia (ISO 9075 §5.2 `<comment>`): a `--`
/// simple comment runs to the end of the line, and a `/* … */` bracketed
/// comment spans to its closing `*/`. A `--` shares its lead byte with the `-`
/// subtraction operator and `/*` with the `/` division operator, so each opens
/// a comment only when its second byte confirms it.
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
    try trivia()

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

    case UInt8(ascii: "\""):
      return try delimited()

    case UInt8(ascii: ":"):
      return try parameter()

    // An `x'…'`/`X'…'` binary-string literal. The `x` prefix is also an
    // identifier lead byte, so scan a blob only when a quote follows;
    // otherwise fall through to `identifier()` as an ordinary name.
    case UInt8(ascii: "x"), UInt8(ascii: "X"):
      return if peek(1) == UInt8(ascii: "'") { try blob() }
          else { identifier() }

    case let b where digit(b):
      return try number()

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

    throw .unterminated("string literal", at: start)
  }

  /// Scans a double-quoted delimited identifier at the current position.
  ///
  /// A delimited identifier spells a name a bare identifier cannot: a reserved
  /// word used as a column (`"Offset"`, which `ManifestResource` and
  /// `FieldLayout` declare), or a spelling outside the identifier bytes. Its
  /// text is taken verbatim and case-sensitively — never matched against the
  /// keywords — so it is a `quoted` token, distinct from a bare `identifier` so
  /// the parser keeps a dot in it as part of the name rather than a qualifier; a
  /// doubled quote `""` is an escaped quote, mirroring a string literal's `''`.
  /// Faults if unclosed.
  private mutating func delimited() throws(SQLError) -> Token {
    let start = location
    advance()
    let begin = position

    // As with a string literal, defer assembling the text from segments until a
    // doubled quote appears, and otherwise materialise the whole run at close.
    var value: String? = nil
    var segment = position
    while let byte = peek() {
      switch byte {
      case UInt8(ascii: "\"") where peek(1) == UInt8(ascii: "\""):
        value = (value ?? "") + String(bytes, segment ..< position) + "\""
        advance()
        advance()
        segment = position
      case UInt8(ascii: "\""):
        let text = if let value {
          value + String(bytes, segment ..< position)
        } else {
          String(bytes, begin ..< position)
        }
        advance()
        return Token(kind: .quoted(text), location: start)
      default:
        advance()
      }
    }

    throw .unterminated("delimited identifier", at: start)
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

  /// Scans a binary-string literal `x'…'`/`X'…'` at the current position.
  ///
  /// The `x` prefix and its opening quote are consumed; the body is a run of
  /// hex digit pairs — each pair one byte, high nibble first — closed by a
  /// quote. The count of digits must be even (a whole number of bytes); an
  /// empty body `x''` is the empty blob. A non-hex digit faults where it sits,
  /// an odd digit count faults at the close, and an unclosed body is
  /// unterminated.
  private mutating func blob() throws(SQLError) -> Token {
    let start = location
    advance()
    advance()

    var bytes = Array<UInt8>()
    var high: UInt8? = nil
    while let byte = peek() {
      if byte == UInt8(ascii: "'") {
        guard high == nil else {
          throw .character("'", at: location)
        }
        advance()
        return Token(kind: .blob(bytes), location: start)
      }
      guard let nibble = nibble(byte) else {
        throw .character(Character(UnicodeScalar(byte)), at: location)
      }
      if let leading = high {
        bytes.append(leading << 4 | nibble)
        high = nil
      } else {
        high = nibble
      }
      advance()
    }

    throw .unterminated("binary literal", at: start)
  }

  /// The value of the ASCII hex digit `byte` (`0`–`9`, `a`–`f`, `A`–`F`), or
  /// `nil` when it is not a hex digit.
  private func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0") ... UInt8(ascii: "9"):
      byte - UInt8(ascii: "0")
    case UInt8(ascii: "a") ... UInt8(ascii: "f"):
      byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A") ... UInt8(ascii: "F"):
      byte - UInt8(ascii: "A") + 10
    default:
      nil
    }
  }

  /// Scans a numeric literal at the current position — an integer or a decimal.
  ///
  /// A bare run of digits is an `integer`. A `.` fraction and/or an `e`/`E`
  /// exponent makes it a `decimal` (an approximate-numeric `Double`): `3.14`,
  /// `1.0`, `1e3`, `2.5e-1`. The `.` and exponent are each consumed only when a
  /// digit follows — a `.` with no fraction digit (`1.`) leaves the `.` for the
  /// caller and scans the leading integer, and an `e` with no exponent digit is
  /// not an exponent — so a qualified reference is never misread as a float (an
  /// identifier's leading `.` never reaches here: it begins with a letter, not
  /// a digit). An integer past the `Int` boundary faults; a decimal does not
  /// (an out-of-range magnitude is IEEE `inf`).
  private mutating func number() throws(SQLError) -> Token {
    let start = location
    while let byte = peek(), digit(byte) {
      advance()
    }

    var decimal = false
    // A `.` is a fraction only when a digit follows; otherwise it is not part
    // of the number (a lone `1.` scans as the integer `1`).
    if peek() == UInt8(ascii: "."), let next = peek(1), digit(next) {
      decimal = true
      advance()
      while let byte = peek(), digit(byte) {
        advance()
      }
    }

    // An `e`/`E` exponent takes an optional sign then at least one digit; short
    // of that it is not an exponent and the number ends before the `e`.
    if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
      let sign = peek(1) == UInt8(ascii: "+") || peek(1) == UInt8(ascii: "-")
      if let next = peek(sign ? 2 : 1), digit(next) {
        decimal = true
        advance()
        if sign { advance() }
        while let byte = peek(), digit(byte) {
          advance()
        }
      }
    }

    let text = String(bytes, start.offset ..< position)
    if decimal {
      // `Double` never returns nil for lexer-shaped digits, but it yields `inf`
      // for a magnitude past its range (`1e9999`); reject that as an overflow —
      // like an out-of-range integer literal — so no `inf` (and thus no `inf -
      // inf` NaN) enters the engine.
      guard let value = Double(text), value.isFinite else {
        throw .overflow(text, at: start)
      }
      return Token(kind: .decimal(value), location: start)
    }
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
    case "FUNCTION": .function
    case "RETURNS": .returns
    case "SELECT": .select
    case "DISTINCT": .distinct
    case "FROM": .from
    case "WHERE": .where
    case "ORDER": .order
    case "GROUP": .group
    case "HAVING": .having
    case "BY": .by
    case "ASC": .asc
    case "DESC": .desc
    case "OFFSET": .offset
    case "FETCH": .fetch
    case "FIRST", "NEXT": .first
    case "ROW", "ROWS": .rows
    case "ONLY": .only
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
    case "TRUE": .true
    case "FALSE": .false
    case "CASE": .case
    case "WHEN": .when
    case "THEN": .then
    case "ELSE": .else
    case "END": .end
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

  /// Advances past any run of insignificant bytes — whitespace and comments —
  /// separating tokens.
  ///
  /// Whitespace and the two comment forms may interleave freely, so this loops
  /// until the cursor rests on a byte that begins a token (or the input ends).
  private mutating func trivia() throws(SQLError) {
    while let byte = peek() {
      switch byte {
      case let b where whitespace(b):
        advance()
      case UInt8(ascii: "-") where peek(1) == UInt8(ascii: "-"):
        simple()
      case UInt8(ascii: "/") where peek(1) == UInt8(ascii: "*"):
        try block()
      default:
        return
      }
    }
  }

  /// Skips a `--` simple comment: from the `--` to the next newline, or to the
  /// end of input if none follows.
  ///
  /// The terminating newline is left for `trivia()` to consume as ordinary
  /// whitespace, so its line/column bookkeeping stays with `advance()`. An
  /// unterminated `--` comment at end of input is not a fault.
  private mutating func simple() {
    advance()
    advance()
    while let byte = peek(), byte != UInt8(ascii: "\n") {
      advance()
    }
  }

  /// Skips a `/* … */` bracketed comment: from the `/*` to the matching `*/`.
  ///
  /// Bracketed comments do not nest — ISO 9075 does not require nesting, and
  /// the common interpretation stops at the first `*/`. Newlines within the
  /// comment advance the line counter through `advance()`. A comment left open
  /// at end of input is unterminated and faults.
  private mutating func block() throws(SQLError) {
    let start = location
    advance()
    advance()
    while let byte = peek() {
      if byte == UInt8(ascii: "*"), peek(1) == UInt8(ascii: "/") {
        advance()
        advance()
        return
      }
      advance()
    }

    throw .unterminated("block comment", at: start)
  }

  /// The byte `offset` positions ahead of the cursor, or `nil` past the end.
  private func peek(_ offset: Int = 0) -> UInt8? {
    let index = position + offset
    return index < bytes.count ? bytes[index] : nil
  }
}
