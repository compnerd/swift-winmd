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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Point", fields: 3)
          let __macro_local_5valuefMu_ = Point(x: try deserializer.decode(), y: try deserializer.decode(), label: try deserializer.decode())
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("Box", fields: 1)
          try __macro_local_9structurefMu_.field("value", self.value)
          return try __macro_local_9structurefMu_.end()
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Counter", fields: 3)
          let __macro_local_5valuefMu_ = Counter(a: try deserializer.decode(), n: try deserializer.decode(), b: try deserializer.decode())
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Line", fields: 4)
          let __macro_local_5valuefMu_ = Line(a: try deserializer.decode(), x: try deserializer.decode(), y: try deserializer.decode(), b: try deserializer.decode())
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("Nested", fields: 3)
          let __macro_local_5valuefMu_ = Nested(x: try deserializer.decode(), y: try deserializer.decode(), z: try deserializer.decode())
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = S(x: try deserializer.decode(), y: try deserializer.decode())
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = S(deserializer: try deserializer.decode(), value: try deserializer.decode())
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = S(x: try deserializer.decode(), y: try deserializer.decode())
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
        public static func deserialize<D>(from deserializer: inout D)
            throws(D.Failure) -> Self
            where D: Decant.Deserializer & ~Copyable & ~Escapable {
          try deserializer.structure("S", fields: 2)
          let __macro_local_5valuefMu_ = S(count: try deserializer.decode(), name: try deserializer.decode())
          try deserializer.end()
          return __macro_local_5valuefMu_
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
        public func serialize<S>(into serializer: consuming S)
            throws(S.Failure) -> S
            where S: Decant.Serializer & ~Copyable & ~Escapable {
          var __macro_local_9structurefMu_ = (consume serializer).structure("S", fields: 2)
          try __macro_local_9structurefMu_.field("x", self.x)
          try __macro_local_9structurefMu_.field("y", self.y)
          return try __macro_local_9structurefMu_.end()
        }
      }
      """)
  }
}
