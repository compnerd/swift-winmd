// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.Data
import struct Foundation.URL

public class Database {
  public typealias Heaps =
      (blob: BlobsHeap, guid: GUIDHeap, string: StringsHeap)

  private let dos: DOSFile
  private let pe: PEFile
  private let cil: Assembly

  public var stream: TablesStream {
    get throws {
      try TablesStream(from: self.cil)
    }
  }

  public var decoder: DatabaseDecoder {
    get throws {
      try DatabaseDecoder(self.stream)
    }
  }

  // MARK - Heaps

  public var blobs: BlobsHeap {
    get throws {
      try BlobsHeap(from: self.cil)
    }
  }

  public var guids: GUIDHeap {
    get throws {
      try GUIDHeap(from: self.cil)
    }
  }

  public var strings: StringsHeap {
    get throws {
      try StringsHeap(from: self.cil)
    }
  }

  // MARK - Tables

  public var tables: [WinMD.Table] {
    get throws {
      try self.stream.Tables
    }
  }

  // MARK - Initializers

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

  // MARK - subscripting

  public func rows<Table: WinMD.Table>(of table: Table.Type,
                                       from begin: Int = 0,
                                       to end: Int? = nil) throws
      -> TableIterator<Table> {
    guard let table = try tables.first(where: { $0 is Table }) as? Table else {
      throw WinMDError.TableNotFound
    }
    return TableIterator<Table>(self, table, from: begin, to: end)
  }
}
