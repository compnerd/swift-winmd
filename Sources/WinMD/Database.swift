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

  /// The decoded physical schema (index and column widths) of the database.
  ///
  /// This is invariant for the lifetime of the database — it depends only on
  /// which tables are present and their row counts — so it is decoded once when
  /// the database is opened rather than rebuilt on every record access.
  public let decoder: DatabaseDecoder

  /// The open tables of the database.
  ///
  /// The tables present in a database and their record layouts are fixed once
  /// the file is mapped, so they are opened once when the database is opened and
  /// reused for every query rather than reconstructed on each access.
  private let relations: Array<Table>

  public var stream: TablesStream {
    get throws {
      try TablesStream(from: cil)
    }
  }

  // MARK: - Heaps

  public var blobs: BlobsHeap {
    get throws {
      try BlobsHeap(from: cil)
    }
  }

  public var guids: GUIDHeap {
    get throws {
      try GUIDHeap(from: cil)
    }
  }

  public var strings: StringsHeap {
    get throws {
      try StringsHeap(from: cil)
    }
  }

  // MARK: - Tables

  public var tables: Array<Table> {
    relations
  }

  // MARK: - Initializers

  private init(data: Array<UInt8>) throws {
    self.dos = try DOSFile(from: data)
    self.pe = try PEFile(from: dos)
    self.cil = try Assembly(from: pe)

    let stream = try TablesStream(from: self.cil)
    self.decoder = DatabaseDecoder(stream)
    self.relations = try stream.relations(self.decoder)
  }

  public convenience init(at path: URL) throws {
    // Although it is inconvenient to read data from a file without using
    // `Data`, once the data has been read, it is usually easier to work with a
    // byte array representation. Unfortunately, this conversion is likely to
    // incur a pointless copy.
    try self.init(data: Array(Data(contentsOf: path, options: .alwaysMapped)))
  }

  // MARK: - subscripting

  public func rows<Schema: TableSchema>(of schema: Schema.Type,
                                        from begin: Int = 0,
                                        to end: Int? = nil) throws
      -> TableIterator<Schema> {
    guard let table =
        relations.first(where: { $0.number == Schema.number }) else {
      throw WinMDError.TableNotFound
    }
    return TableIterator<Schema>(self, table, from: begin, to: end)
  }
}
