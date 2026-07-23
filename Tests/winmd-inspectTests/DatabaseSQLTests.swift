// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import Mustache
import SQLEngine
@testable import WinMD
import WinMDSynthesis

import struct Foundation.Data
import struct Foundation.URL
import class Foundation.FileManager
import struct Foundation.UUID
import func Foundation.NSTemporaryDirectory

/// The Swift `Dialect` the render-time signature decode spells against — the same
/// strings the bundled `swift.lang` carries, so the helper assertions read the
/// exact Swift spellings the old `ReturnType`/`ParamType` virtual columns did.
extension Dialect {
  static var swift: Dialect {
    Dialect(
        primitives: [
          "void": "Void", "bool": "CBool", "char": "Unicode.UTF16.CodeUnit",
          "i1": "CChar", "u1": "CUnsignedChar", "i2": "CShort",
          "u2": "CUnsignedShort", "i4": "CInt", "u4": "CUnsignedInt",
          "i8": "CLongLong", "u8": "CUnsignedLongLong", "f4": "CFloat",
          "f8": "CDouble", "iptr": "Int", "uptr": "UInt", "string": "HSTRING",
          "object": "UnsafeMutableRawPointer",
          "typedref": "UnsafeMutableRawPointer",
        ],
        pointer: (typed: (mutable: "UnsafeMutablePointer",
                          constant: "UnsafePointer"),
                  untyped: (mutable: "UnsafeMutableRawPointer",
                            constant: "UnsafeRawPointer")),
        optional: "?",
        generic: (open: "<", close: ">"),
        variable: (type: "T", method: "M"),
        projection: ".ABI",
        opaque: "UnsafeMutableRawPointer",
        guid: (iid: "IID", clsid: "CLSID"),
        known: [
          Identity(namespace: "Windows.Win32.Foundation", name: "HRESULT"):
              "HRESULT",
          Identity(namespace: "Windows.Win32.Foundation", name: "BOOL"):
              "BOOL",
        ],
        escape: { keyword in
          ["class", "default", "in", "protocol", "repeat"].contains(keyword)
              ? "`\(keyword)`" : keyword
        })
  }
}

