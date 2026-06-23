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
                          guid: empty.span.bytes, valid: 0)
    body(Tuple(0, table, storage))
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
                          guid: empty.span.bytes, valid: 0)
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
}
