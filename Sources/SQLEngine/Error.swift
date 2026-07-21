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
  /// A delimited construct whose closing delimiter is missing — the `String`
  /// names what was left open (a string literal, a block comment, …).
  case unterminated(String, at: SourceLocation)
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
  /// A binary arithmetic expression applies to a non-numeric (text, boolean, or
  /// blob) operand — the operands must be numeric (integer or double), not a
  /// silent coercion; the string describes the fault. A NULL operand is not a
  /// fault: it propagates to a NULL result.
  case operand(String)
  /// A binary arithmetic expression divides by zero — standard SQL raises
  /// rather than yielding a value.
  case divide
  /// A binary arithmetic expression's integer result exceeds the platform `Int`
  /// — reported rather than trapped; the string describes the fault.
  case magnitude(String)
  /// A `CREATE VIEW` projects a column whose name cannot be inferred — a
  /// `SELECT *`, or an unaliased non-column expression — and no explicit column
  /// list names it; the string describes the offending projection.
  case named(String)
  /// An explicit column list — a `CREATE VIEW`'s, a `WITH` CTE's, or a derived
  /// table's `AS t(c, …)` — does not match the query expression's DEGREE, the
  /// number of columns its body projects; the list must name exactly one column
  /// per projected value. ISO 9075 makes the degree the reference, so
  /// `expected` carries the body/query-expression degree and `got` the declared
  /// list count, uniformly across every kind. Caught at parse when the
  /// projection's arity is statically known, and as an engine backstop when the
  /// width is known only at resolution (a `SELECT *` body).
  case columns(expected: Int, got: Int)
  /// A `CREATE VIEW` names two columns that collide — supplied explicitly or
  /// inferred from the projection — under the case-insensitive resolution
  /// `Schema.ordinal(of:)` performs, so the shadowed column would be
  /// unreachable; the string is the offending name.
  case duplicate(String)
  /// A `WITH` list binds the same query name twice (case-insensitively), so the
  /// later definition would silently shadow the earlier; the string is the
  /// repeated name.
  case redefinition(String)
  /// A `UNION` combines two `SELECT`s of differing column counts — the result
  /// columns of every arm must align — carrying the first arm's width and the
  /// offending arm's.
  case arity(Int, Int)
  /// A query uses a construct the engine does not support in the shape given —
  /// a `SELECT *` with no `FROM`, or a `WHERE`/`ORDER BY`/`JOIN` on a FROM-less
  /// select (which projects only expressions over a single row); the string
  /// describes it.
  case unsupported(String)
  /// A statement cannot be run as a query — a `CREATE VIEW` defines a view
  /// rather than producing rows, or a malformed `WITH` member; the string
  /// describes the fault.
  case statement(String)
  /// A definition refers to itself without end: a recursive common table
  /// expression that did not reach a fixpoint within the iteration cap
  /// (`kRecursionCap`) — it produces rows without end — or a cyclic registered
  /// view whose body resolves back to itself (`A` over `B` over `A`), which
  /// would otherwise recurse resolve→compile→resolve until the stack overflows.
  /// The string is the offending CTE's or view's name.
  case recursion(String)
  /// An aggregate query names a column in its projection, `HAVING`, or `ORDER
  /// BY` that is neither aggregated nor a `GROUP BY` key — the standard rule
  /// requires every non-aggregated column to appear in the `GROUP BY`. The
  /// string is the offending column's name.
  case grouping(String)
  /// A `SELECT DISTINCT` orders on a column absent from its select list — the
  /// dedup runs on the projected rows, so ordering on a dropped column is
  /// ill-defined; the standard requires every `ORDER BY` key under `DISTINCT`
  /// to be an output column. The string is the offending column's name.
  case distinct(String)
  /// A scalar subquery `(SELECT …)` used where at most one row is admitted
  /// yielded MORE THAN ONE row — the ISO `<scalar subquery>` requires a
  /// cardinality of at most one, an empty result standing for NULL and a single
  /// row for its lone cell. A wider result cannot collapse to one value, so a
  /// run raises rather than picking one arbitrarily.
  case cardinality
}

