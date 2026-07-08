// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@_spi(RawSyntax) import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// The diagnostics the derive macros raise when applied to an unsupported
/// declaration.
///
/// The macros are syntactic: they see spellings, not resolved types, so they
/// refuse anything but a struct up front and leave the type-checker to verify
/// each field's `Serializable`/`Deserializable` conformance.
internal enum DecantDiagnostic: String, DiagnosticMessage {
  case nonstruct
  case lazy
  case constant
  case wrapper
  case deprecated
  case initializer
  case conditional
  case isolation
  case inferred

  internal var message: String {
    switch self {
    case .nonstruct:
      "@Serializable / @Deserializable can only be applied to a struct"
    case .lazy:
      "@Serializable / @Deserializable cannot derive a `lazy` property: a "
        + "lazy var has a mutating getter and is not a memberwise-init "
        + "parameter"
    case .constant:
      "@Serializable / @Deserializable cannot derive an initialized `let` "
        + "(not a memberwise-init parameter); make it a `var` or remove the "
        + "initializer"
    case .wrapper:
      "@Serializable / @Deserializable cannot derive a property-wrapper-backed "
        + "property; its memberwise-init parameter is the wrapper storage, not "
        + "the wrapped value"
    case .deprecated:
      "@Serializable cannot derive a deprecated stored property: the generated "
        + "serialize reads `self.<field>`, which warns on every access to a "
        + "deprecated member and so breaks a warning-free build; exclude the "
        + "field or drop its @available(*, deprecated). @Deserializable alone "
        + "is fine — it passes the field as a memberwise-init argument"
    case .initializer:
      "@Deserializable requires the synthesized memberwise initializer, which "
        + "is suppressed by a custom initializer; declare a matching "
        + "init(<field>: …) or remove the custom initializer"
    case .conditional:
      "@Serializable / @Deserializable cannot derive this many independent "
        + "`#if` blocks over stored properties: the per-branch initializer "
        + "calls are the cartesian product of the blocks' clauses, which here "
        + "exceeds the emission cap; reduce the conditional stored properties"
    case .isolation:
      "@Serializable / @Deserializable cannot derive a global-actor-isolated "
        + "type whose stored property may be non-Sendable: the witnesses are "
        + "nonisolated (the requirements are), so the generated `self.<field>` "
        + "read and memberwise-init call are rejected unless every field is "
        + "Sendable, which the syntactic macro cannot confirm; make the field "
        + "type Sendable, drop the global actor, or write the conformance by "
        + "hand"
    case .inferred:
      "@Serializable / @Deserializable cannot derive a stored property whose "
        + "type is inferred from an initializer that mentions a generic "
        + "parameter: the conditional conformance is constrained on each "
        + "field's WRITTEN type, and this field has none to constrain, so the "
        + "generated body would fail to type-check; add an explicit type "
        + "annotation naming the generic parameter"
    }
  }

  internal var diagnosticID: MessageID {
    MessageID(domain: "DecantMacros", id: rawValue)
  }

  internal var severity: DiagnosticSeverity {
    .error
  }
}

/// The stored properties, in declaration order, a derive emits reads and writes
/// for.
///
/// A stored property is a `var`/`let` binding whose accessor block, if any,
/// holds only `willSet`/`didSet` observers; a computed property (a getter, or
/// an accessor list with `get`/`set`/`_read`/`_modify`/`unsafeAddress`/
/// `unsafeMutableAddress`) is skipped. Several bindings on one `let a, b: Int`
/// line expand to one entry each, as does a tuple binding — `var (x, y):
/// (Int, Int)`, whose components Swift stores separately.
internal enum DecantModel {
  /// Which side of the round-trip a collection serves. Serialize reads
  /// `self.<name>` (nonmutating) and so accepts any stored property, including
  /// an initialized `let`; deserialize passes each field to the synthesized
  /// memberwise init, which omits an initialized `let`, so that shape is
  /// rejected only here.
  internal enum Direction {
    case serialize
    case deserialize
  }

  /// One stored property's name and, when it is written, its declared type.
  ///
  /// The name is all a derive's emission needs: the write reads `self.<name>`
  /// and the read passes its `decode` to the memberwise-init argument labelled
  /// `<name>`, whose parameter supplies the type. The macro is syntactic and
  /// never resolves the property's type.
  ///
  /// `type` is the trimmed spelling of the field's written type annotation, or
  /// `nil` when none is written (an inferred `var count = 0`) or the binding is
  /// a tuple whose per-element types the syntactic macro does not split out. It
  /// exists only so `matches` can prove a user init's parameter types equal the
  /// fields': a `nil` type is unprovable and forces a non-match (the safe
  /// `.initializer` diagnostic).
  ///
  /// `coercion` is the spelling the read's `decode() as <coercion>` cast
  /// annotates with — normally `type`, but an implicitly-unwrapped optional
  /// `T!` is normalized to the optional `T?`: `as T!` is not a legal coercion
  /// target, yet the memberwise-init parameter (still `T!`) accepts a `T?`
  /// value, and `Optional` is `Deserializable`. An opaque `some P` field
  /// carries NO coercion at all — `as some P` is not a legal coercion target —
  /// so the read stays a bare `decode()` the memberwise-init parameter's opaque
  /// type drives, matching the type-less fallback. Matching (`passes`) keeps
  /// the verbatim `type` so an init parameter spelled `T!` still equals the
  /// field.
  internal struct Field {
    internal let name: String
    internal let type: String?
    internal let coercion: String?
  }

  /// A run of stored properties sharing a compilation condition, in declaration
  /// order.
  ///
  /// A member under no `#if` is an `unconditional` run; a member under an
  /// `#if`/`#elseif`/`#else` is one `conditional` block whose clauses the
  /// derive mirrors verbatim into the generated code — the plugin cannot
  /// evaluate a condition (it arrives unresolved), so it re-emits the guard and
  /// lets the compiler activate the matching branch. A clause's body recurses
  /// through `Segment` again, so a nested `#if` is supported.
  internal enum Segment {
    case unconditional(Array<Field>)
    case conditional(Array<Clause>)
  }

  /// One clause of an `#if`/`#elseif`/`#else` block: the pound keyword
  /// spelling, the condition copied verbatim (`nil` for the conditionless
  /// `#else`), and the stored properties the clause guards, as their own
  /// segment list so a nested `#if` recurses.
  internal struct Clause {
    internal let pound: String
    internal let condition: String?
    internal let segments: Array<Segment>
  }

  /// The stored properties of a struct, split into `segments` that mirror its
  /// `#if` structure. The serialize/deserialize emission walks the segments
  /// directly.
  internal struct Model {
    internal let segments: Array<Segment>
  }

