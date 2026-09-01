// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import SwiftSyntax
internal import SwiftParser

/// The lexical surface a rendered body exposes to `nest`: the top-level type
/// names it declares, and the primary declaration's boundaries so a container's
/// nested child splices in while its file-scope header and footer bubble out.
/// Both read off the Swift syntax tree `SwiftParser` produces rather than a
/// character scan, so a comment, a string literal, and a nested declaration are
/// excluded by the grammar rather than by hand-tracked lexer state. Which types
/// a signature *references* is not read here — the metadata resolution records
/// that directly, so the closure never re-derives it from the rendered text.
internal enum Surface {
  /// The top-level type names `body` declares as code — the `name` of every
  /// `struct`/`class`/`enum`/`protocol`/`actor` and the `name` of every
  /// `typealias` at the root of the source file. A top-level
  /// conditional-compilation block (`#if os(Windows) … #endif`) is descended
  /// into — the render is platform-agnostic, so a declaration a template guards
  /// behind a `#if` still counts — but a declaration nested inside another
  /// type's member block is a member, not a top-level type.
  static func declarations(in body: String) -> Set<String> {
    var names = Set<String>()
    collect(Parser.parse(source: body).statements, into: &names)
    return names
  }

  private static func collect(_ statements: CodeBlockItemListSyntax,
                              into names: inout Set<String>) {
    for statement in statements {
      guard case let .decl(declaration) = statement.item else { continue }
      if let conditional = declaration.as(IfConfigDeclSyntax.self) {
        for clause in conditional.clauses {
          if case let .statements(inner)? = clause.elements {
            collect(inner, into: &names)
          }
        }
      } else if let name = named(declaration) {
        names.insert(name)
      }
    }
  }

  /// The declared name of a top-level *type* declaration — a `struct`, `class`,
  /// `enum`, `protocol`, `actor`, or `typealias` — or `nil` for any other
  /// declaration (a `func`/`var`/`import` is not a type the render nests).
  private static func named(_ declaration: DeclSyntax) -> String? {
    if let s = declaration.as(StructDeclSyntax.self) { return s.name.text }
    if let c = declaration.as(ClassDeclSyntax.self) { return c.name.text }
    if let e = declaration.as(EnumDeclSyntax.self) { return e.name.text }
    if let p = declaration.as(ProtocolDeclSyntax.self) { return p.name.text }
    if let a = declaration.as(ActorDeclSyntax.self) { return a.name.text }
    if let t = declaration.as(TypeAliasDeclSyntax.self) { return t.name.text }
    return nil
  }

  /// The signature position a spelled type occupies — a method or `Invoke`
  /// parameter or return, a stored field, or an inheritance base — the category
  /// the metadata records each spelled reference under.
  enum Category: Hashable {
    case parameter
    case returned
    case base
    case field
  }

  /// Splices the nested-declaration `block` into `body` just before the closing
  /// brace of `body`'s primary declaration — the top-level `struct` or `enum`
  /// named `name` — so a rendered container carries its nested types inside its
  /// own body. The closer is located off the syntax tree rather than a running
  /// brace count, so a `{`/`}` in a comment or a string literal is excluded by
  /// the grammar, a leading helper (`func`/second type) before the container is
  /// skipped, and a brace-delimited footer (`extension`) after it is left
  /// untouched.
  ///
  /// When the closing brace shares its line with the declaration body
  /// (`struct Outer {}`) the line splits so the child nests between the body
  /// and the brace, keeping the brace at the declaration's own indentation;
  /// when the brace is on its own line the child inserts as a whole line before
  /// it. A body with no locatable brace falls back to splicing before its last
  /// non-blank line.
  static func inject(_ block: String, into body: String,
                     container name: String) -> String {
    var lines = lines(body)
    while let last = lines.last, last.allSatisfy(\.isWhitespace) {
      lines.removeLast()
    }
    guard !lines.isEmpty else { return body }
    // The line and character index of the container's closing brace — the
    // splice point. `column` stays `-1` until located, so an unlocatable
    // container falls back to inserting before the trimmed body's last line.
    var closer = lines.count - 1
    var column = -1
    if let primary = primary(name, in: Parser.parse(source: body)),
        let spot = locate(primary.close, in: body) {
      closer = spot.line
      column = spot.column
    }
    let characters = Array(lines[closer])
    let prefix = String(characters[0 ..< max(column, 0)])
    if column >= 0, !prefix.allSatisfy(\.isWhitespace) {
      // The closing brace shares its line with the declaration body: split the
      // line so the child nests between the body and the brace, keeping the
      // brace at the declaration's own indentation.
      let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
      let suffix = String(characters[column...])
      lines[closer] = prefix + "\n" + block + "\n" + indent + suffix
    } else {
      // A brace-only closing line (or no located brace): insert the child as a
      // whole line before it.
      lines.insert(block, at: closer)
    }
    return lines.joined(separator: "\n")
  }

