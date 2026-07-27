// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import SQLEngineWinMD

import SQLEngine
@testable import WinMD

/// Coverage of the `TypeSpec` generic-base resolution the adapter and the
/// `identities`/`bases` keystone views layer over a hand-assembled in-memory
/// WinMD.
///
/// A `TypeSpec` (ECMA-335 §II.22.39) names a constructed type through a single
/// `Signature` `#Blob`, not a `TypeName` — a generic instantiation is
/// `GENERICINST <base TypeDefOrRef> <args…>`. It has no namespace/name of its
/// own, so without resolution it would degrade to `opaque` and a generic base
/// interface named through it would vanish. The adapter decodes the
/// instantiation's base `TypeDefOrRef` to the `Base_TypeRef`/`Base_TypeDef`
/// virtual columns — the base type's 1-based `Id` in its table — the way the
/// coded-index join keys decode a coded index. `identities` then resolves a
/// `TypeSpec` to its generic base's namespace/name across those keys, and
/// `bases` names a class's generic base interface through the `TypeSpec` arm of
/// `InterfaceImpl.Interface` rather than dropping it.
///
/// The fixture packs one generic base `TypeRef` (`NS.IVector`), one class
/// `TypeDef` (`NS.Widget`), an `InterfaceImpl` tagging `Widget`'s base as a
/// `TypeSpec`, and four `TypeSpec`s: a `GENERICINST` of the base `TypeRef`
/// (`IVector<String>`), a non-generic `SZARRAY` of `I4`, a `GENERICINST` of
/// the same base wrapped in a `CMOD_OPT` custom modifier (the regression: a
/// valid modified instantiation whose base was dropped when the extraction
/// matched `.instance` directly), and a `CMOD_REQD`-wrapped `SZARRAY` — the
/// adversarial cases that must resolve to NULL (the arrays) or to the base
/// (both instantiations) rather than mis-resolve or crash.
struct TypeSpecViewTests {
  // Four narrow (all-index / natural-width) tables packed back to back in
  // table-number order — TypeRef (#1, 1 row), TypeDef (#2, 1 row),
  // InterfaceImpl (#9, 1 row), TypeSpec (#27, 4 rows). ECMA-335 rows are
  // 1-based; a TypeDefOrRef coded token is `(row << 2) | tag`, tag 1 selecting
  // TypeRef and tag 2 selecting TypeSpec.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="IVector"(4),
  //                TypeNamespace="NS"(1) — the generic base interface.
  //   TypeDef[0]:  Flags=0, TypeName="Widget"(12), TypeNamespace="NS"(1),
  //                null Extends/Field/Method — the class implementing the base.
  //   InterfaceImpl[0]: Class=1 (TypeDef row 1, Widget),
  //                Interface=6 ((1 << 2) | 2 — TypeSpec row 1).
  //   TypeSpec[0]: Signature=1  (blob offset 1 — GENERICINST of TypeRef row 1).
  //   TypeSpec[1]: Signature=7  (blob offset 7 — SZARRAY I4, no generic base).
  //   TypeSpec[2]: Signature=10 (blob offset 10 — CMOD_OPT GENERICINST of
  //                TypeRef row 1: a modifier-wrapped generic base).
  //   TypeSpec[3]: Signature=18 (blob offset 18 — CMOD_REQD SZARRAY I4: a
  //                modifier-wrapped non-instance, still no generic base).
  private static let bytes: Array<UInt8> = [
    // TypeRef[0]: ResolutionScope, TypeName=4, TypeNamespace=1.
    0x00, 0x00, 0x04, 0x00, 0x01, 0x00,
    // TypeDef[0]: Flags, TypeName=12, TypeNamespace=1, Extends, FieldList,
    // MethodList.
    0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // InterfaceImpl[0]: Class=1, Interface=6.
    0x01, 0x00, 0x06, 0x00,
    // TypeSpec[0]: Signature=1.  TypeSpec[1]: Signature=7.
    // TypeSpec[2]: Signature=10. TypeSpec[3]: Signature=18.
    0x01, 0x00,
    0x07, 0x00,
    0x0a, 0x00,
    0x12, 0x00,
  ]

