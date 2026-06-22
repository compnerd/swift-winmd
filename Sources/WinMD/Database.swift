// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.Data
import struct Foundation.URL

public class Database {
  /// The tables stream of the database.
  ///
  /// Locating a stream means parsing the metadata stream headers, so resolving
  /// it on each access would re-parse those headers every time. It is invariant
  /// for the file's lifetime, so it is located once when the database is opened.
  public let stream: TablesStream

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

  // The heaps, located once when the database is opened. A heap is invariant
  // for the file's lifetime, and an absent heap fails the open rather than being
  // tolerated and surfaced as an error on use.
  public let blobs: BlobsHeap
  public let guids: GUIDHeap
  public let strings: StringsHeap

  // MARK: - Tables

  public var tables: Array<Table> {
    relations
  }

  // MARK: - Initializers

  private init(data: Array<UInt8>) throws(WinMDError) {
    let dos = try DOSFile(from: data)
    let pe = try PEFile(from: dos)
    let cil = try Assembly(from: pe)

    self.stream = try TablesStream(from: cil)
    self.decoder = DatabaseDecoder(stream)
    self.relations = try stream.relations(decoder)

    self.blobs = try BlobsHeap(from: cil)
    self.guids = try GUIDHeap(from: cil)
    self.strings = try StringsHeap(from: cil)
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
                                        to end: Int? = nil) throws(WinMDError)
      -> TableIterator<Schema> {
    guard let table =
        relations.first(where: { $0.number == Schema.number }) else {
      throw .TableNotFound
    }
    return TableIterator<Schema>(self, table, from: begin, to: end)
  }
}
