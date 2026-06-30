// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQL
@testable import WinMD

import struct Foundation.Data
import struct Foundation.URL
import class Foundation.FileManager
import struct Foundation.UUID
import func Foundation.NSTemporaryDirectory

/// Coverage of the per-table decoded virtual columns the WinMD → SQL adapter
/// exposes: `guid` on `CustomAttribute`, `ReturnType` on `MethodDef`, and
/// `ParamType` on `Param`. Rather than map a `.winmd` file, the tests assemble a
/// tiny COM
/// interface in memory — a `TypeDef` carrying a `GuidAttribute` (through the
/// `CustomAttribute` → `MemberRef` → `TypeRef` chain), a `MethodDef` whose
/// signature decodes to `void Method(i4, string)`, the method's three `Param`
/// rows (the `Sequence == 0` return pseudo-parameter and the two real
/// parameters), and an `InterfaceImpl` row naming the base `IInspectable`
/// `TypeRef` (so the `bases` view derives the interface's base) — and drive a
/// parsed `SELECT` through `Engine.run` over the `WinMD.Storage` catalog,
/// asserting the decoded `Value`s the engine yields.
struct DatabaseSQLTests {
  // The records of seven narrow (all-index 2-byte) tables, packed back to back
  // in table-number order. ECMA-335 rows are 1-based, so a stored index `N`
  // names the 0-based row `N - 1`; a coded index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1) — the
  //                attribute's declaring type the `iid` decode matches on.
  //   TypeRef[1]:  ResolutionScope=0, TypeName="IInspectable"(89),
  //                TypeNamespace=0 — the base interface `IMyInterface` extends,
  //                referenced from another component; the `bases` view names it.
  //   TypeDef[0]:  Flags=0x21, TypeName="IMyInterface"(49), TypeNamespace="NS"
  //                (77), MethodList=1 — owns MethodDef[0]; carries the
  //                `GuidAttribute`, so the `interfaces` view names it.
  //   TypeDef[1]:  Flags=0, TypeName="INotGuid"(80), TypeNamespace="NS"(77),
  //                MethodList=2 — owns no methods and carries no
  //                `GuidAttribute`, so the `interfaces` view excludes it.
  //   MethodDef[0]: Name="MyMethod"(62), Signature=blob[1], ParamList=1 — owns
  //                Param[0..2].
  //   Param[0]:    Sequence=0 (the return pseudo-parameter, → NULL).
  //   Param[1]:    Sequence=1, Name="first"(71) — signature.parameters[0] (i4).
  //   Param[2]:    Sequence=2 — signature.parameters[1] (string).
  //   InterfaceImpl[0]: Class=TypeDef row 1 (the simple `TypeDef` index stores
  //                the rowid directly, so 1)=IMyInterface;
  //                Interface=TypeDefOrRef(TypeRef row 2)=(2<<2)|1=9 — names the
  //                base `IInspectable`, so the `bases` view derives it.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the ctor
  //                whose declaring type is the `GuidAttribute` TypeRef.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[7] — the `0x0001`-prologued GUID value blob.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0]
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1]
    0x00, 0x00, 0x59, 0x00, 0x00, 0x00,
    // TypeDef[0]
    0x21, 0x00, 0x00, 0x00, 0x31, 0x00, 0x4d, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1]
    0x00, 0x00, 0x00, 0x00, 0x50, 0x00, 0x4d, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // MethodDef[0]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x3e, 0x00, 0x01, 0x00, 0x01, 0x00,
    // Param[0..2]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x47, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    // InterfaceImpl[0]
    0x01, 0x00, 0x09, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x07, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0IMyInterface\0MyMethod
  // \0first\0NS\0INotGuid\0IInspectable\0": GuidNamespace@1, GuidName@35,
  // IMyInterface@49, MyMethod@62, first@71, NS@77, INotGuid@80,
  // IInspectable@89.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x49, 0x4d, 0x79, 0x49, 0x6e, 0x74, 0x65, 0x72, 0x66, 0x61, 0x63, 0x65,
    0x00,
    0x4d, 0x79, 0x4d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x00,
    0x66, 0x69, 0x72, 0x73, 0x74, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x4e, 0x6f, 0x74, 0x47, 0x75, 0x69, 0x64, 0x00,
    0x49, 0x49, 0x6e, 0x73, 0x70, 0x65, 0x63, 0x74, 0x61, 0x62, 0x6c, 0x65,
    0x00,
  ]

  // A `#Blob` heap: offset 0 is the reserved empty blob; offset 1 is the 5-byte
  // method signature `void Method(i4, string)` — prolog 0x20 (HASTHIS), count 2,
  // VOID (0x01), I4 (0x08), STRING (0x0e) — preceded by its length 0x05; offset
  // 7 is the 20-byte `GuidAttribute` value (prolog 0x0001, the GUID as `u32,
  // u16, u16, u8×8`, then NumNamed 0), preceded by its length 0x14. The GUID is
  // the well-known `0C733A30-2A1C-11CE-ADE5-00AA0044773D`.
  private static let blob: Array<UInt8> = [
    0x00,
    0x05, 0x20, 0x02, 0x01, 0x08, 0x0e,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 40 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 3, range: 54 ..< 72,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 72 ..< 76,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 76 ..< 82,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 82 ..< 88,
                wide: 0, stride: 6),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10)
          | (1 << 12)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
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
    return try Engine.run(select, catalog)
  }

  /// Parses `query` as a `CREATE VIEW`, returning its case-folded name and view.
  private static func create(_ query: String) throws -> (String, View) {
    guard case let .create(name, view) = try Statement(parsing: query) else {
      Issue.record("not a CREATE VIEW")
      throw SQLError.incomplete(expected: "a CREATE VIEW")
    }
    return (name.lowercased(), view)
  }

  /// Plans and runs `query` through the engine over a `Session` catalog
  /// overlaying `views` on the storage.
  private static func run(_ query: String,
                          _ views: Dictionary<String, View>,
                          _ catalog: borrowing Storage)
      throws -> Array<Array<Value>> {
    let statement = try Statement(parsing: query)
    guard case let .select(select) = statement else {
      Issue.record("not a SELECT")
      return []
    }
    return try Engine.run(select, Session(catalog, views))
  }

  @Test("a registered view is queryable through the session catalog")
  func sessionView() throws {
    // `CREATE VIEW guids …` registers a view over `CustomAttribute`'s decoded
    // `guid` extra; a `SELECT … FROM guids` then resolves it through the session
    // catalog and yields the view's rows. The fixture's single
    // `CustomAttribute` is the `GuidAttribute`, so its `guid` is the well-known
    // value.
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW guids AS "
          + "SELECT guid FROM CustomAttribute WHERE guid IS NOT NULL")
      let rows = try DatabaseSQLTests.run(
          "SELECT guid FROM guids", [name: view], catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test("a view is resolved case-insensitively")
  func sessionViewCaseInsensitive() throws {
    // The session catalog folds the view name, so a query may name the view in
    // any case (relation names resolve case-insensitively elsewhere).
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW interfaces AS SELECT TypeName FROM TypeDef")
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName FROM INTERFACES", [name: view], catalog)
      #expect(rows == [[.text("IMyInterface")], [.text("INotGuid")]])
    }
  }

  @Test("a view over a decoded extra joins through the session catalog")
  func sessionViewMethod() throws {
    // A view over `MethodDef`'s decoded `ReturnType` extra resolves and yields
    // the decoded return spelling, proving the session catalog vends the same
    // storage-backed relation the engine plans over.
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW returns AS SELECT Name, ReturnType FROM MethodDef")
      let rows = try DatabaseSQLTests.run(
          "SELECT Name, ReturnType FROM returns", [name: view], catalog)
      #expect(rows == [[.text("MyMethod"), .text("Void")]])
    }
  }

  @Test("vends a CustomAttribute's decoded guid")
  func guid() throws {
    // The `guid` extra decodes the `GuidAttribute`'s `Value` blob to the
    // well-known UUID as text; the fixture's sole `CustomAttribute` is that
    // attribute.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT guid FROM CustomAttribute", catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test("excludes the decoded extras from SELECT *")
  func star() throws {
    // `SELECT *` projects exactly the six real `TypeDef` fields — neither
    // `rowid`, `parent`, nor any decoded extra appears — for each of the two
    // fixture types.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run("SELECT * FROM TypeDef", catalog)
      #expect(rows.count == 2)
      #expect(rows[0].count == 6)
    }
  }

  @Test("vends a MethodDef's decoded ReturnType")
  func returnType() throws {
    // The signature `void Method(i4, string)` decodes its return to `Void`.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Name, ReturnType FROM MethodDef", catalog)
      #expect(rows == [[.text("MyMethod"), .text("Void")]])
    }
  }

  @Test("vends each Param's decoded ParamType, NULL for the return parameter")
  func paramType() throws {
    // The `Sequence == 0` return pseudo-parameter decodes to NULL; the two real
    // parameters decode to the signature's `i4` (`CInt`) and `string`
    // (`HSTRING`).
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Sequence, ParamType FROM Param ORDER BY Sequence", catalog)
      #expect(rows == [
        [.integer(0), .null],
        [.integer(1), .text("CInt")],
        [.integer(2), .text("HSTRING")],
      ])
    }
  }

  @Test("excludes the return parameter through a ParamType filter")
  func paramTypeNotNull() throws {
    // A guard on `ParamType IS NOT NULL` drops the `Sequence == 0` return row,
    // leaving the two real parameters.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT ParamType FROM Param WHERE ParamType IS NOT NULL "
          + "ORDER BY Sequence", catalog)
      #expect(rows == [
        [.text("CInt")],
        [.text("HSTRING")],
      ])
    }
  }

  @Test("a coded-index join key decodes to the target's rowid")
  func codedKeyResolves() throws {
    // `CustomAttribute[0].Parent` is `HasCustomAttribute(TypeDef row 1)`, so
    // the `Parent_TypeDef` key decodes to the owning `TypeDef`'s 1-based rowid.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Parent_TypeDef FROM CustomAttribute", catalog)
      #expect(rows == [[.integer(1)]])
    }
  }

  @Test("a coded-index join key is NULL when it points elsewhere")
  func codedKeyNull() throws {
    // The same `Parent` cell tags `TypeDef` (tag 3), so every other candidate
    // target's join key — here `Parent_MethodDef` (tag 0) — is SQL NULL: a NULL
    // will not equi-join, so only the `TypeDef` key matches.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Parent_MethodDef FROM CustomAttribute", catalog)
      #expect(rows == [[.null]])
    }
    // A `MemberRefParent(TypeRef row 1)` `Class` cell tags `TypeRef` (tag 1),
    // not `TypeDef` (tag 0), so `Class_TypeDef` is NULL and `Class_TypeRef` is
    // the referenced row.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Class_TypeDef, Class_TypeRef FROM MemberRef", catalog)
      #expect(rows == [[.null, .integer(1)]])
    }
  }

  @Test("a coded-index join key is excluded from SELECT *")
  func codedKeyStar() throws {
    // `SELECT *` projects exactly the three real `CustomAttribute` fields —
    // neither the virtuals nor the coded-index join keys appear.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT * FROM CustomAttribute", catalog)
      #expect(rows.count == 1)
      #expect(rows[0].count == 3)
    }
  }

  @Test("a coded-index join key joins a CustomAttribute to its owning TypeDef")
  func codedKeyJoin() throws {
    // Joining `CustomAttribute` to `TypeDef` on the decoded `Parent_TypeDef`
    // key against the `TypeDef`'s rowid pairs the `GuidAttribute` row (carrying
    // the decoded `guid`) with the `IMyInterface` type it decorates, end to end
    // across the coded index.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeDef.TypeName, CustomAttribute.guid FROM CustomAttribute "
          + "JOIN TypeDef ON CustomAttribute.Parent_TypeDef = TypeDef.rowid",
          catalog)
      #expect(rows == [
        [.text("IMyInterface"),
         .text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")],
      ])
    }
  }

  @Test("a script's CREATE VIEW is visible to a later statement's SELECT")
  func scriptSession() throws {
    // The batch driver threads one shared `Session` across every statement, so a
    // `CREATE VIEW` registered by one statement is visible to a later `SELECT`.
    // `execute` prints rather than returning rows, so this drives the shared
    // statement path directly — `Shell.execute` over the same session — to
    // register the view (the `CREATE VIEW` branch), then resolves a `SELECT`
    // naming it through the session's views, the exact session state the batch
    // threads.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute("CREATE VIEW names AS SELECT TypeName FROM TypeDef")
      #expect(shell.session.views.keys.contains("names"))
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName FROM names", shell.session.views, catalog)
      #expect(rows == [[.text("IMyInterface")], [.text("INotGuid")]])
    }
  }

  @Test("execute routes a `.`-token to its meta-command")
  func executeMeta() throws {
    // The leading-token dispatch matches `.tables` to `Tables`, which lists the
    // storage's relations; the fixture's catalog vends them, so `execute`
    // succeeds. A SQL statement takes the parse path instead — exercised by
    // `scriptSession` — and `.quit` throws the loop's `Stop` sentinel.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".tables")
      #expect(throws: Shell.Stop.self) { try shell.execute(".quit") }
    }
  }

  @Test("execute rejects an unknown or empty-argument `.`-command")
  func executeUnknown() {
    // An unrecognised `.`-token is `MetaError.unknown`, and a `.read` with no
    // path executes to the same unknown fault — the empty-argument guard the
    // `Read` command carries.
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: Shell.MetaError.unknown(".bogus")) {
        try shell.execute(".bogus")
      }
      #expect(throws: Shell.MetaError.unknown(".read")) {
        try shell.execute(".read")
      }
    }
  }

  @Test("a `.quit` inside a `.read` file leaves the shell, not just the file")
  func readPropagatesQuit() throws {
    // `.read` drives the same statement stream, but a `.quit` in the file must
    // throw `Stop` past the file reader so the whole session ends — the help's
    // promise — not merely the included file. The statement after the `.quit`
    // never runs; that the read throws `Stop` is the observable evidence.
    let path = NSTemporaryDirectory()
             + "winmd-inspect-\(UUID().uuidString).sql"
    try Data(".quit\nSELECT TypeName FROM TypeDef;\n".utf8)
        .write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: Shell.Stop.self) {
        try shell.execute(".read \(path)")
      }
    }
  }

  @Test("a `.read` fault fails an explicit batch fast")
  func readFailsFastInBatch() throws {
    // A `strict` shell (an explicit batch) lets an included file's fault
    // propagate, so the run aborts rather than pressing on against a partially
    // applied session. The bad `SELECT` is the file's only statement here; that
    // `.read` throws is the evidence the batch would fail.
    let path = NSTemporaryDirectory()
             + "winmd-inspect-\(UUID().uuidString).sql"
    try Data("SELECT Name FROM NoSuchTable;\n".utf8)
        .write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog, strict: true)
      #expect(throws: (any Error).self) {
        try shell.execute(".read \(path)")
      }
    }
  }

  @Test("a `.read` fault is reported and skipped in shell mode")
  func readContinuesInShell() throws {
    // A forgiving shell (the interactive/redirected path) reports a statement's
    // fault and reads on, so an included file behaves like its text on stdin: a
    // bad statement does not skip the file's later valid ones. `.read` must not
    // throw here, and the CREATE VIEW after the bad SELECT must still register.
    let path = NSTemporaryDirectory()
             + "winmd-inspect-\(UUID().uuidString).sql"
    try Data("""
      SELECT Name FROM NoSuchTable;
      CREATE VIEW ok AS SELECT TypeName FROM TypeDef;

      """.utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: Never.self) { try shell.execute(".read \(path)") }
      #expect(shell.session.views.keys.contains("ok"))
    }
  }

  @Test("a coded-index join key admits one key per candidate target table")
  func codedKeyEnumeration() {
    // `CustomAttribute.Parent` is `HasCustomAttribute`, which admits 22 target
    // tables, plus `Type` is `CustomAttributeType`, which admits two (its three
    // reserved tags yield no key): the relation exposes 24 join keys in total,
    // named `<Column>_<Target>`.
    DatabaseSQLTests.with { storage in
      let relation = storage.table(named: "CustomAttribute")
      let keys = relation?.keys ?? []
      #expect(keys.count == 24)
      #expect(keys.contains { $0.name == "Parent_TypeDef" })
      #expect(keys.contains { $0.name == "Type_MethodDef" })
      #expect(keys.contains { $0.name == "Type_MemberRef" })
      // The reserved `CustomAttributeType` tags contribute no key.
      #expect(keys.allSatisfy { !$0.name.isEmpty })
    }
  }

  @Test("an unowned Param's ParamType is NULL and does not trap")
  func paramTypeUnowned() throws {
    // A `Param` no `MethodDef` run owns — the `MethodDef` table is present but
    // has zero rows, so its owner resolves to 0 — decodes to SQL NULL rather
    // than indexing the negative row `owner - 1` through the parent cursor.
    try UnownedParamFixture.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT ParamType FROM Param", catalog)
      #expect(rows == [[.null]])
    }
  }

  @Test("a System.Guid Param decodes to CLSID or IID by its Name")
  func paramTypeGuidClassification() throws {
    // The signature `void Method(Guid, Guid)` names `System.Guid` parameters;
    // the decoder classifies each by the `Param.Name` hint — `clsid` yields
    // `CLSID`, an unrelated name (`iid`) yields the default `IID`.
    try GuidParamFixture.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Name, ParamType FROM Param WHERE ParamType IS NOT NULL "
          + "ORDER BY Sequence", catalog)
      #expect(rows == [
        [.text("clsid"), .text("CLSID")],
        [.text("iid"), .text("IID")],
      ])
    }
  }
}

