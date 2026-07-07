// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

public import SQLEngine

extension Routines {
  /// The standard-library prelude — the ISO scalar built-ins the `SQLStandard`
  /// layer installs so a query reaches them without a caller registering a
  /// closure (the prelude-defaulting `run`/`columns` overloads seed it). They
  /// are PROTECTED: a caller cannot shadow one through `registering(_:…)` (the
  /// prelude marks its names via `protecting(_:)`), so a query naming a
  /// built-in always reaches the shipped one. Every member is a pure,
  /// side-effect-free mapping and so DETERMINISTIC — a row-independent call
  /// folds at compile time — and returns NULL on any NULL argument (SQL null
  /// propagation), faulting `SQLError.argument` on the wrong argument count or
  /// a value it cannot map, mirroring its declared `[parameters]`/`returns`
  /// contract the static type-check validates a call against.
  ///
  /// The set covers the ISO scalar built-ins the grammar can already CALL
  /// (`f(…)`), in two families:
  ///
  /// - STRING: `UPPER`/`LOWER` (case fold), `CHAR_LENGTH` (with its ISO synonym
  ///   `CHARACTER_LENGTH`, the same routine under both names), `SUBSTRING` (the
  ///   two-argument `SUBSTRING(text, start)` form, ISO 1-based indexing),
  ///   `TRIM` (the one-argument `TRIM(text)` form, stripping leading and
  ///   trailing spaces), `POSITION` (the ISO `POSITION(substring IN string)`
  ///   form the parser desugars to `position(substring, string)`, 1-based, 0
  ///   when absent), and `OVERLAY` (the ISO `OVERLAY(string PLACING replacement
  ///   FROM start [FOR length])` form the parser desugars to `overlay(string,
  ///   replacement, start[, length])` — an optional-tail routine (`minimum` 3)
  ///   that defaults an omitted `length` to the once-evaluated replacement's
  ///   character count itself, so the parser need not re-reference the
  ///   replacement).
  /// - NUMERIC: `ABS`, `ROUND` (the one-argument form, to the nearest integer
  ///   value), `CEILING` (with its synonym `CEIL`), `FLOOR`, and `MOD` (the
  ///   two-integer remainder — `BITAND`'s numeric sibling, an operation the
  ///   grammar's `%` otherwise lacks a call spelling for). `BITAND` — the
  ///   portable, standards-compliant spelling (Oracle's) of a bitwise AND, an
  ///   operation ISO SQL and this grammar otherwise lack — is kept.
  ///
  /// FOLLOW-UPS (each needs grammar or overloading this batch does not add, so
  /// each ships in its simplest callable form now):
  /// - `SUBSTRING(text FROM start FOR length)` — the full ISO clause with a
  ///   `FROM`/`FOR` keyword syntax and an optional length — and the plain
  ///   three-argument `SUBSTRING(text, start, length)` could now adopt the
  ///   optional-tail arity `OVERLAY` introduced (`minimum` 2, an optional third
  ///   `length`); only the two-argument prefix form ships in this batch.
  /// - `TRIM([{LEADING | TRAILING | BOTH}] [char] FROM text)` — the full ISO
  ///   clause with a trim specification and a trim character — needs grammar;
  ///   only the leading-and-trailing-space `TRIM(text)` form ships.
  /// - `ROUND(n, places)` — rounding to a decimal place — could now use the
  ///   optional-tail arity (`minimum` 1); only the nearest-integer `ROUND(n)`
  ///   form ships in this batch.
  /// - The numeric routines are declared over `double` (`returns` a `double`,
  ///   save `MOD`'s integer remainder), so an INTEGER argument does not satisfy
  ///   the static contract (the type-check is exact-equality — an integer is
  ///   not a double); an integer-domain overload (`ABS(integer) → integer`, …)
  ///   needs routine overloading, which the single-signature contract lacks.
  public static let standard: Routines = preludeMap.protecting(preludeMap.names)