  /// Splits a value type's rendered `body` into the file-scope content before
  /// its primary declaration, the declaration itself (with its leading
  /// attributes and doc comments and its whole nested body), and the file-scope
  /// content after it. The primary declaration is the top-level `struct` or
  /// `enum` named `name`, located off the syntax tree; its leading run of
  /// attribute (`@`), comment (`//`), and blank lines is kept with it so an
  /// `@frozen` or doc comment is not stranded at file scope, and a trailing
  /// comment or blank on its own lines stays with it too — the footer begins at
  /// the first code line past its close. A body with no locatable
  /// `struct`/`enum` named `name` is treated as all declaration.
  static func partition(_ body: String, named name: String)
      -> (header: String, declaration: String, footer: String) {
    let lines = lines(body)
    guard let primary = primary(name, in: Parser.parse(source: body)),
        let head = locate(primary.leading, in: body),
        let tail = locate(primary.close, in: body) else {
      return ("", body, "")
    }
    // Keep the declaration's leading doc comments and blank lines with it — its
    // attribute list is already covered, the leading token being the first
    // attribute — so a `///` above the type, a block `/** … */`, or a multiline
    // `@available(…)` is not stranded at file scope apart from its declaration.
    // A block comment is absorbed by scanning backward from its closing `*/`
    // line to its opening `/*`, since its lines carry no `//`.
    var start = head.line
    var block = false
    while start > 0 {
      // Trim both ends, a trailing `\r` included — a CRLF `-I` override's split
      // lines keep the `\r`, so a block-doc closer reads `*/\r` and would fail
      // the `*/` recognition, stranding the comment in the file-scope header.
      let text = String(lines[start - 1].drop { $0 == " " || $0 == "\t" }
                            .reversed().drop { $0.isWhitespace }.reversed())
      if block {
        start -= 1
        if text.hasPrefix("/*") { block = false }
        continue
      }
      if text.isEmpty || text.hasPrefix("//") { start -= 1; continue }
      if text.hasSuffix("*/") {
        start -= 1
        if !text.hasPrefix("/*") { block = true }
        continue
      }
      break
    }
    let header = lines[0 ..< start].joined(separator: "\n")
    // The footer is the file-scope content after the declaration. When code
    // follows the closing brace on its *own* line (`struct Foo {}; extension
    // Foo {}`), it splits at the brace's source column so the trailing
    // `extension` lands in the footer, not the declaration — a nesting caller
    // would otherwise indent it into the enclosing type, where a nested
    // `extension` is invalid. Otherwise the footer begins at the first code
    // line past the close; a trailing comment (`// end Foo`) or blank on the
    // type's own lines stays with it.
    let closer = Array(lines[tail.line])
    let column = min(tail.column, closer.count - 1)
    let suffix = column + 1 < closer.count
        ? String(closer[(column + 1)...]) : ""
    let trailing = suffix.drop { $0 == " " || $0 == "\t" }
    if !trailing.isEmpty, !trailing.hasPrefix("//") {
      let declaration = (lines[start ..< tail.line]
          + [String(closer[...column])]).joined(separator: "\n")
      let footer = tail.line + 1 < lines.count
          ? ([suffix] + Array(lines[(tail.line + 1)...]))
              .joined(separator: "\n")
          : suffix
      return (header, declaration, footer)
    }
    // A trailing comment or blank on the primary's own lines stays with the
    // declaration only when nothing follows it. A comment run that reaches the
    // end of the body trails the primary (`struct Foo {}` then `// end Foo`),
    // but a comment above a *following* declaration (`struct Foo {}` then
    // `/// Bar` then `struct Bar {}`) is that declaration's leading
    // documentation and belongs to the footer, not folded into `Foo`.
    var end = tail.line + 1
    var scan = end
    while scan < lines.count {
      let content = lines[scan].drop { $0 == " " || $0 == "\t" }
      guard content.isEmpty || content.hasPrefix("//") else { break }
      scan += 1
    }
    if scan == lines.count { end = scan }
    let declaration = lines[start ..< end].joined(separator: "\n")
    let footer = end < lines.count
        ? lines[end...].joined(separator: "\n") : ""
    return (header, declaration, footer)
  }

