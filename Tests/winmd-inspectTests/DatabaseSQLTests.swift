// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

import SQL
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

  @Test("the bundled `interfaces` view yields the IID-carrying TypeDef")
  func bundledInterfaces() throws {
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

  @Test("the bundled `methods` view yields a method bound by its parent Id")
  func bundledMethods() throws {
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

  @Test("the bundled `params` view yields params bound by their method Id")
  func bundledParams() throws {
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

  @Test("a registered view is queryable through the session catalog")
  func sessionView() throws {
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

  @Test("a session enumerates its registered views for introspection")
  func sessionViewsEnumerated() throws {
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

  @Test("a session view is listed in information_schema.tables")
  func sessionViewIntrospected() throws {
    // The session's registered views appear in the `INFORMATION_SCHEMA` overlay
    // with a `'VIEW'` table type, enumerated beside the storage's base tables —
    // the feature over the real WinMD catalog, not just an in-memory fixture.
    try DatabaseSQLTests.with { catalog in
      let (name, view) = try DatabaseSQLTests.create(
          "CREATE VIEW named AS SELECT TypeName FROM TypeDef")
      let rows = try DatabaseSQLTests.run("""
          SELECT table_name FROM information_schema.tables
           WHERE table_type = 'VIEW'
          """, [name: view], catalog)
      #expect(rows == [[.text("named")]])
    }
  }

  @Test("information_schema.columns types the GUID view column as text")
  func guidColumnTypedText() throws {
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

  @Test("the render decode spells a method's return from its signature")
  func decodesReturn() {
    // The render decodes a return at render time (not through a virtual column):
    // `MethodDef` Id 1's signature `void Method(i4, string)` decodes its
    // return to `Void`.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.decode(return: 1, in: .swift) == "Void")
    }
  }

  @Test("the `interfaces` view excludes a type with no GuidAttribute")
  func interfacesViewExcludes() throws {
    // `INotGuid` (TypeDef row 2) carries no `GuidAttribute`, so the view's
    // navigation finds no matching `CustomAttribute` chain for it: it does not
    // appear, leaving only `IMyInterface`.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT TypeName FROM interfaces", Session.bundled(), catalog)
      #expect(rows == [[.text("IMyInterface")]])
    }
  }

  @Test("the `interfaces` view resolves a same-module MethodDef-ctor IID")
  func interfacesViewSameModuleMethodDefCtor() throws {
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

  @Test("the `interfaces` view resolves a same-module MemberRef-ctor IID")
  func interfacesViewSameModuleMemberRefCtor() throws {
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

  @Test("the `interfaces` view excludes a GuidAttribute-carrying non-interface")
  func interfacesViewExcludesNonInterface() throws {
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

  @Test("the GUID UDF decodes a CustomAttribute's Value blob")
  func guid() throws {
    // The `GUID` UDF decodes the `GuidAttribute`'s `Value` blob (surfaced as a
    // real `.blob` column) to the well-known UUID as text; the fixture's sole
    // `CustomAttribute` is that attribute.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT GUID(Value) FROM CustomAttribute", catalog)
      #expect(rows == [[.text("0C733A30-2A1C-11CE-ADE5-00AA0044773D")]])
    }
  }

  @Test("excludes the virtual columns from SELECT *")
  func star() throws {
    // `SELECT *` projects exactly the six real `TypeDef` fields — neither
    // `Id` nor an owner-FK column appears — for each of the two fixture types.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run("SELECT * FROM TypeDef", catalog)
      #expect(rows.count == 2)
      #expect(rows[0].count == 6)
    }
  }

  @Test("the render decode spells a MethodDef's return")
  func returnType() {
    // The signature `void Method(i4, string)` decodes its return to `Void`, the
    // render-time decode replacing the old `ReturnType` virtual column.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.decode(return: 1, in: .swift) == "Void")
    }
  }

  @Test("the render decode spells each Param, nil for the return parameter")
  func paramType() {
    // The `Sequence == 0` return pseudo-parameter (`Param` Id 1) decodes to
    // `nil`; the two real parameters (rowids 2 and 3) decode to the signature's
    // `i4` (`CInt`) and `string` (`HSTRING`) — the render-time decode replacing
    // the old `ParamType` virtual column.
    DatabaseSQLTests.with { catalog in
      #expect(catalog.decode(parameter: 1, for: .swift) == nil)
      #expect(catalog.decode(parameter: 2, for: .swift) == "CInt")
      #expect(catalog.decode(parameter: 3, for: .swift)
                  == "HSTRING")
    }
  }

  @Test("the bundled `bases` view yields the interface's derived bases")
  func bundledBases() throws {
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

  @Test("the bundled `bases` view is empty for a rootless interface")
  func bundledBasesRoot() throws {
    // `INotGuid` is `TypeDef` Id 2 and has no `InterfaceImpl` row, so the
    // view yields no base — the render's `IUnknown` default path.
    try DatabaseSQLTests.with { catalog in
      let rows = try DatabaseSQLTests.run(
          "SELECT base FROM bases", Session.bundled(), catalog,
          ["parent": .integer(2)])
      #expect(rows.isEmpty)
    }
  }

  @Test("renders the fixture interface's `@com` protocol from the views")
  func render() throws {
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

  @Test("renders the `IUnknown` default for a rootless interface")
  func renderRoot() throws {
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

  @Test("the root interface renders with no base, not self-inheritance")
  func renderRootInterface() throws {
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

  @Test("a keyword base interface name is escaped in the inheritance clause")
  func renderKeywordBase() throws {
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

  @Test("an unknown interface name raises a clear render error")
  func renderUnknown() {
    DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.interface("IMissing")) {
        try shell.render("IMissing", template: "com")
      }
    }
  }

  @Test("execute routes `.render <iface> <tmpl>` to the render command")
  func renderCommand() throws {
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

  @Test("`*` renders every interface in the views")
  func renderAll() throws {
    // `*` drops the name filter and loops every interface; this fixture's
    // `interfaces` view holds only `IMyInterface` (the IID-carrying type), so
    // the sweep emits its protocol — exercising the no-filter `*` path.
    try DatabaseSQLTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render("*", template: "com")
      #expect(rendered.contains("public protocol IMyInterface"))
    }
  }


  @Test("a coded-index join key decodes to the target's Id")
  func codedKeyResolves() throws {
    // `CustomAttribute[0].Parent` is `HasCustomAttribute(TypeDef row 1)`, so
    // the `Parent_TypeDef` key decodes to the owning `TypeDef`'s 1-based Id.
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

  @Test("a script's CREATE VIEW is visible to a later statement's SELECT")
  func scriptSession() throws {
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

  @Test("a `.bind` value threads into a later parameterized SELECT")
  func bindThreadsIntoQuery() throws {
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

  @Test("a `.bind` value threads into a WITH statement's parameterized body")
  func bindThreadsIntoWith() throws {
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

  @Test("a `.template` registers an inline body that shadows a file lookup")
  func templateRegisters() throws {
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

  @Test("a `.render` through an inline template renders the interface")
  func templateRenders() throws {
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
      #expect(shell.session.registered.keys.contains("ok"))
    }
  }

  @Test("a script SELECTing a bundled view sees it through the seeded session")
  func scriptBundledView() throws {
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

  @Test("an unowned Param's render decode is nil and does not trap")
  func paramTypeUnowned() {
    // A `Param` no `MethodDef` run owns — the `MethodDef` table is present but
    // has zero rows, so its owner resolves to 0 — decodes to `nil` rather than
    // indexing the negative row `owner - 1` through the parent cursor.
    UnownedParamFixture.with { catalog in
      #expect(catalog.decode(parameter: 1, for: .swift) == nil)
    }
  }

  @Test("a System.Guid Param decodes to CLSID or IID by its Name")
  func paramTypeGuidClassification() {
    // The signature `void Method(Guid, Guid)` names `System.Guid` parameters;
    // the render decode classifies each by the `Param.Name` hint — `clsid`
    // (Id 2) yields `CLSID`, `iid` (Id 3) yields the default `IID`.
    GuidParamFixture.with { catalog in
      #expect(catalog.decode(parameter: 2, for: .swift) == "CLSID")
      #expect(catalog.decode(parameter: 3, for: .swift) == "IID")
    }
  }

  @Test("a `-I` directory's template shadows the bundled one")
  func searchTemplateOverride() throws {
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

  @Test("a `-I` directory's view joins the bundled ones in the seed")
  func searchViewAddition() throws {
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

  @Test("a search directory without a match falls back to the bundle")
  func searchFallsBackToBundle() throws {
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

  @Test("with two `-I` directories the last one wins")
  func searchLastWins() throws {
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
