// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import SQLEngineWinMD

import SQLEngine
@testable import WinMD

/// Coverage of the bundled `types` and `identities` keystone views over a
/// hand-assembled in-memory WinMD.
///
/// The `identities` view unifies a reference: it `UNION ALL`s every `TypeDef`
/// and `TypeRef` under a `kind` discriminator, so a base named through the
/// `TypeDef.Extends` coded index resolves to its namespace/name whether the
/// base is a same-module `TypeDef` or a cross-module `TypeRef`. The `types`
/// view classifies each `TypeDef` by kind — `interface` from the `tdInterface`
/// (0x20) `Flags` bit, then `enum`/`delegate`/`struct` from its direct base
/// (`System.Enum`/`System.MulticastDelegate`/`System.ValueType`), everything
/// else `class` — joining `identities` across both arms of `Extends` and
/// coalescing the base namespace/name.
///
/// The fixture packs four system-base `TypeRef`s (`System.Enum`,
/// `System.ValueType`, `System.MulticastDelegate`, `System.Object`) and six
/// `TypeDef`s: one per kind — an interface (the 0x20 bit, a null `Extends`),
/// and an enum, struct, delegate, and class each extending its system base
/// through the `Extends` `TypeDefOrRef` coded index — plus the `<Module>`
/// pseudo-type (no base, no flag), which `types` filters out by name while
/// `identities` still unifies it. Driving a `SELECT … FROM types` through
/// `Catalog.run` over the `WinMD.Storage` catalog asserts each `TypeDef` is
/// classified as expected.
struct TypesViewTests {
  // Two narrow (all-index 2-byte) tables packed back to back in table-number
  // order — `TypeRef` (4 rows) then `TypeDef` (6 rows). ECMA-335 rows are
  // 1-based, so a stored index `N` names the 0-based row `N - 1`; the `Extends`
  // `TypeDefOrRef` coded index is `(row << 2) | tag`, with tag 1 selecting
  // `TypeRef` — so an `Extends` of `(1 << 2) | 1 = 5` names `TypeRef` row 1.
  //
  //   TypeRef[0]: ResolutionScope=0, TypeName="Enum"(8),
  //               TypeNamespace="System"(1).
  //   TypeRef[1]: TypeName="ValueType"(13), TypeNamespace="System"(1).
  //   TypeRef[2]: TypeName="MulticastDelegate"(23), TypeNamespace="System"(1).
  //   TypeRef[3]: TypeName="Object"(41), TypeNamespace="System"(1).
  //   TypeDef[0]: Flags=0x20 (tdInterface), TypeName="MyInterface"(51),
  //               TypeNamespace="NS"(48), Extends=0 (null) — an interface.
  //   TypeDef[1]: Flags=0, TypeName="MyEnum"(63), Extends=5 (TypeRef row 1,
  //               System.Enum) — an enum.
  //   TypeDef[2]: TypeName="MyStruct"(70), Extends=9 (TypeRef row 2,
  //               System.ValueType) — a struct.
  //   TypeDef[3]: TypeName="MyDelegate"(79), Extends=13 (TypeRef row 3,
  //               System.MulticastDelegate) — a delegate.
  //   TypeDef[4]: TypeName="MyClass"(90), Extends=17 (TypeRef row 4,
  //               System.Object) — a class (the fall-through `ELSE` arm).
  //   TypeDef[5]: Flags=0, TypeName="<Module>"(98), TypeNamespace=0 (null),
  //               Extends=0 (null) — the module pseudo-type `types` excludes.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0..3]
    0x00, 0x00, 0x08, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x0d, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x17, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x29, 0x00, 0x01, 0x00,
    // TypeDef[0] MyInterface
    0x20, 0x00, 0x00, 0x00, 0x33, 0x00, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00,
    // TypeDef[1] MyEnum
    0x00, 0x00, 0x00, 0x00, 0x3f, 0x00, 0x30, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x00, 0x00,
    // TypeDef[2] MyStruct
    0x00, 0x00, 0x00, 0x00, 0x46, 0x00, 0x30, 0x00, 0x09, 0x00, 0x00, 0x00,
    0x00, 0x00,
    // TypeDef[3] MyDelegate
    0x00, 0x00, 0x00, 0x00, 0x4f, 0x00, 0x30, 0x00, 0x0d, 0x00, 0x00, 0x00,
    0x00, 0x00,
    // TypeDef[4] MyClass
    0x00, 0x00, 0x00, 0x00, 0x5a, 0x00, 0x30, 0x00, 0x11, 0x00, 0x00, 0x00,
    0x00, 0x00,
    // TypeDef[5] <Module> — TypeName offset 98 (0x62), null namespace/Extends
    0x00, 0x00, 0x00, 0x00, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00,
  ]

  // "\0System\0Enum\0ValueType\0MulticastDelegate\0Object\0NS\0MyInterface\0
  // MyEnum\0MyStruct\0MyDelegate\0MyClass\0<Module>\0": System@1, Enum@8,
  // ValueType@13, MulticastDelegate@23, Object@41, NS@48, MyInterface@51,
  // MyEnum@63, MyStruct@70, MyDelegate@79, MyClass@90, <Module>@98.
  private static let strings: Array<UInt8> = [
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x45, 0x6e, 0x75, 0x6d,
    0x00, 0x56, 0x61, 0x6c, 0x75, 0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x4d,
    0x75, 0x6c, 0x74, 0x69, 0x63, 0x61, 0x73, 0x74, 0x44, 0x65, 0x6c, 0x65,
    0x67, 0x61, 0x74, 0x65, 0x00, 0x4f, 0x62, 0x6a, 0x65, 0x63, 0x74, 0x00,
    0x4e, 0x53, 0x00, 0x4d, 0x79, 0x49, 0x6e, 0x74, 0x65, 0x72, 0x66, 0x61,
    0x63, 0x65, 0x00, 0x4d, 0x79, 0x45, 0x6e, 0x75, 0x6d, 0x00, 0x4d, 0x79,
    0x53, 0x74, 0x72, 0x75, 0x63, 0x74, 0x00, 0x4d, 0x79, 0x44, 0x65, 0x6c,
    0x65, 0x67, 0x61, 0x74, 0x65, 0x00, 0x4d, 0x79, 0x43, 0x6c, 0x61, 0x73,
    0x73, 0x00,
    // "<Module>" at offset 98
    0x3c, 0x4d, 0x6f, 0x64, 0x75, 0x6c, 0x65, 0x3e, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 4, range: 0 ..< 24,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 6, range: 24 ..< 108,
                wide: 0, stride: 14),
  ]

  // Only `TypeRef` (table 1) and `TypeDef` (table 2) are present — this
  // database declares no `TypeSpec`, which the adapter resolves to an empty
  // relation so the `identities` `TypeSpec` arm reads no rows, not a fault.
  private static let valid: UInt64 = (1 << 1) | (1 << 2)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Plans and runs `query` through the engine over a `Session` catalog seeded
  /// with the bundled views (`identities`, `types`, …).
  private static func run(_ query: String, _ catalog: borrowing Storage)
      throws -> Array<Array<Value>> {
    guard case let .select(select) = try Statement(parsing: query) else {
      Issue.record("not a SELECT")
      return []
    }
    return try Session(catalog, Session.bundled()).run(select,
                                                       Session.routines)
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

  @Test func `the types view classifies each TypeDef by its kind`() throws {
    // Each of the five fixture `TypeDef`s classifies by the view's rules: the
    // 0x20-flagged type is an interface (its null `Extends` is irrelevant), and
    // the four base-derived types resolve their `System` base through the
    // `Extends_TypeRef` join into `identities` — `Enum`→enum, `ValueType`→
    // struct, `MulticastDelegate`→delegate, `Object`→the `ELSE` class.
    try TypesViewTests.with { catalog in
      let rows = try TypesViewTests.run(
          "SELECT Id, TypeNamespace, TypeName, kind FROM types ORDER BY Id",
          catalog)
      #expect(rows == [
        [.integer(1), .text("NS"), .text("MyInterface"), .text("interface")],
        [.integer(2), .text("NS"), .text("MyEnum"), .text("enum")],
        [.integer(3), .text("NS"), .text("MyStruct"), .text("struct")],
        [.integer(4), .text("NS"), .text("MyDelegate"), .text("delegate")],
        [.integer(5), .text("NS"), .text("MyClass"), .text("class")],
      ])
    }
  }

  @Test func `the types view exposes the coalesced base namespace and name`() throws {
    // The `base_namespace`/`base_name` projections carry the resolved direct
    // base — `System.Enum` for the enum, `System.Object` for the class — while
    // the interface, whose `Extends` is null, coalesces to NULL for both.
    try TypesViewTests.with { catalog in
      let rows = try TypesViewTests.run(
          "SELECT TypeName, base_namespace, base_name FROM types ORDER BY Id",
          catalog)
      #expect(rows == [
        [.text("MyInterface"), .null, .null],
        [.text("MyEnum"), .text("System"), .text("Enum")],
        [.text("MyStruct"), .text("System"), .text("ValueType")],
        [.text("MyDelegate"), .text("System"), .text("MulticastDelegate")],
        [.text("MyClass"), .text("System"), .text("Object")],
      ])
    }
  }

  @Test func `the identities view unifies TypeDef and TypeRef under a kind`() throws {
    // `identities` `UNION ALL`s the six `TypeDef`s and four `TypeRef`s, each
    // tagged by its `kind`; the discriminator disambiguates a `TypeDef` Id N
    // from a `TypeRef` Id N (both are 1-based within their own table). Unlike
    // `types`, `identities` retains the `<Module>` pseudo-type — it is a
    // faithful reference unification, not a declaration enumeration.
    try TypesViewTests.with { catalog in
      let rows = try TypesViewTests.run(
          "SELECT kind, Id, TypeName FROM identities ORDER BY kind, Id",
          catalog)
      #expect(rows == [
        [.text("TypeDef"), .integer(1), .text("MyInterface")],
        [.text("TypeDef"), .integer(2), .text("MyEnum")],
        [.text("TypeDef"), .integer(3), .text("MyStruct")],
        [.text("TypeDef"), .integer(4), .text("MyDelegate")],
        [.text("TypeDef"), .integer(5), .text("MyClass")],
        [.text("TypeDef"), .integer(6), .text("<Module>")],
        [.text("TypeRef"), .integer(1), .text("Enum")],
        [.text("TypeRef"), .integer(2), .text("ValueType")],
        [.text("TypeRef"), .integer(3), .text("MulticastDelegate")],
        [.text("TypeRef"), .integer(4), .text("Object")],
      ])
    }
  }

  @Test func `the types view excludes the <Module> pseudo-type`() throws {
    // The fixture's sixth `TypeDef` is the ECMA-335 `<Module>` pseudo-type — no
    // base and no interface flag, so the classification's `ELSE` arm would
    // otherwise mislabel it a `class` and hand every caller a bogus type. The
    // view filters it by its reserved name, so `types` names none while
    // `identities` still carries it.
    try TypesViewTests.with { catalog in
      let types = try TypesViewTests.run(
          "SELECT TypeName FROM types WHERE TypeName = '<Module>'", catalog)
      #expect(types == [])
      let identities = try TypesViewTests.run(
          "SELECT TypeName FROM identities WHERE TypeName = '<Module>'",
          catalog)
      #expect(identities == [[.text("<Module>")]])
    }
  }

  @Test func `relations enumerates the synthetic absent TypeSpec`() throws {
    // This database declares no `TypeSpec`, yet `table(named:)` resolves it to
    // an empty relation so the bundled `identities`/`bases` views do not fault.
    // The catalog contract requires `relations()` to enumerate every base
    // relation `table(named:)` resolves, so it must name the synthetic
    // `TypeSpec` too — exactly once, and under the same schema name a direct
    // `SELECT … FROM TypeSpec` uses.
    TypesViewTests.with { catalog in
      let relations = catalog.relations()
      let spec = relations.filter { $0.caseInsensitiveCompare("TypeSpec")
                                        == .orderedSame }
      #expect(spec == ["TypeSpec"])
      // `table(named:)` resolves the synthetic relation — the enumeration above
      // must match it. Its result is `~Escapable`, so bind it in a `guard`
      // rather than compare it inside a macro.
      guard catalog.table(named: "TypeSpec") != nil else {
        Issue.record("table(named: \"TypeSpec\") did not resolve")
        return
      }
      // A delimited name that is a Unicode case-fold equivalent resolves the
      // same, per the catalog's case-insensitive contract: `ſ` folds to `s`, so
      // `Typeſpec` must reach `TypeSpec`. The name registry keys on a case-fold
      // (not `lowercased()`, which leaves `ſ` unchanged) to preserve this.
      guard catalog.table(named: "Typeſpec") != nil else {
        Issue.record("table(named: \"Typeſpec\") did not resolve (case-fold)")
        return
      }
    }
  }

  @Test func `information_schema lists the synthetic TypeSpec's columns`() throws {
    // The `INFORMATION_SCHEMA` overlay iterates `relations()`, so listing the
    // synthetic `TypeSpec` makes it a first-class base table there: it appears
    // in `information_schema.tables` and its real column (`Signature`) appears
    // in `information_schema.columns`, deriving that column from the same
    // synthetic relation `table(named:)` resolves.
    try TypesViewTests.with { catalog in
      let tables = try TypesViewTests.run(
          "SELECT table_name FROM information_schema.tables "
          + "WHERE table_name = 'TypeSpec'", catalog)
      #expect(tables == [[.text("TypeSpec")]])
      let columns = try TypesViewTests.run(
          "SELECT column_name FROM information_schema.columns "
          + "WHERE table_name = 'TypeSpec' ORDER BY ordinal_position", catalog)
      #expect(columns == [[.text("Signature")]])
    }
  }

  @Test func `a direct query over the absent TypeSpec reads no rows`() throws {
    // The synthetic relation `table(named:)` vends is empty, so a direct
    // `SELECT … FROM TypeSpec` succeeds and yields no rows rather than faulting
    // on a missing relation — the behaviour `relations()` now advertises.
    try TypesViewTests.with { catalog in
      let rows = try TypesViewTests.run("SELECT Id FROM TypeSpec", catalog)
      #expect(rows == [])
    }
  }

  @Test func `the schema path agrees with the run for the keystone views`() throws {
    // A `columns(of:validate:true)` derive validates each view and reports the
    // same projected columns a run yields, so the schema path cannot diverge
    // from the run path on either keystone view.
    try TypesViewTests.with { catalog in
      let types = try TypesViewTests.columns(
          "SELECT Id, TypeNamespace, TypeName, kind FROM types", catalog)
      #expect(types == ["Id", "TypeNamespace", "TypeName", "kind"])
      let identities = try TypesViewTests.columns(
          "SELECT kind, Id, TypeNamespace, TypeName FROM identities", catalog)
      #expect(identities == ["kind", "Id", "TypeNamespace", "TypeName"])
    }
  }
}
