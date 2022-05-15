// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.Data
import struct Foundation.URL

public class Database {
  public typealias Heaps =
      (blob: BlobsHeap, guid: GUIDHeap, string: StringsHeap)

  public let dos: DOSFile
  public let pe: PEFile
  public let cil: Assembly

  public private(set) lazy var stream: Result<TablesStream, Error> =
      Result { try TablesStream(from: self.cil) }
  public private(set) lazy var decoder: Result<DatabaseDecoder, Error> =
      Result { try DatabaseDecoder(self.stream.get()) }

  public private(set) lazy var blobs: Result<BlobsHeap, Error> =
      Result { try BlobsHeap(from: self.cil) }
  public private(set) lazy var guids: Result<GUIDHeap, Error> =
      Result { try GUIDHeap(from: self.cil) }
  public private(set) lazy var strings: Result<StringsHeap, Error> =
      Result { try StringsHeap(from: self.cil) }

  public lazy var tables: Result<[WinMD.Table], Error> =
      Result { try self.stream.get().Tables }

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

  public func rows<Table: WinMD.Table>(of table: Table.Type) throws -> TableIterator<Table> {
    guard let table = try tables.get().first(where: { $0 is Table }) as? Table else {
      throw WinMDError.TableNotFound
    }
    let heaps: Heaps =
        try (blob: blobs.get(), guid: guids.get(), string: strings.get())
    return try TableIterator<Table>(table, heaps, decoder.get())
  }
}
