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

  public init(identity: Identity, token: Int) {
    self.identity = identity
    self.token = token
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

  /// The coded indices `table` holds that occur *only* as a custom modifier,
  /// never as an ordinary type — kept in `table` for the decode's `IsConst`
  /// resolution but excluded from `identities`, since the generated signature
  /// never spells a modifier type. A token that also occurs ordinarily is not
  /// here, so its ordinary occurrence still enqueues its declaration.
  private let modifiers: Set<Int>

  public init(_ table: Dictionary<Int, Identity>) {
    self.table = table
    self.modifiers = []
  }

  /// Builds a resolver over the pre-resolved tables — the storage-backed
  /// initializers' shared destination.
  private init(_ table: Dictionary<Int, Identity>,
               _ modifiers: Set<Int>) {
    self.table = table
    self.modifiers = modifiers
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
  package init(of signature: MethodSignature,
               with storage: borrowing Storage) throws(WinMDError) {
    var table = Dictionary<Int, Identity>()
    var spelled = Set<Int>()
    var modifiers = Set<Int>()
    try collect(signature, into: &table, spelled: &spelled,
                modifiers: &modifiers, with: storage)
    self.init(table, modifiers.subtracting(spelled))
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
  package init(of signature: FieldSignature,
               with storage: borrowing Storage) throws(WinMDError) {
    var table = Dictionary<Int, Identity>()
    var spelled = Set<Int>()
    var modifiers = Set<Int>()
    try collect(signature.type, into: &table, spelled: &spelled,
                modifiers: &modifiers, with: storage)
    self.init(table, modifiers.subtracting(spelled))
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
        .map { Referent(identity: $0.value, token: $0.key) })
  }

  public func resolve(_ reference: TypeDefOrRef, kind: NamedKind) -> Identity? {
    table[reference.rawValue]
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

/// Resolves every `TypeDefOrRef` `signature` names into the table, recording
/// each ordinary (spelled) occurrence in `spelled` and each custom-modifier
/// occurrence in `modifiers`.
private func collect(_ signature: MethodSignature,
                     into table: inout Dictionary<Int, Identity>,
                     spelled: inout Set<Int>, modifiers: inout Set<Int>,
                     with storage: borrowing Storage) throws(WinMDError) {
  try collect(signature.returns, into: &table, spelled: &spelled,
              modifiers: &modifiers, with: storage)
  for parameter in signature.parameters {
    try collect(parameter, into: &table, spelled: &spelled,
                modifiers: &modifiers, with: storage)
  }
}

/// Resolves every `TypeDefOrRef` `type` names into the table, recursively,
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
                     spelled: inout Set<Int>, modifiers: inout Set<Int>,
                     with storage: borrowing Storage) throws(WinMDError) {
  switch type {
  case .primitive, .variable, .function:
    break
  case let .pointer(pointee), let .reference(pointee),
       let .array(pointee), let .matrix(pointee, _):
    try collect(pointee, into: &table, spelled: &spelled,
                modifiers: &modifiers, with: storage)
  case let .named(_, reference):
    try record(reference, into: &table, with: storage)
    spelled.insert(reference.rawValue)
  case let .instance(base, arguments):
    try collect(base, into: &table, spelled: &spelled,
                modifiers: &modifiers, with: storage)
    for argument in arguments {
      try collect(argument, into: &table, spelled: &spelled,
                  modifiers: &modifiers, with: storage)
    }
  case let .modified(inner, modifiers: mods):
    try collect(inner, into: &table, spelled: &spelled,
                modifiers: &modifiers, with: storage)
    for modifier in mods {
      try record(modifier.type, into: &table, with: storage)
      modifiers.insert(modifier.type.rawValue)
    }
  }
}

/// Resolves a single `TypeDefOrRef` to its `Identity` and records it.
private func record(_ reference: TypeDefOrRef,
                    into table: inout Dictionary<Int, Identity>,
                    with storage: borrowing Storage) throws(WinMDError) {
  guard table[reference.rawValue] == nil else { return }
  guard let tuple = try storage.resolve(reference) else { return }
  // A reference into a type nested under a *generic* encloser has no valid
  // unqualified spelling (`Outer``1.Inner` needs the enclosing specialization,
  // `Outer<T>.Inner`), so leave it unrecorded — an unsupported frontier the
  // decode then omits — rather than spell an uncompilable `Outer.Inner`.
  guard try !storage.enclosedByGeneric(tuple) else { return }
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
}
