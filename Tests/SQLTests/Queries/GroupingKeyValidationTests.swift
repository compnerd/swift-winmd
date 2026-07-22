// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLStandard
import SQLTestSupport

// MARK: - Fixtures

/// A two-relation catalog sharing a `Region` column so a `USING`/`NATURAL`
/// join forms a merged column a `GROUP BY` may key on.
private func shipments() throws -> FixtureCatalog {
  try Catalog {
    Relation("Orders", ["Region": .text, "Amount": .integer]) {
      Row("East", 10)
      Row("West", 20)
    }
    Relation("Ship", ["Region": .text, "Cost": .integer]) {
      Row("East", 5)
      Row("West", 7)
    }
  }
}

/// The AST `SELECT COUNT(*) FROM Orders GROUP BY <key>`. The parser now admits
/// a general scalar expression as a `GROUP BY` key (see the SQL-text tests
/// below), so an EVALUATABLE key is equally reachable from source; the AST
/// builder is retained here to exercise the validation path directly with a
/// key of any shape.
private func grouped(by key: Expression,
                     where predicate: Predicate? = nil) -> Query {
  .select(Select(projection: .expressions(
                     [Projected(expression: .aggregate(.count, of: .star))]),
                 from: Relation(name: "Orders"), predicate: predicate,
                 grouping: [key]))
}

/// The `SQLError` running `query` against `catalog` raises, or `nil`.
private func running(_ query: Query,
                     _ catalog: borrowing FixtureCatalog) -> SQLError? {
  do {
    _ = try catalog.run(query)
    return nil
  } catch let fault {
    return fault
  }
}

/// The `SQLError` type-checking `query`'s schema raises, or `nil`.
private func checking(_ query: Query,
                      _ catalog: borrowing FixtureCatalog) -> SQLError? {
  do {
    _ = try catalog.columns(of: query, validate: true)
    return nil
  } catch let fault {
    return fault
  }
}

// MARK: - Tests

struct GroupingKeyValidationTests {
  @Test func `an evaluatable GROUP BY key faults under validate as it does at run`()
      throws {
    // A `GROUP BY 1 / 0` key is EVALUATED per row to form the groups, so a run
    // faults `SQLError.divide`. The schema/type-check walk must surface the
    // SAME fault: `group` lowers the key to a term STRUCTURALLY (no
    // evaluation), so `compile` alone never raised it — the walk now routes
    // each key through the same operand type-check the projection and ORDER BY
    // keys use, closing the gap where `columns(of:validate:)` returned a silent
    // schema for a key a run would fault on.
    let query = grouped(by: .binary(.divide, .literal(.integer(1)),
                                    .literal(.integer(0))))
    #expect(running(query, try shipments()) == .divide)
    #expect(checking(query, try shipments()) == .divide)
  }

  @Test func `a bad-type GROUP BY key faults under validate as it does at run`()
      throws {
    // `'a' + 1` adds text to an integer — a type error the arithmetic operand
    // check faults on. As an evaluated grouping key it faults at run, and the
    // walk now surfaces the same fault under validate.
    let query = grouped(by: .binary(.add, .literal(.string("a")),
                                    .literal(.integer(1))))
    let ran = running(query, try shipments())
    #expect(ran != nil)
    #expect(checking(query, try shipments()) == ran)
  }

  @Test func `a bare-column GROUP BY key still validates and runs`() throws {
    // The common case — the only shape the parser yields today — must not be
    // falsely rejected by the added grouping walk: a bare column resolves
    // exactly as it does elsewhere.
    let sql = "SELECT COUNT(*) FROM Orders GROUP BY Region"
    let columns = try shipments().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try shipments().expect(sql, yields: [[1], [1]])
  }

  @Test func `a merged USING GROUP BY key still validates and runs`() throws {
    // A bare `NATURAL`/`USING` merged column keys on its COALESCE value; the
    // grouping walk validates it through the same merged-aware bare lookup the
    // run lowers it with, so it is not falsely rejected.
    let sql = """
        SELECT COUNT(*) FROM Orders JOIN Ship USING (Region) GROUP BY Region
        """
    let columns = try shipments().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try shipments().expect(sql, yields: [[1], [1]])
  }

