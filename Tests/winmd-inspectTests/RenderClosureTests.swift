// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect
@testable import SQLEngineWinMD

import Mustache
import SQLEngine
@testable import WinMD
import WinMDSynthesis

import struct Foundation.Data
import class Foundation.FileManager
import struct Foundation.URL
import struct Foundation.UUID

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

  @Test func `--closure pulls in a struct a method returns, before the interface`() throws {
    // `IRoot.Make` returns the local struct `Point` (edge E3, value arm). The
    // closure decodes the method signature, resolves `Point` to its local
    // `struct` `TypeDef`, and emits it before `IRoot`, the type naming it — the
    // post-order the walk holds. The flat render of `IRoot` alone pulls nothing
    // in.
    try ClosureFixture.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `@frozen` fixes the ABI layout so the projected struct is the C/C++
      // record it mirrors field for field.
      #expect(closed.contains("@frozen public struct Point {"))
      #expect(closed.contains("public var value: CInt"))
      // A public memberwise initializer — the synthesized one is internal, so a
      // caller outside the generated module could not otherwise construct it.
      #expect(closed.contains("public init(value: CInt) {"))
      #expect(closed.contains("self.value = value"))
      let structure = try #require(closed.range(of: "public struct Point"))
      let interface = try #require(closed.range(of: "public protocol IRoot"))
      #expect(structure.lowerBound < interface.lowerBound)

      let flat = try shell.render("IRoot", template: "com")
      #expect(!flat.contains("public struct Point"))
    }
  }

  @Test func `--closure omits a static field from struct storage`() throws {
    // `Point`'s only field `value` is marked `fdStatic`. A static field is not
    // laid out in an instance, so emitting it as a stored `public var` would add
    // a nonexistent field and shift every offset, corrupting a by-value native
    // call. The struct render must drop it — `Point` stays a struct but carries
    // no `value` field and no `value` init parameter. Pre-fix, the fields loop
    // emitted every `FieldDef` row as a stored `var`.
    try ClosureFixture.withStaticPointField { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("@frozen public struct Point {"))
      #expect(!closed.contains("public var value"))
      #expect(!closed.contains("public init(value:"))
    }
  }

  @Test func `--closure gives a self field a distinct initializer local`() throws {
    // `Point`'s field is named `self`, which `SANITIZE` escapes to `` `self` ``
    // for the stored property. The memberwise initializer cannot reuse that
    // spelling as its parameter: `` init(`self`:) { self.`self` = `self` } ``
    // binds the assignment's leading `self` to the `CInt` parameter, not the
    // struct instance, and fails to compile. So it takes a collision-free
    // `local` (`arg0`) — the parameter's internal name and the assignment's
    // right-hand side — while `` `self` `` stays the label and property name.
    try ClosureFixture.withPointFieldNamed("self") { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public var `self`: CInt"))
      // Label `` `self` `` with a distinct internal `arg0`, and the assignment
      // reads the parameter through that local — not the reused field spelling.
      #expect(closed.contains("public init(`self` arg0: CInt) {"))
      #expect(closed.contains("self.`self` = arg0"))
      #expect(!closed.contains("self.`self` = `self`"))
    }
  }

  @Test func `--closure escapes a struct field named underscore`() throws {
    // `Point`'s field is named `_`, the wildcard pattern. Passed through raw it
    // renders `public var _: CInt` — invalid: `_` is a discard, not a name — so
    // the stored property and its initializer are both rejected. `_` is
    // escaped to the backticked `` `_` `` (a usable identifier), which — unlike
    // `` `self` `` — does not shadow the instance, so the field takes no
    // distinct local: `` init(`_`:) { self.`_` = `_` } `` compiles as is.
    try ClosureFixture.withPointFieldNamed("_") { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public var `_`: CInt"))
      #expect(closed.contains("public init(`_`: CInt) {"))
      #expect(closed.contains("self.`_` = `_`"))
      // Never the bare discard `_`, which is not a declarable property.
      #expect(!closed.contains("public var _:"))
    }
  }

  @Test func `--closure rejects an explicit-layout struct rather than misprojecting it`() throws {
    // The same `IRoot.Make` returns `Point`, but `Point`'s `TypeDef` `Flags`
    // now carry `tdExplicitLayout` (the `0x10` value of the `0x18` LayoutMask),
    // marking it a union or offset-placed record. `@frozen` freezes the layout
    // Swift chooses, not the declared one, so projecting it would give the wrong
    // size and field offsets across the ABI. The closure must reject it — emit
    // nothing for `Point` and not recurse its fields — leaving it a frontier the
    // consumer defines, while `IRoot` itself still renders. Pre-fix, the walk
    // emitted every resolved value type, so `Point` came out as an
    // ABI-incompatible `@frozen` struct.
    try ClosureFixture.withPointFlags(0x10) { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot"))
      #expect(!closed.contains("struct Point"))
    }
  }

  @Test func `--closure projects a regular enum a method names as a raw-value struct newtype`() throws {
    // `IRoot.Paint(Color)` names the local enum `Color`, a regular (non-`[flags]`)
    // enum. The closure projects it as an explicitly-stored raw-value struct
    // newtype, not a native Swift `enum`: a native `enum Color: CInt` does not
    // carry `CInt`'s ABI width — Swift freezes a compact representation, so a
    // two-case enum is one byte, not four — so the newtype stores the `value__`
    // underlying type directly (the ABI-exact width) and its members are
    // `@_transparent` accessors folding to values read from the `Constant` table
    // (`Red = 5`, `Green = 7`). The `OptionSet` is the separate `[flags]`
    // projection.
    try ClosureFixture.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains(
          "@frozen public struct Color: Hashable, Sendable {"))
      #expect(closed.contains("public var rawValue: CInt"))
      #expect(closed.contains(
          "@_transparent public static var Red: Color { Color(rawValue: 5) }"))
      #expect(closed.contains(
          "@_transparent public static var Green: Color { Color(rawValue: 7) }"))
      // Not a native enum (the wrong ABI width) nor the `[flags]` OptionSet.
      #expect(!closed.contains("enum Color"))
      #expect(!closed.contains("Color: OptionSet"))
    }
  }

  @Test func `--closure emits a duplicate enum raw value as two static constants`() throws {
    // A Win32 enum aliases raw values — two member names for one value.
    // `withDuplicateColorValue` makes `Green` share `Red`'s value 5. The stored
    // struct newtype tolerates this: both are `@_transparent` accessors of the
    // same raw value, no deduplication a native enum's `case`s would demand. Both
    // members emit — the alias the C enum spelled, without a compile error.
    try ClosureFixture.withDuplicateColorValue { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains(
          "@_transparent public static var Red: Color { Color(rawValue: 5) }"))
      #expect(closed.contains(
          "@_transparent public static var Green: Color { Color(rawValue: 5) }"))
    }
  }

  @Test func `--closure projects a delegate a method names as a com protocol`() throws {
    // `IRoot.Listen(Handler)` names the local delegate `Handler`. A WinRT
    // delegate is a COM interface (IUnknown plus a single `Invoke`), so the
    // closure projects it as an `@com(interface:)` protocol carrying just
    // `Invoke` — its own static IID decoded through the `guid` query — not a
    // Swift closure typealias. `void Invoke(i4)` renders a void return (no
    // arrow) over a single `CInt` parameter.
    try ClosureFixture.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains(
          "@com(interface: \"DEADBEEF-CAFE-BABE-F00D-1234567890AB\")"))
      #expect(closed.contains("public protocol Handler {"))
      #expect(closed.contains("func Invoke(_ : CInt)"))
      // Not a closure typealias.
      #expect(!closed.contains("typealias Handler"))
    }
  }

  @Test func `--closure enqueues an interface a method names, emitting it`() throws {
    // `IRoot.Chain(IOther)` names another local interface. A signature-named
    // interface routes through the interface path — enqueued, then emitted
    // through the `{{#interface}}` section, its own IID intact — before `IRoot`.
    try ClosureFixture.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IOther: IUnknown {"))
      let other = try #require(closed.range(of: "public protocol IOther"))
      let root = try #require(closed.range(of: "public protocol IRoot"))
      #expect(other.lowerBound < root.lowerBound)
    }
  }

  @Test func `the render decode spells a unique-named value type bare`() {
    // Qualification is collision-only: a value type whose simple `TypeName` is
    // borne by no other value type spells BARE, its namespace omitted. `Point`
    // (a struct) and `Color` (an enum) are each the only value type of their
    // name, so `IRoot.Make`'s return decodes to the bare `Point` and `Paint`'s
    // `Color` parameter to the bare `Color` — not `NS.Point`/`NS.Color`. A
    // protocol type is never qualified either, so `Chain`'s `IOther` interface
    // parameter stays the bare `IOther`. (Pre-fix always-qualify wrongly spelled
    // the unique `Point`/`Color` with their namespace; a genuine collision is
    // covered by `RenderClosureNamespaceTests`.)
    ClosureFixture.with { catalog in
      #expect(catalog.decode(return: 1, in: .swift) == "Point")
      // `Make` has no parameters, so the four `Param` rows are, in declaration
      // order, `Paint`'s `Color` (1), `Listen`'s `Handler` (2), `Chain`'s
      // `IOther` (3), and `Invoke`'s `i4` (4).
      #expect(catalog.decode(parameter: 1, for: .swift) == "Color")
      #expect(catalog.decode(parameter: 3, for: .swift) == "IOther")
    }
  }

  @Test func `--closure emits a unique-named value type bare, with no namespace`() throws {
    // The emit half of collision-only: an unambiguous top-level value type is a
    // plain root, wrapped in no fabricated namespace `enum`, matching the bare
    // spelling its references carry. `Point` and `Color` are each uniquely
    // named, so the closure over `IRoot` emits them at the top level with no
    // `public enum NS` container — unlike a genuine collision, which
    // `RenderClosureNamespaceTests` wraps.
    try ClosureFixture.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("@frozen public struct Point {"))
      #expect(closed.contains("@frozen public struct Color: Hashable, Sendable {"))
      #expect(!closed.contains("public enum NS"))
      #expect(!closed.contains("NS.Point"))
      #expect(!closed.contains("NS.Color"))
    }
  }

  @Test func `--closure frontiers a reached type the language import provides`() throws {
    // Change 1 — frontier a `known` dependency. A type whose Identity
    // `(namespace, name)` is a key in the dialect's `known` bridge table is one
    // the consumer already has from the language import, so the closure must
    // emit no wrapper for it and not walk its members, exactly as the
    // layout-reject and nested-protocol frontiers do — while a reference still
    // spells through `dialect.known` (its bridged name). `IRoot.Make` returns
    // the local struct `Point` (namespace `NS`); a `-I` `swift.lang` that adds
    // `wellknown NS.Point PointBridge` makes `(NS, Point)` a `known` key, so
    // the closure frontiers `Point` — no `struct Point` renders — yet `Make`
    // still spells its return `PointBridge` from the bridge table. The unique
    // enum `Color`, absent from `known`, still emits.
    let bridge = "wellknown NS.Point PointBridge"
    try RenderClosureTests.withLanguage(adding: bridge) { directory in
      try ClosureFixture.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let closed = try shell.render(closure: "IRoot", template: "com")
        // The `known` struct is frontiered: no wrapper renders for it.
        #expect(!closed.contains("public struct Point"))
        // … yet a reference still spells its bridged name.
        #expect(closed.contains("-> PointBridge"))
        // The root interface, and a non-`known` value type it names, still emit.
        #expect(closed.contains("public protocol IRoot"))
        #expect(closed.contains("@frozen public struct Color: Hashable, Sendable {"))
      }
    }
  }

  @Test func `--closure drops a guid-less nongeneric interface a signature names`() throws {
    // `IRoot.Chain(IOther)` still names `IOther`, but `IOther`'s `GuidAttribute`
    // is removed, so it has no static IID and `references` yields a NULL iid.
    // Emitting it would spell `@com(interface: "")` — unusable source — so the
    // closure must drop it (the normal `interfaces` view's INNER GUID join
    // excludes it too), leaving it a frontier while `IRoot` still renders.
    // Pre-fix, only classes and guid-less delegates were filtered, so the
    // guid-less interface was emitted with an empty `@com` interface id.
    try ClosureFixture.withoutIOtherGuid { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot"))
      #expect(!closed.contains("public protocol IOther"))
      #expect(!closed.contains("@com(interface: \"\")"))
    }
  }

  /// Runs `body` with the path of a temporary `-I` directory whose
  /// `Languages/swift.lang` is the stock Swift spec with `extra` appended — so a
  /// render of the bundled `com` template (which declares `language: swift`)
  /// resolves the augmented spec (a search directory shadows the bundle), the
  /// hook a `known`-frontier test uses to add a `wellknown` line. The directory
  /// is removed afterwards.
  static func withLanguage(adding extra: String,
                           _ body: (String) throws -> Void) throws {
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let languages = directory.appendingPathComponent("Languages")
    try manager.createDirectory(at: languages, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let spec = RenderClosureTests.swiftLanguage + "\n" + extra + "\n"
    try Data(spec.utf8)
        .write(to: languages.appendingPathComponent("swift.lang"))
    try body(directory.path)
  }

  /// The stock Swift language spec — the conventions the `com` render's decode
  /// composes a spelling from — embedded so a test may augment it without
  /// reading the package bundle. It mirrors `Resources/Languages/swift.lang`;
  /// only the well-known projections a test appends differ.
  private static let swiftLanguage = """
    escape-prefix `
    escape-suffix `
    void Void
    root IUnknown
    type void Void
    type bool CBool
    type char Unicode.UTF16.CodeUnit
    type i1 CChar
    type u1 CUnsignedChar
    type i2 CShort
    type u2 CUnsignedShort
    type i4 CInt
    type u4 CUnsignedInt
    type i8 CLongLong
    type u8 CUnsignedLongLong
    type f4 CFloat
    type f8 CDouble
    type iptr Int
    type uptr UInt
    type string HSTRING
    type object UnsafeMutableRawPointer
    type typedref UnsafeMutableRawPointer
    pointer-mutable UnsafeMutablePointer
    pointer-const UnsafePointer
    rawpointer-mutable UnsafeMutableRawPointer
    rawpointer-const UnsafeRawPointer
    optional ?
    generic-open <
    generic-close >
    var-type T
    var-method M
    opaque UnsafeMutableRawPointer
    guid-iid IID
    guid-clsid CLSID
    wellknown Windows.Win32.Foundation.HRESULT HRESULT
    wellknown Windows.Win32.Foundation.BOOL BOOL
    """
}

