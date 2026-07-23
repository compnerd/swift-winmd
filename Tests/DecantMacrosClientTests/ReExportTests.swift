// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// Imports ONLY DecantMacros — never Decant directly — so this target fails
// to build if the derive layer stops re-exporting the `Decant` core. A macro
// expansion references `Decant.Serializable`/`Decant.Serializer` (and the
// deserialize equivalents) in this scope; without the re-export their members
// are not visible here and the conformance does not compile.
import DecantMacros
import Testing

@Serializable
@Deserializable
struct Probe {
  let x: Int
  let y: Int
}

// An implicitly-unwrapped optional field `Int!`. The read cannot annotate as
// `decode() as Int!` — the `!` sugar is not a legal coercion target — so the
// derive normalizes the cast to `decode() as Int?`, which the memberwise-init
// parameter (still `Int!`) accepts (`Optional` is `Deserializable`). That this
// COMPILES and round-trips WARNING-FREE — the swiftc-level guard the expansion
// golden cannot give — proves the normalization.
@Serializable
@Deserializable
struct IUOProbe: Equatable {
  var x: Int!
}

// A field declared with a keyword name — `` var `self` `` / `` var `init` ``
// — is stored under the BARE word (`self`/`init`). The derive must re-escape
// it in the serialize `self.`self`` member-access position: without the
// escape, `self.self` serializes the whole instance and `self.init` fails to
// compile. The deserialize argument label stays the bare `self:` / `init:`
// (an argument label accepts a keyword unescaped), and the serialization-name
// STRING keys stay the bare words (data, not identifiers). That this derives
// AND round-trips WARNING-FREE is the guard.
@Serializable
@Deserializable
struct KeywordProbe: Equatable {
  var `self`: Int
  var `init`: Int
  var x: Int
}

// A field declared with a RAW identifier name (SE-0451) — `` var `foo bar` ``
// carries a space and `` var `quote"x` `` a quote, neither a plain identifier
// nor a keyword. The derive must spell each source-safely in three contexts:
// the serialize member access (`self.`foo bar``, backtick-escaped), the
// serialization-name STRING key (a valid literal — the quote forces `#"…"#`
// delimiters), and the deserialize init LABEL (`` `foo bar`: ``, backticked,
// since a bare `foo bar:` is a syntax error). Without any one of these the
// bare interpolation fails to compile. That it derives AND round-trips
// WARNING-FREE is the guard.
@Serializable
@Deserializable
struct RawNameProbe: Equatable {
  var `foo bar`: Int
  var `quote"x`: Int
}

// A field named exactly the wildcard `_` — canonicalized to the bare word
// `_`. It is a plain, non-keyword identifier, yet BOTH derive contexts need
// backticks the other escaping rules miss: the serialize member access
// `` self.`_` `` (a bare `self._` does not parse) and the deserialize init
// LABEL `` `_`: `` (a bare `_:` is an OMITTED positional label, not the real
// `_` label the memberwise init `UnderscoreProbe(_:x:)` expects, so it
// mis-binds). The serialization-name STRING key stays the bare `"_"` (data,
// not an identifier). That this derives AND round-trips WARNING-FREE — with the
// escaped `` `_`: `` label carrying the value to the right parameter — is the
// guard; a bare `_:` would compile to a positional argument and round-trip
// wrong.
@Serializable
@Deserializable
struct UnderscoreProbe: Equatable {
  var `_`: Int
  var x: Int
}

// A struct whose TYPE NAME is a RAW identifier (SE-0451) carrying a quote —
// `` `Quote"Type` ``. The derive must spell it source-safely by position: the
// `` extension `Quote"Type` `` header keeps the backticks (an identifier
// position), while the serialized structure-name `structure(…)` argument is
// the CANONICAL bare name emitted as a valid string LITERAL — the quote forces
// `#"…"#` delimiters, so a bare `structure("Quote"Type", …)` interpolation
// would not compile. The deserialize constructor is `Self`, so the type name
// never appears in call position. That this derives AND round-trips
// WARNING-FREE is the guard.
@Serializable
@Deserializable
struct `Quote"Type`: Equatable {
  var x: Int
}

// A struct whose TYPE NAME is exactly `D` — the same letter the deserialize
// derive gives its generic `Deserializer` parameter (`deserialize<D>`). Were
// the constructor spelled by name (`try D(x: …)`), that `D` would resolve to
// the generic parameter (the `Deserializer` type) rather than the enclosing
// model, so a valid model named `D` would not derive. The derive spells the
// constructor `Self`, which is the conforming model unambiguously and is not
// shadowed by the generic parameter. That this derives AND round-trips
// WARNING-FREE is the guard.
@Serializable
@Deserializable
struct D: Equatable {
  var x: Int
}

// A generic struct whose type parameter is named exactly `S` — the letter the
// serialize derive gives its own `Serializer` generic parameter. The method's
// `<S>` is nested in the type, so a same-named type parameter shadows it, which
// Swift 6 rejects; the derive detects the collision and gives the serialize
// parameter a hygienic name instead. The fields do not even depend on `S`, so
// the model is otherwise valid. That this derives AND round-trips WARNING-FREE
// is the guard; the shadowing spelling would not compile.
@Serializable
@Deserializable
struct SerializerCollisionProbe<S>: Equatable {
  var x: Int
}

// The deserialize twin — a type parameter named `D`, the letter the
// deserialize derive gives its `Deserializer` generic parameter, which the
// method's `<D>` would otherwise shadow. Same guard.
@Serializable
@Deserializable
struct DeserializerCollisionProbe<D>: Equatable {
  var x: Int
}

// A NON-generic type nested in a generic context. The derive is applied to
// `Inner`, whose emitted `serialize<S>`/`deserialize<D>` would — with a
// readable spelling — shadow the enclosing `NestingProbe`'s `S`/`D`, a Swift 6
// error, even though `Inner` does not itself use them. The compiler hands the
// macro the declaration DETACHED from its enclosing tree, so those names are
// invisible and cannot be reserved; the derive always takes a hygienic generic
// parameter name, which shadows nothing in or around the type. That `Inner`
// derives AND round-trips WARNING-FREE is the guard.
struct NestingProbe<S, D> {
  @Serializable
  @Deserializable
  struct Inner: Equatable {
    var x: Int
  }

  // Doubly nested, under a second generic level, to confirm the hygienic name
  // clears every enclosing scope, not just the innermost.
  struct Middle<T> {
    @Serializable
    @Deserializable
    struct Leaf: Equatable {
      var y: Int
    }
  }
}

// A generic type whose stored field's type USES the generic parameter, so the
// derive must emit a CONDITIONAL conformance — `extension Box: … where T: …`.
// An unconditional conformance would not type-check: `serializer.field` needs
// `T: Serializable` and `deserializer.decode()` needs `T: Deserializable`.
// `Box<Int>` supplies a conforming `T`, so the conditional conformance holds
// and the value round-trips; that it derives AND round-trips is the guard.
@Serializable
@Deserializable
public struct GenericFieldProbe<T>: Equatable where T: Equatable {
  public var value: T
}

// Two generic parameters, each read by a field, so BOTH are constrained. A
// `Pair<Int, Int>` conforms on both parameters and round-trips.
@Serializable
@Deserializable
public struct GenericPairProbe<A, B>: Equatable
    where A: Equatable, B: Equatable {
  public var a: A
  public var b: B
}

// A wrapper that conforms to `Serializable`/`Deserializable` for EVERY `T`,
// serializing only its own `Int` and ignoring the phantom `T`. It stands in
// for a real container that conforms independent of its element.
public struct Wrapper<T>: Serializable, Deserializable, Equatable {
  public var payload: Int

  public init(payload: Int) {
    self.payload = payload
  }

  public func serialize<S>(into serializer: consuming S)
      throws(S.Failure) -> S
      where S: Serializer & ~Copyable & ~Escapable {
    var structure = (consume serializer).structure("Wrapper", fields: 1)
    try structure.field("payload", payload)
    return try structure.end()
  }

  public static func deserialize<D>(from deserializer: inout D)
      throws(D.Failure) -> Self
      where D: Deserializer & ~Copyable & ~Escapable {
    try deserializer.structure("Wrapper", fields: 1)
    let value = try Self(payload: deserializer.decode())
    try deserializer.end()
    return value
  }
}

