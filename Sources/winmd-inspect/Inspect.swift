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
    // Zero namespaces must yield zero lines, not one blank line, so scripts
    // reading a namespace per line never see a spurious empty entry.
    let out = try PrintNamespaces.namespaces(database.storage)
    if !out.isEmpty { print(out) }
  }

  /// The database's distinct namespaces as a plain one-per-line list, ascending
  /// — a `SELECT DISTINCT … ORDER BY` deduplicates and sorts them, the engine's
  /// own dedup replacing the hand-rolled `Set` + `sorted()`.
  ///
  /// The result is a plain namespace-per-line list scripts parse, NOT the boxed
  /// table `Shell.execute` frames a row result as (borders and a `TypeNamespace`
  /// header): each row's single cell prints on its own line, unframed, so this
  /// runs the DISTINCT query directly rather than through the shell.
  internal static func namespaces(_ storage: borrowing WinMD.Storage)
      throws -> String {
    var session = Session(storage)
    let rows = try session.run(
        "SELECT DISTINCT TypeNamespace FROM TypeDef ORDER BY TypeNamespace")
    return rows.map { $0[0].display }.joined(separator: "\n")
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
