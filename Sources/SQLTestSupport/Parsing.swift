// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SQLEngine
import Testing

/// Parses `text` as a single, non-compound `SELECT`, recording a test issue
/// before rejecting any other statement or compound-query shape.
public func parse(select text: String,
                  location: Testing.SourceLocation = #_sourceLocation)
    throws(SQLError) -> Select {
  guard case let .select(.select(select)) = try Statement(parsing: text) else {
    Issue.record("expected a single SELECT statement",
                 sourceLocation: location)
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return select
}

/// Parses `text` as a query, recording a test issue before rejecting a
/// non-query statement.
public func parse(query text: String,
                  location: Testing.SourceLocation = #_sourceLocation)
    throws(SQLError) -> Query {
  guard case let .select(query) = try Statement(parsing: text) else {
    Issue.record("expected a SELECT statement", sourceLocation: location)
    throw SQLError.incomplete(expected: "a SELECT statement")
  }
  return query
}

extension FixtureCatalog {
  /// Resolves the single output type of `sql`, recording an issue if it does
  /// not project exactly one column.
  public borrowing func type(of sql: String, routines: Routines = [:],
                             location: Testing.SourceLocation =
                                 #_sourceLocation)
      throws(SQLError) -> ValueType {
    let columns = try columns(of: parse(query: sql, location: location),
                              routines: routines)
    #expect(columns.count == 1, sourceLocation: location)
    return columns[0].type
  }
}
