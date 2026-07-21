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

/// The AST `SELECT COUNT(*) FROM Orders GROUP BY <key>`. The parser accepts
/// only a bare column as a `GROUP BY` key (ISO extended grouping is a
/// follow-up), so an EVALUATABLE key — the surface the `Array<Expression>`
/// widening admits and the merged-column lowering relies on — is built by AST
/// to exercise the validation path a future general-key parser would feed.
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
}