  /// Extracts the stored properties of `declaration`, mirroring its `#if`
  /// structure in the returned segments, or raises `.nonstruct` if it is not a
  /// struct (and the other field diagnostics as they arise).
  internal static func model(of declaration: some DeclGroupSyntax,
                             for direction: Direction,
                             in context: some MacroExpansionContext,
                             at node: AttributeSyntax) -> Model? {
    guard declaration.is(StructDeclSyntax.self) else {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.nonstruct))
      return nil
    }

    // The generated conformance extension copies the type's own `@available`
    // AND the enclosing type chain's (see `available`), so a serialize read of
    // `self.<field>` runs inside a context carrying that whole gate. When the
    // gate DEPRECATES a field's platform — the enclosing type is deprecated —
    // the read sits in a deprecated context where Swift suppresses the
    // deprecation warning, so the field's deprecation is COVERED and the
    // serialize guard must not fire; a NON-deprecated context still warns and
    // the guard fires. This mirrors the deprecated-INIT coverage: the same
    // `Availability` model, weighed the same way.
    let deprecation = availability(available(declaration)
        + available(enclosing: context.lexicalContext))
    guard let segments = collect(declaration.memberBlock.members,
                                 for: direction, under: deprecation,
                                 in: context, at: node) else {
      return nil
    }
    // A global-actor-isolated type isolates its stored properties, but the
    // emitted witnesses are `nonisolated` (the requirements are), and Swift
    // lets a nonisolated body read an isolated stored property — and call the
    // memberwise init — only when its value is `Sendable`. Sendability is a
    // semantic conformance the syntactic macro cannot see, so it approximates:
    // a field whose written type is not a recognizably-`Sendable` standard
    // spelling (`safe`) may be non-Sendable, which would make the generated
    // `self.<name>` read (serialize) and `Self(<name>: …)` call (deserialize)
    // fail to compile from the nonisolated witness. Diagnose that up front — a
    // clear guide beats a silent actor-isolation error — rather than derive
    // code the compiler rejects. An all-`safe` isolated type (the common
    // `@MainActor` case) derives unchanged. A field of no written type is left
    // to the compiler, as its spelling gives nothing to judge.
    if isolated(declaration), risky(segments) {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.isolation))
      return nil
    }
    // The single generic environment the derive reasons over: the type's own
    // clause plus every parameter an enclosing type OR extension contributes
    // (see `environment`). The inferred-field guard, the init-candidate check,
    // and the conformance's `where` clause all consume it, so the guard sees
    // exactly the parameters the constraint builder does.
    let scope = environment(of: declaration, enclosing: context.lexicalContext)
    // The conditional conformance a generic type derives is constrained on each
    // serialized field's WRITTEN type (see `constrained`). A field that infers
    // its type from an initializer mentioning a generic parameter — `struct
    // Box<T: Defaulted> { var value = T.defaultValue }`, or an enclosing
    // parameter `struct Outer<T: Defaulted> { @Serializable struct Inner { var
    // value = T.defaultValue } }` — has no written type to constrain, yet the
    // generated body reads and reconstructs a `T` needing `T: Serializable`/
    // `Deserializable`, so an unconstrained conformance would fail to
    // type-check downstream. Deriving the constraint from the initializer
    // expression is unreliable (the syntactic macro cannot resolve
    // `T.defaultValue`'s type), so diagnose the field up front — a clear guide
    // to annotate beats a cryptic conformance failure — rather than emit code
    // the compiler rejects. The scan consults `scope`, the SAME environment the
    // constraint builder uses, so an enclosing parameter an unannotated field
    // initialises from is caught too.
    if inferred(declaration, mentioning: Set(scope)) {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.inferred))
      return nil
    }
    // Serialize reads `self.<field>` under each `#if` guard and calls no
    // initializer, so its emission is linear in the fields and needs neither
    // the branch cap nor the init-resolution analysis below. Return before
    // both, so a serialize-only struct derives however many `#if` blocks it
    // carries.
    guard direction == .deserialize else {
      return Model(segments: segments)
    }
    // A cartesian product of the conditional blocks' clauses drives the
    // per-branch deserialize initializer calls, so a runaway product would emit
    // enormous code. Cap it with the `.conditional` diagnostic rather than do
    // so. The cap is deserialize-only: only the deserialize side multiplies its
    // `Self(…)` leaves. A field-less `#if` is already dropped from the
    // segments, so it neither counts here nor multiplies the branches.
    guard branches(segments) <= cap else {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.conditional))
      return nil
    }
    // Declaring any initializer in the primary struct declaration suppresses
    // the synthesized memberwise initializer, which deserialize calls as
    // `Self(<field>: …)`. (An init in an extension does not suppress it, and
    // the macro sees only the primary declaration's members anyway.) The check
    // is per emitted build: `resolutions` enumerates each build's ACTIVE fields
    // paired with its ACTIVE inits — inits gated by the same `#if` clauses as
    // fields, so a conditional init counts only in the builds it compiles in.
    // A build is fine when no init is active (the memberwise init is
    // synthesized) or when an active init covers the build's fields; otherwise
    // the suppressed memberwise init has no callable `Self(…)` replacement, so
    // diagnose. A single flattened list would wrongly demand a conditional init
    // cover builds it is not compiled in. Serialize reads `self.<field>` and
    // never calls an init, so this is deserialize-only.
    //
    // The enumeration is its own cartesian, over the `#if` blocks that carry a
    // field OR an init (`resolutions` prunes the rest, as many field/init-less
    // helper-only blocks would otherwise blow the product up though they vary
    // no build). It is not the emission branch count `branches(_ segments:)`
    // caps — an init-only `#if` is dropped from the segments yet still branches
    // the resolution — so cap it separately, with the same `.conditional`
    // diagnostic, before enumerating.
    guard branches(declaration.memberBlock.members) <= cap else {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.conditional))
      return nil
    }
    // The generated extension carries the type's own `@available` AND the
    // enclosing type chain's (the emission copies both onto it), so a user init
    // gated the SAME as the type — or as an enclosing type — is callable
    // wherever the conformance exists. The resolution analysis weighs an init's
    // version gate against this full set: a gate the extension already carries
    // is covered and callable, a NARROWER one is not.
    let gate = available(declaration)
        + available(enclosing: context.lexicalContext)
    let resolutions = self.resolutions(declaration.memberBlock.members)
    guard resolutions.allSatisfy({ resolvable($0, under: gate) }) else {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.initializer))
      return nil
    }
    // The emission reads each typed field with an EXPLICIT type
    // (`decode() as <type>`), so the field's declared type — not the generic
    // `decode()` — drives overload resolution; a type-less field stays a bare
    // `decode()`. Swift RANKS the overloads it keeps: the EXACT
    // memberwise-equivalent init — parameters corresponding one-to-one to the
    // fields, with no extra parameter, even a defaulted one — outranks an init
    // that relies on a defaulted extra parameter, so a unique exact candidate
    // resolves the call unambiguously. A build is ambiguous only when NO unique
    // best candidate exists: two or more inits stay viable against the typed
    // call and none is a unique exact match — either the annotation cannot
    // break the tie because a field carries no type to annotate with, or two
    // inits share the covered fields' types and differ only by extra defaulted
    // parameters (`init(x: Int, y: Int = 0)` and `init(x: Int, z: Int = 0)`
    // both take `Self(x: … as Int)`, neither exact). A set with one best-ranked
    // exact candidate — say `init(x: Int)` beside `init(x: Int, y: Int = 0)` —
    // resolves to it and derives.
    for resolution in resolutions where ambiguous(resolution, under: gate) {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.initializer))
      return nil
    }
    return Model(segments: segments)
  }

  /// Collects `members`, in declaration order, into segments that mirror their
  /// `#if` structure: a stored `var`/`let` extends the current unconditional
  /// run, and an `IfConfigDeclSyntax` becomes one conditional block whose
  /// clauses recurse through `collect` again. Returns `nil` once a field
  /// diagnostic has fired.
  private static func collect(_ members: MemberBlockItemListSyntax,
                              for direction: Direction,
                              under gate: Availability,
                              in context: some MacroExpansionContext,
                              at node: AttributeSyntax) -> Array<Segment>? {
    var segments = Array<Segment>()
    var run = Array<Field>()
    func flush() {
      guard !run.isEmpty else { return }
      segments.append(.unconditional(run))
      run.removeAll()
    }
    for member in members {
      if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
        flush()
        guard let clauses = clauses(of: conditional, for: direction,
                                    under: gate, in: context, at: node) else {
          return nil
        }
        // An `#if` guarding only non-field members (helper methods,
        // typealiases, computed properties, or a nested field-less `#if`)
        // contributes no stored field, so the serialized field set is the same
        // in every clause. Dropping it keeps the emission unconditional and,
        // crucially, keeps such a block out of the deserialize branch product —
        // otherwise many field-less blocks would multiply the per-branch
        // `Self(…)` calls (and hit the `.conditional` cap) though the field set
        // never varies. The init-suppression analysis still sees any init the
        // block guards, since it walks the primary declaration's members
        // directly rather than these segments.
        guard clauses.contains(where: { carries($0.segments) }) else {
          continue
        }
        segments.append(.conditional(clauses))
        continue
      }
      guard let binding = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      guard append(binding, for: direction, under: gate, to: &run,
                   in: context, at: node) else {
        return nil
      }
    }
    flush()
    return segments
  }

  /// The clauses of `conditional`, each carrying its verbatim condition and its
  /// recursively collected segments. A clause whose body is not member
  /// declarations (an `#if` around statements or attributes) contributes no
  /// segments. Returns `nil` once a field diagnostic has fired.
  private static func clauses(of conditional: IfConfigDeclSyntax,
                              for direction: Direction,
                              under gate: Availability,
                              in context: some MacroExpansionContext,
                              at node: AttributeSyntax) -> Array<Clause>? {
    var clauses = Array<Clause>()
    for clause in conditional.clauses {
      guard case let .decls(members)? = clause.elements else {
        clauses.append(Clause(pound: clause.poundKeyword.text,
                              condition: clause.condition?.trimmedDescription,
                              segments: []))
        continue
      }
      guard let segments = collect(members, for: direction, under: gate,
                                   in: context, at: node) else {
        return nil
      }
      clauses.append(Clause(pound: clause.poundKeyword.text,
                            condition: clause.condition?.trimmedDescription,
                            segments: segments))
    }
    return clauses
  }

  /// Whether `segments` carry a stored field at any depth — an unconditional
  /// run holding one, or a conditional clause that recursively does. A field-
  /// less `#if` (guarding only methods, typealiases, or computed properties)
  /// answers `false`, so `collect` drops it rather than record a conditional
  /// segment whose clauses vary no field.
  private static func carries(_ segments: Array<Segment>) -> Bool {
    segments.contains { segment in
      switch segment {
      case let .unconditional(run):
        return !run.isEmpty
      case let .conditional(clauses):
        return clauses.contains { carries($0.segments) }
      }
    }
  }

  /// Appends the stored properties `binding` declares to `run`, or diagnoses
  /// and returns `false` for a shape the derive rejects (a `lazy`,
  /// wrapper-backed, or — on the deserialize side — an initialized `let`).
  private static func append(_ binding: VariableDeclSyntax,
                             for direction: Direction,
                             under gate: Availability,
                             to run: inout Array<Field>,
                             in context: some MacroExpansionContext,
                             at node: AttributeSyntax) -> Bool {
    guard !typed(binding.modifiers) else { return true }
    // A `lazy var` has a mutating getter, so serialize's nonmutating
    // `self.<name>` read cannot type-check, and it is not a memberwise-init
    // parameter for deserialize to pass. Reject rather than miscompile.
    guard !lazy(binding.modifiers) else {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.lazy))
      return false
    }
    let constant = binding.bindingSpecifier.tokenKind == .keyword(.let)
    for (pattern, type) in bindings(of: binding) {
      // A computed property has no storage: serialize does not read it and it
      // is not a memberwise-init parameter, so it contributes no field and its
      // attributes are irrelevant. Skip it BEFORE the wrapper check, so an
      // attribute the derive does not recognize on a computed property (say a
      // `@MainActor var y: Int { 0 }`) is not misread as a property wrapper.
      guard !computed(pattern.accessorBlock) else { continue }
      // A property wrapper's synthesized memberwise parameter is typed for the
      // wrapper storage, which need not match the wrapped value serialize
      // writes. The syntactic macro cannot resolve the two, so it rejects a
      // wrapper-backed stored property on both sides rather than emit a shape
      // that deserializes differently than it serialized.
      guard !wrapped(binding.attributes) else {
        context.diagnose(Diagnostic(node: node,
                                    message: DecantDiagnostic.wrapper))
        return false
      }
      // A deprecated stored field warns on every access, and serialize reads
      // `self.<field>` — UNLESS the read sits in a deprecated context, where
      // Swift suppresses the warning. The generated extension copies the type's
      // and enclosing chain's `@available` (`gate`), so when that gate covers
      // the field's deprecation ON ITS PLATFORM the extension IS a deprecated
      // context and the read is warning-free; only an UNCOVERED deprecation
      // (the extension is not deprecated on the field's platform) breaks a
      // warning-free build. Reject only such an uncovered field, and only on
      // serialize — deserialize passes the field as a memberwise-init argument
      // (`Self(<label>: …)`), which is not an access and never warns (mirroring
      // the deprecated-init coverage on deserialize). An `unavailable`/
      // `obsoleted:` field is worse than deprecated — reading it is an ERROR a
      // deprecated context does NOT suppress — so it is rejected outright
      // (`disqualified`), never excused by the gate.
      let field = availability(binding.attributes)
      guard !(direction == .serialize
                && (field.disqualified
                      || !covers(deprecation: gate, field))) else {
        context.diagnose(Diagnostic(node: node,
                                    message: DecantDiagnostic.deprecated))
        return false
      }
      // Swift omits an initialized `let` from the synthesized memberwise init,
      // so deserialize would pass an argument no parameter accepts. An
      // uninitialized `let` and any `var` remain memberwise parameters. The
      // nonmutating serialize read of `self.<name>` is fine either way, so this
      // rejection is deserialize-only.
      guard !(direction == .deserialize
                && constant && pattern.initializer != nil) else {
        context.diagnose(Diagnostic(node: node,
                                    message: DecantDiagnostic.constant))
        return false
      }
      append(pattern.pattern, typed: type, to: &run)
    }
    return true
  }

  /// The number of distinct deserialize branches `segments` describes: the
  /// product over each conditional block of the sum of its clauses' branch
  /// counts, plus one for the synthesized `#else` a block without a source
  /// `#else` gains (the case no clause is active). An unconditional segment is
  /// one branch; a block multiplies. This is the count `builds` emits, so the
  /// cap it guards is exact.
  ///
  /// The product SATURATES at `cap + 1`: many independent conditional blocks
  /// would overflow `Int` before the `<= cap` comparison and trap the plugin
  /// instead of raising `.conditional`, so once the running product passes the
  /// cap the fold stops and returns `cap + 1`. A saturated value stays `> cap`,
  /// so the diagnostic still fires for the oversized shape; a within-cap
  /// product is exact and unaffected. `branches` never exceeds `cap + 1`, so
  /// each clause's term is bounded and the clause sum cannot overflow.
  private static func branches(_ segments: Array<Segment>) -> Int {
    var product = 1
    for segment in segments {
      guard case let .conditional(clauses) = segment else { continue }
      var sum = clauses.reduce(0) { $0 + branches($1.segments) }
      if clauses.last?.condition != nil { sum += 1 }
      let (scaled, overflow) = product.multipliedReportingOverflow(by: sum)
      guard !overflow, scaled <= cap else { return cap + 1 }
      product = scaled
    }
    return product
  }

  /// The emission cap on the deserialize branch count. Past it the per-branch
  /// `Self(…)` calls — the cartesian product of the `#if` blocks' clauses —
  /// would emit enormous code, so `branches` saturates here and `model` raises
  /// `.conditional`.
  private static let cap = 256

  /// One emitted build: the fields active in it, in declaration order, paired
  /// with the initializers active in it. The derive emits a `Self(<fields>)`
  /// for the build, and its active inits are the ones in scope that suppress
  /// the synthesized memberwise init in that build.
  private struct Resolution {
    internal let fields: Array<Field>
    internal let inits: Array<InitializerDeclSyntax>
  }

  /// Every emitted build's active fields and active initializers — the
  /// cartesian of the `#if` blocks' clause selections, each selection carrying
  /// the fields AND the inits its clauses compile. Fields and inits share the
  /// same `#if` structure, so one walk yields both: a field or init a clause
  /// guards appears only in the builds that keep that clause. A block without a
  /// source `#else` contributes an implicit "no clause active" build that omits
  /// the block's fields and inits, matching the synthesized `#else` leaf the
  /// emission produces. A clause whose body is not member declarations (a `#if`
  /// around statements) contributes nothing.
  ///
  /// An `#if` block carrying NEITHER a field NOR an init at any depth
  /// (`pertinent` answers `false`: a block of helper methods, computed
  /// properties, or typealiases) varies no build — the same fields and inits
  /// are active whichever clause the compiler picks — so it is skipped rather
  /// than branched over. Many such blocks would otherwise multiply the
  /// cartesian pointlessly (and blow the resolution up) though the analysis'
  /// answer never changes.
  ///
  /// `model` caps `branches(_ members:)` before this runs, so the enumeration
  /// is bounded. The field walk needs no diagnostics: `collect` has already
  /// validated the shapes and fired any field diagnostic.
  private static func resolutions(_ members: MemberBlockItemListSyntax)
      -> Array<Resolution> {
    var properties = Array<Field>()
    var initializers = Array<InitializerDeclSyntax>()
    var index = members.startIndex
    while index != members.endIndex {
      let decl = members[index].decl
      if let binding = decl.as(VariableDeclSyntax.self) {
        properties.append(contentsOf: fields(of: binding))
      } else if let initializer = decl.as(InitializerDeclSyntax.self) {
        initializers.append(initializer)
      } else if let block = decl.as(IfConfigDeclSyntax.self),
                pertinent(block) {
        break
      }
      index = members.index(after: index)
    }
    guard index != members.endIndex,
          let block = members[index].decl.as(IfConfigDeclSyntax.self) else {
      return [Resolution(fields: properties, inits: initializers)]
    }
    let after = members.index(after: index)
    let rest = MemberBlockItemListSyntax(members[after...])
    // Splice each clause's members ahead of `rest` and recurse, so the
    // remaining top-level members join every clause selection.
    func joined(_ clause: MemberBlockItemListSyntax?) -> Array<Resolution> {
      let head = clause.map { Array($0) } ?? []
      let spliced = MemberBlockItemListSyntax(head + Array(rest))
      return resolutions(spliced).map { resolution in
        Resolution(fields: properties + resolution.fields,
                   inits: initializers + resolution.inits)
      }
    }
    var builds = Array<Resolution>()
    for clause in block.clauses {
      guard case let .decls(members)? = clause.elements else {
        builds += joined(nil)
        continue
      }
      builds += joined(members)
    }
    // A block without a source `#else` still has the "no clause active" build,
    // which omits the block's members.
    if block.clauses.last?.condition != nil {
      builds += joined(nil)
    }
    return builds
  }

  /// Whether `block` carries a stored field or an initializer in any clause, at
  /// any depth — the predicate that decides a block matters to the resolution
  /// enumeration. A block of only helper methods, computed properties, or
  /// typealiases (or a nested block of the same) varies neither the active
  /// fields nor the active inits, so `resolutions` skips it. A block carrying
  /// an init but no field is still pertinent: the init suppresses the
  /// memberwise init in the builds that compile it, which the analysis must
  /// weigh even though `collect` drops the field-less block from the emitted
  /// segments.
  private static func pertinent(_ block: IfConfigDeclSyntax) -> Bool {
    block.clauses.contains { clause in
      guard case let .decls(members)? = clause.elements else { return false }
      return members.contains { member in
        let decl = member.decl
        if let binding = decl.as(VariableDeclSyntax.self) {
          return !fields(of: binding).isEmpty
        }
        if decl.is(InitializerDeclSyntax.self) { return true }
        if let nested = decl.as(IfConfigDeclSyntax.self) {
          return pertinent(nested)
        }
        return false
      }
    }
  }

  /// The number of distinct builds the resolution enumeration visits — the
  /// product over each PERTINENT `#if` block of the sum of its clauses' build
  /// counts, plus one for the synthesized "no clause active" build a block
  /// without a source `#else` gains. A non-pertinent block `resolutions` skips
  /// contributes no factor, matching the enumeration.
  ///
  /// This is the resolution cartesian, not the emission branch count
  /// `branches(_ segments:)` caps: an init-only `#if` is dropped from the
  /// segments (so that overload sees one branch) yet still branches the
  /// resolution here. Like it, the product SATURATES at `cap + 1`, so many
  /// blocks cannot overflow `Int` before `model`'s `<= cap` guard raises
  /// `.conditional`.
  private static func branches(_ members: MemberBlockItemListSyntax) -> Int {
    var product = 1
    for member in members {
      guard let block = member.decl.as(IfConfigDeclSyntax.self),
            pertinent(block) else { continue }
      var sum = block.clauses.reduce(0) { partial, clause in
        guard case let .decls(members)? = clause.elements else {
          return partial
        }
        return partial + branches(members)
      }
      if block.clauses.last?.condition != nil { sum += 1 }
      let (scaled, overflow) = product.multipliedReportingOverflow(by: sum)
      guard !overflow, scaled <= cap else { return cap + 1 }
      product = scaled
    }
    return product
  }

  /// The stored fields `binding` declares, in declaration order — the same
  /// fields `collect` gathers, without the diagnostics it has already fired.
  /// Skips a type-level member, a computed property, and (mirroring the
  /// deserialize side that owns the resolution analysis) an initialized `let`,
  /// none of which is a memberwise parameter.
  private static func fields(of binding: VariableDeclSyntax) -> Array<Field> {
    guard !typed(binding.modifiers) else { return [] }
    let constant = binding.bindingSpecifier.tokenKind == .keyword(.let)
    var fields = Array<Field>()
    for (pattern, type) in bindings(of: binding) {
      guard !computed(pattern.accessorBlock) else { continue }
      guard !(constant && pattern.initializer != nil) else { continue }
      append(pattern.pattern, typed: type, to: &fields)
    }
    return fields
  }

  /// Whether `resolution` needs no `.initializer` diagnostic: either no init is
  /// active in the build (the memberwise init is synthesized) or an active init
  /// is a callable replacement covering the build's active fields by label AND
  /// type. An active init present but none covering leaves the suppressed
  /// memberwise init with no callable `Self(…)` target, so the build is
  /// unresolvable and the caller diagnoses.
  private static func resolvable(_ resolution: Resolution,
                                 under gate: Array<String>) -> Bool {
    resolution.inits.isEmpty
        || resolution.inits.contains { covers($0, resolution.fields,
                                              under: gate) }
  }

  /// Whether `resolution`'s active inits leave the emitted `Self(<labels>: …)`
  /// call with no unique best-ranked candidate, so the caller diagnoses.
  ///
  /// An init stays viable against the typed call — each typed field read
  /// `decode() as <type>` — only if its matched parameter matches the field by
  /// label AND type; a type-less field stays a bare `decode()`, so it is kept
  /// live by LABEL alone (the annotation cannot break a tie resting on it).
  /// Fewer than two viable inits is unambiguous. When two or more stay viable,
  /// Swift ranks an EXACT candidate — parameters corresponding one-to-one to
  /// the fields, no extra parameter — above one that needs a defaulted extra
  /// parameter, so a UNIQUE exact candidate resolves the call and is not a tie.
  /// The set is ambiguous only when no unique best candidate exists: either no
  /// exact candidate (two overloads each needing a different default) or two or
  /// more equally exact candidates (a type-less field they share by label).
  private static func ambiguous(_ resolution: Resolution,
                                under gate: Array<String>) -> Bool {
    let live = resolution.inits.filter { callable($0, under: gate)
        && inferable($0, resolution.fields)
        && consistent($0, resolution.fields)
        && viable(parameters(of: $0), resolution.fields,
                  generics: generics(of: $0)) }
    guard live.count >= 2 else { return false }
    let exact = live.filter {
      exact(parameters(of: $0), resolution.fields, generics: generics(of: $0))
    }
    return exact.count != 1
  }

  /// Whether the typed `Self(<fields>: …)` call resolves `parameters` EXACTLY:
  /// viable, and every parameter is matched to a field with no extra parameter
  /// left over (`parameters.count == fields.count`). An exact match is the
  /// memberwise-equivalent init Swift ranks above an overload that relies on a
  /// defaulted extra parameter.
  private static func exact(_ parameters: Array<FunctionParameterSyntax>,
                            _ fields: Array<Field>,
                            generics: Set<String>) -> Bool {
    parameters.count == fields.count
        && viable(parameters, fields, generics: generics)
  }

  /// Whether the typed `Self(<fields>: …)` call keeps `parameters` viable: the
  /// `covers` subsequence-with-defaults rule, matching each parameter to its
  /// field by label — and by TYPE when the field carries one (the annotation
  /// fixes it), by label alone when it does not. A parameter whose type IS one
  /// of the init's own `generics` matches by label: the passed field fixes the
  /// generic, so the spelling need not equal the field's.
  private static func viable(_ parameters: Array<FunctionParameterSyntax>,
                             _ fields: Array<Field>,
                             generics: Set<String>) -> Bool {
    var field = 0
    for parameter in parameters {
      let matched = field < fields.count
          && matches(parameter, fields[field], generics: generics)
      if matched {
        field += 1
      } else if parameter.defaultValue == nil {
        return false
      }
    }
    return field == fields.count
  }

  /// Whether `parameter` matches `field` for the viable/exact overload check: a
  /// type-less field matches by LABEL alone (the bare `decode()` cannot fix the
  /// type), a typed field matches by label AND type (`passes`) OR by label when
  /// the parameter's type is one of the init's `generics` (the field's decoded
  /// value fixes the generic).
  private static func matches(_ parameter: FunctionParameterSyntax,
                              _ field: Field,
                              generics: Set<String>) -> Bool {
    if field.type == nil { return labelled(parameter, field) }
    return passes(parameter, field)
        || generic(parameter, field, generics: generics)
  }

  /// The generic parameter names `initializer` declares — its own `<…>` clause,
  /// the set `inferable` and the overload matching consult so a parameter typed
  /// as one of them is matched by label and bound by the passed field.
  private static func generics(of initializer: InitializerDeclSyntax)
      -> Set<String> {
    Set(initializer.genericParameterClause?.parameters
        .map { $0.name.text } ?? [])
  }

  /// Whether `parameter`'s type is exactly one of the init's `generics` and its
  /// label is `field.name` — a generic parameter the passed field binds, so the
  /// derive's `Self(<field>: decode() as <fieldtype>)` supplies the type. The
  /// parameter must carry no specifier the memberwise init lacks (`passes`
  /// enforces the same for a concrete parameter).
  private static func generic(_ parameter: FunctionParameterSyntax,
                              _ field: Field, generics: Set<String>) -> Bool {
    guard labelled(parameter, field), !specified(parameter.type),
          let identifier = parameter.type.as(IdentifierTypeSyntax.self),
          identifier.genericArgumentClause == nil else {
      return false
    }
    return generics.contains(identifier.name.text)
  }

  /// Whether `initializer` covers the build's `fields` by label AND type and is
  /// plainly callable, so the derive's `Self(<fields>)` resolves against it —
  /// the label-and-type-parity check plus the callability guard.
  ///
  /// Label parity alone does not suffice: `struct S { var x: Int;
  /// init(x: String) }` suppresses the memberwise init and matches on the `x`
  /// label, yet the derive's `try Self(x: deserializer.decode())` infers
  /// `decode` as `String` while serialize writes `self.x` as `Int` — a shape a
  /// non-self-converting format round-trips wrong. So each parameter's trimmed
  /// type spelling must equal the corresponding field's. A field with no
  /// captured type (`Field.type == nil`: an inferred `var count = 0`, or a
  /// tuple element) makes equivalence unprovable, so it is a non-match.
  ///
  /// A field a `#if` guards is absent from the builds that omit its clause, so
  /// the `Self(<active fields>)` for such a build passes a SUBSET of the init's
  /// parameters. `covers` (below) enforces that every skipped parameter carries
  /// a default, and a mutually-exclusive field is active once per build, so
  /// `#if A var x #else var x #endif; init(x:)` covers each build's single `x`
  /// while `var base; #if A var x #endif; init(base:x:)` needs `x` defaulted.
  private static func covers(_ initializer: InitializerDeclSyntax,
                             _ fields: Array<Field>,
                             under gate: Array<String>) -> Bool {
    callable(initializer, under: gate)
        && inferable(initializer, fields)
        && consistent(initializer, fields)
        && covers(parameters(of: initializer), fields,
                  generics: generics(of: initializer))
  }

  /// Whether every generic parameter `initializer` declares is INFERABLE from
  /// the fields the derive's `Self(<fields>: …)` actually passes — the types of
  /// the parameters matched to a field, not the skipped defaulted ones.
  ///
  /// A generic parameter reachable only through a SKIPPED defaulted parameter
  /// cannot be inferred at the call: `init<U>(x: Int, y: U? = nil)` covers a
  /// lone `x` field by defaulting `y`, but the emitted `Self(x: … as Int)`
  /// passes no argument mentioning `U`, so `U` is unbound and the call fails to
  /// type-check. Rejecting such a candidate leaves the suppressed memberwise
  /// init with no callable replacement, so the normal `.initializer` diagnostic
  /// fires rather than uncompilable code. A non-generic init is inferable;
  /// an init whose every generic parameter appears in a PASSED parameter's type
  /// (`init<U>(x: U)` matched to `x`) is inferable and stays a candidate.
  private static func inferable(_ initializer: InitializerDeclSyntax,
                                _ fields: Array<Field>) -> Bool {
    let generics = generics(of: initializer)
    guard !generics.isEmpty else { return true }
    var mentioned = Set<String>()
    var field = 0
    for parameter in parameters(of: initializer) {
      guard field < fields.count,
            matches(parameter, fields[field], generics: generics) else {
        continue
      }
      mentioned.formUnion(references(parameter.type))
      field += 1
    }
    return generics.isSubset(of: mentioned)
  }

  /// Whether the field types the derive's `Self(<fields>: …)` passes bind each
  /// of `initializer`'s generic parameters CONSISTENTLY — no generic bound to
  /// two different field types across the parameters it types.
  ///
  /// `init<U>(x: U, y: U)` matched to `var x: Int; var y: String` accepts each
  /// parameter by label alone (a generic-typed parameter matches by label, the
  /// passed field fixing the type), so the label-and-subsequence checks read it
  /// as covering — but the emitted `Self(x: … as Int, y: … as String)` infers
  /// `U` as both `Int` and `String`, a conflict Swift rejects. Recording the
  /// field type each generic-typed parameter binds and rejecting a second,
  /// DIFFERENT binding for the same generic keeps such an init from being a
  /// candidate, so the normal `.initializer` diagnostic fires rather than a
  /// `Self(…)` that will not compile. A generic bound to ONE type throughout
  /// (`var x: Int; var y: Int; init<U>(x: U, y: U)`) is consistent and covers.
  /// A field of no captured type cannot conflict-check (its bound type is
  /// unknown), so it records nothing and leaves the generic free.
  private static func consistent(_ initializer: InitializerDeclSyntax,
                                 _ fields: Array<Field>) -> Bool {
    let generics = generics(of: initializer)
    guard !generics.isEmpty else { return true }
    var bindings = Dictionary<String, String>()
    var field = 0
    for parameter in parameters(of: initializer) {
      guard field < fields.count,
            matches(parameter, fields[field], generics: generics) else {
        continue
      }
      defer { field += 1 }
      guard generic(parameter, fields[field], generics: generics),
            let identifier = parameter.type.as(IdentifierTypeSyntax.self),
            let bound = fields[field].type else {
        continue
      }
      let name = identifier.name.text
      if let existing = bindings[name], existing != bound { return false }
      bindings[name] = bound
    }
    return true
  }

  /// Whether `initializer` is plainly callable as the derive's synchronous
  /// `Self(…)` in a `throws(D.Failure)` context — non-failable, non-throwing,
  /// non-async, non-isolated, and callable-and-warning-free under `@available`.
  ///
  /// A failable `init?` yields `Self?`, not the `Self` the derive binds; a
  /// `throws` (or `throws(SomeError)`) init raises an error the typed-throws
  /// context cannot absorb, though a `throws(Never)` init is nonthrowing and
  /// stays callable (`nonthrowing`); an `async` init cannot be awaited from the
  /// synchronous call. A custom
  /// (non-built-in) attribute — a global actor such as `@MainActor` — imposes
  /// actor isolation the nonisolated `deserialize` witness cannot honor. A
  /// non-isolation built-in attribute (`@inlinable`, `@objc`, …) is harmless.
  /// `@available` is callable only when it leaves the init callable and
  /// warning-free: an `unavailable`/`obsoleted:` argument makes it uncallable
  /// and a `deprecated` argument warns at the `Self(…)` call (which the
  /// warning-free build rejects), so either disqualifies it — UNLESS the
  /// deprecation is covered by `gate`, the type's own `@available` the
  /// extension copies. A deprecated init gated the SAME as a deprecated type is
  /// called from a deprecated extension, where the call raises no warning, so
  /// it stays callable; a deprecation the extension does not carry still warns
  /// and disqualifies. A version restriction — a platform `introduced:` or
  /// short-form version such as `@available(macOS 99, *)`, or `@available(swift
  /// 99)` — disqualifies the init only when it is NOT covered by `gate`: one
  /// gated the SAME as the type is emitted under that gate and IS callable,
  /// while a NARROWER one gates the init to a version the witness is not
  /// emitted under, so `Self(…)` would call an unavailable init. See
  /// `isolating`, `unavailable`, `restricted`.
  private static func callable(_ initializer: InitializerDeclSyntax,
                               under gate: Array<String>) -> Bool {
    guard initializer.optionalMark == nil else { return false }
    guard !isolating(initializer.attributes) else { return false }
    guard !unavailable(initializer.attributes, under: gate) else {
      return false
    }
    guard !restricted(initializer.attributes, under: gate) else {
      return false
    }
    let effects = initializer.signature.effectSpecifiers
    return nonthrowing(effects?.throwsClause)
        && effects?.asyncSpecifier == nil
  }

  /// Whether `clause` leaves the init NONTHROWING at the call site — no clause
  /// at all, or a TYPED `throws(Never)`, which Swift treats as nonthrowing (the
  /// derive's `Self(…)` needs no `try`, and where a field's `decode()` already
  /// forces `try`, the extra nonthrowing init raises nothing). A plain `throws`
  /// or a `throws(SomeError)` over a real error type raises an error the
  /// derive's `throws(D.Failure)` context cannot absorb, so it stays throwing.
  private static func nonthrowing(_ clause: ThrowsClauseSyntax?) -> Bool {
    guard let clause else { return true }
    guard let type = clause.type?.as(IdentifierTypeSyntax.self) else {
      return false
    }
    return type.genericArgumentClause == nil && type.name.text == "Never"
  }

  /// The `initializer`'s parameters as an array.
  private static func parameters(of initializer: InitializerDeclSyntax)
      -> Array<FunctionParameterSyntax> {
    Array(initializer.signature.parameterClause.parameters)
  }

  /// Whether the derive's `Self(<fields>)` call — passing `fields`, in order,
  /// by their memberwise labels — resolves against `parameters`, the init's
  /// parameter list.
  ///
  /// Swift matches call arguments to parameters in declaration order and lets a
  /// defaulted parameter be skipped, so the branch's `fields` must be a
  /// SUBSEQUENCE of `parameters` (matched by label AND type), and every skipped
  /// parameter must carry a default. A parameter matched to a field must also
  /// be a spelling the memberwise init could have — no wildcard label
  /// (positional, matching no named field), no `inout`/ownership/`isolated`
  /// specifier (a by-value rvalue cannot satisfy it), and a field of no
  /// captured type is unprovable — any of which makes it a non-match.
  private static func covers(_ parameters: Array<FunctionParameterSyntax>,
                             _ fields: Array<Field>,
                             generics: Set<String>) -> Bool {
    var field = 0
    for parameter in parameters {
      // The covers path demands type parity for safety: a field with no
      // captured type is unprovable and never matches (unlike the viable path,
      // which keeps a type-less field live by label). A parameter typed as one
      // of the init's own `generics` still matches by label — the passed typed
      // field binds the generic — so an `init<U>(x: U)` covers a typed `x`.
      let matched = field < fields.count
          && fields[field].type != nil
          && (passes(parameter, fields[field])
                || generic(parameter, fields[field], generics: generics))
      if matched {
        field += 1
      } else if parameter.defaultValue == nil {
        // A parameter this branch does not pass — because its field is inactive
        // — must default, or the shorter `Self(…)` call cannot resolve.
        return false
      }
    }
    // Every active field must have found a parameter, in order.
    return field == fields.count
  }

  /// Whether `parameter` is the one the derive's `Self(…)` passes `field` to:
  /// its external label is `field.name`, its type equals the field's, and it
  /// carries no specifier the memberwise init lacks.
  private static func passes(_ parameter: FunctionParameterSyntax,
                             _ field: Field) -> Bool {
    guard labelled(parameter, field) else { return false }
    // A parameter specifier — `inout`, `borrowing`, `consuming`, or any other
    // the parser attaches to the type — is one the memberwise init never
    // carries, and the derive's `Self(<field>: deserializer.decode())` passes a
    // by-value rvalue an `inout` (or ownership-annotated) parameter will not
    // accept. Its type parses as an `AttributedTypeSyntax` whose specifiers
    // (`inout Int` → a `SimpleTypeSpecifier`) are non-empty, so reject any such
    // parameter rather than accept an init the emitted call cannot compile
    // against.
    guard !specified(parameter.type) else { return false }
    guard let type = field.type else { return false }
    return parameter.type.trimmedDescription == type
  }

  /// Whether `parameter`'s external label is `field.name` — the label-only half
  /// of `passes`, so `Self(<field>: …)` names this parameter regardless of the
  /// TYPES the generic `decode()` cannot fix yet. `viable` uses it to keep a
  /// type-less field's init live; `passes` adds the specifier and type check.
  private static func labelled(_ parameter: FunctionParameterSyntax,
                               _ field: Field) -> Bool {
    // A `_` first name is the WILDCARD: the parameter has NO external label and
    // is passed positionally, unlike a field named `_`, whose memberwise label
    // is the escaped `` `_` ``. `Identifier` would canonicalize both to the
    // string `"_"` and conflate them, so `init(_ x: Int)` would falsely match
    // `var _: Int` — yet the derive emits `` Self(`_`: …) ``, a real label that
    // does not resolve to the positional init. A positional parameter matches
    // no named field, so treat the wildcard as unmatchable.
    guard parameter.firstName.tokenKind != .wildcard else { return false }
    let label = Identifier(parameter.firstName)?.name
        ?? parameter.firstName.text
    return label == field.name
  }

  /// Whether `type` carries a parameter specifier the synthesized memberwise
  /// initializer would never spell — `inout` or an ownership modifier
  /// (`borrowing`/`consuming`), and any other specifier the parser attaches. A
  /// specified parameter type parses as an `AttributedTypeSyntax` whose
  /// `specifiers` list holds the modifier, so a non-empty list is the signal;
  /// the derive's by-value `Self(<field>: …)` call cannot satisfy such a
  /// parameter, so a carrying init must not match.
  private static func specified(_ type: TypeSyntax) -> Bool {
    guard let attributed = type.as(AttributedTypeSyntax.self) else {
      return false
    }
    return !attributed.specifiers.isEmpty
  }

  /// Whether `attributes` carry an attribute that could impose actor isolation
  /// on the initializer — any custom attribute, since a global actor
  /// (`@MainActor`, or a custom `@SomeGlobalActor`) is a custom attribute. An
  /// isolated init cannot be called from the derive's synchronous, nonisolated
  /// `deserialize` witness, so the init is not a memberwise-equivalent
  /// replacement. A Swift built-in declaration attribute (`builtins`, e.g.
  /// `@inlinable` / `@available`) does not affect the synchronous nonisolated
  /// call and passes here; the trailing name is matched so a qualified spelling
  /// is covered too, like `wrapped`. `@available` is a built-in, so its
  /// isolation is a non-issue — but its ARGUMENTS may still make the init
  /// uncallable or warning-carrying, which `unavailable` checks separately.
  private static func isolating(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { attribute in
      guard case let .attribute(attribute) = attribute,
            let name = trailing(attribute.attributeName) else {
        return false
      }
      return !builtins.contains(name)
    }
  }

  /// Whether `attributes` carry an `@available` that stops the derive's
  /// `Self(<field>: …)` call from a clean compile — an `unavailable`/
  /// `obsoleted:` argument, which makes the init uncallable, or a `deprecated`
  /// argument the enclosing extension does NOT itself carry ON THE SAME
  /// PLATFORM, whose call then warns and so breaks the warning-free build. A
  /// plain platform availability (`@available(macOS 10.0, *)`, only `introduced`
  /// / `*` / version restrictions) is harmless and reports `false`.
  ///
  /// The check is SEMANTIC and PER PLATFORM, not by exact gate text. The init's
  /// attributes and `gate` — the type's copied `@available` spellings the
  /// extension repeats — each parse into an ``Availability`` model keyed by
  /// platform (`macOS`, `iOS`, …, `swift`, and the `*` fallback). An
  /// `unavailable`/`obsoleted:` on ANY platform disqualifies unconditionally:
  /// the deprecated extension does not make an unavailable init callable, so
  /// those stay rejected by their mere presence. A `deprecation` is EXCUSED only
  /// where covered: for EACH platform the init is deprecated on, the type must
  /// ALSO be deprecated on that same platform (at the same or an earlier
  /// version), so the `Self(…)` call sits inside a matching deprecated context
  /// where Swift suppresses the warning. A type deprecated only on `macOS` does
  /// NOT cover an init deprecated on `iOS`, since an `iOS` build's extension is
  /// not `iOS`-deprecated and the call there would warn.
  ///
  /// `unavailable` and a bare `deprecated` are unlabeled identifier tokens in
  /// the argument list; `obsoleted:` and `deprecated:` (with a version) are
  /// labeled arguments. Both spellings are modelled. Only `@available` carries
  /// availability arguments, so a non-`@available` attribute contributes nothing
  /// and its isolation, if any, is left to `isolating`.
  private static func unavailable(_ attributes: AttributeListSyntax,
                                  under gate: Array<String>) -> Bool {
    let initializer = availability(attributes)
    guard !initializer.disqualified else { return true }
    return !covers(deprecation: availability(gate), initializer)
  }

  /// Whether `type` — the extension's own parsed availability — covers every
  /// platform-scoped deprecation `initializer` carries, so the derive's
  /// `Self(…)` call raises no deprecation warning. A deprecated init is
  /// warning-free ONLY inside an extension that is deprecated on the SAME
  /// platform: Swift suppresses the warning in a deprecated context, and the
  /// extension inherits the type's per-platform deprecation. So for each
  /// platform the init is deprecated on, the type must be deprecated on that
  /// platform too, at the same or an earlier version (an earlier type
  /// deprecation still spans the init's). An init deprecation the type does not
  /// match on its platform would warn on a build of that platform, so it is not
  /// covered. The `*` fallback deprecates every platform, so a `*`-deprecated
  /// type covers any init deprecation and a `*`-deprecated init needs the type
  /// deprecated on `*` too.
  private static func covers(deprecation type: Availability,
                             _ initializer: Availability) -> Bool {
    initializer.deprecations.allSatisfy { platform, version in
      guard let cover = type.deprecation(on: platform) else { return false }
      return precedes(cover, version)
    }
  }

  /// Whether `attributes` gate the init to a VERSION or PLATFORM the generated
  /// witness is not itself emitted under — an availability the extension's own
  /// gate does NOT cover, so the init is a NARROWER replacement `Self(…)` could
  /// call where it does not exist.
  ///
  /// The check is SEMANTIC and PER PLATFORM. The init's attributes and `gate` —
  /// the type's copied `@available` spellings the extension repeats — parse into
  /// an ``Availability`` model, and the init COVERS the extension iff, on every
  /// platform the extension is available, the init is available there too at the
  /// same or an EARLIER introduced version. A same-or-BROADER init gate is fine:
  /// an `@available(macOS 10.0, iOS 13.0, *)` type with an `@available(macOS
  /// 10.0, *)` init is covered, since the init's `*` fallback makes it available
  /// wherever the extension is (its `iOS` context included). A NARROWER gate —
  /// `@available(macOS 99, *)` under a `macOS 10.0` type, or a
  /// version-restricted init under an ungated type — leaves `Self(…)`
  /// uncallable below the init's floor yet callable at the witness's, a mismatch
  /// the macro cannot guarantee away, so `callable` rejects it and the
  /// `.initializer` diagnostic (or memberwise fallback) applies. `unavailable`/
  /// `obsoleted:`/`deprecated` are NOT restrictions here — they are left to
  /// `unavailable` — so a purely deprecating gate never trips this.
  private static func restricted(_ attributes: AttributeListSyntax,
                                 under gate: Array<String>) -> Bool {
    !covers(introduction: availability(gate), availability(attributes))
  }

  /// Whether `initializer` is introduced no later than `type` on every platform
  /// EITHER model restricts, so the derive's `Self(…)` reaches it wherever the
  /// extension exists.
  ///
  /// The extension inherits `type`'s per-platform floor; an `@available` names
  /// only the platforms it RESTRICTS and leaves every other platform available
  /// with no floor (`introduction(on:)` reports that unrestricted floor). So the
  /// init covers the extension iff, on each platform either names, the init's
  /// floor is at or below the type's. A same-or-BROADER init is fine — an
  /// `@available(macOS 10.0, iOS 13.0, *)` type with an `@available(macOS 10.0,
  /// *)` init covers `iOS` through the init's unrestricted fallback. A platform
  /// the INIT restricts but the type does not (a narrower `swift` version, say)
  /// has a type floor of nothing and an init floor above it, so it is not
  /// covered; likewise a later init floor on a shared platform, or any init
  /// restriction under an ungated type.
  private static func covers(introduction type: Availability,
                             _ initializer: Availability) -> Bool {
    let platforms = Set(type.introductions.keys)
        .union(initializer.introductions.keys)
    return platforms.allSatisfy { platform in
      precedes(initializer.introduction(on: platform),
               type.introduction(on: platform))
    }
  }

  /// A semantic per-platform reading of a declaration's `@available` gate — the
  /// single model the coverage predicates compare, replacing the earlier
  /// exact-attribute-text and single-boolean checks so a NARROWER platform or
  /// version cannot slip through a shallow match.
  ///
  /// Each platform Swift restricts — `macOS`, `iOS`, …, the pseudo-platform
  /// `swift`, and the `*` wildcard fallback — maps to the state the gate assigns
  /// it: its introduced-version floor, its deprecation (present, with an
  /// optional version), and whether an `unavailable`/`obsoleted:` disqualifies
  /// it outright. A platform NO `@available` names is unrestricted — available
  /// from version zero, not deprecated — which the accessors report by falling
  /// back to the `*` wildcard and then to that unrestricted default. A version
  /// is a `[Int]` component list ordered by `precedes`; a missing version reads
  /// as the zero floor, since an unversioned `deprecated`/`introduced` spans
  /// every version.
  private struct Availability {
    /// One platform's gate state — its introduced floor, its deprecation, and
    /// whether a hard `unavailable`/`obsoleted:` disqualifies it.
    fileprivate struct State {
      fileprivate var introduced: Array<Int>?
      fileprivate var deprecated: Array<Int>??
      fileprivate var disqualified: Bool = false
    }

    /// The per-platform states, keyed by platform name (`*` for the wildcard).
    fileprivate var states: Dictionary<String, State> = [:]

    /// Whether ANY platform carries a hard `unavailable`/`obsoleted:`, which
    /// disqualifies the init unconditionally — the deprecated extension never
    /// makes an unavailable init callable.
    fileprivate var disqualified: Bool {
      states.values.contains { $0.disqualified }
    }

    /// The introduced floor of every platform this gate RESTRICTS with one,
    /// keyed by platform — the platforms `covers(introduction:)` weighs. The
    /// `*` wildcard carries no floor, so it never appears here.
    fileprivate var introductions: Dictionary<String, Array<Int>> {
      states.compactMapValues(\.introduced)
    }

    /// The deprecation of every platform this gate deprecates, keyed by platform
    /// (a missing version reads as the zero floor) — the entries
    /// `covers(deprecation:)` must each find matched on the type.
    fileprivate var deprecations: Dictionary<String, Array<Int>> {
      states.compactMapValues { $0.deprecated.map { $0 ?? [] } }
    }

    /// The introduced floor `platform` reaches under this gate: its own when
    /// named, else the `*` wildcard's, else the unrestricted zero floor — an
    /// unnamed platform is available from the start.
    fileprivate func introduction(on platform: String) -> Array<Int> {
      states[platform]?.introduced
          ?? states["*"]?.introduced
          ?? []
    }

    /// The deprecation `platform` carries under this gate — its own when
    /// deprecated, else the `*` wildcard's when it deprecates every platform,
    /// else `nil` (not deprecated there). A missing version reads as the zero
    /// floor, so an unversioned deprecation spans every version.
    fileprivate func deprecation(on platform: String) -> Array<Int>? {
      if let own = states[platform]?.deprecated { return own ?? [] }
      if let wildcard = states["*"]?.deprecated { return wildcard ?? [] }
      return nil
    }
  }

  /// The ``Availability`` model of an attribute list — the init side of both
  /// coverage predicates. Only `@available` attributes contribute; each folds
  /// its per-platform arguments into the shared model.
  private static func availability(_ attributes: AttributeListSyntax)
      -> Availability {
    var model = Availability()
    for case let .attribute(attribute) in attributes
        where trailing(attribute.attributeName) == "available" {
      if case let .availability(arguments)? = attribute.arguments {
        absorb(arguments, into: &model)
      }
    }
    return model
  }

  /// The ``Availability`` model of the type's copied `@available` spellings —
  /// the gate side of both coverage predicates. Each `gate` entry is a verbatim
  /// `@available(...)` spelling `available` produced, so it re-parses into an
  /// `AttributeSyntax` and folds into the shared model.
  private static func availability(_ gate: Array<String>) -> Availability {
    var model = Availability()
    for spelling in gate {
      let attribute: AttributeSyntax = "\(raw: spelling)"
      if case let .availability(arguments)? = attribute.arguments {
        absorb(arguments, into: &model)
      }
    }
    return model
  }

  /// Folds one `@available` argument list into `model`, in either spelling.
  ///
  /// A SHORT form (`@available(macOS 10.0, iOS 13.0, *)`) lists a version
  /// restriction per platform — each an introduced floor — trailed by a bare
  /// `*` wildcard token; it carries no deprecation or unavailability. A LONG
  /// form (`@available(macOS, deprecated: 10.0)`, `@available(*, unavailable)`)
  /// LEADS with a single platform token — a name or `*` — that every following
  /// keyword argument (`introduced:`/`deprecated:`/`obsoleted:`, or a bare
  /// `deprecated`/`unavailable`) scopes to. Both a leading long-form `*` and a
  /// trailing short-form `*` land in the same branch: the long form scopes its
  /// following keywords to that `*`, while the short form's trailing `*` scopes
  /// nothing, so tracking it is harmless. `message:`/`renamed:` carry no
  /// availability and are ignored.
  private static func absorb(_ arguments: AvailabilityArgumentListSyntax,
                             into model: inout Availability) {
    var platform: String? = nil
    for argument in arguments {
      switch argument.argument {
      case let .availabilityVersionRestriction(restriction):
        let floor = version(restriction.version)
        model.states[restriction.platform.text, default: .init()]
            .introduced = floor
      case let .token(token):
        if token.text == "deprecated" {
          scope(platform) { $0.deprecated = .some(nil) }
        } else if token.text == "unavailable" {
          scope(platform) { $0.disqualified = true }
        } else {
          platform = token.text
        }
      case let .availabilityLabeledArgument(labeled):
        absorb(labeled, on: platform, into: &model)
      }
    }

    /// Applies `mutate` to the current long-form `platform`'s state, defaulting
    /// a first mention. A bare `deprecated`/`unavailable` before any platform
    /// token cannot occur in a well-formed gate, so an absent platform is a
    /// no-op.
    func scope(_ platform: String?,
               _ mutate: (inout Availability.State) -> Void) {
      guard let platform else { return }
      mutate(&model.states[platform, default: .init()])
    }
  }

  /// Folds one long-form labeled argument (`introduced:`/`deprecated:`/
  /// `obsoleted:`, with a version) onto `platform`'s state. `obsoleted:`
  /// disqualifies like `unavailable`; `message:`/`renamed:` are ignored.
  private static func absorb(_ labeled: AvailabilityLabeledArgumentSyntax,
                             on platform: String?,
                             into model: inout Availability) {
    guard let platform else { return }
    let floor: Array<Int>?
    if case let .version(tuple) = labeled.value { floor = version(tuple) }
    else { floor = nil }
    switch labeled.label.tokenKind {
    case .keyword(.introduced):
      model.states[platform, default: .init()].introduced = floor ?? []
    case .keyword(.deprecated):
      model.states[platform, default: .init()].deprecated = .some(floor)
    case .keyword(.obsoleted):
      model.states[platform, default: .init()].disqualified = true
    default:
      break
    }
  }

  /// A version tuple as its ordered `[Int]` components — `10.0` as `[10, 0]` —
  /// the shape `precedes` compares. A missing tuple is the empty (zero) floor.
  private static func version(_ tuple: VersionTupleSyntax?) -> Array<Int> {
    guard let tuple else { return [] }
    let major = Int(tuple.major.text) ?? 0
    let rest = tuple.components.compactMap { Int($0.number.text) }
    return [major] + rest
  }

  /// Whether `first` is at or before `second` as a version — component-wise,
  /// shorter padded with zeros, so `[10]` precedes `[10, 0]` and `[10, 0]`
  /// precedes `[10, 1]`. The empty floor precedes every version.
  private static func precedes(_ first: Array<Int>,
                               _ second: Array<Int>) -> Bool {
    let width = max(first.count, second.count)
    for index in 0 ..< width {
      let a = index < first.count ? first[index] : 0
      let b = index < second.count ? second[index] : 0
      if a != b { return a < b }
    }
    return true
  }

  /// The `@available` attributes on `declaration`, in source order, each as its
  /// verbatim spelling — the attributes a conformance extension must repeat.
  ///
  /// When the annotated type is itself availability-limited — `@available(*,
  /// deprecated)`, `@available(*, unavailable)`, or a platform gate such as
  /// `@available(macOS, unavailable)` — a BARE `extension <Type>: …` references
  /// the limited type and so WARNS (deprecated) or ERRORS (unavailable). The
  /// generated extension must carry the same `@available` to stay callable and
  /// warning-free, so the emission copies each attribute this returns onto the
  /// `extension`. Only `@available` propagates: a property wrapper or other
  /// attribute is irrelevant to the extension. The attribute name is matched on
  /// its trailing component, like the other helpers, so a qualified spelling is
  /// covered too. A type with no `@available` yields an empty array and the
  /// emitted extension is unchanged.
  internal static func available(_ declaration: some DeclGroupSyntax)
      -> Array<String> {
    available(declaration.attributes)
  }

  /// The `@available` spellings on an attribute list — the shared filter both
  /// the direct-declaration and enclosing-context availability draw on.
  private static func available(_ attributes: AttributeListSyntax)
      -> Array<String> {
    attributes.compactMap { attribute in
      guard case let .attribute(attribute) = attribute,
            trailing(attribute.attributeName) == "available" else {
        return nil
      }
      return attribute.trimmedDescription
    }
  }

  /// The `@available` spellings the ENCLOSING type context contributes, from
  /// innermost enclosing type outward, so the generated extension carries the
  /// availability of every type its qualified name references.
  ///
  /// A derived type nested in an availability-limited type — `@available(*,
  /// unavailable) struct Outer { @Serializable struct Inner { … } }` — expands
  /// to `extension Outer.Inner: …`, referencing the limited `Outer`; a bare
  /// extension then ERRORS (`unavailable`) or WARNS (`deprecated`) as it
  /// would for a limited annotated type. The direct declaration's own
  /// `@available` is not enough, since the LIMITATION is on the enclosing type,
  /// so the extension inherits the enclosing chain's gates too. The compiler
  /// detaches the annotated declaration (its `.parent` is nil in the plugin),
  /// but `MacroExpansionContext.lexicalContext` still yields the enclosing
  /// declaration groups, so their `@available` is readable here.
  ///
  /// Each enclosing entry that is a type declaration contributes its verbatim
  /// `@available` spellings; a non-type entry (a function or accessor the type
  /// nests in) carries no relevant availability and adds none. A type nested at
  /// top level has an empty enclosing context and inherits nothing.
  internal static func available(enclosing context: Array<Syntax>)
      -> Array<String> {
    context.flatMap { entry -> Array<String> in
      guard let group = group(entry) else { return [] }
      return available(group.attributes)
    }
  }

  /// The generic parameter names in scope at the derived type: its OWN clause
  /// first, then every parameter each ENCLOSING lexical entry contributes,
  /// innermost outward, deduplicated in that order.
  ///
  /// This is the SINGLE generic environment the derive computes: `constrained`
  /// (the conformance's `where` clause), `inferred` (the unannotated-field
  /// guard), and `inferable` (the init-candidate check) all consume it, so no
  /// caller recomputes a partial view. An in-scope parameter a field mentions
  /// gets a `where … : Serializable`/`Deserializable`, an unannotated field
  /// whose initializer mentions one is diagnosed `.inferred`, and an init whose
  /// own generic parameter is not one of these must be inferable from the
  /// passed fields to be a callable replacement.
  ///
  /// The own clause and the enclosing chain both feed it, and — beyond an
  /// enclosing generic TYPE, whose clause `parameters(enclosing:)` reads — an
  /// enclosing EXTENSION contributes the generic environment of the type it
  /// extends. A non-generic type in no generic context yields an empty array.
  internal static func environment(of declaration: some DeclGroupSyntax,
                                   enclosing context: Array<Syntax>)
      -> Array<String> {
    var scope = Array<String>()
    func add(_ names: some Sequence<String>) {
      for name in names where !scope.contains(name) { scope.append(name) }
    }
    if let structure = declaration.as(StructDeclSyntax.self) {
      add(structure.genericParameterClause?.parameters
          .map { $0.name.text } ?? [])
    }
    add(parameters(enclosing: context))
    return scope
  }

  /// The generic parameter names every ENCLOSING lexical entry contributes,
  /// innermost outward — the parameters in scope at the derived type beyond its
  /// own.
  ///
  /// A type nested in a generic outer — `struct Outer<T> { @Serializable struct
  /// Inner { var value: T } }` — stores the enclosing `T`, which the derive
  /// must recognise as a generic parameter to constrain the conformance on. An
  /// enclosing EXTENSION extends a generic type too — `extension Outer where T:
  /// … { @Serializable struct Inner { var value: T } }` — so `T` is likewise in
  /// scope; the extension contributes the generic arguments spelled on its
  /// extended type (`extension Outer<T>`) AND the parameters its `where` clause
  /// names, the only spellings from which the detached plugin can recover the
  /// extended type's parameters (a bare `extension Outer` carries neither, so
  /// it contributes none). As with `available(enclosing:)`, the detached
  /// declaration cannot reach these, but `lexicalContext` yields the enclosing
  /// groups. A non-generic or non-type/-extension entry contributes none.
  internal static func parameters(enclosing context: Array<Syntax>)
      -> Array<String> {
    context.flatMap { entry -> Array<String> in
      if let extended = entry.as(ExtensionDeclSyntax.self) {
        return extending(extended)
      }
      return generics(entry)?.parameters.map { $0.name.text } ?? []
    }
  }

  /// The generic parameter names an enclosing `extension` contributes: the
  /// identifiers its extended type's generic argument clause spells
  /// (`extension Outer<T>` → `T`) together with the SUBJECT of each `where`
  /// requirement (`extension Outer where T: P` → `T`), deduplicated. A bare
  /// `extension Outer` carries neither, so the detached plugin cannot recover
  /// the extended type's parameters and the extension contributes none.
  ///
  /// Only a requirement's LEFT side (its subject) is a parameter reference; the
  /// right side is the constraint (`P` in `T: P`), never a parameter to
  /// constrain, so it is not collected.
  private static func extending(_ extension: ExtensionDeclSyntax)
      -> Array<String> {
    var names = Set<String>()
    if let identifier =
        `extension`.extendedType.as(IdentifierTypeSyntax.self),
       let arguments = identifier.genericArgumentClause {
      collect(arguments, into: &names)
    }
    for requirement in `extension`.genericWhereClause?.requirements ?? [] {
      switch requirement.requirement {
      case let .conformanceRequirement(conformance):
        names.formUnion(references(conformance.leftType))
      case let .sameTypeRequirement(sameType):
        collect(sameType.leftType, into: &names)
      default:
        break
      }
    }
    return Array(names)
  }

  /// The `DeclGroupSyntax` an enclosing lexical entry names, or `nil` when the
  /// entry is not a type declaration (a function/accessor the type nests in).
  /// The concrete type declarations are matched individually: `DeclGroupSyntax`
  /// is the shared shape whose `attributes` the availability walk reads.
  private static func group(_ entry: Syntax) -> (any DeclGroupSyntax)? {
    if let structure = entry.as(StructDeclSyntax.self) { return structure }
    if let enumeration = entry.as(EnumDeclSyntax.self) { return enumeration }
    if let classes = entry.as(ClassDeclSyntax.self) { return classes }
    if let actor = entry.as(ActorDeclSyntax.self) { return actor }
    if let extended = entry.as(ExtensionDeclSyntax.self) { return extended }
    return nil
  }

  /// The generic parameter clause an enclosing lexical entry declares, or `nil`
  /// when the entry is not a generic type declaration. An extension carries no
  /// generic parameter clause of its own (its parameters come from the extended
  /// type), so it contributes none.
  private static func generics(_ entry: Syntax)
      -> GenericParameterClauseSyntax? {
    if let structure = entry.as(StructDeclSyntax.self) {
      return structure.genericParameterClause
    }
    if let enumeration = entry.as(EnumDeclSyntax.self) {
      return enumeration.genericParameterClause
    }
    if let classes = entry.as(ClassDeclSyntax.self) {
      return classes.genericParameterClause
    }
    return nil
  }

  /// The generic PARAMETERS a conditional conformance must constrain — those a
  /// serialized field type mentions, deduplicated in first-mention order.
  ///
  /// `serializer.field(…, self.<field>)` requires the field's value type to
  /// conform to `Serializable`, and `deserializer.decode()` requires
  /// `Deserializable`, so `struct Box<T> { var value: T }` type-checks only when
  /// `T` does. An UNCONDITIONAL `extension Box: Decant.Serializable` therefore
  /// fails; the correct derive is CONDITIONAL — `extension Box: … where …`.
  ///
  /// The requirement is expressed on the generic PARAMETERS the field type
  /// mentions, not on the field's WRITTEN type: Swift's grammar rejects a
  /// conformance requirement whose left side is an APPLIED concrete type
  /// (`where Array<T>: …`, `where Wrapper<T>: …`) — the left side must be a
  /// generic parameter or a dependent-member type — so an applied-type clause
  /// fails to type-check before the generated body ever runs. Constraining the
  /// mentioned parameters is always LEGAL (the left side is a generic
  /// parameter) and, for a container whose conditional conformance is element-
  /// driven (`Array<T>`, `Optional<T>`, `Set<T>`, `Dictionary<K, V>`), it is
  /// the exact lowering: `Array<T>: Serializable` holds precisely when
  /// `T: Serializable`, so `where T: Serializable` is neither weaker nor
  /// stronger. For a general applied type (`Wrapper<T>`), the parameter
  /// constraint is the tightest requirement Swift's grammar can express: the
  /// exotic "conforms for EVERY `T`" wrapper cannot be captured as an extension
  /// where-clause at all, so the mentioned parameter is the correct fallback.
  ///
  /// Only a parameter a field type mentions is constrained: a concrete
  /// `var x: Int` mentions none (and `Int: Serializable` would be redundant),
  /// and a phantom parameter no field mentions gets none. A non-generic type
  /// nested in no generic context yields an empty array and the extension stays
  /// unconditional.
  ///
  /// The in-scope generic parameters are the type's OWN clause AND every
  /// parameter an ENCLOSING type declares (`enclosing`): a type nested in a
  /// generic outer — `struct Outer<T> { @Serializable struct Inner { var value:
  /// T } }` — has no own clause, yet `Inner`'s field stores the OUTER `T`, so
  /// an UNCONDITIONAL `extension Outer.Inner: Serializable` type-checks for
  /// every `T` while its body's `field(…, self.value)` needs `T: Serializable`
  /// and fails to compile. Constraining the mentioned enclosing parameter —
  /// `extension Outer.Inner: … where T: Serializable` — is the correct
  /// conditional conformance. A parameter is a LEGAL requirement left side
  /// however it is scoped, so an enclosing parameter constrains just as an own
  /// one does.
  ///
  /// The direction selects the serialized fields — the deserialize side drops
  /// an initialized `let`, as `model` does — so the constraint set matches the
  /// fields the emission actually reads or writes. A parameter is emitted in
  /// the order the type DECLARES it (own parameters first, then the enclosing
  /// chain outward), so `Pair<A, B>` constrains `A` before `B` however the
  /// fields mention them.
  internal static func constrained(_ declaration: some DeclGroupSyntax,
                                   for direction: Direction,
                                   scope: Array<String>) -> Array<String> {
    guard let structure = declaration.as(StructDeclSyntax.self) else {
      return []
    }
    let environment = Set(scope)
    // A field written through a SAME-SCOPE typealias hides the generic it
    // resolves to: `struct S<T> { typealias Value = T; var value: Value }`
    // records only `Value`, which is no in-scope parameter, so the naive walk
    // emits NO `where T: …` and the generated unconditional extension then
    // serializes an unconstrained `T` that fails to type-check. Expanding the
    // field type through the type's own typealiases before the walk — `Value`
    // to `T`, `[Value]` to `[T]` — surfaces the hidden parameter (or dependent
    // member), so the correct conditional constraint is emitted.
    let aliases = self.aliases(structure.memberBlock.members)
    var mentioned = Set<String>()
    var dependents = Array<String>()
    for written in types(of: structure.memberBlock.members, for: direction) {
      let type = expand(written, through: aliases)
      // A field typed as — or WRAPPING — a dependent member of an in-scope
      // parameter needs that member ITSELF to conform. A bare `T.Element` in
      // `struct Box<T: Sequence> { var value: T.Element }` passes a `T.Element`
      // to `field(…)` and decodes a `T.Element`; a wrapped `[T.Element]` (or
      // `T.Element?`, `Wrapper<T.Element>`) serializes an `Array<T.Element>`
      // whose conformance likewise rests on `T.Element`. Constraining the base
      // `T` supplies neither, and would wrongly forbid a sequence whose ELEMENT
      // alone is serializable. A dependent member is a LEGAL where-clause left
      // side (unlike an applied `Wrapper<T>`), so emit the full `T.Element` as
      // the requirement — descending the wrapper to reach it — rather than
      // reduce it to `T`. A type surfacing no dependent member lowers to the
      // parameters it mentions (a bare `T`, a container's element parameter, or
      // a general applied type's mentioned parameters), the tightest legal
      // requirement Swift's grammar expresses for it.
      let members = self.dependents(of: type, in: environment)
      guard members.isEmpty else {
        for member in members where !dependents.contains(member) {
          dependents.append(member)
        }
        continue
      }
      mentioned.formUnion(references(type))
    }
    return scope.filter { mentioned.contains($0) } + dependents
  }

  /// The SAME-SCOPE typealiases `members` declare, mapping each alias name to
  /// its aliased type — the `typealias Value = T` declarations in the type's
  /// own member block, which `expand` substitutes to surface a generic
  /// parameter a field hides behind an alias.
  ///
  /// Only a plain (non-generic) alias contributes: a `typealias Boxed<U> =
  /// Wrapper<U>` binds its own parameter and does not stand for an outer
  /// parameter, so substituting a field's `Boxed<T>` for it would misread its
  /// argument. A `#if`-guarded alias is not descended — an alias resolving
  /// differently per branch is out of scope, so it is left to the compiler.
  private static func aliases(_ members: MemberBlockItemListSyntax)
      -> Dictionary<String, TypeSyntax> {
    var aliases = Dictionary<String, TypeSyntax>()
    for member in members {
      guard let alias = member.decl.as(TypeAliasDeclSyntax.self),
            alias.genericParameterClause == nil else {
        continue
      }
      aliases[alias.name.text] = alias.initializer.value
    }
    return aliases
  }

  /// `type` with each same-scope alias identifier substituted for its aliased
  /// type, recursively so a chained `typealias A = B; typealias B = T` resolves
  /// to `T` — the field type the constraint walk actually reasons over.
  ///
  /// A bare `IdentifierTypeSyntax` naming an alias becomes the aliased type
  /// (itself re-expanded); a wrapper (`[Value]`, `Value?`, `Wrapper<Value>`)
  /// has its element/argument spellings expanded and is rebuilt from them, so a
  /// hidden parameter is surfaced however deep it sits. A generic-argument-
  /// bearing identifier whose base name is an alias is NOT substituted (a plain
  /// alias takes no arguments), so only its arguments expand. The rebuild goes
  /// through the trimmed spelling and one re-parse, the same shape `sendable`
  /// and the `Availability` gate parse; a spelling that fails to re-parse falls
  /// back to `type` unchanged. `depth` bounds a pathological alias cycle.
  private static func expand(_ type: TypeSyntax,
                             through aliases: Dictionary<String, TypeSyntax>,
                             depth: Int = 16) -> TypeSyntax {
    guard depth > 0, !aliases.isEmpty else { return type }
    if let identifier = type.as(IdentifierTypeSyntax.self),
       identifier.genericArgumentClause == nil,
       let aliased = aliases[identifier.name.text] {
      return expand(aliased, through: aliases, depth: depth - 1)
    }
    let elements = wrapped(type)
    guard !elements.isEmpty else { return type }
    let expanded = elements.map {
      expand($0, through: aliases, depth: depth - 1).trimmedDescription
    }
    return rebuild(type, from: expanded) ?? type
  }

  /// `type` re-spelled with its wrapped/element types replaced by `elements`,
  /// re-parsed — an array/optional/IUO/dictionary sugar or an applied
  /// `Wrapper<…>` rebuilt around the (already alias-expanded) inner spellings.
  /// A shape `wrapped` does not describe, or a re-spelling that fails to parse,
  /// yields `nil` so `expand` keeps the original type.
  private static func rebuild(_ type: TypeSyntax, from elements: Array<String>)
      -> TypeSyntax? {
    let spelling: String
    if type.is(ArrayTypeSyntax.self), elements.count == 1 {
      spelling = "[\(elements[0])]"
    } else if type.is(OptionalTypeSyntax.self), elements.count == 1 {
      spelling = "\(elements[0])?"
    } else if type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self),
              elements.count == 1 {
      spelling = "\(elements[0])!"
    } else if type.is(DictionaryTypeSyntax.self), elements.count == 2 {
      spelling = "[\(elements[0]): \(elements[1])]"
    } else if let identifier = type.as(IdentifierTypeSyntax.self),
              identifier.genericArgumentClause != nil {
      spelling = "\(identifier.name.text)<\(elements.joined(separator: ", "))>"
    } else {
      return nil
    }
    let rebuilt = TypeSyntax("\(raw: spelling)")
    return rebuilt.hasError ? nil : rebuilt
  }

  /// The dependent-member requirements a field `type` contributes — the full
  /// spellings (`T.Element`, `T.A.B`) it needs conforming, whether `type` IS
  /// such a member or WRAPS one.
  ///
  /// A `MemberTypeSyntax` whose BASE is (recursively) an in-scope generic
  /// parameter is a dependent member itself and yields its own spelling. A
  /// wrapper — the array `[X]`, optional `X?`, implicitly-unwrapped `X!`,
  /// dictionary `[K: V]`, or a general applied `Wrapper<…>` sugar/spelling —
  /// descends into each wrapped/element type and yields the members THOSE hold,
  /// so `[T.Element]` surfaces `T.Element` just as the bare member does: the
  /// serialized `Array<T.Element>` conforms exactly when `T.Element` does. A
  /// member based on a concrete qualified symbol (`Namespace.T`, whose base is
  /// no parameter), and any type wrapping none, yields nothing, so it falls
  /// through to the mentioned-parameter lowering.
  private static func dependents(of type: TypeSyntax,
                                 in scope: Set<String>) -> Array<String> {
    if let member = type.as(MemberTypeSyntax.self),
       member.genericArgumentClause == nil,
       rooted(member.baseType, in: scope) {
      return [member.trimmedDescription]
    }
    return wrapped(type).flatMap { dependents(of: $0, in: scope) }
  }

  /// The element/wrapped types a container `type` holds — an array's element,
  /// an optional's or implicitly-unwrapped optional's wrapped type, a
  /// dictionary's key and value, or every generic argument of an applied
  /// `Wrapper<…>` — the types `dependents(of:in:)` descends to reach a nested
  /// dependent member. A non-container type wraps nothing and yields the empty
  /// array.
  private static func wrapped(_ type: TypeSyntax) -> Array<TypeSyntax> {
    if let array = type.as(ArrayTypeSyntax.self) {
      return [array.element]
    }
    if let optional = type.as(OptionalTypeSyntax.self) {
      return [optional.wrappedType]
    }
    if let iuo = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
      return [iuo.wrappedType]
    }
    if let dictionary = type.as(DictionaryTypeSyntax.self) {
      return [dictionary.key, dictionary.value]
    }
    if let identifier = type.as(IdentifierTypeSyntax.self),
       let arguments = identifier.genericArgumentClause {
      return arguments.arguments.compactMap { argument in
        guard case let .type(type) = argument.argument else { return nil }
        return type
      }
    }
    return []
  }

  /// Whether `type` roots a dependent-member spelling at an in-scope generic
  /// parameter — a bare `IdentifierTypeSyntax` named one of `scope`, or a
  /// `MemberTypeSyntax` (`T.A` in `T.A.B`) whose own base recursively does. A
  /// generic-argument-bearing base (`Wrapper<T>.Element`) is an applied type,
  /// not a parameter root, so it does not root a dependent member.
  private static func rooted(_ type: TypeSyntax,
                             in scope: Set<String>) -> Bool {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifier.genericArgumentClause == nil
          && scope.contains(identifier.name.text)
    }
    if let member = type.as(MemberTypeSyntax.self) {
      return member.genericArgumentClause == nil
          && rooted(member.baseType, in: scope)
    }
    return false
  }

  /// Whether `declaration` is a struct with a serialized stored property that
  /// infers its type from an initializer mentioning an in-scope generic
  /// parameter (`parameters`) — the shape `model` rejects with `.inferred`.
  ///
  /// The conditional conformance constrains each field's WRITTEN type
  /// (`constrained`), so a field with no annotation contributes no constraint
  /// even when its inferred type needs one. `var value = T.defaultValue`
  /// reconstructs a `T` the generated body requires be `Serializable`/
  /// `Deserializable`, but the derive cannot name the constraint, so the body
  /// would not type-check. Only a field whose INITIALIZER references a generic
  /// parameter is caught: an inferred `var count = 0` is concrete and fine, and
  /// an annotated `var value: T` carries its own constraint. A struct in no
  /// generic context has no parameters to mention, so it never triggers.
  ///
  /// `parameters` is the UNIFIED environment (`environment`), so a parameter an
  /// ENCLOSING type or extension declares — `struct Outer<T: Defaulted> {
  /// @Serializable struct Inner { var value = T.defaultValue } }` — is caught
  /// just as an own parameter is: the constraint builder would see no written
  /// type to constrain the enclosing `T` on either, so the guard must consult
  /// the same environment it does.
  ///
  /// The scan descends through `#if` (like `types(of:)` and `collect`), so a
  /// generic-dependent inferred field guarded by a conditional — `#if DEBUG var
  /// value = T.defaultValue #endif` — is caught too: `collect` still emits the
  /// field but `constrained` sees no written type to constrain, leaving the
  /// active branch's conformance unconditional and its `T` reconstruction
  /// unchecked. A top-level scan alone would miss it.
  private static func inferred(_ declaration: some DeclGroupSyntax,
                               mentioning parameters: Set<String>) -> Bool {
    guard let structure = declaration.as(StructDeclSyntax.self),
          !parameters.isEmpty else {
      return false
    }
    return inferred(structure.memberBlock.members, mentioning: parameters)
  }

  /// Whether `members` hold — at top level or descending through `#if` — an
  /// unannotated stored field whose initializer mentions a parameter in
  /// `parameters`. The `#if` walk mirrors `types(of:)`, so a conditionally-
  /// compiled inferred field is scanned like a top-level one.
  private static func inferred(_ members: MemberBlockItemListSyntax,
                               mentioning parameters: Set<String>) -> Bool {
    members.contains { member in
      if let block = member.decl.as(IfConfigDeclSyntax.self) {
        return block.clauses.contains { clause in
          guard case let .decls(members)? = clause.elements else {
            return false
          }
          return inferred(members, mentioning: parameters)
        }
      }
      guard let binding = member.decl.as(VariableDeclSyntax.self),
            !typed(binding.modifiers) else {
        return false
      }
      return binding.bindings.contains { pattern in
        guard !computed(pattern.accessorBlock),
              pattern.typeAnnotation == nil,
              let value = pattern.initializer?.value else {
          return false
        }
        return !mentions(value).isDisjoint(with: parameters)
      }
    }
  }

  /// The identifier names the expression `value` references STRUCTURALLY — the
  /// expression-tree analogue of `references`, sharing its `collect` walk so an
  /// unannotated field's initializer is tested for a generic-parameter mention
  /// the SAME way a field type is.
  ///
  /// The walk skips the trailing member of a qualified member access, so a
  /// concrete `Namespace.T()` in a `struct Holder<T>` does NOT surface `T`: the
  /// base (`Namespace`) is descended but the `.T` declName is a member of a
  /// concrete symbol, not a reference to the parameter. A flat token scan would
  /// collect the `.T` token and wrongly raise `.inferred` on a field whose
  /// inferred type is concrete.
  private static func mentions(_ value: ExprSyntax) -> Set<String> {
    var names = Set<String>()
    collect(value, into: &names)
    return names
  }

  /// The written types of the stored fields `members` serialize, in declaration
  /// order and descending through `#if`, mirroring `fields`' skip rules — a
  /// type-level member, a computed property, and (on deserialize) an initialized
  /// `let` contribute none. A field with no written annotation (`var count = 0`)
  /// or a tuple binding carries no single type and is skipped: it cannot
  /// reference a generic parameter this analysis could name.
  private static func types(_ binding: VariableDeclSyntax,
                            for direction: Direction) -> Array<TypeSyntax> {
    guard !typed(binding.modifiers) else { return [] }
    let constant = binding.bindingSpecifier.tokenKind == .keyword(.let)
    var types = Array<TypeSyntax>()
    for (pattern, type) in bindings(of: binding) {
      guard !computed(pattern.accessorBlock) else { continue }
      guard !(direction == .deserialize
                && constant && pattern.initializer != nil) else { continue }
      if let type { types.append(type) }
    }
    return types
  }

  /// The written types of every serialized stored field `members` hold, walking
  /// their `#if` structure so a conditionally-compiled field's type is included
  /// too — a generic a `#if var value: T` guards must still be constrained.
  private static func types(of members: MemberBlockItemListSyntax,
                            for direction: Direction) -> Array<TypeSyntax> {
    var types = Array<TypeSyntax>()
    for member in members {
      if let block = member.decl.as(IfConfigDeclSyntax.self) {
        for clause in block.clauses {
          guard case let .decls(members)? = clause.elements else { continue }
          types += self.types(of: members, for: direction)
        }
      } else if let binding = member.decl.as(VariableDeclSyntax.self) {
        types += self.types(binding, for: direction)
      }
    }
    return types
  }

  /// The identifier names `type` references STRUCTURALLY — every
  /// `IdentifierTypeSyntax` name in the type tree, but NOT the trailing member
  /// component of a qualified `MemberTypeSyntax`, whose base alone names a
  /// type. A bare `T` yields `T`, a nested `Array<T>` yields `Array` and `T`,
  /// and a `Dictionary<K, V>` yields `Dictionary`, `K`, and `V` — the caller
  /// intersects these with the in-scope generic parameters, so the container
  /// names (`Array`, `Dictionary`) fall away.
  ///
  /// The walk is STRUCTURAL, not a flat token scan, so a qualified concrete
  /// type whose member name happens to equal a generic parameter —
  /// `Namespace.T` in a `struct Holder<T>` — does NOT surface that `T`: the
  /// base component (`Namespace`) is descended, but the `.T` member is part of
  /// a fully qualified concrete type, not a reference to the parameter, so it
  /// is not collected. A flat token scan would collect the `.T` token and
  /// wrongly constrain on `Holder`'s `T`. When a generic parameter is
  /// itself the BASE — `T.Element`, a dependent-member spelling — the base `T`
  /// IS descended and collected, so a genuine associated-type dependence is
  /// kept; only the trailing member component is skipped.
  private static func references(_ type: TypeSyntax) -> Set<String> {
    var names = Set<String>()
    collect(type, into: &names)
    return names
  }

  /// Descends `syntax` collecting the base/standalone identifier names into
  /// `names`, skipping the trailing member component of every qualified
  /// reference — a type's `MemberTypeSyntax` (`references`) OR an expression's
  /// `MemberAccessExprSyntax` (`mentions`), so ONE structural walk serves both
  /// the field-type and the inferred-initializer paths.
  ///
  /// A generic argument clause is a child of its `IdentifierTypeSyntax`, so
  /// recursing over children walks `Array<T>`'s `T`; a member type descends
  /// its base but not its `.name`, and a member access descends its base but
  /// not its `.declName`. A standalone `IdentifierTypeSyntax` (a type `T`) or
  /// `DeclReferenceExprSyntax` (an expression `T`) contributes its name.
  private static func collect(_ syntax: some SyntaxProtocol,
                              into names: inout Set<String>) {
    if let member = syntax.as(MemberTypeSyntax.self) {
      collect(member.baseType, into: &names)
      if let arguments = member.genericArgumentClause {
        collect(arguments, into: &names)
      }
      return
    }
    if let access = syntax.as(MemberAccessExprSyntax.self) {
      if let base = access.base { collect(base, into: &names) }
      return
    }
    if let identifier = syntax.as(IdentifierTypeSyntax.self) {
      names.insert(identifier.name.text)
    }
    if let reference = syntax.as(DeclReferenceExprSyntax.self) {
      names.insert(reference.baseName.text)
    }
    for child in syntax.children(viewMode: .sourceAccurate) {
      collect(child, into: &names)
    }
  }

  /// Whether the annotated `declaration` carries actor isolation the emitted
  /// witnesses must shed — a global-actor attribute (`@MainActor` or a custom
  /// `@SomeGlobalActor`), which is a custom (non-built-in) attribute like a
  /// property wrapper.
  ///
  /// A global-actor-isolated type isolates its members, so a plain emitted
  /// `serialize`/`deserialize` INHERITS that isolation and cannot satisfy the
  /// NONISOLATED `Serializable`/`Deserializable` requirement — a Swift 6
  /// conformance-isolation error. The emission marks the witnesses
  /// `nonisolated` when this answers `true`, restoring them to the
  /// requirement's isolation. A value type's `Sendable` stored properties stay
  /// reachable from the nonisolated body — serialize reads `self.<field>` and
  /// deserialize calls the memberwise init — so the bodies compile.
  ///
  /// The derive's OWN attributes (`@Serializable`/`@Deserializable` and the
  /// peer markers `@DecantName`/`@DecantSkip`) sit in the same attribute list
  /// and are custom attributes too, so they are excluded here — otherwise a
  /// derive on every type would read as isolated. A built-in (`@available`,
  /// `@frozen`) imposes no isolation and passes through, matching `wrapped`. An
  /// explicit `nonisolated` modifier already leaves the type unisolated and
  /// carries no attribute, so it needs no prefix.
  internal static func isolated(_ declaration: some DeclGroupSyntax) -> Bool {
    declaration.attributes.contains { attribute in
      guard case let .attribute(attribute) = attribute,
            let name = trailing(attribute.attributeName) else {
        return false
      }
      switch name {
      case "Serializable", "Deserializable", "DecantName", "DecantSkip":
        return false
      case let name where builtins.contains(name):
        return false
      default:
        return true
      }
    }
  }

  /// Whether any field in `segments` carries a written type that is not a
  /// recognizably-`Sendable` standard type, so a nonisolated witness of a
  /// global-actor-isolated type could not safely reach it. Recurses through the
  /// `#if` clauses like `carries`. A field of no written type is judged safe:
  /// its spelling gives nothing to reject, so it is left to the compiler.
  private static func risky(_ segments: Array<Segment>) -> Bool {
    segments.contains { segment in
      switch segment {
      case let .unconditional(run):
        return run.contains { field in field.type.map { !safe($0) } ?? false }
      case let .conditional(clauses):
        return clauses.contains { risky($0.segments) }
      }
    }
  }

  /// Whether the written type spelling `type` names a standard type known to be
  /// `Sendable` by value, so an isolated stored property of it stays reachable
  /// from a nonisolated witness. An optional (`T?`) or array (`[T]`) of a safe
  /// element is safe; a `Sendable` composition (`P & Sendable`) is safe; every
  /// other spelling — a bare user nominal the macro cannot resolve — is treated
  /// as possibly non-Sendable. Deliberately conservative on the SAFE side: it
  /// names only the standard value types, so a false "risky" (a user `Sendable`
  /// type) diagnoses rather than a false "safe" miscompiling.
  ///
  /// The GENERIC standard spellings `Optional<T>` and `Array<T>` are the
  /// desugared forms of `T?` and `[T]` — Sendable under the same condition on
  /// the element — so each is normalized to its sugar and the same check runs,
  /// rather than falling through to the bare-name set and diagnosing a
  /// valid model. Only the sugars the allowlist recognizes are desugared here:
  /// dictionary sugar (`[K: V]`) is deliberately excluded above, so
  /// `Dictionary<K, V>` is not desugared either, keeping the two spellings in
  /// step.
  private static func safe(_ type: String) -> Bool {
    if type.hasSuffix("?"), !type.hasPrefix("(") {
      return safe(String(type.dropLast()))
    }
    if type.hasPrefix("["), type.hasSuffix("]"), !type.contains(":") {
      return safe(String(type.dropFirst().dropLast()))
    }
    if let element = element(of: "Optional", in: type) {
      return safe(element)
    }
    if let element = element(of: "Array", in: type) {
      return safe(element)
    }
    if sendable(type) { return true }
    return sendables.contains(type)
  }

  /// Whether the type spelling `type` names `Sendable` as a real identifier —
  /// the bare protocol (`Sendable`), an existential over it (`any Sendable`),
  /// or a composition one of whose members is exactly `Sendable`
  /// (`T & Sendable`, `Sendable & P`). A composition carrying `Sendable`
  /// existentially is Sendable, so it is safe to reach from a nonisolated
  /// witness.
  ///
  /// The spelling is parsed and its structure inspected rather than
  /// substring-matched: a bare `type.contains("Sendable")` treats a
  /// `NonSendable`, a `MySendableThing`, or an `Array<NonSendable>` as safe, so
  /// the nonisolated witness would then touch actor-isolated non-Sendable state
  /// the compiler rejects. Matching the identifier `Sendable` as a component —
  /// `IdentifierTypeSyntax` named `Sendable`, itself or under an `any`, or a
  /// member of a `&` composition — accepts only the genuinely-Sendable
  /// spellings and diagnoses the rest.
  private static func sendable(_ type: String) -> Bool {
    sendable(TypeSyntax("\(raw: type)"))
  }

  /// Whether the parsed `type` is `Sendable`, `any Sendable`, or a composition
  /// with a `Sendable` member — the syntax-tree half of the string overload.
  private static func sendable(_ type: TypeSyntax) -> Bool {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifier.name.text == "Sendable"
    }
    if let some = type.as(SomeOrAnyTypeSyntax.self) {
      return sendable(some.constraint)
    }
    if let composition = type.as(CompositionTypeSyntax.self) {
      return composition.elements.contains { sendable($0.type) }
    }
    return false
  }

  /// The single generic argument of `type` when it is the standard spelling
  /// `wrapper<Element>` — `element(of: "Optional", in: "Optional<Int>")` yields
  /// `"Int"` — or `nil` when `type` is not that wrapper applied to exactly one
  /// argument. The match is on the trimmed spelling, so a nested `Optional<
  /// Array<Int>>` yields `"Array<Int>"` for the caller to recurse on. A
  /// comma-bearing argument list (a two-parameter generic) is not a single
  /// element and yields `nil`.
  private static func element(of wrapper: String, in type: String) -> String? {
    let prefix = "\(wrapper)<"
    guard type.hasPrefix(prefix), type.hasSuffix(">") else { return nil }
    let inner = type.dropFirst(prefix.count).dropLast()
    guard !inner.contains(",") else { return nil }
    return String(inner)
  }

  /// The standard-library value types known `Sendable` by their bare spelling.
  /// A field of one of these stays readable from a nonisolated witness of an
  /// isolated type; anything outside this set the macro cannot vouch for.
  private static let sendables: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Float", "Double", "Float16", "Bool", "Character", "String",
    "Substring", "Unicode.Scalar", "StaticString",
  ]

  /// Whether `modifiers` mark the declaration `lazy`. A `lazy var` has a
  /// mutating getter and is absent from the synthesized memberwise
  /// initializer, so it is neither serializable nor a memberwise parameter.
  private static func lazy(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
  }

  /// The Swift built-in declaration attributes that can appear on a stored
  /// property and are NOT property wrappers, so `wrapped` passes a property
  /// carrying one through rather than rejecting it. A property wrapper is a
  /// user-defined custom type; these are the known compiler-defined spellings.
  /// Matched on the trailing name component, like the marker allowlist, so a
  /// qualified spelling (were one to occur) is covered too.
  private static let builtins: Set<String> = [
    "available", "objc", "nonobjc", "inline", "inlinable", "usableFromInline",
    "discardableResult", "dynamicMemberLookup", "dynamicCallable", "IBOutlet",
    "IBInspectable", "IBAction", "NSManaged", "NSCopying", "GKInspectable",
    "preconcurrency", "Sendable", "unchecked", "frozen",
    "warn_unqualified_access",
  ]

  /// Whether `attributes` mark the declaration property-wrapper-backed: a
  /// custom attribute — an `AttributeSyntax` naming a type, whether
  /// unqualified (`@W`, an `IdentifierTypeSyntax`) or qualified (`@MyModule.W`,
  /// a `MemberTypeSyntax`) — that is neither one of the derive's own peer
  /// markers `@DecantName` / `@DecantSkip` nor a Swift built-in declaration
  /// attribute (`builtins`, e.g. `@available`), all of which pass through. A
  /// qualified wrapper's `attributeName` is a member type, so matching only the
  /// plain identifier would let it bypass the guard. The allowlist matches the
  /// trailing name component, so a marker passes however it is spelled. A
  /// wrapper's memberwise parameter is the wrapper storage, not the wrapped
  /// value, so the syntactic derive cannot keep the two sides consistent.
  private static func wrapped(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { attribute in
      guard case let .attribute(attribute) = attribute,
            let name = trailing(attribute.attributeName) else {
        return false
      }
      switch name {
      case "DecantName", "DecantSkip":
        return false
      case let name where builtins.contains(name):
        return false
      default:
        return true
      }
    }
  }

  /// The trailing name component of an attribute's `attributeName`, or `nil`
  /// when it is neither a plain identifier (`W`, an `IdentifierTypeSyntax`) nor
  /// a qualified member type (`MyModule.W`, a `MemberTypeSyntax`, whose
  /// trailing component is what an unqualified marker would match). A
  /// non-nominal attribute name has no simple component and is not a candidate.
  private static func trailing(_ type: TypeSyntax) -> String? {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifier.name.text
    }
    if let member = type.as(MemberTypeSyntax.self) {
      return member.name.text
    }
    return nil
  }

  /// Whether `modifiers` mark the declaration a type-level (`static`/`class`)
  /// member rather than an instance stored property. A type property is neither
  /// serialized state nor a memberwise-init parameter, so it contributes no
  /// field.
  private static func typed(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains {
      switch $0.name.tokenKind {
      case .keyword(.static), .keyword(.class):
        return true
      default:
        return false
      }
    }
  }

  /// The bindings `binding` declares, each paired with the written type that
  /// applies to it — the SINGLE place the multi-binding type-propagation rule
  /// lives, so every field-collection walk resolves a binding's type the same
  /// way.
  ///
  /// SwiftSyntax annotates only the TRAILING binding of a `var x, y: Int` line
  /// (`y: Int`), leaving the earlier `x` with no `typeAnnotation` though Swift
  /// gives it the shared `Int`. A binding with its own annotation keeps it; an
  /// annotation-less binding takes the type of the NEXT annotated binding, as
  /// a run of comma-separated names shares the following declaration's type
  /// (`var a: String, b, c: Int` — `b` and `c` are `Int`). A binding that
  /// carries an INITIALIZER instead infers its type from that value, not the
  /// trailing annotation (`var x = 1, y: Int` — `x` is not `Int`), so it takes
  /// no propagated type. A tuple binding (`var (x, y): (Int, String)`) carries
  /// its own annotation on the one binding, so nothing propagates across it.
  private static func bindings(of binding: VariableDeclSyntax)
      -> Array<(binding: PatternBindingSyntax, type: TypeSyntax?)> {
    let patterns = Array(binding.bindings)
    return patterns.indices.map { index in
      let pattern = patterns[index]
      if let type = pattern.typeAnnotation?.type {
        return (pattern, type)
      }
      guard pattern.initializer == nil else { return (pattern, nil) }
      // An annotation-less, initializer-less binding shares the type of the
      // next binding that carries one.
      let shared = patterns[index...]
          .lazy.compactMap { $0.typeAnnotation?.type }.first
      return (pattern, shared)
    }
  }

  /// Appends the stored properties `pattern` binds to `fields`, in declaration
  /// order, carrying `type` (the binding's written type annotation, or `nil`)
  /// on each identifier field.
  ///
  /// An identifier binds one property named for it, typed `type`. A tuple
  /// binding — a `var (x, y): (Int, Int)` line, for which Swift synthesizes
  /// `x` and `y` as separate stored properties — destructures into one property
  /// per element, named for its element pattern; the whole tuple type SPLITS
  /// per element, so `x` records `Int` and `y` records `Int`, each with its own
  /// coerced `decode() as Int`. Per-leaf coercion matters when an extension
  /// adds a same-labelled overload (`init(x: String, y: String)`): the
  /// memberwise init then shares the label, and the `as Int` casts pick the
  /// `Int` init, disambiguating the otherwise-ambiguous `Self(x:y:)` call. A
  /// tuple whose element arity does NOT match its annotation (a spelling the
  /// macro cannot split leaf-for-leaf) drops to a `nil` type per element, the
  /// safe fallback that forces a non-match. A `_` element binds nothing, so it
  /// contributes no property. Nesting recurses, splitting the nested tuple type
  /// alongside.
  ///
  /// A name is stored in its canonical (backtick-stripped) spelling: a
  /// `` var `self` `` binding's token text carries the backticks, but the
  /// serialization-name key, the memberwise argument label, and the serialize
  /// member access each re-derive a source-safe spelling from the bare word.
  /// `Identifier` performs that canonicalization.
  private static func append(_ pattern: PatternSyntax,
                             typed type: TypeSyntax?,
                             to fields: inout Array<Field>) {
    if let identifier = pattern.as(IdentifierPatternSyntax.self) {
      let name = Identifier(identifier.identifier)?.name
          ?? identifier.identifier.text
      fields.append(Field(name: name, type: type?.trimmedDescription,
                          coercion: type.flatMap(coercion)))
    } else if let tuple = pattern.as(TuplePatternSyntax.self) {
      let elements = split(type, count: tuple.elements.count)
      for (element, type) in zip(tuple.elements, elements) {
        append(element.pattern, typed: type, to: &fields)
      }
    }
  }

  /// The per-element written types a tuple `pattern` of `count` elements
  /// destructures `type` into, or `count` `nil`s when `type` cannot be split
  /// leaf-for-leaf.
  ///
  /// `var (x, y): (Int, Int)` splits `(Int, Int)` into `[Int, Int]`, one type
  /// per element, so each field records its own type and decodes with a coerced
  /// `decode() as Int`. A `type` that is not a `TupleTypeSyntax` (an inferred
  /// tuple binding with no annotation, `var (x, y) = (1, 2)`) or whose element
  /// arity does not match the pattern's yields `nil`s: the macro cannot map
  /// element to type, so the safe type-less fallback keeps each field a
  /// non-match. A labelled tuple type element keeps its type — the label is
  /// dropped, as the field name comes from the element PATTERN, not the type.
  private static func split(_ type: TypeSyntax?, count: Int)
      -> Array<TypeSyntax?> {
    guard let tuple = type?.as(TupleTypeSyntax.self),
          tuple.elements.count == count else {
      return Array(repeating: nil, count: count)
    }
    return tuple.elements.map { $0.type }
  }

  /// The `decode() as <spelling>` cast target for a field of written `type`,
  /// or `nil` when the type admits no legal coercion and the read must stay a
  /// bare `decode()`.
  ///
  /// Normally the trimmed `type` spelling. An implicitly-unwrapped optional
  /// `T!` is an `ImplicitlyUnwrappedOptionalType` node whose `!` is only sugar
  /// on the annotation — Swift rejects it as a coercion target (`as T!` is not
  /// legal) — so it is normalized to the optional `T?` spelling, which IS a
  /// legal coercion and which the field's `T!` memberwise-init parameter
  /// accepts (`Optional` conforms to `Deserializable`). Only the outermost IUO
  /// sugar is rewritten; a nested `T` is left verbatim.
  ///
  /// An opaque `some P` field is a `SomeOrAnyType` node whose specifier is
  /// `some`: Swift permits `some` only in a declaration position, never as a
  /// cast target (`decode() as some P` is rejected), so it yields `nil` and the
  /// read stays a bare `decode()` the opaque memberwise-init parameter drives —
  /// exactly the type-less fallback. An `any P` existential, by contrast, IS a
  /// legal coercion target, so it keeps its spelling.
  private static func coercion(of type: TypeSyntax) -> String? {
    if let some = type.as(SomeOrAnyTypeSyntax.self),
       some.someOrAnySpecifier.tokenKind == .keyword(.some) {
      return nil
    }
    guard let iuo =
        type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) else {
      return type.trimmedDescription
    }
    return "\(iuo.wrappedType.trimmedDescription)?"
  }

  /// Whether `block` makes its binding a computed property, rather than a
  /// stored property (whose accessor block, if present, holds only
  /// `willSet`/`didSet` observers).
  ///
  /// A bare getter (`{ … }`) is computed; an accessor list is computed when
  /// it names any accessor that supplies or intercepts storage, leaving pure
  /// observers as the only stored case.
  private static func computed(_ block: AccessorBlockSyntax?) -> Bool {
    guard let block else { return false }
    switch block.accessors {
    case .getter:
      return true
    case let .accessors(accessors):
      return accessors.contains { computing($0.accessorSpecifier.tokenKind) }
    }
  }

  /// Whether `kind` names an accessor that supplies or intercepts storage, as
  /// opposed to a `willSet`/`didSet` observer.
  private static func computing(_ kind: TokenKind) -> Bool {
    switch kind {
    case .keyword(.get), .keyword(.set), .keyword(._read),
         .keyword(._modify), .keyword(.unsafeAddress),
         .keyword(.unsafeMutableAddress):
      return true
    default:
      return false
    }
  }
}

