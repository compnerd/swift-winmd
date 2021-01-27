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

  private init(data: Data) throws {
    dos = DOSFile(data: data)
    try dos.validate()

    pe = PEFile(from: dos)
    try pe.validate()

    cil = try Assembly(from: pe)
    try cil.validate()
  }

  public convenience init(at path: URL) throws {
    let buffer: Data = try NSData(contentsOf: path, options: .alwaysMapped) as Data
    try self.init(data: buffer)
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
