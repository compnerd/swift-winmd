// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import ArgumentParser
import WinMD

struct Dump: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(abstract: "Dump the contents of the database.")
  }

  @OptionGroup
  var options: InspectOptions

  func run() throws {
    let database = try Database(at: options.database.url)

    print("Database: \(options.database.url.path)")

    let stream = try database.stream.get()
    print("MajorVersion: \(String(stream.MajorVersion, radix: 16))")
    print("MinorVersion: \(String(stream.MinorVersion, radix: 16))")

    let heaps: Database.Heaps =
        try (blob: database.blobs.get(), guid: database.guids.get(), string: database.strings.get())

    print("Tables:")
    for table in try database.tables.get() {
      print("  - \(table)")
      for row in try TableIterator(table, database.decoder.get(), heaps) {
        print("    - \(row)")
      }
    }
  }
}

struct PrintNamespaces: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(abstract: "Print namespaces referenced in the databse")
  }

  @OptionGroup
  var options: InspectOptions

  func run() throws {
    let database = try Database(at: options.database.url)

    var namespaces: Set<String> = []
    for row in try database.rows(of: Metadata.Tables.TypeDef.self) {
      if !row.TypeNamespace.isEmpty {
        namespaces.insert(row.TypeNamespace)
      }
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
                         ])
  }

  @OptionGroup
  var options: InspectOptions

  func validate() throws {
    guard options.database.existsOnDisk && options.database.isRegularFile else {
      throw ValidationError("Database must be an existing file.")
    }
  }
}