/// Expands `@Serializable` to a `Serializable` conformance whose `serialize`
/// writes each stored property in declaration order.
public struct SerializableMacro: ExtensionMacro {
  public static func expansion(of node: AttributeSyntax,
                               attachedTo declaration: some DeclGroupSyntax,
                               providingExtensionsOf type: some TypeSyntaxProtocol,
                               conformingTo protocols: Array<TypeSyntax>,
                               in context: some MacroExpansionContext)
      throws -> Array<ExtensionDeclSyntax> {
    guard let model =
        DecantModel.model(of: declaration, for: .serialize,
                          in: context, at: node) else {
      return []
    }

    let name = trimmed(type)
    // The serializer generic parameter takes a hygienic name: a readable `S`
    // shadows any same-named generic parameter of the type or an enclosing
    // context (an error under Swift 6), and the detached declaration cannot
    // reveal which names those are.
    let serializer = parameter(named: "Serializer", in: context)
    // The sub-serializer local is hygienic so a field named `structure` (or
    // `serializer`) reads through `self`, never this introduced name.
    let structure = context.makeUniqueName("structure").text
    // The field count is a plain literal when no `#if` guards a field; a
    // conditional field makes it a hygienic local a mirrored `#if` accumulates,
    // since the plugin cannot resolve which branch the compiler activates.
    let field = { (field: DecantModel.Field) in
      "    try \(structure).field(\(key(field.name)), "
        + "self.\(member(field.name)))"
    }
    let count = context.makeUniqueName("fields").text
    let fields = preamble(model.segments, into: count)
    let lines = writes(model.segments, with: field)
    // The sub-serializer local is mutated by each `field(…)` write, so it is a
    // `var` — unless the struct has no stored property at all, when no write
    // mutates it and a `var` would warn "never mutated"; a fieldless struct
    // binds it `let`. (A struct whose only fields are conditional still emits a
    // guarded write, so it stays `var`.)
    let binding = empty(model.segments) ? "let" : "var"
    // An availability-limited type — `@available(*, deprecated)`,
    // `@available(*, unavailable)`, or a platform gate — makes a bare
    // `extension <Type>` warn or error, so its `@available` leads the
    // extension. A type nested in a limited ENCLOSING type has the same problem
    // through its qualified name (`extension Outer.Inner` references a limited
    // `Outer`), so the enclosing chain's `@available` leads the extension too.
    let available = attributed(DecantModel.available(declaration)
        + DecantModel.available(enclosing: context.lexicalContext))
    // A global-actor-isolated type (`@MainActor`) isolates its members, so a
    // plain `serialize` would inherit that isolation and could not satisfy the
    // nonisolated `Serializable` requirement (a Swift 6 conformance-isolation
    // error). Marking the witness `nonisolated` restores the requirement's
    // isolation; a non-isolated type emits it unchanged.
    let nonisolated = DecantModel.isolated(declaration) ? "nonisolated " : ""
    // A generic type whose serialized field's type mentions a generic parameter
    // type-checks only when that parameter is `Serializable`
    // (`serializer.field(…)` requires it), so the conformance is CONDITIONAL: a
    // `where T: Decant.Serializable` per referenced parameter — including a
    // parameter an ENCLOSING generic type declares that a field stores. A
    // non-generic type in no generic context constrains nothing and the
    // conformance stays unconditional.
    let scope = DecantModel.environment(of: declaration,
                                        enclosing: context.lexicalContext)
    let clause =
        constrained(DecantModel.constrained(declaration, for: .serialize,
                                             scope: scope),
                    to: "Decant.Serializable")

    let body = """
    \(available)extension \(name): Decant.Serializable\(clause) {
      \(nonisolated)public func serialize<\(serializer)>(into serializer: \
    consuming \(serializer))
          throws(\(serializer).Failure) -> \(serializer)
          where \(serializer): Decant.Serializer & ~Copyable & ~Escapable {
    \(fields)    \(binding) \(structure) = (consume serializer).structure(\
    \(key(canonical(type))), fields: \(counted(model.segments, as: count)))
    \(lines)
        return try \(structure).end()
      }
    }
    """

    return try [ExtensionDeclSyntax("\(raw: body)")]
  }
}

