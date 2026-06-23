// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct ResolveTests {
  // Forward navigation reads the referenced tables out of `relations`, so unlike
  // the single-row `QueryTests` fixture this hand-builds a small multi-table
  // database: `TypeRef` (#1), `TypeDef` (#2), and `NestedClass` (#41). The tables
  // are dense and ordered by number so the population-count slot math resolves
  // them, and the records carry live foreign keys:
  //   TypeDef[0].Extends    = 5  → (row 1 << 2) | tag 1 ⇒ TypeRef[0] (System.Object)
  //   TypeDef[1].Extends    = 0  → the null reference
  //   NestedClass[0].Nested = 1  → a simple TypeDef index ⇒ TypeDef[0] (string0)
  private static let record: Array<UInt8> = [
    // TypeRef[0]: ResolutionScope = 0, TypeName = 1 ("Object"),
    //             TypeNamespace = 8 ("System").
    0x00, 0x00, 0x01, 0x00, 0x08, 0x00,
    // TypeDef[0]: Flags = 0x21, TypeName = 15 ("string0"), TypeNamespace = 23 ("string1"),
    //             Extends = 5 (TypeRef[0]), FieldList = 0, MethodList = 0.
    0x21, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x17, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
    // TypeDef[1]: as above but Extends = 0 (the null reference).
    0x21, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // NestedClass[0]: NestedClass = 1 (TypeDef[0]), EnclosingClass = 1.
    0x01, 0x00, 0x01, 0x00,
  ]

  // A strings heap: "\0Object\0System\0string0\0string1\0".
  private static let strings: Array<UInt8> = [
    0x00,
    0x4f, 0x62, 0x6a, 0x65, 0x63, 0x74, 0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x30, 0x00,
    0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x31, 0x00,
  ]

  private static let empty = Array<UInt8>()

  // The open tables, dense and ordered by number; each names its byte range
  // within `record`. All indices are narrow (2-byte), so the strides are the sum
  // of the columns' narrow widths.
  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6, wide: 0, stride: 6),
    Table(Metadata.Tables.TypeDef.self, rows: 2, range: 6 ..< 34, wide: 0, stride: 14),
    Table(Metadata.Tables.NestedClass.self, rows: 1, range: 34 ..< 38, wide: 0, stride: 4),
  ]

  private static let valid: UInt64 = (1 << 1) | (1 << 2) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: ResolveTests.record.span.bytes,
                          relations: ResolveTests.relations.span,
                          strings: ResolveTests.strings.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: ResolveTests.valid)
    try body(storage)
  }

  @Test("resolves a coded foreign key to the referenced row")
  func codedIndexResolution() throws {
    try ResolveTests.with { storage in
      // TypeDef[0] extends TypeRef[0] through `Extends` (ordinal 3), a
      // `TypeDefOrRef` coded index whose tag selects the `TypeRef` table.
      let source = Tuple(0, ResolveTests.relations[1], storage)
      guard let base = try source.resolve(3) else {
        Issue.record("Extends did not resolve"); return
      }
      // The resolved tuple is a TypeRef row: TypeName (1), TypeNamespace (2).
      let name = try base.string(1)
      let namespace = try base.string(2)
      #expect(name == "Object")
      #expect(namespace == "System")
    }
  }

  @Test("resolves a simple index to the referenced row")
  func simpleIndexResolution() throws {
    try ResolveTests.with { storage in
      // NestedClass[0].NestedClass (ordinal 0) is a simple `TypeDef` index;
      // resolving it lands on the six-column TypeDef row it names.
      let source = Tuple(0, ResolveTests.relations[2], storage)
      guard let parent = try source.resolve(0) else {
        Issue.record("NestedClass did not resolve"); return
      }
      let count = parent.count
      let name = try parent.string(1)
      #expect(count == Metadata.Tables.TypeDef.fields.count)
      #expect(name == "string0")
    }
  }

  @Test("resolves a null reference to nothing")
  func nullReference() throws {
    try ResolveTests.with { storage in
      // TypeDef[1].Extends is the null reference (coded row 0), so it resolves
      // to nothing.
      let source = Tuple(1, ResolveTests.relations[1], storage)
      let resolved: Bool = if let _ = try source.resolve(3) { true } else { false }
      #expect(!resolved)
    }
  }

  @Test("rejects resolving a non-foreign-key column")
  func columnKindMismatch() throws {
    ResolveTests.with { storage in
      let source = Tuple(0, ResolveTests.relations[1], storage)
      // Flags (ordinal 0) is a constant and TypeName (ordinal 1) is a string
      // heap index; neither is a foreign key.
      #expect(throws: WinMDError.InvalidColumn) { _ = try source.resolve(0) }
      #expect(throws: WinMDError.InvalidColumn) { _ = try source.resolve(1) }
    }
  }

  // A single TypeDef row whose `Extends` (ordinal 3, a `TypeDefOrRef` coded
  // index) carries an out-of-range tag. `TypeDefOrRef` names three tables and
  // uses two tag bits, so tag 3 is an unused bit pattern: `(1 << 2) | 3 = 7`
  // encodes a non-null row (1) with `tag == coded.tables.count`.
  private static let malformed: Array<UInt8> = [
    // TypeDef[0]: Flags (4 bytes) = 0, TypeName = 0, TypeNamespace = 0,
    //             Extends = 7, FieldList = 0, MethodList = 0.
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]

  @Test("rejects a coded foreign key whose tag is out of range")
  func codedIndexBadTag() throws {
    let relations: Array<Table> = [
      Table(Metadata.Tables.TypeDef.self, rows: 1, range: 0 ..< 14,
            wide: 0, stride: 14),
    ]
    let storage = Storage(bytes: ResolveTests.malformed.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: 1 << 2)
    let source = Tuple(0, relations[0], storage)
    // `Extends` names a non-null row through tag 3, which selects no table; the
    // resolve must throw rather than trap on the out-of-bounds table lookup.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(3) }
  }
}
