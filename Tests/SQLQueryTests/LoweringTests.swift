// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery

// The lowering oracle: a fluent query builds the SAME `Statement` AST the
// parser builds for the equivalent SQL text. The AST is `Hashable`/`Equatable`,
// so each test asserts the built statement equals `Statement(parsing:)` of the
// hand-written SQL — an exact, cheap oracle that the AST-direct lowering is
// correct without running anything.

/// Parses `sql` to the `Statement` the builder should equal.
private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

struct LoweringTests {
  @Test func `a bare FROM lowers to SELECT *`() throws {
    #expect(from("TypeDef").statement == (try parsed("SELECT * FROM TypeDef")))
  }

  @Test func `select of bare columns lowers to a columns projection`() throws {
    let built = from("TypeDef").select("TypeNamespace", "TypeName").statement
    #expect(built == (try parsed("""
        SELECT TypeNamespace, TypeName FROM TypeDef
        """)))
  }

  @Test func `where with a comparison lowers to a predicate`() throws {
    let built = from("TypeDef").where(column("Flags") == 32).statement
    #expect(built == (try parsed("SELECT * FROM TypeDef WHERE Flags = 32")))
  }

  @Test func `conjoined comparisons lower to AND`() throws {
    let built = from("TypeDef")
        .where(column("Flags") == 32 && column("TypeName") != "")
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM TypeDef WHERE Flags = 32 AND TypeName <> ''
        """)))
  }

  @Test func `a disjunction and negation lower to OR and NOT`() throws {
    let built =
        from("T").where(!(column("a") == 1) || column("b") > 2).statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE NOT a = 1 OR b > 2
        """)))
  }

  @Test func `IS NULL and IS NOT NULL lower to the null predicate`() throws {
    let built = from("T").where(column("a").isNull && column("b").isNotNull)
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE a IS NULL AND b IS NOT NULL
        """)))
  }

  @Test func `IN lowers to a membership predicate`() throws {
    let built = from("T").where(column("a").in(1, 2, 3)).statement
    #expect(built == (try parsed("SELECT * FROM T WHERE a IN (1, 2, 3)")))
  }

  @Test func `LIKE lowers to a like predicate`() throws {
    let built = from("T").where(column("Name").like("IVector%")).statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE Name LIKE 'IVector%'
        """)))
  }

  @Test func `BETWEEN lowers to a between predicate`() throws {
    let built = from("T").where(column("a").between(1, and: 10)).statement
    #expect(built == (try parsed("SELECT * FROM T WHERE a BETWEEN 1 AND 10")))
  }

  @Test func `arithmetic in a projection lowers to a binary expression`()
      throws {
    let built = from("T").select((column("a") + column("b")).as("s")).statement
    #expect(built == (try parsed("SELECT a + b AS s FROM T")))
  }

  @Test func `a scalar call in a projection lowers to a call`() throws {
    let built = from("T").select(Term.call("UPPER", column("Name")).as("u"))
        .statement
    #expect(built == (try parsed("SELECT UPPER(Name) AS u FROM T")))
  }
}
