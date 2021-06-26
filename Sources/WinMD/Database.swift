// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.Data
import struct Foundation.URL

public class Database {
  private let dos: DOSFile
  private let pe: PEFile
  private let cil: Assembly

  private init(data: [UInt8]) throws {
    self.dos = try DOSFile(from: data)
    self.pe = try PEFile(from: self.dos)
    self.cil = try Assembly(from: self.pe)
  }

  public convenience init(at path: URL) throws {
    // Although it is inconvenient to read data from a file without using
    // `Data`, once the data has been read, it is usually easier to work with a
    // byte array representation.  Unfortunately, this conversion is likely to
    // incur a pointless copy.
    try self.init(data: Array(Data(contentsOf: path, options: .alwaysMapped)))
  }

  public func dump() {
    let metadata = self.cil.Metadata

    print("Version: \(metadata.Version)")
    print("Streams: \(metadata.Streams)")
    metadata.StreamHeaders.forEach { print("  - \($0)") }

    if let tables = TablesStream(from: self.cil), let _ = BlobsHeap(from: self.cil),
        let _ = StringsHeap(from: self.cil), let _ = GUIDHeap(from: self.cil) {
      print("MajorVersion: \(String(tables.MajorVersion, radix: 16))")
      print("MinorVersion: \(String(tables.MinorVersion, radix: 16))")
      print("Tables:")
      tables.Tables.forEach { print("  - \($0)") }
    }
  }
}
