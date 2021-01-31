/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 **/

import Foundation

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
    // It's rather a pain to read data from a file without using `Data`, but at any point after that it's usually a bit
    // easier to work with a straight array of bytes. Unfortunately, the conversion is likely to incur a pointless copy.
    try self.init(data: Array(Data(contentsOf: path, options: .alwaysMapped)))
  }

  public func dump() {
    let metadata = self.cil.Metadata
    
    print("Version: \(metadata.Version)")
    print("Streams: \(metadata.Streams)")
    metadata.StreamHeaders.forEach { print($0) }

    if let stream = metadata.stream(named: Metadata.Stream.Tables) {
      let ts = TablesStream(data: stream)

      print("MajorVersion: \(String(ts.MajorVersion, radix: 16))")
      print("MinorVersion: \(String(ts.MinorVersion, radix: 16))")
      print("Tables:\n\(ts.Tables.map { "  - \($0)" }.joined(separator: "\n"))")
    }
  }
}