  @Test func `a merged NATURAL GROUP BY key still validates and runs`() throws {
    let sql = "SELECT COUNT(*) FROM Orders NATURAL JOIN Ship GROUP BY Region"
    let columns = try shipments().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try shipments().expect(sql, yields: [[1], [1]])
  }

  @Test func `a constant-false WHERE spares an evaluatable GROUP BY key`()
      throws {
    // A constant-false WHERE yields no rows, so a GROUP BY forms NO group and
    // never evaluates its key — the run does not fault, so validate must not
    // either. This mirrors the projection path's constant-false elision (a
    // false WHERE spares an unreachable `1 / 0`), which the grouping walk
    // inherits by sitting past the same early return.
    let query = grouped(by: .binary(.divide, .literal(.integer(1)),
                                    .literal(.integer(0))),
                        where: .comparison(left: .literal(.integer(1)),
                                           op: .equal,
                                           right: .literal(.integer(0))))
    #expect(checking(query, try shipments()) == nil)
    #expect(running(query, try shipments()) == nil)
  }

  // MARK: - General scalar expression keys (parsed from SQL text)

  @Test func `GROUP BY groups by an arithmetic expression key`() throws {
    // `Amount + 1` — an arithmetic key over a column — groups the two distinct
    // amounts (10, 20) into their own groups, keyed on 11 and 21. The key is
    // both PROJECTED (aliased `k`) and grouped, so it names an output column.
    let sql = """
        SELECT Amount + 1 AS k, COUNT(*) FROM Orders
          GROUP BY Amount + 1 ORDER BY k
        """
    try shipments().expect(sql, yields: [[11, 1], [21, 1]])
  }

  @Test func `GROUP BY groups by a group-only expression key`() throws {
    // The grouping key need not be projected: `Amount + 1` forms the two
    // groups while only `COUNT(*)` is selected. Ordering by the aggregate
    // keeps the assertion stable without projecting the key.
    let sql = """
        SELECT COUNT(*) FROM Orders GROUP BY Amount + 1 ORDER BY COUNT(*)
        """
    try shipments().expect(sql, yields: [[1], [1]])
  }

  @Test func `GROUP BY groups by a function-call expression key`() throws {
    // A scalar function call is a value expression too: `LOWER(Region)` groups
    // the two regions (already lower-case, one row each).
    let sql = """
        SELECT LOWER(Region) AS r, COUNT(*) FROM Orders
          GROUP BY LOWER(Region) ORDER BY r
        """
    try shipments().expect(sql, yields: [["east", 1], ["west", 1]])
  }

  @Test func `GROUP BY of a multi-key list mixes a column and an expression`()
      throws {
    // `GROUP BY Region, Amount + 1` — a bare column and an arithmetic
    // expression in one comma-separated list — keys on the pair; each row is
    // its own group here.
    let sql = """
        SELECT Region, Amount + 1 AS k, COUNT(*) FROM Orders
          GROUP BY Region, Amount + 1 ORDER BY Region
        """
    try shipments().expect(sql, yields: [["East", 11, 1], ["West", 21, 1]])
  }

  // MARK: - Expression-key matching normalizes qualification and case

  @Test func `a qualified projection matches an unqualified expression key`()
      throws {
    // `Orders.Amount + 1` (qualified) in the projection is SEMANTICALLY the
    // unqualified `Amount + 1` grouping key — they lower to ONE term. The
    // match is now by lowered term, not raw AST, so the qualified projection is
    // grouped and runs rather than faulting `SQLError.grouping`.
    let sql = """
        SELECT Orders.Amount + 1, COUNT(*) FROM Orders
          GROUP BY Amount + 1 ORDER BY Orders.Amount + 1
        """
    try shipments().expect(sql, yields: [[11, 1], [21, 1]])
  }

  @Test func `an unqualified projection matches a qualified expression key`()
      throws {
    // The reverse qualification: a qualified GROUP BY key with an unqualified
    // projection reference of the same value — also grouped by lowered term.
    let sql = """
        SELECT Amount + 1, COUNT(*) FROM Orders
          GROUP BY Orders.Amount + 1 ORDER BY Amount + 1
        """
    try shipments().expect(sql, yields: [[11, 1], [21, 1]])
  }

