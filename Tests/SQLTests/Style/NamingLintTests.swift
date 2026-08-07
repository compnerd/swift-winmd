// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import Testing

// MARK: - Naming convention lint

/// Mechanically enforces the project's naming convention across every
/// `Sources/**/*.swift` file (CodingStyle §7): a function, method, enum case,
/// or variable's base name is a single word or a labelled form
/// (`optimise(view:)`, `strict(on:)`), never a camelCase compound such as
/// `optimiseView`, `firstValue`, or `orderKeys`. Hand review keeps missing the
/// drift (a compound name reads naturally, so the eye skips it), so this check
/// catches it instead: it fails listing every offender with its `file:line`,
/// and stays green only on a tree with no compound method, case, or variable.
///
/// The rule flags a declaration whose base name begins with a lowercase letter
/// (a lowerCamelCase identifier, not a PascalCase ECMA/external accessor — the
/// §7 exception, e.g. a `Metadata.Stream` case, spells its verbatim PascalCase
/// and so is never read as lowercase-first) and runs a lowercase letter
/// straight into an uppercase one (a camelCase seam). A labelled argument is
/// invisible to the rule — only the base name is inspected — so `encode(to:)`,
/// `hash(into:)`, and `strict(on:)` never flag; a fully lowercase name
/// (`typecheck`, `precheck`, `cumulative`) never flags.
///
/// A variable form carries the §7 external-mirror exceptions that would else
/// read as lowercase-first compounds: a `k`-prefixed global (`kRegisteredTables`)
/// and a COM `Cor*` flag constant (`static var tdPublic: CorTypeAttr`, matched
/// by its `Cor…` type), plus the stdlib property names (`rawValue`, `isEmpty`).
@Suite struct NamingLintTests {
  /// Names that are unavoidably lowerCamelCase because Swift itself fixes their
  /// spelling — a standard-library or protocol requirement, or a builder or
  /// callable special form. None is a name the project chose, so none drifts;
  /// each is listed by its exact spelling (not a pattern) to keep the exemption
  /// narrow. Every entry is one that actually occurs in `Sources`.
  private static let allowed: Set<String> = [
    // `@resultBuilder` requirements — the fixture DSL builders in
    // SQLTestSupport (`Catalog { … }`); the result-builder protocol dictates
    // the method names.
    "buildExpression", "buildBlock", "buildArray",
    // `Sequence`/`IteratorProtocol` requirement.
    "makeIterator",
    // Swift call-syntax special form — `value(args)` sugar over a type.
    "callAsFunction",
    // Mirrors `Sequence.forEach`: the each-element terminal on the `~Escapable`
    // query stages, which cannot conform to `Sequence` (a non-escapable type)
    // and so must spell the canonical name by hand rather than rename it.
    "forEach",
    // Standard-library / protocol property names Swift fixes: the
    // `RawRepresentable`/`CustomDebugStringConvertible`/`Hashable` requirements
    // and the universal `isEmpty` collection idiom.
    "rawValue", "debugDescription", "hashValue", "isEmpty",
  ]