/// A fixture whose `Param` row is owned by no `MethodDef` run: the `MethodDef`
/// table is present (so the list link resolves to it) but has zero rows, so the
/// owner of the lone `Param` resolves to 0. `SELECT ParamType FROM Param` must
/// then yield SQL NULL rather than index a negative `MethodDef` row.
private enum UnownedParamFixture {
  // Two narrow tables packed back to back. `MethodDef` contributes no records
  // (zero rows); `Param` contributes one.
  //
  //   Param[0]: Flags=0, Sequence=1, Name=0 — a real parameter owned by no
  //             method, so its `ParamType` decode finds owner 0.
  private static let bytes: Array<UInt8> = [
    // Param[0]
    0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 0 ..< 0,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
  ]

  private static let valid: UInt64 = (1 << 6) | (1 << 8)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: empty.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }
}

/// A fixture whose method takes two `System.Guid` parameters — one named
/// `clsid`, one named `iid` — so the `ParamType` decode exercises the
/// `Param.Name` classification hint: a `clsid`-rooted name spells `CLSID`, any
/// other Guid parameter the default `IID`.
private enum GuidParamFixture {
  // Three narrow (all-index 2-byte) tables packed back to back in table-number
  // order. A stored index `N` names the 0-based row `N - 1`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="Guid"(8),
  //                TypeNamespace="System"(1) — the `System.Guid` the signature
  //                names, resolved to the `IID`/`CLSID` identity.
  //   MethodDef[0]: Name="Method"(23), Signature=blob[1], ParamList=1 — owns
  //                Param[0..2].
  //   Param[0]:    Sequence=0 (the return pseudo-parameter, → NULL).
  //   Param[1]:    Sequence=1, Name="clsid"(13) — parameters[0], a Guid whose
  //                name classifies it as a `CLSID`.
  //   Param[2]:    Sequence=2, Name="iid"(19) — parameters[1], a Guid whose
  //                name leaves it the default `IID`.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0]
    0x00, 0x00, 0x08, 0x00, 0x01, 0x00,
    // MethodDef[0]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x17, 0x00, 0x01, 0x00, 0x01, 0x00,
    // Param[0..2]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x0d, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x13, 0x00,
  ]

  // "\0System\0Guid\0clsid\0iid\0Method\0": System@1, Guid@8, clsid@13, iid@19,
  // Method@23.
  private static let strings: Array<UInt8> = [
    0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x00,
    0x63, 0x6c, 0x73, 0x69, 0x64, 0x00,
    0x69, 0x69, 0x64, 0x00,
    0x4d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x00,
  ]

  // A `#Blob` heap: offset 0 is the reserved empty blob; offset 1 is the 7-byte
  // signature `void Method(Guid, Guid)` — prolog 0x20 (HASTHIS); count 2; VOID
  // (0x01); then two `VALUETYPE` (0x11) operands each naming the `TypeDefOrRef`
  // to TypeRef row 1 (compressed `(1 << 2) | 1 == 0x05`) — preceded by its
  // length 0x07.
  private static let blob: Array<UInt8> = [
    0x00,
    0x07, 0x20, 0x02, 0x01, 0x11, 0x05, 0x11, 0x05,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 6 ..< 20,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 3, range: 20 ..< 38,
                wide: 0, stride: 6),
  ]

  private static let valid: UInt64 = (1 << 1) | (1 << 6) | (1 << 8)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }
}
