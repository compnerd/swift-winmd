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
}

extension SQLError: CustomStringConvertible {
  public var description: String {
    switch self {
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
    }
  }
}