// A model whose field wraps `T` in a general (non-container) type. The derive
// cannot legally constrain the WRITTEN type — `where Wrapper<T>: Serializable`
// has an applied-type left side Swift's grammar REJECTS — so it falls back to
// the parameter the type mentions: `where T: Serializable`. That the emitted
// extension COMPILES (not merely expands to text) with the parameter constraint
// and `HolderProbe<Int>` round-trips is the guard: a naive `where Wrapper<T>:
// …` clause fails to type-check before the body runs, which an expansion-only
// golden would not catch.
@Serializable
@Deserializable
public struct HolderProbe<T>: Equatable {
  public var value: Wrapper<T>
}

// A container field whose element is the generic parameter — the derive lowers
// `Array<T>` to `where T: Serializable`, the exact condition under which the
// array conforms. That `Bag<Int>` COMPILES and round-trips proves the lowered
// element-parameter clause is legal and sufficient (an applied `where Array<T>:
// …` would fail to type-check). Nesting is covered too: `Array<Optional<T>>`
// mentions only `T`, so it lowers to the same `where T: Serializable`.
@Serializable
@Deserializable
public struct BagProbe<T> {
  public var items: Array<T>
  public var maybe: Array<Optional<T>>
}

extension BagProbe: Equatable where T: Equatable {}

// A stored property carrying a built-in declaration attribute — `@available`,
// which is NOT a property wrapper. The derive must collect and round-trip it
// rather than reject it as wrapper-backed; that it derives is the guard. The
// availability is a plain platform introduction (not `deprecated`) so the
// serialize read of `self.x` stays warning-free — the expansion test carries
// the `deprecated` spelling, where no member access type-checks.
@Serializable
@Deserializable
struct BuiltinAttributeProbe: Equatable {
  @available(macOS 10.0, *) var x: Int
  var y: Int
}

// A struct whose only initializer is the memberwise-EQUIVALENT one the user
// wrote by hand: its argument labels match the fields in order, so the
// derive's `MatchingInitProbe(value:)` call resolves and no `.initializer`
// diagnostic fires. That it derives and round-trips is the guard that the
// match escape hatch is not a false negative.
@Serializable
@Deserializable
struct MatchingInitProbe: Equatable {
  var value: Int
  init(value: Int) {
    self.value = value
  }
}

// A matching init inside an `#if true` — no `#else`. The per-branch scan finds
// the one active clause carries a match, so no `.initializer` diagnostic fires
// and the derive proceeds; the memberwise-equivalent init the clause supplies
// is what `Self(value:tag:)` resolves against in this build. The `#if true tag`
// field is a conditional field, absent from the branch that omits the clause,
// so its `tag` parameter carries a DEFAULT — the omitting build's
// `Self(value:)` resolves through it. That it derives AND round-trips is the
// guard that a matching conditional init is not a false positive of the
// mutually-exclusive analysis, and that a defaulted conditional-field
// parameter satisfies the per-branch match.
@Serializable
@Deserializable
struct ConditionalMatchingInitProbe: Equatable {
  var value: Int
  #if true
  var tag: Int
  init(value: Int, tag: Int = 0) {
    self.value = value
    self.tag = tag
  }
  #endif
}

// A tuple stored binding destructures into its components, so the generated
// conformance writes and reads each and the synthesized memberwise init —
// flattened to `TupleProbe(a:x:y:b:)` — reconstructs them. That this compiles
// is the guarantee: a syntactic derive that skipped the tuple would emit too
// few fields and a mismatched initializer.
@Serializable
@Deserializable
struct TupleProbe {
  var a: Int
  var (x, y): (Int, Int)
  var b: Int
}

// A nested tuple binding flattens the same way — `NestedProbe(x:y:z:)`.
@Serializable
@Deserializable
struct NestedProbe {
  var (x, (y, z)): (Int, (Int, Int))
}

// Stored properties named exactly for the macro's own introduced locals — the
// serialize sub-serializer (`structure`), the consumed `serializer`, and the
// `inout deserializer` parameter. Without hygiene the generated `field(…)`
// operand or the decoded `let` would resolve to those introduced names, so this
// FAILS to compile: `field("structure", structure)` would pass the
// sub-serializer (not `Serializable`) and `let deserializer = …` would shadow
// the parameter the structure-close reads. With `makeUniqueName` locals and
// `self.`-qualified reads it derives, compiles, and does not miscompile.
@Serializable
@Deserializable
struct HygieneProbe {
  var structure: Int
  var serializer: Int
  var deserializer: Int
}

// A type-level member — `static let`/`static var`, and the `class` spelling on
// the reference-count-free struct is still type level — is NOT an instance
// stored property and NOT a memberwise-init parameter. The derive must skip it:
// were `version`/`shared` collected, serialize would emit `self.version` and
// deserialize would pass an argument the memberwise init `StaticProbe(x:y:)`
// has no parameter for, so this FAILS to compile. That it derives is the guard.
@Serializable
@Deserializable
struct StaticProbe {
  static let version = 1
  nonisolated(unsafe) static var shared = 0
  let x: Int
  var y: Int
}

// A field whose type is inferred from its initializer (`count`, no written
// annotation). The read is emitted in the memberwise-init argument position, so
// the init parameter supplies `decode`'s result type; without that context the
// generic `decode()` has nothing to infer against and this FAILS to type-check.
@Serializable
@Deserializable
struct InferredProbe {
  var count = 0
  let name: String
}

// An untyped tuple leaf — `(x, y)` inferred `(1, 2)` — flattens to the same
// init-argument reads, so each leaf's type comes from its `InferredTupleProbe`
// parameter. It compiles for the same reason `InferredProbe` does.
@Serializable
@Deserializable
struct InferredTupleProbe {
  var (x, y) = (1, 2)
}

// The shapes the diagnostics for `lazy` and initialized `let` must NOT
// over-reject: an uninitialized `let` is a REQUIRED memberwise parameter, an
// initialized `var` is a DEFAULTED one, and an observed stored `var` stays a
// parameter too. All three remain instance stored properties in the
// synthesized memberwise init, so the derive collects each and this compiles;
// were the rejection too broad, `MemberwiseProbe(x:y:z:)` would lose a
// parameter and the generated init call would fail to type-check.
@Serializable
@Deserializable
struct MemberwiseProbe {
  let x: Int
  var y = 0
  var z = 0 {
    didSet {}
  }
}

// An initialized `let` is a valid stored property on the serialize side: the
// generated `serialize` reads `self.version` (nonmutating), and Swift omits it
// only from the memberwise init — which serialize never calls. So a
// `@Serializable`-only struct carrying one derives and writes it; were the
// initialized-`let` rejection still shared with deserialize, this would refuse
// to compile. (`@Deserializable` on the same shape stays diagnosed — proven in
// the expansion tests — so no silent round-trip mismatch escapes.)
@Serializable
struct VersionedProbe {
  let version = 1
  let payload: Int
}

// Stored properties guarded by `#if` — a validated bug the derive once dropped
// silently, since an `IfConfigDeclSyntax` member is neither a `var` nor a `let`
// binding. The plugin cannot evaluate a compilation condition (it arrives
// unresolved), so the derive MIRRORS the guards into the generated code and
// lets the compiler activate the matching clause. The test build's config is
// fixed, so `#if true` (active) and `#if false` (inactive) exercise BOTH a live
// and a dead branch deterministically: the type — and the derived code — carry
// `t` (under `#if true`) but not `skip` (under `#if false`), so a correct
// round-trip writes and reads exactly `a`, `t`, `b`. Were the guards dropped,
// serialize would write too few fields and deserialize would call a `Self(…)`
// missing `t`; were the inactive field NOT guarded, `self.skip` would not even
// compile. That this derives, compiles, and round-trips is the guard.
@Serializable
@Deserializable
struct ConditionalProbe: Equatable {
  var a: Int
  #if true
  var t: Int
  #endif
  #if false
  var skip: Int
  #endif
  var b: Int
}

// An `#if true`/`#else`: the `#if` clause is active, so `live` is the compiled
// field and `dead` is absent. The derive emits a `Self(…)` per branch — the
// active one carries `live` — so it round-trips `a`, `live`, `b`.
@Serializable
@Deserializable
struct IfElseActiveProbe: Equatable {
  var a: Int
  #if true
  var live: Int
  #else
  var dead: Int
  #endif
  var b: Int
}

