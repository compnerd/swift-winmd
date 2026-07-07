// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQLEngine
@testable import WinMD

/// End-to-end coverage of the WinMD → SQL-engine adapter.
///
/// Rather than map a `.winmd` file, the tests assemble a tiny store in memory —
/// `TypeDef` (#2), `MethodDef` (#6), `NestedClass` (#41), and `EventMap` (#18)
/// — and drive a parsed `SELECT` through `Catalog.run` over the `WinMD.Storage`
/// catalog, asserting the typed `Value` rows the engine yields. They exercise a
/// single-relation projection / filter / order with the `Id` virtual column
/// and a sorted-key seek, a foreign-key join on `Id`, a list join on the owner
/// foreign-key column (a `MethodDef`'s `TypeDef`), and a real `Parent` column
/// that is an ordinary foreign key.
struct AdapterTests {
  // TypeDef[0..1] (14-byte narrow rows), MethodDef[0..2] (14-byte rows), and
  // NestedClass[0..1] (4-byte rows), packed back to back. ECMA-335 rows are
  // 1-based, so a stored index `N` names the 0-based row `N - 1`.
  //
  //   TypeDef[0]: Flags=0x21 TypeName="Alpha" TypeNamespace="NS" MethodList=1
  //   TypeDef[1]: Flags=0x10 TypeName="Beta"  TypeNamespace="NS" MethodList=3
  //   so TypeDef[0] owns MethodDef[0,1] and TypeDef[1] owns MethodDef[2].
  //
  //   MethodDef[0]: Name="m0"  MethodDef[1]: Name="m1"  MethodDef[2]: Name="m2"
  //
  //   NestedClass[0]: NestedClass=1 EnclosingClass=2   (→ TypeDef[0], Alpha)
  //   NestedClass[1]: NestedClass=2 EnclosingClass=1   (→ TypeDef[1], Beta)
  //
  // `NestedClass` is laid out ascending by its key column (ordinal 0): 1, 2.
  //
  //   EventMap[0]: Parent=1 EventList=1   (→ TypeDef[0], Alpha)
  //   EventMap[1]: Parent=2 EventList=1   (→ TypeDef[1], Beta)
  //
  // `EventMap` carries a *real* `Parent` field (a TypeDef index), an ordinary
  // foreign key; `EventMap` owns no list, so it has no owner-FK column.
  private static let bytes: Array<UInt8> = [
    // TypeDef[0]: Flags, TypeName=1, TypeNamespace=12, Extends, FieldList,
    // MethodList=1.
    0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1]: Flags, TypeName=7, TypeNamespace=12, Extends, FieldList,
    // MethodList=3.
    0x10, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00,
    // MethodDef[0]: RVA, ImplFlags, Flags, Name=15, Signature, ParamList.
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0f, 0x00, 0x00, 0x00, 0x00, 0x00,
    // MethodDef[1]: Name=18.
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x12, 0x00, 0x00, 0x00, 0x00, 0x00,
    // MethodDef[2]: Name=21.
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x15, 0x00, 0x00, 0x00, 0x00, 0x00,
    // NestedClass[0..1]: NestedClass index then EnclosingClass index.
    0x01, 0x00, 0x02, 0x00,
    0x02, 0x00, 0x01, 0x00,
    // EventMap[0..1]: Parent (TypeDef index) then EventList (EventDef index).
    0x01, 0x00, 0x01, 0x00,
    0x02, 0x00, 0x01, 0x00,
  ]

  // "\0Alpha\0Beta\0NS\0m0\0m1\0m2\0": Alpha@1, Beta@7, NS@12, m0@15, m1@18,
  // m2@21.
  private static let strings: Array<UInt8> = [
    0x00,
    0x41, 0x6c, 0x70, 0x68, 0x61, 0x00,
    0x42, 0x65, 0x74, 0x61, 0x00,
    0x4e, 0x53, 0x00,
    0x6d, 0x30, 0x00,
    0x6d, 0x31, 0x00,
    0x6d, 0x32, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 0 ..< 28,
          wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 3, range: 28 ..< 70,
          wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 2, range: 70 ..< 78,
          wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.EventMap.self, rows: 2, range: 78 ..< 86,
          wide: 0, stride: 4),
  ]

  // NestedClass (#41) is physically sorted on its key column.
  private static let sorted: UInt64 = 1 << 41
  private static let valid: UInt64 =
      (1 << 2) | (1 << 6) | (1 << 18) | (1 << 41)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: sorted)
    try body(storage)
  }

  /// Plans and runs `query` through the engine over the catalog.
  private static func run(_ query: String, _ catalog: borrowing Storage)
      throws -> Array<Array<Value>> {
    let statement = try Statement(parsing: query)
    guard case let .select(select) = statement else {
      Issue.record("not a SELECT")
      return []
    }
    return try catalog.run(select)
  }

  @Test func `projects, filters, and orders a single relation`() throws {
    // The string columns project as text, the constant as an integer; the
    // WHERE keeps both rows (both are in "NS"), and ORDER BY TypeName sorts
    // Alpha < Beta. `SELECT *` is the two real string heaps plus the constant
    // and the three index columns — never `Id` or an owner-FK column.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT TypeName, Flags FROM TypeDef "
          + "WHERE TypeNamespace = 'NS' ORDER BY TypeName", catalog)
      #expect(rows == [
        [.text("Alpha"), .integer(0x21)],
        [.text("Beta"), .integer(0x10)],
      ])
    }
  }

  @Test func `excludes Id and the owner FK from SELECT *`() throws {
    // `SELECT *` projects exactly the real fields: a TypeDef has six. Neither
    // the `Id` nor an owner-foreign-key virtual column appears.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run("SELECT * FROM TypeDef ORDER BY Id",
                                      catalog)
      #expect(rows.count == 2)
      #expect(rows[0].count == 6)
      #expect(rows[0] == [
        .integer(0x21), .text("Alpha"), .text("NS"),
        .integer(0), .integer(0), .integer(1),
      ])
    }
  }

  @Test func `vends the Id virtual column 1-based`() throws {
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT Id, TypeName FROM TypeDef ORDER BY Id", catalog)
      #expect(rows == [
        [.integer(1), .text("Alpha")],
        [.integer(2), .text("Beta")],
      ])
    }
  }

  @Test func `seeks a sorted key rather than scanning`() throws {
    // NestedClass is sorted on its key column, so an equality on it takes the
    // engine's seek path; the one row whose NestedClass index is 2 survives.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT NestedClass, EnclosingClass FROM NestedClass "
          + "WHERE NestedClass = 2", catalog)
      #expect(rows == [[.integer(2), .integer(1)]])
    }
  }

  @Test func `joins through a foreign key on Id`() throws {
    // The FK `NestedClass.NestedClass` holds a TypeDef Id; the engine joins
    // each NestedClass row to its TypeDef and projects the resolved name.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT NestedClass.EnclosingClass, TypeDef.TypeName "
          + "FROM NestedClass JOIN TypeDef "
          + "ON NestedClass.NestedClass = TypeDef.Id "
          + "ORDER BY NestedClass.EnclosingClass", catalog)
      #expect(rows == [
        [.integer(1), .text("Beta")],
        [.integer(2), .text("Alpha")],
      ])
    }
  }

  @Test func `joins a list child to its owner on the owner FK`() throws {
    // The `TypeDef` owner-FK column relates each MethodDef to the TypeDef whose
    // MethodList run owns it: MethodDef[0,1] → TypeDef[0] (Alpha), MethodDef[2]
    // → TypeDef[1] (Beta). The join seeks TypeDef on its `Id` per method.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT MethodDef.Name, TypeDef.TypeName "
          + "FROM MethodDef JOIN TypeDef "
          + "ON MethodDef.TypeDef = TypeDef.Id "
          + "ORDER BY MethodDef.Name", catalog)
      #expect(rows == [
        [.text("m0"), .text("Alpha")],
        [.text("m1"), .text("Alpha")],
        [.text("m2"), .text("Beta")],
      ])
    }
  }

  @Test func `resolves a real Parent foreign-key column`() throws {
    // EventMap carries a real `Parent` field — a TypeDef index — and owns no
    // list, so it has no owner-FK column: the name resolves to that ordinary
    // foreign key. EventMap[0].Parent=1, EventMap[1].Parent=2.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT Parent FROM EventMap ORDER BY Id", catalog)
      #expect(rows == [[.integer(1)], [.integer(2)]])
    }
  }

  @Test func `joins through a real Parent foreign key on Id`() throws {
    // The real `EventMap.Parent` FK holds a TypeDef Id; the join resolves
    // each EventMap row to its TypeDef: Parent=1 → Alpha, Parent=2 → Beta.
    try AdapterTests.with { catalog in
      let rows = try AdapterTests.run(
          "SELECT EventMap.Parent, TypeDef.TypeName "
          + "FROM EventMap JOIN TypeDef "
          + "ON EventMap.Parent = TypeDef.Id "
          + "ORDER BY EventMap.Parent", catalog)
      #expect(rows == [
        [.integer(1), .text("Alpha")],
        [.integer(2), .text("Beta")],
      ])
    }
  }
}
