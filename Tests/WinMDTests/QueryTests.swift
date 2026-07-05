// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct QueryTests {
  // A synthetic, narrow `TypeDef` row backed by hand-built spans. The schema's
  // narrow stride is 14: Flags (4) + five 2-byte indices. The cells are laid
  // out so that TypeName resolves to "string0" and TypeNamespace to "string1" out of a
  // tiny strings heap.
  //   Flags         = 0x00000021
  //   TypeName      = 1  ("string0")
  //   TypeNamespace = 9  ("string1")
  //   Extends       = 0
  //   FieldList     = 0
  //   MethodList    = 0
  private static let record: Array<UInt8> = [
    0x21, 0x00, 0x00, 0x00,
    0x01, 0x00,
    0x09, 0x00,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
  ]

  // A strings heap: "\0string0\0string1\0" — "string0" at offset 1, "string1" at offset 9.
  private static let strings: Array<UInt8> = [
    0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x30, 0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x31, 0x00,
  ]

  private static let empty = Array<UInt8>()
  private static let relations = Array<Table>()

  private static func with(_ body: (borrowing Tuple) -> Void) {
    let record = QueryTests.record.span.bytes
    let table = Table(Metadata.Tables.TypeDef.self, rows: 1,
                      range: 0 ..< record.byteCount, wide: 0, stride: 14)
    let storage = Storage(bytes: record, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: 0, sorted: 0)
    body(Tuple(0, table, storage))
  }

  private static func scan(_ body: (borrowing Storage, Table) -> Void) {
    let record = QueryTests.record.span.bytes
    let table = Table(Metadata.Tables.TypeDef.self, rows: 1,
                      range: 0 ..< record.byteCount, wide: 0, stride: 14)
    let storage = Storage(bytes: record, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: 0, sorted: 0)
    body(storage, table)
  }

  @Test("resolves column ordinals by name")
  func ordinalResolution() {
    QueryTests.with { tuple in
      #expect(tuple.ordinal(for: "Flags") == 0)
      #expect(tuple.ordinal(for: "TypeName") == 1)
      #expect(tuple.ordinal(for: "TypeNamespace") == 2)
      #expect(tuple.ordinal(for: "MethodList") == 5)
      #expect(tuple.ordinal(for: "DoesNotExist") == nil)
    }
  }

  @Test("reads string cells through the strings heap")
  func stringResolution() throws {
    QueryTests.with { tuple in
      #expect((try? tuple.string(1)) == "string0")
      #expect((try? tuple.string(2)) == "string1")
    }
  }

  @Test("throws on a malformed strings-heap entry rather than trapping")
  func malformedStringEntry() {
    // A record whose TypeName cell points one past the heap end, and whose
    // TypeNamespace cell points at an unterminated run that reaches the heap
    // end without a NUL. Both must throw `.BadImageFormat` through
    // `Tuple.string(_:)` rather than trapping.
    //   TypeName      = 9  (one past the 9-byte heap)
    //   TypeNamespace = 1  (an unterminated run to the heap end)
    let record: Array<UInt8> = [
      0x21, 0x00, 0x00, 0x00,
      0x09, 0x00,
      0x01, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
    ]
    // "\0string0" - nine bytes, no trailing NUL, so a read from offset 1
    // runs to the heap end without a terminator.
    let strings: Array<UInt8> = [
      0x00,
      0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x30,
    ]
    let empty = Array<UInt8>()
    let relations = Array<Table>()
    let span = record.span.bytes
    let table = Table(Metadata.Tables.TypeDef.self, rows: 1,
                      range: 0 ..< span.byteCount, wide: 0, stride: 14)
    let storage = Storage(bytes: span, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: 0, sorted: 0)
    let tuple = Tuple(0, table, storage)
    // An offset past the heap end.
    #expect(throws: WinMDError.BadImageFormat) { _ = try tuple.string(1) }
    // A run with no NUL terminator before the heap end.
    #expect(throws: WinMDError.BadImageFormat) { _ = try tuple.string(2) }
  }

  @Test("rejects a heap read on the wrong column kind")
  func heapKindMismatch() {
    QueryTests.with { tuple in
      // Field 0 (Flags) is a constant, not a string heap index.
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.string(0) }
      // A string column is not a blob or GUID column.
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.blob(1) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.guid(1) }
      // Field 3 (Extends) is a coded index, not any heap kind.
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.string(3) }
    }
  }

  @Test("rejects an out-of-bounds column ordinal without trapping")
  func ordinalBounds() {
    QueryTests.with { tuple in
      // The throwing accessors index the schema's fields to recover a column's
      // type, so an ordinal outside `0 ..< count` would trap on that lookup
      // before the kind guard could run. A negative and a one-past-the-end
      // ordinal must both throw `.InvalidColumn` rather than trap. The TypeDef
      // fixture has six columns, so `tuple.count` is the first out-of-range
      // ordinal.
      let past = tuple.count
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.string(-1) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.string(past) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.blob(-1) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.blob(past) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.guid(-1) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.guid(past) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.resolve(-1) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try tuple.resolve(past) }
      // A valid in-range column still reads.
      #expect((try? tuple.string(1)) == "string0")
    }
  }

  @Test("a scan yields nil for an out-of-range offset on both ends")
  func scanBounds() {
    // The `Scan.element(_:)` contract is to return `nil` for any offset
    // outside `0 ..< count`. The subscript the conformances delegate to must
    // reject a negative offset as well as one at or past `count`; a negative
    // offset would otherwise address a row before the table's start.
    QueryTests.scan { storage, table in
      let cursor = Cursor(storage, table)
      #expect(cursor.count == 1)
      // `element` yields a `~Escapable` `Tuple?`, which cannot escape the
      // borrow to be compared with `nil`; bind it in place and report only
      // its presence as an escapable `Bool`.
      let before: Bool = if let _ = cursor.element(-1) { true } else { false }
      let past: Bool =
          if let _ = cursor.element(cursor.count) { true } else { false }
      let first: Bool = if let _ = cursor.element(0) { true } else { false }
      #expect(before == false)
      #expect(past == false)
      #expect(first == true)
    }
    QueryTests.scan { storage, table in
      let rows = TableIterator<Metadata.Tables.TypeDef>(storage, table)
      #expect(rows.count == 1)
      let before: Bool = if let _ = rows.element(-1) { true } else { false }
      let past: Bool =
          if let _ = rows.element(rows.count) { true } else { false }
      let first: Bool = if let _ = rows.element(0) { true } else { false }
      #expect(before == false)
      #expect(past == false)
      #expect(first == true)
    }
  }
}