// An `#if false`/`#else`: the ELSE clause is active, so `chosen` is the
// compiled field and the `#if` clause's `other` is absent. The per-branch
// `Self(…)` for the else clause carries `chosen`, so it round-trips `a`,
// `chosen`, `b` — proving the derive follows the guard the compiler activates
// rather than the first-written clause.
@Serializable
@Deserializable
struct IfElseInactiveProbe: Equatable {
  var a: Int
  #if false
  var other: Int
  #else
  var chosen: Int
  #endif
  var b: Int
}

// A matching init whose CONDITIONAL field lives under `#if false`, so the
// build that omits the clause is the one that compiles: `omitted` is absent and
// the derive emits `Self(kept:)`. The init's `omitted` parameter carries a
// DEFAULT, so that shorter call resolves — the guard that a defaulted
// conditional-field parameter lets an omitting branch reuse the custom init
// rather than diagnose. It round-trips exactly `kept`.
@Serializable
@Deserializable
struct DefaultedConditionalInitProbe: Equatable {
  var kept: Int
  #if false
  var omitted: Int
  #endif
  init(kept: Int, omitted: Int = 0) {
    self.kept = kept
    #if false
    self.omitted = omitted
    #endif
  }
}

// Mutually-exclusive `#if` clauses declaring the SAME field `x`, plus the exact
// replacement `init(x:)`. Every build compiles ONE `x`, so the derive emits
// `Self(x:)` in each branch and the custom init resolves in every build. A
// flattened field list would hold two `x`s and reject the one-parameter init;
// the per-branch match sees one active `x` per branch, so it derives and
// round-trips `x` rather than diagnosing `.initializer`.
@Serializable
@Deserializable
struct ExclusiveSameFieldProbe: Equatable {
  #if true
  var x: Int
  #else
  var x: Int
  #endif
  init(x: Int) {
    self.x = x
  }
}

// A matching init carrying NO availability (nor any other disqualifying
// attribute): it stays a memberwise-equivalent replacement, so the derive
// reuses it (no `.initializer` diagnostic) and the value round-trips. A
// version-restricted `@available` (a platform `introduced:`/short-form
// version, or `swift <version>`) would instead be a non-match — it gates the
// init to a version the witness is not emitted under — proven in the expansion
// tests, alongside `unavailable`/`obsoleted`/`deprecated`.
@Serializable
@Deserializable
struct MatchingInitAvailabilityProbe: Equatable {
  var x: Int
  init(x: Int) {
    self.x = x
  }
}

// A conditional field `x` and a custom init in the SAME `#if` as the field.
// In the build where the clause is active, `init(base:x:)` is compiled and
// covers `Self(base:x:)`; in the build that omits it, neither `x` nor the init
// is compiled, so the synthesized memberwise `init(base:)` applies. The
// per-build analysis matches the init only against its active build, so it does
// not demand `x` carry a default — a validated bug the global scan diagnosed.
// The test build's `#if true` is active, so it round-trips `base` and `x`.
@Serializable
@Deserializable
struct ConditionalInitProbe: Equatable {
  var base: Int
  #if true
  var x: Int
  init(base: Int, x: Int) {
    self.base = base
    self.x = x
  }
  #endif
}

// Two same-labelled initializer overloads active together — `init(x: Int)` and
// `init(x: String)`. The bare `Self(x: deserializer.decode())` would leave the
// generic `decode()` no result type and the `init(x:)` set ambiguous; the
// derive disambiguates by reading the field with its declared type
// (`decode() as Int`), so overload resolution picks `init(x: Int)`. That this
// derives AND round-trips WARNING-FREE — through the `Int` init, not the
// `String` one — is the guard.
@Serializable
@Deserializable
struct OverloadedInitProbe: Equatable {
  var x: Int
  init(x: Int) {
    self.x = x
  }
  init(x: String) {
    self.x = Int(x) ?? 0
  }
}

// A same-labelled init overload declared in an EXTENSION — `init(x: String)`
// — which the macro CANNOT see (it reads only the primary declaration) and
// which does NOT suppress the synthesized `init(x: Int)`. Both join overload
// resolution at the derive's call site, so a bare `Self(x: deserializer
// .decode())` would leave `decode()` untyped and the `init(x:)` set an
// ambiguity — a hard `swiftc` error in this client target the macro test
// cannot catch. The derive annotating the read `decode() as Int`
// unconditionally picks the `Int` init regardless. That this compiles AND
// round-trips WARNING-FREE is the guard.
@Serializable
@Deserializable
struct ExtensionOverloadProbe: Equatable {
  var x: Int
}

extension ExtensionOverloadProbe {
  init(x: String) {
    self.x = Int(x) ?? 0
  }
}

// A tuple stored binding whose written annotation SPLITS per leaf, beside a
// same-labelled init overload in an EXTENSION. Without the split, `x` and `y`
// would record no type and decode as bare `deserializer.decode()`; with the
// `init(x: String, y: String)` overload also live (an extension init does not
// suppress the memberwise `init(x: Int, y: Int)`), the bare `Self(x:y:)` call
// would be AMBIGUOUS — a hard `swiftc` error the macro golden cannot catch. The
// per-leaf split records `x: Int`/`y: Int` and emits `decode() as Int` casts,
// which pick the `Int` init and resolve the call. That this compiles AND
// round-trips WARNING-FREE is the guard.
@Serializable
@Deserializable
struct TupleOverloadProbe: Equatable {
  var (x, y): (Int, Int)
}

extension TupleOverloadProbe {
  init(x: String, y: String) {
    self.x = Int(x) ?? 0
    self.y = Int(y) ?? 0
  }
}

// A derived type NESTED in an EXTENSION of a generic type, whose OUTER
// parameter a field stores. The `extension Probe where T: Equatable` carries
// `T` in scope, so `Inner`'s `var value: T` mentions the enclosing `T` — but a
// naive derive that reads generic parameters only from enclosing TYPE
// declarations would treat the extension as contributing NONE, emit an
// UNCONDITIONAL `extension Probe.Inner: Serializable`, and fail to compile
// (the body needs `T: Serializable`/`Deserializable`). The unified generic
// environment reads the extension's `where`-clause subject `T`, so the derive
// emits the CONDITIONAL `extension …Inner: … where T: …`. That an
// `EnclosingExtensionProbe<Int>.Inner` round-trips is the guard; before the
// fix the unconditional conformance did not compile.
public struct EnclosingExtensionProbe<T> {}

extension EnclosingExtensionProbe where T: Equatable {
  @Serializable
  @Deserializable
  public struct Inner: Equatable {
    public var value: T

    public init(value: T) {
      self.value = value
    }
  }
}

// A struct with NO stored properties. Its deserialize branch decodes nothing,
// so it must call the synthesized no-argument memberwise init WITHOUT `try` —
// that init is nonthrowing, and a `try Self()` would warn "no calls to
// throwing functions occur", failing the warning-free build. That this derives
// AND round-trips WARNING-FREE is the guard.
@Serializable
@Deserializable
struct EmptyProbe: Equatable {}

// A conditional-ONLY field set: `payload` lives under `#if false`, so the
// build that compiles is the synthesized `#else` with no active field. That
// empty branch must also emit `Self()` without `try` — the same warning-free
// guard as `EmptyProbe`, but for a synthesized empty branch rather than a
// fieldless struct. The `#if false` clause is dead, so it round-trips nothing.
@Serializable
@Deserializable
struct EmptyBranchProbe: Equatable {
  #if false
  var payload: Int
  #endif
}

// Many `#if` blocks guarding ONLY methods and computed properties — no stored
// field, no initializer — beside two real fields. The blocks are dropped from
// the emitted segments AND pruned from the init-resolution enumeration, so the
// derive stays a single build rather than expanding a 2^12 cartesian over the
// helper blocks (which would hang or hit the `.conditional` cap). That this
// derives quickly and round-trips `first`/`second` is the guard.
@Serializable
@Deserializable
struct HelperOnlyConditionalProbe: Equatable {
  var first: Int
  var second: Int
  #if true
  func h0() {}
  #endif
  #if true
  func h1() {}
  #endif
  #if true
  func h2() {}
  #endif
  #if true
  func h3() {}
  #endif
  #if true
  func h4() {}
  #endif
  #if true
  func h5() {}
  #endif
  #if true
  var c6: Int { 0 }
  #endif
  #if true
  var c7: Int { 0 }
  #endif
  #if true
  var c8: Int { 0 }
  #endif
  #if true
  var c9: Int { 0 }
  #endif
  #if true
  var c10: Int { 0 }
  #endif
  #if true
  var c11: Int { 0 }
  #endif

