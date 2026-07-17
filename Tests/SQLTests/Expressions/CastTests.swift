// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine

import SQLTestSupport

// MARK: - Fixture

/// A relation exercising `CAST`: an integer `Id`, an approximate `D`, a textual
/// `T` (both numeric and non-numeric spellings) with a `T` row that is `NULL`
/// so a cast of a NULL operand is covered, and a boolean `B` so a NON-constant
/// operand of a structurally-unsupported pair (a boolean column to an integer)
/// is covered.
private func things() throws -> FixtureCatalog {
  try Catalog {
    Relation("C",
             ["Id": .integer, "D": .double, "T": .text, "B": .boolean]) {
      Row(1, 1.9, "42", true)
      Row(2, 2.5, "x", false)
      Row(3, 3.0, nil, true)
    }
  }
}

// MARK: - Parsing

/// Parses `text` and returns its `Select`, failing on any other shape.
private func parse(select text: String) throws -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement")
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

struct CastParsingTests {
  @Test func `parses a CAST to a typed conversion`() throws {
    let select = try parse(select: "SELECT CAST(Id AS DOUBLE) FROM C")
    let expression = Expression.cast(.column("Id"), .double)
    #expect(select.projection
                == .expressions([Projected(expression: expression)]))
  }

  @Test func `a delimited CAST is an ordinary function name`() throws {
    // `"CAST"(x)` is a scalar call, not the conversion operator — only the bare
    // keyword spelling is a cast.
    let select = try parse(select: #"SELECT "CAST"(Id) FROM C"#)
    let expression = Expression.call(name: "CAST", arguments: [.column("Id")])
    #expect(select.projection
                == .expressions([Projected(expression: expression)]))
  }

  @Test func `rejects a CAST missing AS`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT CAST(Id DOUBLE) FROM C")
    }
  }

  @Test func `rejects a CAST to an unknown type`() {
    #expect(throws: SQLError.self) {
      _ = try Statement(parsing: "SELECT CAST(Id AS WIDGET) FROM C")
    }
  }
}

// MARK: - Numeric conversions

struct CastNumericTests {
  @Test func `integer widens to double exactly`() throws {
    try things().expect("SELECT CAST(Id AS DOUBLE) FROM C WHERE Id = 1",
                        yields: [[1.0]])
  }

  @Test func `double truncates toward zero to integer`() throws {
    // `1.9` → `1`, `2.5` → `2`, `3.0` → `3` — ISO truncation, not rounding.
    try things().expect("SELECT CAST(D AS INTEGER) FROM C",
                        yields: [[1], [2], [3]])
  }

  @Test func `a number casts to its canonical text`() throws {
    try things().expect("SELECT CAST(42 AS TEXT)", yields: [["42"]])
  }

  @Test func `text parses to an integer`() throws {
    try things().expect("SELECT CAST('42' AS INTEGER)", yields: [[42]])
  }

  @Test func `text parses to a double`() throws {
    try things().expect("SELECT CAST('2.5' AS DOUBLE)", yields: [[2.5]])
    try things().expect("SELECT CAST('1.5' AS DOUBLE)", yields: [[1.5]])
  }

  @Test func `text of overflowing magnitude to double faults`() throws {
    // `'1e999'` PARSES to a finite-syntax spelling but its magnitude is out of
    // range — `Double('1e999')` is `inf` — so the cast raises the numeric
    // value out-of-range fault (`22003`), matching the numeric-literal path,
    // NOT the invalid-character fault (`22018`) reserved for an unparseable
    // spelling.
    try things().expect(
        "SELECT CAST('1e999' AS DOUBLE)",
        fails: .magnitude("double '1e999' out of range for cast"))
  }

  @Test func `unparseable text to double faults`() throws {
    // `'abc'` is no number at all, so its cast raises the ISO
    // invalid-character-for-cast fault (`22018`), distinct from the
    // out-of-range fault above.
    try things().expect("SELECT CAST('abc' AS DOUBLE)",
                        fails: .state("22018", "cannot cast 'abc' to double"))
  }

  @Test func `unparseable text to integer faults`() throws {
    // Row 2's `T` is `'x'`, which is no integer, so the cast raises the ISO
    // invalid-character-for-cast fault (`22018`) rather than yielding a value.
    try things().expect("SELECT CAST(T AS INTEGER) FROM C WHERE Id = 2",
                        fails: .state("22018", "cannot cast 'x' to integer"))
  }
}

// MARK: - NULL, boolean, and blob

struct CastValueTests {
  @Test func `NULL casts to NULL for any target`() throws {
    // Row 3's `T` is NULL; casting it to INTEGER stays NULL, never a fault.
    try things().expect("SELECT CAST(T AS INTEGER) FROM C WHERE Id = 3",
                        yields: [[nil]])
  }

