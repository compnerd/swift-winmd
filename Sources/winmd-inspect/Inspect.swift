// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import struct Foundation.Data

internal import ArgumentParser
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
    let data = try Data(contentsOf: options.database.url,
                        options: .alwaysMapped)
    let database = try Database(data.span.bytes)

    var namespaces = Set<String>()
    let rows = try database.rows(of: Metadata.Tables.TypeDef.self)
    for i in 0 ..< rows.count {
      let row = rows[i]!
      namespaces.insert(row.TypeNamespace)
    }

    for namespace in namespaces.sorted() {
      print(namespace)
    }
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
