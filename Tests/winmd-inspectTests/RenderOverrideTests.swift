// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect
@testable import SQLEngineWinMD

import Mustache
import SQLEngine
@testable import WinMD
import WinMDSynthesis

import class Foundation.FileManager
import struct Foundation.Data
import struct Foundation.URL
import struct Foundation.UUID

/// Coverage of the `.render *` override fallback: the flat render's batch reads
/// raw tables and the `interfaces` view, bypassing the overridable per-node
/// `methods`/`params`/`bases`/`guid` render queries and the
/// `methods`/`params`/`bases` views they read. So an override honoured by
/// `.render <interface>` — which runs the per-node queries — was silently
/// ignored by `.render *`, whose batch shortcut divergently emitted the
/// un-overridden surface. The fix detects an override (a `-I` file or a session
/// `CREATE VIEW` of one of those names) and, for `*`, falls back to the same
/// per-node emit, so `*` and the per-interface renders stay identical.
///
/// The fixture assembles two COM interfaces — `IBase` and `IDerived`, each
/// carrying a `GuidAttribute` (so the `interfaces` view names both), with an
/// `InterfaceImpl` naming `IDerived`'s base as the local `IBase` `TypeDef` — so
/// the `bases` layer has an observable row (`IDerived`'s base) to override. An
/// override that renames that base to `IOverridden` diverges the batch (which
/// reads the raw `InterfaceImpl`) from the per-node path (which reads the
/// overridden `bases`) — the exact bug — and the assertion is that `*` matches
/// the concatenation of the per-interface renders.
struct RenderOverrideTests {
  // Five narrow (all-index 2-byte) tables packed back to back in table-number
  // order — TypeRef (#1, 1 row), TypeDef (#2, 2 rows), InterfaceImpl (#9, 1
  // row), MemberRef (#10, 1 row), CustomAttribute (#12, 2 rows) — plus empty
  // MethodDef (#6) and Param (#8) tables so the `methods` view resolves a
  // relation. ECMA-335 rows are 1-based; a coded index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IBase"(52),
  //                TypeNamespace="NS"(49), MethodList=1 (empty) — the base.
  //   TypeDef[1]:  Flags=0x21, TypeName="IDerived"(58), TypeNamespace="NS"(49),
  //                MethodList=1 (empty) — the refiner.
  //   InterfaceImpl[0]: Class=2 (TypeDef row 2, IDerived),
  //                Interface=TypeDefOrRef(TypeDef row 1)=(1<<2)|0=4 — names the
  //                local base `IBase`.
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
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10)
          | (1 << 12)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  /// `fileprivate` so `RenderCacheTests` reuses this fixture's `IBase`/`IDerived`
  /// pair (with its observable `bases` row).
  fileprivate static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Runs `body` with the path of a fresh temporary directory that exists for
  /// the call and is removed after — the `-I` search directory a file override
  /// test seeds. `fileprivate` so `RenderCacheTests` reuses it.
  fileprivate static func withDirectory(_ body: (String) throws -> Void)
      rethrows {
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? manager.createDirectory(at: directory,
                                 withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    try body(directory.path)
  }

  @Test func `a flat render exposes interface fields at the template root`() throws {
    try RenderOverrideTests.withDirectory { directory in
      let manager = FileManager.default
      let templates = URL(fileURLWithPath: "\(directory)/Templates")
      try manager.createDirectory(at: templates,
                                  withIntermediateDirectories: true)
      // A template written for the flat renderer, reading top-level fields.
      let flat = "{{! language: swift }}\ninterface {{name}}: {{iid}}"
      try Data(flat.utf8)
          .write(to: templates.appendingPathComponent("flat.mustache"))
      try RenderOverrideTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let rendered = try shell.render("IDerived", template: "flat")
        // The top-level `{{name}}` resolves to the interface's name, not "" —
        // the documented flat behaviour the sectioned template must preserve.
        #expect(rendered.hasPrefix("interface IDerived: "))
      }
    }
  }

  @Test func `a closure render exposes interface fields at the template root`() throws {
    try RenderOverrideTests.withDirectory { directory in
      let manager = FileManager.default
      let templates = URL(fileURLWithPath: "\(directory)/Templates")
      try manager.createDirectory(at: templates,
                                  withIntermediateDirectories: true)
      // The same top-level template a flat render uses, now under `--closure`.
      let flat = "{{! language: swift }}\ninterface {{name}}: {{iid}}"
      try Data(flat.utf8)
          .write(to: templates.appendingPathComponent("flat.mustache"))
      try RenderOverrideTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let rendered = try shell.render(closure: "IDerived", template: "flat")
        // A `--closure` emission exposes the same top-level context as the flat
        // path, so a template reading `{{name}}` resolves each type's name
        // rather than "" — the closure over `IDerived` names both `IBase` and
        // `IDerived`, not two blank `interface : ` lines.
        #expect(rendered.contains("interface IBase: "))
        #expect(rendered.contains("interface IDerived: "))
      }
    }
  }

  // A `-I` override supplying the former four-column `Render/requires.sql`
  // (`Id`, namespace, name, `iid` — no trailing `kind`) must not trap the
  // closure walk, which reads each base's kind from `found[4]`. Render-query
  // shadowing is a supported extension point, so a copied override carrying the
  // pre-`kind` shape resolves `IDerived`'s base `IBase` and emits both.
  @Test func `a four-column requires override walks the base without trapping`() throws {
    try RenderOverrideTests.withDirectory { directory in
      let manager = FileManager.default
      let render = URL(fileURLWithPath: "\(directory)/Render")
      try manager.createDirectory(at: render,
                                  withIntermediateDirectories: true)
      let requires = """
        SELECT n.Id, n.TypeNamespace, n.TypeName, n.iid
        FROM InterfaceImpl i
        JOIN interfaces n ON n.Id = i.Interface_TypeDef
        WHERE i.Class = :parent
        """
      try Data(requires.utf8)
          .write(to: render.appendingPathComponent("requires.sql"))
      try RenderOverrideTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let closed = try shell.render(closure: "IDerived", template: "com")
        // The base `IBase`, reached through the four-column requires, emits
        // rather than trapping on the absent `kind` column.
        #expect(closed.contains("protocol IBase"))
        #expect(closed.contains("protocol IDerived"))
      }
    }
  }

  @Test func `* honours a CREATE VIEW override, matching the per-interface renders`() throws {
    // A session `CREATE VIEW bases` renames `IDerived`'s base to `IOverridden`.
    // `.render <interface>` runs the per-node `bases` query and honours it; the
    // pre-fix `.render *` batch read the raw `InterfaceImpl` and emitted the
    // original `IBase`, diverging. The fix detects the override and falls the
    // `*` path back to the per-node emit, so `*` equals the concatenation of
    // the per-interface renders (the seed order — ascending `Id` — is `IBase`
    // then `IDerived`).
    try RenderOverrideTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute("""
        CREATE VIEW bases AS
        SELECT 'IOverridden' AS base, NULL AS spec
        FROM InterfaceImpl WHERE Class = :parent
        """)
      let star = try shell.render("*", template: "com")
      let base = try shell.render("IBase", template: "com")
      let derived = try shell.render("IDerived", template: "com")
      #expect(star == [base, derived].joined(separator: "\n"))
      // The override is honoured by `*`: the renamed base appears, the original
      // does not.
      #expect(star.contains("public protocol IDerived: IOverridden {"))
      #expect(!star.contains("public protocol IDerived: IBase {"))
    }
  }

  @Test func `* honours a -I file override, matching the per-interface renders`() throws {
    // A `-I` directory carrying `Render/bases.sql` overrides the per-node base
    // query to rename `IDerived`'s base to `IOverridden`. As with the session
    // override, `.render <interface>` honours it while the pre-fix `.render *`
    // batch ignored it; the fix detects the shadowing file and falls `*` back
    // to the per-node emit, so `*` equals the concatenation of the
    // per-interface renders.
    try RenderOverrideTests.withDirectory { directory in
      let manager = FileManager.default
      let render = URL(fileURLWithPath: "\(directory)/Render")
      try manager.createDirectory(at: render, withIntermediateDirectories: true)
      let override = """
        SELECT 'IOverridden' AS base
        FROM InterfaceImpl WHERE Class = :parent
        """
      try Data(override.utf8)
          .write(to: render.appendingPathComponent("bases.sql"))
      try RenderOverrideTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let star = try shell.render("*", template: "com")
        let base = try shell.render("IBase", template: "com")
        let derived = try shell.render("IDerived", template: "com")
        #expect(star == [base, derived].joined(separator: "\n"))
        #expect(star.contains("public protocol IDerived: IOverridden {"))
        #expect(!star.contains("public protocol IDerived: IBase {"))
      }
    }
  }

  @Test func `* keeps the fast batch when nothing is overridden`() throws {
    // With no override the detection predicate is false, so `*` stays batched.
    // The batch and per-node paths still agree — `*` equals the concatenation
    // of the per-interface renders — and the un-overridden base (`IBase`) is
    // the one emitted.
    try RenderOverrideTests.with { catalog in
      let shell = Shell(catalog)
      let star = try shell.render("*", template: "com")
      let base = try shell.render("IBase", template: "com")
      let derived = try shell.render("IDerived", template: "com")
      #expect(star == [base, derived].joined(separator: "\n"))
      #expect(star.contains("public protocol IDerived: IBase {"))
      #expect(!star.contains("IOverridden"))
    }
  }
}