/// Coverage of the WinMD → SQL adapter's `GUID` scalar UDF over a
/// `CustomAttribute.Value` `.blob` column and the render-time signature decode
/// (`decode(return:in:)`/
/// `decode(parameter:for:)`), which the adapter no longer bakes as `ReturnType`/
/// `ParamType` columns. Rather than map a `.winmd` file, the tests assemble a
/// tiny COM
/// interface in memory — a `TypeDef` carrying a `GuidAttribute` (through the
/// `CustomAttribute` → `MemberRef` → `TypeRef` chain), a `MethodDef` whose
/// signature decodes to `void Method(i4, string)`, the method's three `Param`
/// rows (the `Sequence == 0` return pseudo-parameter and the two real
/// parameters), and an `InterfaceImpl` row naming the base `IInspectable`
/// `TypeRef` (so the `bases` view derives the interface's base) — and drive a
/// parsed `SELECT` through `Catalog.run` over the `WinMD.Storage` catalog,
/// asserting the decoded `Value`s the engine yields (or the spellings the render
/// decode composes).
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
  //                the Id directly, so 1)=IMyInterface;
  //                Interface=TypeDefOrRef(TypeRef row 2)=(2<<2)|1=9 — names the
  //                base `IInspectable`, so the `bases` view derives it.
  //   InterfaceImpl[1]: Class=1=IMyInterface; Interface=TypeDefOrRef(TypeDef
  //                row 2)=(2<<2)|0=8 — a second base, `INotGuid`, defined in the
  //                SAME file, so `Interface_TypeRef` is NULL and `bases` must
  //                resolve it through the `Interface_TypeDef` UNION arm.
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
    // InterfaceImpl[1]
    0x01, 0x00, 0x08, 0x00,
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
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 2, range: 72 ..< 80,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 80 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 86 ..< 92,
                wide: 0, stride: 6),
    // No `TypeSpec` table: this file has no generic bases, so — like a real
    // WinMD with no `TypeSpec` rows — it omits the table entirely (its `Valid`
    // bit is clear). The bundled `bases` view's `TypeSpec` arm still resolves:
    // the SQL adapter surfaces a schema-defined but absent table as an EMPTY
    // relation (`WinMD.Table.empty`), so the arm yields no rows rather than
    // faulting an unknown relation.
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

  /// Runs `body` over a `Storage` catalog whose relations carry an (empty)
  /// `GenericParam` table, so the render's `declarations` guard — which checks
  /// the table's PRESENCE in storage before running the `generics` view —
  /// passes and the render takes its generic arm. The rows the arm renders come
  /// from a `generics` view override the caller registers, so the table need
  /// hold no rows (an empty range past the last real table); the shared
  /// fixture omits it (no generics), which the render treats as no generics.
  private static func withGenerics(
      _ body: (borrowing Storage) throws -> Void) rethrows {
    var relations = DatabaseSQLTests.relations
    relations.append(WinMD.Table(Metadata.Tables.GenericParam.self, rows: 0,
                                 range: bytes.count ..< bytes.count,
                                 wide: 0, stride: 8))
    let valid = DatabaseSQLTests.valid | (1 << 42)
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// The bundled template `name`'s body with its leading `{{! language: … }}`
  /// directive line stripped — the body the render hands to `MustacheTemplate`
  /// after `language(declaredIn:)` consumes the directive. A test renders it
  /// directly with a hand-built context to pin the template's output shape.
  private static func template(named name: String) throws -> String {
    var body = ""
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      body = try shell.template(named: name, search: [])
    }
    guard let newline = body.firstIndex(where: \.isNewline) else { return body }
    return String(body[body.index(after: newline)...])
  }

  /// Plans and runs `query` through the engine over the catalog.
  private static func run(_ query: String, _ catalog: borrowing Storage)
      throws -> Array<Array<Value>> {
    let statement = try Statement(parsing: query)
    guard case let .select(select) = statement else {
      Issue.record("not a SELECT")
      return []
    }
    return try catalog.run(select, Session.routines)
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
    return try Session(catalog, views).run(select, Session.routines)
  }

  /// Plans and runs `query` through the engine over a `Session` catalog
  /// overlaying `views` on the storage, with `bindings` resolving any `:name`
  /// parameter (a view's correlated-subquery predicate binds from these).
  private static func run(_ query: String,
                          _ views: Dictionary<String, View>,
                          _ catalog: borrowing Storage,
                          _ bindings: Bindings)
      throws -> Array<Array<Value>> {
    let statement = try Statement(parsing: query)
    guard case let .select(select) = statement else {
      Issue.record("not a SELECT")
      return []
    }
    return try Session(catalog, views).run(select, Session.routines,
                                           bindings: bindings)
  }

  @Test func `the bundled interfaces view yields the IID-carrying TypeDef`() throws {
    // The `interfaces` view navigates each `TypeDef` to its `GuidAttribute` IID
    // across the coded-index join keys (`TypeDef` ← `CustomAttribute` →
    // `MemberRef` → `TypeRef`), projecting `GUID(c.Value)` as `iid`; the only
    // IID-carrying type is `IMyInterface`, whose `iid` is the well-known value.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName, iid FROM interfaces", Session.bundled(), catalog)
      #expect(rows == [
        [.text("IMyInterface"),
         .text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")],
      ])
    }
  }

  @Test func `the bundled methods view yields a method bound by its parent Id`() throws {
    // `IMyInterface` is `TypeDef` Id 1, which owns `MethodDef` Id 1;
    // binding `:parent` to the interface's Id yields the method's `Id` and
    // `Name` (the type is no longer a column — the render decodes it).
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Id, Name FROM methods", Session.bundled(), catalog,
          ["parent": .integer(1)])
      #expect(rows == [[.integer(1), .text("MyMethod")]])
    }
  }

  @Test func `the bundled params view yields params bound by their method Id`() throws {
    // `MethodDef` Id 1 owns the three `Param` rows; binding `:parent` to it
    // yields each parameter's `Id`, `Name`, and `Sequence` (the type is no
    // longer a column — the render navigates from these and decodes it).
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Id, Name, Sequence FROM params", Session.bundled(),
          catalog, ["parent": .integer(1)])
      #expect(rows == [
        [.integer(1), .text(""), .integer(0)],
        [.integer(2), .text("first"), .integer(1)],
        [.integer(3), .text(""), .integer(2)],
      ])
    }
  }

  @Test func `a registered view is queryable through the session catalog`() throws {
    // `CREATE VIEW guids …` registers a view decoding `CustomAttribute.Value`
    // through the `GUID` UDF; a `SELECT … FROM guids` then resolves it through
    // the session catalog and yields the view's rows. The fixture's single
    // `CustomAttribute` is the `GuidAttribute`, so its `GUID(Value)` is the
    // well-known value.
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW guids AS "
          + "SELECT GUID(Value) AS guid FROM CustomAttribute "
          + "WHERE GUID(Value) IS NOT NULL")
      let rows = try DatabaseSQLTests.run(
          "SELECT guid FROM guids", [name: view], catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test func `a session CREATE FUNCTION helper is visible to the render routines`() throws {
    // The bug: the render composed its routine set from the STATIC prelude
    // (`language.routines.merging(Session.routines)`), NOT the session's own
    // routines, so a helper a session `CREATE FUNCTION` defined — reachable
    // from an ordinary `SELECT`/`.schema`, which resolve through
    // `session.functions` — was invisible to the render, faulting
    // `SQLError.function`. The render now merges `session.functions`, so the
    // helper is visible there too, at parity with the non-render paths.
    //
    // A stand-in for `language.routines` (the target-language spec's UDFs the
    // render always merges) stands for the render's base; the fix is that the
    // session's routines — not the static prelude — are merged over it.
    try DatabaseSQLTests.with { catalog in
      var session = Session(catalog, Session.bundled())
      _ = try session.run("CREATE FUNCTION twice(n INTEGER) RETURNS INTEGER "
                          + "AS n + n")
      let language = try Routines().registering("sanitize", returns: .text,
                                                parameters: [.text]) { $0[0] }
      // The OLD render composition — the static prelude, WITHOUT the
      // session's routines — cannot resolve the session helper.
      let stale = language.merging(Session.routines)
      #expect(stale["twice"] == nil)
      // The FIXED render composition merges the session's routines, so the
      // helper resolves and a render query naming it runs.
      let routines = language.merging(session.functions)
      #expect(routines["twice"] != nil)
      guard case let .select(select) =
          try Statement(parsing: "SELECT twice(Id) FROM TypeDef") else {
        Issue.record("not a SELECT")
        return
      }
      let rows = try session.run(select, routines)
      #expect(rows == [[.integer(2)], [.integer(4)]])
    }
  }

  @Test func `a view is resolved case-insensitively`() throws {
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

  @Test func `a session enumerates its registered views for introspection`() throws {
    // The session implements `Catalog.views()` off its registered set, the
    // surface the `INFORMATION_SCHEMA` overlay lists with a `'VIEW'` table type.
    // A session over one registered view enumerates exactly that view's name.
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW named AS SELECT TypeName FROM TypeDef")
      let session = Session(catalog, [name: view])
      #expect(session.views() == ["named"])
    }
  }

  @Test func `a session view is listed in information_schema.tables`() throws {
    // The session's registered views appear in the `INFORMATION_SCHEMA` overlay
    // with a `'VIEW'` table type, enumerated beside the storage's base tables —
    // the feature over the real WinMD catalog, not just an in-memory fixture.
    // The engine-provided `information_schema.` views are listed too.
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW named AS SELECT TypeName FROM TypeDef")
      let rows = try DatabaseSQLTests.run("""
          SELECT table_name FROM information_schema.tables
           WHERE table_type = 'VIEW' ORDER BY table_name
          """, [name: view], catalog)
      #expect(rows == [
        [.text("information_schema.columns")],
        [.text("information_schema.tables")],
        [.text("named")],
      ])
    }
  }

  @Test func `information_schema.columns types the GUID view column as text`() throws {
    // The bundled `interfaces` view projects `GUID(c.Value) AS iid`; `GUID`
    // declares a `.text` return type, so `information_schema.columns` reports
    // `iid`'s `data_type` as `character varying` rather than the integer
    // default a scalar call fell to before routines carried a return type.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run("""
          SELECT data_type FROM information_schema.columns
           WHERE table_name = 'interfaces' AND column_name = 'iid'
          """, Session.bundled(), catalog)
      #expect(rows == [[.text("character varying")]])
    }
  }

  @Test func `the render decode spells a method's return from its signature`() {
    // The render decodes a return at render time (not through a virtual column):
    // `MethodDef` Id 1's signature `void Method(i4, string)` decodes its
    // return to `Void`.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.decode(return: 1, in: .swift) == "Void")
    }
  }

  @Test func `the interfaces view excludes a type with no GuidAttribute`() throws {
    // `INotGuid` (TypeDef row 2) carries no `GuidAttribute`, so the view's
    // navigation finds no matching `CustomAttribute` chain for it: it does not
    // appear, leaving only `IMyInterface`.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName FROM interfaces", Session.bundled(), catalog)
      #expect(rows == [[.text("IMyInterface")]])
    }
  }

  @Test func `the interfaces view resolves a same-module MethodDef-ctor IID`() throws {
    // When `GuidAttribute` is defined in the same file, a type's
    // `CustomAttribute.Type` names the attribute's `.ctor` directly as a
    // `MethodDef` (not a cross-module `MemberRef`), so the `MemberRef` chains
    // find nothing: the view's `Type_MethodDef → MethodDef.TypeDef → TypeDef`
    // arm navigates it instead. `IThing` carries such an attribute, so the view
    // resolves its IID.
    try SameModuleGuidFixture.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT iid FROM interfaces WHERE TypeName = 'IThing'",
          Session.bundled(), catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test func `the interfaces view resolves a same-module MemberRef-ctor IID`() throws {
    // A same-file constructor can also be encoded as a `MemberRef` whose
    // `Class` points back at the in-file `GuidAttribute` `TypeDef`, so the
    // decoded key is `Class_TypeDef`, not `Class_TypeRef`, and the cross-module
    // `MemberRef → TypeRef` arm drops it. The view's third arm,
    // `Type_MemberRef → MemberRef.Class_TypeDef → TypeDef`, resolves it —
    // `IOther` carries such an attribute.
    try SameModuleGuidFixture.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT iid FROM interfaces WHERE TypeName = 'IOther'",
          Session.bundled(), catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test func `the interfaces view excludes a GuidAttribute-carrying non-interface`() throws {
    // `CThing` is a coclass — a `TypeDef` carrying a `GuidAttribute` yet whose
    // `Flags` clear the `tdInterface` (0x20) bit. Not every GUID-bearing type
    // is a COM interface, so the view's `BITAND(t.Flags, 32) = 32` filter drops
    // it, leaving only the interfaces `IThing` and `IOther`.
    try SameModuleGuidFixture.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName FROM interfaces", Session.bundled(), catalog)
      #expect(rows == [[.text("IThing")], [.text("IOther")]])
    }
  }

  @Test func `the GUID UDF decodes a CustomAttribute's Value blob`() throws {
    // The `GUID` UDF decodes the `GuidAttribute`'s `Value` blob (surfaced as a
    // real `.blob` column) to the well-known UUID as text; the fixture's sole
    // `CustomAttribute` is that attribute.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT GUID(Value) FROM CustomAttribute", catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test func `the SIGNATURE UDF decodes a MethodDef's Signature blob`() throws {
    // The `SIGNATURE` UDF decodes the `MethodDef.Signature` `#Blob` (surfaced
    // as a real `.blob` column) to its return type's neutral spelling; the
    // fixture's sole method's signature is `void Method(i4, string)`, so its
    // return decodes to `void`. This reuses the SAME decoder the render's
    // `decode(return:in:)` navigates a method Id through — here driven off the
    // raw blob cell with no database resolution.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT SIGNATURE(Signature) FROM MethodDef", catalog)
      #expect(rows == [[.text("void")]])
    }
  }

  @Test func `the SIGNATURE UDF is NULL on a malformed blob`() throws {
    // A blob that is not a decodable method signature yields SQL NULL,
    // mirroring `GUID`'s NULL-on-mismatch: `x'ff'` (an invalid prolog) does not
    // decode, so the projection is NULL. It resolves through the session's
    // routines, the same set the render binds.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT SIGNATURE(x'ff') FROM MethodDef", catalog)
      #expect(rows == [[.null]])
    }
  }

  @Test func `the SIGNATURE UDF propagates a NULL argument`() throws {
    // A NULL argument propagates to NULL, exactly as `GUID` does — invoked
    // directly against the session's `signature` routine (the dialect has no
    // bare `NULL` literal in expression position, so this exercises the
    // propagation off the routine itself).
    let routine = Session.routines["signature"]
    #expect(try routine?([.null]) == .null)
  }

  @Test func `the bundled signatures view decodes a method's return`() throws {
    // The bundled `signatures` view projects `SIGNATURE(Signature) AS Type`
    // over a `TypeDef`'s methods, bound by `:parent` — the render-facing
    // demonstration of the UDF. `IMyInterface` (Id 1) owns `MyMethod`, whose
    // signature's return decodes to `void`.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Name, Type FROM signatures", Session.bundled(), catalog,
          ["parent": .integer(1)])
      #expect(rows == [[.text("MyMethod"), .text("void")]])
    }
  }

  @Test func `excludes the virtual columns from SELECT *`() throws {
    // `SELECT *` projects exactly the six real `TypeDef` fields — neither
    // `Id` nor an owner-FK column appears — for each of the two fixture types.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run("SELECT * FROM TypeDef", catalog)
      #expect(rows.count == 2)
      #expect(rows[0].count == 6)
    }
  }

  @Test func `the render decode spells a MethodDef's return`() {
    // The signature `void Method(i4, string)` decodes its return to `Void`, the
    // render-time decode replacing the old `ReturnType` virtual column.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.decode(return: 1, in: .swift) == "Void")
    }
  }

  @Test func `the render decode spells each Param, nil for the return parameter`() {
    // The `Sequence == 0` return pseudo-parameter (`Param` Id 1) decodes to
    // `nil`; the two real parameters (Ids 2 and 3) decode to the signature's
    // `i4` (`CInt`) and `string` (`HSTRING`) — the render-time decode replacing
    // the old `ParamType` virtual column.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.decode(parameter: 1, for: .swift) == nil)
      #expect(catalog.decode(parameter: 2, for: .swift) == "CInt")
      #expect(catalog.decode(parameter: 3, for: .swift)
                  == "HSTRING")
    }
  }

  @Test func `the erased-ABI decode keeps a value slot and reports it a value`() {
    // The fixture's `void Method(i4, string)` is all values: the erased-ABI
    // return/parameter spellings (`abi(return:)`/`abi(parameter:)`) coincide
    // with their typed `decode(…)` — a value crosses the ABI as itself — and
    // `reference(…)` reports each a value, so the wrapper forwards it uncast.
    // The reference-slot erasure is exercised by `SignatureType.abi(…)`'s own
    // tests and the erased-shape golden render; the fixture carries no
    // reference slot to drive it end-to-end here.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.abi(return: 1, in: .swift) == "Void")
      #expect(catalog.reference(return: 1) == false)
      #expect(catalog.abi(parameter: 2, for: .swift) == "CInt")
      #expect(catalog.abi(parameter: 3, for: .swift) == "HSTRING")
      #expect(catalog.reference(parameter: 2) == false)
      #expect(catalog.reference(parameter: 3) == false)
    }
  }

  @Test func `the bundled bases view yields the interface's derived bases`() throws {
    // `IMyInterface` is `TypeDef` Id 1; binding `:parent` to its Id
    // navigates `InterfaceImpl.Class = :parent`, and the view UNIONs both arms
    // of the `Interface` coded index: the cross-file `IInspectable` reached
    // through `Interface_TypeRef` → `TypeRef`, and the same-file `INotGuid`
    // reached through `Interface_TypeDef` → `TypeDef`.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT base FROM bases", Session.bundled(), catalog,
          ["parent": .integer(1)])
      #expect(rows == [[.text("IInspectable")], [.text("INotGuid")]])
    }
  }

  @Test func `the bundled bases view is empty for a rootless interface`() throws {
    // `INotGuid` is `TypeDef` Id 2 and has no `InterfaceImpl` row, so the
    // view yields no base — the render's `IUnknown` default path.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT base FROM bases", Session.bundled(), catalog,
          ["parent": .integer(2)])
      #expect(rows.isEmpty)
    }
  }

  @Test func `the bundled bases view resolves a TypeSpec-recorded generic base`() throws {
    // A generic interface inheriting ANOTHER generic interface records the base
    // through a `TypeSpec` (a GENERICINST signature), NOT a
    // `TypeRef`/`TypeDef`, so the plain coded-index arms find nothing. The
    // `TypeSpec` arm joins the spec, decodes its signature to the base token
    // (`GENERICBASE`), and splits the token's tag/row to resolve the base
    // `TypeRef` by `Id` — here `IIterable`1`, the raw arity-suffixed name the
    // render then rewrites to `IIterableABI`.
    try GenericBaseFixture.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT base FROM bases", Session.bundled(), catalog,
          ["parent": .integer(1)])
      #expect(rows == [[.text("IIterable`1")]])
    }
  }

  @Test func `a schema-defined but absent table resolves as an empty relation`() throws {
    // A metadata file omits a table with no rows (its `Valid` bit is clear);
    // the shared fixture carries no `TypeSpec`, so its mask omits table 27.
    // The adapter surfaces the absent-but-schema-defined `TypeSpec` as an EMPTY
    // relation — the six schema columns, zero rows — so a query naming it
    // resolves to no rows rather than faulting `SQLError.relation`. A name no
    // CIL schema bears is still an unknown relation.
    try DatabaseSQLTests.with { catalog in
      // The absent `TypeSpec` resolves and projects its six schema columns with
      // zero rows; a `SELECT *` over it yields nothing rather than faulting.
      let rows = try DatabaseSQLTests.run("SELECT * FROM TypeSpec", catalog)
      #expect(rows.isEmpty)
      // A name no CIL schema bears is still an unknown relation.
      #expect(throws: SQLError.self) {
        _ = try DatabaseSQLTests.run("SELECT * FROM NotACILTable", catalog)
      }
    }
  }

  @Test func `the bundled bases view resolves over a file with no TypeSpec table`() throws {
    // The bundled `bases` view's `TypeSpec` arm references the `TypeSpec`
    // relation UNCONDITIONALLY, and the engine resolves EVERY UNION arm at
    // compile time. Over the shared fixture — which omits the `TypeSpec` table
    // (no generic bases, `Valid` bit clear) — resolving a NON-generic
    // interface's bases must still succeed: the adapter surfaces the absent
    // `TypeSpec` as an empty relation, so the `TypeSpec` arms yield nothing and
    // the plain `TypeRef`/`TypeDef` arms yield the real bases. `IMyInterface`
    // (Id 1) derives `IInspectable` and `INotGuid`; the query does not fault.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT base FROM bases", Session.bundled(), catalog,
          ["parent": .integer(1)])
      #expect(rows == [[.text("IInspectable")], [.text("INotGuid")]])
    }
  }

  @Test func `renders the fixture interface's @com protocol from the views`() throws {
    // The render joins the bundled views — `interfaces` → `methods` → `params`
    // → `bases` — and the Mustache template into the `@com` protocol source.
    // The fixture is `IMyInterface` with the well-known IID and the single
    // `MyMethod`, whose signature decodes to `void Method(i4, string)`: two real
    // parameters (`first: CInt` and the unnamed `string`) and a `Void` return
    // (so no return clause). The base is derived through the `bases` view from
    // the interface's `InterfaceImpl` row — `IInspectable`, not the `IUnknown`
    // default.
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered == """
        @com(interface: "0C733A30-2A1C-11CE-ADE5-00AA0044773D")
        public protocol IMyInterface: IInspectable {
            func MyMethod(_ first: CInt, _ : \
        HSTRING)
        }

        """)
    }
  }

  @Test func `renders the IUnknown default for a rootless interface`() throws {
    // A `bases`-empty interface (no `InterfaceImpl` row) falls back to the
    // `IUnknown` COM-root convention. The fixture's only IID-carrying type has
    // an `InterfaceImpl`, so this overrides `bases` with a never-matching view
    // (a `Class` no row holds), exercising the default branch while still
    // rendering `IMyInterface` from the other views.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      let query = """
        CREATE VIEW bases AS SELECT b.TypeName AS base FROM InterfaceImpl i
        JOIN TypeRef b ON i.Interface_TypeRef = b.Id
        WHERE i.Class = :parent AND i.Class = 0
        """
      let (name, view) = try DatabaseSQLTests.create(query)
      shell.session.register(name, view)
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered.contains("public protocol IMyInterface: IUnknown {"))
    }
  }

  @Test func `the root interface renders with no base, not self-inheritance`() throws {
    // When the rendered interface is the COM root itself (`IUnknown`), it
    // implements nothing, so `bases` is empty. The root default must not then
    // make it its own base — `public protocol IUnknown: IUnknown` is invalid
    // Swift and would block rendering a winmd that defines the root. The render
    // omits the inheritance clause entirely.
    try RootInterfaceFixture.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render("IUnknown", template: "com")
      #expect(rendered.contains("public protocol IUnknown {"))
      #expect(!rendered.contains("IUnknown:"))
    }
  }

  @Test func `a keyword base interface name is escaped in the inheritance clause`() throws {
    // A base whose `TypeName` is a Swift keyword (`protocol`, `repeat`, …) must
    // be escaped in the `: <base>` clause, exactly as the interface, method, and
    // parameter names are — otherwise `public protocol IMyInterface: protocol`
    // would not compile. Overriding `bases` to yield a keyword base drives the
    // render's `SANITIZE(base)`.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      let query = """
        CREATE VIEW bases AS
        SELECT 'protocol' AS base FROM TypeDef WHERE Id = :parent
        """
      let (name, view) = try DatabaseSQLTests.create(query)
      shell.session.register(name, view)
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered.contains("public protocol IMyInterface: `protocol` {"))
    }
  }

  @Test func `an unknown interface name raises a clear render error`() {
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.interface("IMissing")) {
        try shell.render("IMissing", template: "com")
      }
    }
  }

  @Test func `execute routes .render <iface> <tmpl> to the render command`() throws {
    // The leading-token dispatch matches `.render` to `Render`, which renders
    // the named interface through the named template (here the fixture's
    // `IMyInterface` through `com`, so `execute` succeeds). Anything but two
    // fields `execute` rejects as unknown — the `Render` command's guard — so a
    // no-argument `.render` and a one-argument `.render IMyInterface` (missing
    // template) both throw.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".render IMyInterface com")
      #expect(throws: Shell.MetaError.unknown(".render")) {
        try shell.execute(".render")
      }
      #expect(throws: Shell.MetaError.unknown(".render")) {
        try shell.execute(".render IMyInterface")
      }
    }
  }

  @Test func `* renders every interface in the views`() throws {
    // `*` drops the name filter and loops every interface; this fixture's
    // `interfaces` view holds only `IMyInterface` (the IID-carrying type), so
    // the sweep emits its protocol — exercising the no-filter `*` path.
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render("*", template: "com")
      #expect(rendered.contains("public protocol IMyInterface"))
    }
  }


  @Test func `a coded-index join key decodes to the target's Id`() throws {
    // `CustomAttribute[0].Parent` is `HasCustomAttribute(TypeDef row 1)`, so
    // the `Parent_TypeDef` key decodes to the owning `TypeDef`'s 1-based Id.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT Parent_TypeDef FROM CustomAttribute", catalog)
      #expect(rows == [[.integer(1)]])
    }
  }

  @Test func `a coded-index join key is NULL when it points elsewhere`() throws {
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

  @Test func `a coded-index join key is excluded from SELECT *`() throws {
    // `SELECT *` projects exactly the three real `CustomAttribute` fields —
    // neither the virtuals nor the coded-index join keys appear.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT * FROM CustomAttribute", catalog)
      #expect(rows.count == 1)
      #expect(rows[0].count == 3)
    }
  }

  @Test func `a coded-index join key joins a CustomAttribute to its owning TypeDef`() throws {
    // Joining `CustomAttribute` to `TypeDef` on the decoded `Parent_TypeDef`
    // key against the `TypeDef`'s Id pairs the `GuidAttribute` row (its
    // `GUID(Value)` IID) with the `IMyInterface` type it decorates, end to end
    // across the coded index.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeDef.TypeName, GUID(CustomAttribute.Value) "
          + "FROM CustomAttribute "
          + "JOIN TypeDef ON CustomAttribute.Parent_TypeDef = TypeDef.Id",
          catalog)
      #expect(rows == [
        [.text("IMyInterface"),
         .text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")],
      ])
    }
  }

  @Test func `a script's CREATE VIEW is visible to a later statement's SELECT`() throws {
    // The batch driver seeds the bundled views and threads one shared `Session`
    // across every statement, so a `CREATE VIEW` registered by one statement is
    // visible to a later `SELECT`. `execute` prints rather than returning rows,
    // so this drives the shared statement path directly — `Shell.execute` over
    // the same session — to register the view (the `CREATE VIEW` branch), then
    // resolves a `SELECT` naming it through the session's views, the exact
    // session state the batch threads.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute("CREATE VIEW names AS SELECT TypeName FROM TypeDef")
      #expect(shell.session.registered.keys.contains("names"))
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName FROM names", shell.session.registered, catalog)
      #expect(rows == [[.text("IMyInterface")], [.text("INotGuid")]])
    }
  }

  @Test func `a .bind value threads into a later parameterized SELECT`() throws {
    // `.bind` stores a `:name` in the shell's `bindings`, which `execute`'s SQL
    // path forwards to `Session.run(_, bindings:)`. Binding `:name` to a
    // `TypeName` the fixture carries, then running `WHERE TypeName = :name`
    // through the session with those bindings, returns the one matching row —
    // the exact thread `execute` performs. An unbound `:name` is UNKNOWN, so it
    // admits no row.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".bind name 'IMyInterface'")
      #expect(shell.bindings["name"] == .text("IMyInterface"))
      let query = "SELECT TypeName FROM TypeDef WHERE TypeName = :name"
      let rows = try shell.session.run(query, bindings: shell.bindings)
      #expect(rows == [[.text("IMyInterface")]])
      // The other fixture type does not match the binding, so it is excluded.
      try shell.execute(".bind name 'INotGuid'")
      let others = try shell.session.run(query, bindings: shell.bindings)
      #expect(others == [[.text("INotGuid")]])
      // Clearing the binding (a `.bind` with no value) unbinds `:name`. An
      // unbound parameter is UNKNOWN, not a value, so the predicate admits no
      // row — the same query now yields nothing rather than matching a type.
      try shell.execute(".bind name")
      #expect(shell.bindings["name"] == nil)
      let unbound = try shell.session.run(query, bindings: shell.bindings)
      #expect(unbound.isEmpty)
    }
  }

  @Test func `a .bind value threads into a WITH statement's parameterized body`() throws {
    // A `:name` in a `WITH` body must bind from the shell's `.bind` values the
    // same way a plain `SELECT`'s does — `Session.run` forwards `bindings` to
    // the WITH arm. Binding `:name` to a `TypeName` the fixture carries, then
    // running a `WITH` whose CTE filters `WHERE TypeName = :name`, returns the
    // one matching row. An unbound `:name` is UNKNOWN, so it admits nothing —
    // the same behaviour the plain-SELECT arm exhibits.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".bind name 'IMyInterface'")
      let query = """
          WITH t (n) AS (SELECT TypeName FROM TypeDef WHERE TypeName = :name)
            SELECT n FROM t
          """
      let rows = try shell.session.run(query, bindings: shell.bindings)
      #expect(rows == [[.text("IMyInterface")]])
      // Rebinding to the other fixture type matches only it — the binding, not a
      // default empty map, resolves the WITH body's parameter.
      try shell.execute(".bind name 'INotGuid'")
      let others = try shell.session.run(query, bindings: shell.bindings)
      #expect(others == [[.text("INotGuid")]])
      // An unbound parameter is UNKNOWN, so the predicate admits no row.
      try shell.execute(".bind name")
      let unbound = try shell.session.run(query, bindings: shell.bindings)
      #expect(unbound.isEmpty)
    }
  }

  @Test func `a .template registers an inline body that shadows a file lookup`() throws {
    // `.template` stores its body in the shell's `templates`, and
    // `template(named:)` returns it (unescaped) when present — an inline
    // template shadows the `-I`/bundle resolution. Registering `com` (the one
    // bundled template) with an inline body proves the shadow: the resolver
    // returns the inline text, not the bundled file.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".template com 'inline: it''s {{name}}'")
      #expect(shell.templates["com"] == "inline: it's {{name}}")
      // The resolver returns the inline body verbatim, shadowing the bundle.
      #expect(try shell.template(named: "com", search: []) ==
              "inline: it's {{name}}")
    }
  }

  @Test func `a .render through an inline template renders the interface`() throws {
    // The end-to-end pipeline: define an inline template, then `.render` an
    // interface through it. The fixture's `IMyInterface` renders through a
    // minimal inline template (no language directive — the identity language
    // leaves the body verbatim), proving the inline template feeds the render.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".template mine 'interface {{name}}'")
      let rendered = try shell.render("IMyInterface", template: "mine")
      #expect(rendered == "interface IMyInterface")
    }
  }

  @Test func `the bundled com template renders a non-generic interface unchanged`() throws {
    // The fixture's `IMyInterface` (non-generic) renders through the REAL
    // bundled `com` template: the `{{^generic}}` arm emits today's `@com`
    // protocol shape unchanged — a static `@com(interface:)` IID, `public
    // protocol` with its `: IInspectable` base, and one `func` per method —
    // with no generic-wrapper output. This pins the non-generic output
    // byte-for-byte so the generic split cannot perturb it.
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered == """
        @com(interface: "0C733A30-2A1C-11CE-ADE5-00AA0044773D")
        public protocol IMyInterface: IInspectable {
            func MyMethod(_ first: CInt, _ : HSTRING)
        }

        """)
    }
  }

  @Test func `the bundled com template renders a generic interface projected`() throws {
    // A generic interface renders through the `{{#generic}}` arm of the REAL
    // bundled `com` template in the PROJECTED ABI shape: an ABI protocol
    // generic over the same `ABIProjectable` parameters as the wrapper, whose
    // requirements spell each projected slot as `Element.ABI` (a value's ABI is
    // itself, a reference's the opaque pointer) — no static IID (the WinRT PIID
    // is computed at runtime) — plus a public generic `struct` wrapper
    // `IVector<Element: ABIProjectable>` keeping the typed surface, its `base` a
    // parameterised `any IVectorABI<Element>` existential, each method
    // projecting between the typed value and its ABI form through
    // `toABI()`/`fromABI(_:)`. Here `GetAt` returns the generic `Element`, so
    // the ABI protocol returns `Element.ABI` and the wrapper reconstructs the
    // typed result as `Element.fromABI(…)` — size-correct for a value AND a
    // reference instantiation, NO fixed-size pointer cast; the `index` parameter
    // is a value (`CUnsignedInt`), passed through unconverted. The context is
    // built the way the render loop assembles it for an `IVector`-like ``1`
    // type.
    let body = try DatabaseSQLTests.template(named: "com")
    let template = try MustacheTemplate(string: body)
    let context: [String: Any] = [
      "name": "IVector",
      "abi": "IVectorABI",
      "iid": "00000000-0000-0000-0000-000000000000",
      "namespace": "Windows.Foundation.Collections",
      "generic": true,
      "generics": [["name": "Element", "last": true]],
      "methods": [
        [
          "name": "GetAt",
          "params": [
            ["name": "index", "local": "index", "type": "CUnsignedInt",
             "typed": "CUnsignedInt", "argument": "index", "last": true],
          ],
          "returns": "Element.ABI",
          "typed": "Element",
          "call": "Element.fromABI(base.GetAt(index))",
        ],
      ],
    ]
    #expect(template.render(context) == """
      // A WinRT parameterised interface projects its generic slots through each
      // element's associated ABI type (the windows-rs `Type::Abi` mechanism): a
      // value slot crosses the vtable as the value itself (`Element.ABI == Element`),
      // a reference slot as the opaque interface pointer (`Element.ABI ==
      // UnsafeMutableRawPointer`). The ABI protocol is therefore generic over the
      // same `ABIProjectable` parameters as the wrapper, and each requirement spells
      // its projected slots as `<Element>.ABI` — size-correct for a value AND a
      // reference instantiation, never a fixed-size raw-pointer cast. It has no
      // static IID: a parameterised interface's IID is a per-instantiation PIID
      // computed at runtime from the type arguments, so no `@com(interface:)` is
      // emitted on the ABI protocol or the wrapper — the runtime projection supplies
      // it.
      internal protocol IVectorABI<Element> {
          associatedtype Element: ABIProjectable
          func GetAt(_ index: CUnsignedInt) -> Element.ABI
      }

      // The public generic wrapper keeps the typed Swift surface: each method takes
      // and returns the decoded typed parameters, projecting between the typed value
      // and its ABI form through the element's `ABIProjectable` conformance
      // (`toABI()`/`fromABI(_:)`) as it forwards through `base` to the ABI protocol
      // — the size-correct analogue of windows-rs's `transmute_copy` across the
      // vtable. A value slot projects by identity, so it forwards unchanged.
      public struct IVector<Element: ABIProjectable> {
          internal let base: any IVectorABI<Element>
          public func GetAt(_ index: CUnsignedInt) -> Element {
              Element.fromABI(base.GetAt(index))
          }
      }

      """)
  }

  @Test func `a generic interface whose stripped name is a keyword renders escaped`() throws {
    // A generic type named `protocol``1` strips to the reserved word
    // `protocol`, which the render escapes to the backticked `` `protocol` ``
    // for the wrapper `struct` name. The ABI-protocol name is a DIFFERENT
    // spelling: it suffixes `ABI` onto the stripped name BEFORE escaping, so it
    // is the plain `protocolABI` (no Swift keyword ends in `ABI`, so the escape
    // is a no-op). Suffixing `ABI` onto the ALREADY-escaped `` `protocol` ``
    // would splice a backtick pair into the middle (`` `protocol`ABI ``), which
    // Swift cannot parse. The wrapper `struct` keeps the escaped bare name
    // (`` `protocol`<Element> ``); the ABI protocol's declaration and the
    // wrapper's `base: any …<Element>` existential both spell `protocolABI`.
    // Overriding `interfaces` to yield a suffixed keyword name over the
    // fixture's generic-aware storage drives the render's generic arm;
    // `methods` and `bases` are emptied so the output is the declaration shell
    // alone.
    try DatabaseSQLTests.withGenerics { catalog in
      var shell = Shell(catalog)
      let interfaces = """
        CREATE VIEW interfaces AS
        SELECT Id, TypeNamespace, 'protocol`1' AS TypeName,
               '00000000-0000-0000-0000-000000000000' AS iid
        FROM TypeDef WHERE Id = 1
        """
      let generics = """
        CREATE VIEW generics AS
        SELECT 'Element' AS Name, 0 AS Number FROM TypeDef WHERE Id = :parent
        """
      let methods = """
        CREATE VIEW methods AS
        SELECT Id, '' AS Name FROM TypeDef WHERE 0 = 1
        """
      let bases = """
        CREATE VIEW bases AS SELECT '' AS base FROM TypeDef WHERE 0 = 1
        """
      for query in [interfaces, generics, methods, bases] {
        let (name, view) = try DatabaseSQLTests.create(query)
        shell.session.register(name, view)
      }
      let rendered = try shell.render("protocol`1", template: "com")
      #expect(rendered == """
        // A WinRT parameterised interface projects its generic slots through each
        // element's associated ABI type (the windows-rs `Type::Abi` mechanism): a
        // value slot crosses the vtable as the value itself (`Element.ABI == Element`),
        // a reference slot as the opaque interface pointer (`Element.ABI ==
        // UnsafeMutableRawPointer`). The ABI protocol is therefore generic over the
        // same `ABIProjectable` parameters as the wrapper, and each requirement spells
        // its projected slots as `<Element>.ABI` — size-correct for a value AND a
        // reference instantiation, never a fixed-size raw-pointer cast. It has no
        // static IID: a parameterised interface's IID is a per-instantiation PIID
        // computed at runtime from the type arguments, so no `@com(interface:)` is
        // emitted on the ABI protocol or the wrapper — the runtime projection supplies
        // it.
        internal protocol protocolABI<Element>: IUnknown {
            associatedtype Element: ABIProjectable
        }

        // The public generic wrapper keeps the typed Swift surface: each method takes
        // and returns the decoded typed parameters, projecting between the typed value
        // and its ABI form through the element's `ABIProjectable` conformance
        // (`toABI()`/`fromABI(_:)`) as it forwards through `base` to the ABI protocol
        // — the size-correct analogue of windows-rs's `transmute_copy` across the
        // vtable. A value slot projects by identity, so it forwards unchanged.
        public struct `protocol`<Element: ABIProjectable> {
            internal let base: any protocolABI<Element>
        }

        """)
    }
  }

  @Test func `a generic interface inheriting a non-generic base keeps it plain`() throws {
    // A generic interface may inherit a NON-generic base — `IInspectable`, a
    // plain protocol, not a generic one — which arrives through `bases` (a
    // `TypeRef`/`TypeDef` simple name). Its ABI protocol's inheritance clause
    // names that base UNCHANGED (`: IInspectable`, no `ABI` suffix and no
    // arguments): the base is already a protocol and carries no wrapper/ABI
    // split. The `bases` override supplies the plain name; `methods` are
    // emptied so the output is the declaration shell.
    try DatabaseSQLTests.withGenerics { catalog in
      var shell = Shell(catalog)
      let interfaces = """
        CREATE VIEW interfaces AS
        SELECT Id, TypeNamespace, 'IVector`1' AS TypeName,
               '00000000-0000-0000-0000-000000000000' AS iid
        FROM TypeDef WHERE Id = 1
        """
      let generics = """
        CREATE VIEW generics AS
        SELECT 'Element' AS Name, 0 AS Number FROM TypeDef WHERE Id = :parent
        """
      let methods = """
        CREATE VIEW methods AS
        SELECT Id, '' AS Name FROM TypeDef WHERE 0 = 1
        """
      let bases = """
        CREATE VIEW bases AS
        SELECT 'IInspectable' AS base FROM TypeDef WHERE Id = :parent
        """
      for query in [interfaces, generics, methods, bases] {
        let (name, view) = try DatabaseSQLTests.create(query)
        shell.session.register(name, view)
      }
      let rendered = try shell.render("IVector`1", template: "com")
      #expect(rendered == """
        // A WinRT parameterised interface projects its generic slots through each
        // element's associated ABI type (the windows-rs `Type::Abi` mechanism): a
        // value slot crosses the vtable as the value itself (`Element.ABI == Element`),
        // a reference slot as the opaque interface pointer (`Element.ABI ==
        // UnsafeMutableRawPointer`). The ABI protocol is therefore generic over the
        // same `ABIProjectable` parameters as the wrapper, and each requirement spells
        // its projected slots as `<Element>.ABI` — size-correct for a value AND a
        // reference instantiation, never a fixed-size raw-pointer cast. It has no
        // static IID: a parameterised interface's IID is a per-instantiation PIID
        // computed at runtime from the type arguments, so no `@com(interface:)` is
        // emitted on the ABI protocol or the wrapper — the runtime projection supplies
        // it.
        internal protocol IVectorABI<Element>: IInspectable {
            associatedtype Element: ABIProjectable
        }

        // The public generic wrapper keeps the typed Swift surface: each method takes
        // and returns the decoded typed parameters, projecting between the typed value
        // and its ABI form through the element's `ABIProjectable` conformance
        // (`toABI()`/`fromABI(_:)`) as it forwards through `base` to the ABI protocol
        // — the size-correct analogue of windows-rs's `transmute_copy` across the
        // vtable. A value slot projects by identity, so it forwards unchanged.
        public struct IVector<Element: ABIProjectable> {
            internal let base: any IVectorABI<Element>
        }

        """)
    }
  }

  @Test func `a generic interface inheriting a keyword-named base keeps it escaped`() throws {
    // A generic interface may inherit a NON-generic base whose name is a Swift
    // keyword (`protocol`). It arrives through `bases` keyword-ESCAPED by
    // `SANITIZE` as `` `protocol` `` — backticks WRAPPING the identifier, NOT a
    // CLR arity suffix. The base rewrite must tell those escaping backticks
    // apart from an arity backtick (a backtick before a DIGIT) and inherit the
    // escaped name UNCHANGED (`: `protocol``), not mistake it for a generic
    // base and emit a broken `` `protocolABI` ``. The `bases` override supplies
    // the raw keyword; the render query's `SANITIZE` escapes it; `methods` are
    // emptied so the output is the declaration shell.
    try DatabaseSQLTests.withGenerics { catalog in
      var shell = Shell(catalog)
      let interfaces = """
        CREATE VIEW interfaces AS
        SELECT Id, TypeNamespace, 'IVector`1' AS TypeName,
               '00000000-0000-0000-0000-000000000000' AS iid
        FROM TypeDef WHERE Id = 1
        """
      let generics = """
        CREATE VIEW generics AS
        SELECT 'Element' AS Name, 0 AS Number FROM TypeDef WHERE Id = :parent
        """
      let methods = """
        CREATE VIEW methods AS
        SELECT Id, '' AS Name FROM TypeDef WHERE 0 = 1
        """
      let bases = """
        CREATE VIEW bases AS
        SELECT 'protocol' AS base FROM TypeDef WHERE Id = :parent
        """
      for query in [interfaces, generics, methods, bases] {
        let (name, view) = try DatabaseSQLTests.create(query)
        shell.session.register(name, view)
      }
      let rendered = try shell.render("IVector`1", template: "com")
      #expect(rendered.contains("internal protocol IVectorABI<Element>: " +
                                "`protocol` {"))
      #expect(!rendered.contains("protocolABI"))
    }
  }

  @Test func `a generic wrapper forwards a blank parameter under a synthesized name`() throws {
    // The non-generic renderer allows a blank parameter name (`func Foo(_ :
    // T)`), and the projected ABI protocol requirement keeps it blank too, but the
    // wrapper's forwarding method must PASS every argument BY NAME in the call
    // (`base.Foo(arg0)`) — a blank name there expands to an empty argument,
    // dropping the argument or mangling the commas. A blank parameter therefore
    // synthesizes a stable `arg<N>` local, used in BOTH the forwarding method's
    // parameter list (`_ arg0: …`) and the call. This context (built as the
    // render loop assembles one) drives the REAL bundled `com` template: the
    // first parameter is blank (→ `arg0`), the second named (`value`, kept).
    // Both are values here (`CInt`), so their ABI and typed spellings coincide
    // and the call passes the bare locals uncast; the protocol requirement
    // leaves the blank parameter blank (`_ : CInt`). The point under test is
    // the blank-name synthesis, not erasure.
    let body = try DatabaseSQLTests.template(named: "com")
    let template = try MustacheTemplate(string: body)
    let context: [String: Any] = [
      "name": "IPair",
      "abi": "IPairABI",
      "iid": "00000000-0000-0000-0000-000000000000",
      "namespace": "NS",
      "generic": true,
      "generics": [["name": "Element", "last": true]],
      "methods": [
        [
          "name": "Set",
          "params": [
            ["name": "", "local": "arg0", "type": "CInt",
             "typed": "CInt", "argument": "arg0", "last": false],
            ["name": "value", "local": "value", "type": "CInt",
             "typed": "CInt", "argument": "value", "last": true],
          ],
          "call": "base.Set(arg0, value)",
        ],
      ],
    ]
    #expect(template.render(context) == """
      // A WinRT parameterised interface projects its generic slots through each
      // element's associated ABI type (the windows-rs `Type::Abi` mechanism): a
      // value slot crosses the vtable as the value itself (`Element.ABI == Element`),
      // a reference slot as the opaque interface pointer (`Element.ABI ==
      // UnsafeMutableRawPointer`). The ABI protocol is therefore generic over the
      // same `ABIProjectable` parameters as the wrapper, and each requirement spells
      // its projected slots as `<Element>.ABI` — size-correct for a value AND a
      // reference instantiation, never a fixed-size raw-pointer cast. It has no
      // static IID: a parameterised interface's IID is a per-instantiation PIID
      // computed at runtime from the type arguments, so no `@com(interface:)` is
      // emitted on the ABI protocol or the wrapper — the runtime projection supplies
      // it.
      internal protocol IPairABI<Element> {
          associatedtype Element: ABIProjectable
          func Set(_ : CInt, _ value: CInt)
      }

      // The public generic wrapper keeps the typed Swift surface: each method takes
      // and returns the decoded typed parameters, projecting between the typed value
      // and its ABI form through the element's `ABIProjectable` conformance
      // (`toABI()`/`fromABI(_:)`) as it forwards through `base` to the ABI protocol
      // — the size-correct analogue of windows-rs's `transmute_copy` across the
      // vtable. A value slot projects by identity, so it forwards unchanged.
      public struct IPair<Element: ABIProjectable> {
          internal let base: any IPairABI<Element>
          public func Set(_ arg0: CInt, _ value: CInt) {
              base.Set(arg0, value)
          }
      }

      """)
  }

  @Test func `the render synthesizes arg names for blank parameters positionally`() throws {
    // The render loop itself (not just the template) assigns the `arg<N>`
    // local: a `Param` whose `Name` is blank gets a positional `arg0`/`arg1`, a
    // named one keeps its name, so a mix renders `_ arg0: …, _ named: …, _
    // arg2: …`. A single blank parameter forwards as `base.M(arg0)` — no empty
    // argument — and a named parameter is untouched. The fixture's storage
    // decodes the parameter types; `interfaces`/`methods`/`params` are
    // overridden so the one method takes a blank then a named parameter over
    // the fixture's `MethodDef` signature. The forwarding call passes both
    // locals.
    try DatabaseSQLTests.withGenerics { catalog in
      var shell = Shell(catalog)
      let interfaces = """
        CREATE VIEW interfaces AS
        SELECT Id, TypeNamespace, 'IThing`1' AS TypeName,
               '00000000-0000-0000-0000-000000000000' AS iid
        FROM TypeDef WHERE Id = 1
        """
      let generics = """
        CREATE VIEW generics AS
        SELECT 'Element' AS Name, 0 AS Number FROM TypeDef WHERE Id = :parent
        """
      // The fixture's `MethodDef` Id 1 is `void MyMethod(i4, string)`, its two
      // real parameters `Param` Id 2 (Sequence 1, `i4` → `CInt`) and Id 3
      // (Sequence 2, `string` → `HSTRING`). `methods` names the one method;
      // `params` yields those two rows in order but BLANKS the first's `Name`
      // (its type still decodes from the real `Param` Id) and names the second
      // `first`, so the render must synthesize `arg0` for the blank one and
      // keep `first`. The `Sequence` column is non-zero so neither is filtered
      // as the return pseudo-parameter.
      let methods = """
        CREATE VIEW methods AS
        SELECT Id, 'MyMethod' AS Name FROM MethodDef WHERE Id = 1
        """
      let params = """
        CREATE VIEW params AS
        SELECT 2 AS Id, '' AS Name, 1 AS Sequence
        FROM MethodDef WHERE Id = 1
        UNION ALL
        SELECT 3 AS Id, 'first' AS Name, 2 AS Sequence
        FROM MethodDef WHERE Id = 1
        """
      let bases = """
        CREATE VIEW bases AS SELECT '' AS base FROM TypeDef WHERE 0 = 1
        """
      for query in [interfaces, generics, methods, params, bases] {
        let (name, view) = try DatabaseSQLTests.create(query)
        shell.session.register(name, view)
      }
      let rendered = try shell.render("IThing`1", template: "com")
      // The wrapper's forwarding method names the blank parameter `arg0` and
      // keeps `first`; the call passes both. The ABI requirement leaves the
      // blank parameter blank (`_ : CInt`).
      #expect(rendered.contains(
          "public func MyMethod(_ arg0: CInt, _ first: HSTRING) {"))
      #expect(rendered.contains("base.MyMethod(arg0, first)"))
      #expect(rendered.contains("func MyMethod(_ : CInt, _ first: HSTRING)"))
    }
  }

  @Test func `execute routes a .-token to its meta-command`() throws {
    // The leading-token dispatch matches `.help` to `Help`, which prints the
    // command summary, so `execute` succeeds. A SQL statement takes the parse
    // path instead — exercised by `scriptSession` — and `.quit` throws the
    // loop's `Stop` sentinel.
    try DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute(".help")
      #expect(throws: Shell.Stop.self) { try shell.execute(".quit") }
    }
  }

  @Test func `execute rejects an unknown or empty-argument .-command`() {
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

  @Test func `.schema types a query's result columns without running it`() throws {
    // `.schema` prints the query's result columns — the name and type
    // `session.columns(of:)` resolves WITHOUT opening a cursor, the capability
    // the command formats. `TypeDef.TypeName` is a `#Strings` column, so it
    // types `.text`, and the bundled `interfaces` view's `GUID(c.Value) AS iid`
    // types `.text` too — the `GUID` UDF's declared `.text` return, not the
    // integer default a scalar call falls to.
    try DatabaseSQLTests.with { catalog in
      let session = Session(catalog, Session.bundled())
      guard case let .select(query) =
          try Statement(parsing: "SELECT TypeName, iid FROM interfaces") else {
        Issue.record("not a SELECT")
        return
      }
      let columns = try session.columns(of: query, routines: Session.routines)
      #expect(columns == [
        OutputColumn(name: "TypeName", type: .text),
        OutputColumn(name: "iid", type: .text),
      ])
    }
  }

  @Test func `.schema faults on a query that would not run, without running it`() {
    // `.schema` resolves the query the way a run would, so an unknown relation
    // faults `SQLError.relation` exactly as a run would — the dry-run check —
    // rather than silently printing nothing. An empty query is the unknown-meta
    // fault its guard raises.
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: SQLError.relation("NoSuchTable")) {
        try shell.execute(".schema SELECT x FROM NoSuchTable")
      }
      #expect(throws: Shell.MetaError.unknown(".schema")) {
        try shell.execute(".schema")
      }
    }
  }

  @Test func `.schema describes a WITH statement, the shape the shell runs`() {
    // `.schema` routes through the CTE-aware, statement-level derive, so a
    // `WITH` types its trailing query against the CTE scope — the SAME
    // statement the shell runs. The trailing `SELECT n FROM t` resolves `n` off
    // the CTE, so `.schema` succeeds rather than rejecting anything but a bare
    // `SELECT`.
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: Never.self) {
        try shell.execute(
            ".schema WITH t(n) AS (SELECT TypeName FROM TypeDef)"
                + " SELECT n FROM t")
      }
    }
  }

  @Test func `.schema faults a WITH whose body arity contradicts its list`() {
    // The CTE declares ONE column but its body — a `SELECT *` over the
    // six-column `TypeDef` — projects six. The parser cannot catch this (a
    // `SELECT *`'s width is known only at resolution), so a run rejects it with
    // `SQLError.columns`. `.schema` validates the whole statement, so it faults
    // the SAME way rather than advertising the one trusted declared column.
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: SQLError.columns(expected: 6, got: 1)) {
        try shell.execute(
            ".schema WITH t(a) AS (SELECT * FROM TypeDef) SELECT * FROM t")
      }
    }
  }

  @Test func `an empty SELECT frames its REAL column names, not column N`() throws {
    // A `SELECT *` yielding no rows still frames its box, and the headers are
    // the RESOLVED result-schema names (`columns(of:)`), not the positional
    // `column N` a syntactic `SELECT *` would fall back to. A false predicate
    // filters every fixture row, so the result is empty yet the six real
    // `TypeDef` field names frame it. A named projection resolves too.
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(shell.headers(of: "SELECT * FROM TypeDef WHERE 1 = 0", [])
              == ["Flags", "TypeName", "TypeNamespace", "Extends",
                  "FieldList", "MethodList"])
      #expect(shell.headers(of: "SELECT TypeName FROM TypeDef WHERE 1 = 0", [])
              == ["TypeName"])
    }
  }

  @Test func `a non-empty SELECT frames its rows under the resolved headers`() throws {
    // A `SELECT` yielding rows frames them under its resolved headers — the box
    // renderer always heads its grid, so a run with rows keeps the same column
    // names as the empty case. A `CREATE VIEW` is not row output, so `headers`
    // yields nil (nothing printed).
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(shell.headers(of: "SELECT TypeName FROM TypeDef",
                            [[.text("IMyInterface")], [.text("INotGuid")]])
              == ["TypeName"])
      #expect(shell.headers(of: "CREATE VIEW v AS SELECT TypeName FROM TypeDef",
                            []) == nil)
    }
  }

  @Test func `a data-dependent empty result headers without re-validating`() throws {
    // A `WHERE` no fixture row satisfies filters the result to empty, so the
    // projection's `TypeName + 1` (text arithmetic) NEVER evaluates — the run
    // SUCCEEDS with zero rows. The header path then DERIVES the `x` header off
    // the query (`validate: false`), never re-type-checking the reachable-but-
    // unevaluated arithmetic that a validating resolve would fault
    // `SQLError.operand`. The header survives; no error.
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(shell.headers(of:
          "SELECT TypeName + 1 AS x FROM TypeDef WHERE TypeName = 'missing'",
          []) == ["x"])
    }
  }

  @Test func `a WITH's SELECT * over a CTE heads the CTE's columns, not the base`() throws {
    // A CTE `TypeDef` SHADOWS the six-column base `TypeDef`: the run resolves
    // the trailing `SELECT * FROM TypeDef` against the CTE (one column `x`), so
    // the header must too — derived with the CTE scope in place, not the base
    // catalog. The bug this guards headed the six base field names, a
    // column-count mismatch against the one-column result.
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(shell.headers(of:
          "WITH TypeDef(x) AS (SELECT 1) SELECT * FROM TypeDef", [[.integer(1)]])
          == ["x"])
    }
  }

  @Test func `a WITH heads its trailing query's CTE-resolved column names`() throws {
    // The trailing query names columns off the CTE it references: an explicit
    // list `(a, b)` heads `a, b` through the CTE, and a bare-column projection
    // reads the CTE's declared column. Both resolve against the CTE scope.
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(shell.headers(of:
          "WITH t(a, b) AS (SELECT 1, 2) SELECT * FROM t",
          [[.integer(1), .integer(2)]]) == ["a", "b"])
      #expect(shell.headers(of:
          "WITH t(a, b) AS (SELECT 1, 2) SELECT b FROM t",
          [[.integer(2)]]) == ["b"])
    }
  }

  @Test func `a WITH not shadowing a base heads its trailing SELECT * real names`() throws {
    // A CTE whose name does NOT collide with a base relation leaves the base
    // reachable: the trailing `SELECT * FROM TypeDef` resolves the six real
    // base columns, and the unrelated CTE scope does not perturb them.
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(shell.headers(of:
          "WITH t(x) AS (SELECT 1) SELECT * FROM TypeDef", [])
          == ["Flags", "TypeName", "TypeNamespace", "Extends",
              "FieldList", "MethodList"])
    }
  }

  @Test func `.schema still faults a data-dependently ill-typed query`() {
    // The validating default a static shape check keeps: `.schema` reports an
    // ill-typed query even when a data-dependent filter would spare it at run.
    // The SAME `TypeName + 1` the derive-only header renders faults here — the
    // filter is not statically false, so the projection is reachable and its
    // text arithmetic type-checks to `SQLError.operand`; `.schema` is a dry-run
    // TYPE check, not a run.
    DatabaseSQLTests.with { catalog in
      var shell = Shell(catalog)
      #expect(throws: SQLError.self) {
        try shell.execute(
            ".schema SELECT TypeName + 1 AS x FROM TypeDef WHERE TypeName = ''")
      }
    }
  }

  @Test func `a .quit inside a .read file leaves the shell, not just the file`() throws {
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

  @Test func `a .read fault fails an explicit batch fast`() throws {
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

  @Test func `a .read fault is reported and skipped in shell mode`() throws {
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
      #expect(shell.session.registered.keys.contains("ok"))
    }
  }

  @Test func `a script SELECTing a bundled view sees it through the seeded session`() throws {
    // The `script` runner seeds `Session.bundled()`, so a statement may name a
    // bundled view (here `interfaces`) with no explicit `CREATE VIEW` — the gap
    // the old one-shot path (an empty view set) could not span. The session
    // core resolves `interfaces` through the seeded catalog to the only
    // IID-carrying type.
    try DatabaseSQLTests.with { catalog in
      let views = Session.bundled()
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName, iid FROM interfaces", views, catalog)
      #expect(rows == [
        [.text("IMyInterface"),
         .text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")],
      ])
    }
  }

  @Test func `a coded-index join key admits one key per candidate target table`() {
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

  @Test func `an unowned Param's render decode is nil and does not trap`() {
    // A `Param` no `MethodDef` run owns — the `MethodDef` table is present but
    // has zero rows, so its owner resolves to 0 — decodes to `nil` rather than
    // indexing the negative row `owner - 1` through the parent cursor.
    UnownedParamFixture.with { catalog in
      #expect(catalog.decode(parameter: 1, for: .swift) == nil)
    }
  }

  @Test func `a System.Guid Param decodes to CLSID or IID by its Name`() {
    // The signature `void Method(Guid, Guid)` names `System.Guid` parameters;
    // the render decode classifies each by the `Param.Name` hint — `clsid`
    // (Id 2) yields `CLSID`, `iid` (Id 3) yields the default `IID`.
    GuidParamFixture.with { catalog in
      #expect(catalog.decode(parameter: 2, for: .swift) == "CLSID")
      #expect(catalog.decode(parameter: 3, for: .swift) == "IID")
    }
  }

  @Test func `a -I directory's template shadows the bundled one`() throws {
    // A `-I` directory's `Templates/com.mustache` is loaded in place of the
    // bundled template, so the render emits the override's text.
    let root = NSTemporaryDirectory() + "winmd-inspect-\(UUID().uuidString)"
    let templates = root + "/Templates"
    try FileManager.default.createDirectory(atPath: templates,
                                            withIntermediateDirectories: true)
    try Data("OVERRIDDEN {{name}}".utf8)
        .write(to: URL(fileURLWithPath: templates + "/com.mustache"))
    defer { try? FileManager.default.removeItem(atPath: root) }
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog, search: [root])
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered.contains("OVERRIDDEN"))
    }
  }

  @Test func `a -I directory's view joins the bundled ones in the seed`() throws {
    // A `-I` directory's `Queries/extra.sql` adds its view to the seed, while
    // the bundled views (here `interfaces`) remain — the union.
    let root = NSTemporaryDirectory() + "winmd-inspect-\(UUID().uuidString)"
    let queries = root + "/Queries"
    try FileManager.default.createDirectory(atPath: queries,
                                            withIntermediateDirectories: true)
    try Data("CREATE VIEW extra AS SELECT TypeName FROM TypeDef".utf8)
        .write(to: URL(fileURLWithPath: queries + "/extra.sql"))
    defer { try? FileManager.default.removeItem(atPath: root) }
    let views = Session.bundled(search: [root])
    #expect(views.keys.contains("extra"))
    #expect(views.keys.contains("interfaces"))
  }

  @Test func `a search directory without a match falls back to the bundle`() throws {
    // A `-I` directory that holds no matching resource leaves the render on the
    // bundled template and views, so the normal `@com` protocol still renders.
    let root = NSTemporaryDirectory() + "winmd-inspect-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog, search: [root])
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered.contains("public protocol IMyInterface"))
    }
  }

  @Test func `with two -I directories the last one wins`() throws {
    // Both directories carry a `Templates/com.mustache`; the render must use the
    // LAST `-I`'s copy, so a later directory overrides an earlier one.
    let first = NSTemporaryDirectory() + "winmd-inspect-\(UUID().uuidString)"
    let last = NSTemporaryDirectory() + "winmd-inspect-\(UUID().uuidString)"
    for (root, tag) in [(first, "FIRST"), (last, "LAST")] {
      let templates = root + "/Templates"
      try FileManager.default.createDirectory(atPath: templates,
                                              withIntermediateDirectories: true)
      try Data("\(tag) {{name}}".utf8)
          .write(to: URL(fileURLWithPath: templates + "/com.mustache"))
    }
    defer {
      try? FileManager.default.removeItem(atPath: first)
      try? FileManager.default.removeItem(atPath: last)
    }
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog, search: [first, last])
      let rendered = try shell.render("IMyInterface", template: "com")
      #expect(rendered.contains("LAST"))
      #expect(!rendered.contains("FIRST"))
    }
  }
}

/// A fixture whose `Param` row is owned by no `MethodDef` run: the `MethodDef`
/// table is present (so the list link resolves to it) but has zero rows, so the
/// owner of the lone `Param` resolves to 0. `decode(parameter:for:)` must then
/// yield `nil` rather than index a negative `MethodDef` row.
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
/// `clsid`, one named `iid` — so the render decode exercises the
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

/// A fixture whose `GuidAttribute` is defined in the same file, so a type's
/// `CustomAttribute.Type` names its in-file `.ctor` rather than a cross-module
/// `MemberRef → TypeRef`: the `interfaces` view must reach the IID through one
/// of its same-module arms. Both same-file encodings appear — the constructor as
/// a bare `MethodDef` (`IThing`) and as a `MemberRef` whose `Class` points back
/// at the in-file `TypeDef` (`IOther`) — alongside a GUID-bearing non-interface
/// (`CThing`) exercising the `tdInterface` filter.
private enum SameModuleGuidFixture {
  // Five narrow (all-index 2-byte) tables packed back to back in table-number
  // order; the empty `TypeRef` is present (so the view's cross-module arm plans)
  // but contributes no rows. A stored index `N` names the 0-based row `N - 1`; a
  // coded index is `(row << bits) | tag`.
  //
  //   TypeDef[0]:  Flags=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1),
  //                MethodList=1 — the in-file attribute, owning its `.ctor`
  //                MethodDef[0]; the arms' owning `TypeDef` `g`.
  //   TypeDef[1]:  Flags=0x21, TypeName="IThing"(52), TypeNamespace="NS"(49),
  //                MethodList=2 — an interface whose attribute names the ctor
  //                directly as a `MethodDef` (the `Type_MethodDef` arm).
  //   TypeDef[2]:  Flags=0, TypeName="CThing"(59), TypeNamespace="NS"(49),
  //                MethodList=2 — a coclass (tdInterface clear) also carrying
  //                the `GuidAttribute`, so the view's flag filter excludes it.
  //   TypeDef[3]:  Flags=0x21, TypeName="IOther"(66), TypeNamespace="NS"(49),
  //                MethodList=2 — an interface whose attribute names the ctor as
  //                a `MemberRef` into the in-file `TypeDef` (the `Class_TypeDef`
  //                arm).
  //   MethodDef[0]: Name=0, Signature=0, ParamList=1 — the `GuidAttribute`
  //                `.ctor`, owned by TypeDef[0] (so its `TypeDef` FK is Id 1).
  //   MemberRef[0]: Class=MemberRefParent(TypeDef row 1)=(1<<3)|0=8 — the ctor
  //                reference whose declaring class is the in-file `GuidAttribute`
  //                `TypeDef`, so `Class_TypeDef` (not `Class_TypeRef`) decodes.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 2)=(2<<5)|3=67,
  //                Type=CustomAttributeType(MethodDef row 1)=(1<<3)|2=10,
  //                Value=blob[1] — `IThing`'s in-file GUID (MethodDef ctor).
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 3)=(3<<5)|3=99,
  //                Type=CustomAttributeType(MethodDef row 1)=(1<<3)|2=10,
  //                Value=blob[1] — `CThing`'s in-file GUID.
  //   CustomAttribute[2]: Parent=HasCustomAttribute(TypeDef row 4)=(4<<5)|3=131,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `IOther`'s in-file GUID (MemberRef ctor).
  private static let bytes: Array<UInt8> = [
    // TypeDef[0] — GuidAttribute
    0x00, 0x00, 0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] — IThing
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // TypeDef[2] — CThing
    0x00, 0x00, 0x00, 0x00, 0x3b, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // TypeDef[3] — IOther
    0x21, 0x00, 0x00, 0x00, 0x42, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // MethodDef[0] — .ctor
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0..2]
    0x43, 0x00, 0x0a, 0x00, 0x01, 0x00,
    0x63, 0x00, 0x0a, 0x00, 0x01, 0x00,
    0x83, 0x00, 0x0b, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IThing\0CThing\0
  // IOther\0": GuidNamespace@1, GuidName@35, NS@49, IThing@52, CThing@59,
  // IOther@66.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x54, 0x68, 0x69, 0x6e, 0x67, 0x00,
    0x43, 0x54, 0x68, 0x69, 0x6e, 0x67, 0x00,
    0x49, 0x4f, 0x74, 0x68, 0x65, 0x72, 0x00,
  ]

  // A `#Blob` heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the GUID as `u32, u16, u16, u8×8`,
  // then NumNamed 0), preceded by its length 0x14. The GUID is the well-known
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 0, range: 0 ..< 0,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 4, range: 0 ..< 56,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 56 ..< 70,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 70 ..< 76,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 3, range: 76 ..< 94,
                wide: 0, stride: 6),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 10) | (1 << 12)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }
}

/// A fixture whose sole interface is the COM root `IUnknown` itself — an
/// in-file `GuidAttribute`-carrying `TypeDef` with no `InterfaceImpl` — so
/// `bases` is empty and the render must omit the inheritance clause rather than
/// make `IUnknown` inherit itself.
private enum RootInterfaceFixture {
  // Four narrow (all-index 2-byte) tables packed back to back in table-number
  // order; the empty `TypeRef` and `MemberRef` are present so the `interfaces`
  // view's cross-module arms plan. A stored index `N` names the 0-based row
  // `N - 1`; a coded index is `(row << bits) | tag`.
  //
  //   TypeDef[0]:  Flags=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1),
  //                MethodList=1 — the in-file attribute, owning its `.ctor`.
  //   TypeDef[1]:  Flags=0x21, TypeName="IUnknown"(52), TypeNamespace="NS"(49),
  //                MethodList=2 — the COM root interface, carrying the
  //                `GuidAttribute` yet implementing nothing (no `InterfaceImpl`).
  //   MethodDef[0]: Name=0, Signature=0, ParamList=1 — the `GuidAttribute`
  //                `.ctor`, owned by TypeDef[0].
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 2)=(2<<5)|3=67,
  //                Type=CustomAttributeType(MethodDef row 1)=(1<<3)|2=10,
  //                Value=blob[1] — `IUnknown`'s in-file GUID.
  private static let bytes: Array<UInt8> = [
    // TypeDef[0] — GuidAttribute
    0x00, 0x00, 0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] — IUnknown
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // MethodDef[0] — .ctor
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // CustomAttribute[0]
    0x43, 0x00, 0x0a, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IUnknown\0":
  // GuidNamespace@1, GuidName@35, NS@49, IUnknown@52.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x55, 0x6e, 0x6b, 0x6e, 0x6f, 0x77, 0x6e, 0x00,
  ]

  // A `#Blob` heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the GUID, then NumNamed 0), preceded
  // by its length 0x14. The GUID is the well-known
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 0, range: 0 ..< 0,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 0 ..< 28,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 28 ..< 42,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 42 ..< 42,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 0, range: 42 ..< 42,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 42 ..< 48,
                wide: 0, stride: 6),
    // No `TypeSpec` table: the root implements nothing, so the file omits it
    // (its `Valid` bit is clear) as a real WinMD does. The bundled `bases`
    // view's `TypeSpec` arm still resolves — the adapter surfaces the absent
    // table as an empty relation.
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 9) | (1 << 10) | (1 << 12)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }
}

/// A minimal WinMD whose one generic interface inherits ANOTHER generic
/// interface, the base recorded through a `TypeSpec` GENERICINST signature —
/// the shape the bundled `bases` view's `TypeSpec` arm resolves.
///
///   TypeRef[0]:  Name="IIterable`1"(1) — the generic base, arity-suffixed.
///   TypeDef[0]:  Flags=0x21, TypeName="IVector`1"(13) — the generic interface
///                (Id 1), the `InterfaceImpl.Class` the `bases` view binds.
///   InterfaceImpl[0]: Class=1; Interface=TypeDefOrRef(TypeSpec row 1)=
///                (1<<2)|2=6 — the base named through a `TypeSpec`, so neither
///                the `Interface_TypeRef` nor `Interface_TypeDef` arm sees it.
///   TypeSpec[0]: Signature=blob[1] — `IIterable`1<T>`, a GENERICINST over the
///                base `TypeRef` with one type-variable argument.
private enum GenericBaseFixture {
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] — IIterable`1: ResolutionScope=0, Name=1, Namespace=0.
    0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    // TypeDef[0] — IVector`1: Flags=0x21, Name=13, Namespace=0, Extends=0,
    // FieldList=1, MethodList=1.
    0x21, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // InterfaceImpl[0] — Class=1, Interface=6 (TypeSpec row 1).
    0x01, 0x00, 0x06, 0x00,
    // TypeSpec[0] — Signature=blob[1].
    0x01, 0x00,
  ]

  // "\0IIterable`1\0IVector`1\0": IIterable`1@1, IVector`1@13.
  private static let strings: Array<UInt8> = [
    0x00,
    0x49, 0x49, 0x74, 0x65, 0x72, 0x61, 0x62, 0x6c, 0x65, 0x60, 0x31, 0x00,
    0x49, 0x56, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x60, 0x31, 0x00,
  ]

  // A `#Blob` heap: offset 0 the reserved empty blob; offset 1 the 6-byte
  // `IIterable`1<T>` GENERICINST signature — GENERICINST (0x15), CLASS (0x12),
  // the base `TypeRef[0]` coded index (0x05), argument count 1, VAR (0x13) 0 —
  // preceded by its length 0x06.
  private static let blob: Array<UInt8> = [
    0x00,
    0x06, 0x15, 0x12, 0x05, 0x01, 0x13, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 1, range: 6 ..< 20,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 20 ..< 24,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 1, range: 24 ..< 26,
                wide: 0, stride: 2),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 9) | (1 << 27)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }
}
