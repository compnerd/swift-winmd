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

  @Test func `--closure qualifies a nested interface base named through a TypeRef`() throws {
    // The nested `Widget` reference is scoped to the local `A`, so the
    // scope-chain walk resolves it to `A.Widget` — never `B.Widget`, which
    // shares the bare name under a different enclosing. `A.Widget` is a
    // metadata-nested interface, which projects as a Swift `protocol` that
    // cannot legally nest in its `A` container, so the closure frontiers it —
    // the base is dropped from emission (the consumer defines it). But `IRoot`
    // must name its base through the enclosing path it resolves to,
    // `A.Widget` — the same `requires` scope-chain resolution the walk performs
    // — not the bare `Widget`, which binds no visible declaration and could not
    // tell the two same-named nested `Widget`s apart. Pre-finding-A the walk
    // emitted `A.Widget` as a top-level bare `public protocol Widget`.
    try RenderClosureNestedConflationTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `IRoot` names its nested base through the enclosing path, not bare.
      #expect(closed.contains("public protocol IRoot: A.Widget {"))
      #expect(!closed.contains("public protocol IRoot: Widget {"))
      // The nested interface base is a dropped frontier: no `Widget`
      // declaration renders, so neither same-named nested `Widget`'s IID
      // appears — `A.Widget`'s well-known GUID nor `B.Widget`'s all-0x11 one.
      #expect(!closed.contains("public protocol Widget"))
      #expect(!closed.contains("0C733A30-2A1C-11CE-ADE5-00AA0044773D"))
      #expect(!closed.contains("11111111-1111-1111-1111-111111111111"))
    }
  }
}

/// Coverage of the `references` TypeRef arm's scope-chain walk over a *nested*
/// external reference named by a method signature (edge E3) — the references-side
/// mirror of the requires-side nested-external test. The fixture assembles a root
/// `IRoot` whose one method `Get` returns a nested `TypeRef` `Widget` whose
/// immediate `ResolutionScope` is another `TypeRef` (`Outer`), whose own scope is
/// an external `AssemblyRef`. Its chain terminates externally, so `resolved`
/// never reaches its anchor and the reference drops. A local nested interface
/// `Widget` (empty namespace, under a local `Host`) shares the bare name, so the
/// pre-fix name-only join would have enqueued and emitted `public protocol
/// Widget`; binding the referenced `TypeRef` row keeps that unrelated declaration
/// out while `IRoot.Get` still names `Widget` in its signature.
struct RenderReferencesNestedExternalTests {
  // Nine tables packed back to back in table-number order — TypeRef (#1, 3
  // rows), TypeDef (#2, 3 rows), MethodDef (#6, 1 row), Param (#8, empty),
  // InterfaceImpl (#9, empty), MemberRef (#10, 1 row), CustomAttribute (#12, 2
  // rows), AssemblyRef (#35, 1 row), NestedClass (#41, 1 row) — every index
  // narrow (2-byte). ECMA-335 rows are 1-based; a coded index is
  // `(row << bits) | tag`, and a signature's `TypeDefOrRef` is compressed the
  // same way (tag 0 `TypeDef`, tag 1 `TypeRef`).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope(AssemblyRef row 1)=(1<<2)|2=6,
  //                TypeName="Outer"(63), TypeNamespace="NS"(49) — the external
  //                enclosing reference.
  //   TypeRef[2]:  ResolutionScope(TypeRef row 2)=(2<<2)|3=11,
  //                TypeName="Widget"(69), TypeNamespace=empty(0) — nested under
  //                `Outer`; the chain terminates at the `AssemblyRef`.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(52),
  //                TypeNamespace="NS"(49), MethodList=1 — owns `Get`.
  //   TypeDef[1]:  Flags=0 (a plain class), TypeName="Host"(58),
  //                TypeNamespace="NS"(49), MethodList=2 — a local enclosing.
  //   TypeDef[2]:  Flags=0x21, TypeName="Widget"(69), TypeNamespace=empty(0),
  //                MethodList=2 — a local nested interface sharing the bare name.
  //   MethodDef[0]: TypeName="Get"(76), Signature=blob[1] — `Widget Get()`, its
  //                return the nested external `TypeRef` `Widget`
  //                (`TypeDefOrRef`=(3<<2)|1=13).
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[6] — `IRoot`'s IID.
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 3)=(3<<5)|3=99,
  //                Type=11, Value=blob[6] — the local `Widget`'s IID.
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
    // TypeDef[0] (IRoot): Flags, Name, Namespace, Extends, FieldList, MethodList
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (Host)
    0x00, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x02, 0x00,
    // TypeDef[2] (local nested Widget)
    0x21, 0x00, 0x00, 0x00, 0x45, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x02, 0x00,
    // MethodDef[0] (Get): RVA, ImplFlags, Flags, Name, Signature, ParamList
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x4c, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x06, 0x00,
    // CustomAttribute[1]
    0x63, 0x00, 0x0b, 0x00, 0x06, 0x00,
    // AssemblyRef[0]
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // NestedClass[0]
    0x03, 0x00, 0x02, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IRoot\0Host\0Outer\0
  //  Widget\0Get\0": GuidNamespace@1, GuidName@35, NS@49, IRoot@52, Host@58,
  // Outer@63, Widget@69, Get@76.
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
    0x47, 0x65, 0x74, 0x00,
  ]

  // The blob heap: offset 0 the empty blob; offset 1 the `Get` method signature
  // (length 4: HASTHIS, 0 params, return `ELEMENT_TYPE_CLASS` naming the
  // `TypeDefOrRef` 13 — the nested `Widget` reference); offset 6 the 20-byte
  // `GuidAttribute` value (the well-known GUID), preceded by its length 0x14.
  private static let blob: Array<UInt8> = [
    0x00,
    0x04, 0x20, 0x00, 0x12, 0x0d,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 3, range: 0 ..< 18,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 18 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 60 ..< 74,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 80 ..< 92,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.AssemblyRef.self, rows: 1, range: 92 ..< 112,
                wide: 0, stride: 20),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 112 ..< 116,
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

  @Test func `--closure drops a nested external type a signature names`() throws {
    // `IRoot.Get` returns a nested `TypeRef` `Widget` whose immediate scope is
    // another `TypeRef` (so the pre-fix immediate-scope gate would pass) but
    // whose chain terminates at an `AssemblyRef`. Binding the referenced row
    // resolves it through the scope-chain CTE to no local row, so the local
    // nested `Widget` sharing the bare name is not enqueued: `Get` names
    // `Widget` in its signature yet no `Widget` declaration is emitted.
    try RenderReferencesNestedExternalTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot"))
      // The edge is genuine (the method names the nested `Widget`), and a
      // nested type spells fully qualified from its outermost encloser — the
      // signature walks the reference's `ResolutionScope_TypeRef` chain to
      // `Outer`, so the return reads `Outer.Widget`, not a bare `Widget` that
      // would collide with any other nested `Widget`.
      #expect(closed.contains("-> Outer.Widget"))
      // … but the nested external ref is a frontier, so no `Widget` declaration.
      #expect(!closed.contains("public protocol Widget"))
    }
  }
}

/// Coverage of the nested value-type name collision the closure render once
/// emitted as duplicate top-level declarations. The fixture assembles a root
/// `IRoot` whose methods return two enclosing structs `Foo` and `Baz`, each of
/// which encloses a distinct nested struct sharing the bare `TypeName` `Bar` —
/// `Foo.Bar` and `Baz.Bar`. A flat emission would spell both nested signatures
/// `-> Bar` and emit two top-level `struct Bar`, an ambiguous, non-compiling
/// clash. The render must instead nest each `Bar` under its enclosing struct —
/// a real emitted value-type container, since a nested type may legally nest
/// only inside an emitted `struct`/`enum`, never a fabricated namespace `enum`
/// — and spell each return fully qualified, so the two `Bar`s are distinct
/// declarations (`Foo.Bar` and `Baz.Bar`) and each signature names the right
/// one. `Foo`/`Baz` are themselves reached (returned by `IRoot.GetC`/`GetD`) so
/// the two children nest inside real emitted containers rather than fabricated
/// ones.
struct RenderClosureNestedValueCollisionTests {
  // Nine tables packed back to back in table-number order — TypeRef (#1, 2
  // rows), TypeDef (#2, 5 rows), FieldDef (#4, 2 rows), MethodDef (#6, 4 rows),
  // Param (#8, empty), InterfaceImpl (#9, empty), MemberRef (#10, 1 row),
  // CustomAttribute (#12, 1 row), NestedClass (#41, 2 rows) — every index narrow
  // (2-byte). ECMA-335 rows are 1-based; a coded index is `(row << bits) | tag`,
  // and a signature's `TypeDefOrRef` is compressed the same way (tag 0
  // `TypeDef`).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope=0, TypeName="ValueType"(56),
  //                TypeNamespace="System"(49) — the base the `types` view
  //                classifies a struct by.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(69),
  //                TypeNamespace="NS"(66), FieldList=1, MethodList=1 — owns
  //                `GetA`/`GetB`/`GetC`/`GetD`.
  //   TypeDef[1]:  Flags=0, TypeName="Foo"(75), TypeNamespace="NS"(66),
  //                Extends=ValueType (TypeDefOrRef=(2<<2)|1=9), FieldList=1,
  //                MethodList=5 — a local enclosing struct, no fields of its own.
  //   TypeDef[2]:  Flags=0, TypeName="Baz"(79), TypeNamespace="NS"(66),
  //                Extends=9, FieldList=1, MethodList=5 — the other enclosing
  //                struct.
  //   TypeDef[3]:  Flags=0, TypeName="Bar"(83), TypeNamespace=empty(0),
  //                Extends=9, FieldList=1, MethodList=5 — `Foo.Bar`, a nested
  //                struct with one `i4` field.
  //   TypeDef[4]:  Flags=0, TypeName="Bar"(83), TypeNamespace=empty(0),
  //                Extends=9, FieldList=2, MethodList=5 — `Baz.Bar`, same bare
  //                name under a different enclosing.
  //   FieldDef[0]: Name="x"(87), Signature=blob[11] — `Foo.Bar`'s `i4` field.
  //   FieldDef[1]: Name="x"(87), Signature=blob[11] — `Baz.Bar`'s `i4` field.
  //   MethodDef[0]: Name="GetA"(89), Signature=blob[1] — `Foo.Bar GetA()`, its
  //                return the nested `TypeDef` `Foo.Bar` (`TypeDefOrRef`
  //                =(4<<2)|0=16).
  //   MethodDef[1]: Name="GetB"(94), Signature=blob[6] — `Baz.Bar GetB()`, its
  //                return the nested `TypeDef` `Baz.Bar` (`TypeDefOrRef`
  //                =(5<<2)|0=20).
  //   MethodDef[2]: Name="GetC"(99), Signature=blob[35] — `Foo GetC()`, its
  //                return the enclosing `TypeDef` `Foo` (`TypeDefOrRef`
  //                =(2<<2)|0=8), which pulls `Foo` into the closure.
  //   MethodDef[3]: Name="GetD"(104), Signature=blob[40] — `Baz GetD()`, its
  //                return the enclosing `TypeDef` `Baz` (`TypeDefOrRef`
  //                =(3<<2)|0=12), which pulls `Baz` into the closure.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the
  //                `GuidAttribute` ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[14] — `IRoot`'s IID.
  //   NestedClass[0]: NestedClass=4 (TypeDef row 4), EnclosingClass=2 (Foo).
  //   NestedClass[1]: NestedClass=5 (TypeDef row 5), EnclosingClass=3 (Baz).
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (System.ValueType)
    0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    // TypeDef[0] (IRoot): Flags, Name, Namespace, Extends, FieldList, MethodList
    0x21, 0x00, 0x00, 0x00, 0x45, 0x00, 0x42, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (Foo): sequential layout, Extends=ValueType(9), MethodList=5
    0x08, 0x00, 0x00, 0x00, 0x4b, 0x00, 0x42, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x05, 0x00,
    // TypeDef[2] (Baz): sequential layout, Extends=ValueType(9), MethodList=5
    0x08, 0x00, 0x00, 0x00, 0x4f, 0x00, 0x42, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x05, 0x00,
    // TypeDef[3] (Foo.Bar): sequential layout, MethodList=5
    0x08, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x05, 0x00,
    // TypeDef[4] (Baz.Bar): sequential layout, MethodList=5
    0x08, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x02, 0x00, 0x05, 0x00,
    // FieldDef[0] (Foo.Bar.x): Flags, Name, Signature
    0x00, 0x00, 0x57, 0x00, 0x0b, 0x00,
    // FieldDef[1] (Baz.Bar.x)
    0x00, 0x00, 0x57, 0x00, 0x0b, 0x00,
    // MethodDef[0] (GetA): RVA, ImplFlags, Flags, Name, Signature, ParamList
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x59, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MethodDef[1] (GetB)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x5e, 0x00, 0x06, 0x00, 0x01, 0x00,
    // MethodDef[2] (GetC): return `Foo` (blob[35])
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x63, 0x00, 0x23, 0x00, 0x01, 0x00,
    // MethodDef[3] (GetD): return `Baz` (blob[40])
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x68, 0x00, 0x28, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x0e, 0x00,
    // NestedClass[0] (Foo.Bar under Foo)
    0x04, 0x00, 0x02, 0x00,
    // NestedClass[1] (Baz.Bar under Baz)
    0x05, 0x00, 0x03, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0System\0ValueType\0NS\0
  //  IRoot\0Foo\0Baz\0Bar\0x\0GetA\0GetB\0GetC\0GetD\0": GuidNamespace@1,
  // GuidName@35, System@49, ValueType@56, NS@66, IRoot@69, Foo@75, Baz@79,
  // Bar@83, x@87, GetA@89, GetB@94, GetC@99, GetD@104.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x56, 0x61, 0x6c, 0x75, 0x65, 0x54, 0x79, 0x70, 0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00,
    0x46, 0x6f, 0x6f, 0x00,
    0x42, 0x61, 0x7a, 0x00,
    0x42, 0x61, 0x72, 0x00,
    0x78, 0x00,
    0x47, 0x65, 0x74, 0x41, 0x00,
    0x47, 0x65, 0x74, 0x42, 0x00,
    0x47, 0x65, 0x74, 0x43, 0x00,
    0x47, 0x65, 0x74, 0x44, 0x00,
  ]

  // The blob heap: offset 0 the empty blob; offset 1 the `GetA` signature
  // (length 4: HASTHIS, 0 params, return `ELEMENT_TYPE_VALUETYPE` naming the
  // `TypeDefOrRef` 16 — `Foo.Bar`); offset 6 the `GetB` signature (return
  // `TypeDefOrRef` 20 — `Baz.Bar`); offset 11 the shared `i4` field signature
  // (length 2: FIELD, `ELEMENT_TYPE_I4`); offset 14 the 20-byte `GuidAttribute`
  // value (the well-known GUID), preceded by its length 0x14; offset 35 the
  // `GetC` signature (return `TypeDefOrRef` 8 — the enclosing struct `Foo`);
  // offset 40 the `GetD` signature (return `TypeDefOrRef` 12 — `Baz`). The two
  // enclosing-struct signatures follow the GUID value so its offset 14 stays put.
  private static let blob: Array<UInt8> = [
    0x00,
    0x04, 0x20, 0x00, 0x11, 0x10,
    0x04, 0x20, 0x00, 0x11, 0x14,
    0x02, 0x06, 0x08,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
    0x04, 0x20, 0x00, 0x11, 0x08,
    0x04, 0x20, 0x00, 0x11, 0x0c,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 5, range: 12 ..< 82,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 2, range: 82 ..< 94,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 4, range: 94 ..< 150,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 150 ..< 150,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 150 ..< 150,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 150 ..< 156,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 156 ..< 162,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 2, range: 162 ..< 170,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 12) | (1 << 41)

  /// Runs `body` over a `Storage` catalog bound to the assembled metadata.
  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure nests two same-named value types under their enclosers`() throws {
    // `IRoot.GetA` returns `Foo.Bar` and `IRoot.GetB` returns `Baz.Bar` — two
    // distinct nested structs that share the bare name `Bar` — while `GetC`/
    // `GetD` return their enclosing structs `Foo`/`Baz`, so both enclosers are
    // reached and emitted as real value-type containers. The closure must nest
    // each `Bar` inside its enclosing struct and spell each return by its
    // enclosing dot-path, so the two declarations are distinct and each
    // signature names the right one. The enclosing type already disambiguates
    // the two `Bar`s (`Foo.Bar` vs `Baz.Bar`), so — collision-only — no
    // namespace is fabricated: `Foo`/`Baz` are uniquely named, so they spell and
    // emit bare, and their `Bar`s spell `Foo.Bar`/`Baz.Bar` rather than
    // `NS.Foo.Bar`. Pre-fix, both spelled `-> Bar` and both emitted as a
    // top-level `struct Bar`, an ambiguous non-compiling clash.
    try RenderClosureNestedValueCollisionTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `Foo`/`Baz` are uniquely named top-level value types, so neither is
      // wrapped in a fabricated namespace `enum` — the `NS` namespace stays off
      // the spelling and the emit.
      #expect(!closed.contains("public enum NS"))
      #expect(!closed.contains("NS.Foo"))
      #expect(!closed.contains("NS.Baz"))
      // Each enclosing struct is a top-level `struct`, never a fabricated `enum`.
      #expect(closed.contains("@frozen public struct Foo {"))
      #expect(closed.contains("@frozen public struct Baz {"))
      #expect(!closed.contains("public enum Foo"))
      #expect(!closed.contains("public enum Baz"))
      // The two `Bar` structs are actual nested declarations — never a top-level
      // `struct Bar` — one under each enclosing struct.
      #expect(closed.contains("@frozen public struct Bar {"))
      #expect(closed.contains("public var x: CInt"))
      #expect(!closed.contains("\n@frozen public struct Bar"))
      // Exactly two `Bar` declarations, one per enclosing.
      #expect(closed.components(separatedBy: "public struct Bar {").count == 3)
      // Each method spells its nested return by its enclosing dot-path, so the
      // two `Bar`s are told apart by their distinct enclosers.
      #expect(closed.contains("-> Foo.Bar"))
      #expect(closed.contains("-> Baz.Bar"))
      #expect(closed.contains("-> Foo"))
      #expect(closed.contains("-> Baz"))
      // A container sorts at its earliest-emitted descendant, and the walk emits
      // `Foo.Bar` before `Baz.Bar` (the local `Id` breaks the shared-name tie),
      // so `Foo` precedes `Baz`, and both precede the interface naming them.
      let foo = try #require(closed.range(of: "public struct Foo"))
      let baz = try #require(closed.range(of: "public struct Baz"))
      let root = try #require(closed.range(of: "public protocol IRoot"))
      #expect(foo.lowerBound < baz.lowerBound)
      #expect(baz.lowerBound < root.lowerBound)
    }
  }

  @Test func `--closure nests a child before a custom template's footer`() throws {
    // A custom `com` template whose struct section emits a footer after the
    // closing brace — a trailing comment on its own line — must still nest a
    // child value type inside the container, before the brace, not after the
    // footer. `Foo` encloses the nested struct `Foo.Bar`, so the closure
    // splices `Bar` before `Foo`'s `}` and keeps the footer a line past it.
    // Pre-fix, `inject` treated the body's last line as the closer, so the
    // footer looked like the brace and `Bar` spilled out past `Foo` as a
    // sibling — uncompilable, since a signature still spells `Foo.Bar`.
    try RenderClosureNestedValueCollisionTests.with { catalog in
      var shell = Shell(catalog)
      // A struct section that closes the brace on its own line, then a footer
      // line after it — the shape that trips a last-line closer heuristic.
      shell.templates["com"] = """
        {{! language: swift }}
        {{#interface}}
        protocol {{{name}}} {}
        {{/interface}}
        {{#struct}}
        struct {{{name}}} {
        }
        // end {{{name}}}
        {{/struct}}
        """
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `Bar` nests directly inside `Foo`, before `Foo`'s closing brace.
      #expect(closed.contains("struct Foo {\n    struct Bar {"))
      // The footer rides one line past the real closer, preserved.
      #expect(closed.contains("}\n// end Foo"))
      // `Bar` never spills out as a sibling after `Foo`'s brace.
      #expect(!closed.contains("}\n    struct Bar {"))
    }
  }
}

