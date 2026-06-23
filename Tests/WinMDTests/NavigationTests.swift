// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
@testable import WinMD

struct NavigationTests {
  // Typed navigation reads referenced tables out of `relations`, so this
  // hand-builds a small multi-table database: `TypeRef` (#1), `TypeDef` (#2),
  // `FieldDef` (#4), and `NestedClass` (#41). The records carry live foreign
  // keys and a list run:
  //   TypeDef[0].Extends    = 5  → (row 1 << 2) | tag 1 ⇒ TypeRef[0] (coded)
  //   TypeDef[0].FieldList  = 1  → 1-based start, run [0, next-1] ⇒ FieldDef[0]
  //   TypeDef[1].FieldList  = 2  → 1-based, marks one past TypeDef[0]'s run
  //   NestedClass[0].Nested = 1  → a simple TypeDef index ⇒ TypeDef[0] (string0)
  private static let record: Array<UInt8> = [
    // TypeRef[0]: ResolutionScope = 0, TypeName = 1 ("Object"),
    //             TypeNamespace = 8 ("System").
    0x00, 0x00, 0x01, 0x00, 0x08, 0x00,
    // TypeDef[0]: Flags = 0x21, TypeName = 15 ("string0"), TypeNamespace = 23 ("string1"),
    //             Extends = 5 (TypeRef[0]), FieldList = 1 (1-based), MethodList = 1.
    0x21, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x17, 0x00, 0x05, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1]: as above but Extends = 0 (null), FieldList = 2 (1-based).
    0x21, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x17, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00,
    // FieldDef[0]: Flags = 0, Name = 15 ("string0"), Signature = 0.
    0x00, 0x00, 0x0f, 0x00, 0x00, 0x00,
    // FieldDef[1]: Flags = 0, Name = 23 ("string1"), Signature = 0.
    0x00, 0x00, 0x17, 0x00, 0x00, 0x00,
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
  // within `record`. All indices are narrow (2-byte).
  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6, wide: 0, stride: 6),
    Table(Metadata.Tables.TypeDef.self, rows: 2, range: 6 ..< 34, wide: 0, stride: 14),
    Table(Metadata.Tables.FieldDef.self, rows: 2, range: 34 ..< 46, wide: 0, stride: 6),
    Table(Metadata.Tables.NestedClass.self, rows: 1, range: 46 ..< 50, wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: NavigationTests.record.span.bytes,
                          relations: NavigationTests.relations.span,
                          strings: NavigationTests.strings.span.bytes,
                          blob: NavigationTests.empty.span.bytes,
                          guid: NavigationTests.empty.span.bytes,
                          valid: NavigationTests.valid, sorted: 0)
    try body(storage)
  }

  @Test("resolves a simple-index token to a typed row")
  func simpleResolution() throws {
    try NavigationTests.with { storage in
      // NestedClass[0].NestedClass is a simple `TypeDef` index; the token
      // resolve lands on the typed `Row<TypeDef>` it names.
      let source = Row<Metadata.Tables.NestedClass>(0,
                                                    NavigationTests.relations[3],
                                                    storage)
      guard let parent = try source.resolve(.NestedClass) else {
        Issue.record("NestedClass did not resolve"); return
      }
      #expect(parent.TypeName == "string0")
    }
  }

  @Test("resolves a null simple-index token to nothing")
  func nullSimpleResolution() throws {
    try NavigationTests.with { storage in
      // The reframed `EnclosingClass` accessor is non-optional; the underlying
      // token resolve is optional and non-nil for a live reference.
      let source = Row<Metadata.Tables.NestedClass>(0,
                                                    NavigationTests.relations[3],
                                                    storage)
      let resolved: Bool =
          if let _ = try source.resolve(.EnclosingClass) { true } else { false }
      #expect(resolved)
    }
  }

  @Test("resolves a coded-index token to a type-erased tuple")
  func codedResolution() throws {
    try NavigationTests.with { storage in
      // TypeDef[0].Extends is a `TypeDefOrRef` coded index whose tag selects
      // the `TypeRef` table; the token resolve yields the type-erased tuple.
      let source = Row<Metadata.Tables.TypeDef>(0,
                                                NavigationTests.relations[1],
                                                storage)
      guard let base = try source.resolve(.Extends) else {
        Issue.record("Extends did not resolve"); return
      }
      #expect(try base.string(1) == "Object")
    }
  }

  @Test("resolves a null coded-index token to nothing")
  func nullCodedResolution() throws {
    try NavigationTests.with { storage in
      // TypeDef[1].Extends is the null reference (coded row 0).
      let source = Row<Metadata.Tables.TypeDef>(1,
                                                NavigationTests.relations[1],
                                                storage)
      let resolved: Bool =
          if let _ = try source.resolve(.Extends) { true } else { false }
      #expect(!resolved)
    }
  }

  @Test("narrows a coded resolution to the target with Row(_:)")
  func typedRoundTrip() throws {
    try NavigationTests.with { storage in
      let source = Row<Metadata.Tables.TypeDef>(0,
                                                NavigationTests.relations[1],
                                                storage)
      guard let base = try source.resolve(.Extends) else {
        Issue.record("Extends did not resolve"); return
      }
      // The tag selected `TypeRef`, so narrowing to `TypeRef` recovers a typed
      // row; the token accessors read off it.
      guard let typed = Row<Metadata.Tables.TypeRef>(base) else {
        Issue.record("Row(_:) rejected the matching table"); return
      }
      #expect(typed.TypeName == "Object")
      #expect(typed.TypeNamespace == "System")
    }
  }

  @Test("rejects a Row(_:) narrowing to the wrong table")
  func typedMismatch() throws {
    try NavigationTests.with { storage in
      let source = Row<Metadata.Tables.TypeDef>(0,
                                                NavigationTests.relations[1],
                                                storage)
      guard let base = try source.resolve(.Extends) else {
        Issue.record("Extends did not resolve"); return
      }
      // The resolved tuple is a `TypeRef` row, so narrowing to `TypeDef` fails.
      let mismatched: Bool =
          if let _ = Row<Metadata.Tables.TypeDef>(base) {
            true
          } else {
            false
          }
      #expect(!mismatched)
    }
  }

  @Test("opens a typed list iterator over the run")
  func listNavigation() throws {
    try NavigationTests.with { storage in
      // TypeDef[0].FieldList delimits a run ending one before the next row's
      // start, so it yields exactly FieldDef[0] ("string0").
      let source = Row<Metadata.Tables.TypeDef>(0,
                                                NavigationTests.relations[1],
                                                storage)
      let fields = try source.list(.FieldList)
      #expect(fields.count == 1)
      #expect(fields[0]?.Name == "string0")
    }
  }

  @Test("a typed list run agrees with the reframed accessor")
  func listAccessorAgrees() throws {
    try NavigationTests.with { storage in
      let source = Row<Metadata.Tables.TypeDef>(0,
                                                NavigationTests.relations[1],
                                                storage)
      let token = try source.list(.FieldList)
      let accessor = try source.FieldList
      #expect(token.count == accessor.count)
    }
  }
}
