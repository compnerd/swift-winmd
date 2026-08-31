// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import WinMD

/// A resolved type identity: the namespace and name a `TypeDefOrRef` names.
///
/// The decode tier does not navigate a database; it is handed an `Identity` by
/// an injected `TypeResolver`, exactly as the SQL layer holds a structured value
/// rather than rows. The pair is the resolved type's CLR namespace (e.g.
/// `Windows.Win32.Foundation`) and its simple name (e.g. `HRESULT`).
public struct Identity: Sendable, Hashable {
  /// The CLR namespace the type lives in.
  public let namespace: String

  /// The type's simple name.
  public let name: String

  public init(namespace: String, name: String) {
    self.namespace = namespace
    self.name = name
  }
}

/// A signature-referenced type paired with the coded-index row the signature
/// named it through — the `TypeDefOrRef` `rawValue` (its tag and 1-based row).
///
/// The `identity` still spells the type (namespace and name); the `token` is
/// what lets a closure walk resolve the reference to a local definition by
/// binding the exact `TypeRef`/`TypeDef` Id rather than matching on the name. A
/// bare name mislocates: two nested types share the empty namespace and a bare
/// name, and an external `TypeRef` may share a local type's (namespace, name)
/// yet resolve elsewhere. Binding the row instead routes a `TypeDef` straight to
/// its definition and a `TypeRef` through the scope-chain resolution the local
/// resolution needs. A `TypeSpec` names no identity, so a `Resolver` never holds
/// one — every `Referent` is a `TypeDef` or a `TypeRef`.
public struct Referent: Sendable, Hashable {
  /// Which table the coded index names — a local `TypeDef` a caller resolves by
  /// its Id directly, or a `TypeRef` it resolves through the scope chain. A
  /// `Resolver` never holds a `TypeSpec` (which names no identity), so a
  /// reference is one or the other.
  public enum Kind: Sendable, Hashable {
    case definition
    case reference
  }

  /// The resolved spelling identity — the type's namespace and name.
  public let identity: Identity

  /// The `TypeDefOrRef` coded-index raw value the signature named the type
  /// through; `kind` and `row` decode it.
  public let token: Int

  /// Whether the reference occurs *by value* — its type embedded directly, not
  /// behind a pointer, byref, or array. Only a by-value occurrence embeds the
  /// type's layout, so only it forces a caller (the closure poison) to drop a
  /// containing declaration naming a value type with no valid spelling; an
  /// occurrence solely behind an indirection renders as an opaque pointer and
  /// imposes nothing on the layout. A token that occurs both ways yields a
  /// distinct by-value `Referent`, so the layout constraint is still seen.
  public let embedded: Bool

  public init(identity: Identity, token: Int, embedded: Bool = false) {
    self.identity = identity
    self.token = token
    self.embedded = embedded
  }

  /// The decoded coded index — its `tag` selects the table and its `row` is the
  /// 1-based Id a caller binds to resolve the reference to a local definition.
  public var coded: TypeDefOrRef {
    TypeDefOrRef(rawValue: token)
  }

  /// Whether the reference names a local `TypeDef` directly or a `TypeRef` the
  /// caller resolves through the scope chain, keyed off the coded index's
  /// selected table rather than a hard-coded tag.
  public var kind: Kind {
    TypeDefOrRef.tables[coded.tag]?.number == Metadata.Tables.TypeDef.number
        ? .definition : .reference
  }

  /// The 1-based Id the reference names in the table `kind` selects — the
  /// `TypeDef` Id for a definition, the `TypeRef` Id for a reference.
  public var row: Int {
    coded.row
  }
}

/// Resolves a `TypeDefOrRef` (with its `NamedKind`) to an `Identity`.
///
/// The decode tier is injected with a resolver so it needs no live database: a
/// stub resolver suffices for tests, a database-backed one in production. The
/// `kind` is forwarded because a resolver may key on `class`/`value`
/// distinctions.
public protocol TypeResolver: Sendable {
  /// The namespace and name the coded index names, or `nil` when unresolvable.
  func resolve(_ reference: TypeDefOrRef, kind: NamedKind) -> Identity?
}

