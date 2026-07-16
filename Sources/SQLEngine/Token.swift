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
    /// The `FILTER` keyword introducing an aggregate's `FILTER (WHERE …)`
    /// per-row gate.
    case filter
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
    /// The `LATERAL` keyword introducing a FROM/JOIN derived table whose body
    /// may reference the preceding FROM items (a correlated apply).
    case lateral
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
    case between
    /// The `EXISTS` keyword introducing an `[NOT] EXISTS (subquery)` predicate.
    case exists
    /// The `ANY` keyword introducing a quantified comparison `x op ANY (Q)`.
    case any
    /// The `SOME` keyword — a synonym for `ANY` in a quantified comparison.
    case some
    case like
    case escape
    /// The `PLACING` keyword separating an `OVERLAY`'s source string from its
    /// replacement.
    case placing
    /// The `FOR` keyword introducing an `OVERLAY`'s optional replacement span.
    case `for`
    case union
    case intersect
    case except
    case all
    case with
    case recursive
    case `true`
    case `false`
    case unknown
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
    /// The `||` string-concatenation operator.
    case concat
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
    case .filter: "FILTER"
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
    case .lateral: "LATERAL"
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
    case .between: "BETWEEN"
    case .exists: "EXISTS"
    case .any: "ANY"
    case .some: "SOME"
    case .like: "LIKE"
    case .escape: "ESCAPE"
    case .placing: "PLACING"
    case .for: "FOR"
    case .union: "UNION"
    case .intersect: "INTERSECT"
    case .except: "EXCEPT"
    case .all: "ALL"
    case .with: "WITH"
    case .recursive: "RECURSIVE"
    case .true: "TRUE"
    case .false: "FALSE"
    case .unknown: "UNKNOWN"
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
    case let .blob(bytes): "x'" + bytes.reduce(into: "") { $0 += hex($1) } + "'"
    case let .parameter(name): ":\(name)"
    case .star: "*"
    case .plus: "+"
    case .minus: "-"
    case .slash: "/"
    case .concat: "||"
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


private let kHexDigits: InlineArray<_, Character> = [
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"
]

/// `byte` as two lowercase-hex nibbles, high nibble first — a byte's fixed
/// two-digit spelling, keeping its leading zero.
private func hex(_ byte: UInt8) -> String {
  return String([kHexDigits[Int(byte >> 4)], kHexDigits[Int(byte & 0x0f)]])
}