  static func == (lhs: HelperOnlyConditionalProbe,
                  rhs: HelperOnlyConditionalProbe) -> Bool {
    lhs.first == rhs.first && lhs.second == rhs.second
  }
}

// Nine INDEPENDENT `#if` stored fields — a deserialize branch product of
// 2^9 = 512, past the 256 cap — under `@Serializable` ALONE. Serialize emits a
// LINEAR field-count accumulator and `#if`-guarded writes, not the cartesian
// `Self(…)` the cap guards, so the cap must NOT block it: the branch product
// is a deserialize-only limit. That this SERIALIZE-only struct derives (the
// same shape `@Deserializable` diagnoses `.conditional`, proven in the
// expansion tests) is the guard. All clauses are `#if true`, so it writes all
// nine fields.
@Serializable
struct ManyConditionalSerializeProbe {
  #if true
  var f1: Int
  #endif
  #if true
  var f2: Int
  #endif
  #if true
  var f3: Int
  #endif
  #if true
  var f4: Int
  #endif
  #if true
  var f5: Int
  #endif
  #if true
  var f6: Int
  #endif
  #if true
  var f7: Int
  #endif
  #if true
  var f8: Int
  #endif
  #if true
  var f9: Int
  #endif
}

// A `@available(*, deprecated)` TYPE. A bare `extension DeprecatedProbe: …`
// references the deprecated type and WARNS ("'DeprecatedProbe' is deprecated"),
// which the warning-free build rejects; the derive must copy the type's
// `@available` onto BOTH conformance extensions so they compile warning-free.
// That this whole target still builds warning-free — with the derived
// extensions guarded by the same availability — is the guard.
@available(*, deprecated)
@Serializable
@Deserializable
struct DeprecatedProbe: Equatable {
  var x: Int
}

// A struct with a `@available(*, deprecated)` STORED FIELD, derived
// `@Deserializable` ONLY. Deserialize passes the field as a memberwise-init
// argument (`Self(x: …)`), which is not an access and so does not warn — the
// `@Serializable` side, which would read `self.x`, is the one the derive
// rejects. That this target builds warning-free WITH the deserialize
// conformance derived over a deprecated field is the guard; it is not
// `@Serializable`, so `roundtrip` cannot serialize it and the test decodes it
// directly.
@Deserializable
struct DeprecatedFieldProbe: Equatable {
  @available(*, deprecated) var x: Int
}

// A `@available(*, deprecated)` TYPE with a matching `@available(*,
// deprecated)` custom init. The custom init suppresses the synthesized
// memberwise init, so `@Deserializable` must call THIS init as `Self(x: …)`.
// Its deprecation is covered by the type's — the derived extension is emitted
// `@available(*, deprecated)` too, so the call sits inside a deprecated context
// and raises no deprecation warning. That this target builds warning-free with
// the deserialize conformance derived over the deprecated init is the guard.
// (`x` is not itself deprecated, so the `@Serializable` read of `self.x` stays
// warning-free and the value round-trips.)
@available(*, deprecated)
@Serializable
@Deserializable
struct DeprecatedInitProbe: Equatable {
  var x: Int

  @available(*, deprecated)
  init(x: Int) {
    self.x = x
  }
}

// A `@available(*, deprecated, message: "type")` TYPE with a `@available(*,
// deprecated, message: "init")` custom init — the two deprecations spell
// DIFFERENT messages. The custom init suppresses the synthesized memberwise
// init, so `@Deserializable` must call THIS init as `Self(x: …)`. The derived
// extension is emitted `@available(*, deprecated, message: "type")`, and Swift
// suppresses the `Self(x: …)` deprecation warning inside a deprecated context
// REGARDLESS of the message, so the call is warning-free even though the two
// messages differ. Coverage is by deprecation KIND, not exact gate text; this
// target building warning-free is the guard. Before the fix the exact-text
// gate comparison left the init UNCOVERED, so `@Deserializable` fired
// `.initializer` and no conformance was emitted — the round-trip below then
// failed to compile.
@available(*, deprecated, message: "type")
@Serializable
@Deserializable
struct DeprecatedMessageProbe: Equatable {
  var x: Int

  @available(*, deprecated, message: "init")
  init(x: Int) {
    self.x = x
  }
}

// An `@available(*, unavailable)` TYPE. A bare extension over it is a hard
// ERROR, not merely a warning — so before the fix this shape did not compile at
// all. The copied `@available(*, unavailable)` on each extension makes the
// conformance track the type's unavailability, so the target builds. It is
// never instantiated (an unavailable type cannot be), so no round-trip runs; it
// exists purely as a compile guard.
@available(*, unavailable)
@Serializable
@Deserializable
struct UnavailableProbe: Equatable {
  var x: Int
}

// A platform-gated TYPE — `@available(macOS 10.0, *)`. The derive copies the
// gate verbatim onto each extension so the conformance is available exactly
// where the type is; the deployment target satisfies the gate, so it derives
// and round-trips.
@available(macOS 10.0, *)
@Serializable
@Deserializable
struct PlatformProbe: Equatable {
  var x: Int
}

// A platform-gated TYPE — `@available(macOS 10.0, iOS 13.0, *)` — with a custom
// init gated SAME-or-BROADER: `@available(macOS 10.0, *)`. The init names macOS
// at the type's floor and leaves iOS to its `*` fallback, so it is available
// everywhere the extension is (its macOS 10.0 floor and its iOS 13.0 floor
// included). The derive weighs coverage SEMANTICALLY per platform, not by exact
// gate text, so the broader init is a safe replacement: `@Deserializable` calls
// it as `Self(x: …)` and the target builds warning-free. Before the fix the
// exact-text gate comparison rejected the differing init spelling, fired
// `.initializer`, and emitted no conformance, so the round-trip did not compile.
@available(macOS 10.0, iOS 13.0, *)
@Serializable
@Deserializable
struct BroaderInitProbe: Equatable {
  var x: Int

  @available(macOS 10.0, *)
  init(x: Int) {
    self.x = x
  }
}

// A PLATFORM-scoped deprecation matched on both sides — the type and the custom
// init are both `@available(macOS, deprecated: 10.0)`. The custom init
// suppresses the synthesized memberwise init, so `@Deserializable` must call it
// as `Self(x: …)`. The derived extension inherits the type's macOS deprecation,
// so the call sits inside a macOS-deprecated context where Swift suppresses the
// init's deprecation warning — the deprecation is covered ON ITS PLATFORM. That
// this target builds warning-free is the guard: a build for macOS derives the
// conformance over the platform-deprecated init with no warning. (`x` is not
// deprecated, so the `@Serializable` read of `self.x` stays warning-free and the
// value round-trips.)
@available(macOS, deprecated: 10.0)
@Serializable
@Deserializable
struct PlatformDeprecatedInitProbe: Equatable {
  var x: Int

  @available(macOS, deprecated: 10.0)
  init(x: Int) {
    self.x = x
  }
}

// A derived type NESTED in a `@available(*, deprecated)` ENCLOSING type, whose
// custom init is `@available(*, deprecated)` to MATCH. The init suppresses the
// synthesized memberwise init, so `@Deserializable` must call THIS init as
// `Self(x: …)` — and a deprecated init is callable warning-free only from a
// deprecated context. The init-resolution analysis weighs the init's gate
// against the availability the generated extension carries: with the direct
// declaration alone, `Inner` has NO `@available`, so the deprecated init is
// UNCOVERED, `@Deserializable` fires `.initializer`, and no conformance is
// emitted — the round-trip below then fails to compile. Reading the ENCLOSING
// chain's `@available` (from the lexical context) into the gate covers the init
// — the enclosing deprecation is copied onto the extension, so the call sits in
// a deprecated context — and the conformance derives. That the derive covers a
// deprecated init under a deprecated ENCLOSING type and `Inner` round-trips
// warning-free is the guard; before reading the enclosing gate the derive
// diagnosed the init and emitted no `Deserializable`, so this did not compile.
@available(*, deprecated)
enum EnclosingDeprecatedProbe {
  @Serializable
  @Deserializable
  struct Inner: Equatable {
    var x: Int

