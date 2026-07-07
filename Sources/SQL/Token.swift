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
    case function
    case returns
    case select
    case distinct
    case from
    case `where`
    case order
    case group
    case having
    case by
    case asc
    case desc
    case offset
    case fetch
    case first
    case rows
    case only
    case and
    case or
    case not
    case join
    case inner
    case left
    case right
    case full
    case outer
    case on
    case `as`
    case `is`
    case null
    case `in`
    case union
    case all
    case with
    case recursive
    case `true`
    case `false`
    case `case`
    case when
    case then
    case `else`
    case end

    // Operands.
    case identifier(String)
    /// A delimited (double-quoted) identifier — a name taken verbatim, so unlike
    /// a bare `identifier` a dot in it is part of the name, not a qualifier.
    case quoted(String)
    case string(String)
    /// A bare integer literal — a run of digits with no fraction or exponent.
    case integer(Int)
    /// An approximate-numeric literal — a decimal with a `.` fraction and/or an
    /// exponent (`3.14`, `1.0`, `1e3`, `2.5e-1`), scanned into a `Double`.
    case decimal(Double)
    /// A binary-string literal — an `x'…'` run of hex byte pairs, its bytes
    /// scanned out. `x''` is the empty blob.
    case blob(Array<UInt8>)
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
    case .function: "FUNCTION"
    case .returns: "RETURNS"
    case .select: "SELECT"
    case .distinct: "DISTINCT"
    case .from: "FROM"
    case .where: "WHERE"
    case .order: "ORDER"
    case .group: "GROUP"
    case .having: "HAVING"
    case .by: "BY"
    case .asc: "ASC"
    case .desc: "DESC"
    case .offset: "OFFSET"
    case .fetch: "FETCH"
    case .first: "FIRST"
    case .rows: "ROWS"
    case .only: "ONLY"
    case .and: "AND"
    case .or: "OR"
    case .not: "NOT"
    case .join: "JOIN"
    case .inner: "INNER"
    case .left: "LEFT"
    case .right: "RIGHT"
    case .full: "FULL"
    case .outer: "OUTER"
    case .on: "ON"
    case .as: "AS"
    case .is: "IS"
    case .null: "NULL"
    case .in: "IN"
    case .union: "UNION"
    case .all: "ALL"
    case .with: "WITH"
    case .recursive: "RECURSIVE"
    case .true: "TRUE"
    case .false: "FALSE"
    case .case: "CASE"
    case .when: "WHEN"
    case .then: "THEN"
    case .else: "ELSE"
    case .end: "END"
    case let .identifier(name): name
    case let .quoted(name): "\"\(name)\""
    case let .string(value): "'\(value)'"
    case let .integer(value): "\(value)"
    case let .decimal(value): "\(value)"
    case let .blob(bytes):
      "x'" + bytes.reduce(into: "") { $0 += Self.hex($1) } + "'"
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

  /// `byte` as two lowercase-hex nibbles, high nibble first — a byte's fixed
  /// two-digit spelling, keeping its leading zero.
  private static func hex(_ byte: UInt8) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
  }
}