  @Test func `no lowerCamelCase compound method, case, or variable names`()
      throws {
    let sources = try Self.sources()
    let offenders = try Self.offenders(under: sources)
    #expect(offenders.isEmpty, """
      \(offenders.count) method, enum-case, or variable name(s) break the \
      single-word / labelled-argument convention (a lowerCamelCase compound \
      like `optimiseView`, `firstValue`, or `orderKeys`). Rename each to a \
      single word or a labelled form:
      \(offenders.map { "  \($0)" }.joined(separator: "\n"))
      """)
  }

  // MARK: - Scanning

  private struct Offender: CustomStringConvertible {
    let name: String
    let file: String
    let line: Int
    var description: String { "\(name) — \(file):\(line)" }
  }

  private enum Failure: Error { case rootNotFound }

  /// The repository `Sources` directory, found by walking up from this source
  /// file (`#filePath`) to the package root — the nearest ancestor holding both
  /// a `Package.swift` and a `Sources` directory. Deriving it needs no absolute
  /// path, so the check moves with the checkout and runs from any worktree.
  private static func sources() throws -> URL {
    let manager = FileManager.default
    var directory =
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
      let package = directory.appendingPathComponent("Package.swift")
      let sources = directory.appendingPathComponent("Sources")
      var directoryFlag: ObjCBool = false
      if manager.fileExists(atPath: package.path),
          manager.fileExists(atPath: sources.path, isDirectory: &directoryFlag),
          directoryFlag.boolValue {
        return sources
      }
      directory = directory.deletingLastPathComponent()
    }
    throw Failure.rootNotFound
  }

  /// Every offending declaration under `sources`, sorted by file then line so
  /// the report reads top-to-bottom.
  private static func offenders(under sources: URL) throws -> Array<Offender> {
    let manager = FileManager.default
    guard let walk = manager.enumerator(at: sources,
                                        includingPropertiesForKeys: nil) else {
      throw Failure.rootNotFound
    }
    let root = sources.deletingLastPathComponent().path + "/"
    var offenders = Array<Offender>()
    for case let url as URL in walk where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      let file = url.path.replacingOccurrences(of: root, with: "")
      offenders.append(contentsOf: violations(in: text, of: file))
    }
    return offenders.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
  }

  private static func violations(in text: String,
                                 of file: String) -> Array<Offender> {
    // Three declaration forms, each anchored to the start of a line. A method:
    // any leading modifier words (`public`, `private`, `mutating`, …) then
    // `func` then the base name. An enum case: an optional `indirect` then
    // `case` then the case name. A variable: leading modifiers then `var`/`let`
    // then the name. Anchoring to declaration position keeps a keyword in prose
    // from matching — a comment line opens with `//`/`///`/`*`, never a modifier
    // word — and each first capture is the optional leading backtick, so a
    // backtick-quoted name is skipped.
    //
    // A switch's `case` never matches the enum-case form: its pattern opens
    // with `.` (an enum-case pattern), `let`/`var` (a binding), or a literal,
    // none a bare word after `case`, so the `(\w+)` capture fails or lands
    // on `let`/`var` (not a compound). Only a genuine enum-case declaration —
    // a bare case name — is read.
    let function = /^\h*(?:\w+\h+)*func\h+(`?)(\w+)/
    let enumeration = /^\h*(?:indirect\h+)?case\h+(`?)(\w+)/
    let variable = /^\h*(?:\w+\h+)*(?:var|let)\h+(`?)(\w+)/
    var offenders = Array<Offender>()
    let lines = stripped(text).split(separator: "\n",
                                     omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      // Drop a trailing line comment; the anchored match already rejects a line
      // that opens with `//`.
      var code = line
      if let comment = code.range(of: "//") {
        code = code[..<comment.lowerBound]
      }
      let declaration = code.firstMatch(of: function)
              ?? code.firstMatch(of: enumeration)
      // A variable is read only when the line is not already a func/case, and
      // it carries two extra §7 exemptions the metadata layer relies on.
      let isVariable = declaration == nil
      guard let match = declaration ?? code.firstMatch(of: variable) else {
        continue
      }
      if !match.1.isEmpty { continue }   // a backtick-quoted raw name is exempt
      let name = String(match.2)
      guard compound(name), !allowed.contains(name) else { continue }
      if isVariable {
        // §7 spares two external-mirror variable forms: a `k`-prefixed global
        // (`kRegisteredTables`), and a COM `Cor*` flag constant — recognised by
        // its `Cor…` type on the same line, as every `CILFlags` mirror is a
        // `static var …: Cor<Attr>`.
        if name.first == "k", name.dropFirst().first?.isUppercase == true {
          continue
        }
        if code.contains(/:\h*Cor[A-Z]/) { continue }
      }
      offenders.append(Offender(name: name, file: file, line: index + 1))
    }
    return offenders
  }

  /// Whether `name` is a lowerCamelCase compound: it begins with a lowercase
  /// letter (a method name, not a PascalCase accessor) and somewhere runs a
  /// lowercase letter straight into an uppercase one (the `optimise`|`View`
  /// seam). A single lowercase word, an all-lowercase-with-digits name, and a
  /// PascalCase name all return `false`.
  private static func compound(_ name: String) -> Bool {
    guard let first = name.first, first.isLowercase else { return false }
    var previous = first
    for character in name.dropFirst() {
      if previous.isLowercase, character.isUppercase { return true }
      previous = character
    }
    return false
  }

  /// `text` with each `/* … */` block comment blanked so a `func` mentioned
  /// inside one is never read as a declaration. The negated class `[^*]` admits
  /// newlines, so a comment spans lines; the spanned newlines are kept, so each
  /// surviving line holds its original number for the report.
  private static func stripped(_ text: String) -> String {
    let blockComment = /\/\*(?:[^*]|\*(?!\/))*\*\//
    return text.replacing(blockComment) { match in
      String(repeating: "\n", count: match.output.filter { $0 == "\n" }.count)
    }
  }
}