  /// The prelude routines as an UNPROTECTED map — `standard` wraps it with
  /// `protecting(_:)` so its own names cannot be shadowed. Built through the
  /// dictionary-literal escape hatch, which carries no protected names.
  private static let preludeMap: Routines = [
    "bitand": Routine(returns: .integer, parameters: [.integer, .integer],
                      deterministic: true, bitand),
    "upper": Routine(returns: .text, parameters: [.text],
                     deterministic: true, upper),
    "lower": Routine(returns: .text, parameters: [.text],
                     deterministic: true, lower),
    "char_length": Routine(returns: .integer, parameters: [.text],
                           deterministic: true, length),
    "character_length": Routine(returns: .integer, parameters: [.text],
                                deterministic: true, length),
    "substring": Routine(returns: .text, parameters: [.text, .integer],
                         deterministic: true, substring),
    "trim": Routine(returns: .text, parameters: [.text],
                    deterministic: true, trim),
    "abs": Routine(returns: .double, parameters: [.double],
                   deterministic: true, abs),
    "round": Routine(returns: .double, parameters: [.double],
                     deterministic: true, round),
    "ceiling": Routine(returns: .double, parameters: [.double],
                       deterministic: true, ceiling),
    "ceil": Routine(returns: .double, parameters: [.double],
                    deterministic: true, ceiling),
    "floor": Routine(returns: .double, parameters: [.double],
                     deterministic: true, floor),
    "mod": Routine(returns: .integer, parameters: [.integer, .integer],
                   deterministic: true, mod),
    "position": Routine(returns: .integer, parameters: [.text, .text],
                        deterministic: true, position),
    "overlay": Routine(returns: .text,
                       parameters: [.text, .text, .integer, .integer],
                       minimum: 3, deterministic: true, overlay),
  ]

  /// The single `.null` short-circuit ISO null propagation gives every built-in
  /// — a NULL argument yields NULL — factored out so each routine reads as its
  /// mapping alone. Returns `true` when any argument is NULL, so the caller
  /// returns `.null` before matching a concrete kind.
  private static func propagates(_ arguments: Array<SQLEngine.Value>) -> Bool {
    arguments.contains(.null)
  }