  @Test func `a case-variant projection matches an expression key`() throws {
    // `AMOUNT + 1` differs from the `Amount + 1` key only by case, which the
    // engine's identifier resolution folds away — the lowered terms match, so
    // the case-variant reference is grouped.
    let sql = """
        SELECT AMOUNT + 1, COUNT(*) FROM Orders
          GROUP BY Amount + 1 ORDER BY AMOUNT + 1
        """
    try shipments().expect(sql, yields: [[11, 1], [21, 1]])
  }

  @Test func `a HAVING reference matches an expression key by term`() throws {
    // A HAVING reference to the grouped expression matches the SAME way a
    // projection does — `Orders.Amount + 1` (qualified) is the `Amount + 1`
    // key. `HAVING Orders.Amount + 1 > 15` keeps only the group keyed on 21.
    let sql = """
        SELECT Amount + 1, COUNT(*) FROM Orders
          GROUP BY Amount + 1 HAVING Orders.Amount + 1 > 15
        """
    try shipments().expect(sql, yields: [[21, 1]])
  }

  @Test func `an ORDER BY reference matches an expression key by term`()
      throws {
    // An ORDER BY reference to the grouped expression matches by term too — a
    // qualified `Orders.Amount + 1` sort key orders on the unqualified
    // `Amount + 1` grouping key, descending here.
    let sql = """
        SELECT Amount + 1, COUNT(*) FROM Orders
          GROUP BY Amount + 1 ORDER BY Orders.Amount + 1 DESC
        """
    try shipments().expect(sql, yields: [[21, 1], [11, 1]])
  }

  @Test func `a genuinely different projection expression still faults`()
      throws {
    // Term matching must NOT over-accept: `Amount + 2` is a DIFFERENT value
    // from the `Amount + 1` key — its lowered term differs — so the bare
    // non-key `Amount` in it still faults the standard grouping rule.
    let sql = """
        SELECT Amount + 2, COUNT(*) FROM Orders GROUP BY Amount + 1
        """
    let query = try parse(query: sql)
    #expect(running(query, try shipments()) == .grouping("Amount"))
    #expect(checking(query, try shipments()) == .grouping("Amount"))
  }

