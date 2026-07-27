// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// `default` — the LINQ `DefaultIfEmpty` — lowers to `self UNION ALL (SELECT
// <defaults> FROM (VALUES (0)) AS defaults WHERE NOT EXISTS (self))`: the ISO
// `VALUES (0)` one-row derived table gives the guard arm a FROM to hang its
// WHERE on, so it yields its one default row only when the source is empty and
// exactly one arm contributes. The lowering asserts the built statement equals
// the parser's tree; the execution asserts the source rows survive when present
// and the default row stands in when they do not.

/// Parses `sql` to the `Statement` the builder should equal.
private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

/// A one-column `T` with two rows — the fixture for the non-empty case and,
/// filtered to nothing, the empty case.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["K": .integer]) {
      Row(1)
      Row(2)
    }
  }
}

struct DefaultLoweringTests {
  @Test func `default lowers to a UNION ALL guarded by NOT EXISTS`() throws {
    let built = from("T").select("K").default(0).statement
    #expect(built == (try parsed("""
        SELECT K FROM T \
        UNION ALL \
        SELECT 0 FROM (VALUES (0)) AS defaults \
        WHERE NOT EXISTS (SELECT K FROM T)
        """)))
  }
}

struct DefaultExecutionTests {
  @Test func `default yields the source rows when it is non-empty`() throws {
    let catalog = try fixture()
    let rows = try from("T").select("K").default(0)
        .run(against: catalog, routines: .standard)
    // The source has rows, so the guard arm contributes none — the result is
    // the source's two rows and never the default (asserted independent of
    // order, since a UNION ALL arm carries no ORDER BY).
    #expect(rows.count == 2)
    #expect(rows.contains([.integer(1)]) && rows.contains([.integer(2)]))
    #expect(!rows.contains([.integer(0)]))
  }

  @Test func `default yields the default row when the source is empty`()
      throws {
    let catalog = try fixture()
    let rows = try from("T").select("K").where(column("K") > 100).default(0)
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(0)]])
  }
}
