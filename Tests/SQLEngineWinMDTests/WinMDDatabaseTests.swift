// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

// A plain (non-`@testable`) import: this suite reaches `SQLEngineWinMD` only
// through its public surface, proving a third-party package can open and query
// a WinMD database with the shipped API alone. `WinMD` is imported `@testable`
// solely to assemble the in-memory `Storage` fixture — the byte-level store a
// real caller would map from a `.winmd` file instead.
import SQLEngineWinMD

import SQLEngine
@testable import WinMD

/// A public-consumer probe over `WinMDDatabase`.
///
/// It assembles a tiny two-row `TypeDef` store in memory, opens a
/// `WinMDDatabase` over the borrowed `Storage`, and queries it three ways a
/// consumer would — the ergonomic SQL-string `run`, the engine's generic
/// `Catalog.run(_:_:bindings:)` over a parsed `Query` with the database's
/// `routines`, and the schema-only `columns(of:)` — asserting the rows and the
/// output shape. Everything resolves against `SQLEngineWinMD`'s public API.
struct WinMDDatabaseTests {
  // TypeDef[0]: Flags=0x21 TypeName="Alpha" TypeNamespace="NS"
  // TypeDef[1]: Flags=0x10 TypeName="Beta"  TypeNamespace="NS"
  // 14-byte narrow rows; ECMA-335 stored indices are 1-based.
  private static let bytes: Array<UInt8> = [
    0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00,
  ]

  // "\0Alpha\0Beta\0NS\0": Alpha@1, Beta@7, NS@12.
  private static let strings: Array<UInt8> = [
    0x00,
    0x41, 0x6c, 0x70, 0x68, 0x61, 0x00,
    0x42, 0x65, 0x74, 0x61, 0x00,
    0x4e, 0x53, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 0 ..< 28,
                wide: 0, stride: 14),
  ]

  // TypeDef is table #2; no table is physically sorted here.
  private static let valid: UInt64 = 1 << 2

  /// Opens a `WinMDDatabase` over the assembled store and runs `body` against
  /// it — the public open path a consumer takes from a mapped file's `Storage`.
  private static func with(_ body: (borrowing WinMDDatabase) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    let database = WinMDDatabase(storage)
    try body(database)
  }

  @Test func `runs a SELECT string through the public facade`() throws {
    try WinMDDatabaseTests.with { database in
      let rows = try database.run(
          "SELECT TypeName, Flags FROM TypeDef "
          + "WHERE TypeNamespace = 'NS' ORDER BY TypeName")
      #expect(rows == [
        [.text("Alpha"), .integer(0x21)],
        [.text("Beta"), .integer(0x10)],
      ])
    }
  }

  @Test func `binds a parameter through the public run`() throws {
    try WinMDDatabaseTests.with { database in
      let rows = try database.run(
          "SELECT TypeName FROM TypeDef WHERE TypeName = :name",
          bindings: ["name": .text("Beta")])
      #expect(rows == [[.text("Beta")]])
    }
  }

  @Test func `serves as a Catalog for the engine's parsed run`() throws {
    // The facade is a public `Catalog`: a parsed `Query` runs against it
    // through the engine's generic entry point, resolving against its
    // `routines`.
    try WinMDDatabaseTests.with { database in
      let statement = try Statement(parsing: "SELECT Id, TypeName FROM TypeDef "
                                    + "ORDER BY Id")
      guard case let .select(query) = statement else {
        Issue.record("not a SELECT")
        return
      }
      let rows = try database.run(query, database.routines)
      #expect(rows == [
        [.integer(1), .text("Alpha")],
        [.integer(2), .text("Beta")],
      ])
    }
  }

  @Test func `derives the output columns of a SELECT string`() throws {
    try WinMDDatabaseTests.with { database in
      let columns = try database.columns(of: "SELECT TypeName FROM TypeDef")
      #expect(columns.map(\.name) == ["TypeName"])
    }
  }

  @Test func `enumerates its base relations`() {
    // The store physically holds only `TypeDef`, yet `table(named:)` also
    // resolves the optional tables — `TypeSpec` (ECMA-335 §II.22.39),
    // `NestedClass` (§II.22.32), and `ClassLayout` (§II.22.8) — to an empty
    // relation when they are absent, so `relations()` enumerates them too — the
    // catalog contract that `relations()` names every base relation
    // `table(named:)` resolves. Each is appended once, past the physical tables.
    WinMDDatabaseTests.with { database in
      #expect(database.relations()
              == ["TypeDef", "TypeSpec", "NestedClass", "ClassLayout"])
    }
  }
}