  @Test func `a qualified bare-column projection matches a bare-column key`()
      throws {
    // The bare-column path is unchanged: a qualified `Orders.Amount` projection
    // still matches the unqualified `Amount` grouping key through the ordinal
    // map, and a non-key bare column still faults.
    let grouped = """
        SELECT Orders.Amount, COUNT(*) FROM Orders
          GROUP BY Amount ORDER BY Orders.Amount
        """
    try shipments().expect(grouped, yields: [[10, 1], [20, 1]])
    let ungrouped = "SELECT Region, COUNT(*) FROM Orders GROUP BY Amount"
    #expect(running(try parse(query: ungrouped), try shipments())
              == .grouping("Region"))
  }

  @Test func `a bare-column GROUP BY parsed from SQL is unchanged`() throws {
    // The pre-existing shape must still parse to a bare `Expression.column`
    // and group exactly as before the widening.
    let sql = """
        SELECT Region, COUNT(*) FROM Orders GROUP BY Region ORDER BY Region
        """
    try shipments().expect(sql, yields: [["East", 1], ["West", 1]])
  }

  @Test func `GROUP BY 1 / 0 parsed from SQL faults on both run and validate`()
      throws {
    // The round-11 payoff: the evaluatable `1 / 0` grouping key is now
    // REACHABLE from SQL text (the parser no longer rejects a non-identifier
    // key). Over a NON-EMPTY input it forms a group per row, evaluating the
    // key and faulting `SQLError.divide` — surfaced identically by the run and
    // by `columns(of:validate:)`.
    let query = try parse(query: "SELECT COUNT(*) FROM Orders GROUP BY 1 / 0")
    #expect(running(query, try shipments()) == .divide)
    #expect(checking(query, try shipments()) == .divide)
  }

  @Test func `a constant-false WHERE spares a SQL GROUP BY 1 / 0 key`() throws {
    // With no surviving rows the GROUP BY forms no group and never evaluates
    // its key, so neither the run nor validate faults — mirroring the
    // AST-built spare above, now driven from SQL text.
    let query = try parse(query: """
        SELECT COUNT(*) FROM Orders WHERE 1 = 0 GROUP BY 1 / 0
        """)
    #expect(checking(query, try shipments()) == nil)
    #expect(running(query, try shipments()) == nil)
  }

  @Test func `GROUP BY of an aggregate faults as a misplaced aggregate`()
      throws {
    // An aggregate is not a grouping key. `GROUP BY COUNT(*)` now PARSES (an
    // aggregate call is an expression) and faults `42803` "an aggregate is not
    // allowed here" — the same fault a nested aggregate raises elsewhere
    // (`HAVING COUNT(COUNT(*)) > 0`), not a parse error.
    let misplaced: SQLError =
        .state("42803", "an aggregate is not allowed here")
    let group = try parse(query: """
        SELECT COUNT(*) FROM Orders GROUP BY COUNT(*)
        """)
    #expect(running(group, try shipments()) == misplaced)
    #expect(checking(group, try shipments()) == misplaced)
    let nested = try parse(query: """
        SELECT COUNT(*) FROM Orders HAVING COUNT(COUNT(*)) > 0
        """)
    #expect(running(nested, try shipments()) == misplaced)
  }

  // MARK: - Scalar subquery grouping keys

  @Test func `GROUP BY of a scalar subquery resolves runs and validates`()
      throws {
    // A scalar subquery is a scalar expression, so `GROUP BY (SELECT 1)` is a
    // valid grouping key — the constant `1` puts every row in one group. The
    // subquery collectors now visit `select.grouping`, so the occurrence is
    // registered and lowers exactly as the same subquery in any other clause;
    // before the fix it faulted "a subquery is not supported in this position".
    let sql = "SELECT COUNT(*) FROM Orders GROUP BY (SELECT 1)"
    let columns = try shipments().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 1)
    try shipments().expect(sql, yields: [[2]])
  }

  @Test func `a correlated scalar subquery grouping key groups per row`()
      throws {
    // A correlated grouping subquery keys each row on the per-row scalar it
    // yields — here `Amount` itself (10, 20) via a correlated lookup — so it
    // forms one group per distinct value, matching the SAME correlated subquery
    // used as a projection.
    let group = """
        SELECT COUNT(*) FROM Orders o
          GROUP BY (SELECT SUM(Amount) FROM Orders i WHERE i.Amount = o.Amount)
          ORDER BY COUNT(*)
        """
    try shipments().expect(group, yields: [[1], [1]])
    // The same correlated subquery as a projection yields the per-row scalar.
    let project = """
        SELECT (SELECT SUM(Amount) FROM Orders i WHERE i.Amount = o.Amount) AS s
          FROM Orders o ORDER BY s
        """
    try shipments().expect(project, yields: [[10], [20]])
  }

  @Test func `a subquery grouping key also in the projection works`() throws {
    // The SAME scalar subquery both projected (aliased `k`) and used as the
    // grouping key registers ONCE (its role is shared) — no double-register
    // or width mismatch — and groups every row into the one constant group.
    let sql = """
        SELECT (SELECT 1) AS k, COUNT(*) FROM Orders GROUP BY (SELECT 1)
        """
    let columns = try shipments().columns(of: parse(query: sql), validate: true)
    #expect(columns.count == 2)
    try shipments().expect(sql, yields: [[1, 2]])
  }

  @Test func `a cardinality-violating subquery grouping key faults as it does in a projection`()
      throws {
    // A scalar subquery yielding more than one row faults
    // `SQLError.cardinality` — the SAME fault it raises as a projection, NOT
    // the generic "not supported in this position" the unregistered key raised.
    let group = try parse(query: """
        SELECT COUNT(*) FROM Orders GROUP BY (SELECT Amount FROM Orders)
        """)
    let project = try parse(query: """
        SELECT (SELECT Amount FROM Orders) FROM Orders
        """)
    let fault = running(group, try shipments())
    #expect(fault == .cardinality)
    #expect(running(project, try shipments()) == fault)
  }
}
