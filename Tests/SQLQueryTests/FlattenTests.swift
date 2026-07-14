// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// `flatten` — the LINQ `SelectMany` — lowers to a `LATERAL` derived table (an
// APPLY) and, run over a parent/child fixture, yields one row per (parent,
// child) pair. The lowering asserts the built statement equals the parser's
// tree for the equivalent `JOIN LATERAL (…) ON 1 = 1`; the execution asserts
// the flattened row set the engine's per-outer-row re-evaluation produces.

/// Parses `sql` to the `Statement` the builder should equal.
private func parsed(_ sql: String) throws -> Statement {
  try Statement(parsing: sql)
}

struct FlattenLoweringTests {
  @Test func `flatten lowers to an INNER JOIN LATERAL with a vacuous ON`()
      throws {
    let built = from("T")
        .flatten { t in from("S").where(column("S.k") == t["Id"]) }
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T \
        JOIN LATERAL (SELECT * FROM S WHERE S.k = T.Id) AS d ON 1 = 1
        """)))
  }

  @Test func `an aliased flatten binds the body under that name`() throws {
    let built = from("T")
        .flatten(as: "c") { t in from("S").where(column("S.k") == t["Id"]) }
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T \
        JOIN LATERAL (SELECT * FROM S WHERE S.k = T.Id) AS c ON 1 = 1
        """)))
  }

  @Test func `a left flatten lowers to a LEFT JOIN LATERAL (OUTER APPLY)`()
      throws {
    let built = from("T")
        .flatten(kind: .left) { t in
          from("S").where(column("S.k") == t["Id"])
        }
        .statement
    #expect(built == (try parsed("""
        SELECT * FROM T \
        LEFT JOIN LATERAL (SELECT * FROM S WHERE S.k = T.Id) AS d ON 1 = 1
        """)))
  }
}

// MARK: - Execution

/// A parent `T(Id)` and its child `S(k, x)` keyed on `T.Id`, so a `flatten`
/// body's `S.k = T.Id` correlates each parent to its own children. Parent 3 is
/// CHILDLESS — the row an INNER flatten drops, an OUTER flatten NULL-extends.
private func nested() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["Id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
    }
    Relation("S", ["k": .integer, "x": .integer]) {
      Row(1, 100)
      Row(1, 101)
      Row(2, 200)
    }
  }
}

struct FlattenExecutionTests {
  @Test func `flatten yields one row per parent-child pair`() throws {
    let catalog = try nested()
    // Parent 1 has two children, parent 2 has one, parent 3 has none — so an
    // INNER flatten yields three rows, the childless parent contributing none.
    let rows = try from("T")
        .flatten { t in from("S").where(column("S.k") == t["Id"]) }
        .select(column("T.Id").as("Id"), column("d.x").as("x"))
        .order(by: "Id", "x")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1), .integer(100)],
                     [.integer(1), .integer(101)],
                     [.integer(2), .integer(200)]])
  }

  @Test func `an INNER flatten drops a childless parent`() throws {
    let catalog = try nested()
    let rows = try from("T")
        .flatten { t in from("S").where(column("S.k") == t["Id"]) }
        .select(column("T.Id").as("Id"))
        .run(against: catalog, routines: .standard)
    // Parent 3 (childless) never appears — only the parents WITH children do.
    #expect(!rows.contains([.integer(3)]))
    #expect(rows.count == 3)
  }

  @Test func `a left flatten NULL-extends a childless parent`() throws {
    let catalog = try nested()
    let rows = try from("T")
        .flatten(kind: .left) { t in
          from("S").where(column("S.k") == t["Id"])
        }
        .select(column("T.Id").as("Id"), column("d.x").as("x"))
        .order(by: "Id", "x")
        .run(against: catalog, routines: .standard)
    // Parent 3 survives with a NULL child column, the OUTER APPLY row.
    #expect(rows == [[.integer(1), .integer(100)],
                     [.integer(1), .integer(101)],
                     [.integer(2), .integer(200)],
                     [.integer(3), .null]])
  }
}