/// Coverage of the seed query (`Render/interfaces.sql`) as a batch-shortcut
/// override the `.render *` fallback must honour. The batch derives each iid
/// from the bundled `interfaces` view, whose three-arm union gates on
/// `BITAND(Flags, 32) = 32` (the `tdInterface` bit); the per-node path derives
/// each iid from the ungated `Render/guid.sql`, which resolves any `TypeDef`
/// bearing a decodable `GuidAttribute`. So an overridden seed that names a
/// `TypeDef` without the interface flag — a COM delegate carrying a static IID —
/// is emitted by `.render <name>` (the ungated per-node guid resolves it) yet
/// was silently dropped by the pre-fix `.render *` batch (the flag-gated view's
/// `guids` finds no iid for it, and the seed loop drops a guid-less row). The
/// fix counts the seed's own name among the batch-shortcut render queries, so
/// overriding it falls `*` back to the per-node emit and the two paths agree.
///
/// The fixture assembles one non-interface `TypeDef` — `Callback`, a `tdSealed`
/// (`0x100`) type with no `tdInterface` bit — carrying a `GuidAttribute` through
/// the `CustomAttribute` -> `MemberRef` -> `TypeRef` (`GuidAttribute`) chain the
/// `interfaces` view and `guid.sql` both read. Because it lacks the flag, the
/// bundled `interfaces` view (and thus the batch) never names it; only an
/// overridden, ungated seed does.
struct RenderSeedOverrideTests {
  // Four narrow (all-index 2-byte) tables packed back to back in table-number
  // order — TypeRef (#1, 1 row), TypeDef (#2, 1 row), MemberRef (#10, 1 row),
  // CustomAttribute (#12, 1 row) — plus empty MethodDef (#6), Param (#8), and
  // InterfaceImpl (#9) tables so the render's `methods`/`bases` views resolve a
  // relation. ECMA-335 rows are 1-based; a coded index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x100 (tdSealed, not tdInterface), TypeName=
  //                "Callback"(52), TypeNamespace="NS"(49), MethodList=1 (empty)
  //                — the guid-bearing non-interface the flag-gated view drops.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `Callback`'s IID.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0]
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeDef[0] (Callback, tdSealed 0x100 — no tdInterface bit 5)
    0x00, 0x01, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0Callback\0":
  // GuidNamespace@1, GuidName@35, NS@49, Callback@52.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x43, 0x61, 0x6c, 0x6c, 0x62, 0x61, 0x63, 0x6b, 0x00,
  ]

  // The blob heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the well-known GUID
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`, then NumNamed 0), preceded by its
  // length 0x14.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 1, range: 6 ..< 20,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 20 ..< 20,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 20 ..< 20,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 20 ..< 20,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 20 ..< 26,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 26 ..< 32,
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

  /// Runs `body` with the path of a fresh temporary directory that exists for
  /// the call and is removed after — the `-I` search directory the seed override
  /// test seeds.
  private static func withDirectory(_ body: (String) throws -> Void) rethrows {
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? manager.createDirectory(at: directory,
                                 withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    try body(directory.path)
  }

  @Test func `* honours a seed override naming a guid-bearing non-interface`() throws {
    // A `-I` directory carrying `Render/interfaces.sql` overrides the seed to
    // name `Callback` by its own three-column (`Id`, `TypeNamespace`,
    // `TypeName`) shape with no flag gate. `.render Callback` runs that seed and
    // resolves its iid through the ungated per-node `guid.sql`, emitting it. The
    // pre-fix `.render *` kept batching (the seed's own name was not a
    // batch-shortcut trip), and the batch derives iids from the flag-gated
    // `interfaces` view, which never names `Callback` — so the seed loop found
    // no iid for it and dropped it. The fix counts the seed among the
    // batch-shortcut render queries, so `*` falls back to the per-node emit and
    // emits `Callback` exactly as the per-interface render does.
    try RenderSeedOverrideTests.withDirectory { directory in
      let manager = FileManager.default
      let render = URL(fileURLWithPath: "\(directory)/Render")
      try manager.createDirectory(at: render, withIntermediateDirectories: true)
      let override = """
        SELECT Id, TypeNamespace, TypeName
        FROM TypeDef
        WHERE TypeName = :name OR '*' = :name
        ORDER BY Id
        """
      try Data(override.utf8)
          .write(to: render.appendingPathComponent("interfaces.sql"))
      try RenderSeedOverrideTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let star = try shell.render("*", template: "com")
        let callback = try shell.render("Callback", template: "com")
        // `*` falls back to per-node and emits the guid-bearing non-interface,
        // byte-identical to its per-interface render.
        #expect(star == callback)
        #expect(star.contains("public protocol Callback: IUnknown {"))
        // The ungated per-node guid resolves the IID both paths spell.
        #expect(star.contains(
            "@com(interface: \"0C733A30-2A1C-11CE-ADE5-00AA0044773D\")"))
      }
    }
  }
}

/// Coverage of the `.render *` batch SANITIZE scoping: the batch scans read raw
/// `MethodDef`/`Param` names and escape only the emitted set through the active
/// `SANITIZE` UDF in one query, so the UDF is never invoked over a method or
/// parameter of a type `.render *` does not emit. Because `SANITIZE` is
/// session-overridable (a `CREATE FUNCTION`), the pre-fix batch — which ran
/// `SANITIZE(Name)` over every `MethodDef`/`Param` row — let a custom,
/// value-sensitive `SANITIZE` faulting on a non-emitted name abort the whole
/// render. The fix defers escaping to the emitted names only, matching the
/// per-node path (which runs `SANITIZE` over its emitted rows alone).
///
/// The fixture assembles two `tdInterface` `TypeDef`s in namespace `NS` —
/// `IHasGuid`, carrying a `GuidAttribute` (so it is emitted) and owning a method
/// `Keep`, and `INoGuid`, carrying none (so the seed drops it) and owning a
/// method `Boom`. A session `CREATE FUNCTION SANITIZE` faults (a runtime
/// divide-by-zero) on the exact name `Boom` and is identity for every other
/// name. A custom `SANITIZE` does not trip the override fallback, so the batch
/// stays active — the exact scenario the bug bit — yet the fix escapes only
/// `Keep` (the emitted method), never `Boom`, so `.render * com` succeeds.
struct RenderSanitizeTests {
  // Seven tables packed back to back in table-number order — TypeRef (#1, 1
  // row), TypeDef (#2, 2 rows), MethodDef (#6, 2 rows), Param (#8, empty),
  // InterfaceImpl (#9, empty), MemberRef (#10, 1 row), CustomAttribute (#12, 1
  // row) — every index narrow (2-byte). ECMA-335 rows are 1-based; a coded
  // index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IHasGuid"(52),
  //                TypeNamespace="NS"(49), MethodList=1 — carries a GuidAttribute
  //                and owns MethodDef row 1 (`Keep`); it is emitted.
  //   TypeDef[1]:  Flags=0x21, TypeName="INoGuid"(61), TypeNamespace="NS"(49),
  //                MethodList=2 — carries no GuidAttribute (dropped) and owns
  //                MethodDef row 2 (`Boom`), a name `.render *` never emits.
  //   MethodDef[0]: Name="Keep"(69), Signature=blob[0] (empty), ParamList=1 —
  //                owned by TypeDef row 1 through the MethodList run [1, 2).
  //   MethodDef[1]: Name="Boom"(74), Signature=blob[0], ParamList=1 — owned by
  //                TypeDef row 2 through the run [2, end).
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `IHasGuid`'s IID. `INoGuid` (row 2) has none.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeDef[0] (IHasGuid, MethodList 1)
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] (INoGuid, MethodList 2)
    0x21, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // MethodDef[0] (Keep, Signature blob[0], ParamList 1)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x45, 0x00, 0x00, 0x00, 0x01, 0x00,
    // MethodDef[1] (Boom, Signature blob[0], ParamList 1)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x4a, 0x00, 0x00, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IHasGuid\0INoGuid
  // \0Keep\0Boom\0": GuidNamespace@1, GuidName@35, NS@49, IHasGuid@52,
  // INoGuid@61, Keep@69, Boom@74.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x48, 0x61, 0x73, 0x47, 0x75, 0x69, 0x64, 0x00,
    0x49, 0x4e, 0x6f, 0x47, 0x75, 0x69, 0x64, 0x00,
    0x4b, 0x65, 0x65, 0x70, 0x00,
    0x42, 0x6f, 0x6f, 0x6d, 0x00,
  ]

  // The blob heap: offset 0 is the reserved empty blob; offset 1 is the 20-byte
  // `GuidAttribute` value (prolog 0x0001, the well-known GUID
  // `0C733A30-2A1C-11CE-ADE5-00AA0044773D`, then NumNamed 0), preceded by its
  // length 0x14. A method's Signature is blob[0] (empty), so its return does not
  // decode and it emits a `()` no-argument, no-return requirement.
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
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 2, range: 34 ..< 62,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 62 ..< 62,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 62 ..< 62,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 62 ..< 68,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 68 ..< 74,
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

  @Test func `* does not SANITIZE a non-emitted method name`() throws {
    // A session `CREATE FUNCTION SANITIZE` faults (a value-dependent
    // divide-by-zero, unfoldable, so it faults only at run time) on the exact
    // name `Boom` and is identity otherwise. `Boom` belongs to `INoGuid`, a
    // guid-less interface the seed drops, so it is never emitted. The pre-fix
    // batch ran `SANITIZE(Name)` over every `MethodDef` row — including `Boom` —
    // and aborted the whole render on the fault. The fix escapes only the
    // emitted names, so `SANITIZE` runs over `Keep` (identity) and never over
    // `Boom`, and `.render * com` succeeds — emitting `IHasGuid`'s `Keep`
    // requirement and nothing of `INoGuid`.
    try RenderSanitizeTests.with { catalog in
      var shell = Shell(catalog)
      try shell.execute("""
        CREATE FUNCTION SANITIZE(n TEXT) RETURNS TEXT
        AS CASE WHEN 1 / (CASE WHEN n = 'Boom' THEN 0 ELSE 1 END) = 1
                THEN n ELSE n END
        """)
      let star = try shell.render("*", template: "com")
      #expect(star.contains("public protocol IHasGuid"))
      #expect(star.contains("func Keep()"))
      // The fault-triggering non-emitted name is never SANITIZEd, so it — and
      // its guid-less owner — is absent rather than aborting the render.
      #expect(!star.contains("Boom"))
      #expect(!star.contains("INoGuid"))
    }
  }
}

/// Coverage of the render query memo's scope: the parsed `Render/<name>.sql`
/// queries were memoised for the shell's lifetime, so editing a `-I`
/// `Render/<name>.sql` override between renders in one interactive shell had no
/// effect — the second render served the stale parse — while templates and
/// language specs reloaded per render, silently mixing fresh presentation with
/// stale SQL. The fix clears the memo at the start of each top-level render, so
/// each render re-resolves every named query once (keeping the within-render
/// dedup); an override edited since the last render takes effect on the next.
///
/// The sequence reuses the `RenderOverrideTests` fixture (the `IBase`/`IDerived`
/// pair with an observable `bases` row): a `-I` `Render/bases.sql` renames
/// `IDerived`'s base to `IFirst`, a first render observes it, the file is
/// rewritten to name `ISecond`, and a second render in the same shell must
/// observe `ISecond` — not the cached `IFirst`.
struct RenderCacheTests {
  @Test func `a -I override edited between renders refreshes on the next render`() throws {
    try RenderOverrideTests.withDirectory { directory in
      let manager = FileManager.default
      let render = URL(fileURLWithPath: "\(directory)/Render")
      try manager.createDirectory(at: render, withIntermediateDirectories: true)
      let base = render.appendingPathComponent("bases.sql")
      let first = """
        SELECT 'IFirst' AS base
        FROM InterfaceImpl WHERE Class = :parent
        """
      try Data(first.utf8).write(to: base)
      try RenderOverrideTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        // The first render resolves and memoises the override naming `IFirst`.
        let before = try shell.render("IDerived", template: "com")
        #expect(before.contains("public protocol IDerived: IFirst {"))
        // The same shell's override file is rewritten to name `ISecond`.
        let second = """
          SELECT 'ISecond' AS base
          FROM InterfaceImpl WHERE Class = :parent
          """
        try Data(second.utf8).write(to: base)
        // The next render re-resolves the file: the pre-fix shell-lifetime memo
        // returned the stale `IFirst` parse; the per-render memo reflects the
        // edit and names `ISecond`.
        let after = try shell.render("IDerived", template: "com")
        #expect(after.contains("public protocol IDerived: ISecond {"))
        #expect(!after.contains("IFirst"))
      }
    }
  }
}

/// Coverage of the `.render *` empty-seed guard: a metadata file whose `TypeDef`
/// rows are all non-interface produces no seed, so `.render *` emits nothing.
/// The batch shortcuts must not fire in that case — `guids` expands the
/// `interfaces` view (a three-way UNION over `CustomAttribute`/`MemberRef`/
/// `TypeRef`) and the `inherits`/`roster`/`signatures` trio expands views over
/// `InterfaceImpl`/`MethodDef`/`Param`, none of which a valid interface-free
/// file need carry — so running them would fault with a missing relation where
/// there is nothing to render. The fix skips every batch query on an empty
/// wildcard seed, so `.render *` returns the empty string rather than faulting.
struct RenderEmptyTests {
  // One `TypeDef` (#2) and no other table: a single non-interface row (Flags 0,
  // so the seed scan's `BITAND(Flags, 32) = 32` drops it), so the `interfaces`
  // view's `CustomAttribute`/`MemberRef`/`TypeRef` and the trio's
  // `InterfaceImpl`/`MethodDef`/`Param` are all absent — expanding either would
  // fault on a missing relation. TypeDef stride 14 (narrow indexes).
  //   TypeDef[0]: Flags=0, TypeName="Widget"(4), TypeNamespace="NS"(1),
  //               Extends=0, FieldList=0, MethodList=0.
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]

  // "\0NS\0Widget\0": NS@1, Widget@4.
  private static let strings: Array<UInt8> = [
    0x00, 0x4e, 0x53, 0x00, 0x57, 0x69, 0x64, 0x67, 0x65, 0x74, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 1, range: 0 ..< 14,
                wide: 0, stride: 14),
  ]

  // Only the `TypeDef` table (#2) is present.
  private static let valid: UInt64 = (1 << 2)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: empty.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `* renders nothing rather than expanding a batch view on an empty seed`() throws {
    try RenderEmptyTests.with { catalog in
      let shell = Shell(catalog)
      // Pre-fix, the batch fired unconditionally for `*`: `guids` expanded the
      // `interfaces` view and faulted on the absent `CustomAttribute`. The fix
      // skips the batch on an empty seed, so the render returns "".
      let star = try shell.render("*", template: "com")
      #expect(star.isEmpty)
    }
  }
}
