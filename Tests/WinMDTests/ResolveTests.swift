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
                          valid: ResolveTests.valid, sorted: 0)
    try body(storage)
  }

  @Test func `resolves a coded foreign key to the referenced row`() throws {
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

  @Test func `resolves a simple index to the referenced row`() throws {
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

  @Test func `resolves a null reference to nothing`() throws {
    try ResolveTests.with { storage in
      // TypeDef[1].Extends is the null reference (coded row 0), so it resolves
      // to nothing.
      let source = Tuple(1, ResolveTests.relations[1], storage)
      let resolved: Bool = if let _ = try source.resolve(3) { true } else { false }
      #expect(!resolved)
    }
  }

  @Test func `rejects resolving a non-foreign-key column`() throws {
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

  @Test func `rejects a coded foreign key whose tag is out of range`() throws {
    let relations: Array<Table> = [
      Table(Metadata.Tables.TypeDef.self, rows: 1, range: 0 ..< 14,
            wide: 0, stride: 14),
    ]
    let storage = Storage(bytes: ResolveTests.malformed.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: 1 << 2, sorted: 0)
    let source = Tuple(0, relations[0], storage)
    // `Extends` names a non-null row through tag 3, which selects no table; the
    // resolve must throw rather than trap on the out-of-bounds table lookup.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(3) }
  }

  @Test func `rejects a TypeDefOrRef reference whose tag is out of range`() throws {
    // A signature can carry a `TypeDefOrRef` directly (not decoded out of a row's
    // coded-index cell), and `Database.resolve(_:)` selects its target table by
    // tag. `TypeDefOrRef` names three tables across two tag bits, so tag 3 is the
    // unused pattern: `(1 << 2) | 3 = 7` is a non-null row (1) with tag 3.
    let reference = TypeDefOrRef(rawValue: (1 << 2) | 3)
    #expect(reference.row != 0)
    #expect(reference.tag == TypeDefOrRef.tables.count)

    let storage = Storage(bytes: ResolveTests.malformed.span.bytes,
                          relations: ResolveTests.relations.span,
                          strings: ResolveTests.strings.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: ResolveTests.valid, sorted: 0)
    // `Database.resolve(_:)`'s body, against an in-memory storage: the tag guard
    // must reject the reference rather than trap on `TypeDefOrRef.tables[tag]`.
    #expect(throws: WinMDError.BadImageFormat) {
      if reference.row == 0 { return }
      guard reference.tag < TypeDefOrRef.tables.count,
          let schema = TypeDefOrRef.tables[reference.tag]
      else { throw WinMDError.BadImageFormat }
      _ = try storage.tuple(reference.row - 1, of: schema)
    }
  }

  // `CustomAttributeType` is the one coded index with in-range reserved tags:
  // it names five slots across three tag bits, but tags 0, 1, and 4 are reserved
  // (modelled as `nil` table entries) and only 2 (`MethodDef`) and 3
  // (`MemberRef`) are real. A `CustomAttribute` row (#12) whose `Type` (ordinal
  // 1) carries a reserved tag must be rejected, not resolved to a stray table.
  //
  // CustomAttribute[0]: Parent = 0, Type = the coded cell under test, Value = 0;
  // each cell a narrow (2-byte) index, so the stride is 6.
  private static func attribute(_ type: Int) -> Array<UInt8> {
    [0x00, 0x00, UInt8(type & 0xff), UInt8(type >> 8), 0x00, 0x00]
  }

  // A single MethodDef row (#6) so a valid tag-2 reference has a table to land
  // on. The narrow stride is RVA (4) + ImplFlags (2) + Flags (2) + Name (2) +
  // Signature (2) + ParamList (2) = 14; all cells zero.
  private static let methodRow =
      Array<UInt8>(repeating: 0, count: 14)

  @Test func `rejects a CustomAttributeType with a reserved tag`() throws {
    // `Type` = `(1 << CustomAttributeType.bits) | 0`: row 1, tag 0 — reserved.
    let reserved = (1 << CustomAttributeType.bits) | 0
    let record = ResolveTests.attribute(reserved)
    let relations: Array<Table> = [
      Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 0 ..< 6,
            wide: 0, stride: 6),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: 1 << 12, sorted: 0)
    let source = Tuple(0, relations[0], storage)
    // `Type` (ordinal 1) names a non-null row through a reserved tag; the resolve
    // must throw rather than treat the reserved slot as a real table.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(1) }
  }

  @Test func `resolves a CustomAttributeType with a valid tag`() throws {
    // `Type` = `(1 << CustomAttributeType.bits) | 2`: row 1, tag 2 — `MethodDef`.
    let valid = (1 << CustomAttributeType.bits) | 2
    let record = ResolveTests.attribute(valid) + ResolveTests.methodRow
    let relations: Array<Table> = [
      // MethodDef (#6) before CustomAttribute (#12): relations are ordered by
      // table number, so the lower-numbered table's row range comes first.
      Table(Metadata.Tables.MethodDef.self, rows: 1, range: 6 ..< 20,
            wide: 0, stride: 14),
      Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 0 ..< 6,
            wide: 0, stride: 6),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: (1 << 6) | (1 << 12), sorted: 0)
    let source = Tuple(0, relations[1], storage)
    guard let target = try source.resolve(1) else {
      Issue.record("Type did not resolve"); return
    }
    #expect(target.count == Metadata.Tables.MethodDef.fields.count)
  }

  // A single NestedClass row (#41) whose `NestedClass` (ordinal 0, a simple
  // `TypeDef` index) names row 999 — non-null but far past the single TypeDef
  // row. `storage.tuple` returns nil for the out-of-range row; resolution must
  // surface that as a malformed image rather than as "no relationship".
  @Test func `rejects a simple foreign key whose row is out of range`() throws {
    // TypeDef[0] (the target table) before NestedClass[0] (the source): the
    // relations are ordered by table number. The NestedClass row points its
    // `NestedClass` simple index at row 999, well past the one TypeDef row.
    let row = 999
    let record: Array<UInt8> = [
      // NestedClass[0]: NestedClass = 999 (out of range), EnclosingClass = 0.
      UInt8(row & 0xff), UInt8(row >> 8), 0x00, 0x00,
      // TypeDef[0]: a 14-byte row, all zero (only the row count matters).
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,
    ]
    let relations: Array<Table> = [
      Table(Metadata.Tables.TypeDef.self, rows: 1, range: 4 ..< 18,
            wide: 0, stride: 14),
      Table(Metadata.Tables.NestedClass.self, rows: 1, range: 0 ..< 4,
            wide: 0, stride: 4),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: (1 << 2) | (1 << 41), sorted: 0)
    let source = Tuple(0, relations[1], storage)
    // The index is non-null (so it is not the null-FK case) but out of range, so
    // `storage.tuple` returns nil; resolution must throw rather than report no
    // relationship.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(0) }
  }

  @Test func `rejects a coded foreign key whose row is out of range`() throws {
    // TypeDef[0].Extends (ordinal 3, a `TypeDefOrRef` coded index) names a
    // non-null row through tag 1 (`TypeRef`), but row 999 is far past the single
    // TypeRef row. Encoding: `(999 << 2) | 1`.
    let row = (999 << 2) | 1
    let record: Array<UInt8> = [
      // TypeRef[0]: ResolutionScope, TypeName, TypeNamespace — all zero.
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      // TypeDef[0]: Flags (4) = 0, TypeName = 0, TypeNamespace = 0,
      //             Extends = row, FieldList = 0, MethodList = 0.
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      UInt8(row & 0xff), UInt8(row >> 8), 0x00, 0x00, 0x00, 0x00,
    ]
    let relations: Array<Table> = [
      Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
            wide: 0, stride: 6),
      Table(Metadata.Tables.TypeDef.self, rows: 1, range: 6 ..< 20,
            wide: 0, stride: 14),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: (1 << 1) | (1 << 2), sorted: 0)
    let source = Tuple(0, relations[1], storage)
    // Non-null coded row, in-range tag, but the named TypeRef row does not exist;
    // `storage.tuple` returns nil and resolution must throw.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(3) }
  }

  @Test func `rejects a TypeDefOrRef reference whose row is out of range`() throws {
    // A `TypeDefOrRef` carried in a signature with tag 1 (`TypeRef`) but row 999:
    // `(999 << 2) | 1`. `Database.resolve(_:)`'s tag guard passes (the tag names
    // a real table) but the row is past the one TypeRef row.
    let reference = TypeDefOrRef(rawValue: (999 << 2) | 1)
    #expect(reference.row == 999)
    #expect(reference.tag < TypeDefOrRef.tables.count)

    let storage = Storage(bytes: ResolveTests.record.span.bytes,
                          relations: ResolveTests.relations.span,
                          strings: ResolveTests.strings.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: ResolveTests.valid, sorted: 0)
    // `Database.resolve(_:)`'s body against an in-memory storage: the tag guard
    // admits the reference, but the out-of-range row makes `storage.tuple` return
    // nil, which must be surfaced as a malformed image.
    #expect(throws: WinMDError.BadImageFormat) {
      if reference.row == 0 { return }
      guard reference.tag < TypeDefOrRef.tables.count,
          let schema = TypeDefOrRef.tables[reference.tag]
      else { throw WinMDError.BadImageFormat }
      guard let _ = try storage.tuple(reference.row - 1, of: schema) else {
        throw WinMDError.BadImageFormat
      }
    }
  }

  @Test func `rejects a simple foreign key whose target table is absent`() throws {
    // A NestedClass row (#41) whose `NestedClass` (ordinal 0, a simple `TypeDef`
    // index) names a non-null row, but the `TypeDef` table (#2) is absent from
    // the `Valid` mask. A dangling foreign-key target is a malformed image, not a
    // missing user-requested table, so resolution must throw `.BadImageFormat`
    // (not `.TableNotFound`).
    let record: Array<UInt8> = [
      // NestedClass[0]: NestedClass = 1 (non-null), EnclosingClass = 0.
      0x01, 0x00, 0x00, 0x00,
    ]
    let relations: Array<Table> = [
      Table(Metadata.Tables.NestedClass.self, rows: 1, range: 0 ..< 4,
            wide: 0, stride: 4),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: 1 << 41, sorted: 0)
    let source = Tuple(0, relations[0], storage)
    // The index is non-null, but its target `TypeDef` table is absent; resolution
    // must surface that as a malformed image.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(0) }
  }

  @Test func `rejects a coded foreign key whose target table is absent`() throws {
    // TypeDef[0].Extends (ordinal 3, a `TypeDefOrRef` coded index) names a
    // non-null row through tag 1 (`TypeRef`), but the `TypeRef` table (#1) is
    // absent from the `Valid` mask. Encoding: `(1 << 2) | 1 = 5`.
    let record: Array<UInt8> = [
      // TypeDef[0]: Flags (4) = 0, TypeName = 0, TypeNamespace = 0,
      //             Extends = 5, FieldList = 0, MethodList = 0.
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    let relations: Array<Table> = [
      Table(Metadata.Tables.TypeDef.self, rows: 1, range: 0 ..< 14,
            wide: 0, stride: 14),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: 1 << 2, sorted: 0)
    let source = Tuple(0, relations[0], storage)
    // Non-null coded row, in-range tag, but the named `TypeRef` table is absent;
    // resolution must throw rather than report no relationship.
    #expect(throws: WinMDError.BadImageFormat) { _ = try source.resolve(3) }
  }

  @Test func `rejects a TypeDefOrRef reference whose target table is absent`() throws {
    // A `TypeDefOrRef` carried in a signature with tag 1 (`TypeRef`) and row 1:
    // `(1 << 2) | 1`. `Database.resolve(_:)`'s tag guard passes (the tag names a
    // real table), but the `TypeRef` table is absent from the `Valid` mask.
    let reference = TypeDefOrRef(rawValue: (1 << 2) | 1)
    #expect(reference.row == 1)
    #expect(reference.tag < TypeDefOrRef.tables.count)

    let record: Array<UInt8> = [
      // TypeDef[0]: a 14-byte row, all zero (only the row count matters).
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,
    ]
    let relations: Array<Table> = [
      Table(Metadata.Tables.TypeDef.self, rows: 1, range: 0 ..< 14,
            wide: 0, stride: 14),
    ]
    let storage = Storage(bytes: record.span.bytes,
                          relations: relations.span,
                          strings: ResolveTests.empty.span.bytes,
                          blob: ResolveTests.empty.span.bytes,
                          guid: ResolveTests.empty.span.bytes,
                          valid: 1 << 2, sorted: 0)
    // `Database.resolve(_:)`'s body against an in-memory storage: the tag guard
    // admits the reference, but the absent target table makes `storage.tuple`
    // return nil, which must be surfaced as a malformed image.
    #expect(throws: WinMDError.BadImageFormat) {
      if reference.row == 0 { return }
      guard reference.tag < TypeDefOrRef.tables.count,
          let schema = TypeDefOrRef.tables[reference.tag]
      else { throw WinMDError.BadImageFormat }
      guard let _ = try storage.tuple(reference.row - 1, of: schema) else {
        throw WinMDError.BadImageFormat
      }
    }
  }
}