/// A `TypeResolver` backed by a table pre-resolved against a database.
///
/// `TypeResolver` is `Sendable` and its `resolve` is non-throwing and takes no
/// database — but a `Database` is `~Escapable` and cannot be captured by a
/// `Sendable` value. The resolution is therefore done eagerly while the database
/// is in scope: every `TypeDefOrRef` a signature names is resolved to its
/// `Identity` and stored in a table keyed by the coded index's `rawValue`, the
/// same shape the unit tests' stub resolver uses. The decode tier then reads the
/// table with no database in hand.
public struct Resolver: TypeResolver {
  /// The pre-resolved `rawValue → Identity` table.
  private let table: Dictionary<Int, Identity>

  /// The pre-resolved `rawValue → namespace-qualified spelling` table — an
  /// ambiguous value type's full namespace path alone (see
  /// `Storage.spelling(of:qualifying:)`). A reference absent here — a
  /// non-ambiguous value type, a protocol/class, a database-free resolver, or
  /// one built over an unresolvable reference — spells by its `Identity` name,
  /// the bare-or-enclosing behaviour that predates namespace preservation.
  private let spellings: Dictionary<Int, String>

  /// The coded indices `table` holds that occur *only* as a custom modifier,
  /// never as an ordinary type — kept in `table` for the decode's `IsConst`
  /// resolution but excluded from `identities`, since the generated signature
  /// never spells a modifier type. A token that also occurs ordinarily is not
  /// here, so its ordinary occurrence still enqueues its declaration.
  private let modifiers: Set<Int>

  /// The coded indices `table` holds that occur *by value* — the type embedded
  /// directly in a signature, not behind a pointer, byref, or array. A caller
  /// keys a layout constraint (the closure poison that drops a declaration
  /// naming an unspellable value type) on this, so a type named only through an
  /// indirection — which renders as an opaque pointer — imposes none.
  private let values: Set<Int>

  /// The coded indices `table` holds that occur in the signature's *return* and
  /// *parameter* positions — both empty for a field signature. A caller that
  /// gates a per-reference decision on which signature section spells the type
  /// (the closure's frontier reservation, which reserves only what the selected
  /// template's return or parameter section renders) reads these to categorize
  /// a reference; a token occurring in both positions is in both sets, so it
  /// carries both categories rather than only one.
  private let returns: Set<Int>
  private let params: Set<Int>

  public init(_ table: Dictionary<Int, Identity>) {
    self.table = table
    self.spellings = [:]
    self.modifiers = []
    self.values = []
    self.returns = []
    self.params = []
  }

  /// Builds a resolver over the pre-resolved tables — the storage-backed
  /// initializers' shared destination.
  private init(_ table: Dictionary<Int, Identity>,
               _ spellings: Dictionary<Int, String>,
               _ modifiers: Set<Int>, _ values: Set<Int>,
               _ returns: Set<Int>, _ params: Set<Int>) {
    self.table = table
    self.spellings = spellings
    self.modifiers = modifiers
    self.values = values
    self.returns = returns
    self.params = params
  }

  /// Builds the `rawValue → Identity` table from a decoded signature, resolved
  /// against a borrowed `Storage`.
  ///
  /// `SignatureType.decode` resolves a `named` type through a `Resolver` keyed
  /// by the
  /// coded index's `rawValue`, so every `TypeDefOrRef` a signature carries —
  /// directly or nested under a pointer/reference/array/modifier/instantiation —
  /// must be resolved to its `Identity` while the database is in scope. This is
  /// that resolution, factored out of the assembly so both the interface
  /// synthesizer (which pre-resolves a whole interface) and the SQL adapter
  /// (which resolves a single method's signature on demand) share one
  /// collection. A reference that does not resolve — a `TypeSpec`, a null index
  /// — is left out, and `Decode` renders an opaque pointer for it.
  package init(of signature: MethodSignature, with storage: borrowing Storage,
               qualifying: Set<String> = []) throws(WinMDError) {
    var table = Dictionary<Int, Identity>()
    var spellings = Dictionary<Int, String>()
    var values = Set<Int>()
    var modifiers = Set<Int>()
    // Collect the return and the parameters into separate ordinary-token sets,
    // so a token spelled in both positions lands in both — the shared `table`,
    // `values`, and `modifiers` accumulate across the two.
    var returns = Set<Int>()
    try collect(signature.returns, into: &table, spelling: &spellings,
                spelled: &returns, values: &values, modifiers: &modifiers,
                with: storage, qualifying: qualifying)
    var params = Set<Int>()
    for parameter in signature.parameters {
      try collect(parameter, into: &table, spelling: &spellings,
                  spelled: &params, values: &values, modifiers: &modifiers,
                  with: storage, qualifying: qualifying)
    }
    let spelled = returns.union(params)
    self.init(table, spellings, modifiers.subtracting(spelled), values,
              returns, params)
  }

