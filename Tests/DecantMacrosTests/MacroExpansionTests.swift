// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
@testable import DecantMacrosPlugin

/// The macro specifications the expansion assertions run against — the derive
/// macros mapped to the conformances they add.
private let macros: Dictionary<String, MacroSpec> = [
  "Serializable": MacroSpec(type: SerializableMacro.self,
                            conformances: ["Serializable"]),
  "Deserializable": MacroSpec(type: DeserializableMacro.self,
                              conformances: ["Deserializable"]),
]

/// Asserts that `source` expands to `expanded`, routing any failure to
/// swift-testing so it reads as a `@Test` failure rather than an XCTest one.
private func expand(_ source: String, to expanded: String,
                    _ location: SourceLocation = #_sourceLocation) {
  assertMacroExpansion(source, expandedSource: expanded, macroSpecs: macros,
                       failureHandler: { failure in
                         Issue.record("\(failure.message)")
                       })
}

struct MacroExpansionTests {
  @Test func `Serializable writes each stored property in declaration order`() {
    expand("""
      @Serializable
      struct Point {
        var x: Int32
        var y: Int32
        var label: String
      }
      """,
      to: """
      struct Point {
        var x: Int32
        var y: Int32
        var label: String
      }

      extension Point: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Point", fields: 3)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          try __macro_local_9structurefMu_.field("label", self.label)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable reads each property into its init argument`() {
    expand("""
      @Deserializable
      struct Point {
        var x: Int32
        var y: Int32
        var label: String
      }
      """,
      to: """
      struct Point {
        var x: Int32
        var y: Int32
        var label: String
      }

      extension Point: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Point", fields: 3)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int32, y: deserializer.decode() as Int32, label: deserializer.decode() as String)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `a global-actor type derives nonisolated serialize`() {
    // A `@MainActor` (or any global-actor-isolated) type isolates its members,
    // so a plain `serialize` would inherit that isolation and could not satisfy
    // the NONISOLATED `Serializable` requirement — a Swift 6 conformance-
    // isolation error. The witness is emitted `nonisolated` so it satisfies the
    // requirement; a value type's `Sendable` `self.<field>` reads stay
    // reachable from the nonisolated body.
    expand("""
      @MainActor
      @Serializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @MainActor
      struct S {
        var x: Int
      }

      extension S: Decant.Serializable {
        nonisolated public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a global-actor type derives nonisolated deserialize`() {
    // The deserialize twin: a `@MainActor` type's `deserialize` is emitted
    // `nonisolated` so it satisfies the nonisolated `Deserializable`
    // requirement. The memberwise-init call runs from the nonisolated body.
    expand("""
      @MainActor
      @Deserializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @MainActor
      struct S {
        var x: Int
      }

      extension S: Decant.Deserializable {
        nonisolated public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a global-actor type with a possibly non-Sendable field is diagnosed`() {
    // The nonisolated witness of a global-actor-isolated type can read an
    // isolated stored property (and call the memberwise init) only when the
    // value is `Sendable`. A field whose written type is not a recognizably
    // `Sendable` standard type may be non-Sendable — the syntactic macro cannot
    // confirm the conformance — so the derive would emit `self.<field>` and
    // `Self(<field>: …)` the compiler rejects from the nonisolated body.
    // Diagnose up front rather than emit that. (An all-`Sendable` isolated type
    // still derives — the goldens above.)
    assertMacroExpansion("""
      @MainActor
      @Serializable
      @Deserializable
      struct S {
        var c: C
      }
      """,
      expandedSource: """
      @MainActor
      struct S {
        var c: C
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.isolation.message,
                       line: 2, column: 1),
        DiagnosticSpec(message: DecantDiagnostic.isolation.message,
                       line: 3, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `a non-isolated type with a non-Sendable field is not diagnosed`() {
    // The isolation check is gated on the global actor: an UNISOLATED type's
    // witness is not nonisolated, so its `self.<field>` read needs no
    // Sendability, and a non-Sendable field derives unhindered.
    expand("""
      @Serializable
      struct S {
        var c: C
      }
      """,
      to: """
      struct S {
        var c: C
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("c", self.c)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a non-isolated type derives an unmarked serialize`() {
    // The negative half: a type carrying NO global-actor attribute is not
    // isolated, so its witness is emitted WITHOUT `nonisolated`. The `@frozen`
    // built-in attribute imposes no isolation and does not trip the check.
    expand("""
      @frozen
      @Serializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @frozen
      struct S {
        var x: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `a global-actor field whose name merely contains Sendable is diagnosed`() {
    // The Sendability check matches `Sendable` as a real identifier, not a
    // SUBSTRING: a field typed `NonSendable` (a normal non-Sendable class)
    // spells the letters `Sendable` but is not the `Sendable` protocol, so it
    // may be actor-isolated non-Sendable state the nonisolated witness cannot
    // reach. Diagnose it rather than let a `.contains("Sendable")` wave it
    // through into code the compiler rejects.
    assertMacroExpansion("""
      @MainActor
      @Serializable
      @Deserializable
      struct S {
        var value: NonSendable
      }
      """,
      expandedSource: """
      @MainActor
      struct S {
        var value: NonSendable
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.isolation.message,
                       line: 2, column: 1),
        DiagnosticSpec(message: DecantDiagnostic.isolation.message,
                       line: 3, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `a global-actor field of an array of a Sendable-substring type is diagnosed`()
  {
    // The substring trap also hid inside a container: `Array<NonSendable>`
    // desugars to its element `NonSendable`, which is NOT the `Sendable`
    // protocol, so the array is not vouched Sendable and the field is
    // diagnosed. Only a genuine `Sendable` element (or standard value type)
    // would make the array safe.
    assertMacroExpansion("""
      @MainActor
      @Serializable
      struct S {
        var values: Array<NonSendable>
      }
      """,
      expandedSource: """
      @MainActor
      struct S {
        var values: Array<NonSendable>
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.isolation.message,
                       line: 2, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `a global-actor field of any Sendable derives nonisolated`() {
    // An existential over the real `Sendable` protocol (`any Sendable`) IS
    // Sendable, so an isolated stored property of it stays reachable from the
    // nonisolated witness and the derive proceeds. The identifier check accepts
    // it where the substring check happened to too — but here it is accepted
    // for the RIGHT reason (a real `Sendable` token, not the substring).
    expand("""
      @MainActor
      @Serializable
      struct S {
        var value: any Sendable
      }
      """,
      to: """
      @MainActor
      struct S {
        var value: any Sendable
      }

      extension S: Decant.Serializable {
        nonisolated public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a global-actor field of a Sendable composition derives`() {
    // A composition one of whose members is the real `Sendable` protocol
    // (`P & Sendable`) is Sendable, so the field is safe and the derive
    // proceeds — the composition-member half of the identifier check.
    expand("""
      @MainActor
      @Serializable
      struct S {
        var value: any P & Sendable
      }
      """,
      to: """
      @MainActor
      struct S {
        var value: any P & Sendable
      }

      extension S: Decant.Serializable {
        nonisolated public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `an implicitly-unwrapped optional field casts to the optional`() {
    // A field of implicitly-unwrapped optional type `Int!` cannot annotate its
    // read as `decode() as Int!` — the `!` sugar is not a legal coercion
    // target — so the cast is normalized to the optional `Int?`, which IS
    // legal and which the memberwise-init parameter (still `Int!`) accepts.
    expand("""
      @Deserializable
      struct S {
        var x: Int!
      }
      """,
      to: """
      struct S {
        var x: Int!
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int?)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a nested implicitly-unwrapped optional field casts to the optional`() {
    // The normalization rewrites only the outermost IUO sugar: `[Int]!` casts
    // as `[Int]?`, the wrapped `[Int]` left verbatim.
    expand("""
      @Deserializable
      struct S {
        var y: [Int]!
      }
      """,
      to: """
      struct S {
        var y: [Int]!
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(y: deserializer.decode() as [Int]?)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `an opaque field reads without an as coercion`() {
    // An opaque `some P` field cannot annotate its read as
    // `decode() as some …` — `some` is legal only in a declaration position,
    // never as a cast target — so the read stays a bare `decode()`, whose
    // contextual result type the opaque memberwise-init parameter drives. A
    // concrete field keeps its `as` annotation (the sibling goldens); only the
    // opaque one sheds it, exactly as a type-less field does.
    expand("""
      @Deserializable
      struct S {
        var x: some P & Decant.Deserializable = X()
      }
      """,
      to: """
      struct S {
        var x: some P & Decant.Deserializable = X()
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode())
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `an existential field keeps its as coercion`() {
    // Only opaque `some` sheds the cast: an `any P` existential IS a legal
    // coercion target, so it keeps the `decode() as any P` annotation like any
    // concrete type.
    expand("""
      @Deserializable
      struct S {
        var x: any Decant.Deserializable
      }
      """,
      to: """
      struct S {
        var x: any Decant.Deserializable
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as any Decant.Deserializable)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `the derive skips a computed property`() {
    expand("""
      @Serializable
      struct Box {
        var value: Int
        var doubled: Int { value * 2 }
      }
      """,
      to: """
      struct Box {
        var value: Int
        var doubled: Int { value * 2 }
      }

      extension Box: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `the derive ignores an attribute on a computed property`() {
    // A computed property has no storage, so it is neither serialized nor a
    // memberwise-init parameter and its attributes are irrelevant. The
    // computed skip must run BEFORE the property-wrapper check, so an
    // attribute the derive does not recognize (`@MainActor`) on the computed
    // `y` is not misread as a wrapper and does not reject the whole derive;
    // only the stored `x` is serialized.
    expand("""
      @Serializable
      struct S {
        var x: Int
        @MainActor var y: Int { 0 }
      }
      """,
      to: """
      struct S {
        var x: Int
        @MainActor var y: Int { 0 }
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `the wrapper check still rejects a stored field beside a computed one`() {
    // The reorder skips the computed `y` (its `@MainActor` ignored), but the
    // property-wrapper check must still fire for the STORED wrapped `x`: a
    // wrapper-backed stored property is rejected as before.
    assertMacroExpansion("""
      @Serializable
      struct S {
        @W(raw: 0) var x: Int
        @MainActor var y: Int { 0 }
      }
      """,
      expandedSource: """
      struct S {
        @W(raw: 0) var x: Int
        @MainActor var y: Int { 0 }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.wrapper.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `Serializable on a deprecated stored field is diagnosed`() {
    // A deprecated stored field warns on every access, and serialize reads
    // `self.<field>`; no structuring lets a non-deprecated witness touch it
    // warning-free, so the field is diagnosed rather than emitted (mirroring
    // the rejection of a deprecated init).
    assertMacroExpansion("""
      @Serializable
      struct S {
        @available(*, deprecated) var x: Int
      }
      """,
      expandedSource: """
      struct S {
        @available(*, deprecated) var x: Int
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.deprecated.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `both derives on a deprecated stored field diagnose serialize`() {
    // The serialize side of a combined `@Serializable @Deserializable` still
    // reads `self.<field>`, so the deprecated-field rejection fires from the
    // serialize expansion (which emits nothing) even when deserialize is
    // derived alongside. Deserialize passes the field as a memberwise-init
    // argument, not an access, so it derives warning-free next to the
    // diagnostic.
    assertMacroExpansion("""
      @Serializable
      @Deserializable
      struct S {
        @available(*, deprecated) var x: Int
      }
      """,
      expandedSource: """
      struct S {
        @available(*, deprecated) var x: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.deprecated.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `Deserializable alone on a deprecated stored field derives`() {
    // Deserialize passes the deprecated field as a memberwise-init argument
    // (`Self(x: …)`), which is not an access and so does not warn — the derive
    // is warning-free, so a `@Deserializable`-only shape is allowed rather than
    // diagnosed (unlike the serialize side, which reads `self.<field>`).
    expand("""
      @Deserializable
      struct S {
        @available(*, deprecated) var x: Int
      }
      """,
      to: """
      struct S {
        @available(*, deprecated) var x: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable keeps an observed stored property in order`() {
    expand("""
      @Serializable
      struct Counter {
        var a: Int
        var n: Int = 0 {
          didSet {}
        }
        var b: Int
      }
      """,
      to: """
      struct Counter {
        var a: Int
        var n: Int = 0 {
          didSet {}
        }
        var b: Int
      }

      extension Counter: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Counter", fields: 3)
          try __macro_local_9structurefMu_.field("a", self.a)
          try __macro_local_9structurefMu_.field("n", self.n)
          try __macro_local_9structurefMu_.field("b", self.b)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable keeps an observed stored property in order`() {
    expand("""
      @Deserializable
      struct Counter {
        var a: Int
        var n: Int = 0 {
          didSet {}
        }
        var b: Int
      }
      """,
      to: """
      struct Counter {
        var a: Int
        var n: Int = 0 {
          didSet {}
        }
        var b: Int
      }

      extension Counter: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Counter", fields: 3)
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, n: deserializer.decode() as Int, b: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable destructures a tuple binding in order`() {
    expand("""
      @Serializable
      struct Line {
        var a: Int
        var (x, y): (Int, Int)
        var b: Int
      }
      """,
      to: """
      struct Line {
        var a: Int
        var (x, y): (Int, Int)
        var b: Int
      }

      extension Line: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Line", fields: 4)
          try __macro_local_9structurefMu_.field("a", self.a)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          try __macro_local_9structurefMu_.field("b", self.b)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable destructures a tuple binding in order`() {
    expand("""
      @Deserializable
      struct Line {
        var a: Int
        var (x, y): (Int, Int)
        var b: Int
      }
      """,
      to: """
      struct Line {
        var a: Int
        var (x, y): (Int, Int)
        var b: Int
      }

      extension Line: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Line", fields: 4)
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, x: deserializer.decode() as Int, y: deserializer.decode() as Int, b: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `the derive names a tuple component for its pattern`() {
    expand("""
      @Serializable
      struct Pair {
        var (x, y): (p: Int, q: Int)
      }
      """,
      to: """
      struct Pair {
        var (x, y): (p: Int, q: Int)
      }

      extension Pair: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Pair", fields: 2)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `the derive recurses through a nested tuple binding`() {
    expand("""
      @Deserializable
      struct Nested {
        var (x, (y, z)): (Int, (Int, Int))
      }
      """,
      to: """
      struct Nested {
        var (x, (y, z)): (Int, (Int, Int))
      }

      extension Nested: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Nested", fields: 3)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int, y: deserializer.decode() as Int, z: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `the derive drops a wildcard tuple element`() {
    expand("""
      @Serializable
      struct Half {
        var (x, _): (Int, Int)
      }
      """,
      to: """
      struct Half {
        var (x, _): (Int, Int)
      }

      extension Half: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Half", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `applying the derive to an enum is diagnosed`() {
    assertMacroExpansion("""
      @Serializable
      enum Color {
        case red
        case green
      }
      """,
      expandedSource: """
      enum Color {
        case red
        case green
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.nonstruct.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `applying the derive to a lazy property is diagnosed`() {
    assertMacroExpansion("""
      @Serializable
      struct S {
        lazy var cache = 0
      }
      """,
      expandedSource: """
      struct S {
        lazy var cache = 0
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.lazy.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `applying the derive to an initialized let is diagnosed`() {
    assertMacroExpansion("""
      @Deserializable
      struct S {
        let version = 1
      }
      """,
      expandedSource: """
      struct S {
        let version = 1
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.constant.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `Serializable writes an initialized let it reads through self`() {
    expand("""
      @Serializable
      struct S {
        let version = 1
        let x: Int
      }
      """,
      to: """
      struct S {
        let version = 1
        let x: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("version", self.version)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `applying the derive to a wrapper-backed property is diagnosed`() {
    assertMacroExpansion("""
      @Serializable
      struct S {
        @W(raw: 0) var x: Int
      }
      """,
      expandedSource: """
      struct S {
        @W(raw: 0) var x: Int
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.wrapper.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `applying the derive to a qualified-wrapper property is diagnosed`()
  {
    assertMacroExpansion("""
      @Serializable
      struct S {
        @MyModule.W(raw: 0) var x: Int
      }
      """,
      expandedSource: """
      struct S {
        @MyModule.W(raw: 0) var x: Int
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.wrapper.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `the derive keeps a property carrying a built-in attribute`() {
    // A built-in declaration attribute — a plain `@available` platform gate —
    // is not a property wrapper, so the field is collected and serialized
    // rather than rejected. (A *deprecated* `@available` is a separate case:
    // its `self.<field>` read would warn, so it is diagnosed instead.)
    expand("""
      @Serializable
      struct S {
        @available(macOS 10.0, *) var x: Int
        var y: Int
      }
      """,
      to: """
      struct S {
        @available(macOS 10.0, *) var x: Int
        var y: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `the derive keeps a property carrying @DecantName or @DecantSkip`()
  {
    expand("""
      @Serializable
      struct S {
        @DecantName var x: Int
        @DecantSkip var y: Int
      }
      """,
      to: """
      struct S {
        @DecantName var x: Int
        @DecantSkip var y: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `the derive keeps an uninitialized let and initialized var`() {
    expand("""
      @Deserializable
      struct S {
        let x: Int
        var y = 0
      }
      """,
      to: """
      struct S {
        let x: Int
        var y = 0
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int, y: deserializer.decode())
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable reads a field named for a local through self`() {
    expand("""
      @Serializable
      struct S {
        var structure: Int
        var serializer: Int
      }
      """,
      to: """
      struct S {
        var structure: Int
        var serializer: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("structure", self.structure)
          try __macro_local_9structurefMu_.field("serializer", self.serializer)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable reads a param-named field in argument position`()
  {
    expand("""
      @Deserializable
      struct S {
        var deserializer: Int
        var value: Int
      }
      """,
      to: """
      struct S {
        var deserializer: Int
        var value: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(deserializer: deserializer.decode() as Int, value: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `the derive skips a type-level stored property`() {
    expand("""
      @Deserializable
      struct S {
        static let version = 1
        static var shared = 0
        let x: Int
        var y: Int
      }
      """,
      to: """
      struct S {
        static let version = 1
        static var shared = 0
        let x: Int
        var y: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int, y: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `the derive reads an inferred-type field without annotating it`() {
    expand("""
      @Deserializable
      struct S {
        var count = 0
        let name: String
      }
      """,
      to: """
      struct S {
        var count = 0
        let name: String
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(count: deserializer.decode(), name: deserializer.decode() as String)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable escapes a keyword field name in the member access`()
  {
    expand("""
      @Serializable
      struct S {
        var `self`: Int
        var `init`: Int
        var x: Int
      }
      """,
      to: """
      struct S {
        var `self`: Int
        var `init`: Int
        var x: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 3)
          try __macro_local_9structurefMu_.field("self", self.`self`)
          try __macro_local_9structurefMu_.field("init", self.`init`)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Serializable escapes a raw field name in each emission context`()
  {
    // A raw identifier (SE-0451) carries characters no bare interpolation
    // survives: the member access must backtick it and the string key must be
    // a valid literal — a `"` forces `#"…"#` delimiters.
    expand("""
      @Serializable
      struct S {
        var `foo bar`: Int
        var `quote"x`: Int
      }
      """,
      to: """
      struct S {
        var `foo bar`: Int
        var `quote"x`: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("foo bar", self.`foo bar`)
          try __macro_local_9structurefMu_.field(#"quote"x"#, self.`quote"x`)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable escapes a raw field name in the init label`() {
    // A raw identifier is NOT a valid bare argument label (`foo bar:` is a
    // syntax error), so the label must keep its backticks — unlike a keyword,
    // which stays bare.
    expand("""
      @Deserializable
      struct S {
        var `foo bar`: Int
        var `quote"x`: Int
      }
      """,
      to: """
      struct S {
        var `foo bar`: Int
        var `quote"x`: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(`foo bar`: deserializer.decode() as Int, `quote"x`: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Deserializable keeps a keyword field name bare in the init label`()
  {
    // An argument label accepts a keyword unescaped — escaping one instead
    // warns — so the bare `self:` / `init:` labels are correct, and only the
    // serialize member access above is escaped.
    expand("""
      @Deserializable
      struct S {
        var `self`: Int
        var `init`: Int
        var x: Int
      }
      """,
      to: """
      struct S {
        var `self`: Int
        var `init`: Int
        var x: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 3)
          let __macro_local_5valuefMu_ = try Self(self: deserializer.decode() as Int, init: deserializer.decode() as Int, x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable escapes an underscore field name in the member access`()
  {
    // The wildcard `_` is a plain, non-keyword identifier, so the keyword and
    // raw-identifier rules leave it bare — but a bare `self._` does not parse,
    // so the member access must backtick it. The serialization-name STRING key
    // stays the bare `"_"` (data, not an identifier).
    expand("""
      @Serializable
      struct S {
        var `_`: Int
        var x: Int
      }
      """,
      to: """
      struct S {
        var `_`: Int
        var x: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("_", self.`_`)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable escapes an underscore field name in the init label`()
  {
    // A bare `_:` argument label is an OMITTED (positional) label, not the real
    // `_` label the memberwise init requires, so the label must be backticked
    // (`` `_`: ``) — unlike an ordinary keyword, which stays bare. Escaping `_`
    // as a label warns for neither a keyword nor a raw identifier.
    expand("""
      @Deserializable
      struct S {
        var `_`: Int
        var x: Int
      }
      """,
      to: """
      struct S {
        var `_`: Int
        var x: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(`_`: deserializer.decode() as Int, x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable spells a raw type name safely in each context`() {
    // A raw type name (SE-0451) carrying a quote must be spelled by position:
    // the `extension` header keeps the backticks (identifier position) while
    // the serialized structure name is the CANONICAL bare name as a valid
    // string literal — the quote forces `#"…"#` delimiters.
    expand(#"""
      @Serializable
      struct `Quote"Type` {
        var x: Int
      }
      """#,
      to: #"""
      struct `Quote"Type` {
        var x: Int
      }

      extension `Quote"Type`: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure(#"Quote"Type"#, fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """#)
  }

  @Test func `Deserializable spells a raw type name safely in each context`() {
    // The `extension` header keeps the backticks (an identifier position); the
    // `structure(…)` argument is the canonical bare name as a valid `#"…"#`
    // literal. The constructor is `Self`, so the raw type name never appears in
    // call position.
    expand(#"""
      @Deserializable
      struct `Quote"Type` {
        var x: Int
      }
      """#,
      to: #"""
      struct `Quote"Type` {
        var x: Int
      }

      extension `Quote"Type`: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure(#"Quote"Type"#, fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """#)
  }

  @Test func `deserialize constructs Self, not the model type name`() {
    // The deserialize signature names its generic `Deserializer` parameter `D`.
    // A model named `D` collides with it, so a by-name constructor (`try D(…)`)
    // would resolve to the generic parameter, not the model. The derive spells
    // the constructor `Self`, which is the conforming type unambiguously, so a
    // `struct D` derives — the `try Self(x: …)` line below is the guard.
    expand("""
      @Deserializable
      struct D {
        var x: Int
      }
      """,
      to: """
      struct D {
        var x: Int
      }

      extension D: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("D", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed when a custom init suppresses the init`()
  {
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init() {
          x = 0
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init() {
          x = 0
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `a matching user init suppresses no diagnostic and derives`() {
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed when an init matches by label only`() {
    // The label matches, but `init(x: String)` reconstructs an `Int` field
    // from a `String` decode: a shape a non-self-converting format round-trips
    // wrong, so the type mismatch must still diagnose.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed when a matching field has no type`() {
    // `count`'s type is inferred from its initializer, so the macro cannot
    // prove `init(count: Int)`'s parameter type equals it; equivalence is
    // unprovable, so the init does not match and the diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var count = 0
        init(count: Int) {
          self.count = count
        }
      }
      """,
      expandedSource: """
      struct S {
        var count = 0
        init(count: Int) {
          self.count = count
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `deserialize is diagnosed when a repeated generic binds two types`() {
    // The init reuses one generic `U` for `x` and `y`, whose fields are `Int`
    // and `String`. A per-label match would read the init as covering, but the
    // emitted `Self(x: … as Int, y: … as String)` would infer `U` as both — a
    // conflict Swift rejects. The candidate is rejected as inconsistent, so the
    // intended `.initializer` diagnostic fires rather than uncompilable code.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        var y: String
        init<U>(x: U, y: U) {
          self.x = x as! Int
          self.y = y as! String
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        var y: String
        init<U>(x: U, y: U) {
          self.x = x as! Int
          self.y = y as! String
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed when only a failable init matches`() {
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init?(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init?(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed when only a throwing init matches`() {
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) throws {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init(x: Int) throws {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `a throws(Never) replacement init derives without diagnosis`() {
    // Swift treats `throws(Never)` as NONTHROWING, so the custom
    // `init(x:) throws(Never)` is callable as the derive's `Self(x: …)` with no
    // error the typed-throws context must absorb. The init-candidate check
    // accepts it — a genuine `throws` (above) is still diagnosed — and the
    // derive emits the memberwise-equivalent call unchanged.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) throws(Never) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) throws(Never) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed when only an async init matches`() {
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) async {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init(x: Int) async {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a MainActor-isolated init`() {
    // `@MainActor init(x: Int)` matches the `x` label and the `Int` spelling,
    // but the derive's synchronous, nonisolated `deserialize` witness cannot
    // call an actor-isolated init — `Self(x: deserializer.decode())` would be
    // an isolation violation. The custom (non-built-in) attribute signals the
    // init is not a nonisolated replacement, so it is a non-match and the
    // `.initializer` diagnostic fires rather than an ill-typed expansion.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @MainActor init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @MainActor init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a custom global-actor init`() {
    // A custom global actor is a custom attribute like `@MainActor`, imposing
    // isolation the nonisolated witness cannot honor, so `@MyActor init(x:)` is
    // a non-match and the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @MyActor init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @MyActor init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for an isolated-parameter init`() {
    // An `isolated` parameter parses as a specified type, so it is rejected
    // like `inout`/`borrowing`: the derive's by-value call cannot supply it,
    // and the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: MyActor
        init(x: isolated MyActor) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: MyActor
        init(x: isolated MyActor) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `an inlinable user init matches and derives`() {
    // A built-in declaration attribute — `@inlinable` — does not impose actor
    // isolation on the synchronous nonisolated call, so an `@inlinable` init
    // remains a valid memberwise-equivalent replacement: it matches, no
    // diagnostic fires, and the derive proceeds.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        @inlinable init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        @inlinable init(x: Int) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `Serializable with a custom init is not diagnosed`() {
    expand("""
      @Serializable
      struct S {
        var x: Int
        init() {
          x = 0
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init() {
          x = 0
        }
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `the derive skips a static property on the serialize side`() {
    expand("""
      @Serializable
      struct S {
        static let version = 1
        let x: Int
        var y: Int
      }
      """,
      to: """
      struct S {
        static let version = 1
        let x: Int
        var y: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `the derive gives its generic parameter a hygienic name`() {
    // The serialize/deserialize generic parameter is always hygienic, even for
    // a type whose parameter (`T`) does not collide with `S`/`D`: the compiler
    // hands the macro the declaration detached from its enclosing tree, so a
    // readable `S`/`D` could still shadow an enclosing context's parameter the
    // macro cannot see. A `__macro_local_…` name never shadows.
    expand("""
      @Serializable
      @Deserializable
      struct Pair<T> {
        var x: Int
        var y: Int
      }
      """,
      to: """
      struct Pair<T> {
        var x: Int
        var y: Int
      }

      extension Pair: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Pair", fields: 2)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          return try __macro_local_9structurefMu_.end()
        }
      }

      extension Pair: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Pair", fields: 2)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int, y: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `a type parameter named S does not shadow the serializer`() {
    // The type's own `S` would collide with a readable serialize `<S>`; the
    // hygienic name sidesteps it, as it does for any parameter name.
    expand("""
      @Serializable
      struct Box<S> {
        var x: Int
      }
      """,
      to: """
      struct Box<S> {
        var x: Int
      }

      extension Box: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a type parameter named D does not shadow the deserializer`() {
    // The deserialize twin — the type's own `D` would collide with a readable
    // `<D>`; the hygienic name sidesteps it.
    expand("""
      @Deserializable
      struct Box<D> {
        var x: Int
      }
      """,
      to: """
      struct Box<D> {
        var x: Int
      }

      extension Box: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Box", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `a type nested in a generic context does not shadow`() {
    // The derive is applied to `Inner`, which is not itself generic, but is
    // nested in `Outer<S>`. A readable serialize `<S>` would shadow `Outer`'s
    // `S` (an error under Swift 6). The hygienic parameter name avoids it even
    // though the detached declaration cannot reveal the enclosing `S`.
    expand("""
      struct Outer<S> {
        @Serializable
        struct Inner {
          var x: Int
        }
      }
      """,
      to: """
      struct Outer<S> {
        struct Inner {
          var x: Int
        }
      }

      extension Outer.Inner: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Outer.Inner", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed for an omitted-label positional init`() {
    // The field is named `_`, and the only init takes a POSITIONAL parameter
    // (`init(_ x: Int)`, an omitted external label), which is NOT the escaped
    // `` `_` `` label the derive emits as `` Self(`_`: …) ``. The omitted `_`
    // must not be conflated with a field named `_`, so the init does not match
    // and the `.initializer` diagnostic fires — rather than emitting a call the
    // positional init does not accept.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var `_`: Int
        init(_ x: Int) {
          self.`_` = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var `_`: Int
        init(_ x: Int) {
          self.`_` = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a non-matching conditional init`() {
    // An init inside an active `#if` still suppresses the synthesized
    // memberwise init in that build, but the scan once saw only top-level
    // inits, so the active branch derived an uncompilable `Self(x: …)`. The
    // scan now recurses through the `#if` clause; the plugin cannot resolve the
    // condition (`#if true` keeps the branch deterministically active), so a
    // non-matching conditional init diagnoses conservatively.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        #if true
        init() {
          self.x = 0
        }
        #endif
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        #if true
        init() {
          self.x = 0
        }
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `a matching conditional init suppresses no diagnostic and derives`()
  {
    // A conditional init that matches the fields is safe in either build:
    // active it replaces the memberwise init, inactive the memberwise init is
    // synthesized, so it never diagnoses and the derive proceeds. The `#if`
    // guards no stored field, so it is dropped from the emission entirely — the
    // serialized field set never varies — and the count and `Self(…)` are the
    // plain unconditional shape.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        #if true
        init(x: Int) {
          self.x = x
        }
        #endif
      }
      """,
      to: """
      struct S {
        var x: Int
        #if true
        init(x: Int) {
          self.x = x
        }
        #endif
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed for a nested conditional init`() {
    // The recursion descends through a nested `#if`, so a non-matching init two
    // `#if` levels deep is still found and diagnosed.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        #if true
        #if true
        init() {
          self.x = 0
        }
        #endif
        #endif
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        #if true
        #if true
        init() {
          self.x = 0
        }
        #endif
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `deserialize is diagnosed when a matching clause has a non-matching sibling`()
  {
    // The `#if true` clause holds a matching init, but the mutually-exclusive
    // `#else` clause holds a non-matching one — and in the build where the
    // `#else` is active, its `init()` still suppresses the memberwise init with
    // no callable `Self(x: …)` target. A per-branch scan finds the `#else`
    // clause unsafe (no match in reach), so it diagnoses even though the `#if`
    // build alone would compile; a global "some clause matches" scan misses it.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        #if true
        init(x: Int) {
          self.x = x
        }
        #else
        init() {
          self.x = 0
        }
        #endif
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        #if true
        init(x: Int) {
          self.x = x
        }
        #else
        init() {
          self.x = 0
        }
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `deserialize is diagnosed when the non-matching sibling is the #if clause`()
  {
    // The reverse arrangement: the `#else` clause matches while the `#if false`
    // clause does not. The plugin cannot resolve the condition, so it holds
    // each clause to its own active init set; the `#if` clause's `init()`
    // suppresses with no match in reach, so the derive still diagnoses.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        #if false
        init() {
          self.x = 0
        }
        #else
        init(x: Int) {
          self.x = x
        }
        #endif
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        #if false
        init() {
          self.x = 0
        }
        #else
        init(x: Int) {
          self.x = x
        }
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `deserialize is diagnosed for two non-matching #elseif clauses`() {
    // Neither mutually-exclusive clause carries a matching init, so every
    // active build suppresses with no callable target; both scopes are unsafe.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        #if false
        init() {
          self.x = 0
        }
        #elseif true
        init(y: Int) {
          self.x = y
        }
        #endif
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        #if false
        init() {
          self.x = 0
        }
        #elseif true
        init(y: Int) {
          self.x = y
        }
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `a top-level match saves a non-matching conditional sibling init`() {
    // A top-level matching init is active in every build, so it replaces the
    // memberwise init the conditional `init()` also suppresses — every build
    // has a callable `Self(x: …)` target. The per-build analysis pairs the
    // active fields with the active inits: the `#if true` build sees both
    // inits, the `#else` build only the top-level one, and each covers the
    // single `x`, so no diagnostic fires. The `#if` guards no stored field, so
    // it is dropped from the emission and the plain shape derives.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        #if true
        init() {
          self.init(x: 0)
        }
        #endif
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        #if true
        init() {
          self.init(x: 0)
        }
        #endif
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed for an inout-parameter init`() {
    // `init(x: inout Int)` matches the `x` label and the bare `Int` spelling,
    // but the derive's by-value `Self(x: deserializer.decode())` cannot bind
    // the `inout` parameter's lvalue, so the specified parameter is a non-match
    // and the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init(x: inout Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init(x: inout Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a borrowing-parameter init`() {
    // An ownership specifier the memberwise init never carries is rejected the
    // same way as `inout`: the derive's by-value call cannot satisfy it.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init(x: borrowing Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init(x: borrowing Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `Serializable mirrors a conditional field's #if guard`() {
    // A stored property under `#if` cannot be counted or written
    // unconditionally — the plugin never resolves the condition — so the derive
    // mirrors the guard: a count accumulator tallies the field only in its
    // clause, and the write is emitted under the same `#if`.
    expand("""
      @Serializable
      struct S {
        var a: Int
        #if os(Windows)
        var trace: Int
        #endif
        var b: Int
      }
      """,
      to: """
      struct S {
        var a: Int
        #if os(Windows)
        var trace: Int
        #endif
        var b: Int
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 2
          #if os(Windows)
          __macro_local_6fieldsfMu_ += 1
          #endif
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: __macro_local_6fieldsfMu_)
          try __macro_local_9structurefMu_.field("a", self.a)
          #if os(Windows)
          try __macro_local_9structurefMu_.field("trace", self.trace)
          #endif
          try __macro_local_9structurefMu_.field("b", self.b)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `Deserializable emits a per-branch Self for a conditional field`()
  {
    // An initializer's argument list cannot hold a `#if`, so the derive emits a
    // complete `Self(…)` per branch under the mirrored guard. A `#if` with no
    // `#else` still needs a leaf for the inactive case — its field absent — so
    // an `#else` is synthesized. The count accumulator frames the whole tree.
    expand("""
      @Deserializable
      struct S {
        var a: Int
        #if os(Windows)
        var trace: Int
        #endif
        var b: Int
      }
      """,
      to: """
      struct S {
        var a: Int
        #if os(Windows)
        var trace: Int
        #endif
        var b: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 2
          #if os(Windows)
          __macro_local_6fieldsfMu_ += 1
          #endif
          try deserializer.structure("S", fields: __macro_local_6fieldsfMu_)
          #if os(Windows)
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, trace: deserializer.decode() as Int, b: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #else
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, b: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #endif
        }
      }
      """)
  }

  @Test func `Deserializable mirrors an #if/#elseif/#else chain`() {
    // Each clause of the chain is a distinct branch, so the derive emits a
    // `Self(…)` per clause carrying that clause's active field. The source
    // `#else` is the exhaustive fallback, so no `#else` is synthesized.
    expand("""
      @Deserializable
      struct S {
        var a: Int
        #if DEBUG
        var d: Int
        #elseif TEST
        var t: Int
        #else
        var r: Int
        #endif
      }
      """,
      to: """
      struct S {
        var a: Int
        #if DEBUG
        var d: Int
        #elseif TEST
        var t: Int
        #else
        var r: Int
        #endif
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 1
          #if DEBUG
          __macro_local_6fieldsfMu_ += 1
          #elseif TEST
          __macro_local_6fieldsfMu_ += 1
          #else
          __macro_local_6fieldsfMu_ += 1
          #endif
          try deserializer.structure("S", fields: __macro_local_6fieldsfMu_)
          #if DEBUG
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, d: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #elseif TEST
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, t: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #else
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, r: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #endif
        }
      }
      """)
  }

  @Test func `Serializable recurses through a nested #if`() {
    // A `#if` inside a clause recurses: the count accumulates the outer then
    // the inner field under nested guards, each write emitted under both.
    expand("""
      @Serializable
      struct S {
        #if A
        var x: Int
        #if B
        var y: Int
        #endif
        #endif
      }
      """,
      to: """
      struct S {
        #if A
        var x: Int
        #if B
        var y: Int
        #endif
        #endif
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 0
          #if A
          __macro_local_6fieldsfMu_ += 1
          #if B
          __macro_local_6fieldsfMu_ += 1
          #endif
          #endif
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: __macro_local_6fieldsfMu_)
          #if A
          try __macro_local_9structurefMu_.field("x", self.x)
          #if B
          try __macro_local_9structurefMu_.field("y", self.y)
          #endif
          #endif
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `too many independent #if blocks is diagnosed`() {
    // The per-branch deserialize calls are the cartesian product of the blocks'
    // clauses, so nine two-clause `#if`s would emit 2^9 = 512 `Self(…)` calls,
    // past the 256 cap. The `.conditional` diagnostic fires instead.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        #if A
        var a: Int
        #endif
        #if B
        var b: Int
        #endif
        #if C
        var c: Int
        #endif
        #if D
        var d: Int
        #endif
        #if E
        var e: Int
        #endif
        #if F
        var f: Int
        #endif
        #if G
        var g: Int
        #endif
        #if H
        var h: Int
        #endif
        #if I
        var i: Int
        #endif
      }
      """,
      expandedSource: """
      struct S {
        #if A
        var a: Int
        #endif
        #if B
        var b: Int
        #endif
        #if C
        var c: Int
        #endif
        #if D
        var d: Int
        #endif
        #if E
        var e: Int
        #endif
        #if F
        var f: Int
        #endif
        #if G
        var g: Int
        #endif
        #if H
        var h: Int
        #endif
        #if I
        var i: Int
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.conditional.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `deserialize is diagnosed for a conditional-field init without a default`()
  {
    // `x` is a `#if`-guarded conditional field, so the branch that omits the
    // clause emits `Self(base:)` — but the top-level `init(base:x:)` suppresses
    // the memberwise init in every build and gives `x` no default, so that
    // shorter call cannot resolve. The init is a non-match and the
    // `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var base: Int
        #if true
        var x: Int
        #endif
        init(base: Int, x: Int) {
          self.base = base
        }
      }
      """,
      expandedSource: """
      struct S {
        var base: Int
        #if true
        var x: Int
        #endif
        init(base: Int, x: Int) {
          self.base = base
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `a conditional-field init with a default derives`() {
    // The same shape, but `x`'s parameter now carries a default, so the branch
    // that omits the `#if` clause resolves `Self(base:)` through it and the
    // branch that keeps it passes `x`. The init matches in every build, no
    // diagnostic fires, and the per-branch `Self(…)` shape derives.
    expand("""
      @Deserializable
      struct S {
        var base: Int
        #if true
        var x: Int
        #endif
        init(base: Int, x: Int = 0) {
          self.base = base
        }
      }
      """,
      to: """
      struct S {
        var base: Int
        #if true
        var x: Int
        #endif
        init(base: Int, x: Int = 0) {
          self.base = base
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 1
          #if true
          __macro_local_6fieldsfMu_ += 1
          #endif
          try deserializer.structure("S", fields: __macro_local_6fieldsfMu_)
          #if true
          let __macro_local_5valuefMu_ = try Self(base: deserializer.decode() as Int, x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #else
          let __macro_local_5valuefMu_ = try Self(base: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #endif
        }
      }
      """)
  }

  @Test func `deserialize is diagnosed for an unavailable init`() {
    // `@available(*, unavailable)` makes the init uncallable, so the derive's
    // `Self(x: …)` would resolve to an unavailable initializer — a hard error.
    // The init is a non-match, so the safe `.initializer` diagnostic fires
    // instead. `@available` is a built-in, so only its arguments — not the
    // attribute itself — flag it.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(*, unavailable) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(*, unavailable) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for an obsoleted init`() {
    // An `obsoleted:` argument likewise makes the init uncallable past the
    // version, so it is a non-match and the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(macOS, obsoleted: 1.0) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(macOS, obsoleted: 1.0) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a deprecated init`() {
    // Calling a `deprecated` init WARNS at the emitted `Self(x: …)`, which the
    // warning-free build rejects, so a `deprecated` `@available` is a non-match
    // too and the `.initializer` diagnostic fires rather than a warning.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(*, deprecated) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(*, deprecated) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a version-restricted init`() {
    // A short-form platform version restriction (`@available(macOS 10.0, *)`)
    // gates the init to a deployment target the generated witness is NOT
    // emitted under, so `Self(x: …)` compiles above the version and errors
    // below it — the macro cannot guarantee the witness is gated the same. The
    // init is therefore not a safe unconditional replacement; it is a non-match
    // and the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(macOS 10.0, *) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(macOS 10.0, *) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for a swift-version-restricted init`() {
    // The language-version spelling (`@available(swift 99)`) gates the init to
    // a Swift version the witness is not emitted under, exactly like a platform
    // version restriction, so it is a non-match and the `.initializer`
    // diagnostic fires rather than an uncallable `Self(x: …)`.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(swift 99) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(swift 99) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize is diagnosed for an introduced-restricted init`() {
    // The long-form version restriction (`@available(macOS, introduced: 99)`)
    // gates the init like the short form, so it too is a non-match and the
    // `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(macOS, introduced: 99) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(macOS, introduced: 99) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `an init gated the same as the type is covered and derives`() {
    // The type is `@available(macOS 10.0, *)`, so the generated extension
    // carries that same gate and the witness's `Self(x: …)` runs only where the
    // conformance exists — exactly where the equally-gated `init(x: Int)` is
    // callable. The init's gate is covered by the type's, so it is a safe
    // replacement: no `.initializer` diagnostic, and the extension leads with
    // the copied `@available(macOS 10.0, *)`.
    expand("""
      @available(macOS 10.0, *)
      @Deserializable
      struct S {
        var x: Int
        @available(macOS 10.0, *) init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      @available(macOS 10.0, *)
      struct S {
        var x: Int
        @available(macOS 10.0, *) init(x: Int) {
          self.x = x
        }
      }

      @available(macOS 10.0, *)
      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a deprecated init covered by a deprecated type derives`() {
    // The type is `@available(*, deprecated)`, so the generated extension is
    // emitted deprecated too; a `Self(x: …)` inside a deprecated extension
    // raises no deprecation warning, so the equally-deprecated `init(x: Int)`
    // is a warning-free replacement. Its deprecation is covered by the type's,
    // so no `.initializer` diagnostic fires and the extension leads with the
    // copied `@available(*, deprecated)`.
    expand("""
      @available(*, deprecated)
      @Deserializable
      struct S {
        var x: Int
        @available(*, deprecated) init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      @available(*, deprecated)
      struct S {
        var x: Int
        @available(*, deprecated) init(x: Int) {
          self.x = x
        }
      }

      @available(*, deprecated)
      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a deprecated init derives when the type's deprecation differs`() {
    // The type is `@available(*, deprecated, message: "type")` and the init is
    // `@available(*, deprecated, message: "init")` — the two deprecations spell
    // DIFFERENT messages. The generated extension is still emitted deprecated,
    // and Swift suppresses the `Self(x: …)` deprecation warning inside a
    // deprecated context REGARDLESS of the message, so the init stays a
    // warning-free replacement. Coverage is by availability KIND — a deprecated
    // gate covers a deprecated init — not by exact gate text, so no
    // `.initializer` diagnostic fires and the extension leads with the copied
    // `@available(*, deprecated, message: "type")`.
    expand("""
      @available(*, deprecated, message: "type")
      @Deserializable
      struct S {
        var x: Int
        @available(*, deprecated, message: "init") init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      @available(*, deprecated, message: "type")
      struct S {
        var x: Int
        @available(*, deprecated, message: "init") init(x: Int) {
          self.x = x
        }
      }

      @available(*, deprecated, message: "type")
      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a deprecated init on a non-deprecated type is still diagnosed`() {
    // The type carries no deprecation, so the extension is not deprecated and
    // the `Self(x: …)` call to a `deprecated` init WARNS — the deprecation is
    // NOT covered by the (empty) type gate, so the `.initializer` diagnostic
    // still fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        @available(*, deprecated) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        @available(*, deprecated) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `an init gated narrower than the type is diagnosed`() {
    // The type is `@available(macOS 10.0, *)` but the init is
    // `@available(macOS 99, *)` — a NARROWER gate the extension does NOT carry.
    // Below macOS 99 the witness compiles yet `Self(x: …)` calls an unavailable
    // init, so the gate is not covered and the init is not a safe replacement:
    // the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @available(macOS 10.0, *)
      @Deserializable
      struct S {
        var x: Int
        @available(macOS 99, *) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      @available(macOS 10.0, *)
      struct S {
        var x: Int
        @available(macOS 99, *) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 2, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `an init gated broader than the type is covered and derives`() {
    // The type is `@available(macOS 10.0, iOS 13.0, *)`, so the extension
    // carries that gate; the init is `@available(macOS 10.0, *)` — a SAME-or-
    // BROADER gate. Per platform: on macOS the init's 10.0 floor matches the
    // type's, and on iOS the init's `*` fallback (no floor) is broader than the
    // type's 13.0, so the init is available everywhere the extension is. The
    // coverage is SEMANTIC and per platform, not by exact gate text, so the
    // broader init is a safe replacement and the derive proceeds, leading with
    // the copied `@available(macOS 10.0, iOS 13.0, *)`.
    expand("""
      @available(macOS 10.0, iOS 13.0, *)
      @Deserializable
      struct S {
        var x: Int
        @available(macOS 10.0, *) init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      @available(macOS 10.0, iOS 13.0, *)
      struct S {
        var x: Int
        @available(macOS 10.0, *) init(x: Int) {
          self.x = x
        }
      }

      @available(macOS 10.0, iOS 13.0, *)
      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a platform-matched deprecated init is covered and derives`() {
    // The type and the init are BOTH `@available(macOS, deprecated: 10.0)` — a
    // platform-scoped deprecation on the SAME platform. The extension inherits
    // the type's macOS deprecation, so the `Self(x: …)` call sits inside a
    // macOS-deprecated context where Swift suppresses the init's deprecation
    // warning. The deprecation is covered on its platform, so the derive
    // proceeds warning-free, leading with the copied
    // `@available(macOS, deprecated: 10.0)`.
    expand("""
      @available(macOS, deprecated: 10.0)
      @Deserializable
      struct S {
        var x: Int
        @available(macOS, deprecated: 10.0) init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      @available(macOS, deprecated: 10.0)
      struct S {
        var x: Int
        @available(macOS, deprecated: 10.0) init(x: Int) {
          self.x = x
        }
      }

      @available(macOS, deprecated: 10.0)
      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a platform-mismatched deprecated init is diagnosed`() {
    // The type is `@available(iOS, deprecated: 13.0)` but the init is
    // `@available(macOS, deprecated: 10.0)` — deprecations on DIFFERENT
    // platforms. On a macOS build the extension is NOT macOS-deprecated, so the
    // `Self(x: …)` call to the macOS-deprecated init WARNS there — the
    // deprecation is not covered on its platform. The `.initializer` diagnostic
    // fires rather than the macro emitting warning-tripping code. (A single
    // global boolean — "the type is deprecated somewhere" — would wrongly accept
    // it and leave the macOS warning; the per-platform model rejects it.)
    assertMacroExpansion("""
      @available(iOS, deprecated: 13.0)
      @Deserializable
      struct S {
        var x: Int
        @available(macOS, deprecated: 10.0) init(x: Int) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      @available(iOS, deprecated: 13.0)
      struct S {
        var x: Int
        @available(macOS, deprecated: 10.0) init(x: Int) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 2, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `a user init with no availability matches and derives`() {
    // The control for the version-restricted rejections: an init carrying no
    // `@available` (nor any other disqualifying attribute) is a plain
    // memberwise-equivalent replacement, so it matches, no diagnostic fires,
    // and the derive proceeds.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a replacement init for mutually-exclusive same #if fields derives`() {
    // Mutually-exclusive `#if` clauses declare the SAME field `x`, so EVERY
    // build's emitted call is `Self(x:)` — one active `x`, never both copies.
    // `init(x: Int)` is the exact replacement in every branch. A flattened
    // field list holds two `x`s and fails the count check, but the per-branch
    // match sees one active `x` per branch and derives; no `.initializer`.
    expand("""
      @Deserializable
      struct S {
        #if true
        var x: Int
        #else
        var x: Int
        #endif
        init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        #if true
        var x: Int
        #else
        var x: Int
        #endif
        init(x: Int) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 0
          #if true
          __macro_local_6fieldsfMu_ += 1
          #else
          __macro_local_6fieldsfMu_ += 1
          #endif
          try deserializer.structure("S", fields: __macro_local_6fieldsfMu_)
          #if true
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #else
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #endif
        }
      }
      """)
  }

  @Test func `a field-less #if guarding only members contributes no branch`() {
    // An `#if` around a helper method, a typealias, or a computed property
    // guards no STORED field, so the serialized field set is identical in every
    // clause. The derive drops such a block entirely rather than mirror it: the
    // emission stays the plain shape over the two real fields, and the block
    // adds no deserialize branch to multiply.
    expand("""
      @Deserializable
      struct S {
        var a: Int
        #if os(Windows)
        func helper() {}
        #endif
        #if DEBUG
        typealias Alias = Int
        #else
        var computed: Int { 0 }
        #endif
        var b: Int
      }
      """,
      to: """
      struct S {
        var a: Int
        #if os(Windows)
        func helper() {}
        #endif
        #if DEBUG
        typealias Alias = Int
        #else
        var computed: Int { 0 }
        #endif
        var b: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(a: deserializer.decode() as Int, b: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `many field-less #if blocks that would exceed the cap still derive`() {
    // Nine two-clause field-less `#if` blocks would be 2^9 = 512 branches —
    // past the 256 cap — WERE they counted. Each guards only a method, so none
    // is a stored field and all are dropped; the branch product stays 1 and the
    // derive proceeds over the single real field rather than diagnosing
    // `.conditional`.
    let blocks = (0 ..< 9).map { index in
      "  #if C\(index)\n  func f\(index)() {}\n  #else\n"
        + "  func g\(index)() {}\n  #endif"
    }.joined(separator: "\n")
    expand("@Deserializable\nstruct S {\n  var x: Int\n\(blocks)\n}",
      to: """
      struct S {
        var x: Int
      \(blocks)
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `a conditional init covering only its active branch derives`() {
    // `init(base:x:)` lives inside the SAME `#if` as its conditional field `x`,
    // so it is compiled only in the build where `x` is too. The per-build
    // analysis pairs them: the active build has fields `[base, x]` and the init
    // covering them, the inactive build has only `base` and NO active init, so
    // the synthesized `init(base:)` applies. Neither build is unsafe, so no
    // `.initializer` diagnostic fires though `x` has no default — the earlier
    // global scan wrongly demanded the conditional init cover the build it is
    // not compiled in.
    expand("""
      @Deserializable
      struct S {
        var base: Int
        #if true
        var x: Int
        init(base: Int, x: Int) {
          self.base = base
          self.x = x
        }
        #endif
      }
      """,
      to: """
      struct S {
        var base: Int
        #if true
        var x: Int
        init(base: Int, x: Int) {
          self.base = base
          self.x = x
        }
        #endif
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 1
          #if true
          __macro_local_6fieldsfMu_ += 1
          #endif
          try deserializer.structure("S", fields: __macro_local_6fieldsfMu_)
          #if true
          let __macro_local_5valuefMu_ = try Self(base: deserializer.decode() as Int, x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #else
          let __macro_local_5valuefMu_ = try Self(base: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #endif
        }
      }
      """)
  }

  @Test func
      `ambiguous same-label inits decode with an explicit field type`() {
    // Both `init(x: Int)` and `init(x: String)` are active, so the bare
    // `Self(x: deserializer.decode())` leaves the generic `decode()` no result
    // type and the `init(x:)` overload set is ambiguous. The derive reads the
    // field with its declared type — `decode() as Int` — so overload resolution
    // picks `init(x: Int)`; no diagnostic fires.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `a single matching init still annotates the decode by type`() {
    // The derive annotates each typed field's read `decode() as <type>` even
    // when one `init(x: Int)` makes the call unambiguous: the annotation is
    // harmless here, and it is what disambiguates an init declared in an
    // extension — invisible to the macro yet live in overload resolution.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `an ambiguous overload set on an inferred-type field is diagnosed`() {
    // The field `x` has no written type (inferred from its initializer), so the
    // ambiguous `init(x:)` overload set cannot be broken by an explicit
    // annotation — there is no type to spell. The ambiguity is unresolvable
    // syntactically, so the `.initializer` diagnostic fires.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x = 0
        init(x: Int) {
          self.x = x
        }
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }
      """,
      expandedSource: """
      struct S {
        var x = 0
        init(x: Int) {
          self.x = x
        }
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `a plain field's decode is annotated so an extension init cannot tie`() {
    // The macro sees only the primary declaration — an `init(x:)` in an
    // EXTENSION is invisible to it, does NOT suppress the synthesized
    // memberwise init, yet still joins overload resolution at the call site. A
    // bare `Self(x: decode())` would leave `decode()` untyped against both the
    // synthesized `init(x: Int)` and an extension `init(x: String)` and fail
    // to compile. Annotating the read `decode() as Int` unconditionally — the
    // plain no-extension struct emits the same — resolves the call regardless.
    expand("""
      @Deserializable
      struct S {
        var x: Int
      }
      """,
      to: """
      struct S {
        var x: Int
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `an overload set ambiguous after typing is diagnosed, not emitted`() {
    // Two primary inits cover the single `x: Int` field by the SAME parameter
    // type, differing only by an extra DEFAULTED parameter, so the typed call
    // `Self(x: decode() as Int)` keeps BOTH viable — the annotation cannot
    // break the tie. Rather than emit an ambiguous call, the `.initializer`
    // diagnostic fires; a set left one viable init after typing derives.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int, y: Int = 0) {
          self.x = x
        }
        init(x: Int, z: Int = 0) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init(x: Int, y: Int = 0) {
          self.x = x
        }
        init(x: Int, z: Int = 0) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `an overload set left with one viable init after typing derives`() {
    // Two primary inits share the `x` LABEL but differ in `x`'s TYPE, so the
    // typed call `Self(x: decode() as Int)` leaves exactly the `init(x: Int)`
    // viable — the `init(x: String)` is dropped by the annotation. One viable
    // init is unambiguous, so the derive emits the annotated call, no error.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        init(x: String) {
          self.x = Int(x) ?? 0
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `an exact init ranks above a defaulted-extra overload and derives`() {
    // Two primary inits stay viable against `Self(x: decode() as Int)`, but
    // `init(x: Int)` corresponds one-to-one to the single field while
    // `init(x: Int, y: Int = 0)` relies on a defaulted EXTRA parameter. Swift
    // ranks the exact memberwise-equivalent init above the defaulted overload,
    // so the call resolves to it unambiguously — a UNIQUE best candidate is not
    // a tie, so the derive emits the call, no `.initializer` diagnostic.
    expand("""
      @Deserializable
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        init(x: Int, y: Int = 0) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
        init(x: Int) {
          self.x = x
        }
        init(x: Int, y: Int = 0) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `the synthesized memberwise init ranks above an extension overload`() {
    // The struct declares no init, so the memberwise `init(x: Int)` is
    // synthesized and invisible in source; an `init(x: Int, y: Int = 0)` in an
    // EXTENSION also joins overload resolution at the call site. The exact
    // synthesized init ranks above the defaulted-extra extension overload, so
    // `Self(x: decode() as Int)` resolves to it and the emitted code compiles.
    // The macro sees no primary init, so it derives with no diagnostic.
    expand("""
      @Deserializable
      struct S {
        var x: Int
      }
      extension S {
        init(x: Int, y: Int = 0) {
          self.x = x
        }
      }
      """,
      to: """
      struct S {
        var x: Int
      }
      extension S {
        init(x: Int, y: Int = 0) {
          self.x = x
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `an overflowing #if block product is diagnosed, not trapped`() {
    // Enough independent two-clause `#if` blocks (each an implicit `#else`
    // doubles the branch count) that the cartesian product overflows `Int`
    // before the `<= 256` comparison. The count SATURATES instead of trapping
    // the plugin, so the `.conditional` diagnostic fires for the oversized
    // shape. Sixty-four blocks alone would be 2^64, past `Int.max`.
    let blocks = (0 ..< 64).map { index in
      "  #if C\(index)\n  var f\(index): Int\n  #endif"
    }.joined(separator: "\n")
    let structure = "struct S {\n\(blocks)\n}"
    assertMacroExpansion("@Deserializable\n\(structure)",
      expandedSource: structure,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.conditional.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `helper-only #if blocks resolve as a single build`() {
    // Twelve `#if` blocks guarding only a method — no stored field, no
    // initializer — beside two real fields. The blocks are dropped from the
    // emitted segments AND pruned from the init-resolution enumeration, so the
    // derive stays ONE build rather than expanding a 2^12 cartesian (which
    // would hit the `.conditional` cap or hang). It derives the plain
    // unconditional shape over `first`/`second`, no diagnostic.
    let blocks = (0 ..< 12).map { index in
      "  #if true\n  func helper\(index)() {}\n  #endif"
    }.joined(separator: "\n")
    let source = """
      @Deserializable
      struct S {
        var first: Int
        var second: Int
      \(blocks)
      }
      """
    expand(source, to: """
      struct S {
        var first: Int
        var second: Int
      \(blocks)
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(first: deserializer.decode() as Int, second: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `an empty struct deserializes with a try-free Self()`() {
    // A struct with no stored property decodes nothing, so its `Self()` calls
    // the nonthrowing no-argument memberwise init. Emitting `try Self()` would
    // warn "no calls to throwing functions occur" and fail the warning-free
    // build, so the `try` is dropped for the fieldless call.
    expand("""
      @Deserializable
      struct Empty {}
      """,
      to: """
      struct Empty {}

      extension Empty: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Empty", fields: 0)
          let __macro_local_5valuefMu_ = Self()
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `an empty synthesized #else branch is a try-free Self()`() {
    // A conditional-only field set: `payload` lives under `#if false`, so the
    // synthesized `#else` branch — the case no clause is active — decodes no
    // field. That empty leaf emits `Self()` without `try`, warning-free, while
    // the `#if` branch with the field keeps the hoisted `try Self(…)`.
    expand("""
      @Deserializable
      struct S {
        #if false
        var payload: Int
        #endif
      }
      """,
      to: """
      struct S {
        #if false
        var payload: Int
        #endif
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 0
          #if false
          __macro_local_6fieldsfMu_ += 1
          #endif
          try deserializer.structure("S", fields: __macro_local_6fieldsfMu_)
          #if false
          let __macro_local_5valuefMu_ = try Self(payload: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
          #else
          let __macro_local_5valuefMu_ = Self()
          try deserializer.end()
          return __macro_local_5valuefMu_
          #endif
        }
      }
      """)
  }

  @Test func `a serialize-only over-cap struct derives without the cap`() {
    // Nine independent `#if` stored fields — a deserialize branch product of
    // 2^9 = 512, past the 256 cap. Serialize emits only a LINEAR count
    // accumulator and `#if`-guarded writes, not the cartesian `Self(…)` the cap
    // guards, so `@Serializable` derives regardless of the product. (The SAME
    // shape under `@Deserializable` diagnoses `.conditional`, above.)
    let fields = (1 ... 9).map { "  #if true\n  var f\($0): Int\n  #endif" }
        .joined(separator: "\n")
    let counts = (1 ... 9).map { _ in
      "    #if true\n    __macro_local_6fieldsfMu_ += 1\n    #endif"
    }.joined(separator: "\n")
    let writes = (1 ... 9).map { index in
      "    #if true\n    try __macro_local_9structurefMu_.field("
        + "\"f\(index)\", self.f\(index))\n    #endif"
    }.joined(separator: "\n")
    expand("@Serializable\nstruct S {\n\(fields)\n}", to: """
      struct S {
      \(fields)
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 0
      \(counts)
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: __macro_local_6fieldsfMu_)
      \(writes)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `a deprecated type's serialize extension carries its @available`() {
    // The annotated type is `@available(*, deprecated)`, so a BARE
    // `extension S` would reference the deprecated type and warn, failing the
    // warning-free build. The derive copies the attribute onto the extension,
    // spelled AHEAD of `extension`, so the conformance stays warning-free.
    expand("""
      @available(*, deprecated)
      @Serializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @available(*, deprecated)
      struct S {
        var x: Int
      }

      @available(*, deprecated)
      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `a deprecated type's deserialize extension carries its @available`() {
    // The deserialize twin: the `@available(*, deprecated)` leads the
    // `extension`, so the conformance references the deprecated type
    // warning-free.
    expand("""
      @available(*, deprecated)
      @Deserializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @available(*, deprecated)
      struct S {
        var x: Int
      }

      @available(*, deprecated)
      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 1)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func
      `an unavailable type's extension carries its @available`() {
    // An `@available(*, unavailable)` type makes a bare `extension S` a hard
    // ERROR, not just a warning. Copying the attribute onto the extension is
    // what lets an unavailable type derive at all.
    expand("""
      @available(*, unavailable)
      @Serializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @available(*, unavailable)
      struct S {
        var x: Int
      }

      @available(*, unavailable)
      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a platform @available is copied onto the extension verbatim`() {
    // A plain platform gate copies through unchanged — the same arguments, in
    // the same order — so the extension is available exactly where the type is.
    expand("""
      @available(macOS 10.0, *)
      @Serializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @available(macOS 10.0, *)
      struct S {
        var x: Int
      }

      @available(macOS 10.0, *)
      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `several @available attributes all copy onto the extension`() {
    // A type may carry one `@available` per platform; the derive copies EVERY
    // one, in source order, each on its own line ahead of `extension`.
    expand("""
      @available(macOS 10.0, *)
      @available(iOS 13.0, *)
      @Serializable
      struct S {
        var x: Int
      }
      """,
      to: """
      @available(macOS 10.0, *)
      @available(iOS 13.0, *)
      struct S {
        var x: Int
      }

      @available(macOS 10.0, *)
      @available(iOS 13.0, *)
      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `a non-@available type attribute is not copied onto the extension`() {
    // Only `@available` propagates: a `@dynamicMemberLookup` (or any other
    // non-availability attribute) on the type is irrelevant to the conformance
    // extension and must NOT be copied — the bare extension stays unchanged.
    expand("""
      @dynamicMemberLookup
      @Serializable
      struct S {
        var x: Int
        subscript(dynamicMember member: String) -> Int { 0 }
      }
      """,
      to: """
      @dynamicMemberLookup
      struct S {
        var x: Int
        subscript(dynamicMember member: String) -> Int { 0 }
      }

      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a generic type derives a conditional conformance`() {
    // `serializer.field(…, self.value)` needs `T: Serializable` and
    // `deserializer.decode()` needs `T: Deserializable`, so an UNCONDITIONAL
    // conformance would not type-check. The derive constrains the generic
    // parameter a serialized field references: a `where` clause per side.
    expand("""
      @Serializable @Deserializable
      struct Box<T> {
        var value: T
      }
      """,
      to: """
      struct Box<T> {
        var value: T
      }

      extension Box: Decant.Serializable where T: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }

      extension Box: Decant.Deserializable where T: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Box", fields: 1)
          let __macro_local_5valuefMu_ = try Self(value: deserializer.decode() as T)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `each generic parameter in a field type is constrained`() {
    // Two parameters, each read by a field, are each constrained.
    expand("""
      @Serializable
      struct Pair<A, B> {
        var a: A
        var b: B
      }
      """,
      to: """
      struct Pair<A, B> {
        var a: A
        var b: B
      }

      extension Pair: Decant.Serializable where A: Decant.Serializable, B: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Pair", fields: 2)
          try __macro_local_9structurefMu_.field("a", self.a)
          try __macro_local_9structurefMu_.field("b", self.b)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a container field lowers to its element parameter`() {
    // The derive lowers the FIELD's container type `Array<T>` to the generic
    // PARAMETER it drives — `where T: Serializable`, which is exactly when
    // `Array<T>: Serializable` holds. An applied-type left side
    // (`where Array<T>: …`) is ILLEGAL Swift — the left side must be a generic
    // parameter or dependent-member type — so the parameter lowering is both
    // legal and precise.
    expand("""
      @Serializable
      struct Wrap<T> {
        var items: Array<T>
      }
      """,
      to: """
      struct Wrap<T> {
        var items: Array<T>
      }

      extension Wrap: Decant.Serializable where T: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Wrap", fields: 1)
          try __macro_local_9structurefMu_.field("items", self.items)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a phantom generic parameter is not constrained`() {
    // No serialized field's type references `T`, so it gets no constraint and
    // the conformance stays unconditional.
    expand("""
      @Serializable
      struct Phantom<T> {
        var x: Int
      }
      """,
      to: """
      struct Phantom<T> {
        var x: Int
      }

      extension Phantom: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Phantom", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a wrapper field constrains its mentioned parameter`() {
    // A field whose type wraps `T` in a general (non-container) type cannot
    // legally constrain the WRITTEN type — `where Wrapper<T>: Serializable` has
    // an applied-type left side Swift's grammar REJECTS — so the derive falls
    // back to the parameter the type mentions: `where T: Serializable`. The
    // exotic "conforms for EVERY T" wrapper is inexpressible as a where-clause,
    // so the mentioned-parameter constraint is the correct legal fallback.
    expand("""
      @Serializable @Deserializable
      struct Holder<T> {
        var value: Wrapper<T>
      }
      """,
      to: """
      struct Holder<T> {
        var value: Wrapper<T>
      }

      extension Holder: Decant.Serializable where T: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Holder", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }

      extension Holder: Decant.Deserializable where T: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Holder", fields: 1)
          let __macro_local_5valuefMu_ = try Self(value: deserializer.decode() as Wrapper<T>)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `a dependent-member field constrains the member directly`() {
    // A `T.Element` field needs `T.Element` ITSELF to conform — the body
    // passes a `T.Element` to `field(…)` and decodes one — so the derive
    // constrains the dependent member DIRECTLY, `where T.Element: …`, NOT the
    // base `T`. A dependent member is a LEGAL where-clause left side (unlike an
    // applied `Wrapper<T>`), and constraining the base `T` would neither supply
    // the member's conformance nor permit a container whose element alone
    // conforms.
    expand("""
      @Serializable @Deserializable
      struct Box<T> {
        var value: T.Element
      }
      """,
      to: """
      struct Box<T> {
        var value: T.Element
      }

      extension Box: Decant.Serializable where T.Element: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }

      extension Box: Decant.Deserializable where T.Element: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Box", fields: 1)
          let __macro_local_5valuefMu_ = try Self(value: deserializer.decode() as T.Element)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """)
  }

  @Test func `a dictionary field lowers to both element parameters`() {
    // A `Dictionary<K, V>` field lowers to BOTH element parameters —
    // `where K: Serializable, V: Serializable`, in the type's declared
    // parameter order — the exact condition under which the dictionary
    // conforms. An applied-type left side is illegal, so both parameters are
    // constrained instead.
    expand("""
      @Serializable
      struct Map<K, V> {
        var pairs: Dictionary<K, V>
      }
      """,
      to: """
      struct Map<K, V> {
        var pairs: Dictionary<K, V>
      }

      extension Map: Decant.Serializable where K: Decant.Serializable, V: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Map", fields: 1)
          try __macro_local_9structurefMu_.field("pairs", self.pairs)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a nested container field lowers to the innermost parameter`() {
    // Nesting recurses: `Array<Optional<T>>` mentions only `T`, so the derive
    // lowers to `where T: Serializable` — no applied-type left side at any
    // depth.
    expand("""
      @Serializable
      struct Nest<T> {
        var items: Array<Optional<T>>
      }
      """,
      to: """
      struct Nest<T> {
        var items: Array<Optional<T>>
      }

      extension Nest: Decant.Serializable where T: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Nest", fields: 1)
          try __macro_local_9structurefMu_.field("items", self.items)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a generic type composes @available with the where clause`() {
    // An availability-limited generic type gets BOTH the copied `@available`
    // attribute and the conditional-conformance `where` clause.
    expand("""
      @available(macOS 10.0, *)
      @Serializable
      struct Box<T> {
        var value: T
      }
      """,
      to: """
      @available(macOS 10.0, *)
      struct Box<T> {
        var value: T
      }

      @available(macOS 10.0, *)
      extension Box: Decant.Serializable where T: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `an inferred generic-dependent field is diagnosed`() {
    // A stored property that infers its type from an initializer mentioning a
    // generic parameter (`var value = T.defaultValue`) has no WRITTEN type for
    // the conditional conformance to constrain, yet the generated body needs
    // `T: Serializable`/`Deserializable`. Deriving the constraint from the
    // initializer expression is unreliable (the syntactic macro cannot resolve
    // `T.defaultValue`'s type), so the derive diagnoses the shape — a clear
    // guide to annotate — rather than emit an unconstrained conformance the
    // compiler later rejects. An explicit annotation (`var value: T = …`)
    // carries its own constraint and derives.
    assertMacroExpansion("""
      @Serializable
      @Deserializable
      struct Box<T: Defaulted> {
        var value = T.defaultValue
      }
      """,
      expandedSource: """
      struct Box<T: Defaulted> {
        var value = T.defaultValue
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.inferred.message,
                       line: 1, column: 1),
        DiagnosticSpec(message: DecantDiagnostic.inferred.message,
                       line: 2, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `an inferred concrete field in a generic type derives`() {
    // The `.inferred` guard fires only when the initializer mentions a generic
    // parameter. A concrete inferred field (`var count = 0`) in a generic type
    // is fully typed and derives an unconditional conformance.
    expand("""
      @Serializable
      struct Counter<T> {
        var count = 0
      }
      """,
      to: """
      struct Counter<T> {
        var count = 0
      }

      extension Counter: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Counter", fields: 1)
          try __macro_local_9structurefMu_.field("count", self.count)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `an inferred qualified-symbol field in a generic type derives`() {
    // The inferred-initializer scan walks the expression STRUCTURALLY, so a
    // field initialised from a concrete qualified symbol whose member name
    // equals the generic parameter (`var value = Namespace.T()`) does NOT
    // surface `T`: the `.T` member of `Namespace` is a concrete symbol, not a
    // reference to the parameter. No `.inferred` diagnostic fires and the
    // conformance is unconditional. A flat token scan would count the `.T`
    // token and wrongly diagnose.
    expand("""
      @Serializable
      struct Holder<T> {
        var value = Namespace.T()
      }
      """,
      to: """
      struct Holder<T> {
        var value = Namespace.T()
      }

      extension Holder: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Holder", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `an inferred generic-dependent field under #if is diagnosed`() {
    // The `.inferred` guard descends through `#if`, like the field walk: a
    // generic-dependent inferred field guarded by a conditional
    // (`#if DEBUG var value = T.defaultValue #endif`) has no written type to
    // constrain, so the active branch's conformance would be unconditional and
    // its `T` reconstruction unchecked. A top-level-only scan would miss it, so
    // the recursion catches it — diagnosed `.inferred`, exactly as the
    // top-level shape is.
    assertMacroExpansion("""
      @Serializable
      @Deserializable
      struct Box<T: Defaulted> {
        #if DEBUG
        var value = T.defaultValue
        #endif
      }
      """,
      expandedSource: """
      struct Box<T: Defaulted> {
        #if DEBUG
        var value = T.defaultValue
        #endif
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.inferred.message,
                       line: 1, column: 1),
        DiagnosticSpec(message: DecantDiagnostic.inferred.message,
                       line: 2, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `an inferred concrete field under #if in a generic type derives`() {
    // The recursion fires only for a generic-parameter mention: a CONCRETE
    // inferred field inside `#if` (`#if DEBUG var n = 0 #endif`) is fully typed
    // and derives its (guarded) conformance, just like a top-level concrete
    // inferred field.
    expand("""
      @Serializable
      struct Counter<T> {
        #if DEBUG
        var n = 0
        #endif
      }
      """,
      to: """
      struct Counter<T> {
        #if DEBUG
        var n = 0
        #endif
      }

      extension Counter: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_6fieldsfMu_ = 0
          #if DEBUG
          __macro_local_6fieldsfMu_ += 1
          #endif
          var __macro_local_9structurefMu_ = (consume serializer).structure("Counter", fields: __macro_local_6fieldsfMu_)
          #if DEBUG
          try __macro_local_9structurefMu_.field("n", self.n)
          #endif
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a generic Optional field under actor isolation derives`() {
    // `Optional<Int>` is Sendable exactly as the sugar `Int?` is, so a
    // `@MainActor`-isolated model spelling the generic form must be recognized
    // safe and derive a nonisolated witness — not fall through to `.isolation`.
    expand("""
      @MainActor
      @Serializable
      struct S {
        var x: Optional<Int>
      }
      """,
      to: """
      @MainActor
      struct S {
        var x: Optional<Int>
      }

      extension S: Decant.Serializable {
        nonisolated public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a generic Array field under actor isolation derives`() {
    // `Array<Int>` is Sendable exactly as the sugar `[Int]` is, so the generic
    // spelling must be recognized safe under a global actor too.
    expand("""
      @MainActor
      @Serializable
      struct S {
        var xs: Array<Int>
      }
      """,
      to: """
      @MainActor
      struct S {
        var xs: Array<Int>
      }

      extension S: Decant.Serializable {
        nonisolated public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("xs", self.xs)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `deserialize is diagnosed for an uninferable generic init`() {
    // A custom init whose generic parameter is reachable ONLY through a SKIPPED
    // defaulted parameter — `init<U>(x: Int, y: U? = nil)` — suppresses the
    // memberwise init, but the emitted `Self(x: … as Int)` passes nothing that
    // fixes `U`, so `U` is unbound and the call would not type-check. The
    // candidate is rejected (its generic parameter is not inferable from the
    // passed fields), so the `.initializer` diagnostic fires rather than an
    // uncompilable expansion.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        init<U>(x: Int, y: U? = nil) {
          self.x = x
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        init<U>(x: Int, y: U? = nil) {
          self.x = x
        }
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: DecantDiagnostic.initializer.message,
                       line: 1, column: 1),
      ],
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func `deserialize derives for an inferable generic init`() {
    // The parity: a custom init whose generic parameter IS inferable from a
    // PASSED field is a callable replacement and the derive uses it. Here `y`'s
    // generic `U` is fixed by the passed `y` argument (`U == Int`), so `U` is
    // bound at the call and the init covers — unlike the uninferable case where
    // the generic reaches only a skipped defaulted parameter. No `.initializer`
    // diagnostic; each read is annotated from its field's written type.
    assertMacroExpansion("""
      @Deserializable
      struct S {
        var x: Int
        var y: Int
        init<U>(x: Int, y: U) where U == Int {
          self.x = x
          self.y = y
        }
      }
      """,
      expandedSource: """
      struct S {
        var x: Int
        var y: Int
        init<U>(x: Int, y: U) where U == Int {
          self.x = x
          self.y = y
        }
      }

      extension S: Decant.Deserializable {
        public static func deserialize<__macro_local_12DeserializerfMu_>(from deserializer: inout __macro_local_12DeserializerfMu_)
            throws(__macro_local_12DeserializerfMu_.Failure) -> Self
            where __macro_local_12DeserializerfMu_: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = try Self(x: deserializer.decode() as Int, y: deserializer.decode() as Int)
          try deserializer.end()
          return __macro_local_5valuefMu_
        }
      }
      """,
      macroSpecs: macros,
      failureHandler: { failure in Issue.record("\(failure.message)") })
  }

  @Test func
      `Serializable on a deprecated field under a deprecated type derives`() {
    // The field is `@available(*, deprecated)`, but so is the TYPE, so the
    // generated extension copies `@available(*, deprecated)` and the serialize
    // `self.x` read sits inside a deprecated context where Swift suppresses the
    // deprecation warning. The field's deprecation is COVERED by the type's, so
    // the serialize side derives (no `.deprecated` diagnostic) rather than
    // rejecting — mirroring the deprecated-init coverage by KIND. The
    // NON-deprecated-type shape (a plain `@Serializable struct` with a
    // deprecated field) still diagnoses, above.
    expand("""
      @available(*, deprecated)
      @Serializable
      struct S {
        @available(*, deprecated) var x: Int
      }
      """,
      to: """
      @available(*, deprecated)
      struct S {
        @available(*, deprecated) var x: Int
      }

      @available(*, deprecated)
      extension S: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 1)
          try __macro_local_9structurefMu_.field("x", self.x)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func `a same-scope alias field constrains the hidden parameter`() {
    // The field is written through a same-scope `typealias Value = T`, so the
    // written type is only `Value` — no in-scope parameter — and a naive walk
    // would emit an UNCONDITIONAL conformance that serializes an unconstrained
    // `T`. The derive EXPANDS the alias to `T` before the constraint walk and
    // emits the CONDITIONAL `where T: Decant.Serializable`, just as a bare
    // `var value: T` field would.
    expand("""
      @Serializable
      struct Box<T> {
        typealias Value = T
        var value: Value
      }
      """,
      to: """
      struct Box<T> {
        typealias Value = T
        var value: Value
      }

      extension Box: Decant.Serializable where T: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }

  @Test func
      `a same-scope alias to a wrapped dependent member constrains it`() {
    // The alias `Values = Array<T.Element>` hides a WRAPPED dependent member.
    // Expansion composes with the wrapped-dependent walk: `Values` expands to
    // `Array<T.Element>`, whose array wrapper descends to the dependent member
    // `T.Element`, so the derive emits `where T.Element: Decant.Serializable` —
    // not the base `T`, which would wrongly demand the whole sequence conform.
    expand("""
      @Serializable
      struct Box<T: Sequence> {
        typealias Values = Array<T.Element>
        var values: Values
      }
      """,
      to: """
      struct Box<T: Sequence> {
        typealias Values = Array<T.Element>
        var values: Values
      }

      extension Box: Decant.Serializable where T.Element: Decant.Serializable {
        public func serialize<__macro_local_10SerializerfMu_>(into serializer: consuming __macro_local_10SerializerfMu_)
            throws(__macro_local_10SerializerfMu_.Failure) -> __macro_local_10SerializerfMu_
            where __macro_local_10SerializerfMu_: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("values", self.values)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }
}
