// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A position in the query text.
///
/// `line` and `column` are 1-based, counting from the start of the input; the
/// lexer advances the column per byte and starts a fresh line on each newline.
/// `offset` is the zero-based byte index of the same position, retained for
/// consumers that index the raw buffer.
public struct SourceLocation: Hashable, Sendable {
  /// The 1-based line number.
  public let line: Int

  /// The 1-based column number.
  public let column: Int

  /// The zero-based byte offset into the query text.
  public let offset: Int

  public init(line: Int, column: Int, offset: Int) {
    self.line = line
    self.column = column
    self.offset = offset
  }
}

extension SourceLocation: CustomStringConvertible {
  public var description: String {
    "\(line):\(column)"
  }
}

/// A lexer or parser diagnostic.
///
/// Most cases carry the `SourceLocation` at which the fault was detected, so a
/// consumer can point at the offending span.
public enum SQLError: Error, Hashable, Sendable {
  /// An error carrying an explicit ISO SQLSTATE and message, for a fault whose
  /// code the raiser knows but which no semantic case models. The first string
  /// is the 5-character class+subclass code (e.g. `"42601"`); the second is the
  /// human-readable message. This is the passthrough that lets a caller surface
  /// any SQLSTATE without extending the enum.
  case state(String, String)
  /// A character that begins no valid token.
  case character(Character, at: SourceLocation)
  /// A string literal whose closing quote is missing.
  case unterminated(at: SourceLocation)
  /// An integer literal that does not fit the platform `Int`.
  case overflow(String, at: SourceLocation)
  /// A token of a kind other than the one the grammar requires here.
  case unexpected(String, expected: String, at: SourceLocation)
  /// The end of the input was reached while a token was still required.
  case incomplete(expected: String)
  /// Tokens remain after a complete statement was parsed.
  case trailing(at: SourceLocation)
  /// A statement names a relation the catalog does not resolve.
  case relation(String)
  /// A statement names a column the relation does not resolve.
  case column(String)
  /// A statement names an unqualified column both joined relations resolve.
  case ambiguous(String)
  /// A statement calls a scalar function the routines do not resolve.
  case function(String)
  /// A scalar function rejects its arguments (the wrong count, or a value it
  /// cannot map); the string describes the fault.
  case argument(String)
  /// A binary arithmetic expression applies to a non-integer (text) operand —
  /// the operands must be integers, not a silent coercion; the string describes
  /// the fault. A NULL operand is not a fault: it propagates to a NULL result.
  case operand(String)
  /// A binary arithmetic expression divides by zero — standard SQL raises rather
  /// than yielding a value.
  case divide
  /// A binary arithmetic expression's integer result exceeds the platform `Int`
  /// — reported rather than trapped; the string describes the fault.
  case magnitude(String)
  /// A `CREATE VIEW` projects a column whose name cannot be inferred — a
  /// `SELECT *`, or an unaliased non-column expression — and no explicit column
  /// list names it; the string describes the offending projection.
  case named(String)
  /// A `CREATE VIEW`'s explicit column list does not match the view query's
  /// output width — the list must name exactly one column per projected value —
  /// carrying the `expected` query arity and the `got` list count. Caught at
  /// parse when the projection's arity is known, and as an engine backstop when
  /// a view (a `SELECT *` whose width is known only at resolution) is compiled.
  case columns(expected: Int, got: Int)
  /// A `CREATE VIEW` names two columns that collide — supplied explicitly or
  /// inferred from the projection — under the case-insensitive resolution
  /// `Schema.ordinal(of:)` performs, so the shadowed column would be
  /// unreachable; the string is the offending name.
  case duplicate(String)
  /// A `UNION` combines two `SELECT`s of differing column counts — the result
  /// columns of every arm must align — carrying the first arm's width and the
  /// offending arm's.
  case arity(Int, Int)
}

extension SQLError: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .state(_, message):
      message
    case let .character(character, location):
      "unexpected character '\(character)' at \(location)"
    case let .unterminated(location):
      "unterminated string literal at \(location)"
    case let .overflow(text, location):
      "integer literal '\(text)' out of range at \(location)"
    case let .unexpected(found, expected, location):
      "expected \(expected) but found '\(found)' at \(location)"
    case let .incomplete(expected):
      "expected \(expected) but reached end of input"
    case let .trailing(location):
      "unexpected trailing input at \(location)"
    case let .relation(name):
      "no such relation '\(name)'"
    case let .column(name):
      "no such column '\(name)'"
    case let .ambiguous(name):
      "ambiguous column '\(name)'"
    case let .function(name):
      "no such function '\(name)'"
    case let .argument(detail):
      "invalid function argument: \(detail)"
    case let .operand(detail):
      "invalid arithmetic: \(detail)"
    case .divide:
      "invalid arithmetic: division by zero"
    case let .magnitude(detail):
      "invalid arithmetic: \(detail)"
    case let .named(detail):
      "view column cannot be named: \(detail)"
    case let .columns(expected, got):
      "view column list count does not match the query: "
          + "expected \(expected), got \(got)"
    case let .duplicate(name):
      "duplicate view column '\(name)'"
    case let .arity(expected, found):
      "UNION arms project differing column counts: "
          + "expected \(expected), found \(found)"
    }
  }
}

// MARK: - SQLSTATE

extension SQLError {
  /// The ISO SQLSTATE for this error: a 5-character string whose first two
  /// characters are the class and whose last three are the subclass. Every case
  /// maps to a code, so any `SQLError` exposes one.
  ///
  /// The codes draw on ISO/IEC 9075-2 Annex B (SQLSTATE class values) and, where
  /// ISO leaves the subclass implementation-defined, the de-facto PostgreSQL
  /// assignments:
  ///
  /// - Class `42` — syntax error or access rule violation — covers the
  ///   lexer/parser faults (`42601` syntax error), the undefined-object faults
  ///   (`42P01` table, `42703` column, `42883` function), and the name-collision
  ///   faults (`42702` ambiguous, `42701` duplicate). `42P01` is a PostgreSQL
  ///   subclass; ISO itself leaves the `42` subclass implementation-defined, so
  ///   this is a deliberate choice noted alongside `42703`/`42883`, which are
  ///   likewise PostgreSQL subclasses on the same class.
  /// - Class `22` — data exception — covers the value faults: `22003` numeric
  ///   value out of range (the out-of-range integer literal and the arithmetic
  ///   overflow), `22012` division by zero, and `22023` invalid parameter value
  ///   (a scalar function's rejected argument).
  /// - `42804` (datatype mismatch) is the non-integer arithmetic operand — a
  ///   type error at evaluation rather than a value-range fault.
  public var sqlstate: String {
    switch self {
    case let .state(code, _):
      code
    // Class 42 — syntax error or access rule violation.
    case .character, .unterminated, .unexpected, .incomplete, .trailing,
         .named, .columns, .arity:
      "42601"
    case .relation:
      "42P01"
    case .column:
      "42703"
    case .ambiguous:
      "42702"
    case .duplicate:
      "42701"
    case .function:
      "42883"
    // Class 22 — data exception.
    case .overflow:
      "22003"
    case .argument:
      "22023"
    case .operand:
      "42804"
    case .divide:
      "22012"
    case .magnitude:
      "22003"
    }
  }

  /// The human-readable message for this error — the same text as
  /// `description`. Paired with `sqlstate`, it gives every error a uniform
  /// `(sqlstate, message)` surface.
  public var message: String {
    description
  }
}