  /// Builds the `rawValue → Identity` table from a decoded field signature,
  /// resolved against a borrowed `Storage` — the field-signature sibling of the
  /// method-signature initializer.
  ///
  /// A field carries a single `type`, so this reuses the same `collect` walk the
  /// method initializer runs over each parameter, resolving every `TypeDefOrRef`
  /// the field's type names (directly or nested under a pointer, array, or
  /// instantiation). A closure walk over a struct's fields (edge E6) resolves a
  /// field's named value type exactly the way it resolves a method parameter.
  package init(of signature: FieldSignature, with storage: borrowing Storage,
               qualifying: Set<String> = []) throws(WinMDError) {
    var table = Dictionary<Int, Identity>()
    var spellings = Dictionary<Int, String>()
    var spelled = Set<Int>()
    var values = Set<Int>()
    var modifiers = Set<Int>()
    try collect(signature.type, into: &table, spelling: &spellings,
                spelled: &spelled, values: &values, modifiers: &modifiers,
                with: storage, qualifying: qualifying)
    self.init(table, spellings, modifiers.subtracting(spelled), values, [], [])
  }

  /// The distinct references the table holds — every type a signature named,
  /// each paired with the coded-index row it was named through.
  ///
  /// The table keys by coded-index raw value, so one `Referent` is yielded per
  /// distinct `TypeDefOrRef` the signature carries; two uses of the same coded
  /// row collapse to one. A closure walk reads this to enumerate a signature's
  /// referenced types without re-walking it, then resolves each — by its `token`
  /// row, not its name — to a local `TypeDef` and enqueues the unvisited.
  public var identities: Set<Referent> {
    Set(table.filter { !modifiers.contains($0.key) }
        .map { Referent(identity: $0.value, token: $0.key,
                        embedded: values.contains($0.key)) })
  }

  /// The subset of `identities` a method's *return* position spells — each an
  /// ordinary reference the return names. A field resolver has none. A caller
  /// categorizes a reference by its membership here and in `parameters`; a
  /// reference named in both positions is in both, so it carries both
  /// categories.
  public var returned: Set<Referent> {
    Set(table.filter { returns.contains($0.key) && !modifiers.contains($0.key) }
        .map { Referent(identity: $0.value, token: $0.key,
                        embedded: values.contains($0.key)) })
  }

  /// The subset of `identities` a method's *parameter* positions spell — each
  /// an ordinary reference a parameter names. A field resolver has none. A
  /// reference named in both a return and a parameter is in `returned` too.
  public var parameters: Set<Referent> {
    Set(table.filter { params.contains($0.key) && !modifiers.contains($0.key) }
        .map { Referent(identity: $0.value, token: $0.key,
                        embedded: values.contains($0.key)) })
  }

  public func resolve(_ reference: TypeDefOrRef, kind: NamedKind) -> Identity? {
    table[reference.rawValue]
  }

  /// The namespace-qualified render spelling `reference` was pre-resolved to,
  /// or `nil` when it names no ambiguous local value type (or the resolver
  /// carries no spellings) — the signal the decode falls back to the
  /// reference's bare-or-enclosing `Identity` name. Populated only by the
  /// storage-backed initializers, from `Storage.spelling(of:qualifying:)`.
  public func spelling(of reference: TypeDefOrRef) -> String? {
    spellings[reference.rawValue]
  }
}