extension SQLError: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .state(_, message):
      message
    case let .character(character, location):
      "unexpected character '\(character)' at \(location)"
    case let .unterminated(what, location):
      "unterminated \(what) at \(location)"
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
      "column list count does not match the query-expression degree: "
          + "expected \(expected), got \(got)"
    case let .duplicate(name):
      "duplicate view column '\(name)'"
    case let .redefinition(name):
      "WITH query name '\(name)' specified more than once"
    case let .arity(expected, found):
      "UNION arms project differing column counts: "
          + "expected \(expected), found \(found)"
    case let .unsupported(detail):
      "unsupported query: \(detail)"
    case let .statement(detail):
      "statement is not runnable as a query: \(detail)"
    case let .recursion(name):
      "recursive definition '\(name)' did not terminate"
    case let .grouping(name):
      "column '\(name)' must appear in the GROUP BY clause "
          + "or be used in an aggregate function"
    case let .distinct(name):
      "ORDER BY column '\(name)' must appear in the SELECT DISTINCT list"
    case .cardinality:
      "a scalar subquery yielded more than one row"
    }
  }
}

// MARK: - SQLSTATE

extension SQLError {
  /// The ISO SQLSTATE for this error: a 5-character string whose first two
  /// characters are the class and whose last three are the subclass. Every case
  /// maps to a code, so any `SQLError` exposes one.
  ///
  /// The codes draw on ISO/IEC 9075-2 Annex B (SQLSTATE class values) and,
  /// where ISO leaves the subclass implementation-defined, the de-facto
  /// PostgreSQL assignments:
  ///
  /// - Class `42` — syntax error or access rule violation — covers the
  /// lexer/parser faults (`42601` syntax error), the undefined-object faults
  /// (`42P01` table, `42703` column, `42883` function), and the name-collision
  /// faults (`42702` ambiguous, `42701` duplicate). `42P01` is a PostgreSQL
  /// subclass; ISO itself leaves the `42` subclass implementation-defined, so
  /// this is a deliberate choice noted alongside `42703`/`42883`, which are
  /// likewise PostgreSQL subclasses on the same class. - Class `22` — data
  /// exception — covers the value faults: `22003` numeric value out of range
  /// (the out-of-range integer literal and the arithmetic overflow), `22012`
  /// division by zero, and `22023` invalid parameter value (a scalar function's
  /// rejected argument). - `42804` (datatype mismatch) is the non-numeric
  /// arithmetic operand — a type error at evaluation rather than a value-range
  /// fault. - Class `SS` — the implementation-defined class this engine squats
  /// on (SwiftSQL) for a condition with no standard ISO code — `SS001`, a query
  /// shape the engine does not support (a FROM-less `SELECT *`, or a clause
  /// with no `FROM`), `SS002`, a statement that is not runnable as a query (a
  /// `CREATE VIEW`, or a malformed `WITH` member), `SS003`, a recursive CTE
  /// that did not reach a fixpoint within the iteration cap, `SS004`, an
  /// aggregate query naming a non-aggregated column absent from the `GROUP BY`,
  /// `SS005`, a `SELECT DISTINCT` ordering on a column absent from its select
  /// list, and `SS006`, a scalar subquery yielding more than one row (ISO's
  /// `21000` cardinality violation, kept in the engine's own class for
  /// uniformity with its siblings). ISO leaves classes whose first character is
  /// `5`–`9` or `I`–`Z` implementation-defined, so `SS` is a safe squat.
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
    case .redefinition:
      "42712"
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
    // Class SS — SwiftSQL, this engine's implementation-defined conditions.
    case .unsupported:
      "SS001"
    case .statement:
      "SS002"
    case .recursion:
      "SS003"
    case .grouping:
      "SS004"
    case .distinct:
      "SS005"
    case .cardinality:
      "SS006"
    }
  }

  /// The human-readable message for this error — the same text as
  /// `description`. Paired with `sqlstate`, it gives every error a uniform
  /// `(sqlstate, message)` surface.
  public var message: String {
    description
  }
}
