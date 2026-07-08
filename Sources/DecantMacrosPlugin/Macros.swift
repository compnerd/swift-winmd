// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import SwiftSyntax
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

  internal var message: String {
    switch self {
    case .nonstruct:
      "@Serializable / @Deserializable can only be applied to a struct"
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
/// A stored property is a `var`/`let` binding with a type annotation and no
/// accessor block (a computed property has one and is skipped). Several
/// bindings on one `let a, b: Int` line expand to one entry each.
internal enum DecantModel {
  /// One stored property's name and its written type, if annotated. The type is
  /// the spelling as written (the macro is syntactic and cannot resolve it); it
  /// annotates the generated read so inference does not depend on the
  /// initializer's argument labels.
  internal struct Field {
    internal let name: String
    internal let type: String?
  }

  /// Extracts the stored properties of `declaration` in declaration order, or
  /// raises `.nonstruct` if it is not a struct.
  internal static func fields(of declaration: some DeclGroupSyntax,
                              in context: some MacroExpansionContext,
                              at node: AttributeSyntax) -> Array<Field>? {
    guard declaration.is(StructDeclSyntax.self) else {
      context.diagnose(Diagnostic(node: node,
                                  message: DecantDiagnostic.nonstruct))
      return nil
    }

    var fields = Array<Field>()
    for member in declaration.memberBlock.members {
      guard let binding = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      for pattern in binding.bindings {
        guard pattern.accessorBlock == nil,
              let identifier =
                  pattern.pattern.as(IdentifierPatternSyntax.self) else {
          continue
        }
        let type = pattern.typeAnnotation?.type.trimmedDescription
        fields.append(Field(name: identifier.identifier.text, type: type))
      }
    }
    return fields
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
    guard let fields =
        DecantModel.fields(of: declaration, in: context, at: node) else {
      return []
    }

    let name = trimmed(type)
    let writes = fields.map {
      "    try structure.field(\"\($0.name)\", \($0.name))"
    }.joined(separator: "\n")

    let body = """
    extension \(name): Decant.Serializable {
      public func serialize<S>(into serializer: consuming S)
          throws(S.Failure) -> S
          where S: Decant.Serializer & ~Copyable & ~Escapable {
        var structure = (consume serializer).structure(\
    "\(name)", fields: \(fields.count))
    \(writes)
        return try structure.end()
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
    guard let fields =
        DecantModel.fields(of: declaration, in: context, at: node) else {
      return []
    }

    let name = trimmed(type)
    let reads = fields.map { field in
      let annotation = field.type.map { ": \($0)" } ?? ""
      return "    let \(field.name)\(annotation) = try deserializer.decode()"
    }.joined(separator: "\n")
    let arguments = fields.map {
      "\($0.name): \($0.name)"
    }.joined(separator: ", ")

    let body = """
    extension \(name): Decant.Deserializable {
      public static func deserialize<D>(from deserializer: inout D)
          throws(D.Failure) -> Self
          where D: Decant.Deserializer & ~Copyable & ~Escapable {
        try deserializer.structure("\(name)", fields: \(fields.count))
    \(reads)
        try deserializer.end()
        return \(name)(\(arguments))
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
                               providingPeersOf declaration: some DeclSyntaxProtocol,
                               in context: some MacroExpansionContext)
      throws -> Array<DeclSyntax> {
    []
  }
}

/// The `@DecantSkip` marker — a peer macro that expands to nothing, as above.
public struct DecantSkipMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingPeersOf declaration: some DeclSyntaxProtocol,
                               in context: some MacroExpansionContext)
      throws -> Array<DeclSyntax> {
    []
  }
}

/// The bare type name for a `providingExtensionsOf` argument, stripped of
/// whitespace, so it reads cleanly in the generated `extension` header.
internal func trimmed(_ type: some TypeSyntaxProtocol) -> String {
  type.trimmedDescription
}