    @available(*, deprecated)
    init(x: Int) {
      self.x = x
    }
  }
}

// A derived type NESTED in a generic ENCLOSING type whose OUTER parameter a
// field stores. `Inner` has no generic clause of its own, so a naive
// `extension EnclosingGenericProbe.Inner: Serializable` is UNCONDITIONAL and
// type-checks for every `T` — but the body's `field(…, self.value)` needs
// `T: Serializable` and `decode() as T` needs `T: Deserializable`, so the
// unconditional conformance FAILS to compile. The derive reads the enclosing
// `T` from the lexical context and, seeing a field mention it, emits the
// CONDITIONAL `extension EnclosingGenericProbe.Inner: … where T: …`. That the
// conformance derives over the ENCLOSING parameter and `Inner<Int>` round-trips
// is the guard; before the fix the unconditional conformance did not compile.
public struct EnclosingGenericProbe<T> {
  @Serializable
  @Deserializable
  public struct Inner: Equatable where T: Equatable {
    public var value: T

    public init(value: T) {
      self.value = value
    }
  }
}

// A concrete field whose written type is QUALIFIED and whose trailing member
// component happens to equal the enclosing generic parameter — `Namespace.T` in
// a `Holder<T>`. The field does NOT depend on `Holder`'s `T`: `Namespace.T` is
// a fully-qualified concrete type. A flat token scan would see the `.T` token
// and wrongly emit `extension Holder: … where T: …`, so `Holder<NonSerial>`
// would LOSE the conformance it should keep. The structural walk descends the
// base (`Namespace`) but not the trailing `.T`, so no parameter is mentioned
// and the conformance stays UNCONDITIONAL. That `Holder<NonSerial>` — whose
// `NonSerial` is neither `Serializable` nor `Deserializable` — still conforms
// and round-trips is the guard: an unconditional conformance holds for a
// non-conforming `T`, which a `where T: …` clause would have forbidden.
enum QualifiedNamespace {
  struct T: Serializable, Deserializable, Equatable {
    var payload: Int

    init(payload: Int) {
      self.payload = payload
    }

    func serialize<S>(into serializer: consuming S)
        throws(S.Failure) -> S
        where S: Serializer & ~Copyable & ~Escapable {
      var structure = (consume serializer).structure("T", fields: 1)
      try structure.field("payload", self.payload)
      return try structure.end()
    }

    static func deserialize<D>(from deserializer: inout D)
        throws(D.Failure) -> Self
        where D: Deserializer & ~Copyable & ~Escapable {
      try deserializer.structure("T", fields: 1)
      let value = try Self(payload: deserializer.decode())
      try deserializer.end()
      return value
    }
  }
}

// A non-`Serializable`, non-`Deserializable` element to instantiate the
// qualified-member holder with, proving the derived conformance is
// unconditional (a `where T: …` clause would reject this `T`).
struct NonSerial: Equatable {}

@Serializable
@Deserializable
struct QualifiedMemberProbe<T>: Equatable where T: Equatable {
  var value: QualifiedNamespace.T
}

// A field typed as a DEPENDENT MEMBER of a generic parameter — `T.Element` in
// `struct Box<T: Sequence>`. The body passes a `T.Element` to `field(…)` and
// decodes a `T.Element`, so `T.Element` ITSELF must conform; constraining the
// base `T` does not supply that and wrongly forbids a `Box<T>` whose ELEMENT
// alone is serializable. A dependent member is a LEGAL where-clause left side,
// so the derive emits `where T.Element: …` directly. That `Box<Array<Int>>`
// (whose `Element` is `Int`) COMPILES and round-trips is the real-compile
// guard: before the fix the base-`T` reduction (`where T: …`, requiring the
// non-conforming `Array<Int>` sequence itself to conform) rejected it.
@Serializable
@Deserializable
public struct DependentMemberProbe<T: Sequence>: Equatable
    where T.Element: Equatable {
  public var value: T.Element
}

// A field typed as a WRAPPED dependent member — `Array<T.Element>` in `struct
// Box<T: Sequence>`. The body serializes an `Array<T.Element>` and decodes one,
// whose conformance rests on `T.Element`, not the base `T`; constraining `T`
// wrongly forbids a `Box<T>` whose ELEMENT alone is serializable. The derive
// descends the array wrapper to the dependent member and emits `where
// T.Element: …` directly. That `Box<Array<Int>>` (whose `Element` is `Int`)
// COMPILES and round-trips is the real-compile guard: before the fix the
// wrapper reduced to the base `T` (`where T: …`, requiring the non-conforming
// `Array<Int>` sequence itself to conform) and rejected it.
@Serializable
@Deserializable
public struct WrappedDependentMemberProbe<T: Sequence>: Equatable
    where T.Element: Equatable {
  public var values: Array<T.Element>
}

// A struct with a `var x, y: Int` MULTI-BINDING line — SwiftSyntax annotates
// only the trailing `y` — and an EXTENSION adding a same-label overload
// `init(x: String, y: Int)`. The derive must propagate the shared `Int` to the
// earlier `x`, so the read is `decode() as Int` and the `Self(x:y:)` call
// resolves to the synthesized `init(x: Int, y: Int)` unambiguously. That this
// target builds with NO ambiguity is the guard: before the fix `x` carried no
// type, its read stayed a bare `decode()`, and `Self(x:y:)` was ambiguous
// between the `Int` and `String` inits.
@Serializable
@Deserializable
struct SharedBindingOverloadProbe: Equatable {
  var x, y: Int
}

extension SharedBindingOverloadProbe {
  init(x: String, y: Int) {
    self.x = Int(x) ?? 0
    self.y = y
  }
}

// A struct with a `var x, y: Int` MULTI-BINDING line and a MATCHING primary
// custom `init(x: Int, y: Int)`. The custom init suppresses the synthesized
// memberwise init, so `@Deserializable` must recognise it as a covering
// replacement — which needs the earlier `x`'s propagated `Int` type to prove
// parity. That this DERIVES (no `.initializer` diagnostic) and round-trips is
// the guard: before the fix `x` had no type, so the matching init was falsely
// rejected.
@Serializable
@Deserializable
struct SharedBindingInitProbe: Equatable {
  var x, y: Int

  init(x: Int, y: Int) {
    self.x = x
    self.y = y
  }
}

// A struct whose custom init reuses ONE generic parameter across fields of the
// SAME type — `var x: Int; var y: Int; init<U>(x: U, y: U)`. Both fields bind
// `U` to `Int`, a consistent binding, so the init covers and `Self(x: … as Int,
// y: … as Int)` type-checks. That this DERIVES and round-trips is the guard —
// the twin of the reject case (a `U` bound to two DIFFERENT types), which is
// diagnosed rather than emitted as an uncompilable call.
@Serializable
@Deserializable
struct RepeatedGenericInitProbe: Equatable {
  var x: Int
  var y: Int

  init<U>(x: U, y: U) {
    self.x = (x as? Int) ?? 0
    self.y = (y as? Int) ?? 0
  }
}

// A concrete namespace whose member type is NAMED for a generic parameter, to
// prove item 2's structural walk of an inferred initializer. `Namespace.T()`
// is a concrete symbol; its `.T` member is NOT a reference to `Holder`'s `T`.
enum InferredNamespace {
  struct T: Serializable, Deserializable, Equatable {
    var payload: Int

    init(payload: Int = 0) {
      self.payload = payload
    }

    func serialize<S>(into serializer: consuming S)
        throws(S.Failure) -> S
        where S: Serializer & ~Copyable & ~Escapable {
      var structure = (consume serializer).structure("T", fields: 1)
      try structure.field("payload", self.payload)
      return try structure.end()
    }

    static func deserialize<D>(from deserializer: inout D)
        throws(D.Failure) -> Self
        where D: Deserializer & ~Copyable & ~Escapable {
      try deserializer.structure("T", fields: 1)
      let value = try Self(payload: deserializer.decode())
      try deserializer.end()
      return value
    }
  }
}

