// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect
@testable import SQLEngineWinMD

import Mustache
import SQLEngine
@testable import WinMD
import WinMDSynthesis

/// Coverage of the `.render … --closure` transitive-closure walk (Stage 0: the
/// plain base and required-interface edges). Rather than map a `.winmd` file,
/// the fixture assembles two method-less COM interfaces in memory — `IBase` and
/// `IDerived`, each carrying a `GuidAttribute` (so the `interfaces` view names
/// both) with an `InterfaceImpl` naming `IDerived`'s base as the local `IBase`
/// `TypeDef` — and renders the closure over `IDerived`, asserting it emits the
/// base before the interface refining it while the flat render emits `IDerived`
/// alone. The fixture declares no `NestedClass` table, as a real `.winmd`
/// without nested types omits it, so it also proves the adapter synthesises an
/// empty relation for that absent optional table rather than faulting the CTE.
struct RenderClosureTests {
  // Five narrow (all-index 2-byte) tables packed back to back in table-number
  // order — TypeRef (#1, 1 row), TypeDef (#2, 2 rows), InterfaceImpl (#9, 1
  // row), MemberRef (#10, 1 row), CustomAttribute (#12, 2 rows) — plus empty
  // MethodDef (#6) and Param (#8) tables so the render's `methods` view
  // resolves a relation. ECMA-335 rows are 1-based; a coded index is
  // `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IBase"(52),
  //                TypeNamespace="NS"(49), MethodList=1 (empty) — the base.
  //   TypeDef[1]:  Flags=0x21, TypeName="IDerived"(58), TypeNamespace="NS"(49),
  //                MethodList=1 (empty) — the refiner.
  //   InterfaceImpl[0]: Class=2 (TypeDef row 2, IDerived),
  //                Interface=TypeDefOrRef(TypeDef row 1)=(1<<2)|0=4 — names the
  //                local base `IBase`, so `requires` resolves it.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `IBase`'s IID.
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 2)=(2<<5)|3=67,
  //                Type=11, Value=blob[1] — `IDerived`'s IID.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0]
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeDef[0] (IBase)
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] (IDerived)
    0x21, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // InterfaceImpl[0]
    0x02, 0x00, 0x04, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // CustomAttribute[1]
    0x43, 0x00, 0x0b, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IBase\0IDerived\0":
  // GuidNamespace@1, GuidName@35, NS@49, IBase@52, IDerived@58.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x42, 0x61, 0x73, 0x65, 0x00,
    0x49, 0x44, 0x65, 0x72, 0x69, 0x76, 0x65, 0x64, 0x00,
  ]

  // The blob heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the well-known GUID
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`, then NumNamed 0), preceded by its
  // length 0x14. Both interfaces name it, so both carry the same IID.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 6 ..< 34,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 34 ..< 38,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 38 ..< 44,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 44 ..< 56,
                wide: 0, stride: 6),
    // No `NestedClass` table: this fixture has no nested types, so a real
    // `.winmd` would omit it from the tables stream. The `requires` recursive
    // CTE still names `NestedClass`, so the adapter must synthesise an empty
    // relation for the absent optional table — `IDerived`'s base resolves
    // through the `TypeDef` arm regardless.
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

  @Test func `--closure renders the base before the interface refining it`() throws {
    // The closure over `IDerived` follows its plain base edge to the local
    // `IBase` interface and emits both, the base first (a depth-first
    // post-order over the E1 edges). The flat render of `IDerived` emits only
    // `IDerived`, so `--closure` is what pulls the base declaration in.
    try RenderClosureTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IDerived", template: "com")
      #expect(closed.contains("public protocol IBase: IUnknown {"))
      #expect(closed.contains("public protocol IDerived: IBase {"))
      let base = try #require(closed.range(of: "public protocol IBase"))
      let derived = try #require(closed.range(of: "public protocol IDerived"))
      #expect(base.lowerBound < derived.lowerBound)

      let flat = try shell.render("IDerived", template: "com")
      #expect(flat.contains("public protocol IDerived: IBase {"))
      #expect(!flat.contains("public protocol IBase"))
    }
  }

  @Test func `--closure resolves a direct TypeDef base with NestedClass omitted`() throws {
    // A `.winmd` with no nested types omits `NestedClass` from the tables
    // stream, so this fixture declares no such table — yet the `requires`
    // recursive CTE names `NestedClass`. The adapter synthesises an empty
    // relation for the absent optional table, so the closure over `IDerived`
    // still resolves its direct `TypeDef` base and emits `IBase`. Pre-fix the
    // CTE faulted on the missing relation, so `--closure` failed for every
    // otherwise-valid file without nested types.
    try RenderClosureTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IDerived", template: "com")
      #expect(closed.contains("public protocol IBase: IUnknown {"))
      #expect(closed.contains("public protocol IDerived: IBase {"))
    }
  }
}

/// Coverage of the `requires` TypeRef arm's scope gate: an `InterfaceImpl` base
/// named through an externally scoped `TypeRef` that happens to share a local
/// interface's (namespace, name) must not resolve to that local interface. The
/// fixture assembles two method-less COM interfaces — a root `IRoot` and an
/// unrelated local `IStray`, both in namespace `NS` and both carrying a
/// `GuidAttribute` (so the `interfaces` view names both) — with an
/// `InterfaceImpl` naming `IRoot`'s base through a `TypeRef` to (`NS`, `IStray`)
/// whose `ResolutionScope` is an external `AssemblyRef` (tag 2). The closure
/// over `IRoot` names `IStray` in the refinement clause (the edge is genuine)
/// yet must not emit `IStray`'s declaration: the external ref is the frontier.
/// A pre-fix name-only join would have pulled the local `IStray` (and its whole
/// closure) in.
struct RenderClosureScopeTests {
  // Eight tables packed back to back in table-number order — TypeRef (#1, 2
  // rows), TypeDef (#2, 2 rows), MethodDef (#6, empty), Param (#8, empty),
  // InterfaceImpl (#9, 1 row), MemberRef (#10, 1 row), CustomAttribute (#12, 2
  // rows), AssemblyRef (#35, 1 row) — every index narrow (2-byte). ECMA-335
  // rows are 1-based; a coded index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope=ResolutionScope(AssemblyRef row 1)
  //                =(1<<2)|2=6, TypeName="IStray"(58), TypeNamespace="NS"(49) —
  //                an externally scoped ref sharing the local `IStray` identity.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(52),
  //                TypeNamespace="NS"(49), MethodList=1 (empty) — the root.
  //   TypeDef[1]:  Flags=0x21, TypeName="IStray"(58), TypeNamespace="NS"(49),
  //                MethodList=1 (empty) — the unrelated local interface.
  //   InterfaceImpl[0]: Class=1 (TypeDef row 1, IRoot),
  //                Interface=TypeDefOrRef(TypeRef row 2)=(2<<2)|1=9 — names the
  //                external `IStray` ref, so `requires` must drop it.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `IRoot`'s IID.
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 2)=(2<<5)|3=67,
  //                Type=11, Value=blob[1] — `IStray`'s IID.
  //   AssemblyRef[0]: all-zero (an empty external assembly the ref scopes to).
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (external IStray ref)
    0x06, 0x00, 0x3a, 0x00, 0x31, 0x00,
    // TypeDef[0] (IRoot)
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] (IStray)
    0x21, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // InterfaceImpl[0]
    0x01, 0x00, 0x09, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // CustomAttribute[1]
    0x43, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // AssemblyRef[0]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IRoot\0IStray\0":
  // GuidNamespace@1, GuidName@35, NS@49, IRoot@52, IStray@58.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00,
    0x49, 0x53, 0x74, 0x72, 0x61, 0x79, 0x00,
  ]

  // The blob heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the well-known GUID
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`, then NumNamed 0), preceded by its
  // length 0x14. Both interfaces name it, so both carry the same IID.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 40 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 40 ..< 40,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 40 ..< 44,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 44 ..< 50,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 50 ..< 62,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.AssemblyRef.self, rows: 1, range: 62 ..< 82,
                wide: 0, stride: 20),
    // No `NestedClass` table: this fixture has no nested types, so a real
    // `.winmd` would omit it. The `requires` recursive CTE still names it, so
    // the adapter synthesises an empty relation for the absent optional table;
    // the external `IStray` ref's chain terminates at the `AssemblyRef`, so
    // nothing resolves anyway.
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10)
          | (1 << 12) | (1 << 35)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure drops an externally scoped base sharing a local name`() throws {
    // `IRoot`'s only base edge names an external `TypeRef` to (`NS`, `IStray`)
    // whose `ResolutionScope` is an `AssemblyRef`, so `IRoot` refines `IStray`
    // in its clause yet the closure must not emit `IStray`'s declaration — the
    // external ref is the frontier. The pre-fix name-only join matched the
    // local `IStray` interface and would have emitted `public protocol IStray:
    // IUnknown {`; the scope gate keeps that declaration out.
    try RenderClosureScopeTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot: IStray {"))
      // The edge is genuine (the clause names `IStray`) …
      #expect(closed.contains(": IStray"))
      // … but the external ref is a frontier, so no `IStray` declaration.
      #expect(!closed.contains("public protocol IStray"))
    }
  }
}

