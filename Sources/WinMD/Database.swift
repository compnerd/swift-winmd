// Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import struct Foundation.Data
import struct Foundation.URL

public class Database {
  public typealias Heaps =
      (blob: BlobsHeap, guid: GUIDHeap, string: StringsHeap)

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

  // The heaps, located once when the database is opened.  A heap is absent when
  // its stream is, in which case the corresponding accessor throws on use rather
  // than failing the open.
  private let blob: BlobsHeap?
  private let guid: GUIDHeap?
  private let string: StringsHeap?

  // MARK: - Heaps

  public var blobs: BlobsHeap {
    get throws(WinMDError) {
      guard let blob = blob else { throw .BlobsHeapNotFound }
      return blob
    }
  }

  public var guids: GUIDHeap {
    get throws(WinMDError) {
      guard let guid = guid else { throw .GUIDHeapNotFound }
      return guid
    }
  }

  public var strings: StringsHeap {
    get throws(WinMDError) {
      guard let string = string else { throw .StringsHeapNotFound }
      return string
    }
  }

  // MARK: - Tables

  public var tables: Array<Table> {
    relations
  }

  // MARK: - Initializers

  private init(data: Array<UInt8>) throws {
    let dos = try DOSFile(from: data)
    let pe = try PEFile(from: dos)
    let cil = try Assembly(from: pe)

    self.stream = try TablesStream(from: cil)
    self.decoder = DatabaseDecoder(stream)
    self.relations = try stream.relations(decoder)

    self.blob = try? BlobsHeap(from: cil)
    self.guid = try? GUIDHeap(from: cil)
    self.string = try? StringsHeap(from: cil)
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