/// Expands `@Deserializable` to a `Deserializable` conformance whose
/// `deserialize` reads each stored property in declaration order — the inverse
/// field order of `@Serializable`.
public struct DeserializableMacro: ExtensionMacro {
  public static func expansion(of node: AttributeSyntax,
                               attachedTo declaration: some DeclGroupSyntax,
                               providingExtensionsOf type: some TypeSyntaxProtocol,
                               conformingTo protocols: Array<TypeSyntax>,
                               in context: some MacroExpansionContext)
      throws -> Array<ExtensionDeclSyntax> {
    guard let model =
        DecantModel.model(of: declaration, for: .deserialize,
                          in: context, at: node) else {
      return []
    }

    let name = trimmed(type)
    // The deserializer generic parameter takes a hygienic name: a readable `D`
    // shadows any same-named generic parameter of the type or an enclosing
    // context (an error under Swift 6), and the detached declaration cannot
    // reveal which names those are.
    let deserializer = parameter(named: "Deserializer", in: context)
    // Each field is read directly in its memberwise-init argument position, so
    // the init parameter supplies `decode`'s contextual result type — the read
    // of a field whose type is inferred from its initializer (`var count = 0`,
    // no written annotation) type-checks with no annotation to lend it. Swift
    // evaluates call arguments left-to-right in source order, so the reads run
    // in declaration order; each `decode` mutation of `deserializer` completes
    // before the next argument, so exclusive access holds. No decoded
    // temporary is introduced, which is also why a field named `deserializer`
    // cannot shadow the `inout` parameter `end` reads through.
    //
    // Each field of a known declared type is read with an EXPLICIT type
    // (`decode() as <type>`), so the field type — not the otherwise-
    // unconstrained generic `decode()` — drives overload resolution to the
    // matching init. Annotating unconditionally (not only when `model`
    // detected a primary-declaration ambiguity) disambiguates the call against
    // an init declared in an EXTENSION too: such an init does NOT suppress the
    // synthesized memberwise init, so both participate in overload resolution,
    // which the macro never sees — yet the annotation resolves the call
    // regardless, and is harmless when only one init is viable. A field of no
    // captured type (an inferred `var count = 0`, or a tuple element) cannot be
    // annotated, so it keeps the bare `decode()`, whose contextual result type
    // the sole memberwise-init parameter still supplies. An IUO field annotates
    // with the normalized optional spelling (`coercion`), since `as T!` is not
    // a legal coercion target.
    let argument = { (field: DecantModel.Field) in
      guard let coercion = field.coercion else {
        return "\(label(field.name)): deserializer.decode()"
      }
      return "\(label(field.name)): deserializer.decode() as \(coercion)"
    }
    // The reconstructed value binds to a hygienic local so `end` runs after all
    // reads and before the return, without a field named `value` colliding.
    let value = context.makeUniqueName("value").text
    let count = context.makeUniqueName("fields").text
    let fields = preamble(model.segments, into: count)
    // A `#if` cannot appear inside an initializer's argument list, so a
    // conditional field forces a per-branch `Self(…)` call — the cartesian
    // product of the blocks' clauses, each listing its active fields inline,
    // all wrapped in the mirrored guards. `structure`/`end` frame the whole
    // tree once, outside the branches; only one branch compiles, so the shared
    // `value` local is declared and returned within each.
    let tree = builds(model.segments, with: argument, binding: value)
    // An availability-limited type — `@available(*, deprecated)`,
    // `@available(*, unavailable)`, or a platform gate — makes a bare
    // `extension <Type>` warn or error, so its `@available` leads the
    // extension. A type nested in a limited ENCLOSING type has the same problem
    // through its qualified name (`extension Outer.Inner` references a limited
    // `Outer`), so the enclosing chain's `@available` leads the extension too.
    let available = attributed(DecantModel.available(declaration)
        + DecantModel.available(enclosing: context.lexicalContext))
    // A global-actor-isolated type (`@MainActor`) isolates its members, so a
    // plain `deserialize` would inherit that isolation and could not satisfy
    // the nonisolated `Deserializable` requirement (a Swift 6 conformance-
    // isolation error). Marking the witness `nonisolated` restores the
    // requirement's isolation; a non-isolated type emits it unchanged.
    let nonisolated = DecantModel.isolated(declaration) ? "nonisolated " : ""
    // A generic type whose serialized field's type mentions a generic parameter
    // type-checks only when that parameter is `Deserializable`
    // (`deserializer.decode()` requires it), so the conformance is CONDITIONAL:
    // a `where T: Decant.Deserializable` per referenced parameter — including a
    // parameter an ENCLOSING generic type declares that a field stores. A
    // non-generic type in no generic context constrains nothing and the
    // conformance stays unconditional.
    let scope = DecantModel.environment(of: declaration,
                                        enclosing: context.lexicalContext)
    let clause =
        constrained(DecantModel.constrained(declaration, for: .deserialize,
                                             scope: scope),
                    to: "Decant.Deserializable")

    let body = """
    \(available)extension \(name): Decant.Deserializable\(clause) {
      \(nonisolated)public static func deserialize<\(deserializer)>(from \
    deserializer: inout \(deserializer))
          throws(\(deserializer).Failure) -> Self
          where \(deserializer): Decant.Deserializer & ~Copyable \
    & ~Escapable {
    \(fields)    try deserializer.structure(\(key(canonical(type))), \
    fields: \(counted(model.segments, as: count)))
    \(tree)
      }
    }
    """

    return try [ExtensionDeclSyntax("\(raw: body)")]
  }
}

