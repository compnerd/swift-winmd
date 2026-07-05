// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import struct Foundation.Data

internal import ArgumentParser
internal import SQL
internal import WinMD

struct Dump: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(abstract: "Dump the contents of the database.")
  }

  @OptionGroup
  var options: InspectOptions

  func run() throws {
    // The caller owns the mapping; it must outlive the database, which is a
    // borrowed view over it.
    let data = try Data(contentsOf: options.database.url,
                        options: .alwaysMapped)
    let database = try Database(data.span.bytes)

    print("Database: \(options.database.url.path)")

    let stream = database.stream
    print("MajorVersion: \(String(stream.MajorVersion, radix: 16))")
    print("MinorVersion: \(String(stream.MinorVersion, radix: 16))")

    print("Tables:")
    for table in database.tables {
      print("  - \(table)")
      let rows = database.rows(of: table)
      for offset in 0 ..< rows.count {
        if let row = rows[offset] { print("    - \(row.debugDescription)") }
      }
    }
  }
}

struct PrintNamespaces: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(abstract: "Print namespaces referenced in the database.")
  }

  @OptionGroup
  var options: InspectOptions

  func run() throws {
    // The caller owns the mapping; it must outlive the database, which is a
    // borrowed view over it.
    let data = try Data(contentsOf: options.database.url,
                        options: .alwaysMapped)
    let database = try Database(data.span.bytes)
    // One line per namespace row: no rows prints nothing, while a lone
    // empty-string namespace (the global namespace) prints one blank line —
    // outcomes a joined string cannot tell apart, so scripts read exactly one
    // line per namespace and none for a namespace-free database.
    for namespace in try PrintNamespaces.namespaces(database.storage) {
      print(namespace)
    }
  }

  /// The database's distinct namespaces, ascending, one element per row — a
  /// `SELECT DISTINCT … ORDER BY` deduplicates and sorts them, the engine's own
  /// dedup replacing the hand-rolled `Set` + `sorted()`.
  ///
  /// An element per row, rather than a joined string, keeps the zero-rows case
  /// (a namespace-free database) distinct from a single empty-string namespace:
  /// the former yields no lines, the latter one blank line, whereas a
  /// newline-join collapses both to the empty string. Each element is a plain
  /// namespace scripts parse a line at a time, NOT the boxed table
  /// `Shell.execute` frames a row result as (borders and a `TypeNamespace`
  /// header), so this runs the DISTINCT query directly rather than the shell.
  internal static func namespaces(_ storage: borrowing WinMD.Storage)
      throws -> Array<String> {
    var session = Session(storage)
    let rows = try session.run(
        "SELECT DISTINCT TypeNamespace FROM TypeDef ORDER BY TypeNamespace")
    return rows.map { $0[0].display }
  }
}

struct InspectOptions: ParsableArguments {
  // "C:\\Windows\\System32\\WinMetadata\\Windows.Foundation.winmd"
  @Argument
  var database: FileURL
}

@main
struct Inspect: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(abstract: "Windows Metadata File Inspection Utility",
                         subcommands: [
                           Dump.self,
                           PrintNamespaces.self,
                           Query.self,
                         ],
                         defaultSubcommand: Query.self)
  }

  @OptionGroup
  var options: InspectOptions

  func validate() throws {
    guard options.database.existsOnDisk && options.database.isRegularFile else {
      throw ValidationError("Database must be an existing file.")
    }
  }
}
