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
    tables.forEach {
      print("  - \($0)")
      for record in reader.rows($0) {
        print("    - \(record)")
      }
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