/// The `@DecantName` marker — a peer macro that expands to nothing; declared so
/// the spelling is stable ahead of derive support for it.
public struct DecantNameMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingPeersOf decl: some DeclSyntaxProtocol,
                               in context: some MacroExpansionContext)
      throws -> Array<DeclSyntax> {
    []
  }
}

/// The `@DecantSkip` marker — a peer macro that expands to nothing, as above.
public struct DecantSkipMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingPeersOf decl: some DeclSyntaxProtocol,
                               in context: some MacroExpansionContext)
      throws -> Array<DeclSyntax> {
    []
  }
}

/// Whether any segment, at any depth, guards a field with `#if`. When none
/// does, the derive emits exactly the unconditional shape it always has: a
/// literal field count and a flat write/read list.
private func conditional(_ segments: Array<DecantModel.Segment>) -> Bool {
  segments.contains {
    if case .conditional = $0 { return true }
    return false
  }
}

/// Whether `segments` carry no stored field at any depth — a struct with no
/// serialized property. The serialize sub-serializer local is then never
/// mutated by a `field(…)` write, so it binds `let` rather than a `var` that
/// would warn.
private func empty(_ segments: Array<DecantModel.Segment>) -> Bool {
  segments.allSatisfy { segment in
    switch segment {
    case let .unconditional(run):
      return run.isEmpty
    case let .conditional(clauses):
      return clauses.allSatisfy { empty($0.segments) }
    }
  }
}

