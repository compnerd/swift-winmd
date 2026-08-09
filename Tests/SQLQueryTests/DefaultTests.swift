// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// `default` — the LINQ `DefaultIfEmpty` — lowers to `WITH source AS (self)
// SELECT * FROM source UNION ALL (SELECT <defaults> FROM (VALUES (0)) AS
// defaults WHERE NOT EXISTS (SELECT * FROM source))`: the source is
// materialized once as the `source` CTE and read by both the emitted arm and
// the emptiness guard, so a non-deterministic source cannot make them disagree.
// The lowering asserts the built statement equals the parser's tree; the
// execution asserts the source rows survive when present and the default row
// stands in when they do not.

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
  @Test func `default materializes the source once as a CTE`() throws {
    let built = try from("T").select("K").default(0).statement
    #expect(built == (try parsed("""
        WITH source (c1) AS (SELECT K FROM T) \
        SELECT c1 AS K FROM source \
        UNION ALL \
        SELECT 0 FROM (VALUES (0)) AS defaults \
        WHERE NOT EXISTS (SELECT * FROM source)
        """)))
  }

  @Test func `default materializes duplicate output names positionally`()
      throws {
    // A source may project a name twice (`SELECT K, K`); naming the CTE columns
    // K, K would fault the engine's case-insensitive uniqueness check, so they
    // are the unique positional c1, c2, re-projected to the duplicate output
    // names — the result keeps both K columns.
    let built = try from("T").select("K", "K").default(0, 0).statement
    #expect(built == (try parsed("""
        WITH source (c1, c2) AS (SELECT K, K FROM T) \
        SELECT c1 AS K, c2 AS K FROM source \
        UNION ALL \
        SELECT 0, 0 FROM (VALUES (0)) AS defaults \
        WHERE NOT EXISTS (SELECT * FROM source)
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

  @Test func `default returns a source with duplicate output names`() throws {
    let catalog = try fixture()
    // `SELECT K, K` projects the same name twice; the source is non-empty, so
    // its rows survive with no default. A CTE column list of K, K would fault
    // the uniqueness check — the positional c1, c2 names let it materialize.
    let rows = try from("T").select("K", "K").default(0, 0)
        .run(against: catalog, routines: .standard)
    #expect(rows.count == 2)
    #expect(rows.contains([.integer(1), .integer(1)]))
    #expect(rows.contains([.integer(2), .integer(2)]))
  }

  @Test func `default evaluates a non-deterministic source once`() throws {
    let catalog = try single()
    // `flip()` returns true, then false, then true, … — a non-deterministic
    // routine. The source `SELECT K FROM T WHERE flip()` over T's one row keeps
    // that row on a single evaluation (the first call is true). Were the source
    // evaluated twice — once for the emitted arm and once for the emptiness
    // guard — the second call (false) would empty the guard's view and wrongly
    // append the default for two rows. Materializing the source once as a CTE
    // makes both arms read the one kept row, so it is invoked exactly once.
    final class Flip: @unchecked Sendable { var calls = 0 }
    let state = Flip()
    let flip = Routine(returns: .boolean, parameters: [],
                       deterministic: false) { _ throws(SQLError) in
      defer { state.calls += 1 }
      return .boolean(state.calls % 2 == 0)
    }
    let routines = Routines.standard.merging(["flip": flip])
    let rows = try from("T").select("K").where(Term.call("flip") == true)
        .default(0).run(against: catalog, routines: routines)
    #expect(rows == [[.integer(1)]])
    #expect(state.calls == 1)
  }
}

/// A one-row `T` — the source's routine runs against a single row, so a second
/// evaluation would alternate and disagree with the first.
private func single() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["K": .integer]) {
      Row(1)
    }
  }
}