/// Coverage of a value type reachable under an emitted nongeneric interface: a
/// nested type may nest only inside a value-type container (an emitted `struct`
/// or `enum`), never a Swift `protocol`. The fixture assembles a root interface
/// `IOuter` (a `protocol` bearing a static IID) whose method returns a struct
/// `IOuter.Inner` nested under it in the metadata. Splicing `Inner` into the
/// protocol body would compile to `type 'Inner' cannot be nested in protocol
/// 'IOuter'`, so the closure must leave `Inner` a frontier — dropped from the
/// output, not injected into the protocol — while `IOuter` still renders as a
/// `protocol` carrying only its `func` requirements.
struct RenderClosureNestedInInterfaceTests {
  // Nine tables in table-number order — TypeRef (#1, 2 rows), TypeDef (#2, 2
  // rows), FieldDef (#4, 1 row), MethodDef (#6, 1 row), Param (#8, empty),
  // InterfaceImpl (#9, empty), MemberRef (#10, 1 row), CustomAttribute (#12, 1
  // row), NestedClass (#41, 1 row) — every index narrow (2-byte).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope=0, TypeName="ValueType"(56),
  //                TypeNamespace="System"(49) — the struct base.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IOuter"(69),
  //                TypeNamespace="NS"(66), FieldList=1, MethodList=1 — the root
  //                interface, emitted as a `protocol`.
  //   TypeDef[1]:  Flags=0, TypeName="Inner"(76), TypeNamespace=empty(0),
  //                Extends=ValueType(9), FieldList=1, MethodList=2 — a struct
  //                nested under `IOuter`.
  //   FieldDef[0]: Name="x"(82), Signature=blob[6] — `Inner`'s `i4` field.
  //   MethodDef[0]: Name="GetInner"(84), Signature=blob[1] — return the nested
  //                `TypeDef` `Inner` (`TypeDefOrRef`=(2<<2)|0=8).
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=9 — the ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=35,
  //                Type=CustomAttributeType(MemberRef row 1)=11, Value=blob[9].
  //   NestedClass[0]: NestedClass=2 (Inner), EnclosingClass=1 (IOuter).
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (System.ValueType)
    0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    // TypeDef[0] (IOuter): interface, MethodList=1
    0x21, 0x00, 0x00, 0x00, 0x45, 0x00, 0x42, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (Inner): struct nested under IOuter, MethodList=2
    0x00, 0x00, 0x00, 0x00, 0x4c, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x02, 0x00,
    // FieldDef[0] (Inner.x)
    0x00, 0x00, 0x52, 0x00, 0x06, 0x00,
    // MethodDef[0] (GetInner): return Inner (blob[1])
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x54, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x09, 0x00,
    // NestedClass[0] (Inner under IOuter)
    0x02, 0x00, 0x01, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0System\0ValueType\0NS\0
  //  IOuter\0Inner\0x\0GetInner\0": GuidNamespace@1, GuidName@35, System@49,
  // ValueType@56, NS@66, IOuter@69, Inner@76, x@82, GetInner@84.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x56, 0x61, 0x6c, 0x75, 0x65, 0x54, 0x79, 0x70, 0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x4f, 0x75, 0x74, 0x65, 0x72, 0x00,
    0x49, 0x6e, 0x6e, 0x65, 0x72, 0x00,
    0x78, 0x00,
    0x47, 0x65, 0x74, 0x49, 0x6e, 0x6e, 0x65, 0x72, 0x00,
  ]

  // Blob heap: offset 1 the `GetInner` signature (return `ELEMENT_TYPE_VALUETYPE`
  // naming `TypeDefOrRef` 8 — `Inner`); offset 6 the `i4` field signature;
  // offset 9 the 20-byte `GuidAttribute` value.
  private static let blob: Array<UInt8> = [
    0x00,
    0x04, 0x20, 0x00, 0x11, 0x08,
    0x02, 0x06, 0x08,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 40 ..< 46,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 46 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 60 ..< 66,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 66 ..< 72,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 72 ..< 76,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 12) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure does not nest a value type inside an emitted interface`() throws {
    // `IOuter.GetInner` returns the struct `IOuter.Inner`, a value type nested
    // under the interface in the metadata. A Swift `protocol` cannot contain a
    // nested type, so the closure must not emit `Inner` inside `IOuter`'s body —
    // it leaves `Inner` a dropped frontier and renders `IOuter` as a `protocol`
    // holding only its `func` requirement. Pre-fix, the nesting assembly spliced
    // `Inner` before the protocol's closing brace, producing source that fails to
    // compile with `type 'Inner' cannot be nested in protocol 'IOuter'`.
    try RenderClosureNestedInInterfaceTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IOuter", template: "com")
      // `IOuter` renders as a protocol.
      #expect(closed.contains("public protocol IOuter"))
      // The nested value type is a dropped frontier: never emitted, never
      // injected into the protocol body — no `struct`/`enum`/`@frozen` anywhere.
      #expect(!closed.contains("struct Inner"))
      #expect(!closed.contains("@frozen"))
      #expect(!closed.contains("enum"))
      // The protocol body holds only `func` requirements — every non-brace,
      // non-attribute line inside it is a `func`, so no declaration can be nested
      // where Swift would reject it.
      for line in closed.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed.hasPrefix("//") { continue }
        if trimmed.hasPrefix("@com") { continue }
        if trimmed.hasPrefix("public protocol") { continue }
        if trimmed == "}" { continue }
        #expect(trimmed.hasPrefix("func "))
      }
    }
  }
}

/// Coverage of a value type reachable under a local runtime class: a nested
/// type may nest only inside an emitted value-type container, and a runtime
/// class is a frontier the walk excludes, never emitted. The fixture assembles
/// a root interface `IRoot` whose `GetInner` returns a struct `Outer.Inner`
/// nested under the local class `Outer`, and whose `GetOuter` returns the class
/// `Outer` itself. Fabricating a `public enum Outer` container to hold `Inner`
/// would shadow the real class `Outer`, so `GetOuter`'s return would resolve to
/// the namespace enum rather than the consumer's real class. The closure must
/// leave `Inner` a dropped frontier and fabricate no `enum Outer`, so the real
/// `Outer` a signature names stays the consumer's type, un-shadowed.
struct RenderClosureNestedInClassTests {
  // Nine tables in table-number order — TypeRef (#1, 2 rows), TypeDef (#2, 3
  // rows), FieldDef (#4, 1 row), MethodDef (#6, 2 rows), Param (#8, empty),
  // InterfaceImpl (#9, empty), MemberRef (#10, 1 row), CustomAttribute (#12, 1
  // row), NestedClass (#41, 1 row) — every index narrow (2-byte).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope=0, TypeName="ValueType"(56),
  //                TypeNamespace="System"(49) — the struct base.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(69),
  //                TypeNamespace="NS"(66), FieldList=1, MethodList=1 — owns
  //                `GetInner`/`GetOuter`.
  //   TypeDef[1]:  Flags=0, TypeName="Outer"(75), TypeNamespace="NS"(66),
  //                Extends=0 (no base) → kind `class`, FieldList=1, MethodList=3
  //                — a runtime class the walk excludes from the value closure.
  //   TypeDef[2]:  Flags=0, TypeName="Inner"(81), TypeNamespace=empty(0),
  //                Extends=ValueType(9), FieldList=1, MethodList=3 — a struct
  //                nested under `Outer`.
  //   FieldDef[0]: Name="x"(87), Signature=blob[11] — `Inner`'s `i4` field.
  //   MethodDef[0]: Name="GetInner"(89), Signature=blob[1] — return the nested
  //                `TypeDef` `Inner` (`ELEMENT_TYPE_VALUETYPE`, `TypeDefOrRef`
  //                =(3<<2)|0=12).
  //   MethodDef[1]: Name="GetOuter"(98), Signature=blob[6] — return the class
  //                `Outer` (`ELEMENT_TYPE_CLASS`, `TypeDefOrRef`=(2<<2)|0=8).
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=9 — the ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=35,
  //                Type=CustomAttributeType(MemberRef row 1)=11, Value=blob[14].
  //   NestedClass[0]: NestedClass=3 (Inner), EnclosingClass=2 (Outer).
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (System.ValueType)
    0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    // TypeDef[0] (IRoot): interface, MethodList=1
    0x21, 0x00, 0x00, 0x00, 0x45, 0x00, 0x42, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (Outer): runtime class (Extends=0), MethodList=3
    0x00, 0x00, 0x00, 0x00, 0x4b, 0x00, 0x42, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x03, 0x00,
    // TypeDef[2] (Inner): struct nested under Outer, MethodList=3
    0x00, 0x00, 0x00, 0x00, 0x51, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x03, 0x00,
    // FieldDef[0] (Inner.x)
    0x00, 0x00, 0x57, 0x00, 0x0b, 0x00,
    // MethodDef[0] (GetInner): return Inner (blob[1])
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x59, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MethodDef[1] (GetOuter): return Outer (blob[6])
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x62, 0x00, 0x06, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x0e, 0x00,
    // NestedClass[0] (Inner under Outer)
    0x03, 0x00, 0x02, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0System\0ValueType\0NS\0
  //  IRoot\0Outer\0Inner\0x\0GetInner\0GetOuter\0": GuidNamespace@1, GuidName@35,
  // System@49, ValueType@56, NS@66, IRoot@69, Outer@75, Inner@81, x@87,
  // GetInner@89, GetOuter@98.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x56, 0x61, 0x6c, 0x75, 0x65, 0x54, 0x79, 0x70, 0x65, 0x00,
    0x4e, 0x53, 0x00,
    0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00,
    0x4f, 0x75, 0x74, 0x65, 0x72, 0x00,
    0x49, 0x6e, 0x6e, 0x65, 0x72, 0x00,
    0x78, 0x00,
    0x47, 0x65, 0x74, 0x49, 0x6e, 0x6e, 0x65, 0x72, 0x00,
    0x47, 0x65, 0x74, 0x4f, 0x75, 0x74, 0x65, 0x72, 0x00,
  ]

  // Blob heap: offset 1 the `GetInner` signature (return `ELEMENT_TYPE_VALUETYPE`
  // naming `TypeDefOrRef` 12 — `Inner`); offset 6 the `GetOuter` signature
  // (return `ELEMENT_TYPE_CLASS` naming `TypeDefOrRef` 8 — the class `Outer`);
  // offset 11 the `i4` field signature; offset 14 the 20-byte `GuidAttribute`
  // value.
  private static let blob: Array<UInt8> = [
    0x00,
    0x04, 0x20, 0x00, 0x11, 0x0c,
    0x04, 0x20, 0x00, 0x12, 0x08,
    0x02, 0x06, 0x08,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 54 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 2, range: 60 ..< 88,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 88 ..< 88,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 88 ..< 88,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 88 ..< 94,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 94 ..< 100,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 100 ..< 104,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 12) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure fabricates no container for a value type nested in a class`() throws {
    // `IRoot.GetInner` returns `Outer.Inner`, a struct nested under the local
    // runtime class `Outer`; `IRoot.GetOuter` returns `Outer` itself. `Outer` is
    // a class — a frontier the walk excludes, never emitted — so the closure must
    // fabricate no `public enum Outer` to hold `Inner`: that enum would shadow
    // the real class `Outer` a signature names, redirecting `GetOuter`'s return
    // to the namespace enum. `Inner` is a dropped frontier, and `Outer` stays the
    // consumer's real type. Pre-fix, the nesting assembly materialised a
    // `public enum Outer` container around `Inner`, shadowing the class.
    try RenderClosureNestedInClassTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot"))
      // No fabricated namespace container shadows the real class.
      #expect(!closed.contains("public enum Outer"))
      #expect(!closed.contains("enum Outer"))
      // The nested value type is a dropped frontier: never emitted.
      #expect(!closed.contains("struct Inner"))
      #expect(!closed.contains("@frozen"))
      // A method still names the real class `Outer`, un-shadowed.
      #expect(closed.contains("Outer"))
    }
  }
}