/// The number of fields in this level's unconditional runs, not descending into
/// a `#if` — the constant part of the field count at the level a count
/// accumulator is initialized or incremented.
private func direct(_ segments: Array<DecantModel.Segment>) -> Int {
  segments.reduce(0) {
    guard case let .unconditional(run) = $1 else { return $0 }
    return $0 + run.count
  }
}

/// The `fields:` argument for `structure(…)`: a literal count when no `#if`
/// guards a field, otherwise the accumulator local `name` a mirrored `#if`
/// tallies (see `preamble`).
private func counted(_ segments: Array<DecantModel.Segment>,
                     as name: String) -> String {
  conditional(segments) ? name : "\(direct(segments))"
}

/// The lines, if any, that declare and accumulate the field-count local `name`
/// ahead of `structure(…)`. Empty when no field is conditional; otherwise a
/// `var name = <unconditional count>` seed followed by a `#if` tree mirroring
/// the fields' guards, each active clause adding its own fields — the plugin
/// cannot resolve which clause the compiler picks, so it re-emits the guard.
private func preamble(_ segments: Array<DecantModel.Segment>,
                      into name: String) -> String {
  guard conditional(segments) else { return "" }
  return "    var \(name) = \(direct(segments))\n"
    + accumulate(segments, into: name)
}

