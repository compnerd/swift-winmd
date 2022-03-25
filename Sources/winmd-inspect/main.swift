// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import ArgumentParser
import WinMD

private func open(_ path: FileURL) throws -> (Database, DatabaseDecoder, TablesStream, RecordReader) {
  let database = try Database(at: path.url)

  let tables = try TablesStream(from: database.cil)
  let blobs = try BlobsHeap(from: database.cil)
  let strings = try StringsHeap(from: database.cil)
  let guids = try GUIDHeap(from: database.cil)

  let decoder = DatabaseDecoder(tables)
  let reader = RecordReader(decoder: decoder,
                            heaps: RecordReader.HeapRefs(blob: blobs,
                                                          guid: guids,
                                                          string: strings))

  return (database, decoder, tables, reader)
}

struct Dump: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(abstract: "Dump the contents of the database.")
  }

  @OptionGroup
  var options: InspectOptions

  func run() throws {
    let tables: TablesStream
    var reader: RecordReader

    (_, _, tables, reader) = try open(options.database)

    print("Database: \(options.database.url.path)")
    print("MajorVersion: \(String(tables.MajorVersion, radix: 16))")
    print("MinorVersion: \(String(tables.MinorVersion, radix: 16))")
    print("Tables:")
    for table in try tables.Tables {
      print("  - \(table)")
      for record in reader.rows(table) {
        print("    - \(record)")
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
    let tables: TablesStream
    var reader: RecordReader

    (_, _, tables, reader) = try open(options.database)

    guard let typedef = try tables.Tables.first(where: { $0 is Metadata.Tables.TypeDef }) else {
      throw ValidationError("No TypeDef table found.")
    }

    var namespaces: Set<String> = []
    for record in reader.rows(typedef) {
      if let namespace = reader.heaps?.string[record.TypeNamespace] {
        if !namespace.isEmpty {
          namespaces.insert(namespace)
        }
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
