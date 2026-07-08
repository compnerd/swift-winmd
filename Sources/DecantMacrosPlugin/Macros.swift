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
  case lazy
  case constant

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
  /// One stored property's name. That is all a derive needs: the write reads
  /// `self.<name>` and the read passes its `decode` to the memberwise-init
  /// argument labelled `<name>`, whose parameter supplies the type. The macro
  /// is syntactic and never resolves the property's type.
  internal struct Field {
    internal let name: String
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
      guard !typed(binding.modifiers) else { continue }
      // A `lazy var` has a mutating getter, so serialize's nonmutating
      // `self.<name>` read cannot type-check, and it is not a memberwise-init
      // parameter for deserialize to pass. Reject rather than miscompile.
      guard !lazy(binding.modifiers) else {
        context.diagnose(Diagnostic(node: node,
                                    message: DecantDiagnostic.lazy))
        return nil
      }
      let constant = binding.bindingSpecifier.tokenKind == .keyword(.let)
      for pattern in binding.bindings {
        guard !computed(pattern.accessorBlock) else { continue }
        // Swift omits an initialized `let` from the synthesized memberwise
        // init, so deserialize would pass an argument no parameter accepts.
        // An uninitialized `let` and any `var` remain memberwise parameters.
        guard !(constant && pattern.initializer != nil) else {
          context.diagnose(Diagnostic(node: node,
                                      message: DecantDiagnostic.constant))
          return nil
        }
        append(pattern.pattern, to: &fields)
      }
    }
    return fields
  }

  /// Whether `modifiers` mark the declaration `lazy`. A `lazy var` has a
  /// mutating getter and is absent from the synthesized memberwise
  /// initializer, so it is neither serializable nor a memberwise parameter.
  private static func lazy(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
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

  /// Appends the stored properties `pattern` binds to `fields`, in declaration
  /// order.
  ///
  /// An identifier binds one property named for it. A tuple binding — a
  /// `var (x, y): (Int, Int)` line, for which Swift synthesizes `x` and `y`
  /// as separate stored properties — destructures into one property per
  /// element, named for its element pattern. A `_` element binds nothing, so
  /// it contributes no property. Nesting recurses.
  private static func append(_ pattern: PatternSyntax,
                             to fields: inout Array<Field>) {
    if let identifier = pattern.as(IdentifierPatternSyntax.self) {
      fields.append(Field(name: identifier.identifier.text))
    } else if let tuple = pattern.as(TuplePatternSyntax.self) {
      for element in tuple.elements {
        append(element.pattern, to: &fields)
      }
    }
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
    guard let fields =
        DecantModel.fields(of: declaration, in: context, at: node) else {
      return []
    }

    let name = trimmed(type)
    // The sub-serializer local is hygienic so a field named `structure` (or
    // `serializer`) reads through `self`, never this introduced name.
    let structure = context.makeUniqueName("structure").text
    let writes = fields.map {
      "    try \(structure).field(\"\($0.name)\", self.\($0.name))"
    }.joined(separator: "\n")

    let body = """
    extension \(name): Decant.Serializable {
      public func serialize<S>(into serializer: consuming S)
          throws(S.Failure) -> S
          where S: Decant.Serializer & ~Copyable & ~Escapable {
        var \(structure) = (consume serializer).structure(\
    "\(name)", fields: \(fields.count))
    \(writes)
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
    guard let fields =
        DecantModel.fields(of: declaration, in: context, at: node) else {
      return []
    }

    let name = trimmed(type)
    // Each field is read directly in its memberwise-init argument position, so
    // the init parameter supplies `decode`'s contextual result type — the read
    // of a field whose type is inferred from its initializer (`var count = 0`,
    // no written annotation) type-checks with no annotation to lend it. Swift
    // evaluates call arguments left-to-right in source order, so the reads run
    // in declaration order; each `decode` mutation of `deserializer` completes
    // before the next argument, so exclusive access holds. No decoded
    // temporary is introduced, which is also why a field named `deserializer`
    // cannot shadow the `inout` parameter `end` reads through.
    let arguments = fields.map {
      "\($0.name): try deserializer.decode()"
    }.joined(separator: ", ")
    // The reconstructed value binds to a hygienic local so `end` runs after all
    // reads and before the return, without a field named `value` colliding.
    let value = context.makeUniqueName("value").text

    let body = """
    extension \(name): Decant.Deserializable {
      public static func deserialize<D>(from deserializer: inout D)
          throws(D.Failure) -> Self
          where D: Decant.Deserializer & ~Copyable & ~Escapable {
        try deserializer.structure("\(name)", fields: \(fields.count))
        let \(value) = \(name)(\(arguments))
        try deserializer.end()
        return \(value)
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