/// The `#if` tree that increments the count local `name` by each active
/// clause's fields, recursing into a nested `#if`. Only conditional segments
/// contribute; an unconditional run is already in the seed or a `+=` above.
private func accumulate(_ segments: Array<DecantModel.Segment>,
                        into name: String) -> String {
  var lines = ""
  for segment in segments {
    guard case let .conditional(clauses) = segment else { continue }
    for clause in clauses {
      lines += "    \(directive(clause))\n"
      let count = direct(clause.segments)
      if count > 0 { lines += "    \(name) += \(count)\n" }
      lines += accumulate(clause.segments, into: name)
    }
    lines += "    #endif\n"
  }
  return lines
}

/// The serialize `field(…)` writes in declaration order, mirroring each `#if`
/// so a conditional field is written only under the same guard. `write` renders
/// one field's line.
private func writes(_ segments: Array<DecantModel.Segment>,
                    with write: (DecantModel.Field) -> String) -> String {
  var lines = Array<String>()
  for segment in segments {
    switch segment {
    case let .unconditional(run):
      lines.append(contentsOf: run.map(write))
    case let .conditional(clauses):
      for clause in clauses {
        lines.append("    \(directive(clause))")
        let body = writes(clause.segments, with: write)
        if !body.isEmpty { lines.append(body) }
      }
      lines.append("    #endif")
    }
  }
  return lines.joined(separator: "\n")
}