/// Coverage of Finding B: two top-level value types that share the bare
/// `TypeName` `Point` in different CLR namespaces must both emit, each under a
/// fabricated namespace `enum` container, distinct and non-colliding, and each
/// signature must spell them fully namespace-qualified. The fixture assembles a
/// root `IRoot` whose three methods return `A.Point` (namespace `A`), `B.Point`
/// (namespace `B`), and `C.D.Point` (a dotted namespace `C.D`), each a local
/// struct (`Extends System.ValueType`) with one `i4` field. Pre-fix all three
/// spelled the bare `Point` and emitted a single ambiguous top-level `struct
/// Point`; the namespaces disambiguate them.
struct RenderClosureNamespaceTests {
  // Nine tables in table-number order — TypeRef (#1, 2 rows), TypeDef (#2, 4
  // rows), FieldDef (#4, 3 rows), MethodDef (#6, 3 rows), Param (#8, empty),
  // MemberRef (#10, 1 row), CustomAttribute (#12, 1 row), TypeSpec (#27, empty),
  // NestedClass (#41, empty) — every index narrow (2-byte). ECMA-335 rows are
  // 1-based; a `TypeDefOrRef` is `(row << 2) | tag` (tag 0 `TypeDef`, 1
  // `TypeRef`).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  ResolutionScope=0, TypeName="ValueType"(56),
  //                TypeNamespace="System"(49) — the struct base.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(74),
  //                TypeNamespace=empty(0), MethodList=1 — the root, owns
  //                `GetA`/`GetB`/`GetC`.
  //   TypeDef[1]:  Flags=0, TypeName="Point"(80), TypeNamespace="A"(66),
  //                Extends=ValueType((2<<2)|1=9), FieldList=1, MethodList=4.
  //   TypeDef[2]:  Flags=0, TypeName="Point"(80), TypeNamespace="B"(68),
  //                Extends=9, FieldList=2, MethodList=4.
  //   TypeDef[3]:  Flags=0, TypeName="Point"(80), TypeNamespace="C.D"(70),
  //                Extends=9, FieldList=3, MethodList=4.
  //   FieldDef[0..2]: each `x`(86) with the shared `i4` signature (blob@16).
  //   MethodDef[0]: "GetA"(88), Signature=blob@1 — return `A.Point` (VALUETYPE
  //                `TypeDefOrRef`=(2<<2)|0=8).
  //   MethodDef[1]: "GetB"(93), Signature=blob@6 — return `B.Point` (=(3<<2)=12).
  //   MethodDef[2]: "GetC"(98), Signature=blob@11 — return `C.D.Point`
  //                (=(4<<2)=16).
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob@19 — `IRoot`'s well-known IID.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeRef[1] (System.ValueType)
    0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    // TypeDef[0] (IRoot): Flags, Name, Namespace, Extends, FieldList, MethodList
    0x21, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (A.Point): sequential layout
    0x08, 0x00, 0x00, 0x00, 0x50, 0x00, 0x42, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x04, 0x00,
    // TypeDef[2] (B.Point): sequential layout
    0x08, 0x00, 0x00, 0x00, 0x50, 0x00, 0x44, 0x00,
    0x09, 0x00, 0x02, 0x00, 0x04, 0x00,
    // TypeDef[3] (C.D.Point): sequential layout
    0x08, 0x00, 0x00, 0x00, 0x50, 0x00, 0x46, 0x00,
    0x09, 0x00, 0x03, 0x00, 0x04, 0x00,
    // FieldDef[0] (A.Point.x)
    0x00, 0x00, 0x56, 0x00, 0x10, 0x00,
    // FieldDef[1] (B.Point.x)
    0x00, 0x00, 0x56, 0x00, 0x10, 0x00,
    // FieldDef[2] (C.D.Point.x)
    0x00, 0x00, 0x56, 0x00, 0x10, 0x00,
    // MethodDef[0] (GetA): RVA, ImplFlags, Flags, Name, Signature, ParamList
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x58, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MethodDef[1] (GetB)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x5d, 0x00, 0x06, 0x00, 0x01, 0x00,
    // MethodDef[2] (GetC)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x62, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x13, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0System\0ValueType\0A\0
  //  B\0C.D\0IRoot\0Point\0x\0GetA\0GetB\0GetC\0": GuidNamespace@1, GuidName@35,
  // System@49, ValueType@56, A@66, B@68, C.D@70, IRoot@74, Point@80, x@86,
  // GetA@88, GetB@93, GetC@98.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00,
    0x56, 0x61, 0x6c, 0x75, 0x65, 0x54, 0x79, 0x70, 0x65, 0x00,
    0x41, 0x00,
    0x42, 0x00,
    0x43, 0x2e, 0x44, 0x00,
    0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00,
    0x50, 0x6f, 0x69, 0x6e, 0x74, 0x00,
    0x78, 0x00,
    0x47, 0x65, 0x74, 0x41, 0x00,
    0x47, 0x65, 0x74, 0x42, 0x00,
    0x47, 0x65, 0x74, 0x43, 0x00,
  ]

  // The blob heap: offset 0 the empty blob; offset 1/6/11 the three method
  // signatures (each length 4: HASTHIS, 0 params, return `ELEMENT_TYPE_VALUETYPE`
  // naming the `TypeDefOrRef` 8/12/16 — `A.Point`/`B.Point`/`C.D.Point`); offset
  // 16 the shared `i4` field signature; offset 19 the 20-byte well-known
  // `GuidAttribute` value.
  private static let blob: Array<UInt8> = [
    0x00,
    0x04, 0x20, 0x00, 0x11, 0x08,
    0x04, 0x20, 0x00, 0x11, 0x0c,
    0x04, 0x20, 0x00, 0x11, 0x10,
    0x02, 0x06, 0x08,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 4, range: 12 ..< 68,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 3, range: 68 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 3, range: 86 ..< 128,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 128 ..< 128,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 128 ..< 128,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 128 ..< 134,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 134 ..< 140,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 140 ..< 140,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 140 ..< 140,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 12) | (1 << 27) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure preserves the namespace of same-named value types`() throws {
    // `IRoot.GetA`/`GetB`/`GetC` return `A.Point`, `B.Point`, and `C.D.Point` —
    // three local structs sharing the bare name `Point` across three CLR
    // namespaces. The closure must wrap each in fabricated `public enum`
    // namespace containers (`enum C { enum D { … } }` for the dotted one) and
    // spell each return fully qualified, so the three declarations are distinct
    // and each signature names the right one.
    try RenderClosureNamespaceTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // A namespace `enum` per distinct segment; the dotted `C.D` nests `D`
      // inside `C`.
      #expect(closed.contains("public enum A {"))
      #expect(closed.contains("public enum B {"))
      #expect(closed.contains("public enum C {"))
      #expect(closed.contains("public enum D {"))
      // The three same-named structs each nest under their namespace — three
      // `Point` declarations, never one ambiguous top-level `struct Point`.
      #expect(closed.components(separatedBy: "public struct Point {").count == 4)
      #expect(!closed.contains("\n@frozen public struct Point"))
      // Each return is spelled fully namespace-qualified, the dotted one down
      // both segments.
      #expect(closed.contains("-> A.Point"))
      #expect(closed.contains("-> B.Point"))
      #expect(closed.contains("-> C.D.Point"))
      // The root interface itself still emits, top-level and unqualified.
      #expect(closed.contains("public protocol IRoot"))
    }
  }
}

/// Coverage of Finding A: a metadata-nested interface reached by a signature is
/// a dropped frontier — a `@com` protocol cannot legally nest, and a bare
/// top-level declaration would neither match its metadata-nested spelling nor
/// tell two same-named nested interfaces apart — while a top-level interface a
/// signature names still emits, bare. The fixture assembles a root `IRoot`
/// whose methods name two nested interfaces `Host.IChild` and `Peer.IChild`
/// (each a `tdInterface` `TypeDef` under a local class, each with its own
/// `GuidAttribute`) that share the bare name `IChild`, and a top-level interface
/// `ITop`. The closure must emit `IRoot` and `ITop` and frontier both `IChild`s,
/// so no `protocol IChild` renders (and never two). Pre-finding-A the walk
/// emitted each nested interface as a top-level bare `protocol IChild`, a
/// duplicate, ambiguous clash.
struct RenderClosureNestedProtocolTests {
  // Nine tables in table-number order — TypeRef (#1, 1 row), TypeDef (#2, 6
  // rows), MethodDef (#6, 3 rows), Param (#8, empty), InterfaceImpl (#9, empty),
  // MemberRef (#10, 1 row), CustomAttribute (#12, 4 rows), TypeSpec (#27,
  // empty), NestedClass (#41, 2 rows) — every index narrow (2-byte). ECMA-335
  // rows are 1-based; a `TypeDefOrRef` is `(row << 2) | tag` (tag 0 `TypeDef`).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(52),
  //                TypeNamespace="NS"(49), MethodList=1 — owns `A`/`B`/`C`.
  //   TypeDef[1]:  Flags=0 (class), TypeName="Host"(58), TypeNamespace="NS"(49)
  //                — a local encloser, not itself reached.
  //   TypeDef[2]:  Flags=0, TypeName="Peer"(63), TypeNamespace="NS"(49) — the
  //                other encloser.
  //   TypeDef[3]:  Flags=0x21, TypeName="ITop"(68), TypeNamespace="NS"(49) — a
  //                top-level interface a signature names, so it emits bare.
  //   TypeDef[4]:  Flags=0x21, TypeName="IChild"(73), TypeNamespace=empty(0) —
  //                `Host.IChild`, a nested interface.
  //   TypeDef[5]:  Flags=0x21, TypeName="IChild"(73), TypeNamespace=empty(0) —
  //                `Peer.IChild`, the same bare name under a different encloser.
  //   MethodDef[0]: "A"(80), Signature=blob@1 — return `ELEMENT_TYPE_CLASS`
  //                naming `Host.IChild` (`TypeDefOrRef`=(5<<2)|0=20).
  //   MethodDef[1]: "B"(82), Signature=blob@6 — return `Peer.IChild` (=(6<<2)=24).
  //   MethodDef[2]: "C"(84), Signature=blob@11 — return `ITop` (=(4<<2)=16).
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the ctor.
  //   CustomAttribute[0..3]: the `GuidAttribute`s for `IRoot` (well-known),
  //                `ITop` (all-0x22), `Host.IChild` (all-0x11), and `Peer.IChild`
  //                (all-0x33), keyed by their `Parent` `TypeDef`.
  //   NestedClass[0]: NestedClass=5 (Host.IChild), EnclosingClass=2 (Host).
  //   NestedClass[1]: NestedClass=6 (Peer.IChild), EnclosingClass=3 (Peer).
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeDef[0] (IRoot): Flags, Name, Namespace, Extends, FieldList, MethodList
    0x21, 0x00, 0x00, 0x00, 0x34, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (Host): class
    0x00, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x04, 0x00,
    // TypeDef[2] (Peer): class
    0x00, 0x00, 0x00, 0x00, 0x3f, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x04, 0x00,
    // TypeDef[3] (ITop): interface
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x04, 0x00,
    // TypeDef[4] (Host.IChild): interface, empty namespace
    0x21, 0x00, 0x00, 0x00, 0x49, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x04, 0x00,
    // TypeDef[5] (Peer.IChild): interface, empty namespace
    0x21, 0x00, 0x00, 0x00, 0x49, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x04, 0x00,
    // MethodDef[0] (A): RVA, ImplFlags, Flags, Name, Signature, ParamList
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x50, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MethodDef[1] (B)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x52, 0x00, 0x06, 0x00, 0x01, 0x00,
    // MethodDef[2] (C)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x54, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0] (IRoot)
    0x23, 0x00, 0x0b, 0x00, 0x10, 0x00,
    // CustomAttribute[1] (ITop)
    0x83, 0x00, 0x0b, 0x00, 0x25, 0x00,
    // CustomAttribute[2] (Host.IChild)
    0xa3, 0x00, 0x0b, 0x00, 0x3a, 0x00,
    // CustomAttribute[3] (Peer.IChild)
    0xc3, 0x00, 0x0b, 0x00, 0x4f, 0x00,
    // NestedClass[0] (Host.IChild under Host)
    0x05, 0x00, 0x02, 0x00,
    // NestedClass[1] (Peer.IChild under Peer)
    0x06, 0x00, 0x03, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0NS\0IRoot\0Host\0Peer\0
  //  ITop\0IChild\0A\0B\0C\0": GuidNamespace@1, GuidName@35, NS@49, IRoot@52,
  // Host@58, Peer@63, ITop@68, IChild@73, A@80, B@82, C@84.
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
    0x50, 0x65, 0x65, 0x72, 0x00,
    0x49, 0x54, 0x6f, 0x70, 0x00,
    0x49, 0x43, 0x68, 0x69, 0x6c, 0x64, 0x00,
    0x41, 0x00,
    0x42, 0x00,
    0x43, 0x00,
  ]

  // The blob heap: offset 0 the empty blob; offset 1/6/11 the three method
  // signatures (each length 4: HASTHIS, 0 params, return `ELEMENT_TYPE_CLASS`
  // naming the `TypeDefOrRef` 20/24/16 — `Host.IChild`/`Peer.IChild`/`ITop`);
  // offset 16/37/58/79 four 20-byte `GuidAttribute` values (`IRoot`'s well-known
  // GUID, then all-0x22 `ITop`, all-0x11 `Host.IChild`, all-0x33 `Peer.IChild`),
  // each preceded by its length 0x14.
  private static let blob: Array<UInt8> = [
    0x00,
    0x04, 0x20, 0x00, 0x12, 0x14,
    0x04, 0x20, 0x00, 0x12, 0x18,
    0x04, 0x20, 0x00, 0x12, 0x10,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
    0x14, 0x01, 0x00, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
    0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x00, 0x00,
    0x14, 0x01, 0x00, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
    0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x00, 0x00,
    0x14, 0x01, 0x00, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
    0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 6, range: 6 ..< 90,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 3, range: 90 ..< 132,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 132 ..< 132,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 132 ..< 132,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 132 ..< 138,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 4, range: 138 ..< 162,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 162 ..< 162,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 2, range: 162 ..< 170,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10)
          | (1 << 12) | (1 << 27) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure frontiers nested interfaces a signature names, keeps a top-level one`() throws {
    // `IRoot.A`/`B` name the nested interfaces `Host.IChild`/`Peer.IChild` and
    // `IRoot.C` the top-level `ITop`. The closure emits `IRoot` and `ITop` and
    // frontiers both nested `IChild`s: a nested `@com` protocol cannot legally
    // nest, and a bare top-level declaration would be a duplicate, so neither
    // renders. Pre-finding-A each nested interface emitted as a top-level bare
    // `public protocol IChild`, an ambiguous clash.
    try RenderClosureNestedProtocolTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // The top-level interfaces emit, bare and unqualified.
      #expect(closed.contains("public protocol IRoot"))
      #expect(closed.contains("public protocol ITop"))
      // Both nested interfaces are dropped frontiers — no `IChild` declaration
      // renders at all, so the two same-named nested protocols never collide.
      #expect(!closed.contains("public protocol IChild"))
      #expect(!closed.contains("11111111-1111-1111-1111-111111111111"))
      #expect(!closed.contains("33333333-3333-3333-3333-333333333333"))
      // `ITop`'s own IID does render — a top-level interface is projected whole.
      #expect(closed.contains("22222222-2222-2222-2222-222222222222"))
    }
  }
}

