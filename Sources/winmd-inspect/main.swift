// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import ArgumentParser
import WinMD

private func dump(database: WinMD.Database) throws {
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

@main
struct Inspect: ParsableCommand {
  @Argument
  var database: FileURL

  @Flag
  var dump: Bool = false

  func validate() throws {
    guard self.database.existsOnDisk && self.database.isRegularFile else {
      throw ValidationError("Database must be an existing file.")
    }
  }

  func run() throws {
    // "C:\\Windows\\System32\\WinMetadata\\Windows.Foundation.winmd"
    print("Database: \(self.database.url.path)")
    if let database = try? WinMD.Database(at: self.database.url) {
      if dump { try winmd_inspect.dump(database: database) }
    }
  }
}