  // "\0NS\0IVector\0Widget\0": NS@1, IVector@4, Widget@12.
  private static let strings: Array<UInt8> = [
    0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x56, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x00,
    0x57, 0x69, 0x64, 0x67, 0x65, 0x74, 0x00,
  ]

  // The blob heap: the empty blob at 0, then four length-prefixed signatures.
  // A custom modifier is `CMOD_REQD`(0x1f)/`CMOD_OPT`(0x20) followed by a
  // compressed TypeDefOrRef coded token (ECMA-335 §II.23.2.7); `type()` reads
  // any leading modifier run before the type it decorates.
  //   @1:  [0x05] GENERICINST(0x15) CLASS(0x12) TypeRef#1(token 0x05) 1 arg
  //        STRING(0x0e) — `IVector<String>`, its base TypeRef row 1.
  //   @7:  [0x02] SZARRAY(0x1d) I4(0x08) — a non-generic TypeSpec, no base.
  //   @10: [0x07] CMOD_OPT(0x20) TypeRef#1(token 0x05) then the @1 GENERICINST
  //        — a modifier-wrapped generic base, same base TypeRef row 1.
  //   @18: [0x04] CMOD_REQD(0x1f) TypeRef#1(token 0x05) then SZARRAY(0x1d)
  //        I4(0x08) — a modifier-wrapped non-instance, still no base.
  private static let blob: Array<UInt8> = [
    0x00,
    0x05, 0x15, 0x12, 0x05, 0x01, 0x0e,
    0x02, 0x1d, 0x08,
    0x07, 0x20, 0x05, 0x15, 0x12, 0x05, 0x01, 0x0e,
    0x04, 0x1f, 0x05, 0x1d, 0x08,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 1, range: 6 ..< 20,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 20 ..< 24,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 4, range: 24 ..< 32,
                wide: 0, stride: 2),
  ]

  // TypeRef (#1), TypeDef (#2), InterfaceImpl (#9), TypeSpec (#27).
  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 9) | (1 << 27)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Plans and runs `query` through the engine over a `Session` catalog seeded
  /// with the bundled views, binding any `:name` parameters from `bindings`.
  private static func run(_ query: String, _ catalog: borrowing Storage,
                          bindings: Bindings = [:])
      throws -> Array<Array<Value>> {
    guard case let .select(select) = try Statement(parsing: query) else {
      Issue.record("not a SELECT")
      return []
    }
    return try Session(catalog, Session.bundled())
        .run(select, Session.routines, bindings: bindings)
  }

  /// The output-column names the schema path derives for `query` over a
  /// `Session` catalog, validating the query — the parity check that a
  /// `columns(of:)` derive agrees with what a run projects.
  private static func columns(_ query: String, _ catalog: borrowing Storage)
      throws -> Array<String> {
    try Session(catalog, Session.bundled())
        .columns(of: Statement(parsing: query), routines: Session.routines,
                 validate: true)
        .map(\.name)
  }

  @Test func `the adapter decodes a GENERICINST base to the Base keys`() throws {
    // The first `TypeSpec` is `GENERICINST CLASS TypeRef#1 <String>`, so its
    // base is `TypeRef` row 1 — `Base_TypeRef` is 1 and `Base_TypeDef` is
    // NULL. The second is a non-generic `SZARRAY I4`, which names no generic
    // base, so both keys are NULL (the adversarial case must not mis-resolve
    // or crash). The third wraps the same `GENERICINST` in a `CMOD_OPT` custom
    // modifier: peeling the outer `.modified` reaches the instantiation, so it
    // resolves to the same base `TypeRef` row 1 rather than dropping it. The
    // fourth wraps a `SZARRAY` in a `CMOD_REQD` modifier — a modified
    // non-instance still names no generic base, so both keys stay NULL.
    try TypeSpecViewTests.with { catalog in
      let rows = try TypeSpecViewTests.run(
          "SELECT Base_TypeRef, Base_TypeDef FROM TypeSpec ORDER BY Id",
          catalog)
      #expect(rows == [
        [.integer(1), .null],
        [.null, .null],
        [.integer(1), .null],
        [.null, .null],
      ])
    }
  }

  @Test func `the identities view resolves a TypeSpec to its generic base`() throws {
    // `identities` now carries a `TypeSpec` arm: each `GENERICINST` `TypeSpec`
    // resolves to its base's identity (`NS.IVector`) — the bare instantiation
    // (Id 1) and the `CMOD_OPT`-wrapped one (Id 3) alike — while the two
    // non-instance `TypeSpec`s, whose `Base` keys are both NULL, name no
    // identity row.
    try TypeSpecViewTests.with { catalog in
      let rows = try TypeSpecViewTests.run(
          "SELECT kind, Id, TypeNamespace, TypeName FROM identities "
          + "WHERE kind = 'TypeSpec' ORDER BY Id", catalog)
      #expect(rows == [
        [.text("TypeSpec"), .integer(1), .text("NS"), .text("IVector")],
        [.text("TypeSpec"), .integer(3), .text("NS"), .text("IVector")],
      ])
    }
  }

  @Test func `the bases view names a generic base interface`() throws {
    // `Widget` (TypeDef Id 1) implements a generic interface: its
    // `InterfaceImpl.Interface` tags a `TypeSpec`, which `bases` resolves
    // through `identities` to the generic base's name (`IVector`) rather than
    // dropping it (the pre-fix behaviour, with no `TypeSpec` arm).
    try TypeSpecViewTests.with { catalog in
      let rows = try TypeSpecViewTests.run("SELECT base FROM bases", catalog,
                                           bindings: ["parent": .integer(1)])
      #expect(rows == [[.text("IVector")]])
    }
  }

  @Test func `relations lists a physical TypeSpec exactly once`() throws {
    // This database has generic instantiations, so `TypeSpec` is physically
    // present in the tables stream. `relations()` must name it from that
    // physical enumeration and must not also append the synthetic entry — a
    // duplicate would list `TypeSpec` twice in `INFORMATION_SCHEMA`.
    try TypeSpecViewTests.with { catalog in
      let relations = catalog.relations()
      let spec = relations.filter { $0.caseInsensitiveCompare("TypeSpec")
                                        == .orderedSame }
      #expect(spec == ["TypeSpec"])
      let tables = try TypeSpecViewTests.run(
          "SELECT table_name FROM information_schema.tables "
          + "WHERE table_name = 'TypeSpec'", catalog)
      #expect(tables == [[.text("TypeSpec")]])
    }
  }

  @Test func `a physical TypeSpec still returns its rows`() throws {
    // Listing `TypeSpec` in `relations()` does not disturb a query over the
    // physical table: its two fixture rows are still read.
    try TypeSpecViewTests.with { catalog in
      let rows = try TypeSpecViewTests.run(
          "SELECT Id FROM TypeSpec ORDER BY Id", catalog)
      #expect(rows == [[.integer(1)], [.integer(2)], [.integer(3)],
                       [.integer(4)]])
    }
  }

  @Test func `the schema path agrees with the run for the TypeSpec views`() throws {
    // A `columns(of:validate:true)` derive validates each changed view and
    // reports the same projected columns a run yields, so the schema path
    // cannot diverge from the run path on `identities` or `bases`.
    try TypeSpecViewTests.with { catalog in
      let identities = try TypeSpecViewTests.columns(
          "SELECT kind, Id, TypeNamespace, TypeName FROM identities", catalog)
      #expect(identities == ["kind", "Id", "TypeNamespace", "TypeName"])
      let bases = try TypeSpecViewTests.columns("SELECT base FROM bases",
                                                catalog)
      #expect(bases == ["base"])
    }
  }
}