/// Coverage of Finding X: an interface whose base *is* a nested interface must
/// spell that base through its enclosing path (`Outer.IChild`), not the bare
/// `IChild` a nested `TypeName` alone yields — which resolves to no declaration.
/// The fixture assembles a top-level `R.IRoot` whose sole `InterfaceImpl` names,
/// directly through `Interface_TypeDef`, the interface `IChild` nested under the
/// value type `NS.Outer`. Both interfaces bear a `GuidAttribute`, so `IChild`
/// projects as a `@com` protocol nested in the `Outer` container the closure
/// emits, and `IRoot`'s inheritance clause must name it `Outer.IChild` — the
/// same `qualified` spelling `IChild`'s own nested declaration wears. Before
/// the fix the clause read the raw `TypeName` and emitted `protocol IRoot:
/// IChild`.
struct RenderNestedBaseTests {
  // Eleven tables in table-number order — TypeRef (#1, 2 rows), TypeDef (#2, 3
  // rows), FieldDef (#4, empty), MethodDef (#6, empty), Param (#8, empty),
  // InterfaceImpl (#9, 1 row), MemberRef (#10, 1 row), Constant (#11, empty),
  // CustomAttribute (#12, 2 rows), TypeSpec (#27, empty), NestedClass (#41, 1
  // row) — every index narrow (2-byte). ECMA-335 rows are 1-based; a
  // `TypeDefOrRef` is `(row << 2) | tag` (tag 0 `TypeDef`).
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeRef[1]:  TypeName="ValueType"(56), TypeNamespace="System"(49) — the
  //                base `Outer` extends, marking it a value type.
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IRoot"(68),
  //                TypeNamespace="R"(66), Extends=0 — the top-level root.
  //   TypeDef[1]:  Flags=0x08, TypeName="Outer"(77), TypeNamespace="NS"(74),
  //                Extends=`System.ValueType`(TypeRef row 2)=(2<<2)|1=9 — the
  //                enclosing value type.
  //   TypeDef[2]:  Flags=0x21, TypeName="IChild"(83), TypeNamespace=empty(0) —
  //                `Outer.IChild`, the nested interface.
  //   InterfaceImpl[0]: Class=1 (TypeDef row 1, IRoot),
  //                Interface=TypeDefOrRef(TypeDef row 3)=(3<<2)|0=12 — the
  //                direct local nested base `Outer.IChild`.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob[7] — `IRoot`'s IID (`DEADBEEF-…`).
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 3)=(3<<5)|3=99,
  //                Type=11, Value=blob[28] — `Outer.IChild`'s IID
  //                (`FEEDFACE-…`).
  //   NestedClass[0]: NestedClass=3 (Outer.IChild), EnclosingClass=2 (Outer).
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4d, 0x00, 0x4a, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x01, 0x00, 0x21, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x0c, 0x00, 0x09, 0x00,
    0x5a, 0x00, 0x01, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x07, 0x00, 0x63, 0x00,
    0x0b, 0x00, 0x1c, 0x00, 0x03, 0x00, 0x02, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x4e, 0x53, 0x00, 0x4f, 0x75, 0x74, 0x65, 0x72, 0x00, 0x49,
    0x43, 0x68, 0x69, 0x6c, 0x64, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00,
  ]

  // The blob heap: offset 0 the empty blob; offset 1 the ctor signature (length
  // 5); offset 7/28 two 20-byte `GuidAttribute` values (prolog 0x0001, 16 GUID
  // bytes, NumNamed 0), each preceded by its length 0x14 — `IRoot`'s
  // `DEADBEEF-CAFE-BABE-F00D-1234567890AB`, then `Outer.IChild`'s
  // `FEEDFACE-CAFE-BABE-F00D-1234567890AB`.
  private static let blob: Array<UInt8> = [
    0x00, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe,
    0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78,
    0x90, 0xab, 0x00, 0x00, 0x14, 0x01, 0x00, 0xce, 0xfa, 0xed, 0xfe, 0xfe,
    0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00,
    0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 54 ..< 58,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 58 ..< 64,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 64 ..< 64,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 64 ..< 76,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 76 ..< 76,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 76 ..< 80,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure qualifies an inheritance clause naming a nested interface`() throws {
    // `IRoot`'s base is the nested `Outer.IChild`. The closure emits `IChild`
    // nested in its `Outer` container, and `IRoot`'s clause names it through the
    // enclosing path — `Outer.IChild`, the spelling `IChild`'s own declaration
    // and a signature naming it both wear — not the bare `IChild` a nested
    // `TypeName` alone yields, which binds no visible declaration.
    try RenderNestedBaseTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot: Outer.IChild {"))
      #expect(!closed.contains("public protocol IRoot: IChild {"))
      // The nested base is really emitted — its own IID renders — so the
      // qualified clause resolves to a present declaration, not a dangling name.
      #expect(closed.contains("FEEDFACE-CAFE-BABE-F00D-1234567890AB"))
    }
  }

  @Test func `a flat render names a nested base by its bare leaf`() throws {
    // The flat render emits every interface at the top level and nests nothing,
    // so `IRoot`'s nested base spells its bare leaf `IChild` — the top-level
    // `protocol IChild` the flat render emits it as — not the enclosing
    // `Outer.IChild`, which would resolve against a container it never nests.
    try RenderNestedBaseTests.with { catalog in
      let shell = Shell(catalog)
      let flat = try shell.render("*", template: "com")
      #expect(flat.contains("public protocol IRoot: IChild {"))
      #expect(!flat.contains("Outer.IChild"))
    }
  }
}

/// Coverage of Finding 4: two same-named top-level protocols emit as duplicate,
/// uncompilable `public protocol` declarations, and a protocol cannot nest in a
/// namespace `enum` the way a value type disambiguates — so the render rejects
/// the closure rather than emit them. The fixture assembles two top-level
/// interfaces `A.IFoo` and `B.IFoo`, each a `tdInterface` `TypeDef` bearing its
/// own `GuidAttribute`, sharing the bare name `IFoo` across two CLR namespaces.
/// A `--closure` over the simple name `IFoo` seeds both (the ambiguous root),
/// so the walk emits two top-level `IFoo` protocols and `nest` — which sees
/// every emitted protocol — must throw `RenderError.ambiguous` naming the two
/// namespaces. A signature reaching two same-named protocols mid-closure faults
/// through the identical detection point.
struct RenderClosureAmbiguousProtocolTests {
  // Ten tables in table-number order — TypeRef (#1, 1 row), TypeDef (#2, 2
  // rows), FieldDef (#4, empty), MethodDef (#6, empty), Param (#8, empty),
  // InterfaceImpl (#9, empty), MemberRef (#10, 1 row), CustomAttribute (#12, 2
  // rows), TypeSpec (#27, empty), NestedClass (#41, empty) — every index narrow
  // (2-byte). ECMA-335 rows are 1-based; a coded index is `(row << bits) | tag`.
  //
  //   TypeRef[0]:  ResolutionScope=0, TypeName="GuidAttribute"(35),
  //                TypeNamespace="Windows.Win32.Foundation.Metadata"(1).
  //   TypeDef[0]:  Flags=0x21 (tdInterface), TypeName="IFoo"(53),
  //                TypeNamespace="A"(49) — the first same-named interface.
  //   TypeDef[1]:  Flags=0x21, TypeName="IFoo"(53), TypeNamespace="B"(51) — the
  //                second, same bare name under a different namespace.
  //   MemberRef[0]: Class=MemberRefParent(TypeRef row 1)=(1<<3)|1=9 — the ctor.
  //   CustomAttribute[0]: Parent=HasCustomAttribute(TypeDef row 1)=(1<<5)|3=35,
  //                Type=CustomAttributeType(MemberRef row 1)=(1<<3)|3=11,
  //                Value=blob@1 — `A.IFoo`'s IID (the well-known GUID).
  //   CustomAttribute[1]: Parent=HasCustomAttribute(TypeDef row 2)=(2<<5)|3=67,
  //                Type=11, Value=blob@22 — `B.IFoo`'s IID (all-0x11), distinct.
  private static let bytes: Array<UInt8> = [
    // TypeRef[0] (GuidAttribute)
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00,
    // TypeDef[0] (A.IFoo): Flags, Name, Namespace, Extends, FieldList, MethodList
    0x21, 0x00, 0x00, 0x00, 0x35, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // TypeDef[1] (B.IFoo)
    0x21, 0x00, 0x00, 0x00, 0x35, 0x00, 0x33, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    // MemberRef[0]
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    // CustomAttribute[0]
    0x23, 0x00, 0x0b, 0x00, 0x01, 0x00,
    // CustomAttribute[1]
    0x43, 0x00, 0x0b, 0x00, 0x16, 0x00,
  ]

  // "\0Windows.Win32.Foundation.Metadata\0GuidAttribute\0A\0B\0IFoo\0":
  // GuidNamespace@1, GuidName@35, A@49, B@51, IFoo@53.
  private static let strings: Array<UInt8> = [
    0x00,
    0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e, 0x33,
    0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00,
    0x47, 0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74,
    0x65, 0x00,
    0x41, 0x00,
    0x42, 0x00,
    0x49, 0x46, 0x6f, 0x6f, 0x00,
  ]

  // The blob heap: offset 0 the empty blob; offset 1 the well-known 20-byte
  // `GuidAttribute` value (`0C733A30-…`, `A.IFoo`); offset 22 the all-0x11 value
  // (`B.IFoo`), so the two IIDs are distinct.
  private static let blob: Array<UInt8> = [
    0x00,
    0x14, 0x01, 0x00, 0x30, 0x3a, 0x73, 0x0c, 0x1c, 0x2a, 0xce, 0x11,
    0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d, 0x00, 0x00,
    0x14, 0x01, 0x00, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
    0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 1, range: 0 ..< 6,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 6 ..< 34,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 34 ..< 34,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 34 ..< 40,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 40 ..< 52,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 52 ..< 52,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 52 ..< 52,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 12) | (1 << 27) | (1 << 41)

  private static func with(_ body: (borrowing Storage) throws -> Void)
      rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure rejects an ambiguous top-level protocol`() throws {
    // `A.IFoo` and `B.IFoo` share the bare name `IFoo`, so a closure over the
    // simple name `IFoo` seeds both. A protocol cannot nest in a namespace
    // `enum`, so the two would emit as duplicate top-level `public protocol
    // IFoo` — the render rejects it instead, naming the two namespaces sorted.
    RenderClosureAmbiguousProtocolTests.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.ambiguous("IFoo", ["A", "B"])) {
        _ = try shell.render(closure: "IFoo", template: "com")
      }
    }
  }
}

/// A value type and an interface bearing the one simple name in different
/// namespaces — `A.Shape` (a struct) and `B.Shape` (an interface). The flat
/// Win32 surface never lands a value-type name on a same-named protocol, so this
/// hand-built pair pins the cross-kind collision the closure must resolve: the
/// value type is namespace-qualified and wrapped, the protocol stays bare.
@Suite struct RenderCrossKindCollisionTests {
  @Test func `a value type colliding with a same-named protocol wraps while the protocol stays bare`() throws {
    // `Shape` is ambiguous across kinds — the struct `A.Shape` (token 4) and the
    // interface `B.Shape` (token 8) both bear it — so the value type must be
    // disambiguated even though it is the only value type of the name. Only the
    // struct wraps and qualifies to `A.Shape`; the protocol stays bare.
    let b = WinMDBuilder()
    b.structure("A.Shape")
    b.interface("B.Shape")
    try b.with { storage in
      let (names, ids) = try storage.collisions()
      #expect(names.contains("Shape"))
      #expect(ids.contains(1))
      #expect(!ids.contains(2))
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 4),
                                   qualifying: names) == "A.Shape")
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 8),
                                   qualifying: names) == nil)
    }
  }
}

/// The whole closure emit disambiguates a value type from a same-named emitted
/// *non-value* declaration. `R.IRoot.Use` reaches the struct `A.Point` and the
/// interface `B.Point` (then, separately, the delegate `B.Point`); both project
/// to bare `Point`. The contention tally counts a reached declaration of any
/// kind, so `Point` is ambiguous and the value type wraps under a fabricated
/// `enum A` and qualifies to `A.Point`, while the protocol (or delegate) stays
/// a bare top-level `Point` — one `struct Point` nested under `enum A`, no
/// redeclaration. Counting only value types would leave `A.Point` an unwrapped
/// bare `struct Point` clashing with the emitted `protocol Point`, which `nest`
/// then faults `.collision("Point")`.
@Suite struct RenderValueNonValueCollisionTests {
  @Test func `a value type wraps against a same-named emitted protocol`() throws {
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Use", [("a", .value("A.Point")), ("b", .object("B.Point"))])
    b.structure("A.Point")
    b.interface("B.Point", guid: 0xFEEDFACE)
    try b.with { catalog in
      let closed = try Shell(catalog).render(closure: "IRoot", template: "com")
      #expect(closed.contains("public enum A {"))
      let structs = closed.components(separatedBy: "struct Point").count - 1
      let protocols = closed.components(separatedBy: "protocol Point").count - 1
      #expect(structs == 1)
      #expect(protocols == 1)
    }
  }

  @Test func `a value type wraps against a same-named emitted delegate`() throws {
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Use", [("a", .value("A.Point")), ("b", .object("B.Point"))])
    b.structure("A.Point")
    b.delegate("B.Point", guid: 0xFEEDFACE)
    try b.with { catalog in
      let closed = try Shell(catalog).render(closure: "IRoot", template: "com")
      #expect(closed.contains("public enum A {"))
      #expect(closed.components(separatedBy: "struct Point").count - 1 == 1)
    }
  }
}