/// A metadata fixture whose root interface `IRoot` names, across its method
/// signatures, one of each closure-reachable value kind — a struct it returns,
/// an enum and a delegate it takes, and another interface — so the `--closure`
/// walk pulls each in through the E3/E6/E7 edges and renders it through its own
/// template section. Ten tables packed back to back in table-number order; a
/// stored index `N` names the 0-based row `N - 1`, and a `TypeDefOrRef` token is
/// `(row << 2) | tag` (tag 0 `TypeDef`, tag 1 `TypeRef`).
///
///   TypeRef[0]: `Windows.Win32.Foundation.Metadata.GuidAttribute` — the IID
///               attribute the `interfaces` view keys on.
///   TypeRef[1..3]: `System.ValueType`/`System.Enum`/`System.MulticastDelegate`
///               — the bases the `types` view classifies a struct/enum/delegate
///               `TypeDef` by.
///   TypeDef[0]: `IRoot` (interface, `GuidAttribute`) owning the four methods.
///   TypeDef[1]: `Point` (struct, `Extends` ValueType) with one `i4` field.
///   TypeDef[2]: `Color` (enum, `Extends` Enum) with `value__` and the members
///               `Red`/`Green`, whose values live in the `Constant` table.
///   TypeDef[3]: `Handler` (delegate, `Extends` MulticastDelegate, its own
///               `GuidAttribute`) owning `Invoke` — a WinRT delegate is a COM
///               interface, so it carries a static IID the `@com` projection
///               reads.
///   TypeDef[4]: `IOther` (interface, `GuidAttribute`) — the signature-named
///               interface.
///   CustomAttribute[0..2]: the `GuidAttribute` rows for `IRoot`, `Handler`,
///               and `IOther`, in `Parent`-sorted order.
///   MethodDef[0..3]: `IRoot`'s `Make` (returns `Point`), `Paint(Color)`,
///               `Listen(Handler)`, `Chain(IOther)`.
///   MethodDef[4]: `Handler`'s `Invoke(i4)`.
private enum ClosureFixture {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x42, 0x00, 0x31, 0x00, 0x00, 0x00, 0x47, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x5c, 0x00, 0x59, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x62, 0x00, 0x59, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x59, 0x00,
    0x0d, 0x00, 0x02, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6e, 0x00,
    0x59, 0x00, 0x11, 0x00, 0x05, 0x00, 0x05, 0x00, 0x21, 0x00, 0x00, 0x00,
    0x76, 0x00, 0x59, 0x00, 0x00, 0x00, 0x05, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x8f, 0x00, 0x1d, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x1d, 0x00, 0x00, 0x00,
    0x85, 0x00, 0x1d, 0x00, 0x00, 0x00, 0x89, 0x00, 0x1d, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x95, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9a, 0x00, 0x06, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xa0, 0x00,
    0x0c, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xa7, 0x00, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xad, 0x00, 0x18, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x35, 0x00, 0x08, 0x00, 0x10, 0x00,
    0x3a, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x20, 0x00, 0x83, 0x00, 0x0b, 0x00,
    0x3f, 0x00, 0xa3, 0x00, 0x0b, 0x00, 0x20, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x45, 0x6e, 0x75, 0x6d, 0x00, 0x4d,
    0x75, 0x6c, 0x74, 0x69, 0x63, 0x61, 0x73, 0x74, 0x44, 0x65, 0x6c, 0x65,
    0x67, 0x61, 0x74, 0x65, 0x00, 0x4e, 0x53, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x50, 0x6f, 0x69, 0x6e, 0x74, 0x00, 0x43, 0x6f, 0x6c, 0x6f,
    0x72, 0x00, 0x48, 0x61, 0x6e, 0x64, 0x6c, 0x65, 0x72, 0x00, 0x49, 0x4f,
    0x74, 0x68, 0x65, 0x72, 0x00, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x5f, 0x5f,
    0x00, 0x52, 0x65, 0x64, 0x00, 0x47, 0x72, 0x65, 0x65, 0x6e, 0x00, 0x76,
    0x61, 0x6c, 0x75, 0x65, 0x00, 0x4d, 0x61, 0x6b, 0x65, 0x00, 0x50, 0x61,
    0x69, 0x6e, 0x74, 0x00, 0x4c, 0x69, 0x73, 0x74, 0x65, 0x6e, 0x00, 0x43,
    0x68, 0x61, 0x69, 0x6e, 0x00, 0x49, 0x6e, 0x76, 0x6f, 0x6b, 0x65, 0x00,
  ]

  // The `#Blob` heap: the empty blob, the five method signatures, the shared
  // `i4` field signature, the 20-byte interface `GuidAttribute` value (blob@32),
  // the two i4 constant values `5` and `7`, and the delegate's distinct 20-byte
  // `GuidAttribute` value (blob@63, `DEADBEEF-CAFE-BABE-F00D-1234567890AB`).
  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x08, 0x05, 0x20, 0x01, 0x01, 0x11, 0x0c,
    0x05, 0x20, 0x01, 0x01, 0x12, 0x10, 0x05, 0x20, 0x01, 0x01, 0x12, 0x14,
    0x04, 0x20, 0x01, 0x01, 0x08, 0x02, 0x06, 0x08, 0x14, 0x01, 0x00, 0x30,
    0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11, 0xad, 0xe5, 0x00, 0xaa, 0x00,
    0x44, 0x77, 0x3d, 0x00, 0x00, 0x04, 0x05, 0x00, 0x00, 0x00, 0x04, 0x07,
    0x00, 0x00, 0x00, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca,
    0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 4, range: 0 ..< 24,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 5, range: 24 ..< 94,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 4, range: 94 ..< 118,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 5, range: 118 ..< 188,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 4, range: 188 ..< 212,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 212 ..< 212,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 212 ..< 218,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 2, range: 218 ..< 230,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 3, range: 230 ..< 248,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 248 ..< 248,
                wide: 0, stride: 2),
    // An empty NestedClass, present as real metadata always is, so the
    // `references` recursive `resolved` CTE resolves the relation (this fixture
    // names its referenced types through top-level, module-scoped refs).
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 248 ..< 248,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Runs `body` over the fixture with `Point`'s `TypeDef` `Flags` overwritten to
  /// `flags` — used to mark the struct an explicit-layout (union) value type the
  /// closure must reject. `Point` is `TypeDef` row 2; the `TypeDef` table opens
  /// at byte 24 of the tables stream with stride 14, so row 2's `Flags` (its
  /// leading 4-byte field) begins at byte 38.
  static func withPointFlags(_ flags: UInt8,
                             _ body: (borrowing Storage) throws -> Void)
      rethrows {
    var bytes = ClosureFixture.bytes
    bytes[38] = flags
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Runs `body` with `Point`'s single field `value` marked `fdStatic` (the
  /// `0x10` bit OR-ed into its `FieldDef.Flags`), so the struct render must drop
  /// it — a static field is not instance storage. `value` is `FieldDef` row 1;
  /// the `FieldDef` table opens at byte 94 of the tables stream with stride 6,
  /// so its `Flags` (the leading 2-byte field) begins at byte 94.
  static func withStaticPointField(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    var bytes = ClosureFixture.bytes
    bytes[94] |= 0x10
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Runs `body` with `Point`'s single field renamed from `value` to `name` — a
  /// metadata field literally named `name`, which `SANITIZE` escapes when it is
  /// a reserved word. `value` is `FieldDef` row 1; the table opens at byte 94
  /// (stride 6) with `Flags`(2) then `Name`(2), so its `Name` index is at bytes
  /// 96–97, repointed to `name` appended to the string heap. The signature is
  /// untouched, so the field still decodes to `CInt`.
  static func withPointFieldNamed(_ name: String,
                                  _ body: (borrowing Storage) throws -> Void)
      rethrows {
    var bytes = ClosureFixture.bytes
    var strings = ClosureFixture.strings
    let offset = strings.count
    strings.append(contentsOf: Array(name.utf8))
    strings.append(0)
    bytes[96] = UInt8(offset & 0xff)
    bytes[97] = UInt8(offset >> 8)
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Runs `body` over the fixture with `IOther`'s `GuidAttribute` removed, so the
  /// signature-named interface resolves no static IID. `CustomAttribute` is the
  /// 9th relation (index 8); its three rows are `IRoot`'s, `Handler`'s, and
  /// `IOther`'s `GuidAttribute`s in `Parent`-sorted order, so dropping the table
  /// to its first two rows (range `230 ..< 242`) removes `IOther`'s alone.
  static func withoutIOtherGuid(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    var relations = ClosureFixture.relations
    relations[8] = WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2,
                               range: 230 ..< 242, wide: 0, stride: 6)
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  /// Runs `body` over the fixture with `Handler` (`TypeDef` row 4) made
  /// parameterized — a single `GenericParam` row (table 42, §II.22.20) owning
  /// it, its parameter name `T` appended to the string heap. A generic delegate
  /// bears no static IID (a per-instantiation PIID), so `guid(of:)` resolves
  /// nothing; the closure must keep it as generic and emit its ABI-protocol arm,
  /// not drop it as GUID-less. The `generics` view reads `GenericParam` by
  /// `Owner_TypeDef`, so the row alone makes `declarations(Handler)` non-empty.
  static func withGenericHandler(named name: String = "T",
                                 _ body: (borrowing Storage) throws -> Void)
      rethrows {
    var bytes = ClosureFixture.bytes
    var strings = ClosureFixture.strings
    var relations = ClosureFixture.relations
    // The generic parameter's name (`T` by default), appended to the string
    // heap; a keyword name exercises the declaration's identifier escaping.
    let offset = strings.count
    strings.append(contentsOf: Array(name.utf8))
    strings.append(0)
    // One `GenericParam` row (stride 8, narrow indexes): Number 0, Flags 0,
    // Owner=TypeOrMethodDef(TypeDef row 4)=(4 << 1) | 0 = 8, Name at `offset`.
    let start = bytes.count
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x08, 0x00,
                              UInt8(offset & 0xff), UInt8(offset >> 8)])
    relations.append(WinMD.Table(Metadata.Tables.GenericParam.self, rows: 1,
                                 range: start ..< bytes.count,
                                 wide: 0, stride: 8))
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid | (1 << 42),
                          sorted: 0)
    try body(storage)
  }

  /// Runs `body` over the fixture with `Green`'s constant value overwritten from
  /// 7 to 5, so `Color` has two members (`Red`, `Green`) sharing the raw value 5
  /// — a Win32 enum alias; the stored struct newtype renders both as `static
  /// let`s, a repeat a native Swift `enum`'s `case`s could not have expressed.
  /// `Green`'s constant is the second of the two little-endian i4 values in the
  /// `#Blob` heap: they follow the 20-byte interface `GuidAttribute` value at
  /// `blob@32` (a 1-byte length prefix plus 20 bytes, so ending at index 52), so
  /// `Red`'s value blob is `[0x04] 05 00 00 00` at index 53 and `Green`'s is
  /// `[0x04] 07 00 00 00` at index 58 — its low value byte (`0x07`) at index 59,
  /// which this overwrites to `0x05`.
  static func withDuplicateColorValue(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    var blob = ClosureFixture.blob
    blob[59] = 0x05
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
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

/// A `-I` override supplying the former two-column `Render/fields.sql` (`Id`,
/// `Name` — no `Flags`) must not trap the walk or the struct render, which now
/// read a `Flags` column. Render-query shadowing is a supported extension
/// point, so a copied override carrying the pre-`Flags` shape renders as it did
/// before: a field with no `Flags` counts as instance storage.
@Suite struct RenderFieldsOverrideTests {
  @Test func `a two-column fields override renders a struct without trapping`() throws {
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let render = directory.appendingPathComponent("Render")
    try manager.createDirectory(at: render, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let fields = "SELECT f.Id, SANITIZE(f.Name) AS Name FROM fields f"
    try Data(fields.utf8)
        .write(to: render.appendingPathComponent("fields.sql"))
    try ClosureFixture.withStaticPointField { catalog in
      let shell = Shell(catalog, search: [directory.path])
      let closed = try shell.render(closure: "IRoot", template: "com")
      // No trap on the missing `Flags` column; with no `Flags` the field counts
      // as instance storage, so the override's `value` field renders.
      #expect(closed.contains("@frozen public struct Point {"))
      #expect(closed.contains("public var value"))
    }
  }
}
