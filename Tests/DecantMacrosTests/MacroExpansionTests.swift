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
          var structure = (consume serializer).structure("Point", fields: 3)
          try structure.field("x", x)
          try structure.field("y", y)
          try structure.field("label", label)
          return try structure.end()
        }
      }
      """)
  }

  @Test func `Deserializable reads each property annotated by its type`() {
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
          let x: Int32 = try deserializer.decode()
          let y: Int32 = try deserializer.decode()
          let label: String = try deserializer.decode()
          try deserializer.end()
          return Point(x: x, y: y, label: label)
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
          var structure = (consume serializer).structure("Box", fields: 1)
          try structure.field("value", value)
          return try structure.end()
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
}
