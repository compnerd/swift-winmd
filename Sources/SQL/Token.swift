// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// A lexical token, tagged with its source position.
///
/// `location` is the `SourceLocation` at which the token's text begins in the
/// query, so diagnostics can point at the span.
internal struct Token: Hashable, Sendable {
  internal let kind: Kind
  internal let location: SourceLocation
}

extension Token {
  /// The classification of a token.
  ///
  /// Keywords are recognised case-insensitively during lexing and normalised
  /// to a dedicated case; an identifier therefore never holds a keyword.
  internal enum Kind: Hashable, Sendable {
    // Keywords.
    case select
    case from
    case `where`
    case order
    case by
    case asc
    case desc
    case and
    case or
    case not
    case join
    case on
    case `as`

    // Operands.
    case identifier(String)
    case string(String)
    case integer(Int)

    // Punctuation and operators.
    case star
    case comma
    case lparen
    case rparen
    case equal
    case unequal
    case lt
    case gt
    case leq
    case geq
  }
}

extension Token.Kind {
  /// A human-readable spelling of the token, for diagnostics.
  internal var description: String {
    switch self {
    case .select: "SELECT"
    case .from: "FROM"
    case .where: "WHERE"
    case .order: "ORDER"
    case .by: "BY"
    case .asc: "ASC"
    case .desc: "DESC"
    case .and: "AND"
    case .or: "OR"
    case .not: "NOT"
    case .join: "JOIN"
    case .on: "ON"
    case .as: "AS"
    case let .identifier(name): name
    case let .string(value): "'\(value)'"
    case let .integer(value): "\(value)"
    case .star: "*"
    case .comma: ","
    case .lparen: "("
    case .rparen: ")"
    case .equal: "="
    case .unequal: "<>"
    case .lt: "<"
    case .gt: ">"
    case .leq: "<="
    case .geq: ">="
    }
  }
}