/// Coverage of the `requires` TypeRef arm's scope-chain walk over a *nested*
/// external reference — the case the pre-fix immediate-scope gate missed. The
/// fixture assembles a root `IRoot` whose base is named through a `TypeRef` to a
/// nested `Widget` whose immediate `ResolutionScope` is another `TypeRef`
/// (`Outer`), whose own scope is an external `AssemblyRef`. Its immediate scope
/// is thus a `TypeRef` — the pre-fix gate (`ResolutionScope_AssemblyRef` and
/// `ResolutionScope_ModuleRef` both null) passed, wrongly localising it — yet
/// its scope chain terminates externally, so `resolved` never reaches its
/// anchor and the reference drops. A local nested interface `Widget` (empty
/// namespace, under a local `Host`) shares the bare name, so the pre-fix
/// name-only join would have emitted `public protocol Widget`; the scope-chain
/// walk keeps that unrelated declaration out.
struct RenderClosureNestedExternalTests {
  // Nine tables packed back to back in table-number order — TypeRef (#1, 3
  // rows), TypeDef (#2, 3 rows), MethodDef (#6, empty), Param (#8, empty),
  // InterfaceImpl (#9, 1 row), MemberRef (#10, 1 row), CustomAttribute (#12, 2
  // rows), AssemblyRef (#35, 1 row), NestedClass (#41, 1 row) — every index
  // narrow (2-byte). ECMA-335 rows are 1-based; a coded index is
  // `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope(AssemblyRef row 1)=(1<<2)|2=6,
  //                TypeName="Outer"(63), TypeNamespace="NS"(49) — the external
  //                enclosing reference.
  //   TypeRef[2]:  ResolutionScope(TypeRef row 2)=(2<<2)|3=11,
  //                TypeName="Widget"(69), TypeNamespace=empty(0) — nested under
  //                `Outer`, so its immediate scope is a `TypeRef`; the chain
  //                terminates at the external `AssemblyRef`.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(52),
  //                TypeNamespace="NS"(49), MethodList=1 (empty) — the root.
  //   TypeDef[1]:  Flags=0 (a plain class), TypeName="Host"(58),
  //                TypeNamespace="NS"(49), MethodList=1 — a local enclosing.
  //   TypeDef[2]:  Flags=0x21, TypeName="Widget"(69), TypeNamespace=empty(0),
  //                MethodList=1 — a local nested interface sharing the bare name.
  //   InterfaceImpl[0]: Class=1 (TypeDef row 1, IRoot),
  //                Interface=TypeDefOrRef(TypeRef row 3)=(3<<2)|1=13 — names the
  //                nested external `Widget` reference.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `IRoot`'s IID.
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 3)=(3<<5)|3=99,
  //                Type=11, Value=blob[1] — the local `Widget`'s IID.
  //   AssemblyRef[0]: all-zero (an empty external assembly the chain scopes to).
  //   NestedClass[0]: NestedClass=3 (TypeDef row 3, Widget), EnclosingClass=2
  //                (TypeDef row 2, Host) — the local `Widget` is nested.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (external Outer ref)
    0x06, 0x00, 0x3f, 0x00, 0x31, 0x00,
    // TypeRef[2] (nested Widget ref under Outer)
    0x0b, 0x00, 0x45, 0x00, 0x00, 0x00,
    // TypeDef[0] (IRoot)
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] (Host)
    0x00, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[2] (local nested Widget)
    0x21, 0x00, 0x00, 0x00, 0x45, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // InterfaceImpl[0]
    0x01, 0x00, 0x0d, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // CustomAttribute[1]
    0x63, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // AssemblyRef[0]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // NestedClass[0]
    0x03, 0x00, 0x02, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IRoot\0Host\0Outer\0
  //  Widget\0": GuidNamespace@1, GuidName@35, NS@49, IRoot@52, Host@58,
  // Outer@63, Widget@69.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00,
    0x48, 0x6f, 0x73, 0x74, 0x00,
    0x4f, 0x75, 0x74, 0x65, 0x72, 0x00,
    0x57, 0x69, 0x64, 0x67, 0x65, 0x74, 0x00,
  ]

  // The blob heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the well-known GUID
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`, then NumNamed 0), preceded by its
  // length 0x14. Both interfaces name it, so both carry the same IID.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 3, range: 0 ..< 18,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 18 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 60 ..< 64,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 64 ..< 70,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 70 ..< 82,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.AssemblyRef.self, rows: 1, range: 82 ..< 102,
                wide: 0, stride: 20),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 102 ..< 106,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10)
          | (1 << 12) | (1 << 35) | (1 << 41)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure drops a nested external base sharing a local name`() throws {
    // `IRoot`'s base names a nested `TypeRef` whose immediate scope is another
    // `TypeRef` (so the pre-fix immediate-scope gate passed) but whose chain
    // terminates at an `AssemblyRef`. The scope-chain walk classifies it
    // external, so the local nested `Widget` sharing the bare name is not
    // pulled in: `IRoot` refines `Widget` in its clause yet no `Widget`
    // declaration is emitted.
    try RenderClosureNestedExternalTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot: Widget {"))
      // The edge is genuine (the clause names `Widget`) …
      #expect(closed.contains(": Widget"))
      // … but the nested external ref is a frontier, so no `Widget` declaration.
      #expect(!closed.contains("public protocol Widget"))
    }
  }
}