extension Tuple {
  /// The `Namespace.Name` identity of a type the coded index named, read by
  /// resolved ordinal off the type-erased tuple.
  ///
  /// A coded index selects `TypeDef`/`TypeRef`/`TypeSpec` at runtime; `TypeDef`
  /// and `TypeRef` both carry the name at ordinal 1 and the namespace at ordinal
  /// 2, while a `TypeSpec` (which names a `#Blob` signature, not a `TypeName`)
  /// has neither and yields `nil`.
  var identity: Identity? {
    get throws(WinMDError) {
      guard let name = ordinal(for: "TypeName"),
          let space = ordinal(for: "TypeNamespace") else {
        return nil
      }
      return try Identity(namespace: string(space), name: string(name))
    }
  }
}

/// Resolves every `TypeDefOrRef` `signature` names into the tables, recording
/// each ordinary (spelled) occurrence in `spelled` and each custom-modifier
/// occurrence in `modifiers`.
private func collect(_ signature: MethodSignature,
                     into table: inout Dictionary<Int, Identity>,
                     spelling spellings: inout Dictionary<Int, String>,
                     spelled: inout Set<Int>, values: inout Set<Int>,
                     modifiers: inout Set<Int>,
                     with storage: borrowing Storage,
                     qualifying: Set<String>) throws(WinMDError) {
  try collect(signature.returns, into: &table, spelling: &spellings,
              spelled: &spelled, values: &values, modifiers: &modifiers,
              with: storage, qualifying: qualifying)
  for parameter in signature.parameters {
    try collect(parameter, into: &table, spelling: &spellings,
                spelled: &spelled, values: &values, modifiers: &modifiers,
                with: storage, qualifying: qualifying)
  }
}

/// Resolves every `TypeDefOrRef` `type` names into the tables, recursively,
/// recording each ordinary occurrence in `spelled` and each custom-modifier
/// occurrence in `modifiers`, so the closure walk can omit a token used *only*
/// as a modifier: such a type stays in `table` for the decode's `IsConst`
/// check, but the generated signature never names it (a non-`IsConst` modifier
/// is
/// ignored, `IsConst` only changes pointer constness), so enqueuing it would
/// emit an orphan. A token that also occurs as an ordinary type is spelled and
/// so kept — subtracting every token ever seen as a modifier would drop it.
private func collect(_ type: SignatureType,
                     into table: inout Dictionary<Int, Identity>,
                     spelling spellings: inout Dictionary<Int, String>,
                     spelled: inout Set<Int>, values: inout Set<Int>,
                     modifiers: inout Set<Int>, value: Bool = true,
                     with storage: borrowing Storage,
                     qualifying: Set<String>) throws(WinMDError) {
  switch type {
  case .primitive, .variable, .function:
    break
  case let .pointer(pointee), let .reference(pointee),
       let .array(pointee), let .matrix(pointee, _):
    // A pointer/byref/array indirection does not embed the pointee's layout —
    // it renders as an opaque pointer — so its `named` types occur by pointer,
    // not by value: descend with `value` cleared.
    try collect(pointee, into: &table, spelling: &spellings, spelled: &spelled,
                values: &values, modifiers: &modifiers, value: false,
                with: storage, qualifying: qualifying)
  case let .named(_, reference):
    try record(reference, into: &table, spelling: &spellings, embedded: value,
               with: storage, qualifying: qualifying)
    spelled.insert(reference.rawValue)
    if value { values.insert(reference.rawValue) }
  case let .instance(base, arguments):
    try collect(base, into: &table, spelling: &spellings, spelled: &spelled,
                values: &values, modifiers: &modifiers, value: value,
                with: storage, qualifying: qualifying)
    for argument in arguments {
      try collect(argument, into: &table, spelling: &spellings,
                  spelled: &spelled, values: &values, modifiers: &modifiers,
                  value: value, with: storage, qualifying: qualifying)
    }
  case let .modified(inner, modifiers: mods):
    try collect(inner, into: &table, spelling: &spellings, spelled: &spelled,
                values: &values, modifiers: &modifiers, value: value,
                with: storage, qualifying: qualifying)
    for modifier in mods {
      try record(modifier.type, into: &table, spelling: &spellings,
                 with: storage, qualifying: qualifying)
      modifiers.insert(modifier.type.rawValue)
    }
  }
}

