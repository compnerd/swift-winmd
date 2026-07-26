// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import SQLEngine
import func SQLTestSupport.parse

// MARK: - Parser recursion-depth guard

/// Pathologically nested input faults `54001` (statement too complex) at the
/// depth guard rather than overrunning the native stack. The guard trips at the
/// nesting limit, so input nested far past it recurses only ~limit frames
/// before faulting — the deep cases here parse to a clean fault, never a crash.
struct ParserDepthTests {
  private func sqlstate(parsing sql: String) -> String? {
    do { _ = try parse(query: sql); return nil }
    catch let error as SQLError { return error.sqlstate }
    catch { return nil }
  }

  @Test func `deeply nested input faults 54001, not a stack overrun`() throws {
    // One case per recursion cycle the guard bounds: expression parentheses,
    // predicate parentheses, a nested subquery, and nested GROUPING SETS. A
    // thousand levels each — far past the limit — so a missing guard would
    // crash the process rather than fault.
    let deep = 1000
    let opens = String(repeating: "(", count: deep)
    let closes = String(repeating: ")", count: deep)
    #expect(sqlstate(parsing: "SELECT \(opens)1\(closes)") == "54001")
    #expect(sqlstate(parsing: "SELECT 1 FROM t WHERE \(opens)1 = 1\(closes)")
            == "54001")
    #expect(sqlstate(parsing: "SELECT * FROM \(opens)SELECT 1\(closes) AS d")
            == "54001")
    #expect(sqlstate(parsing: "SELECT a FROM t GROUP BY "
            + String(repeating: "GROUPING SETS (", count: deep) + "a" + closes)
            == "54001")
    // A prefix `NOT` run is parsed iteratively, but each `NOT` stacks a `.not`
    // node compile/execute later recurse over, so it is bounded the same way: a
    // thousand `NOT`s fault rather than build a stack-overflowing predicate.
    #expect(sqlstate(parsing: "SELECT 1 FROM t WHERE "
            + String(repeating: "NOT ", count: deep) + "1 = 1") == "54001")
  }

  @Test func `a modestly nested query parses without tripping the limit`()
      throws {
    // A handful of nesting levels — well under the limit — parses normally, so
    // the guard never bites a real query. A flat chain iterates rather than
    // recurses, so its length costs no depth.
    _ = try parse(query: "SELECT " + String(repeating: "(", count: 10) + "1"
                         + String(repeating: ")", count: 10))
    _ = try parse(query:
        "SELECT * FROM (SELECT * FROM (SELECT 1) AS a) AS b")
    _ = try parse(query: "SELECT 1 FROM t WHERE ((1 = 1 AND 2 = 2) OR (3 = 3))")
    _ = try parse(query:
        "SELECT 1 FROM t WHERE x IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)")
    _ = try parse(query: "SELECT 1 FROM t WHERE NOT NOT NOT 1 = 1")
  }
}
