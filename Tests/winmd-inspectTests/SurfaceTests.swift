// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

import Testing

@testable import winmd_inspect

/// `Surface.partition` splits a rendered body into its file-scope header, the
/// primary declaration (with its leading attributes and doc comments and its
/// whole nested body), and the file-scope footer — read off the Swift syntax
/// tree, so a nesting caller folds only the declaration into its container
/// while the header and footer bubble to file scope.
@Suite struct SurfaceTests {
  @Test func `a multiline attribute stays with its declaration`() {
    let body = """
      @available(macOS 14,
                 *)
      public struct Foo {
      }
      """
    let (header, declaration, _) = Surface.partition(body, named: "Foo")
    // The whole attribute lands in the declaration, not the file-scope header.
    #expect(declaration.contains("@available(macOS 14,"))
    #expect(declaration.contains("*)"))
    #expect(!header.contains("@available"))
  }

  @Test func `code after the closing brace on its line splits into the footer`() {
    let body = "public struct Foo {}; extension Foo {}"
    let (_, declaration, footer) = Surface.partition(body, named: "Foo")
    // The trailing `extension` is file-scope, not part of the declaration a
    // nesting caller would indent into the enclosing type.
    #expect(declaration.contains("struct Foo {}"))
    #expect(!declaration.contains("extension"))
    #expect(footer.contains("extension Foo {}"))
  }

  @Test func `a block doc comment stays with its declaration`() {
    let body = """
      /**
       * A widget.
       */
      public struct Widget {
      }
      """
    let (header, declaration, _) = Surface.partition(body, named: "Widget")
    #expect(declaration.contains("A widget."))
    #expect(!header.contains("A widget."))
  }

  @Test func `a following declaration's leading comment stays in the footer`() {
    let body = """
      public struct Foo {}
      /// Bar documentation.
      public struct Bar {}
      """
    let (_, declaration, footer) = Surface.partition(body, named: "Foo")
    // The `/// Bar` comment documents `Bar`, a file-scope sibling, so it stays
    // in the footer rather than folding into `Foo`'s declaration where a
    // nesting caller would indent it into the enclosing type.
    #expect(!declaration.contains("Bar documentation"))
    #expect(footer.contains("Bar documentation"))
    #expect(footer.contains("struct Bar"))
  }

  @Test func `a trailing comment at the end of the body stays with the declaration`() {
    let body = """
      public struct Foo {}
      // end Foo
      """
    let (_, declaration, footer) = Surface.partition(body, named: "Foo")
    // Nothing follows the comment, so it trails `Foo` and stays with it.
    #expect(declaration.contains("// end Foo"))
    #expect(footer.isEmpty)
  }

  @Test func `a CRLF body partitions header, declaration, and footer`() {
    // A Windows `-I` override uses CRLF endings. `\r\n` is one `Character`
    // grapheme a `Character` split neither breaks on nor recognizes, so a plain
    // split leaves the whole body one unpartitionable line; a scalar split
    // separates the lines (keeping each `\r`) so the file-scope `import` header
    // and `extension` footer hoist off the declaration.
    let body = "import Foo\r\npublic struct Bar {\r\n}\r\nextension Bar {}"
    let (header, declaration, footer) = Surface.partition(body, named: "Bar")
    #expect(header.contains("import Foo"))
    #expect(!header.contains("struct Bar"))
    #expect(declaration.contains("struct Bar"))
    #expect(footer.contains("extension Bar"))
  }

  @Test func `a block doc comment with CRLF endings stays with the declaration`() {
    // The block-doc closer reads `*/\r` under CRLF; the delimiter recognition
    // trims the trailing `\r`, or the block doc strands in the file-scope
    // header and nesting misattaches it to the enclosing container.
    let body = "/**\r\n * A widget.\r\n */\r\npublic struct Widget {\r\n}"
    let (header, declaration, _) = Surface.partition(body, named: "Widget")
    #expect(declaration.contains("A widget."))
    #expect(!header.contains("A widget."))
  }

  @Test func `a declaration inside a top-level conditional is a declaration`() {
    let body = """
      #if os(Windows)
      public struct Point {}
      #endif
      """
    // A `#if`-guarded declaration still counts, so the emittedness check does
    // not treat the conditional node as undeclared and drop it.
    #expect(Surface.declarations(in: body).contains("Point"))
  }

  @Test func `a malformed body with no closing brace takes the fallback`() {
    // A missing `rightBrace` the parser synthesizes at EOF must not be located,
    // or the slice indexes an out-of-range/empty line and traps. `partition`
    // returns the whole body as its declaration, and `inject` splices at its
    // last-line fallback without crashing.
    let body = "public struct Foo {\n"
    let (header, declaration, footer) = Surface.partition(body, named: "Foo")
    #expect(header.isEmpty)
    #expect(footer.isEmpty)
    #expect(declaration == body)
    #expect(Surface.inject("  child", into: body, container: "Foo")
        .contains("child"))
  }

  @Test func `a nested protocol declaration is located as the primary`() {
    // `nest` folds a nested `protocol` into its container, so `partition` must
    // recognize a protocol primary — not only `struct`/`enum` — to hoist its
    // file-scope header and footer rather than indent them into the container.
    let body = """
      import Bridge
      public protocol IChild {
      }
      extension IChild {}
      """
    let (header, declaration, footer) =
        Surface.partition(body, named: "IChild")
    #expect(header.contains("import Bridge"))
    #expect(declaration.contains("protocol IChild"))
    #expect(footer.contains("extension IChild {}"))
  }
}