// An INFERRED field initialised from a concrete qualified symbol whose member
// name equals the generic parameter — `var value = InferredNamespace.T()` in a
// `Holder<T>`. The field's inferred type is the CONCRETE `InferredNamespace.T`
// and needs no generic constraint. The inferred-initializer scan walks the
// expression STRUCTURALLY (like `references` walks a type), skipping the `.T`
// member of `InferredNamespace`, so it is NOT counted as a mention of the
// generic `T`. That this DERIVES with no `.inferred` diagnostic and round-trips
// is the guard: before the fix a flat token scan saw the `.T` token, read it as
// a mention of `T`, and wrongly raised `.inferred`.
@Serializable
@Deserializable
struct InferredQualifiedProbe<T>: Equatable {
  var value = InferredNamespace.T()
}

// A custom replacement initializer declared `throws(Never)`, which Swift treats
// as NONTHROWING — callable as the derive's `Self(…)` with no `try` the
// typed-throws context cannot absorb. The init-candidate check must accept it
// (item 3); before the fix the mere presence of a throws clause forced the
// `.initializer` diagnostic. That this DERIVES and round-trips is the guard.
@Serializable
@Deserializable
public struct NonthrowingInitProbe: Equatable {
  public var x: Int

  public init(x: Int) throws(Never) {
    self.x = x
  }
}

// A `@MainActor`-isolated TYPE. A global-actor-isolated type isolates its
// members, so a plainly-emitted `serialize`/`deserialize` would inherit that
// isolation and could NOT satisfy the NONISOLATED `Serializable`/
// `Deserializable` requirement — a Swift 6 conformance-isolation error that,
// before the fix, made this shape fail to compile. The derive detects the
// isolation and emits each witness `nonisolated`, restoring it to the
// requirement's isolation; the value type's `Sendable` stored property stays
// reachable from the nonisolated body. That this whole target builds
// WARNING-FREE — the swiftc-level guard the expansion golden cannot give —
// and round-trips is the guard.
@MainActor
@Serializable
@Deserializable
struct IsolatedProbe: Equatable {
  var x: Int
}

// A `@MainActor`-isolated TYPE whose fields spell the standard Sendable
// wrappers GENERICALLY — `Optional<Int>` / `Array<Int>` rather than the sugar
// `Int?` / `[Int]`. Each is Sendable under the same condition as its sugar, so
// the derive must recognize the generic spelling safe and emit `nonisolated`
// witnesses — before the fix these fell through the sugar-only allowlist and
// were diagnosed. That this target builds WARNING-FREE and round-trips is the
// guard.
@MainActor
@Serializable
@Deserializable
struct IsolatedGenericProbe: Equatable {
  var maybe: Optional<Int>
  var many: Array<Int>
}

// A `@available(*, deprecated)` TYPE with a `@available(*, deprecated)` STORED
// FIELD, derived on BOTH sides. Serialize reads `self.x`, which normally warns
// on a deprecated field and breaks a warning-free build — but the derived
// extension copies the type's `@available(*, deprecated)`, so the read sits in
// a DEPRECATED context where Swift suppresses the warning. The field's
// deprecation is thus COVERED by the enclosing type's, so the serialize side
// must derive (not diagnose `.deprecated`). That this target builds
// WARNING-FREE — the serialize `self.x` read inside the deprecated extension —
// and round-trips is the guard. Before the fix the serialize guard rejected the
// deprecated field unconditionally, so no `@Serializable` conformance was
// emitted and this round-trip did not compile.
@available(*, deprecated)
@Serializable
@Deserializable
struct DeprecatedFieldCoveredProbe: Equatable {
  @available(*, deprecated) var x: Int
}

// A generic struct whose field is written through a SAME-SCOPE typealias that
// hides the parameter — `typealias Value = T; var value: Value`. The written
// field type is only `Value`, no in-scope parameter, so a naive constraint walk
// emits NO `where T: …` and the unconditional `extension Aliased: Serializable`
// serializes an unconstrained `T` that fails to type-check. The derive must
// EXPAND `Value` to `T` before the walk and emit the CONDITIONAL `where T: …`.
// That `AliasedFieldProbe<Int>` COMPILES and round-trips is the real-compile
// guard: before the fix the hidden `T` went unconstrained and the invalid
// unconditional conformance did not compile.
@Serializable
@Deserializable
public struct AliasedFieldProbe<T>: Equatable where T: Equatable {
  public typealias Value = T
  public var value: Value
}

// A generic struct whose field is written through a SAME-SCOPE typealias to a
// WRAPPED dependent member — `typealias Values = Array<T.Element>; var values:
// Values`. Expanding the alias must compose with the wrapped-dependent walk:
// `Values` becomes `Array<T.Element>`, which descends to the dependent member
// `T.Element`, so the derive emits `where T.Element: …`. That
// `AliasedDependentProbe<Array<Int>>` (whose `Element` is the conforming `Int`)
// COMPILES and round-trips — though the SEQUENCE `Array<Int>` need not itself
// conform — is the guard.
@Serializable
@Deserializable
public struct AliasedDependentProbe<T: Sequence>: Equatable
    where T.Element: Equatable {
  public typealias Values = Array<T.Element>
  public var values: Values
}

// A tiny concrete format, in the CLIENT scope so it drives a macro-derived
// value through the re-exported `Serializer`/`Deserializer` surface end to
// end. It is fixed-width: an integer is its little-endian eight bytes and a
// structure is its children back to back — enough to prove the derived
// conformances round-trip. (The `Decant` test target has its own richer
// version; this one exists so the client target, which never imports `Decant`
// directly, still runs a round-trip.)
private struct ClientSerializer: Serializer, ~Copyable {
  typealias Failure = DecantError

  var sink: ArraySink

  init(_ sink: consuming ArraySink) {
    self.sink = sink
  }

  consuming func finish() -> ArraySink {
    sink
  }

  mutating func serialize(_ value: Bool) throws(DecantError) {
    try sink.append(value ? 1 : 0)
  }

  mutating func serialize<T: FixedWidthInteger>(_ value: T)
      throws(DecantError) {
    let word = Int64(truncatingIfNeeded: value).littleEndian
    try sink.append(withUnsafeBytes(of: word) { Array($0) })
  }

  mutating func serialize(_ value: Double) throws(DecantError) {
    try sink.append(withUnsafeBytes(of: value.bitPattern.littleEndian) {
      Array($0)
    })
  }

  mutating func serialize(_ value: String) throws(DecantError) {
    try sink.append(Array(value.utf8))
  }

  mutating func serialize(bytes: some Sequence<UInt8>) throws(DecantError) {
    try sink.append(Array(bytes))
  }

  mutating func null() throws(DecantError) {
    try sink.append(0)
  }

  mutating func some() throws(DecantError) {
    try sink.append(1)
  }

  consuming func sequence(count: Int?) -> ClientSubSerializer {
    // Write the element count as one little-endian word so the deserializer's
    // `count()` reads it back; a known count is always supplied here (the
    // derive never streams), so the `nil` case writes zero.
    var this = self
    try? this.serialize(Int64(count ?? 0))
    return ClientSubSerializer(this)
  }

  consuming func structure(_ name: StaticString, fields count: Int)
      -> ClientSubSerializer {
    ClientSubSerializer(self)
  }
}

private struct ClientSubSerializer: SequenceSerializer, StructureSerializer,
    ~Copyable {
  typealias Failure = DecantError
  typealias Parent = ClientSerializer

  var serializer: ClientSerializer?

  init(_ serializer: consuming ClientSerializer) {
    self.serializer = consume serializer
  }

  mutating func element<T: Serializable>(_ value: borrowing T)
      throws(DecantError) {
    serializer = try value.serialize(into: serializer.take()!)
  }

  mutating func field<T: Serializable>(_ name: StaticString,
                                       _ value: borrowing T)
      throws(DecantError) {
    serializer = try value.serialize(into: serializer.take()!)
  }

  consuming func end() throws(DecantError) -> ClientSerializer {
    var this = self
    return this.serializer.take()!
  }
}

private struct ClientDeserializer: Deserializer {
  typealias Failure = DecantError

  let storage: Array<UInt8>
  var position: Int