  /// `BITAND(x, y)` — the bitwise AND of two integers. A NULL argument yields
  /// NULL (SQL null propagation); the wrong argument count or a non-integer
  /// argument is `SQLError.argument` (a function-argument fault — not
  /// `SQLError.arity`, which is the UNION column-count mismatch). Its declared
  /// `[.integer, .integer]` contract is what the static type-check validates a
  /// call against, mirroring these run-time faults.
  private static func bitand(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("BITAND takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .integer(x) = arguments[0],
        case let .integer(y) = arguments[1] else {
      throw .argument("BITAND requires integer arguments")
    }
    return .integer(x & y)
  }

  /// `UPPER(text)` — the string upper-cased. A NULL argument yields NULL; the
  /// wrong count or a non-text argument is `SQLError.argument`.
  private static func upper(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("UPPER takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("UPPER requires a text argument")
    }
    return .text(string.uppercased())
  }

  /// `LOWER(text)` — the string lower-cased. A NULL argument yields NULL; the
  /// wrong count or a non-text argument is `SQLError.argument`.
  private static func lower(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("LOWER takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("LOWER requires a text argument")
    }
    return .text(string.lowercased())
  }

  /// `CHAR_LENGTH(text)` / `CHARACTER_LENGTH(text)` — the number of characters
  /// in the string (its Unicode character count, not its UTF-8 byte length). A
  /// NULL argument yields NULL; the wrong count or a non-text argument is
  /// `SQLError.argument`.
  private static func length(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("CHAR_LENGTH takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("CHAR_LENGTH requires a text argument")
    }
    return .integer(string.count)
  }

  /// `SUBSTRING(text, start)` — the substring of `text` from the 1-based
  /// `start` character to the end, the ISO indexing where the first character
  /// is position 1. A `start` at or before 1 begins at the first character; a
  /// `start` past the end yields the empty string. A NULL argument yields NULL;
  /// the wrong count, a non-text first argument, or a non-integer second is
  /// `SQLError.argument`.
  private static func substring(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("SUBSTRING takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0],
        case let .integer(start) = arguments[1] else {
      throw .argument("SUBSTRING requires a text and an integer argument")
    }
    // ISO positions are 1-based; a start at or before 1 clamps to the first
    // character, and one past the end clamps to the end (the empty tail). The
    // `start - 1` conversion overflows for `Int.min`, so a start at or before
    // 1 takes the whole string directly rather than subtracting.
    let drop = start > 1 ? start - 1 : 0
    return .text(String(string.dropFirst(drop)))
  }

  /// `TRIM(text)` — the string with leading and trailing SPACE characters
  /// removed (the one-argument ISO form, whose implicit trim character is a
  /// space and whose implicit specification is BOTH). A NULL argument yields
  /// NULL; the wrong count or a non-text argument is `SQLError.argument`.
  private static func trim(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("TRIM takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0] else {
      throw .argument("TRIM requires a text argument")
    }
    return .text(String(string.drop(while: { $0 == " " })
                            .reversed().drop(while: { $0 == " " })
                            .reversed()))
  }

  /// `ABS(n)` — the absolute value of a real number. A NULL argument yields
  /// NULL; the wrong count or a non-double argument is `SQLError.argument`.
  private static func abs(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("ABS takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("ABS requires a double argument")
    }
    return .double(Swift.abs(value))
  }

  /// `ROUND(n)` — the real number rounded to the nearest integer value (ties
  /// away from zero, the ISO default), carried as a double. A NULL argument
  /// yields NULL; the wrong count or a non-double argument is
  /// `SQLError.argument`.
  private static func round(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("ROUND takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("ROUND requires a double argument")
    }
    return .double(value.rounded())
  }

  /// `CEILING(n)` / `CEIL(n)` — the least integer value not less than `n`,
  /// carried as a double. A NULL argument yields NULL; the wrong count or a
  /// non-double argument is `SQLError.argument`.
  private static func ceiling(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("CEILING takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("CEILING requires a double argument")
    }
    return .double(value.rounded(.up))
  }

  /// `FLOOR(n)` — the greatest integer value not greater than `n`, carried as a
  /// double. A NULL argument yields NULL; the wrong count or a non-double
  /// argument is `SQLError.argument`.
  private static func floor(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 1 else {
      throw .argument("FLOOR takes one argument")
    }
    if propagates(arguments) { return .null }
    guard case let .double(value) = arguments[0] else {
      throw .argument("FLOOR requires a double argument")
    }
    return .double(value.rounded(.down))
  }

  /// `MOD(a, b)` — the remainder of `a` divided by `b`, both integers (the ISO
  /// `MOD` function, distinct from the grammar's `%` operator). A zero divisor
  /// is `SQLError.divide`, as integer arithmetic's `%` by zero is. A NULL
  /// argument yields NULL; the wrong count or a non-integer argument is
  /// `SQLError.argument`.
  private static func mod(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("MOD takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .integer(a) = arguments[0],
        case let .integer(b) = arguments[1] else {
      throw .argument("MOD requires integer arguments")
    }
    guard b != 0 else { throw .divide }
    // `a % -1` is mathematically 0, but `Int.min % -1` overflows the implied
    // division and traps, so a divisor of -1 short-circuits to that 0.
    guard b != -1 else { return .integer(0) }
    return .integer(a % b)
  }

  /// `POSITION(substring, string)` — the parser's desugaring of the ISO
  /// `POSITION(substring IN string)` — the 1-based character position of the
  /// first occurrence of `substring` in `string`, 0 when it does not occur. An
  /// EMPTY substring occurs at position 1 (ISO): the empty string is a prefix
  /// of every string, including another empty string. Matching is
  /// character-wise and case-SENSITIVE (no case fold). A NULL argument yields
  /// NULL; the wrong count or a non-text argument is `SQLError.argument`.
  private static func position(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard arguments.count == 2 else {
      throw .argument("POSITION takes two arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .text(substring) = arguments[0],
        case let .text(string) = arguments[1] else {
      throw .argument("POSITION requires text arguments")
    }
    // The empty substring is a prefix of every string, so it occurs at 1.
    guard !substring.isEmpty else { return .integer(1) }
    // Character-wise search over the Unicode scalars `CHAR_LENGTH` counts, so
    // the reported position is a 1-based character index, not a byte offset.
    let haystack = Array(string), needle = Array(substring)
    guard haystack.count >= needle.count else { return .integer(0) }
    for start in 0...(haystack.count - needle.count)
        where Array(haystack[start ..< start + needle.count]) == needle {
      return .integer(start + 1)
    }
    return .integer(0)
  }

  /// `OVERLAY(string, replacement, start, length)` — the parser's desugaring of
  /// the ISO `OVERLAY(string PLACING replacement FROM start [FOR length])` —
  /// the `string` with `length` characters from the 1-based `start` replaced by
  /// `replacement`. The optional `FOR length` defaults, in the parser, to the
  /// replacement's character count, so the four-argument form is the only one
  /// this routine sees. A NULL argument yields NULL; the wrong count, a
  /// non-text `string`/`replacement`, or a non-integer `start`/`length` is
  /// `SQLError.argument`.
  ///
  /// The 1-based `start` and the `length` are CLAMPED to the string rather than
  /// trusted, so no arithmetic traps and no slice runs out of bounds: a `start`
  /// at or before 1 begins at the first character (the `start - 1` conversion
  /// would overflow for `Int.min`, so it is not subtracted below 1), a `start`
  /// past the end appends, a negative `length` removes nothing, and a `length`
  /// past the end removes only to the end. This is `SUBSTRING`'s clamp
  /// discipline applied to both the prefix kept and the suffix resumed.
  private static func overlay(_ arguments: Array<SQLEngine.Value>)
      throws(SQLError) -> SQLEngine.Value {
    guard (3 ... 4).contains(arguments.count) else {
      throw .argument("OVERLAY takes three or four arguments")
    }
    if propagates(arguments) { return .null }
    guard case let .text(string) = arguments[0],
        case let .text(replacement) = arguments[1],
        case let .integer(start) = arguments[2] else {
      throw .argument("OVERLAY requires text, text, and integer arguments")
    }
    // The number of characters to remove: the explicit `FOR length` fourth
    // argument, or — when omitted — the character count of the replacement.
    // Defaulting HERE, from the single evaluated replacement value, is what
    // lets the parser pass only three arguments for the omitted-`FOR` form:
    // the replacement is evaluated ONCE, so a NOT-DETERMINISTIC one
    // (`stepper_text()`) both inserts and measures the SAME value, rather than
    // the parser re-referencing it as `char_length(replacement)` and
    // evaluating it a second time.
    let length: Int
    if arguments.count == 4 {
      guard case let .integer(explicit) = arguments[3] else {
        throw .argument("OVERLAY requires an integer length")
      }
      length = explicit
    } else {
      length = replacement.count
    }
    let characters = Array(string)
    // The prefix kept is `start - 1` characters, clamped into `[0, count]`; the
    // `start - 1` is not computed for a start at or before 1, which would
    // overflow at `Int.min`, and is capped at the string's length so a start
    // past the end keeps the whole string and appends.
    let head = start > 1 ? Swift.min(start - 1, characters.count) : 0
    // The suffix resumes `length` characters after `head`, clamped the same
    // way: a negative or zero length removes nothing (resumes at `head`), and a
    // length past the end resumes at the end. The overshoot is tested against
    // the REMAINING capacity (`count - head`) rather than forming `head +
    // length`, whose sum would overflow for an `Int.max` length.
    let tail = if length <= 0 {
      head
    } else if length < characters.count - head {
      head + length
    } else {
      characters.count
    }
    return .text(String(characters[..<head]) + replacement
                     + String(characters[tail...]))
  }
}
