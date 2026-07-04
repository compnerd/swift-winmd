// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQL
import Testing

/// Expectation helpers that run a SQL query against a fixture catalog and check
/// its rows, forwarding the swift-testing source location so a failure points
/// at the call site rather than into this file.
///
/// `catalog.expect(_:yields:)` runs the query and checks the projected rows
/// against bare Swift literals a `ValueConvertible` lifts into `Value`s;
/// `catalog.empty(_:)` checks the query returns nothing; `catalog.expect(_:
/// fails:)` checks the query raises a given `SQLError`; and
/// `catalog.expect(_:equals:)` checks two queries return the same rows — the
/// pervasive "seek result equals scan result" idiom. Each is a `borrowing`
/// method on the catalog under test, takes a `location` defaulting to the
/// caller's, and runs through the engine's public `Catalog.run`, so the
/// framework needs no `@testable` import.

/// Parses `sql` to a `Query`, trapping on any other statement.
private func query(_ sql: String) throws(SQLError) -> Query {
  guard case let .select(query) = try Statement(parsing: sql) else {
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

extension Catalog where Self: ~Escapable {
  /// Runs `sql` against this catalog through the given routines and bindings.
  private borrowing func run(_ sql: String, routines: Routines,
                             bindings: Bindings)
      throws(SQLError) -> Array<Array<Value>> {
    try run(query(sql), routines, bindings: bindings)
  }

  /// Checks `sql` run against this catalog yields exactly `rows`, each row a
  /// list of Swift literals lifted into `Value`s.
  public borrowing func expect(_ sql: String,
      yields rows: Array<Array<(any ValueConvertible)?>>,
      routines: Routines = [:], bindings: Bindings = [:],
      location: Testing.SourceLocation = #_sourceLocation) throws {
    let expected = rows.map { $0.map { $0?.value ?? .null } }
    let actual = try run(sql, routines: routines, bindings: bindings)
    #expect(actual == expected, sourceLocation: location)
  }

  /// Checks `sql` run against this catalog yields no rows.
  public borrowing func empty(_ sql: String,
      routines: Routines = [:], bindings: Bindings = [:],
      location: Testing.SourceLocation = #_sourceLocation) throws {
    let actual = try run(sql, routines: routines, bindings: bindings)
    #expect(actual.isEmpty, sourceLocation: location)
  }

  /// Checks `sql` run against this catalog raises `error`.
  ///
  /// The run is eager rather than wrapped in `#expect(throws:)`'s closure — a
  /// borrowed `~Escapable` catalog cannot be captured by an escaping closure —
  /// so it catches the outcome and asserts on it, still reporting at the call
  /// site.
  public borrowing func expect(_ sql: String, fails error: SQLError,
      routines: Routines = [:], bindings: Bindings = [:],
      location: Testing.SourceLocation = #_sourceLocation) {
    let raised: SQLError?
    do {
      _ = try run(sql, routines: routines, bindings: bindings)
      raised = nil
    } catch let fault {
      raised = fault
    }
    #expect(raised == error, sourceLocation: location)
  }

  /// Checks two queries run against this catalog yield the same rows — the
  /// seek / scan (or hash / seek) equivalence idiom.
  public borrowing func expect(_ lhs: String, equals rhs: String,
      routines: Routines = [:], bindings: Bindings = [:],
      location: Testing.SourceLocation = #_sourceLocation) throws {
    let left = try run(lhs, routines: routines, bindings: bindings)
    let right = try run(rhs, routines: routines, bindings: bindings)
    #expect(left == right, sourceLocation: location)
  }
}
