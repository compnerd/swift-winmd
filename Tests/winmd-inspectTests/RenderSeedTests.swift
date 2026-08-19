// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect
@testable import SQLEngineWinMD

import Mustache
import SQLEngine
@testable import WinMD
import WinMDSynthesis

/// Coverage of the render seed's membership: the flat render seeds from a
/// name-filtered `TypeDef` scan (the `tdInterface` flag) and fetches each
/// interface's `iid` through the seekable `guid` query, rather than
/// materialising the `interfaces` view. The view INNER-joins the
/// `GuidAttribute`, so a `tdInterface` `TypeDef` with no decodable
/// `GuidAttribute` is absent from it and is not rendered; the seed must
/// reproduce that exactly by dropping a guid-less interface. The fixture
/// assembles two method-less `tdInterface` `TypeDef`s in namespace `NS` —
/// `IHasGuid`, carrying a `GuidAttribute`, and `INoGuid`, carrying none — so a
/// `*` render emits only `IHasGuid`, a named render of `INoGuid` raises
/// `RenderError.interface` (the empty view names it none), and the emitted
/// `@com(interface:)` spells the fetched IID.
struct RenderSeedTests {
  // Seven tables packed back to back in table-number order — TypeRef (#1, 1
  // row), TypeDef (#2, 2 rows), MethodDef (#6, empty), Param (#8, empty),
  // InterfaceImpl (#9, empty), MemberRef (#10, 1 row), CustomAttribute (#12, 1
  // row) — every index narrow (2-byte). ECMA-335 rows are 1-based; a coded
  // index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IHasGuid"(52),
  //                TypeNamespace="NS"(49), MethodList=1 — carries a GuidAttribute.
  //   TypeDef[1]:  Flags=0x21, TypeName="INoGuid"(61), TypeNamespace="NS"(49),
  //                MethodList=1 — carries no GuidAttribute, so the view drops it.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[1] — `IHasGuid`'s IID. `INoGuid` (row 2) has none.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeDef[0] (IHasGuid)
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // TypeDef[1] (INoGuid)
    0x21, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IHasGuid\0INoGuid\0":
  // GuidNamespace@1, GuidName@35, NS@49, IHasGuid@52, INoGuid@61.
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
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 6 ..< 34,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 34 ..< 40,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 40 ..< 46,
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

  @Test func `a * render drops a tdInterface bearing no GuidAttribute`() throws {
    // The `interfaces` view INNER-joins the `GuidAttribute`, so `INoGuid` — a
    // `tdInterface` `TypeDef` carrying none — is absent from it. The TypeDef
    // scan finds both interfaces, but the seed fetches each `iid` and drops the
    // one whose `guid` resolves nothing, so the `*` render emits only
    // `IHasGuid`, its `@com(interface:)` spelling the fetched IID.
    try RenderSeedTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render("*", template: "com")
      #expect(rendered.contains("public protocol IHasGuid"))
      #expect(!rendered.contains("public protocol INoGuid"))
      #expect(rendered.contains("0C733A30-2A1C-11CE-ADE5-00AA0044773D"))
    }
  }

  @Test func `a named render of a guid-less interface faults as unnamed`() throws {
    // A named render of `INoGuid` resolves no seed (the view names it none), so
    // it raises `RenderError.interface` exactly as a name no interface bears
    // would — the seed's drop preserves the view's membership fault. `IHasGuid`,
    // which carries a `GuidAttribute`, still renders.
    try RenderSeedTests.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.interface("INoGuid")) {
        try shell.render("INoGuid", template: "com")
      }
      let rendered = try shell.render("IHasGuid", template: "com")
      #expect(rendered.contains("public protocol IHasGuid"))
      #expect(rendered.contains("0C733A30-2A1C-11CE-ADE5-00AA0044773D"))
    }
  }
}
