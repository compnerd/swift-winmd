// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine
import SQLStandard

import SQLTestSupport

// MARK: - NULL value expression

struct NullLiteralTests {
  @Test func `NULL in value position parses to a literal`() throws {
    // The keyword `NULL` written where a value expression is expected is the ISO
    // `<null specification>` — a `Literal.null`, distinct from the `IS NULL`
    // predicate that tests a value.
    let select = try parse(select: "SELECT NULL FROM T")
    #expect(select.projection
                == .expressions([Projected(expression: .literal(.null))]))
  }

  @Test func `SELECT NULL yields NULL, typed as the placeholder integer`()
      throws {
    // A bare NULL has no determinate type; its column is unconstrained and takes
    // the `.integer` placeholder where nothing else constrains it, and every row
    // projects the absent value.
    #expect(try nullable().type(of: "SELECT NULL FROM T") == .integer)
    try nullable().expect("SELECT NULL FROM T", yields: [[nil], [nil]])
  }

  @Test func `a NULL arm of a UNION unifies with the typed arm`() throws {
    // A constant-NULL projection places no type constraint, so the set-operation
    // fold carries the other arm's type: `SELECT NULL UNION SELECT Name` is a
    // text column, its NULL row preserved.
    #expect(try nullable().type(of: """
        SELECT NULL FROM T WHERE Id = 1
         UNION SELECT Name FROM T WHERE Id = 1
        """) == .text)
    try nullable().expect("""
        SELECT NULL FROM T WHERE Id = 1
         UNION SELECT Name FROM T WHERE Id = 2
        """, yields: [[nil], ["b"]])
  }

  @Test func `a NULL CASE result is type-neutral and unifies with a typed arm`()
      throws {
    // A `THEN NULL` (or `ELSE NULL`) places no type constraint on the CASE — the
    // NULL unifies with any arm — so the result type is the typed arm's, exactly
    // as COALESCE skips a constant-NULL argument.
    #expect(try nullable().type(of: """
        SELECT CASE WHEN Id = 1 THEN NULL ELSE Name END FROM T
        """) == .text)
    try nullable().expect("""
        SELECT CASE WHEN Id = 1 THEN NULL ELSE Name END FROM T
        """, yields: [[nil], ["b"]])
  }

  @Test func `an all-NULL CASE is unconstrained, taking the placeholder`()
      throws {
    // Every reachable result constant NULL leaves the CASE unconstrained; it
    // takes the `.integer` placeholder and yields NULL for every row.
    #expect(try nullable().type(of: """
        SELECT CASE WHEN Id = 1 THEN NULL ELSE NULL END FROM T
        """) == .integer)
    try nullable().expect("""
        SELECT CASE WHEN Id = 1 THEN NULL ELSE NULL END FROM T
        """, yields: [[nil], [nil]])
  }

  @Test func `COALESCE over a NULL literal skips it`() throws {
    // A NULL literal argument is a constant NULL COALESCE skips, so `COALESCE(NULL,
    // Name)` is the text column and returns each row's Name.
    #expect(try nullable().type(of: "SELECT COALESCE(NULL, Name) FROM T")
                == .text)
    try nullable().expect("SELECT COALESCE(NULL, Name) FROM T",
                        yields: [["a"], ["b"]])
  }

  @Test func `a comparison against NULL is UNKNOWN, selecting no row`() throws {
    // `K = NULL` is UNKNOWN for every row under three-valued logic (ISO), so it
    // filters everything — the reason `IS NULL` exists. The NULL is a value
    // expression here, not the `IS NULL` predicate.
    try nullable().empty("SELECT Id FROM T WHERE K = NULL")
  }

  @Test func `IS NULL still tests a value, unaffected by the NULL literal`()
      throws {
    // The `IS NULL` predicate consumes its own `NULL`, so it keeps testing the
    // operand: row 2's `K` is absent.
    try nullable().expect("SELECT Id FROM T WHERE K IS NULL", yields: [[2]])
  }

  @Test func `NULL propagates through arithmetic`() throws {
    // A NULL operand makes the arithmetic NULL; the column is numeric.
    try nullable().expect("SELECT NULL + 1 FROM T WHERE Id = 1", yields: [[nil]])
  }

  @Test func `a NULL literal fits a non-integer routine parameter`() throws {
    // UPPER declares a text parameter. A bare NULL's placeholder integer type
    // must not fault schema validation, since dispatch accepts NULL for any
    // declared type and returns NULL — validate and run must agree.
    let cat = try nullable()
    let sql = "SELECT UPPER(NULL) FROM T"
    _ = try cat.columns(of: parse(query: sql), routines: .standard)
    try cat.expect(sql, yields: [[nil], [nil]])
  }

  @Test func `a row-dependent all-NULL CASE is unconstrained in a UNION`()
      throws {
    // Every reachable result is NULL, so the CASE yields NULL whichever branch a
    // row takes — even though the `Id = 1` guard is row-dependent (the
    // whole-expression fold is undecided). The column is therefore unconstrained
    // and unifies with the text arm rather than faulting integer-versus-text.
    let sql = """
        SELECT CASE WHEN Id = 1 THEN NULL ELSE NULL END FROM T WHERE Id = 1
         UNION SELECT Name FROM T WHERE Id = 2
        """
    #expect(try nullable().type(of: sql) == .text)
    try nullable().expect(sql, yields: [[nil], ["b"]])
  }

  @Test func `a NULL operand short-circuits mixed-kind arithmetic`() throws {
    // `Arithmetic.apply` returns NULL before inspecting operand kinds, dividing,
    // or overflowing, so a statically-NULL operand makes the whole expression
    // NULL whatever the other operand — schema validation must agree with the
    // run rather than fault on the non-numeric operand or the zero divisor. This
    // covers both orders, a non-numeric partner, and the short-circuited divide.
    let cat = try nullable()
    for sql in ["SELECT NULL + 'x' FROM T WHERE Id = 1",
                "SELECT 'x' + NULL FROM T WHERE Id = 1",
                "SELECT NULL * Name FROM T WHERE Id = 1",
                "SELECT NULL / 0 FROM T WHERE Id = 1"] {
      _ = try cat.columns(of: parse(query: sql), validate: true)
      try cat.expect(sql, yields: [[nil]])
    }
  }
}
