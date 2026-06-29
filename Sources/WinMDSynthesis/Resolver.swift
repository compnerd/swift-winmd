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

  public init(_ table: Dictionary<Int, Identity>) {
    self.table = table
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
    try collect(signature, into: &table, with: storage)
    self.init(table)
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

/// Resolves every `TypeDefOrRef` `signature` names into `table`.
private func collect(_ signature: MethodSignature,
                     into table: inout Dictionary<Int, Identity>,
                     with storage: borrowing Storage) throws(WinMDError) {
  try collect(signature.returns, into: &table, with: storage)
  for parameter in signature.parameters {
    try collect(parameter, into: &table, with: storage)
  }
}

/// Resolves every `TypeDefOrRef` `type` names into `table`, recursively.
private func collect(_ type: SignatureType,
                     into table: inout Dictionary<Int, Identity>,
                     with storage: borrowing Storage) throws(WinMDError) {
  switch type {
  case .primitive, .variable, .function:
    break
  case let .pointer(pointee), let .reference(pointee),
       let .array(pointee), let .matrix(pointee, _):
    try collect(pointee, into: &table, with: storage)
  case let .named(_, reference):
    try record(reference, into: &table, with: storage)
  case let .instance(base, arguments):
    try collect(base, into: &table, with: storage)
    for argument in arguments {
      try collect(argument, into: &table, with: storage)
    }
  case let .modified(inner, modifiers):
    try collect(inner, into: &table, with: storage)
    for modifier in modifiers {
      try record(modifier.type, into: &table, with: storage)
    }
  }
}

/// Resolves a single `TypeDefOrRef` to its `Identity` and records it.
private func record(_ reference: TypeDefOrRef,
                    into table: inout Dictionary<Int, Identity>,
                    with storage: borrowing Storage) throws(WinMDError) {
  guard table[reference.rawValue] == nil else { return }
  guard let tuple = try storage.resolve(reference) else { return }
  guard let identity = try tuple.identity else { return }
  table[reference.rawValue] = identity
}