/// Resolves a single `TypeDefOrRef` to its `Identity` and its kind-aware
/// spelling and records both.
private func record(_ reference: TypeDefOrRef,
                    into table: inout Dictionary<Int, Identity>,
                    spelling spellings: inout Dictionary<Int, String>,
                    embedded: Bool = true,
                    with storage: borrowing Storage,
                    qualifying: Set<String>) throws(WinMDError) {
  guard table[reference.rawValue] == nil else { return }
  guard let tuple = try storage.resolve(reference) else { return }
  // A reference into a type nested under a *generic* encloser has no valid
  // unqualified spelling (`Outer``1.Inner` needs the enclosing specialization,
  // `Outer<T>.Inner`), so it renders as the dialect's opaque pointer in every
  // case *except* a by-value occurrence of a value type — there the opaque
  // pointer would silently change the by-value ABI layout, so it is recorded
  // instead and the render poison drops the whole containing declaration. It is
  // left unrecorded — an unsupported frontier the decode spells as the opaque
  // pointer — when it is a by-reference type (a runtime class, harmless as a
  // pointer) *or* a value type occurring only behind an indirection (a pointer,
  // byref, or array — `embedded` false), which embeds no layout and so is
  // faithfully an opaque pointer. Recording only the by-value occurrence keeps
  // `Ptr<Outer``1.Inner>` an opaque pointer rather than an uncompilable
  // `UnsafeMutablePointer<Outer.Inner>`.
  //
  // The value/reference kind is read off the *resolved local definition*, not
  // the reference row: a `TypeRef` carries neither `Flags` nor `Extends`, so
  // `kind` on the raw row misclassifies every reference as a `class` and would
  // drop a by-value type named through a `TypeRef` as though it were an opaque
  // pointer — corrupting the struct's ABI. A reference that resolves to no
  // local definition (an external `TypeRef`) keeps the reference row, whose
  // chain is not generic, so it stays recorded as an ordinary frontier.
  let (generic, value): (Bool, Bool)
  if let definition = try storage.definition(of: reference) {
    generic = try storage.enclosedByGeneric(definition)
    value = try storage.kind(definition).value
  } else {
    generic = try storage.enclosedByGeneric(tuple)
    value = try storage.kind(tuple).value
  }
  if generic, !value || !embedded { return }
  guard let identity = try tuple.identity else { return }
  // The `Identity` carries the type's own namespace and its enclosing dot-path
  // (`Foo.Bar`), the key the decode's well-known and `System.Guid` lookups
  // resolve on and the name the decode spells. The enclosing path is
  // arity-stripped so a nested value type spells `Outer.Inner`, not
  // `Outer``1.Inner`; the *leaf* keeps its arity suffix so the decode's
  // well-known lookup can key on a generic's raw name (`Box1`) — the decode
  // strips the leaf suffix when it spells the projected `Box<…>`.
  let name = try storage.identifier(tuple)
  table[reference.rawValue] =
      Identity(namespace: identity.namespace, name: name)
  // Only a value type whose (outermost encloser's) name is ambiguous is spelled
  // namespace-qualified; the bare-or-enclosing `name` above serves every other
  // type. `Storage.spelling(of:qualifying:)` is the single source of that
  // decision — it applies the O(1) ambiguity test and, only then, resolves the
  // reference to confirm its definition is a value type (a protocol, a runtime
  // class, or an external `TypeRef` sharing the ambiguous name stays bare). An
  // earlier inline fast path here recomputed the top-level case from the
  // `identity` alone and, spelling it directly, skipped that value-type check,
  // qualifying a same-named protocol or class to a phantom `NS.Point`.
  //
  // The guard here is only a pre-filter on *whether* to call `spelling`, never a
  // second copy of the decision: a top-level reference (a non-empty own
  // namespace) whose leaf name is not ambiguous cannot qualify — `spelling`
  // tests that very name first and would return `nil` — so skipping the call is
  // exactly equivalent and spares the resolution for the common bare reference.
  // A nested or global reference (an empty own namespace) qualifies off its
  // outermost encloser's name, which the leaf `identity.name` does not reveal,
  // so it always defers to `spelling`'s chain walk.
  guard identity.namespace.isEmpty || qualifying.contains(identity.name) else {
    return
  }
  if let spelling =
      try storage.spelling(of: reference, qualifying: qualifying) {
    spellings[reference.rawValue] = spelling
  }
}
