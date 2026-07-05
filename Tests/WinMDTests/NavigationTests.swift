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

  @Test func `resolves a simple-index token to a typed row`() throws {
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

  @Test func `resolves a null simple-index token to nothing`() throws {
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

  @Test func `resolves a coded-index token to a type-erased tuple`() throws {
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

  @Test func `resolves a null coded-index token to nothing`() throws {
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

  @Test func `narrows a coded resolution to the target with Row(_:)`() throws {
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

  @Test func `rejects a Row(_:) narrowing to the wrong table`() throws {
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

  @Test func `opens a typed list iterator over the run`() throws {
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

  @Test func `a typed list run agrees with the reframed accessor`() throws {
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

// Typed reverse navigation over a simple-index owner. `NestedClass.NestedClass`
// (a `Reference<NestedClass, TypeDef>`) is the table's sort key, so the rows
// referencing a given `TypeDef` form a contiguous run. ECMA-335 rows are
// 1-based, so a stored value `N` names the 0-based TypeDef row `N - 1`:
//   NestedClass[0].NestedClass = 1  → TypeDef[0]
//   NestedClass[1].NestedClass = 2  → TypeDef[1]
//   NestedClass[2].NestedClass = 2  → TypeDef[1]
//   NestedClass[3].NestedClass = 4  → TypeDef[3]
struct ReverseNavigationTests {
  private static let record: Array<UInt8> = [
    // TypeDef[0..3]: four 14-byte rows, all zero (only the row count matters).
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // NestedClass[0..3]: NestedClass then EnclosingClass, ordered by NestedClass.
    0x01, 0x00, 0x09, 0x00,
    0x02, 0x00, 0x09, 0x00,
    0x02, 0x00, 0x09, 0x00,
    0x04, 0x00, 0x09, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeDef.self, rows: 4, range: 0 ..< 56,
          wide: 0, stride: 14),
    Table(Metadata.Tables.NestedClass.self, rows: 4, range: 56 ..< 72,
          wide: 0, stride: 4),
  ]

  private static let valid: UInt64 = (1 << 2) | (1 << 41)

  private static func with(_ sorted: UInt64,
                           _ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage =
        Storage(bytes: ReverseNavigationTests.record.span.bytes,
                relations: ReverseNavigationTests.relations.span,
                strings: ReverseNavigationTests.empty.span.bytes,
                blob: ReverseNavigationTests.empty.span.bytes,
                guid: ReverseNavigationTests.empty.span.bytes,
                valid: ReverseNavigationTests.valid, sorted: sorted)
    try body(storage)
  }

  @Test func `reverse-navigates a simple-index token to its owners`() throws {
    // The token names the owning `NestedClass` table and the `NestedClass`
    // ordinal, so the call site needs no schema or ordinal; the rows naming
    // TypeDef[1] are the contiguous run [1, 3).
    try ReverseNavigationTests.with(1 << 41) { storage in
      let target = Row<Metadata.Tables.TypeDef>(1,
                                                ReverseNavigationTests.relations[0],
                                                storage)
      var rows = Array<Int>()
      let filter = try storage.referencing(target, by: .NestedClass)
      filter.forEach { rows.append($0.row) }
      #expect(rows == [1, 2])
    }
  }

  @Test func `the typed reverse token agrees with the ordinal form`() throws {
    try ReverseNavigationTests.with(0) { storage in
      let target = Row<Metadata.Tables.TypeDef>(1,
                                                ReverseNavigationTests.relations[0],
                                                storage)
      var byToken = Array<Int>()
      let tokenFilter = try storage.referencing(target, by: .NestedClass)
      tokenFilter.forEach { byToken.append($0.row) }

      var byOrdinal = Array<Int>()
      let ordinalFilter =
          try storage.referencing(target.columns,
                                  in: Metadata.Tables.NestedClass.self, by: 0)
      ordinalFilter.forEach { byOrdinal.append($0.row) }

      #expect(byToken == byOrdinal)
    }
  }
}

// Typed reverse navigation over a coded-index owner. `CustomAttribute.Parent`
// (a `CodedReference<CustomAttribute>`) is a `HasCustomAttribute` coded index;
// `TypeDef` is its fourth table (tag 3) over 5 tag bits, so a row naming
// TypeDef[r] stores `((r + 1) << 5) | 3`.
struct ReverseCodedNavigationTests {
  private static let record: Array<UInt8> = [
    // TypeDef[0..1]: two 14-byte rows (only the row count matters).
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]: Parent = 0x23 → TypeDef[0].
    0x23, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[1]: Parent = 0x43 → TypeDef[1].
    0x43, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[2]: Parent = 0x23 → TypeDef[0] again.
    0x23, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<Table> = [
    Table(Metadata.Tables.TypeDef.self, rows: 2, range: 0 ..< 28,
          wide: 0, stride: 14),
    Table(Metadata.Tables.CustomAttribute.self, rows: 3, range: 28 ..< 46,
          wide: 0, stride: 6),
  ]

  private static let valid: UInt64 = (1 << 2) | (1 << 12)

  @Test func `reverse-navigates a coded-index token to its owners`() throws {
    // CustomAttribute is left unsorted, so the typed reverse lookup scans; the
    // rows naming TypeDef[0] through `Parent` are 0 and 2.
    let storage =
        Storage(bytes: ReverseCodedNavigationTests.record.span.bytes,
                relations: ReverseCodedNavigationTests.relations.span,
                strings: ReverseCodedNavigationTests.empty.span.bytes,
                blob: ReverseCodedNavigationTests.empty.span.bytes,
                guid: ReverseCodedNavigationTests.empty.span.bytes,
                valid: ReverseCodedNavigationTests.valid, sorted: 0)
    let target = Row<Metadata.Tables.TypeDef>(0,
                                              ReverseCodedNavigationTests.relations[0],
                                              storage)
    var rows = Array<Int>()
    // The owning table is named explicitly: `CustomAttribute.Parent` is a
    // `CodedReference<CustomAttribute>` carrying the owner and the ordinal.
    let token =
        CodedReference<Metadata.Tables.CustomAttribute>.Parent
    let filter = try storage.referencing(target, by: token)
    filter.forEach { rows.append($0.row) }
    #expect(rows == [0, 2])
  }
}
