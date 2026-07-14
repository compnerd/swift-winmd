// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SQLEngine
import SQLQuery
import SQLStandard
import SQLTestSupport

// Execution of the subquery operators over a small in-memory fixture — the
// built subquery, handed to `run(against:routines:)`, yields the rows the
// equivalent SQL would. It proves the subquery lowering runs end to end, not
// just that it equals the parser's tree.

/// An outer `T` (keys 1…4) and an inner `S` (a two-value subset), the fixture
/// for the membership, `EXISTS`, quantified, and scalar-subquery chains.
private func fixture() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["K": .integer]) {
      Row(1)
      Row(2)
      Row(3)
      Row(4)
    }
    Relation("S", ["V": .integer]) {
      Row(2)
      Row(3)
    }
  }
}

struct SubqueryExecutionTests {
  @Test func `IN over a subquery keeps the members`() throws {
    let catalog = try fixture()
    let rows = try from("T")
        .where(column("K").in(from("S").select("V")))
        .order(by: "K")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `NOT IN over a subquery keeps the non-members`() throws {
    let catalog = try fixture()
    let rows = try from("T")
        .where(column("K").in(from("S").select("V"), negated: true))
        .order(by: "K")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }

  @Test func `EXISTS keeps every row when the subquery is non-empty`()
      throws {
    let catalog = try fixture()
    let rows = try from("T")
        .where(exists(from("S").select("V")))
        .order(by: "K")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                     [.integer(4)]])
  }

  @Test func `NOT EXISTS drops every row over a non-empty subquery`()
      throws {
    let catalog = try fixture()
    let rows = try from("T")
        .where(exists(from("S").select("V"), negated: true))
        .run(against: catalog, routines: .standard)
    #expect(rows.isEmpty)
  }

  @Test func `= ANY matches any subquery value`() throws {
    let catalog = try fixture()
    let rows = try from("T")
        .where(column("K") == any(from("S").select("V")))
        .order(by: "K")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `> ALL matches values above every subquery value`() throws {
    let catalog = try fixture()
    let rows = try from("T")
        .where(column("K") > all(from("S").select("V")))
        .order(by: "K")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(4)]])
  }

  @Test func `a scalar subquery projects the same value on every row`()
      throws {
    let catalog = try fixture()
    let inner = from("S").select(Projection(max(column("V"))))
    let rows = try from("T")
        .select(column("K").as("K"), scalar(inner).as("m"))
        .order(by: "K")
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1), .integer(3)], [.integer(2), .integer(3)],
                     [.integer(3), .integer(3)], [.integer(4), .integer(3)]])
  }

  @Test func `a scalar subquery as a comparison operand filters`() throws {
    let catalog = try fixture()
    let inner = from("S").select(Projection(min(column("V"))))
    let rows = try from("T")
        .where(column("K") == scalar(inner))
        .run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(2)]])
  }
}

// MARK: - Correlated

/// An outer `T(id)` (1…4) and an inner `S(sid, tid)` whose `tid` points back at
/// a `T.id` — the fixture for the CORRELATED operators, which re-execute the
/// inner query per outer row against the outer `id`. Each correlated test below
/// asserts a result that VARIES by outer row (rows kept, dropped, or a per-row
/// count), which a once-memoised uncorrelated run could not produce —
/// proving the engine re-runs the inner plan per outer row (PR243).
private func linked() throws -> FixtureCatalog {
  try Catalog {
    Relation("T", ["id": .integer]) {
      Row(1)
      Row(2)
      Row(3)
      Row(4)
    }
    Relation("S", ["sid": .integer, "tid": .integer]) {
      Row(10, 2)
      Row(11, 3)
      Row(12, 3)
    }
  }
}

struct CorrelatedSubqueryExecutionTests {
  @Test func `a correlated EXISTS keeps only the matched outer rows`()
      throws {
    let catalog = try linked()
    // `EXISTS (SELECT sid FROM S WHERE S.tid = T.id)` is TRUE only for the
    // outer rows some `S.tid` points at (2, 3), FALSE for 1 and 4 — a per-row
    // result, not the constant a once-run subquery would give.
    let inner = from("S").select("sid")
        .grouping(on: column("S.tid"), equals: outer("T", "id"))
    let rows = try from("T").select("id").where(exists(inner))
        .order(by: "id").run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `a correlated NOT EXISTS keeps the unmatched outer rows`()
      throws {
    let catalog = try linked()
    let inner = from("S").select("sid")
        .grouping(on: column("S.tid"), equals: outer("T", "id"))
    let rows = try from("T").select("id").where(exists(inner, negated: true))
        .order(by: "id").run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1)], [.integer(4)]])
  }

  @Test func `a correlated IN keeps the rows its own group yields`() throws {
    let catalog = try linked()
    // `T.id IN (SELECT S.tid FROM S WHERE S.tid = T.id)` — the inner set is
    // {T.id} exactly when some `S.tid` equals it, empty otherwise, so it keeps
    // 2 and 3 — a per-row membership, not a fixed value list.
    let inner = from("S").select("tid")
        .grouping(on: column("S.tid"), equals: outer("T", "id"))
    let rows = try from("T").select("id").where(column("id").in(inner))
        .order(by: "id").run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(2)], [.integer(3)]])
  }

  @Test func `a correlated scalar count varies by outer row`() throws {
    let catalog = try linked()
    // `(SELECT COUNT(*) FROM S WHERE S.tid = T.id)` is the GROUP size per outer
    // row — 0 for 1, 1 for 2, 2 for 3, 0 for 4 — the LINQ group-join reduction.
    // The differing counts prove per-outer-row re-execution.
    let group = from("S")
        .grouping(on: column("S.tid"), equals: outer("T", "id"))
        .select(Projection(count()))
    let rows = try from("T")
        .select(column("id").as("id"), scalar(group).as("n"))
        .order(by: "id").run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1), .integer(0)], [.integer(2), .integer(1)],
                     [.integer(3), .integer(2)], [.integer(4), .integer(0)]])
  }

  @Test func `a non-equi correlated predicate re-runs per outer row`()
      throws {
    let catalog = try linked()
    // The non-equi correlated form: `EXISTS (SELECT sid FROM S WHERE
    // S.tid > T.id)` is TRUE for the outer rows some `S.tid` exceeds — 2 and 3
    // are below the max `S.tid` (3), 1 is too, but 3 is NOT strictly exceeded
    // and 4 is not — so it keeps 1 and 2, again varying by outer row.
    let inner = from("S").select("sid")
        .correlating(where: column("S.tid") > outer("T", "id"))
    let rows = try from("T").select("id").where(exists(inner))
        .order(by: "id").run(against: catalog, routines: .standard)
    #expect(rows == [[.integer(1)], [.integer(2)]])
  }
}