/// A non-generic value type `A.Foo` and a generic interface `B.Foo` (its `TypeName`
/// the CLR spelling `Foo` + arity suffix) — projected, both are the one Swift name
/// `Foo`, so they collide even though their raw metadata names differ. The tally
/// must strip the arity suffix, the same normalization the emission applies, or
/// the value type is left an unwrapped bare `struct Foo` clashing with the generic
/// interface's `struct Foo` wrapper.
@Suite struct RenderGenericArityCollisionTests {
  @Test func `a value type and a generic type collide on their arity-stripped name`() throws {
    // The value type `A.Foo` (token 4) and the generic interface `B.Foo`1`
    // (token 8) project to the one name `Foo`, so it is ambiguous and only the
    // value type wraps; the raw names (`Foo` vs `Foo` + arity) would read as
    // distinct and leave the struct an unwrapped bare root.
    let b = WinMDBuilder()
    b.structure("A.Foo")
    b.interface("B.Foo").generic("T")
    try b.with { storage in
      let (names, ids) = try storage.collisions()
      #expect(names.contains("Foo"))
      #expect(ids.contains(1))
      #expect(!ids.contains(2))
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 4),
                                   qualifying: names) == "A.Foo")
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 8),
                                   qualifying: names) == nil)
    }
  }
}

@Suite struct RenderSameNamespaceArityCollisionTests {
  @Test func `a same-namespace value type and generic type collide on arity`() throws {
    // The value type `A.Foo` (token 4) and same-namespace generic interface
    // `A.Foo`1` (token 8) project to the one `Foo`, so the value type wraps and
    // qualifies to `A.Foo`; the identity keys off the raw name, so the
    // protocol's suffixed `A.Foo`1` never enters and it stays bare.
    let b = WinMDBuilder()
    b.structure("A.Foo")
    b.interface("A.Foo").generic("T")
    try b.with { storage in
      let (names, ids) = try storage.collisions()
      #expect(names.contains("Foo"))
      #expect(names.contains("A.Foo"))
      #expect(!names.contains("A.Foo`1"))
      #expect(ids.contains(1))
      #expect(!ids.contains(2))
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 4),
                                   qualifying: names) == "A.Foo")
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 8),
                                   qualifying: names) == nil)
    }
  }
}

/// A closure whose fabricated namespace container shadows an emitted type. The
/// root interface `R.A` (simple name `A`) returns `A.Point`, whose instance
/// field is a `B.Point`, so the closure reaches both value types and `Point` is
/// ambiguous *among the reached declarations* — the collision the reached-only
/// tally counts. The render wraps `A.Point` under a fabricated `enum A`, which
/// collides with the bare `protocol A` the root itself emits. Only a value type
/// can be namespace-wrapped, so the namespace segment has no fallback and the
/// render must fault rather than emit `enum A` beside `protocol A`. (The field
/// reaching `B.Point` is what keeps the ambiguity reachable: an unreachable
/// `B.Point` would leave `Point` unique and the closure bare and valid — the
/// case `RenderUnreachableCollisionTests` pins.)
@Suite struct RenderNamespaceShadowTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x46, 0x00, 0x44, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x46, 0x00, 0x4c, 0x00,
    0x09, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x59, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x05, 0x54, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x09, 0x00, 0x4e, 0x00, 0x06, 0x00, 0x23, 0x00, 0x0b, 0x00,
    0x10, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x41, 0x00, 0x50, 0x6f,
    0x69, 0x6e, 0x74, 0x00, 0x42, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00,
    0x4d, 0x61, 0x6b, 0x65, 0x00, 0x6f, 0x72, 0x69, 0x67, 0x69, 0x6e, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x08, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f,
    0x03, 0x06, 0x11, 0x0c, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe,
    0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00,
    0x00,
  ]

  private static let empty = Array<UInt8>()

  // The tables the render's views touch, ascending by table number; the empty
  // ones carry no rows but must be present so a view resolves the relation.
  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 54 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 60 ..< 74,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 80 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 86 ..< 86,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 86 ..< 86,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `a fabricated namespace container shadowing an emitted type faults`() {
    RenderNamespaceShadowTests.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.collision("A")) {
        _ = try shell.render(closure: "A", template: "com")
      }
    }
  }
}