  init(_ bytes: Array<UInt8>) {
    storage = bytes
    position = 0
  }

  mutating func word() throws(DecantError) -> UInt64 {
    guard position + 8 <= storage.count else { throw .truncated }
    defer { position += 8 }
    var value: UInt64 = 0
    for index in 0 ..< 8 {
      value |= UInt64(storage[position + index]) << (8 * index)
    }
    return value
  }

  mutating func byte() throws(DecantError) -> UInt8 {
    guard position < storage.count else { throw .truncated }
    defer { position += 1 }
    return storage[position]
  }

  mutating func integer<T: FixedWidthInteger>(_: T.Type)
      throws(DecantError) -> T {
    T(truncatingIfNeeded: Int64(bitPattern: try word()))
  }

  mutating func bool() throws(DecantError) -> Bool {
    try byte() != 0
  }

  mutating func double() throws(DecantError) -> Double {
    Double(bitPattern: try word())
  }

  mutating func string() throws(DecantError) -> String {
    ""
  }

  mutating func bytes() throws(DecantError) -> Array<UInt8> {
    []
  }

  mutating func some() throws(DecantError) -> Bool {
    try byte() != 0
  }

  mutating func count() throws(DecantError) -> Int {
    Int(try word())
  }

  mutating func structure(_ name: StaticString, fields count: Int)
      throws(DecantError) {}

  mutating func end() throws(DecantError) {}
}

private func roundtrip<T: Serializable & Deserializable>(_ value: T)
    throws(DecantError) -> T {
  var serializer = ClientSerializer(ArraySink())
  serializer = try value.serialize(into: serializer)
  var deserializer = ClientDeserializer(serializer.finish().bytes)
  return try deserializer.decode(T.self)
}

