// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import struct Foundation.Data

internal import ArgumentParser
internal import SQL
internal import WinMD

/// The `query` subcommand: run a SQL query against a metadata database.
///
/// The parsed `SELECT` is handed to the database-agnostic `Engine`, which plans
/// and executes it over the WinMD database adapted as a `SQL.Catalog`: a
/// relation, a foreign-key join (`ON child.fk = parent.rowid`), or a list join
/// (`ON child.parent = parent.rowid`). The engine yields typed `Value` records;
/// this renders each as a tab-separated line. There is no bespoke predicate,
/// planner, or join here — the engine owns all of it.
internal struct Query: ParsableCommand {
  internal static var configuration: CommandConfiguration {
    CommandConfiguration(commandName: "query",
                         abstract: "Query the database with SQL.")
  }

  @Argument(help: "The SQL query to run against the database.")
  internal var sql: String

  @OptionGroup
  internal var options: InspectOptions

  internal func run() throws {
    // The caller owns the mapping; it must outlive the database, which is a
    // borrowed view over it.
    let data = try Data(contentsOf: options.database.url,
                        options: .alwaysMapped)
    let database = try Database(data.span.bytes)

    let statement = try Statement(parsing: sql)

    // The engine plans and executes over the WinMD database adapted as a
    // catalog, returning the projected, filtered, and ordered rows as typed
    // values.
    let rows = switch statement {
    case let .select(select):
      try Engine.run(select, database.storage)
    }
    for row in rows {
      print(row.map(Query.render).joined(separator: "\t"))
    }
  }

  /// Renders a typed cell value to its display string: text verbatim, an
  /// integer as its decimal spelling.
  private static func render(_ value: Value) -> String {
    switch value {
    case let .integer(integer):
      "\(integer)"
    case let .text(text):
      text
    }
  }
}