/// A closure whose nesting places a real type and a fabricated namespace
/// container of the one name inside the same container. `IRoot` returns `A.B` (a
/// value type ambiguous with `D.B`) and `A.B.Point` (ambiguous with `C.Point`).
/// `A.B` carries an instance field of `D.B` and `A.B.Point` a field of
/// `C.Point`, so the closure reaches all four and both names are ambiguous
/// *among the reached declarations*. The render wraps `A.B` as a real `B` under
/// `enum A` and wraps `A.B.Point` under a fabricated `enum A.enum B` — two
/// children named `B` inside `enum A`. A root-only claims check passes (the
/// roots are just `enum A`); the clash is a level down, so the emit must
/// validate every container's children, not only the roots.
@Suite struct RenderNestedShadowTests {
  @Test func `a namespace container shadowing a type inside another container faults`() {
    // `IRoot` returns `A.B` (a value type ambiguous with `D.B`) and `A.B.Point`
    // (ambiguous with `C.Point`), each reached through a field, so `A.B` wraps
    // as a real `B` under `enum A` while `A.B.Point` wraps under a fabricated
    // `enum A.enum B` — two children named `B` inside `enum A`, a clash a level
    // below the roots that a root-only claims check would miss.
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Make", returns: .value("A.B"))
        .method("Get", returns: .value("A.B.Point"))
    b.structure("A.B").field("low", .value("D.B"))
    b.structure("A.B.Point").field("tip", .value("C.Point"))
    b.structure("D.B")
    b.structure("C.Point")
    b.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.collision("B")) {
        _ = try shell.render(closure: "IRoot", template: "com")
      }
    }
  }
}
/// A closure that reaches a value type only through its metadata-nested member.
/// `R.IRoot.Make` returns `Outer.Inner` (`Inner` nested in `Outer` via
/// `NestedClass`), and no signature names `Outer` directly. The walk must walk
/// and emit `Outer` — the real `struct` container `Inner` nests inside — rather
/// than only try to retain a nonexistent `Outer` emission during the prune,
/// which would drop `Inner` while its signature still spells `Outer.Inner`.
@Suite struct RenderEnclosingValueTypeTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4c, 0x00, 0x4a, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x52, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xc6, 0x05, 0x5e, 0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x00, 0x58, 0x00,
    0x06, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x0c, 0x00, 0x03, 0x00, 0x02, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x4e, 0x00, 0x4f, 0x75, 0x74, 0x65, 0x72, 0x00, 0x49, 0x6e,
    0x6e, 0x65, 0x72, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00, 0x4d, 0x61,
    0x6b, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x0c, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f,
    0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0,
    0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 54 ..< 68,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 68 ..< 68,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 68 ..< 68,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 68 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 80 ..< 84,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `an enclosing value type reached only through a nested member emits`() throws {
    try RenderEnclosingValueTypeTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `Outer` is emitted as the real value-type container even though only
      // `Outer.Inner` is named, and `Inner` nests inside it rather than being
      // dropped; the signature's `Outer.Inner` spelling then resolves.
      #expect(closed.contains("@frozen public struct Outer {"))
      #expect(closed.contains("@frozen public struct Inner {"))
      #expect(closed.contains("Outer.Inner"))
    }
  }

  @Test func `a nested type nests before a container template's brace footer`() throws {
    // A custom struct template both opens with a header comment containing
    // braces and appends a brace-delimited footer — an `extension` — after the
    // main declaration. `Inner` must nest inside `struct Outer` (after its
    // opening brace, before its own closing brace): the closer scan must skip
    // the comment's `{}` (not balance a phantom pair at the header, which would
    // splice `Inner` above the declaration) and must not anchor on the last
    // brace-only line (which would spill `Inner` into the extension) — either
    // way leaving `Outer.Inner` undefined.
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let templates = directory.appendingPathComponent("Templates")
    try manager.createDirectory(at: templates,
                                withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let template = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {
        }
        {{/interface}}
        {{#struct}}
        // A header brace pair {} must not be read as the declaration body.
        public struct {{{name}}} {
        }
        extension {{{name}}} {
        }
        {{/struct}}
        {{#enum}}
        public struct {{{name}}} {
        }
        {{/enum}}
        {{#delegate}}
        public protocol {{{name}}} {
        }
        {{/delegate}}
        """
    try Data(template.utf8)
        .write(to: templates.appendingPathComponent("nest.mustache"))
    try RenderEnclosingValueTypeTests.with { catalog in
      let shell = Shell(catalog, search: [directory.path])
      let rendered = try shell.render(closure: "IRoot", template: "nest")
      let container = rendered.range(of: "public struct Outer {")
      let inner = rendered.range(of: "struct Inner")
      let footer = rendered.range(of: "extension Outer")
      #expect(container != nil)
      #expect(inner != nil)
      #expect(footer != nil)
      // `Inner` falls after `struct Outer`'s opening brace and before `Outer`'s
      // own `extension` footer — proof it nested into the container, neither
      // spliced above the declaration by the header comment's braces nor into
      // the footer by the last brace.
      if let container, let inner, let footer {
        #expect(container.lowerBound < inner.lowerBound)
        #expect(inner.lowerBound < footer.lowerBound)
      }
    }
  }

  @Test func `a nested type nests despite braces in a multiline string`() throws {
    // A custom struct template opens with a Swift multiline string (`"""…"""`)
    // whose interior lines carry braces. The closer scan must hold the
    // multiline state across lines — those braces are string content, not code
    // — or a `}`
    // on a later literal line balances a phantom body and splices `Inner` into
    // the string, above `struct Outer`, leaving `Outer.Inner` undefined.
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let templates = directory.appendingPathComponent("Templates")
    try manager.createDirectory(at: templates,
                                withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let template = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {
        }
        {{/interface}}
        {{#struct}}
        let documentation = \"\"\"
        an opening brace { on a literal line
        a closing brace } on another literal line
        \"\"\"
        public struct {{{name}}} {
        }
        {{/struct}}
        {{#enum}}
        public struct {{{name}}} {
        }
        {{/enum}}
        {{#delegate}}
        public protocol {{{name}}} {
        }
        {{/delegate}}
        """
    try Data(template.utf8)
        .write(to: templates.appendingPathComponent("nest.mustache"))
    try RenderEnclosingValueTypeTests.with { catalog in
      let shell = Shell(catalog, search: [directory.path])
      let rendered = try shell.render(closure: "IRoot", template: "nest")
      let container = rendered.range(of: "public struct Outer {")
      let inner = rendered.range(of: "struct Inner")
      #expect(container != nil)
      #expect(inner != nil)
      // `Inner` falls after `struct Outer`'s opening brace — proof the
      // multiline string's braces were skipped, not read as declaration body.
      if let container, let inner {
        #expect(container.lowerBound < inner.lowerBound)
      }
    }
  }

  @Test func `a nested type nests inside a single-line declaration`() throws {
    // A custom struct template renders its whole declaration on one line
    // (`public struct Outer {}`), so the closing brace shares the line with the
    // body. The splice must land the child between the braces, not before the
    // whole line — which would place `Inner` at top level and leave the
    // `Outer.Inner` its signature spells unresolved.
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let templates = directory.appendingPathComponent("Templates")
    try manager.createDirectory(at: templates,
                                withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let template = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {}
        {{/interface}}
        {{#struct}}
        public struct {{{name}}} {}
        {{/struct}}
        {{#enum}}
        public struct {{{name}}} {}
        {{/enum}}
        {{#delegate}}
        public protocol {{{name}}} {}
        {{/delegate}}
        """
    try Data(template.utf8)
        .write(to: templates.appendingPathComponent("nest.mustache"))
    try RenderEnclosingValueTypeTests.with { catalog in
      let shell = Shell(catalog, search: [directory.path])
      let rendered = try shell.render(closure: "IRoot", template: "nest")
      // `Inner` splices between `Outer`'s `{` and `}` on the one line, so the
      // rendered source nests it: `struct Outer {` then `Inner` then `}`.
      let container = rendered.range(of: "public struct Outer {")
      let inner = rendered.range(of: "struct Inner")
      #expect(container != nil)
      #expect(inner != nil)
      if let container, let inner {
        #expect(container.lowerBound < inner.lowerBound)
      }
    }
  }

  @Test func `a nested type nests past a leading helper declaration`() throws {
    // A custom struct template emits a brace-delimited helper (`func helper()
    // {}`) before the main declaration. The scan must locate `struct Outer`
    // before balancing — a first-code-brace scan would balance the helper's
    // `{}` and inject `Inner` into the helper, leaving `Outer.Inner`
    // unresolved.
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let templates = directory.appendingPathComponent("Templates")
    try manager.createDirectory(at: templates,
                                withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let template = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {
        }
        {{/interface}}
        {{#struct}}
        func helper_{{{name}}}() {
        }
        public struct {{{name}}} {
        }
        {{/struct}}
        {{#enum}}
        public struct {{{name}}} {
        }
        {{/enum}}
        {{#delegate}}
        public protocol {{{name}}} {
        }
        {{/delegate}}
        """
    try Data(template.utf8)
        .write(to: templates.appendingPathComponent("nest.mustache"))
    try RenderEnclosingValueTypeTests.with { catalog in
      let shell = Shell(catalog, search: [directory.path])
      let rendered = try shell.render(closure: "IRoot", template: "nest")
      // `Inner` nests after `struct Outer`'s opening brace, not inside the
      // leading `helper_Outer` function.
      let helper = rendered.range(of: "func helper_Outer")
      let container = rendered.range(of: "public struct Outer {")
      let inner = rendered.range(of: "struct Inner")
      #expect(helper != nil)
      #expect(container != nil)
      #expect(inner != nil)
      if let container, let inner {
        #expect(container.lowerBound < inner.lowerBound)
      }
    }
  }
}

/// A closure whose sole reached `Point` is unique: an unreachable same-named
/// type must not make it ambiguous. `R.A.Make` returns `A.Point`; `B.Point`
/// exists but nothing reaches it, so `Point` stays bare — no fabricated
/// `enum A` shadowing `protocol A` — and the closure renders. Counting the
/// ambiguity over the whole assembly (rather than the reached declarations)
/// would wrongly wrap `A.Point` and fault; this is the pre-rework shape of the
/// shadow fixture.
@Suite struct RenderUnreachableCollisionTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x46, 0x00, 0x44, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x46, 0x00, 0x4c, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xc6, 0x05, 0x54, 0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x00, 0x4e, 0x00,
    0x06, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x0c, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x41, 0x00, 0x50, 0x6f,
    0x69, 0x6e, 0x74, 0x00, 0x42, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00,
    0x4d, 0x61, 0x6b, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x08, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f,
    0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0,
    0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 54 ..< 68,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 68 ..< 68,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 68 ..< 68,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 68 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `an unreachable same-named type does not qualify a reached value type`() throws {
    try RenderUnreachableCollisionTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "A", template: "com")
      // `Point` is unique among the reached {A.Point}, so it stays bare: no
      // fabricated `enum A` to shadow `protocol A`, and the return spells bare.
      #expect(closed.contains("public protocol A"))
      #expect(closed.contains("@frozen public struct Point {"))
      #expect(!closed.contains("enum A"))
      #expect(!closed.contains("A.Point"))
    }
  }

  @Test func `a flat render does not qualify a value type it does not emit`() throws {
    try RenderUnreachableCollisionTests.with { catalog in
      let shell = Shell(catalog)
      let flat = try shell.render("A", template: "com")
      // `Point` is ambiguous across the whole assembly (`A.Point`/`B.Point`),
      // but the flat render emits only `protocol A` — no value type, no
      // fabricated `enum A` — so it must spell the return bare, not `A.Point`,
      // which would name a container this render never emits.
      #expect(flat.contains("public protocol A"))
      #expect(!flat.contains("A.Point"))
      #expect(!flat.contains("enum A"))
      #expect(!flat.contains("struct Point"))
    }
  }
}

/// A closure whose reached value type shares a bare name with a frontier the
/// signature also references. `R.IRoot.Use` takes a local value type `A.Point`
/// and an *external* `B.Point` — a `TypeRef` scoped to an `AssemblyRef`, so it
/// resolves to no local row and the closure spells it bare `Point` without
/// emitting it. The reached tally sees only the emitted `A.Point`, so `Point`
/// reads as unique and `A.Point` would spell bare `Point` too — capturing the
/// frontier's reference. The frontier name must bump the ambiguity decision, so
/// `A.Point` wraps under a fabricated `enum A` and the two `Point`s stay
/// distinct (`A.Point` vs the consumer's `Point`).
@Suite struct RenderReachedExternalTests {
  @Test func `a reached value type wraps against a frontier of the same name`() throws {
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Use", [("a", .value("A.Point")), ("b", .external("Point"))])
    b.structure("A.Point")
    try b.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render(closure: "IRoot", template: "com")
      #expect(rendered.contains("public enum A {"))
      #expect(rendered.contains("struct Point"))
    }
  }
}
/// A closure whose reached value type shares a bare name with a
/// *layout-rejected* frontier. `R.IRoot.Use` takes local value types `A.Point`
/// (sequential layout, which renders) and `B.Point` (explicit layout, which the
/// `layout` query rejects — a frontier the walk drops and does not emit).
/// Adjacency keeps `B.Point` (a valid struct row) and the walk rejects it only
/// afterward, so its `Point` reaches the contention set only if recorded at the
/// keep. Without it
/// the reached tally sees only `A.Point`, spells it bare `Point`, and captures
/// the frontier's reference; the layout-reject contention bumps `A.Point` so it
/// wraps under a fabricated `enum A`.
@Suite struct RenderLayoutContendedTests {
  @Test func `a reached value type wraps against a layout-rejected frontier`() throws {
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
    b.structure("A.Point")
    b.structure("B.Point").layout(.explicit)
    try b.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render(closure: "IRoot", template: "com")
      #expect(rendered.contains("public enum A {"))
      #expect(rendered.contains("struct Point"))
    }
  }
}

/// A closure whose reached value type shares a bare name with an *external
/// base* the interface refines. `R.IRoot`'s base is an external `TypeRef`
/// `Point`
/// (`AssemblyRef` scope), so `bases` emits `protocol IRoot: Point` while the
/// `requires` walk never sees it, and `R.IRoot.Use` takes a local value type
/// `A.Point`. Recording the base name only in the shadow set leaves `A.Point`
/// bare, so `protocol IRoot: Point` binds to the emitted struct rather than the
/// external protocol; the base name must also enter the contention set so
/// `A.Point` wraps under `enum A` and the base stays the consumer's `Point`.
@Suite struct RenderBaseContendedTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x06, 0x00, 0x4a, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x38, 0x00, 0x31, 0x00, 0x21, 0x00, 0x00, 0x00, 0x44, 0x00,
    0x42, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x4a, 0x00, 0x50, 0x00, 0x0d, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xc6, 0x05, 0x58, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x09, 0x00, 0x09, 0x00, 0x52, 0x00, 0x07, 0x00, 0x23, 0x00,
    0x0b, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x50, 0x6f, 0x69, 0x6e, 0x74, 0x00, 0x41, 0x00, 0x2e, 0x63,
    0x74, 0x6f, 0x72, 0x00, 0x55, 0x73, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x05, 0x20, 0x01, 0x01, 0x11, 0x08, 0x05, 0x20, 0x02, 0x01, 0x08,
    0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba,
    0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 3, range: 0 ..< 18,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 18 ..< 46,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 46 ..< 46,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 46 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 1, range: 60 ..< 64,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 64 ..< 70,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 70 ..< 70,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 70 ..< 76,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 76 ..< 76,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.AssemblyRef.self, rows: 1, range: 76 ..< 96,
                wide: 0, stride: 20),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 96 ..< 96,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 35)
          | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `a reached value type wraps against an external base of the same name`() throws {
    try RenderBaseContendedTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render(closure: "IRoot", template: "com")
      // `A.Point` wraps under `enum A`, so `protocol IRoot: Point` names the
      // external base rather than a bare local `struct Point`. Without the base
      // in the contention set the local stays bare and the base binds to it.
      #expect(rendered.contains("public enum A {"))
      #expect(rendered.contains(": Point"))
    }
  }
}

/// A closure whose signature names a value type nested under a *generic*
/// encloser. `R.IRoot.Use` takes `Inner`, a value type nested in a generic
/// runtime class `Outer`1` — a frontier the closure spells but does not emit.
/// Its enclosing dot-path must strip the CLR arity suffix from *every*
/// component, spelling `Outer.Inner`; preserving the encloser's suffix would
/// emit the unresolved `Outer`1.Inner`, which names no declaration (the
/// encloser projects as `Outer`).
@Suite struct RenderGenericNestingTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x3f, 0x00, 0x31, 0x00, 0x21, 0x00, 0x00, 0x00, 0x4b, 0x00,
    0x49, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x54, 0x00, 0x51, 0x00, 0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x08, 0x00,
    0x00, 0x00, 0x5c, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x01, 0x00, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x05, 0x68, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x6c, 0x00, 0x09, 0x00, 0x62, 0x00,
    0x07, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x0d, 0x00, 0x03, 0x00, 0x02, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x4f, 0x62, 0x6a, 0x65,
    0x63, 0x74, 0x00, 0x56, 0x61, 0x6c, 0x75, 0x65, 0x54, 0x79, 0x70, 0x65,
    0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00, 0x4e, 0x53, 0x00,
    0x4f, 0x75, 0x74, 0x65, 0x72, 0x60, 0x31, 0x00, 0x49, 0x6e, 0x6e, 0x65,
    0x72, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00, 0x55, 0x73, 0x65, 0x00,
    0x76, 0x61, 0x6c, 0x75, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x05, 0x20, 0x01, 0x01, 0x11, 0x0c, 0x05, 0x20, 0x02, 0x01, 0x08,
    0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba,
    0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 3, range: 0 ..< 18,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 18 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 60 ..< 74,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 80 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 86 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 86 ..< 92,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 92 ..< 92,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 92 ..< 96,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `a by-value reference under a generic encloser drops its declaration`() throws {
    try RenderGenericNestingTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render(closure: "IRoot", template: "com")
      // `IRoot.Use` names the by-value `Inner`, nested under the generic
      // `Outer`1`. That reference has no valid unqualified spelling — a member
      // of `Outer`1` is `Outer<T>.Inner`, needing the enclosing specialization
      // the projection does not yet emit — and rendering it as an opaque pointer
      // would silently change the by-value ABI. So the whole containing
      // declaration `IRoot` is dropped rather than misrendered; neither the
      // arity-stripped `Outer.Inner` nor the raw `Outer`1` appears.
      #expect(!rendered.contains("protocol IRoot"))
      #expect(!rendered.contains("Outer.Inner"))
      #expect(!rendered.contains("Outer`1"))
    }
  }
}

/// A closure whose reached value type shares a name with a `known`-bridged
/// frontier's *target* spelling. `R.IRoot.Use` takes `NS.Known` — a value type
/// a `wellknown NS.Known Bridge` line maps to the imported `Bridge`, so the
/// walk frontiers it and a reference spells `Bridge` — and a local value type
/// `A.Bridge` (name `Bridge`). The frontier's bridge name must contend, so
/// `A.Bridge` wraps under `enum A` rather than spelling bare `Bridge` and
/// capturing the imported type.
@Suite struct RenderKnownContendedTests {
  @Test func `a reached value type wraps against a known bridge name`() throws {
    let bridge = "wellknown NS.Known Bridge"
    try RenderClosureTests.withLanguage(adding: bridge) { directory in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("NS.Known")), ("b", .value("A.Bridge"))])
      b.structure("NS.Known")
      b.structure("A.Bridge")
      try b.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let rendered = try shell.render(closure: "IRoot", template: "com")
        #expect(rendered.contains("public enum A {"))
        #expect(rendered.contains("struct Bridge"))
      }
    }
  }
}
/// A frontier reference to a *nested* type bridged `known` reserves its bridge
/// leaf name, not its dotted enclosing root. `R.IRoot.Use` takes `Outer.Inner`,
/// bridged to the leaf `InnerBridge`, and a local `A.InnerBridge`. The bridge
/// keys on the identity's leaf (`Inner`), as the decode does, so the reserved
/// frontier is `InnerBridge`; the reached `A.InnerBridge` bears that projected
/// name and must wrap under `enum A` rather than spell bare and capture the
/// frontier's reference. Keying the bridge on the qualified `Outer.Inner`
/// misses it and reserves the root `Outer`, leaving `A.InnerBridge` free.
@Suite struct RenderNestedKnownContendedTests {
  @Test func `a nested known bridge reserves its leaf frontier name`() throws {
    try RenderClosureTests.withLanguage(adding: "wellknown Inner InnerBridge") {
      directory in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("Outer.Inner")),
                          ("b", .value("A.InnerBridge"))])
      b.structure("Outer")
      b.structure("Inner", nested: "Outer")
      b.structure("A.InnerBridge")
      try b.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let rendered = try shell.render(closure: "IRoot", template: "com")
        #expect(rendered.contains("public enum A {"))
        #expect(rendered.contains("struct InnerBridge"))
      }
    }
  }
}
/// A closure whose signature reaches an interface nested in an emitted
/// value-type container. `R.IRoot.Use` takes `IChild`, an interface nested in
/// `struct Outer`. Swift permits a protocol nested in a non-generic value type
/// (SE-0404), so the closure must emit `IChild` inside `struct Outer` and pull
/// `Outer` in as its emitted parent — the reference spells `Outer.IChild`,
/// which must resolve to a real member rather than a phantom one.
@Suite struct RenderNestedProtocolTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4d, 0x00, 0x4a, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x21, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xc6, 0x05, 0x60, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x64, 0x00, 0x09, 0x00, 0x5a, 0x00, 0x07, 0x00, 0x23, 0x00, 0x0b, 0x00,
    0x0d, 0x00, 0x63, 0x00, 0x0b, 0x00, 0x22, 0x00, 0x03, 0x00, 0x02, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x4e, 0x53, 0x00, 0x4f, 0x75, 0x74, 0x65, 0x72, 0x00, 0x49,
    0x43, 0x68, 0x69, 0x6c, 0x64, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00,
    0x55, 0x73, 0x65, 0x00, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x05, 0x20, 0x01, 0x01, 0x12, 0x0c, 0x05, 0x20, 0x02, 0x01, 0x08,
    0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba,
    0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00, 0x14, 0x01,
    0x00, 0xce, 0xfa, 0xed, 0xfe, 0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12,
    0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 54 ..< 68,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 1, range: 68 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 2, range: 80 ..< 92,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 92 ..< 92,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 92 ..< 96,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `an interface nested in an emitted struct nests inside it`() throws {
    try RenderNestedProtocolTests.with { catalog in
      let shell = Shell(catalog)
      let rendered = try shell.render(closure: "IRoot", template: "com")
      let outer = rendered.range(of: "public struct Outer {")
      let child = rendered.range(of: "protocol IChild")
      #expect(outer != nil)
      #expect(child != nil)
      // `IChild` renders inside `struct Outer` — after its opening brace — so
      // the `Outer.IChild` its signature spells resolves. The pre-fix drop
      // omitted `IChild` entirely, leaving a phantom member.
      if let outer, let child { #expect(outer.lowerBound < child.lowerBound) }
    }
  }
}
/// A closure whose ambiguous value type is in the global CLR namespace, which
/// no fabricated container can qualify. `R.IRoot.Use` takes a local `Point` in
/// the global namespace and a local `A.Point`. Both project to `Point`, so both
/// are ambiguous: `A.Point` wraps under `enum A`, but the global `Point` has no
/// namespace segment to wrap under, so its references would stay bare and
/// capture the other's; the render must fault the residual collision
/// rather than emit a plain bare root.
@Suite struct RenderGlobalAmbiguousTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x50, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xc6, 0x05, 0x58, 0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x00, 0x52, 0x00,
    0x09, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x0f, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x50, 0x6f, 0x69, 0x6e, 0x74, 0x00, 0x41, 0x00, 0x2e, 0x63,
    0x74, 0x6f, 0x72, 0x00, 0x55, 0x73, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x07, 0x20, 0x02, 0x01, 0x11, 0x08, 0x11, 0x0c, 0x05, 0x20, 0x02,
    0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca,
    0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 0, range: 54 ..< 54,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 54 ..< 68,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 68 ..< 68,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 68 ..< 68,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 68 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 74 ..< 74,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 74 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `an ambiguous global value type faults rather than spelling bare`() {
    RenderGlobalAmbiguousTests.with { catalog in
      let shell = Shell(catalog)
      #expect(throws: Shell.RenderError.collision("Point")) {
        _ = try shell.render(closure: "IRoot", template: "com")
      }
    }
  }
}

/// A closure whose frontier reference is owned by a declaration prune keeps but
/// does not emit. `R.IRoot.Use` takes `A.Point`/`B.Point` (ambiguous `Point` →
/// fabricate `enum A`/`enum B`) and `Inner`, a value type nested under a
/// runtime class `C` — prune keeps it reached, but `nest` drops it (an
/// unemittable frontier). `Inner`'s field is typed `A` (an external class), so
/// the walk
/// records that reference *owned by* `Inner`. No emitted source spells it, so
/// it must not become a frontier `A` that the fabricated `enum A` would shadow:
/// the render must succeed, wrapping `A.Point`, not fault.
@Suite struct RenderPrunedOwnerTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x00, 0x00, 0x42, 0x00, 0x31, 0x00, 0x06, 0x00, 0x51, 0x00, 0x00, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x4b, 0x00, 0x49, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x53, 0x00, 0x51, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x53, 0x00, 0x59, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5e, 0x00,
    0x5b, 0x00, 0x0d, 0x00, 0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x60, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x66, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x05,
    0x6e, 0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x00, 0x68, 0x00, 0x0b, 0x00,
    0x23, 0x00, 0x0b, 0x00, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x05, 0x00, 0x04, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x4f, 0x62, 0x6a, 0x65, 0x63, 0x74,
    0x00, 0x52, 0x00, 0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00, 0x41, 0x00, 0x50,
    0x6f, 0x69, 0x6e, 0x74, 0x00, 0x42, 0x00, 0x4e, 0x53, 0x00, 0x43, 0x00,
    0x49, 0x6e, 0x6e, 0x65, 0x72, 0x00, 0x61, 0x00, 0x2e, 0x63, 0x74, 0x6f,
    0x72, 0x00, 0x55, 0x73, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x09, 0x20, 0x03, 0x01, 0x11, 0x08, 0x11, 0x0c, 0x11, 0x14, 0x05,
    0x20, 0x02, 0x01, 0x08, 0x0f, 0x03, 0x06, 0x12, 0x11, 0x14, 0x01, 0x00,
    0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34,
    0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 4, range: 0 ..< 24,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 5, range: 24 ..< 94,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 94 ..< 100,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 100 ..< 114,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 114 ..< 114,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 114 ..< 114,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 114 ..< 120,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 120 ..< 120,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 120 ..< 126,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 126 ..< 126,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.AssemblyRef.self, rows: 1, range: 126 ..< 146,
                wide: 0, stride: 20),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 146 ..< 150,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 35)
          | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `a reference owned by a pruned frontier is not a frontier`() throws {
    try RenderPrunedOwnerTests.with { catalog in
      let shell = Shell(catalog)
      // `A.Point` wraps under `enum A` normally; the stale `A` reference owned
      // by the unemitted `Inner` does not shadow it. Without the owner filter,
      // that stale label faults `.collision("A")`.
      let rendered = try shell.render(closure: "IRoot", template: "com")
      #expect(rendered.contains("public enum A {"))
    }
  }
}