  /// The declaration's leading token — its first attribute, modifier, or
  /// keyword — and closing member brace of the top-level type named `name`, or
  /// `nil` when the tree declares no such type at file scope. Any named
  /// member-bearing declaration is a candidate — a `struct` or `enum` value
  /// type, and a `protocol` (or `class`/`actor`) the nesting now permits as a
  /// child — matched by conforming to both `NamedDeclSyntax` (its `name`) and
  /// `DeclGroupSyntax` (its `memberBlock`); an `extension`, being unnamed, is
  /// excluded, so a trailing `extension` footer is not read as the primary.
  /// A leading helper declaration is likewise not it. A keyword-escaped
  /// name matches its bare spelling. The leading token, not the name, marks the
  /// declaration's start, so its whole attribute list — however many lines an
  /// `@available(…)` spans — stays with the type rather than stranding in the
  /// file-scope header.
  private static func primary(_ name: String, in tree: SourceFileSyntax)
      -> (leading: TokenSyntax, close: TokenSyntax)? {
    primary(name, among: tree.statements)
  }

  private static func primary(_ name: String,
                              among statements: CodeBlockItemListSyntax)
      -> (leading: TokenSyntax, close: TokenSyntax)? {
    func bare(_ text: Substring) -> Substring {
      var trimmed = text
      if trimmed.hasPrefix("`") { trimmed = trimmed.dropFirst() }
      if trimmed.hasSuffix("`") { trimmed = trimmed.dropLast() }
      return trimmed
    }
    let sourced = SyntaxTreeViewMode.sourceAccurate
    let wanted = bare(name[...])
    for statement in statements {
      guard case let .decl(declaration) = statement.item else { continue }
      // A top-level `#if os(Windows) … #endif` guarding the primary: descend
      // each clause so a conditionally-compiled declaration is still located.
      if let conditional = declaration.as(IfConfigDeclSyntax.self) {
        for clause in conditional.clauses {
          if case let .statements(inner)? = clause.elements,
              let found = primary(name, among: inner) {
            return found
          }
        }
        continue
      }
      guard let group = declaration.asProtocol(DeclGroupSyntax.self),
          let type = declaration.asProtocol(NamedDeclSyntax.self),
          bare(type.name.text[...]) == wanted else { continue }
      // A malformed body (`struct Foo {` with no close) yields a *missing*
      // `rightBrace` token the parser synthesizes at EOF; returning it would
      // trap the line-indexing splice and slice, so treat the declaration as
      // unlocatable and take the whole-body fallback instead.
      let close = group.memberBlock.rightBrace
      guard close.presence == .present else { return nil }
      return (declaration.firstToken(viewMode: sourced) ?? type.name, close)
    }
    return nil
  }

  /// The zero-based line and character-column of `token`'s first code character
  /// within `body` — the syntax-tree position mapped back to an index into the
  /// original source, so a splice or slice preserves the body's exact bytes.
  /// The column counts `Character`s, matching a `\n`-split line's own indices.
  private static func locate(_ token: TokenSyntax, in body: String)
      -> (line: Int, column: Int)? {
    // Count Unicode *scalars*, breaking a line on the `\n` scalar, so a CRLF
    // (`\r\n`) — a single `Character` grapheme a `Character` scan would neither
    // split nor recognize — advances the line, its `\r` a trailing column of
    // the line just ended. This matches `lines(_:)`, which splits on the same
    // scalar and keeps the `\r`, so a column indexes the same position in both.
    let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
    var line = 0
    var column = 0
    var utf8 = 0
    for scalar in body.unicodeScalars {
      if utf8 == offset { return (line, column) }
      if scalar == "\n" { line += 1; column = 0 } else { column += 1 }
      utf8 += scalar.utf8.count
    }
    return utf8 == offset ? (line, column) : nil
  }

  /// The lines of `body`, split on the `\n` scalar with the split preserved
  /// (`omittingEmptySubsequences: false`). A CRLF line keeps its trailing `\r`
  /// — the split consumes only the `\n` — so `joined(separator: "\n")` restores
  /// the exact bytes, while `partition`/`inject` trim the `\r` where they
  /// recognize a delimiter. A plain `String.split(separator: "\n")` scans
  /// `Character`s and would not split a CRLF body at all (`\r\n` is one
  /// grapheme), leaving the whole body an unpartitionable single line.
  private static func lines(_ body: String) -> Array<String> {
    body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        .map { String(String.UnicodeScalarView($0)) }
  }
}