struct ClientRoundTripTests {
  @Test func `a keyword-named field round-trips through the derive`() throws {
    let probe = KeywordProbe(self: 1, init: 2, x: 3)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a raw-named field round-trips through the derive`() throws {
    let probe = RawNameProbe(`foo bar`: 4, `quote"x`: 5)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an implicitly-unwrapped optional field round-trips`() throws {
    let probe = IUOProbe(x: 6)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an underscore-named field round-trips through the derive`()
      throws {
    let probe = UnderscoreProbe(`_`: 1, x: 2)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a raw-named type round-trips through the derive`() throws {
    let probe = `Quote"Type`(x: 8)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a type named for the generic parameter round-trips`() throws {
    let probe = D(x: 9)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a built-in-attributed field round-trips through the derive`()
      throws {
    let probe = BuiltinAttributeProbe(x: 6, y: 7)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a matching user init round-trips through the derive`() throws {
    let probe = MatchingInitProbe(value: 7)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a lone matching conditional init round-trips through the derive`()
      throws {
    let probe = ConditionalMatchingInitProbe(value: 8, tag: 9)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a type parameter named S round-trips through the derive`()
      throws {
    let probe = SerializerCollisionProbe<Never>(x: 10)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a type parameter named D round-trips through the derive`()
      throws {
    let probe = DeserializerCollisionProbe<Never>(x: 11)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a generic type's conditional conformance round-trips`() throws {
    let probe = GenericFieldProbe<Int>(value: 10)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a two-parameter generic type round-trips through the derive`()
      throws {
    let probe = GenericPairProbe<Int, Int>(a: 11, b: 12)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a wrapper field's parameter-constrained conformance compiles`()
      throws {
    // `HolderProbe<Int>` conforms via the LEGAL `where T: Serializable` the
    // derive lowered `Wrapper<T>` to — an applied `where Wrapper<T>: …` would
    // not type-check. That this COMPILES (the client target builds) and
    // round-trips is the real-compile guard the expansion golden cannot give.
    let probe = HolderProbe<Int>(value: Wrapper(payload: 99))
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a container field's lowered element constraint round-trips`()
      throws {
    // `BagProbe<Int>` conforms via `where T: Serializable`, the element
    // parameter its `Array<T>` (and nested `Array<Optional<T>>`) fields lower
    // to. That it COMPILES and round-trips proves the lowered element clause is
    // legal and sufficient.
    let probe = BagProbe<Int>(items: [1, 2, 3], maybe: [4, nil, 6])
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a type nested in a generic context round-trips`() throws {
    let probe = NestingProbe<Never, Never>.Inner(x: 12)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a doubly-nested type round-trips through the derive`() throws {
    let probe = NestingProbe<Never, Never>.Middle<Never>.Leaf(y: 13)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a conditional field round-trips through the derive`() throws {
    // `t` is under `#if true` (present); `skip` under `#if false` (absent), so
    // the memberwise init is `ConditionalProbe(a:t:b:)`.
    let probe = ConditionalProbe(a: 14, t: 15, b: 16)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an if-else active clause round-trips through the derive`()
      throws {
    let probe = IfElseActiveProbe(a: 17, live: 18, b: 19)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an if-else inactive clause round-trips through the derive`()
      throws {
    let probe = IfElseInactiveProbe(a: 20, chosen: 21, b: 22)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a defaulted conditional init round-trips through the derive`()
      throws {
    let probe = DefaultedConditionalInitProbe(kept: 23)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a no-availability init round-trips through the derive`() throws {
    let probe = MatchingInitAvailabilityProbe(x: 24)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func
      `a mutually-exclusive same #if field round-trips through the derive`()
      throws {
    let probe = ExclusiveSameFieldProbe(x: 25)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func
      `a same-#if conditional-field init round-trips through the derive`()
      throws {
    let probe = ConditionalInitProbe(base: 26, x: 27)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an overloaded same-label init round-trips through the derive`()
      throws {
    let probe = OverloadedInitProbe(x: 28)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an extension init overload round-trips through the derive`()
      throws {
    let probe = ExtensionOverloadProbe(x: 29)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a tuple field disambiguates an extension overload`() throws {
    let probe = TupleOverloadProbe(x: 30, y: 31)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func
      `a type in a generic extension stores the enclosing parameter`() throws {
    let probe = EnclosingExtensionProbe<Int>.Inner(value: 32)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an empty struct round-trips through the derive`() throws {
    let probe = EmptyProbe()
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an empty conditional branch round-trips through the derive`()
      throws {
    let probe = EmptyBranchProbe()
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `helper-only #if blocks round-trip through the derive`() throws {
    let probe = HelperOnlyConditionalProbe(first: 29, second: 30)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a serialize-only over-cap struct serializes through the derive`()
      throws {
    let probe = ManyConditionalSerializeProbe(f1: 1, f2: 2, f3: 3, f4: 4,
                                              f5: 5, f6: 6, f7: 7, f8: 8, f9: 9)
    let serializer = try probe.serialize(into: ClientSerializer(ArraySink()))
    #expect(serializer.finish().bytes.count == 9 * 8)
  }

  // The test is itself `@available(*, deprecated)` so its use of the deprecated
  // type is warning-free; the guard is that the derived conformances exist and
  // round-trip on a deprecated type.
  @available(*, deprecated)
  @Test func `a deprecated type round-trips through the derive`() throws {
    let probe = DeprecatedProbe(x: 31)
    #expect(try roundtrip(probe) == probe)
  }

  @available(macOS 10.0, *)
  @Test func `a platform-gated type round-trips through the derive`() throws {
    let probe = PlatformProbe(x: 32)
    #expect(try roundtrip(probe) == probe)
  }

  // The type is `@available(macOS 10.0, iOS 13.0, *)`, so the test carries the
  // same gate to use it warning-free; the guard is that the derive covers the
  // SAME-or-BROADER `@available(macOS 10.0, *)` init semantically per platform —
  // its `*` fallback spans the type's iOS floor — and round-trips. Before the
  // fix the exact-text gate comparison rejected the init, so this did not
  // compile.
  @available(macOS 10.0, iOS 13.0, *)
  @Test func `a broader-gated init round-trips through the derive`() throws {
    let probe = BroaderInitProbe(x: 33)
    #expect(try roundtrip(probe) == probe)
  }

  // The test carries `@available(macOS, deprecated: 10.0)` so its use of the
  // platform-deprecated type and init is warning-free on macOS; the guard is
  // that the derived deserialize covers the init's deprecation ON ITS PLATFORM —
  // the type is deprecated on macOS too, so the `Self(x: …)` call sits in a
  // macOS-deprecated context — and round-trips warning-free.
  @available(macOS, deprecated: 10.0)
  @Test func
      `a platform-deprecated init round-trips through the derive`() throws {
    let probe = PlatformDeprecatedInitProbe(x: 40)
    #expect(try roundtrip(probe) == probe)
  }

  // The nonisolated witnesses let a `@MainActor`-isolated type conform and
  // round-trip. The test is itself `@MainActor` to build and compare the
  // isolated value; the derived `serialize`/`deserialize` are nonisolated, so
  // `roundtrip` calls them freely off the actor.
  @MainActor
  @Test func `a global-actor type round-trips through the derive`() throws {
    let probe = IsolatedProbe(x: 34)
    #expect(try roundtrip(probe) == probe)
  }

  @MainActor
  @Test func
      `a global-actor type with generic wrappers round-trips`() throws {
    let probe = IsolatedGenericProbe(maybe: 35, many: [36, 37])
    #expect(try roundtrip(probe) == probe)
  }

  // The test is itself `@available(*, deprecated)` so its use of the deprecated
  // type and init is warning-free; the guard is that the derived deserialize —
  // calling the deprecated `Self(x: …)` from the deprecated extension — exists
  // and round-trips.
  @available(*, deprecated)
  @Test func `a deprecated-init type round-trips through the derive`() throws {
    let probe = DeprecatedInitProbe(x: 38)
    #expect(try roundtrip(probe) == probe)
  }

  // The test is itself `@available(*, deprecated)` so its use of the deprecated
  // type and init is warning-free; the guard is that the derived deserialize
  // covers the init by deprecation KIND — the init's `message: "init"` differs
  // from the type's `message: "type"` — and round-trips. Before the fix the
  // exact-text gate comparison rejected the init, so this did not compile.
  @available(*, deprecated)
  @Test func `a deprecated-init type with a differing message round-trips`()
      throws {
    let probe = DeprecatedMessageProbe(x: 41)
    #expect(try roundtrip(probe) == probe)
  }

  // The test is itself `@available(*, deprecated)` so its use of the type
  // nested in a deprecated enclosing type is warning-free; the guard is that
  // the derived conformances INHERIT the enclosing `@available(*, deprecated)`
  // (so the target builds warning-free) and round-trip.
  @available(*, deprecated)
  @Test func `a type in a deprecated enclosing type round-trips`() throws {
    let probe = EnclosingDeprecatedProbe.Inner(x: 39)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a type storing an enclosing generic parameter round-trips`()
      throws {
    let probe = EnclosingGenericProbe<Int>.Inner(value: 40)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a qualified-member field keeps an unconditional conformance`()
      throws {
    // `QualifiedMemberProbe<NonSerial>` conforms though `NonSerial` is neither
    // `Serializable` nor `Deserializable`: the field is the concrete
    // `QualifiedNamespace.T`, so the conformance is unconditional and the `T`
    // parameter is unconstrained. A `where T: …` clause would reject this.
    let value = QualifiedNamespace.T(payload: 41)
    let probe = QualifiedMemberProbe<NonSerial>(value: value)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a dependent-member field constrains the member directly`()
      throws {
    // `DependentMemberProbe<Array<Int>>` conforms via `where T.Element: …`,
    // the dependent member the `T.Element` field lowers to. Its `Element` is
    // the conforming `Int`, so it round-trips even though the SEQUENCE
    // `Array<Int>` need not itself conform. A base-`T` reduction would have
    // demanded that and rejected this.
    let probe = DependentMemberProbe<Array<Int>>(value: 42)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `an inferred qualified-symbol field derives unconstrained`()
      throws {
    // `InferredQualifiedProbe<NonSerial>` derives though its inferred field is
    // initialised from `InferredNamespace.T()`, whose `.T` member equals the
    // generic parameter: the structural walk of the initializer skips the
    // qualified member, so no `.inferred` diagnostic fires. A flat token scan
    // would have counted the `.T` and rejected it.
    let probe = InferredQualifiedProbe<NonSerial>()
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a throws(Never) replacement init round-trips`() throws {
    // `NonthrowingInitProbe`'s custom `init(x:) throws(Never)` is nonthrowing,
    // so the derive's `Self(x: …)` type-checks and no `.initializer` diagnostic
    // fires. A genuine `throws` init would still be diagnosed.
    let probe = NonthrowingInitProbe(x: 43)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func
      `a deprecated stored field deserializes through the derive`() throws {
    // A `@Deserializable`-only struct over a deprecated stored field derives
    // (the serialize side would read `self.x` and warn, but deserialize passes
    // `x` as a memberwise-init argument, which does not). It is not
    // `@Serializable`, so it is decoded directly rather than round-tripped: one
    // little-endian word decodes to `x`. The `Equatable` compare and the
    // `x:`-labeled init argument are not member accesses, so the test is
    // warning-free too.
    var deserializer =
        ClientDeserializer([33, 0, 0, 0, 0, 0, 0, 0])
    let probe = try deserializer.decode(DeprecatedFieldProbe.self)
    #expect(probe == DeprecatedFieldProbe(x: 33))
  }

  @Test func `a wrapped dependent-member field constrains the member directly`()
      throws {
    // `WrappedDependentMemberProbe<Array<Int>>` conforms via `where
    // T.Element: …`, the dependent member its `Array<T.Element>` field descends
    // to. Its `Element` is the conforming `Int`, so it round-trips even though
    // the SEQUENCE `Array<Int>` need not itself conform. A base-`T` reduction
    // would have demanded that and rejected this.
    let probe = WrappedDependentMemberProbe<Array<Int>>(values: [44, 45])
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a shared-binding overload resolves unambiguously`() throws {
    // `SharedBindingOverloadProbe`'s `var x, y: Int` line gives `x` its shared
    // `Int` type, so `Self(x:y:)` resolves to the `Int` init over the
    // extension's `String` overload. Before the fix the untyped `x` left the
    // call ambiguous and this did not compile.
    let probe = SharedBindingOverloadProbe(x: 46, y: 47)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a shared-binding matching init round-trips`() throws {
    // `SharedBindingInitProbe`'s matching `init(x: Int, y: Int)` covers the
    // `var x, y: Int` line only once `x` carries the propagated `Int`. Before
    // the fix the untyped `x` broke parity and the init was falsely rejected.
    let probe = SharedBindingInitProbe(x: 48, y: 49)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a repeated generic init with one field type round-trips`()
      throws {
    // `RepeatedGenericInitProbe`'s `init<U>(x: U, y: U)` binds `U` to `Int` for
    // both fields — a consistent binding — so it covers and round-trips. The
    // reject twin (a `U` bound to two different types) is diagnosed instead.
    let probe = RepeatedGenericInitProbe(x: 50, y: 51)
    #expect(try roundtrip(probe) == probe)
  }

  // The test is itself `@available(*, deprecated)` so its use of the deprecated
  // type is warning-free; the guard is that BOTH derives exist over a
  // deprecated field under a deprecated type — serialize's `self.x` read is
  // covered by the extension's copied `@available(*, deprecated)` — and
  // round-trip.
  @available(*, deprecated)
  @Test func `a deprecated field under a deprecated type round-trips`() throws {
    let probe = DeprecatedFieldCoveredProbe(x: 52)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a same-scope alias field constrains the hidden parameter`()
      throws {
    // `AliasedFieldProbe<Int>` conforms via `where T: …`, the parameter its
    // `typealias Value = T` field hides. That it COMPILES and round-trips is
    // the real-compile guard: before the alias expansion the hidden `T` went
    // unconstrained and the unconditional conformance did not type-check.
    let probe = AliasedFieldProbe<Int>(value: 53)
    #expect(try roundtrip(probe) == probe)
  }

  @Test func `a same-scope alias to a wrapped dependent member constrains it`()
      throws {
    // `AliasedDependentProbe<Array<Int>>` conforms via `where T.Element: …`:
    // the alias `Values = Array<T.Element>` expands and the array wrapper
    // descends to the dependent member. Its `Element` is the conforming `Int`,
    // so it round-trips though the SEQUENCE `Array<Int>` need not conform.
    let probe = AliasedDependentProbe<Array<Int>>(values: [54, 55])
    #expect(try roundtrip(probe) == probe)
  }
}