/// A closure whose reached struct has a static field naming another local type.
/// `IRoot` returns `S`, whose only field `f` is static (the `fdStatic` bit) and
/// typed `T`. `structure` drops the static field from the emitted declaration,
/// so the walk must drop it from the dependency scan too: otherwise `T` is
/// pulled into the closure and emitted though nothing references it — an orphan
/// that renders anyway and can fault validation on an omitted member.
@Suite struct RenderStaticFieldDependencyTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x42, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4c, 0x00, 0x42, 0x00,
    0x09, 0x00, 0x02, 0x00, 0x02, 0x00, 0x16, 0x00, 0x4e, 0x00, 0x06, 0x00,
    0x06, 0x00, 0x50, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xc6, 0x05, 0x58, 0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x00, 0x52, 0x00,
    0x0d, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x13, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x4e, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x53, 0x00, 0x54, 0x00, 0x66, 0x00, 0x67, 0x00, 0x2e, 0x63,
    0x74, 0x6f, 0x72, 0x00, 0x4d, 0x61, 0x6b, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x08, 0x03, 0x06, 0x11, 0x0c, 0x02, 0x06,
    0x08, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe,
    0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78,
    0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 3, range: 12 ..< 54,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 2, range: 54 ..< 66,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 66 ..< 80,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 80 ..< 80,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 80 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 86 ..< 86,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 86 ..< 92,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 92 ..< 92,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 92 ..< 92,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure skips a static field's type when collecting dependencies`() throws {
    try RenderStaticFieldDependencyTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `S` emits (its static field dropped, so no stored properties).
      #expect(closed.contains("public struct S {"))
      // `T`, named only by `S`'s dropped static field, is not pulled in.
      #expect(!closed.contains("struct T"))
    }
  }
}

/// A closure whose reached enum is backed by a non-`i4` width (`u8`), rendered
/// with a session `SANITIZE` that respells `value__`. The enum's underlying type
/// is the `value__` field's decoded type, found by the field's raw metadata name
/// — not its escaped spelling, which the override changes — so the enum keeps its
/// `UInt64` ABI width rather than silently falling back to `i4`.
@Suite struct RenderEnumUnderlyingSanitizeTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x3f, 0x00, 0x3d, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x45, 0x00, 0x3d, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x06, 0x00, 0x47, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xc6, 0x05, 0x55, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x09, 0x00, 0x4f, 0x00, 0x09, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x0f, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x45, 0x6e, 0x75, 0x6d,
    0x00, 0x4e, 0x00, 0x49, 0x52, 0x6f, 0x6f, 0x74, 0x00, 0x45, 0x00, 0x76,
    0x61, 0x6c, 0x75, 0x65, 0x5f, 0x5f, 0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72,
    0x00, 0x4d, 0x61, 0x6b, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x08, 0x02, 0x06, 0x0b, 0x05, 0x20, 0x02,
    0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde, 0xfe, 0xca,
    0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 40 ..< 46,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 46 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 60 ..< 60,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 60 ..< 66,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 66 ..< 66,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 66 ..< 72,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 72 ..< 72,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 72 ..< 72,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure identifies enum storage before a SANITIZE override respells it`() throws {
    try RenderEnumUnderlyingSanitizeTests.with { catalog in
      var shell = Shell(catalog)
      // A session `SANITIZE` that respells only `value__`, overlaying the
      // language spec's escaping the way an `-I` spec would.
      _ = try shell.session.run(
          "CREATE FUNCTION SANITIZE(n TEXT) RETURNS TEXT "
              + "AS (CASE WHEN n = 'value__' THEN 'renamed' ELSE n END)")
      let closed = try shell.render(closure: "IRoot", template: "com")
      // The enum keeps its `u8` (`UInt64`) width, found by the raw `value__`
      // name; matching the respelled name would miss it and fall back to `i4`.
      #expect(closed.contains("public var rawValue: CUnsignedLongLong"))
      #expect(!closed.contains("public var rawValue: CInt"))
    }
  }
}

/// A closure that reaches a frontier whose own dependencies must not orphan.
/// `IRoot` returns `V`, a value type nested under the runtime class `Cl` — so its
/// enclosing chain is not an emitted value-type container and `nest` discards it
/// as a frontier. `V`'s field names `W`, reached only through the discarded `V`,
/// so `W` must be pruned rather than rendered as an unreferenced orphan.
@Suite struct RenderFrontierDependencyTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x42, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4d, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4f, 0x00,
    0x42, 0x00, 0x09, 0x00, 0x02, 0x00, 0x02, 0x00, 0x06, 0x00, 0x51, 0x00,
    0x06, 0x00, 0x06, 0x00, 0x53, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xc6, 0x05, 0x5b, 0x00, 0x01, 0x00, 0x01, 0x00, 0x09, 0x00,
    0x55, 0x00, 0x0d, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x13, 0x00, 0x03, 0x00,
    0x02, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x4e, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x43, 0x6c, 0x00, 0x56, 0x00, 0x57, 0x00, 0x66, 0x00, 0x67,
    0x00, 0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00, 0x4d, 0x61, 0x6b, 0x65, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x04, 0x20, 0x00, 0x11, 0x0c, 0x03, 0x06, 0x11, 0x10, 0x02, 0x06,
    0x08, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe,
    0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78,
    0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 4, range: 12 ..< 68,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 2, range: 68 ..< 80,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 80 ..< 94,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 0, range: 94 ..< 94,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 94 ..< 94,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 94 ..< 100,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 100 ..< 100,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1,
                range: 100 ..< 106, wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 106 ..< 106,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 1, range: 106 ..< 110,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure prunes a discarded frontier's exclusive dependency`() throws {
    try RenderFrontierDependencyTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      #expect(closed.contains("public protocol IRoot"))
      // `V` nests under the runtime class `Cl`, so it is a dropped frontier.
      #expect(!closed.contains("struct V"))
      // `W`, named only by the discarded `V`'s field, is pruned — not rendered
      // as an unreferenced orphan.
      #expect(!closed.contains("struct W"))
    }
  }
}