/// Coverage of the `requires` TypeRef arm resolving two same-named nested types
/// by their distinct enclosings rather than conflating them. The fixture
/// assembles a root `IRoot` whose base is named through a nested `TypeRef`
/// `Widget` scoped to a local enclosing `A`, plus two local enclosings `A` and
/// `B` each owning a distinct nested interface `Widget` (both empty-namespace,
/// bare name `Widget`, but with different IIDs). A name-only join is ambiguous
/// across the two `Widget`s; the scope-chain walk resolves the reference to
/// `A.Widget` by following its enclosing reference to the local `A`, so only
/// `A`'s `Widget` (its IID) is emitted, never `B`'s.
struct RenderClosureNestedConflationTests {
  // Eight tables packed back to back in table-number order — TypeRef (#1, 3
  // rows), TypeDef (#2, 5 rows), MethodDef (#6, empty), Param (#8, empty),
  // InterfaceImpl (#9, 1 row), MemberRef (#10, 1 row), CustomAttribute (#12, 3
  // rows), NestedClass (#41, 2 rows) — every index narrow (2-byte). ECMA-335
  // rows are 1-based; a coded index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope(Module row 1)=(1<<2)|0=4, TypeName="A"(58),
  //                TypeNamespace="NS"(49) — a top-level, module-scoped
  //                reference to the local enclosing `A`.
  //   TypeRef[2]:  ResolutionScope(TypeRef row 2)=(2<<2)|3=11,
  //                TypeName="Widget"(62), TypeNamespace=empty(0) — nested under
  //                the `A` reference.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(52),
  //                TypeNamespace="NS"(49), MethodList=1 — the root.
  //   TypeDef[1]:  Flags=0 (a plain class), TypeName="A"(58),
  //                TypeNamespace="NS"(49), MethodList=1 — a local enclosing.
  //   TypeDef[2]:  Flags=0, TypeName="B"(60), TypeNamespace="NS"(49),
  //                MethodList=1 — the other local enclosing.
  //   TypeDef[3]:  Flags=0x21, TypeName="Widget"(62), TypeNamespace=empty(0),
  //                MethodList=1 — `A`'s nested interface.
  //   TypeDef[4]:  Flags=0x21, TypeName="Widget"(62), TypeNamespace=empty(0),
  //                MethodList=1 — `B`'s nested interface, same bare name.
  //   InterfaceImpl[0]: Class=1 (TypeDef row 1, IRoot),
  //                Interface=TypeDefOrRef(TypeRef row 3)=(3<<2)|1=13 — the
  //                nested `Widget` reference under `A`.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[43] — `IRoot`'s IID (all-0x22).
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 4)=(4<<5)|3=131,
  //                Type=11, Value=blob[1] — `A.Widget`'s IID (the well-known
  //                GUID).
  //   CustomAttribute[2]: Parent=HasCustomAttribute(TypeDef row 5)=(5<<5)|3=163,
  //                Type=11, Value=blob[22] — `B.Widget`'s IID (all-0x11).
  //   NestedClass[0]: NestedClass=4 (TypeDef row 4), EnclosingClass=2 (TypeDef
  //                row 2, A) — `A.Widget` nested under `A`.
  //   NestedClass[1]: NestedClass=5 (TypeDef row 5), EnclosingClass=3 (TypeDef
  //                row 3, B) — `B.Widget` nested under `B`.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (module-scoped A ref)
    0x04, 0x00, 0x3a, 0x00, 0x31, 0x00,
    // TypeRef[2] (nested Widget ref under A)
    0x0b, 0x00, 0x3e, 0x00, 0x00, 0x00,
    // TypeDef[0] (IRoot)
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] (A)
    0x00, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[2] (B)
    0x00, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[3] (A.Widget)
    0x21, 0x00, 0x00, 0x00, 0x3e, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[4] (B.Widget)
    0x21, 0x00, 0x00, 0x00, 0x3e, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // InterfaceImpl[0]
    0x01, 0x00, 0x0d, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x2b, 0x00,
    // CustomAttribute[1]
    0x83, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // CustomAttribute[2]
    0xa3, 0x00, 0x0b, 0x00, 0x16, 0x00,
    // NestedClass[0]
    0x04, 0x00, 0x02, 0x00,
    // NestedClass[1]
    0x05, 0x00, 0x03, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IRoot\0A\0B\0Widget\0":
  // GuidNamespace@1, GuidName@35, NS@49, IRoot@52, A@58, B@60, Widget@62.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00,
    0x41, 0x00,
    0x42, 0x00,
    0x57, 0x69, 0x64, 0x67, 0x65, 0x74, 0x00,
  ]

  // The blob heap: offset 0 is the reserved empty blob; each subsequent blob is
  // a 20-byte `GuidAttribute` value (prolog 0x0001, 16 GUID bytes, NumNamed 0)
  // preceded by its length 0x14. Offset 1 is the well-known GUID
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D` (`A.Widget`); offset 22 is all-0x11
  // (`B.Widget`); offset 43 is all-0x22 (`IRoot`), so the three IIDs are
  // distinct.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
    0x14, 0x01, 0x00, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
    0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x00, 0x00,
    0x14, 0x01, 0x00, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
    0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 3, range: 0 ..< 18,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 5, range: 18 ..< 88,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 88 ..< 88,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 88 ..< 88,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 88 ..< 92,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 92 ..< 98,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 3, range: 98 ..< 116,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 2, range: 116 ..< 124,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10)
          | (1 << 12) | (1 << 41)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure resolves a nested base by its enclosing, not its bare name`() throws {
    // The nested `Widget` reference is scoped to the local `A`, so the
    // scope-chain walk resolves it to `A.Widget` — never `B.Widget`, which
    // shares the bare name under a different enclosing. Only `A.Widget`'s IID
    // is emitted; `B.Widget`'s is not, and exactly one `Widget` declaration
    // renders (the name-only join would have conflated both).
    try RenderClosureNestedConflationTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot: Widget {"))
      // `A.Widget` (the well-known GUID) resolved and emitted …
      #expect(closed.contains("0C733A30-2A1C-11CE-ADE5-00AA0044773D"))
      // … while `B.Widget` (the all-0x11 GUID) did not.
      #expect(!closed.contains("11111111-1111-1111-1111-111111111111"))
      let count = closed.components(separatedBy: "public protocol Widget").count
      #expect(count == 2) // one split ⇒ exactly one occurrence
    }
  }
}
