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
    guard let database = try? Database(at: options.database.url) else {return }
    print("Database: \(options.database.url.path)")

    guard let tables = TablesStream(from: database.cil) else {
      throw ValidationError("No tables stream found.")
    }
    guard let blobs = BlobsHeap(from: database.cil) else {
      throw ValidationError("No blobs heap found.")
    }
    guard let strings = StringsHeap(from: database.cil) else {
      throw ValidationError("No strings heap found.")
    }
    guard let guids = GUIDHeap(from: database.cil) else {
      throw ValidationError("No GUID heap found.")
    }

    let decoder = DatabaseDecoder(tables)
    var reader = RecordReader(decoder: decoder,
                              heaps: RecordReader.HeapRefs(blob: blobs,
                                                           guid: guids,
                                                           string: strings))

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
    guard let database = try? Database(at: options.database.url) else { return }

    guard let tables = TablesStream(from: database.cil) else {
      throw ValidationError("No tables stream found.")
    }
    guard let blobs = BlobsHeap(from: database.cil) else {
      throw ValidationError("No blobs heap found.")
    }
    guard let strings = StringsHeap(from: database.cil) else {
      throw ValidationError("No strings heap found.")
    }
    guard let guids = GUIDHeap(from: database.cil) else {
      throw ValidationError("No GUID heap found.")
    }

    let decoder = DatabaseDecoder(tables)
    var reader = RecordReader(decoder: decoder,
                              heaps: RecordReader.HeapRefs(blob: blobs,
                                                           guid: guids,
                                                           string: strings))

    guard let typedef = try tables.Tables.first(where: { $0 is Metadata.Tables.TypeDef }) else {
      throw ValidationError("No TypeDef table found.")
    }

    var namespaces: Set<String> = []
    for record in reader.rows(typedef) {
      let namespace = strings[record.TypeNamespace]
      if !namespace.isEmpty {
        namespaces.insert(namespace)
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