/// A closure whose method parameter carries a custom modifier naming a local
/// type. `IRoot.Method`'s parameter is `modopt(Mod) i4`; the generated Swift
/// signature spells only `CInt` (a non-`IsConst` modifier is ignored), so `Mod`
/// must stay out of the walk's referents — kept in the resolver for the decode's
/// `IsConst` check but never enqueued — or it emits as an orphan declaration.
@Suite struct RenderCustomModifierTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x42, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x06, 0x00, 0x4e, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xc6, 0x05, 0x58, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x50, 0x00, 0x09, 0x00, 0x52, 0x00, 0x0b, 0x00,
    0x23, 0x00, 0x0b, 0x00, 0x11, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x4e, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x4d, 0x6f, 0x64, 0x00, 0x66, 0x00, 0x70, 0x00, 0x2e, 0x63,
    0x74, 0x6f, 0x72, 0x00, 0x4d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x06, 0x20, 0x01, 0x01, 0x20, 0x08, 0x08, 0x02, 0x06, 0x08, 0x05,
    0x20, 0x02, 0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe, 0xad, 0xde,
    0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab,
    0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 40 ..< 46,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 46 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 1, range: 60 ..< 66,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 66 ..< 66,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 66 ..< 72,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 72 ..< 72,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 72 ..< 78,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 78 ..< 78,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 78 ..< 78,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure omits a custom-modifier type from the dependency walk`() throws {
    try RenderCustomModifierTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // The parameter spells only `CInt`; the modifier is ignored.
      #expect(closed.contains("func Method(_ p: CInt)"))
      // `Mod`, named only as a custom modifier, is not enqueued or emitted.
      #expect(!closed.contains("struct Mod"))
    }
  }
}

/// A closure where one type is used both as an ordinary parameter and as a
/// custom modifier in the same method. `IRoot.Method(a: Mod, b: modopt(Mod) i4)`
/// spells `Mod` for `a`, so `Mod` must still be enqueued and emitted — the
/// modifier filter must drop only a token used *solely* as a modifier, not
/// subtract every token ever seen as one.
@Suite struct RenderModifierAlsoOrdinaryTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x23, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x31, 0x00,
    0x21, 0x00, 0x00, 0x00, 0x44, 0x00, 0x42, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x42, 0x00, 0x09, 0x00,
    0x01, 0x00, 0x02, 0x00, 0x06, 0x00, 0x4e, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xc6, 0x05, 0x5a, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x50, 0x00, 0x00, 0x00, 0x02, 0x00, 0x52, 0x00,
    0x09, 0x00, 0x54, 0x00, 0x0d, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x13, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x57, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2e, 0x57, 0x69, 0x6e,
    0x33, 0x32, 0x2e, 0x46, 0x6f, 0x75, 0x6e, 0x64, 0x61, 0x74, 0x69, 0x6f,
    0x6e, 0x2e, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x00, 0x47,
    0x75, 0x69, 0x64, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x4e, 0x00, 0x49, 0x52, 0x6f, 0x6f,
    0x74, 0x00, 0x4d, 0x6f, 0x64, 0x00, 0x66, 0x00, 0x61, 0x00, 0x62, 0x00,
    0x2e, 0x63, 0x74, 0x6f, 0x72, 0x00, 0x4d, 0x65, 0x74, 0x68, 0x6f, 0x64,
    0x00,
  ]

  private static let blob: Array<UInt8> = [
    0x00, 0x08, 0x20, 0x02, 0x01, 0x11, 0x08, 0x20, 0x08, 0x08, 0x02, 0x06,
    0x08, 0x05, 0x20, 0x02, 0x01, 0x08, 0x0f, 0x14, 0x01, 0x00, 0xef, 0xbe,
    0xad, 0xde, 0xfe, 0xca, 0xbe, 0xba, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78,
    0x90, 0xab, 0x00, 0x00,
  ]

  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.FieldDef.self, rows: 1, range: 40 ..< 46,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.MethodDef.self, rows: 1, range: 46 ..< 60,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.Param.self, rows: 2, range: 60 ..< 72,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.InterfaceImpl.self, rows: 0, range: 72 ..< 72,
                wide: 0, stride: 4),
    WinMD.Table(Metadata.Tables.MemberRef.self, rows: 1, range: 72 ..< 78,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.Constant.self, rows: 0, range: 78 ..< 78,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.CustomAttribute.self, rows: 1, range: 78 ..< 84,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeSpec.self, rows: 0, range: 84 ..< 84,
                wide: 0, stride: 2),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 84 ..< 84,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 =
      (1 << 1) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 9)
          | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 27) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `--closure keeps a type used as both an ordinary parameter and a modifier`() throws {
    try RenderModifierAlsoOrdinaryTests.with { catalog in
      let shell = Shell(catalog)
      let closed = try shell.render(closure: "IRoot", template: "com")
      // `a` spells `Mod`, `b`'s modifier is ignored so it spells `CInt`.
      #expect(closed.contains("func Method(_ a: Mod, _ b: CInt)"))
      // `Mod` is enqueued (its ordinary use), so its declaration emits.
      #expect(closed.contains("public struct Mod {"))
    }
  }
}

/// A metadata-nested child whose custom template frames it with file-scope
/// content — an `import` header and an `extension` footer — must keep that
/// content at file scope, not indented into its parent container's body, which
/// would be invalid Swift. `R.IRoot.Use` names `Outer.Inner`; `Inner`'s
/// rendered body carries an `import`/`extension` around its `struct`, which
/// `partition` splits off so only `struct Inner` nests inside `struct Outer`.
@Suite struct RenderNestedHoistTests {
  @Test func `a nested child's file-scope content hoists out of its parent`() throws {
    try RenderEnclosingValueTypeTests.with { catalog in
      var shell = Shell(catalog)
      shell.templates["nested"] = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {}
        {{/interface}}
        {{#struct}}
        import Foundation
        @frozen public struct {{{name}}} {}
        extension Helper {}
        {{/struct}}
        """
      let rendered = try shell.render(closure: "IRoot", template: "nested")
      #expect(rendered.contains("struct Outer {"))
      #expect(rendered.contains("struct Inner {"))
      // `Inner`'s import/extension stay at file scope, not indented into Outer.
      #expect(!rendered.contains("    import Foundation"))
      #expect(!rendered.contains("    extension Helper"))
    }
  }
}

/// A local, ambiguous value type's identity must not qualify an external
/// reference of the same `(namespace, name)`. `A.Point` and `B.Point` are local
/// value types, so `A.Point` is ambiguous; an `AssemblyRef`-scoped external
/// `A.Point` shares that identity but is nonlocal, so it must spell bare (the
/// consumer supplies it), not bind the local `A.Point` wrapper.
@Suite struct RenderExternalReferenceQualifyTests {
  private static let bytes: Array<UInt8> = [
    0x00, 0x00, 0x08, 0x00, 0x01, 0x00, 0x06, 0x00, 0x12, 0x00, 0x18, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x12, 0x00, 0x18, 0x00, 0x05, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x12, 0x00, 0x1a, 0x00, 0x05, 0x00,
    0x01, 0x00, 0x01, 0x00,
  ]

  private static let strings: Array<UInt8> = [
    0x00, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x00, 0x56, 0x61, 0x6c, 0x75,
    0x65, 0x54, 0x79, 0x70, 0x65, 0x00, 0x50, 0x6f, 0x69, 0x6e, 0x74, 0x00,
    0x41, 0x00, 0x42, 0x00,
  ]

  private static let blob = Array<UInt8>([0x00])
  private static let empty = Array<UInt8>()

  private static let relations: Array<WinMD.Table> = [
    WinMD.Table(Metadata.Tables.TypeRef.self, rows: 2, range: 0 ..< 12,
                wide: 0, stride: 6),
    WinMD.Table(Metadata.Tables.TypeDef.self, rows: 2, range: 12 ..< 40,
                wide: 0, stride: 14),
    WinMD.Table(Metadata.Tables.NestedClass.self, rows: 0, range: 40 ..< 40,
                wide: 0, stride: 4),
  ]

  private static let valid: UInt64 = (1 << 1) | (1 << 2) | (1 << 41)

  static func with(_ body: (borrowing Storage) throws -> Void) rethrows {
    let storage = Storage(bytes: bytes.span.bytes, relations: relations.span,
                          strings: strings.span.bytes, blob: blob.span.bytes,
                          guid: empty.span.bytes, valid: valid, sorted: 0)
    try body(storage)
  }

  @Test func `a qualifying identity does not qualify an external same-named reference`() throws {
    try RenderExternalReferenceQualifyTests.with { storage in
      let (names, _) = try storage.collisions()
      #expect(names.contains("A.Point"))
      // The local `A.Point` (a `TypeDef`, token 4) qualifies to its namespace
      // path; the external `AssemblyRef`-scoped `A.Point` (a `TypeRef`, token 9)
      // shares the identity but is nonlocal, so it spells bare (nil).
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 4),
                                   qualifying: names) == "A.Point")
      #expect(try storage.spelling(of: TypeDefOrRef(rawValue: 9),
                                   qualifying: names) == nil)
    }
  }
}

/// A metadata-nested value type mapped by a well-known line must spell its
/// bridge, not its enclosing dot-path. `IRoot.Make` returns `Outer.Inner`;
/// `wellknown Inner InnerBridge` keys the nested type's own raw identity
/// `("", "Inner")`, so the walk frontiers `Inner` and the return must decode to
/// `InnerBridge` — keyed on the identity's leaf — rather than the `Outer.Inner`
/// the resolver qualifies a nested type to, which the well-known lookup would
/// miss, leaving an unresolved type its declaration was frontiered.
@Suite struct RenderNestedWellKnownTests {
  @Test func `a nested well-known type spells its bridge, not its dotted path`() throws {
    try RenderClosureTests.withLanguage(adding: "wellknown Inner InnerBridge") {
      directory in
      try RenderEnclosingValueTypeTests.with { catalog in
        let shell = Shell(catalog, search: [directory])
        let closed = try shell.render(closure: "IRoot", template: "com")
        #expect(closed.contains("InnerBridge"))
        #expect(!closed.contains("Outer.Inner"))
      }
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
/// Emittedness and ABI-occupant detection read the *code* a template renders,
/// not its complete text: per-type boilerplate outside any kind section, and
/// declaration-like text inside comments or string literals, name nothing.
@Suite struct RenderDeclarationDetectionTests {
  private static func withTemplate(_ name: String, _ body: String,
                                   _ test: (String) throws -> Void) throws {
    let manager = FileManager.default
    let directory =
        manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let templates = directory.appendingPathComponent("Templates")
    try manager.createDirectory(at: templates,
                                withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    try Data(body.utf8)
        .write(to: templates.appendingPathComponent("\(name).mustache"))
    try test(directory.path)
  }


  // A template with per-type boilerplate (here a `// generated for {{name}}`
  // comment) outside its kind sections but no struct section renders a body
  // that differs from the empty-context skeleton for every reached struct, yet
  // declares no struct. Emittedness must find the struct's actual declaration,
  // not diff the whole text, or the phantom struct enters the emitted set and
  // two same-named value types fabricate `enum A`/`enum B`, qualifying the
  // interface's parameter to an undeclared `A.Point`.
  @Test func `a boilerplate comment does not mark an undeclared struct emitted`() throws {
    let template = """
      {{! language: swift }}
      // generated for {{{name}}}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      """
    try Self.withTemplate("boiler", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot", template: "boiler")
        // The structs declare nothing, so `Point` is unambiguous among the
        // emitted set and the parameter spells bare — no fabricated container,
        // no undeclared `A.Point`.
        #expect(rendered.contains("_ a: Point"))
        #expect(!rendered.contains("A.Point"))
        #expect(!rendered.contains("enum A"))
      }
    }
  }

  // A generic type whose template documents `protocol FooABI` in a comment but
  // omits the actual helper declares no ABI occupant. Detecting the helper by a
  // raw text scan would find the comment; when the closure also emits a real
  // `FooABI`, the phantom occupant then faults a spurious `collision("FooABI")`
  // though the rendered source has no redeclaration.
  @Test func `an ABI helper named only in a comment is not an occupant`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      @com(interface: "{{{iid}}}")
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#delegate}}
      {{#generic}}
      // mentions protocol {{{name}}}ABI in a comment but omits the helper
      public struct {{{name}}}<{{#generics}}{{{name}}}{{^last}}, {{/last}}{{/generics}}> {
      }
      {{/generic}}
      {{/delegate}}
      {{#struct}}
      @frozen public struct {{{name}}} {
      }
      {{/struct}}
      """
    try Self.withTemplate("doc", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("f", .object("Foo")), ("g", .value("FooABI"))])
      b.delegate("Foo").generic("T")
          .method("Invoke", [("v", .primitive(0x08))])
      b.structure("FooABI")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot", template: "doc")
        // The comment's `FooABI` is not a declaration, so the real struct is
        // the only `FooABI` occupant and no collision faults.
        #expect(rendered.contains("struct FooABI"))
      }
    }
  }

  // Shared `let {{name}} = 0` boilerplate names the type in a *value*
  // declaration — a variable of the type's name, not a type — so a reached
  // struct with no struct section is not emitted. Only a type-declaration
  // keyword before the name counts; crediting any identifier that follows
  // another (here `Point` after `let`) would readmit the phantom struct and
  // fabricate an undeclared `A.Point`.
  @Test func `a value declaration of the type's name does not emit the struct`() throws {
    let template = """
      {{! language: swift }}
      let {{{name}}} = 0
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      """
    try Self.withTemplate("value", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot", template: "value")
        #expect(rendered.contains("_ a: Point"))
        #expect(!rendered.contains("A.Point"))
        #expect(!rendered.contains("enum A"))
      }
    }
  }

  // A template that declares the metadata name only *inside* a helper —
  // `struct Helper { typealias {{name}} = CInt }` — declares no top-level type
  // of that name. Only a declaration at brace depth zero establishes
  // emittedness; a `typealias Point` nested in `Helper`'s body would otherwise
  // (its keyword being a type keyword) mark the struct emitted and fabricate an
  // undeclared `A.Point`.
  @Test func `a nested member declaration does not emit the struct`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#struct}}
      struct Helper { typealias {{{name}}} = CInt }
      {{/struct}}
      """
    try Self.withTemplate("helper", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot", template: "helper")
        #expect(rendered.contains("_ a: Point"))
        #expect(!rendered.contains("A.Point"))
        #expect(!rendered.contains("enum A"))
      }
    }
  }

  // Swift block comments nest, so a declaration between the inner and outer
  // `*/` of `/* outer /* inner */ struct {{name}} */` stays commented out. A
  // boolean comment flag would exit at the inner `*/` and record the struct,
  // marking a type the template never declares emitted and fabricating an
  // undeclared `A.Point`; the scanner must balance comment nesting depth.
  @Test func `a declaration inside a nested block comment is not emitted`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#struct}}
      /* outer /* inner */ struct {{{name}}} */
      {{/struct}}
      """
    try Self.withTemplate("nested", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot", template: "nested")
        #expect(rendered.contains("_ a: Point"))
        #expect(!rendered.contains("A.Point"))
        #expect(!rendered.contains("enum A"))
      }
    }
  }

  // An auxiliary top-level declaration a template emits beside the primary type
  // — here `struct A` beside `protocol IRoot` — is a scope occupant. When the
  // same closure fabricates the namespace container `enum A` (wrapping the
  // ambiguous `A.Point`/`B.Point`), the two top-level `A` declarations are an
  // invalid redeclaration. The collision scan must see every name the tokenizer
  // found, not only the primary and the generic ABI helper, and fault.
  @Test func `an auxiliary declaration colliding with a fabricated namespace faults`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      struct A {}
      {{/interface}}
      {{#struct}}
      @frozen public struct {{{name}}} {}
      {{/struct}}
      """
    try Self.withTemplate("aux", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        #expect(throws: Shell.RenderError.collision("A")) {
          _ = try shell.render(closure: "IRoot", template: "aux")
        }
      }
    }
  }

  // A custom template frames its value type with a file-scope `import` header
  // and an `extension` footer. When the type collides and is wrapped in a
  // fabricated namespace `enum`, only its primary declaration is wrapped: Swift
  // permits `import`/`extension` only at file scope, so they are hoisted back
  // outside the enum rather than indented into it, which would not compile.
  @Test func `file-scope content stays outside a fabricated namespace enum`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#struct}}
      import Foundation
      @frozen public struct {{{name}}} {}
      extension Helper {}
      {{/struct}}
      """
    try Self.withTemplate("framed", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot", template: "framed")
        #expect(rendered.contains("public enum A {"))
        #expect(rendered.contains("struct Point"))
        // The `import`/`extension` are at file scope, never indented into the
        // enum.
        #expect(!rendered.contains("    import Foundation"))
        #expect(!rendered.contains("    extension Helper"))
      }
    }
  }

  // Two ambiguous value types each wrap in their own fabricated `enum`, and the
  // template appends a `struct Helper {}` auxiliary that `partition` hoists to
  // file scope. The two hoisted `Helper` declarations are a file-scope
  // redeclaration: a per-enum auxiliary check misses it (each `Helper` sits
  // under a different namespace), so the hoisted helpers are attributed to the
  // root scope and fault `collision("Helper")`.
  @Test func `hoisted auxiliaries collide at the root scope`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#struct}}
      @frozen public struct {{{name}}} {}
      struct Helper {}
      {{/struct}}
      """
    try Self.withTemplate("helpers", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("a", .value("A.Point")), ("b", .value("B.Point"))])
      b.structure("A.Point")
      b.structure("B.Point")
      b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        #expect(throws: Shell.RenderError.collision("Helper")) {
          _ = try shell.render(closure: "IRoot", template: "helpers")
        }
      }
    }
  }

  // A template omits `{{#struct}}` but renders `{{#enum}}`. `IRoot` reaches the
  // struct `Point`, and a `Point` field reaches the enum `Widget`. The first
  // prune keeps `Widget` (reached through the metadata-emittable `Point`), but
  // the template declares no `Point`, so `Widget` — reached only through that
  // omitted node — is an orphan the emitted source never references. Re-pruning
  // against the bodied set before filtering drops it rather than rendering an
  // unattached `struct Widget`.
  @Test func `an orphan reached through an omitted declaration is dropped`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#enum}}
      @frozen public struct {{{name}}}: Hashable {}
      {{/enum}}
      """
    try Self.withTemplate("omit-struct", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("v", .value("Point"))])
      b.structure("Point").field("w", .value("Widget"))
      b.enumeration("Widget")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot",
                                        template: "omit-struct")
        #expect(rendered.contains("public protocol IRoot"))
        #expect(!rendered.contains("struct Widget"))
      }
    }
  }

  // A *metadata-nested* value type (`Outer.Inner`) whose custom template frames
  // it with file-scope content: when `Inner` nests into the real `Outer`
  // container, its `import`/`extension` must hoist to file scope, not be
  // indented into `struct Outer` — Swift permits them only at file scope. The
  // `.type` container partitions and hoists a child's file-scope content just
  // as the fabricated `.space` namespace does.
  @Test func `a real nested child hoists its file-scope content`() throws {
    let template = """
      {{! language: swift }}
      {{#interface}}
      public protocol {{{name}}} {
      {{#methods}}
          func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
      {{/methods}}
      }
      {{/interface}}
      {{#struct}}
      import Foundation
      @frozen public struct {{{name}}} {}
      extension Helper {}
      {{/struct}}
      """
    try Self.withTemplate("nested-scope", template) { dir in
      let b = WinMDBuilder()
      b.interface("R.IRoot", guid: 0xDEADBEEF)
          .method("Use", [("v", .value("Outer.Inner"))])
      b.structure("Outer")
      b.structure("Inner", nested: "Outer")
      try b.with { catalog in
        let shell = Shell(catalog, search: [dir])
        let rendered = try shell.render(closure: "IRoot",
                                        template: "nested-scope")
        #expect(rendered.contains("struct Outer {"))
        #expect(rendered.contains("struct Inner {"))
        // `Inner`'s `import`/`extension` are at file scope, never indented into
        // `struct Outer`.
        #expect(!rendered.contains("    import Foundation"))
        #expect(!rendered.contains("    extension Helper"))
      }
    }
  }
}
/// A closure whose two separately-wrapped containers each hold a metadata-nested
/// child that hoists a same-named helper to file scope. `R.IRoot.Use` names
/// `A.Outer.Inner` and `B.Outer.Inner2` (ambiguous `Outer`, so both `Outer`s
/// wrap under fabricated `enum A`/`enum B`); the template renders each nested
/// enum with an extra `struct Helper {}` beside it, which — being only a
/// primary declaration's file-scope neighbour — hoists out through its `Outer`
/// and the enum to the root file scope. Both helpers land at file scope, an
/// invalid redeclaration; the tally must count auxiliaries of a wrapped
/// container's descendants, not just its direct children, and fault
/// `.collision("Helper")`.
@Suite struct RenderDescendantHoistTests {
  @Test func `descendants of wrapped containers hoisting a shared helper fault`() throws {
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Use", [("a", .value("A.Outer.Inner")),
                        ("b", .value("B.Outer.Inner2"))])
    b.structure("A.Outer")
    b.structure("B.Outer")
    b.enumeration("Inner", nested: "A.Outer")
    b.enumeration("Inner2", nested: "B.Outer")
    b.with { catalog in
      var shell = Shell(catalog)
      shell.templates["helper"] = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {
        {{#methods}}
            func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
        {{/methods}}
        }
        {{/interface}}
        {{#struct}}
        public struct {{{name}}} {}
        {{/struct}}
        {{#enum}}
        public struct {{{name}}} {}
        public struct Helper {}
        {{/enum}}
        """
      #expect(throws: Shell.RenderError.collision("Helper")) {
        _ = try shell.render(closure: "IRoot", template: "helper")
      }
    }
  }
}
/// A referent named in *both* a method's return and a parameter collapses to
/// one `Referent`, so it must carry both categories. `R.IRoot.Use` returns an
/// external `A` and takes a local `X.A` plus that same external `A`; the
/// template renders parameters but omits returns. The external `A` reference is
/// spelled (as a parameter), so it must contend the local value type `X.A` —
/// which wraps under `enum X` — even though it also occurs in the omitted
/// return. A return-or-parameter categorization that recorded only `.returned`
/// would treat it as unrendered and leave `X.A` bare to capture the external
/// parameter.
@Suite struct RenderReturnParameterCategoryTests {
  @Test func `a return-and-parameter referent contends when only parameters render`() throws {
    let b = WinMDBuilder()
    b.interface("R.IRoot", guid: 0xDEADBEEF)
        .method("Use", returns: .external("A"),
                [("a", .value("X.A")), ("b", .external("A"))])
    b.structure("X.A")
    try b.with { catalog in
      var shell = Shell(catalog)
      shell.templates["params"] = """
        {{! language: swift }}
        {{#interface}}
        public protocol {{{name}}} {
        {{#methods}}
            func {{{name}}}({{#params}}_ {{{name}}}: {{{type}}}{{^last}}, {{/last}}{{/params}})
        {{/methods}}
        }
        {{/interface}}
        {{#struct}}
        public struct {{{name}}} {}
        {{/struct}}
        """
      let rendered = try shell.render(closure: "IRoot", template: "params")
      #expect(rendered.contains("public enum X {"))
    }
  }
}
