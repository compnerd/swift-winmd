// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery

// The subquery lowering oracle: a fluent subquery operator builds the SAME
// `Statement` AST the parser builds for the equivalent SQL text. Each test
// asserts the built statement equals `Statement(parsing:)` of the hand-written
// SQL, the exact `Hashable` oracle the other lowering tests use.

/// Parses `sql` to the `Statement` the builder should equal.
private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

struct SubqueryTests {
  @Test func `IN over a subquery lowers to a within predicate`() throws {
    let built = from("T")
        .where(column("K").in(from("S").select("V")))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE K IN (SELECT V FROM S)
        """)))
  }

  @Test func `NOT IN over a subquery lowers to a negated within`() throws {
    let built = from("T")
        .where(column("K").in(from("S").select("V"), negated: true))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE K NOT IN (SELECT V FROM S)
        """)))
  }

  @Test func `EXISTS lowers to an exists predicate`() throws {
    let built = from("T")
        .where(exists(from("S").select("V")))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE EXISTS (SELECT V FROM S)
        """)))
  }

  @Test func `NOT EXISTS lowers to a negated exists`() throws {
    let built = from("T")
        .where(exists(from("S").select("V"), negated: true))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE NOT EXISTS (SELECT V FROM S)
        """)))
  }

  @Test func `= ANY lowers to a quantified predicate`() throws {
    let built = from("T")
        .where(column("K") == any(from("S").select("V")))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE K = ANY (SELECT V FROM S)
        """)))
  }

  @Test func `<> ALL lowers to a quantified predicate`() throws {
    let built = from("T")
        .where(column("K") != all(from("S").select("V")))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE K <> ALL (SELECT V FROM S)
        """)))
  }

  @Test func `< ANY lowers to a quantified predicate`() throws {
    let built = from("T")
        .where(column("K") < any(from("S").select("V")))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE K < ANY (SELECT V FROM S)
        """)))
  }

  @Test func `a quantified comparison over a union subquery lowers`() throws {
    let sub = from("S").select("V").union(from("R").select("W"))
    let built = from("T").where(column("K") > all(sub)).statement
    #expect(built == (try parsed("""
        SELECT * FROM T
        WHERE K > ALL (SELECT V FROM S UNION SELECT W FROM R)
        """)))
  }

  @Test func `a scalar subquery in a projection lowers to a subquery`()
      throws {
    let inner = from("S").select(Projection(max(column("V"))))
    let built = from("T").select(scalar(inner).as("m")).statement
    #expect(built == (try parsed("""
        SELECT (SELECT MAX(V) FROM S) AS m FROM T
        """)))
  }

  @Test func `a scalar subquery as a comparison operand lowers`() throws {
    let inner = from("S").select(Projection(min(column("V"))))
    let built = from("T").where(column("V") == scalar(inner)).statement
    #expect(built == (try parsed("""
        SELECT * FROM T WHERE V = (SELECT MIN(V) FROM S)
        """)))
  }

  @Test func `IN over a set-operation subquery lowers to a within`() throws {
    let sub = from("S").select("V").intersect(from("R").select("W"))
    let built = from("T").where(column("K").in(sub)).statement
    #expect(built == (try parsed("""
        SELECT * FROM T
        WHERE K IN (SELECT V FROM S INTERSECT SELECT W FROM R)
        """)))
  }
}
