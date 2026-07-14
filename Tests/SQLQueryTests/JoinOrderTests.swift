// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery

// Joins, ordering, distinct, limit/offset, and the set operators — each built
// fluently and checked against the parser's AST for the equivalent SQL.

private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

struct JoinOrderTests {
  @Test func `an inner equi-join lowers to a JOIN with an ON equality`()
      throws {
    let built = from("TypeDef", as: "t")
        .join("Field", as: "f", on: column("t.Id") == column("f.Owner"))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM TypeDef AS t JOIN Field AS f ON t.Id = f.Owner
        """)))
  }

  @Test func `a left outer join lowers to LEFT JOIN`() throws {
    let built = from("a")
        .join("b", kind: .left, on: column("a.x") == column("b.y"))
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM a LEFT JOIN b ON a.x = b.y
        """)))
  }

  @Test func `order(by:) with mixed directions lowers to ORDER BY`() throws {
    let built = from("T").order(by: "a", desc("b"), asc("c")).statement
    #expect(built == (try parsed("""
        SELECT * FROM T ORDER BY a, b DESC, c ASC
        """)))
  }

  @Test func `distinct lowers to SELECT DISTINCT`() throws {
    let built = from("T").select("a").distinct().statement
    #expect(built == (try parsed("SELECT DISTINCT a FROM T")))
  }

  @Test func `limit and offset lower to FETCH and OFFSET`() throws {
    let built = from("T").offset(5).limit(10).statement
    #expect(built == (try parsed("""
        SELECT * FROM T OFFSET 5 ROWS FETCH FIRST 10 ROWS ONLY
        """)))
  }

  @Test func `union lowers to a set operation`() throws {
    let built = from("a").select("x")
        .union(from("b").select("x"))
        .statement
    #expect(built == (try parsed("""
        SELECT x FROM a UNION SELECT x FROM b
        """)))
  }

  @Test func `union all keeps duplicates`() throws {
    let built = from("a").select("x")
        .union(from("b").select("x"), all: true)
        .statement
    #expect(built == (try parsed("""
        SELECT x FROM a UNION ALL SELECT x FROM b
        """)))
  }

  @Test func `intersect and except lower to their operators`() throws {
    let intersect = from("a").select("x")
        .intersect(from("b").select("x")).statement
    #expect(intersect == (try parsed("""
        SELECT x FROM a INTERSECT SELECT x FROM b
        """)))

    let except = from("a").select("x")
        .except(from("b").select("x")).statement
    #expect(except == (try parsed("""
        SELECT x FROM a EXCEPT SELECT x FROM b
        """)))
  }

  @Test func `a chained set operation associates left`() throws {
    let built = from("a").select("x")
        .union(from("b").select("x"))
        .union(from("c").select("x"))
        .statement
    #expect(built == (try parsed("""
        SELECT x FROM a UNION SELECT x FROM b UNION SELECT x FROM c
        """)))
  }
}

struct GroupTests {
  @Test func `group(by:) with an aggregate lowers to GROUP BY`() throws {
    let built = from("Sales")
        .select(column("Dept").as("Dept"), sum(column("Amount")).as("Total"))
        .group(by: "Dept")
        .statement
    #expect(built == (try parsed("""
        SELECT Dept AS Dept, SUM(Amount) AS Total FROM Sales GROUP BY Dept
        """)))
  }

  @Test func `having filters the grouped rows`() throws {
    let built = from("Sales")
        .select(column("Dept").as("Dept"), count().as("N"))
        .group(by: "Dept")
        .having(count() > 1)
        .statement
    #expect(built == (try parsed("""
        SELECT Dept AS Dept, COUNT(*) AS N FROM Sales
          GROUP BY Dept HAVING COUNT(*) > 1
        """)))
  }

  @Test func `the aggregate builders lower to their aggregate nodes`() throws {
    let built = from("S")
        .select(count().as("c"), count(column("a")).as("ca"),
                sum(column("a")).as("s"), min(column("a")).as("mn"),
                max(column("a")).as("mx"), avg(column("a")).as("av"))
        .statement
    #expect(built == (try parsed("""
        SELECT COUNT(*) AS c, COUNT(a) AS ca, SUM(a) AS s,
               MIN(a) AS mn, MAX(a) AS mx, AVG(a) AS av
          FROM S
        """)))
  }
}
