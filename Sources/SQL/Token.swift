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
    case create
    case view
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
    case `is`
    case null
    case union
    case all

    // Operands.
    case identifier(String)
    case string(String)
    case integer(Int)
    /// A bound parameter placeholder `:name`, holding the parameter's name.
    case parameter(String)

    // Punctuation and operators.
    case star
    case plus
    case minus
    case slash
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
    case .create: "CREATE"
    case .view: "VIEW"
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
    case .is: "IS"
    case .null: "NULL"
    case .union: "UNION"
    case .all: "ALL"
    case let .identifier(name): name
    case let .string(value): "'\(value)'"
    case let .integer(value): "\(value)"
    case let .parameter(name): ":\(name)"
    case .star: "*"
    case .plus: "+"
    case .minus: "-"
    case .slash: "/"
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