/// The per-branch deserialize body: a `#if` tree whose every leaf is a complete
/// `try Self(…)` over that branch's active fields, in declaration order,
/// followed by the framing `end` and the return. Each `#if` block multiplies
/// the leaves — the cartesian product of the blocks' clauses — since an
/// initializer's argument list cannot itself hold a `#if`. `argument` renders
/// one field's `label: deserializer.decode()`; `value` is the shared result
/// local (only one branch compiles, so it is declared and returned per leaf).
///
/// A block without an `#else` still needs a leaf for the case no clause is
/// active — its conditional fields are simply absent — so an implicit `#else`
/// is synthesized, unlike serialize where an inactive clause correctly adds and
/// writes nothing.
private func builds(_ segments: Array<DecantModel.Segment>,
                    with argument: (DecantModel.Field) -> String,
                    binding value: String) -> String {
  func render(_ segments: Array<DecantModel.Segment>,
              _ prefix: Array<String>) -> String {
    var arguments = prefix
    var index = 0
    while index < segments.count,
          case let .unconditional(run) = segments[index] {
      arguments.append(contentsOf: run.map(argument))
      index += 1
    }
    guard index < segments.count,
          case let .conditional(clauses) = segments[index] else {
      // A leaf with no active field decodes nothing, so its `Self()` calls the
      // synthesized no-argument memberwise init — which is nonthrowing (a
      // throwing or failable custom replacement is rejected by `matches`). A
      // `try` on it would warn "no calls to throwing functions occur", failing
      // the warning-free build, so drop the `try` for the fieldless call. A
      // leaf with a field keeps the `try`: each `decode()` can throw. This
      // covers a fully-empty struct and an empty synthesized `#else` branch.
      let call = arguments.joined(separator: ", ")
      let build = arguments.isEmpty ? "Self()" : "try Self(\(call))"
      return "    let \(value) = \(build)\n"
        + "    try deserializer.end()\n    return \(value)"
    }
    let rest = Array(segments[(index + 1)...])
    var lines = ""
    for clause in clauses {
      lines += "    \(directive(clause))\n"
      lines += render(clause.segments + rest, arguments) + "\n"
    }
    // No source `#else` means the block's fields are absent when no clause is
    // active, so synthesize an `#else` leaf carrying only the surrounding
    // fields — the emitted `Self(…)` must be complete in every branch.
    if clauses.last?.condition != nil {
      lines += "    #else\n\(render(rest, arguments))\n"
    }
    return lines + "    #endif"
  }
  return render(segments, [])
}

/// The pound-directive line for `clause` — `#if COND` / `#elseif COND` /
/// `#else` — with the condition tokens copied verbatim so the generated guard
/// evaluates identically to the source's.
private func directive(_ clause: DecantModel.Clause) -> String {
  guard let condition = clause.condition else { return clause.pound }
  return "\(clause.pound) \(condition)"
}

/// The leading-attribute prefix for a generated `extension`, from `attributes`
/// (the annotated type's verbatim `@available` spellings): each attribute on
/// its own line ahead of the `extension`, so the emission reads
/// `@available(...) \n extension <Type>: …`. An empty list yields the empty
/// string, so a type with no `@available` emits its extension unchanged.
internal func attributed(_ attributes: Array<String>) -> String {
  attributes.map { "\($0)\n" }.joined()
}

/// The `where` clause constraining each generic parameter in `parameters` to
/// `protocol` — ` where T: Decant.Serializable, U: Decant.Serializable` — for
/// the generated extension's conditional conformance, or the empty string when
/// `parameters` is empty (a non-generic type, or one whose parameters no
/// serialized field mentions, stays an unconditional conformance).
///
/// The requirement is on the generic PARAMETERS, never on a field's applied
/// written type: Swift rejects a conformance requirement whose left side is an
/// applied concrete type (`where Array<T>: …`), so the caller lowers each field
/// type to the parameters it mentions (see `DecantModel.constrained`). The
/// extension header carries this beside the method's own `where` on its
/// serializer/deserializer parameter; the two clauses are independent. A
/// serialized field's own value type must conform, so the caller passes
/// `Decant.Serializable` for the serialize side and `Decant.Deserializable` for
/// the deserialize side.
internal func constrained(_ parameters: Array<String>,
                          to protocol: String) -> String {
  guard !parameters.isEmpty else { return "" }
  let clauses = parameters.map { "\($0): \(`protocol`)" }
  return " where \(clauses.joined(separator: ", "))"
}

/// A hygienic name for the `serialize`/`deserialize` generic parameter, built
/// from `role` (`Serializer`/`Deserializer`).
///
/// The method's generic parameter is nested in the type, so a same-named type
/// generic parameter shadows it, which Swift 6 rejects. That collision arises
/// with the type's OWN parameter — `@Serializable struct Box<S>` — and, just as
/// fatally, with an ENCLOSING context's — `struct Outer<S> { @Serializable
/// struct Inner { … } }`, where the emitted `serialize<S>` shadows `Outer`'s
/// `S` even though `Inner` is not itself generic. The compiler hands the macro
/// the attached declaration DETACHED from its surrounding tree (its `.parent`
/// is `nil` in the plugin process), so the enclosing parameters cannot be read
/// to reserve them. A readable `S`/`D` is therefore unsafe in general, and the
/// derive always takes a hygienic name: `makeUniqueName` yields a
/// `__macro_local_…` token guaranteed distinct from any source name, in or
/// around the type, so the parameter never shadows.
internal func parameter(named role: String,
                        in context: some MacroExpansionContext) -> String {
  context.makeUniqueName(role).text
}

/// The type name for a `providingExtensionsOf` argument, stripped of
/// whitespace, so it reads cleanly in the generated `extension` header.
///
/// The result is used in an IDENTIFIER position, so it keeps the source
/// spelling: a raw type name (SE-0451: `` `Quote"Type` ``) keeps its backticks,
/// which are exactly what makes `` extension `Quote"Type` `` parse. The
/// deserialize constructor is spelled `Self`, not this name, so a model named
/// after the generic `Deserializer` parameter (`struct D`) is unshadowed. The
/// serialized structure-name string is the canonical (backtick-stripped)
/// spelling instead — see `canonical`.
internal func trimmed(_ type: some TypeSyntaxProtocol) -> String {
  type.trimmedDescription
}

/// The canonical (backtick-stripped) spelling of `type`'s name, for the
/// serialized structure-name key.
///
/// The structure name stays the real type name so round-trip names are stable;
/// only its emitted spelling differs by position. `trimmed` keeps the source
/// spelling for identifier positions, but the string key must carry the bare
/// name — a raw type name's `` `Quote"Type` `` would otherwise serialize the
/// backticks. `Identifier` strips them; a non-nominal or malformed type has no
/// simple name, so the trimmed spelling is the fallback. `key` then emits this
/// as a valid string literal (a `"` forces `#"…"#` delimiters).
internal func canonical(_ type: some TypeSyntaxProtocol) -> String {
  guard let identifier = type.as(IdentifierTypeSyntax.self),
        let name = Identifier(identifier.name)?.name else {
    return trimmed(type)
  }
  return name
}

/// Whether `name` is a plain Swift identifier — one that needs no backticks to
/// be written as itself — as opposed to a keyword or a raw identifier (SE-0451:
/// `` `foo bar` ``, `` `quote"x` ``, which carry spaces, punctuation, or other
/// characters a plain identifier cannot). A plain identifier is a nonempty run
/// of an identifier-start scalar (`_` or an XID-start) followed by
/// identifier-continue scalars (`_` or XID-continue); the XID properties track
/// Swift's identifier grammar. A keyword satisfies this shape but is separately
/// a keyword, so callers that must distinguish the two also test `keyword`.
private func plain(_ name: String) -> Bool {
  var scalars = name.unicodeScalars.makeIterator()
  guard let first = scalars.next(),
        first == "_" || first.properties.isXIDStart else {
    return false
  }
  while let scalar = scalars.next() {
    guard scalar == "_" || scalar.properties.isXIDContinue else {
      return false
    }
  }
  return true
}

/// Whether `name` is a Swift keyword. All keywords are `Keyword` cases, so this
/// covers every reserved word, not just `self`/`init`.
private func keyword(_ name: String) -> Bool {
  var name = name
  return name.withSyntaxText { Keyword($0) != nil }
}

/// `name` as a source-safe member access after a `.` in `self.<name>`.
///
/// A field name is collected in its canonical spelling (`append` strips the
/// backticks off a declared `` var `self` `` or `` var `foo bar` `` through
/// `Identifier`), so serialize must re-escape any name that is not a plain
/// identifier before it emits the member access, or the read miscompiles:
/// `self.self` reads the whole instance, `self.init` is an error, and
/// `self.foo bar` does not parse. A keyword and a raw identifier both need the
/// backticks; the wildcard `_` is a plain, non-keyword identifier yet a bare
/// `self._` does not parse, so it needs the backticks too. Only a plain
/// identifier that is neither a keyword nor `_` is written bare.
internal func member(_ name: String) -> String {
  plain(name) && !keyword(name) && name != "_" ? name : "`\(name)`"
}

/// `name` as a source-safe argument label in `S(<name>: …)`.
///
/// The label rule differs from `member`: an argument label accepts a keyword
/// unescaped — escaping one instead WARNS — so a keyword is written bare, but
/// a raw identifier (`` `foo bar` ``) is NOT a valid bare label (`foo bar:` is
/// a syntax error) and must keep its backticks. The wildcard `_` is a plain,
/// non-keyword identifier yet a bare `_:` label is an OMITTED (positional)
/// label, not the real `_` label the memberwise init expects, so `_` must be
/// backticked (`` `_`: `` warns for neither a keyword nor a raw identifier). So
/// a name is escaped when it is neither a plain identifier nor a keyword, or
/// when it is `_`.
internal func label(_ name: String) -> String {
  (plain(name) || keyword(name)) && name != "_" ? name : "`\(name)`"
}

/// `name` as a Swift string literal for the serialization-name key in
/// `field("<name>", …)`.
///
/// The serialized name stays the real property name, so round-trip keys are
/// stable; only its SOURCE spelling must be a valid literal. A raw identifier
/// carries characters — a `"` or `\` — that break a bare `"\(name)"`
/// interpolation, so the literal is built through `StringLiteralExprSyntax`,
/// which escapes the contents (or wraps them in `#"…"#`) correctly.
internal func key(_ name: String) -> String {
  StringLiteralExprSyntax(content: name).description
}
