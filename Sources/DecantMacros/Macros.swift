// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

@_exported import Decant

/// Derives a `Serializable` conformance for a struct, writing one field per
/// stored property in declaration order.
///
/// The DECLARATION lives here in `DecantMacros`, the opt-in derive layer; the
/// IMPLEMENTATION lives in the `DecantMacrosPlugin` compiler plugin so
/// swift-syntax is a compile-time-only dependency that never links into a
/// client. The `Decant` core carries no macro at all.
@attached(extension, conformances: Serializable, names: named(serialize(into:)))
public macro Serializable() =
    #externalMacro(module: "DecantMacrosPlugin", type: "SerializableMacro")

/// Derives a `Deserializable` conformance for a struct, reading each stored
/// property in declaration order — the inverse of `@Serializable`, matching its
/// field order.
@attached(extension, conformances: Deserializable,
          names: named(deserialize(from:)))
public macro Deserializable() =
    #externalMacro(module: "DecantMacrosPlugin", type: "DeserializableMacro")

/// Marks a stored property to be written and read under a different name than
/// its Swift spelling. The plain-fields derive does not yet honor it; the
/// spelling is declared so it is stable ahead of that support.
@attached(peer)
public macro DecantName(_ name: StaticString) =
    #externalMacro(module: "DecantMacrosPlugin", type: "DecantNameMacro")

/// Marks a stored property the derive should skip. The plain-fields derive does
/// not yet honor it; the spelling is declared so it is stable ahead of that
/// support.
@attached(peer)
public macro DecantSkip() =
    #externalMacro(module: "DecantMacrosPlugin", type: "DecantSkipMacro")