  @Test func `a boolean casts to text`() throws {
    try things().expect("SELECT CAST(TRUE AS TEXT)", yields: [["true"]])
  }

  @Test func `text casts to a boolean`() throws {
    try things().expect("SELECT CAST('no' AS BOOLEAN)", yields: [[false]])
  }

  @Test func `text casts to a blob as its UTF-8 octets`() throws {
    try things().expect("SELECT CAST('AB' AS BLOB)",
                        yields: [[[UInt8(0x41), UInt8(0x42)]]])
  }

  @Test func `a blob casts back to text`() throws {
    try things().expect("SELECT CAST(x'4142' AS TEXT)", yields: [["AB"]])
  }

  @Test func `an unsupported cross-kind cast faults`() throws {
    // A boolean has no conversion to an integer — a cross-kind pair with no ISO
    // conversion faults `42846` (cannot coerce).
    try things().expect(
        "SELECT CAST(TRUE AS INTEGER)",
        fails: .state("42846", "cannot cast boolean to integer"))
  }
}

// MARK: - Schema and column

struct CastSchemaTests {
  private func parse(_ text: String) throws -> Query {
    guard case let .select(query) = try Statement(parsing: text) else {
      Issue.record("expected a SELECT statement")
      throw SQLError.incomplete(expected: "a SELECT statement")
    }
    return query
  }

  /// The single output column type of a one-column query's schema.
  private func type(of text: String) throws -> ValueType {
    let columns = try things().columns(of: parse(text))
    #expect(columns.count == 1)
    return columns[0].type
  }

  @Test func `the schema reports the target type`() throws {
    // The cast's static type is the target, whatever the operand's own type.
    #expect(try type(of: "SELECT CAST(Id AS DOUBLE) AS V FROM C") == .double)
    #expect(try type(of: "SELECT CAST(D AS INTEGER) AS V FROM C") == .integer)
    #expect(try type(of: "SELECT CAST(Id AS TEXT) AS V FROM C") == .text)
  }

  @Test func `casting over a column converts each row`() throws {
    // `CAST(Id AS TEXT)` spells each integer identity canonically.
    try things().expect("SELECT CAST(Id AS TEXT) FROM C",
                        yields: [["1"], ["2"], ["3"]])
  }

  @Test func `a cast in a WHERE filters rows`() throws {
    // Keep the rows whose truncated `D` is `2` — only row 2 (`2.5` → `2`).
    try things().expect("SELECT Id FROM C WHERE CAST(D AS INTEGER) = 2",
                        yields: [[2]])
  }

  @Test func `a structurally impossible cast is rejected at validation`()
      throws {
    // `CAST(TRUE AS INTEGER)` is a reachable projection whose (boolean →
    // integer) pair `Value.cast(to:)` faults `42846` for EVERY value, so the
    // schema type-check rejects it rather than advertising an integer column.
    #expect(throws: SQLError.state("42846",
                                   "cannot cast boolean to integer")) {
      _ = try things().columns(of: parse("SELECT CAST(TRUE AS INTEGER)"))
    }
  }

  @Test func `a value-dependent cast passes validation`() throws {
    // A castable-but-value-dependent pair — `integer` → `double` always
    // convertible, `text` → `integer` convertible for a good spelling —
    // type-checks and reports the target type; only a bad VALUE faults at run.
    #expect(try type(of: "SELECT CAST(1 AS DOUBLE)") == .double)
    #expect(try type(of: "SELECT CAST('1' AS INTEGER)") == .integer)
  }

  @Test func `a constant cast that always fails is rejected at validation`()
      throws {
    // `CAST('abc' AS INTEGER)` has a castable pair but a CONSTANT operand that
    // converts to no value, so a trial cast of the folded constant rejects it
    // at validation, not only at run.
    #expect(throws: SQLError.state("22018",
                                   "cannot cast 'abc' to integer")) {
      _ = try things().columns(of: parse("SELECT CAST('abc' AS INTEGER)"))
    }
  }

  @Test func `a statically-NULL operand validates for any target`() throws {
    // `CASE WHEN 1 = 0 THEN 1 END` folds to NULL, but its DERIVED type is the
    // default `.integer`, whose (integer → blob) pair is structurally
    // unsupported. The constant fold runs FIRST, so the folded NULL trial-casts
    // to `.blob` — a NULL casts to ANY target — and validation SUCCEEDS with a
    // blob column rather than rejecting `42846` a query the run would perform.
    let sql = "SELECT CAST(CASE WHEN 1 = 0 THEN 1 END AS BLOB)"
    let columns = try things().columns(of: parse(sql), validate: true)
    #expect(columns.count == 1)
    #expect(columns[0].type == .blob)
    try things().expect(sql, yields: [[nil]])
  }

  @Test func `a constant unsupported cast is rejected by the trial`() throws {
    // `CAST(TRUE AS INTEGER)` has a CONSTANT non-NULL operand, so the trial
    // cast of the folded `true` — no boolean-to-integer conversion — rejects it
    // `42846`, the same fault the structural check would raise.
    #expect(throws: SQLError.state("42846",
                                   "cannot cast boolean to integer")) {
      _ = try things().columns(of: parse("SELECT CAST(TRUE AS INTEGER)"),
                               validate: true)
    }
  }

  @Test func `a non-constant unsupported cast is rejected structurally`()
      throws {
    // `CAST(B AS INTEGER)` reads a boolean COLUMN, so it folds to no constant;
    // the structural pair check rejects the (boolean → integer) kind `42846`
    // without a value to trial.
    #expect(throws: SQLError.state("42846",
                                   "cannot cast boolean to integer")) {
      _ = try things().columns(of: parse("SELECT CAST(B AS INTEGER) FROM C"),
                               validate: true)
    }
  }

  @Test func `a value-dependent cast still validates`() throws {
    // `CAST('1' AS INTEGER)` is a castable pair whose fault depends on the
    // value, so it type-checks as an integer column even after the reorder —
    // the trial cast of the constant `'1'` succeeds.
    #expect(try type(of: "SELECT CAST('1' AS INTEGER)") == .integer)
  }
}

// MARK: - SQL numeric format

struct CastNumericFormatTests {
  @Test func `a Swift hex float is not a SQL number`() throws {
    // `Double('0x1p2')` is `4.0`, a Swift spelling the SQL grammar rejects, so
    // the cast faults invalid character (`22018`), never yielding `4.0`.
    try things().expect(
        "SELECT CAST('0x1p2' AS DOUBLE)",
        fails: .state("22018", "cannot cast '0x1p2' to double"))
  }

  @Test func `the infinity spelling is not a SQL number`() throws {
    // `Double('inf')` PARSES to a non-finite magnitude, but `inf` is no SQL
    // numeric spelling, so it is an invalid character (`22018`) — NOT the
    // out-of-range fault (`22003`) a valid-format overflow raises.
    try things().expect("SELECT CAST('inf' AS DOUBLE)",
                        fails: .state("22018", "cannot cast 'inf' to double"))
  }

  @Test func `the NaN spelling is not a SQL number`() throws {
    try things().expect("SELECT CAST('nan' AS DOUBLE)",
                        fails: .state("22018", "cannot cast 'nan' to double"))
  }

  @Test func `a format-valid overflow is still out of range`() throws {
    // `'1e999'` is a valid SQL decimal spelling whose magnitude is past range,
    // so it passes the format gate and faults out-of-range (`22003`),
    // unchanged.
    try things().expect(
        "SELECT CAST('1e999' AS DOUBLE)",
        fails: .magnitude("double '1e999' out of range for cast"))
  }

  @Test func `valid SQL decimal spellings parse`() throws {
    try things().expect("SELECT CAST('1.5' AS DOUBLE)", yields: [[1.5]])
    try things().expect("SELECT CAST('-3' AS DOUBLE)", yields: [[-3.0]])
    try things().expect("SELECT CAST('2e3' AS DOUBLE)", yields: [[2000.0]])
  }

  @Test func `a format-valid integer overflow is out of range`() throws {
    // `'9223372036854775808'` is a VALID integer spelling — `Int.max` plus one
    // — so it passes the format gate and `Int(_:)` returns `nil` only for
    // RANGE, faulting out-of-range (`22003`), NOT the invalid-character fault
    // (`22018`) an unspellable text raises.
    try things().expect(
        "SELECT CAST('9223372036854775808' AS INTEGER)",
        fails: .magnitude(
            "integer '9223372036854775808' out of range for cast"))
  }

  @Test func `a malformed integer spelling faults invalid character`() throws {
    // `'12abc'` and `'1.5'` are no SQL integer spelling — trailing letters, a
    // fraction — so each is an invalid character (`22018`), the format gate
    // rejecting them before `Int(_:)` conflates them with a range overflow.
    try things().expect(
        "SELECT CAST('12abc' AS INTEGER)",
        fails: .state("22018", "cannot cast '12abc' to integer"))
    try things().expect(
        "SELECT CAST('1.5' AS INTEGER)",
        fails: .state("22018", "cannot cast '1.5' to integer"))
  }

  @Test func `valid SQL integer spellings parse`() throws {
    try things().expect("SELECT CAST('42' AS INTEGER)", yields: [[42]])
    try things().expect("SELECT CAST('-7' AS INTEGER)", yields: [[-7]])
  }
}
